// Portfolio: GET /v1/portfolio?period=, volume, fees and P&L per section over a period, and its activity (§6.7). A
// session route: DyorHQ's history.
import { periodArg } from "../../_shared/activity.ts";
import { json, Router } from "../../_shared/http.ts";
import { portfolio } from "../../_shared/portfolio.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/portfolio", async ({ req, url }) => {
    const u = await user(req);
    return json(await portfolio(u, periodArg(url.searchParams.get("period"), "all")));
  });
}
