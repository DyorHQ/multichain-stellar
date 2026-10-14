// swap: 50 XLM for USDC through the best venue's route.
import type { E2E } from "../lite_e2e.ts";

export default async function swap({ api, bal, ONE, runPlan }: E2E): Promise<string> {
  const q = await api("POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: (50n * ONE).toString(), slippageBps: 300 });
  const plan = await api("POST", "/swap/build", { quoteId: q.quoteId });
  await runPlan(plan);
  const acct = await api("GET", "/account");
  const routes = [q.best, ...q.alternatives].map((r: any) => `${r.venue}:${(Number(r.amountOut) / 1e7).toFixed(2)}`).join(" ");
  return `50 XLM → ${(Number(bal(acct, "USDC")) / 1e7).toFixed(4)} USDC via ${q.best.venue} (quotes ${routes})`;
}
