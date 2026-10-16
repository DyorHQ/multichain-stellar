// lite-indexer: called every minute by pg_cron (x-cron-secret). Runs the jobs of jobs/<name>.ts in the order below
// within a 45 s budget (the cron job's HTTP call gives up after 55 s), and records each run in lite.job_runs once
// migration 05 has created it. docs/DESIGN-stellar-parity.md §6.1.
//
// Contracts v2 (docs/DESIGN-stellar-contracts-v2.md §20.5, §20.6) runs inside the same jobs: main_events reads both
// generations, each from a cursor of its own, so a deployment of either never clears the other's rows (v2_events.ts
// indexGenerations); watch reads v1's watched contracts and then v2's (launch tokens' rewards, Moment NFTs and coins);
// graduate is v2's keeper (v2_keeper.ts), v1's graduations and, every 10 minutes, v2's fee sweeps; ttl's rotation
// includes v2's entries (_shared/ttl.ts).
import "../_shared/node_globals.ts";
import { sql, tableExists } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { json } from "../_shared/http.ts";
import { bridges } from "./jobs/bridges.ts";
import { earn } from "./jobs/earn.ts";
import { graduate } from "./jobs/graduate.ts";
import { ops } from "./jobs/ops.ts";
import { purge } from "./jobs/purge.ts";
import { reconcile } from "./jobs/reconcile.ts";
import { refprices } from "./jobs/refprices.ts";
import { settlePending } from "./jobs/settle.ts";
import { ttl } from "./jobs/ttl.ts";
import { watchContracts } from "./jobs/watch.ts";
import { indexGenerations, watchV2 } from "./v2_events.ts";
import { keeperV2, keeperV2Fees } from "./v2_keeper.ts";

const MINUTE = 60_000;

/** Runs `parts` in order, each whatever the others do, and answers each one's result or error by name. Throws only
 *  when every part failed, so the run is recorded as failed then. */
export async function inTurn(parts: Record<string, () => Promise<unknown>>): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {};
  const errors: unknown[] = [];
  for (const [name, run] of Object.entries(parts)) {
    try {
      out[name] = await run();
    } catch (err) {
      errors.push(err);
      out[name] = { error: String((err as Error).message ?? err).slice(0, 200) };
    }
  }
  if (errors.length === Object.keys(parts).length && errors.length > 0) throw errors[0];
  return out;
}

/** v1's watched launch tokens and pools (jobs/watch.ts), then v2's launch tokens, Moment NFTs and coins. */
const watchBoth = () => inTurn({ v1: watchContracts, v2: () => watchV2() });

/** v2's keeper first (the live generation, §20.6), then v1's graduations, then v2's fee sweeps when due. */
const keepBoth = () => inTurn({ v2: () => keeperV2(), v1: graduate, fees: () => keeperV2Fees() });

export interface Job {
  name: string;
  /** Null: not written yet, skipped. */
  run: (() => Promise<unknown>) | null;
  /** At most once per this many milliseconds; unset, every run. */
  every?: number;
  /** Starts only in the run's first LATE_MS. */
  late?: boolean;
  /** Signs with the keeper's or the sponsor's key: skipped while LITE_KEEPER=off, so a package's local stack never
   *  races the shared keys (§6.17). */
  keeper?: boolean;
}

export const JOBS: Job[] = [
  { name: "main_events", run: () => indexGenerations() },
  { name: "watch", run: watchBoth },
  { name: "refprices", run: refprices },
  { name: "settle", run: settlePending },
  { name: "graduate", run: keepBoth, keeper: true },
  { name: "bridges", run: bridges, keeper: true },
  { name: "ttl", run: ttl, late: true, keeper: true },
  { name: "reconcile", run: reconcile, every: 10 * MINUTE, late: true },
  { name: "earn", run: earn, every: 10 * MINUTE, late: true },
  { name: "ops", run: ops, every: 10 * MINUTE, late: true },
  { name: "purge", run: purge, every: 24 * 60 * MINUTE, late: true },
];

/** No job starts once BUDGET_MS have passed, and no late one once LATE_MS have. */
export const BUDGET_MS = 45_000;
export const LATE_MS = 40_000;

/** Runs every job that is due, in order, but the keeper's while LITE_KEEPER=off. Answers each job's result (or its
 *  error, or why it was skipped) by name. */
export async function runJobs(jobs: Job[] = JOBS, now: () => number = Date.now): Promise<Record<string, unknown>> {
  const started = now();
  const out: Record<string, unknown> = {};
  const recording = await tableExists("lite.job_runs").catch(() => false);
  const keeper = env.keeperEnabled;
  for (const job of jobs) {
    if (!job.run) continue;
    if (job.keeper && !keeper) {
      out[job.name] = { skipped: "LITE_KEEPER=off" };
      continue;
    }
    const elapsed = now() - started;
    if (elapsed >= BUDGET_MS || (job.late && elapsed >= LATE_MS)) {
      out[job.name] = { skipped: `out of time after ${Math.round(elapsed / 1000)} s` };
      continue;
    }
    if (job.every && !(await due(job, job.every, recording, now()))) continue;
    const at = now();
    let ok = true;
    let result: unknown;
    try {
      result = await job.run();
    } catch (err) {
      ok = false;
      result = { error: String((err as Error).message ?? err).slice(0, 200) };
    }
    out[job.name] = result;
    if (recording) await recordRun(job.name, at, now() - at, ok, result);
  }
  out.ms = now() - started;
  return out;
}

/** A periodic job is due when its last recorded run is a period ago. Before lite.job_runs exists nothing records
 *  runs, so it runs in the first minute of each period instead. */
async function due(job: Job, every: number, recording: boolean, now: number): Promise<boolean> {
  if (recording) {
    try {
      const rows = await sql()`select max(started_at) as last from lite.job_runs where job = ${job.name}`;
      const last = rows[0]?.last as Date | null;
      // Half a minute's slack: the cron fires every minute, never exactly on the period.
      return !last || now - new Date(last).getTime() >= every - 30_000;
    } catch {
      // the clock decides, as before migration 05
    }
  }
  return now % every < MINUTE;
}

/** One row per run, into lite.job_runs (job text, started_at timestamptz, ms integer, ok boolean, result jsonb). A
 *  run that can't be recorded is logged; the next job still runs. */
async function recordRun(job: string, startedAt: number, ms: number, ok: boolean, result: unknown): Promise<void> {
  const value = JSON.parse(JSON.stringify(result ?? null, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
  try {
    await sql()`insert into lite.job_runs (job, started_at, ms, ok, result) values (${job}, ${new Date(startedAt)}, ${ms}, ${ok}, ${sql().json(value)})`;
  } catch (err) {
    console.warn("job_runs: run not recorded", job, String((err as Error).message ?? err).slice(0, 120));
  }
}

if (import.meta.main) {
  // Refuses to start without the lite_api role's connection, rather than reaching the database another way.
  env.dbUrl;
  Deno.serve(async (req) => {
    const secret = env.cronSecret;
    if (!secret || req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);
    return json(await runJobs());
  });
}
