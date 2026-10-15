// The deploy's TTL step (lib/ttl-extend.ts) against an in-memory chain that charges rent per entry and ledger at
// testnet's 2026-10-15 rates and, like the SDK, refuses a transaction whose fee doesn't fit a uint32.
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Account, Address, hash, Keypair, StrKey, type Transaction, xdr } from "@stellar/stellar-sdk";
import type { AccountInfo, Chain, TxOutcome } from "./preflight-v2.ts";
import { CODE_STEP_DAYS, codeKey, codeSteps, extendTtl, LEDGERS_PER_DAY } from "./ttl-extend.ts";

const DAY = LEDGERS_PER_DAY;
const UINT32_MAX = 4_294_967_295n;
const XLM = 10_000_000;
const cid = (s: string) => StrKey.encodeContract(hash(Buffer.from(s)));
const hex = (s: string) => Buffer.from(hash(Buffer.from(s))).toString("hex");

/** Rent in stroops per ledger: a 128 KB WASM 10.4 XLM a day, launchpad-v2's 90 KB 7.4, an instance 0.01. */
const perLedger = (xlmPerDay: number) => (xlmPerDay * XLM) / DAY;

class RentChain implements Chain {
  passphrase = "Test SDF Network ; September 2015";
  ledger = 5_210_000;
  seq = 100n;
  ttl = new Map<string, number>();
  rate = new Map<string, number>();
  sent: { keys: string[]; extendTo: number; fee: bigint }[] = [];
  failAt = -1;

  static id(k: xdr.LedgerKey): string {
    return k.switch().name === "contractCode"
      ? Buffer.from(k.contractCode().hash()).toString("hex")
      : Address.fromScAddress(k.contractData().contract()).toString();
  }
  private parts(tx: Transaction) {
    const fp = tx.toEnvelope().v1().tx().ext().sorobanData().resources().footprint();
    const keys = fp.readOnly().map(RentChain.id);
    const extendTo = (tx.operations[0] as unknown as { extendTo: number }).extendTo;
    const rent = keys.reduce((sum, k) => sum + this.rate.get(k)! * Math.max(0, this.ledger + extendTo - this.ttl.get(k)!), 0);
    return { keys, extendTo, rent: BigInt(Math.ceil(rent)) };
  }
  latestLedger() {
    return Promise.resolve(this.ledger);
  }
  liveUntil(contracts: string[], hashes: string[]) {
    const all = [...contracts, ...hashes];
    if (new Set(all).size !== all.length) return Promise.reject(new Error("could not query captive core (a key named twice)"));
    return Promise.resolve(new Map(all.map((k) => [k, this.ttl.get(k) ?? null])));
  }
  sourceAccount(id: string) {
    return Promise.resolve(new Account(id, this.seq.toString()));
  }
  /** As the kit's prepare: the resource fee raised 1.3× plus 100,000, and the SDK's uint32 limit on the total. */
  prepare(tx: Transaction) {
    const total = 100n + (this.parts(tx).rent * 13n) / 10n + 100_000n;
    if (total > UINT32_MAX) return Promise.reject(new Error(`Total fee (baseFee * operations + resourceFee) exceeds the maximum uint32 value (4294967295). Got ${total}.`));
    return Promise.resolve(tx);
  }
  submit(tx: Transaction): Promise<TxOutcome> {
    if (this.sent.length === this.failAt) return Promise.reject(new Error("transaction failed (txFAILED)"));
    const { keys, extendTo, rent } = this.parts(tx);
    this.seq += 1n;
    this.ledger += 1;
    for (const k of keys) this.ttl.set(k, Math.max(this.ttl.get(k)!, this.ledger + extendTo));
    this.sent.push({ keys, extendTo, fee: rent + 100n });
    return Promise.resolve({ hash: "ab".repeat(32), ledger: this.ledger, feeCharged: rent + 100n, returnValue: null });
  }
  // Unused by the TTL step.
  account(_id: string): Promise<AccountInfo | null> {
    return Promise.resolve(null);
  }
  contractWasmHash(_id: string) {
    return Promise.resolve(null);
  }
  instanceStorage(_id: string) {
    return Promise.resolve(null);
  }
  codeExists(_h: string) {
    return Promise.resolve(false);
  }
  view(): Promise<xdr.ScVal> {
    return Promise.reject(new Error("no views"));
  }
  friendbot() {
    return Promise.resolve();
  }
}

function world() {
  const c = new RentChain();
  const add = (k: string, daysLeft: number | null, xlmPerDay: number) => {
    if (daysLeft !== null) c.ttl.set(k, c.ledger + Math.round(daysLeft * DAY));
    c.rate.set(k, perLedger(xlmPerDay));
    return k;
  };
  const e = {
    pad: add(cid("launchpad-v2"), 7, 0.01),
    mo: add(cid("moments-v2"), 7, 0.01),
    factory: add(cid("soroswap factory"), 94.2, 0.01),
    gone: add(cid("archived"), null, 0.01),
    big: add(hex("128 KB wasm"), 7, 10.4),
    padCode: add(hex("launchpad-v2 wasm"), 7, 7.4),
    factoryCode: add(hex("factory wasm"), 94.2, 0.6),
    pairCode: add(hex("pair wasm"), 177.2, 2),
    fresh: add(hex("extended already"), 200, 7.4),
  };
  return { c, e };
}

Deno.test("ttl-extend: code steps add CODE_STEP_DAYS each and end exactly at the target", () => {
  assertEquals(CODE_STEP_DAYS, 25);
  assertEquals(codeSteps(7 * DAY, 179 * DAY).map((s) => s / DAY), [32, 57, 82, 107, 132, 157, 179]);
  assertEquals(codeSteps(177 * DAY, 179 * DAY), [179 * DAY]);
  assertEquals(codeSteps(200 * DAY, 179 * DAY), [179 * DAY]);
  assertEquals(codeSteps(-5, 30 * DAY, 25).map((s) => s / DAY), [25, 30]);
  // The deploy's 75 days: three transactions for a freshly uploaded WASM (7 days).
  assertEquals(codeSteps(7 * DAY, 75 * DAY).map((s) => s / DAY), [32, 57, 75]);
});

Deno.test("ttl-extend: one batch of every WASM can't be paid in one transaction, at 75 days nor at 30 (why the step exists)", async () => {
  const { c, e } = world();
  const { TransactionBuilder, Operation, SorobanDataBuilder, BASE_FEE } = await import("@stellar/stellar-sdk");
  const batch = (days: number, keys: string[]) =>
    new TransactionBuilder(new Account(Keypair.random().publicKey(), "1"), { fee: BASE_FEE, networkPassphrase: c.passphrase })
      .addOperation(Operation.extendFootprintTtl({ extendTo: days * DAY }))
      .setSorobanData(new SorobanDataBuilder().setReadOnly(keys.map(codeKey)).build())
      .setTimeout(60)
      .build();
  // launchpad-v2's WASM alone, 7 → 75 days: about 500 XLM, 650 with the headroom.
  await assertRejects(() => c.prepare(batch(75, [e.padCode])), Error, "exceeds the maximum uint32 value");
  // The WASMs together, 7 → 30 days (what a keepAlive batch of 20 would send).
  await assertRejects(() => c.prepare(batch(30, [e.big, e.padCode, e.factoryCode])), Error, "exceeds the maximum uint32 value");
  // One step of one WASM fits.
  await c.prepare(batch(7 + CODE_STEP_DAYS, [e.big]));
});

Deno.test("ttl-extend: the deploy's 75 days: entries under 75 days reach it, instances together and each WASM in steps, no fee over the limit", async () => {
  const { c, e } = world();
  const before = c.ledger;
  const lines: string[] = [];
  const payer = Keypair.random();
  const r = await extendTtl(
    c,
    payer,
    [e.pad, e.mo, e.factory, e.gone, e.pad],
    [e.big, e.padCode, e.factoryCode, e.pairCode, e.fresh],
    75,
    75,
    (l) => lines.push(l),
    (k) => (k === e.padCode ? "dyor_launchpad_v2.wasm code" : k.slice(0, 8)),
  );
  // The archived instance is left out; the Soroswap-like entries (94.2 and 177.2 days) and the WASM with 200 days left
  // have more than 75 days and aren't touched.
  assertEquals(r.extended, 2 + 2);
  for (const k of [e.pad, e.mo, e.big, e.padCode]) {
    assert(c.ttl.get(k)! >= before + 75 * DAY, `${k} reaches 75 days`);
    assert(c.ttl.get(k)! <= c.ledger + 75 * DAY, `${k} isn't extended past 75 days`);
  }
  for (const [k, days] of [[e.factory, 94.2], [e.factoryCode, 94.2], [e.pairCode, 177.2], [e.fresh, 200]] as const) {
    assertEquals(c.ttl.get(k), before + Math.round(days * DAY), `${k} untouched`);
  }
  assertEquals(c.ttl.has(e.gone), false);
  // One transaction for the two instances; 3 steps (32, 57, 75 days) for each WASM from 7 days.
  assertEquals(c.sent[0].keys.sort(), [e.pad, e.mo].sort());
  assertEquals(c.sent.length, 1 + 3 + 3);
  assert(c.sent.slice(1).every((t) => t.keys.length === 1), "each WASM alone");
  assertEquals(r.transactions, c.sent.length);
  assertEquals(r.fee, c.sent.reduce((s, t) => s + t.fee, 0n));
  // The largest step (the 128 KB WASM, 25 days) stays well under the 429 XLM a transaction can pay.
  const largest = c.sent.reduce((m, t) => (t.fee > m ? t.fee : m), 0n);
  assert((largest * 13n) / 10n + 100_100n < UINT32_MAX, `largest step ${largest}`);
  assert(largest < 270n * BigInt(XLM), `largest step ${Number(largest) / XLM} XLM`);
  assertStringIncludes(lines.join("\n"), "extended 2 instances to 75.0 days");
  assertStringIncludes(lines.join("\n"), "extended dyor_launchpad_v2.wasm code to 32.0 days");
  // 68 days of rent for the 7.4 XLM-a-day WASM: about 503 XLM, over three transactions.
  const padFee = c.sent.filter((t) => t.keys[0] === e.padCode).reduce((s, t) => s + t.fee, 0n);
  assert(Math.abs(Number(padFee) / XLM - 68 * 7.4) < 2, `${Number(padFee) / XLM} XLM`);
});

Deno.test("ttl-extend: a transaction that fails stops the step; running it again goes on from where it stopped", async () => {
  const { c, e } = world();
  const before = c.ledger;
  c.failAt = 2;
  await assertRejects(() => extendTtl(c, Keypair.random(), [e.pad], [e.padCode], 75, 75), Error, "txFAILED");
  assertEquals(c.sent.length, 2);
  c.failAt = -1;
  const again = await extendTtl(c, Keypair.random(), [e.pad], [e.padCode], 75, 75);
  // The instance has a few ledgers under 75 days, so under the threshold: extended again, for those ledgers.
  assert(c.ttl.get(e.padCode)! >= before + 75 * DAY);
  assertEquals(again.transactions, 1 + 2, "the instance again, then the WASM's two remaining steps from 32 days");
});
