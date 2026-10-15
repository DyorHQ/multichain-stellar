// Earn (docs/DESIGN-stellar-parity.md §6.10, §12.5):
// - pool status: every value Blend v2 defines (0–1 active, 2–3 on ice, 4–5 frozen, 6 setup frozen), anything else
//   frozen;
// - markets: registry reserves only, in the pool's order, read at most a minute ago; USD at the reference price through
//   priceRef (Blend's test USDC as USDC), to the cent, and null without a price; free liquidity never negative;
// - positions: supply and collateral; the owner's view reads the pools now and adds DyorHQ's record, earned = supplied
//   + withdrawn − deposited from the account's successful earn transactions, complete only with a recorded deposit;
//   the public view reads the pools as markets do and leaves the record null;
// - history: week when absent, week or month, else 400; one market's snapshots after the range's start; the last
//   snapshot of each hour, oldest first;
// - snapshots: every registry reserve read now, one row each; a pool that can't be read, or a rate that isn't a number,
//   named in the result; old snapshots deleted; the job waits for migration 08;
// - plans: a deposit and a withdrawal are Blend submits from, spent by and paid to the user, which the verifier's call
//   rule accepts; a withdrawal asks for at most the account's supply;
// - routes: markets and history answer with no token (any token ignored), positions answer the public view for
//   ?address= with no token, and the build needs a session.
import { Account, Address, nativeToScVal, Operation, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, goOffline, OTHER, type Row, routeRows, setTestEnv, SPONSOR, USER, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { contractAllowlist, TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { verifyTransaction } = await import("../../supabase/functions/_shared/verify.ts");
const e = await import("../../supabase/functions/_shared/earn.ts");
const { earn: earnJob } = await import("../../supabase/functions/lite-indexer/jobs/earn.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

type ReserveFigures = import("../../supabase/functions/_shared/earn.ts").ReserveFigures;
type Supplied = import("../../supabase/functions/_shared/earn.ts").Supplied;
type LoggedFlow = import("../../supabase/functions/_shared/earn.ts").LoggedFlow;

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const NOW = Date.UTC(2026, 9, 14, 9, 41);
const POOL = TESTNET.contracts.blendPools[0];
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!;
const BUSDC = TESTNET.assets.find((a) => a.id === "BUSDC")!;
/** Blend's test wETH: a reserve of the pool, not a registry asset. */
const WETH = "CAZAQB3D7KSLSNOSQKYD2V4JP5V2Y3B4RDJZRLBFCCIXDCTE3WHSY3UE";
const ME = USER.publicKey();

// ------------------------------------------------------------------------------------------------ stand-ins

const figures = (o: Partial<ReserveFigures> = {}): ReserveFigures => ({
  decimals: 7,
  supplyApy: 0.031,
  borrowApy: 0.054,
  utilization: 0.61,
  supplied: 182_345_671_200_000n,
  borrowed: 111_230_859_432_000n,
  ...o,
});

interface Pools {
  status: number;
  reserves: Map<string, ReserveFigures>;
  /** What the account supplies, by asset (nothing to the other reserves). */
  supplied: Map<string, Supplied>;
  /** Every read: [what, pool, max age (ms)]. */
  reads: [string, string, number][];
  /** Reads of these pools fail, as RPC does when it's down. */
  failing: Set<string>;
}

function pools(init: Partial<Pools> = {}): Pools {
  const p: Pools = {
    status: 0,
    reserves: new Map([[XLM.contract, figures()], [WETH, figures({ decimals: 7 })], [BUSDC.contract, figures({ supplyApy: 0.048, borrowApy: 0.071, utilization: 0.72, supplied: 12_033_445_000_000n, borrowed: 8_664_080_400_000n })]]),
    supplied: new Map(),
    reads: [],
    failing: new Set(),
    ...init,
  };
  const state = () => ({ status: p.status, reserves: p.reserves });
  e.replacePools({
    read(id, maxAgeMs) {
      p.reads.push(["read", id, maxAgeMs]);
      return p.failing.has(id) ? Promise.reject(new Error("Stellar RPC is down")) : Promise.resolve(state());
    },
    supplies(id, account, maxAgeMs) {
      p.reads.push([`supplies ${account}`, id, maxAgeMs]);
      if (p.failing.has(id)) return Promise.reject(new Error("Stellar RPC is down"));
      const supplied = new Map([...p.reserves.keys()].map((a): [string, Supplied] => [a, p.supplied.get(a) ?? { supply: 0n, collateral: 0n }]));
      return Promise.resolve({ state: state(), supplied });
    },
  });
  return p;
}

interface Db {
  quotes: Row[];
  /** lite.tx_log rows the positions' read answers (successful earn transactions of the account asked for). */
  flows: LoggedFlow[];
  snapshots: Row[];
  migrated: boolean;
  asked: [string, unknown[]][];
}

function database(init: Partial<Db> = {}): Db {
  const db: Db = { quotes: [], flows: [], snapshots: [], migrated: true, asked: [], ...init };
  replaceSql(fakeSql((q, params) => {
    db.asked.push([q, params]);
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") return db.quotes;
    if (q === "select kind, intent from lite.tx_log where address = ? and kind in ('earn_deposit', 'earn_withdraw') and status = 'success'") {
      return params[0] === ME ? db.flows as unknown as Row[] : [];
    }
    if (q === "select taken_at, supply_apy, utilization from lite.earn_snapshots where pool = ? and asset = ? and taken_at > ? order by taken_at") {
      return db.snapshots;
    }
    if (q.startsWith("insert into lite.earn_snapshots") || q.startsWith("delete from lite.earn_snapshots")) return [];
    if (q === "select to_regclass(?) is not null as present") return [{ present: db.migrated }];
    return routeRows(q, params);
  }));
  forgetReferencePrices();
  return db;
}

const quotes = (at = NOW): Row[] => [
  { ref: "XLM", usd: "0.1901", source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date(at) },
  { ref: "USDC", usd: "0.9999", source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date(at) },
];

const submitCall = (asset: string, amount: string): LoggedFlow["intent"] => ({ kind: "", summary: "", spend: {}, calls: [{ contract: POOL.id, fn: "submit" }], display: { asset, amount } });
const deposit = (asset: string, amount: string): LoggedFlow => ({ kind: "earn_deposit", intent: { ...submitCall(asset, amount)!, kind: "earn_deposit", spend: { [asset]: amount } } });
const withdrawal = (asset: string, amount: string): LoggedFlow => ({ kind: "earn_withdraw", intent: { ...submitCall(asset, amount)!, kind: "earn_withdraw", receive: { [asset]: amount } } });

async function refusal(p: Promise<unknown>): Promise<[number, string]> {
  const err = await p.then(() => null, (x) => x);
  assert(err instanceof ApiError, `expected a refusal, got ${err}`);
  return [err.status, err.code];
}

function get(path: string, token?: string): Promise<Response> {
  return handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} }));
}

// ------------------------------------------------------------------------------------------------ pool status

Deno.test("pool status: Blend's 0–1 active, 2–3 on ice, 4–5 frozen, 6 (setup) frozen; anything else frozen", () => {
  const expected: [number, string][] = [[0, "active"], [1, "active"], [2, "on_ice"], [3, "on_ice"], [4, "frozen"], [5, "frozen"], [6, "frozen"]];
  for (const [status, app] of expected) assertEquals(e.poolStatusOf(status), app, `status ${status}`);
  for (const status of [7, 8, 255, -1, 1.5, NaN]) assertEquals(e.poolStatusOf(status), "frozen", `status ${status}`);
});

Deno.test("markets carry the pool's status, mapped", async () => {
  database({ quotes: quotes() });
  for (const [status, app] of [[1, "active"], [3, "on_ice"], [5, "frozen"], [6, "frozen"]] as const) {
    pools({ status });
    const m = await e.markets(TESTNET, NOW);
    assertEquals(m.markets.map((r) => r.poolStatus), [app, app], `status ${status}`);
  }
});

// ------------------------------------------------------------------------------------------------ markets

Deno.test("markets: registry reserves only, in the pool's order, read at most a minute ago; USD at the reference price, to the cent", async () => {
  database({ quotes: quotes() });
  const p = pools();
  const m = await e.markets(TESTNET, NOW);
  assertEquals(m.note, "Testnet rates are set by test activity, not real markets.");
  assertEquals(m.markets.map((r) => [r.asset, r.code]), [[XLM.contract, "XLM"], [BUSDC.contract, "USDC"]]);
  assertEquals(p.reads, [["read", POOL.id, MINUTE]]);
  const [xlm, busdc] = m.markets;
  assertEquals(xlm, {
    pool: POOL.id,
    poolName: "Blend TestnetV2",
    asset: XLM.contract,
    code: "XLM",
    decimals: 7,
    supplyApy: 0.031,
    borrowApy: 0.054,
    utilization: 0.61,
    totalSupplied: 18234567.12,
    note: "Test XLM",
    // 18,234,567.12 XLM × $0.1901, and (18,234,567.12 − 11,123,085.9432) × $0.1901.
    totalSuppliedUsd: 3466391.21,
    freeLiquidityUsd: 1351892.57,
    priceUsd: 0.1901,
    poolStatus: "active",
  });
  // Blend's test USDC is valued as USDC.
  assertEquals([busdc.priceUsd, busdc.totalSuppliedUsd, busdc.freeLiquidityUsd], [0.9999, 1203224.17, 336902.77]);
});

Deno.test("markets: without a reference price every USD figure is null, never 0 or a constant", async () => {
  database();
  pools();
  for (const r of (await e.markets(TESTNET, NOW)).markets) {
    assertEquals([r.priceUsd, r.totalSuppliedUsd, r.freeLiquidityUsd], [null, null, null], r.code);
    assert(r.supplyApy > 0 && r.totalSupplied > 0);
  }
  // A quote older than 24 hours is unknown too.
  database({ quotes: quotes(NOW - 25 * 60 * MINUTE) });
  pools();
  assertEquals((await e.markets(TESTNET, NOW)).markets.map((r) => r.priceUsd), [null, null]);
});

Deno.test("markets: free liquidity is supplied less borrowed, never negative", async () => {
  database({ quotes: quotes() });
  pools({ reserves: new Map([[XLM.contract, figures({ supplied: 10_000_000n, borrowed: 10_000_001n, utilization: 1 })]]) });
  const [xlm] = (await e.markets(TESTNET, NOW)).markets;
  assertEquals([xlm.totalSupplied, xlm.totalSuppliedUsd, xlm.freeLiquidityUsd], [1, 0.19, 0]);
});

Deno.test("markets: a pool that can't be read fails the answer", async () => {
  database({ quotes: quotes() });
  pools({ failing: new Set([POOL.id]) });
  await assertRejects(() => e.markets(TESTNET, NOW), Error, "Stellar RPC is down");
});

Deno.test("markets: mainnet has no note and no pool yet", async () => {
  database({ quotes: quotes() });
  pools();
  const { MAINNET } = await import("../../supabase/functions/_shared/networks.ts");
  assertEquals(await e.markets(MAINNET, NOW), { markets: [], note: null });
});

// ------------------------------------------------------------------------------------------------ positions

Deno.test("positions: the owner's view reads the pools now; earned = supplied + withdrawn − deposited from what was recorded", async () => {
  const db = database({ quotes: quotes(), flows: [deposit(XLM.contract, "1000000000"), deposit(XLM.contract, "500000000"), withdrawal(XLM.contract, "400000000")] });
  const p = pools({ supplied: new Map([[XLM.contract, { supply: 1_100_012_340n, collateral: 0n }], [BUSDC.contract, { supply: 0n, collateral: 0n }], [WETH, { supply: 5n, collateral: 0n }]]) });
  const rows = await e.positions(ME, "owner", TESTNET, NOW);
  assertEquals(p.reads, [[`supplies ${ME}`, POOL.id, 0]]);
  assert(db.asked.some(([q, params]) => q.startsWith("select kind, intent from lite.tx_log") && params[0] === ME));
  // Nothing for a market the account doesn't supply, nor for wETH, which isn't a registry asset.
  assertEquals(rows, [{
    pool: POOL.id,
    asset: XLM.contract,
    code: "XLM",
    supplied: "1100012340",
    poolName: "Blend TestnetV2",
    deposited: "1500000000",
    withdrawn: "400000000",
    earned: "12340",
    earnedComplete: true,
    supplyApy: 0.031,
    // 110.001234 XLM × $0.1901
    valueUsd: 20.91,
  }]);
});

Deno.test("positions: supply and collateral both count; with no recorded deposit, earned isn't complete", async () => {
  database({ quotes: quotes() });
  pools({ supplied: new Map([[BUSDC.contract, { supply: 600_000_000n, collateral: 400_000_000n }]]) });
  const [row] = await e.positions(ME, "owner", TESTNET, NOW);
  assertEquals([row.code, row.supplied, row.deposited, row.withdrawn, row.earned, row.earnedComplete, row.valueUsd], ["USDC", "1000000000", "0", "0", "1000000000", false, 99.99]);
});

Deno.test("positions: the public view reads the pools as markets do and leaves DyorHQ's record null", async () => {
  const db = database({ quotes: quotes(), flows: [deposit(XLM.contract, "1000000000")] });
  const p = pools({ supplied: new Map([[XLM.contract, { supply: 1_000_012_340n, collateral: 0n }]]) });
  const rows = await e.positions(ME, "public", TESTNET, NOW);
  assertEquals(p.reads, [[`supplies ${ME}`, POOL.id, MINUTE]]);
  assert(!db.asked.some(([q]) => q.includes("lite.tx_log")), "the public view read DyorHQ's history");
  assertEquals(rows.map((r) => [r.supplied, r.deposited, r.withdrawn, r.earned, r.earnedComplete, r.valueUsd]), [["1000012340", null, null, null, false, 19.01]]);
});

Deno.test("positions: an account that supplies nothing has none; one the pool can't be read for fails", async () => {
  database({ quotes: quotes() });
  pools();
  assertEquals(await e.positions(OTHER.publicKey(), "public", TESTNET, NOW), []);
  pools({ failing: new Set([POOL.id]) });
  await assertRejects(() => e.positions(ME, "owner", TESTNET, NOW), Error, "Stellar RPC is down");
});

// ------------------------------------------------------------------------------------------------ earned

Deno.test("earned: deposits count what they spend, withdrawals what they receive, by pool and asset", () => {
  const other = "CDDG7DLOWSHRYQ2HWGZEZ4UTR7LPTKFFHN3QUCSZEXOWOPARMONX6T65";
  const flows = e.flowsOf([
    deposit(XLM.contract, "1000000000"),
    deposit(XLM.contract, "250000000"),
    withdrawal(XLM.contract, "400000000"),
    deposit(BUSDC.contract, "70000000"),
    // Another pool's submit is another market.
    { kind: "earn_deposit", intent: { ...deposit(XLM.contract, "5").intent!, calls: [{ contract: other, fn: "submit" }] } },
    // Neither an earn transaction nor a readable one counts.
    { kind: "swap", intent: { kind: "swap", summary: "", spend: { [XLM.contract]: "99" } } },
    { kind: "earn_deposit", intent: null },
    { kind: "earn_deposit", intent: { kind: "earn_deposit", summary: "", spend: { [XLM.contract]: "77" } } },
    { kind: "earn_withdraw", intent: { ...withdrawal(XLM.contract, "1").intent!, receive: { [XLM.contract]: "-3" } } },
    { kind: "earn_deposit", intent: { ...deposit(XLM.contract, "1").intent!, spend: { [XLM.contract]: "1.5" } } },
  ]);
  assertEquals(flows, new Map([
    [`${POOL.id}:${XLM.contract}`, { deposited: 1_250_000_000n, withdrawn: 400_000_000n, deposits: 2 }],
    [`${POOL.id}:${BUSDC.contract}`, { deposited: 70_000_000n, withdrawn: 0n, deposits: 1 }],
    [`${other}:${XLM.contract}`, { deposited: 5n, withdrawn: 0n, deposits: 1 }],
  ]));
});

Deno.test("earned: supplied now + withdrawn − deposited, signed; complete only with a recorded deposit", () => {
  assertEquals(e.earnedOf(1_000_012_340n, { deposited: 1_000_000_000n, withdrawn: 0n, deposits: 1 }), { deposited: "1000000000", withdrawn: "0", earned: "12340", earnedComplete: true });
  assertEquals(e.earnedOf(599_999_999n, { deposited: 1_000_000_000n, withdrawn: 400_000_000n, deposits: 1 }), { deposited: "1000000000", withdrawn: "400000000", earned: "-1", earnedComplete: true });
  assertEquals(e.earnedOf(300n, undefined), { deposited: "0", withdrawn: "0", earned: "300", earnedComplete: false });
  assertEquals(e.earnedOf(300n, { deposited: 0n, withdrawn: 50n, deposits: 0 }).earnedComplete, false);
});

// ------------------------------------------------------------------------------------------------ history

Deno.test("history: week when absent, week or month, anything else 400 bad_range", async () => {
  assertEquals([e.rangeArg(null), e.rangeArg(""), e.rangeArg("week"), e.rangeArg("month")], ["week", "week", "week", "month"]);
  for (const bad of ["day", "all", "WEEK", "7d"]) assertEquals(await refusal(Promise.resolve().then(() => e.rangeArg(bad))), [400, "bad_range"], bad);
});

Deno.test("history: one market after the range's start; the last snapshot of each hour, oldest first", async () => {
  const at = (iso: string) => new Date(iso);
  const db = database({
    snapshots: [
      { taken_at: at("2026-10-13T08:01:00.000Z"), supply_apy: "0.030", utilization: "0.60" },
      { taken_at: at("2026-10-13T08:51:00.000Z"), supply_apy: "0.031", utilization: "0.61" },
      { taken_at: at("2026-10-13T09:01:00.000Z"), supply_apy: "0.032", utilization: "0.62" },
      { taken_at: at("2026-10-14T09:31:00.000Z"), supply_apy: "0.033", utilization: "0.63" },
    ],
  });
  const h = await e.history(POOL.id, "XLM", "week", TESTNET, NOW);
  assertEquals(h, {
    points: [
      { t: "2026-10-13T08:51:00.000Z", supplyApy: 0.031, utilization: 0.61 },
      { t: "2026-10-13T09:01:00.000Z", supplyApy: 0.032, utilization: 0.62 },
      { t: "2026-10-14T09:31:00.000Z", supplyApy: 0.033, utilization: 0.63 },
    ],
  });
  // The asset by id or by contract; the range's start a week or 30 days back.
  const asked = db.asked.filter(([q]) => q.includes("lite.earn_snapshots")).map(([, p]) => p);
  assertEquals(asked, [[POOL.id, XLM.contract, new Date(NOW - 7 * DAY)]]);
  await e.history(POOL.id, BUSDC.contract, "month", TESTNET, NOW);
  assertEquals(db.asked.at(-1)![1], [POOL.id, BUSDC.contract, new Date(NOW - 30 * DAY)]);
});

Deno.test("history: no snapshots yet is no points; an unknown pool or asset is 400", async () => {
  database();
  assertEquals(await e.history(POOL.id, XLM.contract, null, TESTNET, NOW), { points: [] });
  assertEquals(await refusal(e.history(null, XLM.contract, "week", TESTNET, NOW)), [400, "bad_pool"]);
  assertEquals(await refusal(e.history(WETH, XLM.contract, "week", TESTNET, NOW)), [400, "bad_pool"]);
  assertEquals(await refusal(e.history(POOL.id, WETH, "week", TESTNET, NOW)), [400, "bad_asset"]);
  assertEquals(await refusal(e.history(POOL.id, null, "week", TESTNET, NOW)), [400, "bad_asset"]);
});

// ------------------------------------------------------------------------------------------------ snapshots

Deno.test("snapshots: every registry reserve, read now, one row each; snapshots older than 400 days deleted", async () => {
  const db = database();
  const p = pools({ status: 2 });
  assertEquals(await e.snapshot(TESTNET, NOW), { markets: 2 });
  assertEquals(p.reads, [["read", POOL.id, 0]]);
  const inserts = db.asked.filter(([q]) => q.startsWith("insert into lite.earn_snapshots")).map(([, params]) => params);
  const at = new Date(NOW);
  assertEquals(inserts, [
    [POOL.id, XLM.contract, at, 0.031, 0.054, 0.61, "182345671200000", "111230859432000", 2],
    [POOL.id, BUSDC.contract, at, 0.048, 0.071, 0.72, "12033445000000", "8664080400000", 2],
  ]);
  const deletes = db.asked.filter(([q]) => q.startsWith("delete from lite.earn_snapshots")).map(([q, params]) => [q, params]);
  assertEquals(deletes, [["delete from lite.earn_snapshots where taken_at < ?", [new Date(NOW - 400 * DAY)]]]);
});

Deno.test("snapshots: a pool that can't be read and a rate that isn't a number are named; the rest are taken", async () => {
  const db = database();
  pools({ reserves: new Map([[XLM.contract, figures({ supplyApy: NaN })], [BUSDC.contract, figures({ borrowApy: Infinity })]]) });
  assertEquals(await e.snapshot(TESTNET, NOW), { markets: 1, errors: ["Blend TestnetV2 XLM: no rate"] });
  const [busdc] = db.asked.filter(([q]) => q.startsWith("insert into lite.earn_snapshots")).map(([, params]) => params);
  assertEquals([busdc[1], busdc[4]], [BUSDC.contract, null]);
  database();
  pools({ failing: new Set([POOL.id]) });
  assertEquals(await e.snapshot(TESTNET, NOW), { markets: 0, errors: ["Blend TestnetV2: Stellar RPC is down"] });
});

Deno.test("the earn job snapshots once migration 08 is applied, and waits for it before", async () => {
  database({ migrated: false });
  const p = pools();
  assertEquals(await earnJob(), { skipped: "migration 08 isn't applied" });
  assertEquals(p.reads, []);
  database();
  pools();
  assertEquals(await earnJob(), { markets: 2 });
});

// ------------------------------------------------------------------------------------------------ plans

const NOW_S = Math.floor(NOW / 1000);
const allowed = new Set(Object.values(contractAllowlist(TESTNET)).flat());

/** A submit as simulation returns it: its root authorization the call itself, the token transfers it makes beneath. */
function submitTx(args: xdr.ScVal[], transfers: [string, string, bigint][] = []) {
  const ic = new xdr.InvokeContractArgs({ contractAddress: new Address(POOL.id).toScAddress(), functionName: "submit", args });
  const inv = (c: xdr.InvokeContractArgs, subs: xdr.SorobanAuthorizedInvocation[] = []) =>
    new xdr.SorobanAuthorizedInvocation({ function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(c), subInvocations: subs });
  const pulls = transfers.map(([token, to, amount]) =>
    inv(new xdr.InvokeContractArgs({ contractAddress: new Address(token).toScAddress(), functionName: "transfer", args: [new Address(ME).toScVal(), new Address(to).toScVal(), nativeToScVal(amount, { type: "i128" })] }))
  );
  const auth = [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: inv(ic, pulls) })];
  return new TransactionBuilder(new Account(ME, "41"), { fee: "100", networkPassphrase: TESTNET.passphrase, timebounds: { minTime: 0, maxTime: NOW_S + 300 } })
    .addOperation(Operation.invokeHostFunction({ func: xdr.HostFunction.hostFunctionTypeInvokeContract(ic), auth }))
    .build();
}

const verify = (args: xdr.ScVal[], intent: Parameters<typeof verifyTransaction>[1], transfers: [string, string, bigint][] = []) =>
  verifyTransaction(submitTx(args, transfers), intent, { user: ME, sponsor: SPONSOR.publicKey(), passphrase: TESTNET.passphrase, allowedContracts: allowed, now: NOW_S });

Deno.test("plans: a deposit is a submit from, spent by and paid to the user, spending what it declares", () => {
  const args = e.submitArgs(ME, XLM.contract, "1000000000", e.REQUEST.Supply);
  assertEquals(args.slice(0, 3).map((a) => Address.fromScVal(a).toString()), [ME, ME, ME]);
  const intent = e.submitIntent(POOL, XLM, "1000000000", e.REQUEST.Supply);
  assertEquals(intent, {
    kind: "earn_deposit",
    summary: "Deposit 100 XLM to earn",
    spend: { [XLM.contract]: "1000000000" },
    calls: [{ contract: POOL.id, fn: "submit" }],
    display: { asset: "XLM", amount: "1000000000", pool: "Blend TestnetV2" },
  });
  assertEquals(verify(args, intent, [[XLM.contract, POOL.id, 1_000_000_000n]]).outflow, { [XLM.contract]: "1000000000" });
});

Deno.test("plans: a withdrawal is a submit to the user that spends nothing and receives what it declares", () => {
  const args = e.submitArgs(ME, BUSDC.contract, "400000000", e.REQUEST.Withdraw);
  assertEquals(args.slice(0, 3).map((a) => Address.fromScVal(a).toString()), [ME, ME, ME]);
  const intent = e.submitIntent(POOL, BUSDC, "400000000", e.REQUEST.Withdraw);
  assertEquals([intent.kind, intent.summary, intent.spend, intent.receive], ["earn_withdraw", "Withdraw 40 USDC", {}, { [BUSDC.contract]: "400000000" }]);
  assertEquals(verify(args, intent).outflow, {});
});

Deno.test("plans: the verifier refuses a submit for another account, and a deposit that spends more than it declares", () => {
  const intent = e.submitIntent(POOL, XLM, "1000000000", e.REQUEST.Supply);
  const args = e.submitArgs(ME, XLM.contract, "1000000000", e.REQUEST.Supply);
  for (const i of [0, 1, 2]) {
    const other = args.slice();
    other[i] = new Address(OTHER.publicKey()).toScVal();
    let reason = "";
    try {
      verify(other, intent);
    } catch (err) {
      reason = (err as Error).message;
    }
    assertEquals(reason, "the call acts for another account", `argument ${i}`);
  }
  let reason = "";
  try {
    verify(args, intent, [[XLM.contract, POOL.id, 1_000_000_001n]]);
  } catch (err) {
    reason = (err as Error).message;
  }
  assertEquals(reason, `the transaction spends more than this action declares (${XLM.contract})`);
});

Deno.test("plans: a withdrawal asks for at most the account's supply; unknown pools and assets are refused before anything is built", async () => {
  database({ quotes: quotes() });
  pools({ supplied: new Map([[XLM.contract, { supply: 600_000_000n, collateral: 400_000_000n }]]) });
  // The collateral can't be withdrawn this way; nor can anything from a market the account doesn't supply.
  assertEquals(await refusal(e.buildEarn(ME, "withdraw", POOL.id, XLM.contract, 600_000_001n)), [400, "bad_amount"]);
  assertEquals(await refusal(e.buildEarn(ME, "withdraw", POOL.id, "XLM", 1_000_000_000n)), [400, "bad_amount"]);
  assertEquals(await refusal(e.buildEarn(ME, "withdraw", POOL.id, BUSDC.contract, 1n)), [400, "bad_amount"]);
  assertEquals(await refusal(e.buildEarn(ME, "deposit", POOL.id, WETH, 1n)), [400, "bad_asset"]);
  assertEquals(await refusal(e.buildEarn(ME, "deposit", WETH, XLM.contract, 1n)), [400, "bad_pool"]);
  // A registry asset the pool doesn't lend.
  pools({ reserves: new Map([[XLM.contract, figures()]]) });
  assertEquals(await refusal(e.buildEarn(ME, "deposit", POOL.id, BUSDC.contract, 1n)), [400, "bad_asset"]);
  assertEquals(await refusal(e.buildEarn(ME, "withdraw", POOL.id, BUSDC.contract, 1n)), [400, "bad_asset"]);
});

// ------------------------------------------------------------------------------------------------ routes

Deno.test("routes: markets and history answer with no token, cached 30 s, and ignore one that is sent", async () => {
  database({ quotes: quotes(Date.now()) });
  pools();
  const token = await userToken();
  for (const path of ["/v1/earn/markets", `/v1/earn/history?pool=${POOL.id}&asset=${XLM.contract}&range=month`]) {
    const open = await get(path);
    const body = await open.json();
    assertEquals([open.status, open.headers.get("cache-control")], [200, "public, max-age=30"], path);
    const signed = await get(path, token);
    assertEquals([signed.status, await signed.json()], [200, body], `${path} with a token`);
  }
  const bad = await get(`/v1/earn/history?pool=${POOL.id}&asset=${XLM.contract}&range=day`);
  assertEquals([bad.status, (await bad.json()).error.code], [400, "bad_range"]);
});

Deno.test("routes: positions without a token answer the public view of ?address=, cached 15 s; with neither, 400 address_required", async () => {
  database({ quotes: quotes(Date.now()), flows: [deposit(XLM.contract, "1000000000")] });
  pools({ supplied: new Map([[XLM.contract, { supply: 1_000_012_340n, collateral: 0n }]]) });
  const open = await get(`/v1/earn/positions?address=${ME}`);
  const body = await open.json();
  assertEquals([open.status, open.headers.get("cache-control"), body.view, body.positions[0].earned], [200, "public, max-age=15", "public", null]);
  const owner = await get(`/v1/earn/positions?address=${OTHER.publicKey()}`, await userToken());
  const mine = await owner.json();
  assertEquals([owner.status, owner.headers.get("cache-control"), mine.view, mine.positions[0].earned], [200, "no-store", "owner", "12340"]);
  const neither = await get("/v1/earn/positions");
  assertEquals([neither.status, (await neither.json()).error.code], [400, "address_required"]);
  const badToken = await get(`/v1/earn/positions?address=${ME}`, "not-a-token");
  assertEquals(badToken.status, 401);
});

Deno.test("routes: a deposit or withdrawal plan needs a session", async () => {
  const res = await handle(new Request("http://127.0.0.1/lite/v1/earn/build", { method: "POST", body: JSON.stringify({ action: "deposit", pool: POOL.id, asset: XLM.contract, amount: "1" }) }));
  assertEquals([res.status, (await res.json()).error.code], [401, "unauthorized"]);
});
