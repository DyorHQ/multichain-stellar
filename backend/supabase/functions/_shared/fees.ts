// Network fees (docs/DESIGN-stellar-parity.md §4). Users pay every network fee in XLM, so the API bids the network's
// going rate for inclusion, prices each step kind from what it recently cost, works out what an account can spend and
// refuses a plan the account can't pay for before anyone signs it. DyorHQ pays only an account's setup and, where
// activation is sponsored (mainnet), one starter swap into XLM: starterSwapEligibility() decides that one.
import type { Fees, FirstFunding, StarterSwapReason, StepKind, XlmPosition } from "./contract.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError } from "./http.ts";
import { FeePolicy } from "./networks.ts";
import { ClassicAccount, fromStroops, horizon, rpcServer } from "./stellar.ts";

/** Step kinds a user pays for, each with an estimate. An activation is the sponsor's, capped by activationMaxFee. */
export type EstimatedKind = Exclude<StepKind, "activate">;

/** What a step costs with no history to go on (§6.3), in stroops. The app ships the same table (StellarFeeDefaults). */
export const DEFAULT_ESTIMATES: Readonly<Record<EstimatedKind, bigint>> = {
  payment: 10_000n,
  payment_token: 300_000n,
  trust: 10_000n,
  restore: 500_000n,
  swap_sdex: 10_000n,
  swap_soroswap: 500_000n,
  swap_aquarius: 500_000n,
  blend_submit_deposit: 5_000_000n,
  blend_submit_withdraw: 500_000n,
  launch_create: 10_000_000n,
  launch_buy: 500_000n,
  launch_sell: 500_000n,
  launch_graduate: 15_000_000n,
  launch_claim: 500_000n,
  moment_publish: 3_000_000n,
  moment_collect: 10_000_000n,
  token_approve: 300_000n,
  cctp_burn: 500_000n,
  // Contracts v2, as their v1 counterparts where there is one. Creating a launch or publishing a Moment deploys a
  // contract, as a v1 launch does; graduating a Moment deploys its coin and pool, as a launch's graduation does; a
  // harvest or a claim over up to 20 Moments takes several token calls.
  launch_v2_create: 10_000_000n,
  launch_v2_buy: 500_000n,
  launch_v2_sell: 500_000n,
  launch_v2_refund: 500_000n,
  launch_v2_graduate: 15_000_000n,
  launch_v2_graduate_fallback: 15_000_000n,
  launch_v2_mark_stuck: 500_000n,
  launch_v2_rescue: 500_000n,
  launch_v2_claim: 500_000n,
  launch_v2_claim_owed: 500_000n,
  launch_v2_claim_rewards: 500_000n,
  launch_v2_harvest: 3_000_000n,
  launch_v2_recipient_transfer: 500_000n,
  launch_v2_recipient_cancel: 500_000n,
  launch_v2_recipient_execute: 500_000n,
  moment_v2_publish: 10_000_000n,
  moment_v2_collect: 10_000_000n,
  moment_v2_claim: 500_000n,
  moment_v2_claim_all: 3_000_000n,
  moment_v2_withdraw: 500_000n,
  moment_v2_graduate: 15_000_000n,
  moment_v2_expire: 500_000n,
};

export const ESTIMATED_KINDS = Object.keys(DEFAULT_ESTIMATES) as EstimatedKind[];

// ------------------------------------------------------------------------------------------------ inclusion

/** The least a transaction bids for inclusion per operation: the network's minimum. */
const MIN_BID = 100n;

/** The bid per operation (§4.2): the p90 of recent ledgers' bids, clamped to [100, maxInclusionPerOp ÷ 2], so a bid
 *  never comes near the cap the phone enforces; 100 when the network didn't say. */
export function inclusionBid(p90: unknown, policy: Pick<FeePolicy, "maxInclusionPerOp">): bigint {
  if (typeof p90 !== "string" || !/^[0-9]{1,18}$/.test(p90)) return MIN_BID;
  const bid = BigInt(p90);
  const ceiling = policy.maxInclusionPerOp / 2n;
  return bid < MIN_BID ? MIN_BID : bid > ceiling ? ceiling : bid;
}

const STATS_TTL_MS = 30_000;
let stats: { at: number; classic: bigint; soroban: bigint } | null = null;

/** The current bid per operation for a classic or a Soroban transaction (getFeeStats), kept 30 s. RPC down: 100, and
 *  the next call asks again. */
export async function inclusionFee(kind: "classic" | "soroban"): Promise<bigint> {
  const now = Date.now();
  if (!stats || now - stats.at > STATS_TTL_MS) {
    const policy = env.network.feePolicy;
    try {
      const s = await rpcServer().getFeeStats();
      stats = { at: now, classic: inclusionBid(s.inclusionFee?.p90, policy), soroban: inclusionBid(s.sorobanInclusionFee?.p90, policy) };
    } catch (err) {
      console.warn("fees: getFeeStats failed, bidding the minimum", String((err as Error)?.message ?? err).slice(0, 120));
      return MIN_BID;
    }
  }
  return stats[kind];
}

// ------------------------------------------------------------------------------------------------ the ledger's fees

/** The protocol's base reserve and base fee, which no network has changed: used only until Horizon first answers. */
const PROTOCOL_FEES = { baseReserve: 5_000_000n, baseFee: 100n };
const LEDGER_TTL_MS = 5 * 60_000;
let ledger: { at: number; baseReserve: bigint; baseFee: bigint } | null = null;

/** The base reserve and base fee from the latest ledger header (Horizon), kept 5 minutes; a failed read keeps the last
 *  answer and asks again on the next call. */
export async function ledgerFees(): Promise<{ baseReserve: bigint; baseFee: bigint }> {
  const now = Date.now();
  if (!ledger || now - ledger.at > LEDGER_TTL_MS) {
    try {
      const page = await horizon().ledgers().order("desc").limit(1).call();
      const l = page.records[0];
      ledger = { at: now, baseReserve: BigInt(l.base_reserve_in_stroops), baseFee: BigInt(l.base_fee_in_stroops) };
    } catch (err) {
      console.warn("fees: the latest ledger couldn't be read", String((err as Error)?.message ?? err).slice(0, 120));
      if (!ledger) return { ...PROTOCOL_FEES };
    }
  }
  return { baseReserve: ledger.baseReserve, baseFee: ledger.baseFee };
}

export async function baseReserve(): Promise<bigint> {
  return (await ledgerFees()).baseReserve;
}

// ------------------------------------------------------------------------------------------------ estimates

export interface FeeEstimates {
  estimates: Record<EstimatedKind, bigint>;
  basis: Record<EstimatedKind, "history" | "default">;
  /** The newest transaction the estimates count; null when none does, and every estimate is the default. */
  updatedAt: Date | null;
}

/** Each kind's estimate from the p90 of what its successful transactions declared (`history`, any order, kinds
 *  outside the list ignored): × 5/4, rounded up; the default with no history; never above `maxFee`. */
export function estimatesFrom(history: { stepKind: string; p90: bigint; latest: Date }[], maxFee: bigint): FeeEstimates {
  const counted = history.filter((h) => (ESTIMATED_KINDS as string[]).includes(h.stepKind) && h.p90 > 0n);
  const p90 = new Map(counted.map((h) => [h.stepKind, h.p90]));
  const estimates = {} as Record<EstimatedKind, bigint>;
  const basis = {} as Record<EstimatedKind, "history" | "default">;
  for (const kind of ESTIMATED_KINDS) {
    const seen = p90.get(kind);
    const value = seen !== undefined ? (seen * 5n + 3n) / 4n : DEFAULT_ESTIMATES[kind];
    estimates[kind] = value > maxFee ? maxFee : value;
    basis[kind] = seen !== undefined ? "history" : "default";
  }
  const newest = counted.reduce<Date | null>((at, h) => (at === null || h.latest > at ? h.latest : at), null);
  return { estimates, basis, updatedAt: newest };
}

const ESTIMATES_TTL_MS = 30_000;
let estimated: { at: number; value: FeeEstimates } | null = null;

/** Every step kind's estimate (§6.3), from the last 7 days of lite.tx_log, kept 30 s. */
export async function feeEstimates(): Promise<FeeEstimates> {
  const now = Date.now();
  if (estimated && now - estimated.at <= ESTIMATES_TTL_MS) return estimated.value;
  const maxFee = env.network.feePolicy.maxFee;
  let value: FeeEstimates;
  try {
    const rows = await sql()`
      select step_kind, percentile_disc(0.9) within group (order by max_fee) as p90, max(created_at) as latest from lite.tx_log
       where status = 'success' and step_kind is not null and created_at > now() - interval '7 days'
       group by step_kind`;
    value = estimatesFrom(rows.map((r) => ({ stepKind: String(r.step_kind), p90: BigInt(String(r.p90)), latest: new Date(r.latest as Date) })), maxFee);
  } catch (err) {
    console.warn("fees: no fee history, estimating with the defaults", String((err as Error)?.message ?? err).slice(0, 120));
    return estimatesFrom([], maxFee);
  }
  estimated = { at: now, value };
  return value;
}

/** The most an unbuilt step of `kind` is expected to cost: its estimate, or for an activation the most the sponsor's
 *  setup may declare. Either is at most the policy's maxFee. */
export async function feeCeiling(kind: StepKind): Promise<bigint> {
  const policy = env.network.feePolicy;
  if (kind === "activate") return policy.activationMaxFee;
  return (await feeEstimates()).estimates[kind];
}

/** GET /v1/fees (§6.3). */
export async function feesView(): Promise<Fees> {
  const [ledgerFee, classic, soroban, est] = await Promise.all([ledgerFees(), inclusionFee("classic"), inclusionFee("soroban"), feeEstimates()]);
  return {
    network: env.network.name,
    baseReserve: ledgerFee.baseReserve.toString(),
    baseFee: ledgerFee.baseFee.toString(),
    inclusionFee: { classic: classic.toString(), soroban: soroban.toString() },
    estimates: Object.fromEntries(ESTIMATED_KINDS.map((k) => [k, est.estimates[k].toString()])),
    estimateBasis: Object.fromEntries(ESTIMATED_KINDS.map((k) => [k, est.basis[k]])),
    updatedAt: est.updatedAt?.toISOString() ?? null,
  };
}

// ------------------------------------------------------------------------------------------------ an account's XLM

/** What the ledger says about an account's XLM (Horizon), in stroops and entry counts. */
export interface LedgerAccount {
  balance: bigint;
  sellingLiabilities: bigint;
  subentries: number;
  sponsoring: number;
  sponsored: number;
}

/** An account's XLM as Stellar counts it (§4.5): the minimum balance its entries hold back, and what it can spend.
 *  The phone recomputes `spendable` from the same parts. */
export function xlmPosition(a: LedgerAccount, reserve: bigint): XlmPosition {
  const entries = 2 + a.subentries + a.sponsoring - a.sponsored;
  const minBalance = BigInt(Math.max(0, entries)) * reserve;
  const free = a.balance - minBalance - a.sellingLiabilities;
  return {
    balance: a.balance.toString(),
    minBalance: minBalance.toString(),
    sellingLiabilities: a.sellingLiabilities.toString(),
    spendable: (free > 0n ? free : 0n).toString(),
    baseReserve: reserve.toString(),
    reserves: { base: 2, subentries: a.subentries, sponsoring: a.sponsoring, sponsored: a.sponsored },
  };
}

/** The XLM position of an account as Horizon describes it (stellar.ts classicBalances), or null when it is missing. */
export function positionOf(acct: ClassicAccount | null, reserve: bigint): XlmPosition | null {
  if (!acct) return null;
  return xlmPosition({
    balance: BigInt(acct.balances.find((b) => b.asset === "native")?.balance ?? "0"),
    sellingLiabilities: BigInt(acct.sellingLiabilities),
    subentries: acct.subentries,
    sponsoring: acct.sponsoring,
    sponsored: acct.sponsored,
  }, reserve);
}

/** What a plan takes from an account's spendable XLM, in stroops: the network fees it pays, the base reserves its new
 *  entries hold back, and the XLM it sends or spends. */
export interface Need {
  fee: bigint;
  reserve: bigint;
  amount: bigint;
}

/** Refuses a plan the account can't pay for (§4.6, §6.13), naming what doesn't fit first: the fees alone (409
 *  not_enough_xlm_for_fee), then with the reserve (not_enough_xlm_for_reserve), then with the XLM it spends
 *  (not_enough_xlm, which also says what stays in the account). */
export function assertAffordable(position: { spendable: bigint; minBalance: bigint }, need: Need): void {
  const { spendable, minBalance } = position;
  const detail = (n: bigint) => ({ need: n.toString(), spendable: spendable.toString() });
  if (need.fee > spendable) throw new ApiError(409, "not_enough_xlm_for_fee", "Not enough XLM for the network fee.", detail(need.fee));
  const held = need.fee + need.reserve;
  if (held > spendable) throw new ApiError(409, "not_enough_xlm_for_reserve", "Not enough XLM for Stellar's minimum balance.", detail(held));
  const total = held + need.amount;
  if (total > spendable) {
    throw new ApiError(409, "not_enough_xlm", `Not enough XLM. ${fromStroops(minBalance)} XLM stays in your account.`, {
      ...detail(total),
      minBalance: minBalance.toString(),
    });
  }
}

/** The add-funds card (§4.5): whether the account needs XLM (spendable under the funding floor), how much to send
 *  (2 XLM to a missing account; otherwise 1 XLM plus any reserve it lacks), the starter swap's state and testnet's
 *  faucet. `starterSwap` and the faucet's `usedToday` are DyorHQ's records: null in the public view. */
export function firstFunding(
  position: XlmPosition | null,
  policy: Pick<FeePolicy, "fundingFloor">,
  starterSwap: FirstFunding["starterSwap"],
  faucet: FirstFunding["faucet"],
): FirstFunding {
  const ONE = 10_000_000n;
  if (!position) return { needsXlm: true, suggestXlm: (2n * ONE).toString(), starterSwap, faucet };
  const lacking = BigInt(position.minBalance) + BigInt(position.sellingLiabilities) - BigInt(position.balance);
  return {
    needsXlm: BigInt(position.spendable) < policy.fundingFloor,
    suggestXlm: (ONE + (lacking > 0n ? lacking : 0n)).toString(),
    starterSwap,
    faucet,
  };
}

// ------------------------------------------------------------------------------------------------ the starter swap

export interface StarterInput {
  activation: "friendbot" | "sponsored";
  buysXlm: boolean;
  /** The swap sells a registry asset other than XLM. */
  sellsRegistryAsset: boolean;
  /** The account's spendable XLM, in stroops (0 for a missing account). */
  spendable: bigint;
  /** The least XLM the quote delivers, in stroops. */
  minOut: bigint;
  /** The address already has a reserved, sent or successful starter swap. */
  used: boolean;
}

/** Whether DyorHQ pays this swap's fee as the starter swap (§4.3), and if not why, in this order: activation isn't
 *  sponsored here; it doesn't buy XLM; it doesn't sell a registry asset; the account already has XLM to spend; it
 *  delivers too little XLM; the one starter swap is used. */
export function starterSwapEligibility(
  input: StarterInput,
  policy: Pick<FeePolicy, "starterThreshold" | "starterMinXlmOut">,
): { eligible: boolean; reason: StarterSwapReason | null } {
  const no = (reason: StarterSwapReason) => ({ eligible: false, reason });
  if (input.activation !== "sponsored") return no("activation");
  if (!input.buysXlm) return no("buy_not_xlm");
  if (!input.sellsRegistryAsset) return no("sell_not_registry");
  if (input.spendable >= policy.starterThreshold) return no("has_xlm");
  if (input.minOut < policy.starterMinXlmOut) return no("too_small");
  if (input.used) return no("used");
  return { eligible: true, reason: null };
}
