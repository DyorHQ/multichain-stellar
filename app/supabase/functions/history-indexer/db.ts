// The indexer's six database calls (migration 32, all service-role-only PostgREST RPCs) and the error classes the run
// acts on (§12). Errors are told apart by SQLSTATE, never by message alone — except 55P03, which is Postgres's code for
// both a lock timeout and NOWAIT, and only the lock timeout means "commit slow".
import type { CompactLog } from "./logs.ts";
import type { EndpointMemory } from "./pacing.ts";
import type { FirstTxState, IndexerState, ScanState, WalletScanId, WalletScanState, WalletState } from "./planner.ts";
import { parseRanges, type Range } from "./ranges.ts";
import type { ScanId } from "./scans.ts";

// The one-line run summary (history_indexer_runs.summary): counts only, never a wallet address or a URL.
export type RunSummary = { v: 2; [key: string]: unknown };

export type LeaseAnswer = { ok: boolean; paused: boolean; started: boolean; endpoints: Record<string, EndpointMemory> };
export type CommitArgs = { owner: string; scan: ScanId; defVersion: number; from: number; to: number; head: number;
                           headTimestamp: number; wallets: string[] | null; logs: CompactLog[] };
export type CommitAnswer = { inserted: number; trimmed: number; capFloors: Record<string, number> };

export interface HistoryDb {
  lease(owner: string, seconds: number, version: string): Promise<LeaseAnswer>;
  state(owner: string, maxWallets: number, requestedAfter?: string): Promise<IndexerState>;
  commit(c: CommitArgs): Promise<CommitAnswer>;
  markHole(owner: string, scan: ScanId, defVersion: number, wallet: string | null, from: number, to: number): Promise<void>;
  setFirstTx(owner: string, wallet: string, state: "found" | "none", block: number | null, head: number, source: string): Promise<boolean>;
  release(owner: string, head: number | null, headTimestamp: number | null, summary: RunSummary,
          endpoints: Record<string, EndpointMemory> | null, stop: string): Promise<void>;
}

export class LeaseLost extends Error {           // PT409: another run holds the lease, or the owner paused the indexer
  constructor(message: string, readonly paused: boolean) { super(message); }
}
export class DefsChanged extends Error {}        // PT412: a scan was redefined since history_state
export class CommitSlow extends Error {}         // 57014, or 55P03 "lock timeout": smaller commits
export class Retryable extends Error {}          // 40P01, 40001
export class Refused extends Error {}            // 22023: an argument or answer the database refused
export class DbDown extends Error {}             // anything else: network, 5xx, PGRST errors

export function classifyDbError(code: string | undefined, message: string): Error {
  const short = message.slice(0, 200);
  switch (code) {
    case "PT409": return new LeaseLost(short, /paused/i.test(message));
    case "PT412": return new DefsChanged(short);
    case "57014": return new CommitSlow(short);
    case "55P03": return /lock timeout/i.test(message) ? new CommitSlow(short) : new DbDown(short);
    case "40P01":
    case "40001": return new Retryable(short);
    case "22023": return new Refused(short);
    default: return new DbDown(`${code ?? "no code"}: ${short}`);
  }
}

// ── history_state, parsed ──────────────────────────────────────────────────────────────────────────────────────

const time = (v: unknown): number | null => {
  if (v === null || v === undefined) return null;
  const t = typeof v === "string" ? Date.parse(v) : NaN;
  if (!Number.isFinite(t)) throw new Error("state: a malformed time");
  return t;
};
const block = (v: unknown, what: string): number | null => {
  if (v === null || v === undefined) return null;
  if (!Number.isSafeInteger(v) || (v as number) < 0) throw new Error(`state: a malformed ${what}`);
  return v as number;
};
const ranges = (v: unknown, what: string): Range[] => {
  const r = parseRanges(v);
  if (!r) throw new Error(`state: malformed ${what}`);
  return r;
};

function walletScan(v: unknown): WalletScanState {
  const s = (v ?? {}) as Record<string, unknown>;
  return { covered: ranges(s.covered ?? [], "covered"), holes: ranges(s.holes ?? [], "holes"), holesCheckedAt: time(s.holesCheckedAt),
           capFloor: block(s.capFloor, "cap floor"), head: block(s.head, "head"), logCount: block(s.logCount, "log count") ?? 0 };
}

export function parseState(raw: unknown): IndexerState {
  if (!raw || typeof raw !== "object") throw new Error("state: not an object");
  const r = raw as Record<string, unknown>;
  if (!Array.isArray(r.scans) || !Array.isArray(r.wallets)) throw new Error("state: scans and wallets are required");
  const scans: ScanState[] = r.scans.map((row) => {
    const s = row as Record<string, unknown>;
    return { id: s.id as ScanId, covered: ranges(s.covered, "covered"), holes: ranges(s.holes, "holes"),
             holesCheckedAt: time(s.holesCheckedAt), head: block(s.head, "head") };
  });
  const wallets: WalletState[] = r.wallets.map((row) => {
    const w = row as Record<string, unknown>;
    if (typeof w.wallet !== "string" || !/^0x[0-9a-f]{40}$/.test(w.wallet)) throw new Error("state: a malformed wallet");
    const f = (w.firstTx ?? {}) as Record<string, unknown>;
    const fstate = f.state === "found" || f.state === "none" ? f.state : "unknown";
    const firstTx: FirstTxState = { state: fstate, block: block(f.block, "first block"), head: block(f.head, "first-tx head"),
                                    checkedAt: time(f.checkedAt), source: typeof f.source === "string" ? f.source : null };
    const ws = (w.scans ?? {}) as Record<string, unknown>;
    const scansOf = {} as Record<WalletScanId, WalletScanState>;
    for (const id of ["transfers-in", "transfers-out"] as WalletScanId[]) scansOf[id] = walletScan(ws[id]);
    return { wallet: w.wallet, requestedAt: time(w.requestedAt) ?? 0, deep: w.deep === true, firstTx, scans: scansOf };
  });
  return { now: time(r.now) ?? Date.now(), head: block(r.head, "head"), active: block(r.active, "active") ?? wallets.length,
           skipped: block(r.skipped, "skipped") ?? 0, scans, wallets, defs: r.scans };
}

// ── Over PostgREST (supabase-js) ───────────────────────────────────────────────────────────────────────────────

type RpcResult = { data: unknown; error: { code?: string; message?: string } | null };
type RpcBuilder = PromiseLike<RpcResult> & { abortSignal?: (signal: AbortSignal) => PromiseLike<RpcResult> };
export type RpcClient = { rpc(fn: string, args: Record<string, unknown>): RpcBuilder };

export function postgrestDb(client: RpcClient, timeoutMs = 12_000): HistoryDb {
  const call = async (fn: string, args: Record<string, unknown>): Promise<unknown> => {
    let result: RpcResult;
    try {
      const builder = client.rpc(fn, args);
      result = await (builder.abortSignal ? builder.abortSignal(AbortSignal.timeout(timeoutMs)) : builder);
    } catch (err) {
      throw new DbDown(`${fn}: ${String((err as Error)?.message ?? err).slice(0, 120)}`);
    }
    if (result.error) throw classifyDbError(result.error.code, `${fn}: ${result.error.message ?? ""}`);
    return result.data;
  };
  return {
    async lease(owner, seconds, version) {
      const d = (await call("history_lease", { p_owner: owner, p_seconds: seconds, p_version: version })) as Record<string, unknown>;
      return { ok: d?.ok === true, paused: d?.paused === true, started: d?.started === true,
               endpoints: (d?.endpoints && typeof d.endpoints === "object" ? d.endpoints : {}) as Record<string, EndpointMemory> };
    },
    async state(owner, maxWallets, requestedAfter) {
      return parseState(await call("history_state", { p_owner: owner, p_max_wallets: maxWallets, p_requested_after: requestedAfter ?? null }));
    },
    async commit(c) {
      const d = (await call("history_commit", {
        p_owner: c.owner, p_scan: c.scan, p_def_version: c.defVersion, p_from: c.from, p_to: c.to, p_head: c.head,
        p_head_timestamp: c.headTimestamp, p_wallets: c.wallets, p_logs: c.logs,
      })) as Record<string, unknown>;
      return commitAnswer(d);
    },
    async markHole(owner, scan, defVersion, wallet, from, to) {
      await call("history_mark_hole", { p_owner: owner, p_scan: scan, p_def_version: defVersion, p_wallet: wallet, p_from: from, p_to: to });
    },
    async setFirstTx(owner, wallet, state, blk, head, source) {
      return (await call("history_set_first_tx", { p_owner: owner, p_wallet: wallet, p_state: state, p_block: blk, p_head: head, p_source: source })) === true;
    },
    async release(owner, head, headTimestamp, summary, endpoints, stop) {
      await call("history_release", { p_owner: owner, p_head: head, p_head_timestamp: headTimestamp, p_summary: summary,
                                      p_endpoints: endpoints, p_stop: stop });
    },
  };
}

export function commitAnswer(d: Record<string, unknown> | null): CommitAnswer {
  const caps: Record<string, number> = {};
  const raw = (d?.capFloors ?? {}) as Record<string, unknown>;
  for (const [wallet, floor] of Object.entries(raw)) if (Number.isSafeInteger(floor)) caps[wallet] = floor as number;
  return { inserted: Number(d?.inserted ?? 0) || 0, trimmed: Number(d?.trimmed ?? 0) || 0, capFloors: caps };
}
