// Markets and the asset directory (docs/DESIGN-stellar-parity.md §6.5, §6.6, §12.5):
// - /v1/markets: registry rows (listed only: Blend's test USDC never) in registry order, then priced launch rows by
//   24h USD volume, at most 50, each exactly a MarketRow; no 24h change while a launch is new; market cap null for
//   registry assets; prices, changes and staleness from the reference cache;
// - /v1/markets/:id for a registry asset by id or contract (BUSDC a test asset at USDC's price) or a listed launch;
// - history buckets: day 900 s, week and month 3600 s, all 86400 s; `complete` when the store reaches the range's
//   start and is current;
// - every markets route is public: no token needed, a token ignored, cached 30 s;
// - the directory reads the issuer's stellar.toml over https from a public host only, keeps answers 7 days and failed
//   fetches an hour.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, goOffline, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { MAINNET, TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const m = await import("../../supabase/functions/_shared/markets.ts");
const dir = await import("../../supabase/functions/_shared/directory.ts");
const rp = await import("../../supabase/functions/_shared/refprices.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const NOW = Date.UTC(2026, 9, 14, 9, 41);
const TOKEN = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
const AQUA = "AQUA:GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA";

const api = new URL("../fixtures/api/", import.meta.url);
const apiFixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, api)));
const refFixtures = new URL("./fixtures/refprices/", import.meta.url);
const readRef = (name: string) => Deno.readTextFileSync(new URL(name, refFixtures));

// ------------------------------------------------------------------------------------------------ stand-ins

interface Db {
  /** lite.ref_quotes rows. */
  quotes: Row[];
  /** What the history's candle query answers, and the first stored bucket. */
  candles: Row[];
  first: Date | null;
  /** Tokens in lite.launches. */
  launches: string[];
  /** lite.asset_directory rows kept. */
  directory: Row[];
  /** Every query, with its parameters. */
  asked: [string, unknown[]][];
  /** Directory upserts: [asset, home_domain, name, image, expires_at]. */
  saved: unknown[][];
}

function database(init: Partial<Db> = {}): Db {
  const db: Db = { quotes: [], candles: [], first: null, launches: [], directory: [], asked: [], saved: [], ...init };
  replaceSql(fakeSql((q, p) => {
    db.asked.push([q, p]);
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") return db.quotes;
    if (q.startsWith("select bucket, close from lite.ref_candles where ref = ? and interval_s = ? and bucket > ? order by bucket")) return db.candles;
    if (q.startsWith("select min(bucket) as first from lite.ref_candles")) return [{ first: db.first }];
    if (q === "select 1 from lite.launches where token = ?") return db.launches.includes(p[0] as string) ? [{ "?column?": 1 }] : [];
    if (q.startsWith("select token, quote, last_price from lite.launches where last_price is not null")) return [];
    if (q.startsWith("select asset, home_domain, name, image from lite.asset_directory where asset = any(?::text[]) and expires_at > now()")) {
      return db.directory.filter((r) => (p[0] as string[]).includes(r.asset as string));
    }
    if (q.startsWith("insert into lite.asset_directory")) {
      db.saved.push(p);
      return [];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  rp.forgetReferencePrices();
  return db;
}

const quote = (ref: string, usd: number, at: number, extra: Row = {}): Row => ({
  ref,
  usd: String(usd),
  source: "kraken",
  market: `Kraken ${ref}/USD`,
  change_24h: null,
  volume_24h_usd: null,
  quoted_at: new Date(at),
  ...extra,
});

const QUOTES = [
  quote("XLM", 0.1901, NOW - MINUTE, { change_24h: "-0.0123", volume_24h_usd: "3712345.2" }),
  quote("USDC", 0.9999, NOW - MINUTE, { change_24h: "0.0001", volume_24h_usd: "912003.5" }),
];

/** A launch row as launchpad.ts launchMarketRows() writes them (WP-14). */
function launch(id: string, volume: number | null, extra: Row = {}): Row {
  return {
    ...apiFixture("markets").rows[2],
    id,
    contract: id,
    volume24hUsd: volume,
    ...extra,
  };
}

async function get(path: string, authorization?: string): Promise<{ status: number; cache: string | null; body: any }> {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, { headers: authorization ? { authorization } : {} }));
  return { status: res.status, cache: res.headers.get("cache-control"), body: await res.json() };
}

// ------------------------------------------------------------------------------------------------ rows and order

Deno.test("registry rows: listed assets in registry order, BUSDC never; each exactly a MarketRow, in the fixture's key order", async () => {
  database({ quotes: QUOTES });
  const testnet = await m.markets(TESTNET, NOW);
  assertEquals(testnet.rows.map((r) => r.id), ["XLM", "USDC"]);
  assert(TESTNET.assets.some((a) => a.id === "BUSDC" && a.listed === false), "the registry has BUSDC, unlisted");
  const fixtureRow = apiFixture("markets").rows[0];
  for (const row of testnet.rows) assertEquals(Object.keys(row), Object.keys(fixtureRow));
  assertEquals(testnet.pricing, { kind: "reference", source: "Kraken", network: "mainnet", note: TESTNET.pricing.note });
  database({ quotes: QUOTES });
  const mainnet = await m.markets(MAINNET, NOW);
  assertEquals([mainnet.rows.map((r) => r.id), mainnet.pricing.kind, mainnet.pricing.note], [["XLM", "USDC"], "market", null]);
});

Deno.test("registry rows: price, change and volume from the reference quote; no market cap; stale, then unknown", async () => {
  database({ quotes: QUOTES });
  const [xlm, usdc] = (await m.markets(TESTNET, NOW)).rows;
  assertEquals([xlm.priceUsd, xlm.change24h, xlm.volume24hUsd, xlm.marketCapUsd, xlm.isNew, xlm.stale], [0.1901, -0.0123, 3712345.2, null, false, false]);
  assertEquals(xlm.priceSource, { kind: "reference", market: "Kraken XLM/USD", at: new Date(NOW - MINUTE).toISOString() });
  assertEquals([usdc.priceUsd, usdc.change24h, usdc.logo, usdc.badges, usdc.verified], [0.9999, 0.0001, "USDC", [], true]);
  // Eleven minutes old: stale. A day and a minute: unknown.
  database({ quotes: [quote("XLM", 0.19, NOW - 11 * MINUTE), quote("USDC", 1, NOW - DAY - MINUTE)] });
  const [staleXlm, oldUsdc] = (await m.markets(TESTNET, NOW)).rows;
  assertEquals([staleXlm.priceUsd, staleXlm.stale], [0.19, true]);
  assertEquals([oldUsdc.priceUsd, oldUsdc.change24h, oldUsdc.volume24hUsd, oldUsdc.stale, oldUsdc.priceSource.at], [null, null, null, true, new Date(NOW - DAY - MINUTE).toISOString()]);
});

Deno.test("Popular order: the registry, then priced launches by 24h volume (ties as given); look-alikes and unpriced left out; at most 50", () => {
  const registry = TESTNET.assets.filter((a) => a.listed).map((a) => m.registryRow(a, { XLM: rp.refPrice("XLM", null, NOW, "Kraken XLM/USD"), USDC: rp.refPrice("USDC", null, NOW, "Kraken USDC/USD") }));
  const rows = [
    launch("CA", 10),
    launch("CB", 500),
    launch("CC", null),
    launch("CD", 500),
    launch("CE", 900, { priceUsd: null }),
    launch("CF", 9_000, { badges: ["launch", "lookAlike"] }),
    launch("CG", 20),
  ].map((r) => m.launchRow(r)!);
  assertEquals(m.popular(registry, rows).map((r) => r.id), ["XLM", "USDC", "CB", "CD", "CG", "CA", "CC"]);
  const many = Array.from({ length: 60 }, (_, i) => m.launchRow(launch(`C${i}`, 1000 - i))!);
  const capped = m.popular(registry, many);
  assertEquals([capped.length, capped[2].id, capped[49].id], [m.MAX_ROWS, "C0", "C47"]);
});

Deno.test("launch rows are exactly MarketRows: other keys dropped, no 24h change while new; market cap as given", () => {
  const row = m.launchRow(launch(TOKEN, 399.21, { createdAt: "2026-10-14T08:00:00.000Z", trades: 4 }))!;
  assertEquals(Object.keys(row), Object.keys(apiFixture("markets").rows[2]));
  assertEquals([row.marketCapUsd, row.change24h, row.isNew], [7927.17, 0.12, false]);
  const fresh = m.launchRow(launch(TOKEN, 1, { isNew: true, change24h: 0.5 }))!;
  assertEquals([fresh.isNew, fresh.change24h], [true, null]);
  assertEquals(m.launchRow({ ...launch(TOKEN, 1), kind: "registry" }), null);
});

// ------------------------------------------------------------------------------------------------ routes

Deno.test("every markets route is public: no token needed, any token ignored, cached 30 s", async () => {
  for (const path of ["/v1/markets", "/v1/markets/XLM", "/v1/markets/XLM/history?range=week", "/v1/prices"]) {
    for (const authorization of [undefined, "Bearer not-a-token"]) {
      database({ quotes: QUOTES, first: new Date(NOW - 40 * DAY) });
      const res = await get(path, authorization);
      assertEquals([res.status, res.cache], [200, "public, max-age=30"], `${path} ${authorization ?? "no token"}`);
    }
  }
});

Deno.test("a token page: a registry asset by id or contract; BUSDC a test asset at USDC's price, without volume; else 404", async () => {
  const db = database({
    quotes: QUOTES,
    directory: [{ asset: TESTNET.assets[2].classic, home_domain: "centre.io", name: null, image: null }],
  });
  const busdc = (await get("/v1/markets/BUSDC")).body;
  assertEquals([busdc.row.id, busdc.row.badges, busdc.row.priceUsd, busdc.row.change24h, busdc.row.volume24hUsd, busdc.row.logo], ["BUSDC", ["testAsset"], 0.9999, 0.0001, null, null]);
  assertEquals(busdc.about, { contract: TESTNET.assets[2].contract, classic: TESTNET.assets[2].classic, issuer: "GATALTGTWIOT6BUDBCZM3Q4OQ4BO2COLOAZ7IYSKPLC2PMSOPPGF5V56", decimals: 7, homeDomain: "centre.io" });
  assertEquals(db.saved, [], "a kept directory entry is served as it is");
  const byContract = (await get(`/v1/markets/${TESTNET.assets[0].contract}`)).body;
  assertEquals([byContract.row.id, byContract.about.classic, byContract.about.issuer, byContract.about.homeDomain], ["XLM", "native", null, null]);
  // Launch tokens come from launchpad.ts, which lists none yet.
  for (const id of [TOKEN, "NOPE"]) {
    const res = await get(`/v1/markets/${id}`);
    assertEquals([res.status, res.body.error.code], [404, "not_found"], id);
  }
});

Deno.test("history buckets: day 900 s, week and month 3600 s, all 86400 s; from the bucket covering the range's start", async () => {
  const cases: [string, number, number | null][] = [["day", 900, DAY], ["week", 3600, 7 * DAY], ["month", 3600, 30 * DAY], ["all", 86_400, null]];
  for (const [range, intervalS, reach] of cases) {
    const db = database({
      candles: [{ bucket: new Date(NOW - 2 * intervalS * 1000), close: "0.19" }, { bucket: new Date(NOW - intervalS * 1000), close: "0.1901" }],
      first: new Date(NOW - 800 * DAY),
    });
    const body = await m.marketHistory("XLM", m.rangeArg(range), TESTNET, NOW);
    assertEquals([body.id, body.range, body.intervalS, body.source, body.complete], ["XLM", range, intervalS, "Kraken", true], range);
    assertEquals(body.points, [{ t: new Date(NOW - 2 * intervalS * 1000).toISOString(), usd: 0.19 }, { t: new Date(NOW - intervalS * 1000).toISOString(), usd: 0.1901 }]);
    const [, params] = db.asked.find(([q]) => q.startsWith("select bucket, close"))!;
    assertEquals(params, ["XLM", intervalS, reach === null ? new Date(0) : new Date(NOW - reach - intervalS * 1000)], range);
  }
  // BUSDC's history is USDC's.
  const db = database({ candles: [], first: null });
  const busdc = await m.marketHistory("BUSDC", "day", TESTNET, NOW);
  assertEquals([busdc.id, busdc.points, busdc.complete], ["BUSDC", [], false]);
  assertEquals(db.asked.find(([q]) => q.startsWith("select bucket, close"))![1][0], "USDC");
});

Deno.test("history range: day when absent, 400 otherwise", async () => {
  assertEquals(m.rangeArg(null), "day");
  database({ candles: [], first: null });
  assertEquals((await get("/v1/markets/XLM/history")).body.intervalS, 900);
  for (const range of ["year", "toString", "DAY"]) {
    database();
    const res = await get(`/v1/markets/XLM/history?range=${range}`);
    assertEquals([res.status, res.body.error.code], [400, "bad_range"], range);
  }
});

Deno.test("history is complete when the store reaches the range's start and the newest point is current", () => {
  const t = (ms: number) => ({ t: new Date(ms).toISOString() });
  const since = new Date(NOW - DAY);
  assertEquals(m.historyComplete([t(NOW - 15 * MINUTE)], new Date(NOW - 7 * DAY), since, 900, NOW), true);
  // The store starts within one bucket after the range's: Kraken's 720 hourly candles for a month.
  assertEquals(m.historyComplete([t(NOW - HOUR)], new Date(NOW - 30 * DAY + 59 * MINUTE), new Date(NOW - 30 * DAY), 3600, NOW), true);
  assertEquals(m.historyComplete([t(NOW - 15 * MINUTE)], new Date(NOW - 12 * HOUR), since, 900, NOW), false);
  assertEquals(m.historyComplete([t(NOW - 31 * MINUTE)], new Date(NOW - 7 * DAY), since, 900, NOW), false);
  assertEquals(m.historyComplete([], new Date(NOW - 7 * DAY), since, 900, NOW), false);
  assertEquals(m.historyComplete([t(NOW - DAY)], new Date(NOW - DAY), null, 86_400, NOW), true);
});

Deno.test("launch history: a known launch is curve+pool from launchpad.ts; anything else 404", async () => {
  database({ launches: [TOKEN] });
  const body = await m.marketHistory(TOKEN, "week", TESTNET, NOW);
  assertEquals(body, { id: TOKEN, range: "week", intervalS: 3600, source: "curve+pool", complete: false, points: [] });
  database({ launches: [] });
  const res = await get(`/v1/markets/${TOKEN}/history?range=day`);
  assertEquals([res.status, res.body.error.code], [404, "not_found"]);
});

// ------------------------------------------------------------------------------------------------ the asset directory

Deno.test("stellar.toml: [[CURRENCIES]] string fields; other values skipped, across lines too", () => {
  const aqua = dir.parseCurrencies(readRef("aqua.network-stellar.toml"));
  assert(aqua.length >= 2);
  assertEquals(dir.currencyFor(readRef("aqua.network-stellar.toml"), "AQUA", "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"), { name: "AQUA", image: "https://aqua.network/assets/img/aqua-logo.png" });
  // Circle's testnet issuer points at centre.io, whose toml lists its accounts over several lines and mainnet's USDC
  // only: the testnet USDC has no entry there.
  const centre = readRef("centre.io-stellar.toml");
  assertEquals(dir.parseCurrencies(centre).map((c) => [c.code, c.issuer]), [["USDC", "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"]]);
  assertEquals(dir.currencyFor(centre, "USDC", "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"), { name: "USD Coin", image: "https://www.centre.io/images/usdc/usdc-icon-86074d9d49.png" });
  assertEquals(dir.currencyFor(centre, "USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"), { name: null, image: null });
  const anchor = dir.parseCurrencies(readRef("testanchor.stellar.org-stellar.toml"));
  assertEquals(anchor.map((c) => c.code), ["SRT", "USDC", "native"]);
  assertEquals(dir.currencyFor(readRef("testanchor.stellar.org-stellar.toml"), "USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"), { name: null, image: null });

  const issuer = "GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA";
  const toml = [
    'DESC = """',
    "[[CURRENCIES]]",
    'code = "FAKE"',
    '"""',
    "ARRAY = [",
    '  "a]", # a comment ]',
    '  { x = "[[CURRENCIES]]" },',
    "]",
    "[[CURRENCIES]] # the real one",
    `code = 'CAF'`,
    `issuer = "${issuer}"`,
    'name = "Caf\\u00e9 \\"Token\\"\\u0007"',
    'image = "http://example.org/logo.png"',
    "display_decimals = 2",
    "[DOCUMENTATION]",
    'name = "not a currency"',
  ].join("\r\n");
  assertEquals(dir.parseCurrencies(toml), [{ code: "CAF", issuer, name: 'Café "Token"\u0007', image: "http://example.org/logo.png" }]);
  // Control characters go; an image that isn't https is dropped.
  assertEquals(dir.currencyFor(toml, "CAF", issuer), { name: 'Café "Token"', image: null });
  assertEquals(dir.currencyFor(toml, "CAF", "GOTHER"), { name: null, image: null });
});

Deno.test("the directory fetches only https URLs on public host names", () => {
  for (const ok of ["https://aqua.network/.well-known/stellar.toml", "https://www.centre.io/.well-known/stellar.toml"]) assert(dir.publicHttpsUrl(ok), ok);
  for (
    const refused of [
      "http://aqua.network/.well-known/stellar.toml",
      "https://aqua.network:8443/.well-known/stellar.toml",
      "https://user:pw@aqua.network/x",
      "https://localhost/.well-known/stellar.toml",
      "https://127.0.0.1/.well-known/stellar.toml",
      "https://169.254.169.254/latest",
      "https://[::1]/x",
      "https://intranet/x",
      "https://db.internal/x",
      "https://printer.local/x",
      "ftp://aqua.network/x",
      "not a url",
    ]
  ) assertEquals(dir.publicHttpsUrl(refused), null, refused);
  assert(dir.isClassicAsset(AQUA));
  for (const not of ["native", "XLM", TOKEN, "AQUA:GNOPE", "TOOLONGCODE123:GBNZILSTVQZ4R7IKQDGHYGY2QXL5QOFJYQMXPKWRRM5PAV7Y4M67AQUA"]) assertEquals(dir.isClassicAsset(not), false, not);
});

/** fetch: Horizon's /assets and the toml host answer as `answers` says; everything else is offline. */
function web(answers: Record<string, () => Response>): string[] {
  const asked: string[] = [];
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    asked.push(url.origin + url.pathname);
    const answer = answers[url.origin + url.pathname];
    return Promise.resolve(answer ? answer() : new Response("offline", { status: 503 }));
  }) as typeof fetch;
  return asked;
}

const HORIZON_AQUA = "https://horizon.stellar.org/assets";
const AQUA_TOML = "https://aqua.network/.well-known/stellar.toml";

Deno.test("the directory: a miss reads Horizon's toml link and the issuer's toml and keeps the answer 7 days", async () => {
  const db = database();
  const asked = web({ [HORIZON_AQUA]: () => new Response(readRef("horizon-assets-aqua.json")), [AQUA_TOML]: () => new Response(readRef("aqua.network-stellar.toml")) });
  const before = Date.now();
  const entries = await dir.directory([AQUA, "native", TOKEN], MAINNET);
  assertEquals(entries.get(AQUA), { asset: AQUA, homeDomain: "aqua.network", name: "AQUA", image: "https://aqua.network/assets/img/aqua-logo.png" });
  assertEquals(entries.get("native"), { asset: "native", homeDomain: null, name: null, image: null });
  assertEquals(asked, [HORIZON_AQUA, AQUA_TOML]);
  const [saved] = db.saved;
  assertEquals(saved.slice(0, 4), [AQUA, "aqua.network", "AQUA", "https://aqua.network/assets/img/aqua-logo.png"]);
  const keep = +(saved[4] as Date) - before;
  assert(keep >= 7 * DAY && keep < 7 * DAY + MINUTE, `kept ${keep} ms`);
  // Kept: served without fetching.
  database({ directory: [{ asset: AQUA, home_domain: "aqua.network", name: "AQUA", image: null }] });
  const again = web({});
  assertEquals((await dir.directoryEntry(AQUA, MAINNET)).name, "AQUA");
  assertEquals(again, []);
});

Deno.test("the directory: a failed fetch is retried after an hour; a refused or oversized toml is an answer", async () => {
  const keptFor = async (answers: Record<string, () => Response>) => {
    const db = database();
    web(answers);
    const before = Date.now();
    const entry = await dir.directoryEntry(AQUA, MAINNET);
    return { entry, keep: Math.round((+(db.saved[0][4] as Date) - before) / HOUR) };
  };
  const horizon = () => new Response(readRef("horizon-assets-aqua.json"));
  // Horizon or the toml host down, or busy: an hour.
  assertEquals(await keptFor({}), { entry: { asset: AQUA, homeDomain: null, name: null, image: null }, keep: 1 });
  assertEquals((await keptFor({ [HORIZON_AQUA]: horizon, [AQUA_TOML]: () => new Response("busy", { status: 429 }) })).keep, 1);
  // A redirect to http, a 404, or more than 100 KB: the domain is known, nothing else, for 7 days.
  const answer = { asset: AQUA, homeDomain: "aqua.network", name: null, image: null };
  const redirect = () => new Response(null, { status: 301, headers: { location: "http://aqua.network/.well-known/stellar.toml" } });
  assertEquals(await keptFor({ [HORIZON_AQUA]: horizon, [AQUA_TOML]: redirect }), { entry: answer, keep: 168 });
  assertEquals(await keptFor({ [HORIZON_AQUA]: horizon, [AQUA_TOML]: () => new Response("missing", { status: 404 }) }), { entry: answer, keep: 168 });
  const huge = () => new Response(`[[CURRENCIES]]\ncode = "AQUA"\nname = "${"x".repeat(101 * 1024)}"\n`);
  assertEquals(await keptFor({ [HORIZON_AQUA]: horizon, [AQUA_TOML]: huge }), { entry: answer, keep: 168 });
  // An asset Horizon doesn't know: nothing, for 7 days.
  const none = () => new Response(JSON.stringify({ _embedded: { records: [] } }));
  assertEquals(await keptFor({ [HORIZON_AQUA]: none }), { entry: { asset: AQUA, homeDomain: null, name: null, image: null }, keep: 168 });
});
