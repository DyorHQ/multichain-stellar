// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { checkAnswer, type CompactLog, fillTimestamps, splitForCommit } from "./logs.ts";

const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CURVEBUY = "0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455";
const W1 = "0x" + "a1".repeat(20);
const W2 = "0x" + "b2".repeat(20);
const W3 = "0x" + "c3".repeat(20);
const pad = (a: string) => "0x" + "0".repeat(24) + a.slice(2);
const hex = (n: number) => "0x" + n.toString(16);
const tx = (n: number) => "0x" + n.toString(16).padStart(64, "0");

const transfersIn = { kind: "wallet" as const, walletTopic: 2 as const, addresses: [], topic0s: [TRANSFER] };
const launchpad = { kind: "global" as const, walletTopic: 1 as const, addresses: [], topic0s: [CURVEBUY] };
const listed = { kind: "global" as const, walletTopic: 2 as const, addresses: ["0x" + "77".repeat(20)], topic0s: [TRANSFER] };

function rpcLog(b: number, i: number, topics: string[], over: Record<string, unknown> = {}) {
  return { address: "0x" + "66".repeat(20), topics, data: "0x" + "00".repeat(32), blockNumber: hex(b), transactionHash: tx(b * 100 + i),
           logIndex: hex(i), blockTimestamp: hex(1_700_000_000 + b), removed: false, transactionIndex: "0x0", blockHash: tx(b), ...over };
}
const item = { from: 100, to: 200, wallets: [W1, W2] };

Deno.test("checkAnswer: accepts, lowercases, dedupes, sorts", () => {
  const out = checkAnswer(transfersIn, item, [
    rpcLog(150, 2, [TRANSFER, pad(W3), pad(W2)]),
    rpcLog(120, 0, [TRANSFER.toUpperCase().replace("0X", "0x"), pad(W3), pad(W1).toUpperCase().replace("0X", "0x")], { address: "0x" + "AB".repeat(20) }),
    rpcLog(150, 2, [TRANSFER, pad(W3), pad(W2)]),
    rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)]),
  ]);
  assert(out.ok);
  assertEquals(out.logs.map((l) => [l.b, l.i]), [[120, 0], [150, 1], [150, 2]]);
  assertEquals(out.logs[0].a, "0x" + "ab".repeat(20));
  assertEquals(out.logs[0].t, [TRANSFER, pad(W3), pad(W1)]);
  assertEquals(out.logs[0], { a: "0x" + "ab".repeat(20), t: [TRANSFER, pad(W3), pad(W1)], d: "0x" + "00".repeat(32), n: 32, b: 120, h: tx(12000), i: 0, s: 1_700_000_120 });
  assertEquals(out.missingTimestamps, []);
  assertEquals(checkAnswer(transfersIn, item, []), { ok: true, logs: [], missingTimestamps: [] });
});

Deno.test("checkAnswer: every rejection rejects the whole answer", () => {
  const good = rpcLog(150, 0, [TRANSFER, pad(W3), pad(W1)]);
  const cases: [string, unknown, typeof transfersIn | typeof listed][] = [
    ["not a list", { result: [] }, transfersIn],
    ["below the range", rpcLog(99, 0, [TRANSFER, pad(W3), pad(W1)]), transfersIn],
    ["above the range", rpcLog(201, 0, [TRANSFER, pad(W3), pad(W1)]), transfersIn],
    ["another topic0", rpcLog(150, 1, [CURVEBUY, pad(W3), pad(W1)]), transfersIn],
    ["a wallet not asked", rpcLog(150, 1, [TRANSFER, pad(W1), pad(W3)]), transfersIn],
    ["no wallet topic", rpcLog(150, 1, [TRANSFER, pad(W1)]), transfersIn],
    ["a contract outside the list", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)]), listed],
    ["removed", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { removed: true }), transfersIn],
    ["five topics", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1), tx(1), tx(2)]), transfersIn],
    ["short topic", rpcLog(150, 1, [TRANSFER, "0x1234", pad(W1)]), transfersIn],
    ["odd data", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { data: "0x123" }), transfersIn],
    ["bad address", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { address: "0x12" }), transfersIn],
    ["bad hash", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { transactionHash: "0x12" }), transfersIn],
    ["decimal block", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { blockNumber: "150" }), transfersIn],
    ["padded quantity", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { logIndex: "0x01" }), transfersIn],
    ["bad timestamp", rpcLog(150, 1, [TRANSFER, pad(W3), pad(W1)], { blockTimestamp: "soon" }), transfersIn],
    ["not an object", 7, transfersIn],
  ];
  for (const [what, bad, def] of cases) {
    const answer = what === "not a list" ? bad : [good, bad];
    const out = checkAnswer(def, item, answer);
    assertEquals(out.ok, false, what);
  }
});

Deno.test("checkAnswer: global scans skip logs without an address at the wallet topic; 16 KiB data omitted; missing timestamps", () => {
  const big = "0x" + "ab".repeat(16_385);
  const out = checkAnswer(launchpad, { from: 100, to: 200, wallets: [] }, [
    rpcLog(110, 0, [CURVEBUY, pad(W1), pad(W2)]),
    rpcLog(111, 0, [CURVEBUY, "0xff" + "00".repeat(31)]),
    rpcLog(112, 0, [CURVEBUY]),
    rpcLog(113, 0, [CURVEBUY, pad(W2)], { data: big }),
    rpcLog(114, 0, [CURVEBUY, pad(W2)], { data: "0x" + "cd".repeat(16_384), blockTimestamp: undefined }),
  ]);
  assert(out.ok);
  assertEquals(out.logs.map((l) => l.b), [110, 113, 114]);
  assertEquals([out.logs[1].d, out.logs[1].n], [null, 16_385]);
  assertEquals(out.logs[2].n, 16_384);
  assertEquals(out.logs[2].d!.length, 2 + 2 * 16_384);
  assertEquals(out.logs[2].s, null);
  assertEquals(out.missingTimestamps, [114]);
  assertEquals(fillTimestamps(out.logs, new Map([[114, 99]])), true);
  assertEquals(out.logs[2].s, 99);
  assertEquals(fillTimestamps([{ ...out.logs[0], s: null }], new Map()), false);
});

const L = (b: number, i = 0): CompactLog => ({ a: "0x" + "66".repeat(20), t: [TRANSFER], d: "0x", n: 0, b, h: tx(b), i, s: 1 });

Deno.test("splitForCommit: cuts only at block boundaries, covering exactly [from, to]", () => {
  const logs = [L(10), L(10, 1), L(12), L(13), L(13, 1), L(13, 2), L(20)];
  const parts = splitForCommit(logs, 5, 30, 3);
  assertEquals(parts.map((p) => [p.from, p.to, p.logs.length]), [[5, 12, 3], [13, 19, 3], [20, 30, 1]]);
  // Each part ≤ max unless a single block alone exceeds it; the parts are contiguous and cover everything.
  const many = Array.from({ length: 10 }, (_, k) => L(50, k));
  const big = splitForCommit([L(40), ...many, L(60)], 0, 99, 4);
  assertEquals(big.map((p) => [p.from, p.to, p.logs.length]), [[0, 49, 1], [50, 59, 10], [60, 99, 1]]);
  assertEquals(splitForCommit([], 7, 9, 2), [{ from: 7, to: 9, logs: [] }]);
  for (const [from, to, max] of [[5, 30, 1], [5, 30, 2], [5, 30, 100]] as const) {
    const p = splitForCommit(logs, from, to, max);
    assertEquals(p[0].from, from);
    assertEquals(p[p.length - 1].to, to);
    for (let k = 1; k < p.length; k++) assertEquals(p[k].from, p[k - 1].to + 1);
    assertEquals(p.flatMap((x) => x.logs), logs);
    for (const part of p) for (const l of part.logs) assert(l.b >= part.from && l.b <= part.to);
  }
});
