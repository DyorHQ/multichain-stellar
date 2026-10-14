// Account: balances, activation, trustlines, the testnet faucet, sends and recipient checks (§6.4).
import { accountView, friendbotFund, testnetFaucet, usdcAsset } from "../../_shared/account.ts";
import { env } from "../../_shared/env.ts";
import { amountArg, bad, json, notImplemented, readJson, Router, stringArg } from "../../_shared/http.ts";
import { createPlan } from "../../_shared/plans.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/account", async ({ req }) => json(await accountView(await user(req))));

  router.on("POST /v1/account/activate", async ({ req }) => {
    const u = await user(req);
    const acct = await accountView(u);
    const usdc = usdcAsset();
    if (!acct.exists) {
      if (env.network.activation === "friendbot") {
        await friendbotFund(u);
      } else {
        return json(await createPlan(u, "activate", [{ label: "Create your account", spec: { kind: "activate", usdc: usdc.classic } }]));
      }
    }
    const after = await accountView(u);
    const usdcRow = after.balances.find((b) => b.asset === "USDC");
    if (usdcRow && !usdcRow.enabled) {
      return json(await createPlan(u, "trust", [{ label: "Enable USDC", spec: { kind: "trust", asset: usdc.classic } }]));
    }
    return json({ status: "active", account: after });
  });

  router.on("POST /v1/account/trust", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ asset: string }>(req);
    const a = env.network.assets.find((x) => x.id === body.asset);
    if (!a || !a.classic || a.classic === "native") throw bad("bad_asset", "That asset doesn't need enabling.");
    return json(await createPlan(u, "trust", [{ label: `Enable ${a.code}`, spec: { kind: "trust", asset: a.classic } }]));
  });

  router.on("POST /v1/account/faucet", async ({ req }) => json(await testnetFaucet(await user(req))));

  router.on("POST /v1/send", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ asset: string; to: string; amount: string; memo?: string; memoType?: string }>(req);
    const amount = amountArg(body.amount, "amount");
    const to = stringArg(body.to, "to", 69);
    // Anchors and exchanges need a memo on withdrawals (SEP-24 withdraw_memo / withdraw_memo_type).
    const memoType = body.memo ? (body.memoType ?? "text") : null;
    if (memoType && !["text", "id", "hash"].includes(memoType)) throw bad("bad_memo", "memoType is text, id or hash.");
    const spec = { kind: "payment", asset: stringArg(body.asset, "asset", 60), to, amount: amount.toString(), memo: body.memo ?? null, memoType };
    return json(await createPlan(u, "payment", [{ label: "Send", spec }]));
  });

  // Whether an address exists and can receive an asset; refuses M… addresses (§6.4).
  router.on("GET /v1/recipient/:address", async ({ req }) => {
    await user(req);
    throw notImplemented();
  });
}
