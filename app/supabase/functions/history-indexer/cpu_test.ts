// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1";
import { CpuMeter, type CpuPrices, finishReserveMs, IsolateCpu, LOG_BYTES, lookupReads } from "./cpu.ts";
import { locateFirstTx, type NonceSource, reverifyFirstTx } from "./firsttx.ts";
import { type CompactLog, splitForCommit } from "./logs.ts";
import { DEFAULT_RUN_OPTIONS, isolateHasRoom } from "./run.ts";

const PRICES: CpuPrices = { rpcCpuMs: DEFAULT_RUN_OPTIONS.rpcCpuMs, dbCpuMs: DEFAULT_RUN_OPTIONS.dbCpuMs, bytesPerMs: DEFAULT_RUN_OPTIONS.bytesPerMs };

// The two deployed runs the platform stopped for CPU on 2026-10-09 (run.ts D21): their summaries and cpu_time_used.
// `otherDb`: the database calls besides the commits, not in those summaries (lease, state, setFirstTx, release): ~15.
const MEASURED = [
  { syncMs: 71, rpc: 828, commits: 1_203, cpu: 1_815 },
  { syncMs: 98, rpc: 880, commits: 917, cpu: 1_809 },
];

// r (ms per RPC request) and d (ms per database call) solving syncMs + r × rpc + d × db = cpu for both runs.
function fit(otherDb: number): { r: number; d: number } {
  const [a, b] = MEASURED.map((m) => ({ x: m.rpc, y: m.commits + otherDb, c: m.cpu - m.syncMs }));
  const det = a.x * b.y - b.x * a.y;
  return { r: (a.c * b.y - b.c * a.y) / det, d: (a.x * b.c - b.x * a.c) / det };
}

Deno.test("cpu: a run's estimate — syncMs, each RPC request and database call at its price, every streamed byte", () => {
  const m = new CpuMeter({ rpcCpuMs: 1.6, dbCpuMs: 0.5, bytesPerMs: 150_000 });
  assertEquals(m.estimateMs(), 0);
  m.syncMs = 71;
  m.requests = 828;
  m.db.lease = 4; m.db.state = 6; m.db.commit = 1_203; m.db.markHole = 2; m.db.setFirstTx = 9; m.db.release = 1;
  m.streamedBytes = 3_000_000;
  assertEquals(m.dbCalls(), 4 + 6 + 1_203 + 2 + 9 + 1);
  assertAlmostEquals(m.estimateMs(), 71 + 828 * 1.6 + 1_225 * 0.5 + 20);
});

Deno.test("cpu: the isolate's estimate — its start, its requests, and every run in it, live", () => {
  const isolate = new IsolateCpu(60);
  isolate.charge(3);
  isolate.charge(-5); // never negative
  const first = isolate.meter(PRICES);
  first.requests = 100;
  assertAlmostEquals(isolate.spentMs(), 63 + 160);
  // A second run in the same isolate starts from everything the first spent, and the first's later exchanges (its
  // release, still in flight when the second starts) count at once.
  const second = isolate.meter(PRICES);
  assertEquals(second.estimateMs(), 0);
  first.db.release = 1;
  second.db.lease = 1;
  assertAlmostEquals(isolate.spentMs(), 63 + 160 + 0.5 + 0.5);
  // index.ts and the run take no lease once less than minRunCpuMs is left.
  const o = { cpuBudgetMs: 1_000, minRunCpuMs: 300 };
  assert(isolateHasRoom(new IsolateCpu(700), o));
  assert(!isolateHasRoom(new IsolateCpu(700.5), o));
  assert(isolateHasRoom(new IsolateCpu(DEFAULT_RUN_OPTIONS.cpuBudgetMs - DEFAULT_RUN_OPTIONS.minRunCpuMs)));
});

Deno.test("cpu: the prices are at or above the fit of the two runs the platform stopped — for any mix of the two kinds", () => {
  for (const otherDb of [0, 15, 40]) {
    const { r, d } = fit(otherDb);
    // The fit: RPC requests cost several times what database calls do (so one flat price was not an upper bound).
    assert(r > 1.45 && r < 1.6 && d > 0.35 && d < 0.45, `otherDb ${otherDb}: r ${r}, d ${d}`);
    assert(PRICES.rpcCpuMs >= r && PRICES.dbCpuMs >= d, `otherDb ${otherDb}: prices below the fit r ${r}, d ${d}`);
  }
  const { r, d } = fit(15);
  const estimate = (syncMs: number, rpc: number, db: number) => {
    const m = new CpuMeter(PRICES);
    m.syncMs = syncMs;
    m.requests = rpc;
    m.db.commit = db;
    return m.estimateMs();
  };
  // Both measured runs: the estimate is at or above what the platform charged.
  for (const m of MEASURED) assert(estimate(m.syncMs, m.rpc, m.commits + 15) >= m.cpu, `${estimate(m.syncMs, m.rpc, m.commits + 15)} vs ${m.cpu}`);
  // Any mix — commit-heavy as measured, RPC-heavy as coalescing leaves it, either alone — is priced at or above the fit.
  for (const [rpc, db] of [[828, 1_218], [850, 135], [1_000, 0], [0, 1_000], [300, 2_000]]) {
    assert(estimate(60, rpc, db) >= 60 + r * rpc + d * db, `rpc ${rpc}, db ${db}`);
  }
  // The flat 1 ms an exchange it replaces priced the RPC-heavy mix ~25 % below the fit: ~1,045 ms for ~1,410.
  assert(60 + 1.0 * (850 + 135) < 0.8 * (60 + r * 850 + d * 135));
});

// An eth_getLogs log as an endpoint sends it, with `topics` topics and `data` bytes of data (hex).
function rpcLogJson(topics: number, dataBytes: number, block: number, index: number): string {
  const word = (n: number) => "0x" + n.toString(16).padStart(64, "0");
  return JSON.stringify({
    address: "0x" + "ab".repeat(20), topics: Array.from({ length: topics }, (_, k) => word(k)), data: "0x" + "cd".repeat(dataBytes),
    blockNumber: "0x" + block.toString(16), transactionHash: word(block * 1_000 + index), transactionIndex: "0x0",
    blockHash: word(block), logIndex: "0x" + index.toString(16), removed: false,
  });
}
const compact = (b: number, i: number): CompactLog => ({ a: "0x", t: [], d: "0x", n: 0, b, h: "0x", i, s: 0 });

Deno.test("cpu: the finish reserve counts the commits the bytes in flight can become, not one per piece", () => {
  // A log the scans match has ≥ 2 topics: never smaller than LOG_BYTES.
  assert(rpcLogJson(2, 0, 3_000_000, 0).length >= LOG_BYTES, String(rpcLogJson(2, 0, 3_000_000, 0).length));
  // Dense pieces in flight: 6 answers of the smallest logs a scan matches, filling 12 MiB, at the smallest commit size.
  const perLog = rpcLogJson(2, 0, 3_000_000, 0).length + 1;
  const bytes = 12 * 1_048_576;
  const logsPerPiece = Math.floor(bytes / 6 / perLog);
  for (const commitLogs of [2_000, 500]) {
    let commits = 0;
    for (let k = 0; k < 6; k++) {
      const logs = Array.from({ length: logsPerPiece }, (_, i) => compact(1_000 * k + Math.floor(i / 3), i)); // 3 logs a block
      commits += splitForCommit(logs, 1_000 * k, 1_000 * k + 999, commitLogs).length;
    }
    const reserve = finishReserveMs({ commits: 0, pieces: 6, bytes, requests: 0, lookupReads: 0, lookups: 0, commitLogs }, PRICES);
    const reservedCommits = (reserve - (3 * bytes) / PRICES.bytesPerMs) / PRICES.dbCpuMs - 4;
    assert(reservedCommits >= commits, `commitLogs ${commitLogs}: ${reservedCommits} reserved for ${commits} commits`);
    // The pieces alone (the reserve before) counted 6.
    assert(commits > 6 * 2, `commitLogs ${commitLogs}: ${commits}`);
  }
  // Each part, priced as the module says.
  const p = { rpcCpuMs: 1, dbCpuMs: 1, bytesPerMs: 1_000 };
  assertEquals(finishReserveMs({ commits: 0, pieces: 0, bytes: 0, requests: 0, lookupReads: 0, lookups: 0, commitLogs: 2_000 }, p), 4,
               "the end: a renewal and a state refresh after the check, the final renewal, the release");
  assertEquals(finishReserveMs({ commits: 5, pieces: 0, bytes: 0, requests: 0, lookupReads: 0, lookups: 0, commitLogs: 2_000 }, p), 4 + 10,
               "a commit priced twice: a re-split or a retry");
  assertEquals(finishReserveMs({ commits: 0, pieces: 2, bytes: 1_600_000, requests: 0, lookupReads: 0, lookups: 0, commitLogs: 2_000 }, p),
               4 + 2 * (2 + 2) + 3 * 1_600, "pieces in flight, one commit per 800 kB more, three passes over their bytes");
  assertEquals(finishReserveMs({ commits: 0, pieces: 0, bytes: 0, requests: 1, lookupReads: 30, lookups: 2, commitLogs: 2_000 }, p),
               4 + 1 + 30 + 2, "a read being decided, the lookups' reads left and their setFirstTx");
});

Deno.test("cpu: a lookup's reserved reads cover every read locateFirstTx and reverifyFirstTx make", async () => {
  const sleep = async () => {};
  for (const head of [0, 1, 1_000, 3_000_000, 71_000_000, 2 ** 31]) {
    const firsts = [null, 0, 1, Math.floor(head / 3), head - 1, head].filter((f) => f === null || (f >= 0 && f <= head));
    for (const first of firsts) {
      let reads = 0;
      const source = (label: string): NonceSource => ({
        label, nonceAt: (b: number) => { reads++; return Promise.resolve(first !== null && b >= first ? 1n : 0n); },
      });
      const sources = [source("a"), source("b")];
      const found = await locateFirstTx(sources, head, { sleep });
      assert(reads <= lookupReads(head), `head ${head}, first ${first}: ${reads} reads > ${lookupReads(head)}`);
      // The first source's node behind the head refuses the read at the head: one fail-over.
      reads = 0;
      let refused = false;
      const behind: NonceSource = {
        label: "behind",
        nonceAt: (b: number) => {
          reads++;
          if (b === head && !refused) { refused = true; return Promise.reject(new Error("Block requested not found.")); }
          return Promise.resolve(first !== null && b >= first ? 1n : 0n);
        },
      };
      await locateFirstTx([behind, source("b")], head, { sleep });
      assert(reads <= lookupReads(head), `fail-over: head ${head}, first ${first}: ${reads} reads`);
      if (found.state !== "found") continue;
      // Re-verifying a stored block later than the real one: one read, then the bisection below it.
      reads = 0;
      await reverifyFirstTx(sources, { block: head, source: "a+b" }, { sleep });
      assert(reads <= lookupReads(head), `reverify head ${head}, first ${first}: ${reads} reads`);
    }
  }
  assertEquals(lookupReads(71_000_000), 33, "~30 sequential reads on Monad mainnet today, and two fail-overs");
});
