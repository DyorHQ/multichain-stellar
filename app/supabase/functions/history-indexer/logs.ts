// Checking one eth_getLogs answer against the piece it was asked for (§12), and cutting answered pieces into commits.
// An answer is all or nothing: one log the filter could not have produced (another topic0, a contract outside the
// list, a block outside the range, a wallet not asked for, a removed log, a malformed field) rejects the whole answer,
// and the endpoint rests (run.ts). history_commit re-checks everything (defence in depth).
import { type ScanDef, subjectOf, walletWord } from "./scans.ts";

// A log as history_commit takes it: address, topics, data (null when over 16 KiB: `n` keeps its length, and history_read
// lists it as `omitted`), block, tx hash, log index, block timestamp (null until filled from the block header).
export type CompactLog = { a: string; t: string[]; d: string | null; n: number; b: number; h: string; i: number; s: number | null };
export const MAX_DATA_BYTES = 16_384;

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const WORD = /^0x[0-9a-fA-F]{64}$/;
const DATA = /^0x(?:[0-9a-fA-F]{2})*$/;
const QUANTITY = /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]{0,15})$/;

function quantity(v: unknown): number | null {
  if (typeof v !== "string" || !QUANTITY.test(v)) return null;
  const n = parseInt(v, 16);
  return Number.isSafeInteger(n) ? n : null;
}

export type Checked = { ok: true; logs: CompactLog[]; missingTimestamps: number[] } | { ok: false; reason: string };

export function checkAnswer(def: Pick<ScanDef, "kind" | "walletTopic" | "addresses" | "topic0s">,
                            item: { from: number; to: number; wallets: readonly string[] }, result: unknown): Checked {
  if (!Array.isArray(result)) return { ok: false, reason: "not a list" };
  const topic0s = new Set(def.topic0s);
  const addresses = def.addresses.length > 0 ? new Set(def.addresses) : null;
  const words = def.kind === "wallet" ? new Set(item.wallets.map(walletWord)) : null;
  const byKey = new Map<string, CompactLog>();
  const missing = new Set<number>();
  for (const raw of result) {
    if (!raw || typeof raw !== "object") return { ok: false, reason: "a log is not an object" };
    const l = raw as Record<string, unknown>;
    if (l.removed === true) return { ok: false, reason: "a removed log" };
    if (typeof l.address !== "string" || !ADDRESS.test(l.address)) return { ok: false, reason: "a malformed address" };
    if (!Array.isArray(l.topics) || l.topics.length < 1 || l.topics.length > 4 ||
        !l.topics.every((t) => typeof t === "string" && WORD.test(t))) return { ok: false, reason: "malformed topics" };
    if (typeof l.data !== "string" || !DATA.test(l.data)) return { ok: false, reason: "malformed data" };
    if (typeof l.transactionHash !== "string" || !WORD.test(l.transactionHash)) return { ok: false, reason: "a malformed transaction hash" };
    const b = quantity(l.blockNumber), i = quantity(l.logIndex);
    if (b === null || i === null) return { ok: false, reason: "a malformed block number or log index" };
    if (b < item.from || b > item.to) return { ok: false, reason: "a log outside the range asked" };
    const topics = (l.topics as string[]).map((t) => t.toLowerCase());
    const address = l.address.toLowerCase();
    if (!topic0s.has(topics[0])) return { ok: false, reason: "a topic0 the scan does not read" };
    if (addresses && !addresses.has(address)) return { ok: false, reason: "a contract the scan does not read" };
    if (words && !words.has(topics[def.walletTopic] ?? "")) return { ok: false, reason: "a wallet not asked for" };
    // A global-scan log without an address-shaped topic at the wallet position can never match a wallet's query (D6).
    if (!words && subjectOf(def, topics) === null) continue;
    let s: number | null = null;
    if (l.blockTimestamp !== undefined && l.blockTimestamp !== null) {
      s = quantity(l.blockTimestamp);
      if (s === null) return { ok: false, reason: "a malformed block timestamp" };
    } else {
      missing.add(b);
    }
    const length = (l.data.length - 2) / 2;
    const key = `${b}:${i}`;
    if (!byKey.has(key)) {
      byKey.set(key, { a: address, t: topics, d: length > MAX_DATA_BYTES ? null : l.data.toLowerCase(), n: length, b,
                       h: l.transactionHash.toLowerCase(), i, s });
    }
  }
  const logs = [...byKey.values()].sort((x, y) => x.b - y.b || x.i - y.i);
  return { ok: true, logs, missingTimestamps: [...missing].sort((x, y) => x - y) };
}

// Fills `s` from block timestamps read separately (a provider whose logs lack blockTimestamp). Returns false when one
// is still missing.
export function fillTimestamps(logs: CompactLog[], timestamps: ReadonlyMap<number, number>): boolean {
  for (const l of logs) {
    if (l.s === null) {
      const s = timestamps.get(l.b);
      if (s === undefined) return false;
      l.s = s;
    }
  }
  return true;
}

// [from, to] with its logs (ascending), cut at block boundaries into consecutive ranges of at most `max` logs each,
// together covering exactly [from, to]. A single block holding more than `max` logs goes alone (the caller keeps such a
// block ≤ 5,000, history_commit's limit).
export function splitForCommit(logs: readonly CompactLog[], from: number, to: number, max: number)
  : { from: number; to: number; logs: CompactLog[] }[] {
  const out: { from: number; to: number; logs: CompactLog[] }[] = [];
  let start = from;
  let current: CompactLog[] = [];
  let k = 0;
  while (k < logs.length) {
    const block = logs[k].b;
    let end = k;
    while (end < logs.length && logs[end].b === block) end++;
    const blockLogs = logs.slice(k, end);
    if (current.length > 0 && current.length + blockLogs.length > max) {
      out.push({ from: start, to: block - 1, logs: current });
      start = block;
      current = [];
    }
    current = current.concat(blockLogs);
    k = end;
  }
  out.push({ from: start, to, logs: current });
  return out;
}

// The approximate size of a commit payload, for sizing and the CPU meter.
export function compactBytes(logs: readonly CompactLog[]): number {
  let n = 0;
  for (const l of logs) n += 200 + 70 * l.t.length + (l.d ? l.d.length : 0);
  return n;
}
