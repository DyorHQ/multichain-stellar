// launch: create, sell back, buy to the threshold, graduation by the keeper, a Soroswap buy, creator fees claimed.
import type { E2E } from "../lite_e2e.ts";

export default async function launch({ api, bal, indexer, ONE, runPlan }: E2E): Promise<string> {
  const create = await api("POST", "/launches/build", { action: "create", quote: "XLM", name: "E2E Cat", symbol: "ECAT", uri: "", creatorFeeBps: 100, amount: (100n * ONE).toString(), minOut: "0" });
  const [r] = await runPlan(create);
  const launched = String(r.returnValue);
  await indexer();
  const list = await api("GET", "/launches?sort=new");
  if (!list.launches.some((l: any) => l.token === launched)) throw new Error("launch not indexed");
  const extra = [launched];
  // Sell a little back to the curve.
  const acct = await api("GET", "/account");
  const held = bal(acct, launched);
  const sq = await api("POST", `/launches/${launched}/quote`, { side: "sell", amount: (held / 10n).toString() });
  await runPlan(await api("POST", "/launches/build", { action: "sell", token: launched, amount: (held / 10n).toString(), minOut: ((BigInt(sq.quoteOut) * 98n) / 100n).toString() }), extra);
  // Buy to the threshold: the last buy is clamped.
  const bq = await api("POST", `/launches/${launched}/quote`, { side: "buy", amount: (5_000n * ONE).toString() });
  await runPlan(await api("POST", "/launches/build", { action: "buy", token: launched, amount: (5_000n * ONE).toString(), minOut: ((BigInt(bq.tokensOut) * 98n) / 100n).toString() }), extra);
  let detail = await api("GET", `/launches/${launched}`);
  if (!detail.curve.completed) throw new Error("curve not completed");
  // The keeper graduates it (permissionless, sponsor pays).
  await indexer();
  await new Promise((r) => setTimeout(r, 8_000));
  await indexer();
  detail = await api("GET", `/launches/${launched}?candles=1m`);
  if (!detail.curve.graduated) throw new Error("not graduated by the keeper");
  // Now it trades on Soroswap through the aggregator.
  const q = await api("POST", "/swap/quote", { sell: "XLM", buy: launched, amount: (5n * ONE).toString(), slippageBps: 300 });
  await runPlan(await api("POST", "/swap/build", { quoteId: q.quoteId }), extra);
  // Creator fees accrued from every trade: claim them.
  await runPlan(await api("POST", "/launches/build", { action: "claim", token: launched }));
  return `ECAT ${launched.slice(0, 8)}… launched, sold, completed, graduated to ${detail.curve.pair.slice(0, 8)}… by the keeper, bought on ${q.best.venue}, fees claimed; ${detail.trades.length} trades, ${detail.candles.length} candles`;
}
