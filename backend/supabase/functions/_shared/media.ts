// Media for launches and Moments (docs/DESIGN-stellar-parity.md §6.9): the phone uploads each file straight to storage
// with a one-time signed URL, and the API writes the metadata JSON itself. The bucket `lite-media` is public-read and
// write-once (migration 09's trigger), and is written only these two ways:
//   uploads/<address>/<uuid>.<ext>          a photo, a video or a video's poster, uploaded by the phone;
//   launches|moments/<address>/<uuid>.json  metadata, written by the API.
// Storage is Supabase Storage, or on a local testnet stack the API's own stand-in (localmedia.ts). An upload ticket is
// counted against the user's daily budget before its URL is issued: 50 uploads and 200 MB (lite.media_uploads).
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad } from "./http.ts";
import { localMediaBase, localMediaEnabled, localUploadUrl, signUploadToken, writeLocal } from "./localmedia.ts";

/** What an upload may be, by its real content type: the file's extension and whether it is a photo or a video. */
export const UPLOAD_TYPES: Record<string, { ext: string; kind: "image" | "video" }> = {
  "image/jpeg": { ext: "jpg", kind: "image" },
  "image/png": { ext: "png", kind: "image" },
  "image/webp": { ext: "webp", kind: "image" },
  "image/gif": { ext: "gif", kind: "image" },
  "video/mp4": { ext: "mp4", kind: "video" },
  "video/quicktime": { ext: "mov", kind: "video" },
};

/** A user's upload tickets per UTC day, and the bytes they may declare in all. */
export const UPLOADS_PER_DAY = 50;
export const UPLOAD_BYTES_PER_DAY = 200 * 1024 * 1024;

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const EXTENSIONS: Record<"image" | "video", string[]> = {
  image: Object.values(UPLOAD_TYPES).filter((t) => t.kind === "image").map((t) => t.ext),
  video: Object.values(UPLOAD_TYPES).filter((t) => t.kind === "video").map((t) => t.ext),
};

function supabase(): { url: string; key: string } | null {
  return env.supabaseUrl && env.serviceRoleKey ? { url: env.supabaseUrl, key: env.serviceRoleKey } : null;
}

function storage(): { url: string; key: string } {
  const s = supabase();
  if (!s) throw new ApiError(503, "storage_unavailable", "Uploads aren't available right now.");
  return s;
}

/** Where lite-media's files are read, as `<base><path>`: the local stand-in's base on a local stack, else Supabase
 *  Storage's public bucket. Null where neither is configured (unit tests, scripts). */
export function mediaBase(): string | null {
  if (localMediaEnabled()) return localMediaBase();
  return env.supabaseUrl ? `${env.supabaseUrl}/storage/v1/object/public/${env.mediaBucket}/` : null;
}

export function publicUrl(path: string): string {
  return `${mediaBase() ?? `/storage/v1/object/public/${env.mediaBucket}/`}${path}`;
}

/** `url` as one of `user`'s uploads of `kind` on our storage (`<base>uploads/<user>/<uuid>.<ext>`), or null. */
export function ownUpload(url: unknown, user: string, kind: "image" | "video"): string | null {
  const base = mediaBase();
  if (typeof url !== "string" || !base || !url.startsWith(base)) return null;
  const path = url.slice(base.length);
  return new RegExp(`^uploads/${user}/${UUID}\\.(${EXTENSIONS[kind].join("|")})$`).test(path) ? url : null;
}

/** An upload of `kind` on our storage by anyone (`<base>uploads/G…/<uuid>.<ext>`), or null: what the indexer accepts
 *  from metadata it reads. */
export function anyUpload(url: unknown, kind: "image" | "video"): string | null {
  const base = mediaBase();
  if (typeof url !== "string" || !base || !url.startsWith(base)) return null;
  const path = url.slice(base.length);
  return new RegExp(`^uploads/G[A-Z2-7]{55}/${UUID}\\.(${EXTENSIONS[kind].join("|")})$`).test(path) ? url : null;
}

/** POST /v1/media/upload-url: a one-time URL for one upload to `uploads/<user>/<uuid>.<ext>`, after the type, the size
 *  (at most limits.uploadBytes) and the user's daily budget are checked (429 upload_budget). */
export async function signedUpload(user: string, contentType: string, bytes: number): Promise<{ uploadUrl: string; publicUrl: string; path: string }> {
  const t = UPLOAD_TYPES[contentType];
  if (!t) throw bad("bad_type", "Use a JPEG, PNG, WebP or GIF image, or an MP4/MOV video.");
  const max = env.network.limits.uploadBytes;
  if (!Number.isSafeInteger(bytes) || bytes <= 0 || bytes > max) throw bad("too_large", `That file is too large (max ${max / 1024 / 1024} MB).`);
  const local = localMediaEnabled();
  const s = local ? null : storage();
  const path = `uploads/${user}/${crypto.randomUUID()}.${t.ext}`;
  const [{ ok }] = await sql()`
    select lite.reserve_media_upload(${user}, ${path}, ${contentType}, ${bytes}, ${UPLOADS_PER_DAY}, ${UPLOAD_BYTES_PER_DAY}) as ok`;
  if (!ok) throw new ApiError(429, "upload_budget", "You've uploaded a lot today. Try again tomorrow.");
  if (local) return { uploadUrl: localUploadUrl(await signUploadToken(path, bytes)), publicUrl: publicUrl(path), path };
  const res = await fetch(`${s!.url}/storage/v1/object/upload/sign/${env.mediaBucket}/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${s!.key}`, apikey: s!.key, "content-type": "application/json" },
    body: JSON.stringify({}),
  }).catch(() => null);
  if (!res?.ok) {
    await res?.body?.cancel();
    // No URL was issued: the ticket doesn't count.
    await sql()`delete from lite.media_uploads where path = ${path}`;
    throw new ApiError(502, "storage_error", "Couldn't prepare the upload. Try again.");
  }
  const body = await res.json();
  return { uploadUrl: `${s!.url}/storage/v1${body.url}`, publicUrl: publicUrl(path), path };
}

/** Writes an object the API makes (a metadata JSON) once, and answers its public URL. */
export async function putPublicObject(path: string, content: string, contentType: string): Promise<string> {
  if (localMediaEnabled()) {
    await writeLocal(path, new TextEncoder().encode(content));
    return publicUrl(path);
  }
  const s = storage();
  const res = await fetch(`${s.url}/storage/v1/object/${env.mediaBucket}/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${s.key}`, apikey: s.key, "content-type": contentType, "x-upsert": "false" },
    body: content,
  }).catch(() => null);
  if (!res?.ok) {
    await res?.body?.cancel();
    throw new ApiError(502, "storage_error", "Couldn't save the metadata. Try again.");
  }
  await res.body?.cancel();
  return publicUrl(path);
}
