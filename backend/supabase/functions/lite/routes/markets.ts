// Markets and prices: GET /v1/markets, /v1/markets/:id and /v1/markets/:id/history (public, not written yet), and
// GET /v1/prices, kept for older clients (§6.6).
import { json, Router } from "../../_shared/http.ts";
import { prices } from "../../_shared/prices.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/prices", async ({ req }) => {
    await user(req);
    return json(await prices());
  });
}
