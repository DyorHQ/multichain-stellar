// launch (docs/DESIGN-stellar-parity.md §12.6; WP-14): a coin launched with its metadata (an uploaded image, a
// description, links) and a developer buy at the client's 1% minimum, shown with them on the board's public view;
// holders 1 → 2 as a second account buys; sold back, bought to the threshold, graduated by hand (the user pays), then
// bought through Soroswap (a priced pool_swaps row); the creator's fees claimed (a creator_claims row); market cap in
// USD set; My Launchpad lists it (with a session only); and reconcile leaves every holder's indexed balance equal to
// its live balance(). The economics and the board need no session.
//
// Before the owner's redeploy (O-1) it runs on the current deployment, whose feed that redeploy retires; after it,
// only on testnet-qa (Q3). E2E_NO_MEDIA=1 is for a stack without media storage (before the local media stand-in): the
// coin is then launched without metadata, and the summary says so.
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import { hex, SEP53_PREFIX, sha256 } from "../../../supabase/functions/_shared/auth.ts";
import { verifyTransaction } from "../../../supabase/functions/_shared/verify.ts";
import type { E2E } from "../lite_e2e.ts";

const NAME = "E2E Cat";
const SYMBOL = "ECAT";
const DESCRIPTION = "A cat that runs end-to-end tests.";
const WEBSITE = "https://dyorhq.fun/";
const X = "https://x.com/dyorhq";
const CREATOR_FEE_BPS = 100;
/** A 1×1 PNG. */
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));

interface Answer {
  status: number;
  body: any;
  cache: string | null;
}

/** A request as the holder of `token` (none: no Authorization header), whatever its status. */
async function call(t: E2E, token: string | null, method: string, path: string, body?: unknown): Promise<Answer> {
  const res = await fetch(`${t.API}/v1${path}`, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null, cache: res.headers.get("cache-control") };
}

/** call(), throwing unless 2xx. */
async function api(t: E2E, token: string | null, method: string, path: string, body?: unknown): Promise<any> {
  const a = await call(t, token, method, path, body);
  if (a.status < 200 || a.status > 299) throw new Error(`${method} ${path} → ${a.status} ${JSON.stringify(a.body?.error ?? a.body)}`);
  return a.body;
}

/** Signs `kp` in (SEP-53), with an invite written first where the network needs one. */
async function signIn(t: E2E, kp: Keypair): Promise<string> {
  let inviteCode: string | undefined;
  if (t.config.inviteRequired !== false) {
    inviteCode = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await t.db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(inviteCode))}, 'e2e', 1)`;
  }
  const ch = await api(t, null, "POST", "/auth/challenge", { address: kp.publicKey() });
  const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
  return (await api(t, null, "POST", "/auth/verify", { address: kp.publicKey(), nonce: ch.nonce, signature, ...(inviteCode ? { inviteCode } : {}) })).token;
}

/** The phone's loop as `kp`: build, verify against the pinned allowlist, sign, submit, wait. */
async function runAs(t: E2E, kp: Keypair, token: string, plan: any): Promise<any[]> {
  const outs: any[] = [];
  for (let i = 0; i < plan.steps.length; i++) {
    let step = plan.steps[i];
    if (!step.xdr) step = (await api(t, token, "POST", `/plans/${plan.planId}/steps/${step.id}/build`)).steps[i];
    const tx = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
    const allowed = new Set<string>(Object.values(t.config.allowlist as Record<string, string[]>).flat());
    verifyTransaction(tx, step.intent, { user: kp.publicKey(), sponsor: t.config.sponsor, passphrase: t.config.passphrase, allowedContracts: allowed });
    tx.sign(kp);
    const sent = await api(t, token, "POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
    let status = sent;
    for (let k = 0; k < 40 && status.status === "pending"; k++) {
      await new Promise((r) => setTimeout(r, 1_500));
      status = await api(t, token, "GET", `/tx/${sent.hash}`);
    }
    if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
    outs.push(status);
    console.log(`    ✓ ${step.label} ${sent.hash.slice(0, 12)}…`);
  }
  return outs;
}

/** A new account set up: signed in, activated (Friendbot on testnet), USDC enabled if asked. */
async function account(t: E2E, kp: Keypair): Promise<string> {
  const token = await signIn(t, kp);
  const act = await api(t, token, "POST", "/account/activate");
  if (act.planId) await runAs(t, kp, token, act);
  return token;
}

/** The launchpad's events, then the watched tokens' and pairs' until every group has caught up. */
async function indexed(t: E2E): Promise<void> {
  await t.indexer();
  const { watchContracts } = await import("../../../supabase/functions/lite-indexer/jobs/watch.ts");
  for (let i = 0; i < 20; i++) {
    const r = await watchContracts() as { latest?: number; skipped?: string };
    if (r.skipped) throw new Error(`watch: ${r.skipped}`);
    const [{ behind }] = await t.db`select count(*)::int as behind from lite.watch_groups where ledger < ${r.latest! - 12}`;
    if (behind === 0) return;
  }
  throw new Error("the watched contracts didn't catch up");
}

/** A buy (or sell) of `launch`, quoted in `quote`, at the client's 1% minimum from a fresh quote. */
async function trade(t: E2E, kp: Keypair, token: string, launch: string, quote: string, side: "buy" | "sell", amount: bigint): Promise<any> {
  const q = await api(t, token, "POST", `/launches/${launch}/quote`, { side, amount: amount.toString() });
  const minOut = (BigInt(side === "buy" ? q.tokensOut : q.quoteOut) * 99n / 100n).toString();
  const plan = await api(t, token, "POST", "/launches/build", { action: side, token: launch, amount: amount.toString(), minOut });
  if (JSON.stringify(plan.steps[0].intent.receive) !== JSON.stringify({ [side === "buy" ? launch : quote]: minOut })) {
    throw new Error(`the ${side}'s minimum isn't bound: ${JSON.stringify(plan.steps[0].intent)}`);
  }
  await runAs(t, kp, token, plan);
  return q;
}

export default async function launch(t: E2E): Promise<string> {
  t.config ??= await api(t, null, "GET", "/config");
  if (!t.token) t.token = await account(t, t.user);
  const me = t.user.publicKey();
  const { ONE } = t;
  const xlm = t.config.assets.find((a: any) => a.id === "XLM").contract;
  const { refprices } = await import("../../../supabase/functions/lite-indexer/jobs/refprices.ts");
  await refprices();

  // The terms, with no session.
  const econ = await call(t, null, "GET", "/economics");
  if (econ.status !== 200 || econ.cache !== "public, max-age=30") throw new Error(`/economics → ${econ.status} ${econ.cache}`);
  if (JSON.stringify(econ.body).includes("admin")) throw new Error("the economics name an admin");
  const lp = econ.body.launchpad;
  const terms = lp?.quotes.find((q: any) => q.asset === "XLM" && q.enabled);
  if (!lp?.launchesEnabled || !terms) throw new Error(`no XLM launches: ${JSON.stringify(econ.body)}`);

  // The coin's metadata: an uploaded image, a description, links.
  const media = Deno.env.get("E2E_NO_MEDIA") !== "1";
  let uri = "";
  let image: string | null = null;
  if (media) {
    const ticket = await api(t, t.token, "POST", "/media/upload-url", { contentType: "image/png", bytes: PNG.length });
    const put = await fetch(ticket.uploadUrl, { method: "PUT", headers: { "content-type": "image/png" }, body: PNG });
    await put.body?.cancel();
    if (!put.ok) throw new Error(`the image's upload → ${put.status}`);
    image = ticket.publicUrl;
    uri = (await api(t, t.token, "POST", "/launches/metadata", { name: NAME, symbol: SYMBOL, description: DESCRIPTION, imageUrl: image, website: WEBSITE, x: X })).uri;
  }

  // Launch, with a 100 XLM developer buy at 1% under the opening curve's price (the creator pays no early-buy tax).
  const devBuy = 100n * ONE;
  const net = devBuy - (devBuy * BigInt(lp.feeBps)) / 10_000n - (devBuy * BigInt(CREATOR_FEE_BPS)) / 10_000n;
  const opening = (net * BigInt(lp.supply)) / (BigInt(terms.phantom) + net);
  const create = await api(t, t.token, "POST", "/launches/build", {
    action: "create",
    quote: "XLM",
    name: NAME,
    symbol: SYMBOL,
    uri,
    creatorFeeBps: CREATOR_FEE_BPS,
    amount: devBuy.toString(),
    minOut: (opening * 99n / 100n).toString(),
  });
  const [made] = await t.runPlan(create);
  const coin = String(made.returnValue);
  await indexed(t);

  // On the board, with no session: its metadata, one holder.
  const board = await call(t, null, "GET", `/launches?section=explore&sort=newest&q=${coin}`);
  const row = board.body?.launches?.find((l: any) => l.token === coin);
  if (board.status !== 200 || board.cache !== "public, max-age=15" || board.body.view !== "public" || !row) throw new Error(`the public board: ${board.status} ${board.cache} ${JSON.stringify(board.body).slice(0, 300)}`);
  if (media && (row.image !== image || row.description !== DESCRIPTION || row.links.website !== WEBSITE || row.links.x !== X || row.uri !== uri)) {
    throw new Error(`the board's metadata: ${JSON.stringify({ image: row.image, description: row.description, links: row.links, uri: row.uri })}`);
  }
  if (row.holders !== 1 || row.holdersComplete !== true || row.lookAlike !== false) throw new Error(`after the launch: ${row.holders} holders (complete ${row.holdersComplete})`);

  // A second account buys: two holders.
  const friend = Keypair.random();
  const friendToken = await account(t, friend);
  await trade(t, friend, friendToken, coin, xlm, "buy", 50n * ONE);
  // Sell a tenth of the developer buy back, then buy the curve full (the last buy is clamped at the threshold).
  await trade(t, t.user, t.token, coin, xlm, "sell", opening / 10n);
  const fill = await trade(t, t.user, t.token, coin, xlm, "buy", 5_000n * ONE);
  await indexed(t);
  let page = await api(t, t.token, "GET", `/launches/${coin}`);
  if (!page.curve?.completed || page.launch.holders !== 2) throw new Error(`after the fill: completed ${page.curve?.completed}, ${page.launch.holders} holders`);

  // Graduate by hand: any user may, and pays only the network fee. The keeper may have been first.
  if (!page.curve.graduated) {
    const grad = await call(t, t.token, "POST", "/launches/build", { action: "graduate", token: coin });
    if (grad.status === 200) await t.runPlan(grad.body);
    else if (grad.body?.error?.detail?.contractCode !== "launch.closed") throw new Error(`graduate → ${grad.status} ${JSON.stringify(grad.body)}`);
  }
  await indexed(t);
  page = await api(t, t.token, "GET", `/launches/${coin}`);
  if (page.launch.phase !== "graduated" || !page.launch.pair || page.launch.poolFeeBps !== 30 || BigInt(page.launch.burned) <= 0n) {
    throw new Error(`after graduation: ${JSON.stringify({ phase: page.launch.phase, pair: page.launch.pair, poolFeeBps: page.launch.poolFeeBps, burned: page.launch.burned })}`);
  }

  // A Soroswap buy: a pool trade, priced by its transaction's sync.
  let quote: any = null;
  for (let i = 0; i < 6 && !quote; i++) {
    const q = await call(t, t.token, "POST", "/swap/quote", { sell: "XLM", buy: coin, amount: (5n * ONE).toString(), slippageBps: 300 });
    if (q.status === 200) quote = q.body;
    else await new Promise((r) => setTimeout(r, 10_000));
  }
  if (!quote) throw new Error("no route to buy the graduated coin");
  await t.runPlan(await api(t, t.token, "POST", "/swap/build", { quoteId: quote.quoteId }));
  await indexed(t);
  const swaps = await t.db`select trader, side, price from lite.pool_swaps where token = ${coin}`;
  if (!swaps.some((s) => s.trader === me && s.side === "buy" && s.price !== null)) throw new Error(`pool swaps: ${JSON.stringify(swaps)}`);

  // The creator's fees, claimed and recorded.
  await t.runPlan(await api(t, t.token, "POST", "/launches/build", { action: "claim", token: coin }));
  await indexed(t);
  const [claim] = await t.db`select amount from lite.creator_claims where token = ${coin} and creator = ${me}`;
  page = await api(t, t.token, "GET", `/launches/${coin}`);
  if (!claim || page.creatorFees?.claimed !== String(claim.amount) || BigInt(page.creatorFees.claimed) <= 0n) throw new Error(`the claim: ${JSON.stringify({ claim, fees: page.creatorFees })}`);
  if (page.launch.marketCapUsd === null || page.stats.marketCapUsd === null) throw new Error("no market cap in USD (no XLM reference price?)");
  if (!page.trades.some((tr: any) => tr.venue === "soroswap") || !page.trades.some((tr: any) => tr.venue === "curve")) throw new Error("the page's trades miss a venue");
  if (page.view !== "owner" || page.you?.isCreator !== true || page.you.costBasisQuote === null) throw new Error(`you: ${JSON.stringify(page.you)}`);

  // The public view of the page: on-chain facts only.
  const anyone = await call(t, null, "GET", `/launches/${coin}?address=${me}`);
  if (anyone.status !== 200 || anyone.body.view !== "public" || anyone.body.you?.costBasisQuote !== null || anyone.body.you?.pnlQuote !== null || anyone.body.you?.balance === "0") {
    throw new Error(`the public page: ${anyone.status} ${JSON.stringify(anyone.body.you)}`);
  }

  // My Launchpad: with a session only.
  if ((await call(t, null, "GET", "/launchpad/me")).status !== 401) throw new Error("My Launchpad answered without a session");
  const mine = await api(t, t.token, "GET", "/launchpad/me");
  if (!mine.created.some((c: any) => c.launch.token === coin) || !mine.held.some((h: any) => h.token === coin)) throw new Error(`My Launchpad: ${JSON.stringify(mine).slice(0, 400)}`);
  if (!mine.activity.some((a: any) => a.kind === "launch_create")) throw new Error("My Launchpad's activity has no launch");

  // Reconcile: every holder's indexed balance is its live one.
  const { reconcileBalances, balanceAt } = await import("../../../supabase/functions/lite-indexer/jobs/reconcile.ts");
  const holders = await t.db`select address, balance from lite.token_balances where token = ${coin}`;
  let mismatched = 0;
  for (let i = 0; i < 5; i++) mismatched += (await reconcileBalances()).mismatched;
  for (const h of await t.db`select address, balance from lite.token_balances where token = ${coin}`) {
    const live = await balanceAt(coin, String(h.address));
    if (!live || live.balance !== BigInt(h.balance)) throw new Error(`${h.address}: indexed ${h.balance}, live ${live?.balance}`);
  }

  const xlmPaid = (BigInt(fill.used) / ONE).toString();
  return `${SYMBOL} ${coin.slice(0, 8)}… ${media ? "with its image, description and links" : "without metadata (E2E_NO_MEDIA)"}; holders 1 → ${page.launch.holders}; ` +
    `filled for ${xlmPaid} XLM, graduated by hand to ${page.launch.pair.slice(0, 8)}… (pool fee ${page.launch.poolFeeBps} bps); ` +
    `a Soroswap buy via ${quote.best?.venue ?? "the best route"} priced ${swaps.find((s) => s.trader === me)?.price}; claimed ${claim.amount} stroops; ` +
    `market cap $${page.launch.marketCapUsd}; My Launchpad lists it; ${holders.length} balances reconciled (${mismatched} corrected)`;
}
