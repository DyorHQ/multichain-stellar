// Media for launches and Moments: the phone uploads straight to Supabase Storage with a one-time signed URL; the
// API writes metadata JSON itself. Bucket `lite-media` is public-read, written only through these two paths.
import { env } from "./env.ts";
import { ApiError, bad } from "./http.ts";

const TYPES: Record<string, { ext: string; max: number }> = {
  "image/jpeg": { ext: "jpg", max: 5 * 1024 * 1024 },
  "image/png": { ext: "png", max: 5 * 1024 * 1024 },
  "image/webp": { ext: "webp", max: 5 * 1024 * 1024 },
  "image/gif": { ext: "gif", max: 5 * 1024 * 1024 },
  "video/mp4": { ext: "mp4", max: 25 * 1024 * 1024 },
  "video/quicktime": { ext: "mov", max: 25 * 1024 * 1024 },
};

function storage(): { url: string; key: string } {
  if (!env.supabaseUrl || !env.serviceRoleKey) throw new ApiError(503, "storage_unavailable", "Uploads aren't available right now.");
  return { url: env.supabaseUrl, key: env.serviceRoleKey };
}

export function publicUrl(path: string): string {
  return `${env.supabaseUrl}/storage/v1/object/public/${env.mediaBucket}/${path}`;
}

export async function signedUpload(user: string, contentType: string, bytes: number): Promise<{ uploadUrl: string; publicUrl: string; path: string }> {
  const t = TYPES[contentType];
  if (!t) throw bad("bad_type", "Use a JPEG, PNG, WebP or GIF image, or an MP4/MOV video.");
  if (!Number.isInteger(bytes) || bytes <= 0 || bytes > t.max) throw bad("too_large", `That file is too large (max ${t.max / 1024 / 1024} MB).`);
  const path = `uploads/${user}/${crypto.randomUUID()}.${t.ext}`;
  const s = storage();
  const res = await fetch(`${s.url}/storage/v1/object/upload/sign/${env.mediaBucket}/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${s.key}`, apikey: s.key, "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  if (!res.ok) throw new ApiError(502, "storage_error", "Couldn't prepare the upload. Try again.");
  const body = await res.json();
  return { uploadUrl: `${s.url}/storage/v1${body.url}`, publicUrl: publicUrl(path), path };
}

export async function putPublicObject(path: string, content: string, contentType: string): Promise<string> {
  const s = storage();
  const res = await fetch(`${s.url}/storage/v1/object/${env.mediaBucket}/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${s.key}`, apikey: s.key, "content-type": contentType, "x-upsert": "false" },
    body: content,
  });
  if (!res.ok) throw new ApiError(502, "storage_error", "Couldn't save the metadata. Try again.");
  return publicUrl(path);
}
