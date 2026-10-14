// Inclusive block ranges [from, to] (block numbers stay far below 2^53), the shape history_state and history_read use
// for `covered` and `holes` (migration 32's history_ranges()).
export type Range = readonly [number, number];

const valid = (r: Range) => Number.isSafeInteger(r[0]) && Number.isSafeInteger(r[1]) && r[0] >= 0 && r[0] <= r[1];

// Sorted ascending, overlapping and adjacent ranges joined; empty or malformed ranges dropped.
export function merge(ranges: readonly Range[]): Range[] {
  const sorted = ranges.filter(valid).map((r) => [r[0], r[1]] as [number, number]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const out: [number, number][] = [];
  for (const r of sorted) {
    const last = out[out.length - 1];
    if (last && r[0] <= last[1] + 1) last[1] = Math.max(last[1], r[1]);
    else out.push(r);
  }
  return out;
}

// What of `ranges` is not in `minus`, merged, ascending.
export function subtract(ranges: readonly Range[], minus: readonly Range[]): Range[] {
  const cut = merge(minus);
  const out: Range[] = [];
  for (const r of merge(ranges)) {
    let from = r[0];
    const to = r[1];
    for (const m of cut) {
      if (m[1] < from) continue;
      if (m[0] > to) break;
      if (m[0] > from) out.push([from, m[0] - 1]);
      from = Math.max(from, m[1] + 1);
      if (from > to) break;
    }
    if (from <= to) out.push([from, to]);
  }
  return out;
}

// The parts of `window` that `covered` leaves open, newest (highest) first.
export function gapsNewestFirst(window: Range, covered: readonly Range[]): Range[] {
  if (!valid(window)) return [];
  return subtract([window], covered).reverse();
}

// `range` cut at multiples of `align`, newest first: [⌊to/align⌋·align, to], then whole aligned pieces down to `from`.
export function piecesDescending(range: Range, align: number): Range[] {
  if (!valid(range) || !(align >= 1)) return [];
  const out: Range[] = [];
  let to = range[1];
  while (to >= range[0]) {
    const from = Math.max(range[0], Math.floor(to / align) * align);
    out.push([from, to]);
    to = from - 1;
  }
  return out;
}

// The highest covered block, or null when nothing is covered.
export function newestCovered(covered: readonly Range[]): number | null {
  let top: number | null = null;
  for (const r of covered) if (valid(r) && (top === null || r[1] > top)) top = r[1];
  return top;
}

// Whether `lower` ends exactly where `upper` starts (the two join into one range).
export function adjacentBelow(upper: Range, lower: Range): boolean {
  return lower[1] + 1 === upper[0];
}

// Whether any part of `range` lies in `ranges`.
export function intersects(range: Range, ranges: readonly Range[]): boolean {
  return ranges.some((r) => r[0] <= range[1] && r[1] >= range[0]);
}

// `ranges` clipped to `window`.
export function clip(ranges: readonly Range[], window: Range): Range[] {
  const out: Range[] = [];
  for (const r of merge(ranges)) {
    const from = Math.max(r[0], window[0]);
    const to = Math.min(r[1], window[1]);
    if (from <= to) out.push([from, to]);
  }
  return out;
}

// The number of blocks in `ranges` (merged first).
export function size(ranges: readonly Range[]): number {
  return merge(ranges).reduce((n, r) => n + r[1] - r[0] + 1, 0);
}

// Whether `range` lies entirely inside `ranges`.
export function contains(ranges: readonly Range[], range: Range): boolean {
  return subtract([range], ranges).length === 0;
}

// Parses history_ranges() output ([[from, to], …]); null when it is not that shape.
export function parseRanges(value: unknown): Range[] | null {
  if (!Array.isArray(value)) return null;
  const out: Range[] = [];
  for (const r of value) {
    if (!Array.isArray(r) || r.length !== 2) return null;
    const from = Number(r[0]), to = Number(r[1]);
    if (!valid([from, to])) return null;
    out.push([from, to]);
  }
  return merge(out);
}
