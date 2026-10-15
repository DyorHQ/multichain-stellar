// Reference prices in USD (docs/DESIGN-stellar-parity.md §6.12). Testnet assets have no market, so XLM and USDC are
// valued at mainnet market prices, labelled as such (`pricing`); mainnet values its own markets the same way.
//
// - Providers are adapters (PriceProvider). Kraken's public market data is the default: its ticker for quotes, its
//   OHLC for 15-minute, hourly and daily candles. Another provider is another adapter, chosen by
//   networks.ts `reference.provider`.
// - XLM falls back to the mainnet SDEX: the last 15 minutes of XLM/USDC trades on Horizon × the last good USDC/USD.
//   USDC has no fallback: with no fresh quote its price is unknown, never a constant.
// - The indexer's refprices job writes lite.ref_quotes and lite.ref_candles; the API reads them through
//   referencePrices(), kept 15 s per isolate. A quote older than 10 minutes is stale, one older than 24 hours unknown.
import type { Pricing } from "./contract.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { AssetInfo, MAINNET, NetworkConfig, PriceRef } from "./networks.ts";

/** The reference assets, in the order the job asks for them. */
export const REFS: PriceRef[] = ["XLM", "USDC"];

/** Candle intervals, in seconds: 15 minutes, an hour, a day. */
export type IntervalS = 900 | 3600 | 86_400;
export const INTERVALS: IntervalS[] = [900, 3600, 86_400];

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** A quote older than this is served with `stale: true`... */
export const STALE_AFTER_MS = 10 * MINUTE;
/** ...and one older than this not at all: its price is null. */
export const UNKNOWN_AFTER_MS = DAY;

/** How often each interval's candles are written: 15-minute candles every 5 minutes, hourly ones hourly, daily ones
 *  daily. The last candle of each write is the one still open, so it is rewritten next time. */
export const CANDLE_EVERY_MS: Record<IntervalS, number> = { 900: 5 * MINUTE, 3600: HOUR, 86_400: DAY };

/** How long purge keeps candles: 15-minute ones 35 days, hourly ones 400 days, daily ones for good. */
export const CANDLE_KEEP_MS: Record<IntervalS, number | null> = { 900: 35 * DAY, 3600: 400 * DAY, 86_400: null };

/** Where a stored price came from: the provider, or the SDEX fallback (lite.ref_quotes.source). */
export type QuoteSource = "kraken" | "horizon";

/** A USD price as a provider gave it. */
export interface Quote {
  ref: PriceRef;
  usd: number;
  source: QuoteSource;
  /** Shown with the price: "Kraken XLM/USD". */
  market: string;
  volume24hUsd: number | null;
  /** When the price was current. */
  at: Date;
}

/** One USD candle; the bucket starts at a multiple of its interval since the epoch. */
export interface Candle {
  bucket: Date;
  open: number;
  high: number;
  low: number;
  close: number;
  /** In the reference asset. */
  volume: number | null;
}

/** A source of reference prices. */
export interface PriceProvider {
  /** Named wherever its prices are shown (`pricing.source`, the token page's source line). */
  name: string;
  /** lite.ref_quotes.source and lite.ref_candles.source for what it gives. */
  source: QuoteSource;
  /** The market a reference asset is quoted on, as shown: "Kraken XLM/USD". */
  market(ref: PriceRef): string;
  /** The latest quotes; an asset the provider didn't answer for is missing. Throws when the provider can't be read. */
  quotes(refs: PriceRef[], now: number): Promise<Partial<Record<PriceRef, Quote>>>;
  /** Candles from `since` (or as far back as the provider keeps) to the one still open, oldest first. */
  candles(ref: PriceRef, interval: IntervalS, since: Date | null): Promise<Candle[]>;
}

/** Each provider request gives up after this long. */
const TIMEOUT_MS = 5_000;

async function getJson(url: string): Promise<unknown> {
  const res = await fetch(url, { signal: AbortSignal.timeout(TIMEOUT_MS), headers: { accept: "application/json" } });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`HTTP ${res.status} from ${new URL(url).host}`);
  }
  return await res.json();
}

/** A positive finite price, from a provider's string or number; null otherwise. */
function price(v: unknown): number | null {
  if (typeof v !== "string" && typeof v !== "number") return null;
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** `v` rounded to `digits` decimals. */
function round(v: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(v * f) / f;
}

// ------------------------------------------------------------------------------------------------ Kraken

const KRAKEN = "https://api.kraken.com/0/public";

/** Kraken's public market data: Ticker for quotes, OHLC for candles. No key. */
export function kraken(net: NetworkConfig = env.network): PriceProvider {
  const pairs = net.reference.markets;
  return {
    name: "Kraken",
    source: "kraken",
    market: (ref) => `Kraken ${ref}/USD`,
    async quotes(refs, now) {
      const body = await getJson(`${KRAKEN}/Ticker?pair=${refs.map((r) => pairs[r]).join(",")}`);
      return parseKrakenTicker(body, refs, pairs, new Date(now));
    },
    async candles(ref, interval, since) {
      const from = since ? `&since=${Math.floor(since.getTime() / 1000)}` : "";
      const body = await getJson(`${KRAKEN}/OHLC?pair=${pairs[ref]}&interval=${interval / 60}${from}`);
      return parseKrakenOhlc(body, pairs[ref], interval);
    },
  };
}

/** Kraken's `result`, or a throw with its errors. */
function krakenResult(body: unknown): Record<string, unknown> {
  const b = body as { error?: unknown; result?: unknown } | null;
  if (Array.isArray(b?.error) && b.error.length > 0) throw new Error(`Kraken: ${b.error.slice(0, 3).join("; ")}`);
  if (!b || typeof b.result !== "object" || b.result === null) throw new Error("Kraken: no result");
  return b.result as Record<string, unknown>;
}

/** A pair's entry in a Kraken result. Kraken answers older pairs under their full name: XLMUSD as XXLMZUSD. */
function krakenEntry(result: Record<string, unknown>, pair: string): unknown {
  return result[pair] ?? result[`X${pair.slice(0, -3)}Z${pair.slice(-3)}`];
}

/** Ticker → quotes: the last trade's price; 24h volume in USD is the base volume × its volume-weighted price. */
export function parseKrakenTicker(body: unknown, refs: PriceRef[], pairs: Record<PriceRef, string>, at: Date): Partial<Record<PriceRef, Quote>> {
  const result = krakenResult(body);
  const out: Partial<Record<PriceRef, Quote>> = {};
  for (const ref of refs) {
    const t = krakenEntry(result, pairs[ref]) as { c?: unknown[]; v?: unknown[]; p?: unknown[] } | undefined;
    const usd = price(t?.c?.[0]);
    if (usd === null) continue;
    const volume = Number(t?.v?.[1]) * Number(t?.p?.[1]);
    out[ref] = { ref, usd, source: "kraken", market: `Kraken ${ref}/USD`, volume24hUsd: Number.isFinite(volume) && volume >= 0 ? round(volume, 2) : null, at };
  }
  return out;
}

/** OHLC → candles: [time, open, high, low, close, vwap, volume, count], oldest first, the last one still open. Rows
 *  off the interval's grid or with a price that isn't positive are left out. */
export function parseKrakenOhlc(body: unknown, pair: string, interval: IntervalS): Candle[] {
  const rows = krakenEntry(krakenResult(body), pair);
  if (!Array.isArray(rows)) throw new Error(`Kraken: no OHLC for ${pair}`);
  const out: Candle[] = [];
  for (const r of rows) {
    if (!Array.isArray(r) || !Number.isSafeInteger(r[0]) || r[0] % interval !== 0) continue;
    const [open, high, low, close] = [price(r[1]), price(r[2]), price(r[3]), price(r[4])];
    if (open === null || high === null || low === null || close === null) continue;
    const volume = Number(r[6]);
    out.push({ bucket: new Date(r[0] * 1000), open, high, low, close, volume: Number.isFinite(volume) && volume >= 0 ? volume : null });
  }
  return out;
}

// ------------------------------------------------------------------------------------------------ the SDEX fallback (XLM)

/** The resolution of the trade aggregation the fallback reads. */
const DEX_RESOLUTION_MS = 15 * MINUTE;

export const DEX_MARKET = "Stellar DEX XLM/USDC";

/** XLM in USD from mainnet's SDEX: the close of the latest 15-minute XLM/USDC trade aggregation (USDC per XLM) ×
 *  USDC in USD. Null when the book has no trades. Always mainnet: testnet's books aren't markets. */
export async function dexXlmQuote(usdcUsd: number, now: number): Promise<Quote | null> {
  const [code, issuer] = MAINNET.assets.find((a) => a.id === "USDC")!.classic!.split(":");
  const url = `${MAINNET.horizonUrl}/trade_aggregations?base_asset_type=native&counter_asset_type=credit_alphanum4` +
    `&counter_asset_code=${code}&counter_asset_issuer=${issuer}&resolution=${DEX_RESOLUTION_MS}&order=desc&limit=1`;
  return parseDexXlm(await getJson(url), usdcUsd, now);
}

/** A trade aggregation page → XLM's quote. The price is as old as its bucket's end (now, for the open bucket). */
export function parseDexXlm(body: unknown, usdcUsd: number, now: number): Quote | null {
  const records = (body as { _embedded?: { records?: unknown[] } } | null)?._embedded?.records;
  if (!Array.isArray(records)) throw new Error("Horizon: no trade aggregations");
  const latest = records[0] as { timestamp?: unknown; close?: unknown } | undefined;
  const close = price(latest?.close);
  const start = Number(latest?.timestamp);
  if (close === null || !Number.isSafeInteger(start) || !(usdcUsd > 0)) return null;
  return { ref: "XLM", usd: round(close * usdcUsd, 8), source: "horizon", market: DEX_MARKET, volume24hUsd: null, at: new Date(Math.min(now, start + DEX_RESOLUTION_MS)) };
}

// ------------------------------------------------------------------------------------------------ pure rules

/** The provider networks.ts names for this network. */
export function providerFor(net: NetworkConfig = env.network): PriceProvider {
  switch (net.reference.provider) {
    case "Kraken":
      return kraken(net);
  }
}

/** How the app labels USD values (§6.2): reference prices on testnet, market prices on mainnet. */
export function pricingOf(net: NetworkConfig = env.network): Pricing {
  return { kind: net.pricing.kind, source: net.reference.provider, network: net.pricing.network, note: net.pricing.note };
}

/** The start of the 15-minute and the hourly bucket 24 hours before `at`: the closes the 24h change compares with. */
export function dayAgoBuckets(at: Date): { b900: Date; b3600: Date } {
  const t = at.getTime() - DAY;
  return { b900: new Date(t - (t % (900 * 1000))), b3600: new Date(t - (t % HOUR)) };
}

/** The 24h change (§6.12): last / the 15-minute close at floor(at − 24 h) − 1, else the hourly close's, else null. */
export function change24h(last: number, close900: number | null, close3600: number | null): number | null {
  const base = close900 !== null && close900 > 0 ? close900 : close3600 !== null && close3600 > 0 ? close3600 : null;
  return base === null || !(last > 0) ? null : round(last / base - 1, 6);
}

/** Whether an interval's candles are due: never written, or last written a cadence ago (half a minute's slack: the
 *  indexer runs every minute, never exactly on time). */
export function candlesDue(interval: IntervalS, lastWritten: Date | null, now: number): boolean {
  return lastWritten === null || now - lastWritten.getTime() >= CANDLE_EVERY_MS[interval] - 30_000;
}

/** A reference price as the API serves it. */
export interface RefPrice {
  ref: PriceRef;
  /** Null without a quote younger than 24 hours. Never a constant. */
  usd: number | null;
  /** The quote is older than 10 minutes, or there is none. */
  stale: boolean;
  /** When the quote was current; null when there has never been one. */
  at: string | null;
  market: string;
  change24h: number | null;
  volume24hUsd: number | null;
}

/** A lite.ref_quotes row. postgres.js answers numeric as strings. */
export interface QuoteRow {
  ref: string;
  usd: string | number;
  source: QuoteSource;
  market: string;
  change_24h: string | number | null;
  volume_24h_usd: string | number | null;
  quoted_at: Date | string;
}

const numberOrNull = (v: string | number | null) => (v === null ? null : Number(v));

/** A stored quote (or none) at `now`: fresh, stale after 10 minutes, unknown after 24 hours. */
export function refPrice(ref: PriceRef, row: QuoteRow | null, now: number, market: string): RefPrice {
  if (!row) return { ref, usd: null, stale: true, at: null, market, change24h: null, volume24hUsd: null };
  const at = new Date(row.quoted_at);
  const age = now - at.getTime();
  const base = { ref, at: at.toISOString(), market: row.market };
  if (age > UNKNOWN_AFTER_MS) return { ...base, usd: null, stale: true, change24h: null, volume24hUsd: null };
  return { ...base, usd: Number(row.usd), stale: age > STALE_AFTER_MS, change24h: numberOrNull(row.change_24h), volume24hUsd: numberOrNull(row.volume_24h_usd) };
}

// ------------------------------------------------------------------------------------------------ reading

/** The API reads quotes from the database at most every 15 s per isolate. */
const READ_CACHE_MS = 15_000;
let cached: { at: number; rows: QuoteRow[] } | null = null;

/** Drops the isolate's copy of the quotes (tests). */
export function forgetReferencePrices(): void {
  cached = null;
}

/** Every reference asset's price as the API serves it (§6.12). */
export async function referencePrices(now: number = Date.now(), net: NetworkConfig = env.network): Promise<Record<PriceRef, RefPrice>> {
  if (!cached || now - cached.at >= READ_CACHE_MS || now < cached.at) {
    const rows = await sql()`select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes`;
    cached = { at: now, rows: rows as unknown as QuoteRow[] };
  }
  const provider = providerFor(net);
  const out = {} as Record<PriceRef, RefPrice>;
  for (const ref of REFS) out[ref] = refPrice(ref, cached.rows.find((r) => r.ref === ref) ?? null, now, provider.market(ref));
  return out;
}

/** An asset's USD price through its reference (BUSDC through USDC); null for an asset without one or an unknown price. */
export function usdOf(asset: AssetInfo | undefined, prices: Record<PriceRef, RefPrice>): number | null {
  return asset?.priceRef ? prices[asset.priceRef].usd : null;
}
