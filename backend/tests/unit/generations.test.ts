// Both generations in one database (DESIGN-stellar-contracts-v2 §17): lite.launches and lite.moments hold v1's
// (retired) and v2's (live) rows once the indexer reads v2 (migration 20261015000012).
// - Launches: the board, a launch's page, My Launchpad and the markets list both generations, each row with its
//   `generation`, so the app shows v1's as Retired; a launch's curve and creator fees are read from its own launchpad,
//   and its holders leave out both launchpads. v1's plans act on v1's launches only.
// - Moments: v1's feed and My Moments read v1's rows only (a v2 Moment has no number); v2's are served under
//   /v1/moments/v2 (moments_v2_feed.ts, moments_v2_feed.test.ts).
// A v1 launch is the one with a launch index and a v1 Moment the one with a number: v2's have neither, which also holds
// before the migration.
//
// The fake database answers each query from rows of both generations and applies the v1 condition only when the query
// states it, so a query that leaves it out answers v2's rows too, and the route shows it.
import { Address, nativeToScVal, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, OTHER, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const lp = await import("../../supabase/functions/_shared/launchpad.ts");
const moments = await import("../../supabase/functions/_shared/moments.ts");

const PAD = TESTNET.contracts.launchpad!;
/** The owner's launchpad-v2 (testnet-v2.json, bundled). */
const PAD_V2 = env.network.contracts.launchpadV2!;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const ME = USER.publicKey();
const SOMEONE = OTHER.publicKey();
const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const V1_TOKEN = C(31);
const V2_TOKEN = C(32);
const V2_NFT = C(33);
const NOW = Date.UTC(2026, 9, 15, 18, 0);
const at = (iso: string) => new Date(iso);

// ------------------------------------------------------------------------------------------------ both generations

/** A launch row as the indexer writes it: v1's with its launch index, v2's with none (lite-indexer/v2_events.ts). */
function launch(token: string, creator: string, v2: boolean): Row {
  return {
    token,
    creator,
    quote: XLM,
    name: v2 ? "Second Cat" : "First Cat",
    symbol: v2 ? "CAT2" : "CAT1",
    uri: "",
    launch_index: v2 ? null : 4,
    generation: v2 ? 2 : 1,
    nonce: v2 ? "77" : null,
    phase: v2 ? "completed" : null,
    supply: "10000000000000000",
    phantom: "20000000000",
    quote_reserve: "300000000000",
    token_reserve: "9000000000000000",
    real_quote: "1000000000",
    threshold: "50000000000",
    completed: false,
    graduated: false,
    pair: null,
    last_price: "0.0000333",
    volume_quote: "1000000000",
    trades: 4,
    listed: true,
    burned: "0",
    burned_total: "0",
    holders: 2,
    volume_24h: "0",
    price_24h: null,
    creator_fees_claimed: "0",
    created_at: at("2026-10-15T07:00:00.000Z"),
    updated_at: at("2026-10-15T07:10:00.000Z"),
  };
}

/** A Moment row: v1's keyed by its number, v2's by its NFT address with none. */
function moment(id: number | null, creator: string): Row {
  return {
    id,
    nft: id === null ? V2_NFT : null,
    generation: id === null ? 2 : 1,
    creator,
    uri: "https://local.invalid/storage/v1/object/public/lite-media/moments/m.json",
    title: id === null ? "A v2 Moment" : "A v1 Moment",
    media_url: "https://local.invalid/storage/v1/object/public/lite-media/uploads/m.jpg",
    price: "20000000",
    quote: XLM,
    max_editions: id === null ? 0 : 10,
    minted: 2,
    deadline: at("2099-01-01T00:00:00.000Z"),
    created_at: at("2026-10-15T06:00:00.000Z"),
    listed: true,
    platform_bps: 500,
    royalty_bps: 500,
  };
}

/** I created the v2 launch and hold both coins; someone else created the v1 one. I published a Moment of each. */
const LAUNCHES = [launch(V1_TOKEN, SOMEONE, false), launch(V2_TOKEN, ME, true)];
const MOMENTS = [moment(7, ME), moment(null, ME)];

/** The rows a query over `l` answers: v1's only when it says so, then its own conditions this file uses. */
function launchesFor(q: string, p: unknown[]): Row[] {
  let rows = q.includes("l.launch_index is not null") ? LAUNCHES.filter((r) => r.launch_index !== null) : LAUNCHES;
  if (q.includes("l.token = ?")) rows = rows.filter((r) => p.includes(r.token));
  if (q.includes("l.creator = ?")) rows = rows.filter((r) => p.includes(r.creator));
  return rows;
}

function momentsFor(q: string, p: unknown[]): Row[] {
  let rows = q.includes("id is not null") ? MOMENTS.filter((r) => r.id !== null) : MOMENTS;
  if (q.includes("creator = ?")) rows = rows.filter((r) => p.includes(r.creator));
  return rows;
}

let queries: string[] = [];
let asked: [string, unknown[]][] = [];
replaceSql(fakeSql((q, p) => {
  queries.push(q);
  asked.push([q, p]);
  if (q.startsWith("select l.*, greatest(l.burned, coalesce(b.burned, 0)) as burned_total")) return launchesFor(q, p);
  if (q.startsWith("select count(*) filter (where not l.graduated)::int as explore")) {
    const rows = launchesFor(q, p);
    return [{ explore: rows.filter((r) => !r.graduated).length, graduated: rows.filter((r) => r.graduated).length }];
  }
  if (q.startsWith("select l.quote, l.symbol, l.creator from lite.launches l") || q.startsWith("select l.token, l.symbol from lite.launches l")) {
    return launchesFor(q, p);
  }
  if (q.startsWith("select token, balance from lite.token_balances")) return LAUNCHES.map((r) => ({ token: r.token, balance: "1000000000" }));
  if (q.startsWith("select * from lite.moments where")) return momentsFor(q, p);
  // Prices, trades, editions, collects and DyorHQ's history: none.
  return [];
}));

/** launchpad-v2's Curve for my v2 launch: completed, waiting to graduate, with 0.25 XLM of creator fees booked. */
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const V2_CURVE = xdr.ScVal.scvMap(
  Object.entries({
    phantom: i128(20000000000n),
    threshold: i128(50000000000n),
    quote_reserve: i128(70000000000n),
    token_reserve: i128(2000000000000000n),
    real_quote: i128(50000000000n),
    creator_fees: i128(2500000n),
    phase: nativeToScVal(1, { type: "u32" }),
    pool: xdr.ScVal.scvVoid(),
  }).sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: v })),
);

/** Each contract call the fake RPC was asked: "<contract> <function>". */
let calls: string[] = [];

// The v1 launchpad answers that it never launched v2's token, and launchpad-v2 gives v2's curve; any other call fails,
// as an unreachable RPC would.
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  if (new URL(req.url).host !== "soroban-testnet.stellar.org") return new Response("offline", { status: 503 });
  const body = await req.json();
  if (body.method !== "simulateTransaction") return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: "offline" } });
  const tx = TransactionBuilder.fromXDR(body.params.transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract() as xdr.InvokeContractArgs;
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  calls.push(`${contract === PAD ? "launchpad" : contract === PAD_V2 ? "launchpad-v2" : contract} ${call.functionName().toString()}`);
  if (contract === PAD_V2 && call.functionName().toString() === "get_curve") {
    return Response.json({ jsonrpc: "2.0", id: body.id, result: { latestLedger: 1, results: [{ auth: [], xdr: V2_CURVE.toXDR("base64") }], events: [] } });
  }
  const unknown = contract === PAD && call.functionName().toString() === "get_launch";
  // contracts/launchpad Error::UnknownLaunch (#7), as testnet logs it (launch.test.ts).
  const error = unknown ? `HostError: Error(Contract, #7)\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${PAD}, topics:[error, Error(Contract, #7)], data:["failing with contract error", 7]` : "HostError: Error(WasmVm, InvalidAction)";
  return Response.json({ jsonrpc: "2.0", id: body.id, result: { latestLedger: 1, error } });
}) as typeof fetch;

async function refused(run: () => Promise<unknown>): Promise<InstanceType<typeof ApiError>> {
  const err = await run().then(() => null, (e) => e);
  assert(err instanceof ApiError, `expected an ApiError, got ${err}`);
  return err;
}

const tokensOf = (rows: { token: string }[]) => rows.map((r) => r.token);

// ------------------------------------------------------------------------------------------------ launches

const generationsOf = (rows: { token: string; generation?: number }[]) => rows.map((r) => [r.token, r.generation]);

Deno.test("the launch board (both forms) and its counts: both generations, each row with its own", async () => {
  queries = [];
  const board = await lp.launchBoard(lp.boardQuery(new URLSearchParams("section=explore")), "public", NOW);
  assertEquals([generationsOf(board.launches), board.counts], [[[V1_TOKEN, 1], [V2_TOKEN, 2]], { explore: 2, graduated: 0 }]);
  const legacy = await lp.launchBoard(lp.boardQuery(new URLSearchParams("sort=new")), "public", NOW);
  assertEquals(generationsOf(legacy.launches), [[V1_TOKEN, 1], [V2_TOKEN, 2]]);
  assertEquals(queries.filter((q) => q.includes("l.launch_index is not null")), [], "no board query keeps to v1");
});

Deno.test("a v2 row says where it is: a completed curve waiting to graduate is completed, at 100%", async () => {
  const [, v2] = (await lp.launchBoard(lp.boardQuery(new URLSearchParams("section=explore")), "public", NOW)).launches;
  assertEquals([v2.phase, v2.completed, v2.graduated, v2.progress], ["completed", true, false, 1]);
  assertEquals(lp.phaseOf({ generation: 2, phase: "rescued", completed: false, graduated: false }), "rescued");
  assertEquals(lp.phaseOf({ generation: 2, phase: "curve", completed: false, graduated: false }), "curve");
  // v1's phase stays its curve's flags: it has no phase column.
  assertEquals(lp.phaseOf({ completed: true, graduated: false }), "completed");
  assertEquals(lp.phaseOf({ generation: 2, phase: "graduated", completed: true, graduated: true }), "graduated");
});

Deno.test("holders leave out both launchpads, the pool and the token itself", async () => {
  asked = [];
  await lp.launchBoard(lp.boardQuery(new URLSearchParams("section=explore")), "public", NOW);
  const [q, p] = asked.find(([text]) => text.startsWith("select l.*, greatest(l.burned, coalesce(b.burned, 0)) as burned_total"))!;
  assert(q.includes("lite.launch_holders(l.token, array[?::text, ?::text, l.pair, l.token]) as holders"), q);
  assertEquals(p.slice(0, 2), [PAD, PAD_V2]);
});

Deno.test("a launch's page: a v2 launch, with generation 2 and its curve and creator fees read from launchpad-v2", async () => {
  calls = [];
  const page = await lp.launchDetail(V2_TOKEN, { address: null, scope: "public" }, undefined, NOW);
  assertEquals([page.launch.token, page.launch.generation, page.launch.phase], [V2_TOKEN, 2, "completed"]);
  assertEquals(page.curve, {
    quoteReserve: "70000000000",
    tokenReserve: "2000000000000000",
    realQuote: "50000000000",
    threshold: "50000000000",
    creatorFees: "2500000",
    completed: true,
    graduated: false,
    pair: null,
  });
  assertEquals(page.creatorFees?.unclaimed, "2500000");
  assertEquals(calls, ["launchpad-v2 get_curve"]);
  const v1 = await lp.launchDetail(V1_TOKEN, { address: null, scope: "public" }, undefined, NOW);
  assertEquals(v1.launch.generation, 1);
});

Deno.test("My Launchpad: coins of both generations held and created, each with its generation; a v2 launch's creator fees from launchpad-v2", async () => {
  calls = [];
  lp.forgetLaunchReads();
  const mine = await lp.myLaunchpad(ME, NOW);
  assertEquals(mine.held.map((h) => [h.token, h.launch.generation]), [[V1_TOKEN, 1], [V2_TOKEN, 2]]);
  assertEquals(mine.created.map((c) => [c.launch.token, c.launch.generation, c.creatorFees.unclaimed]), [[V2_TOKEN, 2, "2500000"]]);
  assertEquals(calls, ["launchpad-v2 get_curve"], "never the v1 launchpad, which doesn't know it");
});

Deno.test("v1's plans: a v2 token isn't v1's to graduate (404), and claim all leaves v2's launches out", async () => {
  const graduate = await refused(() => lp.buildLaunch(ME, { action: "graduate", token: V2_TOKEN }));
  assertEquals([graduate.status, graduate.code], [404, "not_found"]);
  // My only launch is v2's: nothing of v1's to claim, rather than its fees unreadable on the v1 launchpad (502).
  const claim = await refused(() => lp.buildLaunch(ME, { action: "claim" }));
  assertEquals([claim.status, claim.code, (claim.detail as { contractCode?: string }).contractCode], [422, "simulation_failed", "launch.nothing_to_claim"]);
});

Deno.test("the markets list launch tokens of both generations", async () => {
  const rows = await lp.launchMarketRows(NOW);
  assertEquals(rows.map((r) => r.id).sort(), [V1_TOKEN, V2_TOKEN].sort());
});

// ------------------------------------------------------------------------------------------------ Moments

Deno.test("the Moments feed, collecting or closed: v1's Moments only", async () => {
  for (const filter of ["all", "collecting", "closed"] as const) {
    queries = [];
    const rows = await moments.feed(filter, 50, NOW);
    // The fake answers either filter with every row it has: v2's would show as Moment 0.
    assertEquals(rows.map((r) => r.id), [7], filter);
    assert(queries.some((q) => q.startsWith("select * from lite.moments where") && q.includes("id is not null")), filter);
  }
});

Deno.test("My Moments: the v1 Moments I published only", async () => {
  const mine = await moments.mine(ME, NOW);
  assertEquals(mine.created.map((m) => [m.id, m.title]), [[7, "A v1 Moment"]]);
});
