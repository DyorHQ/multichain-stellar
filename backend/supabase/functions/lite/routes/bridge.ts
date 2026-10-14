// Bridge: USDC between Monad and Stellar (CCTP on testnet): quotes, transfers and their progress (§6.10).
import { bridgeQuote, markClaimed, setSourceTx, startBridge, transferStatus } from "../../_shared/bridge.ts";
import { amountArg, json, readJson, Router, stringArg } from "../../_shared/http.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("POST /v1/bridge/quote", async ({ req }) => {
    await user(req);
    const body = await readJson<{ direction: string; amount: string }>(req);
    amountArg(body.amount, "amount");
    return json(await bridgeQuote(body));
  });

  router.on("POST /v1/bridge/start", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ direction: string; amount: string; monadAddress: string }>(req);
    amountArg(body.amount, "amount");
    return json(await startBridge(u, body));
  });

  router.on("POST /v1/bridge/:id/source", async ({ req, params }) => {
    const u = await user(req);
    const body = await readJson<{ txHash: string }>(req);
    return json(await setSourceTx(u, params.id, stringArg(body.txHash, "txHash", 70)));
  });

  router.on("POST /v1/bridge/:id/claimed", async ({ req, params }) => {
    const u = await user(req);
    const body = await readJson<{ txHash: string }>(req);
    return json(await markClaimed(u, params.id, stringArg(body.txHash, "txHash", 70)));
  });

  router.on("GET /v1/bridge/:id", async ({ req, params }) => json(await transferStatus(await user(req), params.id)));
}
