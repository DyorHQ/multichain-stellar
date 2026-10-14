// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assert, assertEquals, assertInstanceOf, assertRejects } from "jsr:@std/assert@1";
import { CommitSlow, DbDown, DefsChanged, LeaseLost, parseState, postgrestDb, Refused, Retryable, type RpcClient } from "./db.ts";

function client(answer: (fn: string, args: Record<string, unknown>) => unknown): { client: RpcClient; calls: [string, Record<string, unknown>][] } {
  const calls: [string, Record<string, unknown>][] = [];
  return {
    calls,
    client: {
      rpc(fn, args) {
        calls.push([fn, args]);
        const run = async () => {
          const a = answer(fn, args);
          if (a instanceof Error) throw a;
          return a as { data: unknown; error: { code?: string; message?: string } | null };
        };
        const p = run();
        return Object.assign(p, { abortSignal: (_s: AbortSignal) => p });
      },
    },
  };
}
const failing = (code: string | undefined, message: string) => client(() => ({ data: null, error: { code, message } })).client;

Deno.test("postgrestDb maps SQLSTATEs to the run's error classes", async () => {
  const cases: [string | undefined, string, new (...a: never[]) => Error][] = [
    ["PT409", "history_commit: the lease is not held", LeaseLost],
    ["PT412", "history_commit: scan moments is at definition 2", DefsChanged],
    ["57014", "canceling statement due to statement timeout", CommitSlow],
    ["55P03", "canceling statement due to lock timeout", CommitSlow],
    ["55P03", "could not obtain lock on row", DbDown],
    ["40P01", "deadlock detected", Retryable],
    ["40001", "could not serialize access", Retryable],
    ["22023", "history_commit: 1 of 3 logs do not match", Refused],
    ["PGRST202", "Could not find the function", DbDown],
    [undefined, "TypeError: fetch failed", DbDown],
  ];
  for (const [code, message, cls] of cases) {
    const db = postgrestDb(failing(code, message));
    const err = await assertRejects(() => db.commit({ owner: "o", scan: "launchpad", defVersion: 1, from: 1, to: 2, head: 3, headTimestamp: 4, wallets: null, logs: [] }));
    assertInstanceOf(err, cls, `${code} ${message}`);
  }
  const paused = await assertRejects(() => postgrestDb(failing("PT409", "history_state: the indexer is paused")).state("o", 10));
  assertEquals((paused as LeaseLost).paused, true);
  const held = await assertRejects(() => postgrestDb(failing("PT409", "history_state: the lease is not held")).state("o", 10));
  assertEquals((held as LeaseLost).paused, false);
  // A thrown network error (or an abort) is DbDown.
  const thrown = client(() => new TypeError("network down")).client;
  assertInstanceOf(await assertRejects(() => postgrestDb(thrown).lease("o", 300, "dev")), DbDown);
});

Deno.test("postgrestDb sends the documented arguments and reads the answers", async () => {
  const { client: c, calls } = client((fn) => {
    if (fn === "history_lease") return { data: { ok: true, paused: false, started: true, endpoints: { rpc2: { rps: 3 } } }, error: null };
    if (fn === "history_commit") return { data: { inserted: 3, trimmed: 0, capFloors: { ["0x" + "a".repeat(40)]: 77 } }, error: null };
    if (fn === "history_set_first_tx") return { data: true, error: null };
    return { data: null, error: null };
  });
  const db = postgrestDb(c);
  assertEquals(await db.lease("o", 300, "abc1234"), { ok: true, paused: false, started: true, endpoints: { rpc2: { rps: 3 } } });
  const answer = await db.commit({ owner: "o", scan: "transfers-in", defVersion: 2, from: 10, to: 20, head: 30, headTimestamp: 40,
                                   wallets: ["0x" + "a".repeat(40)], logs: [] });
  assertEquals(answer, { inserted: 3, trimmed: 0, capFloors: { ["0x" + "a".repeat(40)]: 77 } });
  assertEquals(await db.setFirstTx("o", "0x" + "a".repeat(40), "found", 5, 9, "rpc4+rpc1"), true);
  await db.markHole("o", "launchpad", 1, null, 5, 5);
  await db.release("o", 30, 40, { v: 2, stop: "done" }, { rpc2: { rps: 4 } }, "done");
  assertEquals(calls.map((x) => x[0]), ["history_lease", "history_commit", "history_set_first_tx", "history_mark_hole", "history_release"]);
  assertEquals(calls[1][1], { p_owner: "o", p_scan: "transfers-in", p_def_version: 2, p_from: 10, p_to: 20, p_head: 30, p_head_timestamp: 40,
                              p_wallets: ["0x" + "a".repeat(40)], p_logs: [] });
  assertEquals(calls[4][1], { p_owner: "o", p_head: 30, p_head_timestamp: 40, p_summary: { v: 2, stop: "done" }, p_endpoints: { rpc2: { rps: 4 } }, p_stop: "done" });
});

Deno.test("parseState: history_state's document", () => {
  const W = "0x" + "a".repeat(40);
  const s = parseState({
    now: "2026-10-08T12:00:00Z", head: 100, active: 1, skipped: 0,
    scans: [{ id: "launchpad", covered: [[1, 5], [6, 9]], holes: [], holesCheckedAt: null, head: 9 }],
    wallets: [{ wallet: W, requestedAt: "2026-10-08T11:00:00Z", deep: true,
                firstTx: { state: "found", block: 7, head: 99, checkedAt: "2026-10-08T10:00:00Z", source: "rpc4+rpc1" },
                scans: { "transfers-in": { covered: [[0, 9]], holes: [[10, 10]], holesCheckedAt: "2026-10-08T09:00:00Z", capFloor: null, head: 9, logCount: 3 } } }],
  });
  assertEquals(s.scans[0].covered, [[1, 9]]);
  assertEquals(s.wallets[0].scans["transfers-out"], { covered: [], holes: [], holesCheckedAt: null, capFloor: null, head: null, logCount: 0 });
  assertEquals(s.wallets[0].firstTx.block, 7);
  assertEquals(s.wallets[0].requestedAt, Date.parse("2026-10-08T11:00:00Z"));
  assert(s.wallets[0].deep);
  for (const bad of [null, {}, { scans: [], wallets: [{ wallet: "0xABC" }] }, { scans: [{ id: "launchpad", covered: [[5, 1]] }], wallets: [] }]) {
    let threw = false;
    try { parseState(bad); } catch { threw = true; }
    assert(threw, JSON.stringify(bad));
  }
});
