// Plans: what the API builds for a user action, step by step (docs/DESIGN-stellar-parity.md §4.8, §6.8). A step is
// built when it can be (the first at once, later ones after the previous step confirms, so sequence numbers and
// simulations are always fresh), bids the network's going rate for inclusion, must fit the fee cap and pass the
// verifier, and is stored; a plan the account can't pay for is refused before anyone signs it. The user pays every
// step's network fee, exactly as signed. DyorHQ pays only an account's setup and, where activation is sponsored, one
// starter swap, each reserved (sponsor.ts) before it is sent. A simulation that finds archived data puts a user-paid
// restore step before the step that needs it (§4.9).
import type { PlanStep as StepView, PlanView, Section, SponsorReason, StepKind, TxStatus } from "./contract.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { assertAffordable, baseReserve, feeCeiling, inclusionFee, Need, positionOf, starterSwapEligibility } from "./fees.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById, contractAllowlist } from "./networks.ts";
import { launchTokensAmong } from "./assets.ts";
import { refusalError, releaseSponsorship, reserveSponsorship, settleSponsorship, sponsorshipSent, starterUsed } from "./sponsor.ts";
import {
  Address,
  classicBalances,
  feeBumpFee,
  isContractId,
  NeedsRestore,
  parseSigned,
  requireAccount,
  RestorePreamble,
  restoreTx,
  sendSigned,
  SendUnconfirmed,
  sendUserTx,
  Settled,
  signedBy,
  sorobanDataOf,
  sponsor,
  sponsorFeeBump,
  Transaction,
  txStatus,
  withInclusionBid,
  xdr,
} from "./stellar.ts";
import { Intent, verifyFeePayer, verifyTransaction, VerifyError } from "./verify.ts";

/** What createPlan() and buildStep() answer: the plan as the phone sees it (contract.ts). */
export type { PlanView };

export interface StepSpec {
  kind: string;
  /** Where activation is sponsored: DyorHQ pays this swap's fee as the account's starter swap (§4.3). */
  starter?: boolean;
  /** The SDEX route a starter swap takes instead when its own would cost DyorHQ more than starterInnerFeeMax, and the
   *  step's label then. */
  fallback?: { label: string; spec: StepSpec } | null;
  [k: string]: unknown;
}

export type StepStatus = "pending" | "built" | "submitted" | "done" | "failed";

/** A step as lite.plans keeps it: what the phone sees (contract.ts PlanStep) and the spec it is built from. */
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
  stepKind?: StepKind;
  /** The built transaction's fee, stroops. */
  maxFee?: string;
  feePayer?: "user" | "sponsor";
  sponsorReason?: SponsorReason | null;
  reserveDelta?: number;
}

export interface BuiltTx {
  tx: Transaction;
  intent: Intent;
  /** The sponsor signs too (an account's setup): only when the step is submitted, once its sponsorship is reserved
   *  (submitStep), never when it is built. An envelope the sponsor signed would let anyone who holds it send it
   *  themselves, past every sponsorship cap. */
  cosignSponsor?: boolean;
  /** The step's kind, where the builder knows it better than the spec does (a send: classic, or a token transfer). */
  stepKind?: StepKind;
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

// ------------------------------------------------------------------------------------------------ step kinds and payers

const STEP_KINDS: ReadonlySet<string> = new Set<StepKind>([
  "payment", "payment_token", "trust", "activate", "restore", "swap_sdex", "swap_soroswap", "swap_aquarius",
  "blend_submit_deposit", "blend_submit_withdraw", "launch_create", "launch_buy", "launch_sell", "launch_graduate",
  "launch_claim", "moment_publish", "moment_collect", "token_approve", "cctp_burn",
]);

/** Contracts v2's step kinds (DESIGN-stellar-contracts-v2 §20.3): each builder's own kind (launchpad_v2.ts
 *  LAUNCH_V2_STEPS, moments_v2.ts SPEC_KINDS) is the step's kind. */
const V2_STEP_KINDS: ReadonlySet<string> = new Set<StepKind>([
  "launch_v2_create", "launch_v2_buy", "launch_v2_sell", "launch_v2_refund", "launch_v2_graduate",
  "launch_v2_graduate_fallback", "launch_v2_mark_stuck", "launch_v2_rescue", "launch_v2_claim", "launch_v2_claim_owed",
  "launch_v2_claim_rewards", "launch_v2_harvest", "launch_v2_recipient_transfer", "launch_v2_recipient_cancel",
  "launch_v2_recipient_execute", "moment_v2_publish", "moment_v2_collect", "moment_v2_claim", "moment_v2_claim_all",
  "moment_v2_withdraw", "moment_v2_graduate", "moment_v2_expire",
]);

/** The step kind a spec builds (§6.3), as fees are estimated and transactions logged; null for a builder's kind that
 *  has none. A send moves a classic asset to an account (payment) or calls a token's transfer (payment_token); a Blend
 *  submit supplies (request type 0) or withdraws (1); a v2 step is its builder's kind. */
export function stepKindOf(spec: StepSpec): StepKind | null {
  if (spec.kind === "payment") {
    const asset = assetById(env.network, String(spec.asset));
    const classic = asset ? asset.classic !== null : !isContractId(String(spec.asset));
    return classic && !isContractId(String(spec.to)) ? "payment" : "payment_token";
  }
  if (spec.kind === "blend_submit") return Number(spec.requestType) === 1 ? "blend_submit_withdraw" : "blend_submit_deposit";
  return STEP_KINDS.has(spec.kind) || V2_STEP_KINDS.has(spec.kind) ? spec.kind as StepKind : null;
}

/** A built step's kind: a v2 step's is its spec's, the same before and after it is built, so its fees are learned
 *  apart from v1's (some v2 builders name v1's kind); any other builder's where it knows better (a send's), else the
 *  spec's. */
function builtKindOf(made: BuiltTx, spec: StepSpec): StepKind | null {
  if (V2_STEP_KINDS.has(spec.kind)) return spec.kind as StepKind;
  return made.stepKind ?? stepKindOf(spec);
}

/** New base reserves a step holds back on the user's account: a trustline is one. */
function reserveDeltaOf(kind: StepKind | null): number {
  return kind === "trust" ? 1 : 0;
}

/** Who pays a step: DyorHQ for an account's setup and a starter swap; the user for everything else. */
function payerOf(kind: StepKind | null, spec: StepSpec): { feePayer: "user" | "sponsor"; sponsorReason: SponsorReason | null } {
  if (kind === "activate") return { feePayer: "sponsor", sponsorReason: "setup" };
  if (spec.starter) return { feePayer: "sponsor", sponsorReason: "starter_swap" };
  return { feePayer: "user", sponsorReason: null };
}

function feeTooHigh(fee: bigint, max: bigint): ApiError {
  return new ApiError(422, "fee_too_high", "The network fee is unusually high right now. Nothing was sent. Try again in a minute.", {
    fee: fee.toString(),
    max: max.toString(),
  });
}

// ------------------------------------------------------------------------------------------------ building

/** Launch tokens are deployed at runtime, so they can't be pinned by id: a contract counts as one when the indexer
 *  saw our launchpad create it. (The phone checks its WASM hash against the pinned launch-token hash.) A restore's
 *  candidates are the contracts whose data it brings back. */
async function launchTokensIn(intent: Intent, tx?: Transaction): Promise<string[]> {
  const ids = (intent.calls ?? []).map((c) => c.contract);
  if (intent.kind === "restore" && tx) ids.push(...footprintContracts(tx));
  return await launchTokensAmong(ids);
}

function footprintContracts(tx: Transaction): string[] {
  const footprint = sorobanDataOf(tx)?.resources().footprint();
  if (!footprint) return [];
  return [...footprint.readOnly(), ...footprint.readWrite()]
    .filter((k) => k.switch() === xdr.LedgerEntryType.contractData())
    .map((k) => k.contractData().contract())
    .filter((c) => c.switch() === xdr.ScAddressType.scAddressTypeContract())
    .map((c) => Address.fromScAddress(c).toString());
}

/** Runs `spec`'s builder, then bids the network's going rate for inclusion. */
async function make(user: string, spec: StepSpec): Promise<BuiltTx> {
  const builder = builders.get(spec.kind);
  if (!builder) throw new Error(`no builder for ${spec.kind}`);
  const built = await builder(user, spec);
  const bid = await inclusionFee(sorobanDataOf(built.tx) ? "soroban" : "classic");
  return { ...built, tx: withInclusionBid(built.tx, bid) };
}

/** Whether DyorHQ may fee-bump `tx` as a starter swap: the fee-bump costs at most starterInnerFeeMax (§4.3). */
function starterFits(tx: Transaction): boolean {
  return feeBumpFee(tx) <= env.network.feePolicy.starterInnerFeeMax;
}

/** Whether a starter-swap spec still qualifies for this user right now (§4.3). */
async function starterVerdict(user: string, spec: StepSpec) {
  const sell = assetById(env.network, String(spec.sell));
  const buy = assetById(env.network, String(spec.buy));
  const position = positionOf(await classicBalances(user), await baseReserve());
  const spendable = BigInt(position?.spendable ?? "0");
  const policy = env.network.feePolicy;
  const input = {
    activation: env.network.activation,
    buysXlm: buy?.id === "XLM",
    sellsRegistryAsset: Boolean(sell) && sell!.id !== "XLM",
    spendable,
    minOut: BigInt(String(spec.minOut ?? "0")),
    used: false,
  };
  const first = starterSwapEligibility(input, policy);
  if (!first.eligible) return first;
  return starterSwapEligibility({ ...input, used: await starterUsed(user) }, policy);
}

/** Builds a step: the transaction, its fee checks and the verifier's. A starter swap stays DyorHQ's only while it
 *  qualifies and its fee-bump fits starterInnerFeeMax. When its route's doesn't fit, it takes its SDEX route, which
 *  must qualify too (its own minimum out) and then names the step; failing that, the user pays it. */
async function build(user: string, step: PlanStep): Promise<PlanStep> {
  let { label, spec } = step;
  if (spec.starter && !(await starterVerdict(user, spec)).eligible) spec = { ...spec, starter: false, fallback: null };
  let made = await make(user, spec);
  if (spec.starter && !starterFits(made.tx)) {
    const fallback = spec.fallback ? { label: spec.fallback.label, spec: { ...spec.fallback.spec, starter: true } } : null;
    const alt = fallback && (await starterVerdict(user, fallback.spec)).eligible ? await make(user, fallback.spec) : null;
    if (fallback && alt && starterFits(alt.tx)) {
      ({ label, spec } = fallback);
      made = alt;
    } else {
      spec = { ...spec, starter: false, fallback: null };
    }
  }
  const { tx, intent } = made;
  const kind = builtKindOf(made, spec);
  const policy = env.network.feePolicy;
  const fee = BigInt(tx.fee);
  if (fee > policy.maxFee) throw feeTooHigh(fee, policy.maxFee);
  if (kind === "activate" && fee > policy.activationMaxFee) throw feeTooHigh(fee, policy.activationMaxFee);
  // Nobody signs here: the step goes out unsigned, and the sponsor of an account's setup signs only in submitStep,
  // after its sponsorship is reserved.
  const payer = payerOf(kind, spec);
  const ctx = verifyContext(user, await launchTokensIn(intent, tx));
  try {
    verifyTransaction(tx, intent, ctx);
    // The phone believes DyorHQ pays only where it can check it (§4.3): so must the step we hand out.
    const checked = verifyFeePayer(tx, intent, payer, ctx);
    if ((payer.sponsorReason ?? "user") !== checked) throw new VerifyError(`the step's payer is ${checked}, not ${payer.sponsorReason}`);
  } catch (err) {
    // A builder produced something the phone would refuse: never hand it out.
    console.error("self-check failed", spec.kind, err);
    throw new ApiError(500, "self_check_failed", "We built a transaction that didn't pass our own checks. Nothing was sent.", {
      reason: err instanceof VerifyError ? err.message : String(err),
    });
  }
  return {
    ...step,
    label,
    spec,
    status: "built",
    intent,
    xdr: tx.toEnvelope().toXDR("base64"),
    hash: tx.hash().toString("hex"),
    builtAt: new Date().toISOString(),
    error: undefined,
    stepKind: kind ?? undefined,
    maxFee: fee.toString(),
    feePayer: payer.feePayer,
    sponsorReason: payer.sponsorReason,
    reserveDelta: reserveDeltaOf(kind),
  };
}

/** A restore step brings back what a simulation found archived, paid by the user, before the step that needs it. */
registerBuilder("restore", async (user, spec) => {
  const acct = await requireAccount(user);
  const tx = restoreTx(acct, spec.preamble as RestorePreamble);
  const intent: Intent = {
    kind: "restore",
    summary: `Restore archived data for ${String(spec.for)}`,
    spend: {},
    ops: ["restoreFootprint"],
    display: { for: String(spec.for) },
  };
  return { tx, intent };
});

/** Builds `steps[idx]`. When it needs archived data restored first, a restore step goes in before it (built) and it
 *  stays to be built after; when even that can't be offered (the data isn't the app's own), the step's 409
 *  needs_restore stands. */
async function buildAt(user: string, steps: PlanStep[], idx: number): Promise<PlanStep[]> {
  const step = steps[idx];
  try {
    const built = await build(user, step);
    return steps.map((s, i) => (i === idx ? built : s));
  } catch (err) {
    if (!(err instanceof NeedsRestore)) throw err;
    const ids = new Set(steps.map((s) => s.id));
    let id = `${step.id}r`;
    for (let n = 2; ids.has(id); n++) id = `${step.id}r${n}`;
    const pending: PlanStep = { id, label: `Restore archived data for ${step.label}`, spec: { kind: "restore", for: step.label, preamble: err.preamble }, status: "pending" };
    let restore: PlanStep;
    try {
      restore = await build(user, pending);
    } catch (refused) {
      console.warn("restore step refused", step.spec.kind, String((refused as Error).message ?? refused).slice(0, 200));
      throw err;
    }
    // The step waits, unbuilt: whatever an earlier build left (an envelope, its fee) no longer stands.
    const waiting: PlanStep = { id: step.id, label: step.label, spec: step.spec, status: "pending" };
    return [...steps.slice(0, idx), restore, waiting, ...steps.slice(idx + 1)];
  }
}

// ------------------------------------------------------------------------------------------------ what a plan costs

const XLM_ID = "XLM";

/** XLM an unbuilt step will send or spend, from its spec (a send or a swap of XLM); built steps say it in their intent. */
function specXlmSpend(spec: StepSpec): bigint {
  const xlm = (id: unknown) => assetById(env.network, String(id))?.id === XLM_ID;
  if (spec.kind === "payment" && xlm(spec.asset)) return BigInt(String(spec.amount ?? "0"));
  if (spec.kind.startsWith("swap_") && xlm(spec.sell)) return BigInt(String(spec.amountIn ?? "0"));
  return 0n;
}

/** What `steps` take from the user's spendable XLM: their fees (a built step's own fee, an unbuilt one's ceiling),
 *  their new reserves and the XLM they send. Steps DyorHQ pays add no fee. */
async function needOf(steps: PlanStep[], reserve: () => Promise<bigint>): Promise<Need> {
  const xlm = assetById(env.network, XLM_ID)!.contract;
  let fee = 0n, reserves = 0n, amount = 0n;
  for (const s of steps) {
    if (s.status === "done" || s.status === "submitted") continue;
    const kind = s.stepKind ?? stepKindOf(s.spec);
    if (payerOf(kind, s.spec).feePayer === "user") fee += s.maxFee ? BigInt(s.maxFee) : await ceilingOf(kind);
    reserves += BigInt(s.reserveDelta ?? reserveDeltaOf(kind));
    amount += s.intent ? BigInt(s.intent.spend[xlm] ?? "0") : specXlmSpend(s.spec);
  }
  return { fee, reserve: reserves > 0n ? reserves * (await reserve()) : 0n, amount };
}

/** Refuses, before anyone signs, a plan the user's account can't pay for from steps[from] on (§4.6). */
async function assertPlanAffordable(user: string, steps: PlanStep[], from: number): Promise<void> {
  let reserve: bigint | null = null;
  const reserveOnce = async () => (reserve ??= await baseReserve());
  const need = await needOf(steps.slice(from), reserveOnce);
  if (need.fee === 0n && need.reserve === 0n && need.amount === 0n) return;
  const position = positionOf(await classicBalances(user), await reserveOnce());
  // A missing account can't run a user-paid step anyway: its builders answer account_inactive.
  if (!position) return;
  assertAffordable({ spendable: BigInt(position.spendable), minBalance: BigInt(position.minBalance) }, need);
}

async function ceilingOf(kind: StepKind | null): Promise<bigint> {
  return kind ? await feeCeiling(kind) : env.network.feePolicy.maxFee;
}

// ------------------------------------------------------------------------------------------------ plans

/** A step as the phone sees it (§6.8): an unbuilt one priced at its kind's ceiling. */
async function stepView(s: PlanStep): Promise<StepView> {
  const kind = s.stepKind ?? stepKindOf(s.spec);
  const payer = s.feePayer ? { feePayer: s.feePayer, sponsorReason: s.sponsorReason ?? null } : payerOf(kind, s.spec);
  return {
    id: s.id,
    label: s.label,
    status: s.status,
    ...(s.intent ? { intent: s.intent } : {}),
    ...(s.xdr ? { xdr: s.xdr } : {}),
    ...(s.hash ? { hash: s.hash } : {}),
    ...(s.txHash ? { txHash: s.txHash } : {}),
    ...(s.builtAt ? { builtAt: s.builtAt } : {}),
    ...(s.error ? { error: s.error } : {}),
    ...(kind ? { stepKind: kind } : {}),
    maxFee: s.maxFee ?? (await ceilingOf(kind)).toString(),
    feePayer: payer.feePayer,
    sponsorReason: payer.sponsorReason,
    reserveDelta: s.reserveDelta ?? reserveDeltaOf(kind),
  };
}

async function view(id: string, kind: string, expiresAt: Date | string, steps: PlanStep[]): Promise<PlanView> {
  const views = await Promise.all(steps.map(stepView));
  const userMax = views.filter((s) => s.feePayer === "user").reduce((sum, s) => sum + BigInt(s.maxFee ?? "0"), 0n);
  return {
    planId: id,
    kind,
    expiresAt: new Date(expiresAt).toISOString(),
    steps: views,
    fees: {
      userMax: userMax.toString(),
      sponsored: views.some((s) => s.feePayer === "sponsor"),
      newReserves: views.reduce((n, s) => n + (s.reserveDelta ?? 0), 0),
    },
  };
}

export async function createPlan(user: string, kind: string, steps: { label: string; spec: StepSpec }[]): Promise<PlanView> {
  if (steps.length === 0) throw bad("empty_plan", "Nothing to do.");
  let all: PlanStep[] = steps.map((s, i) => ({ id: `s${i + 1}`, label: s.label, spec: s.spec, status: "pending" }));
  all = await buildAt(user, all, 0);
  await assertPlanAffordable(user, all, 0);
  const rows = await sql()`
    insert into lite.plans (address, kind, steps) values (${user}, ${kind}, ${sql().json(all as any)})
    returning id, expires_at`;
  return await view(rows[0].id as string, kind, rows[0].expires_at as Date, all);
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
  plan.steps = await buildAt(user, plan.steps, idx);
  await assertPlanAffordable(user, plan.steps, idx);
  await savePlan(planId, plan.steps);
  return await view(planId, plan.kind, plan.expiresAt, plan.steps);
}

/** Throws unless the starter swap `spec` still qualifies (§4.3): one used already is 409 already_set_up; any other
 *  change (the account has XLM to pay with now) makes the signed step stale, so it is reviewed again as user-paid. */
async function assertStarter(user: string, spec: StepSpec): Promise<void> {
  const verdict = await starterVerdict(user, spec);
  if (verdict.eligible) return;
  if (verdict.reason === "used") throw refusalError("starter", "once");
  throw new ApiError(409, "stale_step", "DyorHQ no longer pays this swap's network fee. Nothing was sent. Review the swap again.", {
    reason: verdict.reason,
  });
}

/** Sends a signed step (§4.8): the hash must be the step's and the signature the user's; the fee must fit the cap and
 *  the verifier must pass it again. Then the user's own transaction is sent as signed, or for an account's setup and
 *  a starter swap the sponsorship is reserved first, and only then does the sponsor sign (the setup itself, or the
 *  starter swap's fee-bump). Refused, nothing was sent: the step fails, and the sponsorship is
 *  released. Unconfirmed (RPC gave no answer), it may land: it counts as sent, keeping its sponsorship, and settling it
 *  tells. Logged in lite.tx_log with who pays, the step kind, the section and the declared fee. */
export async function submitStep(user: string, planId: string, stepId: string, signedXdr: string, ip: string): Promise<{ hash: string; status: "pending" }> {
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
  const policy = env.network.feePolicy;
  if (BigInt(tx.fee) > policy.maxFee) throw feeTooHigh(BigInt(tx.fee), policy.maxFee);
  try {
    verifyTransaction(tx, step.intent, verifyContext(user, await launchTokensIn(step.intent, tx)));
  } catch (err) {
    if (!(err instanceof VerifyError)) throw err;
    throw new ApiError(500, "self_check_failed", "We built a transaction that didn't pass our own checks. Nothing was sent.", { reason: err.message });
  }

  const reason = step.feePayer === "sponsor" ? step.sponsorReason ?? null : null;
  let sponsorship: string | null = null;
  let hash: string;
  try {
    if (reason === "setup") {
      // The sponsor signs only now, once the sponsorship is reserved (the caps counted it), and only the transaction
      // the step's hash names: the envelope the user was handed carries no signature of DyorHQ's.
      sponsorship = await reserveSponsorship(user, "activate", ip, BigInt(tx.fee));
      tx.sign(sponsor());
      hash = await sendSigned(tx, "sponsor");
    } else if (reason === "starter_swap") {
      await assertStarter(user, step.spec);
      const bump = sponsorFeeBump(tx, policy.starterInnerFeeMax);
      sponsorship = await reserveSponsorship(user, "starter", ip, BigInt(bump.fee));
      hash = await sendSigned(bump, "sponsor");
    } else {
      hash = await sendUserTx(tx);
    }
  } catch (err) {
    if (!(err instanceof SendUnconfirmed)) {
      if (sponsorship) await releaseSponsorship(sponsorship);
      plan.steps[idx] = { ...step, status: "failed", error: (err as Error).message };
      await savePlan(planId, plan.steps);
      throw err;
    }
    // It may land: a failed step could be built and sent again, a released sponsorship paid for twice. Settling it
    // (trackTx, jobs/settle.ts) settles both: success, or failed once it can no longer land.
    console.warn("submit: unconfirmed, settled later", JSON.stringify(err.detail).slice(0, 300));
    hash = err.hash;
  }
  if (sponsorship) await sponsorshipSent(sponsorship, hash);
  const intent = step.intent;
  const launches = new Set(await launchTokensAmong([...Object.keys(intent.spend ?? {}), ...Object.keys(intent.receive ?? {})]));
  await sql()`
    insert into lite.tx_log (hash, inner_hash, address, plan_id, step_id, kind, intent, max_fee, fee_payer, step_kind, section)
    values (${hash}, ${step.hash}, ${user}, ${planId}, ${stepId}, ${intent.kind}, ${sql().json(intent as any)}, ${tx.fee},
            ${reason ? "sponsor" : "user"}, ${step.stepKind ?? null}, ${sectionOf(intent, launches)})`;
  plan.steps[idx] = { ...step, status: "submitted", txHash: hash };
  await savePlan(planId, plan.steps);
  return { hash, status: "pending" };
}

// ------------------------------------------------------------------------------------------------ outcomes

/** A logged transaction: what settling it needs. */
export interface LoggedTx {
  hash: string;
  status: string;
  plan_id: string | null;
  step_id: string | null;
  step_kind: string | null;
  fee_payer: string;
  ledger?: number | null;
  error?: string | null;
  fee_charged?: string | number | bigint | null;
  result?: { amountOut?: string | null } | null;
}

/** Status of a logged transaction; settles its log row, plan step and sponsorship when it lands. */
export async function trackTx(user: string, hash: string): Promise<TxStatus> {
  if (!/^[0-9a-f]{64}$/.test(hash)) throw notFound("Transaction");
  const rows = await sql()`
    select hash, status, plan_id, step_id, step_kind, fee_payer, ledger, error, fee_charged, result
      from lite.tx_log where hash = ${hash} and address = ${user}`;
  if (rows.length === 0) throw notFound("Transaction");
  const row = rows[0] as unknown as LoggedTx;
  if (row.status !== "pending") {
    // The indexer may have settled it first (jobs/settle.ts). A success still answers with its return value (a new
    // launch token or Moment id), which only RPC keeps; if RPC no longer has it, the settled row stands.
    if (row.status === "success") {
      try {
        const s = await txStatus(hash);
        if (s.status === "SUCCESS") return statusOf(row, s.returnValue);
      } catch { /* RPC unreachable: answer from the log */ }
    }
    return statusOf(row);
  }
  const s = await txStatus(hash);
  if (s.status === "PENDING") return { hash, status: "pending" };
  return statusOf(await settle(row, s), s.returnValue);
}

function statusOf(row: LoggedTx, returnValue?: unknown): TxStatus {
  const status = row.status as TxStatus["status"];
  if (status === "pending") return { hash: row.hash, status };
  return {
    hash: row.hash,
    status,
    ...(row.ledger !== null && row.ledger !== undefined ? { ledger: Number(row.ledger) } : {}),
    ...(row.error ? { error: row.error } : {}),
    ...(returnValue !== undefined ? { returnValue } : {}),
    ...(row.fee_charged !== null && row.fee_charged !== undefined ? { feeCharged: String(row.fee_charged) } : {}),
    feePayer: row.fee_payer as TxStatus["feePayer"],
    result: { amountOut: row.result?.amountOut ?? null },
  };
}

/** Records a logged transaction's outcome (§4.8): its status, ledger, the fee charged and what it delivered; then its
 *  plan step, and the sponsorship that paid for it. Settling twice changes nothing. */
export async function settle(row: LoggedTx, s: Settled): Promise<LoggedTx> {
  const status = s.status === "SUCCESS" ? "success" : "failed";
  const result = status === "success" ? outcomeOf(row.step_kind, s) : { amountOut: null };
  const updated = await sql()`
    update lite.tx_log set status = ${status}, ledger = ${s.ledger ?? null}, fee_charged = ${s.feeCharged ?? null},
           error = ${s.error ?? null}, result = ${sql().json(result)}, updated_at = now()
     where hash = ${row.hash} and status = 'pending' returning hash`;
  if (updated.length) {
    if (row.plan_id && row.step_id) {
      const p = await sql()`select steps from lite.plans where id = ${row.plan_id}`;
      if (p.length) {
        const steps = p[0].steps as PlanStep[];
        const i = steps.findIndex((x) => x.id === row.step_id);
        if (i >= 0 && steps[i].status === "submitted") {
          steps[i] = { ...steps[i], status: status === "success" ? "done" : "failed", error: s.error };
          await savePlan(row.plan_id, steps);
        }
      }
    }
    if (row.fee_payer === "sponsor") await settleSponsorship(row.hash, status, s.feeCharged);
  }
  return { ...row, status, ledger: s.ledger ?? null, error: s.error ?? null, fee_charged: s.feeCharged ?? null, result };
}

/** An integer as base units, or null. */
function units(v: unknown): string | null {
  if (typeof v === "bigint") return v.toString();
  if (typeof v === "number" && Number.isSafeInteger(v)) return String(v);
  if (typeof v === "string" && /^-?[0-9]+$/.test(v)) return v;
  return null;
}

/** What a settled step delivered (§6.11): an SDEX path payment's last amount, the last element of Soroswap's amounts,
 *  Aquarius's u128, a curve buy's tokens out or a sell's quote out (v2's buy and sell return that amount itself); any
 *  other step's return value when it is an amount. Null when it delivered none. */
export function outcomeOf(stepKind: string | null | undefined, settled: Pick<Settled, "resultXdr" | "returnValue">): { amountOut: string | null } {
  const rv = settled.returnValue;
  const field = (name: string) => (rv && typeof rv === "object" && !Array.isArray(rv) ? units((rv as Record<string, unknown>)[name]) : null);
  switch (stepKind) {
    case "swap_sdex":
      return { amountOut: pathPaymentOut(settled.resultXdr) };
    case "swap_soroswap":
      return { amountOut: Array.isArray(rv) && rv.length > 0 ? units(rv[rv.length - 1]) : null };
    case "launch_buy":
    case "launch_v2_buy":
      return { amountOut: field("tokens_out") ?? units(rv) };
    case "launch_sell":
    case "launch_v2_sell":
      return { amountOut: field("quote_out") ?? units(rv) };
    default:
      return { amountOut: units(rv) };
  }
}

/** The amount a pathPaymentStrictSend delivered, from the transaction's result (a fee-bump's inner one included). */
function pathPaymentOut(resultXdr: string | undefined): string | null {
  if (!resultXdr) return null;
  try {
    let r: any = xdr.TransactionResult.fromXDR(resultXdr, "base64").result();
    if (r.switch().name === "txFeeBumpInnerSuccess") r = r.innerResultPair().result().result();
    if (r.switch().name !== "txSuccess") return null;
    for (const op of r.results() as xdr.OperationResult[]) {
      const tr = op.tr();
      if (tr.switch().name !== "pathPaymentStrictSend") continue;
      const res = tr.pathPaymentStrictSendResult();
      if (res.switch().name !== "pathPaymentStrictSendSuccess") continue;
      return res.success().last().amount().toString();
    }
  } catch { /* not a result we can read */ }
  return null;
}

/** The section a step counts in (§6.11): a swap is `launch` when either side is a launch token, otherwise `spot`; a
 *  send is spot; setup, trustlines, the faucet and restores are `account`; Earn, launches and Moments their own;
 *  allowances and bridging `bridge`. */
export function sectionOf(intent: Pick<Intent, "kind" | "spend" | "receive">, launchTokens: Set<string>): Section | null {
  const k = intent.kind;
  if (k === "swap") {
    const sides = [...Object.keys(intent.spend ?? {}), ...Object.keys(intent.receive ?? {})];
    return sides.some((c) => launchTokens.has(c)) ? "launch" : "spot";
  }
  if (k === "payment") return "spot";
  if (k === "trust" || k === "activate" || k === "faucet" || k === "restore") return "account";
  if (k.startsWith("earn_")) return "earn";
  if (k.startsWith("launch_")) return "launch";
  if (k.startsWith("moment_")) return "moments";
  if (k === "approve" || k === "bridge_out") return "bridge";
  return null;
}
