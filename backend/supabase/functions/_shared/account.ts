// Accounts (docs/DESIGN-stellar-parity.md §1.1 decision 7, §4.3, §4.5, §6.4): setup (Friendbot on testnet, DyorHQ's
// sponsored account where activation is sponsored), trustlines the user pays for, testnet's one claim of Friendbot's
// test XLM, sends, recipients, and the account view: every balance, the account's XLM position and the add-funds card,
// for its owner or, from the ledger and the indexer only, for anyone (the public view).
import { Memo, Operation } from "@stellar/stellar-sdk";
import type postgres from "postgres";
import type { AccountView, ActivationResult, BalanceRow, FirstFunding, Recipient, View } from "./contract.ts";
import { classicAssetInfo, registryAsset, resolveAsset, ResolvedAsset } from "./assets.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { baseReserve, firstFunding, positionOf } from "./fees.ts";
import { ApiError, bad } from "./http.ts";
import { AssetInfo, assetById } from "./networks.ts";
import { createPlan, registerBuilder } from "./plans.ts";
import { assertSponsorAvailable, starterUsed } from "./sponsor.ts";
import {
  classicAsset,
  ClassicAccount,
  classicBalances,
  fromStroops,
  invoke,
  isAccountId,
  isContractId,
  isMuxedId,
  Keypair,
  loadAccount,
  newTx,
  requireAccount,
  rpcServer,
  sendSigned,
  SendUnconfirmed,
  sponsor,
  sv,
  TransactionBuilder,
  view,
  waitForTx,
} from "./stellar.ts";
import { instanceKey } from "./ttl.ts";
import { Intent } from "./verify.ts";

/** A trustline the user pays for (§4.1): a plain changeTrust, whose base reserve (0.5 XLM) the user's account holds. */
registerBuilder("trust", async (user, spec) => {
  const asset = String(spec.asset);
  const acct = await requireAccount(user);
  const tx = newTx(acct).addOperation(Operation.changeTrust({ asset: classicAsset(asset) })).build();
  const code = asset.split(":")[0];
  const intent: Intent = { kind: "trust", summary: `Enable ${code}`, spend: {}, ops: ["changeTrust"], trust: [asset], display: { asset: code } };
  return { tx, intent };
});

/** A sponsored account's setup: the sponsor creates it with 0 XLM and pays its reserves and USDC's (§4.3). The
 *  sponsor is the source and pays the fee; sponsor and user both sign. */
registerBuilder("activate", async (user, spec) => {
  const sp = sponsor().publicKey();
  const sponsorAcct = await requireAccount(sp);
  const usdc = String(spec.usdc);
  const tx = newTx(sponsorAcct)
    .addOperation(Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sp }))
    .addOperation(Operation.createAccount({ destination: user, startingBalance: "0", source: sp }))
    .addOperation(Operation.changeTrust({ asset: classicAsset(usdc), source: user }))
    .addOperation(Operation.endSponsoringFutureReserves({ source: user }))
    .build();
  const intent: Intent = {
    kind: "activate",
    summary: "Create your Stellar account",
    spend: {},
    ops: ["beginSponsoringFutureReserves", "createAccount", "changeTrust", "endSponsoringFutureReserves"],
    trust: [usdc],
  };
  return { tx, intent, cosignSponsor: true };
});

const MEMO_TYPES = ["text", "id", "hash"] as const;

/** A send's memo, from what the user typed: the transaction's and the intent's (a hash memo as lowercase hex; some
 *  exchanges give it in base64). Null without one. */
export function memoOf(spec: Record<string, unknown>): { memo: Memo; bound: NonNullable<Intent["memo"]> } | null {
  if (spec.memo === null || spec.memo === undefined || spec.memo === "") return null;
  const value = String(spec.memo);
  const type = (spec.memoType ?? "text") as string;
  if (!(MEMO_TYPES as readonly string[]).includes(type)) throw bad("bad_memo", "memoType is text, id or hash.");
  switch (type) {
    case "id":
      if (!/^[0-9]{1,20}$/.test(value) || BigInt(value) > 2n ** 64n - 1n) throw bad("bad_memo", "That memo ID isn't a number.");
      return { memo: Memo.id(BigInt(value).toString()), bound: { type: "id", value: BigInt(value).toString() } };
    case "hash": {
      const hex = /^[0-9a-f]{64}$/i.test(value) ? value.toLowerCase() : Buffer.from(value, "base64").toString("hex");
      if (!/^[0-9a-f]{64}$/.test(hex)) throw bad("bad_memo", "A hash memo is 32 bytes, in hex or base64.");
      return { memo: Memo.hash(hex), bound: { type: "hash", value: hex } };
    }
    default:
      if (new TextEncoder().encode(value).length > 28) throw bad("bad_memo", "A text memo is at most 28 bytes.");
      return { memo: Memo.text(value), bound: { type: "text", value } };
  }
}

function recipientError(code: "recipient_missing" | "recipient_no_trust", asset: AssetInfo): ApiError {
  const message = code === "recipient_missing"
    ? `This account doesn't exist yet, so it can't receive ${asset.code}.`
    : `This account hasn't enabled ${asset.code}, so it can't receive it.`;
  return new ApiError(409, code, message, { asset: asset.id, assetCode: asset.code });
}

export function muxedUnsupported(): ApiError {
  return new ApiError(400, "muxed_unsupported", "Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given.");
}

/** A send (§5.2, §6.8): the destination and memo the user confirmed are bound in the intent. XLM or a classic asset
 *  to a G… is a classic payment, or creates the account (XLM only, at least 1 XLM); anything else goes through the
 *  token's transfer. Refused before signing: a non-XLM send to a missing account (409 recipient_missing) or to one
 *  without the asset's trustline (409 recipient_no_trust). */
registerBuilder("payment", async (user, spec) => {
  const asset = await resolveAsset(String(spec.asset));
  const to = String(spec.to);
  const amount = BigInt(String(spec.amount));
  const memo = memoOf(spec);
  const acct = await requireAccount(user);
  const display = { asset: asset.code, amount: fromStroops(amount, asset.decimals), to, memo: memo ? String(spec.memo) : null };
  const summary = `Send ${display.amount} ${asset.code}`;
  const spend = { [asset.contract]: amount.toString() };
  if (asset.classic && isAccountId(to)) {
    const dest = await classicBalances(to);
    let tb = newTx(acct);
    if (memo) tb = tb.addMemo(memo.memo);
    if (!dest) {
      if (asset.classic !== "native") throw recipientError("recipient_missing", asset);
      if (amount < 10_000_000n) throw bad("too_small", "A new account needs at least 1 XLM.");
      tb = tb.addOperation(Operation.createAccount({ destination: to, startingBalance: fromStroops(amount) }));
    } else {
      if (asset.classic !== "native" && !dest.balances.some((b) => b.asset === asset.classic)) throw recipientError("recipient_no_trust", asset);
      tb = tb.addOperation(Operation.payment({ destination: to, asset: classicAsset(asset.classic), amount: fromStroops(amount) }));
    }
    const intent: Intent = { kind: "payment", summary, spend, ops: [dest ? "payment" : "createAccount"], display, to, ...(memo ? { memo: memo.bound } : {}) };
    return { tx: tb.build(), intent, stepKind: "payment" };
  }
  if (memo) throw bad("bad_memo", "A memo goes only with a payment of XLM or a classic asset to a G… address.");
  const tx = await invoke(acct, asset.contract, "transfer", [sv.addr(user), sv.addr(to), sv.i128(amount)]);
  const intent: Intent = { kind: "payment", summary, spend, calls: [{ contract: asset.contract, fn: "transfer" }], display, to };
  return { tx, intent, stepKind: "payment_token" };
});

/** POST /v1/send: checks what can be checked without the network, then plans the send. */
export async function sendPlan(user: string, input: { asset: string; to: string; amount: bigint; memo?: string | null; memoType?: string | null }) {
  if (isMuxedId(input.to)) throw muxedUnsupported();
  if (!isAccountId(input.to) && !isContractId(input.to)) throw bad("bad_address", "That isn't a Stellar address.");
  const spec = { kind: "payment", asset: input.asset, to: input.to, amount: input.amount.toString(), memo: input.memo ?? null, memoType: input.memoType ?? null };
  memoOf(spec);
  const asset = await resolveAsset(input.asset);
  return await createPlan(user, "payment", [{ label: "Send", spec: { ...spec, asset: asset.id } }]);
}

/** GET /v1/recipient/:address (§6.4): whether an address exists and, for a classic asset, can receive it. */
export async function recipient(address: string, assetId: string | null): Promise<Recipient> {
  if (isMuxedId(address)) throw muxedUnsupported();
  if (!isAccountId(address) && !isContractId(address)) throw bad("bad_address", "That isn't a Stellar address.");
  const asset = assetId ? await resolveAsset(assetId) : null;
  if (isContractId(address)) {
    const r = await rpcServer().getLedgerEntries(instanceKey(address));
    return { kind: "contract", exists: r.entries.length > 0, trusts: null };
  }
  const acct = await classicBalances(address);
  const classic = asset?.classic && asset.classic !== "native" ? asset.classic : null;
  return { kind: "account", exists: Boolean(acct), trusts: classic ? Boolean(acct?.balances.some((b) => b.asset === classic)) : null };
}

// ------------------------------------------------------------------------------------------------ activation

/** The transaction Friendbot funded an account with, as Horizon records it. */
export interface FriendbotTx {
  hash: string;
  ledger: number | null;
  /** Stroops, as Horizon writes them; null when it doesn't say. */
  maxFee: string | null;
  feeCharged: string | null;
}

/** A Horizon transaction record as a FriendbotTx; null when it isn't one. */
function friendbotTx(record: unknown): FriendbotTx | null {
  const r = (record ?? {}) as Record<string, unknown>;
  if (typeof r.hash !== "string" || !/^[0-9a-f]{64}$/.test(r.hash)) return null;
  const stroops = (v: unknown) => (typeof v === "string" && /^[0-9]{1,19}$/.test(v) ? v : null);
  return { hash: r.hash, ledger: typeof r.ledger === "number" ? r.ledger : null, maxFee: stroops(r.max_fee), feeCharged: stroops(r.fee_charged) };
}

/** A Horizon resource (`path` under the network's Horizon), or null when Horizon doesn't have it or doesn't answer. */
async function horizonRecord(path: string): Promise<unknown> {
  try {
    const res = await fetch(`${env.network.horizonUrl}${path}`);
    if (!res.ok) {
      await res.body?.cancel();
      return null;
    }
    return await res.json();
  } catch {
    return null;
  }
}

/** How many times Horizon is asked for Friendbot's transaction, a second apart: it lists a ledger's transactions a
 *  few seconds after RPC shows the account they created. */
const HORIZON_TRIES = 6;

/** Asks testnet's Friendbot to fund `address` with its grant (networks.ts faucet.amount) and waits until the account
 *  is on the ledger: Friendbot's transaction, or null only when Friendbot found the account already funded, so funded
 *  it no further. A funding is never answered without its transaction (fundingTx). */
export async function friendbotFund(address: string): Promise<FriendbotTx | null> {
  const url = env.network.friendbotUrl;
  if (!url) throw new ApiError(400, "no_friendbot", "Friendbot only exists on testnet.");
  const res = await fetch(`${url}?addr=${encodeURIComponent(address)}`);
  const body = await res.text();
  if (!res.ok && !/already funded|createAccountAlreadyExist/.test(body)) {
    throw new ApiError(502, "friendbot_failed", "Testnet Friendbot didn't answer. Try again.", { status: res.status });
  }
  for (let i = 0; i < 20; i++) {
    if (await loadAccount(address)) return res.ok ? await fundingTx(address, body) : null;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw friendbotSlow();
}

function friendbotSlow(): ApiError {
  return new ApiError(504, "friendbot_slow", "Testnet is slow to create the account. Try again in a minute.");
}

/** The transaction Friendbot funded `address` with, from its answer (`body`): Friendbot answers with Horizon's record
 *  of it; when that lacks the fees, Horizon's record of the hash gives them, and when it names no transaction, the
 *  account's first one on Horizon is Friendbot's. Horizon is asked again while it doesn't list it yet. A funding that
 *  nothing names is refused (504 friendbot_slow), so a caller never takes it for no funding at all. */
async function fundingTx(address: string, body: string): Promise<FriendbotTx> {
  let answer: unknown = null;
  try {
    answer = JSON.parse(body);
  } catch {
    // Not a record: the account's first transaction says which it was.
  }
  const answered = friendbotTx(answer);
  if (answered?.maxFee) return answered;
  for (let k = 0; k < HORIZON_TRIES; k++) {
    if (k > 0) await new Promise((r) => setTimeout(r, 1_000));
    const record = answered
      ? await horizonRecord(`/transactions/${answered.hash}`)
      : ((await horizonRecord(`/accounts/${address}/transactions?order=asc&limit=1`)) as { _embedded?: { records?: unknown[] } } | null)?._embedded?.records?.[0];
    const found = friendbotTx(record);
    if (found) return found;
  }
  if (answered) return answered;
  throw friendbotSlow();
}

export function usdcAsset(): AssetInfo {
  return assetById(env.network, "USDC")!;
}

/** POST /v1/account/activate (§4.3): a missing account is funded by Friendbot (testnet), which is the address's one
 *  claim of test XLM (decision 7), or gets DyorHQ's sponsored setup plan, offered only while DyorHQ could send it;
 *  then USDC, if not enabled yet, is a trust plan the user pays for (409 not_enough_xlm_for_reserve when the account
 *  can't hold it). A missing account is always created, claimed or not: Stellar can't be used without one, and a
 *  testnet reset removes every account. */
export async function activate(user: string, ip: string): Promise<ActivationResult> {
  const net = env.network;
  const usdc = usdcAsset();
  let acct = await classicBalances(user);
  if (!acct) {
    if (net.activation === "sponsored") {
      await assertSponsorAvailable(user, "activate", ip, net.feePolicy.activationMaxFee);
      return await createPlan(user, "activate", [{ label: "Create your account", spec: { kind: "activate", usdc: usdc.classic } }]);
    }
    // Friendbot's grant is the address's one claim: funded and logged under the faucet's per-address lock, so a faucet
    // tap racing this activation finds the claim once it gets the lock, and never claims a second grant.
    await sql().begin(async (q) => {
      await q`select pg_advisory_xact_lock(hashtextextended(${`lite.faucet:${user}`}, 0))`;
      const funded = await friendbotFund(user);
      if (funded) await logFaucet(q, user, funded.hash, { status: "success", ledger: funded.ledger, maxFee: funded.maxFee ?? "0", feeCharged: funded.feeCharged });
    });
    acct = await classicBalances(user);
  }
  if (acct && !acct.balances.some((b) => b.asset === usdc.classic)) {
    return await createPlan(user, "trust", [{ label: "Enable USDC", spec: { kind: "trust", asset: usdc.classic } }]);
  }
  return { status: "active", account: await accountView(user) };
}

/** POST /v1/account/trust: a classic asset (the registry's, or any CODE:ISSUER) to enable, at the user's cost. */
export async function trustPlan(user: string, assetId: string) {
  const asset = await resolveAsset(assetId);
  if (!asset.classic || asset.classic === "native") throw bad("bad_asset", "That asset doesn't need enabling.");
  return await createPlan(user, "trust", [{ label: `Enable ${asset.code}`, spec: { kind: "trust", asset: asset.classic } }]);
}

// ------------------------------------------------------------------------------------------------ Friendbot's one claim

/** Whether `user` has claimed Friendbot's test XLM (decision 7): a faucet row in lite.tx_log, at any time, that didn't
 *  fail. Friendbot's activation of the account is logged as one (activate), so it counts. */
async function faucetClaimed(user: string, q: postgres.Sql | postgres.TransactionSql = sql()): Promise<boolean> {
  const rows = await q`select 1 from lite.tx_log where address = ${user} and kind = 'faucet' and status <> 'failed' limit 1`;
  return rows.length > 0;
}

function faucetUsed(): ApiError {
  return new ApiError(429, "faucet_used", "You already claimed your test XLM.");
}

interface FaucetRow {
  status: "pending" | "success";
  ledger: number | null;
  maxFee: string;
  feeCharged: string | null;
}

/** Logs Friendbot's grant to `user` (transaction `hash`) as the address's faucet row: paid by Friendbot's accounts
 *  (`external`), in the account section, with an intent that says what it was ("Funded with Friendbot"). */
async function logFaucet(q: postgres.Sql | postgres.TransactionSql, user: string, hash: string, row: FaucetRow): Promise<void> {
  const intent = { kind: "faucet", summary: "Funded with Friendbot", spend: {}, display: { amount: env.network.faucet?.amount ?? null } };
  await q`
    insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, ledger, max_fee, fee_charged, fee_payer, section)
    values (${hash}, ${hash}, ${user}, 'faucet', ${q.json(intent)}, ${row.status}, ${row.ledger}, ${row.maxFee}, ${row.feeCharged}, 'external', 'account')
    on conflict do nothing`;
}

/** POST /v1/account/faucet. Testnet: Friendbot's grant of test XLM (networks.ts faucet.amount) for an account that
 *  already existed, once per address, ever (decision 7): 429 faucet_used once the address has claimed, here or by
 *  Friendbot's activation. Friendbot funds a temporary account, which merges into the user's; that account pays the
 *  fee (`external` in the log). Everything up to the claim's row runs under a lock per address (the one activation
 *  takes too): the claim is checked, Friendbot funds the temporary account and the claim is logged before the merge is
 *  sent, so two taps at once ask Friendbot once and claim once; a merge that fails releases the claim. */
export async function testnetFaucet(user: string): Promise<{ hash: string }> {
  if (!env.network.faucet) throw new ApiError(400, "testnet_only", "The faucet is testnet-only.");
  if (await faucetClaimed(user)) throw faucetUsed();
  await requireAccount(user);
  const temp = Keypair.random();
  const claim = await sql().begin(async (q) => {
    await q`select pg_advisory_xact_lock(hashtextextended(${`lite.faucet:${user}`}, 0))`;
    if (await faucetClaimed(user, q)) return null;
    await friendbotFund(temp.publicKey());
    const tempAcct = (await loadAccount(temp.publicKey()))!;
    const tx = new TransactionBuilder(tempAcct, { fee: "1000", networkPassphrase: env.network.passphrase })
      .addOperation(Operation.accountMerge({ destination: user }))
      .setTimeout(60)
      .build();
    tx.sign(temp);
    const hash = tx.hash().toString("hex");
    await logFaucet(q, user, hash, { status: "pending", ledger: null, maxFee: "1000", feeCharged: null });
    return { tx, hash };
  });
  if (!claim) throw faucetUsed();
  const { tx, hash } = claim;
  try {
    await sendSigned(tx, "external");
  } catch (err) {
    // Refused, so nothing was sent: the claim is still to make. An unconfirmed send may yet land, and keeps it.
    if (!(err instanceof SendUnconfirmed)) await sql()`update lite.tx_log set status = 'failed', updated_at = now() where hash = ${hash}`;
    throw err;
  }
  const s = await waitForTx(hash, 30_000);
  await sql()`update lite.tx_log set status = ${s.status === "SUCCESS" ? "success" : s.status === "FAILED" ? "failed" : "pending"}, ledger = ${s.ledger ?? null},
               fee_charged = ${s.feeCharged ?? null}, updated_at = now() where hash = ${hash}`;
  return { hash };
}

// ------------------------------------------------------------------------------------------------ the account view

function balanceRow(a: ResolvedAsset, balance: string, enabled: boolean): BalanceRow {
  return {
    asset: a.id,
    code: a.code,
    name: a.name,
    contract: a.contract,
    classic: a.classic,
    decimals: a.decimals,
    balance,
    enabled,
    ...(a.note ? { note: a.note } : {}),
    kind: a.kind,
    verified: a.verified,
    logo: a.logo,
  };
}

/** Every registry asset, held or not, then every other trustline the account has (liquidity-pool shares aside). */
function classicRows(acct: ClassicAccount | null): BalanceRow[] {
  const registry = env.network.assets;
  const rows = registry.map((a) => {
    const line = acct?.balances.find((b) => b.asset === a.classic);
    return balanceRow(registryAsset(a), line?.balance ?? "0", a.classic === "native" ? Boolean(acct) : Boolean(line));
  });
  for (const b of acct?.balances ?? []) {
    if (b.asset === "native" || registry.some((a) => a.classic === b.asset)) continue;
    rows.push(balanceRow(classicAssetInfo(b.asset), b.balance, true));
  }
  return rows;
}

/** Launch tokens the account holds: those it traded on a curve (lite.launch_trades). The owner's balances are read
 *  live with balance() (the indexed one when that read fails); the public view's are the indexed ones (net of its
 *  trades), with no RPC call (§6.4). */
async function launchRows(address: string, live: boolean): Promise<BalanceRow[]> {
  const tokens = await sql()`
    select l.token, l.symbol, l.name, sum(case when t.side = 'buy' then t.token_amount else -t.token_amount end) as net
      from lite.launch_trades t join lite.launches l on l.token = t.token
     where t.trader = ${address}
     group by l.token, l.symbol, l.name order by l.token limit 50`;
  const indexed = tokens.map((t) => BigInt(String(t.net ?? "0").split(".")[0]));
  const balances = live
    ? await Promise.all(tokens.map((t, i) => view(String(t.token), "balance", [sv.addr(address)]).then((b) => BigInt(b ?? 0n)).catch(() => indexed[i])))
    : indexed;
  const rows: BalanceRow[] = [];
  tokens.forEach((t, i) => {
    const balance = balances[i];
    if (balance <= 0n) return;
    const token = String(t.token);
    const asset: ResolvedAsset = { id: token, code: String(t.symbol), name: String(t.name), decimals: 7, contract: token, classic: null, kind: "launch", verified: true, logo: null };
    rows.push(balanceRow(asset, balance.toString(), true));
  });
  return rows;
}

/** Reserves DyorHQ's sponsor pays for the account: its own two, and each trustline and signer it sponsors. */
function sponsoredByDyorHQ(acct: ClassicAccount): number {
  const sp = sponsor().publicKey();
  return (acct.accountSponsor === sp ? 2 : 0) + acct.balances.filter((b) => b.sponsor === sp).length + acct.signerSponsors.filter((s) => s === sp).length;
}

/** The starter swap's state on the add-funds card (§4.5): only where activation is sponsored; `used` once it is
 *  reserved, sent or done; `available` while the account has too little XLM to spend. */
async function starterSwapState(address: string, spendable: bigint | null): Promise<FirstFunding["starterSwap"]> {
  if (env.network.activation !== "sponsored" || spendable === null) return "unavailable";
  if (await starterUsed(address)) return "used";
  return spendable < env.network.feePolicy.starterThreshold ? "available" : "unavailable";
}

/** GET /v1/account (§6.4): the owner's view, or the public view of any account (`scope` "public"): the same shape
 *  from the ledger and the indexer only, with DyorHQ's own records (the starter swap, the faucet's claim) null. */
export async function accountView(address: string, scope: View = "owner"): Promise<AccountView> {
  const net = env.network;
  const owner = scope === "owner";
  const [acct, reserve] = await Promise.all([classicBalances(address), baseReserve()]);
  const balances = classicRows(acct);
  if (acct) balances.push(...(await launchRows(address, owner)));
  const xlm = positionOf(acct, reserve);
  const starter = owner ? await starterSwapState(address, xlm ? BigInt(xlm.spendable) : null) : null;
  const faucet = net.faucet ? { amount: net.faucet.amount, claimed: owner ? await faucetClaimed(address) : null } : null;
  return {
    address,
    exists: Boolean(acct),
    network: net.name,
    activation: net.activation,
    balances,
    reserves: acct ? { subentries: acct.subentries, sponsoredByDyorHQ: sponsoredByDyorHQ(acct) } : null,
    sponsor: sponsor().publicKey(),
    xlm,
    firstFunding: firstFunding(xlm, net.feePolicy, starter, faucet),
    view: scope,
  };
}

const PUBLIC_TTL_MS = 15_000;
const publicViews = new Map<string, { at: number; view: AccountView }>();

/** The public view of `address`, kept 15 s per address (§6.4): it answers every account alike, member or not. */
export async function publicAccountView(address: string): Promise<AccountView> {
  const now = Date.now();
  const hit = publicViews.get(address);
  if (hit && now - hit.at < PUBLIC_TTL_MS) return hit.view;
  const v = await accountView(address, "public");
  if (publicViews.size >= 1_000) publicViews.clear();
  publicViews.set(address, { at: now, view: v });
  return v;
}

export function needsTrustline(balances: { asset: string; enabled: boolean; classic: string | null }[], assetId: string): string | null {
  const a = assetById(env.network, assetId);
  if (!a || !a.classic || a.classic === "native") return null;
  const row = balances.find((b) => b.asset === a.id);
  return row?.enabled ? null : a.classic;
}

