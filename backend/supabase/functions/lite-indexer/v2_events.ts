// Contracts v2 in the indexer (docs/DESIGN-stellar-contracts-v2.md §20.5), and the cursors of both generations.
// - Generations. Each generation reads its contracts' events with a cursor of its own, kept with the key of the
//   contracts it describes. v1 (retired) keeps the "events" cursor: a different v1 deployment clears v1's rows only
//   (its Moments are numbered per contract, and one v1 Moments contract is kept per database). v2 (live) has
//   "events_v2": its rows are keyed by address (launches by token, Moments by NFT, L15), so another v2 deployment only
//   starts the cursor at its own deploy ledger and clears nothing. Only a testnet reset (the ledger going backwards)
//   still clears every generation, since the chain did.
// - v2's main filter: launchpad-v2, moments-v2 (and on testnet-qa its failing stack, whose Moments carry that
//   contract and are never listed, F5), the lp-locker, the Soroswap factory and the Aquarius router (its add_pool
//   only). Factory and router events only find other pools of sharing launches (pool_candidates, L5, F2), whether or
//   not Aquarius is a graduation venue.
// - Decoding is pure (decode*), from the events' topics and data as scValToNative gives them. Recording is once per
//   event: lite.v2_events takes each event id once, and every effect moves with that insert in one transaction, so a
//   page read twice changes nothing.
// - Watched per-launch and per-Moment contracts (watchV2): launch tokens' reward, exclusion and unlock events (their
//   SEP-41 events and their pools' are read by jobs/watch.ts, which the launch handler registers them with), Moment
//   NFTs' mint, transfer and closed, and graduated Moments' coins. Groups of up to 25 contracts, one cursor each.
import type postgres from "postgres";
import type { rpc } from "@stellar/stellar-sdk";
import { sql, tableExists } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { ratio, SOROSWAP_POOL_FEE_BPS } from "../_shared/launchpad.ts";
import { localMediaEnabled, readLocal } from "../_shared/localmedia.ts";
import { mediaBase } from "../_shared/media.ts";
import { type MomentMetadataFields, takenParts, takenText } from "../_shared/moments.ts";
import type { NetworkConfig } from "../_shared/networks.ts";
import { native, rpcServer, sv, view, xdr } from "../_shared/stellar.ts";
import { errorName } from "../_shared/v2_errors.ts";
import { launchFacts, pairSide, watchContract } from "./handlers/launchpad.ts";
import { decodeMove, metadataFromJson } from "./handlers/moments.ts";
import { cursorLedger, deploymentKey, handle as handleV1, streamStart } from "./jobs/main_events.ts";
import { clearIndexed, resetAllowed } from "./jobs/reset.ts";
import { CAUGHT_UP_LEDGERS, decodeTokenEvent, GROUP_SIZE, ledgerOf, mergeGroups, type Position, RETENTION_MARGIN } from "./jobs/watch.ts";
import { fireAlert, gradFailAlert, venueKindName } from "./v2_keeper.ts";

type Event = rpc.Api.EventResponse;
type Sql = postgres.Sql | postgres.TransactionSql;

/** A decoder's input: the event's topics and data, decoded to native values. */
export interface Decodable {
  topics: any[];
  data: any;
}

const big = (v: unknown): bigint => BigInt(v as bigint | number | string);
const text = (v: unknown): string => String(v);
/** A contract time in seconds as a date; 0 (not set) as null. */
export function timeOf(secs: unknown): Date | null {
  const n = Number(secs ?? 0);
  return n > 0 ? new Date(n * 1000) : null;
}

// ------------------------------------------------------------------------------------------------ launchpad-v2

export interface LaunchedV2 {
  token: string;
  creator: string;
  quote: string;
  name: string;
  symbol: string;
  uri: string;
  nonce: bigint;
  supply: bigint;
  phantom: bigint;
  threshold: bigint;
  feeBps: number;
  protocolShareBps: number;
  creatorFeeBps: number;
  venue: number;
  fallbackVenue: number;
  venueLocked: boolean;
  holderSharing: boolean;
  recipient: string;
  launchFee: bigint;
}

/** launch [launch, token, creator] {quote, name, symbol, uri, nonce, supply, phantom, threshold, fee_bps,
 *  protocol_share_bps, creator_fee_bps, venue, fallback_venue, venue_locked, holder_sharing, recipient, launch_fee}. */
export function decodeLaunchV2({ topics, data }: Decodable): LaunchedV2 {
  return {
    token: text(topics[1]),
    creator: text(topics[2]),
    quote: text(data.quote),
    name: text(data.name),
    symbol: text(data.symbol),
    uri: text(data.uri ?? ""),
    nonce: big(data.nonce),
    supply: big(data.supply),
    phantom: big(data.phantom),
    threshold: big(data.threshold),
    feeBps: Number(data.fee_bps),
    protocolShareBps: Number(data.protocol_share_bps),
    creatorFeeBps: Number(data.creator_fee_bps),
    venue: Number(data.venue),
    fallbackVenue: Number(data.fallback_venue),
    venueLocked: data.venue_locked === true,
    holderSharing: data.holder_sharing === true,
    recipient: text(data.recipient),
    launchFee: big(data.launch_fee),
  };
}

/** fee_booked [fee_booked, token, payer] {asset, amount}: the launch fee, booked on the launch (O6). */
export function decodeFeeBooked({ topics, data }: Decodable) {
  return { token: text(topics[1]), payer: text(topics[2]), asset: text(data.asset), amount: big(data.amount) };
}

export interface TradedV2 {
  token: string;
  trader: string;
  side: "buy" | "sell";
  quoteAmount: bigint;
  tokenAmount: bigint;
  /** The curve fee, the snipe tax and the creator fee. */
  fees: bigint;
  protocolPart: bigint;
  creatorPart: bigint;
  holderPart: bigint;
  quoteReserve: bigint;
  tokenReserve: bigint;
  realQuote: bigint;
  /** The curve's price after the trade: quote reserve / token reserve. */
  price: string;
}

/** trade [trade, token, trader] {is_buy, quote_amount, token_amount, base_fee, snipe_fee, creator_fee, protocol_part,
 *  creator_part, holder_part, quote_reserve, token_reserve, real_quote}. */
export function decodeTradeV2({ topics, data }: Decodable): TradedV2 {
  const quoteReserve = big(data.quote_reserve);
  const tokenReserve = big(data.token_reserve);
  return {
    token: text(topics[1]),
    trader: text(topics[2]),
    side: data.is_buy === true ? "buy" : "sell",
    quoteAmount: big(data.quote_amount),
    tokenAmount: big(data.token_amount),
    fees: big(data.base_fee) + big(data.snipe_fee) + big(data.creator_fee),
    protocolPart: big(data.protocol_part),
    creatorPart: big(data.creator_part),
    holderPart: big(data.holder_part),
    quoteReserve,
    tokenReserve,
    realQuote: big(data.real_quote),
    price: ratio(quoteReserve, tokenReserve),
  };
}

/** complete [complete, token] {real_quote, completed_at}. */
export function decodeCompleteV2({ topics, data }: Decodable) {
  return { token: text(topics[1]), realQuote: big(data.real_quote), completedAt: timeOf(data.completed_at) };
}

export interface GraduatedV2 {
  token: string;
  venue: number;
  pool: string;
  poolTokens: bigint;
  poolQuote: bigint;
  liquidity: bigint;
  burned: bigint;
  /** Through graduate_fallback. */
  fallback: boolean;
  /** The pool's opening price: pool quote / pool tokens. */
  price: string;
}

/** grad_ok [grad_ok, token] {venue, pool, pool_tokens, pool_quote, liquidity, burned, fallback}. */
export function decodeGradOkV2({ topics, data }: Decodable): GraduatedV2 {
  const poolTokens = big(data.pool_tokens);
  const poolQuote = big(data.pool_quote);
  return {
    token: text(topics[1]),
    venue: Number(data.venue),
    pool: text(data.pool),
    poolTokens,
    poolQuote,
    liquidity: big(data.liquidity),
    burned: big(data.burned),
    fallback: data.fallback === true,
    price: ratio(poolQuote, poolTokens),
  };
}

/** A recorded graduation failure: the namespaced pair and its name from _shared/v2_errors.ts (V10). */
export interface Failure {
  origin: number;
  code: number;
  /** Null for a pair the table doesn't know. */
  name: string | null;
}

export interface LaunchGradFailed extends Failure {
  token: string;
  venue: number;
  stuckSince: Date | null;
  /** When graduate_fallback opens (F14). */
  fallbackAt: Date | null;
}

/** grad_fail [grad_fail, token] {venue, origin, code, stuck_since, fallback_at}. */
export function decodeLaunchGradFail({ topics, data }: Decodable): LaunchGradFailed {
  const origin = Number(data.origin);
  const code = Number(data.code);
  return {
    token: text(topics[1]),
    venue: Number(data.venue),
    origin,
    code,
    name: errorName(origin, code),
    stuckSince: timeOf(data.stuck_since),
    fallbackAt: timeOf(data.fallback_at),
  };
}

/** stuck [stuck, token] stuck_since. */
export function decodeStuck({ topics, data }: Decodable) {
  return { token: text(topics[1]), stuckSince: timeOf(data) };
}

/** rescued [rescued, token] {stuck_since, by_admin, refund_quote, refund_supply, burned}. */
export function decodeRescued({ topics, data }: Decodable) {
  return {
    token: text(topics[1]),
    byAdmin: data.by_admin === true,
    refundQuote: big(data.refund_quote),
    refundSupply: big(data.refund_supply),
    burned: big(data.burned),
  };
}

/** refund [refund, token, holder] {tokens_in, quote_out}. */
export function decodeRefund({ topics, data }: Decodable) {
  return { token: text(topics[1]), holder: text(topics[2]), tokensIn: big(data.tokens_in), quoteOut: big(data.quote_out) };
}

/** cr_claim [cr_claim, token, recipient] amount; cr_owed [cr_owed, token, old_recipient] amount. */
export function decodeCreatorFees({ topics, data }: Decodable) {
  return { token: text(topics[1]), account: text(topics[2]), amount: big(data) };
}

/** owed_claim [owed_claim, account, asset] amount (launchpad-v2); owed_paid [owed_paid, to, asset] {amount} and
 *  owed_credit [owed_credit, to, asset] {amount, owed} (the locker). `owed` is the total owed after a credit. */
export function decodeOwed({ topics, data }: Decodable) {
  const amount = typeof data === "object" && data !== null ? big(data.amount) : big(data);
  const owed = typeof data === "object" && data !== null && data.owed !== undefined ? big(data.owed) : null;
  return { account: text(topics[1]), asset: text(topics[2]), amount, owed };
}

/** pr_claim [pr_claim, token] {treasury, quote_amount, launch_fee_amount}. */
export function decodeProtocolClaim({ topics, data }: Decodable) {
  return { token: text(topics[1]), treasury: text(data.treasury), quoteAmount: big(data.quote_amount), launchFeeAmount: big(data.launch_fee_amount) };
}

/** recip_set [recip_set, token] {old, new, by_takeover}; recip_prop [recip_prop, token] {new, effective_at, expires_at}. */
export function decodeRecipient({ topics, data }: Decodable) {
  return {
    token: text(topics[1]),
    recipient: text(data.new),
    effectiveAt: timeOf(data.effective_at),
    expiresAt: timeOf(data.expires_at),
    byTakeover: data.by_takeover === true,
  };
}

// ------------------------------------------------------------------------------------------------ moments-v2

export interface PublishedV2 {
  nft: string;
  creator: string;
  nonce: bigint;
  coin: string;
  name: string;
  symbol: string;
  metadataUri: string;
  price: bigint;
  threshold: bigint;
  creatorAllocBps: number;
  rateNum: bigint;
  rateDen: bigint;
  deadline: Date;
  /** MomentsDurations, in seconds. */
  durations: Record<string, number>;
}

/** publish [publish, nft, creator] {nonce, coin, name, symbol, metadata_uri, price, threshold, creator_alloc_bps,
 *  rate_num, rate_den, deadline, durations}. */
export function decodePublishV2({ topics, data }: Decodable): PublishedV2 {
  const durations = Object.fromEntries(Object.entries((data.durations ?? {}) as Record<string, unknown>).map(([k, v]) => [k, Number(v)]));
  return {
    nft: text(topics[1]),
    creator: text(topics[2]),
    nonce: big(data.nonce),
    coin: text(data.coin),
    name: text(data.name),
    symbol: text(data.symbol),
    metadataUri: text(data.metadata_uri ?? ""),
    price: big(data.price),
    threshold: big(data.threshold),
    creatorAllocBps: Number(data.creator_alloc_bps),
    rateNum: big(data.rate_num),
    rateDen: big(data.rate_den),
    deadline: new Date(Number(data.deadline) * 1000),
    durations,
  };
}

export interface CollectedV2 {
  nft: string;
  collector: string;
  gross: bigint;
  editions: number;
  firstRank: number;
  entitlement: bigint;
  /** The reserve after this collect. */
  reserve: bigint;
}

/** collect [collect, nft, collector] {gross, editions, first_rank, entitlement, reserve_in, creator_in, platform_in,
 *  excess, reserve}. */
export function decodeCollectV2({ topics, data }: Decodable): CollectedV2 {
  return {
    nft: text(topics[1]),
    collector: text(topics[2]),
    gross: big(data.gross),
    editions: Number(data.editions),
    firstRank: Number(data.first_rank),
    entitlement: big(data.entitlement),
    reserve: big(data.reserve),
  };
}

/** complete [complete, nft] {reserve, total_gross, completed_at}. */
export function decodeMomentComplete({ topics, data }: Decodable) {
  return { nft: text(topics[1]), reserve: big(data.reserve), totalGross: big(data.total_gross), completedAt: timeOf(data.completed_at) };
}

/** grad_ok [grad_ok, nft] {coin, pool, lp_token, liquidity, pool_coins, coin_used, usdc_used, usdc_returned}. */
export function decodeMomentGradOk({ topics, data }: Decodable) {
  return {
    nft: text(topics[1]),
    coin: text(data.coin),
    pool: text(data.pool),
    lpToken: text(data.lp_token),
    liquidity: big(data.liquidity),
    poolCoins: big(data.pool_coins),
    usdcUsed: big(data.usdc_used),
  };
}

export interface MomentGradFailed extends Failure {
  nft: string;
  /** The stuck clock the failure started or left running (F15). */
  stuckSince: Date | null;
}

/** grad_fail [grad_fail, nft] {origin, code, stuck_since}. */
export function decodeMomentGradFail({ topics, data }: Decodable): MomentGradFailed {
  const origin = Number(data.origin);
  const code = Number(data.code);
  return { nft: text(topics[1]), origin, code, name: errorName(origin, code), stuckSince: timeOf(data.stuck_since) };
}

export interface ExpiredV2 {
  nft: string;
  reserve: bigint;
  creatorShare: bigint;
  treasuryShare: bigint;
  /** Through pending_backstop, with no recorded failure (V11). */
  backstop: boolean;
}

/** expired [expired, nft] {reserve, creator_share, treasury_share, backstop}. */
export function decodeExpired({ topics, data }: Decodable): ExpiredV2 {
  return {
    nft: text(topics[1]),
    reserve: big(data.reserve),
    creatorShare: big(data.creator_share),
    treasuryShare: big(data.treasury_share),
    backstop: data.backstop === true,
  };
}

/** vest_claim [vest_claim, nft, account] {collector_amount, creator_amount}. */
export function decodeVestClaim({ topics, data }: Decodable) {
  return { nft: text(topics[1]), account: text(topics[2]), collectorAmount: big(data.collector_amount), creatorAmount: big(data.creator_amount) };
}

/** withdrawn [withdrawn, nft, role] {to, amount}: role is creator, platform or treasury. */
export function decodeWithdrawn({ topics, data }: Decodable) {
  return { nft: text(topics[1]), role: text(topics[2]), to: text(data.to), amount: big(data.amount) };
}

// ------------------------------------------------------------------------------------------------ lp-locker

export interface LockRegistered {
  pool: string;
  owner: string;
  /** The VenueKind by name: Soroswap, Aquarius, HoldOnly or QaFail. */
  kind: string;
  lpToken: string;
  lp: bigint;
  base: string;
  quote: string;
  refKind: "launch" | "moment";
  /** The launch token or the Moment's NFT address. */
  ref: string;
  harvestBps: number;
  principal: bigint;
}

/** lock_reg [lock_reg, pool, owner] {kind, lp_token, lp, base, quote, reference, harvest_bps, principal}; kind is the
 *  VenueKind's u32, kept by name; reference is PositionRef::Launch(token) or PositionRef::Moment(nft). */
export function decodeLockReg({ topics, data }: Decodable): LockRegistered {
  const reference = data.reference as unknown[];
  return {
    pool: text(topics[1]),
    owner: text(topics[2]),
    kind: venueKindName(data.kind),
    lpToken: text(data.lp_token),
    lp: big(data.lp),
    base: text(data.base),
    quote: text(data.quote),
    refKind: String(reference[0]) === "Moment" ? "moment" : "launch",
    ref: text(reference[1]),
    harvestBps: Number(data.harvest_bps),
    principal: big(data.principal),
  };
}

export interface Harvested {
  pool: string;
  lpBurned: bigint;
  baseOut: bigint;
  quoteOut: bigint;
  growth: bigint;
  /** What the round harvested, of the √k growth, and what joined the principal. */
  take: bigint;
  compounded: bigint;
  principal: bigint;
}

/** harvested [harvested, pool] {lp_burned, base_out, quote_out, growth, take, compounded, principal}. */
export function decodeHarvested({ topics, data }: Decodable): Harvested {
  return {
    pool: text(topics[1]),
    lpBurned: big(data.lp_burned),
    baseOut: big(data.base_out),
    quoteOut: big(data.quote_out),
    growth: big(data.growth),
    take: big(data.take),
    compounded: big(data.compounded),
    principal: big(data.principal),
  };
}

// ------------------------------------------------------------------------------------------------ launch-token-v2

export type RewardEvent =
  | { kind: "queued"; asset: string; notifier: string; amount: bigint; releasableFrom: number }
  | { kind: "released"; asset: string; amount: bigint; eligible: bigint; acc: bigint }
  | { kind: "to_protocol"; asset: string; amount: bigint; eligible: bigint }
  | { kind: "claimed"; asset: string; holder: string; amount: bigint }
  | { kind: "swept"; asset: string; treasury: string; amount: bigint };

/** A launch token's reward event, in either asset (the quote, or the token itself, F1): rwd_queue [rwd_queue, asset]
 *  {notifier, amount, releasable_from}, rwd_add [rwd_add, asset] {amount, eligible, acc}, rwd_proto [rwd_proto, asset]
 *  {amount, eligible}, rwd_claim [rwd_claim, asset, holder] {amount}, rwd_sweep [rwd_sweep, asset, treasury] {amount}.
 *  Null for any other event. */
export function decodeRewardEvent({ topics, data }: Decodable): RewardEvent | null {
  const asset = text(topics[1]);
  switch (String(topics[0])) {
    case "rwd_queue":
      return { kind: "queued", asset, notifier: text(data.notifier), amount: big(data.amount), releasableFrom: Number(data.releasable_from) };
    case "rwd_add":
      return { kind: "released", asset, amount: big(data.amount), eligible: big(data.eligible), acc: big(data.acc) };
    case "rwd_proto":
      return { kind: "to_protocol", asset, amount: big(data.amount), eligible: big(data.eligible) };
    case "rwd_claim":
      return { kind: "claimed", asset, holder: text(topics[2]), amount: big(data.amount) };
    case "rwd_sweep":
      return { kind: "swept", asset, treasury: text(topics[2]), amount: big(data.amount) };
    default:
      return null;
  }
}

/** excluded [excluded, account] {by_pool, stranded_q, stranded_t}: what the account had earned went to the protocol. */
export function decodeExcluded({ topics, data }: Decodable) {
  return { account: text(topics[1]), byPool: data.by_pool === true, strandedQuote: big(data.stranded_q), strandedToken: big(data.stranded_t) };
}

// ------------------------------------------------------------------------------------------------ pool discovery

export interface NewPool {
  pool: string;
  tokens: string[];
  kind: "soroswap" | "aquarius";
}

/** The Soroswap factory's new_pair [("SoroswapFactory"), new_pair] {token_0, token_1, pair, new_pairs_length}, or the
 *  Aquarius router's add_pool [add_pool, tokens] [pool, pool_type, pool_index, init_args] (contracts/testdata
 *  fixtures.json). Null for any other event of theirs. */
export function decodeNewPool({ topics, data }: Decodable): NewPool | null {
  if (String(topics[0]) === "SoroswapFactory" && String(topics[1]) === "new_pair") {
    return { pool: text(data.pair), tokens: [text(data.token_0), text(data.token_1)], kind: "soroswap" };
  }
  if (String(topics[0]) === "add_pool" && Array.isArray(topics[1]) && Array.isArray(data)) {
    return { pool: text(data[0]), tokens: (topics[1] as unknown[]).map(text), kind: "aquarius" };
  }
  return null;
}

/** The candidates a new pool makes: one per sharing launch among its tokens, with the pool's other token, for a
 *  two-token pool (exclude_pool checks the venue's pool of the pair). */
export function poolCandidates(p: NewPool, sharingLaunches: Set<string>): { token: string; other: string }[] {
  if (p.tokens.length !== 2) return [];
  const [a, b] = p.tokens;
  return [[a, b], [b, a]].filter(([t]) => sharingLaunches.has(t)).map(([token, other]) => ({ token, other }));
}

// ------------------------------------------------------------------------------------------------ keys and filters

export const V1_CURSOR = "events";
export const V2_CURSOR = "events_v2";

/** The Aquarius router's pool-creation topic: its other events (swaps, deposits, every pool's) aren't read. */
const ADD_POOL_TOPIC = xdr.ScVal.scvSymbol("add_pool").toXDR("base64");

/** What v2's indexed rows describe: the network, its v2 singletons and testnet-qa's failing Moments stack. Null where
 *  there is no v2 deployment. */
export function v2Key(net: Pick<NetworkConfig, "passphrase" | "contracts" | "deploymentV2">): string | null {
  const d = net.deploymentV2;
  if (!d) return null;
  return [net.passphrase, d.contracts.launchpadV2, d.contracts.momentsV2, d.contracts.lpLocker, d.qa?.momentsV2QaFail ?? ""].join("|");
}

/** The Moments contracts of v2: the main stack, and on testnet-qa the failing one. */
export function momentsContracts(net: Pick<NetworkConfig, "deploymentV2">): string[] {
  const d = net.deploymentV2;
  if (!d) return [];
  return [d.contracts.momentsV2, ...(d.qa ? [d.qa.momentsV2QaFail] : [])];
}

/** v2's main getEvents filters (at most 5 of 5 contracts): its contracts, the factory, and the router's add_pool. */
export function v2Filters(net: Pick<NetworkConfig, "contracts" | "deploymentV2">): rpc.Api.EventFilter[] {
  const d = net.deploymentV2;
  if (!d) return [];
  const filters: rpc.Api.EventFilter[] = [
    { type: "contract", contractIds: [d.contracts.launchpadV2, ...momentsContracts(net), d.contracts.lpLocker] },
    { type: "contract", contractIds: [net.contracts.soroswapFactory] },
  ];
  if (net.contracts.aquariusRouter) {
    filters.push({ type: "contract", contractIds: [net.contracts.aquariusRouter], topics: [[ADD_POOL_TOPIC, "*"]] });
  }
  return filters;
}

// ------------------------------------------------------------------------------------------------ recording

function contractIdOf(e: Event): string {
  const c = e.contractId as unknown;
  if (!c) return "";
  return typeof c === "string" ? c : typeof (c as { contractId?: unknown }).contractId === "function" ? (c as { contractId(): string }).contractId() : String(c);
}

/** A native value as JSON: big integers as decimal strings. */
export function jsonable(v: unknown): unknown {
  return JSON.parse(JSON.stringify(v ?? null, (_k, x) => (typeof x === "bigint" ? x.toString() : x)));
}

/** Logs `e` in lite.v2_events (as `kind`, its first topic unless said) and, when it is new, applies `effects` in the
 *  same transaction. Answers whether it was new. */
async function once(e: Event, contract: string, d: Decodable, subject: string | null, effects: (tx: Sql) => Promise<unknown>, kind = String(d.topics[0])): Promise<boolean> {
  return await sql().begin(async (tx) => {
    const inserted = await tx`
      insert into lite.v2_events (event_id, contract, kind, subject, topics, data, tx_hash, ledger, ts)
      values (${e.id}, ${contract}, ${kind}, ${subject}, ${tx.json(jsonable(d.topics) as any)}, ${tx.json(jsonable(d.data) as any)},
              ${e.txHash ?? null}, ${e.ledger}, ${new Date(e.ledgerClosedAt)})
      on conflict (event_id) do nothing returning event_id`;
    if (!inserted.length) return false;
    await effects(tx);
    return true;
  }) as boolean;
}

const s = (n: bigint) => n.toString();

type RewardColumn = "funded" | "released" | "to_protocol" | "stranded" | "claimed" | "swept";

/** Adds `delta` to one reward column of (token, asset); a release also sets the reward per share and the eligible
 *  supply after it. */
async function addReward(tx: Sql, token: string, asset: string, column: RewardColumn, delta: bigint, ledger: number, last?: { acc: bigint; eligible: bigint }) {
  if (delta === 0n && !last) return;
  const d = (c: RewardColumn) => (c === column ? s(delta) : "0");
  await tx`
    insert into lite.launch_rewards (token, asset, funded, released, to_protocol, stranded, claimed, swept, acc, eligible, updated_ledger)
    values (${token}, ${asset}, ${d("funded")}, ${d("released")}, ${d("to_protocol")}, ${d("stranded")}, ${d("claimed")}, ${d("swept")},
            ${last ? s(last.acc) : null}, ${last ? s(last.eligible) : null}, ${ledger})
    on conflict (token, asset) do update set funded = lite.launch_rewards.funded + excluded.funded,
      released = lite.launch_rewards.released + excluded.released, to_protocol = lite.launch_rewards.to_protocol + excluded.to_protocol,
      stranded = lite.launch_rewards.stranded + excluded.stranded, claimed = lite.launch_rewards.claimed + excluded.claimed,
      swept = lite.launch_rewards.swept + excluded.swept, acc = coalesce(excluded.acc, lite.launch_rewards.acc),
      eligible = coalesce(excluded.eligible, lite.launch_rewards.eligible),
      updated_ledger = greatest(lite.launch_rewards.updated_ledger, excluded.updated_ledger), updated_at = now()`;
}

/** Moves what `contract` owes `account` in `asset`: + a credit, − a payment; `owed` sets the total (the locker's). */
async function moveOwed(tx: Sql, contract: string, account: string, asset: string, credit: bigint, paid: bigint, ledger: number, owed: bigint | null = null) {
  const total = owed === null ? null : s(owed);
  await tx`
    insert into lite.creator_owed (contract, account, asset, owed, credited, paid, updated_ledger)
    values (${contract}, ${account}, ${asset}, ${total ?? s(credit > paid ? credit - paid : 0n)}, ${s(credit)}, ${s(paid)}, ${ledger})
    on conflict (contract, account, asset) do update set
      owed = coalesce(${total}::numeric, greatest(0, lite.creator_owed.owed + ${s(credit)} - ${s(paid)})),
      credited = lite.creator_owed.credited + excluded.credited, paid = lite.creator_owed.paid + excluded.paid,
      updated_ledger = greatest(lite.creator_owed.updated_ledger, excluded.updated_ledger), updated_at = now()`;
}

async function watchV2Contract(tx: Sql, contract: string, role: "launch_token" | "nft" | "coin", ref: string, fromLedger: number) {
  await tx`insert into lite.watch_v2_contracts (contract, role, ref, from_ledger) values (${contract}, ${role}, ${ref}, ${fromLedger})
           on conflict (contract) do nothing`;
}

/** The kind of the venue with `id` in the v2 deployment's table, or null. */
function venueKind(net: NetworkConfig, id: number): string | null {
  return net.deploymentV2?.venues.find((v) => v.id === id)?.kind ?? null;
}

/** launchpad-v2's events. */
export async function launchpadV2Event(e: Event, d: Decodable, net: NetworkConfig = env.network): Promise<void> {
  const contract = net.deploymentV2!.contracts.launchpadV2;
  const kind = String(d.topics[0]);
  const ts = new Date(e.ledgerClosedAt);
  const subject = d.topics.length > 1 && typeof d.topics[1] === "string" ? d.topics[1] : null;
  switch (kind) {
    case "launch": {
      const l = decodeLaunchV2(d);
      const facts = await launchFacts(l, net);
      await once(e, contract, d, l.token, async (tx) => {
        await tx`
          insert into lite.launches (token, creator, quote, name, symbol, uri, launch_index, supply, phantom, threshold, creator_fee_bps,
                                     quote_reserve, token_reserve, created_ledger, created_at, fee_bps, protocol_share_bps, listed,
                                     look_alike, image_url, description, links, generation, contract, nonce, venue, fallback_venue,
                                     venue_locked, holder_sharing, recipient, launch_fee, phase)
          values (${l.token}, ${l.creator}, ${l.quote}, ${l.name}, ${l.symbol}, ${l.uri}, null, ${s(l.supply)}, ${s(l.phantom)},
                  ${s(l.threshold)}, ${l.creatorFeeBps}, ${s(l.phantom)}, ${s(l.supply)}, ${e.ledger}, ${ts}, ${l.feeBps},
                  ${l.protocolShareBps}, ${facts.listed}, ${facts.lookAlike}, ${facts.image}, ${facts.description},
                  ${facts.links === null ? null : tx.json(facts.links)}, 2, ${contract}, ${s(l.nonce)}, ${l.venue}, ${l.fallbackVenue},
                  ${l.venueLocked}, ${l.holderSharing}, ${l.recipient}, ${s(l.launchFee)}, 'curve')
          on conflict (token) do nothing`;
        // Its SEP-41 events (holders, balances) are jobs/watch.ts's; its rewards events are watchV2's.
        await watchContract(tx as postgres.Sql, l.token, "token", l.token, e.ledger);
        await watchV2Contract(tx, l.token, "launch_token", l.token, e.ledger);
      });
      return;
    }
    case "fee_booked": {
      const f = decodeFeeBooked(d);
      await once(e, contract, d, f.token, (tx) => tx`update lite.launches set launch_fee_due = launch_fee_due + ${s(f.amount)}, updated_at = now() where token = ${f.token}`);
      return;
    }
    case "trade": {
      const t = decodeTradeV2(d);
      await once(e, contract, d, t.token, async (tx) => {
        await tx`
          insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, tx_hash, ledger, ts)
          values (${e.id}, ${t.token}, ${t.trader}, ${t.side}, ${s(t.quoteAmount)}, ${s(t.tokenAmount)}, ${s(t.fees)}, ${t.price},
                  ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`
          update lite.launches set quote_reserve = ${s(t.quoteReserve)}, token_reserve = ${s(t.tokenReserve)}, real_quote = ${s(t.realQuote)},
                 last_price = ${t.price}, volume_quote = volume_quote + ${s(t.quoteAmount)}, trades = trades + 1,
                 last_trade_at = greatest(last_trade_at, ${ts}), protocol_fees_due = protocol_fees_due + ${s(t.protocolPart)},
                 creator_fees_due = creator_fees_due + ${s(t.creatorPart)}, holder_fees_total = holder_fees_total + ${s(t.holderPart)},
                 updated_at = now()
           where token = ${t.token}`;
      });
      return;
    }
    case "complete": {
      // `completed` stays v1's flag: it is what v1's graduation keeper (jobs/graduate.ts) looks for. A v2 launch says
      // where it is with `phase`, and becomes `completed` with its graduation, as a v1 launch does.
      const c = decodeCompleteV2(d);
      await once(e, contract, d, c.token, (tx) => tx`
        update lite.launches set phase = 'completed', completed_at = ${c.completedAt ?? ts}, real_quote = ${s(c.realQuote)}, updated_at = now()
         where token = ${c.token} and phase = 'curve'`);
      return;
    }
    case "grad_ok": {
      const g = decodeGradOkV2(d);
      const kindOf = venueKind(net, g.venue);
      const soroswap = kindOf === "Soroswap";
      const side = soroswap ? await pairSide(g.pool, g.token) : null;
      const feeFraction = net.deploymentV2!.venues.find((v) => v.id === g.venue)?.feeFraction ?? null;
      await once(e, contract, d, g.token, async (tx) => {
        await tx`
          update lite.launches set graduated = true, completed = true, phase = 'graduated', pair = ${g.pool}, graduated_venue = ${g.venue},
                 graduated_fallback = ${g.fallback}, burned = greatest(burned, ${s(g.burned)}),
                 pool_token = coalesce(pool_token, ${s(g.poolTokens)}), pool_quote = coalesce(pool_quote, ${s(g.poolQuote)}),
                 last_price = case when pool_token is null then ${g.price} else last_price end,
                 pair_token0_is_launch = coalesce(pair_token0_is_launch, ${side}), graduated_ledger = coalesce(graduated_ledger, ${e.ledger}),
                 graduated_at = coalesce(graduated_at, ${ts}),
                 pool_fee_bps = coalesce(pool_fee_bps, ${soroswap ? SOROSWAP_POOL_FEE_BPS : feeFraction}), stuck_since = null,
                 fallback_at = null, updated_at = now()
           where token = ${g.token}`;
        // The launchpad excluded it from holder rewards in the same transaction.
        await tx`update lite.pool_candidates set status = 'graduation_pool', checked_at = now() where pool = ${g.pool} and token = ${g.token}`;
        // Soroswap's pair events are jobs/watch.ts's (sync, swap, …); other venues' pools aren't read.
        if (soroswap) await watchContract(tx as postgres.Sql, g.pool, "pair", g.token, e.ledger);
      });
      return;
    }
    case "grad_fail": {
      const f = decodeLaunchGradFail(d);
      const fresh = await once(e, contract, d, f.token, (tx) => tx`
        update lite.launches set stuck_since = coalesce(${f.stuckSince}, stuck_since), fallback_at = coalesce(${f.fallbackAt}, fallback_at),
               fail_venue = ${f.venue}, fail_origin = ${f.origin}, fail_code = ${f.code}, fail_name = ${f.name}, failed_at = ${ts},
               updated_at = now()
         where token = ${f.token}`);
      if (fresh) await alertOnFailure(e, "launch", f.token, f);
      return;
    }
    case "stuck": {
      const st = decodeStuck(d);
      await once(e, contract, d, st.token, (tx) => tx`update lite.launches set stuck_since = coalesce(stuck_since, ${st.stuckSince}), updated_at = now() where token = ${st.token}`);
      return;
    }
    case "fb_allow":
      await once(e, contract, d, subject, (tx) => tx`update lite.launches set fallback_allowed = true, updated_at = now() where token = ${subject}`);
      return;
    case "rescued": {
      const r = decodeRescued(d);
      await once(e, contract, d, r.token, (tx) => tx`
        update lite.launches set phase = 'rescued', rescued_at = ${ts}, rescued_by_admin = ${r.byAdmin}, refund_quote = ${s(r.refundQuote)},
               refund_supply = ${s(r.refundSupply)}, burned = greatest(burned, ${s(r.burned)}), real_quote = 0, updated_at = now()
         where token = ${r.token}`);
      return;
    }
    case "refund": {
      const r = decodeRefund(d);
      await once(e, contract, d, r.token, async (tx) => {
        await tx`
          insert into lite.refunds (event_id, token, holder, tokens_in, quote_out, tx_hash, ledger, ts)
          values (${e.id}, ${r.token}, ${r.holder}, ${s(r.tokensIn)}, ${s(r.quoteOut)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`update lite.launches set refunded = refunded + ${s(r.quoteOut)}, updated_at = now() where token = ${r.token}`;
      });
      return;
    }
    case "cr_claim": {
      const c = decodeCreatorFees(d);
      await once(e, contract, d, c.token, async (tx) => {
        await tx`
          insert into lite.creator_claims (event_id, token, creator, amount, tx_hash, ledger, ts)
          values (${e.id}, ${c.token}, ${c.account}, ${s(c.amount)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`
          update lite.launches set creator_fees_claimed = creator_fees_claimed + ${s(c.amount)},
                 creator_fees_due = greatest(0, creator_fees_due - ${s(c.amount)}), updated_at = now()
           where token = ${c.token}`;
      });
      return;
    }
    case "cr_owed": {
      // The fees booked before a recipient change stay with the old recipient (L14), in the launch's quote.
      const c = decodeCreatorFees(d);
      await once(e, contract, d, c.token, async (tx) => {
        const [l] = await tx`select quote from lite.launches where token = ${c.token}`;
        if (l) await moveOwed(tx, contract, c.account, String(l.quote), c.amount, 0n, e.ledger);
        await tx`update lite.launches set creator_fees_due = greatest(0, creator_fees_due - ${s(c.amount)}), updated_at = now() where token = ${c.token}`;
      });
      return;
    }
    case "owed_claim": {
      const o = decodeOwed(d);
      await once(e, contract, d, null, (tx) => moveOwed(tx, contract, o.account, o.asset, 0n, o.amount, e.ledger));
      return;
    }
    case "pr_claim": {
      const p = decodeProtocolClaim(d);
      await once(e, contract, d, p.token, (tx) => tx`
        update lite.launches set protocol_fees_due = greatest(0, protocol_fees_due - ${s(p.quoteAmount)}),
               launch_fee_due = greatest(0, launch_fee_due - ${s(p.launchFeeAmount)}), updated_at = now()
         where token = ${p.token}`);
      return;
    }
    case "recip_set": {
      const r = decodeRecipient(d);
      await once(e, contract, d, r.token, (tx) => tx`
        update lite.launches set recipient = ${r.recipient}, pending_recipient = null, pending_recipient_at = null,
               pending_recipient_expires = null, updated_at = now()
         where token = ${r.token}`);
      return;
    }
    case "recip_prop": {
      const r = decodeRecipient(d);
      await once(e, contract, d, r.token, (tx) => tx`
        update lite.launches set pending_recipient = ${r.recipient}, pending_recipient_at = ${r.effectiveAt},
               pending_recipient_expires = ${r.expiresAt}, updated_at = now()
         where token = ${r.token}`);
      return;
    }
    case "recip_cncl":
      await once(e, contract, d, subject, (tx) => tx`
        update lite.launches set pending_recipient = null, pending_recipient_at = null, pending_recipient_expires = null, updated_at = now()
         where token = ${subject}`);
      return;
    default:
      // Governance and configuration (treas_set, venue_*, guard_*, quote_set, …): the log is their record; the keeper
      // reads the treasury live. They concern no launch.
      await once(e, contract, d, null, async () => {});
  }
}

/** The metadata of a v2 Moment published with `uri` by `creator`, under v1's rules (handlers/moments.ts): what the API
 *  recorded, written by that creator; else the JSON at `uri`, read only from our own storage, under the creator's own
 *  folder (3 s, at most 64 KB). */
async function momentMetadata(uri: string, creator: string): Promise<MomentMetadataFields | null> {
  const rows = await sql()`select * from lite.moment_metadata where uri = ${uri}`;
  if (rows.length) {
    const r = rows[0];
    if (r.address !== creator) return null;
    return {
      title: r.title,
      description: r.description ?? null,
      place: r.place ?? null,
      takenOn: takenText(r.taken_at, r.taken_on),
      mediaType: r.media_type,
      mediaUrl: r.media_url,
      posterUrl: r.poster_url,
    };
  }
  const base = mediaBase();
  if (!base || !uri.startsWith(`${base}moments/${creator}/`)) return null;
  try {
    if (localMediaEnabled()) return metadataFromJson(JSON.parse(new TextDecoder().decode((await readLocal(uri.slice(base.length))).bytes)));
    const res = await fetch(uri, { signal: AbortSignal.timeout(3_000), redirect: "error" });
    if (!res.ok || Number(res.headers.get("content-length") ?? "0") > 65_536) {
      await res.body?.cancel();
      return null;
    }
    const body = await res.text();
    return body.length > 65_536 ? null : metadataFromJson(JSON.parse(body));
  } catch {
    return null;
  }
}

/** The platform share and royalty a v2 Moment was published under, or null when the contract doesn't answer. */
async function momentTerms(contract: string, nft: string): Promise<{ platformBps: number; royaltyBps: number } | null> {
  try {
    const m = await view(contract, "get_moment", [sv.addr(nft)]);
    return { platformBps: Number(m.platform_bps), royaltyBps: Number(m.royalty_bps) };
  } catch {
    return null;
  }
}

/** Listed in the feeds: a title and an image, and on the main Moments stack (never testnet-qa's failing one, F5). */
export function listedV2(meta: Pick<MomentMetadataFields, "title" | "posterUrl"> | null, contract: string, net: Pick<NetworkConfig, "deploymentV2">): boolean {
  return Boolean(meta?.title && meta.posterUrl) && contract === net.deploymentV2?.contracts.momentsV2;
}

/** moments-v2's events, from the main stack or testnet-qa's failing one (`contract`). */
export async function momentsV2Event(e: Event, d: Decodable, contract: string, net: NetworkConfig = env.network): Promise<void> {
  const kind = String(d.topics[0]);
  const ts = new Date(e.ledgerClosedAt);
  switch (kind) {
    case "publish": {
      const p = decodePublishV2(d);
      const [meta, terms] = await Promise.all([momentMetadata(p.metadataUri, p.creator), momentTerms(contract, p.nft)]);
      // The creator's day where readers of the day have it; the date and time, as the metadata says it, beside it.
      const taken = takenParts(meta?.takenOn);
      const usdc = net.assets.find((a) => a.id === "USDC")!.contract;
      await once(e, contract, d, p.nft, async (tx) => {
        await tx`
          insert into lite.moments (id, nft, generation, contract, nonce, number, creator, uri, title, media_url, price, quote, max_editions,
                                    deadline, created_ledger, created_at, description, place, taken_on, taken_at, media_type, poster_url,
                                    platform_bps, royalty_bps, listed, coin, name, symbol, threshold, creator_alloc_bps, rate_num,
                                    rate_den, durations, state)
          values (null, ${p.nft}, 2, ${contract}, ${s(p.nonce)},
                  (select coalesce(max(number), 0) + 1 from lite.moments where contract = ${contract}), ${p.creator}, ${p.metadataUri},
                  ${meta?.title ?? null}, ${meta?.mediaUrl ?? null}, ${s(p.price)}, ${usdc}, 0, ${p.deadline}, ${e.ledger}, ${ts},
                  ${meta?.description ?? null}, ${meta?.place ?? null}, ${taken?.day ?? null}, ${taken?.at ?? null}, ${meta?.mediaType ?? null},
                  ${meta?.posterUrl || null}, ${terms?.platformBps ?? null}, ${terms?.royaltyBps ?? null},
                  ${listedV2(meta, contract, net)}, ${p.coin}, ${p.name}, ${p.symbol}, ${s(p.threshold)}, ${p.creatorAllocBps},
                  ${s(p.rateNum)}, ${s(p.rateDen)}, ${tx.json(p.durations)}, 'collecting')
          on conflict (nft) do nothing`;
        await watchV2Contract(tx, p.nft, "nft", p.nft, e.ledger);
      });
      return;
    }
    case "collect": {
      const c = decodeCollectV2(d);
      await once(e, contract, d, c.nft, async (tx) => {
        await tx`
          insert into lite.moment_collects (event_id, moment_id, nft, collector, quantity, first_token_id, paid, tx_hash, ledger, ts)
          values (${e.id}, null, ${c.nft}, ${c.collector}, ${c.editions}, ${c.firstRank}, ${s(c.gross)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`
          insert into lite.moment_positions (nft, account, editions, gross, entitlement, updated_ledger)
          values (${c.nft}, ${c.collector}, ${c.editions}, ${s(c.gross)}, ${s(c.entitlement)}, ${e.ledger})
          on conflict (nft, account) do update set editions = lite.moment_positions.editions + excluded.editions,
            gross = lite.moment_positions.gross + excluded.gross, entitlement = lite.moment_positions.entitlement + excluded.entitlement,
            updated_ledger = greatest(lite.moment_positions.updated_ledger, excluded.updated_ledger), updated_at = now()`;
        await tx`
          update lite.moments set minted = greatest(minted, ${c.firstRank + c.editions - 1}), collects = collects + 1,
                 collectors = (select count(distinct collector) from lite.moment_collects where nft = ${c.nft}),
                 reserve = ${s(c.reserve)}, total_gross = total_gross + ${s(c.gross)}, entitlements = entitlements + ${s(c.entitlement)},
                 updated_at = now()
           where nft = ${c.nft}`;
      });
      return;
    }
    case "complete": {
      const c = decodeMomentComplete(d);
      await once(e, contract, d, c.nft, (tx) => tx`
        update lite.moments set state = 'graduation_pending', completed_at = ${c.completedAt ?? ts}, reserve = ${s(c.reserve)},
               total_gross = ${s(c.totalGross)}, updated_at = now()
         where nft = ${c.nft} and state = 'collecting'`);
      return;
    }
    case "grad_ok": {
      const g = decodeMomentGradOk(d);
      await once(e, contract, d, g.nft, async (tx) => {
        await tx`
          update lite.moments set state = 'graduated', pool = ${g.pool}, lp_token = ${g.lpToken}, liquidity = ${s(g.liquidity)},
                 pool_coins = ${s(g.poolCoins)}, usdc_used = ${s(g.usdcUsed)}, graduated_at = ${ts}, stuck_since = null, reserve = 0,
                 updated_at = now()
           where nft = ${g.nft}`;
        await watchV2Contract(tx, g.coin, "coin", g.nft, e.ledger);
      });
      return;
    }
    case "grad_fail": {
      const f = decodeMomentGradFail(d);
      const fresh = await once(e, contract, d, f.nft, (tx) => tx`
        update lite.moments set stuck_since = coalesce(${f.stuckSince}, stuck_since), fail_origin = ${f.origin}, fail_code = ${f.code},
               fail_name = ${f.name}, failed_at = ${ts}, updated_at = now()
         where nft = ${f.nft}`);
      if (fresh) await alertOnFailure(e, "moment", f.nft, f);
      return;
    }
    case "expired": {
      const x = decodeExpired(d);
      await once(e, contract, d, x.nft, (tx) => tx`
        update lite.moments set state = 'expired', expired_at = ${ts}, expired_backstop = ${x.backstop}, reserve = 0,
               expiry_creator_share = ${s(x.creatorShare)}, expiry_treasury_share = ${s(x.treasuryShare)}, updated_at = now()
         where nft = ${x.nft}`);
      return;
    }
    case "vest_claim": {
      const v = decodeVestClaim(d);
      await once(e, contract, d, v.nft, async (tx) => {
        await tx`
          insert into lite.vesting_claims (event_id, nft, account, collector_amount, creator_amount, tx_hash, ledger, ts)
          values (${e.id}, ${v.nft}, ${v.account}, ${s(v.collectorAmount)}, ${s(v.creatorAmount)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`
          insert into lite.moment_positions (nft, account, collector_claimed, creator_claimed, updated_ledger)
          values (${v.nft}, ${v.account}, ${s(v.collectorAmount)}, ${s(v.creatorAmount)}, ${e.ledger})
          on conflict (nft, account) do update set
            collector_claimed = lite.moment_positions.collector_claimed + excluded.collector_claimed,
            creator_claimed = lite.moment_positions.creator_claimed + excluded.creator_claimed,
            updated_ledger = greatest(lite.moment_positions.updated_ledger, excluded.updated_ledger), updated_at = now()`;
      });
      return;
    }
    case "withdrawn": {
      const w = decodeWithdrawn(d);
      await once(e, contract, d, w.nft, (tx) => tx`
        insert into lite.moment_withdrawals (event_id, nft, role, to_address, amount, tx_hash, ledger, ts)
        values (${e.id}, ${w.nft}, ${w.role}, ${w.to}, ${s(w.amount)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
        on conflict (event_id) do nothing`);
      return;
    }
    default:
      // Policy, governance and pauses (pol_*, gov_*, guard_*, pub_pause, base_set): the log is their record. They concern
      // no Moment (gov_prop's topic is the governance key).
      await once(e, contract, d, null, async () => {});
  }
}

/** lp-locker's events. */
export async function lockerEvent(e: Event, d: Decodable, net: NetworkConfig = env.network): Promise<void> {
  const locker = net.deploymentV2!.contracts.lpLocker;
  const ts = new Date(e.ledgerClosedAt);
  switch (String(d.topics[0])) {
    case "lock_reg": {
      const r = decodeLockReg(d);
      await once(e, locker, d, r.ref, (tx) => tx`
        insert into lite.locker_positions (pool, locker, owner, kind, lp_token, lp, base, quote, ref_kind, ref, harvest_bps, principal,
                                           registered_ledger, registered_at)
        values (${r.pool}, ${locker}, ${r.owner}, ${r.kind}, ${r.lpToken}, ${s(r.lp)}, ${r.base}, ${r.quote}, ${r.refKind}, ${r.ref},
                ${r.harvestBps}, ${s(r.principal)}, ${e.ledger}, ${ts})
        on conflict (pool) do nothing`);
      return;
    }
    case "harvested": {
      const h = decodeHarvested(d);
      await once(e, locker, d, null, async (tx) => {
        await tx`
          insert into lite.harvests (event_id, pool, lp_burned, base_out, quote_out, growth, take, compounded, principal, tx_hash, ledger, ts)
          values (${e.id}, ${h.pool}, ${s(h.lpBurned)}, ${s(h.baseOut)}, ${s(h.quoteOut)}, ${s(h.growth)}, ${s(h.take)}, ${s(h.compounded)},
                  ${s(h.principal)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
        await tx`
          update lite.locker_positions set lp = lp - ${s(h.lpBurned)}, principal = ${s(h.principal)}, last_harvest_at = ${ts},
                 harvests = harvests + 1, base_out = base_out + ${s(h.baseOut)}, quote_out = quote_out + ${s(h.quoteOut)}, updated_at = now()
           where pool = ${h.pool}`;
      });
      return;
    }
    case "owed_credit": {
      const o = decodeOwed(d);
      await once(e, locker, d, null, (tx) => moveOwed(tx, locker, o.account, o.asset, o.amount, 0n, e.ledger, o.owed));
      return;
    }
    case "owed_paid": {
      // withdraw_owed pays everything owed.
      const o = decodeOwed(d);
      await once(e, locker, d, null, (tx) => moveOwed(tx, locker, o.account, o.asset, 0n, o.amount, e.ledger, 0n));
      return;
    }
    default:
      await once(e, locker, d, null, async () => {});
  }
}

/** A pool-creation event of the Soroswap factory or the Aquarius router: a candidate for each sharing v2 launch among its
 *  tokens (a pool of two of them is excluded by each). Other events of theirs aren't logged. */
export async function discoveryEvent(e: Event, d: Decodable, contract: string): Promise<number> {
  const p = decodeNewPool(d);
  if (!p) return 0;
  const rows = await sql()`select token from lite.launches where generation = 2 and holder_sharing and token = any(${p.tokens}::text[])`;
  const candidates = poolCandidates(p, new Set(rows.map((r) => String(r.token))));
  if (!candidates.length) return 0;
  await once(e, contract, d, candidates[0].token, async (tx) => {
    for (const c of candidates) {
      await tx`
        insert into lite.pool_candidates (pool, token, other, kind, discovered_event, discovered_ledger, next_check_at)
        values (${p.pool}, ${c.token}, ${c.other}, ${p.kind}, ${e.id}, ${e.ledger}, now())
        on conflict (pool, token) do nothing`;
    }
  }, p.kind === "soroswap" ? "new_pair" : "add_pool");
  return candidates.length;
}

/** A recorded failure that the keeper's alert rules flag (V10): fired once per event. */
async function alertOnFailure(e: Event, kind: "launch" | "moment", target: string, f: Failure): Promise<void> {
  const alert = gradFailAlert(kind, target, f, String(e.id));
  if (alert) await fireAlert(alert);
}

/** Hands a v2 main-filter event to its contract's handler. */
export async function handleV2(e: Event, contract: string, net: NetworkConfig = env.network): Promise<void> {
  const d: Decodable = { topics: (e.topic as xdr.ScVal[]).map((t) => native(t)), data: native(e.value) };
  const v2 = net.deploymentV2!;
  if (contract === v2.contracts.launchpadV2) return await launchpadV2Event(e, d, net);
  if (momentsContracts(net).includes(contract)) return await momentsV2Event(e, d, contract, net);
  if (contract === v2.contracts.lpLocker) return await lockerEvent(e, d, net);
  if (contract === net.contracts.soroswapFactory || contract === net.contracts.aquariusRouter) await discoveryEvent(e, d, contract);
}

// ------------------------------------------------------------------------------------------------ the generations' cursors

/** Every table the v2 indexer and keeper fill from events, cleared with jobs/reset.ts's on a testnet reset. */
export const V2_INDEXED_TABLES = [
  "lite.v2_events",
  "lite.launch_rewards",
  "lite.reward_releases",
  "lite.locker_positions",
  "lite.harvests",
  "lite.refunds",
  "lite.creator_owed",
  "lite.moment_positions",
  "lite.moment_withdrawals",
  "lite.vesting_claims",
  "lite.moment_coin_balances",
  "lite.pool_candidates",
  "lite.keeper_alerts",
  "lite.watch_v2_contracts",
  "lite.watch_v2_groups",
];

/** One generation's event stream. */
interface Stream {
  cursor: string;
  key: string;
  filters: rpc.Api.EventFilter[];
  /** Its deploy ledger, or the first worth indexing. */
  fromLedger: number;
  handle: (e: Event) => Promise<void>;
}

interface CursorRow {
  name: string;
  ledger: number;
  cursor: string | null;
  key: string;
}

/** What a stream does with a cursor row it finds: read on from it, start over (another deployment of its generation),
 *  or wait (the ledger went backwards: a testnet reset, or an RPC behind the chain). */
export function cursorAction(row: CursorRow | null, key: string, latest: number): "continue" | "restart" | "backwards" {
  if (!row) return "restart";
  if (row.ledger > latest + 100) return "backwards";
  return row.key === key ? "continue" : "restart";
}

/** Reads a stream's events from its cursor (or from its start), as jobs/main_events.ts reads v1's: RPC scans a bounded
 *  window per request, so pages go on until the cursor reaches the latest ledger, at most 30 a run. */
async function readStream(st: Stream, start: string | null, latest: number): Promise<number> {
  const fromStart = async () => ({ filters: st.filters, limit: 500, startLedger: await streamStart(st.fromLedger, latest) });
  let req: any = start ? { filters: st.filters, limit: 500, cursor: start } : await fromStart();
  let count = 0;
  for (let round = 0; round < 30; round++) {
    let res: rpc.Api.GetEventsResponse;
    try {
      res = await rpcServer().getEvents(req);
    } catch (err) {
      // A cursor older than RPC's retention (~7 days) is refused: again from what RPC keeps.
      if (round === 0 && req.cursor) {
        console.warn(`${st.cursor}: cursor refused, restarting from the retention window`, String((err as Error).message).slice(0, 120));
        req = await fromStart();
        res = await rpcServer().getEvents(req);
      } else {
        throw err;
      }
    }
    for (const e of res.events) {
      await st.handle(e);
      count++;
    }
    await sql()`
      insert into lite.indexer_cursors (name, ledger, cursor, network_id) values (${st.cursor}, ${res.latestLedger}, ${res.cursor ?? null}, ${st.key})
      on conflict (name) do update set ledger = excluded.ledger, cursor = excluded.cursor, network_id = excluded.network_id, updated_at = now()`;
    if (!res.cursor) break;
    if (cursorLedger(res.cursor) >= res.latestLedger - 1 && res.events.length < 500) break;
    req = { filters: st.filters, limit: 500, cursor: res.cursor };
  }
  return count;
}

/** Clears what the indexer built for v1 when another v1 deployment is selected: its launches and Moments with what
 *  hangs off them (trades, claims, token events and balances, watched tokens and pairs, collects and editions). v2's rows
 *  stay. `oldKey` is the cursor key v1's rows were indexed under. */
export async function clearV1(oldKey: string): Promise<void> {
  // Before migration 20261015000012 every row is v1's.
  if (!(await tableExists("lite.v2_events"))) {
    await clearIndexed();
    return;
  }
  const oldMoments = oldKey.split("|")[2] ?? "";
  await sql().begin(async (tx) => {
    await tx`delete from lite.launches where generation = 1`;
    await tx`delete from lite.moments where generation = 1`;
    if (oldMoments) await tx`delete from lite.moment_editions where contract = ${oldMoments}`;
    await tx`delete from lite.watch_groups g where not exists (select 1 from lite.watch_contracts w where w.group_id = g.id)`;
  });
}

/** Clears every generation after a testnet reset: jobs/reset.ts's tables, then v2's. */
async function clearAll(): Promise<void> {
  await clearIndexed();
  const rows = await sql()`select t from unnest(${V2_INDEXED_TABLES}::text[]) as t where to_regclass(t) is not null`;
  const tables = rows.map((r) => r.t as string);
  // The names come from V2_INDEXED_TABLES above, never from input.
  if (tables.length) await sql().unsafe(`truncate ${tables.join(", ")}`);
}

export interface GenerationsReport {
  v1: { events: number; restarted: boolean } | { skipped: string };
  v2: { events: number; restarted: boolean } | { skipped: string };
  latest: number;
  reset: boolean;
}

/** The main contracts' events of both generations, each from its own cursor (replaces jobs/main_events.ts's
 *  indexEvents, which cleared everything whenever any contract changed). */
export async function indexGenerations(net: NetworkConfig = env.network): Promise<GenerationsReport> {
  const latest = (await rpcServer().getLatestLedger()).sequence;
  // Hosted applies migrations by hand: v2 waits for its tables.
  const v2Ready = await tableExists("lite.v2_events");
  const rows = await sql()`select name, ledger, cursor, network_id from lite.indexer_cursors where name = any(${[V1_CURSOR, V2_CURSOR]}::text[])`;
  const byName = new Map(rows.map((r) => [String(r.name), { name: String(r.name), ledger: Number(r.ledger), cursor: (r.cursor as string | null) ?? null, key: String(r.network_id) }]));

  const v1Ids = [net.contracts.launchpad, net.contracts.moments].filter((x): x is string => Boolean(x));
  const v1: Stream = {
    cursor: V1_CURSOR,
    key: deploymentKey(net),
    filters: v1Ids.length ? [{ type: "contract", contractIds: v1Ids }] : [],
    fromLedger: net.deployment?.indexFromLedger ?? net.deployment?.deployLedger ?? 0,
    handle: (e) => handleV1(e, contractIdOf(e)),
  };
  const key2 = v2Ready ? v2Key(net) : null;
  const v2: Stream | null = key2 === null ? null : {
    cursor: V2_CURSOR,
    key: key2,
    filters: v2Filters(net),
    fromLedger: net.deploymentV2!.deployLedger,
    handle: (e) => handleV2(e, contractIdOf(e), net),
  };

  // The ledger went backwards: a testnet reset, and everything indexed is gone on chain. Off testnet it can only be an
  // RPC behind the chain: wait for it.
  const streams = [v1, ...(v2 ? [v2] : [])];
  if (streams.some((st) => cursorAction(byName.get(st.cursor) ?? null, st.key, latest) === "backwards")) {
    if (!resetAllowed("ledger_backwards", net.name, env.indexerAllowReset)) {
      console.warn(`RPC answers ledger ${latest}, behind the indexed one; waiting for it to catch up.`);
      return { v1: { skipped: "rpc behind" }, v2: { skipped: "rpc behind" }, latest, reset: false };
    }
    await clearAll();
    console.warn("testnet reset detected; indexed data of both generations cleared. Redeploy contracts (docs/RUNBOOK-testnet.md).");
    return { v1: { skipped: "reset" }, v2: { skipped: "reset" }, latest, reset: true };
  }

  const run = async (st: Stream, onRestart: (old: CursorRow) => Promise<void> | void) => {
    const row = byName.get(st.cursor) ?? null;
    const action = cursorAction(row, st.key, latest);
    if (action === "restart" && row) await onRestart(row);
    if (st.filters.length === 0) return { events: 0, restarted: action === "restart" };
    return { events: await readStream(st, action === "continue" ? row!.cursor : null, latest), restarted: action === "restart" };
  };

  // v1: another v1 deployment's Moments would number from 1 again, which v1's rows would shadow: v1's rows go (v2's
  // stay), on testnet or with LITE_INDEXER_ALLOW_RESET, as before.
  const v1Report = await run(v1, async (old) => {
    if (!resetAllowed("new_deployment", net.name, env.indexerAllowReset)) {
      throw new Error("new v1 contracts: the indexed v1 data describes others. Set LITE_INDEXER_ALLOW_RESET=1 to clear it and index the new ones.");
    }
    await clearV1(old.key);
    console.warn("other v1 contracts: v1's indexed data cleared, indexing again from their deploy ledger; v2's rows stay.");
  });
  // v2: rows are keyed by address, so another v2 deployment's never collide: only the cursor starts over.
  const v2Report = v2
    ? await run(v2, () => console.warn("another v2 deployment: indexing it from its deploy ledger; the rows indexed so far stay."))
    : { skipped: net.deploymentV2 ? "migration 20261015000012 not applied" : "no v2 deployment" };
  return { v1: v1Report, v2: v2Report, latest, reset: false };
}

// ------------------------------------------------------------------------------------------------ watched v2 contracts

/** A launch token's reward, exclusion or unlock event. Its SEP-41 events are jobs/watch.ts's. */
async function launchTokenEvent(e: Event, d: Decodable, token: string): Promise<boolean> {
  const kind = String(d.topics[0]);
  const ts = new Date(e.ledgerClosedAt);
  const r = decodeRewardEvent(d);
  if (r) {
    await once(e, token, d, token, async (tx) => {
      if (r.kind === "queued" || r.kind === "released" || r.kind === "to_protocol") {
        await tx`
          insert into lite.reward_releases (event_id, token, asset, kind, amount, notifier, releasable_from, eligible, acc, tx_hash, ledger, ts)
          values (${e.id}, ${token}, ${r.asset}, ${r.kind}, ${s(r.amount)}, ${r.kind === "queued" ? r.notifier : null},
                  ${r.kind === "queued" ? r.releasableFrom : null}, ${r.kind === "queued" ? null : s(r.eligible)},
                  ${r.kind === "released" ? s(r.acc) : null}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
          on conflict (event_id) do nothing`;
      }
      const column = { queued: "funded", released: "released", to_protocol: "to_protocol", claimed: "claimed", swept: "swept" } as const;
      await addReward(tx, token, r.asset, column[r.kind], r.amount, e.ledger, r.kind === "released" ? { acc: r.acc, eligible: r.eligible } : undefined);
    });
    return true;
  }
  if (kind === "excluded") {
    const x = decodeExcluded(d);
    await once(e, token, d, token, async (tx) => {
      const [l] = await tx`select quote from lite.launches where token = ${token}`;
      if (l) await addReward(tx, token, String(l.quote), "stranded", x.strandedQuote, e.ledger);
      await addReward(tx, token, token, "stranded", x.strandedToken, e.ledger);
      await tx`update lite.pool_candidates set status = 'excluded', checked_at = now() where pool = ${x.account} and token = ${token}`;
    });
    return true;
  }
  if (kind === "unlocked") {
    await once(e, token, d, token, (tx) => tx`update lite.launches set unlocked_at = coalesce(unlocked_at, ${ts}), updated_at = now() where token = ${token}`);
    return true;
  }
  return false;
}

/** A Moment NFT's mint or transfer (who holds the edition now, unless a newer event already moved it) or its closed. */
async function nftEvent(e: Event, d: Decodable, nft: string): Promise<boolean> {
  const kind = String(d.topics[0]);
  if (kind === "closed") {
    await once(e, nft, d, nft, (tx) => tx`update lite.moments set edition_size = ${Number(d.data)}, updated_at = now() where nft = ${nft}`);
    return true;
  }
  if (kind !== "mint" && kind !== "transfer") return false;
  const m = decodeMove(d);
  await once(e, nft, d, nft, (tx) => tx`
    insert into lite.moment_editions (contract, token_id, moment_id, owner, owner_event, updated_ledger)
    values (${nft}, ${m.tokenId}, null, ${m.to}, ${String(e.id)}, ${e.ledger})
    on conflict (contract, token_id) do update set
      owner = case when excluded.owner_event >= lite.moment_editions.owner_event then excluded.owner else lite.moment_editions.owner end,
      owner_event = greatest(excluded.owner_event, lite.moment_editions.owner_event),
      updated_ledger = greatest(excluded.updated_ledger, lite.moment_editions.updated_ledger), updated_at = now()`);
  return true;
}

/** A Moment coin's transfer, mint or burn: its holders' balances. */
async function coinEvent(e: Event, d: Decodable, coin: string, nft: string): Promise<boolean> {
  const move = decodeTokenEvent(d.topics, d.data);
  if (!move) return false;
  const changes: [string, bigint][] = move.kind === "transfer"
    ? [[move.from, -move.amount], [move.to, move.amount]]
    : move.kind === "mint"
    ? [[move.to, move.amount]]
    : [[move.from, -move.amount]];
  await once(e, coin, d, nft, async (tx) => {
    for (const [address, delta] of changes) {
      await tx`
        insert into lite.moment_coin_balances (coin, address, balance, updated_ledger) values (${coin}, ${address}, ${s(delta)}, ${e.ledger})
        on conflict (coin, address) do update set balance = lite.moment_coin_balances.balance + excluded.balance,
          updated_ledger = greatest(lite.moment_coin_balances.updated_ledger, excluded.updated_ledger), updated_at = now()`;
    }
  });
  return true;
}

interface WatchedV2 {
  contract: string;
  role: "launch_token" | "nft" | "coin";
  ref: string;
}

/** Records one watched v2 contract's event; answers whether it was one of the kinds watched. */
export async function handleWatchedV2(e: Event, members: Map<string, WatchedV2>): Promise<boolean> {
  const m = members.get(contractIdOf(e));
  if (!m) return false;
  const d: Decodable = { topics: (e.topic as xdr.ScVal[]).map((t) => native(t)), data: native(e.value) };
  if (m.role === "launch_token") return await launchTokenEvent(e, d, m.contract);
  if (m.role === "nft") return await nftEvent(e, d, m.contract);
  return await coinEvent(e, d, m.contract, m.ref);
}

interface GroupV2 {
  id: number;
  position: Position;
  ledger: number;
  members: string[];
  watched: WatchedV2[];
}

/** Contract ids per getEvents filter. */
const PER_FILTER = 5;
const PAGE_LIMIT = 1_000;
const PAGES = 10;
/** The job stops starting groups after this long. */
const WATCH_RUN_MS = 12_000;

async function groupLoose(): Promise<void> {
  const loose = await sql()`select contract, from_ledger from lite.watch_v2_contracts where group_id is null order by from_ledger, contract limit 500`;
  for (let i = 0; i < loose.length; i += GROUP_SIZE) {
    const part = loose.slice(i, i + GROUP_SIZE);
    const start = Number(part[0].from_ledger);
    await sql().begin(async (tx) => {
      const [g] = await tx`insert into lite.watch_v2_groups (start_ledger, ledger) values (${start}, ${start - 1}) returning id`;
      await tx`update lite.watch_v2_contracts set group_id = ${g.id} where contract = any(${part.map((c) => String(c.contract))}::text[])`;
    });
  }
}

async function loadGroups(): Promise<GroupV2[]> {
  const rows = await sql()`
    select g.id, g.start_ledger, g.cursor, g.ledger, w.contract, w.role, w.ref
      from lite.watch_v2_groups g join lite.watch_v2_contracts w on w.group_id = g.id
     order by g.id, w.contract`;
  const out = new Map<number, GroupV2>();
  for (const r of rows) {
    const id = Number(r.id);
    if (!out.has(id)) {
      out.set(id, { id, position: { cursor: (r.cursor as string | null) ?? null, ledger: Number(r.start_ledger) }, ledger: Number(r.ledger), members: [], watched: [] });
    }
    const g = out.get(id)!;
    g.members.push(String(r.contract));
    g.watched.push({ contract: String(r.contract), role: r.role as WatchedV2["role"], ref: String(r.ref) });
  }
  return [...out.values()];
}

async function saveGroup(id: number, p: Position, ledger: number): Promise<void> {
  await sql()`update lite.watch_v2_groups set cursor = ${p.cursor}, start_ledger = ${p.cursor === null ? p.ledger : sql()`start_ledger`}, ledger = ${ledger}, updated_at = now() where id = ${id}`;
}

/** Reads a group from its position until it catches up, runs out of pages or `deadline` passes. A position RPC no longer
 *  keeps starts again a little inside the window it keeps (a gap, reported). */
async function readGroup(g: GroupV2, oldest: number, deadline: number): Promise<{ events: number; gap: boolean }> {
  const members = new Map(g.watched.map((m) => [m.contract, m]));
  const filters = Array.from({ length: Math.ceil(g.members.length / PER_FILTER) }, (_, i) => ({
    type: "contract" as const,
    contractIds: g.members.slice(i * PER_FILTER, (i + 1) * PER_FILTER),
  }));
  let position = g.position;
  let gap = false;
  let retried = false;
  const restart = async () => {
    const start = (await rpcServer().getHealth()).oldestLedger + RETENTION_MARGIN;
    if (ledgerOf(position) < start) gap = true;
    position = { cursor: null, ledger: Math.max(start, ledgerOf(position)) };
  };
  if (ledgerOf(position) < oldest) await restart();
  let events = 0;
  for (let page = 0; page < PAGES && Date.now() < deadline; page++) {
    let res: rpc.Api.GetEventsResponse;
    try {
      res = await rpcServer().getEvents(position.cursor ? { filters, limit: PAGE_LIMIT, cursor: position.cursor } : { filters, limit: PAGE_LIMIT, startLedger: position.ledger });
    } catch (err) {
      if (retried) throw err;
      retried = true;
      await restart();
      continue;
    }
    for (const e of res.events) if (await handleWatchedV2(e, members)) events++;
    if (res.cursor) position = { cursor: res.cursor, ledger: cursorLedger(res.cursor) };
    const readTo = Math.min(res.latestLedger, ledgerOf(position));
    await saveGroup(g.id, position, readTo);
    g.position = position;
    g.ledger = readTo;
    if (!res.cursor || (cursorLedger(res.cursor) >= res.latestLedger - 1 && res.events.length < PAGE_LIMIT)) break;
  }
  return { events, gap };
}

export interface WatchV2Report {
  groups: number;
  events: number;
  gaps: number;
  failed: number;
  merged: number;
  latest: number;
}

/** One run over the watched v2 contracts: new contracts grouped, each group read (the furthest behind first), groups
 *  that have caught up merged (jobs/watch.ts mergeGroups). A group that can't be read doesn't stop the others. */
export async function watchV2(net: NetworkConfig = env.network): Promise<WatchV2Report | { skipped: string }> {
  if (!net.deploymentV2) return { skipped: "no v2 deployment" };
  if (!(await tableExists("lite.watch_v2_groups"))) return { skipped: "migration 20261015000012 not applied" };
  const deadline = Date.now() + WATCH_RUN_MS;
  await groupLoose();
  const health = await rpcServer().getHealth();
  const all = await loadGroups();
  let events = 0;
  let gaps = 0;
  let tried = 0;
  let failed = 0;
  let lastError: unknown = null;
  for (const g of [...all].sort((a, b) => ledgerOf(a.position) - ledgerOf(b.position))) {
    if (Date.now() >= deadline) break;
    tried++;
    try {
      const r = await readGroup(g, health.oldestLedger, deadline);
      events += r.events;
      if (r.gap) gaps++;
    } catch (err) {
      failed++;
      lastError = err;
      console.warn(`watch_v2: group ${g.id} not read this run`, String((err as Error).message ?? err).slice(0, 200));
    }
  }
  if (failed > 0 && failed === tried) throw lastError;
  const merges = mergeGroups(all.filter((g) => g.ledger >= health.latestLedger - CAUGHT_UP_LEDGERS));
  for (const m of merges) {
    await sql().begin(async (tx) => {
      await tx`update lite.watch_v2_contracts set group_id = ${m.keep} where group_id = any(${m.drop}::bigint[])`;
      await tx`update lite.watch_v2_groups set cursor = ${m.position.cursor}, start_ledger = ${m.position.cursor === null ? m.position.ledger : tx`start_ledger`},
                 ledger = ${m.ledger}, updated_at = now() where id = ${m.keep}`;
      await tx`delete from lite.watch_v2_groups where id = any(${m.drop}::bigint[])`;
    });
  }
  const merged = merges.reduce((n, m) => n + m.drop.length, 0);
  return { groups: all.length - merged, events, gaps, failed, merged, latest: health.latestLedger };
}
