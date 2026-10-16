// WP-18's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md §6.0,
// §6.5, §6.6, §6.7, §6.10, §12.5), answered by the API itself (lite/index.ts) from seeded Horizon, RPC, Blend and
// database data that carry the fixtures' figures:
// - GET /v1/holdings as its owner (holdings.json, its launch balance read live), with the launch part unread
//   (holdings.partial.json), and the public view for ?address= with no token (holdings.public.json): cached 15 s, the
//   same for a member and anyone else, with no balance() call (a counting stand-in for RPC) and, over RPC, only Earn's
//   read of what the account supplies to each Blend pool (an on-chain fact §6.5 keeps; counted at Blend's stand-in);
// - GET /v1/portfolio?period=week (portfolio.json): each section's figures come from rows worked back from the
//   fixture's, and its activity from the period's items the fixture lists (the launch buy and the bridge transfer);
// - GET /v1/activity (activity.json), which never names a token by a stand-in, nor do the rows an API before WP-10
//   logged with one (their summary and display name the token);
// - GET /v1/assets: each of assets.json's results is what a search for it finds (no one query finds all four).
// Two of the fixtures' figures aren't what §6.5 gives for their own rows, and the comparisons put §6.5's in their place
// (WP-03's fixtures to be corrected): AQUA's contract (the SAC of AQUA:GAX2… on testnet is CBWKQU57…, not CALSEG…),
// and holdings.json's 24-hour change (−$22.89, −1.17%: Σ value × c / (1 + c) over XLM, USDC, ECAT and the XLM in
// Blend, not −$22.63, −1.16%).
import { Address, Asset, nativeToScVal, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { signJwt } = await import("../../supabase/functions/_shared/auth.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { replacePools } = await import("../../supabase/functions/_shared/earn.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { forgetPublicHoldings } = await import("../../supabase/functions/_shared/holdings.ts");
const { portfolio } = await import("../../supabase/functions/_shared/portfolio.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`../fixtures/api/${name}.json`, import.meta.url)));
const PASS = TESTNET.passphrase;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const POOL = TESTNET.contracts.blendPools[0].id;
const HOLDINGS = fixture("holdings");
const ME: string = HOLDINGS.address;
const ECAT: string = HOLDINGS.launch[0].token;
const AQUA_ISSUER = "GAX2PVUCCLITL6T6ESGOJFHA234KIOUSINBZ2BNLPK47PYFS5MCZL2LO";
const AQUA = `AQUA:${AQUA_ISSUER}`;
const AQUA_SAC = new Asset("AQUA", AQUA_ISSUER).contractId(PASS);
const WAVE = "CAG7HXJ65BFFSKCG4OE64UCFY7DZXSANMPNYNXO4OOGWCDP6XM7OSGWG";
const NOW = Date.parse("2026-10-14T09:41:00.000Z");
const at = (iso: string) => new Date(iso);
/** The old stand-in for a token's name (§9), spelled in two parts so the placeholder scan finds it only where it would
 *  be a placeholder. */
const PLACEHOLDER = ["TOK", "EN"].join("");

// ------------------------------------------------------------------------------------------------ the seeded world

const world = {
  /** The reference prices. */
  xlmUsd: "0.1901",
  usdcUsd: "0.9999",
  /** The account's AQUA, as Horizon writes it. */
  aqua: "25.0000000",
  /** The name AQUA's issuer publishes (the asset directory's). */
  aquaName: null as string | null,
  /** Horizon can't read the account. */
  horizonDown: false,
  /** What the account supplies to Blend's XLM market. */
  supplied: 1_000_012_340n,
  /** The holdings' launch read fails. */
  launchesFail: false,
  /** The account is a tester. */
  member: true,
  /** RPC requests made. */
  rpcCalls: 0,
  /** Blend's pools read for what the account supplies (an RPC read in Blend's SDK, which the stand-in replaces). */
  poolReads: 0,
  /** GET /v1/activity's and Portfolio's rows. */
  activityTxs: [] as Record<string, unknown>[],
  /** GET /v1/activity's last read of the log: its text and parameters. */
  activityQuery: null as [string, unknown[]] | null,
  activityBridges: [] as Record<string, unknown>[],
  cash: [] as Record<string, unknown>[],
};

const line = (code: string, issuer: string, balance: string) => ({
  balance,
  limit: "922337203685.4775807",
  buying_liabilities: "0.0000000",
  selling_liabilities: "0.0000000",
  asset_type: "credit_alphanum4",
  asset_code: code,
  asset_issuer: issuer,
});

/** Horizon's account: 10,000 XLM, 5.23 USDC and some AQUA, one subentry counted (holdings.json's xlm). */
function horizonAccount() {
  return {
    id: ME,
    account_id: ME,
    sequence: "22096910953218050",
    subentry_count: 1,
    num_sponsoring: 0,
    num_sponsored: 0,
    signers: [],
    balances: [
      line("USDC", USDC.classic!.split(":")[1], "5.2300000"),
      line("AQUA", AQUA_ISSUER, world.aqua),
      { balance: "10000.0000000", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "native" },
    ],
  };
}

const answer = (v: xdr.ScVal) => ({
  latestLedger: 1,
  minResourceFee: "1000",
  transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
  results: [{ auth: [], xdr: v.toXDR("base64") }],
  events: [],
});

/** The token views the routes read: ECAT's balance (holdings.json's 1,200,000), and WAVE, a SEP-41 token. */
function simulate(params: { transaction: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fn = call.functionName().toString();
  if (contract === ECAT && fn === "balance") return answer(nativeToScVal(12_000_000_000_000n, { type: "i128" }));
  if (contract === WAVE && fn === "symbol") return answer(nativeToScVal("WAVE", { type: "string" }));
  if (contract === WAVE && fn === "name") return answer(nativeToScVal("Wave", { type: "string" }));
  if (contract === WAVE && fn === "decimals") return answer(nativeToScVal(7, { type: "u32" }));
  if (contract === WAVE && fn === "balance") return answer(nativeToScVal(0n, { type: "i128" }));
  return { latestLedger: 1, error: "HostError: Error(Contract, #1)" };
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === `/accounts/${ME}`) {
    return world.horizonDown ? new Response("down", { status: 503 }) : Response.json(horizonAccount());
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    world.rpcCalls++;
    const body = await req.json();
    return Response.json({ jsonrpc: "2.0", id: body.id, result: body.method === "simulateTransaction" ? simulate(body.params) : null });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** Blend's pool: the XLM market, and what the account supplies to it. */
const reserves = () => new Map([[XLM.contract, { decimals: 7, supplyApy: 0.031, borrowApy: 0.054, utilization: 0.61, supplied: 182_345_671_200_000n, borrowed: 111_230_859_432_000n }]]);
replacePools({
  read: () => Promise.resolve({ status: 0, reserves: reserves() }),
  supplies: () => {
    world.poolReads++;
    return Promise.resolve({ state: { status: 0, reserves: reserves() }, supplied: new Map([[XLM.contract, { supply: world.supplied, collateral: 0n }]]) });
  },
});

/** ECAT on its curve at 0.0000415571 XLM ($0.0000079), 12% up on a day, 41.93% of the way to graduation. */
const ECAT_ROW = {
  token: ECAT,
  creator: "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN",
  quote: XLM.contract,
  name: "E2E Cat",
  symbol: "ECAT",
  uri: "",
  supply: "10000000000000000",
  phantom: "300000000000",
  burned: "0",
  quote_reserve: "320965000000",
  token_reserve: "7723400000000000",
  real_quote: "20965000000",
  threshold: "50000000000",
  completed: false,
  graduated: false,
  pair: null,
  last_price: "0.0000415571",
  volume_quote: "20965000000",
  trades: 4,
  image_url: HOLDINGS.launch[0].image,
  look_alike: false,
  created_at: at("2026-10-13T07:00:00.000Z"),
};

const EDITIONS = HOLDINGS.moments.editions.map((e: Record<string, unknown>) => ({
  token_id: e.tokenId,
  moment_id: e.momentId,
  contract: e.contract,
  title: e.title,
  media_url: e.mediaUrl,
  poster_url: e.posterUrl,
  media_type: e.mediaType,
}));

/** XLM in base units for `usd` at XLM's reference price (Portfolio's rows, worked back from its figures). */
const xlmFor = (usd: number) => Math.round((usd / 0.1901) * 1e7);

/** The account's week, as portfolio.json's figures need it. */
const PORTFOLIO_TXS = [
  // Spot: 100 XLM ($19.01) for 18.9718972 USDC ($18.97).
  {
    kind: "swap",
    section: "spot",
    status: "success",
    fee_payer: "user",
    fee_charged: "41210",
    intent: { spend: { [XLM.contract]: "1000000000" }, receive: { [USDC.contract]: "188000000" }, display: { amountIn: "1000000000" } },
    result: { amountOut: "189718972" },
  },
  { kind: "earn_deposit", section: "earn", status: "success", fee_payer: "user", fee_charged: "1250000", intent: {}, result: null },
  // The launch trades as logged: their network fees only.
  { kind: "launch_buy", section: "launch", status: "success", fee_payer: "user", fee_charged: "41210", intent: {}, result: null },
  { kind: "launch_sell", section: "launch", status: "success", fee_payer: "user", fee_charged: "41210", intent: {}, result: null },
  { kind: "moment_collect", section: "moments", status: "success", fee_payer: "user", fee_charged: "2010000", intent: {}, result: null },
  { kind: "approve", section: "bridge", status: "success", fee_payer: "user", fee_charged: "100000", intent: {}, result: null },
  { kind: "bridge_out", section: "bridge", status: "success", fee_payer: "user", fee_charged: "200000", intent: {}, result: null },
  // Counted in no section: the account's own setup.
  { kind: "trust", section: "account", status: "success", fee_payer: "user", fee_charged: "10000", intent: {}, result: null },
];

/** The launch buy portfolio.json and activity.json list. */
const LAUNCH_BUY = {
  hash: "e8c10a640996c1bfdf8c8c69989b344dce8daeefdfd356454c630f4357999225",
  address: ME,
  kind: "launch_buy",
  intent: {
    kind: "launch_buy",
    summary: "Buy ECAT with 50 XLM",
    spend: { [XLM.contract]: "500000000" },
    receive: { [ECAT]: "11880000000000" },
    display: { token: ECAT, symbol: "ECAT", quote: "XLM", amount: "500000000", minOut: "11880000000000" },
  },
  status: "success",
  ledger: 5_300_000,
  created_at: at("2026-10-14T09:29:00.000Z"),
  section: "launch",
  fee_charged: "41210",
  fee_payer: "user",
  result: { amountOut: "12000000000000" },
};

/** A transfer from Monad, completed: its message is kept, Circle took no fee. */
const BRIDGE_IN = (amount: string) => ({
  id: "c69ef4a0-421e-418d-a93b-92081f4a0fcb",
  direction: "monad_to_stellar",
  amount,
  status: "completed",
  source_tx: `0x${"ab".repeat(32)}`,
  dest_tx: null,
  message: `0x${"00".repeat(148 + 228)}`,
  created_at: at("2026-10-13T07:41:00.000Z"),
});

replaceSql(fakeSql((q, ps) => {
  if (q === "select 1 from lite.testers where address = ? and revoked_at is null") return world.member ? [{ "?column?": 1 }] : [];
  if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
    return [
      { ref: "XLM", usd: world.xlmUsd, source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date() },
      { ref: "USDC", usd: world.usdcUsd, source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date() },
    ];
  }
  if (q.startsWith("select ref, lite.ref_usd_at(ref, ?) as usd from unnest(")) return [{ ref: "XLM", usd: "0.1901" }, { ref: "USDC", usd: "0.9999" }];
  // AQUA's issuer publishes nothing about it, or a name.
  if (q.startsWith("select asset, home_domain, name, image from lite.asset_directory")) return [{ asset: AQUA, home_domain: null, name: world.aquaName, image: null }];
  // Holdings: ECAT, its one buy, the editions.
  if (q.startsWith("select l.*, coalesce(tb.balance, 0) as indexed_balance")) {
    if (world.launchesFail) throw new Error("the launch read failed");
    return [{ ...ECAT_ROW, indexed_balance: "12000000000000", price_24h: "0.00003710455357142857" }];
  }
  if (q.startsWith("select token, side, quote_amount, token_amount from (")) {
    return [{ token: ECAT, side: "buy", quote_amount: "500000000", token_amount: "12000000000000" }];
  }
  if (q.includes("from lite.moment_editions e join lite.moments m")) return EDITIONS;
  // Earn's record: one deposit of 100 XLM, in the week.
  if (q.startsWith("select kind, intent") && q.includes("kind in ('earn_deposit', 'earn_withdraw') and status = 'success'")) {
    const intent = { kind: "earn_deposit", summary: "", spend: { [XLM.contract]: "1000000000" }, calls: [{ contract: POOL, fn: "submit" }] };
    return [{ kind: "earn_deposit", intent, created_at: at("2026-10-10T12:00:00.000Z") }];
  }
  // Portfolio's week.
  if (q.startsWith("select kind, section, status, fee_payer, fee_charged, intent, result from lite.tx_log t")) return PORTFOLIO_TXS;
  if (q.startsWith("select f.token, l.quote, f.side, f.quote_amount, f.token_amount, f.fees from (")) {
    // A buy and a sell on the curve: $9.50 traded, $0.19 of fees, a $0.02 loss at today's ECAT price.
    const traded = xlmFor(9.5);
    const fees = xlmFor(0.19);
    return [
      { token: ECAT, quote: XLM.contract, side: "buy", quote_amount: "400000000", token_amount: "9600000000000", fees: String(fees - 997_370) },
      { token: ECAT, quote: XLM.contract, side: "sell", quote_amount: String(traded - 400_000_000), token_amount: "2400000000000", fees: "997370" },
    ];
  }
  if (q.startsWith("select l.quote, c.amount from lite.creator_claims")) return [];
  if (q.startsWith("select m.quote, c.paid, m.platform_bps from lite.moment_collects")) return [{ quote: XLM.contract, paid: String(xlmFor(0.38)), platform_bps: 500 }];
  if (q.startsWith("select m.quote, sum(lite.moment_creator_share(c.paid, m.platform_bps)) as amount")) return [{ quote: XLM.contract, amount: String(xlmFor(0.36)) }];
  if (q.startsWith("select direction, amount, message from lite.bridge_transfers b")) return [BRIDGE_IN("12501250")];
  if (q === "select min(created_at) as first from lite.tx_log where address = ?") return [{ first: at("2026-10-05T09:41:00.000Z") }];
  // GET /v1/activity's rows (Portfolio's: the period's settled ones).
  if (q.startsWith("select hash, address, kind, intent, status, ledger, created_at, section, fee_charged, fee_payer, result from lite.tx_log t")) {
    world.activityQuery = [q, ps];
    return world.activityTxs;
  }
  if (q.startsWith("select id, direction, amount, status, source_tx, dest_tx, created_at from lite.bridge_transfers b")) return world.activityBridges;
  if (q.startsWith("select id, anchor, kind, asset, amount, status, created_at from lite.anchor_transfers c")) return world.cash;
  if (q.startsWith("select * from lite.launches where token = any(")) return (ps[0] as string[]).includes(ECAT) ? [ECAT_ROW] : [];
  // The asset search: the listed launches it finds, ECAT held.
  if (q.startsWith("select l.token, l.symbol, l.name, l.look_alike from lite.launches l where l.listed")) {
    return ps.some((p) => p === ECAT || String(p).toLowerCase().includes("ecat")) ? [{ token: ECAT, symbol: "ECAT", name: "E2E Cat", look_alike: false }] : [];
  }
  if (q === "select token from lite.token_balances where address = ? and balance > 0") return [{ token: ECAT }];
  if (q === "select token, symbol, name from lite.launches where token = ?") return [];
  throw new Error(`unexpected query: ${q}`);
}));

const token = await signJwt({ sub: ME, net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 4_102_444_800, iat: 1_760_400_000 });

async function ask(path: string, auth: string | null = token) {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite/v1${path}`, {
    headers: { ...(auth ? { authorization: `Bearer ${auth}` } : {}), "x-forwarded-for": "198.51.100.18" },
  }));
  const text = await res.text();
  return { status: res.status, cache: res.headers.get("cache-control"), text, body: JSON.parse(text) };
}

/** A holdings fixture as §6.5 answers it from its own rows (see the head of this file), at the answer's time. */
function asAnswered(f: Record<string, any>, asOf: string): Record<string, unknown> {
  const spot = f.spot.map((r: Record<string, unknown>) => (r.id === AQUA ? { ...r, contract: AQUA_SAC } : r));
  const change24h = f.change24h.usd === null ? f.change24h : { usd: -22.89, pct: -0.0117, complete: false };
  return { ...f, asOf, spot, change24h };
}

function reset(): void {
  Object.assign(world, { xlmUsd: "0.1901", usdcUsd: "0.9999", aqua: "25.0000000", aquaName: null, horizonDown: false, supplied: 1_000_012_340n, launchesFail: false, member: true, rpcCalls: 0, poolReads: 0 });
  forgetReferencePrices();
  forgetPublicHoldings();
}

// ------------------------------------------------------------------------------------------------ holdings

Deno.test("GET /v1/holdings as its owner is holdings.json, ECAT's balance confirmed live", async () => {
  reset();
  const h = await ask("/holdings");
  assertEquals([h.status, h.cache], [200, "no-store"]);
  assertEquals(h.body, asAnswered(HOLDINGS, h.body.asOf));
  assert(world.rpcCalls >= 1, "the owner's launch balance is read live");
  // The 24-hour change, by hand: XLM 1901 × −0.0123/0.9877, USDC 5.2295 × 0.0001/1.0001, ECAT 9.48 × 0.12/1.12 and the
  // XLM in Blend 19.01 × −0.0123/0.9877; over the value a day ago, 1934.7195 + 22.894.
  const moved = (1901 * -0.0123) / 0.9877 + (5.2295 * 0.0001) / 1.0001 + (9.48 * 0.12) / 1.12 + (19.01 * -0.0123) / 0.9877;
  assertEquals([h.body.change24h.usd, h.body.change24h.pct], [Math.round(moved * 100) / 100, Math.round((moved / (1934.7195 - moved)) * 1e4) / 1e4]);
});

Deno.test("GET /v1/holdings with the launch part unread is holdings.partial.json: no total, nothing complete", async () => {
  reset();
  world.launchesFail = true;
  const error = console.warn;
  console.warn = () => {};
  try {
    const h = await ask("/holdings");
    assertEquals(h.body, { ...asAnswered(fixture("holdings.partial"), h.body.asOf), view: "owner" });
  } finally {
    console.warn = error;
  }
});

Deno.test("GET /v1/holdings?address= with no token is holdings.public.json, cached 15 s, with no balance() call, for anyone", async () => {
  reset();
  const pub = await ask(`/holdings?address=${ME}`, null);
  assertEquals([pub.status, pub.cache], [200, "public, max-age=15"]);
  assertEquals(pub.body, asAnswered(fixture("holdings.public"), pub.body.asOf));
  // No RPC call of its own; Earn's read of each pool is the one §6.5 keeps.
  const pools = TESTNET.contracts.blendPools.length;
  assertEquals([world.rpcCalls, world.poolReads], [0, pools]);
  // Kept 15 s: the same answer, byte for byte, read from nothing.
  assertEquals((await ask(`/holdings?address=${ME}`, null)).text, pub.text);
  assertEquals([world.rpcCalls, world.poolReads], [0, pools]);
  // The same for an account that isn't a tester: the public view never asks.
  forgetPublicHoldings();
  world.member = false;
  const anyone = await ask(`/holdings?address=${ME}`, null);
  assertEquals({ ...anyone.body, asOf: pub.body.asOf }, pub.body);
  assertEquals([world.rpcCalls, world.poolReads], [0, 2 * pools]);
});

// ------------------------------------------------------------------------------------------------ portfolio

Deno.test("GET /v1/portfolio?period=week is portfolio.json", async () => {
  reset();
  world.supplied = 1_000_000_000n + 120_990n;
  world.activityTxs = [LAUNCH_BUY];
  world.activityBridges = [BRIDGE_IN("12501250")];
  world.cash = [];
  assertEquals(await portfolio(ME, "week", NOW), fixture("portfolio"));
  const p = await ask("/portfolio?period=week");
  assertEquals([p.status, p.cache], [200, "no-store"]);
  assertEquals(Date.parse(p.body.asOf) - Date.parse(p.body.since), 7 * 86_400_000);
  assertEquals({ ...p.body, asOf: NOW, since: NOW }, { ...fixture("portfolio"), asOf: NOW, since: NOW });
  // DyorHQ's history: a session route.
  assertEquals((await ask("/portfolio?period=week", null)).status, 401);
});

// ------------------------------------------------------------------------------------------------ activity

Deno.test("GET /v1/activity is activity.json, and never names a token by a stand-in", async () => {
  reset();
  // activity.json's world: XLM at $0.19, USDC at $1.
  world.xlmUsd = "0.19";
  world.usdcUsd = "1";
  world.activityTxs = [
    LAUNCH_BUY,
    {
      hash: "c3a436e46b4a0dcb674825bff51c9977e2b3766663a5bfdf84e2f71b7649a793",
      address: ME,
      kind: "swap",
      intent: {
        kind: "swap",
        summary: "Swap 10 XLM for at least 1.8843341 USDC",
        spend: { [XLM.contract]: "100000000" },
        receive: { [USDC.contract]: "18843366" },
        display: { venue: "soroswap", sell: "XLM", buy: "USDC", amountIn: "100000000", minOut: "18843366" },
      },
      status: "success",
      ledger: 5_299_800,
      created_at: at("2026-10-14T09:11:00.000Z"),
      section: "spot",
      fee_charged: "41210",
      fee_payer: "user",
      result: { amountOut: "18938032" },
    },
  ];
  world.activityBridges = [BRIDGE_IN("12500000")];
  world.cash = [{ id: "d77e0470-cc55-4be3-af10-ba7f5dbd99f0", anchor: "testanchor.stellar.org", kind: "deposit", asset: "USDC", amount: "50", status: "completed", created_at: at("2026-10-12T09:41:00.000Z") }];
  const a = await ask("/activity");
  assertEquals([a.status, a.cache], [200, "no-store"]);
  assertEquals(a.body, fixture("activity"));
  assert(!new RegExp(`\\b${PLACEHOLDER}\\b|"Token"`).test(a.text), a.text.slice(0, 300));
  assertEquals((await ask("/activity", null)).status, 401);
});

Deno.test("GET /v1/activity names the tokens an API before WP-10 logged by a stand-in, in the section the migration gave", async () => {
  reset();
  // As migration 10 leaves them: the section its backfill gave; the sponsor paid; no result kept.
  const legacy = (hash: string, kind: string, section: string, intent: Record<string, unknown>) => ({
    hash: hash.repeat(64),
    address: ME,
    kind,
    intent: { kind, ...intent },
    status: "success",
    ledger: 5_000_000,
    // The first newest.
    created_at: at(`2026-10-12T09:${50 - Number(hash)}:00.000Z`),
    section,
    fee_charged: "100",
    fee_payer: "sponsor",
    result: null,
  });
  world.activityTxs = [
    legacy("1", "swap", "launch", {
      summary: `Swap 10 XLM for at least 240000 ${PLACEHOLDER}`,
      spend: { [XLM.contract]: "100000000" },
      receive: { [ECAT]: "2400000000000" },
      display: { venue: "soroswap", sell: "XLM", buy: PLACEHOLDER, amountIn: "100000000", minOut: "2400000000000" },
    }),
    legacy("2", "swap", "launch", {
      summary: `Swap 1000 ${PLACEHOLDER} for at least 5 ${PLACEHOLDER}`,
      spend: { [ECAT]: "10000000000" },
      receive: { [WAVE]: "50000000" },
      display: { venue: "soroswap", sell: PLACEHOLDER, buy: PLACEHOLDER, amountIn: "10000000000", minOut: "50000000" },
    }),
    legacy("3", "payment", "spot", {
      summary: `Send 5 ${PLACEHOLDER}`,
      spend: { [WAVE]: "50000000" },
      display: { asset: PLACEHOLDER, amount: "5", to: AQUA_ISSUER, memo: null },
    }),
  ];
  world.activityBridges = [];
  world.cash = [];
  const a = await ask("/activity");
  assertEquals(a.status, 200);
  assert(!new RegExp(`\\b${PLACEHOLDER}\\b|"Token"`).test(a.text), a.text.slice(0, 300));
  const wave = `${WAVE.slice(0, 4)}…${WAVE.slice(-4)}`;
  assertEquals(a.body.items.map((i: any) => [i.section, i.summary, i.display.sell ?? i.display.asset, i.display.buy ?? null, i.title, i.subtitle, i.symbol]), [
    ["launch", "Swap 10 XLM for at least 240000 ECAT", "XLM", "ECAT", "Swapped", "XLM → ECAT", "ECAT"],
    ["launch", `Swap 1000 ECAT for at least 5 ${wave}`, "ECAT", wave, "Swapped", `ECAT → ${wave}`, null],
    ["spot", `Send 5 ${wave}`, wave, null, `Sent ${wave}`, `5 ${wave} to GAX2…L2LO`, null],
  ]);
  // The rest as logged.
  assertEquals(a.body.items[0].display, { venue: "soroswap", sell: "XLM", buy: "ECAT", amountIn: "100000000", minOut: "2400000000000" });
  assertEquals([a.body.items[0].feePayer, a.body.items[0].result, a.body.items[0].ref], ["sponsor", null, { token: ECAT }]);
});

Deno.test("GET /v1/activity?section= filters on the section the items carry: a row of a kind no section counts is the account's", async () => {
  reset();
  world.activityTxs = [{ ...LAUNCH_BUY, kind: "mystery", section: null, intent: { kind: "mystery", summary: "Something" } }];
  world.activityBridges = [];
  world.cash = [];
  const a = await ask("/activity");
  assertEquals(a.body.items.map((i: any) => [i.kind, i.section]), [["mystery", "account"]]);
  // The filter reads the same section (portfolio_test.sql runs it).
  await ask("/activity?section=account");
  const [q, ps] = world.activityQuery!;
  assert(q.includes("and coalesce(t.section, 'account') = ?"), q);
  assert(ps.includes("account"));
});

// ------------------------------------------------------------------------------------------------ asset search

Deno.test("GET /v1/assets finds each of assets.json's results, held as the owner holds them", async () => {
  reset();
  // The account has AQUA enabled, and none of it.
  world.aqua = "0.0000000";
  const expected = fixture("assets");
  const found = [];
  for (const [q, id] of [["USDC", "USDC"], ["ECAT", ECAT], [AQUA, AQUA], [WAVE, WAVE]]) {
    const r = await ask(`/assets?q=${encodeURIComponent(q)}`);
    assertEquals([r.status, r.body.view], [200, "owner"], q);
    found.push(r.body.results.find((x: { id: string }) => x.id === id));
  }
  const results = expected.results.map((r: Record<string, unknown>) => (r.id === AQUA ? { ...r, contract: AQUA_SAC } : r));
  assertEquals({ results: found, view: "owner" }, { ...expected, results });
});

Deno.test("GET /v1/assets finds the account's other trustlines by the name their issuer publishes, as well as by code", async () => {
  reset();
  world.aquaName = "Aquarius";
  for (const q of ["aquarius", "AQU"]) {
    const r = await ask(`/assets?q=${q}`);
    assertEquals(r.body.results.map((x: { id: string; name: string | null; held: boolean }) => [x.id, x.name, x.held]), [[AQUA, "Aquarius", true]], q);
  }
  assertEquals((await ask("/assets?q=Neptune")).body.results, []);
});

Deno.test("GET /v1/assets still answers when Horizon can't read the account: nothing held but what the index holds", async () => {
  reset();
  world.horizonDown = true;
  const warn = console.warn;
  console.warn = () => {};
  try {
    const usdc = await ask("/assets?q=USDC");
    assertEquals([usdc.status, usdc.body.results.map((x: { id: string; held: boolean }) => [x.id, x.held])], [200, [["USDC", false], ["BUSDC", false]]]);
    // A launch's held is the index's.
    const ecat = await ask("/assets?q=ECAT");
    assertEquals([ecat.status, ecat.body.results.map((x: { id: string; held: boolean }) => [x.id, x.held])], [200, [[ECAT, true]]]);
  } finally {
    console.warn = warn;
  }
});
