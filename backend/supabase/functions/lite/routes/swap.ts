// Swap: quotes from every venue, then a plan for the chosen route (§6.8).
import { amountArg, intArg, json, readJson, Router, stringArg } from "../../_shared/http.ts";
import { buildSwap, quote } from "../../_shared/swap.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("POST /v1/swap/quote", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ sell: string; buy: string; amount: string; slippageBps?: number }>(req);
    return json(await quote(u, stringArg(body.sell, "sell", 60), stringArg(body.buy, "buy", 60), amountArg(body.amount, "amount"), intArg(body.slippageBps ?? 100, "slippageBps", 1, 1_000)));
  });

  router.on("POST /v1/swap/build", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ quoteId: string }>(req);
    return json(await buildSwap(u, stringArg(body.quoteId, "quoteId", 40)));
  });
}
