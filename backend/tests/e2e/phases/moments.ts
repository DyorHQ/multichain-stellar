// moments (docs/DESIGN-stellar-parity.md §12.6; WP-16): media uploaded through the stack's storage (the local media
// stand-in on a local stack: a path takes one upload, and is served with its type); a video's metadata refused without
// its poster, then written with it (image = the poster, animation_url = the video); a photo Moment and a video Moment
// published, each plan carrying the terms it was built under; both on the feed with no session, titled and with a
// poster, and no Moment without a title served; a second account collects 2, then 20 editions, each collect's fee
// within the network's cap (config.fees.maxFee); its editions, with no session too, are exactly the ones owner_of
// names on chain; the Moment's page counts them; My Moments needs a session and adds up the spending and the
// earnings; a collect past the cap is refused before signing (moment.sold_out).
import { Keypair, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import { hex, SEP53_PREFIX, sha256 } from "../../../supabase/functions/_shared/auth.ts";
import { sv, view } from "../../../supabase/functions/_shared/stellar.ts";
import { verifyTransaction } from "../../../supabase/functions/_shared/verify.ts";
import type { E2E } from "../lite_e2e.ts";

/** A 1×1 PNG for the photo, and a 1×1 JPEG for the video's poster (the phone uploads a frame as a JPEG). */
const bytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const PNG = bytes("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==");
const JPEG = bytes(
    "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB" +
    "AAAAAaADAAQAAAABAAAAAQAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+" +
    "/8AAEQgAAQABAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAE" +
    "EQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0" +
    "dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5" +
    "+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRC" +
    "kaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKT" +
    "lJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMAAgICAgICAwICAwUD" +
    "AwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQ" +
    "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A7iiiiv8AQA+XP//Z",
);
/** An MP4's file-type box: the start of a video, all the stand-in stores. */
const MP4 = Uint8Array.from([0, 0, 0, 0x18, ...new TextEncoder().encode("ftypmp42"), 0, 0, 0, 0, ...new TextEncoder().encode("mp42isom")]);
const PRICE = 10_000_000n;
const MAX_EDITIONS = 30;

interface Answer {
  status: number;
  body: any;
  cache: string | null;
}

/** A request as the holder of `token` (none: no Authorization header), whatever its status. */
async function call(t: E2E, token: string | null, method: string, path: string, body?: unknown): Promise<Answer> {
  const res = await fetch(`${t.API}/v1${path}`, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null, cache: res.headers.get("cache-control") };
}

/** call(), throwing unless 2xx. */
async function api(t: E2E, token: string | null, method: string, path: string, body?: unknown): Promise<any> {
  const a = await call(t, token, method, path, body);
  if (a.status < 200 || a.status > 299) throw new Error(`${method} ${path} → ${a.status} ${JSON.stringify(a.body?.error ?? a.body)}`);
  return a.body;
}

/** Throws unless `a` is the refusal `status` `code`. */
function expectRefusal(a: Answer, status: number, code: string, what: string): Answer {
  if (a.status !== status || a.body?.error?.code !== code) throw new Error(`${what}: expected ${status} ${code}, got ${a.status} ${JSON.stringify(a.body)}`);
  return a;
}

/** Signs `kp` in (SEP-53), with an invite written first where the network needs one. */
async function signIn(t: E2E, kp: Keypair): Promise<string> {
  let inviteCode: string | undefined;
  if (t.config.inviteRequired !== false) {
    inviteCode = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await t.db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(inviteCode))}, 'e2e', 1)`;
  }
  const ch = await api(t, null, "POST", "/auth/challenge", { address: kp.publicKey() });
  const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
  return (await api(t, null, "POST", "/auth/verify", { address: kp.publicKey(), nonce: ch.nonce, signature, ...(inviteCode ? { inviteCode } : {}) })).token;
}

/** The fee a built step declares, and the network's cap on it. */
function feeOf(t: E2E, step: any): { fee: bigint; cap: bigint } {
  const tx = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
  return { fee: BigInt(tx.fee), cap: BigInt(t.config.fees?.maxFee ?? "30000000") };
}

/** The phone's loop as `kp`: build, verify against the pinned allowlist, check the fee against the cap, sign, submit,
 *  wait. Answers each step's settled status and the fee it declared. */
async function runAs(t: E2E, kp: Keypair, token: string, plan: any): Promise<{ status: any; fee: bigint }[]> {
  const outs: { status: any; fee: bigint }[] = [];
  for (let i = 0; i < plan.steps.length; i++) {
    let step = plan.steps[i];
    if (!step.xdr) step = (await api(t, token, "POST", `/plans/${plan.planId}/steps/${step.id}/build`)).steps[i];
    const tx = TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction;
    const allowed = new Set<string>(Object.values(t.config.allowlist as Record<string, string[]>).flat());
    verifyTransaction(tx, step.intent, { user: kp.publicKey(), sponsor: t.config.sponsor, passphrase: t.config.passphrase, allowedContracts: allowed });
    const { fee, cap } = feeOf(t, step);
    if (fee > cap) throw new Error(`${step.label}: the fee ${fee} is over the network's cap ${cap}`);
    tx.sign(kp);
    const sent = await api(t, token, "POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
    let status = sent;
    for (let k = 0; k < 40 && status.status === "pending"; k++) {
      await new Promise((r) => setTimeout(r, 1_500));
      status = await api(t, token, "GET", `/tx/${sent.hash}`);
    }
    if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
    outs.push({ status, fee });
    console.log(`    ✓ ${step.label} ${sent.hash.slice(0, 12)}… fee ${fee} stroops`);
  }
  return outs;
}

/** A new account set up: signed in, activated (Friendbot on testnet). */
async function account(t: E2E, kp: Keypair): Promise<string> {
  const token = await signIn(t, kp);
  const act = await api(t, token, "POST", "/account/activate");
  if (act.planId) await runAs(t, kp, token, act);
  return token;
}

/** Uploads `bytes` as `type` through a ticket; a second upload to the same path is refused; the file is served with
 *  its type to anyone. Answers its public URL. */
async function uploaded(t: E2E, token: string, type: string, bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const ticket = await api(t, token, "POST", "/media/upload-url", { contentType: type, bytes: bytes.length });
  const put = (body: Uint8Array<ArrayBuffer>) => fetch(ticket.uploadUrl, { method: "PUT", headers: { "content-type": type }, body });
  const first = await put(bytes);
  await first.body?.cancel();
  if (!first.ok) throw new Error(`upload of ${type} → ${first.status}`);
  const second = await put(bytes);
  const again = await second.text();
  if (second.ok) throw new Error(`a second upload to ${ticket.path} was taken: ${second.status}`);
  if (ticket.uploadUrl.startsWith(`${t.API}/v1/local-media/`) && (second.status !== 409 || !again.includes("already_uploaded"))) {
    throw new Error(`the local stand-in's second upload: ${second.status} ${again}`);
  }
  const read = await fetch(ticket.publicUrl);
  const got = new Uint8Array(await read.arrayBuffer());
  if (!read.ok || read.headers.get("content-type") !== type || got.length !== bytes.length || got.some((b, i) => b !== bytes[i])) {
    throw new Error(`${ticket.publicUrl} → ${read.status} ${read.headers.get("content-type")}, ${got.length} bytes`);
  }
  return ticket.publicUrl;
}

/** Publishes a Moment from its metadata URI; the plan carries the policy it was built under. Answers its id. */
async function published(t: E2E, uri: string, maxEditions: number, windowSecs: number): Promise<number> {
  const plan = await api(t, t.token, "POST", "/moments/build", { action: "publish", uri, price: PRICE.toString(), quote: "XLM", maxEditions, windowSecs });
  const step = plan.steps.at(-1);
  const d = step.intent?.display ?? {};
  if (step.intent && (!Number.isInteger(d.platformBps) || !Number.isInteger(d.royaltyBps) || typeof d.minPrice !== "string" || BigInt(d.minPrice) > PRICE)) {
    throw new Error(`the publish plan's terms: ${JSON.stringify(d)}`);
  }
  const [out] = (await runAs(t, t.user, t.token, plan)).slice(-1);
  return Number(out.status.returnValue);
}

export default async function moments(t: E2E): Promise<string | null> {
  t.config ??= await api(t, null, "GET", "/config");
  const contract: string | null = t.config.contracts?.moments ?? null;
  if (!contract) {
    console.log("  Moments isn't deployed on this network");
    return null;
  }
  if (!t.token) t.token = await account(t, t.user);
  const me = t.user.publicKey();

  // Media, through the stack's storage.
  const photo = await uploaded(t, t.token, "image/png", PNG);
  const video = await uploaded(t, t.token, "video/mp4", MP4);
  const poster = await uploaded(t, t.token, "image/jpeg", JPEG);
  const local = photo.startsWith(`${t.API}/v1/local-media/lite-media/`);

  // Metadata: a video needs its poster; the JSON always has an image.
  const takenOn = new Date().toISOString().slice(0, 10);
  expectRefusal(await call(t, t.token, "POST", "/moments/metadata", { title: "E2E harbour", mediaUrl: video, mediaType: "video" }), 400, "bad_media", "a video without its poster");
  const photoMeta = await api(t, t.token, "POST", "/moments/metadata", { title: "E2E dusk", description: "End-to-end photo.", mediaUrl: photo, mediaType: "image", place: "Accra", takenOn });
  const videoMeta = await api(t, t.token, "POST", "/moments/metadata", { title: "E2E harbour", mediaUrl: video, mediaType: "video", posterUrl: poster, place: "Accra", takenOn });
  if (photoMeta.posterUrl !== photo || videoMeta.posterUrl !== poster) throw new Error(`posters: ${photoMeta.posterUrl}, ${videoMeta.posterUrl}`);
  const photoJson = await (await fetch(photoMeta.uri)).json();
  const videoJson = await (await fetch(videoMeta.uri)).json();
  const network = (j: any) => j.attributes?.find((a: any) => a.trait_type === "Network")?.value;
  if (photoJson.image !== photo || "animation_url" in photoJson || videoJson.image !== poster || videoJson.animation_url !== video || network(videoJson) !== "Stellar Testnet") {
    throw new Error(`the SEP-50 JSON: ${JSON.stringify({ photoJson, videoJson })}`);
  }

  // Publish both: a capped photo edition and an open video edition.
  const photoId = await published(t, photoMeta.uri, MAX_EDITIONS, 7_200);
  const videoId = await published(t, videoMeta.uri, 0, 3_600);
  await t.indexer();

  // The feed, with no session: both listed, titled, with their posters; nothing untitled, and not the smoke Moment #1.
  const feed = await call(t, null, "GET", "/moments?limit=100");
  if (feed.status !== 200 || feed.cache !== "public, max-age=15" || feed.body.view !== "public") throw new Error(`the public feed: ${feed.status} ${feed.cache}`);
  const row = (id: number) => feed.body.moments.find((x: any) => x.id === id);
  const p = row(photoId);
  const v = row(videoId);
  if (!p || p.title !== "E2E dusk" || p.mediaType !== "image" || p.posterUrl !== photo || p.state !== "collecting" || p.place !== "Accra" || p.takenOn !== takenOn) {
    throw new Error(`the photo Moment on the feed: ${JSON.stringify(p)}`);
  }
  if (!v || v.title !== "E2E harbour" || v.mediaType !== "video" || v.mediaUrl !== video || v.posterUrl !== poster || v.maxEditions !== 0) {
    throw new Error(`the video Moment on the feed: ${JSON.stringify(v)}`);
  }
  if (feed.body.moments.some((x: any) => !x.title || !x.posterUrl)) throw new Error("the feed serves a Moment without a title or an image");
  if (row(1)) throw new Error("the smoke Moment #1 is on the feed");
  if (!(p.platformBps >= 0 && p.royaltyBps >= 0 && p.priceUsd !== undefined)) throw new Error(`the photo Moment's terms: ${JSON.stringify(p)}`);

  // A second account collects 2, then 20 editions of the photo Moment, each within the fee cap.
  const collector = Keypair.random();
  const collectorToken = await account(t, collector);
  const fees: bigint[] = [];
  for (const quantity of [2, 20]) {
    const plan = await api(t, collectorToken, "POST", "/moments/build", { action: "collect", momentId: photoId, quantity });
    const spend = plan.steps[0].intent.spend;
    if (spend[t.config.assets.find((a: any) => a.id === "XLM").contract] !== (PRICE * BigInt(quantity)).toString()) throw new Error(`the collect's spend: ${JSON.stringify(spend)}`);
    const [out] = await runAs(t, collector, collectorToken, plan);
    fees.push(out.fee);
  }
  // Past the cap: refused before signing.
  const soldOut = expectRefusal(await call(t, collectorToken, "POST", "/moments/build", { action: "collect", momentId: photoId, quantity: MAX_EDITIONS - 21 }), 422, "simulation_failed", "a collect past the cap");
  if (soldOut.body.error.detail?.contractCode !== "moment.sold_out") throw new Error(`past the cap: ${JSON.stringify(soldOut.body)}`);
  expectRefusal(await call(t, collectorToken, "POST", "/moments/build", { action: "collect", momentId: 4_000_000, quantity: 1 }), 404, "not_found", "an unknown Moment");
  await t.indexer();

  // The collector's editions, with no session and with one: exactly the ones owner_of names on chain.
  const who = collector.publicKey();
  const owned = await call(t, null, "GET", `/moments/owned?address=${who}`);
  if (owned.status !== 200 || owned.cache !== "public, max-age=15" || owned.body.view !== "public") throw new Error(`the public editions: ${owned.status} ${owned.cache}`);
  const ids = owned.body.editions.filter((e: any) => e.momentId === photoId).map((e: any) => e.tokenId).sort((a: number, b: number) => a - b);
  if (ids.length !== 22 || owned.body.editions.some((e: any) => e.contract !== contract || e.title !== "E2E dusk" || e.posterUrl !== photo)) {
    throw new Error(`the collector's editions: ${JSON.stringify(owned.body.editions).slice(0, 400)}`);
  }
  for (const id of ids) {
    const holder = await view(contract, "owner_of", [sv.u32(id)]);
    if (holder !== who) throw new Error(`edition #${id}: owner_of says ${holder}, not the collector`);
  }
  const ownerView = await api(t, collectorToken, "GET", "/moments/owned");
  if (ownerView.view !== "owner" || JSON.stringify(ownerView.editions) !== JSON.stringify(owned.body.editions)) throw new Error("the owner's editions differ from the public view's");

  // The Moment's page: its counts, the collector's editions; spent only in the owner's view.
  const page = await api(t, collectorToken, "GET", `/moments/${photoId}`);
  if (page.moment.minted !== 22 || page.moment.collects !== 2 || page.moment.collectors !== 1 || page.collectorsSummary.largest?.editions !== 22) {
    throw new Error(`the Moment's page: ${JSON.stringify({ moment: page.moment, summary: page.collectorsSummary })}`);
  }
  if (JSON.stringify(page.you.editions) !== JSON.stringify(ids) || page.you.spent !== (PRICE * 22n).toString()) throw new Error(`you: ${JSON.stringify(page.you)}`);
  const publicPage = await call(t, null, "GET", `/moments/${photoId}?address=${who}`);
  if (publicPage.status !== 200 || publicPage.body.view !== "public" || publicPage.body.you.spent !== null || publicPage.body.you.editions.length !== 22) {
    throw new Error(`the Moment's public page: ${publicPage.status} ${JSON.stringify(publicPage.body?.you)}`);
  }
  const share = PRICE * 22n - (PRICE * 2n * BigInt(page.moment.platformBps)) / 10_000n - (PRICE * 20n * BigInt(page.moment.platformBps)) / 10_000n;
  if (page.creatorEarned !== share.toString()) throw new Error(`creatorEarned ${page.creatorEarned}, not ${share}`);

  // My Moments: a session route that never reaches /:id; the collector's spending and the creator's earnings.
  expectRefusal(await call(t, null, "GET", "/moments/mine"), 401, "unauthorized", "My Moments without a session");
  const theirs = await api(t, collectorToken, "GET", "/moments/mine");
  if (theirs.totals.editions !== 22 || theirs.totals.moments !== 1 || theirs.totals.spentByQuote.XLM !== (PRICE * 22n).toString()) throw new Error(`the collector's totals: ${JSON.stringify(theirs.totals)}`);
  const mine = await api(t, t.token, "GET", "/moments/mine");
  const created = mine.created.map((c: any) => c.id).sort();
  if (JSON.stringify(created) !== JSON.stringify([photoId, videoId].sort()) || mine.totals.earnedByQuote.XLM !== share.toString()) {
    throw new Error(`the creator's My Moments: ${JSON.stringify({ created, totals: mine.totals })}`);
  }
  const [{ n }] = await t.db`select count(*)::int as n from lite.moment_editions where moment_id = ${photoId} and owner = ${who}`;
  if (n !== 22) throw new Error(`moment_editions holds ${n} of the collector's editions`);

  return [
    `media on ${local ? "the local stand-in" : "storage"} (write-once)`,
    `published photo #${photoId} (${MAX_EDITIONS} editions) and video #${videoId} (open, poster set) at ${PRICE / t.ONE} XLM by ${me.slice(0, 6)}…`,
    `collected 2 and 20 (fees ${fees.join(" and ")} stroops, cap ${t.config.fees?.maxFee ?? "30000000"})`,
    "22 editions owned, each owner_of on chain; a collect past the cap refused (moment.sold_out)",
  ].join("; ");
}
