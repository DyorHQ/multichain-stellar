// Shared by the wallet-history cache's tests: a throwaway PGlite database with every migration applied (as
// migrations_test.ts does), PostgREST's per-role limits, and `pgliteDb` — the indexer's HistoryDb over that database as
// the service role, with optional injected latency and errors, a hook after every commit, and enter/leave calls so a
// test's virtual clock never moves while the database is working. Not a test file itself.
import { PGlite, type Transaction } from "npm:@electric-sql/pglite@0.5.8";
import { pgcrypto } from "npm:@electric-sql/pglite@0.5.8/contrib/pgcrypto";
import { citext } from "npm:@electric-sql/pglite@0.5.8/contrib/citext";
import {
  classifyDbError, type CommitAnswer, commitAnswer, type CommitArgs, type HistoryDb, parseState,
} from "../functions/history-indexer/db.ts";
import type { EndpointMemory } from "../functions/history-indexer/pacing.ts";

const MIGRATIONS = new URL("../migrations/", import.meta.url);
const STUB = new URL("./supabase_stub.sql", import.meta.url);
const PLATFORM_ONLY = ["33_"];

export type Role = "anon" | "authenticated" | "service_role";

// A fresh database: the platform stub, then every migration in order (platform-only ones skipped).
export async function historyDatabase(): Promise<PGlite> {
  const db = await PGlite.create({ extensions: { pgcrypto, citext } });
  await db.exec(await Deno.readTextFile(STUB));
  const names: string[] = [];
  for await (const e of Deno.readDir(MIGRATIONS)) if (e.isFile && e.name.endsWith(".sql")) names.push(e.name);
  for (const name of names.sort()) {
    if (PLATFORM_ONLY.some((p) => name.startsWith(p))) continue;
    try { await db.exec(await Deno.readTextFile(new URL(name, MIGRATIONS))); }
    catch (err) { throw new Error(`${name}: ${(err as Error).message}`); }
  }
  return db;
}

// Runs `sql` as `role` in its own transaction, as PostgREST would: the JWT claims, the role, and its limits (anon 3 s;
// authenticated 8 s; service_role inherits authenticator's 8 s statement and 8 s lock timeouts).
export async function as<T = Record<string, unknown>>(db: PGlite, role: Role, wallet: string | null, sql: string,
                                                     params: unknown[] = []): Promise<T[]> {
  return await db.transaction(async (tx: Transaction) => {
    const claims = wallet ? { role, wallet_address: wallet } : { role };
    await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)]);
    await tx.exec(`set local role ${role}`);
    await tx.exec(role === "anon" ? "set local statement_timeout = '3s'" : "set local statement_timeout = '8s'");
    await tx.exec("set local lock_timeout = '8s'");
    return (await tx.query<T>(sql, params)).rows;
  });
}

export async function one<T = Record<string, unknown>>(db: PGlite, sql: string, params: unknown[] = []): Promise<T> {
  return (await db.query<T>(sql, params)).rows[0];
}

// The SQLSTATE and message of a failed call, for assertions ("no error" when it succeeded).
export async function code(p: Promise<unknown>): Promise<string> {
  try { await p; } catch (e) { return `${(e as { code?: string }).code ?? ""} ${(e as Error).message}`; }
  return "no error";
}

export type PgliteDbOptions = {
  latency?: (fn: string) => number;                  // virtual milliseconds before each call
  sleep?: (ms: number) => Promise<void>;
  inject?: (fn: string) => { code: string; message: string } | null;
  busy?: { enter(): void; leave(): void };
  onCommit?: (args: CommitArgs, answer: CommitAnswer) => Promise<void> | void;
};

export type CountingDb = HistoryDb & { calls: Record<string, number> };

export function pgliteDb(db: PGlite, o: PgliteDbOptions = {}): CountingDb {
  const calls: Record<string, number> = {};
  const rpc = async (fn: string, sql: string, params: unknown[]): Promise<unknown> => {
    calls[fn] = (calls[fn] ?? 0) + 1;
    const ms = o.latency?.(fn) ?? 0;
    if (ms > 0 && o.sleep) await o.sleep(ms);
    const injected = o.inject?.(fn);
    if (injected) throw classifyDbError(injected.code, `${fn}: ${injected.message}`);
    o.busy?.enter();
    try {
      return (await as<{ r: unknown }>(db, "service_role", null, sql, params))[0]?.r;
    } catch (err) {
      const e = err as { code?: string; message?: string };
      throw classifyDbError(e.code, `${fn}: ${e.message ?? ""}`);
    } finally {
      o.busy?.leave();
    }
  };
  return {
    calls,
    async lease(owner, seconds, version) {
      const d = (await rpc("history_lease", "select public.history_lease($1, $2, $3) as r", [owner, seconds, version])) as Record<string, unknown>;
      return { ok: d.ok === true, paused: d.paused === true, started: d.started === true,
               endpoints: (d.endpoints ?? {}) as Record<string, EndpointMemory> };
    },
    async state(owner, maxWallets, requestedAfter) {
      return parseState(await rpc("history_state", "select public.history_state($1, $2, $3) as r", [owner, maxWallets, requestedAfter ?? null]));
    },
    async commit(c) {
      const d = await rpc("history_commit", "select public.history_commit($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb) as r",
                          [c.owner, c.scan, c.defVersion, c.from, c.to, c.head, c.headTimestamp, c.wallets, JSON.stringify(c.logs)]);
      const answer = commitAnswer(d as Record<string, unknown>);
      if (o.onCommit) {
        o.busy?.enter();
        try { await o.onCommit(c, answer); } finally { o.busy?.leave(); }
      }
      return answer;
    },
    async markHole(owner, scan, defVersion, wallet, from, to) {
      await rpc("history_mark_hole", "select public.history_mark_hole($1, $2, $3, $4, $5, $6) as r", [owner, scan, defVersion, wallet, from, to]);
    },
    async setFirstTx(owner, wallet, state, block, head, source) {
      return (await rpc("history_set_first_tx", "select public.history_set_first_tx($1, $2, $3, $4, $5, $6) as r",
                        [owner, wallet, state, block, head, source])) === true;
    },
    async release(owner, head, headTimestamp, summary, endpoints, stop) {
      await rpc("history_release", "select public.history_release($1, $2, $3, $4::jsonb, $5::jsonb, $6) as r",
                [owner, head, headTimestamp, JSON.stringify(summary), endpoints === null ? null : JSON.stringify(endpoints), stop]);
    },
  };
}

// A virtual clock for the run loop: `sleep` and `setTimer` register timers; a driver advances time to the earliest one
// whenever nothing real is in progress (`enter`/`leave` around database work), so a 240-second run takes seconds.
export class VirtualClock {
  t: number;
  private timers: { at: number; seq: number; fn: () => void; live: boolean }[] = [];
  private seq = 0;
  private busy = 0;
  private running = true;
  private handle: ReturnType<typeof setTimeout> | undefined;

  constructor(start: number) {
    this.t = start;
    this.schedule();
  }

  now = () => this.t;
  setTimer = (ms: number, fn: () => void): (() => void) => {
    const timer = { at: this.t + Math.max(0, ms), seq: this.seq++, fn, live: true };
    this.timers.push(timer);
    this.timers.sort((a, b) => a.at - b.at || a.seq - b.seq);
    return () => { timer.live = false; };
  };
  sleep = (ms: number) => new Promise<void>((resolve) => { this.setTimer(ms, resolve); });
  enter = () => { this.busy++; };
  leave = () => { this.busy = Math.max(0, this.busy - 1); };

  private schedule() {
    this.handle = setTimeout(() => this.tick(), 0);
  }

  private tick() {
    if (!this.running) return;
    if (this.busy === 0) {
      while (this.timers.length > 0 && !this.timers[0].live) this.timers.shift();
      const next = this.timers.shift();
      if (next) {
        this.t = Math.max(this.t, next.at);
        try { next.fn(); } catch (err) { console.error("virtual clock: a timer threw", err); }
      }
    }
    this.schedule();
  }

  stop() {
    this.running = false;
    if (this.handle !== undefined) clearTimeout(this.handle);
  }
}
