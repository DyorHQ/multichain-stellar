// The CPU estimate (D21, run.ts DEFAULT_RUN_OPTIONS). The platform stops an isolate at 2,000 ms of CPU ("shutdown cpu"),
// whatever the isolate spent it on: its own start, every request it answered, every run it did (index.ts starts another
// run in the same isolate once the last one released). The isolate cannot read its own CPU time, and what a run can
// time itself (`syncMs`: JSON.parse of the answers, the planner, the filters, the commit payloads' JSON.stringify
// estimated from their size) was ~5 % of what the platform charged on 2026-10-09: the rest is the HTTP exchanges
// themselves (TLS, fetch, streams, supabase-js) and the bytes they carry. So:
//
//   a run's estimate      syncMs + rpcCpuMs × RPC requests + dbCpuMs × database calls + streamed bytes / bytesPerMs
//   the isolate's         its start + REQUEST_CPU_MS × every request it answered + the estimates of all its runs
//
// and a run stops new reads (stop "cpu") once the ISOLATE's estimate plus what finishing the run still costs
// (finishReserveMs) reaches the budget, and does not take the lease when less than `minRunCpuMs` of the budget is left.
//
// The prices: the two runs the platform stopped on 2026-10-09, at cpu_time_used 1,815 and 1,809 ms, had syncMs 71 / 98,
// 828 / 880 RPC requests, 1,203 / 917 commits and ~15 other database calls each. Solving syncMs + r × requests +
// d × database calls = cpu_time_used for both gives r ≈ 1.53 ms per RPC request and d ≈ 0.39 ms per database call
// (cpu_test.ts): an RPC answer comes gzipped over TLS from a public endpoint, a database call goes to the project's own
// REST endpoint. Two points only, so the prices are those rounded up — 1.6 and 0.5 — which put both measured runs, and
// any mix of the two kinds, at or above the fit. One flat price (1 ms) did not: it was an average over a commit-heavy
// mix, and coalescing the commits moves a run's mix toward RPC requests, the dearer kind.
//   `bytesPerMs`: an answer's bytes cost CPU in each pass over them — streamed in (gunzip, the stream's reads, the copy
// into one buffer, the UTF-8 decode), parsed, and, for logs that are committed, stringified again. Not measured: 150 kB
// a millisecond per pass, on the low side of what zlib and V8 do. Charged for every exchange's streamed bytes, answered
// or not — an answer cut off at the response cap (tooLarge) has been streamed and inflated up to the cap, and is never
// parsed — and on top of the fitted per-request price (which holds the measured runs' average answer), so a run of
// large or cut-off answers is never priced like one of small ones.

// The database calls (db.ts HistoryDb), counted by name in the run summary (`counts.db`).
export type DbCall = "lease" | "state" | "commit" | "markHole" | "setFirstTx" | "release";

export type CpuPrices = { rpcCpuMs: number; dbCpuMs: number; bytesPerMs: number };

// The isolate's start and the requests it answers (index.ts). An idle tick in an isolate of its own cost ~55–60 ms on
// 2026-10-09 (the start: module load, the client, the Vault digest fetch, one answer), so an isolate starts at 60 ms. A
// request to a warm isolate (a cron tick while a run holds the lease, or between runs) does none of the start's work:
// not measured, and 3 ms is on the high side for a header check and a 202. A Vault digest fetch (auth.ts, at most once
// a minute) is a database call on top.
export const ISOLATE_START_CPU_MS = 60;
export const REQUEST_CPU_MS = 3;

// One run's meter: what it measured and what it counted.
export class CpuMeter {
  syncMs = 0;          // measured (and the commit payloads' estimated stringify)
  requests = 0;        // every RPC request sent: log reads, head reads, probes, nonce reads, block-timestamp reads
  streamedBytes = 0;   // every exchange's body as streamed, answered or not (a tooLarge answer up to its cut)
  readonly db: Record<DbCall, number> = { lease: 0, state: 0, commit: 0, markHole: 0, setFirstTx: 0, release: 0 };

  constructor(readonly prices: CpuPrices) {}

  dbCalls(): number {
    let n = 0;
    for (const v of Object.values(this.db)) n += v;
    return n;
  }

  estimateMs(): number {
    const p = this.prices;
    return this.syncMs + p.rpcCpuMs * this.requests + p.dbCpuMs * this.dbCalls() + this.streamedBytes / p.bytesPerMs;
  }
}

// The isolate's estimate: what it was charged (its start, the requests it answered) plus the live estimate of every run
// it has done or is doing. A run's meter is part of it from the moment the run starts, so a run finishing while the
// next starts (index.ts lets a tick start one as soon as the last released) is never counted at 0.
export class IsolateCpu {
  private chargedMs: number;
  private readonly meters: CpuMeter[] = [];

  constructor(startMs = 0) { this.chargedMs = Math.max(0, startMs); }

  charge(ms: number): void { this.chargedMs += Math.max(0, ms); }

  meter(prices: CpuPrices): CpuMeter {
    const m = new CpuMeter(prices);
    this.meters.push(m);
    return m;
  }

  spentMs(): number {
    let n = this.chargedMs;
    for (const m of this.meters) n += m.estimateMs();
    return n;
  }
}

// A log the scans match has at least two topics (the event and a wallet's word): ≥ ~465 bytes of JSON as an endpoint
// sends it (a Transfer with its data and blockTimestamp ~630). Counting one per 400 bytes counts more logs, so more
// commits, than the bytes can hold (cpu_test.ts).
export const LOG_BYTES = 400;

// What finishing a run still costs, from the moment it decides whether to start a read (and, with a read's own share
// added, what that read adds):
//   commits   the pending coalesced fragments' commits and the queued ones, plus those the answers in flight can
//             become — one per piece, and one more per `commitLogs` × LOG_BYTES of the bytes reserved for them; each
//             priced twice (a slow commit is re-split once, a deadlock retried);
//   bytes     the bytes in flight (ByteBudget's reservations), three passes each: streamed in, parsed, stringified;
//   requests  RPC requests not sent yet but already decided (the read being checked);
//   lookups   each first-transaction lookup in progress: the reads it has not made yet (it may finish them past a "cpu"
//             stop) and its setFirstTx;
//   the end   a lease renewal and a state refresh the read loop may make after its check, the final renewal, the release.
// Not reserved: a third attempt at a commit, extra parts when splitForCommit cuts a fragment at a block holding many
// logs, holes recorded from answers in flight, an answer larger than its byte reservation (2 × its kind's running
// average, ≥ 256 KiB), a lookup's fail-over past its allowance (its next read then stops). Those are the slack between
// a run's estimate and its budget; cpu_test.ts and the run test check the bound without them.
export type Finish = {
  commits: number; pieces: number; bytes: number; requests: number; lookupReads: number; lookups: number; commitLogs: number;
};

export function finishReserveMs(f: Finish, p: CpuPrices): number {
  const fromAnswers = f.pieces + Math.ceil(Math.max(0, f.bytes) / (Math.max(1, f.commitLogs) * LOG_BYTES));
  const commits = 2 * (f.commits + fromAnswers);
  return p.rpcCpuMs * (f.requests + f.lookupReads) + p.dbCpuMs * (commits + f.lookups + 4) + (3 * Math.max(0, f.bytes)) / p.bytesPerMs;
}

// The reads one first-transaction lookup makes (firsttx.ts): the nonce at the head, the bisection over [0, head], the
// two confirmations, a re-verification's first read, and two fail-overs (a node behind the head refuses a nonce read
// near it, and the next source is asked). More fail-overs than that: its reads past these are not reserved, and a
// stop ends it.
export function lookupReads(head: number): number {
  return Math.ceil(Math.log2(Math.max(1, head) + 1)) + 6;
}
