// earn: supply 100 XLM to Blend, then withdraw 40.
import type { E2E } from "../lite_e2e.ts";

export default async function earn({ api, ONE, runPlan }: E2E): Promise<string> {
  const m = await api("GET", "/earn/markets");
  const xlmMarket = m.markets.find((x: any) => x.code === "XLM");
  const dep = await api("POST", "/earn/build", { action: "deposit", pool: xlmMarket.pool, asset: xlmMarket.asset, amount: (100n * ONE).toString() });
  await runPlan(dep);
  const p1 = await api("GET", "/earn/positions");
  const pos = p1.positions.find((x: any) => x.asset === xlmMarket.asset);
  if (!pos || BigInt(pos.supplied) < 99n * ONE) throw new Error(`position ${JSON.stringify(p1)}`);
  const wd = await api("POST", "/earn/build", { action: "withdraw", pool: xlmMarket.pool, asset: xlmMarket.asset, amount: (40n * ONE).toString() });
  await runPlan(wd);
  const p2 = await api("GET", "/earn/positions");
  const after = p2.positions.find((x: any) => x.asset === xlmMarket.asset);
  return `supplied 100 XLM at ${(xlmMarket.supplyApy * 100).toFixed(2)}% APY (testnet), withdrew 40 → position ${(Number(after.supplied) / 1e7).toFixed(4)} XLM`;
}
