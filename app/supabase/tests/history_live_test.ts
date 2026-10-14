// Opt-in: the history indexer against Monad's PUBLIC endpoints (never a keyed URL; ≤ 4 requests/s per endpoint), on a
// throwaway PGlite database. Skipped unless HISTORY_LIVE is set:
//
//   HISTORY_LIVE=1     probes, then the last 500,000 blocks of every scan for one wallet (floors raised in the test
//                      database), checked against an independent reader — about a minute
//   HISTORY_LIVE=full  probes, the real global floors and the 30-day window, with 99 random addresses enrolled too so
//                      the 100-wallet path runs — 5–8 minutes
//   HISTORY_LIVE=deep  as full, and the wallet's transfers back to genesis — 20–30 minutes
//
//   HISTORY_LIVE=1 deno test -A --no-config --node-modules-dir=none supabase/tests/history_live_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1";
import { classifyCallError, DEFAULT_ENDPOINTS } from "../functions/history-indexer/endpoints.ts";
import { type Range } from "../functions/history-indexer/ranges.ts";
import { runIndexer } from "../functions/history-indexer/run.ts";
import { as, historyDatabase, one, pgliteDb } from "./history_pglite_db.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

const LEVEL = Deno.env.get("HISTORY_LIVE");
const WALLET = "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47"; // its first transaction is at block 103,551,773
const NOTHING = "0x" + "f".repeat(64);
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
const hex = (n: number) => "0x" + n.toString(16);

async function rpc(url: string, method: string, params: unknown[]): Promise<{ status: number; result?: Any; error?: { code?: number; message?: string } }> {
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" },
                                 body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), signal: AbortSignal.timeout(20_000) });
  const text = await res.text();
  try {
    const j = JSON.parse(text);
    return { status: res.status, result: j.result, error: j.error };
  } catch {
    return { status: res.status, error: { message: text.slice(0, 120) } };
  }
}

Deno.test({ name: "history-indexer live: probes and end to end on public Monad RPC", ignore: !LEVEL, sanitizeOps: false, sanitizeResources: false }, async (t) => {
  const rpc2 = DEFAULT_ENDPOINTS.find((e) => e.label === "rpc2")!.url;
  const finalized = async () => parseInt((await rpc(rpc2, "eth_getBlockByNumber", ["finalized", false])).result.number, 16);

  await t.step("probes: a refusing endpoint refuses a range crossing its head; no node far behind the finalized head", async () => {
    for (const e of DEFAULT_ENDPOINTS) {
      const seen: string[] = [];
      for (let round = 0; round < 3; round++) {
        const bn = parseInt((await rpc(e.url, "eth_blockNumber", [])).result, 16);
        await sleep(400);
        const straddle = await rpc(e.url, "eth_getLogs", [{ fromBlock: hex(bn - 10), toBlock: hex(bn + 50), topics: [NOTHING] }]);
        await sleep(400);
        const verdict = straddle.error ? classifyCallError(straddle.error, { from: bn - 10, to: bn + 50 }, bn).kind : "answered";
        seen.push(verdict);
        if (e.straddle === "refuses") assertEquals(verdict, "pastHead", `${e.label} is declared refuses, answered a straddling range`);
      }
      console.log(`  straddle ${e.label} (${e.straddle}): ${seen.join(", ")}`);
    }
    const head = await finalized();
    for (const e of DEFAULT_ENDPOINTS) {
      const heights: number[] = [];
      for (let k = 0; k < 20; k++) {
        const r = await rpc(e.url, "eth_blockNumber", []);
        if (r.result) heights.push(parseInt(r.result, 16));
        await sleep(500);
      }
      const behind = head - Math.min(...heights);
      console.log(`  node lag ${e.label}: spread ${Math.max(...heights) - Math.min(...heights)}, behind finalized ${behind}`);
      assert(behind <= 1_200, `${e.label}: a node ${behind} blocks behind the finalized head (the residual risk of D4)`);
    }
  });

  await t.step(`end to end (HISTORY_LIVE=${LEVEL})`, async () => {
    const db = await historyDatabase();
    await as(db, "authenticated", WALLET, "insert into public.profiles (wallet) values ($1) on conflict (wallet) do update set wallet = excluded.wallet", [WALLET]);
    const head = await finalized();
    const window = 8_574_264;
    if (LEVEL === "full" || LEVEL === "deep") {
      const random = Array.from({ length: 99 }, () => "0x" + [...crypto.getRandomValues(new Uint8Array(20))].map((b) => b.toString(16).padStart(2, "0")).join(""));
      await db.query("insert into public.profiles (wallet) select unnest($1::text[])", [random]);
    }
    // Floors raised in this test database only: the last 500,000 blocks (level 1); the 30-day window (full).
    const raise = async (scan: string, floor: number) => db.query("select public.history_redefine_scan($1, null, null, $2, $2)", [scan, floor]);
    if (LEVEL === "1") for (const s of ["launchpad", "fee-sharing", "moments", "transfers-in", "transfers-out"]) {
      const current = Number((await one<Any>(db, "select floor_block::bigint::text f from public.history_scans where id = $1", [s])).f);
      await raise(s, Math.max(current, head - 500_000));
    }
    if (LEVEL === "full") for (const s of ["transfers-in", "transfers-out"]) await raise(s, head - window + 1);
    const started = Date.now();
    for (let run = 0; Date.now() - started < 40 * 60_000; run++) {
      const summary = await runIndexer({
        db: pgliteDb(db), endpoints: DEFAULT_ENDPOINTS.map((e) => ({ ...e })), fetch, now: Date.now, cpuNow: () => performance.now(), sleep,
        setTimer: (ms, fn) => { const h = setTimeout(fn, ms); return () => clearTimeout(h); },
        random: Math.random, log: () => {}, isolateStartedAt: Date.now(), version: "live",
        options: { syncBudgetMs: 60_000, cpuBudgetMs: 1e9, maxParsedBytes: 256 * 1_048_576, maxLogs: 1_000_000 }, // no platform CPU meter here
      }, {});
      const c = summary.counts as Any;
      console.log(`  run ${run}: ${summary.stop}, ${summary.ms} ms, cpuEstimateMs ${summary.cpuEstimateMs}, requests ${JSON.stringify(c.requests)}, ` +
                  `db ${JSON.stringify(c.db)}, logs ${c.logs}, commits ${c.commits}, ` +
                  `firstTx ${JSON.stringify(c.firstTx)}, errors ${JSON.stringify(summary.errors)}`);
      assert(!["db", "error", "lease", "defs"].includes(String(summary.stop)), String(summary.stop));
      const items = Object.values(c.items as Record<string, number>).reduce((a, b) => a + b, 0);
      if (summary.stop === "done" && items <= 6 && c.firstTx.found + c.firstTx.none + c.firstTx.unconfirmed + c.firstTx.failed === 0) break;
    }
    const first = await one<Any>(db, "select first_tx_state s, first_tx_block::bigint::text b, first_tx_source src from public.history_wallets where wallet = $1", [WALLET]);
    assertEquals([first.s, Number(first.b)], ["found", 103_551_773]);
    assert(/^[a-z0-9-]+\+[a-z0-9-]+$/.test(first.src), "confirmed on a second read");

    // The served history against an independent reader: rpc2, sequential 6 × 10,000-block batches, ≤ 3 requests/s,
    // with the app's exact filters (each scan's `query`), over each scan's served coverage.
    const pages: Any[] = [];
    let cursor: string | null = null;
    do {
      const page: Any = (await as<Any>(db, "anon", null, "select public.history_read($1, $2) r", [WALLET, cursor]))[0].r;
      pages.push(page);
      cursor = page.next;
    } while (cursor);
    const norm = (l: Any) => [l.address, ...l.topics, l.data, parseInt(l.blockNumber, 16), parseInt(l.logIndex, 16), l.transactionHash].join("|").toLowerCase();
    for (const [scan, doc] of Object.entries(pages[0].scans as Record<string, Any>)) {
      assert(doc.complete, `${scan} complete`);
      const served = pages.flatMap((p) => p.scans[scan].logs).map(norm).sort();
      const omitted = new Set((doc.omitted as Any[]).map((o) => `${parseInt(o.blockNumber, 16)}:${parseInt(o.logIndex, 16)}`));
      const reference: string[] = [];
      for (const [from, to] of doc.covered as Range[]) {
        for (let lo = from; lo <= to; lo += 60_000) {
          const calls = [];
          for (let k = lo; k <= Math.min(to, lo + 59_999); k += 10_000) {
            const filter: Any = { fromBlock: hex(k), toBlock: hex(Math.min(to, k + 9_999)), topics: doc.query.topics };
            if (doc.query.addresses.length > 0) filter.address = doc.query.addresses;
            calls.push({ jsonrpc: "2.0", id: calls.length + 1, method: "eth_getLogs", params: [filter] });
          }
          const res = await fetch(rpc2, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(calls) });
          const answers = (await res.json()) as Any[];
          for (const a of answers) {
            assert(Array.isArray(a.result), `reference read: ${JSON.stringify(a.error ?? a).slice(0, 120)}`);
            for (const l of a.result) if (!omitted.has(`${parseInt(l.blockNumber, 16)}:${parseInt(l.logIndex, 16)}`)) reference.push(norm(l));
          }
          await sleep(350);
        }
      }
      assertEquals(served, reference.sort(), `${scan}: the served logs equal the chain's`);
      console.log(`  ${scan}: ${served.length} logs over ${JSON.stringify(doc.covered)}`);
    }
    await db.close();
  });
});
