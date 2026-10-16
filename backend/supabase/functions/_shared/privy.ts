// Privy, for the Stellar wallets of the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey
// (DyorHQ/internal ios-app/stellar-v2/privy-stellar-wallets.md §5.1). Privy holds those wallets' keys; this API never
// decides what they sign.
//
//   * privyUserId(token) checks a token Privy issued to the user (ES256, issuer privy.io, audience the app id) against
//     the Privy app's public verification key, and answers the user's id. The key is cached for an hour and re-read
//     early, at most every 5 minutes, when a token's signature fails against it (Privy may have rotated it).
//   * stellarWallets / createStellarWallet / rawSign are Privy's REST API with the app secret. rawSign relays a request
//     the phone already authorized: the phone signed the exact request (wallet, hash, expiry) with the user's own Privy
//     key, and the signature goes to Privy as it came, so nothing here can change what Privy signs.
//
// Every call has a timeout. An outage, a rate limit or a timeout is PrivyUnavailable ("try again"); any other refusal is
// PrivyRefused with Privy's status. Neither carries Privy's answer text.
import { StrKey } from "@stellar/stellar-sdk";
import { env } from "./env.ts";

const AUTH = "https://auth.privy.io/api/v1";
const API = "https://api.privy.io/v1";
export const PRIVY_TIMEOUT_MS = 8_000;
const KEY_TTL_MS = 60 * 60_000;
const KEY_RETRY_MS = 5 * 60_000;
/** Tolerated clock difference with Privy, in seconds. */
const SKEW_S = 60;

export class PrivyUnavailable extends Error {}
export class PrivyRefused extends Error {
  constructor(public status: number, what: string) {
    super(`${what} ${status}`);
  }
}
/** A token that isn't one Privy issued for this app, or that has expired. */
export class PrivyTokenInvalid extends Error {}

export interface PrivyWallet {
  id: string;
  address: string;
}

const enc = new TextEncoder();
const USER_ID = /^did:privy:[A-Za-z0-9]{1,64}$/;
const WALLET_ID = /^[A-Za-z0-9_-]{1,64}$/;

function b64urlDecode(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new PrivyTokenInvalid("not base64url");
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad), (c) => c.charCodeAt(0));
}

async function privyFetch(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(PRIVY_TIMEOUT_MS) });
  } catch {
    throw new PrivyUnavailable("privy did not answer");
  }
}

function refusal(status: number, what: string): Error {
  return status === 429 || status >= 500 ? new PrivyUnavailable(`${what} ${status}`) : new PrivyRefused(status, what);
}

// ---------------------------------------------------------------------------------------------- tokens

let verificationKey: CryptoKey | null = null;
let keyFetchedAt = 0, keyTriedAt = 0;

/** Tests only: forget the cached key. */
export function resetPrivyKey(): void {
  verificationKey = null;
  keyFetchedAt = 0;
  keyTriedAt = 0;
}

/** The Privy app's ES256 verification key (public, from Privy's app config), re-read once older than `maxAgeMs` and
 *  never tried more than once per KEY_RETRY_MS. A failed re-read keeps the key held; with none yet, PrivyUnavailable. */
async function appKey(maxAgeMs: number): Promise<CryptoKey> {
  const now = Date.now();
  if (verificationKey && (now - keyFetchedAt < maxAgeMs || now - keyTriedAt < KEY_RETRY_MS)) return verificationKey;
  keyTriedAt = now;
  try {
    const res = await privyFetch(`${AUTH}/apps/${env.privyAppId}`, { headers: { "privy-app-id": env.privyAppId } });
    if (!res.ok) throw new PrivyUnavailable(`privy app config ${res.status}`);
    const pem = String((await res.json()).verification_key ?? "");
    const der = pem.replace(/-----(BEGIN|END) PUBLIC KEY-----/g, "").replace(/\s+/g, "");
    verificationKey = await crypto.subtle.importKey("spki", Uint8Array.from(atob(der), (c) => c.charCodeAt(0)),
      { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    keyFetchedAt = now;
  } catch {
    if (!verificationKey) throw new PrivyUnavailable("privy app key unavailable");
  }
  return verificationKey;
}

/** The claims of `token` when its ES256 signature verifies against `key`; null when it doesn't. */
async function verifiedClaims(token: string, key: CryptoKey): Promise<Record<string, unknown> | null> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new PrivyTokenInvalid("not a JWT");
  let header: Record<string, unknown>;
  let claims: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch {
    throw new PrivyTokenInvalid("unreadable JWT");
  }
  if (header?.alg !== "ES256" || !claims || typeof claims !== "object") throw new PrivyTokenInvalid("not ES256");
  const signature = b64urlDecode(parts[2]);
  if (signature.length !== 64) throw new PrivyTokenInvalid("bad signature length");
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature as BufferSource,
    enc.encode(`${parts[0]}.${parts[1]}`));
  return ok ? claims : null;
}

/** The Privy user id (`did:privy:…`) of a token Privy issued for DyorHQ's app (an identity or an access token): its
 *  signature, issuer, audience and times are checked. PrivyTokenInvalid for anything else; PrivyUnavailable when the
 *  app's key can't be read. A signature that fails against the cached key is tried once more against a re-read key
 *  (rate-limited, so bad tokens can't hammer Privy). */
export async function privyUserId(token: string, nowMs = Date.now()): Promise<string> {
  if (token.length > 16_384) throw new PrivyTokenInvalid("too long");
  const claims = (await verifiedClaims(token, await appKey(KEY_TTL_MS))) ??
    (await verifiedClaims(token, await appKey(KEY_RETRY_MS)));
  if (!claims) throw new PrivyTokenInvalid("signature");
  const nowS = nowMs / 1000;
  const aud = claims.aud;
  const audiences = Array.isArray(aud) ? aud : [aud];
  if (claims.iss !== "privy.io" || !audiences.includes(env.privyAppId)) throw new PrivyTokenInvalid("issuer or audience");
  if (typeof claims.exp !== "number" || claims.exp + SKEW_S < nowS) throw new PrivyTokenInvalid("expired");
  if (typeof claims.iat === "number" && claims.iat > nowS + SKEW_S) throw new PrivyTokenInvalid("issued in the future");
  if (typeof claims.sub !== "string" || !USER_ID.test(claims.sub)) throw new PrivyTokenInvalid("subject");
  return claims.sub;
}

// ---------------------------------------------------------------------------------------------- REST, app secret

function appHeaders(): Record<string, string> {
  return { Authorization: "Basic " + btoa(`${env.privyAppId}:${env.privyAppSecret}`), "privy-app-id": env.privyAppId };
}

async function answer(res: Response, what: string): Promise<Record<string, unknown>> {
  if (!res.ok) {
    await res.body?.cancel();
    throw refusal(res.status, what);
  }
  try {
    const body = await res.json();
    if (body && typeof body === "object") return body as Record<string, unknown>;
  } catch { /* below */ }
  throw new PrivyUnavailable(`${what}: unreadable reply`);
}

/** A Stellar wallet as Privy describes one; null for anything else (another chain, a bad id or address). */
function stellarWallet(w: unknown): (PrivyWallet & { createdAt: number }) | null {
  if (!w || typeof w !== "object") return null;
  const { id, address, chain_type, created_at } = w as Record<string, unknown>;
  if (chain_type !== "stellar" || typeof id !== "string" || !WALLET_ID.test(id)) return null;
  if (typeof address !== "string" || !StrKey.isValidEd25519PublicKey(address)) return null;
  return { id, address, createdAt: typeof created_at === "number" ? created_at : 0 };
}

/** The user's Stellar wallets at Privy, oldest first. */
export async function stellarWallets(userId: string): Promise<PrivyWallet[]> {
  const q = new URLSearchParams({ user_id: userId, chain_type: "stellar" });
  const body = await answer(await privyFetch(`${API}/wallets?${q}`, { headers: appHeaders() }), "privy wallets");
  const data = Array.isArray(body.data) ? body.data : [];
  return data.map(stellarWallet).filter((w): w is PrivyWallet & { createdAt: number } => w !== null)
    .sort((a, b) => a.createdAt - b.createdAt).map(({ id, address }) => ({ id, address }));
}

/** The idempotency key of a user's wallet creation: two creations for one user within Privy's 24 hours make one. */
export async function creationKey(userId: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", enc.encode(`dyorhq-stellar:${userId}`)));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** A new Stellar wallet owned by the user (only the user's key can authorize its signatures). */
export async function createStellarWallet(userId: string): Promise<PrivyWallet> {
  const res = await privyFetch(`${API}/wallets`, {
    method: "POST",
    headers: { ...appHeaders(), "content-type": "application/json", "privy-idempotency-key": await creationKey(userId) },
    body: JSON.stringify({ chain_type: "stellar", owner: { user_id: userId } }),
  });
  const wallet = stellarWallet(await answer(res, "privy create wallet"));
  if (!wallet) throw new PrivyUnavailable("privy create wallet: not a Stellar wallet");
  return { id: wallet.id, address: wallet.address };
}

/** Privy's Ed25519 signature (64 bytes) of `hash` (0x and 64 hex) by `walletId`, for the request the phone authorized:
 *  its authorization signature and expiry (ms) are sent exactly as the phone made them, with the same body. */
export async function rawSign(walletId: string, hash: string, expiresAt: number, authorization: string): Promise<Uint8Array> {
  const res = await privyFetch(`${API}/wallets/${walletId}/raw_sign`, {
    method: "POST",
    headers: {
      ...appHeaders(),
      "content-type": "application/json",
      "privy-authorization-signature": authorization,
      "privy-request-expiry": String(expiresAt),
    },
    body: JSON.stringify({ params: { hash } }),
  });
  const body = await answer(res, "privy raw_sign");
  const data = body.data as Record<string, unknown> | undefined;
  const sig = typeof data?.signature === "string" ? data.signature.replace(/^0x/, "") : "";
  if (!/^[0-9a-fA-F]{128}$/.test(sig)) throw new PrivyUnavailable("privy raw_sign: not an Ed25519 signature");
  return Uint8Array.from(sig.match(/../g)!.map((h) => parseInt(h, 16)));
}
