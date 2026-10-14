// DyorHQ Lite API (Stellar). Deployed as the `lite` Edge Function with verify_jwt = false: the API checks the Lite JWT
// and the tester allowlist itself, here, before any route that isn't public runs. Routes live in routes/<area>.ts
// (docs/DESIGN-stellar-parity.md §6.1) and match in the order the modules register below.
// Every plan step's builder registers itself when its module loads: load them all, whichever routes use them.
import "../_shared/account.ts";
import "../_shared/swap.ts";
import "../_shared/earn.ts";
import "../_shared/launchpad.ts";
import "../_shared/moments.ts";
import "../_shared/bridge.ts";
import { ApiError, clientIp, json, rateLimit, Router } from "../_shared/http.ts";
import * as account from "./routes/account.ts";
import * as activity from "./routes/activity.ts";
import * as assets from "./routes/assets.ts";
import * as auth from "./routes/auth.ts";
import * as bridge from "./routes/bridge.ts";
import * as cash from "./routes/cash.ts";
import * as config from "./routes/config.ts";
import * as earn from "./routes/earn.ts";
import * as fees from "./routes/fees.ts";
import * as holdings from "./routes/holdings.ts";
import * as launches from "./routes/launches.ts";
import * as markets from "./routes/markets.ts";
import * as moments from "./routes/moments.ts";
import * as plans from "./routes/plans.ts";
import * as portfolio from "./routes/portfolio.ts";
import * as swap from "./routes/swap.ts";

/** Routes anyone may call (§6.0): sign-in, the network's configuration, fees and market data, and the local stack's
 *  stand-in for public Storage, whose uploads carry their own signature. None reads an account's data. */
const PUBLIC = /^[A-Z]+ \/v1\/(auth\/|config$|fees$|markets(\/|$)|prices$|local-media\/)/;

export function isPublic(route: string): boolean {
  return PUBLIC.test(route);
}

const MODULES = [auth, config, fees, account, plans, swap, markets, assets, launches, earn, moments, bridge, cash, holdings, portfolio, activity];

export const router = new Router().before(async (req, route) => {
  if (isPublic(route)) rateLimit(`public:${clientIp(req)}`, 300);
  else await auth.user(req);
});
for (const m of MODULES) m.register(router);

/** The API's request handler. Running this file serves it; tests import it. */
export function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return Promise.resolve(new Response(null, { status: 204 }));
  return router.handle(req).catch((err) => {
    if (err instanceof ApiError) return json({ error: { code: err.code, message: err.message } }, err.status);
    console.error(err);
    return json({ error: { code: "internal", message: "Something went wrong on our side." } }, 500);
  });
}

if (import.meta.main) Deno.serve(handle);
