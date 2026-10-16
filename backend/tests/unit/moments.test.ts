// Moments and media (docs/DESIGN-stellar-parity.md §6.9, §6.11, §12.5; WP-16): a Moment's metadata (a video needs its
// poster, the JSON always has an image, the network named from the environment, an external link only where Moments have
// one, media only the user's own uploads on our storage); its state; the feed's filters; the indexer's decoding of
// publish, collect, mint and transfer, which Moments are listed and what metadata it trusts; the upload budget; and the
// plans: the publish policy and its terms in the intent, the creator's trust step, and the contract's refusals.
import { Address, nativeToScVal, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { fakeSql, OTHER, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
for (const name of ["LITE_MOMENT_LINK_BASE", "LITE_INVITE_REQUIRED"]) Deno.env.delete(name);
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET, MAINNET } = await import("../../supabase/functions/_shared/networks.ts");
const { native } = await import("../../supabase/functions/_shared/stellar.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const media = await import("../../supabase/functions/_shared/media.ts");
const m = await import("../../supabase/functions/_shared/moments.ts");
const h = await import("../../supabase/functions/lite-indexer/handlers/moments.ts");

const ME = USER.publicKey();
const SOMEONE = OTHER.publicKey();
const MOMENTS = TESTNET.deployment!.moments;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const BASE = `${STORAGE}/storage/v1/object/public/lite-media/`;
const upload = (owner: string, file: string) => `${BASE}uploads/${owner}/${file}`;
const PHOTO = upload(ME, "7dedfd8a-9584-4cd0-a43a-cd036723818b.jpg");
const VIDEO = upload(ME, "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed.mp4");
const POSTER = upload(ME, "27601021-cbcb-4512-a8e3-69978e581185.jpg");
const NOW = Date.UTC(2026, 9, 14, 14, 0);

/** The error `fn` threw, as status, code and contract code. */
async function refusedWith(fn: () => unknown): Promise<[number, string, unknown]> {
  try {
    await fn();
  } catch (err) {
    assert(err instanceof ApiError, String(err));
    return [err.status, err.code, (err.detail as Row | undefined)?.contractCode];
  }
  throw new Error("not refused");
}

// ------------------------------------------------------------------------------------------------ a fake network

const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const u64 = (n: bigint) => nativeToScVal(n, { type: "u64" });
const addr = (a: string) => new Address(a).toScVal();
const str = (s: string) => nativeToScVal(s, { type: "string" });
const sym = (s: string) => xdr.ScVal.scvSymbol(s);
const bool = (b: boolean) => xdr.ScVal.scvBool(b);
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));

/** What the fake Moments contract answers. */
const chain = {
  publishing: true,
  rules: { [XLM.contract]: { min: 1_000_000n, enabled: true }, [USDC.contract]: { min: 1_000_000n, enabled: true } } as Record<string, { min: bigint; enabled: boolean }>,
  moment: { maxEditions: 10, minted: 3, deadline: BigInt(Math.floor(NOW / 1000) + 3_600), price: 10_000_000n, quote: XLM.contract },
  /** The account's trustlines on Horizon. */
  trustlines: [] as string[],
};

/** The host's log of a contract refusing with `code` (simulateTransaction's error text). */
function refusalText(contract: string, code: number): string {
  return `HostError: Error(Contract, #${code})\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${contract}, topics:[error, Error(Contract, #${code})], data:"escalating error to VM trap from failed host function call: call"\n   1: [Diagnostic Event] contract:${contract}, topics:[error, Error(Contract, #${code})], data:["failing with contract error", ${code}]`;
}

function answer(contract: string, fn: string, args: xdr.ScVal[]): xdr.ScVal | { error: string } {
  if (contract !== MOMENTS) return { error: "HostError: Error(Storage, MissingValue)" };
  if (fn === "config") {
    return struct({ admin: addr(SOMEONE), treasury: addr(SOMEONE), platform_bps: u32(500), royalty_bps: u32(700), publishing_enabled: bool(chain.publishing) });
  }
  if (fn === "quote_rule") {
    const rule = chain.rules[String(native(args[0]))];
    return rule ? struct({ min_price: i128(rule.min), enabled: bool(rule.enabled) }) : xdr.ScVal.scvVoid();
  }
  if (fn === "get_moment") {
    const id = Number(native(args[0]));
    if (id !== 3) return { error: refusalText(MOMENTS, 6) };
    const mo = chain.moment;
    return struct({
      id: u32(3),
      creator: addr(SOMEONE),
      uri: str(`${BASE}moments/${SOMEONE}/41019444-f54f-4a9e-ac88-2667a92257fa.json`),
      price: i128(mo.price),
      quote: addr(mo.quote),
      max_editions: u32(mo.maxEditions),
      minted: u32(mo.minted),
      published_at: u64(BigInt(Math.floor(NOW / 1000) - 86_400)),
      deadline: u64(mo.deadline),
      platform_bps: u32(500),
      royalty_bps: u32(500),
    });
  }
  return { error: refusalText(MOMENTS, 1) };
}

/** Storage writes and upload signatures, by URL. */
const stored: { url: string; body: string; headers: Headers }[] = [];
let storageDown = false;

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
  if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
    const id = url.pathname.split("/")[2];
    return Response.json({
      id,
      account_id: id,
      sequence: "1",
      subentry_count: chain.trustlines.length,
      thresholds: { low_threshold: 0, med_threshold: 0, high_threshold: 0 },
      flags: { auth_required: false, auth_revocable: false, auth_immutable: false, auth_clawback_enabled: false },
      signers: [{ key: id, weight: 1, type: "ed25519_public_key" }],
      balances: [
        ...chain.trustlines.map((line) => ({ asset_type: "credit_alphanum4", asset_code: line.split(":")[0], asset_issuer: line.split(":")[1], balance: "0.0000000", limit: "922337203685.4775807" })),
        { asset_type: "native", balance: "100.0000000", selling_liabilities: "0.0000000" },
      ],
      _links: {},
    });
  }
  if (url.origin === STORAGE) {
    if (storageDown) return new Response("down", { status: 500 });
    stored.push({ url: req.url, body: await req.text(), headers: req.headers });
    if (url.pathname.startsWith("/storage/v1/object/upload/sign/")) {
      return Response.json({ url: `${url.pathname.replace("/storage/v1", "")}?token=t0k3n` });
    }
    return Response.json({ Key: url.pathname });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** Runs queries against `respond`, recording each: the SQL text (fragments inlined, parameters as "?") and parameters. */
function database(respond: (q: string, params: unknown[]) => Row[]): { q: string; params: unknown[] }[] {
  const seen: { q: string; params: unknown[] }[] = [];
  replaceSql(fakeSql((q, params) => {
    seen.push({ q, params });
    if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
      return [{ ref: "XLM", usd: "0.1901", source: "kraken", market: "Kraken XLM/USD", change_24h: "0", volume_24h_usd: "1", quoted_at: new Date(NOW - 60_000) }];
    }
    return respond(q, params);
  }));
  forgetReferencePrices();
  return seen;
}

// ------------------------------------------------------------------------------------------------ metadata

Deno.test("metadata: a video without posterUrl is 400 bad_media; with one, the poster is its image; a photo is its own poster", () => {
  const video = { title: "Harbour at dusk", mediaUrl: VIDEO, mediaType: "video" };
  const e = assertThrows(() => m.metadataFields(ME, video, NOW), ApiError);
  assertEquals([e.status, e.code], [400, "bad_media"]);
  const withPoster = m.metadataFields(ME, { ...video, posterUrl: POSTER }, NOW);
  assertEquals([withPoster.mediaType, withPoster.mediaUrl, withPoster.posterUrl], ["video", VIDEO, POSTER]);
  // A photo is its own poster, whatever posterUrl says.
  const photo = m.metadataFields(ME, { title: "Accra", mediaUrl: PHOTO, mediaType: "image", posterUrl: POSTER }, NOW);
  assertEquals([photo.mediaType, photo.mediaUrl, photo.posterUrl], ["image", PHOTO, PHOTO]);
});

Deno.test("metadata: media is only the user's own upload of its kind on our storage", () => {
  const refused = (input: Record<string, unknown>) => {
    const e = assertThrows(() => m.metadataFields(ME, { title: "Accra", ...input }, NOW), ApiError);
    assertEquals([e.status, e.code], [400, "bad_media"], JSON.stringify(input));
  };
  refused({ mediaUrl: PHOTO, mediaType: "gif" });
  refused({ mediaUrl: upload(SOMEONE, "7dedfd8a-9584-4cd0-a43a-cd036723818b.jpg"), mediaType: "image" });
  refused({ mediaUrl: PHOTO.replace(STORAGE, "https://evil.example"), mediaType: "image" });
  refused({ mediaUrl: `${BASE}moments/${ME}/7dedfd8a-9584-4cd0-a43a-cd036723818b.jpg`, mediaType: "image" });
  refused({ mediaUrl: upload(ME, "../7dedfd8a-9584-4cd0-a43a-cd036723818b.jpg"), mediaType: "image" });
  refused({ mediaUrl: VIDEO, mediaType: "image" });
  refused({ mediaUrl: PHOTO, mediaType: "video", posterUrl: POSTER });
  // A video's poster is an image of the user's own.
  refused({ mediaUrl: VIDEO, mediaType: "video", posterUrl: VIDEO });
  refused({ mediaUrl: VIDEO, mediaType: "video", posterUrl: upload(SOMEONE, "27601021-cbcb-4512-a8e3-69978e581185.jpg") });
});

Deno.test("metadata: title 1–80 characters, description at most 500, place at most 64, a real date not in the future", () => {
  const ok = { title: "  Accra at dusk  ", mediaUrl: PHOTO, mediaType: "image" };
  assertEquals(m.metadataFields(ME, ok, NOW).title, "Accra at dusk");
  const code = (input: Record<string, unknown>) => assertThrows(() => m.metadataFields(ME, { ...ok, ...input }, NOW), ApiError).code;
  assertEquals(code({ title: "" }), "bad_title");
  assertEquals(code({ title: "   " }), "bad_title");
  assertEquals(code({ title: "x".repeat(81) }), "bad_title");
  assertEquals(code({ title: 7 }), "bad_title");
  assertEquals(code({ description: "x".repeat(501) }), "bad_arg");
  assertEquals(code({ place: "x".repeat(65) }), "bad_arg");
  assertEquals(code({ takenOn: "2026-02-30" }), "bad_arg");
  assertEquals(code({ takenOn: "14/10/2026" }), "bad_arg");
  assertEquals(code({ takenOn: "2026-10-16" }), "bad_arg");
  const full = m.metadataFields(ME, { ...ok, description: " The last ferry. ", place: "Accra", takenOn: "2026-10-15" }, NOW);
  assertEquals([full.description, full.place, full.takenOn], ["The last ferry.", "Accra", "2026-10-15"]);
  const bare = m.metadataFields(ME, { ...ok, description: "", place: "  " }, NOW);
  assertEquals([bare.description, bare.place, bare.takenOn], [null, null, null]);
});

Deno.test("metadata: takenOn is a day, or a date and time with its offset (ISO 8601) written one way, never in the future", () => {
  const ok = { title: "Accra at dusk", mediaUrl: PHOTO, mediaType: "image" };
  const taken = (takenOn: unknown) => m.metadataFields(ME, { ...ok, takenOn }, NOW).takenOn;
  const code = (takenOn: unknown) => assertThrows(() => m.metadataFields(ME, { ...ok, takenOn }, NOW), ApiError).code;
  // NOW is 2026-10-14T14:00:00Z.
  assertEquals(taken("2026-10-14"), "2026-10-14", "a day as it is");
  assertEquals(taken("2026-10-14T13:30:00Z"), "2026-10-14T13:30:00Z");
  assertEquals(taken("2026-10-14T15:30:00+02:00"), "2026-10-14T15:30:00+02:00", "the creator's own offset kept");
  assertEquals(taken("2026-10-14T04:00-09:30"), "2026-10-14T04:00:00-09:30", "seconds written out");
  assertEquals(taken("2026-10-14T13:59:59.999Z"), "2026-10-14T13:59:59Z", "a fraction dropped");
  assertEquals(taken("2026-10-14T13:00:00+00:00"), "2026-10-14T13:00:00Z", "UTC written as Z");
  assertEquals(taken("2026-10-14T14:04:00Z"), "2026-10-14T14:04:00Z", "a phone clock a little fast");
  assertEquals(taken("2026-10-15T01:00:00+14:00"), "2026-10-15T01:00:00+14:00", "the next day where it is, an hour ago here");
  assertEquals(taken(""), null);
  for (const bad of [
    "2026-10-14T14:06:00Z", // later than now, past the clock's slack
    "2026-10-14T16:30:00+02:00", // the same instant
    "2026-02-30T10:00:00Z",
    "2026-10-14T24:00:00Z",
    "2026-10-14T10:60:00Z",
    "2026-10-14T10:00:00", // no offset: no instant
    "2026-10-14T10:00:00+15:00",
    "2026-10-14 10:00:00Z",
    "2026-10-14T10Z",
    "14/10/2026",
    7,
  ]) assertEquals(code(bad), "bad_arg", String(bad));
  // Every accepted form fits the contract's date (at most 32 bytes).
  for (const v of ["2026-10-14", "2026-10-14T04:00:00-09:30", "2026-10-14T13:59:59.123456789Z"]) assert(new TextEncoder().encode(taken(v)!).length <= 32, v);
});

Deno.test("metadata: the Date attribute and the record carry the time; the day goes where readers of the day have it", async () => {
  const video = m.metadataFields(ME, { title: "Harbour", mediaUrl: VIDEO, mediaType: "video", posterUrl: POSTER, takenOn: "2026-10-14T15:30:00+02:00" }, NOW);
  assertEquals(m.sep50Json(ME, video, "testnet", null).attributes, [
    { trait_type: "Creator", value: ME },
    { trait_type: "Network", value: "Stellar Testnet" },
    { trait_type: "Date", value: "2026-10-14T15:30:00+02:00" },
  ]);
  const seen = database((q) => {
    if (q.startsWith("insert into lite.moment_metadata")) return [];
    throw new Error(`unexpected query: ${q}`);
  });
  stored.length = 0;
  for (const [takenOn, day, time] of [
    ["2026-10-14T15:30:00+02:00", "2026-10-14", "2026-10-14T15:30:00+02:00"],
    // The creator's own calendar day: still the 13th where it was taken.
    ["2026-10-13T21:00:00-09:00", "2026-10-13", "2026-10-13T21:00:00-09:00"],
    ["2026-10-13", "2026-10-13", null],
  ] as const) {
    const out = await m.writeMetadata(ME, { title: "Harbour", mediaUrl: PHOTO, mediaType: "image", takenOn }, NOW);
    const insert = seen.findLast((s) => s.q.startsWith("insert into lite.moment_metadata"))!;
    assertEquals(insert.params, [out.uri, ME, "Harbour", null, null, day, time, "image", PHOTO, PHOTO], takenOn);
    const json = JSON.parse(stored[stored.length - 1].body);
    assertEquals(json.attributes.find((a: { trait_type: string }) => a.trait_type === "Date")?.value, takenOn);
  }
  // A Moment's row answers the time when its record has one, else the day.
  assertEquals(m.takenText("2026-10-14T15:30:00+02:00", new Date("2026-10-14T00:00:00Z")), "2026-10-14T15:30:00+02:00");
  assertEquals(m.takenText(null, new Date("2026-10-14T00:00:00Z")), "2026-10-14");
  assertEquals(m.takenText(null, "2026-10-14"), "2026-10-14");
  assertEquals(m.takenText(undefined, null), null);
});

Deno.test("SEP-50 JSON: always an image; animation_url only for a video; the network's name; Place and Date when given", () => {
  const video = m.metadataFields(ME, { title: "Harbour", mediaUrl: VIDEO, mediaType: "video", posterUrl: POSTER, place: "Accra", takenOn: "2026-10-13" }, NOW);
  assertEquals(m.sep50Json(ME, video, "testnet", null), {
    name: "Harbour",
    description: "",
    image: POSTER,
    animation_url: VIDEO,
    attributes: [
      { trait_type: "Creator", value: ME },
      { trait_type: "Network", value: "Stellar Testnet" },
      { trait_type: "Place", value: "Accra" },
      { trait_type: "Date", value: "2026-10-13" },
    ],
  });
  const photo = m.metadataFields(ME, { title: "Accra", description: "Dusk.", mediaUrl: PHOTO, mediaType: "image" }, NOW);
  const json = m.sep50Json(ME, photo, "mainnet", "https://dyorhq.fun/moments/x");
  assertEquals(json, {
    name: "Accra",
    description: "Dusk.",
    image: PHOTO,
    external_url: "https://dyorhq.fun/moments/x",
    attributes: [{ trait_type: "Creator", value: ME }, { trait_type: "Network", value: "Stellar" }],
  });
  assert(!("animation_url" in json));
});

Deno.test("POST /v1/moments/metadata writes the JSON once to lite-media and records it; external_url only with LITE_MOMENT_LINK_BASE", async () => {
  const seen = database((q) => {
    if (q.startsWith("insert into lite.moment_metadata")) return [];
    throw new Error(`unexpected query: ${q}`);
  });
  for (const linkBase of [undefined, "https://dyorhq.fun/moments"]) {
    if (linkBase) Deno.env.set("LITE_MOMENT_LINK_BASE", linkBase);
    else Deno.env.delete("LITE_MOMENT_LINK_BASE");
    stored.length = 0;
    const out = await m.writeMetadata(ME, { title: "Harbour", mediaUrl: VIDEO, mediaType: "video", posterUrl: POSTER, place: "Accra" }, NOW);
    assert(new RegExp(`^${BASE}moments/${ME}/[0-9a-f-]{36}\\.json$`).test(out.uri), out.uri);
    assertEquals(out.posterUrl, POSTER);
    const [write] = stored;
    assertEquals(write.url, `${STORAGE}/storage/v1/object/lite-media/${out.uri.slice(BASE.length)}`);
    assertEquals([write.headers.get("x-upsert"), write.headers.get("content-type")], ["false", "application/json"]);
    const json = JSON.parse(write.body);
    assertEquals([json.image, json.animation_url, json.attributes[1].value], [POSTER, VIDEO, "Stellar Testnet"]);
    const id = out.uri.slice(out.uri.lastIndexOf("/") + 1, -".json".length);
    assertEquals(json.external_url, linkBase ? `${linkBase}/${id}` : undefined);
    const insert = seen.findLast((s) => s.q.startsWith("insert into lite.moment_metadata"))!;
    assertEquals(insert.params, [out.uri, ME, "Harbour", null, "Accra", null, null, "video", VIDEO, POSTER]);
  }
  Deno.env.delete("LITE_MOMENT_LINK_BASE");
  // Nothing is recorded when storage refuses the write.
  storageDown = true;
  const before = seen.length;
  try {
    assertEquals((await refusedWith(() => m.writeMetadata(ME, { title: "Accra", mediaUrl: PHOTO, mediaType: "image" }, NOW))).slice(0, 2), [502, "storage_error"]);
  } finally {
    storageDown = false;
  }
  assertEquals(seen.slice(before).filter((s) => s.q.startsWith("insert")).length, 0);
});

// ------------------------------------------------------------------------------------------------ states and the feed

Deno.test("state: collecting until the window closes or the editions sell out; sold out wins over a closed window", () => {
  const later = new Date(NOW + 1_000);
  const earlier = new Date(NOW - 1_000);
  assertEquals(m.momentState(10, 3, later, NOW), "collecting");
  assertEquals(m.momentState(0, 50_000, later, NOW), "collecting");
  assertEquals(m.momentState(10, 10, later, NOW), "sold_out");
  assertEquals(m.momentState(10, 10, earlier, NOW), "sold_out");
  assertEquals(m.momentState(10, 3, earlier, NOW), "closed");
  assertEquals(m.momentState(0, 3, new Date(NOW), NOW), "closed");
});

const ROW: Row = {
  id: 3,
  creator: SOMEONE,
  uri: `${BASE}moments/${SOMEONE}/41019444-f54f-4a9e-ac88-2667a92257fa.json`,
  title: "Harbour at dusk",
  media_url: VIDEO,
  price: "10000000",
  quote: XLM.contract,
  max_editions: 10,
  minted: 3,
  deadline: new Date(NOW + 3_600_000),
  created_at: new Date(NOW - 86_400_000),
  description: null,
  place: "Accra",
  taken_on: new Date("2026-10-13T00:00:00.000Z"),
  media_type: "video",
  poster_url: POSTER,
  platform_bps: 500,
  royalty_bps: 500,
  collects: 2,
  collectors: 2,
  listed: true,
};

Deno.test("the feed: listed Moments with a title, newest first; collecting, or closed (sold out and window closed)", async () => {
  const seen = database((q) => {
    if (q.startsWith("select * from lite.moments where listed and title is not null")) return [ROW];
    throw new Error(`unexpected query: ${q}`);
  });
  const all = await m.feed("all", 50, NOW);
  assertEquals(all.map((r) => [r.id, r.state, r.open, r.priceUsd, r.quoteCode, r.takenOn]), [[3, "collecting", true, 0.19, "XLM", "2026-10-13"]]);
  await m.feed("collecting", 20, NOW);
  await m.feed("closed", 20, NOW);
  const feeds = seen.filter((s) => s.q.startsWith("select * from lite.moments"));
  assertEquals(feeds.map((s) => s.q), [
    "select * from lite.moments where listed and title is not null and id is not null order by created_at desc, id desc limit ?",
    "select * from lite.moments where listed and title is not null and id is not null and deadline > ? and (max_editions = 0 or minted < max_editions) order by created_at desc, id desc limit ?",
    "select * from lite.moments where listed and title is not null and id is not null and not (deadline > ? and (max_editions = 0 or minted < max_editions)) order by created_at desc, id desc limit ?",
  ]);
  assertEquals(feeds[1].params, [new Date(NOW), 20]);
  assertEquals(m.filterArg(null), "all");
  assertEquals(m.filterArg("closed"), "closed");
  assertEquals(assertThrows(() => m.filterArg("sold_out"), ApiError).code, "bad_arg");
});

Deno.test("a row indexed before migration 09: its media type from the file, no terms, no poster for a video", () => {
  const prices = { XLM: { ref: "XLM", usd: null, stale: true, at: null, market: "", change24h: null, volume24hUsd: null }, USDC: { ref: "USDC", usd: 1, stale: false, at: null, market: "", change24h: null, volume24hUsd: null } } as const;
  const old = m.momentRowOf({ ...ROW, media_type: null, poster_url: null, platform_bps: null, royalty_bps: null, taken_on: null }, prices as any, NOW);
  assertEquals([old.mediaType, old.posterUrl, old.platformBps, old.royaltyBps, old.priceUsd], ["video", null, undefined, undefined, null]);
  assertEquals(m.momentRowOf({ ...ROW, media_type: null, media_url: PHOTO }, prices as any, NOW).mediaType, "image");
});

Deno.test("a Moment without a title is never served: 404", async () => {
  database((q) => {
    if (q === "select * from lite.moments where id = ?") return [{ ...ROW, title: null }];
    throw new Error(`unexpected query: ${q}`);
  });
  assertEquals((await refusedWith(() => m.momentDetail(3, { address: null, scope: "public" }, NOW))).slice(0, 2), [404, "not_found"]);
});

Deno.test("a Moment's page in the public view: the editions ?address= holds, spent null; without ?address=, no you", async () => {
  const seen = database((q) => {
    if (q === "select * from lite.moments where id = ?") return [ROW];
    if (q.startsWith("select collector, quantity, first_token_id, ts from lite.moment_collects")) return [];
    if (q.startsWith("select collector, sum(quantity)::int as editions")) return [];
    if (q.startsWith("select coalesce(sum(lite.moment_creator_share(paid, ?)), 0) as earned")) return [{ earned: "0" }];
    if (q.startsWith("select token_id from lite.moment_editions")) return [{ token_id: 9 }];
    throw new Error(`unexpected query: ${q}`);
  });
  const named = await m.momentDetail(3, { address: SOMEONE, scope: "public" }, NOW);
  assertEquals([named.you, named.view, named.creatorEarned, named.collectorsSummary], [{ editions: [9], spent: null }, "public", "0", { count: 2, largest: null }]);
  assert(!seen.some((s) => s.q.includes("sum(paid), 0) as spent")), "the public view reads no spending");
  const anyone = await m.momentDetail(3, { address: null, scope: "public" }, NOW);
  assertEquals(anyone.you, null);
});

// ------------------------------------------------------------------------------------------------ the indexer

/** An event as main_events.ts hands it over: topics and data decoded from their ScVals. */
function event(topics: xdr.ScVal[], data: xdr.ScVal) {
  return { topics: topics.map((t) => native(t)), data: native(data) };
}

Deno.test("decode: publish and collect, with their amounts as integers and the deadline as a time", () => {
  const publish = h.decodePublish(event(
    [sym("publish"), u32(3), addr(ME)],
    struct({ uri: str(`${BASE}moments/${ME}/a.json`), price: i128(10_000_000n), quote: addr(XLM.contract), max_editions: u32(0), deadline: u64(1_792_000_000n) }),
  ));
  assertEquals(publish, { id: 3, creator: ME, uri: `${BASE}moments/${ME}/a.json`, price: 10_000_000n, quote: XLM.contract, maxEditions: 0, deadline: new Date(1_792_000_000_000) });
  const collect = h.decodeCollect(event([sym("collect"), u32(3), addr(SOMEONE)], struct({ quantity: u32(20), first_token_id: u32(7), paid: i128(200_000_000n), minted: u32(27) })));
  assertEquals(collect, { id: 3, collector: SOMEONE, quantity: 20, firstTokenId: 7, paid: 200_000_000n, minted: 27 });
  assertEquals(h.editionsOf(collect), Array.from({ length: 20 }, (_, i) => 7 + i));
  assertEquals(h.editionsOf({ ...collect, quantity: 1, firstTokenId: 0 }), [0]);
});

Deno.test("decode: the collection's mint and transfer (OpenZeppelin's events), the token id as a map or a bare value", () => {
  assertEquals(h.decodeMove(event([sym("mint"), addr(ME)], struct({ token_id: u32(0) }))), { tokenId: 0, from: null, to: ME });
  assertEquals(h.decodeMove(event([sym("transfer"), addr(ME), addr(SOMEONE)], struct({ token_id: u32(12) }))), { tokenId: 12, from: ME, to: SOMEONE });
  assertEquals(h.decodeMove(event([sym("transfer"), addr(ME), addr(SOMEONE)], u32(13))), { tokenId: 13, from: ME, to: SOMEONE });
  assertEquals(h.decodeMove(event([sym("transfer"), addr(ME), addr(SOMEONE)], xdr.ScVal.scvVec([u32(14)]))), { tokenId: 14, from: ME, to: SOMEONE });
});

Deno.test("listed: a title and an image, and not a smoke Moment", () => {
  const meta = { title: "Accra", posterUrl: PHOTO };
  assertEquals(h.listedFor(meta, 3, []), true);
  assertEquals(h.listedFor(meta, 1, [1]), false);
  assertEquals(h.listedFor(null, 3, []), false);
  assertEquals(h.listedFor({ title: "", posterUrl: PHOTO }, 3, []), false);
  assertEquals(h.listedFor({ title: "Accra", posterUrl: "" }, 3, []), false);
});

Deno.test("metadata the indexer reads: only media on our storage; a video without an image has no poster", () => {
  const video = h.metadataFromJson({
    name: " Harbour ",
    description: "Dusk.",
    image: POSTER,
    animation_url: VIDEO,
    attributes: [{ trait_type: "Place", value: "Accra" }, { trait_type: "Date", value: "2026-10-13" }, { trait_type: "Network", value: "Stellar Testnet" }],
  });
  assertEquals(video, { title: "Harbour", description: "Dusk.", place: "Accra", takenOn: "2026-10-13", mediaType: "video", mediaUrl: VIDEO, posterUrl: POSTER });
  assertEquals(h.metadataFromJson({ name: "Harbour", animation_url: VIDEO })?.posterUrl, "");
  assertEquals(h.metadataFromJson({ name: "Accra", image: "https://evil.example/a.jpg" }), null);
  assertEquals(h.metadataFromJson({ name: "Accra", image: VIDEO }), null);
  assertEquals(h.metadataFromJson({ image: PHOTO }), null);
  assertEquals(h.metadataFromJson([PHOTO]), null);
  assertEquals(h.metadataFromJson({ name: "Accra", image: PHOTO, attributes: [{ trait_type: "Date", value: "yesterday" }] })?.takenOn, null);
});

/** A contract event as RPC hands it to the indexer. */
function rpcEvent(id: string, topics: xdr.ScVal[], data: xdr.ScVal) {
  const decoded = event(topics, data);
  return { raw: { id, ledger: 5_200_000, txHash: "ab".repeat(32) }, kind: String(decoded.topics[0]), ...decoded, ts: new Date(NOW) };
}

Deno.test("the indexer: a publish joins the creator's own metadata, reads the terms, and is listed; another's metadata isn't trusted", async () => {
  const uri = `${BASE}moments/${ME}/9c3e1c0a-0000-4000-8000-000000000001.json`;
  const meta = { uri, address: ME, title: "Accra", description: null, place: "Accra", taken_on: "2026-10-13", media_type: "image", media_url: PHOTO, poster_url: PHOTO };
  for (const [writer, title, listed] of [[ME, "Accra", true], [SOMEONE, null, false]] as const) {
    const seen = database((q) => {
      if (q === "select * from lite.moment_metadata where uri = ?") return [{ ...meta, address: writer }];
      if (q.startsWith("insert into lite.moments")) return [];
      throw new Error(`unexpected query: ${q}`);
    });
    const e = rpcEvent("0022204953427812352-0000000001", [sym("publish"), u32(3), addr(ME)],
      struct({ uri: str(uri), price: i128(10_000_000n), quote: addr(XLM.contract), max_editions: u32(10), deadline: u64(1_792_000_000n) }));
    await h.momentsEvent(e as any);
    const insert = seen.find((s) => s.q.startsWith("insert into lite.moments"))!;
    assertEquals(insert.params.slice(0, 4), [3, ME, uri, title]);
    // description, place, taken_on, media_type, poster_url, platform_bps, royalty_bps, listed
    assertEquals(insert.params.slice(11), title ? [null, "Accra", "2026-10-13", "image", PHOTO, 500, 500, true] : [null, null, null, null, null, 500, 500, listed]);
  }
});

Deno.test("the indexer: a collect records the collect and the editions, held by the collector; mint and transfer move an edition", async () => {
  const seen = database((q) => {
    if (q.startsWith("insert into lite.moment_collects")) return [{ event_id: "e" }];
    if (q.startsWith("update lite.moments set minted")) return [];
    if (q === "select 1 from lite.moments where id = ?") return [{ "?column?": 1 }];
    if (q.startsWith("insert into lite.moment_editions")) return [];
    throw new Error(`unexpected query: ${q}`);
  });
  await h.momentsEvent(rpcEvent("0022204953427812352-0000000003", [sym("collect"), u32(3), addr(SOMEONE)],
    struct({ quantity: u32(2), first_token_id: u32(7), paid: i128(20_000_000n), minted: u32(5) })) as any);
  await h.momentsEvent(rpcEvent("0022204957722779648-0000000001", [sym("transfer"), addr(SOMEONE), addr(ME)], struct({ token_id: u32(8) })) as any);
  const editions = seen.filter((s) => s.q.startsWith("insert into lite.moment_editions"));
  assertEquals(editions.map((s) => s.params), [
    [MOMENTS, 3, SOMEONE, "0022204953427812352-0000000003", 5_200_000, [7, 8]],
    [MOMENTS, null, ME, "0022204957722779648-0000000001", 5_200_000, [8]],
  ]);
  // An owner is set only by a newer event than the one that set it.
  assert(editions[0].q.includes("owner = case when excluded.owner_event >= lite.moment_editions.owner_event then excluded.owner else lite.moment_editions.owner end"));
  const update = seen.find((s) => s.q.startsWith("update lite.moments set minted"))!;
  assertEquals(update.params, [5, 3, 3]);
});

// ------------------------------------------------------------------------------------------------ uploads

Deno.test("upload tickets: the real content types, at most 25 MB, the daily budget (429 upload_budget)", async () => {
  let budgetOk = true;
  const seen = database((q) => {
    if (q.startsWith("select lite.reserve_media_upload(")) return [{ ok: budgetOk }];
    if (q.startsWith("delete from lite.media_uploads where path = ?")) return [];
    throw new Error(`unexpected query: ${q}`);
  });
  for (const type of ["text/plain", "image/svg+xml", "video/webm", "image/jpg"]) {
    assertEquals((await refusedWith(() => media.signedUpload(ME, type, 10))).slice(0, 2), [400, "bad_type"], type);
  }
  for (const bytes of [0, -1, 1.5, 25 * 1024 * 1024 + 1]) {
    assertEquals((await refusedWith(() => media.signedUpload(ME, "video/mp4", bytes))).slice(0, 2), [400, "too_large"], String(bytes));
  }
  assertEquals(seen.length, 0, "nothing is counted for a refused type or size");

  stored.length = 0;
  const ticket = await media.signedUpload(ME, "video/quicktime", 25 * 1024 * 1024);
  assert(new RegExp(`^uploads/${ME}/[0-9a-f-]{36}\\.mov$`).test(ticket.path), ticket.path);
  assertEquals(ticket.publicUrl, `${BASE}${ticket.path}`);
  assertEquals(ticket.uploadUrl, `${STORAGE}/storage/v1/object/upload/sign/lite-media/${ticket.path}?token=t0k3n`);
  const reserve = seen.find((s) => s.q.startsWith("select lite.reserve_media_upload("))!;
  assertEquals(reserve.params, [ME, ticket.path, "video/quicktime", 25 * 1024 * 1024, 50, 200 * 1024 * 1024]);

  budgetOk = false;
  const over = await refusedWith(() => media.signedUpload(ME, "image/png", 1_000));
  assertEquals(over.slice(0, 2), [429, "upload_budget"]);
  budgetOk = true;

  // A URL Storage didn't issue doesn't count.
  storageDown = true;
  try {
    assertEquals((await refusedWith(() => media.signedUpload(ME, "image/png", 1_000))).slice(0, 2), [502, "storage_error"]);
  } finally {
    storageDown = false;
  }
  const kept = seen.findLast((s) => s.q.startsWith("select lite.reserve_media_upload("))!;
  assertEquals(seen.at(-1)!.q, "delete from lite.media_uploads where path = ?");
  assertEquals(seen.at(-1)!.params, [kept.params[1]]);
});

Deno.test("media: our own uploads only, under the user's folder, of the kind asked", () => {
  assertEquals(media.ownUpload(PHOTO, ME, "image"), PHOTO);
  assertEquals(media.ownUpload(PHOTO, SOMEONE, "image"), null);
  assertEquals(media.ownUpload(PHOTO, ME, "video"), null);
  assertEquals(media.ownUpload(`${PHOTO}?x=1`, ME, "image"), null);
  assertEquals(media.ownUpload(42, ME, "image"), null);
  assertEquals(media.anyUpload(upload(SOMEONE, "27601021-cbcb-4512-a8e3-69978e581185.webp"), "image") !== null, true);
  assertEquals(media.mediaBase(), BASE);
});

// ------------------------------------------------------------------------------------------------ plans

Deno.test("the contract's refusals: the number Moments itself failed with, never another contract's", () => {
  assertEquals(m.momentsError(refusalText(MOMENTS, 8), MOMENTS), 8);
  assertEquals(m.momentsError(refusalText(XLM.contract, 10), MOMENTS), null);
  assertEquals(m.momentsError("HostError: Error(Contract, #8)", MOMENTS), null);
  const e = m.refusal("moment.price_too_low", { minPrice: "1000000", quoteCode: "XLM" });
  assertEquals([e.status, e.code, e.message, e.detail], [422, "simulation_failed", "The price is below the minimum (0.1 XLM).", { contractCode: "moment.price_too_low", minPrice: "1000000", quoteCode: "XLM" }]);
  assertEquals(m.refusal("moment.sold_out").message, "This Moment is sold out.");
  assertEquals(m.refusal("moment.closed").message, "This Moment's collect window has closed.");
});

const PUBLISH = { action: "publish", uri: `${BASE}moments/${ME}/9c3e1c0a-0000-4000-8000-000000000001.json`, price: "10000000", quote: "XLM", maxEditions: 10, windowSecs: 7_200 };

function metadataDb(owner = ME) {
  return database((q, params) => {
    if (q === "select 1 from lite.moment_metadata where uri = ? and address = ?") return params[1] === owner ? [{ "?column?": 1 }] : [];
    throw new Error(`unexpected query: ${q}`);
  });
}

Deno.test("publish: the user's own metadata, the editions and window limits, a price at the quote's minimum or above", async () => {
  metadataDb();
  const steps = await m.publishSteps(ME, PUBLISH);
  assertEquals(steps, [{ label: "Publish Moment", spec: { kind: "moment_publish", uri: PUBLISH.uri, price: "10000000", quote: XLM.contract, maxEditions: 10, windowSecs: 7_200 } }]);
  const code = async (input: Record<string, unknown>, user = ME) => (await refusedWith(() => m.publishSteps(user, { ...PUBLISH, ...input }))).slice(1);
  assertEquals(await code({}, SOMEONE), ["bad_uri", undefined]);
  assertEquals(await code({ uri: "" }), ["bad_uri", undefined]);
  assertEquals(await code({ quote: "BUSDC" }), ["bad_quote", undefined]);
  assertEquals(await code({ maxEditions: 100_001 }), ["bad_editions", undefined]);
  assertEquals(await code({ maxEditions: -1 }), ["bad_editions", undefined]);
  assertEquals(await code({ windowSecs: 3_599 }), ["bad_window", undefined]);
  assertEquals(await code({ windowSecs: 30 * 86_400 + 1 }), ["bad_window", undefined]);
  assertEquals(await code({ price: "0" }), ["bad_amount", undefined]);
  assertEquals(await code({ price: 10_000_000 }), ["bad_amount", undefined]);
  const low = await refusedWith(() => m.publishSteps(ME, { ...PUBLISH, price: "999999" }));
  assertEquals(low, [422, "simulation_failed", "moment.price_too_low"]);
  chain.rules[XLM.contract].enabled = false;
  try {
    assertEquals(await code({}), ["bad_quote", undefined]);
  } finally {
    chain.rules[XLM.contract].enabled = true;
  }
  chain.publishing = false;
  try {
    assertEquals(await code({}), ["simulation_failed", undefined]);
  } finally {
    chain.publishing = true;
  }
});

Deno.test("publish in USDC: a user-paid trust step first when the creator lacks the trustline, none once they have it", async () => {
  metadataDb();
  chain.trustlines = [];
  const steps = await m.publishSteps(ME, { ...PUBLISH, quote: "USDC" });
  assertEquals(steps.map((s) => s.spec.kind), ["trust", "moment_publish"]);
  assertEquals(steps[0], { label: "Enable USDC", spec: { kind: "trust", asset: USDC.classic } });
  chain.trustlines = [USDC.classic!];
  try {
    assertEquals((await m.publishSteps(ME, { ...PUBLISH, quote: "USDC" })).map((s) => s.spec.kind), ["moment_publish"]);
  } finally {
    chain.trustlines = [];
  }
  assertEquals((await m.publishSteps(ME, PUBLISH)).map((s) => s.spec.kind), ["moment_publish"]);
});

Deno.test("publish's intent carries the terms it was built under: platformBps, royaltyBps and minPrice, read live", async () => {
  const policy = await m.publishPolicy(MOMENTS, XLM.contract);
  assertEquals(policy, { platformBps: 500, royaltyBps: 700, publishingEnabled: true, minPrice: "1000000", quoteEnabled: true });
  const [step] = await (metadataDb(), m.publishSteps(ME, PUBLISH));
  const intent = m.publishIntent(MOMENTS, step.spec, XLM, policy);
  assertEquals(intent, {
    kind: "moment_publish",
    summary: "Publish a Moment at 1 XLM",
    spend: {},
    calls: [{ contract: MOMENTS, fn: "publish" }],
    display: { price: "10000000", quote: "XLM", editions: 10, windowSecs: 7_200, platformBps: 500, royaltyBps: 700, minPrice: "1000000" },
  });
});

Deno.test("collect: 1 to 20 editions at the Moment's price; sold out, closed and unknown Moments are refused before signing", async () => {
  database(() => []);
  const [step] = await m.collectSteps({ momentId: 3, quantity: 7 }, TESTNET, NOW);
  assertEquals(step, { label: "Collect 7", spec: { kind: "moment_collect", momentId: 3, quantity: 7, maxTotal: "70000000", quote: XLM.contract } });
  const intent = m.collectIntent(MOMENTS, step.spec, XLM);
  assertEquals([intent.spend, intent.calls, intent.display], [{ [XLM.contract]: "70000000" }, [{ contract: MOMENTS, fn: "collect" }], { momentId: 3, quantity: 7, total: "70000000", quote: "XLM" }]);
  const refused = async (input: Record<string, unknown>, now = NOW) => await refusedWith(() => m.collectSteps(input, TESTNET, now));
  assertEquals(await refused({ momentId: 3, quantity: 8 }), [422, "simulation_failed", "moment.sold_out"]);
  assertEquals(await refused({ momentId: 3, quantity: 1 }, NOW + 3_600_000), [422, "simulation_failed", "moment.closed"]);
  assertEquals(await refused({ momentId: 4, quantity: 1 }), [404, "not_found", undefined]);
  assertEquals(await refused({ momentId: 3, quantity: 21 }), [400, "bad_quantity", undefined]);
  assertEquals(await refused({ momentId: 3, quantity: 0 }), [400, "bad_quantity", undefined]);
  assertEquals(await refused({ momentId: 0 }), [400, "bad_moment", undefined]);
  // An open edition never sells out; 20 at a time is the most.
  chain.moment.maxEditions = 0;
  try {
    assertEquals((await m.collectSteps({ momentId: 3, quantity: 20 }, TESTNET, NOW))[0].spec.maxTotal, "200000000");
  } finally {
    chain.moment.maxEditions = 10;
  }
});

Deno.test("the network names itself in the attributes", () => {
  assertEquals([m.networkLabel(TESTNET.name), m.networkLabel(MAINNET.name)], ["Stellar Testnet", "Stellar"]);
});
