// Plans: what the API builds for a user action, step by step. A step is built when it can be (the first at once,
// later ones after the previous step confirms, so sequence numbers and simulations are always fresh), checked by
// the verifier, stored, then fee-bumped only if the signed transaction's hash equals the stored one.
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { contractAllowlist } from "./networks.ts";
import { feeBumpAndSend, parseSigned, signedBy, sponsor, Transaction, txStatus } from "./stellar.ts";
import { Intent, verifyTransaction, VerifyError } from "./verify.ts";

export interface StepSpec {
  kind: string;
  [k: string]: unknown;
}

export type StepStatus = "pending" | "built" | "submitted" | "done" | "failed";

export interface PlanStep {
  id: string;
  label: string;
  spec: StepSpec;
  status: StepStatus;
  intent?: Intent;
  xdr?: string;
  hash?: string;
  txHash?: string;
  builtAt?: string;
  error?: string;
}

export interface BuiltTx {
  tx: Transaction;
  intent: Intent;
  /** The sponsor signs too (sponsored reserves, account creation). */
  cosignSponsor?: boolean;
}

export type Builder = (user: string, spec: StepSpec) => Promise<BuiltTx>;

const builders = new Map<string, Builder>();

export function registerBuilder(kind: string, builder: Builder): void {
  builders.set(kind, builder);
}

export function verifyContext(user: string, extra: string[] = []) {
  const allow = contractAllowlist(env.network);
  return {
    user,
    sponsor: sponsor().publicKey(),
    passphrase: env.network.passphrase,
    allowedContracts: new Set([...Object.values(allow).flat(), ...extra]),
  };
}

/** Launch tokens are deployed at runtime, so they can't be pinned by id: a call to one is allowed when the indexer
 *  saw our launchpad create it. (The phone checks the token's WASM hash against the pinned launch-token hash.) */
async function launchTokensIn(intent: Intent): Promise<string[]> {
  const ids = (intent.calls ?? []).map((c) => c.contract);
  if (ids.length === 0) return [];
  const rows = await sql()`select token from lite.launches where token = any(${ids})`;
  return rows.map((r) => r.token as string);
}

async function build(user: string, step: PlanStep): Promise<PlanStep> {
  const builder = builders.get(step.spec.kind);
  if (!builder) throw new Error(`no builder for ${step.spec.kind}`);
  const { tx, intent, cosignSponsor } = await builder(user, step.spec);
  if (cosignSponsor) tx.sign(sponsor());
  try {
    verifyTransaction(tx, intent, verifyContext(user, await launchTokensIn(intent)));
  } catch (err) {
    // A builder produced something the phone would refuse: never hand it out.
    console.error("self-check failed", step.spec.kind, err);
    throw new ApiError(500, "self_check_failed", "We built a transaction that didn't pass our own checks. Nothing was sent.", {
      reason: err instanceof VerifyError ? err.message : String(err),
    });
  }
  return {
    ...step,
    intent,
    xdr: tx.toEnvelope().toXDR("base64"),
    hash: tx.hash().toString("hex"),
    status: "built",
    builtAt: new Date().toISOString(),
    error: undefined,
  };
}

export interface PlanView {
  planId: string;
  kind: string;
  expiresAt: string;
  steps: Omit<PlanStep, "spec">[];
}

function view(id: string, kind: string, expiresAt: Date | string, steps: PlanStep[]): PlanView {
  return {
    planId: id,
    kind,
    expiresAt: new Date(expiresAt).toISOString(),
    steps: steps.map(({ spec: _spec, ...rest }) => rest),
  };
}

export async function createPlan(user: string, kind: string, steps: { label: string; spec: StepSpec }[]): Promise<PlanView> {
  if (steps.length === 0) throw bad("empty_plan", "Nothing to do.");
  const all: PlanStep[] = steps.map((s, i) => ({ id: `s${i + 1}`, label: s.label, spec: s.spec, status: "pending" }));
  all[0] = await build(user, all[0]);
  const rows = await sql()`
    insert into lite.plans (address, kind, steps) values (${user}, ${kind}, ${sql().json(all as any)})
    returning id, expires_at`;
  return view(rows[0].id as string, kind, rows[0].expires_at as Date, all);
}

async function loadPlan(user: string, planId: string): Promise<{ kind: string; steps: PlanStep[]; expiresAt: Date }> {
  if (!/^[0-9a-f-]{36}$/.test(planId)) throw notFound("Plan");
  const rows = await sql()`select kind, steps, expires_at from lite.plans where id = ${planId} and address = ${user}`;
  if (rows.length === 0) throw notFound("Plan");
  if ((rows[0].expires_at as Date).getTime() < Date.now()) throw new ApiError(410, "plan_expired", "This took too long. Start again.");
  return { kind: rows[0].kind as string, steps: rows[0].steps as PlanStep[], expiresAt: rows[0].expires_at as Date };
}

async function savePlan(planId: string, steps: PlanStep[]): Promise<void> {
  await sql()`update lite.plans set steps = ${sql().json(steps as any)} where id = ${planId}`;
}

/** Builds (or rebuilds) a step once every step before it has confirmed. */
export async function buildStep(user: string, planId: string, stepId: string): Promise<PlanView> {
  const plan = await loadPlan(user, planId);
  const idx = plan.steps.findIndex((s) => s.id === stepId);
  if (idx < 0) throw notFound("Step");
  const step = plan.steps[idx];
  if (step.status === "submitted" || step.status === "done") throw new ApiError(409, "already_sent", "This step was already sent.");
  if (plan.steps.slice(0, idx).some((s) => s.status !== "done")) throw new ApiError(409, "not_ready", "Finish the previous step first.");
  plan.steps[idx] = await build(user, step);
  await savePlan(planId, plan.steps);
  return view(planId, plan.kind, plan.expiresAt, plan.steps);
}

export async function submitStep(user: string, planId: string, stepId: string, signedXdr: string): Promise<{ hash: string; status: string }> {
  const plan = await loadPlan(user, planId);
  const idx = plan.steps.findIndex((s) => s.id === stepId);
  if (idx < 0) throw notFound("Step");
  const step = plan.steps[idx];
  if (step.status !== "built" || !step.hash || !step.intent) throw new ApiError(409, "not_built", "Build this step first.");
  const tx = parseSigned(signedXdr);
  if (tx.hash().toString("hex") !== step.hash) {
    throw new ApiError(409, "stale_step", "This isn't the transaction we prepared. Nothing was sent.");
  }
  if (!signedBy(tx, user)) throw bad("unsigned", "Your signature is missing.");
  verifyTransaction(tx, step.intent, verifyContext(user, await launchTokensIn(step.intent)));

  const maxFee = env.maxFeePerTx;
  const ok = await sql()`select lite.reserve_fee_budget(${user}, ${maxFee.toString()}::bigint, ${env.dailyFeeBudget.toString()}::bigint) as ok`;
  if (!ok[0].ok) throw new ApiError(429, "budget_exhausted", "You've used today's free transactions. Try again tomorrow.");

  let submitted;
  try {
    submitted = await feeBumpAndSend(tx, maxFee);
  } catch (err) {
    plan.steps[idx] = { ...step, status: "failed", error: (err as Error).message };
    await savePlan(planId, plan.steps);
    // Give the reserved budget back: nothing was charged.
    await sql()`update lite.sponsor_usage set fee_stroops = greatest(0, fee_stroops - ${maxFee.toString()}::bigint), tx_count = greatest(0, tx_count - 1)
                 where address = ${user} and day = (now() at time zone 'utc')::date`;
    throw err;
  }
  // Settle the reservation to the real fee.
  await sql()`update lite.sponsor_usage set fee_stroops = greatest(0, fee_stroops - ${maxFee.toString()}::bigint + ${submitted.fee}::bigint)
               where address = ${user} and day = (now() at time zone 'utc')::date`;
  await sql()`
    insert into lite.tx_log (hash, inner_hash, address, plan_id, step_id, kind, intent, max_fee)
    values (${submitted.hash}, ${submitted.innerHash}, ${user}, ${planId}, ${stepId}, ${step.intent.kind}, ${sql().json(step.intent as any)}, ${submitted.fee})`;
  plan.steps[idx] = { ...step, status: "submitted", txHash: submitted.hash };
  await savePlan(planId, plan.steps);
  return { hash: submitted.hash, status: "pending" };
}

/** Status of a sponsored transaction; settles its log row and plan step when it lands. */
export async function trackTx(user: string, hash: string): Promise<{ hash: string; status: string; ledger?: number; error?: string; returnValue?: unknown }> {
  if (!/^[0-9a-f]{64}$/.test(hash)) throw notFound("Transaction");
  const rows = await sql()`select status, plan_id, step_id, ledger, error from lite.tx_log where hash = ${hash} and address = ${user}`;
  if (rows.length === 0) throw notFound("Transaction");
  const row = rows[0];
  if (row.status !== "pending") {
    const settled = { hash, status: row.status as string, ledger: row.ledger as number, error: (row.error as string) ?? undefined };
    // The indexer may have settled it first (settlePending). A success still answers with its return value (a new
    // launch token or Moment id), which only RPC keeps; if RPC no longer has it, the settled row stands.
    if (row.status === "success") {
      try {
        const s = await txStatus(hash);
        if (s.status === "SUCCESS") return { ...settled, returnValue: s.returnValue };
      } catch { /* RPC unreachable: answer from the log */ }
    }
    return settled;
  }
  const s = await txStatus(hash);
  if (s.status === "PENDING") return { hash, status: "pending" };
  const status = s.status === "SUCCESS" ? "success" : "failed";
  await settle(hash, status, s.ledger, s.feeCharged, s.error, row.plan_id as string | null, row.step_id as string | null);
  return { hash, status, ledger: s.ledger, error: s.error, returnValue: s.returnValue };
}

export async function settle(hash: string, status: "success" | "failed", ledger?: number, fee?: string, error?: string, planId?: string | null, stepId?: string | null) {
  await sql()`update lite.tx_log set status = ${status}, ledger = ${ledger ?? null}, fee_charged = ${fee ?? null}, error = ${error ?? null}, updated_at = now()
               where hash = ${hash} and status = 'pending'`;
  if (planId && stepId) {
    const p = await sql()`select steps from lite.plans where id = ${planId}`;
    if (p.length) {
      const steps = p[0].steps as PlanStep[];
      const i = steps.findIndex((s) => s.id === stepId);
      if (i >= 0 && steps[i].status === "submitted") {
        steps[i] = { ...steps[i], status: status === "success" ? "done" : "failed", error: error };
        await savePlan(planId, steps);
      }
    }
  }
}
