// Holdings (_shared/holdings.ts; docs/DESIGN-stellar-parity.md §6.5, §12.5), against figures worked out by hand for an
// account with 100 XLM ($0.20, +5% on the day), USDC enabled and empty, 3 of Blend's test USDC ($1), some EURC from an
// issuer outside the registry (no price), 50 XLM in Blend, 1,000 of a launch token at 0.025 XLM (+25%) and an edition:
// - spot: XLM, then the registry's enabled assets, then other trustlines, unverified and named by their issuer; a
//   launch token only under launch;
// - totals: each part's value, the total only when every part was read; Moments worth 0; a part that fails is
//   "failed", its total null, the total null and complete false;
// - change24h: Σ value × c / (1 + c), over the value a day ago, complete only with every holding priced;
// - launch: the owner's balances read live, at most 50 at once, the indexed one (stale) when a read fails, a token
//   whose live balance is 0 left out; the public view reads the indexed ones only, with no RPC call, and is kept 15 s.
import { Address, nativeToScVal, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, OTHER, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { replacePools } = await import("../../supabase/functions/_shared/earn.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { forgetPublicHoldings, holdings, LIVE_READS, publicHoldings } = await import("../../supabase/functions/_shared/holdings.ts");

const PASS = TESTNET.passphrase;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const BUSDC = TESTNET.assets.find((a) => a.id === "BUSDC")!;
const POOL = TESTNET.contracts.blendPools[0];
const ME = USER.publicKey();
const EURC_ISSUER = OTHER.publicKey();
const EURC = `EURC:${EURC_ISSUER}`;
const NOW = Date.UTC(2026, 9, 14, 9, 41);
const DAY = 86_400_000;
/** The nth launch token's contract id. */
function token(n: number): string {
  const id = new Uint8Array(32);
  id[0] = 200;
  id[1] = n;
  return StrKey.encodeContract(id as any);
}

// ------------------------------------------------------------------------------------------------ the world

const world = {
  horizonDown: false,
  missing: false,
  poolsDown: false,
  launchesDown: false,
  momentsDown: false,
  /** Launch tokens held: their count, and the live reads that fail (every tenth) or answer 0 (the second). */
  launches: 1,
  manyReads: false,
  rpcCalls: 0,
  inFlight: 0,
  mostInFlight: 0,
  queries: 0,
};

function reset(): void {
  Object.assign(world, { horizonDown: false, missing: false, poolsDown: false, launchesDown: false, momentsDown: false, launches: 1, manyReads: false, rpcCalls: 0, inFlight: 0, mostInFlight: 0, queries: 0 });
  forgetReferencePrices();
  forgetPublicHoldings();
}

const trustline = (asset: string, balance: string) => {
  const [code, issuer] = asset.split(":");
  return { balance, limit: "1000.0000000", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "credit_alphanum4", asset_code: code, asset_issuer: issuer };
};

const answer = (v: xdr.ScVal) => ({
  latestLedger: 1,
  minResourceFee: "1000",
  transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
  results: [{ auth: [], xdr: v.toXDR("base64") }],
  events: [],
});

/** A launch token's live balance: 1,000 (or, among many, every tenth read failing and the second token at 0). */
function balanceRead(params: { transaction: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
  const contract = Address.fromScAddress((tx.operations[0] as any).func.invokeContract().contractAddress()).toString();
  const n = Array.from({ length: world.launches }, (_, i) => i).find((i) => token(i) === contract);
  if (n === undefined || (world.manyReads && n % 10 === 9)) return { latestLedger: 1, error: "HostError: Error(Storage, MissingValue)" };
  return answer(nativeToScVal(world.manyReads && n === 1 ? 0n : 10_000_000_000n, { type: "i128" }));
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === `/accounts/${ME}`) {
    if (world.horizonDown) return new Response("down", { status: 500 });
    if (world.missing) return Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
    return Response.json({
      id: ME,
      account_id: ME,
      sequence: "1",
      subentry_count: 3,
      num_sponsoring: 0,
      num_sponsored: 0,
      signers: [],
      balances: [
        trustline(EURC, "7.0000000"),
        trustline(BUSDC.classic!, "3.0000000"),
        trustline(USDC.classic!, "0.0000000"),
        { balance: "100.0000000", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "native" },
      ],
    });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    world.rpcCalls++;
    world.inFlight++;
    world.mostInFlight = Math.max(world.mostInFlight, world.inFlight);
    try {
      const body = await req.json();
      await new Promise((r) => setTimeout(r, 2));
      return Response.json({ jsonrpc: "2.0", id: body.id, result: balanceRead(body.params) });
    } finally {
      world.inFlight--;
    }
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

const reserves = () => new Map([[XLM.contract, { decimals: 7, supplyApy: 0.031, borrowApy: 0.054, utilization: 0.61, supplied: 10n ** 15n, borrowed: 10n ** 14n }]]);
replacePools({
  read: () => Promise.resolve({ status: 0, reserves: reserves() }),
  supplies: () => (world.poolsDown ? Promise.reject(new Error("RPC down")) : Promise.resolve({ state: { status: 0, reserves: reserves() }, supplied: new Map([[XLM.contract, { supply: 500_000_000n, collateral: 0n }]]) })),
});

/** A launch on its curve at 0.025 XLM, 0.02 a day ago, made two days ago; the account holds 1,000 of it, indexed. */
function launchRow(n: number): Row {
  return {
    token: token(n),
    creator: OTHER.publicKey(),
    quote: XLM.contract,
    name: `Coin ${n}`,
    symbol: `CN${n}`,
    uri: "",
    supply: "10000000000000000",
    burned: "0",
    quote_reserve: "300000000000",
    token_reserve: "9000000000000000",
    real_quote: "10000000000",
    threshold: "50000000000",
    completed: false,
    graduated: false,
    pair: null,
    last_price: "0.025",
    volume_quote: "0",
    trades: 1,
    image_url: null,
    look_alike: false,
    created_at: new Date(NOW - 2 * DAY),
    indexed_balance: "10000000000",
    price_24h: "0.02",
  };
}

replaceSql(fakeSql((q) => {
  world.queries++;
  if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
    return [
      { ref: "XLM", usd: "0.2", source: "kraken", market: "Kraken XLM/USD", change_24h: "0.05", volume_24h_usd: "1", quoted_at: new Date(NOW) },
      { ref: "USDC", usd: "1", source: "kraken", market: "Kraken USDC/USD", change_24h: "0", volume_24h_usd: "1", quoted_at: new Date(NOW) },
    ];
  }
  if (q.startsWith("select ref, lite.ref_usd_at(ref, ?) as usd from unnest(")) return [{ ref: "XLM", usd: "0.2" }, { ref: "USDC", usd: "1" }];
  if (q.startsWith("select asset, home_domain, name, image from lite.asset_directory")) return [{ asset: EURC, home_domain: "euro.example.org", name: "Euro Coin", image: null }];
  if (q.startsWith("select kind, intent from lite.tx_log")) {
    return [{ kind: "earn_deposit", intent: { kind: "earn_deposit", summary: "", spend: { [XLM.contract]: "490000000" }, calls: [{ contract: POOL.id, fn: "submit" }] } }];
  }
  if (q.startsWith("select l.*, coalesce(tb.balance, 0) as indexed_balance")) {
    if (world.launchesDown) throw new Error("the launch read failed");
    return Array.from({ length: world.launches }, (_, i) => launchRow(i));
  }
  if (q.startsWith("select token, side, quote_amount, token_amount from (")) return [];
  if (q.includes("from lite.moment_editions e join lite.moments m")) {
    if (world.momentsDown) throw new Error("the editions read failed");
    return [{ token_id: 4, moment_id: 2, contract: "CCWP4LEV74P26RQ44EG4BBC2BD66YMDTFTR4UNCEINOSXEMG2GQA2YIR", title: "Dusk", media_url: null, poster_url: null, media_type: "image" }];
  }
  throw new Error(`unexpected query: ${q}`);
}));

/** Runs `fn` with warnings held back: a part that fails logs one. */
async function quietly<T>(fn: () => Promise<T>): Promise<T> {
  const warn = console.warn;
  console.warn = () => {};
  try {
    return await fn();
  } finally {
    console.warn = warn;
  }
}

// ------------------------------------------------------------------------------------------------ the parts

Deno.test("spot: XLM, the registry's enabled assets (one empty, the test USDC badged), then other trustlines, unverified", async () => {
  reset();
  const h = await holdings(ME, "owner", NOW);
  assertEquals(h.spot.map((r) => [r.id, r.kind, r.balance, r.verified, r.badges, r.name, r.priceUsd, r.valueUsd, r.change24h]), [
    ["XLM", "registry", "1000000000", true, [], "Stellar Lumens", 0.2, 20, 0.05],
    ["USDC", "registry", "0", true, [], "USD Coin", 1, 0, 0],
    ["BUSDC", "registry", "30000000", true, ["testAsset"], "Blend test USDC", 1, 3, 0],
    [EURC, "classic", "70000000", false, ["unverified"], "Euro Coin", null, null, null],
  ]);
  // A launch token is counted under launch only.
  assertEquals([h.launch.map((l) => l.symbol), h.spot.some((r) => r.contract === h.launch[0].token)], [["CN0"], false]);
  assertEquals([h.exists, h.xlm?.minBalance, h.moments.count], [true, "25000000", 1]);
});

Deno.test("totals and the 24-hour change, worked out by hand", async () => {
  reset();
  const h = await holdings(ME, "owner", NOW);
  // Spot $20 + $0 + $3 (EURC unpriced), Earn 50 XLM $10, the launch 1,000 × 0.025 XLM × $0.20 = $5, Moments 0.
  assertEquals(h.totals, { spot: 23, earn: 10, launch: 5, moments: 0, total: 38, complete: true });
  // Moved: 20 × 0.05/1.05 + 3 × 0 + 10 × 0.05/1.05 + 5 × 0.25/1.25 = 2.428571; a day ago 38 − 2.428571. EURC has no
  // price, so the change isn't complete.
  const moved = (20 * 0.05) / 1.05 + (10 * 0.05) / 1.05 + (5 * 0.25) / 1.25;
  assertEquals(h.change24h, { usd: 2.43, pct: Math.round((moved / (38 - moved)) * 1e4) / 1e4, complete: false });
  assertEquals(h.change24h.pct, 0.0683);
  assertEquals(h.parts, { spot: "ok", earn: "ok", launch: "ok", moments: "ok" });
});

Deno.test("totals.total is null and complete false when any part fails; the others still answer", async () => {
  for (const [part, fail] of [["spot", "horizonDown"], ["earn", "poolsDown"], ["launch", "launchesDown"], ["moments", "momentsDown"]] as const) {
    reset();
    world[fail] = true;
    const h = await quietly(() => holdings(ME, "owner", NOW));
    assertEquals([h.parts[part], h.totals[part], h.totals.total, h.totals.complete], ["failed", null, null, false], part);
    assertEquals(h.change24h, { usd: null, pct: null, complete: false }, part);
    const read = { spot: h.spot.length > 0, earn: h.earn.length > 0, launch: h.launch.length > 0, moments: h.moments.count > 0 };
    assertEquals(read, { spot: part !== "spot", earn: part !== "earn", launch: part !== "launch", moments: part !== "moments" }, part);
    for (const other of ["spot", "earn", "launch", "moments"] as const) if (other !== part) assertEquals(h.parts[other], "ok", `${part}: ${other}`);
  }
  // A spot part that couldn't read the account can't say it exists.
  reset();
  world.horizonDown = true;
  const down = await quietly(() => holdings(ME, "owner", NOW));
  assertEquals([down.exists, down.xlm], [false, null]);
});

Deno.test("an account that doesn't exist: nothing in spot, no XLM position, but the parts are read", async () => {
  reset();
  world.missing = true;
  const h = await holdings(ME, "owner", NOW);
  assertEquals([h.exists, h.xlm, h.spot, h.totals.spot, h.totals.complete], [false, null, [], 0, true]);
});

Deno.test("launch: the owner's balances are read live, at most 50 at once; a failed read keeps the indexed balance, stale", async () => {
  reset();
  world.launches = 60;
  world.manyReads = true;
  const h = await holdings(ME, "owner", NOW);
  assertEquals(world.rpcCalls, 60);
  assert(world.mostInFlight <= LIVE_READS && world.mostInFlight > 1, `${world.mostInFlight} reads at once`);
  // The second token's live balance is 0: it is left out. Every tenth read failed: the indexed balance, stale.
  assertEquals(h.launch.length, 59);
  assertEquals(h.launch.filter((l) => l.stale).map((l) => l.symbol), Array.from({ length: 6 }, (_, i) => `CN${i * 10 + 9}`));
  assert(h.launch.every((l) => l.balance === "10000000000"));
});

Deno.test("the public view reads indexed balances only, with no RPC call, leaves DyorHQ's history out, and is kept 15 s", async () => {
  reset();
  const h = await publicHoldings(ME, NOW);
  assertEquals([world.rpcCalls, h.view, h.launch[0].stale, h.launch[0].costBasisUsd, h.launch[0].pnlUsd], [0, "public", false, null, null]);
  assertEquals([h.earn[0].supplied, h.earn[0].deposited, h.earn[0].withdrawn, h.earn[0].earned, h.earn[0].earnedComplete], ["500000000", null, null, null, false]);
  // The owner's view of the same account: the record, and the live read.
  const owner = await holdings(ME, "owner", NOW);
  assertEquals([owner.earn[0].deposited, owner.earn[0].earned, owner.earn[0].earnedComplete, world.rpcCalls], ["490000000", "10000000", true, 1]);
  // Within 15 s: the same answer, read from nothing.
  const queries = world.queries;
  assertEquals(await publicHoldings(ME, NOW + 14_999), h);
  assertEquals(world.queries, queries);
  // After: read again.
  await publicHoldings(ME, NOW + 15_000);
  assert(world.queries > queries);
});
