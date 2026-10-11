// Stellar plumbing shared by every feature: RPC + Horizon clients, ScVal helpers, building, simulating, fee-bumping,
// submitting and waiting. stellar-sdk 16 (LTS line) — the same major Blend's SDK uses.
import {
  Account,
  Address,
  Asset,
  BASE_FEE,
  Contract,
  FeeBumpTransaction,
  Horizon,
  Keypair,
  nativeToScVal,
  rpc,
  scValToNative,
  StrKey,
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import { env } from "./env.ts";
import { ApiError } from "./http.ts";
import { NetworkConfig } from "./networks.ts";

let rpcClient: rpc.Server | null = null;
let horizonClient: Horizon.Server | null = null;

export function rpcServer(net: NetworkConfig = env.network): rpc.Server {
  if (!rpcClient) rpcClient = new rpc.Server(net.rpcUrl, { allowHttp: net.rpcUrl.startsWith("http://") });
  return rpcClient;
}

export function horizon(net: NetworkConfig = env.network): Horizon.Server {
  if (!horizonClient) horizonClient = new Horizon.Server(net.horizonUrl);
  return horizonClient;
}

let sponsorKp: Keypair | null = null;
export function sponsor(): Keypair {
  if (!sponsorKp) sponsorKp = Keypair.fromSecret(env.sponsorSecret);
  return sponsorKp;
}

// ------------------------------------------------------------------------------------------------ values

export const sv = {
  addr: (a: string) => new Address(a).toScVal(),
  i128: (n: bigint | string | number) => nativeToScVal(BigInt(n), { type: "i128" }),
  u128: (n: bigint | string | number) => nativeToScVal(BigInt(n), { type: "u128" }),
  u64: (n: bigint | string | number) => nativeToScVal(BigInt(n), { type: "u64" }),
  u32: (n: number) => nativeToScVal(n, { type: "u32" }),
  str: (s: string) => nativeToScVal(s, { type: "string" }),
  bool: (b: boolean) => xdr.ScVal.scvBool(b),
  bytes: (b: Uint8Array) => xdr.ScVal.scvBytes(b as any),
  vec: (items: xdr.ScVal[]) => xdr.ScVal.scvVec(items),
};

export const native = scValToNative;

export function classicAsset(spec: string): Asset {
  if (spec === "native") return Asset.native();
  const [code, issuer] = spec.split(":");
  return new Asset(code, issuer);
}

export function sacOf(spec: string, net: NetworkConfig = env.network): string {
  return classicAsset(spec).contractId(net.passphrase);
}

export function isAccountId(a: string): boolean {
  return StrKey.isValidEd25519PublicKey(a);
}

export function isContractId(a: string): boolean {
  return StrKey.isValidContract(a);
}

// ------------------------------------------------------------------------------------------------ accounts

export async function loadAccount(address: string): Promise<Account | null> {
  try {
    return await rpcServer().getAccount(address);
  } catch (err) {
    if (String(err).toLowerCase().includes("not found")) return null;
    throw err;
  }
}

export async function requireAccount(address: string): Promise<Account> {
  const acct = await loadAccount(address);
  if (!acct) throw new ApiError(409, "account_inactive", "Activate your Stellar account first.");
  return acct;
}

export interface ClassicBalance {
  asset: string; // "native" or CODE:ISSUER
  balance: string; // base units
  limit: string | null;
  sponsored: boolean;
}

/** Classic balances and trustlines from Horizon (RPC has no account-wide listing). Null if the account is missing. */
export async function classicBalances(address: string): Promise<{ balances: ClassicBalance[]; subentries: number; sponsoring: number; sponsored: number } | null> {
  try {
    const a = await horizon().loadAccount(address);
    const balances = a.balances.map((b: any) => ({
      asset: b.asset_type === "native" ? "native" : `${b.asset_code}:${b.asset_issuer}`,
      balance: toStroops(b.balance),
      limit: b.limit ? toStroops(b.limit) : null,
      sponsored: Boolean(b.sponsor),
    }));
    return { balances, subentries: a.subentry_count, sponsoring: (a as any).num_sponsoring ?? 0, sponsored: (a as any).num_sponsored ?? 0 };
  } catch (err: any) {
    if (err?.response?.status === 404 || String(err).includes("Not Found")) return null;
    throw err;
  }
}

/** "12.3400000" → "123400000". */
export function toStroops(decimal: string): string {
  const [i, f = ""] = decimal.split(".");
  return (BigInt(i) * 10_000_000n + BigInt((f + "0000000").slice(0, 7))).toString();
}

/** 123400000n → "12.34". */
export function fromStroops(n: bigint | string, decimals = 7): string {
  const v = BigInt(n);
  const neg = v < 0n;
  const abs = neg ? -v : v;
  const base = 10n ** BigInt(decimals);
  const frac = (abs % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${neg ? "-" : ""}${abs / base}${frac ? "." + frac : ""}`;
}

// ------------------------------------------------------------------------------------------------ building

export function newTx(source: Account, timeoutSec = 300): TransactionBuilder {
  return new TransactionBuilder(source, { fee: BASE_FEE, networkPassphrase: env.network.passphrase }).setTimeout(timeoutSec);
}

/** Simulates a Soroban transaction and assembles footprint, resources and auth, with headroom: state can move
 *  between simulation and execution (Blend accrues interest every ledger), and a transaction that runs out of
 *  budget fails on-chain (invokeHostFunctionResourceLimitExceeded). The sponsor pays the margin, never the user. */
export async function prepare(tx: Transaction): Promise<Transaction> {
  let sim: rpc.Api.SimulateTransactionResponse;
  try {
    sim = await rpcServer().simulateTransaction(tx);
  } catch (err) {
    const msg = String((err as any)?.message ?? err);
    throw new ApiError(502, "rpc_unavailable", "Stellar RPC didn't answer. Try again.", { raw: msg.slice(0, 300) });
  }
  if (rpc.Api.isSimulationError(sim)) {
    throw new ApiError(422, "simulation_failed", simulationMessage(sim.error), { raw: sim.error.slice(0, 600) });
  }
  if (rpc.Api.isSimulationRestore(sim)) {
    throw new ApiError(409, "needs_restore", "Part of this contract's data is archived. It is being restored; try again in a minute.");
  }
  const ok = sim as rpc.Api.SimulateTransactionSuccessResponse;
  const data = ok.transactionData;
  const r = data.build().resources();
  const MAX_INSTRUCTIONS = 100_000_000;
  data.setResources(
    Math.min(MAX_INSTRUCTIONS, Math.ceil(r.instructions() * 1.25) + 100_000),
    Math.ceil(r.diskReadBytes() * 1.2) + 1_000,
    Math.ceil(r.writeBytes() * 1.2) + 1_000,
  );
  ok.minResourceFee = String(Math.ceil(Number(ok.minResourceFee) * 1.3) + 100_000);
  ok.transactionData = data;
  return rpc.assembleTransaction(tx, ok).build();
}

/** A read-only contract call (no state change). */
export async function view(contract: string, fn: string, args: xdr.ScVal[] = []): Promise<any> {
  const source = new Account(Keypair.random().publicKey(), "0");
  const tx = newTx(source, 30).addOperation(new Contract(contract).call(fn, ...args)).build();
  const r = await rpcServer().simulateTransaction(tx);
  if (rpc.Api.isSimulationError(r)) throw new ApiError(422, "simulation_failed", simulationMessage(r.error), { raw: r.error.slice(0, 600) });
  return r.result ? scValToNative(r.result.retval) : undefined;
}

export async function invoke(source: Account, contract: string, fn: string, args: xdr.ScVal[], timeoutSec = 300): Promise<Transaction> {
  return await prepare(newTx(source, timeoutSec).addOperation(new Contract(contract).call(fn, ...args)).build());
}

/** Contract errors arrive as "Error(Contract, #10)"; map the ones users can act on. */
function simulationMessage(raw: string): string {
  if (/trustline entry is missing|TrustlineMissing|#13\b.*trust/i.test(raw)) return "Your account needs to enable this asset first.";
  if (/balance is not sufficient|insufficient balance|#10\b.*balance|resulting balance is not within/i.test(raw)) return "Not enough balance for this.";
  if (/Error\(Contract, #(\d+)\)/.test(raw)) return `The contract refused this (code ${raw.match(/Error\(Contract, #(\d+)\)/)![1]}).`;
  return "This transaction would fail on-chain right now.";
}

// ------------------------------------------------------------------------------------------------ submitting

export function parseSigned(envelopeXdr: string): Transaction {
  let tx: Transaction | FeeBumpTransaction;
  try {
    tx = TransactionBuilder.fromXDR(envelopeXdr, env.network.passphrase);
  } catch {
    throw new ApiError(400, "bad_xdr", "That transaction couldn't be read.");
  }
  if (tx instanceof FeeBumpTransaction) throw new ApiError(400, "bad_xdr", "Send the signed transaction, not a fee-bump.");
  return tx;
}

/** True when `tx` carries a valid signature by `address`. */
export function signedBy(tx: Transaction, address: string): boolean {
  const kp = Keypair.fromPublicKey(address);
  const hint = kp.signatureHint();
  const hash = tx.hash();
  return tx.signatures.some((s) => Buffer.from(s.hint()).equals(Buffer.from(hint)) && kp.verify(hash, s.signature()));
}

export interface Submitted {
  hash: string;
  innerHash: string;
  fee: string;
}

/** Wraps a user-signed transaction in a fee-bump paid by the sponsor and sends it. */
export async function feeBumpAndSend(inner: Transaction, maxFee: bigint): Promise<Submitted> {
  const ops = inner.operations.length;
  // The fee-bump's per-op rate must be ≥ the inner's; for Soroban the inner fee includes the resource fee, which the
  // outer fee must cover too. Paying the inner's own total rate (+ one base fee for the outer envelope) does both.
  const innerFee = BigInt(inner.fee);
  const rate = (innerFee + BigInt(BASE_FEE) + BigInt(ops)) / BigInt(ops + 1);
  const baseFee = rate > BigInt(BASE_FEE) ? rate : BigInt(BASE_FEE);
  const fb = TransactionBuilder.buildFeeBumpTransaction(sponsor(), baseFee.toString(), inner, env.network.passphrase);
  if (BigInt(fb.fee) > maxFee) {
    throw new ApiError(422, "fee_too_high", "The network fee for this is above what DyorHQ sponsors right now.", { fee: fb.fee, max: maxFee.toString() });
  }
  fb.sign(sponsor());
  const res = await rpcServer().sendTransaction(fb);
  if (res.status === "ERROR") {
    const code = res.errorResult?.result().switch().name ?? "unknown";
    throw new ApiError(422, "tx_rejected", txErrorMessage(code), { code, detail: res.errorResult?.toXDR("base64") });
  }
  if (res.status === "TRY_AGAIN_LATER") throw new ApiError(503, "network_busy", "The network is busy. Try again in a few seconds.");
  return { hash: res.hash, innerHash: inner.hash().toString("hex"), fee: fb.fee };
}

/** Sends a transaction already signed by every party (the sponsor's own transactions: relays, keeper calls). */
export async function sendSigned(tx: Transaction | FeeBumpTransaction): Promise<string> {
  const res = await rpcServer().sendTransaction(tx);
  if (res.status === "ERROR") {
    const code = res.errorResult?.result().switch().name ?? "unknown";
    throw new ApiError(422, "tx_rejected", txErrorMessage(code), { code });
  }
  if (res.status === "TRY_AGAIN_LATER") throw new ApiError(503, "network_busy", "The network is busy. Try again in a few seconds.");
  return res.hash;
}

function txErrorMessage(code: string): string {
  switch (code) {
    case "txBadSeq":
      return "This transaction is out of date. It will be rebuilt.";
    case "txTooLate":
      return "This transaction expired before it was sent. It will be rebuilt.";
    case "txInsufficientFee":
      return "The network fee went up. Try again.";
    case "txBadAuth":
    case "txFeeBumpInnerFailed":
      return "The signature didn't match. Nothing was sent.";
    default:
      return `The network refused this transaction (${code}).`;
  }
}

export interface Settled {
  status: "SUCCESS" | "FAILED" | "PENDING";
  ledger?: number;
  feeCharged?: string;
  returnValue?: unknown;
  error?: string;
}

export async function txStatus(hash: string): Promise<Settled> {
  const r = await rpcServer().getTransaction(hash);
  if (r.status === rpc.Api.GetTransactionStatus.NOT_FOUND) return { status: "PENDING" };
  if (r.status === rpc.Api.GetTransactionStatus.SUCCESS) {
    let rv: unknown;
    try {
      rv = r.returnValue ? scValToNative(r.returnValue) : undefined;
    } catch {
      rv = undefined;
    }
    return { status: "SUCCESS", ledger: r.ledger, feeCharged: (r as any).resultXdr?.feeCharged?.().toString(), returnValue: rv };
  }
  const code = (r as any).resultXdr?.result?.().switch?.().name ?? "failed";
  return { status: "FAILED", ledger: r.ledger, error: code };
}

export async function waitForTx(hash: string, timeoutMs = 45_000): Promise<Settled> {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    const s = await txStatus(hash);
    if (s.status !== "PENDING") return s;
    await new Promise((r) => setTimeout(r, 1_500));
  }
  return { status: "PENDING" };
}

export { Account, Address, Asset, BASE_FEE, Contract, Keypair, Transaction, TransactionBuilder, xdr };
