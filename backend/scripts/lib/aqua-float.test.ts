// The AQUA float step (finding V8, lead rulings (a) and (b)) against mocked router replies. No network.
import { assert, assertEquals, assertRejects, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Account, Address, Keypair, nativeToScVal, scValToNative, type Transaction, xdr } from "@stellar/stellar-sdk";
import {
  acquireAqua,
  afterFailedFunding,
  type AquaPlanInput,
  aquariusLiveCheck,
  depthCheck,
  MAX_SWAP_STROOPS,
  parseAquariusFixtures,
  planAquarius,
  routerEstimate,
} from "./aqua-float.ts";
import { type AccountInfo, type Chain, STROOPS_PER_XLM } from "./preflight-v2.ts";
import { profileFor, singletonsFor } from "./v2-profile.ts";

const root = new URL("../../../", import.meta.url).pathname;
const fx = parseAquariusFixtures(JSON.parse(Deno.readTextFileSync(`${root}contracts/testdata/fixtures.json`)));
const XLM = STROOPS_PER_XLM;
const AQUA = STROOPS_PER_XLM;

/** A constant-product XLM→AQUA quote with Aquarius's 0.3% fee, from reserves (stroops). */
const pool = (xlmReserve: bigint, aquaReserve: bigint) => (xlmIn: bigint) => {
  const inWithFee = xlmIn * 997n;
  return Promise.resolve((inWithFee * aquaReserve) / (xlmReserve * 1000n + inWithFee));
};
// The testnet XLM–AQUA pool at CT-03's check (fixtures.json reserves_at_check).
const DEEP = pool(349_583_963_389n, 7_911_445_542_969n);

Deno.test("fixtures.json gives the router, its hashes, the gate verdict, AQUA and the XLM–AQUA pool", () => {
  assertEquals(fx.router, "CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD");
  assertEquals(fx.routerWasmHash, "c99539b023df4a28d7857d33ca4c915c2e20fec04f12b125132b84fbdf94dad3");
  assertEquals(fx.venueOk, true);
  assertEquals(fx.aqua.sac, "CDNVQW44C3HALYNVQ4SOBXY5EWYTGVYXX6JPESOLQDABJI5FC5LTRRUE");
  assertEquals(fx.pool.feeFraction, 30);
  assertEquals(fx.pool.tokens, [fx.pool.xlmSac, fx.aqua.sac]);
});

Deno.test("a deep XLM–AQUA pool passes the depth check: about 2.5 XLM buys the 50 AQUA target plus 10%", async () => {
  const d = await depthCheck(DEEP, 50n * AQUA);
  assert(d.ok, d.reason ?? "");
  assertEquals(d.minOut, 55n * AQUA);
  assert(d.rate1 > 22n * AQUA && d.rate1 < 23n * AQUA, `1 XLM → ${d.rate1}`);
  assert(d.spend > 2n * XLM && d.spend < 3n * XLM, `spend ${d.spend}`);
  assert(d.out >= d.minOut);
  // testnet-qa's target is 10 × the payment.
  const qa = await depthCheck(DEEP, 10n * AQUA);
  assert(qa.ok && qa.spend < 1n * XLM);
});

Deno.test("a thin pool fails the depth check, and nothing above 2,000 XLM is ever spent", async () => {
  const thin = await depthCheck(pool(20n * XLM, 400n * AQUA), 50n * AQUA);
  assert(!thin.ok);
  assertStringIncludes(thin.reason!, "too thin");
  const costly = await depthCheck(pool(1_000_000n * XLM, 1_000n * AQUA), 50n * AQUA);
  assert(!costly.ok);
  assertStringIncludes(costly.reason!, "more than 2000 XLM");
  assert(costly.spend > MAX_SWAP_STROOPS);
  // A quote that breaks down for the full amount: more than 3% below the 1-XLM rate.
  const stepped = (x: bigint) => Promise.resolve(x <= XLM ? 20n * AQUA : (x * 19n * AQUA) / XLM);
  const s = await depthCheck(stepped, 50n * AQUA);
  assert(!s.ok);
  const empty = await depthCheck(() => Promise.resolve(0n), 50n * AQUA);
  assertStringIncludes(empty.reason!, "quotes nothing");
});

const input = (o: Partial<AquaPlanInput>): AquaPlanInput => ({
  deployment: "testnet-qa",
  aquarius: "auto",
  fundAquaFloat: false,
  swapByDefault: true,
  fixtures: fx,
  live: { ok: true, lines: [] },
  payment: { asset: fx.aqua.sac, amount: 1n * AQUA },
  targetMultiple: 10,
  ...o,
});

Deno.test("--aquarius off, a thin pool or a failed swap: a testnet-qa plan without exec-aquarius or the Aquarius venue", () => {
  const qa = profileFor("testnet-qa");
  const off = planAquarius(input({ aquarius: "off" }));
  assertEquals([off.enabled, off.reason, off.swap], [false, "--aquarius off", false]);
  assert(!singletonsFor(qa, off.enabled).includes("exec-aquarius"));

  const on = planAquarius(input({}));
  assertEquals([on.enabled, on.swap, on.target], [true, true, 10n * AQUA]);
  assert(singletonsFor(qa, on.enabled).includes("exec-aquarius"));
  for (const reason of ["the pool is too thin: …", "the swap failed: tx failed"]) {
    const after = afterFailedFunding(on, "testnet-qa", reason);
    assertEquals([after.enabled, after.reason, after.swap], [false, reason, false]);
    assert(!singletonsFor(qa, after.enabled).includes("exec-aquarius"));
  }
});

Deno.test("on the owner's testnet nothing is swapped without --fund-aqua-float; a failed funding keeps the venue", () => {
  const base = { deployment: "testnet" as const, swapByDefault: false, targetMultiple: 50 };
  const plain = planAquarius(input(base));
  assertEquals([plain.enabled, plain.swap, plain.target], [true, false, 50n * AQUA]);
  assertStringIncludes(plain.notes[0], "not funded by this run");
  const fund = planAquarius(input({ ...base, fundAquaFloat: true }));
  assertEquals([fund.enabled, fund.swap], [true, true]);
  const failed = afterFailedFunding(fund, "testnet", "the pool is too thin");
  assertEquals([failed.enabled, failed.swap], [true, false]);
  assertStringIncludes(failed.notes.at(-1)!, "fund it to its target by hand");
});

Deno.test("a live router that differs from the fixtures: refused on testnet, Aquarius off on testnet-qa (ruling a)", async () => {
  const storage = (pool: string, token: string) => [
    { key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("ConstantPoolHash")]), val: xdr.ScVal.scvBytes(Buffer.from(pool, "hex")) },
    { key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("TokenHash")]), val: xdr.ScVal.scvBytes(Buffer.from(token, "hex")) },
    { key: xdr.ScVal.scvVec([xdr.ScVal.scvSymbol("EmergencyMode")]), val: xdr.ScVal.scvBool(true) },
  ];
  const reader = (wasm: string, s: ReturnType<typeof storage>) => ({ ...fakeChain(), contractWasmHash: () => Promise.resolve(wasm), instanceStorage: () => Promise.resolve(s) });
  const same = await aquariusLiveCheck(reader(fx.routerWasmHash, storage(fx.constantPoolHash, fx.tokenHash)), fx);
  assert(same.ok);
  assertEquals(same.lines.map((l) => l.label), ["router WASM hash", "ConstantPoolHash", "TokenHash"]);
  const changed = await aquariusLiveCheck(reader(fx.routerWasmHash, storage(fx.constantPoolHash, "00".repeat(32))), fx);
  assert(!changed.ok);
  assertThrows(() => planAquarius(input({ deployment: "testnet", swapByDefault: false, live: changed })), Error, "CT-03's gate checks must be re-run");
  const qa = planAquarius(input({ live: changed }));
  assertEquals(qa.enabled, false);
  assertStringIncludes(qa.reason!, "TokenHash");
  // --aquarius off needs no live match.
  assertEquals(planAquarius(input({ deployment: "testnet", aquarius: "off", live: changed })).enabled, false);
  // A pool payment in another asset is the same kind of change.
  assertThrows(() => planAquarius(input({ deployment: "testnet", payment: { asset: fx.pool.xlmSac, amount: 1n } })), Error, "not AQUA");
  // CT-03's gate said no-go: no venue.
  assertEquals(planAquarius(input({ fixtures: { ...fx, venueOk: false } })).reason, "CT-03's gate is no-go (AQUARIUS_VENUE_OK false)");
});

// ------------------------------------------------------------------------------------------------ the swap itself

/** A chain that applies the two operations of the AQUA step: the trustline and router.swap. */
function fakeChain(opts: { failSwap?: boolean; rate?: bigint } = {}) {
  const accounts = new Map<string, AccountInfo>();
  const sent: { fn: string; args: unknown[] }[] = [];
  const views: { fn: string; args: unknown[] }[] = [];
  const aquaAsset = `${fx.aqua.code}:${fx.aqua.issuer}`;
  const chain: Chain = {
    passphrase: "Test SDF Network ; September 2015",
    account: (id) => Promise.resolve(accounts.get(id) ?? null),
    latestLedger: () => Promise.resolve(100),
    contractWasmHash: () => Promise.resolve(null),
    instanceStorage: () => Promise.resolve(null),
    codeExists: () => Promise.resolve(false),
    liveUntil: () => Promise.resolve(new Map()),
    view(id, fn, args) {
      views.push({ fn, args: args.map((a) => scValToNative(a)) });
      if (id === fx.router && fn === "estimate_swap") {
        const amount = BigInt(scValToNative(args[4]));
        return Promise.resolve(nativeToScVal((amount * (opts.rate ?? 22n * AQUA)) / XLM, { type: "u128" }));
      }
      return Promise.reject(new Error(`no view ${fn}`));
    },
    friendbot: () => Promise.reject(new Error("no friendbot here")),
    sourceAccount: (id) => Promise.resolve(new Account(id, accounts.get(id)!.sequence)),
    prepare: (tx) => Promise.resolve(tx),
    submit(tx: Transaction) {
      const a = accounts.get(tx.source)!;
      a.sequence = (BigInt(a.sequence) + 1n).toString();
      const op = tx.operations[0] as any;
      if (op.type === "changeTrust") {
        a.trustlines.push({ asset: `${op.line.getCode()}:${op.line.getIssuer()}`, balance: 0n, authorized: true });
        sent.push({ fn: "changeTrust", args: [op.line.getCode()] });
      } else {
        const ic = (op.func as xdr.HostFunction).invokeContract();
        const fn = ic.functionName().toString();
        const args = ic.args().map((x) => scValToNative(x));
        sent.push({ fn, args });
        if (Address.fromScAddress(ic.contractAddress()).toString() === fx.router && fn === "swap") {
          if (opts.failSwap) return Promise.reject(new Error("transaction failed (txFailed)"));
          const spend = BigInt(args[5] as bigint);
          a.xlm -= spend;
          const t = a.trustlines.find((x) => x.asset === aquaAsset)!;
          t.balance += (spend * (opts.rate ?? 22n * AQUA)) / XLM;
        }
      }
      return Promise.resolve({ hash: "ab".repeat(32), ledger: 101, feeCharged: 100n, returnValue: null });
    },
  };
  return Object.assign(chain, { accounts, sent, views });
}

Deno.test("the swap adds the AQUA trustline, spends the depth-checked amount and gets at least the minimum", async () => {
  const deployer = Keypair.random();
  const c = fakeChain();
  c.accounts.set(deployer.publicKey(), { id: deployer.publicKey(), sequence: "5", xlm: 10_000n * XLM, trustlines: [], signers: [], thresholds: { low: 0, med: 0, high: 0 } });
  const d = await depthCheck(routerEstimate(c, fx), 50n * AQUA);
  assert(d.ok);
  assertEquals(c.views.map((v) => v.fn), ["estimate_swap", "estimate_swap"]);
  const got = await acquireAqua(c, deployer, fx, d.spend, d.minOut);
  assertEquals(c.sent.map((s) => s.fn), ["changeTrust", "swap"]);
  const swap = c.sent[1].args;
  assertEquals(swap[0], deployer.publicKey());
  assertEquals([swap[2], swap[3]], [fx.pool.xlmSac, fx.aqua.sac]);
  assertEquals(Buffer.from(swap[4] as Uint8Array).toString("hex"), fx.pool.poolIndex);
  assertEquals([swap[5], swap[6]], [d.spend, d.minOut]);
  assert(got.held >= d.minOut);
  // A re-run that already holds the AQUA doesn't swap again.
  const again = await acquireAqua(c, deployer, fx, d.spend, d.minOut);
  assertEquals([again.trustline, again.swap], [null, null]);
  assertEquals(c.sent.length, 2);
});

Deno.test("a failed swap surfaces as an error (the deploy turns it into Aquarius off on testnet-qa); 2,000 XLM is the most", async () => {
  const deployer = Keypair.random();
  const c = fakeChain({ failSwap: true });
  c.accounts.set(deployer.publicKey(), { id: deployer.publicKey(), sequence: "5", xlm: 10_000n * XLM, trustlines: [], signers: [], thresholds: { low: 0, med: 0, high: 0 } });
  await assertRejects(() => acquireAqua(c, deployer, fx, 3n * XLM, 55n * AQUA), Error, "txFailed");
  assertEquals(c.sent.map((s) => s.fn), ["changeTrust", "swap"]);
  await assertRejects(() => acquireAqua(c, deployer, fx, MAX_SWAP_STROOPS + 1n, 55n * AQUA), Error, "more than 2000 XLM");
  assertEquals(c.sent.length, 2, "nothing is sent for a swap above the cap");
});
