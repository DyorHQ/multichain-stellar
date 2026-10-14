// Opt-in: migration 32 on a real Postgres 17 (docker), with production-like data, before the owner applies it: commit,
// cap, read and state timings, lock behaviour under concurrent commits, a profile delete and profile upserts while
// history rows are held, and the read's generic plans. The test owns its container (started here, removed at the end) and drives it with psql inside the
// container, so it needs nothing but docker. Skipped unless HISTORY_PG=1:
//
//   HISTORY_PG=1 deno test -A --no-config --node-modules-dir=none supabase/tests/history_pg_perf_test.ts
//
// The numbers it prints go into the PR description and the owner procedure (DyorHQ/internal).
import { assert } from "jsr:@std/assert@1";

const ENABLED = Deno.env.get("HISTORY_PG") === "1";
const MIGRATIONS = new URL("../migrations/", import.meta.url);
const STUB = new URL("./supabase_stub.sql", import.meta.url);
const TRANSFER = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const CURVEBUY = "ec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455";
const wallet = (n: number) => "0x" + n.toString(16).padStart(40, "0");
const pad = (a: string) => "0x" + "0".repeat(24) + a.slice(2);
const H = 110_000_000;

async function run(cmd: string, args: string[], stdin?: string): Promise<{ code: number; out: string; err: string }> {
  const p = new Deno.Command(cmd, { args, stdin: stdin === undefined ? "null" : "piped", stdout: "piped", stderr: "piped" }).spawn();
  if (stdin !== undefined) {
    const w = p.stdin.getWriter();
    await w.write(new TextEncoder().encode(stdin));
    await w.close();
  }
  const o = await p.output();
  return { code: o.code, out: new TextDecoder().decode(o.stdout), err: new TextDecoder().decode(o.stderr) };
}

class Pg {
  constructor(readonly name: string) {}
  // Runs SQL through psql in the container; with `timing`, returns each statement's milliseconds (psql \timing).
  async sql(text: string, timing = false): Promise<{ out: string; ms: number[] }> {
    const r = await run("docker", ["exec", "-i", this.name, "psql", "-U", "postgres", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"],
                        (timing ? "\\timing on\n" : "") + text);
    if (r.code !== 0) throw new Error(`psql: ${r.err.slice(0, 500)}`);
    const ms = [...r.out.matchAll(/^Time: ([0-9.]+) ms/gm)].map((m) => Number(m[1]));
    return { out: r.out.replace(/^Time: .*$/gm, "").trim(), ms };
  }
}

const p95 = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length * 0.95)] ?? 0;
const asService = (sql: string) => `begin; set local role service_role; set local statement_timeout = '8s'; set local lock_timeout = '8s';\n${sql}\ncommit;`;
const asAnon = (sql: string) => `begin; set local role anon; set local statement_timeout = '3s'; set local lock_timeout = '8s';\n${sql}\ncommit;`;

function commitSql(owner: string, scan: string, def: number, from: number, to: number, wallets: string[] | null, logs: unknown[]) {
  const w = wallets === null ? "null" : `array[${wallets.map((x) => `'${x}'`).join(",")}]::text[]`;
  return `select public.history_commit('${owner}', '${scan}', ${def}, ${from}, ${to}, ${H}, 1700000000, ${w}, '${JSON.stringify(logs)}'::jsonb);`;
}

Deno.test({ name: "history cache on Postgres 17: timings, locks and plans", ignore: !ENABLED, sanitizeOps: false, sanitizeResources: false }, async (t) => {
  const name = `dyorhq-history-pg-${crypto.randomUUID().slice(0, 8)}`;
  const started = await run("docker", ["run", "-d", "--rm", "--name", name, "-e", "POSTGRES_HOST_AUTH_METHOD=trust", "postgres:17"]);
  assert(started.code === 0, started.err);
  const pg = new Pg(name);
  try {
    for (let k = 0; ; k++) {
      const ready = await run("docker", ["exec", name, "pg_isready", "-U", "postgres"]);
      if (ready.code === 0) break;
      assert(k < 60, "Postgres did not start");
      await new Promise((r) => setTimeout(r, 1_000));
    }
    await new Promise((r) => setTimeout(r, 2_000));
    const results: Record<string, number> = {};

    await t.step("apply the stub and migrations 01–32; load 1,000,000 logs", async () => {
      await pg.sql(await Deno.readTextFile(STUB));
      const names: string[] = [];
      for await (const e of Deno.readDir(MIGRATIONS)) if (e.name.endsWith(".sql") && !e.name.startsWith("33_")) names.push(e.name);
      for (const n of names.sort()) await pg.sql(await Deno.readTextFile(new URL(n, MIGRATIONS)));
      // 1,000 enrolled wallets (the real trigger); 800 transfers each; 200 global subjects with 1,000 logs each; one
      // wallet and one global subject at the 20,000 cap.
      await pg.sql(`insert into public.profiles (wallet) select '0x' || lpad(to_hex(g), 40, '0') from generate_series(1, 1000) g;`);
      await pg.sql(`
        insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
        select 'transfers-in', decode(lpad(to_hex(w), 40, '0'), 'hex'), 100000000 + k * 10000 + w, 0,
               decode(lpad(to_hex(w * 100000 + k), 64, '0'), 'hex'), decode(repeat('66', 20), 'hex'),
               array[decode('${TRANSFER}', 'hex'), decode(lpad('77', 64, '0'), 'hex'), decode(lpad(to_hex(w), 64, '0'), 'hex')],
               decode(repeat('00', 32), 'hex'), 32, 1700000000
          from generate_series(1, 1000) w, generate_series(1, 780) k;
        insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
        select 'transfers-in', decode(lpad(to_hex(1), 40, '0'), 'hex'), 90000000 + k, 1, decode(lpad(to_hex(k), 64, '0'), 'hex'),
               decode(repeat('66', 20), 'hex'),
               array[decode('${TRANSFER}', 'hex'), decode(lpad('77', 64, '0'), 'hex'), decode(lpad(to_hex(1), 64, '0'), 'hex')],
               decode(repeat('00', 32), 'hex'), 32, 1700000000
          from generate_series(1, 19220) k;
        update public.history_wallet_scans ws set log_count = (select count(*) from public.history_logs l
           where l.scan = ws.scan and l.subject = decode(substr(ws.wallet, 3), 'hex')), covered = '{[0,${H + 1})}', head_block = ${H}
         where ws.scan = 'transfers-in';
        insert into public.history_logs (scan, subject, block_number, log_index, tx_hash, address, topics, data, data_length, block_timestamp)
        select 'launchpad', decode(lpad(to_hex(50000 + s), 40, '0'), 'hex'), 104000000 + k * 50 + s, 0,
               decode(lpad(to_hex(s * 100000 + k), 64, '0'), 'hex'), decode(repeat('55', 20), 'hex'),
               array[decode('${CURVEBUY}', 'hex'), decode(lpad(to_hex(50000 + s), 64, '0'), 'hex')], decode(repeat('00', 32), 'hex'), 32, 1700000000
          from generate_series(1, 200) s, generate_series(1, case when s = 1 then 20000 else 1000 end) k;
        update public.history_scans set covered = '{[103542521,${H + 1})}', head_block = ${H} where id = 'launchpad';
        analyze;`);
      const n = (await pg.sql("select count(*) from public.history_logs;")).out;
      console.log(`  logs: ${n}`);
      assert(Number(n) >= 1_000_000);
    });

    const owner = crypto.randomUUID();
    await t.step("commits: 2,000 logs for 100 wallets p95 < 300 ms; a capped global subject p95 < 300 ms; the cap < 100 ms", async () => {
      await pg.sql(asService(`select public.history_lease('${owner}', 390, 'perf');`));
      const times: number[] = [];
      for (let c = 0; c < 50; c++) {
        const wallets = Array.from({ length: 100 }, (_, k) => wallet(1 + ((c * 100 + k) % 1000))).filter((w, i, a) => a.indexOf(w) === i).sort();
        const from = 105_000_000 + c * 10_000;
        const logs = Array.from({ length: 2_000 }, (_, k) => ({
          a: "0x" + "66".repeat(20), t: ["0x" + TRANSFER, pad("0x" + "77".repeat(20)), pad(wallets[k % wallets.length])], d: "0x" + "00".repeat(32), n: 32,
          b: from + k, h: "0x" + (c * 10_000 + k).toString(16).padStart(64, "0"), i: 0, s: 1_700_000_000 }));
        times.push(...(await pg.sql(asService(commitSql(owner, "transfers-in", 1, from, from + 9_999, wallets, logs)), true)).ms.slice(-2, -1));
      }
      results.commitP95 = p95(times);
      const global: number[] = [];
      for (let c = 0; c < 20; c++) {
        const from = 106_000_000 + c * 10_000;
        const logs = Array.from({ length: 50 }, (_, k) => ({ a: "0x" + "55".repeat(20), t: ["0x" + CURVEBUY, pad(wallet(50_001))], d: "0x", n: 0,
                                                             b: from + k, h: "0x" + (900_000 + c * 100 + k).toString(16).padStart(64, "0"), i: 0, s: 1_700_000_000 }));
        global.push(...(await pg.sql(asService(commitSql(owner, "launchpad", 1, from, from + 9_999, null, logs)), true)).ms.slice(-2, -1));
      }
      results.globalCappedP95 = p95(global);
      const cap = await pg.sql(`select public.history_apply_cap('${wallet(1)}', 'transfers-in');`, true);
      results.applyCap = cap.ms[0];
      console.log(`  commit p95 ${results.commitP95} ms; capped global commit p95 ${results.globalCappedP95} ms; apply_cap ${results.applyCap} ms`);
      assert(results.commitP95 < 300 && results.globalCappedP95 < 300 && results.applyCap < 100, JSON.stringify(results));
    });

    await t.step("4 concurrent commits over overlapping wallets, and a profile delete during a commit: no deadlock, waits < 1 s", async () => {
      const job = (k: number) => {
        const wallets = Array.from({ length: 100 }, (_, j) => wallet(1 + ((k * 37 + j) % 300))).filter((w, i, a) => a.indexOf(w) === i).sort();
        if (k % 2) wallets.reverse();
        const from = 107_000_000 + (k % 2) * 5_000;
        const logs = Array.from({ length: 1_000 }, (_, j) => ({ a: "0x" + "66".repeat(20), t: ["0x" + TRANSFER, pad("0x" + "77".repeat(20)), pad(wallets[j % wallets.length])],
                                                               d: "0x", n: 0, b: from + j, h: "0x" + (k * 100_000 + j).toString(16).padStart(64, "0"), i: k, s: 1_700_000_000 }));
        return pg.sql(asService(commitSql(owner, "transfers-in", 1, from, from + 9_999, [...wallets].sort(), logs)), true);
      };
      const t0 = performance.now();
      const all = await Promise.all([0, 1, 2, 3].map(job));
      const wall = performance.now() - t0;
      const del = pg.sql(`delete from public.profiles where wallet = '${wallet(5)}';`, true);
      const during = job(4);
      const [d] = await Promise.all([del, during]);
      results.concurrentMax = Math.max(...all.map((r) => r.ms.slice(-2, -1)[0]));
      results.profileDelete = d.ms[0];
      console.log(`  4 concurrent commits in ${Math.round(wall)} ms (slowest ${results.concurrentMax} ms); a profile delete ${results.profileDelete} ms`);
      assert(results.profileDelete < 1_000);
    });

    await t.step("a profile upsert never waits on history rows another transaction holds: < 1 s, the profile written", async () => {
      // ensureProfile's upsert as authenticated (PostgREST's 3 s here, 8 s in production) while history_reset(…, true)
      // holds every history_wallets row, then while a redefinition holds the wallet scan rows: a returning user and a
      // new one. Before migration 32 set lock_timeout on the trigger, the first case failed with 57014 after 3 s.
      const upsert = (w: string) => pg.sql(`begin; set local role authenticated;
        select set_config('request.jwt.claims', '{"role":"authenticated","wallet_address":"${w}"}', true);
        set local statement_timeout = '3s';
        insert into public.profiles (wallet) values ('${w}') on conflict (wallet) do update set wallet = excluded.wallet;
        commit;`, true);
      const holds = ["update public.history_wallets set first_tx_state = first_tx_state where true",
                     "update public.history_wallet_scans set covered = covered where scan in ('transfers-in', 'transfers-out')"];
      for (const [k, hold] of holds.entries()) {
        const held = pg.sql(`begin; ${hold}; select pg_sleep(3); commit;`);
        await new Promise((r) => setTimeout(r, 1_000));
        const fresh = wallet(9_000 + k);
        const times = [Math.max(...(await upsert(wallet(7))).ms), Math.max(...(await upsert(fresh)).ms)];
        await held;
        console.log(`  upserts while ${hold.split(" set ")[0].replace("update public.", "")} is held: ${times.map(Math.round).join(" ms, ")} ms`);
        assert(times.every((ms) => ms < 1_000), JSON.stringify(times));
        const rows = (await pg.sql(`select (select count(*) from public.profiles where wallet in ('${wallet(7)}', '${fresh}')),
                                           (select count(*) from public.history_wallet_scans where wallet = '${fresh}');`)).out;
        assert(rows === "2|2", rows);
      }
    });

    await t.step("reads: a 20,000-log wallet's first and later pages < 300 ms; generic plans index-bound; state < 1 s, health < 2 s", async () => {
      const first = await pg.sql(asAnon(`select public.history_read('${wallet(1)}') ->> 'next';`), true);
      results.readFirst = first.ms.slice(-2, -1)[0];
      let cursor = first.out.split("\n").filter(Boolean).pop();
      const later: number[] = [];
      while (cursor && cursor.startsWith("v1:") && later.length < 12) {
        const page = await pg.sql(asAnon(`select public.history_read('${wallet(1)}', '${cursor}') ->> 'next';`), true);
        later.push(page.ms.slice(-2, -1)[0]);
        cursor = page.out.split("\n").filter(Boolean).pop();
      }
      results.readLaterMax = Math.max(0, ...later);
      const plans = await pg.sql(`set plan_cache_mode = force_generic_plan;
        prepare page(text, bytea, bigint, bigint, integer, integer) as
          select l.block_number, l.log_index from public.history_logs l
           where l.scan = $1 and l.subject = $2 and l.block_number >= $3 and (l.block_number, l.log_index) < ($4, $5) and l.data is not null
           order by l.block_number desc, l.log_index desc limit $6;
        prepare omitted(text, bytea, bigint, bigint) as
          select l.block_number from public.history_logs l
           where l.scan = $1 and l.subject = $2 and l.data is null and l.block_number >= $3 and l.block_number <= $4
           order by l.block_number desc, l.log_index desc limit 101;
        explain (analyze, buffers) execute page('transfers-in', '\\x${wallet(1).slice(2)}', 0, 9999999999, 0, 2001);
        explain (analyze, buffers) execute omitted('transfers-in', '\\x${wallet(1).slice(2)}', 0, 9999999999);`);
      assert(/Index (Only )?Scan Backward using history_logs_pkey/.test(plans.out) && /history_logs_omitted_idx/.test(plans.out), plans.out);
      assert(!/Seq Scan/.test(plans.out), plans.out);
      const state = await pg.sql(asService(`select public.history_lease('${owner}', 390, 'perf'); select length(public.history_state('${owner}', 2000)::text);`), true);
      results.state = state.ms.slice(-2, -1)[0];
      const health = await pg.sql("select length(public.history_health()::text);", true);
      results.health = health.ms[0];
      console.log(`  read first ${results.readFirst} ms, later ≤ ${results.readLaterMax} ms; state ${results.state} ms; health ${results.health} ms`);
      console.log(`  results: ${JSON.stringify(results)}`);
      assert(results.readFirst < 300 && results.readLaterMax < 300 && results.state < 1_000 && results.health < 2_000, JSON.stringify(results));
    });
  } finally {
    await run("docker", ["rm", "-f", name]);
  }
});
