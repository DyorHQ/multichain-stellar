// Migration 32 (the wallet-history cache) on a throwaway PGlite database, from each PostgREST role's point of view:
// the seed against history-scans.json, enrolment by trigger, privileges, the lease and the owner's switches, every
// refusal of history_commit, holes, caps, the paged read, generic plans, first transactions, the owner functions and
// account deletion. Nothing here touches a real project.
//
//   deno test -A --no-config --node-modules-dir=none supabase/tests/history_cache_test.ts   (about 2 minutes)
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";
import { pgcrypto } from "npm:@electric-sql/pglite@0.5.8/contrib/pgcrypto";
import { citext } from "npm:@electric-sql/pglite@0.5.8/contrib/citext";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { bundledDefs, canonicalLines } from "../functions/history-indexer/scans.ts";
import { as, code, historyDatabase, one } from "./history_pglite_db.ts";

// deno-lint-ignore no-explicit-any
type Any = any;

const W = "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47";
const B = "0x" + "b".repeat(40);
const C = "0x" + "c".repeat(40);
const D = "0x" + "d".repeat(40);
const pad = (a: string) => "0x000000000000000000000000" + a.slice(2);
const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CURVEBUY = "0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455";
const COLLECTED = "0xc475c499a9357ec964b24130f5e1e4b21748160d33ce0df8721acb1e370b7c96";
const SHARING_CLAIMED = "0xf7a40077ff7a04c7e61f6f26fb13774259ddf1b6bce9ecf26a8276cdd3992683";
const MOMENTS_FACTORY = "0x95eb7f5a88b10d9df32ac54f48c767927fa80840";
const h64 = (n: number) => "0x" + n.toString(16).padStart(64, "0");
const log = (b: number, i: number, topics: string[], data = "0x" + "00".repeat(32), a = "0x" + "6".repeat(40)) =>
  ({ a, t: topics, d: data, n: (data.length - 2) / 2, b, h: h64(b * 1000 + i), i, s: 1_700_000_000 + b });
// Bulk rows as postgres (committing 20,000 logs through history_commit takes minutes on PGlite).
const bulk = (scan: string, subject: string, topicsSql: string, from: number, n: number, logIndex = 0) => `
  insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
  select '${scan}', decode('${subject.slice(2)}', 'hex'), ${from} + g, ${logIndex}, decode(lpad(to_hex(${from} + g), 64, '0'), 'hex'),
         decode(repeat('66', 20), 'hex'), ${topicsSql}, decode(repeat('00', 32), 'hex'), 32, 1700000000 + g
    from generate_series(0, ${n - 1}) g`;
const transferTopics = (from: string, to: string) =>
  `array[decode('${TRANSFER.slice(2)}', 'hex'), decode(lpad('${from.slice(2)}', 64, '0'), 'hex'), decode(lpad('${to.slice(2)}', 64, '0'), 'hex')]`;
const H = 110_000_000;

const COMMIT = "select public.history_commit($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb) r";
const snapshot = (db: PGlite) => one<Any>(db, `select
  (select coalesce(string_agg(id || covered::text || holes::text || coalesce(head_block::text, '-'), ';' order by id), '') from public.history_scans) s,
  (select coalesce(string_agg(wallet || scan || covered::text || holes::text || log_count, ';' order by wallet, scan), '') from public.history_wallet_scans) w,
  (select count(*)::int from public.history_logs) n`);

Deno.test("migration 32: the wallet-history cache", async (t) => {
  const db = await historyDatabase();
  const owner = crypto.randomUUID();
  const svc = (sql: string, p: unknown[] = []) => as<Any>(db, "service_role", null, sql, p);
  const commit = (scan: string, def: number, from: number, to: number, wallets: string[] | null, logs: unknown[], head = H) =>
    svc(COMMIT, [owner, scan, def, from, to, head, 1_700_000_000, wallets, JSON.stringify(logs)]).then((r) => r[0].r);

  await t.step("1. the seed equals history-scans.json, and the verify query prints print_scans.ts's lines", async () => {
    const spec = JSON.parse(await Deno.readTextFile(new URL("../functions/_shared/history-scans.json", import.meta.url)));
    const rows = (await db.query<Any>(`select id, kind, wallet_topic, floor_block::bigint::text floor,
        (select coalesce(array_agg('0x' || encode(a, 'hex') order by a), '{}') from unnest(addresses) a) addresses,
        (select array_agg('0x' || encode(t, 'hex') order by t) from unnest(topic0s) t) topic0s, def_version
       from public.history_scans`)).rows;
    assertEquals(rows.length, spec.scans.length);
    for (const s of spec.scans) {
      const r = rows.find((x: Any) => x.id === s.id);
      assert(r, s.id);
      assertEquals([r.kind, r.wallet_topic, Number(r.floor), r.def_version], [s.kind, s.walletTopic, s.floor, 1], s.id);
      assertEquals(r.addresses, [...s.addresses].sort(), s.id);
      assertEquals(r.topic0s, s.events.map((e: Any) => e.topic).sort(), s.id);
    }
    const verify = (await db.query<{ line: string }>(`select id || '|' || kind || '|' || wallet_topic || '|' || floor_block || '|'
          || coalesce((select string_agg('0x' || encode(a, 'hex'), ',' order by a) from unnest(addresses) a), '') || '|'
          || (select string_agg('0x' || encode(t, 'hex'), ',' order by t) from unnest(topic0s) t) as line
        from public.history_scans order by id`)).rows.map((r) => r.line);
    assertEquals(verify, canonicalLines(bundledDefs()));
  });

  await t.step("2. enrolment: a profile upsert enrols both wallet scans and moves requested_at; a failure never fails the profile", async () => {
    const upsert = (w: string) => as(db, "authenticated", w,
      "insert into public.profiles (wallet) values ($1) on conflict (wallet) do update set wallet = excluded.wallet", [w]);
    await upsert(W);
    const first = await one<Any>(db, "select requested_at, enrolled_at from public.history_wallets where wallet = $1", [W]);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallet_scans where wallet = $1", [W])).n, 2);
    await upsert(W);
    const second = await one<Any>(db, "select requested_at, enrolled_at from public.history_wallets where wallet = $1", [W]);
    assert(second.requested_at > first.requested_at, "requested_at moves on every upsert");
    assertEquals(second.enrolled_at, first.enrolled_at);
    await upsert(B);
    // An enrolment that fails (here a temporary CHECK) leaves the profile write intact; the wallet is just untracked.
    await db.exec(`alter table public.history_wallets add constraint tmp_refuse check (wallet <> '${D}')`);
    await upsert(D);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.profiles where wallet = $1", [D])).n, 1);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallets where wallet = $1", [D])).n, 0);
    await db.exec("alter table public.history_wallets drop constraint tmp_refuse");
    await as(db, "authenticated", D, "delete from public.profiles where wallet = $1", [D]);
    // Nor does it wait: a lock another transaction holds (history_reset, a redefinition) times out in 200 ms with 55P03,
    // which the handler catches, instead of running into the caller's statement_timeout (57014, uncatchable). PGlite has
    // one connection, so the wait itself is exercised on Postgres (history_pg_perf_test.ts); here, the setting.
    const cfg = await one<Any>(db, "select proconfig c from pg_proc where oid = 'public.history_enrol_profile()'::regprocedure");
    assert(cfg.c.includes("lock_timeout=200ms") && cfg.c.includes("search_path=\"\""), JSON.stringify(cfg.c));
  });

  await t.step("2b. the migration enrols existing profiles, requested when they were last written", async () => {
    const fresh = await PGlite.create({ extensions: { pgcrypto, citext } });
    await fresh.exec(await Deno.readTextFile(new URL("./supabase_stub.sql", import.meta.url)));
    const names: string[] = [];
    for await (const e of Deno.readDir(new URL("../migrations/", import.meta.url))) if (e.name.endsWith(".sql")) names.push(e.name);
    for (const n of names.sort().filter((n) => n < "32_")) await fresh.exec(await Deno.readTextFile(new URL(`../migrations/${n}`, import.meta.url)));
    await fresh.exec(`insert into public.profiles (wallet, updated_at) values ('${C}', '2026-09-01T00:00:00Z')`);
    await fresh.exec(await Deno.readTextFile(new URL("../migrations/32_wallet_history.sql", import.meta.url)));
    const row = await one<Any>(fresh, "select requested_at from public.history_wallets where wallet = $1", [C]);
    assertEquals(new Date(row.requested_at).toISOString(), "2026-09-01T00:00:00.000Z");
    assertEquals((await one<Any>(fresh, "select count(*)::int n from public.history_wallet_scans")).n, 2);
    await fresh.close();
  });

  await t.step("3. privileges: tables closed to every API role; functions by role; RLS; fillfactor", async () => {
    const tables = ["history_scans", "history_wallets", "history_wallet_scans", "history_logs", "history_subject_caps",
                    "history_indexer_state", "history_indexer_runs"];
    for (const role of ["anon", "authenticated", "service_role"] as const) {
      for (const tb of tables) {
        await assertRejects(() => as(db, role, W, `select count(*) from public.${tb}`), Error, "permission denied", `${role} ${tb}`);
      }
      await assertRejects(() => as(db, role, W, "update public.history_indexer_state set paused = true where id"), Error, "permission denied");
    }
    const indexer = ["select public.history_lease(gen_random_uuid(), 60)", "select public.history_state(gen_random_uuid(), 10)",
                     `select public.history_commit(gen_random_uuid(), 'launchpad', 1, 0, 1, 2, 3, null, '[]')`,
                     `select public.history_mark_hole(gen_random_uuid(), 'launchpad', 1, null, 0, 1)`,
                     `select public.history_set_first_tx(gen_random_uuid(), '${W}', 'none', null, 1)`,
                     "select public.history_release(gen_random_uuid(), null, null, null)"];
    const owners = ["select public.history_reset('moments')", "select public.history_health()", "select public.history_housekeeping()",
                    `select public.history_apply_cap('${W}', 'transfers-in')`, "select public.history_redefine_scan('moments', null, null, null, 1)",
                    "select public.history_ranges('{}')", `select public.history_require_lease(gen_random_uuid(), 'x')`,
                    "select public.history_octets('{}', 20)"];
    for (const role of ["anon", "authenticated"] as const) {
      for (const sql of [...indexer, ...owners]) await assertRejects(() => as(db, role, W, sql), Error, "permission denied", `${role}: ${sql}`);
    }
    for (const sql of owners) await assertRejects(() => svc(sql), Error, "permission denied", sql);
    // The six indexer RPCs are executable by service_role (they refuse a non-holder with PT409, not 42501).
    for (const sql of indexer.slice(1, 5)) assert((await code(svc(sql))).startsWith("PT409"), sql);
    for (const role of ["anon", "authenticated", "service_role"] as const) {
      const r = await as<Any>(db, role, W, "select public.history_read($1) r", [W]);
      assertEquals(r[0].r.serving, true);
    }
    for (const tb of tables) assertEquals((await one<Any>(db, `select relrowsecurity r from pg_class where oid = 'public.${tb}'::regclass`)).r, true, tb);
    for (const tb of ["history_scans", "history_wallet_scans", "history_indexer_state"]) {
      assertEquals((await one<Any>(db, `select reloptions f from pg_class where oid = 'public.${tb}'::regclass`)).f, ["fillfactor=50"], tb);
    }
    assertEquals((await one<Any>(db, "select count(*)::int n from pg_policies where tablename like 'history%'")).n, 0);
  });

  await t.step("3b. history_cron_digest: service_role only; the Vault secret's SHA-256, never the secret; null when it is missing, malformed or unreadable", async () => {
    const digestOf = (role: "service_role" | "anon" | "authenticated" = "service_role") =>
      as<Any>(db, role, null, "select public.history_cron_digest() r").then((r) => r[0].r as string | null);
    const sha = async (v: string) =>
      Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))), (b) => b.toString(16).padStart(2, "0")).join("");
    const setSecret = (v: string) => db.query("update vault.secrets set secret = $1 where name = 'history_cron_secret'", [v]);
    const secret = "0123456789abcdef".repeat(4); // 64 hex characters, the shape migration 33 generates (a test value)
    // No secret yet: null.
    assertEquals(await digestOf(), null);
    await db.query("select vault.create_secret($1, 'history_cron_secret', 'test')", [secret]);
    try {
      // The same digest the Edge Function computes for the header (auth.ts: SHA-256 of the UTF-8 bytes), never the secret.
      assertEquals(await digestOf(), await sha(secret));
      assert(!(await digestOf())!.includes(secret));
      // anon and authenticated cannot even call it (42501), and nothing about the secret is in the error.
      for (const role of ["anon", "authenticated"] as const) {
        const err = await code(digestOf(role));
        assert(err.startsWith("42501"), `${role}: ${err}`);
        assert(!err.includes(secret) && !err.includes(await sha(secret)), "the error never quotes the secret or its digest");
      }
      for (const [role, want] of [["anon", false], ["authenticated", false], ["service_role", true]] as const) {
        assertEquals((await one<Any>(db, "select has_function_privilege($1, 'public.history_cron_digest()', 'execute') r", [role])).r, want, role);
      }
      assertEquals((await one<Any>(db, "select has_function_privilege('public', 'public.history_cron_digest()', 'execute') r")).r, false);
      const fn = await one<Any>(db, `select prosecdef d, proconfig c, provolatile v from pg_proc where oid = 'public.history_cron_digest()'::regprocedure`);
      assertEquals([fn.d, fn.c, fn.v], [true, ['search_path=""'], "s"]);
      // Vault unreadable (no vault schema): null, never an error.
      await db.exec("alter schema vault rename to vault_away");
      try { assertEquals(await digestOf(), null); } finally { await db.exec("alter schema vault_away rename to vault"); }
      assertEquals(await digestOf(), await sha(secret));
      // A secret the Edge Function would never accept as a header serves nothing: shorter than 32 or longer than 512
      // characters, or anything outside visible ASCII (a space, a tab, a newline, é).
      for (const bad of ["short-secret", "z".repeat(31), "x".repeat(513), "correct horse battery staple and more words",
                         "a".repeat(40) + "\t", "a".repeat(40) + "\n", "é".repeat(40), "a".repeat(39) + "é"]) {
        await setSecret(bad);
        assertEquals(await digestOf(), null, JSON.stringify(bad.slice(-12)));
      }
      // The edges of the rule: 32 and 512 characters, any visible ASCII.
      for (const ok of ["a".repeat(32), "x".repeat(512), "!~" + "A+/=".repeat(10)]) {
        await setSecret(ok);
        assertEquals(await digestOf(), await sha(ok), ok.slice(0, 12));
      }
    } finally {
      await db.exec("delete from vault.secrets where name = 'history_cron_secret'");
    }
    assertEquals(await digestOf(), null);
  });

  await t.step("4. the lease, the switches, run rows and the endpoint memory", async () => {
    const r = (await svc("select public.history_lease($1, 300, 'abc1234') r", [owner]))[0].r;
    assertEquals([r.ok, r.started, r.paused], [true, true, false]);
    const other = crypto.randomUUID();
    assertEquals((await svc("select public.history_lease($1, 300) r", [other]))[0].r, { ok: false, paused: false });
    for (const sql of ["select public.history_state($1, 100)", `select public.history_mark_hole($1, 'launchpad', 1, null, 104000000, 104000000)`,
                       `select public.history_set_first_tx($1, '${W}', 'none', null, 1)`]) {
      const c = await code(svc(sql, [other]));
      assert(c.startsWith("PT409") && c.includes("not held"), c);
    }
    await commit("launchpad", 1, 104_000_000, 104_000_000, null, []); // the holder commits
    await assertRejects(() => svc("select public.history_lease($1, 10)", [other]), Error, "30–390");
    // Renewing keeps the run; paused refuses everyone at once.
    assertEquals((await svc("select public.history_lease($1, 300) r", [owner]))[0].r.started, false);
    await db.exec("update public.history_indexer_state set paused = true where id");
    assertEquals((await svc("select public.history_lease($1, 300) r", [owner]))[0].r, { ok: false, paused: true });
    const c = await code(svc("select public.history_state($1, 100)", [owner]));
    assert(c.startsWith("PT409") && c.includes("paused"), c);
    await db.exec("update public.history_indexer_state set paused = false where id");
    // A released lease (or an expired one) is taken over by a new run, which gets its own run row.
    await svc("select public.history_release($1, $2, 1, $3::jsonb, $4::jsonb, 'done')",
              [owner, H, JSON.stringify({ v: 2, stop: "done", counts: { inserted: { launchpad: 3 } } }), JSON.stringify({ rpc2: { rps: 3.5 } })]);
    const o2 = crypto.randomUUID();
    const l2 = (await svc("select public.history_lease($1, 300, 'def5678') r", [o2]))[0].r;
    assertEquals([l2.ok, l2.started, l2.endpoints], [true, true, { rpc2: { rps: 3.5 } }]);
    await svc("select public.history_release($1, $2, 1, $3::jsonb, null, 'shutdown:CPUTime')",
              [o2, H, JSON.stringify({ v: 2, stop: "x", counts: { a: 1 }, junk: "z".repeat(20_000) })]);
    // A second release (the shutdown handler racing the normal one, which sends no endpoint memory) changes nothing.
    await svc("select public.history_release($1, $2, 1, '{}'::jsonb, null, 'done')", [o2, H]);
    const run2 = await one<Any>(db, "select stop, summary, version, released_at is not null rel from public.history_indexer_runs where owner = $1", [o2]);
    assertEquals([run2.stop, run2.summary, run2.version, run2.rel], ["shutdown:CPUTime", { v: 2, truncated: true, stop: "x", counts: { a: 1 } }, "def5678", true]);
    assertEquals((await one<Any>(db, "select endpoints from public.history_indexer_state")).endpoints, { rpc2: { rps: 3.5 } });
    const run1 = await one<Any>(db, "select stop, version from public.history_indexer_runs where owner = $1", [owner]);
    assertEquals([run1.stop, run1.version], ["done", "abc1234"]);
    // An expired lease is taken over.
    const o3 = crypto.randomUUID();
    await svc("select public.history_lease($1, 30) r", [o3]);
    await db.exec("update public.history_indexer_state set lease_until = now() - interval '1 second' where id");
    assertEquals((await svc("select public.history_lease($1, 300) r", [owner]))[0].r.ok, true);
    assert((await code(svc("select public.history_state($1, 100)", [o3]))).startsWith("PT409"));
    const st = (await svc("select public.history_state($1, 100) r", [owner]))[0].r;
    assertEquals(st.scans.length, 5);
    assertEquals(st.wallets.map((w: Any) => w.wallet).sort(), [W, B].sort());
    assertEquals(st.head, H);
  });

  await t.step("5. history_commit refuses anything malformed and changes nothing; a redefinition in between is PT412", async () => {
    const ok = [log(104_000_010, 3, [CURVEBUY, pad(W), pad(B)])];
    const cases: [string, string, number, number, string[] | null, unknown[], number?][] = [
      ["a log below the range", "launchpad", 104_010_000, 104_019_999, null, [log(104_000_000, 1, [CURVEBUY, pad(W)])]],
      ["a log above the range", "launchpad", 104_010_000, 104_019_999, null, [log(104_020_000, 1, [CURVEBUY, pad(W)])]],
      ["another topic0", "launchpad", 104_010_000, 104_019_999, null, [log(104_010_000, 1, [TRANSFER, pad(W)])]],
      ["a contract outside the list", "fee-sharing", 104_010_000, 104_019_999, null, [log(104_010_000, 1, [SHARING_CLAIMED, pad(B), pad(W)])]],
      ["malformed hex", "launchpad", 104_010_000, 104_019_999, null, [{ ...log(104_010_000, 1, [CURVEBUY, pad(W)]), h: "0xzz" }]],
      ["five topics", "launchpad", 104_010_000, 104_019_999, null, [log(104_010_000, 1, [CURVEBUY, pad(W), pad(B), pad(C), pad(D)])]],
      ["data length ≠ n", "launchpad", 104_010_000, 104_019_999, null, [{ ...log(104_010_000, 1, [CURVEBUY, pad(W)]), n: 31 }]],
      ["null data with n ≤ 16 KiB", "launchpad", 104_010_000, 104_019_999, null, [{ ...log(104_010_000, 1, [CURVEBUY, pad(W)]), d: null }]],
      ["a wallet not in p_wallets", "transfers-in", 0, 9_999, [W], [log(5, 0, [TRANSFER, pad(W), pad(B)])]],
      ["101 wallets", "transfers-in", 0, 9_999, Array.from({ length: 101 }, (_, k) => "0x" + k.toString(16).padStart(40, "0")), []],
      ["duplicate wallets", "transfers-in", 0, 9_999, [W, W], []],
      ["upper-case wallet", "transfers-in", 0, 9_999, [W.toUpperCase().replace("0X", "0x")], []],
      ["wallets on a global scan", "launchpad", 104_010_000, 104_019_999, [W], []],
      ["below a global floor", "launchpad", 103_000_000, 103_999_999, null, []],
      ["p_to above p_head", "launchpad", 104_010_000, 104_019_999, null, [], 104_019_998],
      ["more than 5,000 logs", "launchpad", 104_010_000, 104_019_999, null, Array.from({ length: 5_001 }, (_, k) => log(104_010_000 + k, 0, [CURVEBUY, pad(W)]))],
      ["an unknown scan", "other", 0, 1, null, []],
    ];
    const before = await snapshot(db);
    for (const [what, scan, from, to, wallets, logs, head] of cases) {
      const c = await code(commit(scan, 1, from, to, wallets, logs, head ?? H));
      assert(c.startsWith("22023"), `${what}: ${c}`);
      assertEquals(await snapshot(db), before, what);
    }
    // The definition moved on between history_state and the commit: refused, nothing changes; the new version works.
    await db.query("select public.history_redefine_scan('moments', null, null, null, 105347754)");
    const mlogs = [log(106_000_000, 0, [COLLECTED, h64(1), pad(W)], undefined, MOMENTS_FACTORY)];
    const c412 = await code(commit("moments", 1, 106_000_000, 106_009_999, null, mlogs));
    assert(c412.startsWith("PT412"), c412);
    assertEquals(await snapshot(db), before);
    assertEquals((await commit("moments", 2, 106_000_000, 106_009_999, null, mlogs)).inserted, 1);
    // Acceptance: adjacency merges, the same commit twice inserts nothing, heads never go back, a global log without an
    // address at the wallet topic is skipped, data over 16 KiB is stored without its data.
    const r1 = await commit("launchpad", 1, 104_000_000, 104_009_999, null, [...ok,
      log(104_000_020, 0, [CURVEBUY, "0xff" + "00".repeat(31)]), { ...log(104_000_030, 0, [CURVEBUY, pad(C)]), d: null, n: 16_385 }]);
    assertEquals(r1.inserted, 2);
    assertEquals((await one<Any>(db, "select data is null x, data_length n from public.history_logs where scan = 'launchpad' and block_number = 104000030")), { x: true, n: 16_385 });
    assertEquals((await commit("launchpad", 1, 104_000_000, 104_009_999, null, ok)).inserted, 0);
    await commit("launchpad", 1, 104_010_000, 104_019_999, null, [], H - 5);
    const lp = await one<Any>(db, "select covered::text c, head_block::bigint::text h from public.history_scans where id = 'launchpad'");
    assertEquals([lp.c, lp.h], ["{[104000000,104020000)}", String(H)]); // adjacent ranges merged; the head did not go back
    // A wallet that is not enrolled (or was deleted) gets nothing, but the enrolled ones in the same commit do.
    const r2 = await commit("transfers-in", 1, 0, 9_999, [W, C], [log(5, 0, [TRANSFER, pad(B), pad(W)]), log(6, 0, [TRANSFER, pad(B), pad(C)])]);
    assertEquals(r2.inserted, 1);
    assertEquals((await one<Any>(db, "select covered::text c, log_count n from public.history_wallet_scans where wallet = $1 and scan = 'transfers-in'", [W])), { c: "{[0,10000)}", n: 1 });
  });

  await t.step("6. holes: recorded, never overlapping coverage, served, cleared by the commit that covers them", async () => {
    const OLD = "2026-01-01T00:00:00Z";
    // The row's retry clock: null, the OLD mark set below, or "other" (moved since).
    const clock = async (table: string, where: string) =>
      (await one<Any>(db, `select case when holes_checked_at is null then null when holes_checked_at = '${OLD}'::timestamptz then 'old'
                                        else 'other' end t from public.${table} where ${where}`)).t as string | null;
    const lp = "id = 'launchpad'";
    assertEquals(await clock("history_scans", lp), null);
    assertEquals((await svc("select public.history_mark_hole($1, 'launchpad', 1, null, 104050000, 104050099) r", [owner]))[0].r, [[104_050_000, 104_050_099]]);
    assertEquals(await clock("history_scans", lp), "other", "the row's first hole starts its retry clock");
    await db.exec(`update public.history_scans set holes_checked_at = '${OLD}' where ${lp}`);
    // A hole over covered blocks keeps only the uncovered part; a new hole beside an older one leaves the clock (else a
    // stream of new holes would postpone the older ones' 6-hour retry for ever).
    assertEquals((await svc("select public.history_mark_hole($1, 'launchpad', 1, null, 104019990, 104020009) r", [owner]))[0].r,
                 [[104_020_000, 104_020_009], [104_050_000, 104_050_099]]);
    assertEquals(await clock("history_scans", lp), "old");
    // Nothing to record (covered blocks only): the clock stays too.
    await svc("select public.history_mark_hole($1, 'launchpad', 1, null, 104000000, 104000009)", [owner]);
    assertEquals(await clock("history_scans", lp), "old");
    // A retry that failed again (the range is already a hole) restarts it.
    assertEquals((await svc("select public.history_mark_hole($1, 'launchpad', 1, null, 104050000, 104050099) r", [owner]))[0].r,
                 [[104_020_000, 104_020_009], [104_050_000, 104_050_099]]);
    assertEquals(await clock("history_scans", lp), "other", "a failed retry restarts the clock");
    // The same rules per wallet (B's transfers-out, cleaned up after).
    const bo = `wallet = '${B}' and scan = 'transfers-out'`;
    await svc("select public.history_mark_hole($1, 'transfers-out', 1, $2, 50, 50)", [owner, B]);
    assertEquals(await clock("history_wallet_scans", bo), "other");
    await db.exec(`update public.history_wallet_scans set holes_checked_at = '${OLD}' where ${bo}`);
    await svc("select public.history_mark_hole($1, 'transfers-out', 1, $2, 70, 70)", [owner, B]);
    assertEquals(await clock("history_wallet_scans", bo), "old");
    assertEquals((await svc("select public.history_mark_hole($1, 'transfers-out', 1, $2, 50, 50) r", [owner, B]))[0].r, [[50, 50], [70, 70]]);
    assertEquals(await clock("history_wallet_scans", bo), "other");
    await db.exec(`update public.history_wallet_scans set holes = '{}', holes_checked_at = null where ${bo}`);
    await assertRejects(() => svc("select public.history_mark_hole($1, 'launchpad', 1, null, 104000000, 104010000)", [owner]), Error, "bad definition version or range");
    await assertRejects(() => svc("select public.history_mark_hole($1, 'launchpad', 1, $2, 104050000, 104050000)", [owner, W]), Error, "takes no wallet");
    await assertRejects(() => svc("select public.history_mark_hole($1, 'transfers-in', 1, null, 5, 5)", [owner]), Error, "one lowercase wallet");
    const read = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [W]))[0].r;
    assertEquals(read.scans.launchpad.holes, [[104_020_000, 104_020_009], [104_050_000, 104_050_099]]);
    await commit("launchpad", 1, 104_050_000, 104_050_099, null, []);
    await commit("launchpad", 1, 104_020_000, 104_020_009, null, []);
    assertEquals((await one<Any>(db, "select holes::text h from public.history_scans where id = 'launchpad'")).h, "{}");
    // A spam block near the head of a wallet that cannot be read: a hole; the wallet's older logs and coverage stay.
    await svc("select public.history_mark_hole($1, 'transfers-in', 1, $2, 9999995, 9999995)", [owner, W]);
    assertEquals((await one<Any>(db, "select covered::text c, holes::text h, cap_floor f, log_count n from public.history_wallet_scans where wallet = $1 and scan = 'transfers-in'", [W])),
                 { c: "{[0,10000)}", h: "{[9999995,9999996)}", f: null, n: 1 });
  });

  await t.step("7. caps: a wallet scan past 20,000 logs by count; a global subject past 20,000 at write time", async () => {
    // W: 20,000 transfers-out over [1,000,000, 1,019,999] (bulk), coverage claimed as commits would have.
    await db.exec(bulk("transfers-out", W, transferTopics(W, B), 1_000_000, 20_000));
    await db.query("update public.history_wallet_scans set covered = '{[1000000,1020000)}', log_count = 20000 where wallet = $1 and scan = 'transfers-out'", [W]);
    await svc("select public.history_mark_hole($1, 'transfers-out', 1, $2, 1029995, 1029995)", [owner, W]);
    const mk = (from: number, n: number) => Array.from({ length: n }, (_, k) => log(from + k, 0, [TRANSFER, pad(W), pad(B)]));
    const r = await commit("transfers-out", 1, 1_020_000, 1_029_994, [W, B], mk(1_020_000, 500));
    assertEquals(r.capFloors[W], 1_000_500);
    assertEquals((await one<Any>(db, "select covered::text c, holes::text h, cap_floor::int f, log_count n from public.history_wallet_scans where wallet = $1 and scan = 'transfers-out'", [W])),
                 { c: "{[1000500,1029995)}", h: "{[1029995,1029996)}", f: 1_000_500, n: 20_000 });
    assertEquals((await one<Any>(db, "select count(*)::int n, min(block_number)::int m from public.history_logs where scan = 'transfers-out' and subject = decode($1, 'hex')", [W.slice(2)])),
                 { n: 20_000, m: 1_000_500 });
    // Below the cap floor a commit stores and claims nothing.
    await commit("transfers-out", 1, 0, 9_999, [W], mk(100, 3));
    assertEquals((await one<Any>(db, "select covered::text c, log_count n from public.history_wallet_scans where wallet = $1 and scan = 'transfers-out'", [W])),
                 { c: "{[1000500,1029995)}", n: 20_000 });
    // A global subject: 20,000 logs for C, then 10 newer → the 10 oldest blocks go, and nothing older is stored again.
    await db.exec(bulk("launchpad", C, `array[decode('${CURVEBUY.slice(2)}', 'hex'), decode(lpad('${C.slice(2)}', 64, '0'), 'hex')]`, 104_100_000, 20_000));
    const cap = await commit("launchpad", 1, 104_200_000, 104_209_999, null, Array.from({ length: 10 }, (_, k) => log(104_200_000 + k, 0, [CURVEBUY, pad(C)])));
    assertEquals([cap.inserted, cap.trimmed], [10, 11]); // the 10 oldest bulk blocks, and step 5's older log for C
    assertEquals((await one<Any>(db, "select cap_floor::int f from public.history_subject_caps where scan = 'launchpad' and subject = decode($1, 'hex')", [C.slice(2)])).f, 104_100_010);
    const older = await commit("launchpad", 1, 104_090_000, 104_099_999, null, [log(104_090_000, 0, [CURVEBUY, pad(C)]), log(104_090_001, 0, [CURVEBUY, pad(B)])]);
    assertEquals([older.inserted, older.trimmed], [1, 0]);
  });

  await t.step("8. history_read: shapes, paging with the bounds in the cursor, a cap raised between pages, meta-only, bounds, omitted", async () => {
    const t0 = performance.now();
    const p1 = (await as<Any>(db, "anon", null, "select public.history_read($1) r", [W.toUpperCase().replace("0X", "0x")]))[0].r;
    assert(performance.now() - t0 < 3_000);
    assertEquals([p1.version, p1.serving, p1.tracked, p1.wallet, Object.keys(p1.scans).sort()],
                 [1, true, true, W, ["fee-sharing", "launchpad", "moments", "transfers-in", "transfers-out"]]);
    assertEquals(p1.firstTx, { state: "unknown", block: null });
    assertEquals(p1.scans["transfers-in"].query, { addresses: [], topics: [[TRANSFER], null, [pad(W)]] });
    assertEquals(p1.scans["transfers-out"].query.topics, [[TRANSFER], [pad(W)]]);
    assertEquals(p1.scans["transfers-in"].fingerprint, `|${TRANSFER},*,${pad(W)}`);
    assertEquals(p1.scans.moments.defVersion, 2);
    assertEquals([p1.scans["transfers-out"].from, p1.scans["transfers-out"].to, p1.scans["transfers-out"].capFloor], [1_000_500, H, 1_000_500]);
    // A served log is eth_getLogs JSON, newest first.
    const first = p1.scans.launchpad.logs[0];
    assertEquals(Object.keys(first).sort(), ["address", "blockNumber", "blockTimestamp", "data", "logIndex", "removed", "topics", "transactionHash"]);
    assert(p1.next.startsWith("v1:4:"), p1.next);
    // Page through transfers-out while a cap is raised between pages: later pages report the higher capFloor, never
    // serve a log above page 1's promise, and serve every log that remains.
    await db.exec(bulk("transfers-out", W, transferTopics(W, B), 1_030_000, 300));
    await db.query("update public.history_wallet_scans set covered = covered + '{[1030000,1030300)}', log_count = log_count + 300 where wallet = $1 and scan = 'transfers-out'", [W]);
    await db.query("select public.history_apply_cap($1, 'transfers-out')", [W]);
    let next = p1.next, pages = 1, served = p1.scans["transfers-out"].logs.length, maxCap = p1.scans["transfers-out"].capFloor;
    const seen = new Set<string>(p1.scans["transfers-out"].logs.map((l: Any) => l.blockNumber));
    let lastBlock = Number.POSITIVE_INFINITY;
    while (next) {
      const p = (await as<Any>(db, "anon", null, "select public.history_read($1, $2) r", [W, next]))[0].r;
      assertEquals([p.tracked, p.scans.moments.defVersion, Object.keys(p.scans).length], [true, 2, 5]);
      maxCap = Math.max(maxCap, p.scans["transfers-out"].capFloor);
      for (const l of p.scans["transfers-out"].logs) {
        const b = parseInt(l.blockNumber, 16);
        assert(!seen.has(l.blockNumber) && b <= H && b < lastBlock, "each log once, newest first, never above the promise");
        seen.add(l.blockNumber);
        lastBlock = b;
      }
      served += p.scans["transfers-out"].logs.length;
      next = p.next;
      pages++;
    }
    assertEquals(maxCap, 1_000_800);
    assertEquals(served, 20_000 - 300);
    assert(pages >= 10);
    // Meta-only, and a bounded range.
    const meta = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [W]))[0].r;
    assertEquals([meta.next, meta.scans["transfers-out"].logs.length, meta.scans["transfers-out"].capFloor], [null, 0, 1_000_800]);
    await assertRejects(() => as(db, "anon", null, "select public.history_read($1, $2, null, null, true)", [W, p1.next]), Error, "p_cursor");
    const rng = (await as<Any>(db, "anon", null, "select public.history_read($1, null, 1019000, 1019099) r", [W]))[0].r;
    assertEquals([rng.scans["transfers-out"].logs.length, rng.scans["transfers-out"].covered, rng.scans["transfers-out"].complete,
                  rng.scans["transfers-out"].from, rng.scans["transfers-out"].to], [100, [[1_019_000, 1_019_099]], true, 1_019_000, 1_019_099]);
    const empty = (await as<Any>(db, "anon", null, "select public.history_read($1, null, 5, 9) r", [W]))[0].r;
    assertEquals([empty.scans.launchpad.from, empty.scans.launchpad.to, empty.scans.launchpad.complete], [1, 0, true]);
    // 101 oversized logs → 100 listed, truncated; a page of 16 KiB logs stays under 2 MB.
    await db.exec(`insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
      select 'transfers-out', decode('${W.slice(2)}', 'hex'), 1020000 + g, 7, decode(lpad(to_hex(g), 64, '0'), 'hex'), decode(repeat('66', 20), 'hex'),
             ${transferTopics(W, B)}, null, 20000, 1 from generate_series(0, 100) g`);
    const om = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [W]))[0].r;
    assertEquals([om.scans["transfers-out"].omitted.length, om.scans["transfers-out"].omittedTruncated], [100, true]);
    assertEquals(Object.keys(om.scans["transfers-out"].omitted[0]).sort(), ["address", "blockNumber", "logIndex", "transactionHash"]);
    await db.exec(`insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
      select 'transfers-in', decode('${B.slice(2)}', 'hex'), 2000000 + g, 0, decode(lpad(to_hex(g), 64, '0'), 'hex'), decode(repeat('66', 20), 'hex'),
             ${transferTopics(W, B)}, decode(repeat('ab', 16384), 'hex'), 16384, 1 from generate_series(0, 199) g`);
    await db.query("update public.history_wallet_scans set covered = '{[2000000,2000200)}', head_block = 2000199 where wallet = $1 and scan = 'transfers-in'", [B]);
    let cursor: string | null = null;
    let pagesB = 0, logsB = 0;
    do {
      const page: Any = (await as<Any>(db, "anon", null, "select public.history_read($1, $2) r", [B, cursor]))[0].r;
      assert(JSON.stringify(page).length < 2_000_000, "a page stays under 2 MB");
      logsB += page.scans["transfers-in"].logs.length;
      cursor = page.next;
      pagesB++;
    } while (cursor);
    assertEquals(logsB, 200);
    assert(pagesB >= 4, `${pagesB} pages`);
    // Untracked: the three global scans only; malformed input refused; serving off.
    const un = (await as<Any>(db, "anon", null, "select public.history_read($1) r", [C]))[0].r;
    assertEquals([un.tracked, un.firstTx, Object.keys(un.scans).sort()], [false, null, ["fee-sharing", "launchpad", "moments"]]);
    assertEquals(un.scans.launchpad.capFloor, 104_100_010);
    for (const bad of ["nope", "0x123", W + "00", ""]) await assertRejects(() => as(db, "anon", null, "select public.history_read($1)", [bad]), Error, "p_wallet");
    for (const bad of ["v1:9", "v2:1:-:-:1-0,1-0,1-0,1-0,1-0", "v1:1:-:-:1-0"]) {
      await assertRejects(() => as(db, "anon", null, "select public.history_read($1, $2)", [W, bad]), Error, "p_cursor");
    }
    await assertRejects(() => as(db, "anon", null, "select public.history_read($1, null, 9, 5)", [W]), Error, "p_from_block");
    await assertRejects(() => as(db, "anon", null, "select public.history_read($1, null, -1)", [W]), Error, "p_from_block");
    await db.exec("update public.history_indexer_state set serving = false where id");
    assertEquals((await as<Any>(db, "anon", null, "select public.history_read($1) r", [W]))[0].r,
                 { version: 1, serving: false, wallet: W, scans: {}, next: null });
    await db.exec("update public.history_indexer_state set serving = true where id");
  });

  await t.step("9. generic plans stay index-bound (200,000 logs for one subject), and the first page answers within 3 s", async () => {
    await db.exec(bulk("transfers-in", W, transferTopics(B, W), 2_000_000, 200_000));
    const plan = async (sql: string) => (await db.query<{ "QUERY PLAN": string }>(sql)).rows.map((r) => r["QUERY PLAN"]).join("\n");
    await db.exec(`set plan_cache_mode = force_generic_plan;
      prepare page(text, bytea, bigint, bigint, integer, integer) as
        select l.block_number, l.log_index from public.history_logs l
         where l.scan = $1 and l.subject = $2 and l.block_number >= $3 and (l.block_number, l.log_index) < ($4, $5) and l.data is not null
         order by l.block_number desc, l.log_index desc limit $6;
      prepare omitted(text, bytea, bigint, bigint) as
        select l.block_number from public.history_logs l
         where l.scan = $1 and l.subject = $2 and l.data is null and l.block_number >= $3 and l.block_number <= $4
         order by l.block_number desc, l.log_index desc limit 101;`);
    const p = await plan(`explain execute page('transfers-in', '\\x${W.slice(2)}', 0, 9999999999, 0, 2001)`);
    const o = await plan(`explain execute omitted('transfers-in', '\\x${W.slice(2)}', 0, 9999999999)`);
    assert(/Index (Only )?Scan Backward using history_logs_pkey/.test(p) && /ROW\(block_number, log_index\) < ROW/.test(p) && !/Seq Scan/.test(p), p);
    assert(/history_logs_omitted_idx/.test(o) && !/Seq Scan/.test(o), o);
    await db.exec("deallocate all; reset plan_cache_mode;");
    const t0 = performance.now();
    const r = (await as<Any>(db, "anon", null, "select public.history_read($1) r", [W]))[0].r;
    assert(performance.now() - t0 < 3_000, "the first page within anon's 3 s");
    assert(r.next !== null);
  });

  await t.step("10. first transaction: a found block only moves earlier; none never replaces found", async () => {
    const set = async (state: string, block: number | null, source = "rpc4+rpc1") =>
      (await svc("select public.history_set_first_tx($1, $2, $3, $4, $5, $6) r", [owner, B, state, block, H, source]))[0].r;
    assertEquals(await set("found", 100), true);
    assertEquals(await set("found", 120), false);
    assertEquals(await set("found", 90), true);
    assertEquals(await set("none", null), false);
    assertEquals(await set("found", 90, "rpc2+rpc4"), true); // the same block refreshes the check
    assertEquals(await one<Any>(db, "select first_tx_state s, first_tx_block::int b, first_tx_source src from public.history_wallets where wallet = $1", [B]),
                 { s: "found", b: 90, src: "rpc2+rpc4" });
    for (const [state, block, source] of [["none", 5, "x"], ["found", H + 1, "x"], ["maybe", 1, "x"], ["found", 1, "a b"]] as const) {
      assert((await code(set(state, block as number | null, source))).startsWith("22023"), `${state} ${block} ${source}`);
    }
    // "found" without a block slips past the argument check (SQL null logic) but changes nothing: on a found row the
    // update's condition is not met (and on any other row the table's CHECK would refuse it).
    assertEquals(await set("found", null), false);
    assertEquals((await one<Any>(db, "select first_tx_block::int b from public.history_wallets where wallet = $1", [B])).b, 90);
    const read = (await as<Any>(db, "anon", null, "select public.history_read($1, null, null, null, true) r", [B]))[0].r;
    assertEquals(read.firstTx, { state: "found", block: 90 });
  });

  await t.step("11. owner functions: health, reset, housekeeping", async () => {
    const hl = (await one<Any>(db, "select public.history_health() h")).h;
    for (const k of ["now", "paused", "serving", "leaseHeldFor", "head", "secondsSinceStart", "secondsSinceRelease", "runsLastHour",
                     "stopsLastHour", "lastVersion", "scans", "wallets", "cappedSubjects", "rows", "insertedLastDay", "globalBaseline",
                     "sizes", "deadTuples", "endpoints"]) assert(k in hl, k);
    assertEquals(hl.wallets.capped, 1);
    assertEquals(hl.cappedSubjects.launchpad, 1);
    assert(hl.rows["transfers-in"] >= 200_000);
    assertEquals(hl.insertedLastDay.launchpad, 3);
    const rs = (await one<Any>(db, "select public.history_reset('transfers-in') r")).r;
    assertEquals(rs.scans, 1);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_logs where scan = 'transfers-in'")).n, 0);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallet_scans where scan = 'transfers-in' and (covered <> '{}' or log_count > 0 or holes <> '{}')")).n, 0);
    const c = await code(commit("transfers-in", 1, 0, 9, [W], []));
    assert(c.startsWith("PT412"), c); // a commit built before the reset is refused
    await commit("transfers-in", 2, 0, 9, [W], []);
    await assertRejects(() => db.query("select public.history_reset('nope')"), Error, "unknown scan");
    await db.exec(`insert into public.history_indexer_runs (owner, started_at) values (gen_random_uuid(), now() - interval '8 days')`);
    assertEquals((await one<Any>(db, "select public.history_housekeeping() n")).n, 1);
  });

  await t.step("12. deleting a profile deletes the wallet's per-wallet cache and keeps the global logs naming it", async () => {
    await db.exec(bulk("transfers-in", W, transferTopics(B, W), 3_000_000, 5));
    await as(db, "authenticated", W, "delete from public.profiles where wallet = $1", [W]);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallets where wallet = $1", [W])).n, 0);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallet_scans where wallet = $1", [W])).n, 0);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_logs where scan like 'transfers%' and subject = decode($1, 'hex')", [W.slice(2)])).n, 0);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_logs where scan = 'launchpad' and subject = decode($1, 'hex')", [W.slice(2)])).n, 1);
    const r = (await as<Any>(db, "anon", null, "select public.history_read($1) r", [W]))[0].r;
    assertEquals([r.tracked, Object.keys(r.scans).length], [false, 3]);
    // A profile row whose wallet changes (the owner, in the SQL editor; the app cannot) moves the enrolment with it.
    const E = "0x" + "e".repeat(40);
    await db.query("update public.profiles set wallet = $1 where wallet = $2", [E, B]);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallets where wallet = $1", [B])).n, 0);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_wallet_scans where wallet = $1", [E])).n, 2);
    assertEquals((await one<Any>(db, "select count(*)::int n from public.history_logs where scan like 'transfers%' and subject = decode($1, 'hex')", [B.slice(2)])).n, 0);
  });

  await t.step("13. history_state's wallets: the last 30 days only (older ones kept and served), fairest first, the limit, the refresh", async () => {
    const upsert = (w: string) => as(db, "authenticated", w,
      "insert into public.profiles (wallet) values ($1) on conflict (wallet) do update set wallet = excluded.wallet", [w]);
    const S = "0x" + "5".repeat(40), F = "0x" + "f".repeat(40), O = "0x" + "a".repeat(40), P = "0x" + "9".repeat(40);
    for (const w of [S, F, O, P]) await upsert(w);
    // S: cached history, last requested 31 days ago. The step-12 wallet: 40 days ago. O: enrolled 8 days ago, requested
    // an hour ago. P: a first transaction found (on-chain activity), requested 2 hours ago. F: new, requested now.
    await db.exec(bulk("transfers-in", S, transferTopics(B, S), 4_000_000, 3));
    await db.exec(`update public.history_wallet_scans set covered = '{[4000000,4000003)}', head_block = 4000002, log_count = 3
                    where wallet = '${S}' and scan = 'transfers-in';
                   update public.history_wallets set requested_at = now() - interval '31 days' where wallet = '${S}';
                   update public.history_wallets set requested_at = now() - interval '40 days' where wallet = '${"0x" + "e".repeat(40)}';
                   update public.history_wallets set enrolled_at = now() - interval '8 days', requested_at = now() - interval '1 hour' where wallet = '${O}';
                   update public.history_wallets set first_tx_state = 'found', first_tx_block = 5, first_tx_head = 10,
                          requested_at = now() - interval '2 hours' where wallet = '${P}';`);
    assertEquals((await svc("select public.history_lease($1, 300) r", [owner]))[0].r.ok, true);
    const state = async (max: number, after: string | null = null) =>
      (await svc(`select public.history_state($1, $2, ${after === null ? "null" : `now() - interval '${after}'`}) r`, [owner, max]))[0].r;
    // Fairest first (on-chain activity or enrolled over 7 days ago), each group most recently requested first.
    const all = await state(100);
    assertEquals(all.wallets.map((w: Any) => [w.wallet, w.deep]), [[O, false], [P, true], [F, false]]);
    assertEquals([all.active, all.skipped], [3, 0]);
    // The limit: the fairest one, and the rest counted as skipped.
    const one1 = await state(1);
    assertEquals([one1.wallets.map((w: Any) => w.wallet), one1.active, one1.skipped], [[O], 3, 2]);
    // The mid-run refresh: only wallets requested after the cursor, never counted as skipped.
    const recent = await state(100, "30 minutes");
    assertEquals([recent.wallets.map((w: Any) => w.wallet), recent.skipped], [[F], 0]);
    const lastTwoHours = await state(100, "90 minutes");
    assertEquals([lastTwoHours.wallets.map((w: Any) => w.wallet), lastTwoHours.skipped], [[O, F], 0]);
    // A wallet not requested for 30 days is no longer followed, but its cache stays and is served.
    const s = (await as<Any>(db, "anon", null, "select public.history_read($1) r", [S]))[0].r;
    assertEquals([s.tracked, s.scans["transfers-in"].covered, s.scans["transfers-in"].logs.length], [true, [[4_000_000, 4_000_002]], 3]);
  });

  await db.close();
});
