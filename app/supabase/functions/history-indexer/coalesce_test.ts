// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { Coalescer, type Fragment } from "./coalesce.ts";
import type { CompactLog } from "./logs.ts";
import { merge, type Range } from "./ranges.ts";

const log = (b: number, i = 0): CompactLog => ({ a: "0x" + "1".repeat(40), t: ["0x" + "2".repeat(64)], d: "0x", n: 0, b, h: "0x" + "3".repeat(64), i, s: 1 });
// A piece of 10 blocks per index k: [10k, 10k + 9], one log in its first block.
const piece = (k: number) => ({ from: 10 * k, to: 10 * k + 9, logs: [log(10 * k)], item: k });

// A deterministic shuffle.
function shuffled<T>(list: T[], seed: number): T[] {
  const out = [...list];
  let s = seed;
  for (let i = out.length - 1; i > 0; i--) {
    s = (s * 1_103_515_245 + 12_345) % 2 ** 31;
    const j = s % (i + 1);
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

// What the old coalescing did (one range per key, flushed by any piece not adjacent to it, at most `max` pieces): the
// number of commits for these pieces in this order.
function oldCommits(pieces: { from: number; to: number }[], max: number): number {
  let commits = 0;
  let cur: { from: number; to: number; n: number } | null = null;
  for (const p of pieces) {
    if (cur && (p.to + 1 === cur.from || cur.to + 1 === p.from)) {
      cur = { from: Math.min(cur.from, p.from), to: Math.max(cur.to, p.to), n: cur.n + 1 };
    } else {
      if (cur) commits++;
      cur = { from: p.from, to: p.to, n: 1 };
    }
    if (cur.n >= max) { commits++; cur = null; }
  }
  return commits + (cur ? 1 : 0);
}

Deno.test("coalesce: adjacent pieces in order make one fragment; it leaves when it holds maxPieces", () => {
  const c = new Coalescer<string, number>(4, 15_000);
  const out: Fragment<string, number>[] = [];
  for (const k of [9, 8, 7]) out.push(...c.add("a", "meta", piece(k).from, piece(k).to, piece(k).logs, k, 0, 2_000));
  assertEquals(out, []);
  assertEquals(c.size, 1);
  out.push(...c.add("a", "meta", 60, 69, [log(60)], 6, 0, 2_000));
  assertEquals(out.length, 1);
  assertEquals([out[0].from, out[0].to, out[0].pieces, out[0].meta], [60, 99, 4, "meta"]);
  assertEquals(out[0].logs.map((l) => l.b), [60, 70, 80, 90], "in block order");
  assertEquals(out[0].items.sort(), [6, 7, 8, 9]);
  assertEquals(c.size, 0);
});

Deno.test("coalesce: pieces out of order still join; a piece closing a gap joins both sides", () => {
  const c = new Coalescer<null, number>(100, 15_000);
  const add = (k: number, now = 0) => c.add("a", null, 10 * k, 10 * k + 9, [log(10 * k, k)], k, now, 2_000);
  add(9); add(7); add(5);
  assertEquals(c.size, 3, "three disjoint fragments");
  add(8);                     // joins 9 above and 7 below
  assertEquals(c.size, 2);
  add(6, 1_000);              // joins [70, 99] above and 5 below
  assertEquals(c.size, 1);
  const [f] = c.drain();
  assertEquals([f.from, f.to, f.pieces, f.firstAt], [50, 99, 5, 0]);
  assertEquals(f.logs.map((l) => l.b), [50, 60, 70, 80, 90]);
});

Deno.test("coalesce: keys never mix; gaps and overlaps are never bridged", () => {
  const c = new Coalescer<string, number>(100, 15_000);
  c.add("a", "a", 0, 9, [], 1, 0, 2_000);
  c.add("b", "b", 10, 19, [], 2, 0, 2_000);   // adjacent, another key
  c.add("a", "a", 11, 19, [], 3, 0, 2_000);   // a gap of one block (10)
  c.add("a", "a", 5, 14, [], 4, 0, 2_000);    // overlaps both: adjacent to neither
  const all = c.drain().map((f) => [f.key, f.from, f.to, f.pieces]).sort();
  assertEquals(all, [["a", 0, 9, 1], ["a", 11, 19, 1], ["a", 5, 14, 1], ["b", 10, 19, 1]]);
});

Deno.test("coalesce: a fragment leaves at maxLogs logs, by age, and the largest first under back-pressure", () => {
  const c = new Coalescer<null, number>(100, 15_000);
  const many = (b: number, n: number) => Array.from({ length: n }, (_, i) => log(b, i));
  assertEquals(c.add("a", null, 0, 9, many(0, 1_200), 1, 0, 2_000), []);
  const full = c.add("a", null, 10, 19, many(10, 900), 2, 0, 2_000);
  assertEquals(full.map((f) => [f.from, f.to, f.logs.length]), [[0, 19, 2_100]]);
  c.add("b", null, 0, 9, many(0, 5), 3, 1_000, 2_000);
  c.add("c", null, 0, 9, many(0, 50), 4, 5_000, 2_000);
  c.add("d", null, 0, 9, many(0, 7), 5, 9_000, 2_000);
  assertEquals(c.commits(2_000), 3);
  assertEquals(c.due(15_999).map((f) => f.key), []);
  assertEquals(c.due(16_000).map((f) => f.key), ["b"]);
  assertEquals(c.largest()?.key, "c");
  assertEquals(c.drain().map((f) => f.key), ["d"]);
  assertEquals(c.largest(), null);
  // The commits a fragment past the commit size makes.
  c.add("e", null, 0, 9, many(0, 4_500), 6, 0, 10_000);
  assertEquals(c.commits(2_000), 3);
});

Deno.test("coalesce: any arrival order — every fragment is exactly the union of the whole pieces it holds", () => {
  for (let seed = 1; seed <= 50; seed++) {
    const ks = shuffled(Array.from({ length: 60 }, (_, k) => k).filter((k) => k % 17 !== 5), seed); // some pieces never answer
    const c = new Coalescer<null, number>(8, 15_000);
    const out: Fragment<null, number>[] = [];
    for (const k of ks) out.push(...c.add("a", null, 10 * k, 10 * k + 9, [log(10 * k, k)], k, 0, 2_000));
    out.push(...c.drain());
    const seen: number[] = [];
    for (const f of out) {
      const ranges: Range[] = f.items.map((k) => [10 * k, 10 * k + 9]);
      assertEquals(merge(ranges), [[f.from, f.to]], `seed ${seed}: a fragment is one run of touching pieces`);
      assertEquals(f.pieces, f.items.length);
      assert(f.pieces <= 2 * 8 - 1, "two fragments under the limit and the piece between them, at most");
      assertEquals(f.logs.map((l) => l.b), [...f.items].sort((a, b) => a - b).map((k) => 10 * k), "its pieces' logs, in block order");
      seen.push(...f.items);
    }
    assertEquals(seen.sort((a, b) => a - b), [...ks].sort((a, b) => a - b), "every piece exactly once");
  }
});

Deno.test("coalesce: adjacent pieces arriving out of order make far fewer commits than one range per key did", () => {
  // 120 adjacent pieces of one scan, read by several endpoints at once: in blocks of 6 (a batch), each block's
  // answers and the blocks themselves a little out of order.
  const ks: number[] = [];
  for (let b = 0; b < 20; b++) ks.push(...shuffled([0, 1, 2, 3, 4, 5].map((i) => 119 - (6 * b + i)), b + 1));
  for (let k = 0; k + 1 < ks.length; k += 5) [ks[k], ks[k + 1]] = [ks[k + 1], ks[k]];
  const before = oldCommits(ks.map((k) => ({ from: 10 * k, to: 10 * k + 9 })), 10);
  const c = new Coalescer<null, number>(40, 15_000);
  let after = 0;
  for (const k of ks) after += c.add("a", null, 10 * k, 10 * k + 9, [], k, 0, 2_000).length;
  after += c.drain().length;
  assertEquals(after, 3, "120 pieces, 40 to a commit");
  assertEquals(before, 80, "one range per key, flushed by every piece out of order");
  // In order, the old rule made 12 (10 pieces each); the new one 3.
  assertEquals(oldCommits(Array.from({ length: 120 }, (_, i) => ({ from: 10 * (119 - i), to: 10 * (119 - i) + 9 })), 10), 12);
});
