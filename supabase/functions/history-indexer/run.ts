// One indexer run (§10): lease → state → head → straddle self-test → plan and read, newest first → commit → release.
// Every dependency is injected (database, endpoints, fetch, clocks, randomness), so the whole loop runs in tests on a
// virtual clock against fake endpoints and a real PGlite database (supabase/tests/history_indexer_run_test.ts).
//
// THE INVARIANT this loop serves (HistoryStore's, enforced again by history_commit): a block range is committed as
// covered only from a complete, checked answer for exactly that range, in the same transaction as its logs. Anything
// not answered — throttled, timed out, too dense, refused past the head — is re-queued, split, recorded as a hole, or
// left as a gap for the next run; it is never claimed.
import { type CommitArgs, CommitSlow, DbDown, DefsChanged, type HistoryDb, LeaseLost, Refused, Retryable, type RunSummary } from "./db.ts";
import { classifyCallError, classifyHttp, type Endpoint, endpointRefusal, isKeyed, retryAfterMs } from "./endpoints.ts";
import { locateFirstTx, type NonceSource, reverifyFirstTx } from "./firsttx.ts";
import { Coalescer, type Fragment } from "./coalesce.ts";
import { type CpuMeter, type DbCall, type Finish, finishReserveMs, IsolateCpu, lookupReads } from "./cpu.ts";
import { checkAnswer, type CompactLog, compactBytes, fillTimestamps, splitForCommit } from "./logs.ts";
import { ByteBudget, EndpointState, followRank, minSpanFor, type Outcome, pickEndpoint, type Priority, takesPriority } from "./pacing.ts";
import { DEFAULT_PLAN, type IndexerState, type PlanOptions, Planner, type WalletState, type WorkItem } from "./planner.ts";
import { type Redact, scrubUrls } from "./redact.ts";
import { type Call, type CallResult, exchange, type Exchange } from "./rpc.ts";
import { bundledDefs, defsDrift, defsFromState, filterFor, GLOBAL_SCANS, type ScanDef, type ScanId } from "./scans.ts";

const MiB = 1_048_576;

export type RunOptions = {
  workMs: number; isolateMaxMs: number; minRunMs: number; readMarginMs: number; slowReadMarginMs: number;
  leaseSeconds: number; renewMs: number; maxWallets: number; stateRefreshMs: number; jitterMs: number;
  requestTimeoutMs: number; responseCap: number; singleBlockCap: number; maxInFlightTotal: number; inFlightReserve: number;
  maxParsedBytes: number; maxLogs: number; syncBudgetMs: number;
  cpuBudgetMs: number; minRunCpuMs: number; rpcCpuMs: number; dbCpuMs: number; bytesPerMs: number;
  denseLogs: number; singleBlockLogs: number;
  commitLogs: number; minCommitLogs: number; commitConcurrency: number; backpressureLogs: number; backpressureCommits: number;
  coalesceItems: number; coalesceMs: number;
  firstTxPerRun: number; firstTxConcurrency: number; firstTxPauseMs: number; firstTxCpuShare: number;
  maxAttempts: number; maxPastHead: number; parkItems: number; headReadyMs: number; probeAttempts: number; plan: PlanOptions;
};

// The budgets (D21). The platform stops an isolate at 2,000 ms of CPU ("shutdown cpu"), counting everything the isolate
// did: its start, the cron ticks it answered, and every run in it. `cpuBudgetMs` is half of that, for the isolate, by an
// estimate (cpu.ts): the isolate's start and requests, plus each of its runs' `syncMs` + `rpcCpuMs` × every RPC request
// (log reads, head reads, probes, nonce and block-timestamp reads) + `dbCpuMs` × every database call (lease, state,
// commit, markHole, setFirstTx, release) + its streamed bytes / `bytesPerMs`. A run takes the lease only when at least
// `minRunCpuMs` of the budget is left in its isolate (index.ts answers "accepted: false" otherwise), and stops its own
// reads (stop "cpu") once the isolate's estimate plus what finishing the run still costs (cpu.ts finishReserveMs: the
// requests in flight and their bytes, the coalesced ranges' commits, the lookups in progress, the release) reaches the
// budget. The summary records the run's estimate and the isolate's (`cpuEstimateMs`, `cpuIsolateMs`, `counts.db`,
// `counts.bytes`) to compare with the platform's cpu_time_used.
//   Measured 2026-10-09 (version 33ce79b, Edge runtime 1.77 / Deno 2.1.4, eu-west-1): the first two deployed runs were
// stopped by the platform for CPU after 155 s and 177 s, at cpu_time_used 1,815 and 1,809 ms. Their summaries: syncMs 71
// and 98 (the run's own meter saw ~5 % of the platform's CPU) for 828 and 880 RPC requests and 1,203 and 917 commits:
// ~1.53 ms per RPC request and ~0.39 ms per database call, so `rpcCpuMs` 1.6 and `dbCpuMs` 0.5 (cpu.ts). The other half
// of the limit is the margin for the estimate's error.
//   Commits were most of those exchanges: coalescing kept one range per key and flushed it whenever a piece arrived out
// of order (several endpoints read one scan at once), and joined at most 10 pieces. It now keeps any number of
// fragments per key and joins up to `coalesceItems` 40 (coalesce.ts).
//   First-transaction lookups (§13) are ~30 sequential nonce reads each (two thirds of the measured runs' requests):
// together they may take at most `firstTxCpuShare` of the budget, a lookup starts only when the whole of it fits, and
// one in progress may finish its reads past a "cpu" stop (they are reserved), so no lookup is cut off half done.
//   `maxInFlightTotal`, `maxParsedBytes`, `maxLogs` and `syncBudgetMs` stay at their starting values until deployed
// runs show the platform's cpu_time_used below half of the limit.
export const DEFAULT_RUN_OPTIONS: RunOptions = {
  workMs: 240_000, isolateMaxMs: 340_000, minRunMs: 40_000, readMarginMs: 30_000, slowReadMarginMs: 45_000,
  leaseSeconds: 300, renewMs: 60_000, maxWallets: 2_000, stateRefreshMs: 30_000, jitterMs: 5_000,
  requestTimeoutMs: 15_000, responseCap: 3 * MiB, singleBlockCap: 8 * MiB, maxInFlightTotal: 6, inFlightReserve: 12 * MiB,
  maxParsedBytes: 8 * MiB, maxLogs: 20_000, syncBudgetMs: 1_000,
  cpuBudgetMs: 1_000, minRunCpuMs: 300, rpcCpuMs: 1.6, dbCpuMs: 0.5, bytesPerMs: 150_000,
  denseLogs: 10_000, singleBlockLogs: 5_000,
  commitLogs: 2_000, minCommitLogs: 500, commitConcurrency: 2, backpressureLogs: 8_000, backpressureCommits: 4,
  coalesceItems: 40, coalesceMs: 15_000,
  firstTxPerRun: 20, firstTxConcurrency: 2, firstTxPauseMs: 2_000, firstTxCpuShare: 0.25,
  maxAttempts: 3, maxPastHead: 3, parkItems: 32, headReadyMs: 2_000, probeAttempts: 3, plan: DEFAULT_PLAN,
};

// Whether an isolate that has spent `isolate` has room for a run to start: `minRunCpuMs` of the budget left (the lease,
// the state, the head reads, a first follow and the release, with something to read). index.ts asks before it starts
// a run; the run asks again before it takes the lease.
export function isolateHasRoom(isolate: IsolateCpu, o: Pick<RunOptions, "cpuBudgetMs" | "minRunCpuMs"> = DEFAULT_RUN_OPTIONS): boolean {
  return isolate.spentMs() + o.minRunCpuMs <= o.cpuBudgetMs;
}

export type Deps = {
  db: HistoryDb; endpoints: Endpoint[]; fetch: typeof fetch; now: () => number; cpuNow: () => number;
  sleep: (ms: number) => Promise<void>; random: () => number; log: (line: string) => void;
  isolateStartedAt: number; version: string;
  // The isolate's CPU estimate (cpu.ts), one per isolate (index.ts), shared by every run in it; default: a fresh one at 0.
  isolateCpu?: IsolateCpu;
  onLease?: (owner: string) => void; onRelease?: (stop: string) => void;
  setTimer?: (ms: number, fn: () => void) => () => void;    // a cancellable timer (default: from `sleep`)
  // Applied to every error line, log line and the run summary (redact.ts: the keyed endpoints' URLs → their labels);
  // default: only the paths and queries cut off any URL.
  redact?: Redact;
  options?: Partial<Omit<RunOptions, "plan">> & { plan?: Partial<PlanOptions> };
};

type ItemCounts = { follow: number; global: number; window: number; deep: number; holes: number };
const PRIORITY_KIND: Record<Priority, string> = { 0: "follow", 1: "global", 2: "window", 3: "deep" };

// The run's counters, turned into the summary at release (§10): counts only, no wallet address, no URL.
class Counters {
  constructor(private readonly redact: Redact) {}
  requests: Record<string, number> = {};
  throttled: Record<string, number> = {};
  refused: Record<string, number> = {};
  sidelined: string[] = [];
  failed = 0; invalid = 0; dense = 0; timeouts = 0; pastHead = 0; straddleWaits = 0; dropped = 0;
  // Priorities no endpoint could take during the run (takesPriority: spans, daily budgets), by kind: held back, not read.
  held: string[] = [];
  commits = 0; commitSlow = 0; commitRetries = 0; logs = 0; inserted: Record<string, number> = {}; trimmed = 0;
  holesMarked = 0; holesCleared = 0; capped = 0;
  // `cut`: lookups a stop ended before their answer (their reads wasted; a "cpu" stop lets the ones in progress finish).
  firstTx = { found: 0, none: 0, same: 0, failed: 0, unconfirmed: 0, movedEarlier: 0, cut: 0 };
  straddle: Record<string, string> = {};
  globalHoles: { scan: string; from: number; to: number }[] = [];
  errors: string[] = [];
  error(line: string) { if (this.errors.length < 5) this.errors.push(this.redact(line).replace(/0x[0-9a-fA-F]{40,}/g, "0x…").slice(0, 120)); }
}

// What every piece of one coalescing key shares (the key: scan, definition, sorted wallet list).
type CommitKey = { scan: ScanId; defVersion: number; wallets: string[] | null };
type Job = { scan: ScanId; defVersion: number; wallets: string[] | null; from: number; to: number; logs: CompactLog[];
             slowRetried: boolean; retries: number; group: { remaining: number; items: WorkItem[] } };

// A first-transaction lookup in progress: the reads reserved for it (cpu.ts lookupReads), those it has made, and whether
// a stop ended it.
type Lookup = { allowance: number; reads: number; cut: boolean };

// The share of a read the CPU check counts before it is sent (cpu.ts Finish): a log read's request, pieces and bytes; a
// small read's request and 64 KiB.
type Extra = Partial<Pick<Finish, "requests" | "pieces" | "bytes" | "lookupReads" | "lookups">>;
const SMALL_READ: Extra = { requests: 1, bytes: 65_536 };

class Stop extends Error { constructor(readonly reason: string) { super(reason); } }

const hex = (n: number) => "0x" + n.toString(16);
const quantity = (v: unknown): number | null => typeof v === "string" && /^0x[0-9a-fA-F]{1,16}$/.test(v) ? parseInt(v, 16) : null;
const NOTHING_TOPIC = "0x" + "f".repeat(64); // matches no event: the straddle self-test's filter
const throttleError = (e: { code?: number; message: string }) =>
  e.code === 429 || e.code === -32005 || /rate limit|too many requests|request limit|per second|throughput/i.test(e.message);

export async function runIndexer(deps: Deps, signal: { shutdown?: string }): Promise<RunSummary> {
  const run = new Run(deps, signal);
  return await run.go();
}

class Run {
  private readonly o: RunOptions;
  private readonly owner = crypto.randomUUID();
  private readonly started: number;
  private readonly redact: Redact;
  private readonly c: Counters;
  // Labels of the endpoints whose URL may hold a key (endpoints.ts isKeyed): their error texts are never stored, an
  // HTTP 401/403 sidelines them at once, and their texts are read for a spent quota or a plan refusal.
  private readonly keyed: Set<string>;
  private readonly offNoted = new Set<string>();
  private align = 0;
  private stop: string | null = null;
  private states: EndpointState[] = [];
  private planner: Planner | null = null;
  private defs = new Map<ScanId, ScanDef>();
  private drift: ScanId[] = [];
  private head: number | null = null;
  private headTimestamp: number | null = null;
  private deadline = 0;           // D: the end of the work
  private readDeadline = 0;       // R: no new reads after it
  private leaseUntil = 0;
  private lastRenew = 0;
  private lastRefresh = 0;
  private stateCursor: string | null = null;
  private wallets = { active: 0, skipped: 0, refreshed: 0 };
  private readonly isolate: IsolateCpu;
  private readonly cpu: CpuMeter;  // this run's part of the isolate's estimate
  private parsedBytes = 0;
  private logsSeen = 0;
  private requestsInFlight = 0;
  private piecesInFlight = 0;     // eth_getLogs pieces in the requests in flight (the CPU reserve)
  private readonly bytes: ByteBudget;
  // The look-ahead (§10): items taken from the planner that wait for an endpoint, offered again most urgent first on
  // every step, so one busy or resting endpoint never holds back work another endpoint could do now (§14). At most
  // `parkItems` of P1–P3 (the follow is never limited; it is bounded by the wallets). An item no endpoint can start
  // before the read deadline stays here to the end of the run (pickEndpoint: late): left unread, it is a gap the next
  // run plans again, and it keeps the run's stop at "deadline" (finish).
  private parked: WorkItem[] = [];
  private readonly probing = new Set<EndpointState>();
  private readonly probes = new Map<EndpointState, number>();
  private readonly pending: Coalescer<CommitKey, WorkItem>;
  private readonly jobs: Job[] = [];
  private commitsInFlight = 0;
  private readonly globalCommitting = new Set<ScanId>();
  private commitLogs: number;
  private commitTimes: number[] = [];
  private uncommitted = 0;
  private waiters: (() => void)[] = [];
  private firstTxWorker: Promise<void> | null = null;

  constructor(private readonly deps: Deps, private readonly signal: { shutdown?: string }) {
    const { plan, ...rest } = deps.options ?? {};
    this.o = { ...DEFAULT_RUN_OPTIONS, ...rest, plan: { ...DEFAULT_PLAN, ...(plan ?? {}) } };
    this.started = deps.now();
    this.redact = deps.redact ?? scrubUrls;
    this.c = new Counters(this.redact);
    this.keyed = new Set(deps.endpoints.filter(isKeyed).map((e) => e.label));
    this.bytes = new ByteBudget(this.o.inFlightReserve, this.o.responseCap, this.o.singleBlockCap);
    this.commitLogs = this.o.commitLogs;
    this.isolate = deps.isolateCpu ?? new IsolateCpu();
    this.cpu = this.isolate.meter({ rpcCpuMs: this.o.rpcCpuMs, dbCpuMs: this.o.dbCpuMs, bytesPerMs: this.o.bytesPerMs });
    this.pending = new Coalescer(this.o.coalesceItems, this.o.coalesceMs);
  }

  private now() { return this.deps.now(); }

  // ── Waiting ─────────────────────────────────────────────────────────────────────────────────────────────────────

  private timer(ms: number, fn: () => void): () => void {
    if (this.deps.setTimer) return this.deps.setTimer(ms, fn);
    let live = true;
    this.deps.sleep(ms).then(() => { if (live) fn(); });
    return () => { live = false; };
  }

  // Until something finishes (a request, a commit) or `ms` pass, whichever is first.
  private wait(ms = 1_000): Promise<void> {
    return new Promise((resolve) => {
      let done = false;
      const finish = () => { if (!done) { done = true; cancel(); resolve(); } };
      const cancel = this.timer(Math.max(0, Math.min(ms, 60_000)), finish);
      this.waiters.push(finish);
    });
  }

  private wake() {
    const w = this.waiters;
    this.waiters = [];
    for (const f of w) f();
  }

  private sync<T>(fn: () => T): T {
    const t = this.deps.cpuNow();
    try { return fn(); } finally { this.cpu.syncMs += Math.max(0, this.deps.cpuNow() - t); }
  }

  private setStop(reason: string) { if (!this.stop) this.stop = reason; }

  // A database call, counted for the CPU estimate (D21) when it is made.
  private db(call: DbCall): HistoryDb {
    this.cpu.db[call]++;
    return this.deps.db;
  }

  // The CPU budget left for more reads: the budget less the isolate's estimate (its start, its requests, its earlier runs
  // and this one), less what finishing this run still costs (cpu.ts finishReserveMs), less `extra` (the read about to be
  // decided).
  private cpuRoom(extra: Extra = {}): number {
    let lookupReads = 0;
    for (const l of this.lookups) lookupReads += Math.max(0, l.allowance - l.reads);
    const reserve = finishReserveMs({
      commits: this.pending.commits(this.commitLogs) + this.jobs.length,
      pieces: this.piecesInFlight + (extra.pieces ?? 0),
      bytes: this.bytes.inUse() + (extra.bytes ?? 0),
      requests: extra.requests ?? 0,
      lookupReads: lookupReads + (extra.lookupReads ?? 0),
      lookups: this.lookups.size + (extra.lookups ?? 0),
      commitLogs: this.commitLogs,
    }, this.cpu.prices);
    return this.o.cpuBudgetMs - this.isolate.spentMs() - reserve;
  }

  // Whether the CPU budget leaves room for more reads (and for `extra`). When it does not, the stop is "cpu": the read
  // loop, the deferred probes and the first-transaction workers start nothing more (a lookup in progress finishes).
  private cpuLeft(extra: Extra = {}): boolean {
    if (this.cpuRoom(extra) > 0) return true;
    this.setStop("cpu");
    return false;
  }

  // ── The run ─────────────────────────────────────────────────────────────────────────────────────────────────────

  async go(): Promise<RunSummary> {
    const { deps, o } = this;
    // The isolate has spent its CPU (earlier runs, the ticks it answered): no lease, nothing to log; a fresh isolate runs.
    if (!isolateHasRoom(this.isolate, o)) return { v: 2, stop: "cpu" };
    let lease;
    try {
      lease = await this.db("lease").lease(this.owner, o.leaseSeconds, deps.version);
    } catch (err) {
      this.setStop("db");
      this.c.error(`lease: ${(err as Error)?.message ?? err}`);
      const summary = this.redacted(this.summary());
      deps.log(`history-indexer: ${JSON.stringify(summary)}`);
      return summary;
    }
    if (!lease.ok) return { v: 2, stop: lease.paused ? "paused" : "busy" }; // silent: another run holds it, or paused
    this.leaseUntil = this.now() + o.leaseSeconds * 1_000;
    this.lastRenew = this.now();
    deps.onLease?.(this.owner);
    this.states = deps.endpoints.map((e) => new EndpointState(e, lease.endpoints[e.label], this.now()));
    try {
      await this.execute();
    } catch (err) {
      this.fail(err);
    } finally {
      await this.finish();
    }
    return this.final ?? this.redacted(this.summary());
  }

  private final: RunSummary | null = null;

  // The summary as it is stored and logged: through the redactor (a summary is counts and labels, so this is a second
  // line of defence). Should a replacement ever break the JSON, only the stop is kept.
  private redacted(summary: RunSummary): RunSummary {
    try {
      return JSON.parse(this.redact(JSON.stringify(summary))) as RunSummary;
    } catch {
      return { v: 2, version: this.deps.version, stop: summary.stop, redacted: true };
    }
  }

  private fail(err: unknown) {
    if (err instanceof Stop) this.setStop(err.reason);
    else if (err instanceof LeaseLost) this.setStop(err.paused ? "paused" : "lease");
    else if (err instanceof DefsChanged) this.setStop("defs");
    else if (err instanceof DbDown) { this.setStop("db"); this.c.error(`db: ${err.message}`); }
    else { this.setStop("error"); this.c.error(`error: ${String((err as Error)?.message ?? err)}`); } // redacted by c.error
  }

  private async execute() {
    const { deps, o } = this;
    const now = this.now();
    this.deadline = Math.min(now + o.workMs, deps.isolateStartedAt + o.isolateMaxMs);
    if (this.deadline - now < o.minRunMs) throw new Stop("isolate");
    this.readDeadline = this.deadline - o.readMarginMs;
    await deps.sleep(Math.floor(deps.random() * o.jitterMs));

    const state = await this.db("state").state(this.owner, o.maxWallets);
    this.lastRefresh = this.now();
    this.stateCursor = new Date(state.now).toISOString();
    this.wallets.active = state.active;
    this.wallets.skipped = state.skipped;
    const defs = defsFromState(state.defs);
    for (const d of defs) this.defs.set(d.id, d);
    this.drift = defsDrift(defs, bundledDefs());

    const head = await this.readHead(state.head);
    if (!head) throw new Stop("head");
    [this.head, this.headTimestamp] = head;
    await this.selfTest();

    this.align = this.planAlign();
    this.planner = this.sync(() => new Planner(state, this.head!, defs, { ...o.plan, align: this.align }, state.now));
    this.firstTxWorker = this.firstTransactions(state.wallets);
    await this.loop();
  }

  // The backfill's piece size this run (PlanOptions.align): the widest span of an endpoint able to take backfill now
  // (not sidelined, log reads on, its daily budget below 100 %), up to maxAlign, in whole multiples of the base align;
  // the base align when none is wider. Endpoints with a narrower span cut each piece to their own (dispatch).
  private planAlign(): number {
    const { align, maxAlign } = this.o.plan;
    const now = this.now();
    let widest = 0;
    for (const s of this.states) {
      if (s.sidelined(now) || s.logsOff(now) || !s.budgetAllows(now, 2)) continue;
      widest = Math.max(widest, s.currentSpan());
    }
    const wide = Math.min(maxAlign, widest);
    return wide > align ? Math.floor(wide / align) * align : align;
  }

  // ── Head (finalized), with a second opinion when it jumped implausibly far ──────────────────────────────────────

  // Endpoints in the follow's order (followRank: rpc2 first, a metered provider last), ≤ 2 tries each; one resting (a
  // Retry-After the last run remembered) is passed over for the next one ready within `headReadyMs`, and waited for only
  // when none is (a lower finalized head from a clamping endpoint is safe: the follow simply starts lower).
  private async readHead(stored: number | null): Promise<[number, number] | null> {
    const tries = new Map<EndpointState, number>();
    let first: [number, number] | null = null;
    for (;;) {
      const now = this.now();
      // An endpoint whose daily budget is spent (a metered provider's maxPerDay) is not asked either.
      const left = this.states.filter((s) => !s.sidelined(now) && s.budgetAllows(now, 0) && (tries.get(s) ?? 0) < 2);
      if (left.length === 0) return first;
      const rank = (x: EndpointState) => followRank(x.endpoint);
      const soon = left.filter((s) => s.nextStartAt(now) <= now + this.o.headReadyMs).sort((a, b) => rank(a) - rank(b));
      const s = soon[0] ?? [...left].sort((a, b) => a.nextStartAt(now) - b.nextStartAt(now) || rank(a) - rank(b))[0];
      tries.set(s, (tries.get(s) ?? 0) + 1);
      const got = await this.headFrom(s);
      if (!got) continue;
      tries.set(s, 2); // answered: never asked again
      if (first) return got[0] < first[0] ? got : first;
      // Plausible: no more than ~5 blocks/s over the last 10 minutes beyond the stored head. Else ask the next endpoint
      // too and take the lower (after downtime this costs one extra request).
      if (stored === null || got[0] <= stored + 5 * 600 + 1_000) return got;
      first = got;
    }
  }

  // An endpoint that answers but cannot name its latest block (an error for both tags) is broken — a key, a quota: a
  // strike (pacing.ts), so it is sidelined even when no log piece ever reaches it.
  private async headFrom(s: EndpointState): Promise<[number, number] | null> {
    let errors = false;
    const block = async (tag: string): Promise<{ number: number; timestamp: number } | "unsupported" | null> => {
      const ex = await this.call(s, [{ method: "eth_getBlockByNumber", params: [tag, false] }], 65_536);
      if (ex.kind !== "answered") return null;
      const r = ex.results[0];
      if (!r.ok) { if (!throttleError(r)) errors = true; return /finalized|tag|invalid/i.test(r.message) ? "unsupported" : null; }
      const b = r.result as Record<string, unknown> | null;
      const number = quantity(b?.number), timestamp = quantity(b?.timestamp);
      return number !== null && timestamp !== null ? { number, timestamp } : null;
    };
    const read = async (): Promise<[number, number] | null> => {
      const fin = await block("finalized");
      if (fin && fin !== "unsupported") return [fin.number, fin.timestamp];
      if (fin === null) return null;
      errors = false; // the tag refused: the question is whether `latest` answers
      const latest = await block("latest");
      if (!latest || latest === "unsupported") return null;
      const settled = await block(hex(Math.max(0, latest.number - 10)));
      return settled && settled !== "unsupported" ? [settled.number, settled.timestamp] : null;
    };
    const head = await read();
    if (!head && errors) { s.strike(this.now()); this.noteSidelined(s); }
    return head;
  }

  // One request through an endpoint's pace (waiting for it), with the outcome noted for pacing. A sidelined endpoint
  // sends nothing: the answer is "unanswered" and nothing is noted. `bypassCap`: past the run's in-flight cap (the
  // block-timestamp reads of a request that already holds a slot, which must never wait on the slots of others).
  // `lookup`: a first-transaction lookup's nonce read, counted against its reserved reads.
  private async call(s: EndpointState, calls: Call[], maxBytes: number, bypassCap = false, lookup?: Lookup): Promise<Exchange> {
    if (!(await this.paced(s, bypassCap, lookup))) return { kind: "unanswered", reason: "network", bytes: 0 };
    if (lookup) lookup.reads++;
    this.c.requests[s.label] = (this.c.requests[s.label] ?? 0) + 1;
    this.cpu.requests++;
    let ex: Exchange = { kind: "unanswered", reason: "network", bytes: 0 };
    try {
      ex = await this.send(s, calls, maxBytes);
    } finally {
      this.requestsInFlight--;
      s.finished(this.now(), this.outcomeOf(s, ex));
      this.noteSidelined(s);
      this.wake();
    }
    return ex;
  }

  // Waits for the endpoint's pace and a slot, then takes both (started, counted in flight); false: it is sidelined. A
  // stop (the CPU budget's included: head reads, probes, nonce and block-timestamp reads) sends nothing more — but for
  // a lookup in progress after a "cpu" stop, within the reads reserved for it (cpu.ts), until the run's finish cuts it.
  private async paced(s: EndpointState, bypassCap = false, lookup?: Lookup): Promise<boolean> {
    for (;;) {
      const reserved = lookup !== undefined && lookup.reads < lookup.allowance; // already in the reserve
      if (!this.stop) this.cpuLeft(reserved ? {} : SMALL_READ);
      if (this.stop && !(reserved && this.stop === "cpu" && !this.lookupsCut)) {
        if (lookup) lookup.cut = true;
        throw new Stop(this.stop);
      }
      const now = this.now();
      if (s.sidelined(now)) return false;
      const at = s.nextStartAt(now);
      const full = !bypassCap && this.requestsInFlight >= this.o.maxInFlightTotal;
      if (at <= now && !full) {
        // Taken in the same synchronous step as the check: several waiters woken together must not all pass it.
        s.started(now);
        this.requestsInFlight++;
        return true;
      }
      if (now >= this.deadline) {
        if (lookup) lookup.cut = true;
        throw new Stop("deadline");
      }
      // A full in-flight cap frees when a request finishes (which wakes every waiter); a pace or a rest has a time.
      await this.wait(full || at === Number.POSITIVE_INFINITY ? 1_000 : Math.max(1, at - now));
    }
  }

  // Reports an endpoint the moment it is sidelined (once per run): it refused SIDELINE_AFTER requests in a row (or, as
  // noteOff already said, a keyed one answered 401/403, or its monthly capacity is spent).
  private noteSidelined(s: EndpointState) {
    if (!s.sidelined(this.now()) || this.c.sidelined.includes(s.label)) return;
    this.c.sidelined.push(s.label);
    if (!this.offNoted.has(s.label)) this.c.error(`sidelined ${s.label}: it refused every request (a key, a quota or a firewall?)`);
  }

  // One error line per endpoint and run for what turned it off, by label and HTTP status only: a provider's own text
  // (which can carry a dashboard link or the URL) is never kept.
  private noteOff(s: EndpointState, line: string) {
    if (this.offNoted.has(s.label)) return;
    this.offNoted.add(s.label);
    this.c.error(line);
  }

  // A keyed endpoint's spent quota, or a plan refusing eth_getLogs ranges.
  private offOutcome(s: EndpointState, kind: "spent" | "plan", status: number): Outcome {
    this.c.refused[s.label] = (this.c.refused[s.label] ?? 0) + 1;
    if (kind === "spent") {
      this.noteOff(s, `${s.label}: monthly capacity spent (HTTP ${status}): off until 00:00 UTC`);
      return { kind: "spent" };
    }
    this.noteOff(s, `${s.label}: its plan refuses eth_getLogs ranges (HTTP ${status}; the Free tier?): no log reads for 24 h`);
    return { kind: "noLogs" };
  }

  private async send(s: EndpointState, calls: Call[], maxBytes: number): Promise<Exchange> {
    // exchange() never throws for the network and never puts the URL in what it returns.
    const ex = await exchange(this.deps.fetch, s.endpoint.url, calls, {
      timeoutMs: this.o.requestTimeoutMs, maxBytes, bare: s.bare() && calls.length === 1, cpuNow: this.deps.cpuNow,
      setTimer: (ms, fn) => this.timer(ms, fn),
    });
    // Every exchange's streamed bytes cost CPU (cpu.ts), answered or not: a tooLarge answer was streamed and inflated up
    // to the cap. Only parsed ones count toward `maxParsedBytes`.
    this.cpu.streamedBytes += ex.bytes;
    if (ex.kind === "answered") { this.cpu.syncMs += ex.parseMs; this.parsedBytes += ex.bytes; }
    return ex;
  }

  // What a request's answer says about the endpoint. An HTTP 4xx (not 429, not the batch refusal) without a JSON-RPC
  // body, or a non-2xx JSON-RPC body refusing every call, is a refusal of the endpoint (a revoked key, a spent quota, a
  // firewall): it rests 2 → 8 → 30 s and the fourth in a row sidelines it (pacing.ts). A keyed endpoint is sidelined by
  // its first HTTP 401/403, off until the next UTC day once its monthly capacity is spent, and without log reads for a
  // day when its plan refuses eth_getLogs ranges (Alchemy's Free tier).
  private outcomeOf(s: EndpointState, ex: Exchange): Outcome {
    const keyed = this.keyed.has(s.label);
    if (ex.kind === "unanswered") return ex.reason === "timeout" ? { kind: "timeout" } : ex.reason === "tooLarge" ? { kind: "answered" } : { kind: "unanswered" };
    if (ex.kind === "http") {
      const v = classifyHttp(ex.status, ex.headers, ex.body, this.now(), keyed);
      if (v.kind === "throttled") { this.c.throttled[s.label] = (this.c.throttled[s.label] ?? 0) + 1; return v; }
      if (v.kind === "batchRefused") return s.bare() ? { kind: "unanswered" } : { kind: "batchRefused" };
      if (v.kind === "unanswered") return { kind: "unanswered" };
      if (v.kind === "spent" || v.kind === "plan") return this.offOutcome(s, v.kind, ex.status);
      this.c.refused[s.label] = (this.c.refused[s.label] ?? 0) + 1;
      if (v.kind === "auth" && keyed) {
        this.noteOff(s, `${s.label}: HTTP ${ex.status}: sidelined for 15 min (the key, or Monad not enabled for it?)`);
        return { kind: "sideline" };
      }
      return { kind: "refused" };
    }
    const errors = ex.results.filter((r) => !r.ok) as Extract<CallResult, { ok: false }>[];
    if (keyed) {
      const refusal = errors.map((e) => endpointRefusal(e.message)).find((r) => r !== null);
      if (refusal) return this.offOutcome(s, refusal, ex.status);
    }
    // A throttle answered in JSON-RPC (rpc2's HTTP 429 carries a JSON-RPC error) keeps the answer's Retry-After.
    if (errors.some(throttleError)) {
      this.c.throttled[s.label] = (this.c.throttled[s.label] ?? 0) + 1;
      return { kind: "throttled", retryAfterMs: retryAfterMs(ex.retryAfter ?? null, this.now()) };
    }
    if (errors.length === ex.results.length && ex.results.length > 1 && errors.every((e) => /internal error/i.test(e.message))) {
      return { kind: "unanswered" };
    }
    if (errors.length === ex.results.length && ex.status >= 400) {
      this.c.refused[s.label] = (this.c.refused[s.label] ?? 0) + 1;
      if (keyed && (ex.status === 401 || ex.status === 403)) {
        this.noteOff(s, `${s.label}: HTTP ${ex.status}: sidelined for 15 min (the key, or Monad not enabled for it?)`);
        return { kind: "sideline" };
      }
      return { kind: "refused" };
    }
    return { kind: "answered", anyOk: errors.length < ex.results.length };
  }

  // ── Straddle self-test (D4): each `refuses` endpoint must refuse a range past its head ──────────────────────────
  // The probe starts well below the head (up to the endpoint's span, ≤ 10,000 blocks), not 10 blocks below it: a
  // clamping node more than 10 blocks behind refuses a range that lies entirely past ITS head ("Block requested not
  // found") and would pass a narrow probe, then silently answer real pieces short (the run-loop test's lagging
  // clamping endpoint found exactly that). A refusing endpoint refuses either way. No verdict (throttled, no answer)
  // → treated as clamping for this run.

  // An endpoint resting at the start (a Retry-After the last run remembered) is not waited for: its probe is deferred
  // until it is first ready (the read loop sends it), and until then it is used as clamping — a piece that needs a
  // refusing endpoint waits for it (pickEndpoint). A probe without a verdict is tried again when the endpoint is next
  // ready, `probeAttempts` in all; then the endpoint is clamping for the rest of the run.
  // A refusing endpoint sidelined, off or without log reads at the start may be back before the reads end (pickEndpoint
  // waits for it): it is clamping until its probe, sent once it is back, passes.
  private async selfTest() {
    for (const s of this.states) {
      const now = this.now();
      if (s.sidelined(now) || s.logsOff(now)) {
        this.c.straddle[s.label] = s.sidelined(now) ? "sidelined" : "nologs";
        if (s.straddle(now) === "refuses") s.deferProbe();
        continue;
      }
      if (s.straddle(now) !== "refuses") { this.c.straddle[s.label] = "clamps"; continue; }
      if (s.nextStartAt(now) > now + this.o.headReadyMs) {
        s.deferProbe();
        this.c.straddle[s.label] = "deferred";
        continue;
      }
      this.settleProbe(s, await this.probe(s));
    }
  }

  private async probe(s: EndpointState): Promise<"refuses" | "clamps" | null> {
    const H = this.head!;
    this.probes.set(s, (this.probes.get(s) ?? 0) + 1);
    const from = Math.max(0, H + 200 - Math.min(10_000, s.currentSpan()) + 1);
    try {
      const ex = await this.call(s, [{ method: "eth_getLogs", params: [{ fromBlock: hex(from), toBlock: hex(H + 200), topics: [NOTHING_TOPIC] }] }], 65_536);
      const r = ex.kind === "answered" ? ex.results[0] : null;
      if (r?.ok && Array.isArray(r.result)) return "clamps";
      if (r && !r.ok && classifyCallError(r, { from, to: H + 200 }, H, this.keyed.has(s.label)).kind === "pastHead") return "refuses";
    } catch (err) {
      if (!(err instanceof Stop)) throw err;
    }
    return null;
  }

  private settleProbe(s: EndpointState, verdict: "refuses" | "clamps" | null) {
    if (verdict === "refuses") {
      s.markVerified();
    } else if (verdict === "clamps") {
      s.markVerified();
      s.markClamps(this.now());
      this.c.error(`straddle: ${s.label} answered past its head; treated as clamping for 24 h`);
    } else if (s.logsOff(this.now())) {           // its plan refused the probe's range: no log reads, nothing to test
      s.markUnverified();
      this.c.straddle[s.label] = "nologs";
      return;
    } else if ((this.probes.get(s) ?? 0) < this.o.probeAttempts && !s.sidelined(this.now()) && !this.stop) {
      s.deferProbe();
      this.c.straddle[s.label] = "deferred";
      return;
    } else {
      s.markUnverified();
    }
    this.c.straddle[s.label] = verdict ?? "unverified";
  }

  // Sends the deferred probes of endpoints that are ready now (one at a time each; the answer wakes the loop).
  private startProbes() {
    const now = this.now();
    for (const s of this.states) {
      if (!s.verifying || this.probing.has(s) || s.sidelined(now) || s.logsOff(now) || s.nextStartAt(now) > now) continue;
      if (this.requestsInFlight >= this.o.maxInFlightTotal) return;
      this.probing.add(s);
      this.probe(s)
        .then((verdict) => this.settleProbe(s, verdict))
        .catch((err) => this.fail(err))
        .finally(() => { this.probing.delete(s); this.wake(); });
    }
  }

  // ── The read loop ───────────────────────────────────────────────────────────────────────────────────────────────

  private async loop() {
    try {
      await this.reads();
    } finally {
      this.loopDone = true;
      this.wake();
    }
  }

  private async reads() {
    const { o } = this;
    for (;;) {
      if (this.stop) return;
      if (this.signal.shutdown) throw new Stop(`shutdown:${this.signal.shutdown}`.slice(0, 40));
      const now = this.now();
      if (now >= this.readDeadline) { this.setStop("deadline"); return; }
      if (this.cpu.syncMs >= o.syncBudgetMs) { this.setStop("cpu"); return; }
      if (!this.cpuLeft()) return;
      if (this.parsedBytes >= o.maxParsedBytes || this.logsSeen >= o.maxLogs) { this.setStop("budget"); return; }
      await this.renewIfDue(false);
      await this.refreshIfDue();
      this.flushDue(now);
      // Too many logs waiting: the largest coalesced fragment goes to the commits now rather than when it is full or old.
      if (this.uncommitted > o.backpressureLogs && this.jobs.length === 0) { const f = this.pending.largest(); if (f) this.flush(f); }
      this.pumpCommits();
      if (this.uncommitted > o.backpressureLogs || this.jobs.length + this.commitsInFlight > o.backpressureCommits) {
        await this.wait(1_000);
        continue;
      }
      this.startProbes();
      if (this.requestsInFlight >= o.maxInFlightTotal) { await this.wait(1_000); continue; }
      const step = this.step();
      if (step === "sent" || step === "stop" || step === "more") continue;
      if (step === "idle") {
        const committing = this.commitNewWindows();
        if (this.requestsInFlight === 0 && !this.firstTxBusy && this.probing.size === 0 && !committing) {
          this.setStop(this.heldLeft() ? "blocked" : "done");
          return;
        }
        await this.wait(1_000);
        continue;
      }
      // Everything at hand waits: for the earliest endpoint to be ready, for bytes, or for something to finish.
      await this.wait(step === "bytes" || step.waitUntil === Number.POSITIVE_INFINITY ? 1_000 : Math.max(1, step.waitUntil - this.now()));
    }
  }

  // One step of the read loop: top up the look-ahead from the planner, then send its most urgent item that an endpoint
  // can take now (items of a priority in the order the planner gave them: newest first). An item whose endpoints are
  // all busy or resting stays parked and the next one is tried — never a stall behind one endpoint (§14). An item none
  // of whose endpoints can start before the read deadline (late: deep work while rpc2, the only public endpoint wide
  // enough for it, rests or is sidelined past the deadline) stays parked too, until the reads end: it holds its place in
  // the look-ahead, so no further planner item is pulled for it, and the run stops "deadline" with work left, not "done".
  // An item whose priority no endpoint may take at all any more (a span narrowed during the run: takesPriority) goes
  // back to the planner, which hands out no more of it (topUp). Only an item no endpoint can take for itself (the
  // straddle rule) is settled (unreadable) — at most `parkItems` in one step ("more": the read loop checks its budgets
  // before the next) — and only then is the look-ahead topped up again within the step.
  private step(): "sent" | "stop" | "idle" | "bytes" | "more" | { waitUntil: number } {
    let settled = 0;
    for (;;) {
      this.topUp();
      if (this.parked.length === 0) return "idle";
      const now = this.now();
      let wait = Number.POSITIVE_INFINITY;
      let room = false, bytes = false;
      for (const item of this.byUrgency(this.parked)) {
        const pick = pickEndpoint(this.states, item, now, this.head!, this.readDeadline);
        if (pick === null) {
          this.unpark(item);
          room = true;
          if (!takesPriority(this.states, item.priority, now)) { this.planner!.giveBack(item); continue; } // held from now on
          this.unreadable(item);
          if (++settled >= this.o.parkItems) return "more";
          continue;
        }
        if ("late" in pick) { wait = Math.min(wait, this.readDeadline); continue; } // stays parked; wake at the deadline
        if ("waitUntil" in pick) { wait = Math.min(wait, pick.waitUntil); continue; }
        // The request, its pieces' commits and its bytes must fit the CPU budget too (cpu.ts): else the stop is "cpu".
        if (!this.cpuLeft(this.dispatchShare(item, pick.state))) return "stop";
        const at = this.unpark(item);
        if (this.dispatch(item, pick.state, pick.upTo)) return "sent";
        this.parked.splice(at, 0, item); // no bytes for it now: it keeps its place
        bytes = true;
      }
      if (room) continue; // room again: top up and try once more
      return bytes && wait === Number.POSITIVE_INFINITY ? "bytes" : { waitUntil: wait };
    }
  }

  // Fills the look-ahead from the planner: up to `parkItems` P1–P3 items (and every follow item); once full, only items
  // more urgent than its least urgent one, which then goes back to the planner. Nothing of a held priority.
  private topUp() {
    const planner = this.planner!;
    const held = this.heldPriorities(this.now());
    for (;;) {
      const counted = this.parked.filter((i) => i.priority > 0);
      const max = counted.length < this.o.parkItems ? 3 : Math.max(...counted.map((i) => i.priority)) - 1;
      const item = this.sync(() => planner.next(planner.pendingNewWindows() === 0, max as Priority, held));
      if (!item) return;
      this.park(item);
    }
  }

  // The priorities no endpoint may take now (takesPriority: every span too narrow, or every daily budget too full, for
  // them; e.g. deep work after rpc2 taught a span below 10,000 blocks, remembered for a day): held back — their items
  // stay in the planner, none is handed out only to be given up, and the read loop ends "blocked", not "done", while any
  // are left. Worked out again on every top-up (a budget frees at 00:00 UTC), and named in the summary (`counts.held`).
  private heldPriorities(now: number): Set<Priority> {
    const held = new Set<Priority>();
    for (const p of [0, 1, 2, 3] as Priority[]) {
      if (takesPriority(this.states, p, now)) continue;
      held.add(p);
      if (!this.c.held.includes(PRIORITY_KIND[p])) this.c.held.push(PRIORITY_KIND[p]);
    }
    return held;
  }

  // Work of a held priority left in the planner.
  private heldLeft(): boolean {
    const held = [...this.heldPriorities(this.now())];
    return held.length > 0 && this.sync(() => this.planner!.hasWork(held));
  }

  // New wallets' windows hold the deep pass back until their last piece is committed (planner.pendingNewWindows), and a
  // coalesced piece waits up to `coalesceMs` for its neighbours. With nothing else to read, they go to the commits now
  // and the read loop waits for them, rather than end its reads with the deep pass never started. True while they are
  // being committed.
  private commitNewWindows(): boolean {
    if (this.planner!.pendingNewWindows() === 0) return false;
    if (this.pending.size === 0 && this.jobs.length === 0 && this.commitsInFlight === 0) return false;
    for (const f of this.pending.drain()) this.flush(f);
    this.pumpCommits();
    return true;
  }

  private park(item: WorkItem) {
    this.parked.push(item);
    const counted = this.parked.filter((i) => i.priority > 0);
    if (counted.length <= this.o.parkItems) return;
    let worst: WorkItem | null = null;
    for (const i of counted) if (!worst || i.priority >= worst.priority) worst = i; // the least urgent, the last given
    this.unpark(worst!);
    this.planner!.giveBack(worst!);
  }

  private unpark(item: WorkItem): number {
    const at = this.parked.indexOf(item);
    if (at >= 0) this.parked.splice(at, 1);
    return at < 0 ? this.parked.length : at;
  }

  // Most urgent first; within a priority, in the order they were parked (a stable sort).
  private byUrgency(items: readonly WorkItem[]): WorkItem[] {
    return [...items].sort((a, b) => a.priority - b.priority);
  }

  // No endpoint can take the item this run at all (pickEndpoint null: not merely too late, which stays parked): past
  // the head on clamping endpoints only (the next run), or dropped.
  private unreadable(item: WorkItem) {
    if (item.to > this.head! - this.maxLag()) this.c.straddleWaits++;
    else this.c.dropped++;
    this.planner!.settle(item);
  }

  private maxLag() { return Math.max(0, ...this.states.map((s) => s.endpoint.lag)); }

  private kindOf(item: WorkItem): string { return item.single ? "single" : item.kind; }
  // The byte budget's running averages: per endpoint for one with its own response cap (a wide provider's answers are
  // not the size of rpc2's 10,000-block ones).
  private byteKind(item: WorkItem, s: EndpointState): string {
    return s.endpoint.responseCap && !item.single ? `${this.kindOf(item)}@${s.label}` : this.kindOf(item);
  }
  private responseCap(item: WorkItem, s: EndpointState): number {
    return item.single ? this.o.singleBlockCap : Math.min(s.endpoint.responseCap ?? this.o.responseCap, this.o.inFlightReserve);
  }
  // What sending `item` on `s` adds to the CPU reserve at most: one request, a full batch of pieces, the bytes dispatch
  // would reserve for it.
  private dispatchShare(item: WorkItem, s: EndpointState): Extra {
    return { requests: 1, pieces: item.alone || item.single ? 1 : s.currentBatch(),
             bytes: this.bytes.reservation(this.byteKind(item, s), !!item.single, this.responseCap(item, s)) };
  }

  // Cuts `item` to what `s` may read, fills a batch from the look-ahead, reserves bytes, and sends it (asynchronously).
  // False (and nothing changed) when the bytes cannot be reserved now.
  private dispatch(first: WorkItem, s: EndpointState, upTo: number): boolean {
    const planner = this.planner!;
    const maxBytes = this.responseCap(first, s);
    const reserved = this.bytes.tryReserve(this.byteKind(first, s), !!first.single, maxBytes);
    if (reserved === null) return false;
    const pieces: WorkItem[] = [];
    const take = (item: WorkItem, top: number) => {
      let it = item;
      const parts: WorkItem[] = [];
      if (top < it.to) {                        // the part above head − lag waits for a refusing endpoint
        const upper = { ...it, from: top + 1 };
        it = { ...it, to: top };
        parts.push(upper);
        planner.requeue(upper, true);
      }
      const span = it.single ? 1 : s.currentSpan();
      const piece = { ...it, from: Math.max(it.from, it.to - span + 1) };
      parts.push(piece);
      if (piece.from > it.from) {
        const rest = { ...it, to: piece.from - 1 };
        parts.push(rest);
        planner.requeue(rest, true);
      }
      if (parts.length > 1) planner.derive(item, parts);
      pieces.push(piece);
    };
    take(first, upTo);
    const batch = first.alone || first.single ? 1 : s.currentBatch();
    if (batch > 1) {
      this.topUp();
      const now = this.now();
      for (const next of this.byUrgency(this.parked)) {
        if (pieces.length >= batch) break;
        const top = s.highestAllowed(now, next.from, this.head!);
        if (next.alone || next.single || top === null || (next.refusingOnly && s.straddle(now) !== "refuses") ||
            !s.budgetAllows(now, next.priority) || s.currentSpan() < minSpanFor(next.priority)) continue;
        this.unpark(next);
        take(next, Math.min(next.to, top));
      }
    }
    const calls = this.sync(() => pieces.map((p) => ({ method: "eth_getLogs", params: [filterFor(this.defs.get(p.scan)!, p.from, p.to, p.wallets)] })));
    s.started(this.now());
    this.c.requests[s.label] = (this.c.requests[s.label] ?? 0) + 1;
    this.cpu.requests++;
    this.requestsInFlight++;
    this.piecesInFlight += pieces.length;
    let noted = false;
    this.send(s, calls, maxBytes)
      .then((ex) => { noted = true; return this.answered(s, pieces, ex); })
      .catch((err) => { if (!noted) s.finished(this.now(), { kind: "unanswered" }); this.fail(err); })
      .finally(() => {
        this.requestsInFlight--;
        this.piecesInFlight -= pieces.length;
        this.bytes.release(reserved, !!first.single);
        this.wake();
      });
    return true;
  }

  // §10.1: one request's outcome, piece by piece.
  private async answered(s: EndpointState, pieces: WorkItem[], ex: Exchange) {
    const planner = this.planner!;
    const now = this.now();
    const H = this.head!;
    const outcome = this.outcomeOf(s, ex);
    s.finished(now, outcome);
    this.noteSidelined(s);
    const again = (p: WorkItem, front = true) => planner.requeue(p, front);
    const batch = pieces.length > 1;
    // The endpoint refused the whole request: its pieces go back unchanged and uncounted (a refusing endpoint never
    // turns a piece into a hole); the endpoint rests, and is sidelined after four refusals in a row (a keyed one at
    // once on HTTP 401/403), is off for the day (spent), or takes no more log pieces (its plan).
    if (outcome.kind === "refused" || outcome.kind === "sideline" || outcome.kind === "spent" || outcome.kind === "noLogs") {
      for (const p of pieces) again(p);
      return;
    }
    const keyed = this.keyed.has(s.label);
    if (ex.kind === "http") {
      // Throttled or a refused batch: re-queued as they are. A 5xx without JSON-RPC: a batch's pieces each alone; a
      // piece already alone counts an attempt (3, then dropped, or a hole at its minimum size).
      for (const p of pieces) {
        if (outcome.kind !== "unanswered") again(p);
        else if (batch) again({ ...p, alone: true });
        else this.failedPiece(p, `${s.label}: HTTP ${ex.status}`);
      }
      return;
    }
    if (ex.kind === "unanswered") {
      if (ex.reason === "timeout") this.c.timeouts++;
      if (ex.reason === "timeout" || ex.reason === "tooLarge") {
        if (ex.reason === "tooLarge") this.c.dense++;
        // A batch: every piece alone at once; a piece already alone is too dense (split, never capped: D10).
        for (const p of pieces) if (batch) again({ ...p, alone: true }); else await this.split(p);
        return;
      }
      for (const p of pieces) {
        if (batch) again({ ...p, alone: true });
        else this.failedPiece(p, `${s.label}: ${ex.reason}`);
      }
      return;
    }
    // Every call failed with an error that says nothing about the piece: a strike against the endpoint (pacing.ts). Only
    // the first strike in a row counts an attempt for its pieces.
    const verdicts = pieces.map((p, k) => { const r = ex.results[k]; return r.ok ? null : classifyCallError(r, p, H, keyed); });
    const endpointAtFault = verdicts.every((v) => v?.kind === "failed") && s.strike(now);
    this.noteSidelined(s);
    for (let k = 0; k < pieces.length; k++) {
      const p = pieces[k];
      const r = ex.results[k];
      if (!r.ok) {
        const v = verdicts[k]!;
        switch (v.kind) {
          case "throttled": case "plan": case "spent": again(p); break;
          case "span":
            s.note(now, { kind: "span", span: v.span, tried: p.to - p.from + 1 });
            again(p);
            break;
          case "dense":
            this.c.dense++;
            await this.split(p, v.cut);
            break;
          case "pastHead": {
            this.c.pastHead++;
            s.note(now, { kind: "pastHead" });
            const times = (p.pastHead ?? 0) + 1;
            if (times >= this.o.maxPastHead) { planner.settle(p); this.c.straddleWaits++; break; } // the next run
            again({ ...p, pastHead: times, refusingOnly: true }, false);
            break;
          }
          case "failed":
            if (endpointAtFault) again(p);
            // A keyed provider's text is never kept (it can quote the URL or a dashboard link): its code only.
            else this.failedPiece(p, keyed ? `${s.label}: error ${r.code ?? "without a code"}` : `${s.label}: ${r.message.slice(0, 60)}`);
            break;
        }
        continue;
      }
      const checked = this.sync(() => checkAnswer(this.defs.get(p.scan)!, p, r.result));
      if (!checked.ok) {
        this.c.invalid++;
        this.c.error(`invalid answer from ${s.label}: ${checked.reason}`);
        s.note(now, { kind: "invalid" });
        this.failedPiece(p, null);
        continue;
      }
      // Too dense to trust whole: ≥ 10,000 logs, or a block with more than one commit can hold.
      const single = p.from === p.to && p.wallets.length <= 1;
      let perBlock = 0, run = 0, last = -1;
      for (const l of checked.logs) { run = l.b === last ? run + 1 : 1; last = l.b; perBlock = Math.max(perBlock, run); }
      if (single ? checked.logs.length > this.o.singleBlockLogs : (checked.logs.length >= this.o.denseLogs || perBlock > this.o.singleBlockLogs)) {
        this.c.dense++;
        await this.split(p);
        continue;
      }
      if (checked.missingTimestamps.length > 0 && !(await this.fillTimestamps(s, checked.logs, checked.missingTimestamps))) {
        if (s.sidelined(this.now())) again(p);
        else this.failedPiece(p, `${s.label}: block timestamps unavailable`);
        continue;
      }
      this.logsSeen += checked.logs.length;
      this.c.logs += checked.logs.length;
      this.bytes.observe(this.byteKind(p, s), ex.bytes / pieces.length);
      this.coalesce(p, checked.logs);
    }
  }

  // A piece that failed: retried up to 3 times this run; then a piece at its minimum size becomes a hole, any other
  // stays a gap for the next run. A hole's retry that failed is recorded again whatever its size (it is already a hole):
  // that restarts its 6-hour clock (history_mark_hole), instead of retrying it on every run.
  private failedPiece(p: WorkItem, reason: string | null) {
    const planner = this.planner!;
    if (reason) { this.c.failed++; }
    const attempts = p.attempts + 1;
    if (attempts < this.o.maxAttempts) { planner.requeue({ ...p, attempts }, false); return; }
    const global = GLOBAL_SCANS.includes(p.scan);
    const minimal = p.from === p.to || (global && p.to - p.from + 1 <= 100);
    if (reason) this.c.error(`gave up on a piece: ${reason}`);
    if (minimal || p.hole) { this.hole(p).catch((err) => this.fail(err)); return; }
    this.c.dropped++;
    planner.settle(p);
  }

  // D10: halve the range down to 100 blocks, then the wallet list, then down to single blocks; a single block for one
  // wallet (or a global single block) still too dense is a hole. Never a cap.
  private async split(p: WorkItem, cut?: number) {
    const planner = this.planner!;
    const blocks = p.to - p.from + 1;
    let parts: WorkItem[];
    const base = { ...p, attempts: 0, alone: true, single: false };
    if (blocks > 100 || (blocks > 1 && p.wallets.length <= 1)) {
      const mid = cut !== undefined && cut >= p.from && cut < p.to ? cut : p.from + Math.floor((blocks - 1) / 2);
      parts = [{ ...base, from: mid + 1 }, { ...base, to: mid }];
    } else if (p.wallets.length > 1) {
      const half = Math.ceil(p.wallets.length / 2);
      parts = [{ ...base, wallets: p.wallets.slice(0, half) }, { ...base, wallets: p.wallets.slice(half) }];
    } else {
      await this.hole(p);
      return;
    }
    parts = parts.map((x) => ({ ...x, single: x.from === x.to }));
    planner.derive(p, parts);
    for (const x of [...parts].reverse()) planner.requeue(x, true); // newest first
  }

  private async hole(p: WorkItem) {
    const planner = this.planner!;
    const global = GLOBAL_SCANS.includes(p.scan);
    try {
      if (global) {
        await this.db("markHole").markHole(this.owner, p.scan, p.defVersion, null, p.from, p.to);
        planner.holed(p.scan, null, [p.from, p.to]);
        if (this.c.globalHoles.length < 20) this.c.globalHoles.push({ scan: p.scan, from: p.from, to: p.to });
        this.c.holesMarked++;
      } else {
        for (const w of p.wallets) {
          await this.db("markHole").markHole(this.owner, p.scan, p.defVersion, w, p.from, p.to);
          planner.holed(p.scan, w, [p.from, p.to]);
          this.c.holesMarked++;
        }
      }
    } catch (err) {
      if (err instanceof Refused) this.c.error(`hole refused: ${p.scan}`);
      else if (err instanceof CommitSlow || err instanceof Retryable) this.c.error(`hole not recorded: ${p.scan}`);
      else throw err;
    } finally {
      planner.settle(p);
    }
  }

  // Blocks whose logs came without blockTimestamp (never on the public endpoints; a custom provider): read their
  // headers on the same endpoint. Past the run's in-flight cap: the request they complete still holds its slot, and
  // with every slot held by such requests they would wait on each other until the deadline.
  private async fillTimestamps(s: EndpointState, logs: CompactLog[], blocks: number[]): Promise<boolean> {
    const times = new Map<number, number>();
    for (let k = 0; k < blocks.length; k += Math.max(1, s.currentBatch())) {
      const chunk = blocks.slice(k, k + Math.max(1, s.currentBatch()));
      const ex = await this.call(s, chunk.map((b) => ({ method: "eth_getBlockByNumber", params: [hex(b), false] })), 4 * MiB, true);
      if (ex.kind !== "answered") return false;
      ex.results.forEach((r, i) => {
        const t = r.ok ? quantity((r.result as Record<string, unknown> | null)?.timestamp) : null;
        if (t !== null) times.set(chunk[i], t);
      });
    }
    return fillTimestamps(logs, times);
  }

  // ── Coalescing and committing (§12) ─────────────────────────────────────────────────────────────────────────────

  private key(p: { scan: ScanId; defVersion: number; wallets: readonly string[] }) {
    return `${p.scan}|${p.defVersion}|${[...p.wallets].sort().join(",")}`;
  }

  // An answered piece joins the adjacent fragments of its key (coalesce.ts); a fragment full of pieces or logs goes to the
  // commits at once, any other when it is `coalesceMs` old, under back-pressure, or at the end of the run.
  private coalesce(p: WorkItem, logs: CompactLog[]) {
    const meta: CommitKey = { scan: p.scan, defVersion: p.defVersion, wallets: GLOBAL_SCANS.includes(p.scan) ? null : [...p.wallets].sort() };
    this.uncommitted += logs.length;
    for (const f of this.pending.add(this.key(p), meta, p.from, p.to, logs, p, this.now(), this.commitLogs)) this.flush(f);
    this.pumpCommits();
  }

  private flushDue(now: number) {
    for (const f of this.pending.due(now)) this.flush(f);
  }

  // A fragment into commit jobs of ≤ commitLogs logs each, cut at block boundaries, together covering exactly its range.
  private flush(f: Fragment<CommitKey, WorkItem>) {
    const { scan, defVersion, wallets } = f.meta;
    const sorted = f.logs.sort((a, b) => a.b - b.b || a.i - b.i);
    const parts = splitForCommit(sorted, f.from, f.to, this.commitLogs);
    const group = { remaining: parts.length, items: f.items };
    for (const part of parts.reverse()) {  // newest first
      this.jobs.push({ scan, defVersion, wallets, from: part.from, to: part.to, logs: part.logs, slowRetried: false, retries: 0, group });
    }
  }

  private pumpCommits() {
    while (this.commitsInFlight < this.o.commitConcurrency && !this.stopsCommits()) {
      const at = this.jobs.findIndex((j) => !GLOBAL_SCANS.includes(j.scan) || !this.globalCommitting.has(j.scan));
      if (at < 0) return;
      const job = this.jobs.splice(at, 1)[0];
      this.commitsInFlight++;
      if (GLOBAL_SCANS.includes(job.scan)) this.globalCommitting.add(job.scan);
      this.commit(job).catch((err) => this.fail(err)).finally(() => {
        this.commitsInFlight--;
        this.globalCommitting.delete(job.scan);
        this.wake();
        this.pumpCommits();
      });
    }
  }

  // Stops after which nothing more is committed: the lease or the definitions are gone, the database is down, or the
  // platform is shutting the isolate down (index.ts has already released the run).
  private stopsCommits() {
    return this.stop !== null && (["lease", "paused", "defs", "db", "error"].includes(this.stop) || this.stop.startsWith("shutdown:"));
  }

  private async commit(job: Job) {
    const planner = this.planner!;
    const args: CommitArgs = { owner: this.owner, scan: job.scan, defVersion: job.defVersion, from: job.from, to: job.to,
                               head: this.head!, headTimestamp: this.headTimestamp!, wallets: job.wallets, logs: job.logs };
    const started = this.now();
    let done = true;
    try {
      this.cpu.syncMs += compactBytes(job.logs) / 200_000; // the payload's JSON.stringify inside the client, at ~200 MB/s
      const answer = await this.db("commit").commit(args);
      this.commitTimes.push(this.now() - started);
      if (this.commitTimes.length > 50) this.commitTimes.shift();
      if (this.p95() > 2_000) this.readDeadline = Math.min(this.readDeadline, this.deadline - this.o.slowReadMarginMs);
      this.c.commits++;
      this.c.inserted[job.scan] = (this.c.inserted[job.scan] ?? 0) + answer.inserted;
      this.c.trimmed += answer.trimmed;
      this.c.holesCleared += planner.committed(job.scan, job.wallets, [job.from, job.to]);
      for (const [w, floor] of Object.entries(answer.capFloors)) { planner.capped(w, job.scan, floor); this.c.capped++; }
    } catch (err) {
      if (err instanceof LeaseLost) { this.setStop(err.paused ? "paused" : "lease"); return; }
      if (err instanceof DefsChanged) { this.setStop("defs"); return; }
      if (err instanceof CommitSlow) {
        this.c.commitSlow++;
        this.commitLogs = Math.max(this.o.minCommitLogs, Math.floor(this.commitLogs / 2));
        if (!job.slowRetried) {
          const parts = splitForCommit(job.logs, job.from, job.to, Math.max(1, Math.ceil(job.logs.length / 2)));
          const sub = parts.length > 1 ? parts : [{ from: job.from, to: job.to, logs: job.logs }];
          job.group.remaining += sub.length - 1;
          for (const part of sub.reverse()) this.jobs.unshift({ ...job, from: part.from, to: part.to, logs: part.logs, slowRetried: true });
          this.c.commitRetries++;
          done = false;
        } else {
          this.c.error(`commit slow twice: ${job.scan}; the range stays a gap`);
        }
        return;
      }
      if (err instanceof Retryable && job.retries < 2) {
        this.c.commitRetries++;
        await this.deps.sleep(100 + Math.floor(this.deps.random() * 400));
        this.jobs.unshift({ ...job, retries: job.retries + 1 });
        done = false;
        return;
      }
      if (err instanceof Refused || err instanceof Retryable) { this.c.error(`commit refused: ${job.scan} ${(err as Error).message.slice(0, 60)}`); return; }
      if (err instanceof DbDown) { this.setStop("db"); this.c.error(`db: ${err.message}`); return; }
      throw err;
    } finally {
      if (done) {
        this.uncommitted = Math.max(0, this.uncommitted - job.logs.length);
        if (--job.group.remaining === 0) for (const item of job.group.items) planner.settle(item);
      }
    }
  }

  private p95(): number {
    if (this.commitTimes.length < 5) return 0;
    const sorted = [...this.commitTimes].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length * 0.95)] ?? 0;
  }

  // ── Lease and mid-run refresh ───────────────────────────────────────────────────────────────────────────────────

  private async renewIfDue(final: boolean) {
    const now = this.now();
    if (!final && now - this.lastRenew < this.o.renewMs) return;
    if (final && this.leaseUntil - now > 30_000) return;
    const lease = await this.db("lease").lease(this.owner, this.o.leaseSeconds, this.deps.version);
    if (!lease.ok) throw new LeaseLost("the lease was taken", lease.paused);
    this.lastRenew = this.now();
    this.leaseUntil = this.lastRenew + this.o.leaseSeconds * 1_000;
  }

  private async refreshIfDue() {
    if (this.now() - this.lastRefresh < this.o.stateRefreshMs || !this.stateCursor) return;
    this.lastRefresh = this.now();
    const fresh: IndexerState = await this.db("state").state(this.owner, this.o.maxWallets, this.stateCursor);
    this.stateCursor = new Date(fresh.now).toISOString();
    if (fresh.wallets.length === 0) return;
    this.wallets.refreshed += fresh.wallets.length;
    this.sync(() => this.planner!.addWallets(fresh.wallets));
    this.firstTxQueue.unshift(...fresh.wallets.filter((w) => this.needsFirstTx(w, fresh.now)));
  }

  // ── First transactions (§13), alongside the reads ──────────────────────────────────────────────────────────────

  private firstTxQueue: WalletState[] = [];
  private firstTxActive = 0;
  private firstTxStarted = 0;
  private firstTxDone = false;          // every worker has returned: no lookup starts any more this run
  private readonly lookups = new Set<Lookup>();
  private lookupsCut = false;           // the finish stopped waiting: a lookup in progress stops at its next read too
  private loopDone = false;
  // Wallets waiting for, or in, a first-transaction lookup this run (the read loop is not done while there are any).
  private get firstTxBusy(): boolean {
    return this.firstTxActive > 0 || (!this.firstTxDone && this.firstTxQueue.length > 0 && this.firstTxStarted < this.o.firstTxPerRun);
  }

  // The reads one lookup may make (reserved for it while it runs), and what that costs with its setFirstTx.
  private lookupAllowance(): number { return lookupReads(this.head ?? 0); }
  private lookupCostMs(): number { return this.lookupAllowance() * this.o.rpcCpuMs + this.o.dbCpuMs; }

  // Whether one more lookup may start: the lookups of this run, each priced whole, stay within `firstTxCpuShare` of
  // the budget, and the whole of it fits in what the budget has left (so it is never cut off half done).
  private lookupFits(): boolean {
    const cost = this.lookupCostMs();
    if ((this.firstTxStarted + 1) * cost > this.o.firstTxCpuShare * this.o.cpuBudgetMs) return false;
    return this.cpuRoom({ lookupReads: this.lookupAllowance(), lookups: 1 }) > 0;
  }

  private needsFirstTx(w: WalletState, now: number): boolean {
    const f = w.firstTx;
    if (f.state === "unknown") return true;
    if (f.state === "none") return f.checkedAt === null || now - f.checkedAt >= 6 * 3_600_000;
    return f.checkedAt === null || now - f.checkedAt >= 7 * 86_400_000;
  }

  private async firstTransactions(wallets: WalletState[]) {
    const now = this.now();
    const rank = (w: WalletState) => (w.firstTx.state === "unknown" ? 0 : w.firstTx.state === "none" ? 1 : 2);
    this.firstTxQueue = wallets.filter((w) => this.needsFirstTx(w, now)).sort((a, b) => rank(a) - rank(b));
    const workers: Promise<void>[] = [];
    for (let k = 0; k < this.o.firstTxConcurrency; k++) workers.push(this.firstTxLoop());
    await Promise.all(workers);
    this.firstTxDone = true;
    this.wake();
  }

  private async firstTxLoop() {
    for (;;) {
      if (this.stop || !this.cpuLeft() || this.now() >= this.readDeadline || this.firstTxStarted >= this.o.firstTxPerRun) return;
      if (this.firstTxQueue.length > 0 && !this.lookupFits()) return; // its share spent, or no room for a whole one
      const w = this.firstTxQueue.shift();
      if (!w) {
        if (this.loopDone) return;
        await this.wait(1_000);   // a mid-run refresh may bring new wallets
        continue;
      }
      this.firstTxStarted++;
      this.firstTxActive++;
      const lookup: Lookup = { allowance: this.lookupAllowance(), reads: 0, cut: false };
      this.lookups.add(lookup);
      try {
        await this.firstTxOf(w, lookup);
      } catch (err) {
        if (err instanceof Stop) { this.c.firstTx.cut++; return; }
        if (err instanceof LeaseLost || err instanceof DefsChanged || err instanceof DbDown) { this.fail(err); return; }
        this.c.firstTx.failed++;
      } finally {
        this.lookups.delete(lookup);
        this.firstTxActive--;
        this.wake();
      }
    }
  }

  // The archive endpoints in the order nonce reads try them: the wide logs endpoints (span ≥ 10,000) last; one whose
  // log reads are off (its plan) still answers nonces, one whose daily budget is spent does not.
  private nonceSources(wallet: string, lookup: Lookup): NonceSource[] {
    const archive = this.states.filter((s) => s.endpoint.archive && !s.sidelined(this.now()) && s.budgetAllows(this.now(), 0))
      .sort((a, b) => (a.endpoint.span >= 10_000 ? 1 : 0) - (b.endpoint.span >= 10_000 ? 1 : 0) || a.endpoint.priority - b.endpoint.priority);
    return archive.map((s) => ({
      label: s.label,
      nonceAt: async (block: number) => {
        const ex = await this.call(s, [{ method: "eth_getTransactionCount", params: [wallet, hex(block)] }], 65_536, false, lookup);
        if (ex.kind !== "answered" || !ex.results[0].ok) throw new Error("no nonce");
        const n = quantity(ex.results[0].result);
        if (n === null) throw new Error("malformed nonce");
        return BigInt(n);
      },
    }));
  }

  private async firstTxOf(w: WalletState, lookup: Lookup) {
    const H = this.head!;
    const sources = this.nonceSources(w.wallet, lookup);
    if (sources.length === 0) return;
    const opts = { sleep: (ms: number) => this.deps.sleep(ms), pauseMs: this.o.firstTxPauseMs };
    const f = w.firstTx;
    const result = f.state === "found" && f.block !== null
      ? await reverifyFirstTx(sources, { block: f.block, source: f.source }, opts)
      : await locateFirstTx(sources, H, f.state === "none" && f.head !== null && f.head < H ? { ...opts, zeroAt: f.head } : opts);
    switch (result.state) {
      case "found":
        if (await this.db("setFirstTx").setFirstTx(this.owner, w.wallet, "found", result.block, H, result.source)) {
          this.c.firstTx.found++;
          if (result.movedEarlier) this.c.firstTx.movedEarlier++;
        }
        this.planner?.markDeep(w.wallet);
        break;
      case "same":
        await this.db("setFirstTx").setFirstTx(this.owner, w.wallet, "found", f.block!, H, f.source ?? sources[0].label);
        this.c.firstTx.same++;
        break;
      case "none":
        await this.db("setFirstTx").setFirstTx(this.owner, w.wallet, "none", null, H, sources[0].label);
        this.c.firstTx.none++;
        break;
      case "unconfirmed": this.c.firstTx.unconfirmed++; break;
      case "failed": if (lookup.cut) this.c.firstTx.cut++; else this.c.firstTx.failed++; break; // cut: a stop refused its read
    }
  }

  // ── The end of the run ──────────────────────────────────────────────────────────────────────────────────────────

  private async finish() {
    const { deps } = this;
    try {
      // No new reads: let the requests in flight answer (each has its own timeout), then commit what they brought.
      while (this.requestsInFlight > 0 && this.now() < this.deadline + this.o.requestTimeoutMs) await this.wait(1_000);
      // The first-transaction workers stop at their next read once a stop is set — after a "cpu" stop, a lookup in
      // progress first finishes the reads reserved for it (up to a minute, within the deadline), and is then cut too.
      // Wait for them (bounded), so nothing of this run is written after its release.
      if (!this.stop) this.stop = "done";
      if (this.firstTxWorker) {
        const finishing = this.stop === "cpu" ? Math.min(60_000, this.deadline - this.now()) - this.o.requestTimeoutMs : 0;
        if (finishing > 0 && !this.firstTxDone) await Promise.race([this.firstTxWorker, this.deps.sleep(finishing)]);
        this.lookupsCut = true;
        if (!this.firstTxDone) await Promise.race([this.firstTxWorker, this.deps.sleep(this.o.requestTimeoutMs)]);
      }
      if (!this.stopsCommits() && this.planner) {
        for (const f of this.pending.drain()) this.flush(f);
        if (this.jobs.length > 0) await this.renewIfDue(true);
        this.pumpCommits();
        while ((this.jobs.length > 0 || this.commitsInFlight > 0) && !this.stopsCommits() && this.now() < this.deadline + 30_000) {
          await this.wait(1_000);
          this.pumpCommits();
        }
      }
      while (this.commitsInFlight > 0 && this.now() < this.deadline + 30_000) await this.wait(1_000);
    } catch (err) {
      this.fail(err);
    }
    // "deadline" with nothing left is "done": no item parked (a parked one — late for an endpoint resting past the read
    // deadline, or waiting for one — is work left) and none in the planner (re-queued or given-back pieces, a pass not
    // finished or not started, a held priority's). Planner.hasWork hands nothing out (the summary's counts stay as they
    // are), and its CPU is metered.
    if (this.stop === "deadline" && this.planner && this.parked.length === 0 && !this.sync(() => this.planner!.hasWork())) this.stop = "done";
    const stop = this.stop ?? "done";
    deps.onRelease?.(stop);
    const db = this.db("release"); // counted before the summary, so the summary's estimate includes it
    const summary = this.redacted(this.summary());
    this.final = summary;
    try {
      await db.release(this.owner, this.head, this.headTimestamp, summary,
                            Object.fromEntries(this.states.map((s) => [s.label, s.memory(this.now())])), stop);
    } catch (err) {
      this.c.error(`release: ${(err as Error).message}`);
    }
    deps.log(`history-indexer: ${JSON.stringify(summary)}`);
    for (const e of this.c.errors) deps.log(`history-indexer: ${e}`);
  }

  summary(): RunSummary {
    const now = this.now();
    const c = this.c;
    const stats = this.planner?.stats();
    const kinds = this.planner?.kindCounts() as ItemCounts | undefined;
    const r429: Record<string, number> = {}, usedToday: Record<string, number> = {};
    for (const s of this.states) { r429[s.label] = Math.round(s.ratio429() * 10_000) / 10_000; usedToday[s.label] = s.usedToday(now); }
    // The look-ahead when the reads ended: items late for (or waiting on) a busy, resting or sidelined endpoint — left for
    // the next run, never settled.
    const leftParked: ItemCounts = { follow: 0, global: 0, window: 0, deep: 0, holes: 0 };
    for (const i of this.parked) leftParked[i.kind]++;
    return {
      v: 2, version: this.deps.version, head: this.head, ms: now - this.started, syncMs: Math.round(this.cpu.syncMs),
      cpuEstimateMs: Math.round(this.cpu.estimateMs()), cpuIsolateMs: Math.round(this.isolate.spentMs()),
      stop: this.stop ?? "done", align: this.align || this.o.plan.align,
      counts: {
        db: { ...this.cpu.db }, bytes: { streamed: this.cpu.streamedBytes, parsed: this.parsedBytes },
        requests: c.requests, throttled: c.throttled, refused: c.refused, sidelined: c.sidelined, r429, usedToday,
        failed: c.failed, invalid: c.invalid, dense: c.dense,
        timeouts: c.timeouts, pastHead: c.pastHead, straddleWaits: c.straddleWaits, dropped: c.dropped,
        items: kinds ?? { follow: 0, global: 0, window: 0, deep: 0, holes: 0 }, leftParked, held: c.held,
        commits: c.commits, commitSlow: c.commitSlow, commitRetries: c.commitRetries, logs: c.logs, inserted: c.inserted,
        trimmed: c.trimmed, holesMarked: c.holesMarked, holesCleared: c.holesCleared, capped: c.capped, firstTx: c.firstTx,
        wallets: { active: this.wallets.active, planned: stats?.planned ?? 0, skipped: this.wallets.skipped, new: stats?.new ?? 0,
                   refreshed: this.wallets.refreshed, windowComplete: stats?.windowComplete ?? 0, deepComplete: stats?.deepComplete ?? 0 },
      },
      straddle: c.straddle, defsDrift: this.drift, globalHoles: c.globalHoles.slice(0, 20), errors: c.errors.slice(0, 5),
    };
  }
}

export type { Priority };
