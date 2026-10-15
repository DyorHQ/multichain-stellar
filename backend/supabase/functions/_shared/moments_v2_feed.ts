// Moments v2 as the indexer recorded them (docs/DESIGN-stellar-contracts-v2.md §20.5, lite-indexer/v2_events.ts): the
// feed, a Moment's page by its NFT address, the editions and coins an account holds per Moment, and the Moments a
// creator published. The shapes and conventions are v1's (moments.ts, DESIGN-stellar-parity §6.9) where they apply:
// - Rows come from lite.moments (generation 2) with what the indexer adds up beside them (moment_collects,
//   moment_editions, moment_positions, moment_withdrawals and the collect events' own split in v2_events): no RPC call.
//   A Moment's live state, its expiry clocks and an account's vesting stay moments_v2.ts's reads (status, vesting).
// - Only the deployment's main Moments stack is served: a former v2 deployment's rows stay in the table, and
//   testnet-qa's failing stack is never in the app's feeds (F5). The feed lists `listed` Moments (DyorHQ's metadata
//   with an image); a Moment's page needs DyorHQ's metadata, as v1's does.
// - The feed and a Moment's page are viewer routes (§6.0), an account's editions too (`?address=` in the public view);
//   a creator's Moments are DyorHQ's history (session). In the public view what the account paid is null, as v1's
//   `spent` is.
// - The name and ticker are the NFT's (on chain); the title, description, place, date and media come from the
//   metadata, as v1's feed gives them. The coin and its pool are named once the Moment graduated: the coin's address is
//   fixed at publish, but the contract exists only from graduation.
import type { MomentDetailV2, MomentHoldingV2, MomentRowV2, MyMomentsV2, View } from "./contract.ts";
import { num, sql } from "./db.ts";
import { env } from "./env.ts";
import { bad, notFound } from "./http.ts";
import type { MomentViewer } from "./moments.ts";
import { durationsOf, type MomentsV2Durations, momentsV2Id, type MomentV2State, pinnedDurations } from "./moments_v2.ts";
import { assetById, AssetInfo, NetworkConfig, PriceRef } from "./networks.ts";
import { referencePrices, RefPrice, usdOf } from "./refprices.ts";
import { isContractId } from "./stellar.ts";

type Row = Record<string, any>;
type Prices = Record<PriceRef, RefPrice>;

/** The most rows one page of the feed takes. */
export const FEED_LIMIT_MAX = 100;

const known = (v: unknown): boolean => v !== null && v !== undefined;
const iso = (v: unknown): string => new Date(v as string).toISOString();
const isoOrNull = (v: unknown): string | null => (known(v) ? iso(v) : null);
const big = (v: unknown): bigint => BigInt(num(v).split(".")[0]);
/** A USD amount: to the cent. */
const usdAmount = (v: number): number => Math.round(v * 100) / 100 || 0;

const STATES: MomentV2State[] = ["collecting", "graduation_pending", "graduated", "expired"];

function stateOf(v: unknown): MomentV2State {
  return STATES.includes(v as MomentV2State) ? v as MomentV2State : "collecting";
}

/** A calendar day ("2026-10-14"), however the driver handed it over. */
function dayText(v: unknown): string | null {
  if (!known(v)) return null;
  return (v instanceof Date ? v.toISOString() : String(v)).slice(0, 10);
}

/** `units` of `asset` in USD, to the cent; null without a price. */
function usdOfUnits(units: string, asset: AssetInfo | undefined, prices: Prices): number | null {
  const usd = usdOf(asset, prices);
  if (usd === null || !asset) return null;
  return usdAmount((Number(units) / 10 ** asset.decimals) * usd);
}

// ------------------------------------------------------------------------------------------------ rows

/** The Moment's terms' durations, as its publish event bound them; the deployment's pinned ones for a row without
 *  them (every v2 Moment binds the deployment's durations, so they are the same). */
export function durationsOfRow(r: Row, net: NetworkConfig): MomentsV2Durations {
  if (r.durations && typeof r.durations === "object") {
    try {
      return durationsOf(r.durations);
    } catch {
      // A key the publish event didn't carry: the pinned set below.
    }
  }
  return pinnedDurations(net);
}

/** How far a Moment got to its threshold, from 0 to 1, as moments_v2.ts progressOf reads it live: 1 once it completed
 *  (graduated, pending graduation, or expired after completing); while it collects its reserve over the threshold;
 *  once it expired without completing, the reserve its expiry split between the creator and the treasury. */
export function progressOfRow(r: Row): number {
  const threshold = big(r.threshold);
  if (threshold <= 0n) return 0;
  const state = stateOf(r.state);
  if (known(r.completed_at) || state === "graduated" || state === "graduation_pending") return 1;
  const reached = state === "expired" ? big(r.expiry_creator_share) + big(r.expiry_treasury_share) : big(r.reserve);
  const below = reached < threshold ? reached : threshold - 1n;
  return Number((below * 1_000_000n) / threshold) / 1_000_000;
}

/** A photo or a video, as recorded (from DyorHQ's metadata); null without it. */
function mediaTypeOf(r: Row): "image" | "video" | null {
  return r.media_type === "image" || r.media_type === "video" ? r.media_type : null;
}

/** A lite.moments row of generation 2 as the API's MomentRowV2. */
export function momentRowV2Of(r: Row, prices: Prices, now: number, net: NetworkConfig = env.network): MomentRowV2 {
  const quote = assetById(net, String(r.quote));
  const state = stateOf(r.state);
  const graduated = state === "graduated";
  const price = num(r.price);
  return {
    generation: 2,
    nft: String(r.nft),
    number: known(r.number) ? Number(r.number) : null,
    creator: String(r.creator),
    uri: String(r.uri ?? ""),
    name: String(r.name ?? ""),
    symbol: String(r.symbol ?? ""),
    title: r.title ?? null,
    description: r.description ?? null,
    place: r.place ?? null,
    takenOn: dayText(r.taken_on),
    mediaUrl: r.media_url ?? null,
    mediaType: mediaTypeOf(r),
    posterUrl: r.poster_url ?? null,
    price,
    quote: String(r.quote),
    quoteCode: quote?.code ?? "USDC",
    priceUsd: usdOfUnits(price, quote, prices),
    threshold: num(r.threshold),
    totalGross: num(r.total_gross),
    reserve: num(r.reserve),
    progress: progressOfRow(r),
    minted: Number(r.minted ?? 0),
    collects: Number(r.collects ?? 0),
    collectors: Number(r.collectors ?? 0),
    creatorAllocBps: Number(r.creator_alloc_bps ?? 0),
    platformBps: known(r.platform_bps) ? Number(r.platform_bps) : null,
    royaltyBps: known(r.royalty_bps) ? Number(r.royalty_bps) : null,
    deadline: iso(r.deadline),
    state,
    open: state === "collecting" && new Date(r.deadline).getTime() > now,
    coin: graduated && known(r.coin) ? String(r.coin) : null,
    pool: graduated && known(r.pool) ? String(r.pool) : null,
    durations: durationsOfRow(r, net),
    publishedAt: iso(r.created_at),
    completedAt: isoOrNull(r.completed_at),
    graduatedAt: isoOrNull(r.graduated_at),
    expiredAt: isoOrNull(r.expired_at),
  };
}

// ------------------------------------------------------------------------------------------------ arguments

export type MomentFilterV2 = "all" | "collecting" | "closed";

/** ?cursor= of the feed: a nextCursor it answered ("page-N"); page 1 without one. */
export function feedPage(cursor: string | null): number {
  if (!cursor) return 1;
  const page = Number(/^page-([1-9][0-9]{0,5})$/.exec(cursor)?.[1] ?? NaN);
  if (!Number.isInteger(page)) throw bad("bad_arg", "cursor is a nextCursor this route answered.");
  return page;
}

function nftArg(v: string): string {
  if (!isContractId(v)) throw notFound("Moment");
  return v;
}

// ------------------------------------------------------------------------------------------------ reads

/** The main stack's v2 Moments (`m`), as every read here serves them. */
function ofTheStack(contract: string) {
  return sql()`m.generation = 2 and m.contract = ${contract}`;
}

/** GET /v1/moments/v2: listed v2 Moments, newest first, a page at a time. `collecting` holds the Moments still taking
 *  collects before their deadline; `closed` every other one (window closed, graduating, graduated, expired). */
export async function feedV2(
  filter: MomentFilterV2,
  limit: number,
  page: number,
  now: number = Date.now(),
  net: NetworkConfig = env.network,
): Promise<{ moments: MomentRowV2[]; nextCursor: string | null }> {
  const contract = momentsV2Id(net);
  const at = new Date(now);
  const collecting = sql()`coalesce(m.state, 'collecting') = 'collecting' and m.deadline > ${at}`;
  const where = filter === "collecting" ? sql()`and ${collecting}` : filter === "closed" ? sql()`and not (${collecting})` : sql()``;
  const [rows, prices] = await Promise.all([
    sql()`
      select m.* from lite.moments m
       where ${ofTheStack(contract)} and m.listed and m.title is not null ${where}
       order by m.created_at desc, m.nft desc
       limit ${limit + 1} offset ${(page - 1) * limit}`,
    referencePrices(now, net),
  ]);
  return {
    moments: rows.slice(0, limit).map((r) => momentRowV2Of(r, prices, now, net)),
    nextCursor: rows.length > limit ? `page-${page + 1}` : null,
  };
}

/** What each Moment of `rows` has earned its creator, by NFT address (base units of USDC): the creator's share of every
 *  collect, as each collect event split it, and of an expired Moment's reserve. */
async function earnedBy(rows: Row[], contract: string): Promise<Map<string, bigint>> {
  const nfts = rows.map((r) => String(r.nft));
  const out = new Map<string, bigint>(rows.map((r) => [String(r.nft), big(r.expiry_creator_share)]));
  if (nfts.length === 0) return out;
  const split = await sql()`
    select subject as nft, coalesce(sum((data ->> 'creator_in')::numeric), 0) as earned from lite.v2_events
     where contract = ${contract} and kind = 'collect' and subject = any(${nfts}::text[])
     group by subject`;
  for (const s of split) out.set(String(s.nft), (out.get(String(s.nft)) ?? 0n) + big(s.earned));
  return out;
}

/** GET /v1/moments/v2/:nft: the Moment, its newest 50 collects, who collected most, what its creator has earned and,
 *  for the viewer's account, the editions it holds, the coins it was promised and has claimed, and (owner view) what it
 *  paid. 404 for an address that is no v2 Moment of the main stack, and for one published without DyorHQ's
 *  metadata. */
export async function momentDetailV2(nft: string, v: MomentViewer, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MomentDetailV2> {
  const contract = momentsV2Id(net);
  const id = nftArg(nft);
  const rows = await sql()`select m.* from lite.moments m where m.nft = ${id} and ${ofTheStack(contract)}`;
  if (rows.length === 0 || !known(rows[0].title)) throw notFound("Moment");
  const r = rows[0];
  const [collects, largest, earned, prices, you] = await Promise.all([
    sql()`select collector, quantity, first_token_id, ts from lite.moment_collects where nft = ${id} order by ts desc, event_id desc limit 50`,
    sql()`
      select collector, sum(quantity)::int as editions from lite.moment_collects where nft = ${id}
       group by collector order by editions desc, min(ts) asc limit 1`,
    earnedBy([r], contract),
    referencePrices(now, net),
    yours(id, v),
  ]);
  return {
    moment: momentRowV2Of(r, prices, now, net),
    collectors: collects.map((c) => ({ collector: String(c.collector), quantity: Number(c.quantity), firstTokenId: Number(c.first_token_id), ts: iso(c.ts) })),
    collectorsSummary: {
      count: Number(r.collectors ?? 0),
      largest: largest.length ? { address: String(largest[0].collector), editions: Number(largest[0].editions) } : null,
    },
    you,
    creatorEarned: (earned.get(id) ?? 0n).toString(),
    view: v.scope,
  };
}

/** The viewer's part in the Moment `nft`: the editions it holds, the coins it was promised as a collector and claimed,
 *  and in the owner view what it paid (null in the public view); null with no account named. */
async function yours(nft: string, v: MomentViewer): Promise<MomentDetailV2["you"]> {
  if (v.address === null) return null;
  const [held, position] = await Promise.all([
    sql()`select token_id from lite.moment_editions where contract = ${nft} and owner = ${v.address} order by token_id`,
    sql()`select entitlement, collector_claimed, gross from lite.moment_positions where nft = ${nft} and account = ${v.address}`,
  ]);
  const p = position[0];
  return {
    editions: held.map((e) => Number(e.token_id)),
    entitlement: num(p?.entitlement),
    claimed: num(p?.collector_claimed),
    spent: v.scope === "owner" ? num(p?.gross) : null,
  };
}

/** The v2 Moments `address` holds editions of or was promised coins in, newest first: per Moment, the editions it
 *  holds, its entitlement as a collector and what it has claimed, and (owner view) what it paid. */
export async function ownedV2(address: string, scope: View, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MomentHoldingV2[]> {
  const contract = momentsV2Id(net);
  const [editions, positions] = await Promise.all([
    sql()`
      select e.contract as nft, e.token_id from lite.moment_editions e join lite.moments m on m.nft = e.contract
       where e.owner = ${address} and ${ofTheStack(contract)}
       order by e.token_id
       limit 2000`,
    sql()`
      select p.nft, p.entitlement, p.collector_claimed, p.gross from lite.moment_positions p join lite.moments m on m.nft = p.nft
       where p.account = ${address} and p.entitlement > 0 and ${ofTheStack(contract)}`,
  ]);
  const held = new Map<string, number[]>();
  for (const e of editions) held.set(String(e.nft), [...(held.get(String(e.nft)) ?? []), Number(e.token_id)]);
  const promised = new Map(positions.map((p) => [String(p.nft), p]));
  const nfts = [...new Set([...held.keys(), ...promised.keys()])];
  if (nfts.length === 0) return [];
  const [rows, prices] = await Promise.all([
    sql()`select m.* from lite.moments m where m.nft = any(${nfts}::text[]) and ${ofTheStack(contract)} order by m.created_at desc, m.nft desc limit 200`,
    referencePrices(now, net),
  ]);
  return rows.map((r) => {
    const p = promised.get(String(r.nft));
    return {
      moment: momentRowV2Of(r, prices, now, net),
      editions: held.get(String(r.nft)) ?? [],
      entitlement: num(p?.entitlement),
      claimed: num(p?.collector_claimed),
      spent: scope === "owner" ? num(p?.gross) : null,
    };
  });
}

/** Adds `amount` to `map[key]`, keeping base units as decimal strings. */
function addTo(map: Record<string, string>, key: string, amount: bigint): void {
  map[key] = (BigInt(map[key] ?? "0") + amount).toString();
}

/** GET /v1/moments/v2/mine: the v2 Moments `user` published, each with what it has earned them (proceeds: their share
 *  of every collect, and of an expired Moment's reserve) and what they withdrew; the Moments they hold editions of or
 *  coins in; and the totals: editions held, the Moments they are from, what the user paid collecting and earned
 *  publishing, per quote. */
export async function mineV2(user: string, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MyMomentsV2> {
  const contract = momentsV2Id(net);
  const [createdRows, collected, prices] = await Promise.all([
    sql()`
      select m.* from lite.moments m
       where m.creator = ${user} and m.title is not null and ${ofTheStack(contract)}
       order by m.created_at desc, m.nft desc limit 200`,
    ownedV2(user, "owner", now, net),
    referencePrices(now, net),
  ]);
  const nfts = createdRows.map((r) => String(r.nft));
  const [earned, withdrawals] = await Promise.all([
    earnedBy(createdRows, contract),
    nfts.length
      ? sql()`
          select nft, coalesce(sum(amount), 0) as withdrawn from lite.moment_withdrawals
           where role = 'creator' and nft = any(${nfts}::text[]) group by nft`
      : Promise.resolve([] as Row[]),
  ]);
  const withdrawn = new Map(withdrawals.map((w) => [String(w.nft), num(w.withdrawn)]));
  const quoteId = (quote: string) => assetById(net, quote)?.id ?? quote;

  const earnedByQuote: Record<string, string> = {};
  const created = createdRows.map((r) => {
    const row = momentRowV2Of(r, prices, now, net);
    const proceeds = earned.get(row.nft) ?? 0n;
    if (proceeds > 0n) addTo(earnedByQuote, quoteId(row.quote), proceeds);
    return {
      ...row,
      proceeds: proceeds.toString(),
      proceedsUsd: usdOfUnits(proceeds.toString(), assetById(net, row.quote), prices),
      withdrawn: withdrawn.get(row.nft) ?? "0",
    };
  });
  const spentByQuote: Record<string, string> = {};
  for (const c of collected) if (BigInt(c.spent ?? "0") > 0n) addTo(spentByQuote, quoteId(c.moment.quote), BigInt(c.spent!));
  return {
    created,
    collected,
    totals: {
      editions: collected.reduce((n, c) => n + c.editions.length, 0),
      moments: collected.filter((c) => c.editions.length > 0).length,
      spentByQuote,
      earnedByQuote,
    },
  };
}
