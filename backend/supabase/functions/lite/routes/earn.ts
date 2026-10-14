// Earn: Blend markets, positions, deposits and withdrawals, rate history (§6.10).
import { amountArg, bad, json, notImplemented, readJson, Router, stringArg } from "../../_shared/http.ts";
import { buildEarn, markets, positions } from "../../_shared/earn.ts";
import { env } from "../../_shared/env.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/earn/markets", async ({ req }) => {
    await user(req);
    return json({ markets: await markets(), note: env.network.name === "testnet" ? "Testnet rates are set by test activity, not real markets." : null });
  });

  router.on("GET /v1/earn/positions", async ({ req }) => json({ positions: await positions(await user(req)) }));

  router.on("POST /v1/earn/build", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ action: string; pool: string; asset: string; amount: string }>(req);
    if (body.action !== "deposit" && body.action !== "withdraw") throw bad("bad_action", "action is deposit or withdraw.");
    return json(await buildEarn(u, body.action, stringArg(body.pool, "pool", 60), stringArg(body.asset, "asset", 60), amountArg(body.amount, "amount")));
  });

  // A market's supply APY and utilization over a week or a month.
  router.on("GET /v1/earn/history", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });
}
