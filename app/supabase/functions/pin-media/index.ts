// pin-media: pins an already-uploaded Moment media object from the public launch-media bucket to IPFS via Pinata, so
// the NFT's on-chain mediaURI can be a permanent ipfs:// CID instead of a Supabase URL. The Pinata JWT lives only in
// this function's environment (Supabase secret PINATA_JWT). Only a signed-in wallet may pin: the session is verified
// here (../_shared/wallet_session.ts: signature, expiry, aud and role authenticated, a wallet_address), not only by the
// gateway's verify_jwt (pinned in supabase/config.toml), so the publishable, anon or service-role key, or a forged
// token, can never drain the Pinata quota even if a deploy drops verify_jwt (security audit 2026-09-26, SB-9).
//
// A wallet-auth session costs nothing but a fresh key, so each pin also passes edge_rate_gate (migration 27; SB-2):
// 20 per wallet per 15 minutes and 100 per day (a creator's video Moment takes two pins), 60 per client network per
// 15 minutes, and 1,000 per day overall — a circuit breaker on the Pinata account. The app writes the https mirror
// on-chain when a pin fails, so the per-wallet budget is kept well above what one creator's session needs.
//
// Deploy:  supabase functions deploy pin-media   (verify_jwt = true, supabase/config.toml)
//          Only after migration 27 is applied: without edge_rate_gate every pin fails closed (503), and the app then
//          writes the https mirror on-chain instead of ipfs://. Needs APP_JWT_SECRET (set for wallet-auth; secrets are
//          project-wide) to verify HS256 sessions.
//
// Time budget (RW-9): the app gives this call 25 s and then writes the https mirror on-chain instead, so the whole
// call — reading the object, pinning, checking the gateway — fits in BUDGET_MS. A pin that cannot be confirmed in time
// is answered as a failure and unpinned (unless Pinata says the account already held that CID, which may be on-chain
// already), so the app's fallback and Pinata never disagree and failed pins do not accumulate.
//
// CRITICAL — return a FILE cid, never a DIRECTORY. Pinata's pinFileToIPFS treats a "/" in `pinataMetadata.name` (and
// in the multipart filename) as a FOLDER PATH: it builds those directories around the file and returns the ROOT
// directory's CID. That is exactly what broke Moment #3 "0N1 Force NFT" — the old code named the pin
// `dyorhq/<wallet>/<file>`, so the on-chain image was a directory listing (HTML), which OpenSea and the app cannot
// render, and the on-chain URI is immutable. Verified directly against the API (2026-09-22): a slash-free metadata
// name + a bare basename + wrapWithDirectory:false returns the bare file CID with MimeType image/jpeg; a name with a
// slash returns a directory CID even with wrapWithDirectory:false. Belt and braces, the returned CID is then checked
// to actually serve file bytes on the account's dedicated gateway before it is handed to the app; a CID that only
// resolves as a directory is pointed at the file inside it, and one that resolves as neither is refused (502) so the
// app falls back to the working https URL rather than writing a broken URI on-chain.
//
// Errors carry no upstream detail (SB-11); Pinata's status and a short excerpt go to the function logs only.
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { rateGate } from "../_shared/rate.ts";
import { sessionKeys, SessionKeysUnavailable, sessionWallet } from "../_shared/wallet_session.ts";
import { Deadline, pinataResult, pinTarget } from "./pin.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "https://fmnjqrguvopusfufmirs.supabase.co";
const PINATA = "https://api.pinata.cloud/pinning/pinFileToIPFS";
const PINATA_UNPIN = "https://api.pinata.cloud/pinning/unpin/";
// The account's dedicated gateway (restricted to this account's pins) serves a fresh pin within a second; the public
// gateway is the fallback when the dedicated one is unavailable. PINATA_GATEWAY overrides the dedicated hostname.
const DEDICATED_GATEWAY = Deno.env.get("PINATA_GATEWAY") ?? "scarlet-secure-kangaroo-820.mypinata.cloud";
const PUBLIC_GATEWAY = "gateway.pinata.cloud";
// Under the app's 25 s wait, leaving room for a cold start and the network.
const BUDGET_MS = 20_000;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

// Resolved once per isolate, so the project's JWKS is fetched once and cached.
const keys = sessionKeys(Deno.env);

// True if the URL serves actual file bytes (not a UnixFS directory index, which gateways render as HTML) within
// timeoutMs.
async function servesFile(url: string, timeoutMs: number): Promise<boolean> {
  try {
    const r = await fetch(url, { method: "GET", headers: { Range: "bytes=0-0" }, signal: AbortSignal.timeout(timeoutMs) });
    const ct = (r.headers.get("content-type") || "").toLowerCase();
    await r.body?.cancel();
    if (!r.ok && r.status !== 206) return false;
    return !ct.includes("text/html") && !ct.includes("application/x-directory");
  } catch { return false; }
}

// The first of `paths` (relative to a CID) that serves file bytes on the dedicated gateway, else on the public one —
// as long as the budget lasts (each check gets at most 8 s of it).
async function resolvableFilePath(cid: string, paths: string[], deadline: Deadline): Promise<string | null> {
  for (const host of [DEDICATED_GATEWAY, PUBLIC_GATEWAY]) {
    for (const p of paths) {
      const timeout = deadline.step(8_000);
      if (timeout < 500) return null;
      if (await servesFile(`https://${host}/ipfs/${cid}${p}`, timeout)) return p;
    }
  }
  return null;
}

// Best effort, after the answer has gone: a pin the app will not use is removed so it does not count against the
// account. Never for a CID the account already held before this call (it may be on-chain).
function unpinLater(cid: string, jwt: string) {
  const unpin = fetch(PINATA_UNPIN + encodeURIComponent(cid), {
    method: "DELETE", headers: { Authorization: `Bearer ${jwt}` }, signal: AbortSignal.timeout(10_000),
  }).then(async (r) => {
    await r.body?.cancel();
    if (!r.ok) console.error("pin-media: unpin failed", r.status);
  }).catch(() => console.error("pin-media: unpin did not answer"));
  if (typeof EdgeRuntime !== "undefined") EdgeRuntime.waitUntil(unpin);
}

Deno.serve(async (req) => {
  const deadline = new Deadline(BUDGET_MS);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let wallet: string | null;
  try {
    wallet = await sessionWallet(req.headers.get("authorization"), keys);
  } catch (err) {
    if (!(err instanceof SessionKeysUnavailable)) throw err;
    console.error("pin-media:", err.message); // logs only (SB-11)
    return json({ error: "pinning is not available right now" }, 503);
  }
  if (!wallet) return json({ error: "a signed-in wallet session is required" }, 403);

  const jwt = Deno.env.get("PINATA_JWT");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!jwt || !serviceKey) {
    console.error("pin-media: PINATA_JWT / SUPABASE_SERVICE_ROLE_KEY missing"); // logs only (SB-11)
    return json({ error: "pinning is not available right now" }, 503);
  }

  let payload: { bucket?: unknown; path?: unknown };
  try { payload = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  if (!payload || typeof payload !== "object") return json({ error: "invalid json" }, 400);
  // No other bucket, no other names — so a session can never pin another wallet's objects, point the fetch below at
  // any other URL on this host, or use the Pinata account to pin arbitrary uploads.
  const target = pinTarget(payload.bucket, payload.path, wallet);
  if ("error" in target) return json({ error: target.error }, target.status);
  const bucket = "launch-media";
  const { path, name } = target;

  const db = createClient(SUPABASE_URL, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const refused = await rateGate(db, "pin-media", wallet, clientNet(req), cors);
  if (refused) return refused;

  // Pull the bytes from the public bucket (the app already uploaded them there).
  const src = `${SUPABASE_URL}/storage/v1/object/public/${bucket}/${path}`;
  if (!new URL(src).pathname.startsWith(`/storage/v1/object/public/${bucket}/${wallet}/`)) return json({ error: "invalid path" }, 400);
  let obj: Response;
  try { obj = await fetch(src, { signal: AbortSignal.timeout(deadline.step(15_000)) }); } catch { return json({ error: "could not read the object" }, 502); }
  if (!obj.ok) { await obj.body?.cancel(); return json({ error: "object not found" }, 404); }
  let buffer: ArrayBuffer;
  try { buffer = await obj.arrayBuffer(); } catch { return json({ error: "could not read the object" }, 502); }
  const bytes = new Uint8Array(buffer);
  const contentType = obj.headers.get("content-type") ?? "application/octet-stream";

  // Bare basename with NO slash, used for both the multipart filename and the pin's metadata name — a "/" in either
  // makes Pinata build wrapper directories and return the directory's CID instead of the file's.
  const form = new FormData();
  form.append("file", new Blob([bytes], { type: contentType }), name);
  form.append("pinataOptions", JSON.stringify({ cidVersion: 1, wrapWithDirectory: false }));
  // The bucket path goes in keyvalues (free-form tags), never in `name`.
  form.append("pinataMetadata", JSON.stringify({ name, keyvalues: { app: "dyorhq", bucket, path } }));

  const pinTimeout = deadline.step(Number.POSITIVE_INFINITY);
  if (pinTimeout < 1_000) return json({ error: "pinning took too long — try again" }, 504);
  let res: Response;
  let text: string;
  try {
    res = await fetch(PINATA, { method: "POST", headers: { Authorization: `Bearer ${jwt}` }, body: form, signal: AbortSignal.timeout(pinTimeout) });
    text = await res.text();
  } catch {
    console.error("pin-media: pinata did not answer in time");
    return json({ error: "pinning is not available right now" }, 502);
  }
  if (!res.ok) {
    console.error("pin-media: pinata responded", res.status, text.slice(0, 200));
    return json({ error: "pinning failed" }, 502);
  }
  const pinned = pinataResult(text);
  if (!pinned) {
    console.error("pin-media: pinata returned no CID");
    return json({ error: "pinning failed" }, 502);
  }

  // Guarantee the on-chain URI resolves to the media itself. Pinata reports MimeType "directory" when it wrapped the
  // file; either way the gateway is the arbiter.
  const filePath = await resolvableFilePath(pinned.cid, pinned.mime === "directory" ? [`/${name}`, ""] : ["", `/${name}`], deadline);
  if (filePath === null) {
    // Nothing resolvable in time — refuse, so the app writes the (working) https URL on-chain instead of a broken URI.
    if (!pinned.duplicate) unpinLater(pinned.cid, jwt);
    return json({ error: "pinned content did not resolve to a file in time" }, 502);
  }
  const uri = `ipfs://${pinned.cid}${filePath}`;
  return json({ cid: pinned.cid, uri, contentType, wrapped: filePath !== "" });
});
