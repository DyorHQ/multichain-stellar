// WP-15's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md §6.0,
// §6.10, §12.5): earn-markets, earn-positions (the owner's view), earn-positions.public and earn-history, answered by
// the API itself (lite/index.ts) from a stand-in for Blend's pool and seeded rows that carry the fixtures' figures.
// Markets, history and the public view are asked with no token. The pool also lends Blend's test wETH, which isn't a
// registry asset, so neither payload lists it.
import { assertEquals } from "jsr:@std/assert@1";
import { fakeSql, goOffline, routeRows, setTestEnv, USER, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { replacePools } = await import("../../supabase/functions/_shared/earn.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const api = new URL("../fixtures/api/", import.meta.url);
const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, api)));
const markets = fixture("earn-markets");
const positions = fixture("earn-positions");
const history = fixture("earn-history");
const [xlmMarket, usdcMarket] = markets.markets;
const [position] = positions.positions;
const WETH = "CAZAQB3D7KSLSNOSQKYD2V4JP5V2Y3B4RDJZRLBFCCIXDCTE3WHSY3UE";

/** A reserve with a market's figures: its size in base units, borrowed at its utilization. */
const reserve = (m: { decimals: number; supplyApy: number; borrowApy: number; utilization: number; totalSupplied: number }) => {
  const supplied = BigInt(Math.round(m.totalSupplied * 10 ** m.decimals));
  return {
    decimals: m.decimals,
    supplyApy: m.supplyApy,
    borrowApy: m.borrowApy,
    utilization: m.utilization,
    supplied,
    borrowed: (supplied * BigInt(Math.round(m.utilization * 10_000))) / 10_000n,
  };
};

replacePools({
  read: () => Promise.resolve(state()),
  supplies: () => Promise.resolve({ state: state(), supplied: new Map([[position.asset, { supply: BigInt(position.supplied), collateral: 0n }]]) }),
});

function state() {
  return {
    status: 0,
    reserves: new Map([[xlmMarket.asset, reserve(xlmMarket)], [WETH, reserve({ ...xlmMarket, decimals: 7 })], [usdcMarket.asset, reserve(usdcMarket)]]),
  };
}

replaceSql(fakeSql((q, params) => {
  // The reference cache, quoted a moment ago: XLM at $0.1901 and USDC at $0.9999 (markets.json's prices).
  if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
    return [
      { ref: "XLM", usd: String(xlmMarket.priceUsd), source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date() },
      { ref: "USDC", usd: String(usdcMarket.priceUsd), source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date() },
    ];
  }
  // The signed-in tester's one deposit, of what the position's record says was deposited.
  if (q === "select kind, intent from lite.tx_log where address = ? and kind in ('earn_deposit', 'earn_withdraw') and status = 'success'") {
    if (params[0] !== USER.publicKey()) return [];
    const amount = position.deposited;
    return [{ kind: "earn_deposit", intent: { kind: "earn_deposit", summary: "", spend: { [position.asset]: amount }, calls: [{ contract: position.pool, fn: "submit" }] } }];
  }
  // The market's snapshots, oldest first; one earlier in the last point's hour gives way to it.
  if (q === "select taken_at, supply_apy, utilization from lite.earn_snapshots where pool = ? and asset = ? and taken_at > ? order by taken_at") {
    const points = history.points as { t: string; supplyApy: number; utilization: number }[];
    const rows = points.map((p) => ({ taken_at: new Date(p.t), supply_apy: String(p.supplyApy), utilization: String(p.utilization) }));
    const last = Date.parse(points[points.length - 1].t);
    rows.splice(rows.length - 1, 0, { taken_at: new Date(last - 10 * 60_000), supply_apy: "0.5", utilization: "0.9" });
    return rows;
  }
  return routeRows(q, params);
}));
forgetReferencePrices();

async function answer(path: string, token?: string): Promise<{ status: number; cache: string | null; body: unknown }> {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} }));
  return { status: res.status, cache: res.headers.get("cache-control"), body: await res.json() };
}

Deno.test("GET /v1/earn/markets with no token equals earn-markets.json", async () => {
  assertEquals(await answer("/v1/earn/markets"), { status: 200, cache: "public, max-age=30", body: markets });
});

Deno.test("GET /v1/earn/positions as its owner equals earn-positions.json", async () => {
  assertEquals(await answer("/v1/earn/positions", await userToken()), { status: 200, cache: "no-store", body: positions });
});

Deno.test("GET /v1/earn/positions?address= with no token equals earn-positions.public.json", async () => {
  assertEquals(await answer(`/v1/earn/positions?address=${USER.publicKey()}`), { status: 200, cache: "public, max-age=15", body: fixture("earn-positions.public") });
});

Deno.test("GET /v1/earn/history with no token equals earn-history.json", async () => {
  const path = `/v1/earn/history?pool=${xlmMarket.pool}&asset=${xlmMarket.asset}&range=week`;
  assertEquals(await answer(path), { status: 200, cache: "public, max-age=30", body: history });
});

Deno.test("the fixtures' market is testnet's pool and registry asset", () => {
  const pool = TESTNET.contracts.blendPools[0];
  assertEquals([xlmMarket.pool, xlmMarket.poolName, position.pool, position.poolName], [pool.id, pool.name, pool.id, pool.name]);
});
