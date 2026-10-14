// The functions' environment (docs/DESIGN-stellar-parity.md §6.14) and the network policy it selects (§4.2); then the
// indexer: when it may clear its tables, and its run's order, budget and records (§6.1).
import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { setTestEnv, SPONSOR } from "../fixtures/routes/harness.ts";

setTestEnv();
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { MAINNET, networkByName, TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
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
// Whether it may clear its tables follows LITE_NETWORK and LITE_INDEXER_ALLOW_RESET (lite-indexer/jobs/reset.ts); its
// run follows the order and the budget of §6.1 (lite-indexer/index.ts).

const { fakeSql } = await import("../fixtures/routes/harness.ts");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { rpcServer } = await import("../../supabase/functions/_shared/stellar.ts");
const { deploymentKey, indexEvents } = await import("../../supabase/functions/lite-indexer/jobs/main_events.ts");
const { INDEXED_TABLES, resetAllowed } = await import("../../supabase/functions/lite-indexer/jobs/reset.ts");
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

/** indexEvents() with this cursor row in lite.indexer_cursors and RPC at `latest`; the queries it sent. */
async function indexWith(cursor: Row | null, latest: number): Promise<{ result?: unknown; error?: string; queries: string[] }> {
  const queries: string[] = [];
  replaceSql(fakeSql((q) => {
    queries.push(q);
    if (q.startsWith("select ledger, cursor, network_id from lite.indexer_cursors")) return cursor ? [cursor] : [];
    if (q.startsWith("select t from unnest")) return INDEXED_TABLES.slice(0, 4).map((t) => ({ t }));
    if (q.startsWith("truncate ") || q.startsWith("insert into lite.indexer_cursors")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  rpcAt(latest);
  try {
    return { result: await indexEvents(), queries };
  } catch (err) {
    return { error: (err as Error).message, queries };
  }
}

const truncates = (queries: string[]) => queries.filter((q) => q.startsWith("truncate "));
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
    const lagging = await withEnvAsync({ ...mainnet, LITE_INDEXER_ALLOW_RESET: allow }, () => quiet(() => indexWith({ ledger: 5_000, cursor: "c", network_id: key }, 1_000)));
    assertEquals([truncates(lagging.queries), lagging.result], [[], { events: 0, latest: 1_000, reset: false }]);
  }
  // Other contracts: refused without the flag, cleared with it.
  const refused = await withEnvAsync(mainnet, () => indexWith({ ledger: 990, cursor: "c", network_id: "other" }, 1_000));
  assertEquals(truncates(refused.queries), []);
  assert(refused.error?.includes("LITE_INDEXER_ALLOW_RESET=1"), refused.error);
  const allowed = await withEnvAsync({ ...mainnet, LITE_INDEXER_ALLOW_RESET: "1" }, () => quiet(() => indexWith({ ledger: 990, cursor: "c", network_id: "other" }, 1_000)));
  assertEquals(truncates(allowed.queries), ["truncate lite.launch_trades, lite.launches, lite.moment_collects, lite.moments"]);
  assertEquals(allowed.result, { events: 0, latest: 1_000, reset: true });
});

Deno.test("on testnet the indexer starts over after a reset or a redeploy, clearing only tables that exist", async () => {
  const testnet = { LITE_NETWORK: "testnet", STELLAR_RPC_URL: "https://rpc.invalid", LITE_INDEXER_ALLOW_RESET: undefined };
  const backwards = await withEnvAsync(testnet, () => quiet(() => indexWith({ ledger: 5_000, cursor: "c", network_id: deploymentKey(TESTNET) }, 1_000)));
  assertEquals(truncates(backwards.queries).length, 1);
  assertEquals(backwards.result, { events: 0, latest: 1_000, reset: true });
  const redeployed = await withEnvAsync(testnet, () => quiet(() => indexWith({ ledger: 990, cursor: "c", network_id: "other" }, 1_000)));
  assertEquals(truncates(redeployed.queries).length, 1);
  assert(redeployed.queries.some((q) => q.startsWith("insert into lite.indexer_cursors")), "indexes again");
  assertEquals(redeployed.result, { events: 0, latest: 1_000, reset: true });
  // The same contracts: nothing cleared.
  const same = await withEnvAsync(testnet, () => indexWith({ ledger: 990, cursor: "c", network_id: deploymentKey(TESTNET) }, 1_000));
  assertEquals([truncates(same.queries), (same.result as { reset: boolean }).reset], [[], false]);
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
