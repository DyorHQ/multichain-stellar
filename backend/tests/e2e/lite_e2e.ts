// End-to-end journey against Stellar testnet, acting as the phone: the same verify → sign → submit → poll loop
// StellarKit's PlanRunner runs. Needs the lite API running (LITE_API, default http://127.0.0.1:8000/lite) and a
// database the test can write an invite into (LITE_DB_URL).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e.ts [phases...]
//   phases: auth swap earn launch moments send bridge anchor (default: all)
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import postgres from "postgres";
import { hex, SEP53_PREFIX, sha256 } from "../../supabase/functions/_shared/auth.ts";
import { verifyTransaction } from "../../supabase/functions/_shared/verify.ts";

const API = Deno.env.get("LITE_API") ?? "http://127.0.0.1:8000/lite";
const db = postgres(Deno.env.get("LITE_DB_URL")!, { onnotice: () => {} });
const only = Deno.args.length ? new Set(Deno.args) : null;
const ONE = 10_000_000n;
const results: { phase: string; ok: boolean; detail: string }[] = [];

let token = "";
let config: any;
const user = Keypair.random();

async function api(method: string, path: string, body?: unknown): Promise<any> {
  const res = await fetch(`${API}/v1${path}`, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${JSON.stringify(json.error ?? json)}`);
  return json;
}

/** The phone's loop: for each step, build if needed, verify against the pinned allowlist, sign, submit, wait. */
async function runPlan(plan: any, extraContracts: string[] = []): Promise<any[]> {
  const outs: any[] = [];
  for (let i = 0; i < plan.steps.length; i++) {
    let step = plan.steps[i];
    if (!step.xdr) {
      const rebuilt = await api("POST", `/plans/${plan.planId}/steps/${step.id}/build`);
      step = rebuilt.steps[i];
    }
    const tx = TransactionBuilder.fromXDR(step.xdr, config.passphrase) as Transaction;
    const allowed = new Set<string>([...Object.values(config.allowlist as Record<string, string[]>).flat(), ...extraContracts]);
    verifyTransaction(tx, step.intent, { user: user.publicKey(), sponsor: config.sponsor, passphrase: config.passphrase, allowedContracts: allowed });
    tx.sign(user);
    const sent = await api("POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
    let status = sent;
    for (let k = 0; k < 40 && status.status === "pending"; k++) {
      await new Promise((r) => setTimeout(r, 1_500));
      status = await api("GET", `/tx/${sent.hash}`);
    }
    if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
    outs.push(status);
    console.log(`    ✓ ${step.label} ${sent.hash.slice(0, 12)}…`);
  }
  return outs;
}

async function phase(name: string, fn: () => Promise<string>) {
  if (only && !only.has(name)) return;
  console.log(`▶ ${name}`);
  try {
    const detail = await fn();
    results.push({ phase: name, ok: true, detail });
    console.log(`  PASS ${detail}`);
  } catch (err) {
    results.push({ phase: name, ok: false, detail: String((err as Error).message ?? err) });
    console.log(`  FAIL ${(err as Error).message}`);
  }
}

async function indexer() {
  const mod = await import("../../supabase/functions/lite-indexer/index.ts");
  return { events: await mod.indexEvents(), settled: await mod.settlePending(), graduated: await mod.keeper() };
}

function bal(acct: any, id: string): bigint {
  return BigInt(acct.balances.find((b: any) => b.asset === id)?.balance ?? "0");
}

// ------------------------------------------------------------------------------------------------ journey

await phase("auth", async () => {
  config = await api("GET", "/config");
  const code = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
  await db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(code))}, 'e2e', 1)`;
  const ch = await api("POST", "/auth/challenge", { address: user.publicKey() });
  const sig = user.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message)));
  // Without the invite: refused.
  const refused = await fetch(`${API}/v1/auth/verify`, { method: "POST", body: JSON.stringify({ address: user.publicKey(), nonce: ch.nonce, signature: sig.toString("base64") }) });
  if (refused.status !== 403) throw new Error(`expected 403 without invite, got ${refused.status}`);
  const ch2 = await api("POST", "/auth/challenge", { address: user.publicKey() });
  const sig2 = user.sign(Buffer.from(await sha256(SEP53_PREFIX + ch2.message)));
  const v = await api("POST", "/auth/verify", { address: user.publicKey(), nonce: ch2.nonce, signature: sig2.toString("base64"), inviteCode: code });
  token = v.token;
  // Nonce replay is refused.
  const replay = await fetch(`${API}/v1/auth/verify`, { method: "POST", body: JSON.stringify({ address: user.publicKey(), nonce: ch2.nonce, signature: sig2.toString("base64") }) });
  if (replay.status !== 401) throw new Error(`expected 401 on replay, got ${replay.status}`);
  // Activate: Friendbot on testnet, then a sponsored USDC trustline.
  const act = await api("POST", "/account/activate");
  if (act.planId) await runPlan(act);
  const acct = await api("GET", "/account");
  const usdc = acct.balances.find((b: any) => b.asset === "USDC");
  if (!acct.exists || !usdc.enabled) throw new Error("account not active with USDC");
  return `signed in ${user.publicKey().slice(0, 8)}…, XLM ${bal(acct, "XLM") / ONE}, USDC enabled (reserve sponsored: ${acct.reserves.sponsoredByDyorHQ})`;
});

await phase("swap", async () => {
  const q = await api("POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: (50n * ONE).toString(), slippageBps: 300 });
  const plan = await api("POST", "/swap/build", { quoteId: q.quoteId });
  await runPlan(plan);
  const acct = await api("GET", "/account");
  const routes = [q.best, ...q.alternatives].map((r: any) => `${r.venue}:${(Number(r.amountOut) / 1e7).toFixed(2)}`).join(" ");
  return `50 XLM → ${(Number(bal(acct, "USDC")) / 1e7).toFixed(4)} USDC via ${q.best.venue} (quotes ${routes})`;
});

await phase("earn", async () => {
  const m = await api("GET", "/earn/markets");
  const xlmMarket = m.markets.find((x: any) => x.code === "XLM");
  const dep = await api("POST", "/earn/build", { action: "deposit", pool: xlmMarket.pool, asset: xlmMarket.asset, amount: (100n * ONE).toString() });
  await runPlan(dep);
  const p1 = await api("GET", "/earn/positions");
  const pos = p1.positions.find((x: any) => x.asset === xlmMarket.asset);
  if (!pos || BigInt(pos.supplied) < 99n * ONE) throw new Error(`position ${JSON.stringify(p1)}`);
  const wd = await api("POST", "/earn/build", { action: "withdraw", pool: xlmMarket.pool, asset: xlmMarket.asset, amount: (40n * ONE).toString() });
  await runPlan(wd);
  const p2 = await api("GET", "/earn/positions");
  const after = p2.positions.find((x: any) => x.asset === xlmMarket.asset);
  return `supplied 100 XLM at ${(xlmMarket.supplyApy * 100).toFixed(2)}% APY (testnet), withdrew 40 → position ${(Number(after.supplied) / 1e7).toFixed(4)} XLM`;
});

let launched = "";
await phase("launch", async () => {
  const create = await api("POST", "/launches/build", { action: "create", quote: "XLM", name: "E2E Cat", symbol: "ECAT", uri: "", creatorFeeBps: 100, amount: (100n * ONE).toString(), minOut: "0" });
  const [r] = await runPlan(create);
  launched = String(r.returnValue);
  await indexer();
  const list = await api("GET", "/launches?sort=new");
  if (!list.launches.some((l: any) => l.token === launched)) throw new Error("launch not indexed");
  const extra = [launched];
  // Sell a little back to the curve.
  const acct = await api("GET", "/account");
  const held = bal(acct, launched);
  const sq = await api("POST", `/launches/${launched}/quote`, { side: "sell", amount: (held / 10n).toString() });
  await runPlan(await api("POST", "/launches/build", { action: "sell", token: launched, amount: (held / 10n).toString(), minOut: ((BigInt(sq.quoteOut) * 98n) / 100n).toString() }), extra);
  // Buy to the threshold: the last buy is clamped.
  const bq = await api("POST", `/launches/${launched}/quote`, { side: "buy", amount: (5_000n * ONE).toString() });
  await runPlan(await api("POST", "/launches/build", { action: "buy", token: launched, amount: (5_000n * ONE).toString(), minOut: ((BigInt(bq.tokensOut) * 98n) / 100n).toString() }), extra);
  let detail = await api("GET", `/launches/${launched}`);
  if (!detail.curve.completed) throw new Error("curve not completed");
  // The keeper graduates it (permissionless, sponsor pays).
  await indexer();
  await new Promise((r) => setTimeout(r, 8_000));
  await indexer();
  detail = await api("GET", `/launches/${launched}?candles=1m`);
  if (!detail.curve.graduated) throw new Error("not graduated by the keeper");
  // Now it trades on Soroswap through the aggregator.
  const q = await api("POST", "/swap/quote", { sell: "XLM", buy: launched, amount: (5n * ONE).toString(), slippageBps: 300 });
  await runPlan(await api("POST", "/swap/build", { quoteId: q.quoteId }), extra);
  // Creator fees accrued from every trade: claim them.
  await runPlan(await api("POST", "/launches/build", { action: "claim", token: launched }));
  return `ECAT ${launched.slice(0, 8)}… launched, sold, completed, graduated to ${detail.curve.pair.slice(0, 8)}… by the keeper, bought on ${q.best.venue}, fees claimed; ${detail.trades.length} trades, ${detail.candles.length} candles`;
});

await phase("moments", async () => {
  const uri = `https://local.invalid/storage/v1/object/public/lite-media/moments/${user.publicKey()}/e2e.json`;
  const [r] = await runPlan(await api("POST", "/moments/build", { action: "publish", uri, price: (2n * ONE).toString(), quote: "XLM", maxEditions: 10, windowSecs: 7_200 }));
  const id = Number(r.returnValue);
  await indexer();
  const feed = await api("GET", "/moments");
  if (!feed.moments.some((m: any) => m.id === id)) throw new Error("moment not indexed");
  await runPlan(await api("POST", "/moments/build", { action: "collect", momentId: id, quantity: 2 }));
  await indexer();
  const owned = await api("GET", "/moments/owned");
  const mine = owned.editions.filter((x: any) => x.momentId === id).length;
  if (mine !== 2) throw new Error(`owned ${mine}`);
  return `published Moment #${id} (2 XLM, 10 editions), collected 2, own ${mine}`;
});

await phase("send", async () => {
  const to = Keypair.random().publicKey();
  await runPlan(await api("POST", "/send", { asset: "XLM", to, amount: (5n * ONE).toString() })); // creates the account
  await runPlan(await api("POST", "/send", { asset: "XLM", to, amount: (1n * ONE).toString() }));
  const r = await fetch(`${API}/v1/send`, { method: "POST", headers: { authorization: `Bearer ${token}` }, body: JSON.stringify({ asset: "USDC", to, amount: "100000" }) });
  const body = await r.json();
  if (body.error?.code !== "recipient_cannot_receive") throw new Error(`expected recipient_cannot_receive, got ${JSON.stringify(body)}`);
  return "created a new account with 5 XLM, sent 1 more; USDC to an account without a trustline refused before signing";
});

await phase("bridge", async () => {
  const q = await api("POST", "/bridge/quote", { direction: "stellar_to_monad", amount: (1n * ONE).toString() });
  const start = await api("POST", "/bridge/start", { direction: "stellar_to_monad", amount: "1000000", monadAddress: "0x000000000000000000000000000000000000dEaD" });
  const outs = await runPlan(start.plan);
  const r = outs[outs.length - 1];
  // The phone reports the burn's transaction hash (the fee-bump hash it got from /tx/submit; Iris indexes that one).
  const hash = r.hash as string;
  await api("POST", `/bridge/${start.transfer.id}/source`, { txHash: hash });
  const back = await api("POST", "/bridge/start", { direction: "monad_to_stellar", amount: "1000000", monadAddress: "0x000000000000000000000000000000000000dEaD" });
  return `quote ${q.route} eta ${q.etaSeconds}s; burned 0.1 USDC on Stellar for Monad (tx ${hash.slice(0, 10)}…, awaiting Iris); Monad→Stellar returns ${back.evmSteps.length} EVM steps`;
});

await phase("anchor", async () => {
  const anchors = await api("GET", "/cash/anchors");
  const a = anchors.anchors[0];
  const toml = await (await fetch(`https://${a.domain}/.well-known/stellar.toml`)).text();
  const webAuth = toml.match(/WEB_AUTH_ENDPOINT\s*=\s*"([^"]+)"/)![1];
  const transfer = toml.match(/TRANSFER_SERVER_SEP0024\s*=\s*"([^"]+)"/)![1];
  const signingKey = toml.match(/SIGNING_KEY\s*=\s*"([^"]+)"/)![1];
  const ch = await (await fetch(`${webAuth}?account=${user.publicKey()}`)).json();
  const tx = TransactionBuilder.fromXDR(ch.transaction, ch.network_passphrase) as Transaction;
  if (!tx.signatures.some((s) => Keypair.fromPublicKey(signingKey).verify(tx.hash(), s.signature()))) throw new Error("challenge not signed by the anchor");
  if (tx.sequence !== "0") throw new Error("SEP-10 challenge must have sequence 0");
  tx.sign(user);
  const jwt = (await (await fetch(webAuth, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ transaction: tx.toEnvelope().toXDR("base64") }) })).json()).token;
  const dep = await (await fetch(`${transfer}/transactions/deposit/interactive`, {
    method: "POST",
    headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
    body: JSON.stringify({ asset_code: "USDC", account: user.publicKey(), lang: "en" }),
  })).json();
  if (!dep.url || !dep.id) throw new Error(JSON.stringify(dep));
  await api("POST", "/cash/track", { anchor: a.domain, kind: "deposit", asset: "USDC", anchorTxId: dep.id, status: "incomplete" });
  const act = await api("GET", "/activity");
  return `SEP-10 signed in at ${a.domain}, SEP-24 deposit ${dep.id.slice(0, 8)}… interactive URL issued, tracked; activity has ${act.items.length} items`;
});

await phase("prices", async () => {
  const p = await api("GET", "/prices");
  return `XLM $${p.usd.XLM.toFixed(4)} (${p.reference})`;
});

console.log("\n" + results.map((r) => `${r.ok ? "PASS" : "FAIL"}  ${r.phase.padEnd(8)} ${r.detail}`).join("\n"));
await db.end();
Deno.exit(results.every((r) => r.ok) ? 0 : 1);
