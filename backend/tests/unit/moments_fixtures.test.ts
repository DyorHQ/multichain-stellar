// WP-16's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md §6.0,
// §6.9, §12.5): the feed, a Moment's page in the owner's and the public view, an account's editions in both views,
// My Moments, a Moment's metadata URI and an upload ticket, produced by the routes' own code from seeded rows that carry
// the fixtures' figures; and what older clients read (the .legacy fixtures) is all still there.
//
// ERRATA: figures the fixtures state that no consistent server could answer, and what this one answers instead. Each
// payload is compared with its fixture with these corrected, and with nothing else changed (they are WP-03's to fix):
// - moment, moment.public, moment.legacy: `collectors` are the newest 50 collects, newest first, as the route has always
//   answered; the fixtures list the two oldest first.
// - moments-mine: Moment 3 is one Moment, so its creator is the same in `created` and in `collected` (the user's own,
//   GCLJ…: `created` lists the Moments the user published); the fixture names GDTC… in `collected`.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
Deno.env.delete("LITE_MOMENT_LINK_BASE");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const { errorResponse } = await import("../../supabase/functions/_shared/http.ts");
const m = await import("../../supabase/functions/_shared/moments.ts");
const { signedUpload } = await import("../../supabase/functions/_shared/media.ts");

const api = new URL("../fixtures/api/", import.meta.url);
const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, api)));

/** Before the fixture Moment's window closes; the reference quote a minute before. */
const NOW = Date.UTC(2026, 9, 14, 14, 0);
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const ME = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH";
const COLLECTOR = "GDFIMZHHSBGAIJUCBALCYGEO2GQKDVWJW4C3LFFLLINXU23OPVEXRITR";
const CREATOR = "GDTCJIP2SGHCVPX6ZMO66KR4E4QIJT7DIGDW7IMCYBY2W3B53B5K3NPN";
/** The collection the fixtures' editions belong to. */
const COLLECTION = "CDOYEDV4D3XQ7IP6R2SQXR5IIQYQRYLIVV53XSPTFKSNHUE22QKQ2JFT";
const MEDIA = `${STORAGE}/storage/v1/object/public/lite-media/`;
const at = (iso: string) => new Date(iso);

/** Moment 3 as lite.moments holds it. */
const MOMENT: Row = {
  id: 3,
  creator: CREATOR,
  uri: `${MEDIA}moments/${CREATOR}/41019444-f54f-4a9e-ac88-2667a92257fa.json`,
  title: "Harbour at dusk",
  media_url: `${MEDIA}uploads/${CREATOR}/7dedfd8a-9584-4cd0-a43a-cd036723818b.mp4`,
  price: "10000000",
  quote: XLM,
  max_editions: 10,
  minted: 3,
  deadline: at("2026-10-21T09:00:00.000Z"),
  created_ledger: 5_180_000,
  created_at: at("2026-10-13T09:41:00.000Z"),
  updated_at: at("2026-10-14T08:41:00.000Z"),
  description: "The last ferry leaving Jamestown.",
  place: "Accra",
  taken_on: at("2026-10-13T00:00:00.000Z"),
  media_type: "video",
  poster_url: `${MEDIA}uploads/${CREATOR}/27601021-cbcb-4512-a8e3-69978e581185.jpg`,
  platform_bps: 500,
  royalty_bps: 500,
  collects: 2,
  collectors: 2,
  listed: true,
};

/** Its collects, as `order by ts desc` reads them. */
const COLLECTS: Row[] = [
  { collector: ME, quantity: 1, first_token_id: 9, ts: at("2026-10-14T08:41:00.000Z") },
  { collector: COLLECTOR, quantity: 2, first_token_id: 7, ts: at("2026-10-14T06:41:00.000Z") },
];

/** lite.moments, its collects, the editions and the reference quote; `moment` is Moment 3 as this database holds it. */
function seed(moment: Row = MOMENT, editions: Row[] = []): { q: string; params: unknown[] }[] {
  const seen: { q: string; params: unknown[] }[] = [];
  replaceSql(fakeSql((q, params) => {
    seen.push({ q, params });
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
      return [{ ref: "XLM", usd: "0.1901", source: "kraken", market: "Kraken XLM/USD", change_24h: "-0.0123", volume_24h_usd: "3712345.2", quoted_at: new Date(NOW - 60_000) }];
    }
    if (q.startsWith("select * from lite.moments where listed and title is not null")) return [moment];
    if (q === "select * from lite.moments where id = ?") return params[0] === 3 ? [moment] : [];
    if (q.startsWith("select collector, quantity, first_token_id, ts from lite.moment_collects")) return COLLECTS;
    if (q.startsWith("select collector, sum(quantity)::int as editions")) return [{ collector: COLLECTOR, editions: 2 }];
    if (q.startsWith("select coalesce(sum(lite.moment_creator_share(paid, ?)), 0) as earned")) return [{ earned: "28500000" }];
    if (q.startsWith("select token_id from lite.moment_editions")) return editions.filter((e) => e.owner === params[1]).map((e) => ({ token_id: e.token_id }));
    if (q.startsWith("select coalesce(sum(paid), 0) as spent")) return [{ spent: params[1] === ME ? "10000000" : "0" }];
    if (q.startsWith("select e.token_id, e.moment_id, e.contract, m.title")) {
      return editions.filter((e) => e.owner === params[0]).map((e) => ({ ...e, moment_id: 3, title: moment.title, media_url: moment.media_url, poster_url: moment.poster_url, media_type: moment.media_type }));
    }
    if (q.startsWith("select * from lite.moments where creator = ?")) return params[0] === moment.creator ? [moment] : [];
    if (q.startsWith("select e.token_id, e.contract, m.* from lite.moment_editions")) {
      return editions.filter((e) => e.owner === params[0]).map((e) => ({ ...moment, token_id: e.token_id, contract: e.contract }));
    }
    if (q.startsWith("select m.quote, sum(c.paid) as spent")) return [{ quote: XLM, spent: "20000000" }];
    if (q.startsWith("select c.moment_id, sum(lite.moment_creator_share(c.paid, m.platform_bps)) as proceeds")) return [{ moment_id: 3, proceeds: "28500000" }];
    if (q.startsWith("insert into lite.moment_metadata")) return [];
    if (q.startsWith("select lite.reserve_media_upload(")) return [{ ok: true }];
    throw new Error(`unexpected query: ${q}`);
  }));
  forgetReferencePrices();
  return seen;
}

/** A copy of `value` with each [path, value] of `errata` set ("collected.0.moment.creator"). */
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
    assert(got !== null && typeof got === "object" && !Array.isArray(got), `${at}: ${JSON.stringify(got)}`);
    for (const [k, v] of Object.entries(legacy)) assertHolds((got as Record<string, unknown>)[k], v, `${at}.${k}`);
  } else {
    assertEquals(got, legacy, at);
  }
}

/** The collects newest first: the order the route answers (ERRATA). */
const newestFirst = (f: any) => corrected(f, [["collectors", [...f.collectors].reverse()]]);

Deno.test("GET /v1/moments equals moments.json, and holds moments.legacy.json", async () => {
  seed();
  const payload = { moments: await m.feed("all", 50, NOW), view: "owner" };
  assertEquals(payload, fixture("moments"));
  assertHolds(payload, fixture("moments.legacy"));
});

Deno.test("GET /v1/moments/:id equals moment.json (owner) and moment.public.json (?address=), and holds moment.legacy.json", async () => {
  const editions = [{ token_id: 9, owner: ME, contract: COLLECTION }, { token_id: 7, owner: COLLECTOR, contract: COLLECTION }, { token_id: 8, owner: COLLECTOR, contract: COLLECTION }];
  seed(MOMENT, editions);
  const owner = await m.momentDetail(3, { address: ME, scope: "owner" }, NOW);
  assertEquals(owner, newestFirst(fixture("moment")));
  assertHolds(owner, newestFirst(fixture("moment.legacy")));
  seed(MOMENT, editions);
  assertEquals(await m.momentDetail(3, { address: ME, scope: "public" }, NOW), newestFirst(fixture("moment.public")));
});

Deno.test("GET /v1/moments/owned equals moments-owned.json and moments-owned.public.json, and holds the legacy one", async () => {
  const editions = [{ token_id: 7, owner: ME, contract: COLLECTION }, { token_id: 8, owner: ME, contract: COLLECTION }];
  seed(MOMENT, editions);
  for (const view of ["owner", "public"] as const) {
    const payload = { editions: await m.owned(ME), view };
    assertEquals(payload, fixture(view === "owner" ? "moments-owned" : "moments-owned.public"));
    assertHolds(payload, fixture("moments-owned.legacy"));
  }
});

Deno.test("GET /v1/moments/mine equals moments-mine.json", async () => {
  const mineMoment = { ...MOMENT, creator: ME };
  seed(mineMoment, [{ token_id: 7, owner: ME, contract: COLLECTION }, { token_id: 8, owner: ME, contract: COLLECTION }]);
  const payload = await m.mine(ME, NOW);
  assertEquals(payload, corrected(fixture("moments-mine"), [["collected.0.moment.creator", ME], ["collected.1.moment.creator", ME]]));
});

Deno.test("POST /v1/moments/metadata equals moment-metadata.json (a photo is its own poster), and holds the legacy one", async () => {
  seed();
  const want = fixture("moment-metadata");
  const id = want.uri.slice(want.uri.lastIndexOf("/") + 1, -".json".length);
  const randomUUID = crypto.randomUUID;
  crypto.randomUUID = () => id;
  const original = fetch;
  globalThis.fetch = (() => Promise.resolve(Response.json({ Key: "ok" }))) as typeof fetch;
  try {
    const payload = await m.writeMetadata(ME, { title: "Accra at dusk", mediaUrl: want.posterUrl, mediaType: "image", place: "Accra" }, NOW);
    assertEquals(payload, want);
    assertHolds(payload, fixture("moment-metadata.legacy"));
  } finally {
    crypto.randomUUID = randomUUID;
    globalThis.fetch = original;
  }
});

Deno.test("POST /v1/media/upload-url equals media-upload-url.json", async () => {
  seed();
  const want = fixture("media-upload-url");
  const id = want.path.slice(want.path.lastIndexOf("/") + 1, -".jpg".length);
  const randomUUID = crypto.randomUUID;
  crypto.randomUUID = () => id;
  const original = fetch;
  globalThis.fetch = ((input: string | URL | Request) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    return Promise.resolve(Response.json({ url: `${url.pathname.replace("/storage/v1", "")}?token=fixture-upload-token` }));
  }) as typeof fetch;
  try {
    assertEquals(await signedUpload(ME, "image/jpeg", 812_345), want);
  } finally {
    crypto.randomUUID = randomUUID;
    globalThis.fetch = original;
  }
});

Deno.test("a Moments refusal answers in error-contract.json's shape: simulation_failed with its contract code", async () => {
  const shape = (v: unknown): unknown =>
    v !== null && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, shape(x)])) : typeof v;
  const body = await errorResponse(m.refusal("moment.sold_out", { raw: "HostError: Error(Contract, #8)" })).json();
  assertEquals(shape(body), shape(fixture("error-contract")));
  assertEquals(body.error.detail.contractCode, "moment.sold_out");
});
