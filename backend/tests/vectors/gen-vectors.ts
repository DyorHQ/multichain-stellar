// Generates the cross-language test vectors the Swift verifier (StellarCore) must agree with:
// - real transactions the API built during the testnet e2e run (read from the plans table), expected OK;
// - synthetic attacks built here, expected to fail with the TS verifier's reason;
// - key derivation, SEP-53, StrKey and SAC id vectors.
//   LITE_DB_URL=… deno run -A --config backend/supabase/functions/deno.json backend/tests/vectors/gen-vectors.ts
import { Account, Address, Asset, Contract, Keypair, nativeToScVal, Operation, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import postgres from "postgres";
import { contractAllowlist, TESTNET } from "../../supabase/functions/_shared/networks.ts";
import { Intent, verifyTransaction } from "../../supabase/functions/_shared/verify.ts";
import { SEP53_PREFIX, sha256 } from "../../supabase/functions/_shared/auth.ts";

const PASS = TESTNET.passphrase;
const out = new URL("../../../ios/Packages/StellarKit/Tests/StellarCoreTests/Vectors/", import.meta.url).pathname;

interface Vector {
  name: string;
  envelope: string;
  intent: Intent;
  user: string;
  sponsor: string;
  allowed: string[];
  now: number;
  expect: { ok: boolean; reason?: string; outflow?: Record<string, string> };
  decoded: { source: string; fee: number; seq: string; maxTime: number; ops: string[] };
}

function decodedOf(tx: Transaction) {
  return {
    source: tx.source,
    fee: Number(tx.fee),
    seq: tx.sequence,
    maxTime: Number(tx.timeBounds?.maxTime ?? 0),
    ops: tx.operations.map((o: any) => o.type),
  };
}

function judge(name: string, tx: Transaction, intent: Intent, user: string, sponsor: string, allowed: string[], now: number): Vector {
  let expect: Vector["expect"];
  try {
    const r = verifyTransaction(tx, intent, { user, sponsor, passphrase: PASS, allowedContracts: new Set(allowed), now });
    expect = { ok: true, outflow: r.outflow };
  } catch (e) {
    expect = { ok: false, reason: (e as Error).message };
  }
  return { name, envelope: tx.toEnvelope().toXDR("base64"), intent, user, sponsor, allowed, now, expect, decoded: decodedOf(tx) };
}

const vectors: Vector[] = [];

// ------------------------------------------------------------------------------------------------ real transactions
const dbUrl = Deno.env.get("LITE_DB_URL");
if (dbUrl) {
  const db = postgres(dbUrl, { onnotice: () => {} });
  const sponsor = Deno.env.get("SPONSOR_PUBLIC")!;
  const launches = (await db`select token from lite.launches`).map((r) => r.token as string);
  const allowed = [...Object.values(contractAllowlist(TESTNET)).flat(), ...launches];
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
      vectors.push(judge(`real ${key}`, tx, s.intent, p.address as string, sponsor, allowed, now));
    }
  }
  await db.end();
}

// ------------------------------------------------------------------------------------------------ synthetic attacks
const userKp = Keypair.fromSecret("SBGWSG6BTNCKCOB3DIFBGCVMUPQFYPA2G4O34RMTB343OYPXU5DJDVMN");
const user = userKp.publicKey();
const sponsor = Keypair.fromRawEd25519Seed(Buffer.alloc(32, 7)).publicKey();
const ROUTER = "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD";
const XLM = Asset.native().contractId(PASS);
const USDC_ASSET = new Asset("USDC", "GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5");
const USDC = USDC_ASSET.contractId(PASS);
const EVIL = new Contract("CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526").contractId();
const allowed = [ROUTER, XLM, USDC];
const NOW = 1_800_000_000;

function tx(ops: xdr.Operation[], source = user, maxTime = NOW + 300) {
  const b = new TransactionBuilder(new Account(source, "41"), { fee: "100", networkPassphrase: PASS, timebounds: { minTime: 0, maxTime } });
  ops.forEach((o) => b.addOperation(o));
  return b.build();
}
const call = (c: string, fn: string, args: xdr.ScVal[]) => new xdr.InvokeContractArgs({ contractAddress: new Address(c).toScAddress(), functionName: fn, args });
const inv = (c: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizedInvocation({ function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(c), subInvocations: subs });
const src = (root: xdr.SorobanAuthorizedInvocation) => new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: root });
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const addr = (a: string) => new Address(a).toScVal();
function swapOp(amount: bigint, authAmount: bigint, contract = ROUTER, creds?: xdr.SorobanCredentials) {
  const c = call(contract, "swap_exact_tokens_for_tokens", [i128(amount), i128(1n), xdr.ScVal.scvVec([addr(XLM), addr(USDC)]), addr(user), nativeToScVal(9n, { type: "u64" })]);
  const t = call(XLM, "transfer", [addr(user), addr(contract), i128(authAmount)]);
  const entry = creds ? new xdr.SorobanAuthorizationEntry({ credentials: creds, rootInvocation: inv(c, [inv(t)]) }) : src(inv(c, [inv(t)]));
  return Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(c), auth: [entry] });
}
const swapIntent = (spend: bigint, contract = ROUTER): Intent => ({ kind: "swap", summary: "", spend: { [XLM]: spend.toString() }, calls: [{ contract, fn: "swap_exact_tokens_for_tokens" }] });

const syn: [string, Transaction, Intent][] = [
  ["swap within cap", tx([swapOp(100n, 100n)]), swapIntent(100n)],
  ["swap auth over cap", tx([swapOp(100n, 101n)]), swapIntent(100n)],
  ["contract not pinned", tx([swapOp(100n, 100n, EVIL)]), swapIntent(100n, EVIL)],
  ["function not in intent", tx([swapOp(100n, 100n)]), { ...swapIntent(100n), calls: [{ contract: ROUTER, fn: "add_liquidity" }] }],
  ["address credentials", tx([swapOp(100n, 100n, ROUTER, xdr.SorobanCredentials.sorobanCredentialsAddress(new xdr.SorobanAddressCredentials({ address: new Address(user).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 10, signature: xdr.ScVal.scvVoid() })))]), swapIntent(100n)],
  ["undeclared asset", tx([swapOp(100n, 100n)]), { ...swapIntent(100n), spend: { [USDC]: "100" } }],
  ["other source", tx([swapOp(1n, 1n)], sponsor), swapIntent(1n)],
  ["long expiry", tx([swapOp(1n, 1n)], user, NOW + 7_200), swapIntent(1n)],
  ["set options", tx([Operation.setOptions({ masterWeight: 0 })]), { kind: "x", summary: "", spend: {}, ops: ["payment"] }],
  ["payment ok", tx([Operation.payment({ destination: sponsor, asset: Asset.native(), amount: "5" })]), { kind: "payment", summary: "", spend: { [XLM]: "50000000" }, ops: ["payment"] }],
  ["payment over", tx([Operation.payment({ destination: sponsor, asset: Asset.native(), amount: "5.0000001" })]), { kind: "payment", summary: "", spend: { [XLM]: "50000000" }, ops: ["payment"] }],
  ["third account op", tx([Operation.payment({ destination: sponsor, asset: Asset.native(), amount: "1", source: Keypair.random().publicKey() })]), { kind: "payment", summary: "", spend: { [XLM]: "50000000" }, ops: ["payment"] }],
  ["path payment ok", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: USDC_ASSET, destMin: "0.9", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["path payment low min", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: user, destAsset: USDC_ASSET, destMin: "0.8", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["path payment elsewhere", tx([Operation.pathPaymentStrictSend({ sendAsset: Asset.native(), sendAmount: "10", destination: sponsor, destAsset: USDC_ASSET, destMin: "0.9", path: [] })]), { kind: "swap", summary: "", spend: { [XLM]: "100000000" }, receive: { [USDC]: "9000000" }, ops: ["pathPaymentStrictSend"] }],
  ["sponsored trust ok", tx([Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }), Operation.changeTrust({ asset: USDC_ASSET, source: user }), Operation.endSponsoringFutureReserves({ source: user })]), { kind: "trust", summary: "", spend: {}, ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"], trust: [`USDC:${USDC_ASSET.getIssuer()}`] }],
  ["trust undeclared asset", tx([Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }), Operation.changeTrust({ asset: new Asset("EVIL", sponsor), source: user }), Operation.endSponsoringFutureReserves({ source: user })]), { kind: "trust", summary: "", spend: {}, ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"], trust: [`USDC:${USDC_ASSET.getIssuer()}`] }],
  ["sponsor pays out", tx([Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sponsor }), Operation.payment({ destination: user, asset: Asset.native(), amount: "1", source: sponsor })]), { kind: "trust", summary: "", spend: {}, ops: ["beginSponsoringFutureReserves", "payment"] }],
  ["create account for friend", tx([Operation.createAccount({ destination: sponsor, startingBalance: "2" })]), { kind: "payment", summary: "", spend: { [XLM]: "20000000" }, ops: ["createAccount"] }],
];
{
  const c = call(USDC, "approve", [addr(user), addr(ROUTER), i128(500n), nativeToScVal(100, { type: "u32" })]);
  const op = Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(c), auth: [src(inv(c))] });
  syn.push(["approve counts in full", tx([op]), { kind: "approve", summary: "", spend: { [USDC]: "499" }, calls: [{ contract: USDC, fn: "approve" }] }]);
  syn.push(["approve within cap", tx([op]), { kind: "approve", summary: "", spend: { [USDC]: "500" }, calls: [{ contract: USDC, fn: "approve" }] }]);
}
for (const [name, t, intent] of syn) vectors.push(judge(name, t, intent, user, sponsor, allowed, NOW));

await Deno.mkdir(out, { recursive: true });
await Deno.writeTextFile(`${out}verifier.json`, JSON.stringify(vectors, null, 1));

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
