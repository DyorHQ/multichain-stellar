// Reference prices (docs/DESIGN-stellar-parity.md §6.12), every indexer run:
// 1. the provider's quote for each reference asset; XLM without one falls back to the mainnet SDEX × the last good
//    USDC/USD, USDC has no fallback;
// 2. candles that are due (15-minute every 5 minutes, hourly, daily), the first run backfilling as far as the provider
//    keeps them (Kraken: 720 candles);
// 3. each quote with its 24h change from the stored candles, into lite.ref_quotes, never over a newer one.
// A provider that can't be read leaves the stored quote to age (stale after 10 minutes, unknown after 24 hours), and
// the job's result names it.
import { sql, tableExists } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import type { PriceRef } from "../../_shared/networks.ts";
import {
  Candle,
  candlesDue,
  change24h,
  dayAgoBuckets,
  dexXlmQuote,
  IntervalS,
  INTERVALS,
  providerFor,
  Quote,
  QuoteSource,
  REFS,
  UNKNOWN_AFTER_MS,
} from "../../_shared/refprices.ts";

/** Candle requests start only in the job's first 15 s: an interval left over stays due for the next run. */
const CANDLE_BUDGET_MS = 15_000;

export interface RefpricesResult {
  /** Each reference asset's source this run, or null when nothing was quoted. */
  quotes: Record<string, QuoteSource | null>;
  /** Candles written, by "<ref>/<interval s>". */
  candles: Record<string, number>;
  /** Due candles left for the next run. */
  deferred?: number;
  errors?: string[];
}

const message = (err: unknown) => String((err as Error)?.message ?? err).slice(0, 160);

export async function refprices(now: () => number = Date.now): Promise<RefpricesResult | { skipped: string }> {
  if (!(await tableExists("lite.ref_quotes"))) return { skipped: "migration 06 isn't applied" };
  const started = now();
  const provider = providerFor(env.network);
  const errors: string[] = [];

  // 1. Quotes.
  let quotes: Partial<Record<PriceRef, Quote>> = {};
  try {
    quotes = await provider.quotes(REFS, now());
  } catch (err) {
    errors.push(`${provider.name} quotes: ${message(err)}`);
  }
  for (const ref of REFS) if (!quotes[ref]) errors.push(`${ref}: no ${provider.name} quote`);
  if (!quotes.XLM) {
    const usdc = quotes.USDC?.usd ?? (await lastGoodUsd("USDC", now()));
    if (usdc === null) {
      errors.push("XLM: no USDC/USD for the SDEX fallback");
    } else {
      try {
        const dex = await dexXlmQuote(usdc, now());
        if (dex) quotes.XLM = dex;
        else errors.push("XLM: no SDEX trades");
      } catch (err) {
        errors.push(`XLM SDEX: ${message(err)}`);
      }
    }
  }

  // 2. Candles that are due.
  const candles: Record<string, number> = {};
  let deferred = 0;
  const written = await sql()`select ref, interval_s, max(bucket) as last, max(updated_at) as written from lite.ref_candles group by ref, interval_s`;
  for (const interval of INTERVALS) {
    for (const ref of REFS) {
      const w = written.find((r) => r.ref === ref && Number(r.interval_s) === interval);
      if (!candlesDue(interval, w ? new Date(w.written) : null, now())) continue;
      if (now() - started >= CANDLE_BUDGET_MS) {
        deferred++;
        continue;
      }
      // From the last stored bucket, which may have been the open one, so it is rewritten closed.
      const since = w ? new Date(new Date(w.last).getTime() - interval * 1000) : null;
      try {
        candles[`${ref}/${interval}`] = await writeCandles(ref, interval, await provider.candles(ref, interval, since), provider.source);
      } catch (err) {
        errors.push(`${ref} ${interval / 60}m candles: ${message(err)}`);
      }
    }
  }

  // 3. Quotes, with their change.
  for (const ref of REFS) {
    const q = quotes[ref];
    if (q) await writeQuote(q);
  }

  return {
    quotes: Object.fromEntries(REFS.map((r) => [r, quotes[r]?.source ?? null])),
    candles,
    ...(deferred ? { deferred } : {}),
    ...(errors.length ? { errors } : {}),
  };
}

/** The stored quote's USD price while it is younger than 24 hours. */
async function lastGoodUsd(ref: PriceRef, now: number): Promise<number | null> {
  const rows = await sql()`select usd, quoted_at from lite.ref_quotes where ref = ${ref}`;
  const row = rows[0];
  if (!row || now - new Date(row.quoted_at).getTime() > UNKNOWN_AFTER_MS) return null;
  return Number(row.usd);
}

async function writeCandles(ref: PriceRef, interval: IntervalS, list: Candle[], source: QuoteSource): Promise<number> {
  if (list.length === 0) return 0;
  await sql()`
    insert into lite.ref_candles (ref, interval_s, bucket, open, high, low, close, volume, source)
    select ${ref}, ${interval}, c.bucket, c.open, c.high, c.low, c.close, c.volume, ${source}
      from unnest(${list.map((c) => c.bucket.toISOString())}::timestamptz[], ${list.map((c) => c.open)}::numeric[],
                  ${list.map((c) => c.high)}::numeric[], ${list.map((c) => c.low)}::numeric[],
                  ${list.map((c) => c.close)}::numeric[], ${list.map((c) => c.volume)}::numeric[])
        as c(bucket, open, high, low, close, volume)
    on conflict (ref, interval_s, bucket) do update set open = excluded.open, high = excluded.high, low = excluded.low,
      close = excluded.close, volume = excluded.volume, source = excluded.source, updated_at = now()`;
  return list.length;
}

async function writeQuote(q: Quote): Promise<void> {
  const { b900, b3600 } = dayAgoBuckets(q.at);
  const closes = await sql()`
    select interval_s, close from lite.ref_candles
     where ref = ${q.ref} and ((interval_s = 900 and bucket = ${b900}) or (interval_s = 3600 and bucket = ${b3600}))`;
  const close = (interval: number) => {
    const row = closes.find((r) => Number(r.interval_s) === interval);
    return row ? Number(row.close) : null;
  };
  const change = change24h(q.usd, close(900), close(3600));
  await sql()`
    insert into lite.ref_quotes (ref, usd, source, market, change_24h, volume_24h_usd, quoted_at)
    values (${q.ref}, ${q.usd}, ${q.source}, ${q.market}, ${change}, ${q.volume24hUsd}, ${q.at})
    on conflict (ref) do update set usd = excluded.usd, source = excluded.source, market = excluded.market,
      change_24h = excluded.change_24h, volume_24h_usd = excluded.volume_24h_usd, quoted_at = excluded.quoted_at,
      updated_at = now()
    where lite.ref_quotes.quoted_at <= excluded.quoted_at`;
}
