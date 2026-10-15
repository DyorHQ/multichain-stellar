// The local media stand-in (docs/DESIGN-stellar-parity.md §6.9, §6.17, §12.5; docs/API-lite.md §12; WP-16): it answers
// on testnet with LITE_LOCAL_STORAGE_DIR only, and is refused on mainnet; an upload's token is an HMAC of its path, size
// and expiry under LITE_JWT_SECRET, valid 10 minutes; a path takes one file; the content type must be the path's and
// the size at most the ticket's; reads answer the stored bytes and their type, and nothing outside the directory. The
// routes run through the API's own handler, without a session.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, goOffline, JWT_SECRET, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const DIR = await Deno.makeTempDir({ prefix: "lite-media-test-" });
const PUBLIC_BASE = "http://127.0.0.1:21600/lite";
Deno.env.set("LITE_LOCAL_STORAGE_DIR", DIR);
Deno.env.set("LITE_PUBLIC_BASE", PUBLIC_BASE);
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
replaceSql(fakeSql((q) => {
  if (q.startsWith("select lite.reserve_media_upload(")) return [{ ok: true }];
  throw new Error(`unexpected query: ${q}`);
}));
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { env } = await import("../../supabase/functions/_shared/env.ts");
const local = await import("../../supabase/functions/_shared/localmedia.ts");
const media = await import("../../supabase/functions/_shared/media.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

const ME = USER.publicKey();
const NOW = Date.UTC(2026, 9, 14, 14, 0);
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));

/** Runs `fn` with these variables set (undefined: unset), then puts every one back. */
async function withEnv<T>(vars: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const before = Object.fromEntries(Object.keys(vars).map((k) => [k, Deno.env.get(k)]));
  const apply = (vs: Record<string, string | undefined>) => {
    for (const [k, v] of Object.entries(vs)) v === undefined ? Deno.env.delete(k) : Deno.env.set(k, v);
  };
  apply(vars);
  try {
    return await fn();
  } finally {
    apply(before);
  }
}

/** A request to the API, as the phone (or the e2e test) sends it to a URL the API handed out. */
async function send(url: string, init: RequestInit = {}): Promise<{ status: number; type: string | null; cache: string | null; bytes: Uint8Array; error: string | null }> {
  const res = await handle(new Request(url, init));
  const bytes = new Uint8Array(await res.arrayBuffer());
  const type = res.headers.get("content-type");
  const error = type?.startsWith("application/json") && res.status >= 400 ? JSON.parse(new TextDecoder().decode(bytes)).error.code : null;
  return { status: res.status, type, cache: res.headers.get("cache-control"), bytes, error };
}

const put = (url: string, body: Uint8Array<ArrayBuffer>, type = "image/png") => send(url, { method: "PUT", headers: { "content-type": type }, body });

Deno.test("the stand-in: on testnet with LITE_LOCAL_STORAGE_DIR, its base the Debug build's pinned one; refused on mainnet", async () => {
  assert(local.localMediaEnabled());
  assertEquals(media.mediaBase(), `${PUBLIC_BASE}/v1/local-media/lite-media/`);
  const path = `uploads/${ME}/${crypto.randomUUID()}.png`;
  const token = await local.signUploadToken(path, PNG.length);
  for (const vars of [{ LITE_NETWORK: "mainnet" }, { LITE_LOCAL_STORAGE_DIR: undefined }]) {
    await withEnv(vars, async () => {
      assertEquals(local.localMediaEnabled(), false);
      assertEquals((await put(`${PUBLIC_BASE}/v1/local-media/upload/${token}`, PNG)).status, 404);
      assertEquals((await send(`${PUBLIC_BASE}/v1/local-media/lite-media/${path}`)).error, "not_found");
    });
  }
  // Mainnet refuses the settings themselves.
  await withEnv({ LITE_NETWORK: "mainnet" }, () => {
    let refused = false;
    try {
      env.localStorageDir;
    } catch {
      refused = true;
    }
    assert(refused, "LITE_LOCAL_STORAGE_DIR is refused on mainnet");
    return Promise.resolve();
  });
  assertEquals(await Array.fromAsync(Deno.readDir(DIR)), [], "nothing was stored");
});

Deno.test("tokens: an HMAC of path, size and expiry under LITE_JWT_SECRET, valid 10 minutes", async () => {
  const path = `uploads/${ME}/${crypto.randomUUID()}.mp4`;
  const token = await local.signUploadToken(path, 1_000, NOW);
  assertEquals(await local.readUploadToken(token, NOW + 599_000), { path, maxBytes: 1_000, expiresAt: NOW / 1000 + 600 });
  const refused = async (t: string, now = NOW) => {
    const e = await assertRejects(() => local.readUploadToken(t, now), ApiError);
    assertEquals([e.status, e.code], [401, "unauthorized"], t);
  };
  await refused(token, NOW + 600_000);
  const [payload, mac] = token.split(".");
  const other = btoa(JSON.stringify({ p: `uploads/${ME}/${crypto.randomUUID()}.mp4`, n: 1_000, e: NOW / 1000 + 600 })).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
  await refused(`${other}.${mac}`);
  await refused(`${payload}.${mac.slice(0, -2)}AA`);
  await refused(`${payload}.${mac}.x`);
  await refused(payload);
  await refused("not-a-token");
  // Signed under another secret.
  const foreign = await withEnv({ LITE_JWT_SECRET: `${JWT_SECRET}-other` }, () => local.signUploadToken(path, 1_000, NOW));
  await refused(foreign);
  // A path outside lite-media's folders is never granted, however it was signed.
  await refused(await local.signUploadToken("uploads/../../etc/passwd", 1_000, NOW));
  await refused(await local.signUploadToken(`avatars/${ME}/${crypto.randomUUID()}.png`, 1_000, NOW));
});

Deno.test("an upload ticket on the local stack: URLs on LITE_PUBLIC_BASE; the upload lands, is served with its type, and only once", async () => {
  const ticket = await media.signedUpload(ME, "image/png", PNG.length);
  assert(ticket.uploadUrl.startsWith(`${PUBLIC_BASE}/v1/local-media/upload/`), ticket.uploadUrl);
  assertEquals(ticket.publicUrl, `${PUBLIC_BASE}/v1/local-media/lite-media/${ticket.path}`);
  assertEquals((await put(ticket.uploadUrl, PNG)).status, 204);
  const read = await send(ticket.publicUrl);
  assertEquals([read.status, read.type, read.cache], [200, "image/png", "public, max-age=31536000, immutable"]);
  assertEquals(read.bytes, PNG);
  // Write-once: a second PUT to the same path is refused, and the first file stays.
  const again = await put(ticket.uploadUrl, PNG.slice(0, 20));
  assertEquals([again.status, again.error], [409, "already_uploaded"]);
  assertEquals((await send(ticket.publicUrl)).bytes, PNG);
});

Deno.test("an upload must name the path's content type and fit the ticket's size; a refused one leaves nothing behind", async () => {
  const ticket = await media.signedUpload(ME, "image/png", PNG.length);
  for (const type of ["image/jpeg", "application/octet-stream", ""]) {
    const wrong = await put(ticket.uploadUrl, PNG, type);
    assertEquals([wrong.status, wrong.error], [400, "bad_type"], type);
  }
  const big = new Uint8Array(PNG.length + 1);
  assertEquals((await put(ticket.uploadUrl, big)).error, "too_large");
  // Streamed without a length: refused as it passes the size.
  const stream = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(PNG);
      c.enqueue(new Uint8Array(1));
      c.close();
    },
  });
  assertEquals((await send(ticket.uploadUrl, { method: "PUT", headers: { "content-type": "image/png" }, body: stream })).error, "too_large");
  assertEquals((await send(ticket.publicUrl)).error, "not_found");
  assertEquals((await put(ticket.uploadUrl, PNG)).status, 204);
  const dir = `${DIR}/uploads/${ME}`;
  const files = (await Array.fromAsync(Deno.readDir(dir))).map((e) => e.name);
  assert(files.every((f) => !f.endsWith(".part")), `no partial file is left: ${files.join(", ")}`);
});

Deno.test("expired or forged upload links: 401 unauthorized, nothing stored", async () => {
  const path = `uploads/${ME}/${crypto.randomUUID()}.png`;
  const expired = await local.signUploadToken(path, PNG.length, Date.now() - 601_000);
  const r = await put(`${PUBLIC_BASE}/v1/local-media/upload/${expired}`, PNG);
  assertEquals([r.status, r.error], [401, "unauthorized"]);
  const forged = await withEnv({ LITE_JWT_SECRET: `${JWT_SECRET}-other` }, () => local.signUploadToken(path, PNG.length));
  assertEquals((await put(`${PUBLIC_BASE}/v1/local-media/upload/${forged}`, PNG)).error, "unauthorized");
  assertEquals((await send(`${PUBLIC_BASE}/v1/local-media/lite-media/${path}`)).error, "not_found");
});

Deno.test("reads: only lite-media's paths, never outside the directory", async () => {
  await Deno.writeTextFile(`${DIR}/secret.txt`, "outside lite-media's paths");
  for (const p of ["secret.txt", "uploads/../secret.txt", "uploads/%2E%2E/secret.txt", `uploads/${ME}/..%2F..%2Fsecret.txt`, `uploads/${ME}/x.png`]) {
    const r = await send(`${PUBLIC_BASE}/v1/local-media/lite-media/${p}`);
    assertEquals(r.status, 404, p);
    assert(!new TextDecoder().decode(r.bytes).includes("outside lite-media"), p);
  }
});

Deno.test("the API's own metadata JSON on the local stack: written once, served as application/json", async () => {
  const path = `moments/${ME}/${crypto.randomUUID()}.json`;
  const url = await media.putPublicObject(path, JSON.stringify({ name: "Accra" }), "application/json");
  assertEquals(url, `${PUBLIC_BASE}/v1/local-media/lite-media/${path}`);
  const read = await send(url);
  assertEquals([read.status, read.type, JSON.parse(new TextDecoder().decode(read.bytes))], [200, "application/json", { name: "Accra" }]);
  const e = await assertRejects(() => media.putPublicObject(path, "{}", "application/json"), ApiError);
  assertEquals([e.status, e.code], [409, "already_uploaded"]);
});

Deno.test("cleanup: the test's media directory", async () => {
  await Deno.remove(DIR, { recursive: true });
});
