// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assertEquals } from "jsr:@std/assert@1";
import { confirmFirstTx, firstTransactionBlock, locateFirstTx, type NonceSource, reverifyFirstTx } from "./firsttx.ts";

// A wallet whose nonce becomes 1 at `first` (and grows after), or never (first = null).
const history = (first: number | null) => async (b: number) => (first === null || b < first ? 0n : BigInt(1 + Math.floor((b - first) / 7)));
const brute = async (nonceAt: (b: number) => Promise<bigint>, head: number) => {
  for (let b = 0; b <= head; b++) if ((await nonceAt(b)) > 0n) return b;
  return null;
};
let seed = 42;
const random = () => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31);
const noSleep = async () => {};

Deno.test("firstTransactionBlock equals a brute-force scan on 200 random histories", async () => {
  for (let k = 0; k < 200; k++) {
    const head = 1 + Math.floor(random() * 600);
    const first = random() < 0.15 ? null : Math.floor(random() * (head + 1));
    const nonceAt = history(first);
    assertEquals(await firstTransactionBlock(nonceAt, head), await brute(nonceAt, head), `head ${head} first ${first}`);
  }
});

Deno.test("firstTransactionBlock: ~log2(head) reads; none; a re-check above a known zero", async () => {
  let reads = 0;
  const counted = (first: number | null) => async (b: number) => { reads++; return await history(first)(b); };
  assertEquals(await firstTransactionBlock(counted(103_551_773), 111_739_139), 103_551_773);
  assertEquals(reads <= 29, true, `${reads} reads`);
  assertEquals(await firstTransactionBlock(counted(null), 1_000), null);
  // A wallet that had sent nothing by block 5,000 (`none` stored with head 5,000) is searched only above it.
  reads = 0;
  const seen: number[] = [];
  const watched = async (b: number) => { seen.push(b); return await history(7_000)(b); };
  assertEquals(await firstTransactionBlock(watched, 9_000, 5_000), 7_000);
  assertEquals(seen.every((b) => b > 5_000), true);
  assertEquals(await confirmFirstTx(history(7_000), 7_000), true);
  assertEquals(await confirmFirstTx(history(7_000), 7_001), false);
  assertEquals(await confirmFirstTx(history(0), 0), true);
});

const source = (label: string, nonceAt: (b: number) => Promise<bigint>, calls: string[] = []): NonceSource =>
  ({ label, nonceAt: async (b) => { calls.push(`${label}:${b}`); return await nonceAt(b); } });
const failing = (label: string): NonceSource => ({ label, nonceAt: () => Promise.reject(new Error("historical state that is not available")) });

Deno.test("locateFirstTx: bisects on the first source that answers, confirms on another", async () => {
  const calls: string[] = [];
  const out = await locateFirstTx([failing("rpc4"), source("rpc1", history(1_234), calls), source("rpc2", history(1_234), calls)], 10_000, { sleep: noSleep });
  assertEquals(out, { state: "found", block: 1_234, source: "rpc1+rpc2" });
  // The two confirmation reads went to rpc2, the bisection to rpc1.
  assertEquals(calls.slice(-2), ["rpc2:1234", "rpc2:1233"]);
  assertEquals(calls.slice(0, -2).every((c) => c.startsWith("rpc1:")), true);
  assertEquals(await locateFirstTx([source("rpc4", history(null)), source("rpc1", history(null))], 10_000, { sleep: noSleep }), { state: "none" });
  assertEquals(await locateFirstTx([failing("rpc4"), failing("rpc1")], 10_000, { sleep: noSleep }), { state: "failed" });
});

Deno.test("locateFirstTx: a source that lies once (a pruned node answering 0 below the first tx) is caught: nothing stored", async () => {
  // rpc4 answers 0 for block 4,095 (the bisection's first midpoint) although the first transaction is at 4,000: the
  // bisection lands on 4,096, and rpc1, asked for nonce(4,095), says 1.
  const asked: string[] = [];
  const liar = async (b: number) => (b === 4_095 ? 0n : await history(4_000)(b));
  const out = await locateFirstTx([source("rpc4", liar, asked), source("rpc1", history(4_000), asked)], 8_191, { sleep: noSleep });
  assertEquals(asked.includes("rpc4:4095"), true);
  assertEquals(out, { state: "unconfirmed" });
  // A source lying exactly at the boundary the bisection lands on (nonce(b − 1) reported 0 although it is 1).
  const boundary = async (b: number) => (b >= 3_000 && b < 4_096 ? 0n : await history(3_000)(b));
  assertEquals(await locateFirstTx([source("rpc4", boundary), source("rpc1", history(3_000))], 8_191, { sleep: noSleep }), { state: "unconfirmed" });
});

Deno.test("locateFirstTx: one archive source only → the same source twice, apart", async () => {
  const slept: number[] = [];
  const out = await locateFirstTx([source("rpc2", history(77))], 1_000, { sleep: async (ms) => { slept.push(ms); } });
  assertEquals(out, { state: "found", block: 77, source: "rpc2+rpc2" });
  assertEquals(slept, [2_000, 2_000]);
});

Deno.test("reverifyFirstTx: the same block, or an earlier one found and confirmed", async () => {
  assertEquals(await reverifyFirstTx([source("rpc4", history(500)), source("rpc1", history(500))], { block: 500, source: "rpc4+rpc1" }, { sleep: noSleep }), { state: "same" });
  // The stored block was too late: an earlier transaction exists.
  const out = await reverifyFirstTx([source("rpc4", history(200)), source("rpc1", history(200))], { block: 500, source: "rpc1+rpc4" }, { sleep: noSleep });
  assertEquals(out, { state: "found", block: 200, source: "rpc4+rpc1", movedEarlier: true });
  assertEquals(await reverifyFirstTx([source("rpc4", history(0))], { block: 0, source: "rpc4+rpc4" }, { sleep: noSleep }), { state: "same" });
  assertEquals(await reverifyFirstTx([failing("rpc4")], { block: 9, source: "rpc4+rpc4" }, { sleep: noSleep }), { state: "failed" });
});
