// Activity: the account's transactions, bridge transfers and anchor transfers, newest first (§6.10), by section, kind,
// period and market. A session route: DyorHQ's history.
import { activity, kindArg, marketArg, periodArg, sectionArg } from "../../_shared/activity.ts";
import { intArg, json, Router } from "../../_shared/http.ts";
import { user } from "./auth.ts";

/** Items answered when ?limit= is absent, and at most. */
const LIMIT_DEFAULT = 80;
const LIMIT_MAX = 200;

export function register(router: Router): void {
  router.on("GET /v1/activity", async ({ req, url }) => {
    const u = await user(req);
    const q = url.searchParams;
    const items = await activity(u, {
      section: sectionArg(q.get("section")),
      kind: kindArg(q.get("kind")),
      period: periodArg(q.get("period"), "all"),
      market: marketArg(q.get("market")),
      limit: intArg(q.get("limit") ?? LIMIT_DEFAULT, "limit", 1, LIMIT_MAX),
    });
    return json({ items });
  });
}
