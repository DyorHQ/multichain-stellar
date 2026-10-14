// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { DEFAULT_PLAN, type IndexerState, type PlanOptions, Planner, type WalletState, type WorkItem } from "./planner.ts";
import type { Range } from "./ranges.ts";
import { bundledDefs, type ScanDef, type ScanId } from "./scans.ts";

const NOW = Date.parse("2026-10-08T12:00:00Z");
const H = 3_000_000;
const HOUR = 3_600_000;
const W = (n: number) => "0x" + n.toString(16).padStart(40, "0");
// The definitions with their floors moved into the test chain's range (a test database redefines them the same way).
const floors: Partial<Record<ScanId, number>> = { launchpad: 2_000_000, "fee-sharing": 2_000_000, moments: 2_500_000 };
const defs: ScanDef[] = bundledDefs().map((d) => ({ ...d, floor: floors[d.id] ?? d.floor, defVersion: 1 }));
const opts = (over: Partial<PlanOptions> = {}): PlanOptions => ({ ...DEFAULT_PLAN, window: 200_000, ...over });

function wallet(n: number, over: { in?: Range[]; out?: Range[]; requestedAt?: number; deep?: boolean; capIn?: number;
                                   holesIn?: Range[]; holesCheckedAt?: number } = {}): WalletState {
  const scan = (covered: Range[], holes: Range[] = [], cap: number | null = null) =>
    ({ covered, holes, holesCheckedAt: over.holesCheckedAt ?? null, capFloor: cap, head: null, logCount: 0 });
  return {
    wallet: W(n), requestedAt: over.requestedAt ?? NOW - 10 * 60_000, deep: over.deep ?? false,
    firstTx: { state: "unknown", block: null, head: null, checkedAt: null, source: null },
    scans: { "transfers-in": scan(over.in ?? [], over.holesIn ?? [], over.capIn ?? null), "transfers-out": scan(over.out ?? []) },
  };
}
function state(wallets: WalletState[], global: Partial<Record<ScanId, { covered: Range[]; holes?: Range[]; checkedAt?: number }>> = {}): IndexerState {
  return {
    now: NOW, head: H, active: wallets.length, skipped: 0, defs: null, wallets,
    scans: (["launchpad", "fee-sharing", "moments"] as ScanId[]).map((id) => ({
      id, covered: global[id]?.covered ?? [[floors[id]!, H]], holes: global[id]?.holes ?? [], holesCheckedAt: global[id]?.checkedAt ?? null, head: H,
    })),
  };
}
function drain(p: Planner, allowDeep = true, max = 100_000): WorkItem[] {
  const out: WorkItem[] = [];
  for (let item = p.next(allowDeep); item && out.length < max; item = p.next(allowDeep)) out.push(item);
  return out;
}
const covered = (from: number, to = H) => [[from, to]] as Range[];

Deno.test("order: P0 follow, P1 global gaps, P2 window, P3 deep", () => {
  const p = new Planner(state([wallet(1, { in: covered(H - 5_000), out: covered(H - 5_000), deep: true })],
                              { launchpad: { covered: [[2_000_000, H - 100_000]] } }), H, defs, opts(), NOW);
  const items = drain(p);
  const priorities = items.map((i) => i.priority);
  assertEquals(priorities, [...priorities].sort());
  assertEquals(new Set(priorities), new Set([0, 1, 2, 3]));
  assertEquals(items[0], { priority: 0, kind: "follow", scan: "launchpad", defVersion: 1, from: H - 59_999, to: H, wallets: [], attempts: 0 });
  assertEquals(items.filter((i) => i.priority === 1).map((i) => [i.from, i.to]), [[H - 60_000, H - 60_000], [H - 70_000, H - 60_001], [H - 80_000, H - 70_001], [H - 90_000, H - 80_001], [H - 99_999, H - 90_001]]);
});

Deno.test("follow: the 1,200-block overlap, and at most 60,000 blocks (the rest is a gap)", () => {
  const p = new Planner(state([], { launchpad: { covered: [[2_000_000, H - 500_000]] }, moments: { covered: covered(2_500_000, H - 100) } }), H, defs, opts(), NOW);
  const items = drain(p);
  const follow = items.filter((i) => i.priority === 0);
  assertEquals(follow.map((i) => [i.scan, i.from, i.to]), [["launchpad", H - 59_999, H], ["moments", H - 100 - 1_199, H]]);
  // The launchpad gap below the follow is P1, newest first, aligned, down to the old coverage.
  const gaps = items.filter((i) => i.priority === 1 && i.scan === "launchpad");
  assertEquals(gaps[0].to, H - 60_000);
  assertEquals(gaps[gaps.length - 1].from, H - 500_000 + 1);
  for (let k = 1; k < gaps.length; k++) assertEquals(gaps[k].to, gaps[k - 1].from - 1);
  assert(gaps.slice(1).every((g) => g.from % 10_000 === 0 || g.from === H - 500_000 + 1));
});

Deno.test("global gaps never go below a floor, and holes wait 6 hours, then are retried one by one", () => {
  const p = new Planner(state([], {
    launchpad: { covered: [], holes: [[2_100_000, 2_100_000]], checkedAt: NOW - HOUR },
    "fee-sharing": { covered: [[2_000_000, 2_499_999]], holes: [[2_600_000, 2_600_099]], checkedAt: NOW - 7 * HOUR },
  }), H, defs, opts(), NOW);
  const items = drain(p);
  const lp = items.filter((i) => i.scan === "launchpad");
  assert(lp.every((i) => i.from >= 2_000_000));
  assertEquals(lp[lp.length - 1].from, 2_000_000);
  assert(!lp.some((i) => i.from <= 2_100_000 && i.to >= 2_100_000), "a fresh hole is not read again");
  const fee = items.filter((i) => i.scan === "fee-sharing");
  const hole = fee.filter((i) => i.hole);
  assertEquals(hole.map((i) => [i.from, i.to, i.kind, i.single]), [[2_600_000, 2_600_099, "holes", false]]);
  assert(!fee.some((i) => !i.hole && i.from <= 2_600_099 && i.to >= 2_600_000), "the hole is retried as itself, not inside a gap");
  // floorOverride raises a floor (never lowers one: history_commit refuses a global range below the stored floor).
  const q = new Planner(state([], { launchpad: { covered: [] } }), H, defs, opts({ floorOverride: { launchpad: 2_900_000, moments: 1 } }), NOW);
  const qi = drain(q);
  assertEquals(qi.filter((i) => i.scan === "moments").length, 0);
  assertEquals(qi.filter((i) => i.scan === "launchpad").reduce((m, i) => Math.min(m, i.from), H), 2_900_000);
});

Deno.test("tiers: hot every run, warm at ≥ 1,000 behind, cold at ≥ 6,000 behind", () => {
  const ws = [
    wallet(1, { in: covered(0, H - 10), out: covered(0, H - 10), requestedAt: NOW - 30 * 60_000 }),     // hot
    wallet(2, { in: covered(0, H - 999), out: covered(0, H - 999), requestedAt: NOW - 5 * HOUR }),       // warm, too close
    wallet(3, { in: covered(0, H - 1_000), out: covered(0, H - 1_000), requestedAt: NOW - 5 * HOUR }),   // warm, due
    wallet(4, { in: covered(0, H - 5_999), out: covered(0, H - 5_999), requestedAt: NOW - 3 * 86_400_000 }), // cold, too close
    wallet(5, { in: covered(0, H - 6_000), out: covered(0, H - 6_000), requestedAt: NOW - 3 * 86_400_000 }), // cold, due
  ];
  const items = drain(new Planner(state(ws), H, defs, opts(), NOW));
  const followed = items.filter((i) => i.priority === 0 && i.scan === "transfers-in");
  assertEquals(followed.length, 1);
  assertEquals(followed[0].wallets, [W(1), W(3), W(5)]); // most recently requested first
  assertEquals([followed[0].from, followed[0].to], [H - 6_000 - 1_199, H]);
  // A wallet not due is not read near the head by any other pass either.
  for (const w of [W(2), W(4)]) assert(!items.some((i) => i.wallets.includes(w)), `${w} must wait for its tier`);
});

Deno.test("range-major window walk: 150 wallets with mixed coverage → chunks of 100 + 50 in fairness order", () => {
  // Every wallet has [H − 70,000, H − 61,000] of transfers-in (too far behind to follow); even wallets also have
  // [H − 100,000, H − 70,001]. transfers-out is complete.
  const ws: WalletState[] = [];
  for (let n = 1; n <= 150; n++) {
    ws.push(wallet(n, { in: [[H - 70_000, H - 61_000] as Range].concat(n % 2 ? [] : [[H - 100_000, H - 70_001]]), out: covered(H - 199_999) }));
  }
  const items = drain(new Planner(state(ws), H, defs, opts(), NOW));
  assert(items.every((i) => i.priority === 2 && i.scan === "transfers-in"));
  // Pieces shared by everyone go in chunks of 100 + 50, in fairness order.
  const top = items.filter((i) => i.to === H - 1);
  assertEquals(top.map((i) => [i.from, i.wallets.length]), [[H - 10_000, 100], [H - 10_000, 50]]);
  assertEquals(top[0].wallets, ws.slice(0, 100).map((w) => w.wallet));
  assertEquals(top[1].wallets, ws.slice(100).map((w) => w.wallet));
  // Aligned pieces, walking down; [H − 100,000, H − 70,001] only for the 75 odd wallets.
  for (const i of items) assert(i.from % 10_000 === 0 || i.from === H - 199_999 || i.to === H, `${i.from}`);
  const extra = items.filter((i) => i.from >= H - 100_000 && i.to <= H - 70_001);
  assertEquals(extra.length, 3);
  for (const i of extra) assertEquals(i.wallets.length, 75);
  // Each wallet's items cover exactly what it lacks (and may re-read a few covered blocks around an aligned edge).
  for (const n of [1, 2, 149, 150]) {
    const mine = items.filter((i) => i.wallets.includes(W(n))).map((i) => [i.from, i.to] as Range);
    const lacks: Range[] = n % 2 ? [[H - 199_999, H - 70_001], [H - 60_999, H]] : [[H - 199_999, H - 100_001], [H - 60_999, H]];
    for (const g of lacks) assert(mine.some((m) => m[0] <= g[0]) && mine.some((m) => m[1] >= g[1]));
    const blocks = mine.reduce((sum, r) => sum + r[1] - r[0] + 1, 0);
    const need = lacks.reduce((sum, r) => sum + r[1] - r[0] + 1, 0);
    assert(blocks >= need && blocks <= need + 20_000, `wallet ${n}: ${blocks} for ${need}`);
  }
});

Deno.test("P3: only wallets with activity, after P2, and held while new wallets' windows are pending", () => {
  const ws = [wallet(1, { in: covered(H - 199_999), out: covered(H - 199_999), deep: true }),
              wallet(2, { in: covered(H - 199_999), out: covered(H - 199_999), deep: false })];
  const p = new Planner(state(ws), H, defs, opts(), NOW);
  const items = drain(p);
  const deep = items.filter((i) => i.priority === 3);
  assert(deep.length > 0);
  assert(deep.every((i) => i.wallets.length === 1 && i.wallets[0] === W(1)));
  assertEquals(deep[0].to, H - 200_000);
  assertEquals(deep[deep.length - 1].from, 0);
  // A new wallet arrives mid-run: its window comes next, and deep work waits until it is settled.
  const q = new Planner(state(ws), H, defs, opts(), NOW);
  drain(q, true, 3); // P0/P1 nothing, a few deep pieces
  q.addWallets([wallet(9)]);
  assert(q.pendingNewWindows() > 0);
  const handed: WorkItem[] = [];
  for (let item = q.next(q.pendingNewWindows() === 0); item; item = q.next(q.pendingNewWindows() === 0)) {
    handed.push(item);
    if (handed.length > 1_000) break;
  }
  assert(handed.length > 0 && handed.every((i) => i.wallets.includes(W(9)) && i.priority === 2), "only the new wallet's window");
  assert(q.next(q.pendingNewWindows() === 0) === null, "deep work is held while those pieces are outstanding");
  for (const i of handed) q.settle(i);
  assertEquals(q.pendingNewWindows(), 0);
  const after = q.next(true)!;
  assertEquals(after.priority, 3);
});

Deno.test("caps and holes steer the walk; requeue; committed coverage feeds the stats", () => {
  const ws = [wallet(1, { in: [], out: covered(0), capIn: H - 150_000, holesIn: [[H - 5, H - 5]], holesCheckedAt: NOW - HOUR, deep: true })];
  const p = new Planner(state(ws), H, defs, opts(), NOW);
  const items = drain(p);
  const ins = items.filter((i) => i.scan === "transfers-in");
  assert(ins.every((i) => i.from >= H - 150_000), "nothing below the cap floor");
  assert(!ins.some((i) => i.from <= H - 5 && i.to >= H - 5), "the fresh hole is not read");
  assertEquals(ins.filter((i) => i.to >= H - 10_000).map((i) => [i.from, i.to]), [[H, H], [H - 4, H - 1], [H - 10_000, H - 6]]);
  // A cap raised mid-walk stops the walk at the new floor.
  const q = new Planner(state([wallet(2, { out: covered(0) })]), H, defs, opts(), NOW);
  const first = q.next(true)!;
  q.capped(W(2), "transfers-in", first.from);
  assertEquals(drain(q).filter((i) => i.scan === "transfers-in").length, 0);
  // requeue: front first, then the priority's own queue.
  const r = new Planner(state([]), H, defs, opts(), NOW);
  const a = { ...first, attempts: 1 }, b = { ...first, attempts: 2, priority: 0 as const };
  r.requeue(a, false);
  r.requeue(b, true);
  assertEquals(r.next(true), b);
  assertEquals(r.next(true), a);
  // committed → stats.
  const s = new Planner(state([wallet(3, { out: covered(0) })]), H, defs, opts(), NOW);
  assertEquals(s.stats().windowComplete, 0);
  s.committed("transfers-in", [W(3)], [0, H]);
  assertEquals(s.stats(), { planned: 0, new: 0, windowComplete: 1, deepComplete: 1 });
});

Deno.test("next(maxPriority) hands out only work that urgent; giveBack puts an item first in its queue, counted once", () => {
  const p = new Planner(state([wallet(1, { in: covered(H - 5_000), out: covered(H - 5_000), deep: true })],
                              { launchpad: { covered: [[2_000_000, H - 100_000]] } }), H, defs, opts(), NOW);
  const follow = p.next(true, 0)!;
  assertEquals(follow.priority, 0);
  for (let item = p.next(true, 0); item; item = p.next(true, 0)) assertEquals(item.priority, 0);
  assertEquals(p.next(true, 0), null);
  const gap = p.next(true, 1)!;
  assertEquals([gap.priority, gap.kind], [1, "global"]);
  const before = p.kindCounts().global;
  p.giveBack(gap);
  assertEquals(p.kindCounts().global, before - 1);
  // Front work above the bound waits; work within it comes first.
  const deep = { ...gap, priority: 3 as const, kind: "deep" as const };
  p.requeue(deep, true);
  assertEquals(p.next(true, 1), gap);
  assertEquals(p.kindCounts().global, before);
  assertEquals(p.next(true, 3), deep);
});

Deno.test("hasWork: whether work is left, handing nothing out (the deep pass not started, no count moved); next skips held priorities", () => {
  const ws = () => [wallet(1, { in: covered(H - 199_999), out: covered(H - 199_999), deep: true }), wallet(2, { in: covered(0), out: covered(0), deep: true })];
  const p = new Planner(state(ws()), H, defs, opts(), NOW);
  // Only deep work (wallet 1 below its window), before the deep pass has started.
  assertEquals([p.hasWork([0]), p.hasWork([1]), p.hasWork([2]), p.hasWork([3]), p.hasWork()], [false, false, false, true, true]);
  assertEquals([p.counts(), p.kindCounts().deep, p.stats().planned], [{ 0: 0, 1: 0, 2: 0, 3: 0 }, 0, 0]);
  // Held: nothing of that priority is handed out; the planner keeps it.
  assertEquals(p.next(true, 3, new Set([3])), null);
  assertEquals(p.hasWork([3]), true);
  // What next() hands out afterwards is what a planner never asked would hand out.
  const ref = new Planner(state(ws()), H, defs, opts(), NOW);
  const first = p.next(true)!;
  assertEquals(first, ref.next(true));
  assertEquals([first.priority, first.wallets, p.stats().planned], [3, [W(1)], 1]);
  // Started: a pass's next item is looked at, not taken (the same item comes next).
  assertEquals(p.hasWork([3]), true);
  const second = p.next(true)!;
  assertEquals(second, ref.next(true));
  // Given back or re-queued work is left too; drained, nothing is.
  p.giveBack(second);
  assertEquals(p.hasWork([3]), true);
  drain(p);
  assertEquals(p.hasWork(), false);
  p.requeue({ ...first, attempts: 1 }, false);
  assertEquals([p.hasWork([2]), p.hasWork([3])], [false, true]);
  // No deep work: complete to genesis, or no activity; a hole due for a retry inside the deep band is deep work.
  const done = new Planner(state([wallet(3, { in: covered(0), out: covered(0), deep: true }), wallet(4, { in: covered(H - 199_999), out: covered(H - 199_999) })]), H, defs, opts(), NOW);
  assertEquals(done.hasWork(), false);
  const holed = new Planner(state([wallet(5, { in: [[0, 999], [1_001, H]], out: covered(0), holesIn: [[1_000, 1_000]], holesCheckedAt: NOW - 7 * HOUR, deep: true })]), H, defs, opts(), NOW);
  assertEquals(holed.hasWork([3]), true);
  assertEquals(drain(holed).map((i) => [i.priority, i.kind, i.from, i.to]), [[3, "holes", 1_000, 1_000]]);
  assertEquals(holed.hasWork(), false);
});
