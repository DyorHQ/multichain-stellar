// Earn (§6.10): Blend's markets and a market's rate history (public: no session, any token ignored), an account's
// positions (a viewer route) and deposit and withdrawal plans (session).
import { amountArg, bad, json, PUBLIC_CACHE, readJson, Router, stringArg } from "../../_shared/http.ts";
import { buildEarn, history, markets, positions } from "../../_shared/earn.ts";
import { accountViewer, user } from "./auth.ts";

/** A public view (no token) may be cached for 15 s (§6.0); the owner's view never is. */
const PUBLIC_VIEW = { "cache-control": "public, max-age=15" };

export function register(router: Router): void {
  router.on("GET /v1/earn/markets", async () => json(await markets(), 200, PUBLIC_CACHE));

  // The owner's view with a token; without one, the public view of ?address= (400 address_required with neither).
  router.on("GET /v1/earn/positions", async ({ req }) => {
    const v = await accountViewer(req);
    const body = { positions: await positions(v.address, v.scope), view: v.scope };
    return v.scope === "public" ? json(body, 200, PUBLIC_VIEW) : json(body);
  });

  router.on("POST /v1/earn/build", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ action: string; pool: string; asset: string; amount: string; all?: unknown }>(req);
    if (body.action !== "deposit" && body.action !== "withdraw") throw bad("bad_action", "action is deposit or withdraw.");
    if (body.all !== undefined && typeof body.all !== "boolean") throw bad("bad_arg", "all is true or false.");
    return json(await buildEarn(u, body.action, stringArg(body.pool, "pool", 60), stringArg(body.asset, "asset", 60), amountArg(body.amount, "amount"), body.all === true));
  });

  // A market's supply APY and utilization over a week or a month.
  router.on("GET /v1/earn/history", async ({ url }) => {
    const q = url.searchParams;
    return json(await history(q.get("pool"), q.get("asset"), q.get("range")), 200, PUBLIC_CACHE);
  });
}
