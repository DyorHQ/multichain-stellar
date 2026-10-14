// Coalescing answered pieces into commits (§12). Every commit is one database call (~0.4 ms of the platform's CPU,
// cpu.ts), so adjacent answered pieces of the same scan, definition and wallet list are joined into one range and
// committed together. Pieces answer in any order (several endpoints read the same scan at once, a narrow endpoint takes
// the top of an item and its rest is read later, a batch's pieces come back together), so a key keeps any number of
// disjoint fragments, and a piece joins the fragment just below it, the one just above it, or both (it closes the gap
// between them). A fragment is only ever a union of whole answered pieces that touch end to end: it never claims a
// block that no piece answered. Overlapping pieces are never merged (each stays its own fragment; history_commit takes
// both).
//
// A fragment leaves (to be split into commits of ≤ maxLogs logs) when it holds `maxPieces` pieces or `maxLogs` logs
// (a piece joining two fragments can take it past either: at most 2 × maxPieces − 1 pieces), when it is `maxMs` old,
// under back-pressure (the largest first), and at the end of the run.
import type { CompactLog } from "./logs.ts";

export type Fragment<M, I> = {
  key: string; meta: M; from: number; to: number;
  logs: CompactLog[];   // ascending (block, log index): each piece's logs are, and fragments join in block order
  pieces: number; firstAt: number; items: I[];
};

export class Coalescer<M, I> {
  private readonly byKey = new Map<string, Fragment<M, I>[]>();

  constructor(private readonly maxPieces: number, private readonly maxMs: number) {}

  // One answered piece [from, to] with its logs (ascending). Returns the fragments that are now full (removed).
  add(key: string, meta: M, from: number, to: number, logs: CompactLog[], item: I, now: number, maxLogs: number): Fragment<M, I>[] {
    let list = this.byKey.get(key);
    if (!list) this.byKey.set(key, list = []);
    const below = list.find((f) => f.to + 1 === from) ?? null;
    const above = list.find((f) => f.from === to + 1) ?? null;
    const merged: Fragment<M, I> = {
      key, meta,
      from: below ? below.from : from,
      to: above ? above.to : to,
      logs: below || above ? [...(below?.logs ?? []), ...logs, ...(above?.logs ?? [])] : logs,
      pieces: 1 + (below?.pieces ?? 0) + (above?.pieces ?? 0),
      firstAt: Math.min(now, below?.firstAt ?? now, above?.firstAt ?? now),
      items: [...(below?.items ?? []), item, ...(above?.items ?? [])],
    };
    const kept = list.filter((f) => f !== below && f !== above);
    if (merged.pieces >= this.maxPieces || merged.logs.length >= maxLogs) {
      this.set(key, kept);
      return [merged];
    }
    kept.push(merged);
    this.set(key, kept);
    return [];
  }

  // The fragments `maxMs` old or older (removed).
  due(now: number): Fragment<M, I>[] {
    return this.take((f) => now - f.firstAt >= this.maxMs);
  }

  // Every fragment (removed): the end of the run.
  drain(): Fragment<M, I>[] {
    return this.take(() => true);
  }

  // The fragment holding the most logs (removed), or null: back-pressure.
  largest(): Fragment<M, I> | null {
    let best: Fragment<M, I> | null = null;
    for (const list of this.byKey.values()) for (const f of list) if (!best || f.logs.length > best.logs.length) best = f;
    if (best) this.set(best.key, this.byKey.get(best.key)!.filter((f) => f !== best));
    return best;
  }

  // How many commits the fragments would make now, at ≤ maxLogs logs each (a lower bound: splitForCommit cuts at block
  // boundaries). The run's CPU reserve for its finish (cpu.ts).
  commits(maxLogs: number): number {
    let n = 0;
    for (const list of this.byKey.values()) for (const f of list) n += Math.max(1, Math.ceil(f.logs.length / Math.max(1, maxLogs)));
    return n;
  }

  get size(): number {
    let n = 0;
    for (const list of this.byKey.values()) n += list.length;
    return n;
  }

  private take(pick: (f: Fragment<M, I>) => boolean): Fragment<M, I>[] {
    const out: Fragment<M, I>[] = [];
    for (const [key, list] of [...this.byKey]) {
      const stay = list.filter((f) => !pick(f));
      if (stay.length === list.length) continue;
      out.push(...list.filter(pick));
      this.set(key, stay);
    }
    return out;
  }

  private set(key: string, list: Fragment<M, I>[]) {
    if (list.length === 0) this.byKey.delete(key);
    else this.byKey.set(key, list);
  }
}
