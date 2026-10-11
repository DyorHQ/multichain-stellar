// The verifier is the line between "the server built it" and "the user signs it". Each test builds a transaction
// offline and checks the verdict.
import { Account, Address, Asset, Contract, Keypair, nativeToScVal, Operation, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { Intent, verifyTransaction, VerifyError } from "../../supabase/functions/_shared/verify.ts";

const PASS = "Test SDF Network ; September 2015";
const user = Keypair.random().publicKey();
const sponsor = Keypair.random().publicKey();
const ROUTER = Keypair.random().publicKey() && new Contract("CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD").contractId();
const XLM = Asset.native().contractId(PASS);
const USDC_ASSET = new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5");
const USDC = USDC_ASSET.contractId(PASS);
const EVIL = "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526";

const ctx = { user, sponsor, passphrase: PASS, allowedContracts: new Set([ROUTER, XLM, USDC]) };

function tx(ops: xdr.Operation[], source = user, timeout = 300) {
  const b = new TransactionBuilder(new Account(source, "41"), { fee: "100", networkPassphrase: PASS }).setTimeout(timeout);
  ops.forEach((o) => b.addOperation(o));
  return b.build();
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

const swapIntent = (spend: bigint): Intent => ({ kind: "swap", summary: "", spend: { [XLM]: spend.toString() }, calls: [{ contract: ROUTER, fn: "swap_exact_tokens_for_tokens" }] });

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

Deno.test("classic payment: amount cap and op source", () => {
  const pay = (amount: string, source?: string) => Operation.payment({ destination: sponsor, asset: Asset.native(), amount, source });
  const intent: Intent = { kind: "payment", summary: "", spend: { [XLM]: "50000000" }, ops: ["payment"] };
  verifyTransaction(tx([pay("5")]), intent, ctx);
  assertThrows(() => verifyTransaction(tx([pay("5.0000001")]), intent, ctx), VerifyError, "spends more");
  assertThrows(() => verifyTransaction(tx([pay("1", Keypair.random().publicKey())]), intent, ctx), VerifyError, "third account");
});

Deno.test("path payment must pay the user at least the quoted minimum", () => {
  const op = (destination: string, destMin: string) =>
    Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination, destAsset: USDC_ASSET, destMin, path: [] });
  const intent: Intent = { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] };
  verifyTransaction(tx([op(user, "0.9")]), intent, ctx);
  assertThrows(() => verifyTransaction(tx([op(user, "0.8")]), intent, ctx), VerifyError, "minimum received");
  assertThrows(() => verifyTransaction(tx([op(sponsor, "0.9")]), intent, ctx), VerifyError, "another account");
});

Deno.test("sponsored trustline: only declared assets, sponsor only begins sponsorship", () => {
  const ops = (asset: Asset) => [
    Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }),
    Operation.changeTrust({ asset, source: user }),
    Operation.endSponsoringFutureReserves({ source: user }),
  ];
  const intent: Intent = { kind: "trust", summary: "", spend: {}, ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"], trust: [`USDC:${USDC_ASSET.getIssuer()}`] };
  verifyTransaction(tx(ops(USDC_ASSET)), intent, ctx);
  assertThrows(() => verifyTransaction(tx(ops(new Asset("EVIL", sponsor))), intent, ctx), VerifyError, "unexpected trustline");
  const sneaky = [...ops(USDC_ASSET), Operation.payment({ destination: user, asset: Asset.native(), amount: "1", source: sponsor })];
  assertThrows(() => verifyTransaction(tx(sneaky), { ...intent, ops: [...intent.ops!, "payment"] }, ctx), VerifyError, "sponsor account runs");
});

Deno.test("an approval counts as outflow in full", () => {
  const c = call(USDC, "approve", [addr(user), addr(ROUTER), i128(500n), nativeToScVal(100, { type: "u32" })]);
  const op = Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(c), auth: [sourceAuth(inv(c))] });
  const intent: Intent = { kind: "approve", summary: "", spend: { [USDC]: "499" }, calls: [{ contract: USDC, fn: "approve" }] };
  assertThrows(() => verifyTransaction(tx([op]), intent, ctx), VerifyError, "spends more");
  verifyTransaction(tx([op]), { ...intent, spend: { [USDC]: "500" } }, ctx);
});
