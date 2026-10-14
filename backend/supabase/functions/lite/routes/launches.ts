// Launchpad: the board, a launch's page, quotes and trades, creating a launch and its metadata, the launchpad's
// economics and My Launchpad (§6.9).
import { amountArg, bad, intArg, json, notImplemented, readJson, Router } from "../../_shared/http.ts";
import { buildLaunch, launchDetail, listLaunches, quoteTrade } from "../../_shared/launchpad.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/launches", async ({ req, url }) => {
    await user(req);
    const sort = url.searchParams.get("sort") ?? "new";
    return json({ launches: await listLaunches(["new", "hot", "graduated"].includes(sort) ? sort : "new", intArg(url.searchParams.get("limit") ?? 50, "limit", 1, 100)) });
  });

  router.on("GET /v1/launches/:token", async ({ req, params, url }) => {
    await user(req);
    return json(await launchDetail(params.token, url.searchParams.get("candles") ?? undefined));
  });

  router.on("POST /v1/launches/:token/quote", async ({ req, params }) => {
    const u = await user(req);
    const body = await readJson<{ side: string; amount: string }>(req);
    if (body.side !== "buy" && body.side !== "sell") throw bad("bad_side", "side is buy or sell.");
    return json(await quoteTrade(u, params.token, body.side, amountArg(body.amount, "amount")));
  });

  router.on("POST /v1/launches/build", async ({ req }) => {
    const u = await user(req);
    return json(await buildLaunch(u, await readJson(req)));
  });

  // The launch's metadata JSON (name, ticker, description, image, links), written before create.
  router.on("POST /v1/launches/metadata", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });

  // The launchpad's and Moments' economics, read live from the contracts.
  router.on("GET /v1/economics", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });

  // My Launchpad: launches held and created, creator fees, activity.
  router.on("GET /v1/launchpad/me", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });
}
