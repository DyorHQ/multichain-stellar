// Contracts v2's Moments as the indexer recorded them (_shared/moments_v2_feed.ts; DESIGN-stellar-contracts-v2 §20.5):
// - the payloads equal the API contract's fixtures (backend/tests/fixtures/api/): the feed (moments-v2), a Moment's page
//   in the owner's and the public view (moment-v2, moment-v2.public), an account's Moments in both views
//   (moments-v2-owned, moments-v2-owned.public) and a creator's Moments (moments-v2-mine), produced from seeded rows;
// - a row's figures: progress in every state, the coin and pool once graduated, open before the deadline only, the
//   durations its publish bound (the deployment's pinned ones without them);
// - every read keeps to the deployment's main Moments stack and generation 2; the feed's filters and pages; 404 for an
//   address that is no listed v2 Moment; 503 where v2 isn't deployed;
// - through the API's router: the feed, a Moment's page and an account's Moments answer without a token (the public
//   view, cached 15 s), an account's Moments need ?address= then, and a creator's Moments need a session.
// A fixture changed on purpose is recorded again, and the diff shows what changed:
//   FIXTURES_RECORD=1 deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/moments_v2_feed.test.ts
import { StrKey } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, OTHER, type Row, setTestEnv, USER, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { MAINNET } = await import("../../supabase/functions/_shared/networks.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { pinnedDurations } = await import("../../supabase/functions/_shared/moments_v2.ts");
const f = await import("../../supabase/functions/_shared/moments_v2_feed.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const api = new URL("../fixtures/api/", import.meta.url);
const RECORD = Deno.env.get("FIXTURES_RECORD") === "1";

/** Before Moment A's window closes; the reference quotes a minute before. */
const NOW = Date.UTC(2026, 9, 15, 20, 0);
const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const net = env.network;
const STACK = net.contracts.momentsV2!;
const USDC = net.assets.find((a) => a.id === "USDC")!.contract;
const ME = USER.publicKey();
const COLLECTOR = OTHER.publicKey();
const CREATOR = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN";
const MEDIA = `${STORAGE}/storage/v1/object/public/lite-media/`;
const at = (iso: string) => new Date(iso);

const NFT_A = C(61);
const NFT_B = C(62);
const NFT_C = C(63);
/** The durations a publish event carries (MomentsDurations, snake case, seconds). */
const DURATIONS = {
  vest_period: 604800,
  stuck_expiry: 604800,
  pending_backstop: 2592000,
  timelock: 172800,
  timelock_window: 604800,
  min_window: 3600,
  max_window: 2592000,
  harvest_interval: 3600,
};

/** A v2 Moment as lite.moments holds it (lite-indexer/v2_events.ts). */
function moment(fields: Row): Row {
  return {
    id: null,
    generation: 2,
    contract: STACK,
    quote: USDC,
    max_editions: 0,
    listed: true,
    platform_bps: 500,
    royalty_bps: 500,
    durations: DURATIONS,
    reserve: "0",
    total_gross: "0",
    entitlements: "0",
    completed_at: null,
    graduated_at: null,
    expired_at: null,
    expiry_creator_share: null,
    expiry_treasury_share: null,
    pool: null,
    ...fields,
  };
}

/** Collecting: 3 of its editions collected, three quarters of the way to its threshold. */
const A = moment({
  nft: NFT_A,
  number: 2,
  creator: CREATOR,
  uri: `${MEDIA}moments/${CREATOR}/9b2f6a0e-1c4d-4f43-9c1e-7a6f3c2d1e01.json`,
  name: "Harbour at dusk",
  symbol: "DUSK",
  title: "Harbour at dusk",
  description: "The last ferry leaving Jamestown.",
  place: "Accra",
  taken_on: at("2026-10-13T00:00:00.000Z"),
  media_type: "video",
  media_url: `${MEDIA}uploads/${CREATOR}/7dedfd8a-9584-4cd0-a43a-cd036723818b.mp4`,
  poster_url: `${MEDIA}uploads/${CREATOR}/27601021-cbcb-4512-a8e3-69978e581185.jpg`,
  coin: C(71),
  price: "50000000",
  threshold: "200000000",
  reserve: "150000000",
  total_gross: "200000000",
  entitlements: "40000000000000",
  minted: 3,
  collects: 3,
  collectors: 2,
  creator_alloc_bps: 500,
  state: "collecting",
  deadline: at("2026-10-22T09:00:00.000Z"),
  created_at: at("2026-10-15T09:41:00.000Z"),
});

/** Graduated: its coin and pool exist. */
const B = moment({
  nft: NFT_B,
  number: 1,
  creator: ME,
  uri: `${MEDIA}moments/${ME}/0d3c1a52-8f7e-4b6a-9d2c-5e4f3a2b1c00.json`,
  name: "Makola market",
  symbol: "MAKOLA",
  title: "Makola market",
  description: null,
  place: "Accra",
  taken_on: at("2026-10-12T00:00:00.000Z"),
  media_type: "image",
  media_url: `${MEDIA}uploads/${ME}/5a1e2b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b.jpg`,
  poster_url: `${MEDIA}uploads/${ME}/5a1e2b3c-4d5e-4f60-8a7b-9c0d1e2f3a4b.jpg`,
  coin: C(72),
  pool: C(73),
  price: "100000000",
  threshold: "750000000",
  reserve: "0",
  total_gross: "1000000000",
  entitlements: "200000000000000",
  minted: 10,
  collects: 6,
  collectors: 4,
  creator_alloc_bps: 1000,
  state: "graduated",
  deadline: at("2026-10-19T09:00:00.000Z"),
  completed_at: at("2026-10-14T11:00:00.000Z"),
  graduated_at: at("2026-10-14T11:01:00.000Z"),
  created_at: at("2026-10-12T09:41:00.000Z"),
});

/** Expired short of its threshold: its reserve went to the creator and the treasury. Never listed (no image). */
const EXPIRED = moment({
  nft: NFT_C,
  number: 3,
  creator: CREATOR,
  uri: "",
  name: "Rain",
  symbol: "RAIN",
  title: "Rain",
  coin: C(74),
  price: "10000000",
  threshold: "1000000000",
  reserve: "0",
  total_gross: "400000000",
  expiry_creator_share: "210000000",
  expiry_treasury_share: "90000000",
  minted: 40,
  collects: 9,
  collectors: 7,
  creator_alloc_bps: 0,
  state: "expired",
  listed: false,
  deadline: at("2026-10-14T09:00:00.000Z"),
  expired_at: at("2026-10-14T10:00:00.000Z"),
  created_at: at("2026-10-11T09:41:00.000Z"),
});

const MOMENTS = [A, B, EXPIRED];

/** Reference prices: USDC's, or none. */
const PRICES = { XLM: { usd: 0.19 }, USDC: { usd: 0.9999 } } as any;
const NO_PRICES = { XLM: { usd: null }, USDC: { usd: null } } as any;

/** Who holds which edition: the collector two of A's, me one of A's and two of B's. */
const EDITIONS: Row[] = [
  { nft: NFT_A, token_id: 1, owner: COLLECTOR },
  { nft: NFT_A, token_id: 2, owner: COLLECTOR },
  { nft: NFT_A, token_id: 3, owner: ME },
  { nft: NFT_B, token_id: 1, owner: ME },
  { nft: NFT_B, token_id: 2, owner: ME },
];

/** Coins promised, by Moment and account. I collected one of A's editions and two of B's, sold one of B's on (EDITIONS
 *  holds the other), and claimed the vested part of B's coins; in the expired Moment I hold nothing but my position. */
const POSITIONS: Row[] = [
  { nft: NFT_A, account: ME, entitlement: "10000000000000", collector_claimed: "0", gross: "50000000" },
  { nft: NFT_A, account: COLLECTOR, entitlement: "20000000000000", collector_claimed: "0", gross: "100000000" },
  { nft: NFT_B, account: ME, entitlement: "60000000000000", collector_claimed: "36000000000000", gross: "300000000" },
  { nft: NFT_C, account: ME, entitlement: "0", collector_claimed: "0", gross: "20000000" },
];

/** A's collects, newest first. */
const COLLECTS: Row[] = [
  { collector: ME, quantity: 1, first_token_id: 3, ts: at("2026-10-15T12:00:00.000Z") },
  { collector: COLLECTOR, quantity: 1, first_token_id: 2, ts: at("2026-10-15T11:00:00.000Z") },
  { collector: COLLECTOR, quantity: 1, first_token_id: 1, ts: at("2026-10-15T10:00:00.000Z") },
];

/** The creator's share of each Moment's collects (the collect events' creator_in), and what B's creator withdrew. */
const CREATOR_IN: Record<string, string> = { [NFT_A]: "40000000", [NFT_B]: "200000000", [NFT_C]: "80000000" };
const WITHDRAWN: Record<string, string> = { [NFT_B]: "150000000" };

let asked: { q: string; params: unknown[] }[] = [];

/** The database: the rows above, each read applying its own conditions on them. */
function seed(rows: Row[] = MOMENTS): void {
  asked = [];
  const ofStack = (q: string, params: unknown[]) => {
    assert(q.includes("m.generation = 2 and m.contract = ?"), `keeps to v2's main stack: ${q}`);
    assert(params.includes(STACK), q);
    return rows.filter((r) => r.generation === 2 && r.contract === STACK);
  };
  replaceSql(fakeSql((q, params) => {
    asked.push({ q, params });
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
      return [{ ref: "USDC", usd: "0.9999", source: "kraken", market: "Kraken USDC/USD", change_24h: "0.0001", volume_24h_usd: "912003.5", quoted_at: new Date(NOW - 60_000) }];
    }
    if (q === "select 1 from lite.testers where address = ? and revoked_at is null") return [{ "?column?": 1 }];
    if (q.startsWith("select m.* from lite.moments m where m.generation = 2 and m.contract = ? and m.listed and m.title is not null")) {
      const listed = ofStack(q, params).filter((r) => r.listed && r.title !== null);
      const [limit, offset] = params.slice(-2) as number[];
      const now = (params.find((p) => p instanceof Date) as Date | undefined)?.getTime() ?? 0;
      const collecting = (r: Row) => r.state === "collecting" && (r.deadline as Date).getTime() > now;
      const filtered = q.includes("and not (") ? listed.filter((r) => !collecting(r)) : q.includes("'collecting' and m.deadline > ?") ? listed.filter(collecting) : listed;
      return filtered.slice(offset, offset + limit);
    }
    if (q.startsWith("select m.* from lite.moments m where m.nft = ? and")) return ofStack(q, params).filter((r) => r.nft === params[0]);
    if (q.startsWith("select m.* from lite.moments m where m.nft = any(?::text[]) and")) return ofStack(q, params).filter((r) => (params[0] as string[]).includes(r.nft as string));
    if (q.startsWith("select m.* from lite.moments m where m.creator = ? and m.title is not null and")) {
      return ofStack(q, params).filter((r) => r.creator === params[0] && r.title !== null);
    }
    if (q.startsWith("select collector, quantity, first_token_id, ts from lite.moment_collects where nft = ?")) return params[0] === NFT_A ? COLLECTS : [];
    if (q.startsWith("select collector, sum(quantity)::int as editions from lite.moment_collects where nft = ?")) {
      return params[0] === NFT_A ? [{ collector: COLLECTOR, editions: 2 }] : [];
    }
    if (q.startsWith("select subject as nft, coalesce(sum((data ->> 'creator_in')::numeric), 0) as earned from lite.v2_events where contract = ? and kind = 'collect'")) {
      assertEquals(params[0], STACK);
      return (params[1] as string[]).filter((n) => CREATOR_IN[n]).map((n) => ({ nft: n, earned: CREATOR_IN[n] }));
    }
    if (q.startsWith("select token_id from lite.moment_editions where contract = ? and owner = ?")) {
      return EDITIONS.filter((e) => e.nft === params[0] && e.owner === params[1]).map((e) => ({ token_id: e.token_id }));
    }
    if (q.startsWith("select entitlement, collector_claimed, gross from lite.moment_positions where nft = ? and account = ?")) {
      return POSITIONS.filter((p) => p.nft === params[0] && p.account === params[1]);
    }
    if (q.startsWith("select e.contract as nft, e.token_id from lite.moment_editions e join lite.moments m on m.nft = e.contract where e.owner = ?")) {
      const nfts = ofStack(q, params).map((r) => r.nft);
      return EDITIONS.filter((e) => e.owner === params[0] && nfts.includes(e.nft)).map((e) => ({ nft: e.nft, token_id: e.token_id }));
    }
    if (q.startsWith("select p.nft, p.entitlement, p.collector_claimed, p.gross from lite.moment_positions p join lite.moments m on m.nft = p.nft where p.account = ? and p.entitlement > 0")) {
      const nfts = ofStack(q, params).map((r) => r.nft);
      return POSITIONS.filter((p) => p.account === params[0] && BigInt(p.entitlement as string) > 0n && nfts.includes(p.nft));
    }
    if (q.startsWith("select nft, coalesce(sum(amount), 0) as withdrawn from lite.moment_withdrawals where role = 'creator'")) {
      return (params[0] as string[]).filter((n) => WITHDRAWN[n]).map((n) => ({ nft: n, withdrawn: WITHDRAWN[n] }));
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  forgetReferencePrices();
}

/** `got` equals the fixture `name`; FIXTURES_RECORD=1 writes it instead. */
async function matches(name: string, got: unknown): Promise<void> {
  const file = new URL(`${name}.json`, api);
  const text = JSON.stringify(got, null, 2) + "\n";
  if (RECORD) return await Deno.writeTextFile(file, text);
  assertEquals(JSON.parse(text), JSON.parse(await Deno.readTextFile(file)), name);
}

async function refused(run: () => Promise<unknown>): Promise<InstanceType<typeof ApiError>> {
  const err = await run().then(() => null, (e) => e);
  assert(err instanceof ApiError, `expected an ApiError, got ${err}`);
  return err;
}

// ------------------------------------------------------------------------------------------------ the fixtures

Deno.test("GET /v1/moments/v2 equals moments-v2.json: listed Moments of the main stack, newest first", async () => {
  seed();
  await matches("moments-v2", { ...await f.feedV2("all", 50, 1, NOW), view: "owner" });
});

Deno.test("GET /v1/moments/v2/:nft equals moment-v2.json (owner) and moment-v2.public.json (?address=)", async () => {
  seed();
  await matches("moment-v2", await f.momentDetailV2(NFT_A, { address: ME, scope: "owner" }, NOW));
  await matches("moment-v2.public", await f.momentDetailV2(NFT_A, { address: ME, scope: "public" }, NOW));
});

Deno.test("GET /v1/moments/v2/owned equals moments-v2-owned.json and moments-v2-owned.public.json", async () => {
  seed();
  await matches("moments-v2-owned", { moments: await f.ownedV2(ME, "owner", NOW), view: "owner" });
  await matches("moments-v2-owned.public", { moments: await f.ownedV2(ME, "public", NOW), view: "public" });
});

Deno.test("GET /v1/moments/v2/mine equals moments-v2-mine.json", async () => {
  seed();
  await matches("moments-v2-mine", await f.mineV2(ME, NOW));
});

if (!RECORD) {
  // ---------------------------------------------------------------------------------------------- rows

  Deno.test("a row: the NFT's name and ticker, the metadata's media, place and date, USDC at its price, the terms' durations", () => {
    const row = f.momentRowV2Of(A, PRICES, NOW);
    assertEquals([row.generation, row.nft, row.number, row.name, row.symbol, row.title], [2, NFT_A, 2, "Harbour at dusk", "DUSK", "Harbour at dusk"]);
    assertEquals([row.mediaType, row.place, row.takenOn, row.quoteCode, row.priceUsd], ["video", "Accra", "2026-10-13", "USDC", 5]);
    assertEquals([row.state, row.open, row.progress, row.minted, row.creatorAllocBps], ["collecting", true, 0.75, 3, 500]);
    assertEquals(row.durations, { vestPeriod: 604800, stuckExpiry: 604800, pendingBackstop: 2592000, timelock: 172800, timelockWindow: 604800, minWindow: 3600, maxWindow: 2592000, harvestInterval: 3600 });
    // Its window closes: still collecting on chain until someone expires it, but no longer open.
    assertEquals(f.momentRowV2Of(A, NO_PRICES, Date.UTC(2026, 9, 22, 9, 0)).open, false);
    // No durations recorded: the deployment's, which every v2 Moment binds.
    assertEquals(f.momentRowV2Of({ ...A, durations: null }, NO_PRICES, NOW).durations, pinnedDurations(net));
    assertEquals(f.momentRowV2Of({ ...A, durations: { vest_period: 1 } }, NO_PRICES, NOW).durations, pinnedDurations(net));
  });

  Deno.test("a row: the coin and the pool are named once it graduated, never before", () => {
    const collecting = f.momentRowV2Of(A, NO_PRICES, NOW);
    assertEquals([collecting.coin, collecting.pool], [null, null]);
    const graduated = f.momentRowV2Of(B, NO_PRICES, NOW);
    assertEquals([graduated.coin, graduated.pool, graduated.progress, graduated.open], [C(72), C(73), 1, false]);
    const pending = f.momentRowV2Of({ ...B, state: "graduation_pending", pool: null, graduated_at: null }, NO_PRICES, NOW);
    assertEquals([pending.coin, pending.pool, pending.progress], [null, null, 1]);
  });

  Deno.test("progress: the reserve over the threshold while collecting; 1 once completed; an expiry's split short of it", () => {
    assertEquals(f.progressOfRow(A), 0.75);
    assertEquals(f.progressOfRow(B), 1);
    // Expired without completing: the reserve its expiry split, 300 of 1,000 USDC.
    assertEquals(f.progressOfRow(EXPIRED), 0.3);
    // Expired after completing (pending graduation past its backstop): it reached its threshold.
    assertEquals(f.progressOfRow({ ...EXPIRED, completed_at: at("2026-10-13T09:00:00.000Z") }), 1);
    // A reserve at the threshold that hasn't completed yet stays below 1, as the contract's own read does.
    assertEquals(f.progressOfRow({ ...A, reserve: "200000000" }), 0.999999);
    assertEquals(f.progressOfRow({ ...A, threshold: "0" }), 0);
  });

  // ---------------------------------------------------------------------------------------------- reads

  Deno.test("the feed: the main stack's listed Moments only; collecting before the deadline, closed the rest", async () => {
    seed([...MOMENTS, { ...A, nft: C(64), contract: C(90) }, { ...A, nft: C(65), title: null }]);
    assertEquals((await f.feedV2("all", 50, 1, NOW)).moments.map((m) => m.nft), [NFT_A, NFT_B]);
    assertEquals((await f.feedV2("collecting", 50, 1, NOW)).moments.map((m) => m.nft), [NFT_A]);
    assertEquals((await f.feedV2("closed", 50, 1, NOW)).moments.map((m) => m.nft), [NFT_B]);
    // A's window closed: it isn't collecting any more.
    assertEquals((await f.feedV2("closed", 50, 1, Date.UTC(2026, 9, 23))).moments.map((m) => m.nft), [NFT_A, NFT_B]);
  });

  Deno.test("the feed's pages: a page of `limit`, and the next one's cursor while there are more", async () => {
    seed();
    const first = await f.feedV2("all", 1, 1, NOW);
    assertEquals([first.moments.map((m) => m.nft), first.nextCursor], [[NFT_A], "page-2"]);
    const second = await f.feedV2("all", 1, f.feedPage(first.nextCursor), NOW);
    assertEquals([second.moments.map((m) => m.nft), second.nextCursor], [[NFT_B], null]);
    assertEquals(f.feedPage(null), 1);
    for (const bad of ["page-0", "page-x", "2", "page-1234567"]) {
      const err = await refused(() => Promise.resolve().then(() => f.feedPage(bad)));
      assertEquals([err.status, err.code], [400, "bad_arg"], bad);
    }
  });

  Deno.test("a Moment's page: 404 for an address that is no v2 Moment of the main stack, or one without DyorHQ's metadata", async () => {
    seed([...MOMENTS, { ...A, nft: C(64), contract: C(90) }, { ...A, nft: C(65), title: null }]);
    for (const nft of ["7", "GABC", C(64), C(65), C(66)]) {
      const err = await refused(() => f.momentDetailV2(nft, { address: null, scope: "public" }, NOW));
      assertEquals([err.status, err.code], [404, "not_found"], nft);
    }
    // Without an account, no `you`; its creator's earnings are the collects' creator share.
    const page = await f.momentDetailV2(NFT_A, { address: null, scope: "public" }, NOW);
    assertEquals([page.you, page.creatorEarned, page.collectorsSummary], [null, "40000000", { count: 2, largest: { address: COLLECTOR, editions: 2 } }]);
    // An expired Moment's creator earned the collects' share and the reserve's.
    const expired = await f.momentDetailV2(NFT_C, { address: null, scope: "public" }, NOW);
    assertEquals(expired.creatorEarned, "290000000");
  });

  Deno.test("an account's Moments: editions held per Moment with what it was promised and claimed; a position without editions too", async () => {
    seed();
    const mine = await f.ownedV2(ME, "owner", NOW);
    assertEquals(mine.map((h) => [h.moment.nft, h.editions, h.entitlement, h.claimed, h.spent]), [
      [NFT_A, [3], "10000000000000", "0", "50000000"],
      [NFT_B, [1, 2], "60000000000000", "36000000000000", "300000000"],
    ]);
    // The collector holds two of A's editions; the public view never says what anyone paid.
    const theirs = await f.ownedV2(COLLECTOR, "public", NOW);
    assertEquals(theirs.map((h) => [h.moment.nft, h.editions, h.entitlement, h.spent]), [[NFT_A, [1, 2], "20000000000000", null]]);
    // Coins promised in B, whose edition the collector sold on: B is theirs too, with no edition.
    POSITIONS.push({ nft: NFT_B, account: COLLECTOR, entitlement: "20000000000000", collector_claimed: "12000000000000", gross: "100000000" });
    try {
      const sold = await f.ownedV2(COLLECTOR, "owner", NOW);
      assertEquals(sold.map((h) => [h.moment.nft, h.editions, h.claimed, h.spent]), [[NFT_A, [1, 2], "0", "100000000"], [NFT_B, [], "12000000000000", "100000000"]]);
    } finally {
      POSITIONS.pop();
    }
    // Nothing held, nothing promised: no Moment read at all.
    seed();
    assertEquals(await f.ownedV2(CREATOR, "owner", NOW), []);
    assertEquals(asked.filter((a) => a.q.startsWith("select m.* from lite.moments")), []);
  });

  Deno.test("a creator's Moments: proceeds (the collects' share and an expiry's), withdrawals and the totals", async () => {
    seed();
    const theirs = await f.mineV2(CREATOR, NOW);
    assertEquals(theirs.created.map((m) => [m.nft, m.proceeds, m.withdrawn]), [[NFT_A, "40000000", "0"], [NFT_C, "290000000", "0"]]);
    assertEquals(theirs.totals, { editions: 0, moments: 0, spentByQuote: {}, earnedByQuote: { USDC: "330000000" } });
  });

  Deno.test("where v2 isn't deployed, its Moments' reads answer 503 not_deployed", async () => {
    seed();
    for (const run of [() => f.feedV2("all", 50, 1, NOW, MAINNET), () => f.momentDetailV2(NFT_A, { address: null, scope: "public" }, NOW, MAINNET), () => f.ownedV2(ME, "owner", NOW, MAINNET), () => f.mineV2(ME, NOW, MAINNET)]) {
      const err = await refused(run);
      assertEquals([err.status, err.code], [503, "not_deployed"]);
    }
    assertEquals(asked, [], "nothing is read");
  });

  // ---------------------------------------------------------------------------------------------- routes

  const get = async (path: string, token?: string) => {
    const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, { headers: token ? { authorization: `Bearer ${token}` } : {} }));
    return { status: res.status, cache: res.headers.get("cache-control"), body: await res.json() };
  };

  Deno.test("the routes: viewer reads without a token (the public view, cached 15 s), the owner's with one; a creator's Moments need a session", async () => {
    seed();
    const token = await userToken();
    const feed = await get("/v1/moments/v2?filter=all&limit=1");
    assertEquals([feed.status, feed.cache, feed.body.view, feed.body.moments.length, feed.body.nextCursor], [200, "public, max-age=15", "public", 1, "page-2"]);
    const owner = await get("/v1/moments/v2?cursor=page-2&limit=1", token);
    assertEquals([owner.status, owner.cache, owner.body.view, owner.body.moments[0].nft], [200, "no-store", "owner", NFT_B]);
    assertEquals((await get("/v1/moments/v2?filter=sold")).body.error.code, "bad_arg");
    assertEquals((await get("/v1/moments/v2?limit=101")).body.error.code, "bad_arg");

    const page = await get(`/v1/moments/v2/${NFT_A}?address=${ME}`);
    assertEquals([page.status, page.cache, page.body.view, page.body.you.editions, page.body.you.spent], [200, "public, max-age=15", "public", [3], null]);
    const mine = await get(`/v1/moments/v2/${NFT_A}`, token);
    assertEquals([mine.status, mine.body.view, mine.body.you.spent], [200, "owner", "50000000"]);
    assertEquals((await get(`/v1/moments/v2/${C(66)}`)).status, 404);

    const owned = await get("/v1/moments/v2/owned");
    assertEquals([owned.status, owned.body.error.code], [400, "address_required"]);
    const theirs = await get(`/v1/moments/v2/owned?address=${COLLECTOR}`);
    assertEquals([theirs.status, theirs.cache, theirs.body.view, theirs.body.moments.length], [200, "public, max-age=15", "public", 1]);

    assertEquals((await get("/v1/moments/v2/mine")).status, 401);
    const created = await get("/v1/moments/v2/mine", token);
    assertEquals([created.status, created.cache, created.body.created.map((m: Row) => m.nft)], [200, "no-store", [NFT_B]]);
  });
}
