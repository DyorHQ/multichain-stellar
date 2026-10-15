// Launchpad (docs/DESIGN-stellar-parity.md §6.6, §6.9, §6.13): the board, a launch's page, trade quotes, the create,
// buy, sell, graduate and claim plans, My Launchpad, and launch tokens' rows in the markets and the asset search.
// - Lists come from the indexer's tables (lite-indexer/handlers/launchpad.ts, jobs/watch.ts): no RPC call per row. A
//   launch's page adds its curve and creator fees read live (the curve kept 30 s), and the owner's live balance.
// - A price in the quote asset is an exact decimal string: on the curve, its last trade's quote reserve / token reserve
//   (the opening reserves before any trade); after graduation the pool's, from its latest sync. USD figures are those
//   times the quote's reference price (refprices.ts): a price to 6 significant digits, an amount to the cent.
// - The launchpad's own refusals carry their stable codes (§6.13).
// - The board and a launch's page are viewer routes (§6.0): in the public view `you` holds on-chain facts only (the
//   indexed balance), never DyorHQ's history.
import type postgres from "postgres";
import type {
  ActivityItem,
  ContractErrorCode,
  CreatorFees,
  DisplayValue,
  FeePayer,
  LaunchBoard,
  LaunchDetail,
  LaunchRow,
  LaunchTrade,
  MyLaunchpad,
  TradeQuote,
  Usd,
  View,
} from "./contract.ts";
import { num, sql } from "./db.ts";
import { QUOTES } from "./economics.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { checkLaunchUri, launchName, launchSymbol, linksOf } from "./launch_metadata.ts";
import { assetById, AssetInfo, NetworkConfig, PriceRef } from "./networks.ts";
import { Builder, createPlan, PlanView, registerBuilder } from "./plans.ts";
import { referencePrices, RefPrice, REFS } from "./refprices.ts";
import { fromStroops, invoke, isContractId, requireAccount, sv, view } from "./stellar.ts";
import { Intent } from "./verify.ts";

type Row = postgres.Row;
type Fragment = postgres.PendingQuery<postgres.Row[]>;

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Launch tokens have 7 decimals, as Stellar assets do (launch-token's DECIMALS). */
export const TOKEN_DECIMALS = 7;

/** A Soroswap pool keeps 0.3% of each swap's input (the pair pays out on 997/1000 of it). The pair has no view of its
 *  fee, so the indexer records this at graduation. */
export const SOROSWAP_POOL_FEE_BPS = 30;

/** A launch's curve, read live, is kept this long for the public view and My Launchpad. */
const CURVE_TTL_MS = 30_000;

/** The most rows a page of the board takes. */
export const BOARD_LIMIT_MAX = 100;

function launchpadId(): string {
  const id = env.network.contracts.launchpad;
  if (!id) throw new ApiError(503, "not_deployed", "The launchpad isn't deployed on this network yet.");
  return id;
}

function quoteAsset(id: string) {
  const a = assetById(env.network, id);
  if (!a || !QUOTES.includes(a.id)) throw bad("bad_quote", "Launches are quoted in XLM or USDC.");
  return a;
}

// ------------------------------------------------------------------------------------------------ decimals

const SCALE = 10n ** 18n;

/** A decimal string ("0.0000417", "-12.5", "41700") as an integer of 18 decimals; digits past the 18th are dropped. */
export function scaled(text: string): bigint {
  const neg = text.startsWith("-");
  const [whole, frac = ""] = (neg ? text.slice(1) : text).split(".");
  const v = BigInt(whole || "0") * SCALE + BigInt((frac + "0".repeat(18)).slice(0, 18));
  return neg ? -v : v;
}

/** An integer of 18 decimals as a decimal string of at most `decimals` decimals (rounded toward zero), trailing zeros
 *  trimmed. */
export function decimalText(v: bigint, decimals = 18): string {
  const neg = v < 0n;
  const step = 10n ** BigInt(18 - decimals);
  const abs = ((neg ? -v : v) / step) * step;
  const frac = (abs % SCALE).toString().padStart(18, "0").replace(/0+$/, "");
  return `${neg && abs > 0n ? "-" : ""}${abs / SCALE}${frac ? `.${frac}` : ""}`;
}

/** a / b as a decimal string of up to 18 decimals, rounded down: a price from two reserves of 7-decimal assets. */
export function ratio(a: bigint, b: bigint): string {
  return decimalText((a * SCALE) / b);
}

/** Base units as the decimal string of whole units. */
export function unitsText(units: bigint, decimals: number = TOKEN_DECIMALS): string {
  return decimalText(units * 10n ** BigInt(18 - decimals));
}

/** Base units as an amount to read: whole units grouped by thousands, up to 7 decimals ("1,200,000", "0.5"). */
export function amountText(units: bigint, decimals: number = TOKEN_DECIMALS): string {
  const [whole, frac] = unitsText(units, decimals).split(".");
  const sign = whole.startsWith("-") ? "-" : "";
  return `${sign}${whole.replace("-", "").replace(/\B(?=(\d{3})+(?!\d))/g, ",")}${frac ? `.${frac}` : ""}`;
}

const big = (v: unknown): bigint => BigInt(num(v).split(".")[0]);
const iso = (v: unknown): string | null => (v === null || v === undefined ? null : new Date(v as string).toISOString());
const known = (v: unknown): boolean => v !== null && v !== undefined;

/** A USD price: 6 significant digits, more than the app's 4. */
const usdPrice = (v: number): number => Number(v.toPrecision(6));
/** A USD amount: to the cent. */
const usdAmount = (v: number): number => Math.round(v * 100) / 100 || 0;
/** A change: 6 decimals, as refprices.ts rounds the reference assets'. */
const fraction = (v: number): number => Math.round(v * 1e6) / 1e6 || 0;

// ------------------------------------------------------------------------------------------------ refusals

/** The launchpad's errors (contracts/launchpad Error) with a stable code: LaunchesDisabled and QuoteNotAllowed (new
 *  launches in that quote are off), CurveClosed and AlreadyGraduated, SlippageExceeded, NothingToClaim. The others keep
 *  the simulation's own message. */
const REFUSALS: Record<number, ContractErrorCode> = {
  1: "launch.disabled",
  2: "launch.disabled",
  8: "launch.closed",
  10: "launch.slippage",
  12: "launch.closed",
  16: "launch.nothing_to_claim",
};

/** The launchpad's UnknownLaunch. */
const UNKNOWN_LAUNCH = 7;

const REFUSAL_TEXT: Partial<Record<ContractErrorCode, string>> = {
  "launch.slippage": "The price moved past your limit. Nothing was sent.",
  "launch.closed": "This curve isn't taking trades now.",
  "launch.disabled": "New launches are paused.",
  "launch.nothing_to_claim": "Nothing to claim yet.",
};

/** The number of the error `launchpad` itself failed with, from a simulation's error text: the host logs the contract
 *  that failed "with contract error". A failure further down (a token's balance, a missing account) is logged by
 *  another contract, and the launchpad only passes it on. */
export function launchpadError(raw: string, launchpad: string): number | null {
  const failed = /contract:(C[A-Z2-7]{55}), topics:\[error, Error\(Contract, #(\d+)\)\], data:\["failing with contract error"/g;
  for (const m of raw.matchAll(failed)) if (m[1] === launchpad) return Number(m[2]);
  return null;
}

/** The stable code of a refusal by `launchpad` itself (§6.13), or null. */
export function launchRefusal(raw: string, launchpad: string): ContractErrorCode | null {
  const n = launchpadError(raw, launchpad);
  return n === null ? null : REFUSALS[n] ?? null;
}

/** A contract's refusal as the API answers it: simulation_failed, its stable code and the raw error when there is one. */
export function refusal(code: ContractErrorCode, raw?: string): ApiError {
  return new ApiError(422, "simulation_failed", REFUSAL_TEXT[code] ?? "The contract refused this.", raw === undefined ? { contractCode: code } : { contractCode: code, raw });
}

function rawOf(err: unknown): string | null {
  return err instanceof ApiError && err.code === "simulation_failed" ? String((err.detail as { raw?: unknown } | undefined)?.raw ?? "") : null;
}

/** Runs a simulation against the launchpad; its own refusals get their stable codes. */
async function refusing<T>(launchpad: string, run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    const raw = rawOf(err);
    const code = raw === null ? null : launchRefusal(raw, launchpad);
    if (code) throw refusal(code, raw!);
    throw err;
  }
}

// ------------------------------------------------------------------------------------------------ rows

/** What a launch's USD figures need: the quotes' reference prices now and a day ago, and the time they're for. */
export interface PriceContext {
  net: NetworkConfig;
  now: number;
  refs: Record<PriceRef, RefPrice>;
  /** ref_usd_at(ref, now − 24 h), read only when a row has a 24 h change. */
  dayAgo: Record<PriceRef, number | null> | null;
}

async function priceContext(rows: Row[], net: NetworkConfig, now: number, refs?: Record<PriceRef, RefPrice>): Promise<PriceContext> {
  const p: PriceContext = { net, now, refs: refs ?? await referencePrices(now, net), dayAgo: null };
  if (rows.some((r) => known(r.price_24h) && now - new Date(r.created_at).getTime() >= DAY)) {
    const found = await sql()`select ref, lite.ref_usd_at(ref, ${new Date(now - DAY)}) as usd from unnest(${REFS}::text[]) as ref`;
    const usd = (ref: PriceRef) => found.find((f) => f.ref === ref)?.usd;
    p.dayAgo = Object.fromEntries(REFS.map((ref) => [ref, known(usd(ref)) ? Number(usd(ref)) : null])) as Record<PriceRef, number | null>;
  }
  return p;
}

/** A quote asset's USD price now and a day ago, and whether the price now is stale. */
function quoteUsd(asset: AssetInfo | undefined, p: PriceContext): { now: number | null; dayAgo: number | null; stale: boolean } {
  const ref = asset?.priceRef;
  if (!ref) return { now: null, dayAgo: null, stale: true };
  return { now: p.refs[ref].usd, dayAgo: p.dayAgo?.[ref] ?? null, stale: p.refs[ref].stale };
}

/** The quote price a launch stands at: its last price (the curve's last trade, or the pool's last sync), else the pool's
 *  reserves after graduation, else the curve's (the opening ones before any trade). */
export function priceOf(r: Row): string {
  if (known(r.last_price)) return decimalText(scaled(num(r.last_price)));
  const poolToken = big(r.pool_token);
  if (r.graduated === true && poolToken > 0n) return ratio(big(r.pool_quote), poolToken);
  const tokenReserve = big(r.token_reserve);
  return tokenReserve > 0n ? ratio(big(r.quote_reserve), tokenReserve) : "0";
}

function progressOf(r: Row): number {
  if (r.graduated === true) return 1;
  const threshold = big(r.threshold);
  return threshold > 0n ? Math.min(1, Number((big(r.real_quote) * 10_000n) / threshold) / 10_000) : 0;
}

/** A LaunchRow with every figure this server adds. */
export type FullLaunchRow = LaunchRow & Required<Pick<LaunchRow, "phase" | "priceQuote" | "priceUsd" | "change24h" | "isNew" | "marketCapQuote" | "marketCapUsd" | "volume24hQuote" | "volume24hUsd" | "holders" | "holdersComplete" | "lookAlike">>;

/** A lite.launches row, with launchQuery()'s figures, as the API's LaunchRow (§6.9). */
export function launchRowOf(r: Row, p: PriceContext): FullLaunchRow {
  const quote = assetById(p.net, String(r.quote));
  const usd = quoteUsd(quote, p);
  const decimals = quote?.decimals ?? TOKEN_DECIMALS;
  const supply = big(r.supply);
  const burned = big(r.burned_total ?? r.burned);
  const circulating = supply - burned;
  const priceQuote = priceOf(r);
  const priceNow = Number(priceQuote);
  const isNew = p.now - new Date(r.created_at).getTime() < DAY;
  const marketCap = decimalText((scaled(priceQuote) * circulating) / 10n ** BigInt(TOKEN_DECIMALS), decimals);
  const volume24h = unitsText(big(r.volume_24h), decimals);
  const price24h = known(r.price_24h) ? Number(num(r.price_24h)) : null;
  const change24h = !isNew && price24h !== null && price24h > 0 && usd.now !== null && usd.dayAgo !== null && usd.dayAgo > 0
    ? fraction((priceNow * usd.now) / (price24h * usd.dayAgo) - 1)
    : null;
  return {
    token: String(r.token),
    creator: String(r.creator),
    quote: String(r.quote),
    name: String(r.name),
    symbol: String(r.symbol),
    uri: String(r.uri ?? ""),
    supply: supply.toString(),
    quoteReserve: num(r.quote_reserve),
    tokenReserve: num(r.token_reserve),
    realQuote: num(r.real_quote),
    threshold: num(r.threshold),
    progress: progressOf(r),
    completed: r.completed === true,
    graduated: r.graduated === true,
    pair: known(r.pair) ? String(r.pair) : null,
    lastPrice: known(r.last_price) ? decimalText(scaled(num(r.last_price))) : null,
    volume: num(r.volume_quote),
    trades: Number(r.trades ?? 0),
    createdAt: iso(r.created_at)!,
    ...(quote ? { quoteCode: quote.code } : {}),
    image: known(r.image_url) ? String(r.image_url) : null,
    description: known(r.description) ? String(r.description) : null,
    links: linksOf(r.links),
    burned: burned.toString(),
    circulating: circulating.toString(),
    phase: r.graduated === true ? "graduated" : r.completed === true ? "completed" : "curve",
    priceQuote,
    priceUsd: usd.now === null ? null : usdPrice(priceNow * usd.now),
    change24h,
    isNew,
    marketCapQuote: marketCap,
    marketCapUsd: usd.now === null ? null : usdAmount(Number(marketCap) * usd.now),
    volume24hQuote: volume24h,
    volume24hUsd: usd.now === null ? null : usdAmount(Number(volume24h) * usd.now),
    holders: Number(r.holders ?? 0),
    holdersComplete: r.holders_complete !== false,
    ...(known(r.fee_bps) ? { feeBps: Number(r.fee_bps) } : {}),
    ...(known(r.protocol_share_bps) ? { protocolShareBps: Number(r.protocol_share_bps) } : {}),
    creatorFeeBps: Number(r.creator_fee_bps ?? 0),
    poolFeeBps: known(r.pool_fee_bps) ? Number(r.pool_fee_bps) : null,
    lookAlike: r.look_alike === true,
    graduatedAt: iso(r.graduated_at),
    lastTradeAt: iso(r.last_trade_at),
  };
}

/** lite.launches rows (`l`) with what a LaunchRow adds up from the other tables: every burn seen (`b`: the graduation's
 *  is also on the row, so the larger counts), holders besides the launchpad and the pair, the last 24 hours' volume on
 *  the curve and in the pool, and the price a day ago. */
function launchQuery(where: Fragment, order: Fragment, limit: number, offset: number, dayAgo: Date): Promise<Row[]> {
  const pad = env.network.contracts.launchpad;
  return sql()`
    select l.*, greatest(l.burned, coalesce(b.burned, 0)) as burned_total,
           lite.launch_holders(l.token, array[${pad}::text, l.pair]) as holders,
           coalesce((select sum(t.quote_amount) from lite.launch_trades t where t.token = l.token and t.ts > ${dayAgo}), 0)
             + coalesce((select sum(s.quote_amount) from lite.pool_swaps s where s.token = l.token and s.ts > ${dayAgo}), 0) as volume_24h,
           lite.token_price_at(l.token, ${dayAgo}) as price_24h
      from lite.launches l
      left join lateral (select sum(e.amount) as burned from lite.token_events e where e.token = l.token and e.kind = 'burn') as b on true
     ${where} ${order}
     limit ${limit} offset ${offset}` as unknown as Promise<Row[]>;
}

/** A search over launches: the token id exactly, or the ticker or name containing `q`, case-insensitively. */
function searchFilter(q: string | null): Fragment {
  if (q === null) return sql()``;
  const pattern = `%${q.replace(/[\\%_]/g, (c) => `\\${c}`)}%`;
  return sql()`and (l.token = ${q} or l.symbol ilike ${pattern} or l.name ilike ${pattern})`;
}

// ------------------------------------------------------------------------------------------------ the board

export type BoardSection = "explore" | "graduated";
export type BoardSort = "newest" | "market_cap" | "near_graduation";
const BOARD_SORTS: BoardSort[] = ["newest", "market_cap", "near_graduation"];
/** The sorts older clients send, without a section. */
const LEGACY_SORTS = ["new", "hot", "graduated"];

export interface BoardQuery {
  /** Null for the older clients' form, sort=new|hot|graduated, answered as {launches}. */
  section: BoardSection | null;
  sort: string;
  q: string | null;
  limit: number;
  /** From 1; a cursor is "page-N". */
  page: number;
}

/** GET /v1/launches' query: section, sort, q, limit and cursor (a nextCursor, "page-N"). */
export function boardQuery(params: URLSearchParams): BoardQuery {
  const section = params.get("section");
  const sort = params.get("sort");
  const limitText = params.get("limit");
  const limit = limitText === null || limitText === "" ? 50 : Number(limitText);
  if (!Number.isInteger(limit) || limit < 1 || limit > BOARD_LIMIT_MAX) throw bad("bad_arg", `limit must be an integer from 1 to ${BOARD_LIMIT_MAX}.`);
  const q = params.get("q")?.trim() || null;
  if (q !== null && q.length > 64) throw bad("bad_arg", "q is at most 64 characters.");
  const cursor = params.get("cursor");
  const page = cursor ? Number(/^page-([1-9][0-9]{0,5})$/.exec(cursor)?.[1] ?? NaN) : 1;
  if (!Number.isInteger(page)) throw bad("bad_arg", "cursor is a nextCursor this route answered.");
  if (section === null && (sort === null || LEGACY_SORTS.includes(sort))) return { section: null, sort: sort ?? "new", q, limit, page };
  if (section !== null && section !== "explore" && section !== "graduated") throw bad("bad_arg", "section is explore or graduated.");
  if (sort !== null && !BOARD_SORTS.includes(sort as BoardSort)) throw bad("bad_arg", "sort is newest, market_cap or near_graduation.");
  return { section: (section ?? "explore") as BoardSection, sort: sort ?? "newest", q, limit, page };
}

/** Each quote asset's USD price now, by contract: what ordering by market cap multiplies by. */
function usdByContract(net: NetworkConfig, refs: Record<PriceRef, RefPrice>): Record<string, number> {
  const out: Record<string, number> = {};
  for (const a of net.assets) {
    const usd = a.priceRef ? refs[a.priceRef].usd : null;
    if (usd !== null) out[a.contract] = usd;
  }
  return out;
}

function boardOrder(section: BoardSection, sort: BoardSort, usd: Record<string, number>): Fragment {
  if (sort === "market_cap") {
    // Market cap in USD: price × circulating × the quote's price (unpriced last).
    return sql()`order by coalesce(l.last_price, l.quote_reserve / nullif(l.token_reserve, 0))
                          * (l.supply - greatest(l.burned, coalesce(b.burned, 0)))
                          * (${sql().json(usd)}::jsonb ->> l.quote)::numeric desc nulls last, l.created_at desc, l.token`;
  }
  // Graduated coins are newest first by graduation; near graduation means nothing for them.
  if (section === "graduated") return sql()`order by coalesce(l.graduated_at, l.updated_at) desc, l.token`;
  if (sort === "near_graduation") return sql()`order by l.real_quote / nullif(l.threshold, 0) desc nulls last, l.created_at desc, l.token`;
  return sql()`order by l.created_at desc, l.token`;
}

/** The older clients' sorts: all by age, the curves by all-time volume, the graduated by graduation. */
function legacyBoard(sort: string): [Fragment, Fragment] {
  if (sort === "hot") return [sql()`where l.listed and not l.graduated`, sql()`order by l.volume_quote desc, l.created_at desc, l.token`];
  if (sort === "graduated") return [sql()`where l.listed and l.graduated`, sql()`order by coalesce(l.graduated_at, l.updated_at) desc, l.token`];
  return [sql()`where l.listed`, sql()`order by l.created_at desc, l.token`];
}

/** GET /v1/launches (§6.9): listed launches only (a deployment's smoke launches never are). Explore holds every coin that
 *  hasn't graduated, completed curves included. */
export async function launchBoard(query: BoardQuery, scope: View, now: number = Date.now()): Promise<LaunchBoard> {
  const net = env.network;
  const dayAgo = new Date(now - DAY);
  const search = searchFilter(query.q);
  if (query.section === null) {
    const [where, order] = legacyBoard(query.sort);
    const rows = await launchQuery(sql()`${where} ${search}`, order, query.limit, 0, dayAgo);
    const p = await priceContext(rows, net, now);
    return { launches: rows.map((r) => launchRowOf(r, p)), view: scope };
  }
  const refs = await referencePrices(now, net);
  const graduated = query.section === "graduated";
  const where = sql()`where l.listed and ${graduated ? sql()`l.graduated` : sql()`not l.graduated`} ${search}`;
  const order = boardOrder(query.section, query.sort as BoardSort, usdByContract(net, refs));
  const [rows, counts] = await Promise.all([
    launchQuery(where, order, query.limit + 1, (query.page - 1) * query.limit, dayAgo),
    sql()`select count(*) filter (where not l.graduated)::int as explore, count(*) filter (where l.graduated)::int as graduated
            from lite.launches l where l.listed ${search}`,
  ]);
  const page = rows.slice(0, query.limit);
  const p = await priceContext(page, net, now, refs);
  return {
    launches: page.map((r) => launchRowOf(r, p)),
    nextCursor: rows.length > query.limit ? `page-${query.page + 1}` : null,
    counts: { explore: Number(counts[0]?.explore ?? 0), graduated: Number(counts[0]?.graduated ?? 0) },
    view: scope,
  };
}

// ------------------------------------------------------------------------------------------------ a launch's page

/** ?candles= of a launch's page, as Postgres intervals. */
const CANDLES: Record<string, string> = { "1m": "1 minute", "5m": "5 minutes", "1h": "1 hour", "1d": "1 day" };
/** pricePoints holds at most this many points. */
const MAX_POINTS = 300;
/** Bucket widths for pricePoints when a launch has more trades than points, the smallest first. */
const POINT_BUCKETS_S = [60, 300, 900, 3_600, 14_400, 86_400, 604_800];

const curves = new Map<string, { at: number; curve: Row }>();

/** The launchpad's get_curve(token); null when it can't be read. A read younger than `maxAgeMs` is answered from the
 *  isolate: 30 s for the public view and My Launchpad, none (a fresh read) for an owner's page, quotes and plans, which
 *  must see a trade the user just made. */
async function liveCurve(token: string, now: number = Date.now(), maxAgeMs: number = CURVE_TTL_MS): Promise<Row | null> {
  const pad = env.network.contracts.launchpad;
  if (!pad) return null;
  const hit = curves.get(token);
  if (hit && now - hit.at < maxAgeMs && now >= hit.at) return hit.curve;
  try {
    const curve = await view(pad, "get_curve", [sv.addr(token)]);
    if (curves.size > 1_000) curves.clear();
    curves.set(token, { at: now, curve });
    return curve;
  } catch {
    return null;
  }
}

/** Drops the isolate's curves and launch market rows (tests). */
export function forgetLaunchReads(): void {
  curves.clear();
  marketCache = null;
}

/** A trade on the curve or in the pool, as an address's position adds it up. */
export interface Fill {
  side: "buy" | "sell";
  /** Quote base units spent or received. */
  quote: bigint;
  /** Token base units bought or sold. */
  tokens: bigint;
}

/** An address's cost basis and P&L in one launch, in quote base units (§6.9 `you`; §6.7's launch P&L), over its curve
 *  trades and pool swaps, oldest first:
 *  - cost basis: what the tokens it still holds from those trades cost, on average (a sell takes its share of the cost);
 *  - P&L: quote received − quote spent + those tokens at `price` (quote per whole token, 18 decimals).
 *  Neither counts more tokens than `balance` holds. Null without trades: coins received by transfer have neither. */
export function positionOf(fills: Fill[], balance: bigint, price: bigint): { costBasis: bigint; pnl: bigint } | null {
  if (fills.length === 0) return null;
  let held = 0n;
  let cost = 0n;
  let spent = 0n;
  let received = 0n;
  for (const f of fills) {
    if (f.side === "buy") {
      held += f.tokens;
      cost += f.quote;
      spent += f.quote;
    } else {
      const sold = f.tokens < held ? f.tokens : held;
      if (held > 0n) cost -= (cost * sold) / held;
      held -= sold;
      received += f.quote;
    }
  }
  const counted = balance < held ? (balance > 0n ? balance : 0n) : held;
  const costBasis = held > 0n ? (cost * counted) / held : 0n;
  return { costBasis, pnl: received - spent + (counted * price) / SCALE };
}

/** An address's curve trades and pool swaps in `tokens`, oldest first, by token. */
async function fillsOf(address: string, tokens: string[]): Promise<Map<string, Fill[]>> {
  const out = new Map<string, Fill[]>();
  if (tokens.length === 0) return out;
  const rows = await sql()`
    select token, side, quote_amount, token_amount from (
      select token, side, quote_amount, token_amount, ts, event_id from lite.launch_trades where trader = ${address} and token = any(${tokens}::text[])
      union all
      select token, side, quote_amount, token_amount, ts, event_id from lite.pool_swaps where trader = ${address} and token = any(${tokens}::text[])
    ) as f order by ts, event_id`;
  for (const f of rows) {
    const token = String(f.token);
    if (!out.has(token)) out.set(token, []);
    out.get(token)!.push({ side: f.side === "sell" ? "sell" : "buy", quote: big(f.quote_amount), tokens: big(f.token_amount) });
  }
  return out;
}

/** An address's indexed balance of a launch token (0 when it holds none, or the index fell short). */
async function indexedBalance(token: string, address: string): Promise<bigint> {
  const rows = await sql()`select balance from lite.token_balances where token = ${token} and address = ${address}`;
  const b = rows.length ? big(rows[0].balance) : 0n;
  return b > 0n ? b : 0n;
}

/** An address's balance of a launch token, read live, or the indexed one when it can't be. */
async function liveBalance(token: string, address: string): Promise<bigint> {
  try {
    return BigInt(await view(token, "balance", [sv.addr(address)]));
  } catch {
    return await indexedBalance(token, address);
  }
}

function creatorFeesOf(quote: AssetInfo | undefined, quoteId: string, unclaimed: bigint, claimed: bigint, usd: number | null): CreatorFees {
  const inUsd = (v: bigint) => (usd === null ? null : usdAmount(Number(unitsText(v, quote?.decimals ?? TOKEN_DECIMALS)) * usd));
  return { unclaimed: unclaimed.toString(), claimed: claimed.toString(), quote: quote?.id ?? quoteId, unclaimedUsd: inUsd(unclaimed), claimedUsd: inUsd(claimed) };
}

/** The newest 50 trades, curve and pool together. A pool swap is priced by its transaction's sync, or by its own
 *  amounts until that is read. */
async function recentTrades(token: string): Promise<LaunchTrade[]> {
  const rows = await sql()`
    select * from (
      (select 'curve' as venue, trader, side, quote_amount, token_amount, price, tx_hash, ts, event_id
         from lite.launch_trades where token = ${token} order by ts desc, event_id desc limit 50)
      union all
      (select 'soroswap' as venue, trader, side, quote_amount, token_amount, coalesce(price, quote_amount / nullif(token_amount, 0)) as price,
              tx_hash, ts, event_id
         from lite.pool_swaps where token = ${token} order by ts desc, event_id desc limit 50)
    ) as t order by ts desc, event_id desc limit 50`;
  return rows.map((t) => ({
    trader: String(t.trader),
    side: t.side === "sell" ? "sell" : "buy",
    quoteAmount: num(t.quote_amount),
    tokenAmount: num(t.token_amount),
    price: decimalText(scaled(num(t.price))),
    txHash: known(t.tx_hash) ? String(t.tx_hash) : null,
    ts: iso(t.ts)!,
    venue: t.venue === "soroswap" ? "soroswap" : "curve",
  }));
}

/** The chart's points (at most 300): the opening price when the launch was made, then each trade's price; with more
 *  trades than fit, the closes of buckets just wide enough for the whole history. */
async function pricePoints(r: Row, now: number): Promise<{ t: string; price: string }[]> {
  const token = String(r.token);
  const opening = { t: iso(r.created_at)!, price: ratio(big(r.phantom), big(r.supply)) };
  const recent = await sql()`
    select ts, price from (
      (select ts, price, event_id from lite.launch_trades where token = ${token} order by ts desc, event_id desc limit ${MAX_POINTS})
      union all
      (select ts, price, event_id from lite.pool_swaps where token = ${token} and price is not null
        order by ts desc, event_id desc limit ${MAX_POINTS})
    ) as p order by ts desc, event_id desc limit ${MAX_POINTS}`;
  if (recent.length < MAX_POINTS) {
    return [opening, ...[...recent].reverse().map((p) => ({ t: iso(p.ts)!, price: decimalText(scaled(num(p.price))) }))];
  }
  const span = (now - new Date(r.created_at).getTime()) / 1000;
  const width = POINT_BUCKETS_S.find((s) => span / s <= MAX_POINTS - 1) ?? POINT_BUCKETS_S[POINT_BUCKETS_S.length - 1];
  const closes = await sql()`select bucket, close from lite.token_candles(${token}, ${`${width} seconds`}::interval, ${MAX_POINTS - 1})`;
  return [opening, ...closes.map((c) => ({ t: iso(c.bucket)!, price: decimalText(scaled(num(c.close))) }))];
}

/** Who reads a launch's page: the token's account (owner), ?address= (public), or nobody. */
export interface LaunchViewer {
  address: string | null;
  scope: View;
}

/** `you` (§6.9): the owner's live balance, cost basis and P&L; in the public view the indexed balance alone. */
async function youOf(r: Row, viewer: LaunchViewer): Promise<LaunchDetail["you"]> {
  if (viewer.address === null) return null;
  const token = String(r.token);
  const isCreator = r.creator === viewer.address;
  if (viewer.scope === "public") {
    return { balance: (await indexedBalance(token, viewer.address)).toString(), costBasisQuote: null, pnlQuote: null, isCreator };
  }
  const [balance, fills] = await Promise.all([liveBalance(token, viewer.address), fillsOf(viewer.address, [token])]);
  const position = positionOf(fills.get(token) ?? [], balance, scaled(priceOf(r)));
  return { balance: balance.toString(), costBasisQuote: position?.costBasis.toString() ?? null, pnlQuote: position?.pnl.toString() ?? null, isCreator };
}

/** GET /v1/launches/:token (§6.9). */
export async function launchDetail(token: string, viewer: LaunchViewer, candles?: string, now: number = Date.now()): Promise<LaunchDetail> {
  if (!isContractId(token)) throw notFound("Launch");
  const net = env.network;
  const rows = await launchQuery(sql()`where l.token = ${token}`, sql()``, 1, 0, new Date(now - DAY));
  if (rows.length === 0) throw notFound("Launch");
  const r = rows[0];
  const interval = candles ? CANDLES[candles] : undefined;
  const [p, curve, trades, candleRows, points, you] = await Promise.all([
    priceContext(rows, net, now),
    liveCurve(token, now, viewer.scope === "owner" ? 0 : CURVE_TTL_MS),
    recentTrades(token),
    interval ? sql()`select bucket, open, high, low, close, volume from lite.token_candles(${token}, ${interval}::interval, 300)` : Promise.resolve([] as Row[]),
    pricePoints(r, now),
    youOf(r, viewer),
  ]);
  const launch = launchRowOf(r, p);
  const quote = assetById(net, launch.quote);
  const usd = quoteUsd(quote, p);
  return {
    launch,
    curve: curve
      ? {
        quoteReserve: String(curve.quote_reserve),
        tokenReserve: String(curve.token_reserve),
        realQuote: String(curve.real_quote),
        threshold: String(curve.threshold),
        creatorFees: String(curve.creator_fees),
        completed: curve.completed === true,
        graduated: curve.graduated === true,
        pair: known(curve.pair) ? String(curve.pair) : null,
      }
      : null,
    trades,
    candles: candleRows.map((c) => ({
      t: iso(c.bucket)!,
      o: decimalText(scaled(num(c.open))),
      h: decimalText(scaled(num(c.high))),
      l: decimalText(scaled(num(c.low))),
      c: decimalText(scaled(num(c.close))),
      v: num(c.volume),
    })),
    stats: {
      volume24hQuote: launch.volume24hQuote,
      volume24hUsd: launch.volume24hUsd,
      holders: launch.holders,
      holdersComplete: launch.holdersComplete,
      marketCapQuote: launch.marketCapQuote,
      marketCapUsd: launch.marketCapUsd,
      priceQuote: launch.priceQuote,
      priceUsd: launch.priceUsd,
      change24h: launch.change24h,
    },
    ...(curve ? { creatorFees: creatorFeesOf(quote, launch.quote, BigInt(curve.creator_fees), big(r.creator_fees_claimed), usd.now) } : {}),
    you,
    ...(known(r.fee_bps) && known(r.protocol_share_bps)
      ? {
        economics: {
          feeBps: Number(r.fee_bps),
          protocolShareBps: Number(r.protocol_share_bps),
          creatorFeeBps: Number(r.creator_fee_bps),
          supply: num(r.supply),
          phantom: num(r.phantom),
          threshold: num(r.threshold),
        },
      }
      : {}),
    pricePoints: points,
    view: viewer.scope,
  };
}

// ------------------------------------------------------------------------------------------------ quotes

/** POST /v1/launches/:token/quote: what the curve would do now, every fee apart (§6.9). A sell on a curve that no
 *  longer trades is refused as the sell itself would be. */
export async function quoteTrade(user: string, token: string, side: "buy" | "sell", amount: bigint): Promise<TradeQuote> {
  const pad = launchpadId();
  if (!isContractId(token)) throw notFound("Launch");
  if (side === "buy") {
    const q = await refusing(pad, () => view(pad, "quote_buy", [sv.addr(token), sv.addr(user), sv.i128(amount)]));
    const [used, baseFee, creatorFee, snipeFee] = [BigInt(q.used), BigInt(q.base_fee), BigInt(q.creator_fee), BigInt(q.snipe_fee)];
    return {
      side,
      used: used.toString(),
      tokensOut: String(q.tokens_out),
      fees: (baseFee + creatorFee + snipeFee).toString(),
      snipeFee: snipeFee.toString(),
      baseFee: baseFee.toString(),
      creatorFee: creatorFee.toString(),
      refund: (amount - used).toString(),
    };
  }
  const curve = await liveCurve(token, Date.now(), 0);
  if (curve && (curve.completed === true || curve.graduated === true)) throw refusal("launch.closed");
  const q = await refusing(pad, () => view(pad, "quote_sell", [sv.addr(token), sv.i128(amount)]));
  const [baseFee, creatorFee] = [BigInt(q.base_fee), BigInt(q.creator_fee)];
  return { side, quoteOut: String(q.quote_out), fees: (baseFee + creatorFee).toString(), baseFee: baseFee.toString(), creatorFee: creatorFee.toString() };
}

// ------------------------------------------------------------------------------------------------ plans

export interface LaunchBuildInput {
  action: "create" | "buy" | "sell" | "graduate" | "claim";
  token?: string;
  quote?: string;
  name?: string;
  symbol?: string;
  uri?: string;
  creatorFeeBps?: number;
  amount?: string;
  minOut?: string;
}

/** Base units as a decimal string, above zero unless `zero` allows it; 400 bad_amount otherwise. */
function unitsArg(v: unknown, name: string, zero = false): string {
  if (typeof v !== "string" || !/^[0-9]{1,30}$/.test(v) || (!zero && BigInt(v) === 0n)) {
    throw bad("bad_amount", `${name} must be a whole number of base units${zero ? "" : " above 0"}, as a string.`);
  }
  return BigInt(v).toString();
}

function tokenArg(v: unknown): string {
  if (typeof v !== "string" || !isContractId(v)) throw bad("bad_arg", "token is required: the launch token's contract id (C…).");
  return v;
}

/** A launch's quote asset, ticker and creator: indexed, or read from the launchpad; 404 for a token it didn't launch. */
async function launchOf(token: string): Promise<{ quote: string; symbol: string; creator: string }> {
  const rows = await sql()`select quote, symbol, creator from lite.launches where token = ${token}`;
  if (rows.length) return { quote: String(rows[0].quote), symbol: String(rows[0].symbol), creator: String(rows[0].creator) };
  const pad = launchpadId();
  try {
    const l = await view(pad, "get_launch", [sv.addr(token)]);
    return { quote: String(l.quote), symbol: String(l.symbol), creator: String(l.creator) };
  } catch (err) {
    const raw = rawOf(err);
    if (raw !== null && launchpadError(raw, pad) === UNKNOWN_LAUNCH) throw notFound("Launch");
    throw err;
  }
}

/** POST /v1/launches/build (§6.9). Create takes a name of at most 32 bytes, a 2–10 character ticker that doesn't imitate
 *  a reserved one, and a URI that is empty or metadata this address wrote; buy and sell take the client's minimum
 *  (its fixed 1%); graduate is any user's to call and pay for; claim pays one launch's creator fees, or with no token
 *  every launch of this creator with fees waiting, one step each. */
export async function buildLaunch(user: string, input: Partial<LaunchBuildInput>): Promise<PlanView> {
  launchpadId();
  switch (input.action) {
    case "create": {
      const quote = quoteAsset(String(input.quote ?? "XLM"));
      const name = launchName(input.name);
      const symbol = launchSymbol(input.symbol);
      const fee = Number(input.creatorFeeBps ?? 0);
      if (!Number.isInteger(fee) || fee < 0 || fee > 1_000) throw bad("bad_fee", "Creator fee: 0–10%.");
      const uri = typeof input.uri === "string" ? input.uri : "";
      if (uri.length > env.network.limits.uriMax) throw bad("bad_uri", "Metadata link is too long.");
      await checkLaunchUri(user, uri, name, symbol);
      const initialBuy = known(input.amount) ? unitsArg(input.amount, "amount", true) : "0";
      const minOut = known(input.minOut) ? unitsArg(input.minOut, "minOut", true) : "0";
      return await createPlan(user, "launch_create", [{
        label: `Launch ${symbol}`,
        spec: { kind: "launch_create", quote: quote.contract, name, symbol, uri, creatorFeeBps: fee, initialBuy, minOut },
      }]);
    }
    case "buy":
    case "sell": {
      const token = tokenArg(input.token);
      const amount = unitsArg(input.amount, "amount");
      const minOut = unitsArg(input.minOut, "minOut");
      const { symbol } = await launchOf(token);
      const kind = `launch_${input.action}`;
      return await createPlan(user, kind, [{ label: `${input.action === "buy" ? "Buy" : "Sell"} ${symbol}`, spec: { kind, token, amount, minOut } }]);
    }
    case "graduate": {
      const token = tokenArg(input.token);
      const { symbol } = await launchOf(token);
      return await createPlan(user, "launch_graduate", [{ label: `Graduate ${symbol}`, spec: { kind: "launch_graduate", token } }]);
    }
    case "claim": {
      if (known(input.token)) {
        const token = tokenArg(input.token);
        const launch = await launchOf(token);
        if (launch.creator !== user) throw bad("bad_arg", "Only the coin's creator can claim its fees.");
        return await createPlan(user, "launch_claim", [{ label: `Claim ${launch.symbol} fees`, spec: { kind: "launch_claim", token } }]);
      }
      const created = await sql()`select token, symbol from lite.launches where creator = ${user} order by created_at`;
      const live = await Promise.all(created.map((c) => liveCurve(String(c.token), Date.now(), 0)));
      const waiting = created.filter((_, i) => live[i] !== null && BigInt(live[i]!.creator_fees) > 0n);
      if (waiting.length === 0) {
        if (live.some((c) => c === null)) throw new ApiError(502, "rpc_unavailable", "Your creator fees couldn't be read just now. Try again.");
        throw refusal("launch.nothing_to_claim");
      }
      return await createPlan(user, "launch_claim", waiting.map((c) => ({ label: `Claim ${c.symbol} fees`, spec: { kind: "launch_claim", token: String(c.token) } })));
    }
    default:
      throw bad("bad_action", "Unknown action.");
  }
}

export const launchCreateStep: Builder = async (user, spec) => {
  const pad = launchpadId();
  const acct = await requireAccount(user);
  const initialBuy = String(spec.initialBuy ?? "0");
  const minOut = String(spec.minOut ?? "0");
  const tx = await refusing(pad, () =>
    invoke(acct, pad, "launch", [
      sv.addr(user),
      sv.addr(String(spec.quote)),
      sv.str(String(spec.name)),
      sv.str(String(spec.symbol)),
      sv.str(String(spec.uri ?? "")),
      sv.u32(Number(spec.creatorFeeBps ?? 0)),
      sv.i128(initialBuy),
      sv.i128(minOut),
    ])
  );
  const q = assetById(env.network, String(spec.quote));
  const intent: Intent = {
    kind: "launch_create",
    summary: `Launch ${spec.symbol}${initialBuy !== "0" ? ` and buy with ${fromStroops(initialBuy)} ${q?.code}` : ""}`,
    spend: initialBuy !== "0" ? { [String(spec.quote)]: initialBuy } : {},
    calls: [{ contract: pad, fn: "launch" }],
    display: { symbol: String(spec.symbol), name: String(spec.name), quote: q?.code ?? "", initialBuy, minOut, creatorFeeBps: Number(spec.creatorFeeBps ?? 0) },
  };
  return { tx, intent };
};

// Curve trades act for the user (buyer/seller = user) and bind the client's minimum through intent.receive, as the
// verifier's call rules for buy and sell read it (verify.ts).
export const launchBuyStep: Builder = async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { quote, symbol } = await launchOf(token);
  const acct = await requireAccount(user);
  const amount = String(spec.amount);
  const minOut = String(spec.minOut ?? "0");
  const tx = await refusing(pad, () => invoke(acct, pad, "buy", [sv.addr(user), sv.addr(token), sv.i128(amount), sv.i128(minOut)]));
  const q = assetById(env.network, quote);
  return {
    tx,
    intent: {
      kind: "launch_buy",
      summary: `Buy ${symbol} with ${fromStroops(amount)} ${q?.code ?? ""}`,
      spend: { [quote]: amount },
      receive: { [token]: minOut },
      calls: [{ contract: pad, fn: "buy" }],
      display: { token, symbol, quote: q?.code ?? "", amount, minOut },
    },
  };
};

export const launchSellStep: Builder = async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { quote, symbol } = await launchOf(token);
  const acct = await requireAccount(user);
  const amount = String(spec.amount);
  const minOut = String(spec.minOut ?? "0");
  const tx = await refusing(pad, () => invoke(acct, pad, "sell", [sv.addr(user), sv.addr(token), sv.i128(amount), sv.i128(minOut)]));
  const q = assetById(env.network, quote);
  return {
    tx,
    intent: {
      kind: "launch_sell",
      summary: `Sell ${fromStroops(amount)} ${symbol}`,
      spend: { [token]: amount },
      receive: { [quote]: minOut },
      calls: [{ contract: pad, fn: "sell" }],
      display: { token, symbol, quote: q?.code ?? "", amount, minOut },
    },
  };
};

// Anyone may graduate a completed curve; a user who does pays its network fee, as for any step of theirs.
export const launchGraduateStep: Builder = async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { symbol } = await launchOf(token);
  const acct = await requireAccount(user);
  const tx = await refusing(pad, () => invoke(acct, pad, "graduate", [sv.addr(token)]));
  return {
    tx,
    intent: { kind: "launch_graduate", summary: `Move ${symbol} to Soroswap`, spend: {}, calls: [{ contract: pad, fn: "graduate" }], display: { token, symbol, venue: "Soroswap" } },
  };
};

export const launchClaimStep: Builder = async (user, spec) => {
  const pad = launchpadId();
  const token = String(spec.token);
  const { quote, symbol } = await launchOf(token);
  const acct = await requireAccount(user);
  const tx = await refusing(pad, () => invoke(acct, pad, "claim_creator_fees", [sv.addr(token)]));
  const curve = await liveCurve(token, Date.now(), 0);
  const q = assetById(env.network, quote);
  return {
    tx,
    intent: {
      kind: "launch_claim",
      summary: `Claim your ${symbol} creator fees`,
      spend: {},
      calls: [{ contract: pad, fn: "claim_creator_fees" }],
      // The launchpad pays the launch's creator, this user.
      display: { token, symbol, quote: q?.code ?? "", amount: curve ? String(curve.creator_fees) : null, to: user },
    },
  };
};

registerBuilder("launch_create", launchCreateStep);
registerBuilder("launch_buy", launchBuyStep);
registerBuilder("launch_sell", launchSellStep);
registerBuilder("launch_graduate", launchGraduateStep);
registerBuilder("launch_claim", launchClaimStep);

// ------------------------------------------------------------------------------------------------ markets and search

/** Launch market rows are kept this long per isolate. */
const MARKET_TTL_MS = 15_000;
/** The markets take at most this many launches, the newest. */
const MARKET_LAUNCHES_MAX = 500;

let marketCache: { at: number; rows: Record<string, unknown>[] } | null = null;

function marketRowOf(l: FullLaunchRow, stale: boolean): Record<string, unknown> {
  return {
    id: l.token,
    kind: "launch",
    contract: l.token,
    classic: null,
    code: l.symbol,
    name: l.name,
    decimals: TOKEN_DECIMALS,
    logo: null,
    image: l.image ?? null,
    verified: !l.lookAlike,
    badges: l.lookAlike ? ["launch", "lookAlike"] : ["launch"],
    note: null,
    priceUsd: l.priceUsd,
    change24h: l.isNew ? null : l.change24h,
    isNew: l.isNew,
    volume24hUsd: l.volume24hUsd,
    marketCapUsd: l.marketCapUsd,
    priceSource: { kind: l.graduated ? "pool" : "curve", quote: l.quoteCode ?? l.quote, quotePrice: l.priceQuote, at: l.lastTradeAt ?? l.createdAt },
    stale,
    launch: { phase: l.phase, progress: l.progress, pair: l.pair },
  };
}

/** Listed launch tokens as market rows (kind "launch", MarketRow's fields; §6.6), by 24 h USD volume, then newest. A
 *  ticker that imitates another carries the lookAlike badge (the markets never list it); a row is stale when its quote's
 *  reference price is. A read that fails leaves the launches out of the markets for that request, logged: the
 *  registry's rows still answer. */
export async function launchMarketRows(now: number = Date.now()): Promise<Record<string, unknown>[]> {
  if (marketCache && now - marketCache.at < MARKET_TTL_MS && now >= marketCache.at) return marketCache.rows;
  try {
    const net = env.network;
    const rows = await launchQuery(sql()`where l.listed`, sql()`order by l.created_at desc, l.token`, MARKET_LAUNCHES_MAX, 0, new Date(now - DAY));
    const p = await priceContext(rows, net, now);
    const out = rows
      .map((r) => ({ row: launchRowOf(r, p), stale: quoteUsd(assetById(net, String(r.quote)), p).stale }))
      .sort((a, b) => (b.row.volume24hUsd ?? -1) - (a.row.volume24hUsd ?? -1))
      .map(({ row, stale }) => marketRowOf(row, stale));
    marketCache = { at: now, rows: out };
    return out;
  } catch (err) {
    console.warn("launchMarketRows: launches left out of the markets", String((err as Error).message ?? err).slice(0, 200));
    return [];
  }
}

/** The history ranges (markets.ts): a day in 15-minute buckets, a week and a month hourly, all of it daily. */
const HISTORY: Record<"day" | "week" | "month" | "all", { intervalS: number; reach: number | null }> = {
  day: { intervalS: 900, reach: DAY },
  week: { intervalS: 3_600, reach: 7 * DAY },
  month: { intervalS: 3_600, reach: 30 * DAY },
  all: { intervalS: 86_400, reach: null },
};

/** A launch token's USD price over `range`, for /v1/markets/:id/history (§6.6): per bucket of the range's interval,
 *  from the later of the range's start and the launch, its price at the bucket's end (the last curve trade or priced
 *  pool swap by then, carried forward) times its quote's reference price in that bucket; a bucket either is unknown for
 *  is left out. A read that fails answers no points, logged. */
export async function launchHistory(token: string, range: "day" | "week" | "month" | "all", now: number = Date.now()): Promise<{ t: string; usd: number }[]> {
  try {
    const rows = await sql()`select quote, created_at from lite.launches where token = ${token}`;
    const ref = rows.length ? assetById(env.network, String(rows[0].quote))?.priceRef : null;
    if (!ref) return [];
    const { intervalS, reach } = HISTORY[range];
    const width = `${intervalS} seconds`;
    const since = reach === null ? null : new Date(now - reach);
    const until = new Date(now);
    const points = await sql()`
      select b.bucket, lite.token_price_at(${token}, least(b.bucket + ${width}::interval, ${until})) as price,
             lite.ref_usd_at(${ref}, b.bucket) as quote_usd
        from generate_series(date_bin(${width}::interval, greatest(${since}::timestamptz, ${rows[0].created_at}::timestamptz), timestamptz 'epoch'),
                             ${until}::timestamptz, ${width}::interval) as b(bucket)
       order by b.bucket`;
    return points.flatMap((p) => (known(p.price) && known(p.quote_usd) ? [{ t: iso(p.bucket)!, usd: usdPrice(Number(num(p.price)) * Number(num(p.quote_usd))) }] : []));
  } catch (err) {
    console.warn("launchHistory: no points", String((err as Error).message ?? err).slice(0, 200));
    return [];
  }
}

/** Listed launches whose token id is `q`, or whose ticker or name contains it, for /v1/assets (§6.6): at most 30, an
 *  exact ticker first, then by all-time volume. AssetResult's fields but `held`, which the asset search adds. A read
 *  that fails finds none, logged. */
export async function launchSearch(q: string): Promise<Record<string, unknown>[]> {
  const text = q.trim();
  if (!text) return [];
  try {
    const rows = await sql()`
      select l.token, l.symbol, l.name, l.look_alike from lite.launches l
       where l.listed ${searchFilter(text)}
       order by upper(l.symbol) = upper(${text}) desc, l.volume_quote desc, l.created_at desc limit 30`;
    return rows.map((r) => ({ id: String(r.token), kind: "launch", code: String(r.symbol), name: String(r.name), contract: String(r.token), classic: null, verified: r.look_alike !== true }));
  } catch (err) {
    console.warn("launchSearch: none found", String((err as Error).message ?? err).slice(0, 200));
    return [];
  }
}

// ------------------------------------------------------------------------------------------------ My Launchpad

/** GET /v1/launchpad/me (§6.9): launches held (indexed balances, cost basis and P&L over curve trades and pool swaps),
 *  launches created with their creator fees (unclaimed read live), fees by quote asset, and the launch activity. */
export async function myLaunchpad(user: string, now: number = Date.now()): Promise<MyLaunchpad> {
  const net = env.network;
  const dayAgo = new Date(now - DAY);
  const order = sql()`order by l.created_at desc, l.token`;
  const [held, created, balances] = await Promise.all([
    launchQuery(sql()`where l.token in (select tb.token from lite.token_balances tb where tb.address = ${user} and tb.balance > 0)`, order, 200, 0, dayAgo),
    launchQuery(sql()`where l.creator = ${user}`, order, 200, 0, dayAgo),
    sql()`select token, balance from lite.token_balances where address = ${user} and balance > 0`,
  ]);
  const p = await priceContext([...held, ...created], net, now);
  const balance = new Map(balances.map((b) => [String(b.token), big(b.balance)]));
  const [fills, live, activity] = await Promise.all([
    fillsOf(user, held.map((r) => String(r.token))),
    Promise.all(created.map((r) => liveCurve(String(r.token), now))),
    launchActivity(user, p),
  ]);
  if (live.some((c) => c === null)) throw new ApiError(502, "rpc_unavailable", "Your creator fees couldn't be read just now. Try again.");

  const heldItems = held.map((r) => {
    const launch = launchRowOf(r, p);
    const amount = balance.get(launch.token) ?? 0n;
    const quote = assetById(net, launch.quote);
    const usd = quoteUsd(quote, p).now;
    const position = positionOf(fills.get(launch.token) ?? [], amount, scaled(launch.priceQuote));
    return {
      token: launch.token,
      balance: amount.toString(),
      valueUsd: usd === null ? null : usdAmount(Number(unitsText(amount)) * Number(launch.priceQuote) * usd),
      costBasisQuote: position ? position.costBasis.toString() : null,
      pnlQuote: position ? position.pnl.toString() : null,
      pnlUsd: position && usd !== null ? usdAmount(Number(unitsText(position.pnl, quote?.decimals ?? TOKEN_DECIMALS)) * usd) : null,
      onCurve: !launch.graduated,
      launch,
    };
  });

  const totals = new Map<string, { asset: AssetInfo | undefined; received: bigint; claimable: bigint }>();
  const createdItems = created.map((r, i) => {
    const launch = launchRowOf(r, p);
    const quote = assetById(net, launch.quote);
    const unclaimed = BigInt(live[i]!.creator_fees);
    const claimed = big(r.creator_fees_claimed);
    const key = quote?.id ?? launch.quote;
    const t = totals.get(key) ?? { asset: quote, received: 0n, claimable: 0n };
    totals.set(key, { asset: quote, received: t.received + claimed, claimable: t.claimable + unclaimed });
    return { launch, creatorFees: creatorFeesOf(quote, launch.quote, unclaimed, claimed, quoteUsd(quote, p).now) };
  });
  const rank = (id: string) => (QUOTES.includes(id) ? QUOTES.indexOf(id) : QUOTES.length);
  const byQuote = [...totals].sort(([a], [b]) => rank(a) - rank(b)).map(([id, t]) => {
    const fees = creatorFeesOf(t.asset, id, t.claimable, t.received, quoteUsd(t.asset, p).now);
    return { quote: id, received: fees.claimed, claimable: fees.unclaimed, receivedUsd: fees.claimedUsd, claimableUsd: fees.unclaimedUsd };
  });
  return { held: heldItems, created: createdItems, fees: { byQuote }, activity };
}

/** The launch kinds of the user's activity (§6.10's items): launch plans, and swaps counted in the launch section.
 *  Who paid, the result and the section are migration 05's tx_log columns, read through to_jsonb so that this also
 *  runs on a database without them (they are null then). */
async function launchActivity(user: string, p: PriceContext): Promise<ActivityItem[]> {
  const rows = await sql()`
    select t.hash, t.kind, t.intent, t.status, t.fee_charged, t.created_at,
           to_jsonb(t) ->> 'fee_payer' as fee_payer, to_jsonb(t) -> 'result' as result
      from lite.tx_log t
     where t.address = ${user} and (left(t.kind, 7) = 'launch_' or to_jsonb(t) ->> 'section' = 'launch')
     order by t.created_at desc limit 50`;
  const named = new Set<string>();
  for (const r of rows) for (const v of Object.values(displayOf(r.intent))) if (typeof v === "string" && isContractId(v)) named.add(v);
  const launches = named.size ? await sql()`select token, symbol, name, quote from lite.launches where token = any(${[...named]}::text[])` : [];
  const byToken = new Map(launches.map((l) => [String(l.token), l]));
  return rows.map((r) => activityItem(r, byToken, p));
}

function displayOf(intent: unknown): Record<string, DisplayValue> {
  const d = (intent as { display?: unknown } | null)?.display;
  return d !== null && typeof d === "object" ? d as Record<string, DisplayValue> : {};
}

function activityItem(r: Row, launches: Map<string, Row>, p: PriceContext): ActivityItem {
  const intent = (r.intent ?? {}) as { summary?: unknown };
  const d = displayOf(r.intent);
  const token = [d.token, d.buy, d.sell].find((v): v is string => typeof v === "string" && launches.has(v)) ?? null;
  const launch = token ? launches.get(token)! : null;
  const result = (r.result ?? null) as { amountOut?: unknown } | null;
  const out = typeof result?.amountOut === "string" ? result.amountOut : null;
  const words = activityWords(String(r.kind), d, launch, out !== null && /^[0-9]+$/.test(out) ? BigInt(out) : null, p);
  return {
    type: "tx",
    id: String(r.hash),
    kind: String(r.kind),
    summary: String(intent.summary ?? ""),
    status: String(r.status),
    at: iso(r.created_at)!,
    display: Object.keys(d).length ? d : null,
    section: "launch",
    hash: String(r.hash),
    feeCharged: known(r.fee_charged) ? String(r.fee_charged) : null,
    feePayer: known(r.fee_payer) ? r.fee_payer as FeePayer : null,
    result: result ? { amountOut: out } : null,
    ref: token ? { token } : null,
    symbol: launch ? String(launch.symbol) : null,
    name: launch ? String(launch.name) : null,
    ...words,
  };
}

/** The server's English words for a launch item and its USD value at today's price (the phone words known kinds
 *  itself). */
function activityWords(kind: string, d: Record<string, DisplayValue>, launch: Row | null, amountOut: bigint | null, p: PriceContext): { title: string; subtitle: string | null; usd: Usd } {
  const symbol = launch ? String(launch.symbol) : typeof d.symbol === "string" ? d.symbol : "a coin";
  const quote = launch ? assetById(p.net, String(launch.quote)) : typeof d.quote === "string" ? assetById(p.net, d.quote) : undefined;
  const code = quote?.code ?? (typeof d.quote === "string" ? d.quote : "");
  const units = (v: DisplayValue | undefined) => (typeof v === "string" && /^[0-9]+$/.test(v) ? BigInt(v) : null);
  const inUsd = (v: bigint | null, asset: AssetInfo | undefined = quote) => {
    const usd = quoteUsd(asset, p).now;
    return v === null || usd === null ? null : usdAmount(Number(unitsText(v, asset?.decimals ?? TOKEN_DECIMALS)) * usd);
  };
  const amount = units(d.amount);
  switch (kind) {
    case "launch_create": {
      const buy = units(d.initialBuy);
      const bought = buy !== null && buy > 0n;
      return { title: `Launched ${symbol}`, subtitle: bought ? `With a ${amountText(buy)} ${code} buy` : null, usd: bought ? inUsd(buy) : null };
    }
    case "launch_buy":
      return {
        title: `Bought ${symbol}`,
        subtitle: amount === null ? null : amountOut !== null ? `${amountText(amountOut)} ${symbol} for ${amountText(amount)} ${code}` : `${amountText(amount)} ${code}`,
        usd: inUsd(amount),
      };
    case "launch_sell":
      return {
        title: `Sold ${symbol}`,
        subtitle: amount === null ? null : amountOut !== null ? `${amountText(amount)} ${symbol} for ${amountText(amountOut)} ${code}` : `${amountText(amount)} ${symbol}`,
        usd: inUsd(amountOut),
      };
    case "launch_graduate":
      return { title: `Graduated ${symbol}`, subtitle: "Moved to Soroswap", usd: null };
    case "launch_claim":
      return { title: "Claimed creator fees", subtitle: amountOut !== null ? `${amountText(amountOut)} ${code} from ${symbol}` : symbol, usd: inUsd(amountOut) };
    default: {
      // A swap in or out of a launch token.
      const side = (id: string) => (id === launch?.token ? symbol : assetById(p.net, id)?.code ?? id);
      const sell = typeof d.sell === "string" ? assetById(p.net, d.sell) : undefined;
      return {
        title: "Swapped",
        subtitle: typeof d.sell === "string" && typeof d.buy === "string" ? `${side(d.sell)} → ${side(d.buy)}` : null,
        usd: sell ? inUsd(units(d.amountIn), sell) : null,
      };
    }
  }
}
