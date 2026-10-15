// Markets and prices (public; docs/DESIGN-stellar-parity.md §6.0, §6.6): GET /v1/markets, /v1/markets/:id and
// /v1/markets/:id/history, and GET /v1/prices, kept for older clients. They read the database, the isolate's
// reference cache and, for a classic asset's page, the asset directory; they need no session (a token that is sent is
// ignored) and may be cached for 30 s.
import { json, PUBLIC_CACHE, Router } from "../../_shared/http.ts";
import { market, marketHistory, markets, rangeArg } from "../../_shared/markets.ts";
import { prices } from "../../_shared/prices.ts";

export function register(router: Router): void {
  router.on("GET /v1/markets", async () => json(await markets(), 200, PUBLIC_CACHE));

  router.on("GET /v1/markets/:id", async ({ params }) => json(await market(params.id), 200, PUBLIC_CACHE));

  router.on("GET /v1/markets/:id/history", async ({ params, url }) => {
    return json(await marketHistory(params.id, rangeArg(url.searchParams.get("range"))), 200, PUBLIC_CACHE);
  });

  router.on("GET /v1/prices", async () => json(await prices(), 200, PUBLIC_CACHE));
}
