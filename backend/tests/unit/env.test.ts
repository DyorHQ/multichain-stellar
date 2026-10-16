// The functions' environment (docs/DESIGN-stellar-parity.md §6.14) and the network policy it selects (§4.2), the
// session settings included (§5.9, §6.18); then the indexer: when it may clear its tables, its run's order, budget
// and records (§6.1), and LITE_KEEPER (§6.17).
import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { setTestEnv, SPONSOR } from "../fixtures/routes/harness.ts";

setTestEnv();
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { MAINNET, networkByName, TESTNET, withDeployment } = await import("../../supabase/functions/_shared/networks.ts");
const { DEPLOYMENTS } = await import("../../supabase/functions/_shared/deployments/index.ts");

const KEEPER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(4) as any);

/** Runs `fn` with these variables set (undefined: unset), then puts every one back. */
function withEnv<T>(vars: Record<string, string | undefined>, fn: () => T): T {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, Deno.env.get(k)]));
  const apply = (vs: Record<string, string | undefined>) => {
    for (const [k, v] of Object.entries(vs)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  };
  apply(vars);
  try {
    return fn();
  } finally {
    apply(before);
  }
}

// Secrets are compared with ===, never with assertEquals, so a failure prints no key.

Deno.test("testnet without KEEPER_SECRET: the sponsor pays protocol upkeep, with one warning", () => {
  const warn = console.warn;
  const warnings: string[] = [];
  console.warn = (...args: unknown[]) => void warnings.push(args.join(" "));
  try {
    withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: undefined }, () => {
      for (let i = 0; i < 3; i++) assert(env.keeperSecret === SPONSOR.secret(), "the keeper is the sponsor");
    });
  } finally {
    console.warn = warn;
  }
  assertEquals(warnings.length, 1);
  assert(warnings[0].includes("KEEPER_SECRET is not set"));
});

Deno.test("testnet with KEEPER_SECRET: the keeper's own key", () => {
  withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: KEEPER.secret() }, () => assert(env.keeperSecret === KEEPER.secret()));
});

Deno.test("testnet with KEEPER_SECRET set: never the sponsor's key in its place; the sponsor's own key there is warned about once", () => {
  const warn = console.warn;
  const warnings: string[] = [];
  console.warn = (...args: unknown[]) => void warnings.push(args.join(" "));
  try {
    withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: KEEPER.secret() }, () => {
      for (let i = 0; i < 3; i++) assert(env.keeperSecret === KEEPER.secret(), "the keeper's own key");
    });
    assertEquals(warnings.length, 0);
    withEnv({ LITE_NETWORK: "testnet", KEEPER_SECRET: SPONSOR.secret() }, () => {
      for (let i = 0; i < 3; i++) assert(env.keeperSecret === SPONSOR.secret());
    });
  } finally {
    console.warn = warn;
  }
  assertEquals(warnings.length, 1);
  assert(warnings[0].includes("share one sequence number") && !warnings[0].includes(SPONSOR.secret()), "a warning that names no key");
});

Deno.test("the database is the lite_api role's LITE_DB_URL only: without it nothing connects, SUPABASE_DB_URL or not", () => {
  const lite = "postgresql://lite_api@127.0.0.1:55096/lite";
  withEnv({ LITE_DB_URL: undefined, SUPABASE_DB_URL: "postgresql://postgres@127.0.0.1:55096/postgres" }, () => {
    assertThrows(() => env.dbUrl, Error, "LITE_DB_URL is not set");
  });
  withEnv({ LITE_DB_URL: lite, SUPABASE_DB_URL: "postgresql://postgres@127.0.0.1:55096/postgres" }, () => assert(env.dbUrl === lite));
});

Deno.test("mainnet needs a keeper key of its own", () => {
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: undefined }, () => {
    assertThrows(() => env.keeperSecret, Error, "KEEPER_SECRET is not set");
  });
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: SPONSOR.secret() }, () => {
    assertThrows(() => env.keeperSecret, Error, "must differ from SPONSOR_SECRET");
  });
  withEnv({ LITE_NETWORK: "mainnet", KEEPER_SECRET: KEEPER.secret() }, () => assert(env.keeperSecret === KEEPER.secret()));
});

Deno.test("an unknown LITE_NETWORK throws instead of meaning testnet", () => {
  for (const name of ["Testnet", "mainnett", "public", "futurenet"]) {
    withEnv({ LITE_NETWORK: name }, () => assertThrows(() => env.network, Error, `Unknown network "${name}"`));
    assertThrows(() => networkByName(name), Error, "testnet or mainnet");
  }
  withEnv({ LITE_NETWORK: undefined }, () => assertEquals(env.network.name, "testnet"));
  withEnv({ LITE_NETWORK: "mainnet" }, () => assertEquals(env.network.name, "mainnet"));
});

Deno.test("LITE_ACTIVATION: friendbot by default on testnet, sponsored to rehearse mainnet; mainnet is always sponsored", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: undefined }, () => assertEquals(env.network.activation, "friendbot"));
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: "sponsored" }, () => assertEquals(env.network.activation, "sponsored"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_ACTIVATION: undefined }, () => assertEquals(env.network.activation, "sponsored"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_ACTIVATION: "friendbot" }, () => assertThrows(() => env.network, Error, "always sponsored"));
  withEnv({ LITE_NETWORK: "testnet", LITE_ACTIVATION: "free" }, () => assertThrows(() => env.network, Error, "friendbot or sponsored"));
});

Deno.test("LITE_DEPLOYMENT picks the contracts: the network's own by default, never another network's", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_DEPLOYMENT: undefined }, () => {
    const net = env.network;
    assertEquals(net.deployment?.id, "testnet");
    assertEquals([net.contracts.launchpad, net.contracts.moments], [DEPLOYMENTS.testnet!.launchpad, DEPLOYMENTS.testnet!.moments]);
  });
  withEnv({ LITE_NETWORK: "testnet", LITE_DEPLOYMENT: "staging" }, () => assertThrows(() => env.network, Error, 'Unknown deployment "staging"'));
  withEnv({ LITE_NETWORK: "mainnet", LITE_DEPLOYMENT: undefined }, () => {
    assertEquals([env.network.deployment, env.network.contracts.launchpad, env.network.contracts.moments], [null, null, null]);
  });
  withEnv({ LITE_NETWORK: "mainnet", LITE_DEPLOYMENT: "testnet" }, () => assertThrows(() => env.network, Error, "is on testnet, not mainnet"));
  // The testnet registry entry and the TESTNET constant (gen-pinned.ts, gen-vectors.ts) agree.
  assertEquals(TESTNET.contracts.launchpad, DEPLOYMENTS.testnet!.launchpad);
});

Deno.test("sponsorship limits: §6.14 defaults per network, and a number when set", () => {
  const unset = {
    LITE_SPONSOR_ACTIVATIONS_PER_DAY: undefined,
    LITE_SPONSOR_STARTERS_PER_DAY: undefined,
    LITE_SPONSOR_PER_IP_PER_DAY: undefined,
    LITE_SPONSOR_DAILY_FEE_CAP: undefined,
    LITE_SPONSOR_MAX_ATTEMPTS: undefined,
    LITE_SPONSOR_MIN_XLM: undefined,
    LITE_KEEPER_MIN_XLM: undefined,
  };
  const read = () => [env.sponsorActivationsPerDay, env.sponsorStartersPerDay, env.sponsorPerIpPerDay, env.sponsorDailyFeeCap, env.sponsorMaxAttempts, env.sponsorMinXlm, env.keeperMinXlm];
  withEnv({ ...unset, LITE_NETWORK: "testnet" }, () => assertEquals(read(), [1000, 1000, 5, 1_000_000_000n, 3, 100, 100]));
  withEnv({ ...unset, LITE_NETWORK: "mainnet" }, () => assertEquals(read(), [200, 200, 3, 200_000_000n, 3, 100, 100]));
  withEnv({ ...unset, LITE_SPONSOR_PER_IP_PER_DAY: "7" }, () => assertEquals(env.sponsorPerIpPerDay, 7));
  withEnv({ ...unset, LITE_SPONSOR_PER_IP_PER_DAY: "lots" }, () => assertThrows(() => env.sponsorPerIpPerDay, Error, "whole number"));
});

Deno.test("the local stack's settings are refused off testnet", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_LOCAL_STORAGE_DIR: "/tmp/lite-media", LITE_PUBLIC_BASE: "http://127.0.0.1:20200/lite" }, () => {
    assertEquals([env.localStorageDir, env.publicBase], ["/tmp/lite-media", "http://127.0.0.1:20200/lite"]);
  });
  withEnv({ LITE_NETWORK: "mainnet", LITE_LOCAL_STORAGE_DIR: "/tmp/lite-media" }, () => assertThrows(() => env.localStorageDir, Error, "local testnet stack only"));
  withEnv({ LITE_NETWORK: "mainnet", LITE_PUBLIC_BASE: "http://127.0.0.1" }, () => assertThrows(() => env.publicBase, Error, "local testnet stack only"));
});

/** Runs `fn` and answers what it warned. */
function warnings(fn: () => void): string[] {
  const warn = console.warn;
  const seen: string[] = [];
  console.warn = (...args: unknown[]) => void seen.push(args.join(" "));
  try {
    fn();
  } finally {
    console.warn = warn;
  }
  return seen;
}

Deno.test("session lifetimes (§5.9, §6.14): an hour and 30 days; testnet QA overrides them, down to 60 and 120 s", () => {
  const unset = { LITE_JWT_TTL_S: undefined, LITE_REFRESH_TTL_S: undefined };
  for (const net of ["testnet", "mainnet"]) {
    withEnv({ ...unset, LITE_NETWORK: net }, () => assertEquals([env.jwtTtlS, env.refreshTtlS], [3600, 2_592_000]));
  }
  withEnv({ LITE_NETWORK: "testnet", LITE_JWT_TTL_S: "120", LITE_REFRESH_TTL_S: "600" }, () => assertEquals([env.jwtTtlS, env.refreshTtlS], [120, 600]));
  withEnv({ LITE_NETWORK: "testnet", LITE_JWT_TTL_S: "60", LITE_REFRESH_TTL_S: "120" }, () => assertEquals([env.jwtTtlS, env.refreshTtlS], [60, 120]));
  for (const v of ["59", "0", "-5", "90.5", "an hour"]) {
    withEnv({ LITE_NETWORK: "testnet", LITE_JWT_TTL_S: v }, () => assertThrows(() => env.jwtTtlS, Error, "LITE_JWT_TTL_S must be a whole number of seconds, at least 60"));
  }
  withEnv({ LITE_NETWORK: "testnet", LITE_REFRESH_TTL_S: "119" }, () => assertThrows(() => env.refreshTtlS, Error, "at least 120"));
});

Deno.test("mainnet ignores the session overrides, with one warning per variable", () => {
  const seen = warnings(() =>
    withEnv({ LITE_NETWORK: "mainnet", LITE_JWT_TTL_S: "120", LITE_REFRESH_TTL_S: "5" }, () => {
      for (let i = 0; i < 3; i++) assertEquals([env.jwtTtlS, env.refreshTtlS], [3600, 2_592_000]);
    })
  );
  assertEquals(seen, ["LITE_JWT_TTL_S is set but ignored: it applies on testnet only.", "LITE_REFRESH_TTL_S is set but ignored: it applies on testnet only."]);
});

Deno.test("the invite gate: none on testnet, always on mainnet; LITE_INVITE_REQUIRED sets it on testnet only", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_INVITE_REQUIRED: undefined }, () => assertEquals(env.inviteRequired, false));
  withEnv({ LITE_NETWORK: "mainnet", LITE_INVITE_REQUIRED: undefined }, () => assertEquals(env.inviteRequired, true));
  for (const [v, required] of [["1", true], ["true", true], ["0", false], ["false", false]] as const) {
    withEnv({ LITE_NETWORK: "testnet", LITE_INVITE_REQUIRED: v }, () => assertEquals(env.inviteRequired, required, v));
  }
  withEnv({ LITE_NETWORK: "testnet", LITE_INVITE_REQUIRED: "yes" }, () => assertThrows(() => env.inviteRequired, Error, "LITE_INVITE_REQUIRED is 1 or 0"));
  const seen = warnings(() => withEnv({ LITE_NETWORK: "mainnet", LITE_INVITE_REQUIRED: "0" }, () => assertEquals(env.inviteRequired, true)));
  assertEquals(seen, ["LITE_INVITE_REQUIRED is set but ignored: it applies on testnet only."]);
});

Deno.test("LITE_KEEPER: on unless set off", () => {
  withEnv({ LITE_KEEPER: undefined }, () => assertEquals(env.keeperEnabled, true));
  withEnv({ LITE_KEEPER: "on" }, () => assertEquals(env.keeperEnabled, true));
  withEnv({ LITE_KEEPER: "off" }, () => assertEquals(env.keeperEnabled, false));
  withEnv({ LITE_KEEPER: "0" }, () => assertThrows(() => env.keeperEnabled, Error, "LITE_KEEPER is on or off"));
});

Deno.test("the sponsor's old fee knobs are gone: the cap is the network's maxFee", () => {
  withEnv({ LITE_NETWORK: "testnet", LITE_MAX_FEE_PER_TX: "1", LITE_DAILY_FEE_BUDGET: "1" }, () => {
    assertEquals([env.maxFeePerTx, env.dailyFeeBudget], [30_000_000n, 500_000_000n]);
  });
  assert(!("soroswapApiKey" in env) && !("monadRelayerKey" in env));
});

Deno.test("fee policy (§4.2): testnet's values, mainnet's copies", () => {
  const stroops = (p: typeof TESTNET.feePolicy) => Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v.toString()]));
  const expected = {
    maxFee: "30000000",
    maxInclusionPerOp: "200000",
    starterInnerFeeMax: "1000000",
    activationMaxFee: "100000",
    starterThreshold: "500000",
    starterMinXlmOut: "10000000",
    fundingFloor: "1000000",
  };
  assertEquals(stroops(TESTNET.feePolicy), expected);
  assertEquals(stroops(MAINNET.feePolicy), expected);
  assertEquals(TESTNET.ttlPolicy, { thresholdDays: 10, extendToDays: 30, perRun: 400, idleDays: 90 });
  assertEquals(MAINNET.ttlPolicy, { thresholdDays: 30, extendToDays: 150, perRun: 400, idleDays: 90 });
  assertEquals([TESTNET.phoneRpcUrl, TESTNET.explorer, TESTNET.faucet], ["https://soroban-testnet.stellar.org", "https://stellar.expert/explorer/testnet", { amount: "10000" }]);
  assertEquals([MAINNET.faucet, MAINNET.pricing.kind, MAINNET.pricing.note, MAINNET.explorer], [null, "market", null, "https://stellar.expert/explorer/public"]);
  assertEquals(TESTNET.reference, { provider: "Kraken", markets: { XLM: "XLMUSD", USDC: "USDCUSD" } });
  for (const net of [TESTNET, MAINNET]) {
    for (const a of net.assets) assert(a.priceRef === "XLM" || a.priceRef === "USDC", `${net.name} ${a.id} priceRef`);
    for (const code of net.assets.map((a) => a.code)) assert(net.reservedSymbols.includes(code), `${code} reserved`);
  }
  assertEquals(TESTNET.assets.filter((a) => !a.listed).map((a) => a.id), ["BUSDC"]);
});

// ------------------------------------------------------------------------------------------------ the indexer
// Whether it may clear its tables follows LITE_NETWORK and LITE_INDEXER_ALLOW_RESET (lite-indexer/jobs/reset.ts), as
// its main_events job runs it: both generations, each from its own cursor (lite-indexer/v2_events.ts
// indexGenerations); its run follows the order and the budget of §6.1 (lite-indexer/index.ts).

const { fakeSql } = await import("../fixtures/routes/harness.ts");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { rpcServer } = await import("../../supabase/functions/_shared/stellar.ts");
const { deploymentKey } = await import("../../supabase/functions/lite-indexer/jobs/main_events.ts");
const { indexGenerations, V1_CURSOR, V2_CURSOR, v2Key } = await import("../../supabase/functions/lite-indexer/v2_events.ts");
const { resetAllowed } = await import("../../supabase/functions/lite-indexer/jobs/reset.ts");
const { BUDGET_MS, JOBS, LATE_MS, runJobs } = await import("../../supabase/functions/lite-indexer/index.ts");

type Row = Record<string, unknown>;

async function withEnvAsync<T>(vars: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, Deno.env.get(k)]));
  const apply = (vs: Record<string, string | undefined>) => {
    for (const [k, v] of Object.entries(vs)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  };
  apply(vars);
  try {
    return await fn();
  } finally {
    apply(before);
  }
}

/** Stellar RPC at ledger `latest`, with no events: the API's RPC client answers without a network. */
function rpcAt(latest: number): void {
  const server = rpcServer() as any;
  server.getLatestLedger = () => Promise.resolve({ id: "l", protocolVersion: 23, sequence: latest });
  server.getEvents = () => Promise.resolve({ events: [], latestLedger: latest, cursor: "" });
}

/** The main_events job (indexGenerations) with these rows in lite.indexer_cursors, on a database with contracts v2's
 *  tables, and RPC at `latest`; the queries it sent. */
async function indexWith(cursors: Row[], latest: number): Promise<{ result?: Row; error?: string; queries: string[] }> {
  const queries: string[] = [];
  replaceSql(fakeSql((q, p) => {
    queries.push(q);
    if (q === "select to_regclass(?) is not null as present") return [{ present: true }];
    if (q.startsWith("select name, ledger, cursor, network_id from lite.indexer_cursors")) return cursors;
    if (q.startsWith("select t from unnest")) return (p[0] as string[]).slice(0, 4).map((t) => ({ t }));
    if (/^(truncate|delete from|insert into lite\.indexer_cursors) /.test(q)) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  rpcAt(latest);
  try {
    return { result: await indexGenerations() as unknown as Row, queries };
  } catch (err) {
    return { error: (err as Error).message, queries };
  }
}

const v1Cursor = (ledger: number, key: string): Row => ({ name: V1_CURSOR, ledger, cursor: "c", network_id: key });
const truncates = (queries: string[]) => queries.filter((q) => q.startsWith("truncate "));
const deletes = (queries: string[]) => queries.filter((q) => q.startsWith("delete from "));
/** What another v1 deployment clears: v1's rows only, v2's stay (v2_events.ts clearV1). */
const V1_ROWS_CLEARED = [
  "delete from lite.launches where generation = 1",
  "delete from lite.moments where generation = 1",
  "delete from lite.watch_groups g where not exists (select 1 from lite.watch_contracts w where w.group_id = g.id)",
];
const quiet = async <T>(fn: () => Promise<T>): Promise<T> => {
  const warn = console.warn;
  console.warn = () => {};
  try {
    return await fn();
  } finally {
    console.warn = warn;
  }
};

Deno.test("indexer resets: testnet for either reason; mainnet only for new contracts, and only when allowed", () => {
  for (const allow of [false, true]) {
    assert(resetAllowed("ledger_backwards", "testnet", allow));
    assert(resetAllowed("new_deployment", "testnet", allow));
    assert(!resetAllowed("ledger_backwards", "mainnet", allow));
  }
  assert(!resetAllowed("new_deployment", "mainnet", false));
  assert(resetAllowed("new_deployment", "mainnet", true));
});

Deno.test("the indexer never wipes off testnet without LITE_INDEXER_ALLOW_RESET", async () => {
  const mainnet = { LITE_NETWORK: "mainnet", STELLAR_RPC_URL: "https://rpc.invalid", LITE_INDEXER_ALLOW_RESET: undefined };
  const key = deploymentKey(MAINNET);
  // An RPC behind the indexed ledger is waited for, flag or not.
  for (const allow of [undefined, "1"]) {
    const lagging = await withEnvAsync({ ...mainnet, LITE_INDEXER_ALLOW_RESET: allow }, () => quiet(() => indexWith([v1Cursor(5_000, key)], 1_000)));
    assertEquals([truncates(lagging.queries), deletes(lagging.queries)], [[], []]);
    assertEquals(lagging.result, { v1: { skipped: "rpc behind" }, v2: { skipped: "rpc behind" }, latest: 1_000, reset: false });
  }
  // Other v1 contracts: refused without the flag; with it, v1's rows go and v2's stay.
  const refused = await withEnvAsync(mainnet, () => indexWith([v1Cursor(990, "other")], 1_000));
  assertEquals([truncates(refused.queries), deletes(refused.queries)], [[], []]);
  assert(refused.error?.includes("LITE_INDEXER_ALLOW_RESET=1"), refused.error);
  const allowed = await withEnvAsync({ ...mainnet, LITE_INDEXER_ALLOW_RESET: "1" }, () => quiet(() => indexWith([v1Cursor(990, "other")], 1_000)));
  assertEquals([truncates(allowed.queries), deletes(allowed.queries)], [[], V1_ROWS_CLEARED]);
  assertEquals(allowed.result, { v1: { events: 0, restarted: true }, v2: { skipped: "no v2 deployment" }, latest: 1_000, reset: false });
});

Deno.test("on testnet the indexer starts over after a reset (both generations) or a v1 redeploy (v1's rows only)", async () => {
  const testnet = { LITE_NETWORK: "testnet", STELLAR_RPC_URL: "https://rpc.invalid", LITE_INDEXER_ALLOW_RESET: undefined };
  const v1Key = deploymentKey(TESTNET);
  const v2Cursor = (ledger: number): Row => ({ name: V2_CURSOR, ledger, cursor: "c2", network_id: v2Key(withDeployment(TESTNET, "testnet")) });
  // The ledger went backwards: every indexed table of both generations is cleared, the ones that exist only.
  const backwards = await withEnvAsync(testnet, () => quiet(() => indexWith([v1Cursor(5_000, v1Key), v2Cursor(5_000)], 1_000)));
  assertEquals(truncates(backwards.queries).length, 2);
  assertEquals(backwards.result, { v1: { skipped: "reset" }, v2: { skipped: "reset" }, latest: 1_000, reset: true });
  // Other v1 contracts: v1's rows go, v2's stay, and both read on.
  const redeployed = await withEnvAsync(testnet, () => quiet(() => indexWith([v1Cursor(990, "other"), v2Cursor(990)], 1_000)));
  assertEquals([truncates(redeployed.queries), deletes(redeployed.queries)], [[], V1_ROWS_CLEARED]);
  assert(redeployed.queries.some((q) => q.startsWith("insert into lite.indexer_cursors")), "indexes again");
  assertEquals(redeployed.result, { v1: { events: 0, restarted: true }, v2: { events: 0, restarted: false }, latest: 1_000, reset: false });
  // The same contracts: nothing cleared.
  const same = await withEnvAsync(testnet, () => indexWith([v1Cursor(990, v1Key), v2Cursor(990)], 1_000));
  assertEquals([truncates(same.queries), deletes(same.queries), same.result?.reset], [[], [], false]);
});

Deno.test("indexer jobs run in §6.1's order; the ones after bridges are late", () => {
  assertEquals(JOBS.map((j) => j.name), ["main_events", "watch", "refprices", "settle", "graduate", "bridges", "ttl", "reconcile", "earn", "ops", "purge"]);
  assertEquals(JOBS.filter((j) => j.late).map((j) => j.name), ["ttl", "reconcile", "earn", "ops", "purge"]);
  assertEquals(JOBS.filter((j) => j.every).map((j) => [j.name, j.every! / 60_000]), [["reconcile", 10], ["earn", 10], ["ops", 10], ["purge", 1440]]);
});

/** A clock the jobs move, from midnight UTC (the start of every period). */
function clock(): { now: () => number; advance: (ms: number) => void } {
  let t = Date.UTC(2026, 9, 14);
  return { now: () => t, advance: (ms) => void (t += ms) };
}

/** The database behind runJobs: job_runs exists when `recording`, its last runs are `last`; inserts are collected. */
function jobRunsDb(recording: boolean, last: Record<string, Date> = {}): unknown[][] {
  const inserted: unknown[][] = [];
  replaceSql(fakeSql((q, params) => {
    if (q.startsWith("select to_regclass(?) is not null as present")) return [{ present: recording }];
    if (q.startsWith("select max(started_at) as last from lite.job_runs")) return [{ last: last[params[0] as string] ?? null }];
    if (q.startsWith("insert into lite.job_runs")) {
      inserted.push(params);
      return [];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  return inserted;
}

Deno.test("the indexer's keeper jobs are graduation, the bridge relay and TTL upkeep", () => {
  assertEquals(JOBS.filter((j) => j.keeper).map((j) => j.name), ["graduate", "bridges", "ttl"]);
});

Deno.test("LITE_KEEPER=off: the indexer skips every keeper job and runs the rest", async () => {
  const run = async (keeper: string | undefined) => {
    jobRunsDb(false);
    const ran: string[] = [];
    const job = (name: string, signs = false) => ({ name, keeper: signs, run: () => (ran.push(name), Promise.resolve(name)) });
    const out = await withEnvAsync({ LITE_KEEPER: keeper }, () => runJobs([job("index"), job("graduate", true), job("settle"), job("ttl", true)], clock().now));
    return { ran, out };
  };
  const off = await run("off");
  assertEquals(off.ran, ["index", "settle"]);
  assertEquals([off.out.graduate, off.out.ttl], [{ skipped: "LITE_KEEPER=off" }, { skipped: "LITE_KEEPER=off" }]);
  assertEquals((await run(undefined)).ran, ["index", "graduate", "settle", "ttl"]);
  assertEquals((await run("on")).ran, ["index", "graduate", "settle", "ttl"]);
});

Deno.test("indexer budget: nothing starts after 45 s, nothing late after 40 s; a job not written yet is skipped", async () => {
  jobRunsDb(false);
  const c = clock();
  const ran: string[] = [];
  const job = (name: string, ms: number, late = false) => ({ name, late, run: () => (ran.push(name), c.advance(ms), Promise.resolve(name)) });
  const out = await runJobs([job("a", LATE_MS + 1_000), { name: "unwritten", run: null }, job("b", 0, true), job("c", 4_000), job("d", 0)], c.now);
  assertEquals(ran, ["a", "c"]);
  assertEquals(out, { a: "a", b: { skipped: "out of time after 41 s" }, c: "c", d: { skipped: "out of time after 45 s" }, ms: BUDGET_MS });
});

Deno.test("indexer cadence before migration 05: a periodic job runs in its period's first minute", async () => {
  jobRunsDb(false);
  const c = clock();
  const periodic = [{ name: "p", every: 10 * 60_000, run: () => Promise.resolve("ran") }];
  assertEquals((await runJobs(periodic, c.now)).p, "ran");
  c.advance(2 * 60_000);
  assertEquals((await runJobs(periodic, c.now)).p, undefined);
  c.advance(8 * 60_000);
  assertEquals((await runJobs(periodic, c.now)).p, "ran");
});

Deno.test("indexer with lite.job_runs: each run is recorded; a periodic job waits for its period", async () => {
  const c = clock();
  const recent = { p: new Date(c.now() - 5 * 60_000), q: new Date(c.now() - 9.6 * 60_000) };
  const inserted = jobRunsDb(true, recent);
  const out = await quiet(() =>
    runJobs([
      { name: "ok", run: () => Promise.resolve({ n: 2n }) },
      { name: "fails", run: () => Promise.reject(new Error("RPC down")) },
      { name: "p", every: 10 * 60_000, run: () => Promise.resolve("p") },
      { name: "q", every: 10 * 60_000, run: () => Promise.resolve("q") },
    ], c.now)
  );
  assertEquals([out.ok, out.fails, out.p, out.q], [{ n: 2n }, { error: "RPC down" }, undefined, "q"]);
  assertEquals(inserted.map(([job, , , ok, result]) => [job, ok, result]), [["ok", true, { n: "2" }], ["fails", false, { error: "RPC down" }], ["q", true, "q"]]);
});

Deno.test("LITE_PRIVY_WALLETS: on by default on testnet, off on mainnet; anything but on or off reads as off, with one warning", () => {
  const warn = console.warn;
  const warnings: string[] = [];
  console.warn = (...args: unknown[]) => void warnings.push(args.join(" "));
  try {
    const read = (network: string, setting: string | undefined) =>
      withEnv({ LITE_NETWORK: network, LITE_PRIVY_WALLETS: setting }, () => env.privyWallets);
    assertEquals([read("testnet", undefined), read("mainnet", undefined)], [true, false]);
    assertEquals([read("mainnet", "on"), read("testnet", "off")], [true, false]);
    assertEquals([read("testnet", "yes"), read("testnet", "ON"), read("mainnet", "1")], [false, false, false]);
    assertEquals(warnings, ["LITE_PRIVY_WALLETS is on or off: read as off."]);
  } finally {
    console.warn = warn;
  }
});
