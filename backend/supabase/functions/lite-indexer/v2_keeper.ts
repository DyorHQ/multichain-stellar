// The v2 keeper (docs/DESIGN-stellar-contracts-v2.md §20.6): permissionless upkeep that DyorHQ pays for, sent from the
// keeper's account one transaction at a time. It never signs for anyone else: a call whose simulation asks for any
// authorization is refused before it is signed.
// - Graduation (L3, F14, F15). Every completed v2 launch and GraduationPending Moment is simulated each run. A graduation
//   that would succeed is sent. A recoverable failure (the call returns Failed) is sent once, while no failure is
//   recorded yet, so the failure is recorded (for a Moment it starts the stuck clock); afterwards only attempts that would
//   succeed are sent, and one that aborts never is. During fallback_delay that is the per-minute retry on the creator's
//   venue; from fallback_at, graduate_fallback is sent only when the simulated graduate fails and the fallback's own
//   simulation succeeds. mark_stuck is for launches only, once the grace has passed with nothing recorded (an aborting
//   graduate records nothing); Moments have none. rescue from rescue_public_at, so holders never depend on the admin
//   (O2). Moments past their deadline are expired once the contract allows it, the backstop included (V11).
// - Fees and rewards. Each locker position is harvested once per harvest_interval when its harvestable growth is above
//   the floor (0 on testnet, A8e); booked protocol and launch fees are swept with claim_protocol_fees, at most 20 launches
//   a call and one quote per call; launch tokens' protocol shares with sweep_protocol; after a treasury change, every
//   graduated sharing launch excludes the new treasury (exclude_treasury, V2); other DEX pools of sharing launches are
//   excluded only when exclude_pool's simulation passes the floor, those under it checked again hourly (L5, F2).
// - Alerts (F11, V10, V11), each fired once (lite.keeper_alerts) and logged: the Aquarius executor's AQUA float below
//   5 × the pool payment; a grad_fail of exec-aquarius' PaymentUnavailable or PaymentTooHigh, matched on the namespaced
//   (origin, code) pair; a launch stuck past fallback_delay; a Moment pending an hour with no recorded failure, and
//   again a day before its backstop.
// - lite.keeper_skip (F5, V5): on testnet-qa every job above that acts on a launch or a Moment checks it (graduate,
//   fallback, mark_stuck, rescue, expire, harvest); anywhere else its rows are ignored, with a warning.
// - The paths first (lead note on CT-15): a graduation stays under the per-transaction memory limit only while every
//   code entry it runs is live; archived code misses the module cache, and the abort can't be recorded. Before it
//   graduates or harvests anything, the keeper checks the paths' code and instances (_shared/ttl.ts v2PathEntries),
//   restores what is archived in a transaction of its own and leaves the graduations and harvests to the next run.
//   Archived data on one graduation's or harvest's footprint is restored the same way, from its simulation's preamble.
//   A graduation whose simulation runs out of budget is alerted.
import { rpc, type xdr as Xdr } from "@stellar/stellar-sdk";
import { sql, tableExists } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { inclusionFee } from "../_shared/fees.ts";
import type { NetworkConfig } from "../_shared/networks.ts";
import {
  Account,
  Contract,
  invoke,
  keeper,
  keeperSend,
  native,
  newTx,
  requireAccount,
  type RestorePreamble,
  restoreTx,
  rpcServer,
  sendSigned,
  sv,
  Transaction,
  waitForTx,
  withInclusionBid,
  xdr,
} from "../_shared/stellar.ts";
import { type PathReport, soroswapCode, upkeepPath, v2PathEntries } from "../_shared/ttl.ts";
import { describeError, errorName, V2_CONTRACT_TAGS, V2_ERRORS } from "../_shared/v2_errors.ts";

// ------------------------------------------------------------------------------------------------ simulation

/** What a simulated call would do: succeed with its return value, or abort with the contract's error code (null when
 *  the error isn't a contract's). `restore`: it would meet archived data, which this restore brings back first. */
export type Sim = { ok: true; value: unknown; auth: number } | { ok: false; error: string; code: number | null; restore?: RestorePreamble };

/** A graduation's outcome from its simulation: the pool, a recoverable failure the call would record, or an abort. */
export type Outcome = { kind: "graduated"; pool: string } | { kind: "failed"; origin: number; code: number } | { kind: "aborted"; code: number | null };

/** GraduationOutcome as scValToNative gives it: ["Graduated", pool] or ["Failed", {origin, code}]. */
export function outcomeOf(s: Sim): Outcome {
  if (!s.ok) return { kind: "aborted", code: s.code };
  const v = s.value as unknown[];
  if (Array.isArray(v) && v[0] === "Graduated") return { kind: "graduated", pool: String(v[1]) };
  if (Array.isArray(v) && v[0] === "Failed") {
    const f = v[1] as { origin: unknown; code: unknown };
    return { kind: "failed", origin: Number(f.origin), code: Number(f.code) };
  }
  return { kind: "aborted", code: null };
}

/** The contract error code in a simulation's error ("Error(Contract, #10214)"), or null. */
export function contractCode(raw: string): number | null {
  const m = raw.match(/Error\(Contract, #(\d+)\)/);
  return m ? Number(m[1]) : null;
}

/** Whether a simulation aborted on the transaction's CPU or memory budget. Soroban can't catch that in a sub-call, so
 *  such an attempt records nothing (L3); on the graduation path it means code ran that wasn't in the module cache. */
export function overBudget(s: Sim): boolean {
  return !s.ok && /Error\(Budget, ExceededLimit\)/.test(s.error);
}

/** The keeper's view of the chain. The default reads and sends through RPC; tests stand in for it. */
export interface Chain {
  /** Simulates `fn` on `contract` from the keeper's account. */
  simulate(contract: string, fn: string, args: Xdr.ScVal[]): Promise<Sim>;
  /** Sends `fn` on `contract` from the keeper's account and waits for it; answers whether it succeeded. Refuses a call
   *  that would need anyone's authorization. */
  send(job: KeeperJobV2, contract: string, fn: string, args: Xdr.ScVal[], target: string): Promise<boolean>;
  /** A read-only call. */
  view(contract: string, fn: string, args?: Xdr.ScVal[]): Promise<any>;
  /** Sends the restore a simulation of a call on `target` asked for, from the keeper's account, and waits for it. */
  restore(preamble: RestorePreamble, target: string): Promise<boolean>;
  /** Checks the graduation and harvest paths (ttl.ts upkeepPath) until `deadline`: restores what is archived, extends
   *  what is low. */
  keepPathAlive(deadline: number): Promise<PathReport>;
  now(): number;
}

/** keeper_log's v2 job names (migration 20261015000012). */
export type KeeperJobV2 =
  | "graduate"
  | "graduate_fallback"
  | "mark_stuck"
  | "rescue"
  | "expire"
  | "harvest"
  | "claim_protocol_fees"
  | "sweep_protocol"
  | "exclude_treasury"
  | "exclude_pool";

/** A transaction of the same job and target still pending, or confirmed this recently, isn't sent again: RPC's state
 *  may not show it yet, and a recoverable failure must be recorded once. */
const IN_FLIGHT_MS = 15 * 60_000;
const SETTLED_LAG_MS = 60_000;

/** The authorization entries a call asks for. The keeper's calls are permissionless: any entry means someone else would
 *  have to sign (an admin's rescue before rescue_public_at, a user's call), so it is never sent. */
export function authEntries(tx: Transaction): number {
  return tx.operations.reduce((n, op) => n + ((op as { auth?: unknown[] }).auth?.length ?? 0), 0);
}

export function rpcChain(net: NetworkConfig = env.network): Chain {
  let source: Account | null = null;
  const keeperAccount = async () => (source ??= await requireAccount(keeper().publicKey()));
  return {
    async simulate(contract, fn, args) {
      const acct = await keeperAccount();
      const tx = newTx(new Account(acct.accountId(), acct.sequenceNumber()), 60).addOperation(new Contract(contract).call(fn, ...args)).build();
      let r: rpc.Api.SimulateTransactionResponse;
      try {
        r = await rpcServer().simulateTransaction(tx);
      } catch (err) {
        return { ok: false, error: String((err as Error).message ?? err).slice(0, 300), code: null };
      }
      if (rpc.Api.isSimulationError(r)) return { ok: false, error: r.error.slice(0, 600), code: contractCode(r.error) };
      if (rpc.Api.isSimulationRestore(r)) {
        const restore = { minResourceFee: r.restorePreamble.minResourceFee, transactionData: r.restorePreamble.transactionData.build().toXDR("base64") };
        return { ok: false, error: "needs_restore", code: null, restore };
      }
      const ok = r as rpc.Api.SimulateTransactionSuccessResponse;
      return { ok: true, value: ok.result ? native(ok.result.retval) : undefined, auth: ok.result?.auth?.length ?? 0 };
    },
    async send(job, contract, fn, args, target) {
      if (await inFlight(job, target)) return false;
      const acct = await requireAccount(keeper().publicKey());
      const prepared = withInclusionBid(await invoke(acct, contract, fn, args, 120), await inclusionFee("soroban"));
      if (authEntries(prepared) > 0) {
        console.warn(`keeper: ${fn} on ${target} needs someone's authorization; not sent`);
        return false;
      }
      const k = keeper();
      prepared.sign(k);
      const hash = await sendSigned(prepared, "keeper");
      await logSent(hash, job, k.publicKey(), prepared.fee, { target, contract, fn });
      source = null;
      const s = await waitForTx(hash, 20_000);
      if (s.status !== "SUCCESS") console.warn(`keeper: ${job} ${target} not confirmed`, s.status, s.error ?? "");
      return s.status === "SUCCESS";
    },
    async view(contract, fn, args = []) {
      const acct = await keeperAccount();
      const tx = newTx(new Account(acct.accountId(), acct.sequenceNumber()), 60).addOperation(new Contract(contract).call(fn, ...args)).build();
      const r = await rpcServer().simulateTransaction(tx);
      if (rpc.Api.isSimulationError(r)) throw new Error(`${fn}: ${r.error.slice(0, 200)}`);
      return (r as rpc.Api.SimulateTransactionSuccessResponse).result ? native((r as rpc.Api.SimulateTransactionSuccessResponse).result!.retval) : undefined;
    },
    async restore(preamble, target) {
      const acct = await requireAccount(keeper().publicKey());
      const tx = withInclusionBid(restoreTx(acct, preamble, 120), await inclusionFee("soroban"));
      const hash = await keeperSend("ttl", tx, { target, restore: true });
      source = null;
      const s = await waitForTx(hash, 20_000);
      if (s.status !== "SUCCESS") console.warn(`keeper: the restore for ${target} not confirmed`, s.status, s.error ?? "");
      return s.status === "SUCCESS";
    },
    async keepPathAlive(deadline) {
      const code = await soroswapCode(net.contracts.soroswapFactory).catch(() => null);
      const report = await upkeepPath(v2PathEntries(net, code), net.ttlPolicy, deadline);
      source = null;
      return report;
    },
    now: () => Date.now(),
  };
}

async function inFlight(job: KeeperJobV2, target: string): Promise<boolean> {
  const rows = await sql()`
    select 1 from lite.keeper_log
     where job = ${job} and detail ->> 'target' = ${target}
       and ((status = 'pending' and created_at > now() - make_interval(secs => ${IN_FLIGHT_MS / 1000}))
         or (status = 'success' and updated_at > now() - make_interval(secs => ${SETTLED_LAG_MS / 1000})))
     limit 1`;
  return rows.length > 0;
}

async function logSent(hash: string, job: KeeperJobV2, keeperId: string, maxFee: string, detail: Record<string, unknown>): Promise<void> {
  try {
    await sql()`insert into lite.keeper_log (hash, job, keeper, max_fee, detail)
                values (${hash}, ${job}, ${keeperId}, ${maxFee}, ${sql().json(detail as any)}) on conflict (hash) do nothing`;
  } catch (err) {
    console.warn("keeper_log: not recorded", job, hash, String((err as Error).message ?? err).slice(0, 120));
  }
}

// ------------------------------------------------------------------------------------------------ keeper_skip

export type SkipJob = "graduate" | "fallback" | "mark_stuck" | "rescue" | "expire" | "harvest";

export interface SkipRow {
  kind: "launch" | "moment";
  target: string;
  jobs: string[];
  until: Date | null;
}

export interface Skips {
  /** Whether `job` on `target` is held off. */
  skipped(kind: SkipRow["kind"], target: string, job: SkipJob): boolean;
  /** Rows in force that this deployment ignores. */
  ignored: number;
}

/** keeper_skip's rows in force at `now`: honoured on testnet-qa only (F5); elsewhere none applies, and the caller warns
 *  about the ones ignored. */
export function skipsFor(rows: SkipRow[], deployment: string, now: number): Skips {
  const live = rows.filter((r) => r.until === null || r.until.getTime() > now);
  if (deployment !== "testnet-qa") return { skipped: () => false, ignored: live.length };
  return {
    skipped: (kind, target, job) => live.some((r) => r.kind === kind && r.target === target && r.jobs.includes(job)),
    ignored: 0,
  };
}

async function loadSkips(deployment: string, now: number): Promise<Skips> {
  const rows = await sql()`select kind, target, jobs, until from lite.keeper_skip`;
  const skips = skipsFor(rows.map((r) => ({ kind: r.kind, target: String(r.target), jobs: r.jobs as string[], until: r.until ? new Date(r.until as Date) : null })), deployment, now);
  if (skips.ignored > 0) console.warn(`keeper: ${skips.ignored} lite.keeper_skip row(s) ignored: the skip list applies on testnet-qa only (LITE_DEPLOYMENT=${deployment})`);
  return skips;
}

// ------------------------------------------------------------------------------------------------ decisions

/** launchpad-v2's status(token), in milliseconds; a time is 0 where it doesn't apply. Phase: 0 Curve, 1 Completed,
 *  2 Graduated, 3 Rescued. */
export interface LaunchStatus {
  phase: number;
  stuckSince: number;
  markStuckAt: number;
  fallbackAt: number;
  rescuePublicAt: number;
}

export function launchStatusOf(v: any): LaunchStatus {
  const ms = (x: unknown) => Number(x ?? 0) * 1000;
  return {
    phase: Number(v.phase),
    stuckSince: ms(v.stuck_since),
    markStuckAt: ms(v.mark_stuck_at),
    fallbackAt: ms(v.fallback_at),
    rescuePublicAt: ms(v.rescue_public_at),
  };
}

export type LaunchCall = "graduate" | "graduate_fallback" | "mark_stuck" | "rescue";

export interface LaunchDecision {
  fn: LaunchCall;
  /** A graduate sent to record its recoverable failure (the launch isn't stuck yet). */
  recordsFailure?: boolean;
}

const PHASE_COMPLETED = 1;

/** What the keeper sends for a completed launch this run, at most one call, from its status and the simulations it asks
 *  `sim` for (graduate first, always; the fallback only from fallback_at, when graduate wouldn't succeed). Null: nothing. */
export async function decideLaunch(st: LaunchStatus, now: number, sim: (fn: LaunchCall) => Promise<Sim>, skip: (job: SkipJob) => boolean): Promise<LaunchDecision | null> {
  if (st.phase !== PHASE_COMPLETED) return null;
  const graduate = outcomeOf(await sim("graduate"));
  if (!skip("graduate")) {
    if (graduate.kind === "graduated") return { fn: "graduate" };
    // The first recoverable failure is recorded so the launch's clock starts; later ones only cost the keeper.
    if (graduate.kind === "failed" && st.stuckSince === 0) return { fn: "graduate", recordsFailure: true };
  }
  if (st.stuckSince === 0) {
    // Nothing recorded: an aborting graduate (GraduationInvalid, budget) records nothing, so mark_stuck starts the clock
    // once the grace has passed.
    if (st.markStuckAt > 0 && now >= st.markStuckAt && !skip("mark_stuck") && (await sim("mark_stuck")).ok) return { fn: "mark_stuck" };
    return null;
  }
  // F14: the creator's venue first; the fallback only from fallback_at, and only when graduate would fail.
  if (graduate.kind !== "graduated" && st.fallbackAt > 0 && now >= st.fallbackAt && !skip("fallback")) {
    if (outcomeOf(await sim("graduate_fallback")).kind === "graduated") return { fn: "graduate_fallback" };
  }
  // O2: anyone may rescue from rescue_public_at, and the keeper does, so holders never wait on the admin.
  if (st.rescuePublicAt > 0 && now >= st.rescuePublicAt && !skip("rescue") && (await sim("rescue")).ok) return { fn: "rescue" };
  return null;
}

/** A v2 Moment as the keeper weighs it, in milliseconds: its ledger's state (0 Collecting, 1 GraduationPending,
 *  2 Graduated, 3 Expired) and clocks, its deadline and durations. */
export interface MomentStatus {
  state: number;
  completedAt: number;
  stuckSince: number;
  deadline: number;
  stuckExpiryMs: number;
  pendingBackstopMs: number;
}

export type MomentCall = "graduate" | "expire";

const STATE_COLLECTING = 0;
const STATE_PENDING = 1;

/** Whether moments-v2's expire would accept the Moment at `now` (collect.rs expire): past its deadline, Collecting; or
 *  GraduationPending once stuck_expiry has passed since its recorded failure, or at the backstop after completion
 *  without one (V11). */
export function expirable(m: MomentStatus, now: number): boolean {
  if (now < m.deadline) return false;
  if (m.state === STATE_COLLECTING) return true;
  if (m.state !== STATE_PENDING) return false;
  return (m.stuckSince > 0 && now >= m.stuckSince + m.stuckExpiryMs) || now >= m.completedAt + m.pendingBackstopMs;
}

/** What the keeper sends for a Moment this run, at most one call. Moments have no mark_stuck (F15): only a recorded
 *  failed graduate starts their stuck clock, and the keeper sends the first one. */
export async function decideMoment(m: MomentStatus, now: number, sim: (fn: MomentCall) => Promise<Sim>, skip: (job: SkipJob) => boolean): Promise<{ fn: MomentCall; recordsFailure?: boolean } | null> {
  if (m.state === STATE_PENDING && !skip("graduate")) {
    const graduate = outcomeOf(await sim("graduate"));
    if (graduate.kind === "graduated") return { fn: "graduate" };
    if (graduate.kind === "failed" && m.stuckSince === 0) return { fn: "graduate", recordsFailure: true };
  }
  if (expirable(m, now) && !skip("expire") && (await sim("expire")).ok) return { fn: "expire" };
  return null;
}

/** lp-locker's harvestable(pool): (growth, lp_to_burn, est_base, est_quote, next_at). A harvest is due when it would burn
 *  LP, its interval has passed and its growth is above the floor (0 on testnet: any positive amount, A8e). */
export function harvestDue(h: unknown[], now: number, floor: bigint): boolean {
  const [growth, lpToBurn, , , nextAt] = h as [bigint, bigint, bigint, bigint, bigint];
  return BigInt(lpToBurn) > 0n && BigInt(growth) > floor && now >= Number(nextAt) * 1000;
}

/** The harvest floor in the position's √k units: 0 on testnet (A8e). Mainnet's (at least the keeper's fee over the
 *  protocol's share, A10) is deferred with mainnet (§23.2): no v2 runs there. */
export function harvestFloor(net: Pick<NetworkConfig, "name">): bigint | null {
  return net.name === "testnet" ? 0n : null;
}

/** claim_protocol_fees batches: at most `max` launches a call, one quote per call, so a treasury that can't take one
 *  asset never holds up the others. */
export function feeBatches(rows: { token: string; quote: string }[], max = 20): { quote: string; tokens: string[] }[] {
  const byQuote = new Map<string, string[]>();
  for (const r of rows) byQuote.set(r.quote, [...(byQuote.get(r.quote) ?? []), r.token]);
  const out: { quote: string; tokens: string[] }[] = [];
  for (const [quote, tokens] of [...byQuote.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
    for (let i = 0; i < tokens.length; i += max) out.push({ quote, tokens: tokens.slice(i, i + max) });
  }
  return out;
}

/** exclude_pool's simulation, as the keeper acts on it: send it (the pool would be excluded), done (already excluded),
 *  below the floor (check again in an hour, F2), rejected (not that venue's pool of the pair, or a venue the token
 *  can't check), or try again later. */
export function poolVerdict(s: Sim): "send" | "excluded" | "below_floor" | "rejected" | "retry" {
  if (s.ok) return s.value === true ? "send" : "excluded";
  const name = s.code === null ? null : errorName(V2_CONTRACT_TAGS["launch-token-v2"], s.code);
  if (name === "BelowFloor") return "below_floor";
  if (name === "NotAPool" || name === "UnsupportedVenue" || name === "SharingOff") return "rejected";
  return "retry";
}

// ------------------------------------------------------------------------------------------------ alerts

export interface Alert {
  kind: "aqua_float" | "payment_failure" | "launch_stuck" | "moment_pending" | "moment_backstop" | "graduation_budget";
  target: string;
  /** Tells repeats apart: one alert per key. */
  key: string;
  message: string;
  detail?: Record<string, unknown>;
}

const AQUARIUS = V2_CONTRACT_TAGS["exec-aquarius"];
/** exec-aquarius' PaymentUnavailable and PaymentTooHigh, by name from the generated table (V10). */
const PAYMENT_CODES = V2_ERRORS.filter((e) => e.origin === AQUARIUS && (e.name === "PaymentUnavailable" || e.name === "PaymentTooHigh")).map((e) => e.code);

/** A recorded graduation failure that needs the owner: exec-aquarius couldn't pay for a new pool. Matched on the
 *  namespaced pair, never a bare local code: exec-soroswap's LiquidityTooLow (3, 10304) and the local 4 don't fire. */
export function gradFailAlert(kind: "launch" | "moment", target: string, f: { origin: number; code: number }, eventId: string): Alert | null {
  if (f.origin !== AQUARIUS || !PAYMENT_CODES.includes(f.code)) return null;
  return {
    kind: "payment_failure",
    target,
    key: eventId,
    message: `${kind} ${target}: graduation failed with ${describeError(f.origin, f.code)}; top up or check the Aquarius executor's AQUA`,
    detail: { origin: f.origin, code: f.code },
  };
}

/** The Aquarius executor's AQUA float below 5 × the pool payment (F11). */
export function floatAlert(executor: string, float: bigint, poolPayment: bigint, now: number): Alert | null {
  if (float >= 5n * poolPayment) return null;
  return {
    kind: "aqua_float",
    target: executor,
    // Once an hour while it stays low.
    key: String(Math.floor(now / 3_600_000)),
    message: `exec-aquarius ${executor} holds ${float} AQUA units, under 5 × the pool payment (${poolPayment}): top it up`,
    detail: { float: float.toString(), poolPayment: poolPayment.toString() },
  };
}

/** A launch still stuck after fallback_delay: neither its venue nor the fallback graduated it. */
export function stuckAlert(token: string, stuckSince: number, fallbackDelayMs: number, now: number): Alert | null {
  if (stuckSince === 0 || now < stuckSince + fallbackDelayMs) return null;
  return {
    kind: "launch_stuck",
    target: token,
    key: String(stuckSince),
    message: `launch ${token} has been stuck since ${new Date(stuckSince).toISOString()}, past its fallback delay`,
  };
}

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;

/** A graduation whose simulation ran out of budget: it would abort and record nothing, so neither the stuck clock nor
 *  the fallback moves. Fired once an hour while it lasts, per call. */
export function budgetAlert(kind: "launch" | "moment", target: string, fn: string, now: number): Alert {
  return {
    kind: "graduation_budget",
    target,
    key: `${fn}:${Math.floor(now / HOUR_MS)}`,
    message: `${kind} ${target}: ${fn} runs out of budget in simulation (Error(Budget, ExceededLimit)) and would abort; check the graduation path's code TTL`,
    detail: { fn },
  };
}

/** A GraduationPending Moment with no recorded failure: an hour after completion (F11), and again a day before its
 *  backstop (V11). */
export function pendingAlerts(nft: string, m: Pick<MomentStatus, "state" | "completedAt" | "stuckSince" | "pendingBackstopMs">, now: number): Alert[] {
  if (m.state !== STATE_PENDING || m.stuckSince !== 0 || m.completedAt === 0) return [];
  const out: Alert[] = [];
  const key = String(m.completedAt);
  if (now >= m.completedAt + HOUR_MS) {
    out.push({ kind: "moment_pending", target: nft, key, message: `Moment ${nft} has waited for graduation over an hour with no recorded failure` });
  }
  const backstop = m.completedAt + m.pendingBackstopMs;
  if (now >= backstop - DAY_MS) {
    out.push({ kind: "moment_backstop", target: nft, key, message: `Moment ${nft} reaches its backstop at ${new Date(backstop).toISOString()} with no recorded failure` });
  }
  return out;
}

/** Fires `a` once: recorded in lite.keeper_alerts and logged. Answers whether it fired now. */
export async function fireAlert(a: Alert): Promise<boolean> {
  const rows = await sql()`
    insert into lite.keeper_alerts (kind, target, key, detail) values (${a.kind}, ${a.target}, ${a.key}, ${sql().json((a.detail ?? { message: a.message }) as any)})
    on conflict (kind, target, key) do nothing returning kind`;
  if (rows.length) console.warn(`keeper alert: ${a.message}`);
  return rows.length > 0;
}

// ------------------------------------------------------------------------------------------------ the jobs

/** VenueKind as a contract argument: the unit variant's name. */
function venueKindArg(kind: "soroswap" | "aquarius"): Xdr.ScVal {
  return xdr.ScVal.scvVec([xdr.ScVal.scvSymbol(kind === "soroswap" ? "Soroswap" : "Aquarius")]);
}

/** How long a run may keep sending, from its start, so the jobs after it (bridges, ttl) keep their time. */
const RUN_MS = 15_000;
const LAUNCHES_PER_RUN = 20;
const MOMENTS_PER_RUN = 20;
const HARVESTS_PER_RUN = 10;
const POOLS_PER_RUN = 10;

export interface KeeperV2Report {
  sent: { job: KeeperJobV2 | "restore"; target: string; ok: boolean }[];
  alerts: string[];
  skippedRows: number;
  /** The graduation and harvest paths' check, when there was a graduation, an expiry or a harvest to do. */
  path?: PathReport;
  /** Graduation calls whose simulation ran out of budget: "<target> <fn>". */
  overBudget?: string[];
}

/** One run of the v2 keeper's per-minute jobs: the paths' check; graduation, stuck, fallback, rescue and expiry;
 *  harvests; the treasury's and other pools' exclusion; the alerts. */
export async function keeperV2(net: NetworkConfig = env.network, chain: Chain = rpcChain(net)): Promise<KeeperV2Report | { skipped: string }> {
  const d = net.deploymentV2;
  if (!d) return { skipped: "no v2 deployment" };
  if (!(await v2KeeperReady())) return { skipped: "migration 20261015000012 not applied" };
  const started = chain.now();
  const until = started + RUN_MS;
  const skips = await loadSkips(env.deployment, started);
  const report: KeeperV2Report = { sent: [], alerts: [], skippedRows: skips.ignored };
  const send = async (job: KeeperJobV2, contract: string, fn: string, args: Xdr.ScVal[], target: string) => {
    const ok = await chain.send(job, contract, fn, args, target);
    report.sent.push({ job, target, ok });
    return ok;
  };
  const alert = async (a: Alert | null) => {
    if (a && await fireAlert(a)) report.alerts.push(a.message);
  };
  const timeLeft = () => chain.now() < until;
  /** One target's simulations, each run once; a graduation that runs out of budget is alerted. */
  const simulator = (kind: "launch" | "moment", contract: string, target: string) => {
    const memo = new Map<string, Promise<Sim>>();
    return (fn: string): Promise<Sim> => {
      if (!memo.has(fn)) {
        memo.set(fn, chain.simulate(contract, fn, [sv.addr(target)]).then(async (s) => {
          if ((fn === "graduate" || fn === "graduate_fallback") && overBudget(s)) {
            (report.overBudget ??= []).push(`${target} ${fn}`);
            await alert(budgetAlert(kind, target, fn, chain.now()));
          }
          return s;
        }));
      }
      return memo.get(fn)!;
    };
  };
  /** Archived data on graduate's footprint (the launch's or the Moment's own entries, a balance): restored in a
   *  transaction of its own, and the target waits for the next run. Not while keeper_skip holds its graduation. */
  const restoredFirst = async (sim: (fn: string) => Promise<Sim>, target: string, skip: (job: SkipJob) => boolean) => {
    if (skip("graduate")) return false;
    const s = await sim("graduate");
    if (s.ok || !s.restore) return false;
    report.sent.push({ job: "restore", target, ok: await chain.restore(s.restore, target) });
    return true;
  };

  const pad = d.contracts.launchpadV2;
  const stacks = [d.contracts.momentsV2, ...(d.qa ? [d.qa.momentsV2QaFail] : [])];
  const floor = harvestFloor(net);
  const launches = await sql()`
    select token from lite.launches where generation = 2 and contract = ${pad} and phase = 'completed' order by completed_at nulls first limit ${LAUNCHES_PER_RUN}`;
  const moments = await sql()`
    select nft, contract, deadline, durations from lite.moments
     where generation = 2 and contract = any(${stacks}::text[])
       and (state = 'graduation_pending' or (state = 'collecting' and deadline <= now()))
     order by deadline limit ${MOMENTS_PER_RUN}`;
  const positions = floor === null ? [] : await sql()`
    select pool, ref_kind, ref from lite.locker_positions
     where locker = ${d.contracts.lpLocker}
       and coalesce(last_harvest_at, registered_at) <= now() - make_interval(secs => ${d.durations.launch.harvest_interval})
     order by coalesce(last_harvest_at, registered_at) limit ${HARVESTS_PER_RUN}`;

  // The paths before anything runs them: with an entry archived nothing graduates or harvests this run.
  let pathLive = true;
  if (launches.length || moments.length || positions.length) {
    report.path = await chain.keepPathAlive(until);
    if (report.path.archived.length) {
      pathLive = false;
      console.warn(`keeper: the graduation path had archived entries (${report.path.archived.join(", ")}), ${report.path.restored ? "restored" : "NOT restored"}; graduations and harvests wait`);
    }
  }

  // Launches waiting for graduation.
  for (const l of pathLive ? launches : []) {
    if (!timeLeft()) break;
    const token = String(l.token);
    const skip = (job: SkipJob) => skips.skipped("launch", token, job);
    const st = launchStatusOf(await chain.view(pad, "status", [sv.addr(token)]));
    const now = chain.now();
    await alert(stuckAlert(token, st.stuckSince, d.durations.launch.fallback_delay * 1000, now));
    const sim = simulator("launch", pad, token);
    if (st.phase === PHASE_COMPLETED && (await restoredFirst(sim, token, skip))) continue;
    const decision = await decideLaunch(st, now, sim, skip);
    if (decision) await send(decision.fn, pad, decision.fn, [sv.addr(token)], token);
  }

  // Moments waiting for graduation, and those past their deadline (both stacks on testnet-qa).
  for (const m of pathLive ? moments : []) {
    if (!timeLeft()) break;
    const nft = String(m.nft);
    const contract = String(m.contract);
    const skip = (job: SkipJob) => skips.skipped("moment", nft, job);
    const ledger = await chain.view(contract, "ledger", [sv.addr(nft)]);
    const durations = (m.durations ?? {}) as Record<string, number>;
    const status: MomentStatus = {
      state: Number(ledger.state),
      completedAt: Number(ledger.completed_at ?? 0) * 1000,
      stuckSince: Number(ledger.stuck_since ?? 0) * 1000,
      deadline: new Date(m.deadline as Date).getTime(),
      stuckExpiryMs: Number(durations.stuck_expiry ?? d.durations.moments.stuck_expiry) * 1000,
      pendingBackstopMs: Number(durations.pending_backstop ?? d.durations.moments.pending_backstop) * 1000,
    };
    const now = chain.now();
    for (const a of pendingAlerts(nft, status, now)) await alert(a);
    const sim = simulator("moment", contract, nft);
    if (status.state === STATE_PENDING && (await restoredFirst(sim, nft, skip))) continue;
    const decision = await decideMoment(status, now, sim, skip);
    if (decision) await send(decision.fn, contract, decision.fn, [sv.addr(nft)], nft);
  }

  // Harvests, once per interval above the floor.
  for (const p of pathLive && floor !== null ? positions : []) {
    if (!timeLeft()) break;
    const pool = String(p.pool);
    const ref = String(p.ref);
    if (skips.skipped(p.ref_kind === "moment" ? "moment" : "launch", ref, "harvest")) continue;
    let h: unknown[];
    try {
      h = await chain.view(d.contracts.lpLocker, "harvestable", [sv.addr(pool)]);
    } catch {
      // A kind the locker doesn't harvest (HoldOnly, QaFail) or a pool it can't read now.
      continue;
    }
    if (!harvestDue(h, chain.now(), floor!)) continue;
    const sim = await chain.simulate(d.contracts.lpLocker, "harvest", [sv.addr(pool)]);
    // A graduated launch's Curve, which every harvest reads and nothing writes, may have archived (§13): restored first.
    if (!sim.ok && sim.restore) report.sent.push({ job: "restore", target: ref, ok: await chain.restore(sim.restore, ref) });
    else if (sim.ok) await send("harvest", d.contracts.lpLocker, "harvest", [sv.addr(pool)], ref);
  }

  // After a treasury change, every graduated sharing launch excludes the new treasury from its holder rewards (V2).
  if (timeLeft()) {
    const treasury = String(await chain.view(pad, "treasury"));
    const graduated = await sql()`
      select token from lite.launches
       where generation = 2 and contract = ${pad} and phase = 'graduated' and holder_sharing and treasury_checked is distinct from ${treasury}
       order by graduated_at limit ${LAUNCHES_PER_RUN}`;
    for (const g of graduated) {
      if (!timeLeft()) break;
      const token = String(g.token);
      const sim = await chain.simulate(token, "exclude_treasury", []);
      if (!sim.ok) continue;
      // False: it is excluded already (from birth, or by a harvest or sweep since).
      if (sim.value === true && !(await send("exclude_treasury", token, "exclude_treasury", [], token))) continue;
      await sql()`update lite.launches set treasury_checked = ${treasury} where token = ${token}`;
    }
  }

  // Other pools of sharing launches, only when exclude_pool's simulation passes the floor (F2).
  if (timeLeft()) {
    const pools = await sql()`
      select c.pool, c.token, c.other, c.kind from lite.pool_candidates c join lite.launches l on l.token = c.token
       where l.generation = 2 and l.contract = ${pad} and c.status in ('pending', 'below_floor') and (c.next_check_at is null or c.next_check_at <= now())
       order by c.next_check_at nulls first limit ${POOLS_PER_RUN}`;
    for (const c of pools) {
      if (!timeLeft()) break;
      const token = String(c.token);
      const pool = String(c.pool);
      const args = [venueKindArg(c.kind as "soroswap" | "aquarius"), sv.addr(String(c.other)), sv.addr(pool)];
      const sim = await chain.simulate(token, "exclude_pool", args);
      let verdict = poolVerdict(sim);
      if (verdict === "send") verdict = (await send("exclude_pool", token, "exclude_pool", args, pool)) ? "excluded" : "retry";
      const status = verdict === "retry" ? null : verdict;
      const recheck = verdict === "below_floor" ? "1 hour" : verdict === "retry" ? "10 minutes" : null;
      await sql()`
        update lite.pool_candidates set status = coalesce(${status}, status), checked_at = now(),
               next_check_at = case when ${recheck}::interval is null then null else now() + ${recheck}::interval end,
               error = ${sim.ok ? null : sim.error.slice(0, 200)}
         where pool = ${pool} and token = ${token}`;
    }
  }

  // The Aquarius executor's float, where the deployment has it.
  if (d.contracts.execAquarius && timeLeft()) {
    const [float, payment] = await Promise.all([chain.view(d.contracts.execAquarius, "float"), chain.view(d.contracts.execAquarius, "pool_payment")]);
    const alert = floatAlert(d.contracts.execAquarius, BigInt(float), BigInt((payment as unknown[])[1] as bigint), chain.now());
    if (alert && await fireAlert(alert)) report.alerts.push(alert.message);
  }
  return report;
}

/** Booked fees are swept at most this often: every sweep is a transaction the keeper pays for. */
export const FEES_EVERY_MS = 10 * 60_000;

/** At most every 10 minutes (FEES_EVERY_MS after the last sweep sent): booked protocol and launch fees to the treasury
 *  (claim_protocol_fees), and launch tokens' protocol shares (sweep_protocol). */
export async function keeperV2Fees(net: NetworkConfig = env.network, chain: Chain = rpcChain(net)): Promise<KeeperV2Report | { skipped: string }> {
  const d = net.deploymentV2;
  if (!d) return { skipped: "no v2 deployment" };
  if (!(await v2KeeperReady())) return { skipped: "migration 20261015000012 not applied" };
  const [last] = await sql()`select max(created_at) as at from lite.keeper_log where job in ('claim_protocol_fees', 'sweep_protocol')`;
  if (last?.at && chain.now() - new Date(last.at as Date).getTime() < FEES_EVERY_MS) return { skipped: "swept less than 10 minutes ago" };
  const until = chain.now() + RUN_MS;
  const report: KeeperV2Report = { sent: [], alerts: [], skippedRows: 0 };
  const pad = d.contracts.launchpadV2;
  const due = await sql()`
    select token, quote from lite.launches
     where generation = 2 and contract = ${pad} and (protocol_fees_due > 0 or launch_fee_due > 0) order by quote, token limit 200`;
  for (const b of feeBatches(due.map((r) => ({ token: String(r.token), quote: String(r.quote) })))) {
    if (chain.now() >= until) break;
    const args = [sv.vec(b.tokens.map((t) => sv.addr(t)))];
    if (!(await chain.simulate(pad, "claim_protocol_fees", args)).ok) continue;
    report.sent.push({ job: "claim_protocol_fees", target: b.quote, ok: await chain.send("claim_protocol_fees", pad, "claim_protocol_fees", args, b.quote) });
  }
  const sweeps = await sql()`
    select distinct r.token from lite.launch_rewards r join lite.launches l on l.token = r.token
     where l.generation = 2 and l.contract = ${pad} and r.to_protocol + r.stranded > r.swept order by r.token limit 20`;
  for (const r of sweeps) {
    if (chain.now() >= until) break;
    const token = String(r.token);
    if (!(await chain.simulate(token, "sweep_protocol", [])).ok) continue;
    report.sent.push({ job: "sweep_protocol", target: token, ok: await chain.send("sweep_protocol", token, "sweep_protocol", [], token) });
  }
  return report;
}

/** The keeper's v2 jobs run once migration 20261015000012 is applied: keeper_log knows their names then. */
export async function v2KeeperReady(): Promise<boolean> {
  return await tableExists("lite.keeper_skip");
}
