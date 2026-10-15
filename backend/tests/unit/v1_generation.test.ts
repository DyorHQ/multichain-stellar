// The retired generation's routes serve its rows only (DESIGN-stellar-contracts-v2 §17 step 7): lite.launches and
// lite.moments hold both generations once the indexer reads v2 (migration 20261015000012), and v1's board, a launch's
// page, My Launchpad, the v1 plans, the Moments feed and My Moments read v1's rows only. A v1 launch is the one with a
// launch index and a v1 Moment the one with a number: v2's have neither, which also holds before the migration. The
// markets list launch tokens of both generations.
//
// The fake database answers each query from rows of both generations and applies the v1 condition only when the query
// states it, so a query that leaves it out answers v2's rows too, and the route shows it.
import { Address, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, OTHER, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const lp = await import("../../supabase/functions/_shared/launchpad.ts");
const moments = await import("../../supabase/functions/_shared/moments.ts");

const PAD = TESTNET.contracts.launchpad!;
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
    phase: v2 ? "curve" : null,
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
replaceSql(fakeSql((q, p) => {
  queries.push(q);
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

// The v1 launchpad answers that it never launched v2's token; any other call fails, as an unreachable RPC would.
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  if (new URL(req.url).host !== "soroban-testnet.stellar.org") return new Response("offline", { status: 503 });
  const body = await req.json();
  if (body.method !== "simulateTransaction") return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: "offline" } });
  const tx = TransactionBuilder.fromXDR(body.params.transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract() as xdr.InvokeContractArgs;
  const unknown = Address.fromScAddress(call.contractAddress()).toString() === PAD && call.functionName().toString() === "get_launch";
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

Deno.test("the launch board (both forms) and its counts: v1's launches only", async () => {
  queries = [];
  const board = await lp.launchBoard(lp.boardQuery(new URLSearchParams("section=explore")), "public", NOW);
  assertEquals([tokensOf(board.launches), board.counts], [[V1_TOKEN], { explore: 1, graduated: 0 }]);
  const legacy = await lp.launchBoard(lp.boardQuery(new URLSearchParams("sort=new")), "public", NOW);
  assertEquals(tokensOf(legacy.launches), [V1_TOKEN]);
  assertEquals(queries.filter((q) => q.includes("from lite.launches l") && !q.includes("l.launch_index is not null")), [], "every board query states it");
});

Deno.test("a launch's page: v2's token has none here (404)", async () => {
  const err = await refused(() => lp.launchDetail(V2_TOKEN, { address: null, scope: "public" }, undefined, NOW));
  assertEquals([err.status, err.code], [404, "not_found"]);
});

Deno.test("My Launchpad: v1's coins held and created only; a v2 launch's creator fees aren't read from the v1 launchpad", async () => {
  queries = [];
  // Read from the v1 launchpad, my v2 launch's fees fail (RPC can't find it): the page would answer 502.
  const mine = await lp.myLaunchpad(ME, NOW);
  assertEquals([mine.held.map((h) => h.token), mine.created.map((c) => c.launch.token)], [[V1_TOKEN], []]);
  assertEquals(queries.filter((q) => q.startsWith("select l.*") && !q.includes("l.launch_index is not null")), []);
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
