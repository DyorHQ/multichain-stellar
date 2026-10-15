// Moments v2 (docs/DESIGN-stellar-contracts-v2.md §9, §14.2–14.3, §20.2–20.3): one Moment is one NFT contract, and
// its address is the Moment's id. Collectors pay USDC only; the collect that reaches the threshold completes it, the
// keeper graduates it into its coin and a Soroswap pool, and the coins collectors were promised vest from then. This
// module serves the main Moments stack of the v2 deployment (net.contracts.momentsV2) and nothing else: testnet-qa's
// failing stack is the e2e's alone and never reaches the API (finding F5). v1 (moments.ts) stays for the retired
// generation.
// - Economics (§20.2): the policy, the pending policy, the terms a publish binds by value (the durations with
//   pending_backstop, and the harvest constants: compounded : harvested = 3,333 : 6,667, finding V3), both pauses, the
//   gross that completes a Moment and its FDV when the pool opens. Read live, kept 5 minutes; the admin keys never.
// - Status: a Moment's state and when it may expire. A Moment pending graduation expires at the later of its deadline
//   and the earlier of `stuck_since + stuck_expiry` (only after a recorded failed graduation) and
//   `completed_at + pending_backstop` (finding V11); a recorded failure is named from v2_errors.ts (finding V10).
// - Vesting: the schedule of an account's coins in a Moment, from the contract's claimable and the vest period.
// - Plans (§20.3), keyed by the Moment's NFT address: publish, collect, claim, claim all, withdraw, graduate and
//   expire. There is no mark_stuck: only a recorded failed graduation starts a Moment's stuck clock (finding F15).
//   Every builder checks its transaction against its intent with the v2 call rules below (momentsV2CallRules), which
//   the verifiers (verify.ts, TxVerifier.swift) take over in CT-16.
// - Metadata is written as for v1 (moments.ts writeMetadata): the same checks, storage paths and lite.moment_metadata.
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { amountArg, ApiError, bad, notFound } from "./http.ts";
import { launchName, launchSymbol } from "./launch_metadata.ts";
import { ownUpload } from "./media.ts";
import { AssetInfo, NetworkConfig } from "./networks.ts";
import { createPlan, PlanView, registerBuilder, StepSpec } from "./plans.ts";
import type { BuiltTx } from "./plans.ts";
import { referencePrices, usdOf } from "./refprices.ts";
import { Address, classicBalances, fromStroops, invoke, isAccountId, isContractId, native, requireAccount, sv, Transaction, view, xdr } from "./stellar.ts";
import { errorName, errorsFor, V2_CONTRACT_TAGS } from "./v2_errors.ts";
import { Intent, VerifyError } from "./verify.ts";

export { writeMetadata as writeMomentMetadata } from "./moments.ts";

type Native = Record<string, any>;
type Steps = { label: string; spec: StepSpec }[];
/** An intent's display values. */
type Display = Record<string, string | number | boolean | null>;

// ------------------------------------------------------------------------------------------------ constants

/** S: every Moment coin's supply, 100,000,000 coins at 7 decimals (moments-v2 SUPPLY, §14.2). */
export const SUPPLY = 1_000_000_000_000_000n;
/** The most editions one collect mints (moments-v2 MAX_BATCH, moment-nft MAX_MINT). */
export const MAX_BATCH = 20;
/** The most Moments one claim_all covers (moments-v2 MAX_CLAIM_IDS). */
export const MAX_CLAIM_IDS = 20;
/** The post-graduation harvest, compile-time constants of moments-v2 that the terms carry so the phone can show them
 *  (§9.1, B13b): each round pays out 6,667 bps of the fee growth and compounds the rest, the paid USDC side 40%
 *  creator / 60% platform, the coin side burned. */
export const MOMENT_HARVEST_BPS = 6_667;
export const MOMENT_HARVEST_CREATOR_BPS = 4_000;
/** A collector's vested share after 0, 1 and 2 or more periods; the creator's 20% at graduation and 16% more per
 *  period for 5 periods (moments-v2 vesting.rs, M:MomentVesting.sol:108-125). */
export const COLLECTOR_VESTED_BPS = [6_000, 8_000, 10_000];
export const CREATOR_BASE_BPS = 2_000;
export const CREATOR_STEP_BPS = 1_600;
export const CREATOR_PERIODS = 5;

const BPS = 10_000n;
/** moments-v2's tag: its errors are ERR_BASE + 7·100 + n (§4, finding V10). */
const TAG = V2_CONTRACT_TAGS["moments-v2"];

/** The Moments contract's v2 deployment, or 503 not_deployed: until the deployment file exists, nothing is pinned for
 *  v2 and its routes answer so (§20.1). */
export function momentsV2Id(net: NetworkConfig = env.network): string {
  const id = net.contracts.momentsV2;
  if (!id || !net.deploymentV2) throw new ApiError(503, "not_deployed", "Moments v2 isn't deployed on this network yet.");
  return id;
}

/** USDC, the only quote of v2 Moments (L9). */
function usdcOf(net: NetworkConfig): AssetInfo {
  const usdc = net.assets.find((a) => a.id === "USDC");
  if (!usdc) throw new ApiError(503, "not_deployed", "Moments v2 needs USDC, which this network doesn't list.");
  return usdc;
}

// ------------------------------------------------------------------------------------------------ wire shapes

/** The economics a Moment published now snapshots (moments-v2 Policy). USDC amounts in base units (7 decimals). */
export interface MomentsV2Policy {
  threshold: string;
  minPrice: string;
  creatorBps: number;
  platformBps: number;
  reserveBps: number;
  maxCreatorAllocBps: number;
  expiryCreatorBps: number;
  royaltyBps: number;
  platform: string;
  treasury: string;
}

/** moments-v2's durations, in seconds (dyor_common::MomentsDurations). */
export interface MomentsV2Durations {
  vestPeriod: number;
  stuckExpiry: number;
  /** After completion, when a Moment still pending graduation may expire without a recorded failure (finding V11). */
  pendingBackstop: number;
  timelock: number;
  timelockWindow: number;
  minWindow: number;
  maxWindow: number;
  harvestInterval: number;
}

/** The post-graduation harvest as the phone states it (§9.1, §14.4). */
export interface MomentsV2Harvest {
  intervalSecs: number;
  /** Of each round's fee growth: paid out, and left compounding in the locked position. */
  harvestedBps: number;
  compoundedBps: number;
  /** compounded : harvested, as the terms state it (finding V3). */
  ratio: string;
  /** The harvested USDC side, by payee; the coin side is burned. */
  quoteSide: { creatorBps: number; platformBps: number };
  coinSide: "burned";
}

/** What a publish binds by value (moments-v2 MomentsTerms): every field is compared at `publish`. */
export interface MomentsV2Terms {
  policy: MomentsV2Policy;
  externalBase: string;
  /** Hex. */
  nftWasmHash: string;
  coinWasmHash: string;
  graduator: string;
  executor: string;
  locker: string;
  durations: MomentsV2Durations;
  harvestBps: number;
  harvestCreatorBps: number;
  /** Not a field of the contract's terms: the harvest constants above, stated for the phone. */
  harvest: MomentsV2Harvest;
}

/** A proposed policy: applicable from `eta` to `expires`; after that it has lapsed, and stays visible until it is
 *  replaced or cancelled. */
export interface MomentsV2PendingPolicy {
  policy: MomentsV2Policy;
  eta: string;
  expires: string;
  state: "waiting" | "ready" | "lapsed";
}

/** The Moments block of GET /v1/economics for v2 (§20.2). */
export interface MomentsV2Economics {
  generation: 2;
  contract: string;
  quote: { asset: "USDC"; contract: string };
  supply: string;
  maxPerCollect: number;
  maxClaimIds: number;
  policy: MomentsV2Policy;
  pendingPolicy: MomentsV2PendingPolicy | null;
  terms: MomentsV2Terms;
  publishingPaused: boolean;
  guardianPaused: boolean;
  /** The gross that completes a Moment from empty, ceil(T·BPS/reserve_bps): also the highest price a Moment may ask. */
  completionGross: string;
  maxPrice: string;
  /** The FDV at the price the pool opens at, with the largest creator allocation the policy allows (§14.2). */
  fdvAtOpen: string;
  fdvAtOpenUsd: number | null;
  /** The same for each creator allocation from 0 in 1% steps (the publish form's choices). */
  fdvByAllocation: { allocationBps: number; fdv: string; fdvUsd: number | null }[];
}

export type MomentV2State = "collecting" | "graduation_pending" | "graduated" | "expired";

/** A failed graduation, named (finding V10): `recorded` as the indexer saw its grad_fail, or `simulated`, the failure
 *  an attempt records now. */
export interface MomentV2Failure {
  origin: number;
  code: number;
  name: string | null;
  source: string | null;
  seen: "recorded" | "simulated";
}

/** A Moment's state, read live, with when it may expire (finding V11). Times are ISO; null where they haven't
 *  happened. */
export interface MomentV2Status {
  generation: 2;
  nft: string;
  creator: string;
  coin: string;
  pool: string | null;
  state: MomentV2State;
  price: string;
  threshold: string;
  reserve: string;
  totalGross: string;
  /** reserve / threshold, at most 1. */
  progress: number;
  collects: number;
  editions: number;
  entitlements: string;
  creatorAllocBps: number;
  creatorBps: number;
  platformBps: number;
  reserveBps: number;
  expiryCreatorBps: number;
  royaltyBps: number;
  /** Coin units per USDC unit a collect promises: num / den. */
  rate: { num: string; den: string };
  publishedAt: string;
  deadline: string;
  completedAt: string | null;
  stuckSince: string | null;
  graduatedAt: string | null;
  endedAt: string | null;
  /** When `expire` will take it: for a Collecting Moment its deadline; for one pending graduation the later of the
   *  deadline and the earlier of failureExpiresAt and backstopAt. Null once Graduated or Expired. */
  expiresAt: string | null;
  /** Which clock sets expiresAt. */
  expiresBy: "deadline" | "failure" | "backstop" | null;
  /** completed_at + pending_backstop, for a Moment pending graduation. */
  backstopAt: string | null;
  /** stuck_since + stuck_expiry, after a recorded failure only. */
  failureExpiresAt: string | null;
  /** `expire` would take it now. */
  expirable: boolean;
  /** Pending graduation: the keeper usually finishes within a minute, and anyone may call graduate. */
  graduatable: boolean;
  /** With a recorded failure (stuck_since set): its origin, code and name. */
  failure: MomentV2Failure | null;
  /** USDC each beneficiary may withdraw now. */
  proceeds: { creator: string; platform: string; treasury: string };
}

/** One step of a vesting schedule: from `at` (null until the Moment graduates), `vestedBps` of the total has vested. */
export interface MomentV2VestingTranche {
  period: number;
  at: string | null;
  vestedBps: number;
  vested: string;
}

export interface MomentV2VestingSide {
  total: string;
  claimed: string;
  /** What the contract's claimable says can be minted now. */
  claimable: string;
  vested: string;
  tranches: MomentV2VestingTranche[];
  nextAt: string | null;
  fullAt: string | null;
}

/** An account's coins in one Moment (§9.2): what it was promised as a collector and, for the creator, its allocation. */
export interface MomentV2Vesting {
  generation: 2;
  nft: string;
  account: string;
  coin: string;
  state: MomentV2State;
  /** False for an expired Moment: its coins never exist. */
  vests: boolean;
  vestPeriodSecs: number;
  /** The vesting start, graduation; null before it. */
  startsAt: string | null;
  periodsElapsed: number | null;
  claimable: { collector: string; creator: string; total: string };
  collector: MomentV2VestingSide | null;
  creator: MomentV2VestingSide | null;
}

/** What POST /v1/moments/build takes for v2 (CT-18 wires the route). */
export interface MomentV2BuildRequest {
  action?: unknown;
  uri?: unknown;
  name?: unknown;
  symbol?: unknown;
  price?: unknown;
  allocationBps?: unknown;
  windowSecs?: unknown;
  nft?: unknown;
  quantity?: unknown;
  nfts?: unknown;
}

// ------------------------------------------------------------------------------------------------ contract values

function big(v: unknown): bigint {
  if (typeof v === "bigint") return v;
  if (typeof v === "number" && Number.isSafeInteger(v)) return BigInt(v);
  if (typeof v === "string" && /^-?[0-9]+$/.test(v)) return BigInt(v);
  throw new Error(`not an integer: ${String(v)}`);
}

const units = (v: unknown): string => big(v).toString();
const whole = (v: unknown): number => Number(big(v));

function hexOf(v: unknown): string {
  if (!(v instanceof Uint8Array)) throw new Error("not bytes");
  return Array.from(v, (b) => b.toString(16).padStart(2, "0")).join("");
}

function bytesOf(hex: string): Uint8Array {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error(`not 32 bytes of hex: ${hex}`);
  return Uint8Array.from(hex.match(/../g)!.map((b) => parseInt(b, 16)));
}

const isoAt = (secs: number): string => new Date(secs * 1000).toISOString();
/** A contract time that is 0 until it happens. */
const isoOrNull = (secs: number): string | null => (secs === 0 ? null : isoAt(secs));

const STATES: MomentV2State[] = ["collecting", "graduation_pending", "graduated", "expired"];

function stateOf(v: unknown): MomentV2State {
  const s = STATES[whole(v)];
  if (!s) throw new Error(`unknown Moment state ${String(v)}`);
  return s;
}

export function policyOf(n: Native): MomentsV2Policy {
  return {
    threshold: units(n.threshold),
    minPrice: units(n.min_price),
    creatorBps: whole(n.creator_bps),
    platformBps: whole(n.platform_bps),
    reserveBps: whole(n.reserve_bps),
    maxCreatorAllocBps: whole(n.max_creator_alloc_bps),
    expiryCreatorBps: whole(n.expiry_creator_bps),
    royaltyBps: whole(n.royalty_bps),
    platform: String(n.platform),
    treasury: String(n.treasury),
  };
}

export function durationsOf(n: Native): MomentsV2Durations {
  return {
    vestPeriod: whole(n.vest_period),
    stuckExpiry: whole(n.stuck_expiry),
    pendingBackstop: whole(n.pending_backstop),
    timelock: whole(n.timelock),
    timelockWindow: whole(n.timelock_window),
    minWindow: whole(n.min_window),
    maxWindow: whole(n.max_window),
    harvestInterval: whole(n.harvest_interval),
  };
}

/** The harvest constants as the phone states them: compounded : harvested = (BPS − hb) : hb (finding V3). */
export function harvestOf(harvestBps: number, harvestCreatorBps: number, intervalSecs: number): MomentsV2Harvest {
  const compounded = 10_000 - harvestBps;
  return {
    intervalSecs,
    harvestedBps: harvestBps,
    compoundedBps: compounded,
    ratio: `${compounded.toLocaleString("en-US")} : ${harvestBps.toLocaleString("en-US")}`,
    quoteSide: { creatorBps: harvestCreatorBps, platformBps: 10_000 - harvestCreatorBps },
    coinSide: "burned",
  };
}

export function termsOf(n: Native): MomentsV2Terms {
  const durations = durationsOf(n.durations);
  const harvestBps = whole(n.harvest_bps);
  const harvestCreatorBps = whole(n.harvest_creator_bps);
  return {
    policy: policyOf(n.policy),
    externalBase: String(n.external_base),
    nftWasmHash: hexOf(n.nft_wasm_hash),
    coinWasmHash: hexOf(n.coin_wasm_hash),
    graduator: String(n.graduator),
    executor: String(n.executor),
    locker: String(n.locker),
    durations,
    harvestBps,
    harvestCreatorBps,
    harvest: harvestOf(harvestBps, harvestCreatorBps, durations.harvestInterval),
  };
}

/** A pending policy at `now` (ms): waiting before its eta, ready until it expires, lapsed after (the contract refuses
 *  apply_policy then; clients treat now > expires as lapsed). */
export function pendingPolicyOf(n: Native | null | undefined, now: number): MomentsV2PendingPolicy | null {
  if (n === null || n === undefined) return null;
  const eta = whole(n.eta);
  const expires = whole(n.expires);
  const secs = Math.floor(now / 1000);
  return { policy: policyOf(n.policy), eta: isoAt(eta), expires: isoAt(expires), state: secs < eta ? "waiting" : secs > expires ? "lapsed" : "ready" };
}

/** A contracttype struct: a map with its field names as symbols, in sorted order. */
function struct(fields: Record<string, xdr.ScVal>): xdr.ScVal {
  return xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));
}

export function policyScVal(p: MomentsV2Policy): xdr.ScVal {
  return struct({
    threshold: sv.i128(p.threshold),
    min_price: sv.i128(p.minPrice),
    creator_bps: sv.u32(p.creatorBps),
    platform_bps: sv.u32(p.platformBps),
    reserve_bps: sv.u32(p.reserveBps),
    max_creator_alloc_bps: sv.u32(p.maxCreatorAllocBps),
    expiry_creator_bps: sv.u32(p.expiryCreatorBps),
    royalty_bps: sv.u32(p.royaltyBps),
    platform: sv.addr(p.platform),
    treasury: sv.addr(p.treasury),
  });
}

export function durationsScVal(d: MomentsV2Durations): xdr.ScVal {
  return struct({
    vest_period: sv.u64(d.vestPeriod),
    stuck_expiry: sv.u64(d.stuckExpiry),
    pending_backstop: sv.u64(d.pendingBackstop),
    timelock: sv.u64(d.timelock),
    timelock_window: sv.u64(d.timelockWindow),
    min_window: sv.u64(d.minWindow),
    max_window: sv.u64(d.maxWindow),
    harvest_interval: sv.u64(d.harvestInterval),
  });
}

/** The terms as `publish` takes them back, by value. */
export function termsScVal(t: MomentsV2Terms): xdr.ScVal {
  return struct({
    policy: policyScVal(t.policy),
    external_base: sv.str(t.externalBase),
    nft_wasm_hash: sv.bytes(bytesOf(t.nftWasmHash)),
    coin_wasm_hash: sv.bytes(bytesOf(t.coinWasmHash)),
    graduator: sv.addr(t.graduator),
    executor: sv.addr(t.executor),
    locker: sv.addr(t.locker),
    durations: durationsScVal(t.durations),
    harvest_bps: sv.u32(t.harvestBps),
    harvest_creator_bps: sv.u32(t.harvestCreatorBps),
  });
}

/** What a creator publishes (moments-v2 PublishParams). */
export interface MomentV2PublishParams {
  name: string;
  symbol: string;
  metadataUri: string;
  /** SHA-256 of the media, hex. */
  mediaHash: string;
  place: string;
  date: string;
  price: string;
  allocationBps: number;
  windowSecs: number;
  nonce: string;
}

export function publishParamsScVal(p: MomentV2PublishParams): xdr.ScVal {
  return struct({
    name: sv.str(p.name),
    symbol: sv.str(p.symbol),
    metadata_uri: sv.str(p.metadataUri),
    media_hash: sv.bytes(bytesOf(p.mediaHash)),
    place: sv.str(p.place),
    date: sv.str(p.date),
    price: sv.i128(p.price),
    creator_alloc_bps: sv.u32(p.allocationBps),
    window_secs: sv.u64(p.windowSecs),
    nonce: sv.u64(p.nonce),
  });
}

/** The terms as an intent displays them: one flat value per field, the phone's terms guard compares them with what it
 *  showed, and the call rules with what the transaction passes to publish (TERMS_DISPLAY_KEYS). */
export function termsDisplay(t: MomentsV2Terms): Display {
  const p = t.policy;
  const d = t.durations;
  return {
    threshold: p.threshold,
    minPrice: p.minPrice,
    creatorBps: p.creatorBps,
    platformBps: p.platformBps,
    reserveBps: p.reserveBps,
    maxCreatorAllocBps: p.maxCreatorAllocBps,
    expiryCreatorBps: p.expiryCreatorBps,
    royaltyBps: p.royaltyBps,
    platform: p.platform,
    treasury: p.treasury,
    externalBase: t.externalBase,
    nftWasmHash: t.nftWasmHash,
    coinWasmHash: t.coinWasmHash,
    graduator: t.graduator,
    executor: t.executor,
    locker: t.locker,
    vestPeriod: d.vestPeriod,
    stuckExpiry: d.stuckExpiry,
    pendingBackstop: d.pendingBackstop,
    timelock: d.timelock,
    timelockWindow: d.timelockWindow,
    minWindow: d.minWindow,
    maxWindow: d.maxWindow,
    harvestInterval: d.harvestInterval,
    harvestBps: t.harvestBps,
    harvestCreatorBps: t.harvestCreatorBps,
  };
}

/** Every key termsDisplay writes. */
export const TERMS_DISPLAY_KEYS: readonly string[] = [
  "threshold", "minPrice", "creatorBps", "platformBps", "reserveBps", "maxCreatorAllocBps", "expiryCreatorBps",
  "royaltyBps", "platform", "treasury", "externalBase", "nftWasmHash", "coinWasmHash", "graduator", "executor", "locker",
  "vestPeriod", "stuckExpiry", "pendingBackstop", "timelock", "timelockWindow", "minWindow", "maxWindow",
  "harvestInterval", "harvestBps", "harvestCreatorBps",
];

/** A Moment as moments-v2 snapshots it at publish. */
export interface MomentV2Snapshot {
  nft: string;
  creator: string;
  platform: string;
  treasury: string;
  coin: string;
  price: bigint;
  threshold: bigint;
  rateNum: bigint;
  rateDen: bigint;
  creatorBps: number;
  platformBps: number;
  reserveBps: number;
  creatorAllocBps: number;
  expiryCreatorBps: number;
  royaltyBps: number;
  nonce: bigint;
  publishedAt: number;
  deadline: number;
}

/** A Moment's ledger. Times in seconds, 0 until they happen. */
export interface MomentV2Ledger {
  state: MomentV2State;
  completedAt: number;
  stuckSince: number;
  endedAt: number;
  graduatedAt: number;
  reserve: bigint;
  creatorClaimable: bigint;
  platformClaimable: bigint;
  treasuryClaimable: bigint;
  totalGross: bigint;
  collects: number;
  editions: number;
  entitlements: bigint;
  creatorClaimed: bigint;
  mintedByVesting: bigint;
  pool: string | null;
  liquidity: bigint;
}

export function momentOf(n: Native): MomentV2Snapshot {
  return {
    nft: String(n.nft),
    creator: String(n.creator),
    platform: String(n.platform),
    treasury: String(n.treasury),
    coin: String(n.coin),
    price: big(n.price),
    threshold: big(n.threshold),
    rateNum: big(n.rate_num),
    rateDen: big(n.rate_den),
    creatorBps: whole(n.creator_bps),
    platformBps: whole(n.platform_bps),
    reserveBps: whole(n.reserve_bps),
    creatorAllocBps: whole(n.creator_alloc_bps),
    expiryCreatorBps: whole(n.expiry_creator_bps),
    royaltyBps: whole(n.royalty_bps),
    nonce: big(n.nonce),
    publishedAt: whole(n.published_at),
    deadline: whole(n.deadline),
  };
}

export function ledgerOf(n: Native): MomentV2Ledger {
  return {
    state: stateOf(n.state),
    completedAt: whole(n.completed_at),
    stuckSince: whole(n.stuck_since),
    endedAt: whole(n.ended_at),
    graduatedAt: whole(n.graduated_at),
    reserve: big(n.reserve),
    creatorClaimable: big(n.creator_claimable),
    platformClaimable: big(n.platform_claimable),
    treasuryClaimable: big(n.treasury_claimable),
    totalGross: big(n.total_gross),
    collects: whole(n.collects),
    editions: whole(n.editions),
    entitlements: big(n.entitlements),
    creatorClaimed: big(n.creator_claimed),
    mintedByVesting: big(n.minted_by_vesting ?? 0),
    pool: n.pool === null || n.pool === undefined ? null : String(n.pool),
    liquidity: big(n.liquidity),
  };
}

// ------------------------------------------------------------------------------------------------ refusals

/** moments-v2's refusals the phone words itself, by error name: v1's codes where the meaning is the same, and v2's
 *  own. Every other error keeps the simulation's message. */
const REFUSALS = {
  PublishingPaused: { code: "moment.paused", text: "Publishing new Moments is paused." },
  TermsChanged: { code: "moment.terms_changed", text: "The Moments terms changed since you started. Review them again." },
  PriceTooLow: { code: "moment.price_too_low", text: "The price is below the minimum." },
  PriceTooHigh: { code: "moment.price_too_high", text: "The price is above the most a Moment can ask." },
  WindowClosed: { code: "moment.closed", text: "This Moment's collect window has closed." },
  NotCollecting: { code: "moment.completed", text: "This Moment reached its goal and isn't collecting any more." },
  NothingToClaim: { code: "moment.nothing_to_claim", text: "Nothing to claim yet." },
  NothingToWithdraw: { code: "moment.nothing_to_withdraw", text: "Nothing to withdraw yet." },
  NotExpirable: { code: "moment.not_expirable", text: "This Moment can't expire yet." },
  WrongState: { code: "moment.wrong_state", text: "This Moment's state doesn't allow this." },
} as const satisfies Record<string, { code: string; text: string }>;

type RefusalName = keyof typeof REFUSALS;

/** The name of the error moments-v2 itself failed with, from a simulation's error text. Its codes are namespaced
 *  (10_701…10_799), so a code in that range is moments-v2's whichever event logged it; another contract's failure
 *  (a token's balance, a missing trustline) has another code and gives null. */
export function momentsV2ErrorName(raw: string): string | null {
  for (const m of raw.matchAll(/Error\(Contract, #(\d+)\)/g)) {
    if (errorsFor(TAG, Number(m[1])).length) return errorName(TAG, Number(m[1]));
  }
  return null;
}

/** A refusal as the API answers it (§6.13): simulation_failed with its stable code; `detail` adds what the copy shows. */
export function refusalV2(name: RefusalName, detail: Record<string, string> = {}, text?: string): ApiError {
  const r = REFUSALS[name];
  return new ApiError(422, "simulation_failed", text ?? r.text, { contractCode: r.code, ...detail });
}

/** Runs a simulation against moments-v2; its own refusals get their stable codes, and an unknown Moment is 404. */
async function refusing<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    if (!(err instanceof ApiError) || err.code !== "simulation_failed") throw err;
    const raw = String((err.detail as { raw?: unknown } | undefined)?.raw ?? "");
    const name = momentsV2ErrorName(raw);
    if (name === "UnknownMoment") throw notFound("Moment");
    if (name !== null && Object.hasOwn(REFUSALS, name)) throw refusalV2(name as RefusalName, { raw });
    throw err;
  }
}

// ------------------------------------------------------------------------------------------------ economics

const ceilDiv = (a: bigint, b: bigint): bigint => (a + b - 1n) / b;

/** The gross that completes a Moment from empty, ceil(T·BPS/reserve_bps): also the price ceiling (§9.2). At T = 10
 *  USDC and 75% that is 13.3333334 USDC. */
export function completionGross(threshold: bigint, reserveBps: number): bigint {
  return ceilDiv(threshold * BPS, BigInt(reserveBps));
}

/** The bundle rate, coin units per USDC unit: S·(BPS − alloc)·r / (BPS·T·(BPS + r)) (M:MomentsFactory.sol:276-283). */
export function bundleRate(threshold: bigint, reserveBps: number, allocationBps: number): { num: bigint; den: bigint } {
  const r = BigInt(reserveBps);
  return { num: SUPPLY * (BPS - BigInt(allocationBps)) * r, den: BPS * threshold * (BPS + r) };
}

/** The FDV in USDC units at the price the pool opens at. Collectors buy at that price, so it is S over the bundle
 *  rate: BPS·T·(BPS + r) / ((BPS − alloc)·r). At T = 10 USDC, 75% and 10% that is 25.9259259 USDC (§14.2). */
export function fdvAtOpen(threshold: bigint, reserveBps: number, allocationBps: number): bigint {
  const r = BigInt(reserveBps);
  return (BPS * threshold * (BPS + r)) / ((BPS - BigInt(allocationBps)) * r);
}

/** How long a read of the terms is served. */
export const MOMENTS_ECONOMICS_TTL_MS = 5 * 60_000;

/** What the contract said: the parts of the block that don't move with the clock or the price. */
interface ChainEconomics {
  terms: MomentsV2Terms;
  pending: Native | null;
  publishingPaused: boolean;
  guardianPaused: boolean;
}

let cachedEconomics: { key: string; at: number; value: ChainEconomics } | null = null;

/** Drops the isolate's copy (tests). */
export function forgetMomentsEconomicsV2(): void {
  cachedEconomics = null;
}

async function chainEconomics(contract: string, net: NetworkConfig, now: number): Promise<ChainEconomics> {
  const key = `${net.passphrase}|${contract}`;
  if (cachedEconomics && cachedEconomics.key === key && now - cachedEconomics.at < MOMENTS_ECONOMICS_TTL_MS && now >= cachedEconomics.at) {
    return cachedEconomics.value;
  }
  try {
    const [cfg, terms, pending] = await Promise.all([view(contract, "config"), view(contract, "terms"), view(contract, "pending_policy")]);
    const value = { terms: termsOf(terms), pending: pending ?? null, publishingPaused: cfg.publishing_paused === true, guardianPaused: cfg.guardian_paused === true };
    cachedEconomics = { key, at: now, value };
    return value;
  } catch (err) {
    if (cachedEconomics && cachedEconomics.key === key) return cachedEconomics.value;
    throw new ApiError(502, "rpc_unavailable", "The Moments terms couldn't be read just now. Try again.", { raw: String((err as Error).message ?? err).slice(0, 300) });
  }
}

/** The Moments block of GET /v1/economics (§20.2), the main stack's only (finding F5). The policy, the pending policy
 *  and the terms are read live from moments-v2 (config(), terms(), pending_policy()) and kept 5 minutes; when a read
 *  fails, the last one is served, and without one 502 rpc_unavailable. Governance and the guardian are never served.
 *  USD values use USDC's reference price, null without one. */
export async function momentsEconomicsV2(net: NetworkConfig = env.network, now: number = Date.now()): Promise<MomentsV2Economics> {
  const contract = momentsV2Id(net);
  const usdc = usdcOf(net);
  const chain = await chainEconomics(contract, net, now);
  let usd: number | null = null;
  try {
    usd = usdOf(usdc, await referencePrices(now, net));
  } catch {
    usd = null;
  }
  const usdOfUnits = (u: bigint) => (usd === null ? null : Math.round((Number(u) / 1e7) * usd * 100) / 100);
  const p = chain.terms.policy;
  const threshold = BigInt(p.threshold);
  const gross = completionGross(threshold, p.reserveBps);
  const allocations = [...new Set([...Array.from({ length: Math.floor(p.maxCreatorAllocBps / 100) + 1 }, (_, i) => i * 100), p.maxCreatorAllocBps])];
  const fdvByAllocation = allocations.map((a) => {
    const fdv = fdvAtOpen(threshold, p.reserveBps, a);
    return { allocationBps: a, fdv: fdv.toString(), fdvUsd: usdOfUnits(fdv) };
  });
  const top = fdvByAllocation[fdvByAllocation.length - 1];
  return {
    generation: 2,
    contract,
    quote: { asset: "USDC", contract: usdc.contract },
    supply: SUPPLY.toString(),
    maxPerCollect: MAX_BATCH,
    maxClaimIds: MAX_CLAIM_IDS,
    policy: p,
    pendingPolicy: pendingPolicyOf(chain.pending, now),
    terms: chain.terms,
    publishingPaused: chain.publishingPaused,
    guardianPaused: chain.guardianPaused,
    completionGross: gross.toString(),
    maxPrice: gross.toString(),
    fdvAtOpen: top.fdv,
    fdvAtOpenUsd: top.fdvUsd,
    fdvByAllocation,
  };
}

// ------------------------------------------------------------------------------------------------ status

/** The deployment's Moments durations, as pinned (deployments/index.ts): the contract's constructor arguments,
 *  immutable, checked value by value against the file's set. */
export function pinnedDurations(net: NetworkConfig): MomentsV2Durations {
  momentsV2Id(net);
  return durationsOf(net.deploymentV2!.durations.moments as unknown as Native);
}

/** When `expire` will take a Moment (moments-v2 collect.rs expire, finding V11), in seconds: a Collecting Moment at its
 *  deadline; one pending graduation at max(deadline, min(stuck_since + stuck_expiry, completed_at + pending_backstop)),
 *  the first clock only after a recorded failure (stuck_since ≠ 0). Null once Graduated or Expired. */
export function expiryOf(
  m: Pick<MomentV2Snapshot, "deadline">,
  l: Pick<MomentV2Ledger, "state" | "completedAt" | "stuckSince">,
  d: Pick<MomentsV2Durations, "stuckExpiry" | "pendingBackstop">,
): { at: number | null; by: MomentV2Status["expiresBy"]; backstopAt: number | null; failureAt: number | null } {
  if (l.state === "collecting") return { at: m.deadline, by: "deadline", backstopAt: null, failureAt: null };
  if (l.state !== "graduation_pending") return { at: null, by: null, backstopAt: null, failureAt: null };
  const backstopAt = l.completedAt + d.pendingBackstop;
  const failureAt = l.stuckSince !== 0 ? l.stuckSince + d.stuckExpiry : null;
  const clock = failureAt !== null && failureAt < backstopAt ? { at: failureAt, by: "failure" as const } : { at: backstopAt, by: "backstop" as const };
  if (m.deadline > clock.at) return { at: m.deadline, by: "deadline", backstopAt, failureAt };
  return { ...clock, backstopAt, failureAt };
}

/** Whether `expire` at `nowSecs` takes the reserve under the backstop branch, as the contract decides it. */
function expiresByBackstop(l: MomentV2Ledger, d: MomentsV2Durations, nowSecs: number): boolean {
  if (l.state !== "graduation_pending") return false;
  if (l.stuckSince !== 0 && nowSecs >= l.stuckSince + d.stuckExpiry) return false;
  return nowSecs >= l.completedAt + d.pendingBackstop;
}

/** A failure named from v2_errors.ts (finding V10). */
export function namedFailure(origin: number, code: number, seen: MomentV2Failure["seen"]): MomentV2Failure {
  const all = errorsFor(origin, code);
  return { origin, code, name: errorName(origin, code), source: all.length ? [...new Set(all.map((e) => e.source))].join(" or ") : null, seen };
}

/** What a graduation attempt does now, by simulation: graduates, records a failure (origin and code), or aborts (a
 *  failure no attempt can record: only the backstop ends such a Moment, finding V11). */
export type MomentV2GraduationOutcome = { kind: "graduated"; pool: string } | { kind: "failed"; origin: number; code: number } | { kind: "aborted" };

export async function graduationOutcome(contract: string, nft: string): Promise<MomentV2GraduationOutcome> {
  let out: unknown;
  try {
    out = await refusing(() => view(contract, "graduate", [sv.addr(nft)]));
  } catch (err) {
    // A refusal with a stable code (a Moment that isn't pending, 404 for an unknown one) stands; any other failed
    // simulation is an abort, GraduationInvalid's included.
    if (err instanceof ApiError && err.code === "simulation_failed" && !(err.detail as { contractCode?: unknown } | undefined)?.contractCode) {
      return { kind: "aborted" };
    }
    throw err;
  }
  if (Array.isArray(out) && out[0] === "Graduated") return { kind: "graduated", pool: String(out[1]) };
  if (Array.isArray(out) && out[0] === "Failed") return { kind: "failed", origin: whole(out[1].origin), code: whole(out[1].code) };
  throw new Error(`unexpected graduation outcome ${JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? v.toString() : v))}`);
}

/** A Moment's status from its snapshot and ledger, at `now` (ms). */
export function statusOf(nft: string, m: MomentV2Snapshot, l: MomentV2Ledger, d: MomentsV2Durations, now: number, failure: MomentV2Failure | null): MomentV2Status {
  const e = expiryOf(m, l, d);
  const nowSecs = Math.floor(now / 1000);
  const progress = m.threshold > 0n ? Math.min(1, Number((l.reserve * 1_000_000n) / m.threshold) / 1_000_000) : 0;
  return {
    generation: 2,
    nft,
    creator: m.creator,
    coin: m.coin,
    pool: l.pool,
    state: l.state,
    price: m.price.toString(),
    threshold: m.threshold.toString(),
    reserve: l.reserve.toString(),
    totalGross: l.totalGross.toString(),
    progress,
    collects: l.collects,
    editions: l.editions,
    entitlements: l.entitlements.toString(),
    creatorAllocBps: m.creatorAllocBps,
    creatorBps: m.creatorBps,
    platformBps: m.platformBps,
    reserveBps: m.reserveBps,
    expiryCreatorBps: m.expiryCreatorBps,
    royaltyBps: m.royaltyBps,
    rate: { num: m.rateNum.toString(), den: m.rateDen.toString() },
    publishedAt: isoAt(m.publishedAt),
    deadline: isoAt(m.deadline),
    completedAt: isoOrNull(l.completedAt),
    stuckSince: isoOrNull(l.stuckSince),
    graduatedAt: isoOrNull(l.graduatedAt),
    endedAt: isoOrNull(l.endedAt),
    expiresAt: e.at === null ? null : isoAt(e.at),
    expiresBy: e.by,
    backstopAt: e.backstopAt === null ? null : isoAt(e.backstopAt),
    failureExpiresAt: e.failureAt === null ? null : isoAt(e.failureAt),
    expirable: e.at !== null && nowSecs >= e.at,
    graduatable: l.state === "graduation_pending",
    failure: l.state === "graduation_pending" && l.stuckSince !== 0 ? failure : null,
    proceeds: { creator: l.creatorClaimable.toString(), platform: l.platformClaimable.toString(), treasury: l.treasuryClaimable.toString() },
  };
}

function nftArg(v: unknown): string {
  if (typeof v !== "string" || !isContractId(v)) throw bad("bad_moment", "Unknown Moment.");
  return v;
}

/** A Moment's snapshot and ledger, read live from the main stack: 404 for a Moment it doesn't have (a v1 id, another
 *  stack's NFT). */
async function readMoment(contract: string, nft: string): Promise<{ m: MomentV2Snapshot; l: MomentV2Ledger }> {
  const [m, l] = await refusing(() => Promise.all([view(contract, "get_moment", [sv.addr(nft)]), view(contract, "ledger", [sv.addr(nft)])]));
  return { m: momentOf(m), l: ledgerOf(l) };
}

/** A Moment's status, read live (moments-v2 get_moment and ledger). With a recorded failure (stuck_since set), the
 *  failure is `recorded` when the caller has the indexed grad_fail's origin and code; otherwise it is the failure a
 *  graduation attempt records now (`simulated`), and null when that attempt would graduate or abort. */
export async function momentStatusV2(
  nft: string,
  opts: { net?: NetworkConfig; now?: number; recorded?: { origin: number; code: number } | null } = {},
): Promise<MomentV2Status> {
  const net = opts.net ?? env.network;
  const now = opts.now ?? Date.now();
  const contract = momentsV2Id(net);
  const id = nftArg(nft);
  const { m, l } = await readMoment(contract, id);
  return statusOf(id, m, l, pinnedDurations(net), now, await failureOf(contract, id, l, opts.recorded));
}

async function failureOf(contract: string, nft: string, l: MomentV2Ledger, recorded: { origin: number; code: number } | null | undefined): Promise<MomentV2Failure | null> {
  if (l.state !== "graduation_pending" || l.stuckSince === 0) return null;
  if (recorded) return namedFailure(recorded.origin, recorded.code, "recorded");
  try {
    const outcome = await graduationOutcome(contract, nft);
    return outcome.kind === "failed" ? namedFailure(outcome.origin, outcome.code, "simulated") : null;
  } catch {
    // RPC unavailable: the status stands without the reason.
    return null;
  }
}

// ------------------------------------------------------------------------------------------------ vesting

function side(total: bigint, claimed: bigint, claimable: bigint, steps: number[], start: number | null, period: number, nowSecs: number): MomentV2VestingSide {
  const tranches = steps.map((bps, k) => ({
    period: k,
    at: start === null ? null : isoAt(start + k * period),
    vestedBps: bps,
    vested: ((total * BigInt(bps)) / BPS).toString(),
  }));
  const next = start === null ? undefined : steps.map((_, k) => start + k * period).find((t) => t > nowSecs);
  return {
    total: total.toString(),
    claimed: claimed.toString(),
    claimable: claimable.toString(),
    vested: (claimed + claimable).toString(),
    tranches,
    nextAt: next === undefined ? null : isoAt(next),
    fullAt: start === null ? null : isoAt(start + (steps.length - 1) * period),
  };
}

/** The collector's tranches: 60 / 80 / 100% at 0 / 1 / 2 periods. The creator's: 20% + 16% per period, all after 5. */
const COLLECTOR_STEPS = COLLECTOR_VESTED_BPS;
const CREATOR_STEPS = Array.from({ length: CREATOR_PERIODS + 1 }, (_, k) => CREATOR_BASE_BPS + CREATOR_STEP_BPS * k);

/** An account's vesting in a Moment at `now` (ms): its tranches from graduation in steps of `vestPeriod`, and what the
 *  contract's claimable says it can mint now (vested = claimed + claimable). */
export function vestingOf(
  nft: string,
  account: string,
  m: MomentV2Snapshot,
  l: MomentV2Ledger,
  position: { entitlement: bigint; claimed: bigint },
  claimable: { collector: bigint; creator: bigint },
  vestPeriod: number,
  now: number,
): MomentV2Vesting {
  const nowSecs = Math.floor(now / 1000);
  const start = l.state === "graduated" ? l.graduatedAt : null;
  const vests = l.state !== "expired";
  const allocation = (SUPPLY * BigInt(m.creatorAllocBps)) / BPS;
  const isCreator = account === m.creator && allocation > 0n;
  return {
    generation: 2,
    nft,
    account,
    coin: m.coin,
    state: l.state,
    vests,
    vestPeriodSecs: vestPeriod,
    startsAt: start === null ? null : isoAt(start),
    periodsElapsed: start === null ? null : Math.floor(Math.max(0, nowSecs - start) / vestPeriod),
    claimable: { collector: claimable.collector.toString(), creator: claimable.creator.toString(), total: (claimable.collector + claimable.creator).toString() },
    collector: vests && position.entitlement > 0n ? side(position.entitlement, position.claimed, claimable.collector, COLLECTOR_STEPS, start, vestPeriod, nowSecs) : null,
    creator: vests && isCreator ? side(allocation, l.creatorClaimed, claimable.creator, CREATOR_STEPS, start, vestPeriod, nowSecs) : null,
  };
}

/** GET a Moment's vesting for `account`, read live (get_moment, ledger, position and claimable). */
export async function momentVestingV2(nft: string, account: string, net: NetworkConfig = env.network, now: number = Date.now()): Promise<MomentV2Vesting> {
  const contract = momentsV2Id(net);
  const id = nftArg(nft);
  if (!isAccountId(account) && !isContractId(account)) throw bad("bad_arg", "address must be a Stellar address (G… or C…).");
  const [{ m, l }, position, claimable] = await Promise.all([
    readMoment(contract, id),
    refusing(() => view(contract, "position", [sv.addr(id), sv.addr(account)])),
    refusing(() => view(contract, "claimable", [sv.addr(id), sv.addr(account)])),
  ]);
  return vestingOf(
    id,
    account,
    m,
    l,
    { entitlement: big(position.entitlement), claimed: big(position.claimed) },
    { collector: big(claimable[0]), creator: big(claimable[1]) },
    pinnedDurations(net).vestPeriod,
    now,
  );
}

// ------------------------------------------------------------------------------------------------ the call rules

const FOR_ANOTHER = "the call acts for another account";
const ARGUMENTS = "the call's arguments are not as expected";
const NOT_SHOWN = "the call is for another Moment than the one shown";

function fail(msg: string): never {
  throw new VerifyError(msg);
}

function addrOf(v: xdr.ScVal | undefined): string | null {
  if (!v || v.switch() !== xdr.ScValType.scvAddress()) return null;
  const a = v.address();
  const t = a.switch();
  if (t !== xdr.ScAddressType.scAddressTypeAccount() && t !== xdr.ScAddressType.scAddressTypeContract()) return null;
  return Address.fromScAddress(a).toString();
}

function intOf(v: xdr.ScVal | undefined, type: "scvU32" | "scvU64" | "scvI128"): bigint | null {
  if (!v || v.switch().name !== type) return null;
  return BigInt(native(v));
}

/** A struct argument's fields, natively, with exactly `keys`; null for anything else. */
function fieldsOf(v: xdr.ScVal | undefined, keys: readonly string[]): Native | null {
  if (!v || v.switch() !== xdr.ScValType.scvMap()) return null;
  const n = native(v) as Native;
  const got = Object.keys(n).sort();
  return got.length === keys.length && [...keys].sort().every((k, i) => got[i] === k) ? n : null;
}

const PARAM_KEYS = ["name", "symbol", "metadata_uri", "media_hash", "place", "date", "price", "creator_alloc_bps", "window_secs", "nonce"];
const TERMS_KEYS = ["policy", "external_base", "nft_wasm_hash", "coin_wasm_hash", "graduator", "executor", "locker", "durations", "harvest_bps", "harvest_creator_bps"];

/** What a rule reads: the account the transaction acts for, the intent it must match, and the USDC contract. */
export interface MomentsV2RuleContext {
  user: string;
  intent: Intent;
  usdc: string;
}

function arity(args: xdr.ScVal[], n: number) {
  if (args.length !== n) fail(ARGUMENTS);
}

function actsFor(rc: MomentsV2RuleContext, v: xdr.ScVal | undefined) {
  if (addrOf(v) !== rc.user) fail(FOR_ANOTHER);
}

function isShownMoment(v: xdr.ScVal | undefined, rc: MomentsV2RuleContext) {
  const nft = addrOf(v);
  if (nft === null || nft !== rc.intent.display?.nft) fail(NOT_SHOWN);
}

const same = (a: unknown, b: unknown) => String(a) === String(b);

/** moments-v2's user-facing functions and what their arguments must say (§20.4), written from the contract's own
 *  signatures (contracts/moments-v2). publish binds every term and parameter to what the intent displays, so the phone
 *  shows what is signed; collect spends at most the intent's USDC; claims act for the user; withdraw_creator, graduate
 *  and expire are anyone's to call and name the Moment shown. */
export const momentsV2CallRules: Record<string, (args: xdr.ScVal[], rc: MomentsV2RuleContext) => void> = {
  // publish(creator, p: PublishParams, expected: MomentsTerms).
  publish: (args, rc) => {
    arity(args, 3);
    actsFor(rc, args[0]);
    const d = rc.intent.display ?? {};
    const p = fieldsOf(args[1], PARAM_KEYS);
    const t = fieldsOf(args[2], TERMS_KEYS);
    if (p === null || t === null) fail(ARGUMENTS);
    const params: [unknown, unknown][] = [
      [p.name, d.name],
      [p.symbol, d.symbol],
      [p.metadata_uri, d.uri],
      [p.media_hash instanceof Uint8Array ? hexOf(p.media_hash) : null, d.mediaHash],
      [p.place, d.place],
      [p.date, d.date],
      [p.price, d.price],
      [p.creator_alloc_bps, d.allocationBps],
      [p.window_secs, d.windowSecs],
      [p.nonce, d.nonce],
    ];
    if (params.some(([a, b]) => !same(a, b))) fail(ARGUMENTS);
    let shown: Display;
    try {
      shown = termsDisplay(termsOf(t));
    } catch {
      fail(ARGUMENTS);
    }
    if (TERMS_DISPLAY_KEYS.some((k) => !same(shown[k], d[k]))) fail("the terms are not the ones shown");
  },
  // collect(collector, nft, qty, max_total): the collector pays at most max_total, which the intent spends in USDC.
  collect: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
    isShownMoment(args[1], rc);
    const qty = intOf(args[2], "scvU32");
    const max = intOf(args[3], "scvI128");
    if (qty === null || max === null || !same(qty, rc.intent.display?.quantity) || !same(max, rc.intent.display?.total)) fail(ARGUMENTS);
    const spend = rc.intent.spend;
    if (Object.keys(spend).length !== 1 || !Object.hasOwn(spend, rc.usdc) || max > BigInt(spend[rc.usdc])) fail(ARGUMENTS);
  },
  // claim(account, nft).
  claim: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[0]);
    isShownMoment(args[1], rc);
  },
  // claim_all(account, nfts): at most 20, exactly the Moments shown.
  claim_all: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[0]);
    const list = args[1]?.switch() === xdr.ScValType.scvVec() ? args[1].vec() ?? [] : null;
    if (list === null || list.length === 0 || list.length > MAX_CLAIM_IDS) fail(ARGUMENTS);
    if (list.map(addrOf).join(",") !== rc.intent.display?.nfts) fail(NOT_SHOWN);
  },
  // withdraw_creator(nft), graduate(nft), expire(nft): anyone's to call; they pay only the Moment's own beneficiaries.
  withdraw_creator: (args, rc) => {
    arity(args, 1);
    isShownMoment(args[0], rc);
  },
  graduate: (args, rc) => {
    arity(args, 1);
    isShownMoment(args[0], rc);
  },
  expire: (args, rc) => {
    arity(args, 1);
    isShownMoment(args[0], rc);
  },
};

/** The functions anyone may call: they need no authorization, and must carry none of the user's. */
export const PERMISSIONLESS_V2 = new Set(["withdraw_creator", "graduate", "expire"]);

/** Checks a Moments v2 step against its intent: one call to moments-v2 that the intent names, its arguments bound by
 *  momentsV2CallRules, and the user's authorization exactly the call itself, with collect's USDC pull (to moments-v2,
 *  at most the intent's spend) the only thing under it; a call anyone may make carries none. Throws VerifyError. */
export function verifyMomentsV2Call(tx: Transaction, intent: Intent, ctx: { user: string; contract: string; usdc: string }): void {
  if (tx.source !== ctx.user) fail("the transaction is not from your account");
  if (tx.operations.length !== 1) fail("unexpected number of operations");
  const op = tx.operations[0] as any;
  if (op.type !== "invokeHostFunction") fail(`operation ${op.type} is not part of this action`);
  if (op.source && op.source !== ctx.user) fail("an operation runs from a third account");
  const hf = op.func as xdr.HostFunction;
  if (hf.switch() !== xdr.HostFunctionType.hostFunctionTypeInvokeContract()) fail("only contract calls are allowed");
  const ic = hf.invokeContract();
  const contract = Address.fromScAddress(ic.contractAddress()).toString();
  const name = ic.functionName().toString();
  if (contract !== ctx.contract) fail(`contract ${contract} is not Moments v2`);
  if (!(intent.calls ?? []).some((c) => c.contract === contract && c.fn === name)) fail(`call ${name} is not part of this action`);
  if (!Object.hasOwn(momentsV2CallRules, name)) fail(`function ${name} is not on the allowlist`);
  momentsV2CallRules[name](ic.args(), { user: ctx.user, intent, usdc: ctx.usdc });

  const auth = (op.auth ?? []) as xdr.SorobanAuthorizationEntry[];
  if (PERMISSIONLESS_V2.has(name)) {
    if (auth.length) fail("a call anyone may make carries your authorization");
    return;
  }
  if (auth.length !== 1) fail("the transaction asks for more authorization than this call");
  const entry = auth[0];
  if (entry.credentials().switch() !== xdr.SorobanCredentialsType.sorobanCredentialsSourceAccount()) {
    fail("the transaction needs a signature from another address");
  }
  const root = entry.rootInvocation();
  const rootFn = root.function();
  if (rootFn.switch() !== xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn() || rootFn.contractFn().toXDR("base64") !== ic.toXDR("base64")) {
    fail("the authorization is not for this call");
  }
  const subs = root.subInvocations();
  if (name !== "collect") {
    if (subs.length) fail("the authorization covers more than this call");
    return;
  }
  // collect's only sub-authorization: usdc.transfer(collector, moments-v2, gross ≤ max_total).
  const pull = subs.length === 1 ? subs[0] : null;
  const fn = pull?.function();
  if (!pull || !fn || fn.switch() !== xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn() || pull.subInvocations().length) {
    fail("the authorization covers more than this call");
  }
  const transfer = fn.contractFn();
  const a = transfer.args();
  const amount = a.length === 3 ? intOf(a[2], "scvI128") : null;
  const ok = Address.fromScAddress(transfer.contractAddress()).toString() === ctx.usdc &&
    transfer.functionName().toString() === "transfer" &&
    addrOf(a[0]) === ctx.user &&
    addrOf(a[1]) === ctx.contract &&
    amount !== null &&
    amount <= BigInt(intent.spend[ctx.usdc] ?? "0");
  if (!ok) fail("the transaction spends more than this action declares");
}

/** `built`, after its own check against the v2 call rules: a builder bug never reaches the phone (plans.ts runs the
 *  verifier too). */
function checked(built: BuiltTx, user: string, contract: string, net: NetworkConfig): BuiltTx {
  try {
    verifyMomentsV2Call(built.tx, built.intent, { user, contract, usdc: usdcOf(net).contract });
  } catch (err) {
    if (!(err instanceof VerifyError)) throw err;
    console.error("self-check failed", built.intent.kind, err.message);
    throw new ApiError(500, "self_check_failed", "We built a transaction that didn't pass our own checks. Nothing was sent.", { reason: err.message });
  }
  return built;
}

// ------------------------------------------------------------------------------------------------ plans

export type MomentV2Action = "publish" | "collect" | "claim" | "claim_all" | "withdraw" | "graduate" | "expire";

/** The plan and intent kind of each action, as the phone and Recent Activity know them. */
export const PLAN_KINDS: Record<MomentV2Action, string> = {
  publish: "moment_publish",
  collect: "moment_collect",
  claim: "moment_claim",
  claim_all: "moment_claim_all",
  withdraw: "moment_withdraw",
  graduate: "moment_graduate",
  expire: "moment_expire",
};

/** The builder each step names: apart from v1's (moments.ts registers moment_publish and moment_collect). */
export const SPEC_KINDS: Record<MomentV2Action, string> = {
  publish: "moment_v2_publish",
  collect: "moment_v2_collect",
  claim: "moment_v2_claim",
  claim_all: "moment_v2_claim_all",
  withdraw: "moment_v2_withdraw",
  graduate: "moment_v2_graduate",
  expire: "moment_v2_expire",
};

/** The terms a publish binds, read as they stand (terms() and config()'s pauses), checked against the deployment's
 *  pins: the durations value by value, the graduator, executor and locker, and the NFT and coin WASM hashes. A
 *  contract whose terms the phone's pins would refuse is refused here first (503 not_deployed). */
export async function liveTermsV2(contract: string, net: NetworkConfig): Promise<{ terms: MomentsV2Terms; publishingPaused: boolean; guardianPaused: boolean }> {
  const [cfg, t] = await Promise.all([view(contract, "config"), view(contract, "terms")]);
  const terms = termsOf(t);
  const dep = net.deploymentV2!;
  const pinned = pinnedDurations(net);
  const differs = [
    ...Object.keys(pinned).filter((k) => terms.durations[k as keyof MomentsV2Durations] !== pinned[k as keyof MomentsV2Durations]).map((k) => `durations.${k}`),
    ...(terms.graduator !== net.contracts.momentsGraduator ? ["graduator"] : []),
    ...(terms.executor !== net.contracts.execSoroswap ? ["executor"] : []),
    ...(terms.locker !== net.contracts.lpLocker ? ["locker"] : []),
    ...(terms.nftWasmHash !== dep.runtimeWasmHashes.momentNft ? ["nftWasmHash"] : []),
    ...(terms.coinWasmHash !== dep.runtimeWasmHashes.momentCoin ? ["coinWasmHash"] : []),
  ];
  if (differs.length) {
    throw new ApiError(503, "not_deployed", "The Moments contract's terms don't match this deployment. Publishing is off until they do.", { differs });
  }
  return { terms, publishingPaused: cfg.publishing_paused === true, guardianPaused: cfg.guardian_paused === true };
}

/** Refuses a publish the terms wouldn't take, before anyone signs: a pause, a price outside [minimum, ceiling], an
 *  allocation above the policy's maximum, a window outside the durations'. */
export function checkPublishV2(live: { terms: MomentsV2Terms; publishingPaused: boolean; guardianPaused: boolean }, price: bigint, allocationBps: number, windowSecs: number): void {
  const p = live.terms.policy;
  const d = live.terms.durations;
  if (live.publishingPaused || live.guardianPaused) throw refusalV2("PublishingPaused");
  if (price < BigInt(p.minPrice)) {
    throw refusalV2("PriceTooLow", { minPrice: p.minPrice, quoteCode: "USDC" }, `The price is below the minimum (${fromStroops(p.minPrice)} USDC).`);
  }
  const ceiling = completionGross(BigInt(p.threshold), p.reserveBps);
  if (price > ceiling) {
    throw refusalV2("PriceTooHigh", { maxPrice: ceiling.toString(), quoteCode: "USDC" }, `The price is above the most a Moment can ask (${fromStroops(ceiling)} USDC).`);
  }
  if (allocationBps > p.maxCreatorAllocBps) throw bad("bad_arg", `Creator allocation: 0–${p.maxCreatorAllocBps / 100}%.`);
  if (windowSecs < d.minWindow || windowSecs > d.maxWindow) {
    throw bad("bad_window", `Collect window: ${spanText(d.minWindow)} to ${spanText(d.maxWindow)}.`);
  }
}

/** "1 hour", "30 days", "2 minutes". */
function spanText(secs: number): string {
  const [n, unit] = secs % 86_400 === 0 ? [secs / 86_400, "day"] : secs % 3_600 === 0 ? [secs / 3_600, "hour"] : [Math.round(secs / 60), "minute"];
  return `${n} ${unit}${n === 1 ? "" : "s"}`;
}

const enc = new TextEncoder();

/** A provenance text: at most `max` UTF-8 bytes (the contract counts bytes). */
function provenanceText(v: unknown, what: string, max: number): string {
  const t = typeof v === "string" ? v : "";
  if (enc.encode(t).length > max) throw bad("bad_arg", `${what}: at most ${max} bytes. Accented letters and emoji count as more than one.`);
  return t;
}

/** "2026-10-14", however the driver handed the day over; "" for none. */
function dayText(v: unknown): string {
  if (v === null || v === undefined) return "";
  return (v instanceof Date ? v.toISOString() : String(v)).slice(0, 10);
}

function wholeArg(v: unknown, code: string, message: string, min: number, max: number): number {
  const n = typeof v === "number" ? v : typeof v === "string" && /^[0-9]+$/.test(v) ? Number(v) : NaN;
  if (!Number.isSafeInteger(n) || n < min || n > max) throw bad(code, message);
  return n;
}

/** A random 64-bit nonce: the NFT's address derives from the creator and it (§9.2, L15), so it never comes from a
 *  counter. */
export function randomNonce(): bigint {
  return crypto.getRandomValues(new BigUint64Array(1))[0];
}

/** SHA-256 of a Moment's media, the NFT's provenance, read from our storage (the metadata only names our own uploads). */
async function mediaHash(url: string, maxBytes: number): Promise<string> {
  const unavailable = () => new ApiError(503, "storage_unavailable", "The Moment's media couldn't be read just now. Try again.");
  let res: Response;
  try {
    res = await fetch(url);
  } catch {
    throw unavailable();
  }
  if (!res.ok) {
    await res.body?.cancel();
    throw unavailable();
  }
  const body = new Uint8Array(await res.arrayBuffer());
  if (body.length === 0 || body.length > maxBytes) throw bad("bad_media", "The Moment's media is empty or too large.");
  return hexOf(new Uint8Array(await crypto.subtle.digest("SHA-256", body)));
}

/** A user-paid trust step for USDC when `user` has no USDC trustline: a creator needs one to withdraw its proceeds. */
async function usdcTrustStep(user: string, net: NetworkConfig): Promise<Steps> {
  const usdc = usdcOf(net);
  const account = await classicBalances(user);
  if (!account || !usdc.classic || account.balances.some((b) => b.asset === usdc.classic)) return [];
  return [{ label: "Enable USDC", spec: { kind: "trust", asset: usdc.classic } }];
}

async function publishSteps(user: string, input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  // The inputs that need no reads first, with clear errors: the contracts refuse the same, later and less clearly.
  const symbol = launchSymbol(input.symbol);
  if (input.name !== undefined) launchName(input.name);
  const price = amountArg(input.price, "price");
  const allocationBps = wholeArg(input.allocationBps ?? 0, "bad_arg", "Creator allocation: a whole number of basis points.", 0, 10_000);
  const windowSecs = wholeArg(input.windowSecs ?? 86_400, "bad_window", "Collect window: a whole number of seconds.", 1, Number.MAX_SAFE_INTEGER);
  const uri = typeof input.uri === "string" ? input.uri : "";
  if (!uri || uri.length > net.limits.uriMax) throw bad("bad_uri", "Create the metadata through DyorHQ first.");

  const contract = momentsV2Id(net);
  const rows = await sql()`select title, place, taken_on, media_type, media_url from lite.moment_metadata where uri = ${uri} and address = ${user}`;
  if (rows.length === 0) throw bad("bad_uri", "Create the metadata through DyorHQ first.");
  const meta = rows[0];
  const name = launchName(input.name ?? meta.title);
  const place = provenanceText(meta.place ?? "", "Place", 64);
  const date = dayText(meta.taken_on);
  const media = ownUpload(meta.media_url, user, meta.media_type === "video" ? "video" : "image");
  if (!media) throw bad("bad_media", "Upload the media through DyorHQ first.");

  const live = await liveTermsV2(contract, net);
  checkPublishV2(live, price, allocationBps, windowSecs);
  const hash = await mediaHash(media, net.limits.uploadBytes);
  const nonce = randomNonce();
  const nft = String(await view(contract, "nft_address", [sv.addr(user), sv.u64(nonce)]));
  const coin = String(await view(live.terms.graduator, "coin_address", [sv.addr(nft)]));
  return [
    ...(await usdcTrustStep(user, net)),
    {
      label: `Publish ${symbol}`,
      spec: { kind: SPEC_KINDS.publish, uri, name, symbol, price: price.toString(), allocationBps, windowSecs, place, date, mediaHash: hash, nonce: nonce.toString(), nft, coin },
    },
  ];
}

async function collectSteps(input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  const nft = nftArg(input.nft);
  const qty = wholeArg(input.quantity ?? 1, "bad_quantity", `Collect 1–${MAX_BATCH} at a time.`, 1, Math.min(MAX_BATCH, net.limits.collectMax));
  const contract = momentsV2Id(net);
  // Priced exactly as it would settle now: the collect that completes the Moment pulls only what the reserve needs.
  const q = await refusing(() => view(contract, "quote", [sv.addr(nft), sv.u32(qty)]));
  const editions = whole(q.editions);
  return [{
    label: `Collect ${editions}`,
    spec: { kind: SPEC_KINDS.collect, nft, quantity: qty, maxTotal: units(q.gross), editions, entitlement: units(q.entitlement), terminal: q.terminal === true },
  }];
}

async function claimSteps(user: string, input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  const nft = nftArg(input.nft);
  const contract = momentsV2Id(net);
  const [{ m }, due] = await Promise.all([readMoment(contract, nft), refusing(() => view(contract, "claimable", [sv.addr(nft), sv.addr(user)]))]);
  const collector = big(due[0]);
  const creator = big(due[1]);
  if (collector + creator === 0n) throw refusalV2("NothingToClaim");
  return [{ label: "Claim coins", spec: { kind: SPEC_KINDS.claim, nft, coin: m.coin, collector: collector.toString(), creator: creator.toString() } }];
}

async function claimAllSteps(user: string, input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  const list = input.nfts;
  if (!Array.isArray(list) || list.length === 0 || list.length > MAX_CLAIM_IDS) {
    throw bad("bad_arg", `nfts: the Moments to claim from, 1 to ${MAX_CLAIM_IDS} at a time.`);
  }
  const nfts = [...new Set(list.map(nftArg))];
  const contract = momentsV2Id(net);
  // claim_all skips the Moments with nothing due; leaving them out keeps the transaction small.
  const dues = await Promise.all(nfts.map((nft) => refusing(() => view(contract, "claimable", [sv.addr(nft), sv.addr(user)]))));
  const totals = dues.map((d) => big(d[0]) + big(d[1]));
  const due = nfts.filter((_, i) => totals[i] > 0n);
  if (due.length === 0) throw refusalV2("NothingToClaim");
  const total = totals.reduce((a, b) => a + b, 0n);
  return [{ label: `Claim coins from ${due.length} ${due.length === 1 ? "Moment" : "Moments"}`, spec: { kind: SPEC_KINDS.claim_all, nfts: due, total: total.toString() } }];
}

async function withdrawSteps(user: string, input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  const nft = nftArg(input.nft);
  const { m, l } = await readMoment(momentsV2Id(net), nft);
  if (m.creator !== user) throw bad("bad_arg", "Only the Moment's creator can withdraw its proceeds.");
  if (l.creatorClaimable === 0n) throw refusalV2("NothingToWithdraw");
  return [
    ...(await usdcTrustStep(user, net)),
    { label: "Withdraw proceeds", spec: { kind: SPEC_KINDS.withdraw, nft, amount: l.creatorClaimable.toString() } },
  ];
}

async function graduateSteps(input: MomentV2BuildRequest, net: NetworkConfig): Promise<Steps> {
  const nft = nftArg(input.nft);
  const contract = momentsV2Id(net);
  const { m, l } = await readMoment(contract, nft);
  if (l.state !== "graduation_pending") throw refusalV2("WrongState", {}, "This Moment isn't waiting to graduate.");
  const outcome = await graduationOutcome(contract, nft);
  if (outcome.kind === "aborted") {
    // Nothing would be recorded, so nothing is offered: the Moment can expire at the time its status gives.
    const at = expiryOf(m, l, pinnedDurations(net)).at!;
    throw new ApiError(422, "simulation_failed", `This Moment's graduation can't run, and the attempt can't be recorded. It can expire from ${isoAt(at)}.`, {
      contractCode: "moment.graduation_aborted",
      expiresAt: isoAt(at),
    });
  }
  return [{
    label: "Graduate Moment",
    spec: {
      kind: SPEC_KINDS.graduate,
      nft,
      outcome: outcome.kind,
      ...(outcome.kind === "failed" ? { origin: outcome.origin, code: outcome.code } : {}),
    },
  }];
}

async function expireSteps(input: MomentV2BuildRequest, net: NetworkConfig, now: number): Promise<Steps> {
  const nft = nftArg(input.nft);
  const { m, l } = await readMoment(momentsV2Id(net), nft);
  if (l.state === "graduated" || l.state === "expired") throw refusalV2("WrongState", {}, `This Moment has ${l.state === "graduated" ? "graduated" : "expired already"}.`);
  const d = pinnedDurations(net);
  const e = expiryOf(m, l, d);
  const nowSecs = Math.floor(now / 1000);
  if (e.at === null || nowSecs < e.at) {
    throw refusalV2("NotExpirable", e.at === null ? {} : { expiresAt: isoAt(e.at) }, e.at === null ? undefined : `This Moment can expire from ${isoAt(e.at)}.`);
  }
  const creatorShare = (l.reserve * BigInt(m.expiryCreatorBps)) / BPS;
  return [{
    label: "Expire Moment",
    spec: {
      kind: SPEC_KINDS.expire,
      nft,
      backstop: expiresByBackstop(l, d, nowSecs),
      reserve: l.reserve.toString(),
      creatorShare: creatorShare.toString(),
      treasuryShare: (l.reserve - creatorShare).toString(),
    },
  }];
}

/** The steps of a v2 Moments action, and the plan's kind. */
export async function momentV2Steps(user: string, input: MomentV2BuildRequest, net: NetworkConfig = env.network, now: number = Date.now()): Promise<{ kind: string; steps: Steps }> {
  const action = input.action as MomentV2Action;
  if (typeof action !== "string" || !Object.hasOwn(PLAN_KINDS, action)) throw bad("bad_action", "Unknown action.");
  const kind = PLAN_KINDS[action];
  switch (action) {
    case "publish":
      return { kind, steps: await publishSteps(user, input, net) };
    case "collect":
      return { kind, steps: await collectSteps(input, net) };
    case "claim":
      return { kind, steps: await claimSteps(user, input, net) };
    case "claim_all":
      return { kind, steps: await claimAllSteps(user, input, net) };
    case "withdraw":
      return { kind, steps: await withdrawSteps(user, input, net) };
    case "graduate":
      return { kind, steps: await graduateSteps(input, net) };
    case "expire":
      return { kind, steps: await expireSteps(input, net, now) };
  }
}

/** POST /v1/moments/build for v2 (CT-18 routes it): a plan for one action on a Moment, keyed by its NFT address. */
export async function buildMomentV2(user: string, input: MomentV2BuildRequest, net: NetworkConfig = env.network): Promise<PlanView> {
  const { kind, steps } = await momentV2Steps(user, input, net);
  return await createPlan(user, kind, steps);
}

// ------------------------------------------------------------------------------------------------ builders

/** Publish: the creator's params with a random nonce, and the terms as they stand when the step is built, by value.
 *  The intent displays every term (the phone's terms guard compares them with what it showed) and the NFT address the
 *  Moment gets. */
export async function momentPublishStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const symbol = launchSymbol(spec.symbol);
  const live = await liveTermsV2(contract, net);
  checkPublishV2(live, BigInt(String(spec.price)), Number(spec.allocationBps), Number(spec.windowSecs));
  const params: MomentV2PublishParams = {
    name: String(spec.name),
    symbol,
    metadataUri: String(spec.uri),
    mediaHash: String(spec.mediaHash),
    place: String(spec.place ?? ""),
    date: String(spec.date ?? ""),
    price: String(spec.price),
    allocationBps: Number(spec.allocationBps),
    windowSecs: Number(spec.windowSecs),
    nonce: String(spec.nonce),
  };
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "publish", [sv.addr(user), publishParamsScVal(params), termsScVal(live.terms)]));
  const p = live.terms.policy;
  const threshold = BigInt(p.threshold);
  const intent: Intent = {
    kind: PLAN_KINDS.publish,
    summary: `Publish ${params.name} ($${symbol}) at ${fromStroops(params.price)} USDC an edition`,
    spend: {},
    calls: [{ contract, fn: "publish" }],
    display: {
      generation: 2,
      nft: String(spec.nft),
      coin: String(spec.coin),
      name: params.name,
      symbol,
      uri: params.metadataUri,
      mediaHash: params.mediaHash,
      place: params.place,
      date: params.date,
      price: params.price,
      quote: "USDC",
      allocationBps: params.allocationBps,
      windowSecs: params.windowSecs,
      nonce: params.nonce,
      completionGross: completionGross(threshold, p.reserveBps).toString(),
      fdvAtOpen: fdvAtOpen(threshold, p.reserveBps, params.allocationBps).toString(),
      ...termsDisplay(live.terms),
    },
  };
  return checked({ tx, intent, stepKind: "moment_publish" }, user, contract, net);
}

/** Collect: at most `maxTotal` USDC, the quote's gross, which the intent spends in USDC and nothing else. */
export async function momentCollectStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const usdc = usdcOf(net);
  const nft = nftArg(spec.nft);
  const qty = Number(spec.quantity);
  const maxTotal = String(spec.maxTotal);
  const acct = await requireAccount(user);
  // The collector is the user: the editions are minted to them, the coins promised to them, and they pay.
  const tx = await refusing(() => invoke(acct, contract, "collect", [sv.addr(user), sv.addr(nft), sv.u32(qty), sv.i128(maxTotal)]));
  const intent: Intent = {
    kind: PLAN_KINDS.collect,
    summary: `Collect ${spec.editions ?? qty} for ${fromStroops(maxTotal)} USDC`,
    spend: { [usdc.contract]: maxTotal },
    calls: [{ contract, fn: "collect" }],
    display: {
      generation: 2,
      nft,
      quantity: qty,
      editions: Number(spec.editions ?? qty),
      total: maxTotal,
      quote: "USDC",
      entitlement: spec.entitlement === undefined ? null : String(spec.entitlement),
      terminal: spec.terminal === true,
    },
  };
  return checked({ tx, intent, stepKind: "moment_collect" }, user, contract, net);
}

/** Claim: the user's vested coins of one Moment, minted to them. The coin is SEP-41: no trustline step. */
export async function momentClaimStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const nft = nftArg(spec.nft);
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "claim", [sv.addr(user), sv.addr(nft)]));
  const collector = String(spec.collector ?? "0");
  const creator = String(spec.creator ?? "0");
  const total = (BigInt(collector) + BigInt(creator)).toString();
  const intent: Intent = {
    kind: PLAN_KINDS.claim,
    summary: `Claim ${fromStroops(total)} vested coins`,
    spend: {},
    calls: [{ contract, fn: "claim" }],
    display: { generation: 2, nft, coin: spec.coin === undefined ? null : String(spec.coin), collectorAmount: collector, creatorAmount: creator, total },
  };
  return checked({ tx, intent }, user, contract, net);
}

/** Claim all: the user's vested coins of up to 20 Moments in one call. */
export async function momentClaimAllStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const nfts = (spec.nfts as unknown[]).map(nftArg);
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "claim_all", [sv.addr(user), sv.vec(nfts.map((n) => sv.addr(n)))]));
  const total = String(spec.total ?? "0");
  const intent: Intent = {
    kind: PLAN_KINDS.claim_all,
    summary: `Claim ${fromStroops(total)} vested coins from ${nfts.length} ${nfts.length === 1 ? "Moment" : "Moments"}`,
    spend: {},
    calls: [{ contract, fn: "claim_all" }],
    display: { generation: 2, moments: nfts.length, nfts: nfts.join(","), total },
  };
  return checked({ tx, intent }, user, contract, net);
}

/** Withdraw: the Moment's creator's USDC, paid to the creator the Moment snapshotted. Anyone may call it. */
export async function momentWithdrawStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const nft = nftArg(spec.nft);
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "withdraw_creator", [sv.addr(nft)]));
  const amount = String(spec.amount ?? "0");
  const intent: Intent = {
    kind: PLAN_KINDS.withdraw,
    summary: `Withdraw ${fromStroops(amount)} USDC of proceeds`,
    spend: {},
    calls: [{ contract, fn: "withdraw_creator" }],
    display: { generation: 2, nft, amount, quote: "USDC", to: user },
  };
  return checked({ tx, intent }, user, contract, net);
}

/** Graduate: one attempt, anyone's to make. The intent says what the simulation found: the Moment graduates, or the
 *  attempt records a failure (named, finding V10), which starts its stuck clock. */
export async function momentGraduateStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const nft = nftArg(spec.nft);
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "graduate", [sv.addr(nft)]));
  const failed = spec.outcome === "failed";
  const failure = failed ? namedFailure(Number(spec.origin), Number(spec.code), "simulated") : null;
  const intent: Intent = {
    kind: PLAN_KINDS.graduate,
    summary: failed ? "Record a failed graduation attempt" : "Graduate the Moment",
    spend: {},
    calls: [{ contract, fn: "graduate" }],
    display: {
      generation: 2,
      nft,
      outcome: failed ? "failed" : "graduated",
      failureOrigin: failure?.origin ?? null,
      failureCode: failure?.code ?? null,
      failureName: failure?.name ?? null,
    },
  };
  return checked({ tx, intent }, user, contract, net);
}

/** Expire: winds a Moment down once the rules allow; the reserve goes to its creator and treasury. Anyone may call it. */
export async function momentExpireStep(user: string, spec: StepSpec, net: NetworkConfig = env.network): Promise<BuiltTx> {
  const contract = momentsV2Id(net);
  const nft = nftArg(spec.nft);
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, contract, "expire", [sv.addr(nft)]));
  const intent: Intent = {
    kind: PLAN_KINDS.expire,
    summary: "Expire the Moment",
    spend: {},
    calls: [{ contract, fn: "expire" }],
    display: {
      generation: 2,
      nft,
      backstop: spec.backstop === true,
      reserve: String(spec.reserve ?? "0"),
      creatorShare: String(spec.creatorShare ?? "0"),
      treasuryShare: String(spec.treasuryShare ?? "0"),
      quote: "USDC",
    },
  };
  return checked({ tx, intent }, user, contract, net);
}

registerBuilder(SPEC_KINDS.publish, (user, spec) => momentPublishStep(user, spec));
registerBuilder(SPEC_KINDS.collect, (user, spec) => momentCollectStep(user, spec));
registerBuilder(SPEC_KINDS.claim, (user, spec) => momentClaimStep(user, spec));
registerBuilder(SPEC_KINDS.claim_all, (user, spec) => momentClaimAllStep(user, spec));
registerBuilder(SPEC_KINDS.withdraw, (user, spec) => momentWithdrawStep(user, spec));
registerBuilder(SPEC_KINDS.graduate, (user, spec) => momentGraduateStep(user, spec));
registerBuilder(SPEC_KINDS.expire, (user, spec) => momentExpireStep(user, spec));
