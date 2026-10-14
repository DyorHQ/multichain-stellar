// history-indexer: fills the wallet-history cache (migration 32) that history_read serves to the app, so a history
// screen reads one PostgREST call instead of minutes of capped public eth_getLogs.
//
// Called every 30 s by pg_cron → pg_net (migrations-deferred/33_history_indexer_schedule.sql) with the x-history-cron
// header, which must equal the Vault secret history_cron_secret: migration 33 generates it inside Postgres and the
// function compares the header with the secret's SHA-256 (history_cron_digest, auth.ts), so no person or Edge secret
// holds it, and no header ever reaches the database. verify_jwt = false (supabase/config.toml): the tick carries no
// Supabase session. The function answers 202 at once and works in
// EdgeRuntime.waitUntil for at most 240 s under a database lease (history_lease), so runs never overlap: follow the
// head, backfill newest first, commit each fully answered range with its logs (history_commit), release
// (history_release). run.ts is the loop; every other file is a pure module with a test beside it.
//
// Secrets (names only), all optional: ALCHEMY_MONAD_RPC (the owner's keyed Alchemy URL: adds the endpoint "alchemy",
// endpoints.ts); MONAD_LOGS_ENDPOINTS (JSON: tune, add or replace endpoints without a code change); HISTORY_CRON_SECRET
// (a second accepted header value, ≥ 32 characters). SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by the
// platform. No keyed URL is ever logged: every line goes through redact.ts, and no Error object is passed to console.*
// (Deno prints a failed fetch's cause, which quotes the URL). Errors to the caller carry no detail (SB-11); the log gets
// one summary line per run (counts only, never a wallet address or a URL) and at most five short error lines.
//
// This is the only file touching Deno.env, Deno.serve, EdgeRuntime and addEventListener.
import { createClient } from "npm:@supabase/supabase-js@2";
import { CronGate, type DigestFetch, plausibleToken, vaultDigest } from "./auth.ts";
import { type HistoryDb, postgrestDb, type RunSummary } from "./db.ts";
import { alchemyEndpoint, type Endpoint, endpointsFromEnv, isKeyed } from "./endpoints.ts";
import { IsolateCpu, ISOLATE_START_CPU_MS, REQUEST_CPU_MS } from "./cpu.ts";
import { type Redact, redactor } from "./redact.ts";
import { DEFAULT_RUN_OPTIONS, isolateHasRoom, runIndexer } from "./run.ts";
import { VERSION } from "./version.ts";

const ISOLATE_STARTED = Date.now();
declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined;

// The platform's CPU limit is the isolate's, not a run's (cpu.ts): one estimate per isolate — its start, every request
// it answers, every Vault digest fetch, and each run in it — which every run here reads and adds to.
const isolateCpu = new IsolateCpu(ISOLATE_START_CPU_MS);

// The run this isolate is doing, so the shutdown handler can release it (best effort) and a second tick reaching the
// same isolate does not start another.
let current: { owner: string; released: boolean; db: HistoryDb } | null = null;
const signal: { shutdown?: string } = {};
const gate = new CronGate();
let client: { db: HistoryDb; fetchDigest: DigestFetch } | null = null; // one service-role client per isolate
let unavailableLoggedAt = -Infinity; // one "could not ask" line a minute, whatever the traffic

// The endpoints and the redactor, from the secrets (read once per isolate; one line about the configuration).
let config: { endpoints: Endpoint[]; redact: Redact } | null = null;
function configure(): { endpoints: Endpoint[]; redact: Redact } {
  if (config) return config;
  const alchemyRaw = Deno.env.get("ALCHEMY_MONAD_RPC");
  const alchemy = alchemyEndpoint(alchemyRaw);
  const { endpoints, error } = endpointsFromEnv(Deno.env.get("MONAD_LOGS_ENDPOINTS"), alchemy.endpoint ? [alchemy.endpoint] : []);
  // Every keyed URL in use, and the raw ALCHEMY_MONAD_RPC value even when it is not used (an http URL can hold a key).
  const redact = redactor([
    ...endpoints.filter(isKeyed).map((e) => ({ url: e.url, label: e.label })),
    ...(alchemyRaw && alchemyRaw.trim() !== "" ? [{ url: alchemyRaw, label: "alchemy" }] : []),
  ]);
  console.log(redact(`history-indexer: ${alchemy.note}; endpoints ${endpoints.map((e) => e.label).join(", ")}`));
  if (error) console.error(redact(`history-indexer: ${error} — using the defaults`)); // names the field, never a value
  config = { endpoints, redact };
  return config;
}

addEventListener("beforeunload", (ev) => {  // CPUTime, Memory, WallClockTime, EarlyDrop, TerminationRequested, …
  const reason = String((ev as CustomEvent).detail?.reason ?? "unknown").replace(/[^A-Za-z0-9_-]/g, "").slice(0, 30) || "unknown";
  console.log(`history-indexer: shutdown ${reason}`);
  signal.shutdown = reason;
  if (current && !current.released) {
    current.released = true;
    const stop = `shutdown:${reason}`;
    current.db.release(current.owner, null, null, { v: 2, stop } as RunSummary, null, stop).catch(() => {});
  }
});

const reply = (status: number, body?: unknown) =>
  new Response(body === undefined ? null : JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
const setTimer = (ms: number, fn: () => void) => { const t = setTimeout(fn, ms); return () => clearTimeout(t); };

Deno.serve(async (req) => {
  isolateCpu.charge(REQUEST_CPU_MS);
  if (req.method !== "POST") return reply(405);
  const presented = req.headers.get("x-history-cron");
  if (!plausibleToken(presented)) return reply(403); // the cheap check, before anything else
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key || typeof EdgeRuntime === "undefined") return reply(503);
  if (!client) {
    const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
    const fetchDigest = vaultDigest(supabase);
    client = {
      db: postgrestDb(supabase),
      fetchDigest: () => { isolateCpu.charge(DEFAULT_RUN_OPTIONS.dbCpuMs); return fetchDigest(); }, // a database call
    };
  }
  const now = Date.now();
  const verdict = await gate.authorize(presented, Deno.env.get("HISTORY_CRON_SECRET"), client.fetchDigest, now);
  if (verdict === "unavailable") {
    if (now - unavailableLoggedAt >= 60_000) {
      unavailableLoggedAt = now;
      console.error("history-indexer: history_cron_digest could not be asked (migration 32 applied? the database up?)");
    }
    return reply(503);
  }
  if (verdict !== "ok") return reply(403);
  await req.body?.cancel();
  if (current && !current.released) return reply(202, { accepted: false });
  // This isolate has spent its CPU on earlier runs and ticks: no run here (the run would check again before its lease).
  if (!isolateHasRoom(isolateCpu)) return reply(202, { accepted: false });
  const { endpoints, redact } = configure();
  const db = client.db;
  signal.shutdown = undefined;
  EdgeRuntime.waitUntil(
    runIndexer({
      db, endpoints, fetch, now: Date.now, cpuNow: () => performance.now(), sleep, setTimer, random: Math.random, redact,
      log: (line) => console.log(redact(line)), isolateStartedAt: ISOLATE_STARTED, version: VERSION, isolateCpu,
      onLease: (owner) => { current = { owner, released: false, db }; },
      onRelease: () => { if (current) current.released = true; },
    }, signal).catch((err) => console.error(redact(`history-indexer: run failed: ${String((err as Error)?.message ?? err)}`).slice(0, 240))),
  );
  return reply(202, { accepted: true });
});
