// Generates the cross-language test vectors the Swift verifier (StellarCore) must agree with
// (docs/DESIGN-stellar-parity.md §12.4):
// - real transactions the API built during the testnet e2e run (read from the plans table), judged as they are;
// - synthetic ones built here, one per rule, judged by the TS verifier: its verdict, reason and outflow, and for a step
//   with a fee payer, who pays (verifyFeePayer);
// - key derivation, SEP-53, StrKey and SAC id vectors.
// Every vector carries the fee caps it was judged with, and what stellar-sdk decoded (source, fee, memo, …), so the
// Swift decoder is checked too.
//   LITE_DB_URL=… SPONSOR_PUBLIC=G… deno run -A --config backend/supabase/functions/deno.json backend/tests/vectors/gen-vectors.ts
//   deno run -A --config backend/supabase/functions/deno.json backend/tests/vectors/gen-vectors.ts --synthetic-only
// The synthetic vectors are deterministic: running it again writes the same files.
import {
  Account,
  Address,
  Asset,
  Contract,
  Keypair,
  Memo,
  MuxedAccount,
  nativeToScVal,
  Operation,
  SorobanDataBuilder,
  StrKey,
  Transaction,
  TransactionBuilder,
  xdr,
} from "@stellar/stellar-sdk";
import postgres from "postgres";
import { contractAllowlist, TESTNET } from "../../supabase/functions/_shared/networks.ts";
import { FeeCaps, Intent, verifyFeePayer, verifyTransaction } from "../../supabase/functions/_shared/verify.ts";
import { SEP53_PREFIX, sha256 } from "../../supabase/functions/_shared/auth.ts";

const PASS = TESTNET.passphrase;
const out = new URL("../../../ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/", import.meta.url).pathname;
const syntheticOnly = Deno.args.includes("--synthetic-only");

/** The testnet caps, as networks.ts and the generated pins hold them. */
const FEES: FeeCaps = {
  maxFee: TESTNET.feePolicy.maxFee,
  maxInclusionPerOp: TESTNET.feePolicy.maxInclusionPerOp,
  starterInnerFeeMax: TESTNET.feePolicy.starterInnerFeeMax,
};
const MONAD_DOMAIN = TESTNET.bridge.monad!.domain;
const WASM = TESTNET.deployment!.launchTokenWasmHash;

interface Step {
  feePayer: string | null;
  sponsorReason: string | null;
}

interface Vector {
  name: string;
  envelope: string;
  intent: Intent;
  user: string;
  sponsor: string;
  /** Pinned contracts. */
  allowed: string[];
  /** Launch tokens the phone verified on chain (their WASM is the pinned one). */
  launchTokens: string[];
  launchTokenWasmHash: string;
  monadDomain: number;
  feePolicy: { maxFee: string; maxInclusionPerOp: string; starterInnerFeeMax: string };
  now: number;
  /** The step's fee-payer flags, when the vector is about who pays. */
  step?: Step;
  expect: {
    ok: boolean;
    reason?: string;
    outflow?: Record<string, string>;
    /** verifyFeePayer's verdict for `step`: who pays, or why the step is refused. */
    step?: { ok: boolean; payer?: string; reason?: string };
  };
  decoded: {
    source: string;
    fee: number;
    seq: string;
    maxTime: number;
    ops: string[];
    resourceFee: string | null;
    memo: { type: string; value: string } | null;
    /** The first operation's destination: a payment's, a new account's, a path payment's, or a token transfer's `to`. */
    to: string | null;
  };
}

function memoOf(tx: Transaction): Vector["decoded"]["memo"] {
  const m = tx.memo;
  switch (m.type) {
    case "none":
      return null;
    case "text":
      return { type: "text", value: Buffer.from(m.value as string | Buffer).toString("utf8") };
    case "id":
      return { type: "id", value: String(m.value) };
    default:
      return { type: m.type, value: (m.value as Buffer).toString("hex") };
  }
}

function destinationOf(tx: Transaction): string | null {
  const op = tx.operations[0] as any;
  switch (op?.type) {
    case "payment":
    case "createAccount":
    case "pathPaymentStrictSend":
      return op.destination;
    case "invokeHostFunction": {
      const fn = op.func as xdr.HostFunction;
      if (fn.switch() !== xdr.HostFunctionType.hostFunctionTypeInvokeContract()) return null;
      const ic = fn.invokeContract();
      const to = ic.args()[1];
      if (ic.functionName().toString() !== "transfer" || !to || to.switch() !== xdr.ScValType.scvAddress()) return null;
      const t = to.address().switch();
      return t === xdr.ScAddressType.scAddressTypeAccount() || t === xdr.ScAddressType.scAddressTypeContract() ? Address.fromScVal(to).toString() : null;
    }
    default:
      return null;
  }
}

function decodedOf(tx: Transaction): Vector["decoded"] {
  const ext = tx.toEnvelope().v1().tx().ext();
  return {
    source: tx.source,
    fee: Number(tx.fee),
    seq: tx.sequence,
    maxTime: Number(tx.timeBounds?.maxTime ?? 0),
    ops: tx.operations.map((o: any) => o.type),
    resourceFee: ext.switch() === 1 ? ext.sorobanData().resourceFee().toString() : null,
    memo: memoOf(tx),
    to: destinationOf(tx),
  };
}

interface Judged {
  name: string;
  tx: Transaction;
  intent: Intent;
  user: string;
  sponsor: string;
  allowed: string[];
  launchTokens?: string[];
  now: number;
  step?: Step;
}

function judge(j: Judged): Vector {
  const launchTokens = j.launchTokens ?? [];
  const ctx = {
    user: j.user,
    sponsor: j.sponsor,
    passphrase: PASS,
    allowedContracts: new Set([...j.allowed, ...launchTokens]),
    now: j.now,
    feePolicy: FEES,
    launchTokenWasmHash: WASM,
    monadDomain: MONAD_DOMAIN,
  };
  let expect: Vector["expect"];
  try {
    const r = verifyTransaction(j.tx, j.intent, ctx);
    expect = { ok: true, outflow: r.outflow };
  } catch (e) {
    expect = { ok: false, reason: (e as Error).message };
  }
  if (j.step) {
    try {
      expect.step = { ok: true, payer: verifyFeePayer(j.tx, j.intent, j.step, ctx) };
    } catch (e) {
      expect.step = { ok: false, reason: (e as Error).message };
    }
  }
  return {
    name: j.name,
    envelope: j.tx.toEnvelope().toXDR("base64"),
    intent: j.intent,
    user: j.user,
    sponsor: j.sponsor,
    allowed: j.allowed,
    launchTokens,
    launchTokenWasmHash: WASM,
    monadDomain: MONAD_DOMAIN,
    feePolicy: { maxFee: FEES.maxFee.toString(), maxInclusionPerOp: FEES.maxInclusionPerOp.toString(), starterInnerFeeMax: FEES.starterInnerFeeMax.toString() },
    now: j.now,
    ...(j.step ? { step: j.step } : {}),
    expect,
    decoded: decodedOf(j.tx),
  };
}

const vectors: Vector[] = [];
const pinned = Object.values(contractAllowlist(TESTNET)).flat();

// ------------------------------------------------------------------------------------------------ real transactions
const dbUrl = Deno.env.get("LITE_DB_URL");
if (dbUrl && !syntheticOnly) {
  const db = postgres(dbUrl, { onnotice: () => {} });
  const sponsor = Deno.env.get("SPONSOR_PUBLIC")!;
  const launches = (await db`select token from lite.launches`).map((r) => r.token as string);
  const plans = await db`select address, kind, steps from lite.plans order by created_at`;
  const seen = new Set<string>();
  for (const p of plans) {
    for (const s of p.steps as any[]) {
      if (!s.xdr || !s.intent) continue;
      const key = `${p.kind}:${s.intent.kind}:${s.intent.calls?.[0]?.contract ?? ""}`;
      if (seen.has(key)) continue;
      seen.add(key);
      const tx = TransactionBuilder.fromXDR(s.xdr, PASS) as Transaction;
      const now = Number(tx.timeBounds!.maxTime) - 300;
      const step = s.feePayer ? { feePayer: s.feePayer as string, sponsorReason: (s.sponsorReason ?? null) as string | null } : undefined;
      vectors.push(judge({ name: `real ${key}`, tx, intent: s.intent, user: p.address as string, sponsor, allowed: pinned, launchTokens: launches, now, step }));
    }
  }
  await db.end();
}

// ------------------------------------------------------------------------------------------------ synthetic
const userKp = Keypair.fromSecret("SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN");
const user = userKp.publicKey();
const sponsor = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 7)).publicKey();
const friend = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 8)).publicKey();
const third = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 9)).publicKey();
const c = TESTNET.contracts;
const ROUTER = c.soroswapRouter;
const AQUARIUS = c.aquariusRouter!;
const LAUNCHPAD = c.launchpad!;
const MOMENTS = c.moments!;
const POOL = c.blendPools[0].id;
const MESSENGER = c.cctp!.tokenMessengerMinter;
const XLM = Asset.native().contractId(PASS);
const USDC_ASSET = new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5");
const USDC = USDC_ASSET.contractId(PASS);
const USDC_SPEC = `USDC:${USDC_ASSET.getIssuer()}`;
const EVIL = new Contract("CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526").contractId();
/** A launch token the phone verified (deployed from the pinned launch-token WASM). */
const TOKEN = StrKey.encodeContract(Buffer.alloc(32, 0x22));
/** A Soroswap pair: a contract a swap's footprint names, and nobody pins. */
const PAIR = StrKey.encodeContract(Buffer.alloc(32, 0x33));
const MONAD_USER = "0x" + "12".repeat(20);
const NOW = 1_800_000_000;

function tx(ops: xdr.Operation[], o: { source?: string | MuxedAccount; maxTime?: number; fee?: string; memo?: Memo; soroban?: xdr.SorobanTransactionData } = {}) {
  const source = o.source instanceof MuxedAccount ? o.source : new Account(o.source ?? user, "41");
  const b = new TransactionBuilder(source, {
    fee: o.fee ?? "100",
    networkPassphrase: PASS,
    timebounds: { minTime: 0, maxTime: o.maxTime ?? NOW + 300 },
    memo: o.memo,
  });
  if (o.soroban) b.setSorobanData(o.soroban);
  ops.forEach((op) => b.addOperation(op));
  return b.build();
}
/** The same transaction declaring another fee (stellar-sdk adds the resource fee to the bid it is given). */
function withFee(t: Transaction, fee: number): Transaction {
  const envelope = t.toEnvelope();
  envelope.v1().tx().fee(fee);
  return new Transaction(envelope, PASS);
}
/** The same trustline change with another limit (stellar-sdk won't build a negative one). */
function withLimit(t: Transaction, limit: bigint): Transaction {
  const envelope = t.toEnvelope();
  envelope.v1().tx().operations()[0].body().changeTrustOp().limit(xdr.Int64.fromString(limit.toString()));
  return new Transaction(envelope, PASS);
}
const resources = (resourceFee: number, readWrite: xdr.LedgerKey[] = []) => new SorobanDataBuilder().setResourceFee(resourceFee).setReadWrite(readWrite).build();
const call = (contract: string, fn: string, args: xdr.ScVal[]) => new xdr.InvokeContractArgs({ contractAddress: new Address(contract).toScAddress(), functionName: fn, args });
const inv = (ic: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizedInvocation({ function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(ic), subInvocations: subs });
const src = (root: xdr.SorobanAuthorizedInvocation) => new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: root });
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u128 = (n: bigint) => nativeToScVal(n, { type: "u128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const u64 = (n: bigint) => nativeToScVal(n, { type: "u64" });
const addr = (a: string) => new Address(a).toScVal();
const str = (s: string) => nativeToScVal(s, { type: "string" });
/** A contract call whose root authorization is the call itself, with `subs` beneath it. */
const invoke = (ic: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = [], extra: xdr.SorobanAuthorizationEntry[] = []) =>
  Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(ic), auth: [src(inv(ic, subs)), ...extra] });
const pull = (token: string, to: string, amount: bigint) => inv(call(token, "transfer", [addr(user), addr(to), i128(amount)]));

// Soroswap: swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline).
function swapCall(amount: bigint, minOut = 1n, to = user, contract = ROUTER) {
  return call(contract, "swap_exact_tokens_for_tokens", [i128(amount), i128(minOut), xdr.ScVal.scvVec([addr(XLM), addr(USDC)]), addr(to), u64(9n)]);
}
function swapOp(amount: bigint, authAmount: bigint, contract = ROUTER, creds?: xdr.SorobanCredentials) {
  const ic = swapCall(amount, 1n, user, contract);
  const t = pull(XLM, contract, authAmount);
  const entry = creds ? new xdr.SorobanAuthorizationEntry({ credentials: creds, rootInvocation: inv(ic, [t]) }) : src(inv(ic, [t]));
  return Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(ic), auth: [entry] });
}
const swapIntent = (spend: bigint, contract = ROUTER, minOut = 1n): Intent => ({
  kind: "swap",
  summary: "",
  spend: { [XLM]: spend.toString() },
  receive: { [USDC]: minOut.toString() },
  calls: [{ contract, fn: "swap_exact_tokens_for_tokens" }],
});
const payIntent = (amount: string, to = friend): Intent => ({ kind: "payment", summary: "", spend: { [XLM]: amount }, ops: ["payment"], to });
const pay = (amount: string, destination = friend, source?: string) => Operation.payment({ destination, asset: Asset.native(), amount, source });
const callIntent = (kind: string, contract: string, fn: string, spend: Record<string, string> = {}, extra: Partial<Intent> = {}): Intent => ({
  kind,
  summary: "",
  spend,
  calls: [{ contract, fn }],
  ...extra,
});
const activateOps = (startingBalance = "0") => [
  Operation.createAccount({ destination: user, startingBalance }),
  Operation.beginSponsoringFutureReserves({ sponsoredId: user }),
  Operation.changeTrust({ asset: USDC_ASSET, source: user }),
  Operation.endSponsoringFutureReserves({ source: user }),
];
const activateIntent: Intent = {
  kind: "activate",
  summary: "",
  spend: {},
  ops: ["createAccount", "beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"],
  trust: [USDC_SPEC],
};
const sponsoredTrust = (asset: Asset) => [
  Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }),
  Operation.changeTrust({ asset, source: user }),
  Operation.endSponsoringFutureReserves({ source: user }),
];
const trustIntent: Intent = { kind: "trust", summary: "", spend: {}, ops: ["changeTrust"], trust: [USDC_SPEC] };
// Footprint keys a restore may name.
const instanceKey = (contract: string) =>
  xdr.LedgerKey.contractData(new xdr.LedgerKeyContractData({ contract: new Address(contract).toScAddress(), key: xdr.ScVal.scvLedgerKeyContractInstance(), durability: xdr.ContractDataDurability.persistent() }));
const balanceKey = (token: string) =>
  xdr.LedgerKey.contractData(
    new xdr.LedgerKeyContractData({ contract: new Address(token).toScAddress(), key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("Balance"), addr(user)]), durability: xdr.ContractDataDurability.persistent() }),
  );
const codeKey = (hex: string) => xdr.LedgerKey.contractCode(new xdr.LedgerKeyContractCode({ hash: Buffer.from(hex, "hex") }));
const restoreIntent = (kind = "restore"): Intent => ({ kind, summary: "", spend: {}, ops: ["restoreFootprint"] });
// A starter swap's stand-in: six payments, so that the classic inclusion cap (6 × 0.02 XLM) is above
// starterInnerFeeMax, declaring `fee` in all.
const sixPayments = (fee: number) => withFee(tx(Array.from({ length: 6 }, () => pay("1"))), fee);
const starterIntent = payIntent("60000000");

type Synthetic = [string, Transaction, Intent, Omit<Partial<Judged>, "name" | "tx" | "intent">?];
const syn: Synthetic[] = [
  // Source, expiry, operations, auth and outflow.
  ["swap within cap", tx([swapOp(100n, 100n)]), swapIntent(100n)],
  ["swap auth over cap", tx([swapOp(100n, 101n)]), swapIntent(100n)],
  ["contract not pinned", tx([swapOp(100n, 100n, EVIL)]), swapIntent(100n, EVIL)],
  ["function not in intent", tx([swapOp(100n, 100n)]), { ...swapIntent(100n), calls: [{ contract: ROUTER, fn: "add_liquidity" }] }],
  [
    "address credentials",
    tx([swapOp(100n, 100n, ROUTER, xdr.SorobanCredentials.sorobanCredentialsAddress(new xdr.SorobanAddressCredentials({ address: new Address(user).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 10, signature: xdr.ScVal.scvVoid() })))]),
    swapIntent(100n),
  ],
  ["undeclared asset", tx([swapOp(100n, 100n)]), { ...swapIntent(100n), spend: { [USDC]: "100" } }],
  ["other source", tx([swapOp(1n, 1n)], { source: sponsor }), swapIntent(1n)],
  ["muxed source", tx([swapOp(1n, 1n)], { source: new MuxedAccount(new Account(user, "41"), "5") }), swapIntent(1n)],
  ["long expiry", tx([swapOp(1n, 1n)], { maxTime: NOW + 7_200 }), swapIntent(1n)],
  ["set options", tx([Operation.setOptions({ masterWeight: 0 })]), { kind: "x", summary: "", spend: {}, ops: ["payment"] }],
  ["payment ok", tx([pay("5")]), payIntent("50000000")],
  ["payment over", tx([pay("5.0000001")]), payIntent("50000000")],
  ["third account op", tx([pay("1", friend, third)]), payIntent("50000000")],
  ["path payment ok", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: USDC_ASSET, destMin: "0.9", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["path payment low min", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: USDC_ASSET, destMin: "0.8", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["path payment elsewhere", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: sponsor, destAsset: USDC_ASSET, destMin: "0.9", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["create account for friend", tx([Operation.createAccount({ destination: friend, startingBalance: "2" })]), { kind: "payment", summary: "", spend: { [XLM]: "20000000" }, ops: ["createAccount"], to: friend }],
  ["create account for another", tx([Operation.createAccount({ destination: third, startingBalance: "2" })]), { kind: "payment", summary: "", spend: { [XLM]: "20000000" }, ops: ["createAccount"], to: friend }],

  // Fee caps (§4.4).
  ["classic fee at the cap ok", tx([pay("1")], { fee: "200000" }), payIntent("10000000")],
  ["inclusion over the cap", tx([pay("1")], { fee: "200001" }), payIntent("10000000")],
  ["two operations at the cap ok", tx([pay("1"), pay("1")], { fee: "200000" }), payIntent("20000000")],
  ["soroban fee at the caps ok", tx([swapOp(100n, 100n)], { fee: "200000", soroban: resources(29_800_000) }), swapIntent(100n)],
  ["soroban fee over the cap", tx([swapOp(100n, 100n)], { fee: "200001", soroban: resources(29_800_000) }), swapIntent(100n)],
  ["soroban inclusion over the cap", tx([swapOp(100n, 100n)], { fee: "200001", soroban: resources(1_000_000) }), swapIntent(100n)],
  ["resource fee above fee", withFee(tx([swapOp(100n, 100n)], { soroban: resources(500_000) }), 400_000), swapIntent(100n)],

  // The sponsor only in an activation (§4.3, §4.4 rule 4).
  ["activate ok", tx(activateOps(), { source: sponsor }), activateIntent, { step: { feePayer: "sponsor", sponsorReason: "setup" } }],
  ["activate funds XLM", tx(activateOps("5"), { source: sponsor }), activateIntent],
  ["sponsor outside activation", tx(sponsoredTrust(USDC_ASSET)), { ...trustIntent, ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"] }],
  ["sponsor pays out in activation", tx([Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }), Operation.payment({ destination: user, asset: Asset.native(), amount: "1", source: sponsor })]), { ...activateIntent, ops: ["beginSponsoringFutureReserves", "payment"] }],
  ["user-paid trust ok", tx([Operation.changeTrust({ asset: USDC_ASSET })]), trustIntent, { step: { feePayer: "user", sponsorReason: null } }],
  ["trust undeclared asset", tx([Operation.changeTrust({ asset: new Asset("EVIL", sponsor) })]), trustIntent],
  ["trust removed", tx([Operation.changeTrust({ asset: USDC_ASSET, limit: "0" })]), trustIntent],
  ["trust with a negative limit", withLimit(tx([Operation.changeTrust({ asset: USDC_ASSET })]), -1n), trustIntent],

  // Destinations and memos (§5.2).
  ["payment to another destination", tx([pay("5", third)]), payIntent("50000000")],
  ["payment without a confirmed destination", tx([pay("5")]), { ...payIntent("50000000"), to: undefined }],
  ["payment to a muxed destination", tx([pay("5", new MuxedAccount(new Account(friend, "0"), "7").accountId())]), payIntent("50000000")],
  ["memo text ok", tx([pay("5")], { memo: Memo.text("invoice 42") }), { ...payIntent("50000000"), memo: { type: "text", value: "invoice 42" } }],
  ["memo id ok", tx([pay("5")], { memo: Memo.id("18446744073709551615") }), { ...payIntent("50000000"), memo: { type: "id", value: "18446744073709551615" } }],
  ["memo hash ok", tx([pay("5")], { memo: Memo.hash("ab".repeat(32)) }), { ...payIntent("50000000"), memo: { type: "hash", value: "AB".repeat(32) } }],
  ["memo mismatch", tx([pay("5")], { memo: Memo.text("invoice 42") }), { ...payIntent("50000000"), memo: { type: "text", value: "invoice 43" } }],
  ["memo type mismatch", tx([pay("5")], { memo: Memo.id("42") }), { ...payIntent("50000000"), memo: { type: "text", value: "42" } }],
  ["memo the intent doesn't have", tx([pay("5")], { memo: Memo.text("hi") }), payIntent("50000000")],
  ["memo missing", tx([pay("5")]), { ...payIntent("50000000"), memo: { type: "text", value: "hi" } }],
  [
    "SAC transfer ok",
    tx([invoke(call(USDC, "transfer", [addr(user), addr(friend), i128(100n)]))]),
    callIntent("payment", USDC, "transfer", { [USDC]: "100" }, { to: friend }),
  ],
  [
    "SAC transfer to another to",
    tx([invoke(call(USDC, "transfer", [addr(user), addr(third), i128(100n)]))]),
    callIntent("payment", USDC, "transfer", { [USDC]: "100" }, { to: friend }),
  ],
  [
    "launch token transfer ok",
    tx([invoke(call(TOKEN, "transfer", [addr(user), addr(friend), i128(100n)]))]),
    callIntent("payment", TOKEN, "transfer", { [TOKEN]: "100" }, { to: friend }),
    { launchTokens: [TOKEN] },
  ],
  [
    "SAC transfer to a muxed address",
    tx([invoke(call(USDC, "transfer", [addr(user), addr(new MuxedAccount(new Account(friend, "0"), "7").accountId()), i128(100n)]))]),
    callIntent("payment", USDC, "transfer", { [USDC]: "100" }, { to: friend }),
  ],
  [
    "SAC transfer to a muxed address without a confirmed destination",
    tx([invoke(call(USDC, "transfer", [addr(user), addr(new MuxedAccount(new Account(friend, "0"), "7").accountId()), i128(100n)]))]),
    callIntent("payment", USDC, "transfer", { [USDC]: "100" }),
  ],
  [
    "transfer in another root to another account",
    tx([invoke(swapCall(100n), [pull(XLM, ROUTER, 100n)], [src(pull(USDC, third, 5n))])]),
    { ...swapIntent(100n), spend: { [XLM]: "100", [USDC]: "5" }, to: friend },
  ],

  // Call rules (§5.2).
  ["soroswap to another account", tx([invoke(swapCall(100n, 1n, third), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n)],
  ["soroswap min below receive", tx([invoke(swapCall(100n, 9n), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n, ROUTER, 10n)],
  ["soroswap min at receive ok", tx([invoke(swapCall(100n, 10n), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n, ROUTER, 10n)],
  ["soroswap without a quoted minimum", tx([invoke(swapCall(100n, 10n), [pull(XLM, ROUTER, 100n)])]), { ...swapIntent(100n), receive: undefined }],
  ...(() => {
    const chain = (out: string) => xdr.ScVal.scvVec([xdr.ScVal.scvVec([xdr.ScVal.scvVec([addr(XLM), addr(USDC)]), xdr.ScVal.scvBytes(Buffer.alloc(32, 3)), addr(out)])]);
    const aqua = (who: string, outMin: bigint) => call(AQUARIUS, "swap_chained", [addr(who), chain(USDC), addr(XLM), u128(100n), u128(outMin)]);
    const intent = { ...callIntent("swap", AQUARIUS, "swap_chained", { [XLM]: "100" }), receive: { [USDC]: "10" } };
    return [
      ["aquarius swap ok", tx([invoke(aqua(user, 10n), [pull(XLM, AQUARIUS, 100n)])]), intent],
      ["aquarius out_min below receive", tx([invoke(aqua(user, 9n), [pull(XLM, AQUARIUS, 100n)])]), intent],
      ["aquarius for another user", tx([invoke(aqua(third, 10n), [pull(XLM, AQUARIUS, 100n)])]), intent],
    ] as Synthetic[];
  })(),
  ...(() => {
    const buy = (who: string, minOut: bigint) => call(LAUNCHPAD, "buy", [addr(who), addr(TOKEN), i128(1_000n), i128(minOut)]);
    const sell = (minOut: bigint) => call(LAUNCHPAD, "sell", [addr(user), addr(TOKEN), i128(500n), i128(minOut)]);
    const buyIntent = callIntent("launch_buy", LAUNCHPAD, "buy", { [XLM]: "1000" }, { receive: { [TOKEN]: "4000" } });
    const sellIntent = callIntent("launch_sell", LAUNCHPAD, "sell", { [TOKEN]: "500" }, { receive: { [XLM]: "90" } });
    const launch = call(LAUNCHPAD, "launch", [addr(user), addr(XLM), str("Deploy"), str("DPLY"), str("https://x.test/m.json"), u32(100), i128(0n), i128(0n)]);
    return [
      ["curve buy ok", tx([invoke(buy(user, 4_000n), [pull(XLM, LAUNCHPAD, 1_000n)])]), buyIntent],
      ["curve buy min_tokens_out below receive", tx([invoke(buy(user, 3_999n), [pull(XLM, LAUNCHPAD, 1_000n)])]), buyIntent],
      ["curve buy for another trader", tx([invoke(buy(third, 4_000n), [pull(XLM, LAUNCHPAD, 1_000n)])]), buyIntent],
      ["curve sell ok", tx([invoke(sell(90n), [pull(TOKEN, LAUNCHPAD, 500n)])]), sellIntent],
      ["curve sell min below receive", tx([invoke(sell(89n), [pull(TOKEN, LAUNCHPAD, 500n)])]), sellIntent],
      ["launch create ok", tx([invoke(launch)]), callIntent("launch_create", LAUNCHPAD, "launch")],
      ["graduate ok", tx([invoke(call(LAUNCHPAD, "graduate", [addr(TOKEN)]))]), callIntent("launch_graduate", LAUNCHPAD, "graduate")],
      ["claim creator fees ok", tx([invoke(call(LAUNCHPAD, "claim_creator_fees", [addr(TOKEN)]))]), callIntent("launch_claim", LAUNCHPAD, "claim_creator_fees")],
      ["curve call with missing arguments", tx([invoke(call(LAUNCHPAD, "buy", [addr(user), addr(TOKEN), i128(1_000n)]))]), buyIntent],
    ] as Synthetic[];
  })(),
  ...(() => {
    const requests = xdr.ScVal.scvVec([
      xdr.ScVal.scvMap([
        new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("address"), val: addr(USDC) }),
        new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("amount"), val: i128(50n) }),
        new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("request_type"), val: u32(0) }),
      ]),
    ]);
    const submit = (to: string) => call(POOL, "submit", [addr(user), addr(user), addr(to), requests]);
    const intent = callIntent("earn_deposit", POOL, "submit", { [USDC]: "50" });
    return [
      ["blend submit ok", tx([invoke(submit(user), [pull(USDC, POOL, 50n)])]), intent],
      ["blend submit to another account", tx([invoke(submit(third), [pull(USDC, POOL, 50n)])]), intent],
    ] as Synthetic[];
  })(),
  ...(() => {
    const burn = (domain: number, recipient: string) =>
      call(MESSENGER, "deposit_for_burn", [
        addr(user),
        i128(70n),
        u32(domain),
        xdr.ScVal.scvBytes(Buffer.concat([Buffer.alloc(12), Buffer.from(recipient.slice(2), "hex")])),
        addr(USDC),
        xdr.ScVal.scvBytes(Buffer.alloc(32)),
        i128(0n),
        u32(2000),
      ]);
    const intent = callIntent("bridge_out", MESSENGER, "deposit_for_burn", { [USDC]: "70" }, { to: MONAD_USER });
    const approve = (spender: string) => call(USDC, "approve", [addr(user), addr(spender), i128(70n), u32(100)]);
    return [
      ["cctp burn ok", tx([invoke(burn(MONAD_DOMAIN, MONAD_USER), [pull(USDC, MESSENGER, 70n)])]), intent],
      ["cctp burn to another mint recipient", tx([invoke(burn(MONAD_DOMAIN, "0x" + "34".repeat(20)), [pull(USDC, MESSENGER, 70n)])]), intent],
      ["cctp burn to another domain", tx([invoke(burn(MONAD_DOMAIN + 1, MONAD_USER), [pull(USDC, MESSENGER, 70n)])]), intent],
      ["cctp approve ok", tx([invoke(approve(MESSENGER))]), callIntent("approve", USDC, "approve", { [USDC]: "70" })],
      ["approve for an unpinned spender", tx([invoke(approve(EVIL))]), callIntent("approve", USDC, "approve", { [USDC]: "70" })],
    ] as Synthetic[];
  })(),
  ...(() => {
    const collect = (who: string) => call(MOMENTS, "collect", [addr(who), u32(1), u32(2), i128(20_000n)]);
    const publish = call(MOMENTS, "publish", [addr(user), str("https://x.test/m.json"), i128(10_000n), addr(USDC), u32(100), u64(86_400n)]);
    const intent = callIntent("moment_collect", MOMENTS, "collect", { [USDC]: "20000" });
    return [
      ["moments collect ok", tx([invoke(collect(user), [pull(USDC, MOMENTS, 20_000n)])]), intent],
      ["moments collect for another collector", tx([invoke(collect(third), [pull(USDC, MOMENTS, 20_000n)])]), intent],
      ["moments publish ok", tx([invoke(publish)]), callIntent("moment_publish", MOMENTS, "publish")],
    ] as Synthetic[];
  })(),
  ["function without a rule", tx([invoke(call(ROUTER, "add_liquidity", [addr(user)]))]), callIntent("swap", ROUTER, "add_liquidity")],

  // Where a decoder or a comparison could tell the verifiers apart: an authorization is of the call itself only byte for
  // byte (a twin root that differs only in a string's Unicode normalization or an error's code holds a transfer to
  // another account), and a function name is read as written.
  ...(() => {
    const launch = (name: xdr.ScVal, uri: xdr.ScVal) =>
      call(LAUNCHPAD, "launch", [addr(user), addr(XLM), name, str("DPLY"), uri, u32(100), i128(0n), i128(0n)]);
    const uri = str("https://x.test/m.json");
    const withTwin = (ic: xdr.InvokeContractArgs, twin: xdr.InvokeContractArgs) => tx([invoke(ic, [], [src(inv(twin, [pull(USDC, third, 5n)]))])]);
    const error = (code: number) => xdr.ScVal.scvError(xdr.ScError.sceContract(code));
    const intent = callIntent("launch_create", LAUNCHPAD, "launch", { [USDC]: "5" }, { to: friend });
    return [
      ["auth root that is the call in another normalization", withTwin(launch(str("Caf\u00e9"), uri), launch(str("Cafe\u0301"), uri)), intent],
      ["auth root that is the call with another error code", withTwin(launch(str("Deploy"), error(1)), launch(str("Deploy"), error(2))), intent],
      [
        "call to a function name with a byte-order mark",
        tx([invoke(call(USDC, "\ufefftransfer", [addr(user), addr(friend), i128(100n)]))]),
        callIntent("payment", USDC, "transfer", { [USDC]: "100" }, { to: friend }),
      ],
    ] as Synthetic[];
  })(),

  // Restores (§4.9).
  ["restore ok", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [instanceKey(LAUNCHPAD), balanceKey(TOKEN), codeKey(WASM)]) }), restoreIntent(), { launchTokens: [TOKEN] }],
  ["restore with a footprint outside the allowlist", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [instanceKey(LAUNCHPAD), balanceKey(EVIL)]) }), restoreIntent()],
  ["restore of another WASM", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [codeKey("cd".repeat(32))]) }), restoreIntent()],
  ["restore outside its own intent", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [instanceKey(LAUNCHPAD)]) }), restoreIntent("swap")],
  // Any other step's footprint plays no part in the checks, unpinned contracts and all.
  [
    "soroban swap with a footprint ok",
    tx([invoke(swapCall(100n, 10n), [pull(XLM, ROUTER, 100n)])], { soroban: resources(50_000, [instanceKey(ROUTER), instanceKey(PAIR)]) }),
    swapIntent(100n, ROUTER, 10n),
  ],

  // Who pays (§4.3): the verifier accepts these; verifyFeePayer and PlanFees decide.
  ["starter step within the cap", sixPayments(1_000_000), starterIntent, { step: { feePayer: "sponsor", sponsorReason: "starter_swap" } }],
  ["starter step with an inner fee above the cap", sixPayments(1_000_001), starterIntent, { step: { feePayer: "sponsor", sponsorReason: "starter_swap" } }],
  ["setup flag on a user's transaction", tx([pay("1")]), payIntent("10000000"), { step: { feePayer: "sponsor", sponsorReason: "setup" } }],
];
{
  const ic = call(USDC, "approve", [addr(user), addr(ROUTER), i128(500n), u32(100)]);
  syn.push(["approve counts in full", tx([invoke(ic)]), callIntent("approve", USDC, "approve", { [USDC]: "499" })]);
  syn.push(["approve within cap", tx([invoke(ic)]), callIntent("approve", USDC, "approve", { [USDC]: "500" })]);
}
for (const [name, t, intent, extra] of syn) {
  vectors.push(judge({ name, tx: t, intent, user, sponsor, allowed: pinned, now: NOW, ...extra }));
}

await Deno.mkdir(out, { recursive: true });
await Deno.writeTextFile(`${out}verifier.json`, JSON.stringify(vectors, null, 1) + "\n");

// ------------------------------------------------------------------------------------------------ keys & ids
const msg = "DyorHQ Lite sign-in\nNetwork: testnet\nAddress: " + user + "\nNonce: abc\nIssued: 2026-10-11T00:00:00Z";
const sep53 = userKp.sign(Buffer.from(await sha256(SEP53_PREFIX + msg))).toString("base64");
const keys = {
  sep5: [
    { mnemonic: "illness spike retreat truth genius clock brain pass fit cave bargain toe", index: 0, address: "GDRXE2BQUC3AZNPVFSCEZ76NJ3WWL25FYFK6RGZGIEKWE4SOOHSUJUJ6", secret: "SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN" },
  ],
  sep53: { secret: userKp.secret(), message: msg, signature: sep53 },
  sac: [
    { asset: "native", network: "testnet", id: XLM },
    { asset: `USDC:${USDC_ASSET.getIssuer()}`, network: "testnet", id: USDC },
    { asset: "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN", network: "mainnet", id: new Asset("USDC", "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN").contractId("Public Global Stellar Network ; September 2015") },
  ],
};
await Deno.writeTextFile(`${out}keys.json`, JSON.stringify(keys, null, 1));
console.log(`wrote ${vectors.length} verifier vectors (${vectors.filter((v) => v.expect.ok).length} ok) and key vectors to ${out}`);
