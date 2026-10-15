// Accounts (docs/DESIGN-stellar-parity.md §4.3, §4.5, §6.4): setup (Friendbot on testnet, DyorHQ's sponsored account
// where activation is sponsored), trustlines the user pays for, the testnet faucet, sends, recipients, and the account
// view: every balance, the account's XLM position and the add-funds card, for its owner or, from the ledger and the
// indexer only, for anyone (the public view).
import { Memo, Operation } from "@stellar/stellar-sdk";
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

/** A send's memo, from what the user typed: the transaction's and the intent's (a hash memo as lowercase hex; SEP-24
 *  anchors give it in base64). Null without one. */
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

export async function friendbotFund(address: string): Promise<void> {
  const url = env.network.friendbotUrl;
  if (!url) throw new ApiError(400, "no_friendbot", "Friendbot only exists on testnet.");
  const res = await fetch(`${url}?addr=${encodeURIComponent(address)}`);
  if (!res.ok) {
    const body = await res.text();
    if (!/already funded|createAccountAlreadyExist/.test(body)) throw new ApiError(502, "friendbot_failed", "Testnet Friendbot didn't answer. Try again.", { status: res.status });
  }
  for (let i = 0; i < 20; i++) {
    if (await loadAccount(address)) return;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw new ApiError(504, "friendbot_slow", "Testnet is slow to create the account. Try again in a minute.");
}

export function usdcAsset(): AssetInfo {
  return assetById(env.network, "USDC")!;
}

/** POST /v1/account/activate (§4.3): a missing account is funded by Friendbot (testnet) or gets DyorHQ's sponsored
 *  setup plan, offered only while DyorHQ could send it; then USDC, if not enabled yet, is a trust plan the user pays
 *  for (409 not_enough_xlm_for_reserve when the account can't hold it). */
export async function activate(user: string, ip: string): Promise<ActivationResult> {
  const net = env.network;
  const usdc = usdcAsset();
  let acct = await classicBalances(user);
  if (!acct) {
    if (net.activation === "sponsored") {
      await assertSponsorAvailable(user, "activate", ip, net.feePolicy.activationMaxFee);
      return await createPlan(user, "activate", [{ label: "Create your account", spec: { kind: "activate", usdc: usdc.classic } }]);
    }
    await friendbotFund(user);
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

async function faucetUsedToday(user: string): Promise<boolean> {
  const recent = await sql()`select 1 from lite.tx_log where address = ${user} and kind = 'faucet' and created_at > now() - interval '1 day'`;
  return recent.length > 0;
}

/** Testnet: tops an existing account up with Friendbot's grant of test XLM (networks.ts faucet.amount): Friendbot funds
 *  a temporary account, which merges into the user's. At most once a day per account. The temporary account pays the
 *  fee: `external` in the log. */
export async function testnetFaucet(user: string): Promise<{ hash: string }> {
  if (env.network.name !== "testnet") throw new ApiError(400, "testnet_only", "The faucet is testnet-only.");
  if (await faucetUsedToday(user)) throw new ApiError(429, "faucet_used", "You already got test XLM today.");
  await requireAccount(user);
  const temp = Keypair.random();
  await friendbotFund(temp.publicKey());
  const tempAcct = (await loadAccount(temp.publicKey()))!;
  const tx = new TransactionBuilder(tempAcct, { fee: "1000", networkPassphrase: env.network.passphrase })
    .addOperation(Operation.accountMerge({ destination: user }))
    .setTimeout(60)
    .build();
  tx.sign(temp);
  const hash = await sendSigned(tx, "external");
  await sql()`
    insert into lite.tx_log (hash, inner_hash, address, kind, status, max_fee, fee_payer, section)
    values (${hash}, ${hash}, ${user}, 'faucet', 'pending', 1000, 'external', 'account')`;
  const s = await waitForTx(hash, 30_000);
  await sql()`update lite.tx_log set status = ${s.status === "SUCCESS" ? "success" : s.status === "FAILED" ? "failed" : "pending"}, ledger = ${s.ledger ?? null},
               fee_charged = ${s.feeCharged ?? null} where hash = ${hash}`;
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
 *  from the ledger and the indexer only, with DyorHQ's own records (the starter swap, the faucet's use) null. */
export async function accountView(address: string, scope: View = "owner"): Promise<AccountView> {
  const net = env.network;
  const owner = scope === "owner";
  const [acct, reserve] = await Promise.all([classicBalances(address), baseReserve()]);
  const balances = classicRows(acct);
  if (acct) balances.push(...(await launchRows(address, owner)));
  const xlm = positionOf(acct, reserve);
  const starter = owner ? await starterSwapState(address, xlm ? BigInt(xlm.spendable) : null) : null;
  const faucet = net.faucet ? { amount: net.faucet.amount, usedToday: owner ? await faucetUsedToday(address) : null } : null;
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

