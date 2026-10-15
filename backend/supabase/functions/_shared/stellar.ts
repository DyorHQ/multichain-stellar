// Stellar plumbing shared by every feature: RPC + Horizon clients, ScVal helpers, building, simulating, submitting and
// waiting. stellar-sdk 16 (LTS line) — the same major Blend's SDK uses. Users pay their own network fees
// (docs/DESIGN-stellar-parity.md §4): their transactions are sent as they signed them. The sponsor fee-bumps only the
// starter swap, and signs only an account's setup; the keeper sends protocol upkeep and logs each transaction.
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
  Operation,
  rpc,
  scValToNative,
  SorobanDataBuilder,
  StrKey,
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import { sql, tableExists } from "./db.ts";
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
/** Pays an account's setup and, where activation is sponsored, the starter swap (§4.3); nothing else. */
export function sponsor(): Keypair {
  if (!sponsorKp) sponsorKp = Keypair.fromSecret(env.sponsorSecret);
  return sponsorKp;
}

let keeperKp: Keypair | null = null;
/** Signs protocol upkeep (graduation, TTL, the CCTP relay); never part of a user's transaction. Testnet falls back to
 *  the sponsor (env.keeperSecret). */
export function keeper(): Keypair {
  if (!keeperKp) keeperKp = Keypair.fromSecret(env.keeperSecret);
  return keeperKp;
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

export function isMuxedId(a: string): boolean {
  return StrKey.isValidMed25519PublicKey(a);
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
  /** Who pays this trustline's reserve, when someone else does. */
  sponsor: string | null;
}

/** An account as Horizon describes it: its classic balances and trustlines (liquidity-pool shares left out), its
 *  entry counts, the XLM its open offers hold, and which of its reserves another account pays. */
export interface ClassicAccount {
  balances: ClassicBalance[];
  subentries: number;
  sponsoring: number;
  sponsored: number;
  /** The native balance's selling liabilities, in stroops. */
  sellingLiabilities: string;
  /** Who pays the account's own two base reserves, when someone else does. */
  accountSponsor: string | null;
  /** Who pays each extra signer's reserve, when someone else does. */
  signerSponsors: string[];
}

/** Classic balances and trustlines from Horizon (RPC has no account-wide listing). Null if the account is missing. */
export async function classicBalances(address: string): Promise<ClassicAccount | null> {
  let a: any;
  try {
    a = await horizon().loadAccount(address);
  } catch (err: any) {
    if (err?.response?.status === 404 || String(err).includes("Not Found")) return null;
    throw err;
  }
  const lines = (a.balances as any[]).filter((b) => b.asset_type !== "liquidity_pool_shares");
  const nativeLine = lines.find((b) => b.asset_type === "native");
  return {
    balances: lines.map((b) => ({
      asset: b.asset_type === "native" ? "native" : `${b.asset_code}:${b.asset_issuer}`,
      balance: toStroops(b.balance),
      limit: b.limit ? toStroops(b.limit) : null,
      sponsored: Boolean(b.sponsor),
      sponsor: b.sponsor ?? null,
    })),
    subentries: a.subentry_count,
    sponsoring: a.num_sponsoring ?? 0,
    sponsored: a.num_sponsored ?? 0,
    sellingLiabilities: toStroops(nativeLine?.selling_liabilities ?? "0"),
    accountSponsor: a.sponsor ?? null,
    signerSponsors: ((a.signers ?? []) as any[]).map((s) => s.sponsor).filter((s): s is string => typeof s === "string"),
  };
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

/** A user's transaction is valid for 10 minutes: long enough to read the review before signing, well inside the
 *  verifier's 30. Plans bid the network's going rate for inclusion when they build a step (plans.ts). */
export const USER_TX_TIMEOUT_S = 600;

export function newTx(source: Account, timeoutSec = USER_TX_TIMEOUT_S): TransactionBuilder {
  return new TransactionBuilder(source, { fee: BASE_FEE, networkPassphrase: env.network.passphrase }).setTimeout(timeoutSec);
}

/** The resource fee a Soroban transaction declares: the simulation's minimum × 1.15 + 50,000 stroops (§4.2), so the
 *  headroom its resources get below still pays for itself. */
export function withResourceMargin(minResourceFee: bigint): bigint {
  return (minResourceFee * 115n + 99n) / 100n + 50_000n;
}

/** What a simulation found archived: the restore it needs first (§4.9). */
export interface RestorePreamble {
  minResourceFee: string;
  /** SorobanTransactionData, base64. */
  transactionData: string;
}

/** A simulation answered with a restore preamble. Plans insert a user-paid restore step for it (plans.ts); anywhere
 *  else it answers 409 needs_restore. */
export class NeedsRestore extends ApiError {
  constructor(readonly preamble: RestorePreamble) {
    super(409, "needs_restore", "Part of this contract's data is archived. It needs to be restored first.");
  }
}

/** Simulates a Soroban transaction and assembles footprint, resources and auth, with headroom: state can move
 *  between simulation and execution (Blend accrues interest every ledger), and a transaction that runs out of
 *  budget fails on-chain (invokeHostFunctionResourceLimitExceeded). Instructions get +25% (+100k), bytes +20% (+1k)
 *  and the resource fee withResourceMargin(), all in the transaction assembled (rpc.assembleTransaction takes the
 *  resources and the fee from the simulation it is given). The margin is part of the fee its payer signs for: the
 *  user's own, for every user transaction (§4.1); the keeper's, for upkeep. */
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
    throw new NeedsRestore({
      minResourceFee: sim.restorePreamble.minResourceFee,
      transactionData: sim.restorePreamble.transactionData.build().toXDR("base64"),
    });
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
  const resourceFee = withResourceMargin(BigInt(ok.minResourceFee));
  data.setResourceFee(resourceFee);
  ok.minResourceFee = resourceFee.toString();
  ok.transactionData = data;
  return rpc.assembleTransaction(tx, ok).build();
}

/** A RestoreFootprint transaction from `source` bringing back what a simulation found archived, with prepare()'s
 *  resource-fee margin. It needs no simulation of its own. */
export function restoreTx(source: Account, preamble: RestorePreamble, timeoutSec = USER_TX_TIMEOUT_S): Transaction {
  const data = new SorobanDataBuilder(preamble.transactionData);
  data.setResourceFee(withResourceMargin(BigInt(preamble.minResourceFee)));
  return newTx(source, timeoutSec).setSorobanData(data.build()).addOperation(Operation.restoreFootprint({})).build();
}

/** A read-only contract call (no state change). */
export async function view(contract: string, fn: string, args: xdr.ScVal[] = []): Promise<any> {
  const source = new Account(Keypair.random().publicKey(), "0");
  const tx = newTx(source, 30).addOperation(new Contract(contract).call(fn, ...args)).build();
  const r = await rpcServer().simulateTransaction(tx);
  if (rpc.Api.isSimulationError(r)) throw new ApiError(422, "simulation_failed", simulationMessage(r.error), { raw: r.error.slice(0, 600) });
  return r.result ? scValToNative(r.result.retval) : undefined;
}

export async function invoke(source: Account, contract: string, fn: string, args: xdr.ScVal[], timeoutSec = USER_TX_TIMEOUT_S): Promise<Transaction> {
  return await prepare(newTx(source, timeoutSec).addOperation(new Contract(contract).call(fn, ...args)).build());
}

/** Contract errors arrive as "Error(Contract, #10)"; map the ones users can act on. */
function simulationMessage(raw: string): string {
  if (/trustline entry is missing|TrustlineMissing|#13\b.*trust/i.test(raw)) return "Your account needs to enable this asset first.";
  if (/balance is not sufficient|insufficient balance|#10\b.*balance|resulting balance is not within/i.test(raw)) return "Not enough balance for this.";
  if (/Error\(Contract, #(\d+)\)/.test(raw)) return `The contract refused this (code ${raw.match(/Error\(Contract, #(\d+)\)/)![1]}).`;
  return "This transaction would fail on-chain right now.";
}

/** The Soroban resources a transaction declares, or null for a classic one. */
export function sorobanDataOf(tx: Transaction): xdr.SorobanTransactionData | null {
  const envelope = tx.toEnvelope();
  if (envelope.switch() !== xdr.EnvelopeType.envelopeTypeTx()) return null;
  const ext = envelope.v1().tx().ext();
  return ext.switch() === 1 ? ext.sorobanData() : null;
}

/** `tx` bidding `bid` stroops per operation for inclusion, its resource fee unchanged: the same transaction (same
 *  source, sequence, time bounds, memo and operations) with another fee. Built, never signed. */
export function withInclusionBid(tx: Transaction, bid: bigint): Transaction {
  const soroban = sorobanDataOf(tx);
  const resourceFee = soroban ? BigInt(soroban.resourceFee().toString()) : 0n;
  if (BigInt(tx.fee) - resourceFee === bid * BigInt(tx.operations.length)) return tx;
  return TransactionBuilder.cloneFrom(tx, { fee: bid.toString(), ...(soroban ? { sorobanData: soroban } : {}) }).build();
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

/** Who pays a transaction being sent (an account outside DyorHQ, such as the faucet's temporary one, is `external`): a
 *  refusal for its fee means something else to each of them. */
export type Payer = "user" | "sponsor" | "keeper" | "external";

/** Sends a transaction its user signed and pays for, exactly as signed. Answers its hash. */
export function sendUserTx(tx: Transaction): Promise<string> {
  return send(tx, "user");
}

/** Sends a transaction already signed by every party: an activation, the sponsor's fee-bump of a starter swap, the
 *  keeper's own transactions. */
export function sendSigned(tx: Transaction | FeeBumpTransaction, payer: Payer = "sponsor"): Promise<string> {
  return send(tx, payer);
}

/** The fee-bump in which the sponsor pays a user-signed transaction's fee (the starter swap, §4.3): at the inner
 *  transaction's own rate per operation, and at most `maxFee` in all (422 fee_too_high otherwise). Signed by the
 *  sponsor, not sent. */
export function sponsorFeeBump(inner: Transaction, maxFee: bigint): FeeBumpTransaction {
  const fb = TransactionBuilder.buildFeeBumpTransaction(sponsor(), feeBumpRate(inner).toString(), inner, env.network.passphrase);
  if (BigInt(fb.fee) > maxFee) {
    throw new ApiError(422, "fee_too_high", "The network fee for this is above what DyorHQ pays right now.", { fee: fb.fee, max: maxFee.toString() });
  }
  fb.sign(sponsor());
  return fb;
}

/** The per-operation rate a fee-bump of `inner` pays: the inner transaction's own inclusion rate, at least the base
 *  fee. The fee-bump then costs that rate × (operations + 1) plus the inner resource fee. */
function feeBumpRate(inner: Transaction): bigint {
  const soroban = sorobanDataOf(inner);
  const resourceFee = soroban ? BigInt(soroban.resourceFee().toString()) : 0n;
  const ops = BigInt(inner.operations.length);
  const rate = (BigInt(inner.fee) - resourceFee + ops - 1n) / ops;
  return rate > BigInt(BASE_FEE) ? rate : BigInt(BASE_FEE);
}

/** What the sponsor would pay to fee-bump `inner` (sponsorFeeBump), without building it. */
export function feeBumpFee(inner: Transaction): bigint {
  const soroban = sorobanDataOf(inner);
  const resourceFee = soroban ? BigInt(soroban.resourceFee().toString()) : 0n;
  return feeBumpRate(inner) * BigInt(inner.operations.length + 1) + resourceFee;
}

/** RPC gave no answer about a transaction it was sent (the connection dropped, it timed out, it answered with an error
 *  of its own), so the transaction may be on its way. Only an answer of ERROR or TRY_AGAIN_LATER proves that nothing
 *  was sent; with this one, whether it lands is known only once it settles. `hash` is the transaction's. */
export class SendUnconfirmed extends ApiError {
  constructor(readonly hash: string, raw: string) {
    super(502, "rpc_unavailable", "Stellar RPC didn't confirm it received this transaction.", { hash, raw: raw.slice(0, 300) });
  }
}

async function send(tx: Transaction | FeeBumpTransaction, payer: Payer): Promise<string> {
  let res: rpc.Api.SendTransactionResponse;
  try {
    res = await rpcServer().sendTransaction(tx);
  } catch (err) {
    throw new SendUnconfirmed(tx.hash().toString("hex"), String((err as Error)?.message ?? err));
  }
  if (res.status === "ERROR") {
    const code = res.errorResult ? resultCode(res.errorResult) : "unknown";
    throw sendError(code, payer, res.errorResult?.toXDR("base64"));
  }
  if (res.status === "TRY_AGAIN_LATER") throw new ApiError(503, "network_busy", "The network is busy. Try again in a few seconds.");
  // DUPLICATE: already on its way, which is what was asked.
  return res.hash;
}

/** "LowReserve" → "low_reserve". */
const snakeCase = (words: string) => words.replace(/[A-Z]/g, (c, at) => (at > 0 ? "_" : "") + c.toLowerCase());

/** Horizon's names for a transaction's and an operation's own codes, where they aren't tx_ or op_ and the code's words
 *  in snake case. */
const HORIZON_CODES: Record<string, string> = {
  txNoAccount: "tx_no_source_account",
  txBadMinSeqAgeOrGap: "tx_bad_minseq_age_or_gap",
  opNoAccount: "op_no_source_account",
};

/** Horizon's names for an operation's results, by the words after the operation's name, where they aren't op_ and
 *  those words in snake case. */
const HORIZON_OP_RESULTS: Record<string, string> = {
  AlreadyExist: "op_already_exists",
  OfferCrossSelf: "op_cross_self",
  OverSendmax: "op_over_source_max",
  UnderDestmin: "op_under_dest_min",
  SellNotAuthorized: "sell_not_authorized",
  BuyNotAuthorized: "buy_not_authorized",
  BuyNoIssuer: "buy_no_issuer",
  NotFound: "op_offer_not_found",
  NotAuthMaintainLiabilities: "op_not_aut_maintain_liabilities",
  SeqnumTooFar: "op_seq_num_too_far",
  NoTrustLine: "op_no_trust",
  TrustNotRequired: "op_not_required",
  NameNotFound: "op_data_name_not_found",
  InvalidName: "op_data_invalid_name",
  NotIssuer: "op_no_issuer",
  Trapped: "function_trapped",
  ResourceLimitExceeded: "resource_limit_exceeded",
  EntryArchived: "entry_archived",
  InsufficientRefundableFee: "insufficient_refundable_fee",
};

/** A transaction's or an operation's own code (txBadSeq, opNoAccount) as Horizon names it. */
function horizonCode(code: string): string {
  return HORIZON_CODES[code] ?? `${code.slice(0, 2)}_${snakeCase(code.slice(2))}`;
}

/** An operation's result (changeTrustLowReserve, of a changeTrust) as Horizon names it (op_low_reserve). */
function horizonOpResult(operation: string, code: string): string {
  // createPassiveSellOffer answers with manageSellOffer's codes.
  const name = operation === "createPassiveSellOffer" ? "manageSellOffer" : operation;
  const words = code.startsWith(name) ? code.slice(name.length) : code;
  return HORIZON_OP_RESULTS[words] ?? `op_${snakeCase(words)}`;
}

/** A transaction result's code as Horizon names it, the names the phone's copy is keyed on (§6.13): the inner
 *  transaction's for a fee-bump; after txFailed, the first failed operation's, whatever its operation
 *  (changeTrustLowReserve and createAccountLowReserve are op_low_reserve, paymentUnderfunded and
 *  pathPaymentStrictSendUnderfunded op_underfunded); otherwise the transaction's own (tx_insufficient_balance). */
export function resultCode(result: xdr.TransactionResult): string {
  const r = result.result();
  const name = r.switch().name;
  if (name === "txFeeBumpInnerFailed" || name === "txFeeBumpInnerSuccess") {
    return resultCode(r.innerResultPair().result() as unknown as xdr.TransactionResult);
  }
  if (name === "txFailed") {
    for (const op of (r.results() ?? []) as xdr.OperationResult[]) {
      if (op.switch().name !== "opInner") return horizonCode(op.switch().name);
      const inner = (op.tr().value() as any)?.switch?.().name as string | undefined;
      if (inner && !/Success$/.test(inner)) return horizonOpResult(op.tr().switch().name, inner);
    }
  }
  return horizonCode(name);
}

/** The refusal a send error stands for (§6.13). RPC refuses a transaction for its fee before it runs: a fee the user can't
 *  pay is theirs to fix (409 not_enough_xlm_for_fee), the sponsor running short is DyorHQ's (429 sponsor_limit), and a
 *  bid the network has outgrown is worth another try. What fails when it runs (an operation's own code) is the
 *  transaction's settled error instead. */
function sendError(code: string, payer: Payer, detail?: string): ApiError {
  if (code === "tx_insufficient_balance" || code === "tx_insufficient_fee") {
    if (payer === "user") return new ApiError(409, "not_enough_xlm_for_fee", "Not enough XLM for the network fee.", { code });
    if (code === "tx_insufficient_fee") return new ApiError(503, "network_busy", "The network fee went up. Try again in a minute.", { code });
    if (payer === "sponsor") return new ApiError(429, "sponsor_limit", "DyorHQ's free setup is busy today. Try again tomorrow.", { code });
  }
  return new ApiError(422, "tx_rejected", txErrorMessage(code), { code, ...(detail ? { detail } : {}) });
}

function txErrorMessage(code: string): string {
  switch (code) {
    case "tx_bad_seq":
      return "This transaction is out of date. It will be rebuilt.";
    case "tx_too_late":
      return "This transaction expired before it was sent. It will be rebuilt.";
    case "tx_bad_auth":
    case "tx_fee_bump_inner_failed":
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
  /** The TransactionResult, base64: what each operation did (an SDEX swap's amount out is only here). */
  resultXdr?: string;
  /** Why it failed, as Horizon names it (resultCode()). */
  error?: string;
}

export async function txStatus(hash: string): Promise<Settled> {
  const r = await rpcServer().getTransaction(hash);
  if (r.status === rpc.Api.GetTransactionStatus.NOT_FOUND) return { status: "PENDING" };
  const result = (r as any).resultXdr as xdr.TransactionResult | undefined;
  const settled = { ledger: r.ledger, feeCharged: result?.feeCharged().toString(), resultXdr: result?.toXDR("base64") };
  if (r.status === rpc.Api.GetTransactionStatus.SUCCESS) {
    let rv: unknown;
    try {
      rv = r.returnValue ? scValToNative(r.returnValue) : undefined;
    } catch {
      rv = undefined;
    }
    return { status: "SUCCESS", ...settled, returnValue: rv };
  }
  return { status: "FAILED", ...settled, error: result ? resultCode(result) : "tx_failed" };
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

// ------------------------------------------------------------------------------------------------ the keeper

export type KeeperJob = "graduate" | "ttl" | "relay";

/** Signs `tx` (built from the keeper's account) with the keeper key, sends it and records it in lite.keeper_log
 *  (§4.7) with what it was for. Answers its hash. */
export async function keeperSend(job: KeeperJob, tx: Transaction, detail: Record<string, unknown> = {}): Promise<string> {
  const k = keeper();
  tx.sign(k);
  const hash = await sendSigned(tx, "keeper");
  try {
    if (await tableExists("lite.keeper_log")) {
      await sql()`insert into lite.keeper_log (hash, job, keeper, max_fee, detail)
                  values (${hash}, ${job}, ${k.publicKey()}, ${tx.fee}, ${sql().json(detail as any)}) on conflict (hash) do nothing`;
    }
  } catch (err) {
    console.warn("keeper_log: not recorded", job, hash, String((err as Error).message ?? err).slice(0, 120));
  }
  return hash;
}

export { Account, Address, Asset, BASE_FEE, Contract, FeeBumpTransaction, Keypair, Operation, SorobanDataBuilder, Transaction, TransactionBuilder, xdr };
