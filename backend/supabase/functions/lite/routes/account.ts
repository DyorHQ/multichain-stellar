// Account: balances and the XLM position (a viewer route), activation, trustlines, testnet's one claim of Friendbot's
// test XLM, sends and recipient checks (§1.1 decision 7, §4.3, §6.4).
import { accountView, activate, publicAccountView, recipient, sendPlan, testnetFaucet, trustPlan } from "../../_shared/account.ts";
import { amountArg, bad, clientIp, json, PUBLIC_VIEW_CACHE, readJson, Router, stringArg } from "../../_shared/http.ts";
import { accountViewer, user } from "./auth.ts";

/** An asset id: XLM, USDC, BUSDC, a C… contract or CODE:G… (at most 12 + 1 + 56 characters). */
const ASSET_ID_MAX = 69;

export function register(router: Router): void {
  // The owner's view with a token; without one, the public view of ?address= (400 address_required with neither).
  router.on("GET /v1/account", async ({ req }) => {
    const v = await accountViewer(req);
    if (v.scope === "owner") return json(await accountView(v.address));
    return json(await publicAccountView(v.address), 200, PUBLIC_VIEW_CACHE);
  });

  router.on("POST /v1/account/activate", async ({ req }) => json(await activate(await user(req), clientIp(req))));

  router.on("POST /v1/account/trust", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ asset?: unknown }>(req);
    return json(await trustPlan(u, stringArg(body.asset, "asset", ASSET_ID_MAX)));
  });

  router.on("POST /v1/account/faucet", async ({ req }) => json(await testnetFaucet(await user(req))));

  router.on("POST /v1/send", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ asset?: unknown; to?: unknown; amount?: unknown; memo?: unknown; memoType?: unknown }>(req);
    const amount = amountArg(body.amount, "amount");
    const to = stringArg(body.to, "to", 69);
    // Exchanges often need a memo on deposits to them: text, a number (id) or a hash.
    const memo = body.memo === undefined || body.memo === null || body.memo === "" ? null : stringArg(body.memo, "memo", 100);
    const memoType = memo ? String(body.memoType ?? "text") : null;
    if (memoType && !["text", "id", "hash"].includes(memoType)) throw bad("bad_memo", "memoType is text, id or hash.");
    return json(await sendPlan(u, { asset: stringArg(body.asset, "asset", ASSET_ID_MAX), to, amount, memo, memoType }));
  });

  // Whether an address exists and can receive an asset; refuses M… addresses (§6.4).
  router.on("GET /v1/recipient/:address", async ({ req, params, url }) => {
    await user(req);
    const asset = url.searchParams.get("asset");
    return json(await recipient(params.address, asset ? stringArg(asset, "asset", ASSET_ID_MAX) : null));
  });
}
