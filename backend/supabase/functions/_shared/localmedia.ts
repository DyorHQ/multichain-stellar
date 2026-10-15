// The local stack's stand-in for Supabase Storage (docs/DESIGN-stellar-parity.md §6.9, §6.17; docs/API-lite.md §12).
// A local stack has no Storage, so the API keeps lite-media's files itself, in LITE_LOCAL_STORAGE_DIR, and serves them
// under LITE_PUBLIC_BASE: the Debug build's pinned media base is http://127.0.0.1:8000/lite/v1/local-media/lite-media/.
// It answers on testnet only (env.ts refuses both settings anywhere else), and only with LITE_LOCAL_STORAGE_DIR set.
//
// - An upload ticket's URL carries its own token: the object's path, the most bytes it may hold and its expiry (10
//   minutes), signed with HMAC-SHA256 under LITE_JWT_SECRET. No session is needed to use it, as with a signed Storage URL.
// - Write-once, as the hosted bucket is (migration 09's trigger): a path takes one file. It is written aside, then
//   linked into place, which fails when something is already there, so two uploads can't both land.
// - A read answers the stored bytes with the content type of their extension, which is the one the upload had to name.
import { env } from "./env.ts";
import { ApiError, bad, unauthorized } from "./http.ts";

/** How long an upload ticket's token is valid. */
export const UPLOAD_TOKEN_TTL_S = 600;

/** The content type each stored file has, by its extension: what an upload must declare, and what a read answers. */
export const CONTENT_TYPES: Record<string, string> = {
  jpg: "image/jpeg",
  png: "image/png",
  webp: "image/webp",
  gif: "image/gif",
  mp4: "video/mp4",
  mov: "video/quicktime",
  json: "application/json",
};

/** What lite-media holds: the phone's uploads, and the metadata JSON the API writes for launches and Moments. */
export const MEDIA_PATH =
  /^(uploads\/G[A-Z2-7]{55}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|gif|mp4|mov)|(launches|moments)\/G[A-Z2-7]{55}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json)$/;

/** Whether the stand-in answers: testnet, with LITE_LOCAL_STORAGE_DIR and LITE_PUBLIC_BASE set. */
export function localMediaEnabled(): boolean {
  return env.network.name === "testnet" && Boolean(env.localStorageDir) && Boolean(env.publicBase);
}

function publicBase(): string {
  return (env.publicBase ?? "").replace(/\/+$/, "");
}

/** The stand-in's media base: where its files are read, as `<base><path>`. */
export function localMediaBase(): string {
  return `${publicBase()}/v1/local-media/lite-media/`;
}

/** An upload ticket's URL. */
export function localUploadUrl(token: string): string {
  return `${publicBase()}/v1/local-media/upload/${token}`;
}

function disabled(): ApiError {
  return new ApiError(404, "not_found", "Local media isn't available here.");
}

function contentTypeOf(path: string): string {
  return CONTENT_TYPES[path.slice(path.lastIndexOf(".") + 1)];
}

// ------------------------------------------------------------------------------------------------ tokens

const encoder = new TextEncoder();
/** Kept apart from every other use of the secret (the session JWTs sign `<header>.<payload>`). */
const TOKEN_CONTEXT = "lite-media-upload:";

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function fromBase64url(text: string): Uint8Array<ArrayBuffer> | null {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  try {
    const bin = atob(text.replaceAll("-", "+").replaceAll("_", "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

async function hmacKey(): Promise<CryptoKey> {
  return await crypto.subtle.importKey("raw", encoder.encode(env.jwtSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

/** What an upload token allows: one file at `path`, of at most `maxBytes`, until `expiresAt` (seconds). */
export interface UploadGrant {
  path: string;
  maxBytes: number;
  expiresAt: number;
}

/** The token for an upload of at most `maxBytes` to `path`, valid 10 minutes from `now`. */
export async function signUploadToken(path: string, maxBytes: number, now: number = Date.now()): Promise<string> {
  const grant = { p: path, n: maxBytes, e: Math.floor(now / 1000) + UPLOAD_TOKEN_TTL_S };
  const payload = base64url(encoder.encode(JSON.stringify(grant)));
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", await hmacKey(), encoder.encode(TOKEN_CONTEXT + payload)));
  return `${payload}.${base64url(mac)}`;
}

/** The grant a token carries; 401 when it isn't one this server signed, or has expired. */
export async function readUploadToken(token: string, now: number = Date.now()): Promise<UploadGrant> {
  const refused = unauthorized("This upload link isn't valid or has expired. Ask for a new one.");
  const [payload, mac, ...rest] = token.split(".");
  const sig = mac === undefined ? null : fromBase64url(mac);
  if (rest.length > 0 || !payload || !sig) throw refused;
  if (!(await crypto.subtle.verify("HMAC", await hmacKey(), sig, encoder.encode(TOKEN_CONTEXT + payload)))) throw refused;
  let grant: { p?: unknown; n?: unknown; e?: unknown };
  try {
    grant = JSON.parse(new TextDecoder().decode(fromBase64url(payload) ?? new Uint8Array()));
  } catch {
    throw refused;
  }
  const { p, n, e } = grant;
  if (typeof p !== "string" || !MEDIA_PATH.test(p) || !Number.isSafeInteger(n) || !Number.isSafeInteger(e)) throw refused;
  if ((e as number) * 1000 <= now) throw refused;
  return { path: p, maxBytes: n as number, expiresAt: e as number };
}

// ------------------------------------------------------------------------------------------------ files

function fileOf(path: string): string {
  if (!MEDIA_PATH.test(path)) throw new ApiError(404, "not_found", "Nothing is stored there.");
  return `${env.localStorageDir!.replace(/\/+$/, "")}/${path}`;
}

/** Stores `body` at `path` once: 409 already_uploaded when the path holds a file; 400 too_large past `maxBytes`. The
 *  bytes are written to a file of their own, then linked into place, so a failed or refused upload leaves nothing. */
async function storeOnce(path: string, body: ReadableStream<Uint8Array> | Uint8Array | null, maxBytes: number): Promise<void> {
  const file = fileOf(path);
  const dir = file.slice(0, file.lastIndexOf("/"));
  await Deno.mkdir(dir, { recursive: true });
  const taken = () => new ApiError(409, "already_uploaded", "Something is already stored there. Ask for a new upload link.");
  if (await Deno.lstat(file).then(() => true, () => false)) throw taken();
  const part = `${file}.${crypto.randomUUID()}.part`;
  const out = await Deno.open(part, { createNew: true, write: true });
  let written = 0;
  try {
    const tooLarge = () => bad("too_large", `That file is too large (max ${maxBytes} bytes for this upload).`);
    if (body instanceof Uint8Array) {
      if (body.length > maxBytes) throw tooLarge();
      written = body.length;
      await writeAll(out, body);
    } else if (body) {
      for await (const chunk of body) {
        written += chunk.length;
        if (written > maxBytes) throw tooLarge();
        await writeAll(out, chunk);
      }
    }
    if (written === 0) throw bad("bad_arg", "The upload has no bytes.");
  } catch (err) {
    out.close();
    await Deno.remove(part).catch(() => {});
    throw err;
  }
  out.close();
  try {
    await Deno.link(part, file);
  } catch (err) {
    if (err instanceof Deno.errors.AlreadyExists) throw taken();
    throw err;
  } finally {
    await Deno.remove(part).catch(() => {});
  }
}

async function writeAll(f: Deno.FsFile, bytes: Uint8Array): Promise<void> {
  let off = 0;
  while (off < bytes.length) off += await f.write(bytes.subarray(off));
}

/** PUT /v1/local-media/upload/:token: the file's bytes, with the content type of the token's path. */
export async function receiveUpload(token: string, req: Request, now: number = Date.now()): Promise<void> {
  if (!localMediaEnabled()) throw disabled();
  const grant = await readUploadToken(token, now);
  const want = contentTypeOf(grant.path);
  const got = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (got !== want) throw bad("bad_type", `This upload is ${want}, not ${got || "untyped"}.`);
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > grant.maxBytes) {
    await req.body?.cancel();
    throw bad("too_large", `That file is too large (max ${grant.maxBytes} bytes for this upload).`);
  }
  await storeOnce(grant.path, req.body, grant.maxBytes);
}

/** The API's own write of a metadata JSON (or any object it makes), write-once like an upload. */
export async function writeLocal(path: string, bytes: Uint8Array): Promise<void> {
  if (!localMediaEnabled()) throw disabled();
  await storeOnce(path, bytes, env.network.limits.uploadBytes);
}

/** GET /v1/local-media/lite-media/<path>: the stored bytes and their content type; 404 when nothing is there. */
export async function readLocal(path: string): Promise<{ bytes: Uint8Array<ArrayBuffer>; contentType: string }> {
  if (!localMediaEnabled()) throw disabled();
  const file = fileOf(path);
  try {
    return { bytes: await Deno.readFile(file), contentType: contentTypeOf(path) };
  } catch (err) {
    if (err instanceof Deno.errors.NotFound) throw new ApiError(404, "not_found", "Nothing is stored there.");
    throw err;
  }
}
