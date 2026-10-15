// Reference prices (docs/DESIGN-stellar-parity.md §6.12, §12.5), against Kraken's and Horizon's answers captured on
// 2026-10-14 at 20:07 UTC (fixtures/refprices/; the OHLC answers trimmed to their last 120 candles):
// - the adapters read the ticker, the OHLC candles and the SDEX trade aggregation as the providers write them;
// - the job asks Kraken first; XLM without a Kraken quote falls back to the SDEX × the last good USDC/USD (this run's,
//   or a stored one under 24 hours old); USDC never falls back; candles are backfilled once, then written on their
//   cadence; each quote carries its 24h change from the stored candles, and never replaces a newer one; the job's
//   result names a source only for a quote it wrote;
// - reads: stale after 10 minutes, unknown after 24 hours; with no provider and nothing stored, no route prices
//   anything: no code path answers a constant.
//
// The database is a stand-in that answers the job's and the API's own statements from rows held here, as Postgres
// would (the statements themselves run on Postgres in backend/tests/sql/prices_test.sql and the e2e markets phase).
import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, goOffline, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const rp = await import("../../supabase/functions/_shared/refprices.ts");
const { refprices } = await import("../../supabase/functions/lite-indexer/jobs/refprices.ts");
const { purge } = await import("../../supabase/functions/lite-indexer/jobs/purge.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
/** When the fixtures were captured: 2026-10-14T20:07:16Z. */
const CAPTURED = Date.UTC(2026, 9, 14, 20, 7, 16);

const fixtures = new URL("./fixtures/refprices/", import.meta.url);
const read = (name: string) => Deno.readTextFileSync(new URL(name, fixtures));
const fixture = (name: string) => JSON.parse(read(name));

// ------------------------------------------------------------------------------------------------ stand-ins

/** Replaces fetch: Kraken and mainnet Horizon answer from the fixtures, a host in `down` refuses the connection, and
 *  everything else is offline. Returns the URLs asked for. */
function providers(opts: { down?: string[]; ticker?: unknown } = {}): URL[] {
  const asked: URL[] = [];
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    asked.push(url);
    if (opts.down?.includes(url.host)) return Promise.reject(new TypeError("error sending request: Connection refused"));
    const body = (text: string) => Promise.resolve(new Response(text, { headers: { "content-type": "application/json" } }));
    if (url.host === "api.kraken.com" && url.pathname === "/0/public/Ticker") {
      return body(opts.ticker === undefined ? read("kraken-ticker.json") : JSON.stringify(opts.ticker));
    }
    if (url.host === "api.kraken.com" && url.pathname === "/0/public/OHLC") {
      return body(read(`kraken-ohlc-${url.searchParams.get("pair")}-${url.searchParams.get("interval")}.json`));
    }
    if (url.host === "horizon.stellar.org" && url.pathname === "/trade_aggregations") return body(read("horizon-trade-aggregations-15m.json"));
    return Promise.resolve(new Response("offline: unit tests make no network calls", { status: 503 }));
  }) as typeof fetch;
  return asked;
}

interface StoredCandle {
  ref: string;
  interval_s: number;
  bucket: Date;
  close: number;
  updated_at: Date;
}

/** lite.ref_quotes and lite.ref_candles, answering the job's and referencePrices()'s statements. */
class PriceDb {
  quotes = new Map<string, Row>();
  candles = new Map<string, StoredCandle>();
  migrated = true;
  deletes: unknown[][] = [];

  constructor(private clock: () => number) {
    replaceSql(fakeSql((q, p) => this.answer(q, p)));
    rp.forgetReferencePrices();
  }

  quote(ref: string, usd: number, at: number, source = "kraken", extra: Row = {}): void {
    this.quotes.set(ref, { ref, usd: String(usd), source, market: source === "kraken" ? `Kraken ${ref}/USD` : rp.DEX_MARKET, change_24h: null, volume_24h_usd: null, quoted_at: new Date(at), ...extra });
  }

  count(ref: string, interval: number): number {
    return [...this.candles.values()].filter((c) => c.ref === ref && c.interval_s === interval).length;
  }

  private answer(q: string, p: unknown[]): Row[] {
    if (q.startsWith("select to_regclass(?) is not null as present")) return [{ present: this.migrated }];
    if (q.startsWith("select ref, interval_s, max(bucket) as last, max(updated_at) as written from lite.ref_candles group by ref, interval_s")) {
      const groups = new Map<string, Row>();
      for (const c of this.candles.values()) {
        const k = `${c.ref}/${c.interval_s}`;
        const g = groups.get(k) ?? { ref: c.ref, interval_s: c.interval_s, last: c.bucket, written: c.updated_at };
        if (c.bucket > (g.last as Date)) g.last = c.bucket;
        if (c.updated_at > (g.written as Date)) g.written = c.updated_at;
        groups.set(k, g);
      }
      return [...groups.values()];
    }
    if (q.startsWith("insert into lite.ref_candles")) {
      const [ref, interval, , buckets, , , , closes] = p as [string, number, string, string[], number[], number[], number[], number[]];
      buckets.forEach((b, i) => {
        const bucket = new Date(b);
        this.candles.set(`${ref}/${interval}/${b}`, { ref, interval_s: interval, bucket, close: closes[i], updated_at: new Date(this.clock()) });
      });
      return [];
    }
    if (q.startsWith("select interval_s, close from lite.ref_candles where ref = ? and ((interval_s = 900 and bucket = ?) or (interval_s = 3600 and bucket = ?))")) {
      const [ref, b900, b3600] = p as [string, Date, Date];
      return [...this.candles.values()]
        .filter((c) => c.ref === ref && ((c.interval_s === 900 && +c.bucket === +b900) || (c.interval_s === 3600 && +c.bucket === +b3600)))
        .map((c) => ({ interval_s: c.interval_s, close: String(c.close) }));
    }
    if (q.startsWith("insert into lite.ref_quotes")) {
      const [ref, usd, source, market, change, volume, at] = p as [string, number, string, string, number | null, number | null, Date];
      const old = this.quotes.get(ref);
      // `where lite.ref_quotes.quoted_at <= excluded.quoted_at returning ref`: a row only when written.
      if (old && +(old.quoted_at as Date) > +at) return [];
      this.quotes.set(ref, { ref, usd: String(usd), source, market, change_24h: change === null ? null : String(change), volume_24h_usd: volume === null ? null : String(volume), quoted_at: at });
      return [{ ref }];
    }
    if (q === "select usd, quoted_at from lite.ref_quotes where ref = ?") {
      const row = this.quotes.get(p[0] as string);
      return row ? [{ usd: row.usd, quoted_at: row.quoted_at }] : [];
    }
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") return [...this.quotes.values()];
    if (q.startsWith("delete from lite.ref_candles where interval_s = ? and bucket < ?")) {
      this.deletes.push(p);
      return Object.assign([], { count: 0 });
    }
    // A token page's issuer domain (directory.ts): nothing kept, and Horizon is offline here.
    if (q.startsWith("select asset, home_domain, name, image from lite.asset_directory")) return [];
    if (q.startsWith("insert into lite.asset_directory")) return [];
    // /v1/prices' launch prices: one launch quoted in XLM.
    if (q.startsWith("select token, quote, last_price from lite.launches where last_price is not null")) {
      return [{ token: "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V", quote: TESTNET.assets[0].contract, last_price: "0.0000417" }];
    }
    throw new Error(`unexpected query: ${q}`);
  }
}

const krakenTicker = fixture("kraken-ticker.json");
const ohlc = (pair: string, interval: number) => fixture(`kraken-ohlc-${pair}-${interval}.json`).result;
const dexClose = Number(fixture("horizon-trade-aggregations-15m.json")._embedded.records[0].close);
const closeAt = (pair: string, key: string, interval: number, t: number) => Number(ohlc(pair, interval)[key].find((r: unknown[]) => r[0] === t / 1000)[4]);

// ------------------------------------------------------------------------------------------------ adapters

Deno.test("Kraken ticker: the last trade's price, and 24h USD volume as base volume × its average price", () => {
  const at = new Date(CAPTURED);
  const quotes = rp.parseKrakenTicker(krakenTicker, rp.REFS, TESTNET.reference.markets, at);
  const xlm = krakenTicker.result.XXLMZUSD;
  const usdc = krakenTicker.result.USDCUSD;
  assertEquals(quotes.XLM, { ref: "XLM", usd: Number(xlm.c[0]), source: "kraken", market: "Kraken XLM/USD", volume24hUsd: Math.round(Number(xlm.v[1]) * Number(xlm.p[1]) * 100) / 100, at });
  assertEquals(quotes.USDC, { ref: "USDC", usd: Number(usdc.c[0]), source: "kraken", market: "Kraken USDC/USD", volume24hUsd: Math.round(Number(usdc.v[1]) * Number(usdc.p[1]) * 100) / 100, at });
  assertEquals([quotes.XLM!.usd, quotes.USDC!.usd], [0.183791, 0.9998]);
  // A pair Kraken left out, or an error, gives no quote: never a stand-in.
  assertEquals(rp.parseKrakenTicker({ error: [], result: { USDCUSD: usdc } }, rp.REFS, TESTNET.reference.markets, at).XLM, undefined);
  assertEquals(rp.parseKrakenTicker({ error: [], result: { XXLMZUSD: { ...xlm, c: ["0.000000", "1"] } } }, ["XLM"], TESTNET.reference.markets, at), {});
  let refused = "";
  try {
    rp.parseKrakenTicker({ error: ["EGeneral:Too many requests"] }, rp.REFS, TESTNET.reference.markets, at);
  } catch (err) {
    refused = (err as Error).message;
  }
  assertEquals(refused, "Kraken: EGeneral:Too many requests");
});

Deno.test("Kraken OHLC: candles on their interval's grid, oldest first, the open one last", () => {
  for (const [pair, key] of [["XLMUSD", "XXLMZUSD"], ["USDCUSD", "USDCUSD"]]) {
    for (const interval of rp.INTERVALS) {
      const candles = rp.parseKrakenOhlc({ error: [], result: ohlc(pair, interval / 60) }, pair, interval);
      const raw = ohlc(pair, interval / 60)[key];
      assertEquals(candles.length, raw.length, `${pair} ${interval}`);
      assert(candles.every((c, i) => +c.bucket % (interval * 1000) === 0 && (i === 0 || c.bucket > candles[i - 1].bucket)), `${pair} ${interval}`);
      assertEquals(+candles[candles.length - 1].bucket, Date.UTC(2026, 9, 14, interval === 86_400 ? 0 : 20), `${pair} ${interval}: the open candle`);
      const last = raw[raw.length - 1];
      assertEquals(candles[candles.length - 1], { bucket: new Date(last[0] * 1000), open: Number(last[1]), high: Number(last[2]), low: Number(last[3]), close: Number(last[4]), volume: Number(last[6]) });
    }
  }
  // Off the grid, or a price that isn't positive: left out.
  const odd = { error: [], result: { XXLMZUSD: [[1792008060, "0.18", "0.18", "0.18", "0.18", "0.18", "1", 1], [1792008000, "0", "0.18", "0.18", "0.18", "0.18", "1", 1]], last: 0 } };
  assertEquals(rp.parseKrakenOhlc(odd, "XLMUSD", 900), []);
});

Deno.test("SDEX fallback: XLM = the latest 15-minute XLM/USDC close × USDC/USD, as old as its bucket's end", () => {
  const body = fixture("horizon-trade-aggregations-15m.json");
  const bucket = Number(body._embedded.records[0].timestamp);
  assertEquals(bucket, Date.UTC(2026, 9, 14, 20));
  const open = rp.parseDexXlm(body, 0.9998, CAPTURED);
  assertEquals(open, { ref: "XLM", usd: Math.round(dexClose * 0.9998 * 1e8) / 1e8, source: "horizon", market: "Stellar DEX XLM/USDC", volume24hUsd: null, at: new Date(CAPTURED) });
  assertEquals(rp.parseDexXlm(body, 0.9998, CAPTURED + HOUR)!.at, new Date(bucket + 15 * MINUTE));
  // No trades, or no USDC price to convert with: nothing.
  assertEquals(rp.parseDexXlm({ _embedded: { records: [] } }, 0.9998, CAPTURED), null);
  assertEquals(rp.parseDexXlm(body, 0, CAPTURED), null);
});

// ------------------------------------------------------------------------------------------------ the job

Deno.test("the job: Kraken first, every candle interval backfilled, quotes with their 24h change; no SDEX call", async () => {
  const db = new PriceDb(() => CAPTURED);
  const asked = providers();
  const result = await refprices(() => CAPTURED);
  assertEquals(result, {
    quotes: { XLM: "kraken", USDC: "kraken" },
    candles: { "XLM/900": 120, "USDC/900": 120, "XLM/3600": 120, "USDC/3600": 120, "XLM/86400": 120, "USDC/86400": 120 },
  });
  assert(!asked.some((u) => u.host === "horizon.stellar.org"), "the SDEX was asked although Kraken answered");
  // The first run backfills: no `since`.
  assert(asked.filter((u) => u.pathname === "/0/public/OHLC").every((u) => !u.searchParams.has("since")));

  // 24h change: last / the 15-minute close at floor(20:07:16 − 24 h) = 20:00 the day before.
  const dayAgo = Date.UTC(2026, 9, 13, 20);
  const xlm = db.quotes.get("XLM")!;
  assertEquals([xlm.usd, xlm.source, xlm.market, xlm.quoted_at], ["0.183791", "kraken", "Kraken XLM/USD", new Date(CAPTURED)]);
  assertAlmostEquals(Number(xlm.change_24h), 0.183791 / closeAt("XLMUSD", "XXLMZUSD", 15, dayAgo) - 1, 1e-6);
  assertAlmostEquals(Number(db.quotes.get("USDC")!.change_24h), 0.9998 / closeAt("USDCUSD", "USDCUSD", 15, dayAgo) - 1, 1e-6);
  assertEquals(Number(xlm.volume_24h_usd), Math.round(Number(krakenTicker.result.XXLMZUSD.v[1]) * Number(krakenTicker.result.XXLMZUSD.p[1]) * 100) / 100);
});

Deno.test("the job: candles on their cadence, from the last stored bucket", async () => {
  let now = CAPTURED;
  const db = new PriceDb(() => now);
  providers();
  await refprices(() => now);
  const ohlcAsked = async (at: number) => {
    now = at;
    const asked = providers();
    const result = await refprices(() => now);
    return { candles: Object.keys((result as { candles: Record<string, number> }).candles), urls: asked.filter((u) => u.pathname === "/0/public/OHLC") };
  };
  // A minute later nothing is due; four and a half minutes after the write, the 15-minute candles are.
  assertEquals((await ohlcAsked(CAPTURED + MINUTE)).candles, []);
  const quarter = await ohlcAsked(CAPTURED + 4.5 * MINUTE);
  assertEquals(quarter.candles, ["XLM/900", "USDC/900"]);
  // From the last stored bucket (the open one, 20:00), so it is rewritten closed.
  assertEquals(quarter.urls.map((u) => [u.searchParams.get("pair"), u.searchParams.get("interval"), u.searchParams.get("since")]), [
    ["XLMUSD", "15", String(Date.UTC(2026, 9, 14, 19, 45) / 1000)],
    ["USDCUSD", "15", String(Date.UTC(2026, 9, 14, 19, 45) / 1000)],
  ]);
  assertEquals((await ohlcAsked(CAPTURED + HOUR)).candles, ["XLM/900", "USDC/900", "XLM/3600", "USDC/3600"]);
  assertEquals((await ohlcAsked(CAPTURED + 24 * HOUR)).candles, ["XLM/900", "USDC/900", "XLM/3600", "USDC/3600", "XLM/86400", "USDC/86400"]);
  assertEquals(db.count("XLM", 900), 120);
});

Deno.test("fallback order: Kraken down, XLM from the SDEX × the stored USDC/USD; USDC isn't quoted and ages", async () => {
  const db = new PriceDb(() => CAPTURED);
  db.quote("USDC", 0.9997, CAPTURED - HOUR);
  const asked = providers({ down: ["api.kraken.com"] });
  const result = await refprices(() => CAPTURED) as { quotes: Record<string, string | null>; errors: string[] };
  assertEquals(result.quotes, { XLM: "horizon", USDC: null });
  assert(result.errors[0].startsWith("Kraken quotes: "), result.errors[0]);
  assert(result.errors.includes("USDC: no Kraken quote"));
  assertEquals(asked.filter((u) => u.host === "horizon.stellar.org").length, 1);
  const xlm = db.quotes.get("XLM")!;
  assertEquals([Number(xlm.usd), xlm.source, xlm.market], [Math.round(dexClose * 0.9997 * 1e8) / 1e8, "horizon", "Stellar DEX XLM/USDC"]);
  // USDC keeps its hour-old quote: stale, never replaced by a constant.
  assertEquals(db.quotes.get("USDC")!.quoted_at, new Date(CAPTURED - HOUR));
  const prices = await rp.referencePrices(CAPTURED);
  assertEquals([prices.USDC.usd, prices.USDC.stale, prices.XLM.stale], [0.9997, true, false]);
});

Deno.test("fallback order: Kraken without XLM, the SDEX × this run's USDC/USD", async () => {
  const db = new PriceDb(() => CAPTURED);
  providers({ ticker: { error: [], result: { USDCUSD: krakenTicker.result.USDCUSD } } });
  const result = await refprices(() => CAPTURED) as { quotes: Record<string, string | null> };
  assertEquals(result.quotes, { XLM: "horizon", USDC: "kraken" });
  assertEquals(Number(db.quotes.get("XLM")!.usd), Math.round(dexClose * 0.9998 * 1e8) / 1e8);
});

Deno.test("no USDC/USD younger than 24 hours: XLM has no fallback either, and nothing is written", async () => {
  for (const stored of [null, CAPTURED - 25 * HOUR]) {
    const db = new PriceDb(() => CAPTURED);
    if (stored !== null) db.quote("USDC", 0.9999, stored);
    const asked = providers({ down: ["api.kraken.com"] });
    const result = await refprices(() => CAPTURED) as { quotes: Record<string, string | null>; errors: string[] };
    assertEquals(result.quotes, { XLM: null, USDC: null });
    assert(result.errors.includes("XLM: no USDC/USD for the SDEX fallback"), JSON.stringify(result.errors));
    assert(!asked.some((u) => u.host === "horizon.stellar.org"));
    assertEquals(db.quotes.has("XLM"), false);
  }
});

Deno.test("a fallback quote never replaces a newer one, and the job doesn't claim it", async () => {
  const db = new PriceDb(() => CAPTURED + HOUR);
  db.quote("USDC", 0.9998, CAPTURED + HOUR - MINUTE);
  // Kraken's XLM from a minute ago; the SDEX's latest trades end at 20:15, 52 minutes before.
  db.quote("XLM", 0.1835, CAPTURED + HOUR - MINUTE);
  providers({ down: ["api.kraken.com"] });
  const result = await refprices(() => CAPTURED + HOUR) as { quotes: Record<string, string | null>; errors: string[] };
  assertEquals([db.quotes.get("XLM")!.usd, db.quotes.get("XLM")!.source], ["0.1835", "kraken"]);
  assertEquals(result.quotes, { XLM: null, USDC: null });
  assert(result.errors.includes("XLM: the stored quote is newer than horizon's of 2026-10-14T20:15:00.000Z"), JSON.stringify(result.errors));
});

Deno.test("the job and purge skip until migration 06 is applied", async () => {
  const db = new PriceDb(() => CAPTURED);
  db.migrated = false;
  const asked = providers();
  assertEquals(await refprices(() => CAPTURED), { skipped: "migration 06 isn't applied" });
  assertEquals(await purge(() => CAPTURED), { skipped: "migration 06 isn't applied" });
  assertEquals(asked, []);
});

Deno.test("purge keeps 15-minute candles 35 days and hourly ones 400 days, daily ones for good", async () => {
  const db = new PriceDb(() => CAPTURED);
  assertEquals(await purge(() => CAPTURED), { refCandles15m: 0, refCandles60m: 0 });
  assertEquals(db.deletes, [[900, new Date(CAPTURED - 35 * 24 * HOUR)], [3600, new Date(CAPTURED - 400 * 24 * HOUR)]]);
});

// ------------------------------------------------------------------------------------------------ rules and reads

Deno.test("24h change: the 15-minute close a day before, else the hourly one, else null", () => {
  assertEquals(rp.dayAgoBuckets(new Date(CAPTURED)), { b900: new Date(Date.UTC(2026, 9, 13, 20)), b3600: new Date(Date.UTC(2026, 9, 13, 20)) });
  assertEquals(rp.dayAgoBuckets(new Date(Date.UTC(2026, 9, 14, 20, 52))), { b900: new Date(Date.UTC(2026, 9, 13, 20, 45)), b3600: new Date(Date.UTC(2026, 9, 13, 20)) });
  assertEquals(rp.change24h(0.2, 0.25, 0.1), -0.2);
  assertEquals(rp.change24h(0.2, null, 0.16), 0.25);
  assertEquals(rp.change24h(0.2, null, null), null);
  assertEquals(rp.change24h(0.2, 0, null), null);
});

Deno.test("reads: stale after 10 minutes, unknown after 24 hours, unknown and stale with no quote", () => {
  const row = (age: number) => ({ ref: "XLM", usd: "0.19", source: "kraken" as const, market: "Kraken XLM/USD", change_24h: "-0.01", volume_24h_usd: "100.5", quoted_at: new Date(CAPTURED - age) });
  const at = (age: number) => new Date(CAPTURED - age).toISOString();
  const fresh = { ref: "XLM" as const, market: "Kraken XLM/USD", usd: 0.19, change24h: -0.01, volume24hUsd: 100.5 };
  assertEquals(rp.refPrice("XLM", row(5 * MINUTE), CAPTURED, "Kraken XLM/USD"), { ...fresh, at: at(5 * MINUTE), stale: false });
  assertEquals(rp.refPrice("XLM", row(10 * MINUTE), CAPTURED, "Kraken XLM/USD"), { ...fresh, at: at(10 * MINUTE), stale: false });
  assertEquals(rp.refPrice("XLM", row(11 * MINUTE), CAPTURED, "Kraken XLM/USD"), { ...fresh, at: at(11 * MINUTE), stale: true });
  assertEquals(rp.refPrice("XLM", row(24 * HOUR), CAPTURED, "Kraken XLM/USD"), { ...fresh, at: at(24 * HOUR), stale: true });
  assertEquals(rp.refPrice("XLM", row(24 * HOUR + 1000), CAPTURED, "Kraken XLM/USD"), { ref: "XLM", market: "Kraken XLM/USD", at: at(24 * HOUR + 1000), usd: null, stale: true, change24h: null, volume24hUsd: null });
  assertEquals(rp.refPrice("USDC", null, CAPTURED, "Kraken USDC/USD"), { ref: "USDC", usd: null, stale: true, at: null, market: "Kraken USDC/USD", change24h: null, volume24hUsd: null });
});

Deno.test("reads are kept 15 s per isolate", async () => {
  const db = new PriceDb(() => CAPTURED);
  db.quote("XLM", 0.19, CAPTURED);
  assertEquals((await rp.referencePrices(CAPTURED)).XLM.usd, 0.19);
  db.quote("XLM", 0.2, CAPTURED);
  assertEquals((await rp.referencePrices(CAPTURED + 14_000)).XLM.usd, 0.19);
  assertEquals((await rp.referencePrices(CAPTURED + 15_000)).XLM.usd, 0.2);
});

Deno.test("never a constant: with no provider and nothing stored, /v1/prices and /v1/markets price nothing", async () => {
  new PriceDb(() => Date.now());
  providers({ down: ["api.kraken.com", "horizon.stellar.org"] });
  await refprices();
  const get = async (path: string) => {
    const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`));
    return [res.status, res.headers.get("cache-control"), await res.json()];
  };
  const [status, cache, prices] = await get("/v1/prices");
  assertEquals([status, cache, prices.usd], [200, "public, max-age=30", {}]);
  const [, , markets] = await get("/v1/markets");
  assertEquals(markets.rows.map((r: Row) => [r.id, r.priceUsd, r.change24h, r.stale, (r.priceSource as Row).at]), [["XLM", null, null, true, null], ["USDC", null, null, true, null]]);
  const [, , detail] = await get("/v1/markets/BUSDC");
  assertEquals([detail.row.priceUsd, detail.row.stale], [null, true]);
});

Deno.test("/v1/prices: registry assets through their reference (BUSDC as USDC), launches × their quote's price", async () => {
  const now = Date.now();
  const db = new PriceDb(() => now);
  db.quote("XLM", 0.1901, now - MINUTE);
  db.quote("USDC", 0.9999, now - MINUTE);
  const res = await handle(new Request("http://127.0.0.1/functions/v1/lite/v1/prices", { headers: { authorization: "Bearer ignored-on-a-public-route" } }));
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(body.usd, { XLM: 0.1901, USDC: 0.9999, BUSDC: 0.9999, CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V: 0.0000417 * 0.1901 });
  assertEquals(body.reference, "Mainnet reference prices; testnet assets have no value.");
});
