// WP-13's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md
// §6.0, §12.5): markets, market, market-history and prices, produced by the routes' own code from seeded rows that
// carry the fixtures' figures. The launch row comes from launchpad.ts launchMarketRows() (WP-14), which lists none
// yet: it is passed through launchRow() and Popular order as WP-14 will hand it over.
import { assertEquals } from "jsr:@std/assert@1";
import { fakeSql, goOffline, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const m = await import("../../supabase/functions/_shared/markets.ts");
const { prices } = await import("../../supabase/functions/_shared/prices.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");

const api = new URL("../fixtures/api/", import.meta.url);
const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, api)));
const markets = fixture("markets");
const [xlmRow, usdcRow, launchFixture] = markets.rows;
const NOW = Date.parse(markets.asOf);

/** lite.ref_quotes with the fixtures' figures; the market history's candles; one launch quoted in XLM. */
function seed(): void {
  const quote = (row: Row): Row => ({
    ref: row.id,
    usd: String(row.priceUsd),
    source: "kraken",
    market: (row.priceSource as Row).market,
    change_24h: String(row.change24h),
    volume_24h_usd: String(row.volume24hUsd),
    quoted_at: new Date((row.priceSource as Row).at as string),
  });
  const history = fixture("market-history");
  replaceSql(fakeSql((q) => {
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") return [quote(xlmRow), quote(usdcRow)];
    if (q.startsWith("select bucket, close from lite.ref_candles")) return history.points.map((p: Row) => ({ bucket: new Date(p.t as string), close: String(p.usd) }));
    if (q.startsWith("select min(bucket) as first from lite.ref_candles")) return [{ first: new Date(NOW - 7 * 86_400_000) }];
    // 0.0000079 USD at 0.1901 USD per XLM.
    if (q.startsWith("select token, quote, last_price from lite.launches")) return [{ token: launchFixture.id, quote: TESTNET.assets[0].contract, last_price: "0.00004155707522356655" }];
    throw new Error(`unexpected query: ${q}`);
  }));
  forgetReferencePrices();
}

Deno.test("GET /v1/markets equals markets.json: the registry rows from the reference cache, then the launch row", async () => {
  seed();
  const payload = await m.markets(TESTNET, NOW);
  assertEquals(payload, { ...markets, rows: [xlmRow, usdcRow] });
  const launch = m.launchRow(launchFixture)!;
  assertEquals({ ...payload, rows: m.popular(payload.rows, [launch]) }, markets);
});

Deno.test("GET /v1/markets/:id equals market.json", async () => {
  seed();
  assertEquals(await m.market("XLM", TESTNET, NOW), fixture("market"));
});

Deno.test("GET /v1/markets/:id/history equals market-history.json", async () => {
  seed();
  assertEquals(await m.marketHistory("XLM", "day", TESTNET, NOW), fixture("market-history"));
});

Deno.test("GET /v1/prices equals prices.json", async () => {
  seed();
  assertEquals(await prices(NOW), fixture("prices"));
});
