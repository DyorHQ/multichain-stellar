// DyorHQ Lite API (Stellar). Deployed as the `lite` Edge Function with verify_jwt = false: every route except
// auth/* and config checks the Lite JWT and the tester allowlist itself (requireUser).
import "../_shared/account.ts";
import "../_shared/swap.ts";
import "../_shared/earn.ts";
import "../_shared/launchpad.ts";
import "../_shared/moments.ts";
import "../_shared/bridge.ts";
import { accountView, friendbotFund, testnetFaucet, usdcAsset } from "../_shared/account.ts";
import { assertAccountId, createChallenge, requireUser, verifyChallenge } from "../_shared/auth.ts";
import { bridgeQuote, markClaimed, setSourceTx, startBridge, transferStatus } from "../_shared/bridge.ts";
import { sql, num } from "../_shared/db.ts";
import { buildEarn, markets, positions } from "../_shared/earn.ts";
import { env } from "../_shared/env.ts";
import { amountArg, ApiError, bad, clientIp, intArg, json, rateLimit, readJson, Router, stringArg } from "../_shared/http.ts";
import { buildLaunch, launchDetail, listLaunches, quoteTrade } from "../_shared/launchpad.ts";
import { signedUpload } from "../_shared/media.ts";
import { buildMoment, feed, momentDetail, owned, writeMetadata } from "../_shared/moments.ts";
import { contractAllowlist } from "../_shared/networks.ts";
import { buildStep, createPlan, submitStep, trackTx } from "../_shared/plans.ts";
import { prices } from "../_shared/prices.ts";
import { sponsor } from "../_shared/stellar.ts";
import { buildSwap, quote } from "../_shared/swap.ts";

const router = new Router();

async function user(req: Request): Promise<string> {
  const address = await requireUser(req);
  rateLimit(`u:${address}`, 120);
  return address;
}

// ------------------------------------------------------------------------------------------------ auth & config

router.on("POST /v1/auth/challenge", async ({ req }) => {
  rateLimit(`ip:${clientIp(req)}`, 20);
  const body = await readJson<{ address: string }>(req);
  return json(await createChallenge(assertAccountId(body.address)));
});

router.on("POST /v1/auth/verify", async ({ req }) => {
  rateLimit(`ip:${clientIp(req)}`, 20);
  const body = await readJson<{ address: string; nonce: string; signature: string; inviteCode?: string }>(req);
  return json(await verifyChallenge(body));
});

router.on("GET /v1/config", async () => {
  const net = env.network;
  const cfg = await sql()`select value from lite.app_config where key = 'lite'`;
  return json({
    network: net.name,
    passphrase: net.passphrase,
    rpcUrl: net.rpcUrl,
    horizonUrl: net.horizonUrl,
    activation: net.activation,
    sponsor: sponsor().publicKey(),
    assets: net.assets,
    contracts: net.contracts,
    allowlist: contractAllowlist(net),
    anchors: net.anchors,
    bridge: { routes: net.bridge.routes, monad: net.bridge.monad ? { chainId: net.bridge.monad.chainId, usdc: net.bridge.monad.usdc } : null },
    flags: cfg[0]?.value ?? { enabled: false },
    minBuild: env.minBuild,
  });
});

// ------------------------------------------------------------------------------------------------ account

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
  const body = await readJson<{ asset: string; to: string; amount: string }>(req);
  const amount = amountArg(body.amount, "amount");
  const to = stringArg(body.to, "to", 69);
  return json(await createPlan(u, "payment", [{ label: "Send", spec: { kind: "payment", asset: stringArg(body.asset, "asset", 60), to, amount: amount.toString() } }]));
});

// ------------------------------------------------------------------------------------------------ plans & transactions

router.on("POST /v1/plans/:plan/steps/:step/build", async ({ req, params }) => json(await buildStep(await user(req), params.plan, params.step)));

router.on("POST /v1/tx/submit", async ({ req }) => {
  const u = await user(req);
  rateLimit(`submit:${u}`, 20);
  const body = await readJson<{ planId: string; stepId: string; signedXdr: string }>(req);
  return json(await submitStep(u, stringArg(body.planId, "planId", 40), stringArg(body.stepId, "stepId", 8), stringArg(body.signedXdr, "signedXdr", 60_000)));
});

router.on("GET /v1/tx/:hash", async ({ req, params }) => json(await trackTx(await user(req), params.hash)));

// ------------------------------------------------------------------------------------------------ swap

router.on("POST /v1/swap/quote", async ({ req }) => {
  const u = await user(req);
  const body = await readJson<{ sell: string; buy: string; amount: string; slippageBps?: number }>(req);
  return json(await quote(u, stringArg(body.sell, "sell", 60), stringArg(body.buy, "buy", 60), amountArg(body.amount, "amount"), intArg(body.slippageBps ?? 100, "slippageBps", 1, 1_000)));
});

router.on("POST /v1/swap/build", async ({ req }) => {
  const u = await user(req);
  const body = await readJson<{ quoteId: string }>(req);
  return json(await buildSwap(u, stringArg(body.quoteId, "quoteId", 40)));
});

// ------------------------------------------------------------------------------------------------ earn

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

// ------------------------------------------------------------------------------------------------ launchpad

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

router.on("POST /v1/media/upload-url", async ({ req }) => {
  const u = await user(req);
  rateLimit(`upload:${u}`, 10);
  const body = await readJson<{ contentType: string; bytes: number }>(req);
  return json(await signedUpload(u, stringArg(body.contentType, "contentType", 40), Number(body.bytes)));
});

// ------------------------------------------------------------------------------------------------ moments

router.on("GET /v1/moments", async ({ req, url }) => {
  await user(req);
  return json({ moments: await feed(intArg(url.searchParams.get("limit") ?? 50, "limit", 1, 100)) });
});

router.on("GET /v1/moments/owned", async ({ req }) => json({ editions: await owned(await user(req)) }));

router.on("GET /v1/moments/:id", async ({ req, params }) => {
  await user(req);
  return json(await momentDetail(intArg(params.id, "id", 1, 2 ** 31)));
});

router.on("POST /v1/moments/metadata", async ({ req }) => {
  const u = await user(req);
  return json({ uri: await writeMetadata(u, await readJson(req)) });
});

router.on("POST /v1/moments/build", async ({ req }) => json(await buildMoment(await user(req), await readJson(req))));

// ------------------------------------------------------------------------------------------------ bridge

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

// ------------------------------------------------------------------------------------------------ cash (anchors)

router.on("GET /v1/cash/anchors", async ({ req, url }) => {
  await user(req);
  const country = (url.searchParams.get("country") ?? "*").toUpperCase();
  const anchors = env.network.anchors.filter((a) => a.countries.includes("*") || a.countries.includes(country));
  return json({ anchors });
});

router.on("POST /v1/cash/track", async ({ req }) => {
  const u = await user(req);
  const body = await readJson<{ anchor: string; kind: string; asset: string; amount?: string; anchorTxId: string; status?: string }>(req);
  if (!env.network.anchors.some((a) => a.domain === body.anchor)) throw bad("bad_anchor", "Unknown anchor.");
  if (body.kind !== "deposit" && body.kind !== "withdraw") throw bad("bad_kind", "kind is deposit or withdraw.");
  const rows = await sql()`
    insert into lite.anchor_transfers (address, anchor, kind, asset, amount, anchor_tx_id, status)
    values (${u}, ${body.anchor}, ${body.kind}, ${stringArg(body.asset, "asset", 20)}, ${body.amount ?? null}, ${stringArg(body.anchorTxId, "anchorTxId", 100)}, ${body.status ?? "incomplete"})
    on conflict (anchor, anchor_tx_id) do update set status = excluded.status, amount = coalesce(excluded.amount, lite.anchor_transfers.amount), updated_at = now()
    returning id`;
  return json({ id: rows[0].id });
});

// ------------------------------------------------------------------------------------------------ activity & prices

router.on("GET /v1/activity", async ({ req }) => {
  const u = await user(req);
  const txs = await sql()`select hash, kind, intent, status, ledger, created_at from lite.tx_log where address = ${u} order by created_at desc limit 50`;
  const bridges = await sql()`select id, direction, amount, status, created_at from lite.bridge_transfers where address = ${u} order by created_at desc limit 20`;
  const cash = await sql()`select id, anchor, kind, asset, amount, status, created_at from lite.anchor_transfers where address = ${u} order by created_at desc limit 20`;
  const items = [
    ...txs.map((t) => ({ type: "tx", id: t.hash, kind: t.kind, summary: (t.intent as any)?.summary ?? t.kind, display: (t.intent as any)?.display ?? null, status: t.status, at: t.created_at })),
    ...bridges.map((b) => ({ type: "bridge", id: b.id, kind: b.direction, summary: b.direction === "monad_to_stellar" ? "Moved USDC from Monad" : "Sent USDC to Monad", amount: num(b.amount), status: b.status, at: b.created_at })),
    ...cash.map((c) => ({ type: "cash", id: c.id, kind: c.kind, summary: c.kind === "deposit" ? `Added ${c.asset}` : `Cashed out ${c.asset}`, amount: c.amount === null ? null : num(c.amount), status: c.status, at: c.created_at })),
  ].sort((a, b) => new Date(b.at as string).getTime() - new Date(a.at as string).getTime());
  return json({ items: items.slice(0, 80) });
});

router.on("GET /v1/prices", async ({ req }) => {
  await user(req);
  return json(await prices());
});

Deno.serve((req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204 });
  return router.handle(req).catch((err) => {
    if (err instanceof ApiError) return json({ error: { code: err.code, message: err.message } }, err.status);
    console.error(err);
    return json({ error: { code: "internal", message: "Something went wrong on our side." } }, 500);
  });
});
