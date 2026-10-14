// The verifier is the line between "the server built it" and "the user signs it". The shared vectors
// (ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/verifier.json, from backend/tests/vectors/gen-vectors.ts) are
// judged again here and by the Swift verifier, which must agree on each; the tests below build transactions offline
// for the rules the vectors don't reach.
import { Account, Address, Asset, Contract, Keypair, Memo, nativeToScVal, Operation, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertGreater, assertThrows } from "jsr:@std/assert@1";
import { FeeCaps, Intent, verifyFeePayer, verifyTransaction, VerifyError } from "../../supabase/functions/_shared/verify.ts";

const PASS = "Test SDF Network ; September 2015";
const user = Keypair.random().publicKey();
const sponsor = Keypair.random().publicKey();
const friend = Keypair.random().publicKey();
const ROUTER = new Contract("CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD").contractId();
const XLM = Asset.native().contractId(PASS);
const USDC_ASSET = new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5");
const USDC = USDC_ASSET.contractId(PASS);
const EVIL = "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526";
const FEES: FeeCaps = { maxFee: 30_000_000n, maxInclusionPerOp: 200_000n, starterInnerFeeMax: 1_000_000n };

const ctx = { user, sponsor, passphrase: PASS, allowedContracts: new Set([ROUTER, XLM, USDC]), feePolicy: FEES, monadDomain: 15, launchTokenWasmHash: "" };

// ------------------------------------------------------------------------------------------------ shared vectors

interface Vector {
  name: string;
  envelope: string;
  intent: Intent;
  user: string;
  sponsor: string;
  allowed: string[];
  launchTokens: string[];
  launchTokenWasmHash: string;
  monadDomain: number;
  feePolicy: { maxFee: string; maxInclusionPerOp: string; starterInnerFeeMax: string };
  now: number;
  step?: { feePayer: string | null; sponsorReason: string | null };
  expect: { ok: boolean; reason?: string; outflow?: Record<string, string>; step?: { ok: boolean; payer?: string; reason?: string } };
}

const vectors: Vector[] = JSON.parse(
  await Deno.readTextFile(new URL("../../../ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/verifier.json", import.meta.url)),
);

function judge(v: Vector) {
  const tx = TransactionBuilder.fromXDR(v.envelope, PASS) as Transaction;
  const vctx = {
    user: v.user,
    sponsor: v.sponsor,
    passphrase: PASS,
    allowedContracts: new Set([...v.allowed, ...v.launchTokens]),
    now: v.now,
    feePolicy: { maxFee: BigInt(v.feePolicy.maxFee), maxInclusionPerOp: BigInt(v.feePolicy.maxInclusionPerOp), starterInnerFeeMax: BigInt(v.feePolicy.starterInnerFeeMax) },
    launchTokenWasmHash: v.launchTokenWasmHash,
    monadDomain: v.monadDomain,
  };
  let verdict: Vector["expect"];
  try {
    verdict = { ok: true, outflow: verifyTransaction(tx, v.intent, vctx).outflow };
  } catch (e) {
    if (!(e instanceof VerifyError)) throw e;
    verdict = { ok: false, reason: e.message };
  }
  if (v.step) {
    try {
      verdict.step = { ok: true, payer: verifyFeePayer(tx, v.intent, v.step, vctx) };
    } catch (e) {
      if (!(e instanceof VerifyError)) throw e;
      verdict.step = { ok: false, reason: e.message };
    }
  }
  return verdict;
}

Deno.test("every shared vector gets the verdict it records", () => {
  assertGreater(vectors.length, 30);
  for (const v of vectors) assertEquals(judge(v), v.expect, v.name);
});

Deno.test("the vectors cover every case of the design's list, with the verdict it gives", () => {
  const byName = new Map(vectors.map((v) => [v.name, v.expect]));
  const fails: [string, string][] = [
    ["sponsor outside activation", "the sponsor appears outside account activation"],
    ["inclusion over the cap", "the inclusion fee is above the limit"],
    ["soroban fee over the cap", "the network fee is above the limit"],
    ["resource fee above fee", "the resource fee is out of range"],
    ["activate funds XLM", "unexpected account creation"],
    ["payment to another destination", "the destination is not the one you confirmed"],
    ["memo mismatch", "the memo is not the one you confirmed"],
    ["SAC transfer to another to", "the destination is not the one you confirmed"],
    ["soroswap to another account", "swap output goes to another account"],
    ["soroswap min below receive", "the minimum received is lower than quoted"],
    ["curve buy min_tokens_out below receive", "the minimum received is lower than quoted"],
    ["blend submit to another account", "the call acts for another account"],
    ["cctp burn to another mint recipient", "the destination is not the one you confirmed"],
    ["restore with a footprint outside the allowlist", "the restore touches data outside the allowlist"],
  ];
  for (const [name, reason] of fails) assertEquals(byName.get(name), { ok: false, reason }, name);
  for (const name of ["classic fee at the cap ok", "activate ok", "user-paid trust ok", "restore ok"]) assertEquals(byName.get(name)?.ok, true, name);
  assertEquals(byName.get("starter step with an inner fee above the cap")?.step, { ok: false, reason: "the sponsored step's network fee is above the limit" });
});

// ------------------------------------------------------------------------------------------------ offline transactions

function tx(ops: xdr.Operation[], source = user, timeout = 300, memo?: Memo) {
  const b = new TransactionBuilder(new Account(source, "41"), { fee: "100", networkPassphrase: PASS, memo }).setTimeout(timeout);
  ops.forEach((o) => b.addOperation(o));
  return b.build();
}

function withFee(t: Transaction, fee: number): Transaction {
  const envelope = t.toEnvelope();
  envelope.v1().tx().fee(fee);
  return new Transaction(envelope, PASS);
}

function call(contract: string, fn: string, args: xdr.ScVal[]): xdr.InvokeContractArgs {
  return new xdr.InvokeContractArgs({ contractAddress: new Address(contract).toScAddress(), functionName: fn, args });
}

function inv(c: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = []): xdr.SorobanAuthorizedInvocation {
  return new xdr.SorobanAuthorizedInvocation({ function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(c), subInvocations: subs });
}

function sourceAuth(root: xdr.SorobanAuthorizedInvocation): xdr.SorobanAuthorizationEntry {
  return new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: root });
}

const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const addr = (a: string) => new Address(a).toScVal();

function swapOp(amount: bigint, authAmount: bigint, contract = ROUTER, creds?: xdr.SorobanCredentials) {
  const c = call(contract, "swap_exact_tokens_for_tokens", [i128(amount), i128(1n), xdr.ScVal.scvVec([addr(XLM), addr(USDC)]), addr(user), nativeToScVal(9n, { type: "u64" })]);
  const transfer = call(XLM, "transfer", [addr(user), addr(contract), i128(authAmount)]);
  const entry = creds
    ? new xdr.SorobanAuthorizationEntry({ credentials: creds, rootInvocation: inv(c, [inv(transfer)]) })
    : sourceAuth(inv(c, [inv(transfer)]));
  return Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(c), auth: [entry] });
}

const swapIntent = (spend: bigint): Intent => ({
  kind: "swap",
  summary: "",
  spend: { [XLM]: spend.toString() },
  receive: { [USDC]: "1" },
  calls: [{ contract: ROUTER, fn: "swap_exact_tokens_for_tokens" }],
});

Deno.test("accepts a Soroban swap whose authorized outflow matches the intent", () => {
  const r = verifyTransaction(tx([swapOp(100n, 100n)]), swapIntent(100n), ctx);
  assertEquals(r.outflow[XLM], "100");
});

Deno.test("rejects when the auth tree spends more than declared", () => {
  assertThrows(() => verifyTransaction(tx([swapOp(100n, 101n)]), swapIntent(100n), ctx), VerifyError, "spends more");
});

Deno.test("rejects a contract that isn't pinned", () => {
  const intent: Intent = { ...swapIntent(100n), calls: [{ contract: EVIL, fn: "swap_exact_tokens_for_tokens" }] };
  assertThrows(() => verifyTransaction(tx([swapOp(100n, 100n, EVIL)]), intent, ctx), VerifyError, "allowlist");
});

Deno.test("rejects a function the intent doesn't name", () => {
  const intent: Intent = { ...swapIntent(100n), calls: [{ contract: ROUTER, fn: "add_liquidity" }] };
  assertThrows(() => verifyTransaction(tx([swapOp(100n, 100n)]), intent, ctx), VerifyError, "not part of this action");
});

Deno.test("rejects auth that needs another address's signature", () => {
  const creds = xdr.SorobanCredentials.sorobanCredentialsAddress(
    new xdr.SorobanAddressCredentials({ address: new Address(user).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 10, signature: xdr.ScVal.scvVoid() }),
  );
  assertThrows(() => verifyTransaction(tx([swapOp(100n, 100n, ROUTER, creds)]), swapIntent(100n), ctx), VerifyError, "another address");
});

Deno.test("rejects an undeclared asset in the auth tree", () => {
  assertThrows(() => verifyTransaction(tx([swapOp(100n, 100n)]), { ...swapIntent(100n), spend: { [USDC]: "100" } }, ctx), VerifyError, "doesn't declare");
});

Deno.test("rejects a transaction from another account", () => {
  assertThrows(() => verifyTransaction(tx([swapOp(1n, 1n)], Keypair.random().publicKey()), swapIntent(1n), ctx), VerifyError, "not from your account");
});

Deno.test("rejects long-lived transactions", () => {
  assertThrows(() => verifyTransaction(tx([swapOp(1n, 1n)], user, 7_200), swapIntent(1n), ctx), VerifyError, "short expiry");
  assertThrows(() => verifyTransaction(tx([swapOp(1n, 1n)], user, 0), swapIntent(1n), ctx), VerifyError, "short expiry");
});

Deno.test("rejects SetOptions, AccountMerge and friends", () => {
  const intent: Intent = { kind: "payment", summary: "", spend: {}, ops: ["payment"] };
  assertThrows(() => verifyTransaction(tx([Operation.setOptions({ masterWeight: 0 })]), intent, ctx), VerifyError, "not part of this action");
  assertThrows(() => verifyTransaction(tx([Operation.accountMerge({ destination: sponsor })]), { ...intent, ops: ["accountMerge"] }, ctx), VerifyError, "not allowed");
});

Deno.test("classic payment: amount cap, op source and the confirmed destination", () => {
  const pay = (amount: string, source?: string, destination = friend) => Operation.payment({ destination, asset: Asset.native(), amount, source });
  const intent: Intent = { kind: "payment", summary: "", spend: { [XLM]: "50000000" }, ops: ["payment"], to: friend };
  verifyTransaction(tx([pay("5")]), intent, ctx);
  assertThrows(() => verifyTransaction(tx([pay("5.0000001")]), intent, ctx), VerifyError, "spends more");
  assertThrows(() => verifyTransaction(tx([pay("1", Keypair.random().publicKey())]), intent, ctx), VerifyError, "third account");
  assertThrows(() => verifyTransaction(tx([pay("1", undefined, sponsor)]), intent, ctx), VerifyError, "not the one you confirmed");
});

Deno.test("path payment must pay the user at least the quoted minimum", () => {
  const op = (destination: string, destMin: string) =>
    Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination, destAsset: USDC_ASSET, destMin, path: [] });
  const intent: Intent = { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] };
  verifyTransaction(tx([op(user, "0.9")]), intent, ctx);
  assertThrows(() => verifyTransaction(tx([op(user, "0.8")]), intent, ctx), VerifyError, "minimum received");
  assertThrows(() => verifyTransaction(tx([op(sponsor, "0.9")]), intent, ctx), VerifyError, "another account");
});

Deno.test("the sponsor appears only in an activation, and there only begins sponsorship or creates the account", () => {
  const ops = (asset: Asset) => [
    Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }),
    Operation.changeTrust({ asset, source: user }),
    Operation.endSponsoringFutureReserves({ source: user }),
  ];
  const trust = [`USDC:${USDC_ASSET.getIssuer()}`];
  const intent: Intent = { kind: "activate", summary: "", spend: {}, ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"], trust };
  verifyTransaction(tx(ops(USDC_ASSET)), intent, ctx);
  assertThrows(() => verifyTransaction(tx(ops(USDC_ASSET)), { ...intent, kind: "trust" }, ctx), VerifyError, "outside account activation");
  assertThrows(() => verifyTransaction(tx(ops(new Asset("EVIL", sponsor))), intent, ctx), VerifyError, "unexpected trustline");
  const sneaky = [...ops(USDC_ASSET), Operation.payment({ destination: user, asset: Asset.native(), amount: "1", source: sponsor })];
  assertThrows(() => verifyTransaction(tx(sneaky), { ...intent, ops: [...intent.ops!, "payment"] }, ctx), VerifyError, "sponsor account runs");
  // The user-paid trustline that replaces the sandwich.
  verifyTransaction(tx([Operation.changeTrust({ asset: USDC_ASSET })]), { ...intent, kind: "trust", ops: ["changeTrust"] }, ctx);
});

Deno.test("an approval counts as outflow in full", () => {
  const c = call(USDC, "approve", [addr(user), addr(ROUTER), i128(500n), nativeToScVal(100, { type: "u32" })]);
  const op = Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(c), auth: [sourceAuth(inv(c))] });
  const intent: Intent = { kind: "approve", summary: "", spend: { [USDC]: "499" }, calls: [{ contract: USDC, fn: "approve" }] };
  assertThrows(() => verifyTransaction(tx([op]), intent, ctx), VerifyError, "spends more");
  verifyTransaction(tx([op]), { ...intent, spend: { [USDC]: "500" } }, ctx);
});

Deno.test("fee caps: the network's policy applies when the context names none", () => {
  const pay = Operation.payment({ destination: friend, asset: Asset.native(), amount: "1" });
  const intent: Intent = { kind: "payment", summary: "", spend: { [XLM]: "10000000" }, ops: ["payment"], to: friend };
  const { feePolicy: _caps, ...envCtx } = ctx;
  // Testnet's maxInclusionPerOp is 0.02 XLM (networks.ts), the same as FEES.
  verifyTransaction(withFee(tx([pay]), 200_000), intent, envCtx);
  assertThrows(() => verifyTransaction(withFee(tx([pay]), 200_001), intent, envCtx), VerifyError, "inclusion fee is above the limit");
  const tight = { ...ctx, feePolicy: { ...FEES, maxFee: 150n } };
  assertThrows(() => verifyTransaction(withFee(tx([pay]), 151), intent, tight), VerifyError, "network fee is above the limit");
});

Deno.test("memo: the one the user confirmed, or none", () => {
  const pay = Operation.payment({ destination: friend, asset: Asset.native(), amount: "1" });
  const intent: Intent = { kind: "payment", summary: "", spend: { [XLM]: "10000000" }, ops: ["payment"], to: friend };
  verifyTransaction(tx([pay], user, 300, Memo.text("12345")), { ...intent, memo: { type: "text", value: "12345" } }, ctx);
  verifyTransaction(tx([pay], user, 300, Memo.id("12345")), { ...intent, memo: { type: "id", value: "12345" } }, ctx);
  assertThrows(() => verifyTransaction(tx([pay], user, 300, Memo.text("12345")), intent, ctx), VerifyError, "memo");
  assertThrows(() => verifyTransaction(tx([pay]), { ...intent, memo: { type: "text", value: "12345" } }, ctx), VerifyError, "memo");
  assertThrows(() => verifyTransaction(tx([pay], user, 300, Memo.id("12345")), { ...intent, memo: { type: "id", value: "012345" } }, ctx), VerifyError, "memo");
});

Deno.test("who pays: setup only from the sponsor in an activation, a starter swap within its cap", () => {
  const pay = Operation.payment({ destination: friend, asset: Asset.native(), amount: "1" });
  const intent: Intent = { kind: "swap", summary: "", spend: {}, ops: ["payment"], to: friend };
  const starter = { feePayer: "sponsor", sponsorReason: "starter_swap" };
  assertEquals(verifyFeePayer(withFee(tx([pay]), 1_000_000), intent, starter, ctx), "starter_swap");
  assertThrows(() => verifyFeePayer(withFee(tx([pay]), 1_000_001), intent, starter, ctx), VerifyError, "sponsored step");
  assertEquals(verifyFeePayer(tx([pay]), intent, { feePayer: "user" }, ctx), "user");
  assertEquals(verifyFeePayer(tx([pay]), { ...intent, kind: "activate" }, { feePayer: "sponsor", sponsorReason: "setup" }, ctx), "user");
  assertEquals(verifyFeePayer(tx([pay], sponsor), { ...intent, kind: "activate" }, {}, ctx), "setup");
  assert(vectors.some((v) => v.step));
});
