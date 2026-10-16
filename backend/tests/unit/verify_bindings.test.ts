// The verifier refuses what a compromised server could slip into a step the user approves: a user authorization of
// any call other than the step's own (nested under it or as a second root) or of a spend of someone else's tokens; a
// swap routed through a token nobody lists; a trade without a minimum; and a v2 launch or Moment publish whose
// recipient, exemptions, creator fee, sharing, price, allocation or window differ from what the intent shows. Each test
// rebuilds a transaction the earlier verifier accepted. The Swift verifier judges the same cases through the shared
// vectors (gen-vectors.ts) and StellarCoreTests' AuthorizationTreeTests.
import { Account, Address, Asset, Keypair, nativeToScVal, Operation, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assertEquals } from "jsr:@std/assert@1";
import { type FeeCaps, type Intent, runtimeWasmHashOf, v2Pins, verifyTransaction, VerifyError } from "../../supabase/functions/_shared/verify.ts";

const PASS = "Test SDF Network ; September 2015";
const user = Keypair.random().publicKey();
const sponsor = Keypair.random().publicKey();
const ROUTER = "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD";
const BLEND = "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF";
const PAD_V2 = "CAEEBNR6DDXCRCHBDUGPG5AWND5L2PHHEK4A77PDPHR4MTS5XVFRTMPS";
const PAD = "CDZD53SNMXM4H7GUHHCCMCCS3W3VRNSG63NXB4OPVK7OELYYIGKC5I6I";
const XLM = Asset.native().contractId(PASS);
const USDC = new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5").contractId(PASS);
/** A token anyone can open a Soroswap pair for: a route through it runs its code inside the user's swap. */
const EVIL_TOKEN = StrKey.encodeContract(Buffer.alloc(32, 0x66));
const ATTACKER = Keypair.random().publicKey();
const MY_LAUNCH = StrKey.encodeContract(Buffer.alloc(32, 0x22));
const FEES: FeeCaps = { maxFee: 30_000_000n, maxInclusionPerOp: 200_000n, starterInnerFeeMax: 1_000_000n };
const NOW = 1_800_000_000;

const addr = (a: string) => new Address(a).toScVal();
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u64 = (n: bigint) => nativeToScVal(n, { type: "u64" });
const call = (c: string, fn: string, args: xdr.ScVal[]) => new xdr.InvokeContractArgs({ contractAddress: new Address(c).toScAddress(), functionName: fn, args });
const inv = (ic: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizedInvocation({ function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(ic), subInvocations: subs });
const src = (root: xdr.SorobanAuthorizedInvocation) => new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: root });

function build(ic: xdr.InvokeContractArgs, auth: xdr.SorobanAuthorizationEntry[]): Transaction {
  const op = Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(ic), auth });
  return new TransactionBuilder(new Account(user, "41"), { fee: "100", networkPassphrase: PASS, timebounds: { minTime: 0, maxTime: NOW + 300 } }).addOperation(op).build();
}

const ctx = {
  user,
  sponsor,
  passphrase: PASS,
  allowedContracts: new Set([ROUTER, XLM, USDC, BLEND, PAD_V2, PAD]),
  feePolicy: FEES,
  monadDomain: 15,
  launchTokenWasmHash: "",
  now: NOW,
  v2: null,
};

function verdict(tx: Transaction, intent: Intent, context: Parameters<typeof verifyTransaction>[2] = ctx) {
  try {
    return { ok: true, outflow: verifyTransaction(tx, intent, context).outflow };
  } catch (e) {
    if (!(e instanceof VerifyError)) throw e;
    return { ok: false, reason: e.message };
  }
}

// ------------------------------------------------------------------------------------------------ the authorization tree

// "Swap 100 XLM for at least 1 USDC", with the user's authorization of the swap and its XLM pull.
const swapThrough = (path: string[]) =>
  call(ROUTER, "swap_exact_tokens_for_tokens", [i128(100n), i128(1n), xdr.ScVal.scvVec(path.map(addr)), addr(user), u64(9n)]);
const swap = swapThrough([XLM, USDC]);
const pull = inv(call(XLM, "transfer", [addr(user), addr(ROUTER), i128(100n)]));
const intent: Intent = { kind: "swap", summary: "Swap 100 XLM for USDC", spend: { [XLM]: "100" }, receive: { [USDC]: "1" }, calls: [{ contract: ROUTER, fn: "swap_exact_tokens_for_tokens" }] };
// Blend submit(from, spender, to, requests) withdrawing to the attacker; launchpad-v2 transfer_creator_fee_recipient
// handing the user's launch's creator fees to the attacker.
const withdrawAll = call(BLEND, "submit", [addr(user), addr(user), addr(ATTACKER), xdr.ScVal.scvVec([])]);
const stealFees = call(PAD_V2, "transfer_creator_fee_recipient", [addr(MY_LAUNCH), addr(ATTACKER)]);

const OTHER_AUTH = "the transaction asks you to authorize a call that is not a spend of your tokens";
const EXTRA_AUTH = "the transaction asks you to authorize a call other than this one";

Deno.test("the plain swap passes, its outflow the XLM it pulls", () => {
  assertEquals(verdict(build(swap, [src(inv(swap, [pull]))]), intent), { ok: true, outflow: { [XLM]: "100" } });
});

Deno.test("a Blend withdrawal to a third party nested under the swap's own authorization is refused", () => {
  assertEquals(verdict(build(swap, [src(inv(swap, [pull, inv(withdrawAll)]))]), intent), { ok: false, reason: OTHER_AUTH });
  // Under the token spend too: every node beneath the call must be a spend of the user's own tokens.
  const deep = inv(call(XLM, "transfer", [addr(user), addr(ROUTER), i128(100n)]), [inv(withdrawAll)]);
  assertEquals(verdict(build(swap, [src(inv(swap, [deep]))]), intent), { ok: false, reason: OTHER_AUTH });
});

Deno.test("an extra root authorizing a creator-fee recipient change, a withdrawal or a token transfer is refused", () => {
  assertEquals(verdict(build(swap, [src(inv(swap, [pull])), src(inv(stealFees))]), intent), { ok: false, reason: EXTRA_AUTH });
  assertEquals(verdict(build(swap, [src(inv(swap, [pull])), src(inv(stealFees)), src(inv(withdrawAll))]), intent), { ok: false, reason: EXTRA_AUTH });
  const transfer = inv(call(USDC, "transfer", [addr(user), addr(ATTACKER), i128(1n)]));
  assertEquals(verdict(build(swap, [src(inv(swap, [pull])), src(transfer)]), { ...intent, spend: { [XLM]: "100", [USDC]: "1" }, to: ATTACKER }), { ok: false, reason: EXTRA_AUTH });
});

Deno.test("a nested spend of another account's tokens, or one with another arity, is refused", () => {
  const theirs = inv(call(USDC, "transfer", [addr(ATTACKER), addr(user), i128(1n)]));
  assertEquals(verdict(build(swap, [src(inv(swap, [pull, theirs]))]), intent), { ok: false, reason: OTHER_AUTH });
  const odd = inv(call(XLM, "transfer", [addr(user), addr(ROUTER), i128(100n), u64(1n)]));
  assertEquals(verdict(build(swap, [src(inv(swap, [odd]))]), intent), { ok: false, reason: OTHER_AUTH });
});

Deno.test("a swap routed through an unlisted token is refused, whatever its authorization", () => {
  const routed = swapThrough([XLM, EVIL_TOKEN, USDC]);
  assertEquals(verdict(build(routed, [src(inv(routed, [pull]))]), intent), { ok: false, reason: "the swap route goes through a token this app doesn't list" });
  // The earlier verifier's accepted shape: the route, the nested withdrawal and the extra root together.
  assertEquals(verdict(build(routed, [src(inv(routed, [pull, inv(withdrawAll)])), src(inv(stealFees))]), intent).ok, false);
});

// ------------------------------------------------------------------------------------------------ minimums

Deno.test("a curve buy or sell with a minimum of 0 is refused even when the intent quotes 0", () => {
  const TOKEN = StrKey.encodeContract(Buffer.alloc(32, 0x22));
  const buy = call(PAD, "buy", [addr(user), addr(TOKEN), i128(100_000_000n), i128(0n)]);
  const buyIntent: Intent = { kind: "launch_buy", summary: "", spend: { [XLM]: "100000000" }, receive: { [TOKEN]: "0" }, calls: [{ contract: PAD, fn: "buy" }] };
  const paid = inv(call(XLM, "transfer", [addr(user), addr(PAD), i128(100_000_000n)]));
  assertEquals(verdict(build(buy, [src(inv(buy, [paid]))]), buyIntent), { ok: false, reason: "the transaction sets no minimum received" });
  const sell = call(PAD, "sell", [addr(user), addr(TOKEN), i128(500n), i128(0n)]);
  const sellIntent: Intent = { kind: "launch_sell", summary: "", spend: { [TOKEN]: "500" }, receive: { [XLM]: "0" }, calls: [{ contract: PAD, fn: "sell" }] };
  const sold = inv(call(TOKEN, "transfer", [addr(user), addr(PAD), i128(500n)]));
  assertEquals(verdict(build(sell, [src(inv(sell, [sold]))]), sellIntent, { ...ctx, allowedContracts: new Set([...ctx.allowedContracts, TOKEN]) }), {
    ok: false,
    reason: "the transaction sets no minimum received",
  });
  const zeroSwap = call(ROUTER, "swap_exact_tokens_for_tokens", [i128(100n), i128(0n), xdr.ScVal.scvVec([addr(XLM), addr(USDC)]), addr(user), u64(9n)]);
  assertEquals(verdict(build(zeroSwap, [src(inv(zeroSwap, [pull]))]), { ...intent, receive: { [USDC]: "0" } }), { ok: false, reason: "the transaction sets no minimum received" });
});

Deno.test("a path payment whose intent quotes no minimum is refused", () => {
  const op = Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5"), destMin: "0.0000001", path: [] });
  const tx = new TransactionBuilder(new Account(user, "41"), { fee: "100", networkPassphrase: PASS, timebounds: { minTime: 0, maxTime: NOW + 300 } }).addOperation(op).build();
  assertEquals(verdict(tx, { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, ops: ["pathPaymentStrictSend"] }), { ok: false, reason: "the minimum received is lower than quoted" });
});

// ------------------------------------------------------------------------------------------------ what the user typed

// deno-lint-ignore no-explicit-any
const vectors: any[] = JSON.parse(await Deno.readTextFile(new URL("../../../ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/verifier.json", import.meta.url)));

// deno-lint-ignore no-explicit-any
function judgeVector(v: any, envelope: string) {
  const tx = TransactionBuilder.fromXDR(envelope, PASS) as Transaction;
  return verdict(tx, v.intent, {
    user: v.user,
    sponsor: v.sponsor,
    passphrase: PASS,
    allowedContracts: new Set<string>([...v.allowed, ...v.launchTokens]),
    now: v.now,
    feePolicy: { maxFee: BigInt(v.feePolicy.maxFee), maxInclusionPerOp: BigInt(v.feePolicy.maxInclusionPerOp), starterInnerFeeMax: BigInt(v.feePolicy.starterInnerFeeMax) },
    launchTokenWasmHash: v.launchTokenWasmHash,
    monadDomain: v.monadDomain,
    v2: v.v2 ? v2Pins(v.v2, BigInt(v.v2.maxLaunchFeeStroops)) : null,
    runtimeContracts: v.runtime,
  });
}

/** Rewrites fields of the call's params struct (args[1]) in the envelope and in every auth root that is the call, so the
 *  authorization stays the call's own. */
function rewrite(envelope: string, fields: Record<string, xdr.ScVal>): string {
  const env = xdr.TransactionEnvelope.fromXDR(envelope, "base64");
  const op = env.v1().tx().operations()[0].body().invokeHostFunctionOp();
  const ic = op.hostFunction().invokeContract();
  const before = ic.toXDR("base64");
  const patch = (args: xdr.ScVal[]) => {
    for (const entry of args[1].map()!) {
      const name = Buffer.from(entry.key().sym() as string | Buffer).toString();
      if (name in fields) entry.val(fields[name]);
    }
  };
  patch(ic.args());
  for (const a of op.auth()) {
    const f = a.rootInvocation().function();
    if (f.switch().value === 0 && f.contractFn().toXDR("base64") === before) patch(f.contractFn().args());
  }
  return env.toXDR("base64");
}

Deno.test("a v2 launch whose creator fees or snipe exemptions go to a third party is refused", () => {
  const v = vectors.find((x) => x.name === "v2 launch create ok");
  assertEquals(judgeVector(v, v.envelope).ok, true);
  const recipient = rewrite(v.envelope, { creator_fee_recipient: addr(ATTACKER) });
  assertEquals(judgeVector(v, recipient), { ok: false, reason: "the creator fees go to another address than the one you confirmed" });
  const exempt = rewrite(v.envelope, { snipe_exempt: xdr.ScVal.scvVec([addr(ATTACKER)]) });
  assertEquals(judgeVector(v, exempt), { ok: false, reason: "the launch settings are not the ones shown" });
  const fee = rewrite(v.envelope, { creator_fee_bps: nativeToScVal(1_000, { type: "u32" }) });
  assertEquals(judgeVector(v, fee), { ok: false, reason: "the launch settings are not the ones shown" });
});

Deno.test("a v2 Moment published at another price, allocation or window is refused", () => {
  const v = vectors.find((x) => x.name === "v2 moments publish ok");
  assertEquals(judgeVector(v, v.envelope).ok, true);
  const reason = "the Moment's price, allocation or window is not the one shown";
  assertEquals(judgeVector(v, rewrite(v.envelope, { price: i128(1n) })), { ok: false, reason });
  assertEquals(judgeVector(v, rewrite(v.envelope, { creator_alloc_bps: nativeToScVal(1_000, { type: "u32" }) })), { ok: false, reason });
  assertEquals(judgeVector(v, rewrite(v.envelope, { window_secs: u64(3_600n) })), { ok: false, reason });
});

// ------------------------------------------------------------------------------------------------ runtime provenance

// deno-lint-ignore no-explicit-any
const runtimeVectors: any[] = JSON.parse(await Deno.readTextFile(new URL("../../../ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/runtime.json", import.meta.url)));

Deno.test("an instance of a pinned v2 runtime WASM counts only when the pinned singleton created it, and only as the contract asked for", () => {
  assertEquals(runtimeVectors.length >= 10, true);
  for (const v of runtimeVectors) {
    const pins = { launchpad: v.pins.launchpadV2, moments: v.pins.momentsV2, runtimeWasmHashes: v.pins.runtimeWasmHashes };
    assertEquals(runtimeWasmHashOf(xdr.LedgerEntryData.fromXDR(v.entry, "base64"), v.contract, pins), v.expect, v.name);
  }
  const byName = new Map(runtimeVectors.map((v) => [v.name, v.expect]));
  for (const name of ["launch token created by another launchpad", "moment coin minted by the launchpad", "moment NFT minted by an account", "entry of another contract than the one asked for"]) {
    assertEquals(byName.get(name), null, name);
  }
  assertEquals(byName.get("launch token created by the pinned launchpad"), "a1".repeat(32));
  assertEquals(byName.get("moment coin minted by the pinned moments"), "a3".repeat(32));
});

// ------------------------------------------------------------------------------------------------ v1's launch and publish

Deno.test("with v2 pinned, a v1 publish or launch is refused, whatever its display shows; without v2's pins it is judged by v1's rules", () => {
  const v2From = vectors.find((x) => x.name === "v2 moments publish ok");
  for (const name of ["moments publish ok without v2 pins", "launch create ok without v2 pins"]) {
    const v = vectors.find((x) => x.name === name);
    assertEquals(judgeVector(v, v.envelope).ok, true, name);
    // The same transaction, judged with the testnet's v2 pins, as a compromised server would substitute it for a v2 one.
    assertEquals(judgeVector({ ...v, v2: v2From.v2 }, v.envelope), { ok: false, reason: "this generation no longer takes new launches or Moments" }, name);
  }
});
