// Markets (docs/DESIGN-stellar-parity.md §6.6; public): Top Tokens' rows, a token page's row and its price history.
// - Registry rows come from networks.ts: listed assets only (Blend's test USDC never), priced through their reference
//   (priceRef) from the reference cache (refprices.ts).
// - Launch rows come from launchpad.ts launchMarketRows() and their history from launchHistory(); until those are
//   written, the markets list the registry only. Nothing stands in for them.
// - Popular order: registry rows in registry order, then listed and priced launch tokens by 24h USD volume (newest
//   first among equals, as launchMarketRows() answers them); at most 50 rows, each exactly a MarketRow.
import type { MarketDetail, MarketRow, Markets, Period, PriceHistory } from "./contract.ts";
import { sql } from "./db.ts";
import { directoryEntry } from "./directory.ts";
import { env } from "./env.ts";
import { bad, notFound } from "./http.ts";
import { launchHistory, launchMarketRows } from "./launchpad.ts";
import { assetById, AssetInfo, NetworkConfig, PriceRef } from "./networks.ts";
import { IntervalS, pricingOf, providerFor, referencePrices, RefPrice } from "./refprices.ts";

/** /v1/markets answers at most this many rows. */
export const MAX_ROWS = 50;

const DAY = 86_400_000;

/** History's candle interval per range (§6.6): a day in 15 minutes, a week and a month in hours, all in days. */
export const HISTORY_INTERVAL: Record<Period, IntervalS> = { day: 900, week: 3600, month: 3600, all: 86_400 };

/** How far back each range reaches; `all` from the first candle. */
const RANGE_MS: Record<Period, number | null> = { day: DAY, week: 7 * DAY, month: 30 * DAY, all: null };

/** A MarketRow's keys, in the order the API writes them. */
const ROW_KEYS = [
  "id",
  "kind",
  "contract",
  "classic",
  "code",
  "name",
  "decimals",
  "logo",
  "image",
  "verified",
  "badges",
  "note",
  "priceUsd",
  "change24h",
  "isNew",
  "volume24hUsd",
  "marketCapUsd",
  "priceSource",
  "stale",
  "launch",
] as const satisfies readonly (keyof MarketRow)[];
// Every key of MarketRow is in ROW_KEYS: a key added to the contract fails here until it is written.
const _everyKey: [Exclude<keyof MarketRow, typeof ROW_KEYS[number]>] extends [never] ? true : never = true;

/** A registry asset's row, priced through its reference. An unlisted asset (Blend's test USDC, the registry's only
 *  one) is a test asset with no market of its own: it shows its reference's price but no volume. */
export function registryRow(asset: AssetInfo, prices: Record<PriceRef, RefPrice>, net: NetworkConfig = env.network): MarketRow {
  const p = asset.priceRef ? prices[asset.priceRef] : null;
  const listed = asset.listed === true;
  return {
    id: asset.id,
    kind: "registry",
    contract: asset.contract,
    classic: asset.classic,
    code: asset.code,
    name: asset.name,
    decimals: asset.decimals,
    logo: asset.logo ?? null,
    image: null,
    verified: true,
    badges: listed ? [] : ["testAsset"],
    note: asset.note ?? null,
    priceUsd: p?.usd ?? null,
    change24h: p?.usd != null ? p.change24h : null,
    isNew: false,
    volume24hUsd: listed && p?.usd != null ? p.volume24hUsd : null,
    marketCapUsd: null,
    priceSource: { kind: "reference", market: p?.market ?? providerFor(net).name, at: p?.at ?? null },
    stale: p?.stale ?? true,
    launch: null,
  };
}

/** A launch row from launchpad.ts as exactly a MarketRow (its keys, in order, nothing else), with no 24h change while
 *  it is new; null for anything that isn't a launch row. */
export function launchRow(raw: Record<string, unknown>): MarketRow | null {
  if (raw.kind !== "launch" || typeof raw.id !== "string") return null;
  const row = Object.fromEntries(ROW_KEYS.map((k) => [k, raw[k] ?? null])) as unknown as MarketRow;
  row.badges = Array.isArray(raw.badges) ? raw.badges : [];
  row.verified = raw.verified === true;
  row.isNew = raw.isNew === true;
  row.stale = raw.stale === true;
  if (row.isNew) row.change24h = null;
  return row;
}

/** Popular order (§6.6): the registry rows as given, then launch rows that are priced and don't imitate another
 *  ticker, by 24h USD volume (a stable sort, so equal volumes keep their order); at most MAX_ROWS. */
export function popular(registry: MarketRow[], launches: MarketRow[]): MarketRow[] {
  const listed = launches.filter((r) => r.priceUsd !== null && !r.badges.includes("lookAlike"));
  listed.sort((a, b) => (b.volume24hUsd ?? -1) - (a.volume24hUsd ?? -1));
  return [...registry, ...listed].slice(0, MAX_ROWS);
}

async function launchRows(): Promise<MarketRow[]> {
  return (await launchMarketRows()).map(launchRow).filter((r): r is MarketRow => r !== null);
}

/** GET /v1/markets. */
export async function markets(net: NetworkConfig = env.network, now: number = Date.now()): Promise<Markets> {
  const [prices, launches] = await Promise.all([referencePrices(now, net), launchRows()]);
  const registry = net.assets.filter((a) => a.listed === true).map((a) => registryRow(a, prices, net));
  return { asOf: new Date(now).toISOString(), pricing: pricingOf(net), rows: popular(registry, launches) };
}

/** GET /v1/markets/:id: a registry asset (by id or contract, listed or not) or a listed launch token. */
export async function market(id: string, net: NetworkConfig = env.network, now: number = Date.now()): Promise<MarketDetail> {
  const asset = assetById(net, id);
  if (asset) {
    const classic = asset.classic && asset.classic !== "native" ? asset.classic : null;
    const [prices, entry] = await Promise.all([referencePrices(now, net), classic ? directoryEntry(classic, net) : null]);
    return {
      row: registryRow(asset, prices, net),
      about: { contract: asset.contract, classic: asset.classic, issuer: classic ? classic.split(":")[1] : null, decimals: asset.decimals, homeDomain: entry?.homeDomain ?? null },
    };
  }
  const row = (await launchRows()).find((r) => r.id === id);
  if (!row) throw notFound("Market");
  return { row, about: { contract: row.contract, classic: null, issuer: null, decimals: row.decimals, homeDomain: null } };
}

/** ?range=, day when absent. */
export function rangeArg(v: string | null): Period {
  if (v === null || v === "") return "day";
  if (Object.hasOwn(HISTORY_INTERVAL, v)) return v as Period;
  throw bad("bad_range", "range is day, week, month or all.");
}

/** Whether a reference history covers its range: it has points, the newest no older than two intervals, and the
 *  stored candles reach back to within one interval of the range's start (`all` starts at the first). */
export function historyComplete(points: { t: string }[], firstStored: Date | null, since: Date | null, intervalS: IntervalS, now: number): boolean {
  if (points.length === 0 || firstStored === null) return false;
  const interval = intervalS * 1000;
  if (Date.parse(points[points.length - 1].t) < now - 2 * interval) return false;
  return since === null || firstStored.getTime() <= since.getTime() + interval;
}

/** GET /v1/markets/:id/history: a registry asset's reference candles (closes, oldest first), or a launch token's
 *  curve and pool prices in USD from launchpad.ts. */
export async function marketHistory(id: string, range: Period, net: NetworkConfig = env.network, now: number = Date.now()): Promise<PriceHistory> {
  const intervalS = HISTORY_INTERVAL[range];
  const reach = RANGE_MS[range];
  const since = reach === null ? null : new Date(now - reach);
  const asset = assetById(net, id);
  if (asset) {
    const source = providerFor(net).name;
    const ref = asset.priceRef;
    if (!ref) return { id: asset.id, range, intervalS, source, complete: false, points: [] };
    // From the bucket that covers `since`.
    const from = since === null ? new Date(0) : new Date(since.getTime() - intervalS * 1000);
    const [rows, first] = await Promise.all([
      sql()`select bucket, close from lite.ref_candles where ref = ${ref} and interval_s = ${intervalS} and bucket > ${from} order by bucket`,
      sql()`select min(bucket) as first from lite.ref_candles where ref = ${ref} and interval_s = ${intervalS}`,
    ]);
    const points = rows.map((r) => ({ t: new Date(r.bucket).toISOString(), usd: Number(r.close) }));
    const firstStored = first[0]?.first ? new Date(first[0].first) : null;
    return { id: asset.id, range, intervalS, source, complete: historyComplete(points, firstStored, since, intervalS, now), points };
  }
  const known = await sql()`select 1 from lite.launches where token = ${id}`;
  if (known.length === 0) throw notFound("Market");
  const points = await launchHistory(id, range);
  return { id, range, intervalS, source: "curve+pool", complete: points.length > 0, points };
}
