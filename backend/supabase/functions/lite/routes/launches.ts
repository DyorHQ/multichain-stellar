// Launchpad (§6.9): the board and a launch's page (viewer routes: no session needed, §6.0), trade quotes, a coin's
// metadata and its plans (session routes), the launchpad's and Moments' economics (public, read live from the
// contracts) and My Launchpad (session: DyorHQ's history).
import { economics } from "../../_shared/economics.ts";
import { amountArg, bad, json, PUBLIC_CACHE, rateLimit, readJson, Router } from "../../_shared/http.ts";
import { writeLaunchMetadata } from "../../_shared/launch_metadata.ts";
import { boardQuery, buildLaunch, launchBoard, launchDetail, myLaunchpad, quoteTrade } from "../../_shared/launchpad.ts";
import { user, viewer } from "./auth.ts";

/** A public view (no token) may be cached for 15 s (§6.0); the owner's view never is. */
const PUBLIC_VIEW = { "cache-control": "public, max-age=15" };

/** The JSON object a request carries; other JSON reads as an object with no fields, which the route's own checks
 *  refuse with 400. */
async function body<T>(req: Request): Promise<Partial<T>> {
  const b = await readJson<unknown>(req);
  return (b !== null && typeof b === "object" && !Array.isArray(b) ? b : {}) as Partial<T>;
}

export function register(router: Router): void {
  router.on("GET /v1/launches", async ({ req, url }) => {
    const v = await viewer(req);
    const board = await launchBoard(boardQuery(url.searchParams), v.scope);
    return v.scope === "public" ? json(board, 200, PUBLIC_VIEW) : json(board);
  });

  router.on("GET /v1/launches/:token", async ({ req, params, url }) => {
    const v = await viewer(req);
    const detail = await launchDetail(params.token, v, url.searchParams.get("candles") ?? undefined);
    return v.scope === "public" ? json(detail, 200, PUBLIC_VIEW) : json(detail);
  });

  router.on("POST /v1/launches/:token/quote", async ({ req, params }) => {
    const u = await user(req);
    const b = await body<{ side: string; amount: string }>(req);
    if (b.side !== "buy" && b.side !== "sell") throw bad("bad_side", "side is buy or sell.");
    return json(await quoteTrade(u, params.token, b.side, amountArg(b.amount, "amount")));
  });

  router.on("POST /v1/launches/build", async ({ req }) => json(await buildLaunch(await user(req), await body(req))));

  // The coin's metadata JSON (name, ticker, description, image, links), written before create.
  router.on("POST /v1/launches/metadata", async ({ req }) => {
    const u = await user(req);
    rateLimit(`metadata:${u}`, 10);
    return json(await writeLaunchMetadata(u, await body(req)));
  });

  router.on("GET /v1/economics", async () => json(await economics(), 200, PUBLIC_CACHE));

  // My Launchpad: launches held and created, creator fees, activity.
  router.on("GET /v1/launchpad/me", async ({ req }) => json(await myLaunchpad(await user(req))));
}
