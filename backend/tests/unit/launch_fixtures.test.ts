// WP-14's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md §6.0,
// §6.9, §12.5): the board (launches, and the older clients' launches.legacy), a launch's page in the owner's and the
// public view (launch, launch.public, launch.legacy), My Launchpad, the economics, a coin's metadata URI, quotes, a
// contract's refusal and the launch row of the markets (markets.json), produced by the routes' own code from seeded
// rows and a fake RPC that carry the fixtures' figures.
//
// ERRATA: figures the fixtures state that no consistent server could answer, and what this one answers instead. Each
// payload is compared with its fixture with these corrected, and with nothing else changed (they are WP-03's to fix):
// - priceUsd: the fixtures round a launch's USD price to 2 significant digits ($0.0000079 for 0.0000417 XLM × $0.1901
//   = $0.00000792717). The API keeps 6, so the app's 4-digit prices (PriceFormat.usdPrice) are right.
// - FULL's and GRAD's marketCapQuote, and so their marketCapUsd: 10 times §6.9's priceQuote × circulating
//   (0.0000471 XLM × 1,000,000,000 FULL is 47,100 XLM, not 471,000; ECAT's 41,700 is right).
// - launchpad-me: valueUsd 9.48 is 1,200,000 × the rounded $0.0000079 (at the price served, $9.51); pnlUsd −0.02
//   isn't −2,400,000 stroops at $0.1901 (−$0.05).
// - error-contract.json's raw is an example; the API passes on the simulation's own text.
import { Address, nativeToScVal, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { native } = await import("../../supabase/functions/_shared/stellar.ts");
const lp = await import("../../supabase/functions/_shared/launchpad.ts");
const { writeLaunchMetadata } = await import("../../supabase/functions/_shared/launch_metadata.ts");
const { economics, forgetEconomics } = await import("../../supabase/functions/_shared/economics.ts");
const m = await import("../../supabase/functions/_shared/markets.ts");
const { errorResponse } = await import("../../supabase/functions/_shared/http.ts");

const api = new URL("../fixtures/api/", import.meta.url);
const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, api)));

/** Late enough that every fixture launch is over a day old; the reference quotes a minute before. */
const NOW = Date.UTC(2026, 9, 14, 14, 0);
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const ECAT = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
const FULL = "CAMK4ZCNBLAJWNWIK2NIX6WSCHY2CNBP47SOC7263IAJ47LDUU5SH6AA";
const GRAD = "CDAG2SCOH4WYY4MPRFLWB3OQOHRDJN6GHDHZ6KXE4ZT4AYFR67UWV5JC";
const ME = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH";
const SELLER = "GDFIMZHHSBGAIJUCBALCYGEO2GQKDVWJW4C3LFFLLINXU23OPVEXRITR";
const CREATOR = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN";
const MEDIA = `${STORAGE}/storage/v1/object/public/lite-media/`;
const at = (iso: string) => new Date(iso);

// ------------------------------------------------------------------------------------------------ the seeded world

/** A lite.launches row as launchQuery() answers it, with the price a day ago that gives the fixture's 24h change at an
 *  unchanged XLM price. */
function launchRow(fields: Row & { last_price: string }, change: number): Row {
  return {
    uri: "",
    image_url: null,
    description: null,
    links: null,
    completed: false,
    graduated: false,
    pair: null,
    burned: "0",
    burned_total: "0",
    holders_complete: true,
    fee_bps: 100,
    protocol_share_bps: 5000,
    creator_fee_bps: 100,
    pool_fee_bps: null,
    look_alike: false,
    graduated_at: null,
    creator_fees_claimed: "0",
    phantom: "250000000000",
    supply: "10000000000000000",
    quote: XLM,
    price_24h: String(Number(fields.last_price) / (1 + change)),
    ...fields,
  };
}

const ECAT_ROW = launchRow({
  token: ECAT,
  creator: CREATOR,
  name: "E2E Cat",
  symbol: "ECAT",
  uri: `${MEDIA}launches/${CREATOR}/aef9135a-6c53-435a-a2e4-5bb339faa0e1.json`,
  image_url: `${MEDIA}uploads/${CREATOR}/b4e32bb4-0296-4ba8-a4c8-9ebd74f07d5e.png`,
  description: "A cat that runs end-to-end tests.",
  links: { website: "https://ecat.dyorhq.fun", x: "https://x.com/ecat", telegram: null },
  quote_reserve: "289000000000",
  token_reserve: "6920415224913495",
  real_quote: "39000000000",
  threshold: "93000000000",
  last_price: "0.0000417",
  volume_quote: "61000000000",
  trades: 12,
  created_at: at("2026-10-13T03:41:00.000Z"),
  holders: 5,
  volume_24h: "21000000000",
  last_trade_at: at("2026-10-14T09:29:00.000Z"),
  creator_fees_claimed: "1200000",
}, 0.12);

const FULL_ROW = launchRow({
  token: FULL,
  creator: CREATOR,
  name: "Full Curve",
  symbol: "FULL",
  quote_reserve: "343000000000",
  token_reserve: "7288629737609329",
  real_quote: "93000000000",
  threshold: "93000000000",
  completed: true,
  last_price: "0.0000471",
  volume_quote: "118000000000",
  trades: 37,
  created_at: at("2026-10-13T13:41:00.000Z"),
  holders: 19,
  volume_24h: "520000000000",
  last_trade_at: at("2026-10-14T09:38:00.000Z"),
}, 0.31);

const GRAD_ROW = launchRow({
  token: GRAD,
  creator: ME,
  name: "Graduate",
  symbol: "GRAD",
  quote_reserve: "0",
  token_reserve: "0",
  real_quote: "93000000000",
  threshold: "93000000000",
  completed: true,
  graduated: true,
  pair: "CAYMMTZR2ZXMQDHFM45I6RI74YEGXD4QXUR5JNY7TBMOEXJTYJ3FXLDI",
  last_price: "0.0000502",
  volume_quote: "151000000000",
  trades: 41,
  created_at: at("2026-10-08T09:41:00.000Z"),
  burned: "1250000000000000",
  burned_total: "1250000000000000",
  holders: 23,
  holders_complete: false,
  pool_fee_bps: 30,
  volume_24h: "8800000000",
  graduated_at: at("2026-10-09T09:41:00.000Z"),
  last_trade_at: at("2026-10-14T08:06:00.000Z"),
  creator_fees_claimed: "9300000",
}, -0.034);

/** The viewer's trades of ECAT: a round trip that lost 0.28 XLM, then the fixture's 50 XLM buy. */
const MY_FILLS = [
  { token: ECAT, side: "buy", quote_amount: "100000000", token_amount: "2400000000000" },
  { token: ECAT, side: "sell", quote_amount: "97200000", token_amount: "2400000000000" },
  { token: ECAT, side: "buy", quote_amount: "500000000", token_amount: "12000000000000" },
];

const BUY_HASH = "e8c10a640996c1bfdf8c8c69989b344dce8daeefdfd356454c630f4357999225";

function database(board: Row[] = [FULL_ROW, ECAT_ROW, GRAD_ROW]): void {
  forgetReferencePrices();
  lp.forgetLaunchReads();
  replaceSql(fakeSql((q) => {
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
      return [
        { ref: "XLM", usd: "0.1901", source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date(NOW - 60_000) },
        { ref: "USDC", usd: "0.9999", source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date(NOW - 60_000) },
      ];
    }
    if (q.startsWith("select ref, lite.ref_usd_at(ref, ?) as usd from unnest(?::text[]) as ref")) return [{ ref: "XLM", usd: "0.1901" }, { ref: "USDC", usd: "0.9999" }];
    if (q.startsWith("select l.*, greatest(l.burned, coalesce(b.burned, 0)) as burned_total")) {
      if (q.includes("where l.token = ?")) return [ECAT_ROW];
      if (q.includes("where l.token in (select tb.token from lite.token_balances tb")) return [ECAT_ROW];
      if (q.includes("where l.creator = ?")) return [GRAD_ROW];
      return board;
    }
    if (q.startsWith("select count(*) filter (where not l.graduated)::int as explore")) return [{ explore: 12, graduated: 3 }];
    if (q.startsWith("select * from ( (select 'curve' as venue")) {
      return [
        { venue: "curve", trader: ME, side: "buy", quote_amount: "500000000", token_amount: "12000000000000", price: "0.0000417", tx_hash: BUY_HASH, ts: at("2026-10-14T09:29:00.000Z") },
        { venue: "curve", trader: SELLER, side: "sell", quote_amount: "100000000", token_amount: "2410000000000", price: "0.0000415", tx_hash: "b9bd2da960151e052b2e46fa97cb612b77e135ceab17e96f0083a5af72bf3f81", ts: at("2026-10-14T09:01:00.000Z") },
      ];
    }
    if (q.startsWith("select bucket, open, high, low, close, volume from lite.token_candles(")) {
      return [
        { bucket: at("2026-10-14T09:11:00.000Z"), open: "0.0000409", high: "0.0000415", low: "0.0000409", close: "0.0000415", volume: "100000000" },
        { bucket: at("2026-10-14T09:26:00.000Z"), open: "0.0000415", high: "0.0000417", low: "0.0000415", close: "0.0000417", volume: "500000000" },
      ];
    }
    if (q.startsWith("select ts, price from ( (select ts, price, event_id from lite.launch_trades")) {
      return [{ ts: at("2026-10-14T09:29:00.000Z"), price: "0.0000417" }, { ts: at("2026-10-14T09:01:00.000Z"), price: "0.0000415" }];
    }
    if (q.startsWith("select token, side, quote_amount, token_amount from (")) return MY_FILLS;
    if (q === "select balance from lite.token_balances where token = ? and address = ?") return [{ balance: "12000000000000" }];
    if (q === "select token, balance from lite.token_balances where address = ? and balance > 0") return [{ token: ECAT, balance: "12000000000000" }];
    if (q.startsWith("select t.hash, t.kind, t.intent, t.status, t.fee_charged, t.created_at")) {
      return [{
        hash: BUY_HASH,
        kind: "launch_buy",
        intent: { kind: "launch_buy", summary: "Buy ECAT with 50 XLM", display: { token: ECAT, symbol: "ECAT", quote: "XLM", amount: "500000000", minOut: "11880000000000" } },
        status: "success",
        fee_charged: "41210",
        created_at: at("2026-10-14T09:29:00.000Z"),
        fee_payer: "user",
        result: { amountOut: "12000000000000" },
      }];
    }
    if (q.startsWith("select token, symbol, name, quote from lite.launches where token = any(")) return [{ token: ECAT, symbol: "ECAT", name: "E2E Cat", quote: XLM }];
    if (q.startsWith("insert into lite.launch_metadata")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
}

// A fake RPC: ECAT's and GRAD's curves, the viewer's ECAT balance, quotes and the contracts' terms.
const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const addr = (a: string) => new Address(a).toScVal();
const bool = (b: boolean) => xdr.ScVal.scvBool(b);
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));

let quoteError: string | null = null;
/** How many times a curve was read. */
let curveReads = 0;

function answer(contract: string, fn: string, args: xdr.ScVal[]): xdr.ScVal | { error: string } {
  const e = fixture("economics");
  const arg = (i: number) => (args[i] ? native(args[i]) : undefined);
  if (fn === "get_curve") {
    curveReads++;
    const token = String(arg(0));
    return token === ECAT
      ? struct({ phantom: i128(250000000000n), threshold: i128(93000000000n), quote_reserve: i128(289000000000n), token_reserve: i128(6920415224913495n), real_quote: i128(39000000000n), creator_fees: i128(3900000n), completed: bool(false), graduated: bool(false), pair: xdr.ScVal.scvVoid() })
      : struct({ phantom: i128(250000000000n), threshold: i128(93000000000n), quote_reserve: i128(0n), token_reserve: i128(0n), real_quote: i128(0n), creator_fees: i128(0n), completed: bool(true), graduated: bool(true), pair: addr(GRAD_ROW.pair as string) });
  }
  if (fn === "balance" && contract === ECAT) return i128(12000000000000n);
  if (fn === "quote_buy") {
    if (quoteError) return { error: quoteError };
    return struct({ used: i128(500000000n), net: i128(490000000n), base_fee: i128(5000000n), creator_fee: i128(5000000n), snipe_fee: i128(0n), tokens_out: i128(11952000000000n) });
  }
  if (fn === "quote_sell") return struct({ gross: i128(100000000n), base_fee: i128(1000000n), creator_fee: i128(1000000n), quote_out: i128(98000000n) });
  if (contract === e.launchpad.contract && fn === "config") {
    return struct({
      admin: addr(ME),
      treasury: addr(e.moments.treasury),
      token_wasm_hash: xdr.ScVal.scvBytes(Buffer.alloc(32, 1)),
      soroswap_factory: addr(TESTNET.contracts.soroswapFactory),
      supply: i128(BigInt(e.launchpad.supply)),
      fee_bps: u32(e.launchpad.feeBps),
      protocol_share_bps: u32(e.launchpad.protocolShareBps),
      max_creator_fee_bps: u32(e.launchpad.maxCreatorFeeBps),
      snipe_schedule: xdr.ScVal.scvVec(e.launchpad.snipeSchedule.map(u32)),
      launches_enabled: bool(e.launchpad.launchesEnabled),
    });
  }
  if (contract === e.launchpad.contract && fn === "quote_economics") {
    const q = e.launchpad.quotes.find((x: Row) => x.contract === arg(0));
    return q ? struct({ phantom: i128(BigInt(q.phantom)), threshold: i128(BigInt(q.threshold)), enabled: bool(q.enabled) }) : xdr.ScVal.scvVoid();
  }
  if (contract === e.moments.contract && fn === "config") {
    return struct({ admin: addr(ME), treasury: addr(e.moments.treasury), platform_bps: u32(e.moments.platformBps), royalty_bps: u32(e.moments.royaltyBps), publishing_enabled: bool(e.moments.publishingEnabled) });
  }
  if (contract === e.moments.contract && fn === "quote_rule") {
    const id = TESTNET.assets.find((a) => a.contract === arg(0))?.id;
    const q = e.moments.quotes.find((x: Row) => x.asset === id);
    return q ? struct({ min_price: i128(BigInt(q.minPrice)), enabled: bool(q.enabled) }) : xdr.ScVal.scvVoid();
  }
  return { error: "HostError: Error(Contract, #1)" };
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    if (body.method !== "simulateTransaction") return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32601, message: body.method } });
    const tx = TransactionBuilder.fromXDR(body.params.transaction, TESTNET.passphrase) as Transaction;
    const call = (tx.operations[0] as any).func.invokeContract();
    const a = answer(Address.fromScAddress(call.contractAddress()).toString(), call.functionName().toString(), call.args());
    const result = a instanceof xdr.ScVal ? { latestLedger: 1, results: [{ auth: [], xdr: a.toXDR("base64") }], events: [] } : { latestLedger: 1, error: a.error };
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  if (url.origin === STORAGE) return Response.json({ Key: url.pathname });
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** A copy of `value` with each [path, value] of `errata` set ("launches.0.priceUsd"). */
function corrected<T>(value: T, errata: [string, unknown][]): T {
  const out = structuredClone(value) as any;
  for (const [path, v] of errata) {
    const keys = path.split(".");
    const last = keys.pop()!;
    let at = out;
    for (const k of keys) at = at[k];
    assert(last in at, `${path} is in the fixture`);
    at[last] = v;
  }
  return out;
}

/** `got` holds everything `legacy` holds, unchanged: an older client reads what it always read. */
function assertHolds(got: unknown, legacy: unknown, at = "body"): void {
  if (Array.isArray(legacy)) {
    assert(Array.isArray(got) && got.length === legacy.length, `${at}: ${JSON.stringify(got)}`);
    legacy.forEach((v, i) => assertHolds(got[i], v, `${at}[${i}]`));
  } else if (legacy !== null && typeof legacy === "object") {
    for (const [k, v] of Object.entries(legacy)) assertHolds((got as Record<string, unknown>)[k], v, `${at}.${k}`);
  } else {
    assertEquals(got, legacy, at);
  }
}

// What the API serves where the fixtures' figures are inconsistent (see ERRATA above).
const ECAT_PRICE_USD = 0.00000792717;
const ECAT_ERRATA = (prefix: string): [string, unknown][] => [[`${prefix}.priceUsd`, ECAT_PRICE_USD]];

// ------------------------------------------------------------------------------------------------ the board

Deno.test("GET /v1/launches equals launches.json: Explore, newest first, a page of 2 with the next one's cursor, the counts", async () => {
  database();
  const board = await lp.launchBoard(lp.boardQuery(new URLSearchParams("section=explore&sort=newest&limit=2")), "owner", NOW);
  assertEquals(board, corrected(fixture("launches"), [
    ["launches.0.priceUsd", 0.00000895371],
    ["launches.0.marketCapQuote", "47100"],
    ["launches.0.marketCapUsd", 8953.71],
    ...ECAT_ERRATA("launches.1"),
  ]));
});

Deno.test("GET /v1/launches?sort=new (older clients) answers {launches} holding every field of launches.legacy.json", async () => {
  database([ECAT_ROW]);
  const board = await lp.launchBoard(lp.boardQuery(new URLSearchParams("sort=new")), "owner", NOW);
  assertEquals(Object.keys(board), ["launches", "view"]);
  assertHolds(board, fixture("launches.legacy"));
});

// ------------------------------------------------------------------------------------------------ a launch's page

Deno.test("GET /v1/launches/:token equals launch.json (owner) and launch.public.json (public view), and holds launch.legacy.json", async () => {
  database();
  const owner = await lp.launchDetail(ECAT, { address: ME, scope: "owner" }, "1m", NOW);
  assertEquals(owner, corrected(fixture("launch"), [...ECAT_ERRATA("launch"), ...ECAT_ERRATA("stats")]));
  assertHolds(owner, fixture("launch.legacy"));
  database();
  const anyone = await lp.launchDetail(ECAT, { address: ME, scope: "public" }, "1m", NOW);
  assertEquals(anyone, corrected(fixture("launch.public"), [...ECAT_ERRATA("launch"), ...ECAT_ERRATA("stats")]));
  // Without ?address=, no `you`.
  database();
  assertEquals((await lp.launchDetail(ECAT, { address: null, scope: "public" }, "1m", NOW)).you, null);
});

Deno.test("a launch's curve: the public view keeps a read 30 s, the owner's page and a sell quote read it fresh", async () => {
  database();
  curveReads = 0;
  const anyone = { address: null, scope: "public" } as const;
  await lp.launchDetail(ECAT, anyone, undefined, NOW);
  await lp.launchDetail(ECAT, anyone, undefined, NOW + 29_000);
  assertEquals(curveReads, 1, "the public view, read once in 30 s");
  await lp.launchDetail(ECAT, anyone, undefined, NOW + 30_000);
  assertEquals(curveReads, 2, "and again after them");
  // The owner may have just traded: a page kept from before the trade would show the curve as it was.
  await lp.launchDetail(ECAT, { address: ME, scope: "owner" }, undefined, NOW + 31_000);
  await lp.launchDetail(ECAT, { address: ME, scope: "owner" }, undefined, NOW + 32_000);
  assertEquals(curveReads, 4, "the owner's page, every time");
  // A sell checks that the curve still trades, so it reads it even with a read just kept (quotes run on the clock).
  await lp.launchDetail(ECAT, anyone, undefined, Date.now());
  const kept = curveReads;
  await lp.quoteTrade(ME, ECAT, "sell", 10n ** 12n);
  assertEquals(curveReads, kept + 1, "a sell quote, every time");
});

// ------------------------------------------------------------------------------------------------ My Launchpad

Deno.test("GET /v1/launchpad/me equals launchpad-me.json", async () => {
  database();
  assertEquals(await lp.myLaunchpad(ME, NOW), corrected(fixture("launchpad-me"), [
    ["held.0.valueUsd", 9.51],
    ["held.0.pnlUsd", -0.05],
    ...ECAT_ERRATA("held.0.launch"),
    ["created.0.launch.priceUsd", 0.00000954302],
    ["created.0.launch.marketCapQuote", "43925"],
    ["created.0.launch.marketCapUsd", 8350.14],
  ]));
});

// ------------------------------------------------------------------------------------------------ the rest

Deno.test("GET /v1/economics equals economics.json, read from the contracts it names", async () => {
  forgetEconomics();
  const e = fixture("economics");
  const net = { ...TESTNET, contracts: { ...TESTNET.contracts, launchpad: e.launchpad.contract, moments: e.moments.contract } };
  assertEquals(await economics(net, NOW), e);
});

Deno.test("POST /v1/launches/metadata equals launch-metadata.json", async () => {
  database();
  const uuid = crypto.randomUUID;
  crypto.randomUUID = () => "dfa28083-2b5f-479f-a4d9-929151a326f1";
  try {
    assertEquals(await writeLaunchMetadata(ME, { name: "E2E Cat", symbol: "ECAT" }), fixture("launch-metadata"));
  } finally {
    crypto.randomUUID = uuid;
  }
});

Deno.test("POST /v1/launches/:token/quote equals launch-quote.json, and holds the older clients' buy and sell", async () => {
  const buy = await lp.quoteTrade(ME, ECAT, "buy", 500_000_000n);
  assertEquals(buy, fixture("launch-quote"));
  assertHolds(buy, fixture("launch-quote.legacy"));
  database();
  assertHolds(await lp.quoteTrade(ME, ECAT, "sell", 2_410_000_000_000n), fixture("launch-quote-sell.legacy"));
});

Deno.test("a contract's refusal is error-contract.json: simulation_failed with its stable code", async () => {
  const raw = `HostError: Error(Contract, #10)\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${TESTNET.contracts.launchpad}, topics:[error, Error(Contract, #10)], data:"escalating error to VM trap from failed host function call: fail_with_error"\n   1: [Diagnostic Event] contract:${TESTNET.contracts.launchpad}, topics:[error, Error(Contract, #10)], data:["failing with contract error", 10]`;
  quoteError = raw;
  try {
    const err = await lp.quoteTrade(ME, ECAT, "buy", 500_000_000n).catch((e) => e);
    const body = await errorResponse(err).json();
    assertEquals(body, corrected(fixture("error-contract"), [["error.detail.raw", raw]]));
  } finally {
    quoteError = null;
  }
});

Deno.test("launchMarketRows() feeds /v1/markets: ECAT's row is markets.json's launch row, listed after the registry", async () => {
  database([ECAT_ROW]);
  const raw = await lp.launchMarketRows(NOW);
  assertEquals(raw.length, 1);
  const row = m.launchRow(raw[0])!;
  const markets = fixture("markets");
  assertEquals(row, corrected(markets.rows[2], [["priceUsd", ECAT_PRICE_USD]]));
  assertEquals(m.popular(markets.rows.slice(0, 2), [row]).map((r) => r.id), ["XLM", "USDC", ECAT]);
});
