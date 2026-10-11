// Accounts: activation (Friendbot on testnet, sponsored reserves on mainnet), sponsored trustlines, balances, sends.
import { Operation } from "@stellar/stellar-sdk";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad } from "./http.ts";
import { AssetInfo, assetById } from "./networks.ts";
import { registerBuilder } from "./plans.ts";
import {
  classicAsset,
  classicBalances,
  fromStroops,
  invoke,
  isAccountId,
  isContractId,
  Keypair,
  loadAccount,
  newTx,
  requireAccount,
  sacOf,
  sendSigned,
  sponsor,
  sv,
  TransactionBuilder,
  view,
  waitForTx,
} from "./stellar.ts";
import { Intent } from "./verify.ts";

const SPONSOR_OPS = ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"];

registerBuilder("trust", async (user, spec) => {
  const asset = String(spec.asset);
  const acct = await requireAccount(user);
  const sp = sponsor().publicKey();
  const tx = newTx(acct)
    .addOperation(Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sp }))
    .addOperation(Operation.changeTrust({ asset: classicAsset(asset), source: user }))
    .addOperation(Operation.endSponsoringFutureReserves({ source: user }))
    .build();
  const code = asset.split(":")[0];
  const intent: Intent = { kind: "trust", summary: `Enable ${code} (reserve paid by DyorHQ)`, spend: {}, ops: SPONSOR_OPS, trust: [asset], display: { asset: code } };
  return { tx, intent, cosignSponsor: true };
});

/** Mainnet activation: the account is created by the sponsor with 0 XLM, reserves sponsored, USDC enabled. */
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
    summary: "Create your Stellar account (paid by DyorHQ)",
    spend: {},
    ops: ["beginSponsoringFutureReserves", "createAccount", "changeTrust", "endSponsoringFutureReserves"],
    trust: [usdc],
  };
  return { tx, intent, cosignSponsor: true };
});

registerBuilder("payment", async (user, spec) => {
  const asset = assetById(env.network, String(spec.asset)) ?? tokenAsset(String(spec.asset));
  const to = String(spec.to);
  const amount = BigInt(String(spec.amount));
  const acct = await requireAccount(user);
  const display = { asset: asset.code, amount: fromStroops(amount, asset.decimals), to };
  if (asset.classic && isAccountId(to)) {
    const dest = await classicBalances(to);
    let tb = newTx(acct);
    if (!dest) {
      if (asset.classic !== "native") throw new ApiError(409, "recipient_inactive", "That account doesn't exist yet, so it can't receive this asset.");
      if (amount < 10_000_000n) throw bad("too_small", "A new account needs at least 1 XLM.");
      tb = tb.addOperation(Operation.createAccount({ destination: to, startingBalance: fromStroops(amount) }));
    } else {
      if (asset.classic !== "native" && !dest.balances.some((b) => b.asset === asset.classic)) {
        throw new ApiError(409, "recipient_cannot_receive", `That account hasn't enabled ${asset.code}.`);
      }
      tb = tb.addOperation(Operation.payment({ destination: to, asset: classicAsset(asset.classic), amount: fromStroops(amount) }));
    }
    const tx = tb.build();
    const ops = dest ? ["payment"] : ["createAccount"];
    const intent: Intent = { kind: "payment", summary: `Send ${display.amount} ${asset.code}`, spend: { [asset.contract]: amount.toString() }, ops, display };
    return { tx, intent };
  }
  if (!isAccountId(to) && !isContractId(to)) throw bad("bad_address", "That isn't a Stellar address.");
  const tx = await invoke(acct, asset.contract, "transfer", [sv.addr(user), sv.addr(to), sv.i128(amount)]);
  const intent: Intent = {
    kind: "payment",
    summary: `Send ${display.amount} ${asset.code}`,
    spend: { [asset.contract]: amount.toString() },
    calls: [{ contract: asset.contract, fn: "transfer" }],
    display,
  };
  return { tx, intent };
});

function tokenAsset(contract: string): AssetInfo {
  if (!isContractId(contract)) throw bad("bad_asset", "Unknown asset.");
  return { id: contract, code: "TOKEN", name: "Token", decimals: 7, contract, classic: null };
}

// ------------------------------------------------------------------------------------------------ activation

export async function friendbotFund(address: string): Promise<void> {
  const url = env.network.friendbotUrl;
  if (!url) throw new ApiError(400, "no_friendbot", "Friendbot only exists on testnet.");
  const res = await fetch(`${url}?addr=${encodeURIComponent(address)}`);
  if (!res.ok) {
    const body = await res.text();
    if (!body.includes("createAccountAlreadyExist")) throw new ApiError(502, "friendbot_failed", "Testnet Friendbot didn't answer. Try again.", { status: res.status });
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

/** Testnet: tops an existing account up with 10,000 test XLM (Friendbot funds a temporary account, which merges
 *  into the user's). At most once per day per account. */
export async function testnetFaucet(user: string): Promise<{ hash: string }> {
  if (env.network.name !== "testnet") throw new ApiError(400, "testnet_only", "The faucet is testnet-only.");
  const recent = await sql()`select 1 from lite.tx_log where address = ${user} and kind = 'faucet' and created_at > now() - interval '1 day'`;
  if (recent.length) throw new ApiError(429, "faucet_used", "You already got test XLM today.");
  await requireAccount(user);
  const temp = Keypair.random();
  await friendbotFund(temp.publicKey());
  const tempAcct = (await loadAccount(temp.publicKey()))!;
  const tx = new TransactionBuilder(tempAcct, { fee: "1000", networkPassphrase: env.network.passphrase })
    .addOperation(Operation.accountMerge({ destination: user }))
    .setTimeout(60)
    .build();
  tx.sign(temp);
  const hash = await sendSigned(tx);
  await sql()`insert into lite.tx_log (hash, inner_hash, address, kind, status, max_fee) values (${hash}, ${hash}, ${user}, 'faucet', 'pending', 1000)`;
  const s = await waitForTx(hash, 30_000);
  await sql()`update lite.tx_log set status = ${s.status === "SUCCESS" ? "success" : s.status === "FAILED" ? "failed" : "pending"}, ledger = ${s.ledger ?? null} where hash = ${hash}`;
  return { hash };
}

// ------------------------------------------------------------------------------------------------ balances

export interface BalanceRow {
  asset: string; // registry id or token contract
  code: string;
  name: string;
  contract: string;
  classic: string | null;
  decimals: number;
  balance: string;
  enabled: boolean; // trustline present (classic) or always true (Soroban)
  note?: string;
}

export async function accountView(user: string) {
  const net = env.network;
  const classic = await classicBalances(user);
  const rows: BalanceRow[] = [];
  for (const a of net.assets) {
    const b = classic?.balances.find((x) => x.asset === a.classic);
    rows.push({
      asset: a.id,
      code: a.code,
      name: a.name,
      contract: a.contract,
      classic: a.classic,
      decimals: a.decimals,
      balance: b?.balance ?? "0",
      enabled: a.classic === "native" ? Boolean(classic) : Boolean(b),
      note: a.note,
    });
  }
  // Launch tokens this account has touched (from the indexer), read live.
  if (classic) {
    const tokens = await sql()`
      select distinct on (l.token) l.token, l.symbol, l.name from lite.launch_trades t join lite.launches l on l.token = t.token
       where t.trader = ${user} order by l.token limit 25`;
    const balances = await Promise.all(tokens.map((t) => view(t.token as string, "balance", [sv.addr(user)]).catch(() => 0n)));
    tokens.forEach((t, i) => {
      const bal = BigInt(balances[i] ?? 0n);
      if (bal > 0n) {
        rows.push({ asset: t.token as string, code: t.symbol as string, name: t.name as string, contract: t.token as string, classic: null, decimals: 7, balance: bal.toString(), enabled: true });
      }
    });
  }
  return {
    address: user,
    exists: Boolean(classic),
    network: net.name,
    activation: net.activation,
    balances: rows,
    reserves: classic ? { subentries: classic.subentries, sponsoredByDyorHQ: classic.sponsored } : null,
    sponsor: sponsor().publicKey(),
  };
}

export function needsTrustline(balances: { asset: string; enabled: boolean; classic: string | null }[], assetId: string): string | null {
  const a = assetById(env.network, assetId);
  if (!a || !a.classic || a.classic === "native") return null;
  const row = balances.find((b) => b.asset === a.id);
  return row?.enabled ? null : a.classic;
}

export { sacOf };
