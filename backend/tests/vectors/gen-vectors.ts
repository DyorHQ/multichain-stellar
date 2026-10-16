// Generates the cross-language test vectors the Swift verifier (StellarCore) must agree with
// (docs/DESIGN-stellar-parity.md §12.4):
// - real transactions the API built during the testnet e2e run (read from the plans table), judged as they are;
// - synthetic ones built here, one per rule, judged by the TS verifier: its verdict, reason and outflow, and for a step
//   with a fee payer, who pays (verifyFeePayer);
// - key derivation, SEP-53, StrKey and SAC id vectors.
// Every vector carries the pins it was judged with (the contracts, v2's roles, runtime WASM hashes, durations and
// launch-fee bound, the fee caps), the runtime contracts the phone read with their WASM hashes, and what stellar-sdk
// decoded (source, fee, memo, …), so the Swift decoder is checked too. The synthetic v2 vectors are judged against a
// fixture deployment (V2_FIXTURE, the shape of deploy-contracts-v2.ts's deploymentRecord()), never the owner's file,
// so a redeploy changes none of them; the real ones against LITE_DEPLOYMENT's.
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
import { DURATION_SETS_V2, parseDeploymentV2 } from "../../supabase/functions/_shared/deployments/index.ts";
import { contractAllowlist, NetworkConfig, TESTNET, withDeployment, withDeploymentV2 } from "../../supabase/functions/_shared/networks.ts";
import { FeeCaps, Intent, runtimeWasmHashOf, V2PinSource, v2Pins, verifyFeePayer, verifyTransaction } from "../../supabase/functions/_shared/verify.ts";
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

/** v2's pins as a vector carries them: what the app pins (PinnedContracts), so never testnet-qa's test contracts. */
interface VectorV2 extends V2PinSource {
  maxLaunchFeeStroops: string;
}

interface Vector {
  name: string;
  envelope: string;
  intent: Intent;
  user: string;
  sponsor: string;
  /** Pinned contracts, v2's singletons included. */
  allowed: string[];
  /** Launch tokens the phone verified on chain (their WASM is the pinned one). */
  launchTokens: string[];
  launchTokenWasmHash: string;
  monadDomain: number;
  feePolicy: { maxFee: string; maxInclusionPerOp: string; starterInnerFeeMax: string };
  /** v2's pins; null where v2 isn't deployed. */
  v2: VectorV2 | null;
  /** Contracts v2 created at runtime, with the WASM hash the phone read for each from the chain. */
  runtime: Record<string, string>;
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

/** What a vector is judged against: the contracts the app pins, and v2's pins. */
interface Pins {
  allowed: string[];
  v2: VectorV2 | null;
}

/** `net`'s pins as the app has them: contractAllowlist's roles (never testnet-qa's test contracts, finding F4) and v2's
 *  roles, runtime WASM hashes, durations and launch-fee bound. */
function pinsOf(net: NetworkConfig): Pins {
  const d = net.deploymentV2;
  return {
    allowed: Object.values(contractAllowlist(net)).flat(),
    v2: d
      ? {
        contracts: d.contracts,
        runtimeWasmHashes: d.runtimeWasmHashes,
        durations: { launch: d.durations.launch, moments: d.durations.moments },
        maxLaunchFeeStroops: net.maxLaunchFeeStroops.toString(),
      }
      : null,
  };
}

interface Judged {
  name: string;
  tx: Transaction;
  intent: Intent;
  user: string;
  sponsor: string;
  pins: Pins;
  launchTokens?: string[];
  runtime?: Record<string, string>;
  now: number;
  step?: Step;
}

function judge(j: Judged): Vector {
  const launchTokens = j.launchTokens ?? [];
  const runtime = j.runtime ?? {};
  const v2 = j.pins.v2;
  const ctx = {
    user: j.user,
    sponsor: j.sponsor,
    passphrase: PASS,
    allowedContracts: new Set([...j.pins.allowed, ...launchTokens]),
    now: j.now,
    feePolicy: FEES,
    launchTokenWasmHash: WASM,
    monadDomain: MONAD_DOMAIN,
    v2: v2 ? v2Pins(v2, BigInt(v2.maxLaunchFeeStroops)) : null,
    runtimeContracts: runtime,
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
    allowed: j.pins.allowed,
    launchTokens,
    launchTokenWasmHash: WASM,
    monadDomain: MONAD_DOMAIN,
    feePolicy: { maxFee: FEES.maxFee.toString(), maxInclusionPerOp: FEES.maxInclusionPerOp.toString(), starterInnerFeeMax: FEES.starterInnerFeeMax.toString() },
    v2,
    runtime,
    now: j.now,
    ...(j.step ? { step: j.step } : {}),
    expect,
    decoded: decodedOf(j.tx),
  };
}

const vectors: Vector[] = [];

// ------------------------------------------------------------------------------------------------ real transactions
const dbUrl = Deno.env.get("LITE_DB_URL");
if (dbUrl && !syntheticOnly) {
  const db = postgres(dbUrl, { onnotice: () => {} });
  const sponsor = Deno.env.get("SPONSOR_PUBLIC")!;
  const live = pinsOf(withDeployment(TESTNET, Deno.env.get("LITE_DEPLOYMENT") ?? "testnet"));
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
      vectors.push(judge({ name: `real ${key}`, tx, intent: s.intent, user: p.address as string, sponsor, pins: live, launchTokens: launches, now, step }));
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
const addrVal = addr;
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

// The authorization tree holds only the call itself and the user's own token spends beneath it: a nested call that is
// not a spend (a Blend withdrawal to a third party), a second root (any call, a token transfer to the confirmed
// address included) or a spend of another account's tokens is refused, whatever the outflow.
{
  const withdraw = call(POOL, "submit", [addr(user), addr(user), addr(third), xdr.ScVal.scvVec([])]);
  const pathSwap = (path: string[], minOut = 1n) => call(ROUTER, "swap_exact_tokens_for_tokens", [i128(100n), i128(minOut), xdr.ScVal.scvVec(path.map(addr)), addr(user), u64(9n)]);
  /** A token nobody pins: anyone can open a Soroswap pair for it, so a route through it runs its code. */
  const UNLISTED = StrKey.encodeContract(Buffer.alloc(32, 0x55));
  const aqua = (hops: [string, string, string][], outMin = 10n) =>
    call(AQUARIUS, "swap_chained", [
      addr(user),
      xdr.ScVal.scvVec(hops.map(([a, b, out]) => xdr.ScVal.scvVec([xdr.ScVal.scvVec([addr(a), addr(b)]), xdr.ScVal.scvBytes(Buffer.alloc(32, 3)), addr(out)]))),
      addr(XLM),
      u128(100n),
      u128(outMin),
    ]);
  const aquaIntent = (min = "10") => ({ ...callIntent("swap", AQUARIUS, "swap_chained", { [XLM]: "100" }), receive: { [USDC]: min } });
  syn.push(
    ["swap with a non-token call nested under its own authorization", tx([invoke(swapCall(100n), [pull(XLM, ROUTER, 100n), inv(withdraw)])]), swapIntent(100n)],
    ["swap with a non-token call nested under a token spend", tx([invoke(swapCall(100n), [inv(call(XLM, "transfer", [addr(user), addr(ROUTER), i128(100n)]), [inv(withdraw)])])]), swapIntent(100n)],
    ["swap with a second root authorizing another call", tx([invoke(swapCall(100n), [pull(XLM, ROUTER, 100n)], [src(inv(withdraw))])]), swapIntent(100n)],
    ["swap with a second root transferring to the confirmed address", tx([invoke(swapCall(100n), [pull(XLM, ROUTER, 100n)], [src(pull(USDC, friend, 5n))])]), { ...swapIntent(100n), spend: { [XLM]: "100", [USDC]: "5" }, to: friend }],
    ["swap with a nested spend of another account's tokens", tx([invoke(swapCall(100n), [pull(XLM, ROUTER, 100n), inv(call(USDC, "transfer", [addr(third), addr(friend), i128(5n)]))])]), swapIntent(100n)],
    ["swap with a nested spend with extra arguments", tx([invoke(swapCall(100n), [inv(call(XLM, "transfer", [addr(user), addr(ROUTER), i128(100n), u32(1)]))])]), swapIntent(100n)],
    ["blend submit with a nested withdrawal", tx([invoke(call(POOL, "submit", [addr(user), addr(user), addr(user), xdr.ScVal.scvVec([])]), [pull(USDC, POOL, 50n), inv(withdraw)])]), callIntent("earn_deposit", POOL, "submit", { [USDC]: "50" })],
    // Every token a swap's route runs is listed; the token sold and the token bought may be the user's own choice.
    ["soroswap through an unlisted middle token", tx([invoke(pathSwap([XLM, UNLISTED, USDC]), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n)],
    ["soroswap through a listed middle token ok", tx([invoke(pathSwap([XLM, USDC, USDC]), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n)],
    ["soroswap to an unlisted token the intent quotes ok", tx([invoke(pathSwap([XLM, USDC, UNLISTED]), [pull(XLM, ROUTER, 100n)])]), { ...swapIntent(100n), receive: { [UNLISTED]: "1" } }],
    ["soroswap to an unlisted token the intent doesn't quote", tx([invoke(pathSwap([XLM, UNLISTED]), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n)],
    ["soroswap from an unlisted token the intent spends ok", tx([invoke(pathSwap([UNLISTED, XLM, USDC]), [pull(UNLISTED, ROUTER, 100n)])]), { ...swapIntent(100n), spend: { [UNLISTED]: "100" } }],
    ["aquarius through an unlisted hop token", tx([invoke(aqua([[XLM, UNLISTED, UNLISTED], [UNLISTED, USDC, USDC]]), [pull(XLM, AQUARIUS, 100n)])]), aquaIntent()],
    ["aquarius through listed hops ok", tx([invoke(aqua([[XLM, USDC, USDC], [USDC, XLM, USDC]]), [pull(XLM, AQUARIUS, 100n)])]), aquaIntent()],
    // A trade's minimum is positive wherever the call encodes one, whatever the intent quotes; a path payment needs one.
    ["soroswap with no minimum", tx([invoke(pathSwap([XLM, USDC], 0n), [pull(XLM, ROUTER, 100n)])]), swapIntent(100n, ROUTER, 0n)],
    ["aquarius with no minimum", tx([invoke(aqua([[XLM, USDC, USDC]], 0n), [pull(XLM, AQUARIUS, 100n)])]), aquaIntent("0")],
    [
      "curve buy with no minimum",
      tx([invoke(call(LAUNCHPAD, "buy", [addr(user), addr(TOKEN), i128(1_000n), i128(0n)]), [pull(XLM, LAUNCHPAD, 1_000n)])]),
      callIntent("launch_buy", LAUNCHPAD, "buy", { [XLM]: "1000" }, { receive: { [TOKEN]: "0" } }),
    ],
    [
      "curve sell with no minimum",
      tx([invoke(call(LAUNCHPAD, "sell", [addr(user), addr(TOKEN), i128(500n), i128(0n)]), [pull(TOKEN, LAUNCHPAD, 500n)])]),
      callIntent("launch_sell", LAUNCHPAD, "sell", { [TOKEN]: "500" }, { receive: { [XLM]: "0" } }),
    ],
    [
      "path payment without a quoted minimum",
      tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: USDC_ASSET, destMin: "0.9", path: [] })]),
      { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, ops: ["pathPaymentStrictSend"] },
    ],
  );
}

// ------------------------------------------------------------------------------------------------ v2 (§20.4)
// Judged against V2_FIXTURE's pins: launchpad-v2, moments-v2, the lp-locker, exec-soroswap and the graduator, and the
// runtime WASM hashes of launch-token-v2, moment-nft and moment-coin. Aquarius is off (decision O7), and qa-exec-fail
// exists only on testnet-qa, so the testnet pins name neither.
const fixed = (n: number) => StrKey.encodeContract(Buffer.alloc(32, n));
const V2_FIXTURE = parseDeploymentV2("testnet-v2", {
  network: "testnet",
  deployment: "testnet",
  name: "testnet-v2",
  generation: 1,
  deployer: Keypair.fromRawEd25519Seed(Buffer.alloc(32, 11)).publicKey(),
  contracts: { launchpadV2: fixed(0x41), momentsV2: fixed(0x42), lpLocker: fixed(0x43), execSoroswap: fixed(0x44), momentsGraduator: fixed(0x45) },
  wasmHashes: {
    launchpadV2: "b1".repeat(32),
    launchTokenV2: "a1".repeat(32),
    execSoroswap: "b2".repeat(32),
    lpLocker: "b3".repeat(32),
    momentsV2: "b4".repeat(32),
    momentNft: "a2".repeat(32),
    momentCoin: "a3".repeat(32),
    momentsGraduator: "b5".repeat(32),
  },
  venues: [{ id: 0, kind: "Soroswap", executor: fixed(0x44), feeFraction: 0, enabled: true }],
  quotes: {},
  aquarius: { enabled: false, reason: "--aquarius off" },
  durations: { set: "production", launch: DURATION_SETS_V2.production.launch, moments: DURATION_SETS_V2.production.moments },
  ttl: { threshold: 120_960, extend_to: 518_400 },
  deployLedger: 1_000,
  deployedAt: "2026-10-15T00:00:00.000Z",
});
const SYNTHETIC = pinsOf(withDeploymentV2(TESTNET, V2_FIXTURE));
{
  const { launchpadV2: PAD2, momentsV2: MOMENTS2, lpLocker: LOCKER2, execSoroswap: EXEC2, momentsGraduator: GRADUATOR } = V2_FIXTURE.contracts;
  const HASHES = V2_FIXTURE.runtimeWasmHashes;
  const LAUNCH_DURATIONS = V2_FIXTURE.durations.launch;
  const MOMENTS_DURATIONS = V2_FIXTURE.durations.moments;
  /** A VenueInfo: its id, its kind (dyor_common::VenueKind: Soroswap 0, QaFail 3) and its executor. */
  type Venue = { id: number; kind: number; executor: string };
  const soroswap = (executor: string): Venue => ({ id: 0, kind: 0, executor });
  /** testnet-qa's failing venue as its deployment lists it (id 1, after Soroswap's; Aquarius is off): a real executor
   *  there, unknown to the testnet pins. */
  const QA_VENUE: Venue = { id: 1, kind: 3, executor: fixed(0x46) };
  /** A v2 launch token, a Moment's NFT and coin (runtime contracts), a graduated launch's pool. */
  const TOKEN2 = fixed(0x47);
  const NFT = fixed(0x48);
  const COIN = fixed(0x49);
  const POOL2 = fixed(0x4a);
  /** A contract whose WASM is no pinned one. */
  const STRANGER = fixed(0x4b);
  const UNKNOWN_WASM = "ee".repeat(32);
  const TREASURY = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 10)).publicKey();
  const FEE = TESTNET.maxLaunchFeeStroops; // 10 XLM (decision O6)

  const bool = (b: boolean) => xdr.ScVal.scvBool(b);
  const bytes = (hex: string) => xdr.ScVal.scvBytes(Buffer.from(hex, "hex"));
  const vec = (items: xdr.ScVal[]) => xdr.ScVal.scvVec(items);
  /** A contract struct: a map with its fields' names as symbols, in order. */
  const struct = (fields: Record<string, xdr.ScVal>) =>
    xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));
  const durations = (d: object) => struct(Object.fromEntries(Object.entries(d).map(([k, v]) => [k, u64(BigInt(v))])));
  const venue = (v: Venue) => struct({ id: u32(v.id), kind: u32(v.kind), executor: addr(v.executor), params: struct({ fee_fraction: u32(0) }), enabled: bool(true) });
  /** A call no one's authorization covers: one anyone may make. */
  const bare = (ic: xdr.InvokeContractArgs) => Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(ic), auth: [] });
  const runtime = (contract: string, hash: string) => ({ runtime: { [contract]: hash } });

  // launch(creator, p: LaunchParams, expected: LaunchTerms) on launchpad-v2, quoted in XLM.
  type TermsChange = { fee?: bigint; venue?: Venue; fallback?: Venue; locker?: string; wasm?: string; durations?: object; feeAsset?: string };
  const terms = (o: TermsChange = {}) =>
    struct({
      supply: i128(10_000_000_000_000_000n),
      fee_bps: u32(100),
      protocol_share_bps: u32(5_000),
      max_creator_fee_bps: u32(1_000),
      snipe_schedule: vec([9_800, 2_500, 300, 30].map(u32)),
      snipe_step_secs: u32(5),
      launch_fee: i128(o.fee ?? FEE),
      fee_asset: addr(o.feeAsset ?? XLM),
      quote: addr(XLM),
      phantom: i128(20_000_000_000n),
      threshold: i128(43_245_553_200n),
      venue: venue(o.venue ?? soroswap(EXEC2)),
      fallback: venue(o.fallback ?? soroswap(EXEC2)),
      venue_locked: bool(false),
      locker: addr(o.locker ?? LOCKER2),
      token_wasm_hash: bytes(o.wasm ?? HASHES.launchTokenV2),
      durations: durations(o.durations ?? LAUNCH_DURATIONS),
    });
  type ParamsChange = { initialBuy?: bigint; minOut?: bigint; symbol?: string; venue?: number; recipient?: string; exempt?: string[]; creatorFeeBps?: number; holderSharing?: boolean };
  const params = (o: ParamsChange = {}) =>
    struct({
      quote: addr(XLM),
      name: str("Deploy"),
      symbol: str(o.symbol ?? "DPLY"),
      uri: str("https://x.test/m.json"),
      creator_fee_bps: u32(o.creatorFeeBps ?? 100),
      venue: u32(o.venue ?? 0),
      holder_sharing: bool(o.holderSharing ?? true),
      creator_fee_recipient: o.recipient ? addr(o.recipient) : xdr.ScVal.scvVoid(),
      snipe_exempt: vec((o.exempt ?? []).map(addr)),
      initial_buy: i128(o.initialBuy ?? 0n),
      min_tokens_out: i128(o.minOut ?? 0n),
      nonce: u64(7n),
    });
  /** A launch whose authorization pays `fee` of XLM to `feeTo` and then an initial buy of `buy` XLM to `buyTo`. */
  const launch = (o: { who?: string; terms?: TermsChange; params?: Parameters<typeof params>[0]; fee?: bigint; feeTo?: string; buy?: bigint; buyTo?: string } = {}) =>
    tx([
      invoke(call(PAD2, "launch", [addr(o.who ?? user), params(o.params), terms(o.terms)]), [
        ...((o.fee ?? FEE) > 0n ? [pull(XLM, o.feeTo ?? PAD2, o.fee ?? FEE)] : []),
        ...(o.buy ? [pull(XLM, o.buyTo ?? PAD2, o.buy)] : []),
      ]),
    ]);
  /** A launch's intent, showing what the user chose as launchpad_v2.ts's builder does: the creator-fee recipient (the
   *  user unless `to` names one), the snipe exemptions, the creator fee and holder sharing. */
  const launchIntent = (spend: bigint, receive?: Record<string, string>, o: { to?: string; display?: Record<string, string | number | boolean> } = {}) =>
    callIntent("launch_create", PAD2, "launch", { [XLM]: spend.toString() }, {
      ...(receive ? { receive } : {}),
      ...(o.to ? { to: o.to } : {}),
      display: { recipient: o.to ?? user, snipeExempt: "", creatorFeeBps: 100, holderSharing: true, ...o.display },
    });
  const BUY = 50_000_000n;
  const withBuy = { params: { initialBuy: BUY, minOut: 4_000n }, buy: BUY };

  // publish(creator, p: PublishParams, expected: MomentsTerms) on moments-v2.
  type MomentTermsChange = { graduator?: string; executor?: string; locker?: string; nft?: string; coin?: string; durations?: object };
  const momentTerms = (o: MomentTermsChange = {}) =>
    struct({
      policy: struct({
        threshold: i128(100_000_000n),
        min_price: i128(1_000_000n),
        creator_bps: u32(2_000),
        platform_bps: u32(500),
        reserve_bps: u32(7_500),
        max_creator_alloc_bps: u32(1_000),
        expiry_creator_bps: u32(7_000),
        royalty_bps: u32(500),
        platform: addr(third),
        treasury: addr(TREASURY),
      }),
      external_base: str("https://x.test/moments/"),
      nft_wasm_hash: bytes(o.nft ?? HASHES.momentNft),
      coin_wasm_hash: bytes(o.coin ?? HASHES.momentCoin),
      graduator: addr(o.graduator ?? GRADUATOR),
      executor: addr(o.executor ?? EXEC2),
      locker: addr(o.locker ?? LOCKER2),
      durations: durations(o.durations ?? MOMENTS_DURATIONS),
      harvest_bps: u32(6_667),
      harvest_creator_bps: u32(4_000),
    });
  const publishParams = (symbol = "DUSK") =>
    struct({
      name: str("Dusk"),
      symbol: str(symbol),
      metadata_uri: str("https://x.test/m.json"),
      media_hash: bytes("5a".repeat(32)),
      place: str("Lisbon"),
      date: str("2026-10-15"),
      price: i128(10_000_000n),
      creator_alloc_bps: u32(500),
      window_secs: u64(86_400n),
      nonce: u64(9n),
    });
  const publish = (o: { who?: string; terms?: MomentTermsChange; symbol?: string } = {}) =>
    tx([invoke(call(MOMENTS2, "publish", [addr(o.who ?? user), publishParams(o.symbol), momentTerms(o.terms)]))]);
  /** A publish's intent, showing the price, creator allocation and window as moments_v2.ts's builder does. */
  const publishIntent = (display: Record<string, string | number> = {}) =>
    callIntent("moment_publish", MOMENTS2, "publish", {}, { display: { price: "10000000", allocationBps: 500, windowSecs: 86_400, ...display } });
  const collect = (who: string, max: bigint, pulled = 20_000n) =>
    tx([invoke(call(MOMENTS2, "collect", [addr(who), addr(NFT), u32(2), i128(max)]), [pull(USDC, MOMENTS2, pulled)])]);
  const collectIntent = callIntent("moment_collect", MOMENTS2, "collect", { [USDC]: "20000" });

  const refund = (who: string) => tx([invoke(call(PAD2, "refund", [addr(who), addr(TOKEN2), i128(500n)]), [inv(call(TOKEN2, "burn", [addr(who), i128(500n)]))])]);
  const claimOwed = (who: string, signed = false) => {
    const ic = call(PAD2, "claim_owed", [addr(who), addr(XLM)]);
    return tx([signed ? invoke(ic) : bare(ic)]);
  };
  const rewards = (who: string, token = TOKEN2) => tx([invoke(call(token, "claim", [addr(who)]))]);

  syn.push(
    // launch: the terms are the pins, and the creator pays exactly their fee, at most 10 XLM, to the launchpad.
    ["v2 launch create ok", launch(), launchIntent(FEE)],
    ["v2 launch create with an initial buy ok", launch(withBuy), launchIntent(FEE + BUY, { [TOKEN2]: "4000" })],
    ["v2 launch fee to the treasury", launch({ feeTo: TREASURY }), launchIntent(FEE)],
    ["v2 launch fee to another address than the launchpad", launch({ feeTo: LOCKER2 }), launchIntent(FEE)],
    ["v2 launch fee other than the terms", launch({ fee: FEE - 1n }), launchIntent(FEE)],
    ["v2 launch without its fee", launch({ fee: 0n }), launchIntent(FEE)],
    ["v2 launch fee above the pinned bound", launch({ terms: { fee: FEE + 1n }, fee: FEE + 1n }), launchIntent(FEE + 1n)],
    ["v2 launch terms with an unpinned executor", launch({ terms: { venue: soroswap(EVIL) } }), launchIntent(FEE)],
    ["v2 launch terms with an unpinned fallback executor", launch({ terms: { fallback: soroswap(EVIL) } }), launchIntent(FEE)],
    // A launch on testnet-qa's failing venue, as testnet-qa's API builds it (CT-18's e2e).
    ["v2 launch terms with the qa-exec-fail venue on the testnet pins", launch({ params: { venue: QA_VENUE.id }, terms: { venue: QA_VENUE } }), launchIntent(FEE)],
    ["v2 launch terms with durations other than the pins", launch({ terms: { durations: { ...LAUNCH_DURATIONS, fallback_delay: 60 } } }), launchIntent(FEE)],
    ["v2 launch terms with another locker", launch({ terms: { locker: EVIL } }), launchIntent(FEE)],
    ["v2 launch terms with another token WASM", launch({ terms: { wasm: UNKNOWN_WASM } }), launchIntent(FEE)],
    ["v2 launch terms with the fee in another asset", launch({ terms: { feeAsset: USDC } }), launchIntent(FEE)],
    ["v2 launch for another creator", launch({ who: third }), launchIntent(FEE)],
    ["v2 launch with a ticker that is not letters or digits", launch({ params: { symbol: "DP-LY" } }), launchIntent(FEE)],
    ["v2 launch initial buy min below the quote", launch({ ...withBuy, params: { initialBuy: BUY, minOut: 3_999n } }), launchIntent(FEE + BUY, { [TOKEN2]: "4000" })],
    ["v2 launch initial buy paid to another address", launch({ ...withBuy, buyTo: TREASURY }), launchIntent(FEE + BUY, { [TOKEN2]: "4000" })],
    [
      "v1 launch arguments on the v2 launchpad",
      tx([invoke(call(PAD2, "launch", [addr(user), addr(XLM), str("Deploy"), str("DPLY"), str("https://x.test/m.json"), u32(100), i128(0n), i128(0n)]))]),
      callIntent("launch_create", PAD2, "launch"),
    ],
    // What the user chose: the creator-fee recipient is the confirmed one (intent.to) or the user, and the
    // exemptions, creator fee and sharing are the ones shown.
    ["v2 launch creator fees to a third party", launch({ params: { recipient: third } }), launchIntent(FEE)],
    ["v2 launch creator fees to the user named ok", launch({ params: { recipient: user } }), launchIntent(FEE)],
    ["v2 launch creator fees to the confirmed recipient ok", launch({ params: { recipient: friend } }), launchIntent(FEE, undefined, { to: friend })],
    ["v2 launch creator fees to another than the confirmed recipient", launch({ params: { recipient: third } }), launchIntent(FEE, undefined, { to: friend })],
    ["v2 launch creator fees to the user when a recipient was confirmed", launch(), launchIntent(FEE, undefined, { to: friend })],
    ["v2 launch showing another recipient", launch(), launchIntent(FEE, undefined, { display: { recipient: third } })],
    ["v2 launch with a snipe exemption not shown", launch({ params: { exempt: [third] } }), launchIntent(FEE)],
    ["v2 launch with its snipe exemptions shown ok", launch({ params: { exempt: [friend, third] } }), launchIntent(FEE, undefined, { display: { snipeExempt: `${friend},${third}` } })],
    ["v2 launch with snipe exemptions in another order", launch({ params: { exempt: [third, friend] } }), launchIntent(FEE, undefined, { display: { snipeExempt: `${friend},${third}` } })],
    ["v2 launch with another creator fee", launch({ params: { creatorFeeBps: 500 } }), launchIntent(FEE)],
    ["v2 launch with holder sharing other than shown", launch({ params: { holderSharing: false } }), launchIntent(FEE)],
    ["v2 launch without its settings shown", launch(), callIntent("launch_create", PAD2, "launch", { [XLM]: FEE.toString() })],
    ["v2 launch initial buy with no minimum", launch({ ...withBuy, params: { initialBuy: BUY, minOut: 0n } }), launchIntent(FEE + BUY, { [TOKEN2]: "0" })],
    [
      "v2 launch with a non-token call nested under its own authorization",
      tx([invoke(call(PAD2, "launch", [addr(user), params(), terms()]), [pull(XLM, PAD2, FEE), inv(call(PAD2, "transfer_creator_fee_recipient", [addr(TOKEN2), addr(third)]))])]),
      launchIntent(FEE),
    ],
    [
      "v2 curve buy with a creator-fee recipient change as a second root",
      tx([invoke(call(PAD2, "buy", [addr(user), addr(TOKEN2), i128(1_000n), i128(4_000n)]), [pull(XLM, PAD2, 1_000n)], [src(inv(call(PAD2, "transfer_creator_fee_recipient", [addr(TOKEN2), addr(third)])))])]),
      callIntent("launch_buy", PAD2, "buy", { [XLM]: "1000" }, { receive: { [TOKEN2]: "4000" } }),
    ],
    [
      "v2 claim rewards with a second root",
      tx([invoke(call(TOKEN2, "claim", [addr(user)]), [], [src(inv(call(POOL, "submit", [addr(user), addr(user), addr(third), xdr.ScVal.scvVec([])])))])]),
      callIntent("launch_claim_rewards", TOKEN2, "claim"),
      runtime(TOKEN2, HASHES.launchTokenV2),
    ],
    ["v2 curve buy ok", tx([invoke(call(PAD2, "buy", [addr(user), addr(TOKEN2), i128(1_000n), i128(4_000n)]), [pull(XLM, PAD2, 1_000n)])]), callIntent("launch_buy", PAD2, "buy", { [XLM]: "1000" }, { receive: { [TOKEN2]: "4000" } })],

    // refund: the holder's own tokens are burned, and the intent declares the burn.
    ["v2 refund ok", refund(user), callIntent("launch_refund", PAD2, "refund", { [TOKEN2]: "500" })],
    ["v2 refund for another holder", refund(third), callIntent("launch_refund", PAD2, "refund", { [TOKEN2]: "500" })],
    ["v2 refund above the spend", refund(user), callIntent("launch_refund", PAD2, "refund", { [TOKEN2]: "499" })],

    // Anyone's calls carry none of the user's authorization.
    ...(["graduate", "graduate_fallback", "mark_stuck", "rescue", "claim_creator_fees", "execute_recipient_change"].map((fn) =>
      [`v2 ${fn.replaceAll("_", " ")} ok`, tx([bare(call(PAD2, fn, [addr(TOKEN2)]))]), callIntent(`launch_${fn}`, PAD2, fn)] as Synthetic
    )),
    ["v2 graduate with your authorization", tx([invoke(call(PAD2, "graduate", [addr(TOKEN2)]))]), callIntent("launch_graduate", PAD2, "graduate")],
    ["v2 harvest ok", tx([bare(call(LOCKER2, "harvest", [addr(POOL2)]))]), callIntent("launch_harvest", LOCKER2, "harvest")],
    ["v2 harvest with your authorization", tx([invoke(call(LOCKER2, "harvest", [addr(POOL2)]))]), callIntent("launch_harvest", LOCKER2, "harvest")],

    // Claims act for the user and spend nothing.
    ["v2 claim owed ok", claimOwed(user), callIntent("launch_claim_owed", PAD2, "claim_owed")],
    ["v2 claim owed for another account", claimOwed(third), callIntent("launch_claim_owed", PAD2, "claim_owed")],
    ["v2 claim owed with a spend", claimOwed(user), callIntent("launch_claim_owed", PAD2, "claim_owed", { [XLM]: "1" })],
    ["v2 claim owed with your authorization", claimOwed(user, true), callIntent("launch_claim_owed", PAD2, "claim_owed")],
    ["v2 claim rewards ok", rewards(user), callIntent("launch_claim_rewards", TOKEN2, "claim"), runtime(TOKEN2, HASHES.launchTokenV2)],
    ["v2 claim rewards for another account", rewards(third), callIntent("launch_claim_rewards", TOKEN2, "claim"), runtime(TOKEN2, HASHES.launchTokenV2)],
    ["v2 claim rewards with a spend", rewards(user), callIntent("launch_claim_rewards", TOKEN2, "claim", { [TOKEN2]: "1" }), runtime(TOKEN2, HASHES.launchTokenV2)],
    ["v2 claim rewards from an unknown runtime WASM", rewards(user, STRANGER), callIntent("launch_claim_rewards", STRANGER, "claim"), runtime(STRANGER, UNKNOWN_WASM)],
    ["v2 claim rewards from a runtime contract the phone didn't read", rewards(user), callIntent("launch_claim_rewards", TOKEN2, "claim")],

    // Recipient changes.
    ["v2 recipient transfer ok", tx([invoke(call(PAD2, "transfer_creator_fee_recipient", [addr(TOKEN2), addr(friend)]))]), callIntent("launch_recipient_transfer", PAD2, "transfer_creator_fee_recipient", {}, { to: friend })],
    [
      "v2 recipient transfer to another address than the one confirmed",
      tx([invoke(call(PAD2, "transfer_creator_fee_recipient", [addr(TOKEN2), addr(third)]))]),
      callIntent("launch_recipient_transfer", PAD2, "transfer_creator_fee_recipient", {}, { to: friend }),
    ],
    ["v2 recipient cancel ok", tx([invoke(call(PAD2, "cancel_recipient_change", [addr(TOKEN2), addr(user)]))]), callIntent("launch_recipient_cancel", PAD2, "cancel_recipient_change")],
    ["v2 recipient cancel for another account", tx([invoke(call(PAD2, "cancel_recipient_change", [addr(TOKEN2), addr(third)]))]), callIntent("launch_recipient_cancel", PAD2, "cancel_recipient_change")],

    // A Moment coin is a SEP-41 token, recognised by its pinned WASM.
    ["v2 moment coin transfer ok", tx([invoke(call(COIN, "transfer", [addr(user), addr(friend), i128(100n)]))]), callIntent("payment", COIN, "transfer", { [COIN]: "100" }, { to: friend }), runtime(COIN, HASHES.momentCoin)],
    ["v2 moment coin transfer to another to", tx([invoke(call(COIN, "transfer", [addr(user), addr(third), i128(100n)]))]), callIntent("payment", COIN, "transfer", { [COIN]: "100" }, { to: friend }), runtime(COIN, HASHES.momentCoin)],

    // moments-v2.
    ["v2 moments publish ok", publish(), publishIntent()],
    ["v2 moments publish for another creator", publish({ who: third }), publishIntent()],
    ["v2 moments publish with another graduator", publish({ terms: { graduator: EVIL } }), publishIntent()],
    ["v2 moments publish with another executor", publish({ terms: { executor: QA_VENUE.executor } }), publishIntent()],
    ["v2 moments publish with another locker", publish({ terms: { locker: EVIL } }), publishIntent()],
    ["v2 moments publish with another NFT WASM", publish({ terms: { nft: UNKNOWN_WASM } }), publishIntent()],
    ["v2 moments publish with another coin WASM", publish({ terms: { coin: UNKNOWN_WASM } }), publishIntent()],
    ["v2 moments publish with durations other than the pins", publish({ terms: { durations: { ...MOMENTS_DURATIONS, pending_backstop: 86_400 } } }), publishIntent()],
    ["v2 moments publish at another price", publish(), publishIntent({ price: "1" })],
    ["v2 moments publish with another allocation", publish(), publishIntent({ allocationBps: 1_000 })],
    ["v2 moments publish with another window", publish(), publishIntent({ windowSecs: 3_600 })],
    ["v2 moments publish without its settings shown", publish(), callIntent("moment_publish", MOMENTS2, "publish")],
    ["v2 moments publish with a ticker that is too long", publish({ symbol: "ABCDEFGHIJK" }), publishIntent()],
    ["v2 moments collect ok", collect(user, 20_000n), collectIntent],
    ["v2 moments collect from another account", collect(third, 20_000n), collectIntent],
    ["v2 moments collect with max_total above the spend", collect(user, 20_001n), collectIntent],
    ["v2 moments claim ok", tx([invoke(call(MOMENTS2, "claim", [addr(user), addr(NFT)]))]), callIntent("moment_claim", MOMENTS2, "claim")],
    ["v2 moments claim for another account", tx([invoke(call(MOMENTS2, "claim", [addr(third), addr(NFT)]))]), callIntent("moment_claim", MOMENTS2, "claim")],
    ["v2 moments claim with a spend", tx([invoke(call(MOMENTS2, "claim", [addr(user), addr(NFT)]))]), callIntent("moment_claim", MOMENTS2, "claim", { [USDC]: "1" })],
    ["v2 moments claim all ok", tx([invoke(call(MOMENTS2, "claim_all", [addr(user), vec([addr(NFT)])]))]), callIntent("moment_claim_all", MOMENTS2, "claim_all")],
    ["v2 moments claim all for another account", tx([invoke(call(MOMENTS2, "claim_all", [addr(third), vec([addr(NFT)])]))]), callIntent("moment_claim_all", MOMENTS2, "claim_all")],
    [
      "v2 moments claim all with a spend",
      tx([invoke(call(MOMENTS2, "claim_all", [addr(user), vec([addr(NFT)])]))]),
      callIntent("moment_claim_all", MOMENTS2, "claim_all", { [USDC]: "1" }),
    ],
    ...(["withdraw_creator", "graduate", "expire"].map((fn) =>
      [`v2 moments ${fn.replaceAll("_", " ")} ok`, tx([bare(call(MOMENTS2, fn, [addr(NFT)]))]), callIntent(`moment_${fn}`, MOMENTS2, fn)] as Synthetic
    )),
    ["v2 moments expire with your authorization", tx([invoke(call(MOMENTS2, "expire", [addr(NFT)]))]), callIntent("moment_expire", MOMENTS2, "expire")],

    // Restores: a v2 runtime contract's data and its pinned WASM, never an unknown one's.
    [
      "v2 restore of a launch token's data and code ok",
      tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [instanceKey(PAD2), balanceKey(TOKEN2), codeKey(HASHES.launchTokenV2), codeKey(HASHES.momentNft)]) }),
      restoreIntent(),
      runtime(TOKEN2, HASHES.launchTokenV2),
    ],
    ["v2 restore of an unknown runtime WASM's data", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [balanceKey(STRANGER)]) }), restoreIntent(), runtime(STRANGER, UNKNOWN_WASM)],
    // The phone read the stranger's WASM hash, which allows nothing: only a pinned WASM's code comes back.
    ["v2 restore of an unknown runtime WASM's code", tx([Operation.restoreFootprint({})], { soroban: resources(50_000, [codeKey(UNKNOWN_WASM)]) }), restoreIntent(), runtime(STRANGER, UNKNOWN_WASM)],
  );
}

for (const [name, t, intent, extra] of syn) {
  vectors.push(judge({ name, tx: t, intent, user, sponsor, pins: SYNTHETIC, now: NOW, ...extra }));
}

await Deno.mkdir(out, { recursive: true });
await Deno.writeTextFile(`${out}verifier.json`, JSON.stringify(vectors, null, 1) + "\n");

// ------------------------------------------------------------------------------------------------ runtime provenance
// Instance ledger entries (LedgerEntryData, as getLedgerEntries answers) and the WASM hash each counts by
// (verify.ts runtimeWasmHashOf, StellarCore RuntimeProvenance), against V2_FIXTURE's pins: an instance of a pinned v2
// runtime WASM counts only when the pinned singleton created it, and only as the contract asked for.
{
  const { launchpadV2: PAD2, momentsV2: MOMENTS2 } = V2_FIXTURE.contracts;
  const HASHES = V2_FIXTURE.runtimeWasmHashes;
  const pins = { launchpad: PAD2, moments: MOMENTS2, runtimeWasmHashes: HASHES };
  const TOKEN2 = fixed(0x47);
  const slot = (name: string, val: xdr.ScVal) => new xdr.ScMapEntry({ key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol(name)]), val });
  const metadata = new xdr.ScMapEntry({
    key: xdr.ScVal.scvSymbol("METADATA"),
    val: xdr.ScVal.scvMap([new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("decimal"), val: nativeToScVal(7, { type: "u32" }) })]),
  });
  const instance = (owner: string, wasm: string | null, storage: xdr.ScMapEntry[] | null) =>
    xdr.LedgerEntryData.contractData(
      new xdr.ContractDataEntry({
        ext: new xdr.ExtensionPoint(0),
        contract: new Address(owner).toScAddress(),
        key: xdr.ScVal.scvLedgerKeyContractInstance(),
        durability: xdr.ContractDataDurability.persistent(),
        val: xdr.ScVal.scvContractInstance(
          new xdr.ScContractInstance({
            executable: wasm ? xdr.ContractExecutable.contractExecutableWasm(Buffer.from(wasm, "hex")) : xdr.ContractExecutable.contractExecutableStellarAsset(),
            storage,
          }),
        ),
      }),
    );
  const cases: [string, xdr.LedgerEntryData, string][] = [
    ["launch token created by the pinned launchpad", instance(TOKEN2, HASHES.launchTokenV2, [metadata, slot("Launchpad", addrVal(PAD2)), slot("Locker", addrVal(fixed(0x43)))]), TOKEN2],
    ["launch token created by another launchpad", instance(TOKEN2, HASHES.launchTokenV2, [slot("Launchpad", addrVal(EVIL))]), TOKEN2],
    ["launch token naming no launchpad", instance(TOKEN2, HASHES.launchTokenV2, null), TOKEN2],
    ["launch token whose launchpad is stored under a bare symbol", instance(TOKEN2, HASHES.launchTokenV2, [new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol("Launchpad"), val: addrVal(PAD2) })]), TOKEN2],
    ["launch token naming the launchpad as its minter", instance(TOKEN2, HASHES.launchTokenV2, [slot("Minter", addrVal(PAD2))]), TOKEN2],
    ["moment NFT minted by the pinned moments", instance(fixed(0x48), HASHES.momentNft, [slot("Minter", addrVal(MOMENTS2)), slot("Creator", addrVal(user)), slot("Minted", nativeToScVal(0, { type: "u32" }))]), fixed(0x48)],
    ["moment coin minted by the pinned moments", instance(fixed(0x49), HASHES.momentCoin, [metadata, slot("Minter", addrVal(MOMENTS2))]), fixed(0x49)],
    ["moment coin minted by the launchpad", instance(fixed(0x49), HASHES.momentCoin, [slot("Minter", addrVal(PAD2))]), fixed(0x49)],
    ["moment NFT minted by an account", instance(fixed(0x48), HASHES.momentNft, [slot("Minter", addrVal(third))]), fixed(0x48)],
    ["entry of another contract than the one asked for", instance(fixed(0x4b), HASHES.launchTokenV2, [slot("Launchpad", addrVal(PAD2))]), TOKEN2],
    ["a Stellar Asset Contract", instance(USDC, null, null), USDC],
    ["v1 launch token, as read", instance(TOKEN, WASM, [slot("Launchpad", addrVal(EVIL))]), TOKEN],
    ["an unknown WASM, as read", instance(fixed(0x4b), "ee".repeat(32), null), fixed(0x4b)],
  ];
  const runtimeVectors = cases.map(([name, entry, contract]) => ({
    name,
    entry: entry.toXDR("base64"),
    contract,
    pins: { launchpadV2: PAD2, momentsV2: MOMENTS2, runtimeWasmHashes: HASHES, launchTokenWasmHash: WASM },
    expect: runtimeWasmHashOf(entry, contract, pins),
  }));
  await Deno.writeTextFile(`${out}runtime.json`, JSON.stringify(runtimeVectors, null, 1) + "\n");
}

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
