// What to read, in priority order, newest first (§11):
//   P0 follow  — the global scans and the followed wallets, from just below their newest covered block to the head
//                (a 1,200-block overlap re-reads what a node behind the head could have clamped, D4); wallets in
//                tiers by how recently the app asked for them (D18);
//   P1 global  — the global scans' gaps down to their floors, then their holes once 6 hours old;
//   P2 window  — every active wallet's last 30 days (8,574,264 blocks), wallets new to the cache in their own pass first;
//   P3 deep    — below the window down to genesis, only for wallets with on-chain activity (D1), and not while new
//                wallets' windows are still pending.
// The wallet passes walk range-major: one aligned 10,000-block piece at a time for every wallet that lacks part of it,
// ≤ 100 wallets per filter, so wallets share requests. The planner keeps its own copy of every coverage, marks what it
// hands out as planned, and learns commits, caps and holes from the run; a dropped piece simply stays a gap.
import { contains, gapsNewestFirst, intersects, merge, newestCovered, piecesDescending, type Range, subtract } from "./ranges.ts";
import type { Priority } from "./pacing.ts";
import { GLOBAL_SCANS, type ScanDef, type ScanId, WALLET_SCANS } from "./scans.ts";

export type WalletScanId = "transfers-in" | "transfers-out";
export type WalletScanState = { covered: Range[]; holes: Range[]; holesCheckedAt: number | null; capFloor: number | null;
                                head: number | null; logCount: number };
export type FirstTxState = { state: "unknown" | "found" | "none"; block: number | null; head: number | null;
                             checkedAt: number | null; source: string | null };
export type WalletState = { wallet: string; requestedAt: number; deep: boolean; firstTx: FirstTxState;
                            scans: Record<WalletScanId, WalletScanState> };
export type ScanState = { id: ScanId; covered: Range[]; holes: Range[]; holesCheckedAt: number | null; head: number | null };
export type IndexerState = { now: number; head: number | null; active: number; skipped: number; scans: ScanState[];
                             wallets: WalletState[]; defs: unknown };

export type ItemKind = "follow" | "global" | "window" | "deep" | "holes";
// Counts how many pieces derived from one pass are still outstanding (pendingNewWindows).
export type Tag = { pending: number };
export type WorkItem = {
  priority: Priority; kind: ItemKind; scan: ScanId; defVersion: number; from: number; to: number; wallets: string[];
  attempts: number; alone?: boolean; single?: boolean; hole?: boolean; tag?: Tag;
  refusingOnly?: boolean; // a past-head refusal: never to a clamping endpoint (D4)
  pastHead?: number;      // past-head refusals of this piece this run (≤ 3, then it waits for the next run)
};

// `align`: the backfill's piece size (10,000 blocks: rpc2's span). run.ts raises it for a run, up to `maxAlign`, to the
// widest span an endpoint able to take backfill has (a keyed provider answering millions of blocks per request); an
// endpoint with a narrower span cuts each piece to its own span (run.ts dispatch), so the requests to rpc2 stay the same.
export type PlanOptions = {
  overlap: number; lag: number; followMax: number; window: number; align: number; maxAlign: number; maxWallets: number; holeRetryMs: number;
  tiers: { hotMs: number; warmMs: number; warmLag: number; coldLag: number };
  floorOverride?: Partial<Record<ScanId, number>>;
};

export const DEFAULT_PLAN: PlanOptions = {
  overlap: 1_200, lag: 600, followMax: 60_000, window: 8_574_264, align: 10_000, maxAlign: 5_000_000, maxWallets: 100, holeRetryMs: 6 * 3_600_000,
  tiers: { hotMs: 3_600_000, warmMs: 86_400_000, warmLag: 1_000, coldLag: 6_000 },
};

const NONE: ReadonlySet<Priority> = new Set();

type Cov = { covered: Range[]; holes: Range[]; holesDue: boolean; planned: Range[]; capFloor: number; retried: Set<string> };
type WalletPlan = { state: WalletState; scans: Record<WalletScanId, Cov>; fresh: boolean; followed: Set<WalletScanId>; handed: boolean };

// A generator with a one-item look-ahead (so the planner can tell an exhausted pass from a pending one).
class Source {
  private buffered: WorkItem | null = null;
  private done = false;
  constructor(private readonly gen: Generator<WorkItem>, readonly tag?: Tag) {}
  peek(): WorkItem | null {
    if (this.buffered || this.done) return this.buffered;
    const r = this.gen.next();
    if (r.done) this.done = true;
    else this.buffered = r.value;
    return this.buffered;
  }
  take(): WorkItem | null {
    const item = this.peek();
    this.buffered = null;
    return item;
  }
}

export class Planner {
  private readonly defs = new Map<ScanId, ScanDef>();
  private readonly global = new Map<ScanId, Cov>();
  private readonly plans = new Map<string, WalletPlan>();
  private order: WalletPlan[] = [];
  private readonly front: WorkItem[] = [];
  private readonly queued: Record<Priority, WorkItem[]> = { 0: [], 1: [], 2: [], 3: [] };
  private readonly sources: Record<Priority, Source[]> = { 0: [], 1: [], 2: [], 3: [] };
  private readonly newTags: Tag[] = [];
  private deepStarted = false;
  private readonly handedOut: Record<Priority, number> = { 0: 0, 1: 0, 2: 0, 3: 0 };
  private readonly kinds: Record<ItemKind, number> = { follow: 0, global: 0, window: 0, deep: 0, holes: 0 };
  private freshCount = 0;

  constructor(state: IndexerState, private readonly head: number, defs: readonly ScanDef[], private readonly o: PlanOptions,
              private readonly now: number) {
    for (const d of defs) this.defs.set(d.id, d);
    for (const s of state.scans) {
      if (!GLOBAL_SCANS.includes(s.id)) continue;
      this.global.set(s.id, { covered: merge(s.covered), holes: merge(s.holes), holesDue: this.due(s.holesCheckedAt, s.holes),
                              planned: [], capFloor: 0, retried: new Set() });
    }
    for (const id of GLOBAL_SCANS) {
      if (!this.global.has(id)) this.global.set(id, { covered: [], holes: [], holesDue: false, planned: [], capFloor: 0, retried: new Set() });
    }
    const fresh: WalletPlan[] = [];
    for (const w of state.wallets) {
      const p = this.planFor(w);
      if (p.fresh) fresh.push(p);
    }
    this.sources[0].push(new Source(this.globalFollow()), new Source(this.walletFollow(this.order)));
    this.sources[1].push(new Source(this.globalGaps()));
    if (fresh.length > 0) this.addWindowPass(fresh);
    this.sources[2].push(new Source(this.alternate(WALLET_SCANS.map((s) => this.walk(s as WalletScanId, this.order.filter((p) => !p.fresh), "window")))));
  }

  // ── Inputs from the run ───────────────────────────────────────────────────────────────────────────────────────

  // Wallets requested since the run's state read (the mid-run refresh): new ones get their follow and their window
  // first, ahead of any deep work; known ones are re-tiered.
  addWallets(wallets: readonly WalletState[]): void {
    const added: WalletPlan[] = [];
    const refollow: WalletPlan[] = [];
    for (const w of wallets) {
      const known = this.plans.get(w.wallet);
      if (known) {
        known.state = { ...known.state, requestedAt: Math.max(known.state.requestedAt, w.requestedAt) };
        refollow.push(known);
      } else {
        added.push(this.planFor(w, true));
      }
    }
    if (added.length + refollow.length > 0) this.sources[0].push(new Source(this.walletFollow([...added, ...refollow])));
    if (added.length > 0) {
      this.addWindowPass(added);
      if (this.deepStarted) this.sources[3].push(new Source(this.deepPass(added)));
    }
  }

  // A commit landed: [from, to] is covered (for these wallets, from their cap floor). Returns how many holes it
  // cleared (history_commit removes them too).
  committed(scan: ScanId, wallets: readonly string[] | null, range: Range): number {
    const clear = (cov: Cov) => {
      const hit = cov.holes.filter((h) => h[0] <= range[1] && h[1] >= range[0]).length;
      cov.holes = subtract(cov.holes, [range]);
      return hit;
    };
    if (GLOBAL_SCANS.includes(scan)) {
      const cov = this.global.get(scan)!;
      cov.covered = merge([...cov.covered, range]);
      return clear(cov);
    }
    let cleared = 0;
    for (const w of wallets ?? []) {
      const cov = this.plans.get(w)?.scans[scan as WalletScanId];
      if (!cov) continue;
      if (range[1] >= cov.capFloor) cov.covered = merge([...cov.covered, [Math.max(range[0], cov.capFloor), range[1]]]);
      cleared += clear(cov);
    }
    return cleared;
  }

  // history_commit trimmed a wallet's scan to its newest 20,000 logs: nothing below `floor` is read again.
  capped(wallet: string, scan: ScanId, floor: number): void {
    const cov = this.plans.get(wallet)?.scans[scan as WalletScanId];
    if (!cov || floor <= cov.capFloor) return;
    cov.capFloor = floor;
    cov.covered = subtract(cov.covered, [[0, floor - 1]]);
    cov.holes = subtract(cov.holes, [[0, floor - 1]]);
  }

  // A range recorded as a hole: not planned again this run.
  holed(scan: ScanId, wallet: string | null, range: Range): void {
    const cov = wallet === null ? this.global.get(scan) : this.plans.get(wallet)?.scans[scan as WalletScanId];
    if (cov) cov.holes = merge([...cov.holes, range]);
  }

  // A first transaction found during the run: the wallet has on-chain activity, so it gets deep work too (when the
  // deep pass has not started yet; else from the next run).
  markDeep(wallet: string): void {
    const p = this.plans.get(wallet);
    if (p && !p.state.deep) p.state = { ...p.state, deep: true };
  }

  // Puts an item back: at the very front (the rest of a piece cut to an endpoint's span), or behind its priority's
  // queue (a retry).
  requeue(item: WorkItem, front: boolean): void {
    if (front) this.front.unshift(item);
    else this.queued[item.priority].push(item);
  }

  // `parts` replaces `item` (cut to a span, or split as too dense): its tag counts them all.
  derive(item: WorkItem, parts: readonly WorkItem[]): void {
    if (item.tag) item.tag.pending += parts.length - 1;
  }

  // An item is finished (committed, recorded as a hole, or dropped for this run).
  settle(item: WorkItem): void {
    if (item.tag) item.tag.pending = Math.max(0, item.tag.pending - 1);
  }

  // ── Output ────────────────────────────────────────────────────────────────────────────────────────────────────

  // The next item, at most `maxPriority` (the run's look-ahead is full of less urgent work: only more urgent work), and
  // of none of the `held` priorities (no endpoint may take them this run: run.ts).
  next(allowDeep: boolean, maxPriority: Priority = 3, held: ReadonlySet<Priority> = NONE): WorkItem | null {
    const at = this.front.findIndex((i) => i.priority <= maxPriority && !held.has(i.priority));
    const item = at >= 0 ? this.front.splice(at, 1)[0] : this.pull(allowDeep, maxPriority, held);
    if (item) {
      this.handedOut[item.priority]++;
      if (item.attempts === 0 && !item.alone) this.kinds[item.kind]++;
      for (const w of item.wallets) { const p = this.plans.get(w); if (p) p.handed = true; }
    }
    return item;
  }

  // An item handed out but never sent (the run's look-ahead made room for more urgent work): first in its priority's
  // queue again, and not counted twice.
  giveBack(item: WorkItem): void {
    this.handedOut[item.priority] = Math.max(0, this.handedOut[item.priority] - 1);
    if (item.attempts === 0 && !item.alone) this.kinds[item.kind] = Math.max(0, this.kinds[item.kind] - 1);
    this.queued[item.priority].unshift(item);
  }

  // Whether any work of these priorities is left: re-queued or given back, or still to come from a pass (the deep pass
  // included before it has started). Unlike next(), it hands nothing out: no wallet is marked planned, no count moves,
  // and the deep pass is not started (a pass's next item may be computed ahead, as pendingNewWindows does; next() then
  // returns that same item).
  hasWork(priorities: readonly Priority[] = [0, 1, 2, 3]): boolean {
    if (this.front.some((i) => priorities.includes(i.priority))) return true;
    for (const p of priorities) {
      if (this.queued[p].length > 0) return true;
      if (this.sources[p].some((s) => s.peek() !== null)) return true;
      if (p === 3 && !this.deepStarted && this.deepWork(this.order)) return true;
    }
    return false;
  }

  private pull(allowDeep: boolean, maxPriority: Priority, held: ReadonlySet<Priority>): WorkItem | null {
    for (const priority of [0, 1, 2, 3] as Priority[]) {
      if (priority > maxPriority) return null;
      if (held.has(priority)) continue;
      if (priority === 3) {
        if (!allowDeep) return null;
        if (!this.deepStarted) {
          this.deepStarted = true;
          this.sources[3].push(new Source(this.deepPass(this.order)));
        }
      }
      const q = this.queued[priority].shift();
      if (q) return q;
      for (const s of this.sources[priority]) {
        const item = s.take();
        if (item) {
          if (s.tag) { item.tag = s.tag; s.tag.pending++; }
          return item;
        }
      }
    }
    return null;
  }

  // New wallets' window pieces not yet handed out or not yet finished.
  pendingNewWindows(): number {
    let n = 0;
    for (const s of this.sources[2]) if (s.tag && s.peek()) n++;
    for (const t of this.newTags) n += t.pending;
    return n;
  }

  counts(): Record<Priority, number> { return { ...this.handedOut }; }
  kindCounts(): Record<ItemKind, number> { return { ...this.kinds }; }

  // For the run's summary: wallets planned, new to the cache, and complete (both scans) over the window and to genesis.
  stats(): { planned: number; new: number; windowComplete: number; deepComplete: number } {
    let planned = 0, windowComplete = 0, deepComplete = 0;
    for (const p of this.order) {
      if (p.handed) planned++;
      const win = WALLET_SCANS.every((s) => {
        const r = this.band(p, s as WalletScanId, "window", false);
        return r === null || contains(p.scans[s as WalletScanId].covered, r);
      });
      const deep = win && WALLET_SCANS.every((s) => {
        const cov = p.scans[s as WalletScanId];
        const lo = Math.max(this.floor(s as ScanId), cov.capFloor);
        return lo > this.head || contains(cov.covered, [lo, this.head]);
      });
      if (win) windowComplete++;
      if (deep) deepComplete++;
    }
    return { planned, new: this.freshCount, windowComplete, deepComplete };
  }

  // ── Internals ─────────────────────────────────────────────────────────────────────────────────────────────────

  private due(checkedAt: number | null, holes: readonly Range[]): boolean {
    return holes.length > 0 && (checkedAt === null || this.now - checkedAt >= this.o.holeRetryMs);
  }

  private floor(scan: ScanId): number {
    return Math.max(this.defs.get(scan)?.floor ?? 0, this.o.floorOverride?.[scan] ?? 0);
  }

  private planFor(w: WalletState, addedMidRun = false): WalletPlan {
    const scans = {} as Record<WalletScanId, Cov>;
    for (const id of WALLET_SCANS as WalletScanId[]) {
      const s = w.scans[id] ?? { covered: [], holes: [], holesCheckedAt: null, capFloor: null, head: null, logCount: 0 };
      scans[id] = { covered: merge(s.covered), holes: merge(s.holes), holesDue: this.due(s.holesCheckedAt, s.holes), planned: [],
                    capFloor: s.capFloor ?? 0, retried: new Set() };
    }
    const fresh = addedMidRun || WALLET_SCANS.every((id) => scans[id as WalletScanId].covered.length === 0);
    const plan: WalletPlan = { state: w, scans, fresh, followed: new Set(), handed: false };
    if (fresh) this.freshCount++;
    this.plans.set(w.wallet, plan);
    this.order.push(plan);
    return plan;
  }

  private addWindowPass(plans: WalletPlan[]) {
    const tag: Tag = { pending: 0 };
    this.newTags.push(tag);
    // Ahead of the main window pass (sources[2] is served in order).
    const pass = new Source(this.alternate(WALLET_SCANS.map((s) => this.walk(s as WalletScanId, plans, "window"))), tag);
    const firstMain = this.sources[2].findIndex((s) => !s.tag);
    if (firstMain < 0) this.sources[2].push(pass);
    else this.sources[2].splice(firstMain, 0, pass);
  }

  // The newest covered block of a wallet scan, when it is close enough to the head to be followed (else null).
  private followable(cov: Cov): number | null {
    const top = newestCovered(cov.covered);
    return top !== null && top >= this.head - this.o.followMax ? top : null;
  }

  private tierDue(p: WalletPlan, top: number): boolean {
    const age = this.now - p.state.requestedAt;
    const behind = this.head - top;
    if (age <= this.o.tiers.hotMs) return true;
    if (age <= this.o.tiers.warmMs) return behind >= this.o.tiers.warmLag;
    return behind >= this.o.tiers.coldLag;
  }

  private item(priority: Priority, kind: ItemKind, scan: ScanId, from: number, to: number, wallets: string[], extra: Partial<WorkItem> = {}): WorkItem {
    return { priority, kind, scan, defVersion: this.defs.get(scan)!.defVersion, from, to, wallets, attempts: 0, ...extra };
  }

  private *globalFollow(): Generator<WorkItem> {
    for (const id of GLOBAL_SCANS) {
      const cov = this.global.get(id)!;
      const top = newestCovered(cov.covered);
      if (top === null || top >= this.head) continue;
      const from = Math.max(this.floor(id), top - (this.o.overlap - 1), this.head - (this.o.followMax - 1));
      if (from > this.head) continue;
      cov.planned.push([from, this.head]);
      yield this.item(0, "follow", id, from, this.head, []);
    }
  }

  private *walletFollow(plans: readonly WalletPlan[]): Generator<WorkItem> {
    const byRecent = [...plans].sort((a, b) => b.state.requestedAt - a.state.requestedAt);
    for (const scan of WALLET_SCANS as WalletScanId[]) {
      const due: { p: WalletPlan; top: number }[] = [];
      for (const p of byRecent) {
        if (p.followed.has(scan)) continue;
        const top = this.followable(p.scans[scan]);
        if (top === null || top >= this.head || !this.tierDue(p, top)) continue;
        due.push({ p, top });
      }
      for (let k = 0; k < due.length; k += this.o.maxWallets) {
        const chunk = due.slice(k, k + this.o.maxWallets);
        const low = Math.min(...chunk.map((c) => c.top));
        const from = Math.max(this.floor(scan), low - (this.o.overlap - 1), this.head - (this.o.followMax - 1));
        for (const c of chunk) { c.p.followed.add(scan); c.p.scans[scan].planned.push([from, this.head]); }
        yield this.item(0, "follow", scan, from, this.head, chunk.map((c) => c.p.state.wallet));
      }
    }
  }

  private *globalGaps(): Generator<WorkItem> {
    for (const id of GLOBAL_SCANS) {
      const cov = this.global.get(id)!;
      const window: Range = [this.floor(id), this.head];
      for (const gap of gapsNewestFirst(window, [...cov.covered, ...cov.planned, ...cov.holes])) {
        for (const piece of piecesDescending(gap, this.o.align)) {
          cov.planned.push(piece);
          yield this.item(1, "global", id, piece[0], piece[1], []);
        }
      }
      if (cov.holesDue) {
        cov.holesDue = false;
        for (const h of [...cov.holes].reverse()) {
          const from = Math.max(h[0], window[0]), to = Math.min(h[1], window[1]);
          if (from <= to) yield this.item(1, "holes", id, from, to, [], { hole: true, single: from === to });
        }
      }
    }
  }

  // A wallet's band for a scan: the 30-day window [H − window + 1, H] or the deep part [floor, H − window], never below
  // its cap floor; a followed wallet's top belongs to the follow (P0), so its band ends at its newest covered block.
  private band(p: WalletPlan, scan: WalletScanId, band: "window" | "deep", followSplit = true): Range | null {
    const cov = p.scans[scan];
    const floor = Math.max(this.floor(scan), cov.capFloor);
    const windowLow = Math.max(0, this.head - this.o.window + 1);
    const followTop = followSplit ? this.followable(cov) : null;
    const top = followTop === null ? this.head : Math.min(this.head, followTop);
    const r: Range = band === "window" ? [Math.max(floor, windowLow), top] : [floor, Math.min(top, windowLow - 1)];
    return r[0] <= r[1] ? r : null;
  }

  private deepPass(plans: readonly WalletPlan[]): Generator<WorkItem> {
    return this.alternate(WALLET_SCANS.map((s) => this.walk(s as WalletScanId, plans.filter((p) => p.state.deep), "deep")));
  }

  // Whether deepPass(plans) would yield anything, without walking it: a deep wallet with a gap in its deep band (walk's
  // entries), or a hole due for a retry inside it (walk's last loop).
  private deepWork(plans: readonly WalletPlan[]): boolean {
    for (const p of plans) {
      if (!p.state.deep) continue;
      for (const scan of WALLET_SCANS as WalletScanId[]) {
        const cov = p.scans[scan];
        const r = this.band(p, scan, "deep");
        if (r && gapsNewestFirst(r, [...cov.covered, ...cov.planned, ...cov.holes]).length > 0) return true;
        const all = cov.holesDue ? this.band(p, scan, "deep", false) : null;
        if (all && cov.holes.some((h) => {
          const from = Math.max(h[0], all[0]), to = Math.min(h[1], all[1]);
          return from <= to && !cov.retried.has(`${from}-${to}`);
        })) return true;
      }
    }
    return false;
  }

  private *alternate(gens: Generator<WorkItem>[]): Generator<WorkItem> {
    let active = gens;
    while (active.length > 0) {
      const still: Generator<WorkItem>[] = [];
      for (const g of active) {
        const r = g.next();
        if (!r.done) { yield r.value; still.push(g); }
      }
      active = still;
    }
  }

  // The range-major walk of one wallet scan over one band, for `plans` in fairness order.
  private *walk(scan: WalletScanId, plans: readonly WalletPlan[], band: "window" | "deep"): Generator<WorkItem> {
    const priority: Priority = band === "window" ? 2 : 3;
    const kind: ItemKind = band === "window" ? "window" : "deep";
    type Entry = { p: WalletPlan; cov: Cov; gaps: [number, number][]; k: number };
    const entries: Entry[] = [];
    let bandLow = Number.POSITIVE_INFINITY;
    for (const p of plans) {
      const r = this.band(p, scan, band);
      if (!r) continue;
      const cov = p.scans[scan];
      const gaps = gapsNewestFirst(r, [...cov.covered, ...cov.planned, ...cov.holes]).map((g) => [g[0], g[1]] as [number, number]);
      if (gaps.length > 0) entries.push({ p, cov, gaps, k: 0 });
      bandLow = Math.min(bandLow, band === "window" ? Math.max(this.floor(scan), this.head - this.o.window + 1) : this.floor(scan));
    }
    for (;;) {
      let c = -1;
      for (const e of entries) {
        // A cap raised during the run: nothing below the cap floor is read.
        while (e.k < e.gaps.length && e.gaps[e.k][1] < e.cov.capFloor) e.k = e.gaps.length;
        if (e.k < e.gaps.length && e.gaps[e.k][0] < e.cov.capFloor) e.gaps[e.k][0] = e.cov.capFloor;
        if (e.k < e.gaps.length && e.gaps[e.k][1] > c) c = e.gaps[e.k][1];
      }
      if (c < 0) break;
      const from = Math.max(bandLow, Math.floor(c / this.o.align) * this.o.align);
      const piece: Range = [from, c];
      const group: Entry[] = [], solo: Entry[] = [];
      for (const e of entries) {
        if (e.k >= e.gaps.length || e.gaps[e.k][1] < from) continue;
        (intersects(piece, e.cov.holes) ? solo : group).push(e);
      }
      for (let k = 0; k < group.length; k += this.o.maxWallets) {
        const chunk = group.slice(k, k + this.o.maxWallets);
        for (const e of chunk) e.cov.planned.push(piece);
        yield this.item(priority, kind, scan, from, c, chunk.map((e) => e.p.state.wallet));
      }
      // A wallet with a hole (not yet due) inside the piece reads only its own gaps there, never the hole again.
      for (const e of solo) {
        for (let j = e.k; j < e.gaps.length && e.gaps[j][1] >= from; j++) {
          const seg: Range = [Math.max(from, e.gaps[j][0]), e.gaps[j][1]];
          e.cov.planned.push(seg);
          yield this.item(priority, kind, scan, seg[0], seg[1], [e.p.state.wallet]);
        }
      }
      for (const e of [...group, ...solo]) {
        while (e.k < e.gaps.length && e.gaps[e.k][0] >= from) e.k++;
        if (e.k < e.gaps.length && e.gaps[e.k][1] >= from) e.gaps[e.k][1] = from - 1;
      }
    }
    // Holes six hours old, inside this band: one item each, per wallet.
    for (const p of plans) {
      const cov = p.scans[scan];
      if (!cov.holesDue) continue;
      const r = this.band(p, scan, band, false);
      if (!r) continue;
      for (const h of [...cov.holes].reverse()) {
        const from = Math.max(h[0], r[0]), to = Math.min(h[1], r[1]);
        if (from > to || cov.retried.has(`${from}-${to}`)) continue;
        cov.retried.add(`${from}-${to}`);
        yield this.item(priority, "holes", scan, from, to, [p.state.wallet], { hole: true, single: from === to });
      }
    }
  }
}
