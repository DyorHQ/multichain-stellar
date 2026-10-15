// Swap: quotes from every venue, then a plan for the route the user picked (§6.8).
import { amountArg, bad, intArg, json, readJson, Router, stringArg } from "../../_shared/http.ts";
import { buildSwap, quote, Venue } from "../../_shared/swap.ts";
import { user } from "./auth.ts";

const VENUES: Venue[] = ["sdex", "soroswap", "aquarius"];

export function register(router: Router): void {
  router.on("POST /v1/swap/quote", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ sell?: unknown; buy?: unknown; amount?: unknown; slippageBps?: unknown }>(req);
    return json(await quote(u, stringArg(body.sell, "sell", 69), stringArg(body.buy, "buy", 69), amountArg(body.amount, "amount"), intArg(body.slippageBps ?? 100, "slippageBps", 1, 1_000)));
  });

  router.on("POST /v1/swap/build", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ quoteId?: unknown; venue?: unknown }>(req);
    const venue = body.venue === undefined || body.venue === null ? undefined : String(body.venue);
    if (venue !== undefined && !(VENUES as string[]).includes(venue)) throw bad("bad_arg", "venue is sdex, soroswap or aquarius.");
    return json(await buildSwap(u, stringArg(body.quoteId, "quoteId", 40), venue as Venue | undefined));
  });
}
