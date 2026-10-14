// Privy, as email-pepper, email-rebind and delete-account use it (security audit 2026-09-26, RO-9: every call has a
// timeout, and an outage, a rate limit or a timeout is reported as retryable — never as a bad token or a missing
// email).
//
//   * privyTokenClaims(token) verifies an access token against the Privy app's public ES256 key (issuer privy.io,
//     audience = the app id). The key is cached for an hour and re-read early — at most every 5 minutes — when a
//     token's signature fails against it, in case Privy rotated it. Throws PrivyUnavailable when no key can be had,
//     anything else for a token that does not verify.
//   * privyUser / privyUserByEmail read a user with the app secret (null when Privy has no such user);
//     deletePrivyUser deletes one. They throw PrivyUnavailable for timeouts, 429 and 5xx, PrivyRefused for any other
//     refusal.
import { importSPKI, jwtVerify } from "npm:jose@5";

export const APP_ID = Deno.env.get("PRIVY_APP_ID") ?? "cmttp2squ00lk0djrso3z0yvm";
const PRIVY = "https://auth.privy.io/api/v1";
const PRIVY_API = "https://api.privy.io/v1";
export const PRIVY_TIMEOUT_MS = 8_000;
const KEY_TTL_MS = 60 * 60_000; // the Privy app key is re-read hourly…
const KEY_RETRY_MS = 5 * 60_000; // …or on a signature failure, but never more often than this

// Privy could not answer (timeout, 429, 5xx, unreadable reply): the caller should say "try again".
export class PrivyUnavailable extends Error {}
// Privy answered with a refusal that retrying will not fix (e.g. 400, 401, 403).
export class PrivyRefused extends Error {}

export type PrivyLinkedAccount = { type?: unknown; address?: unknown; [key: string]: unknown };
export type PrivyUserRecord = { id?: unknown; linked_accounts?: unknown; [key: string]: unknown };

function adminHeaders(secret: string): Record<string, string> {
  return { Authorization: "Basic " + btoa(`${APP_ID}:${secret}`), "privy-app-id": APP_ID };
}

async function privyFetch(url: string, init: RequestInit): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(PRIVY_TIMEOUT_MS) });
  } catch {
    throw new PrivyUnavailable("privy did not answer");
  }
}

function refusal(status: number, what: string): Error {
  return status === 429 || status >= 500 ? new PrivyUnavailable(`${what} ${status}`) : new PrivyRefused(`${what} ${status}`);
}

let verificationKey: CryptoKey | null = null;
let keyFetchedAt = 0, keyTriedAt = 0;
// The Privy app's ES256 verification key — re-read once it is older than maxAgeMs, and never tried more than once per
// KEY_RETRY_MS. A failed re-read keeps the key we have; with none yet, it throws PrivyUnavailable.
async function appVerificationKey(maxAgeMs: number): Promise<CryptoKey> {
  const now = Date.now();
  if (verificationKey && (now - keyFetchedAt < maxAgeMs || now - keyTriedAt < KEY_RETRY_MS)) return verificationKey;
  keyTriedAt = now;
  try {
    const res = await privyFetch(`${PRIVY}/apps/${APP_ID}`, { headers: { "privy-app-id": APP_ID } });
    if (!res.ok) throw new PrivyUnavailable(`privy app config ${res.status}`);
    const app = await res.json();
    verificationKey = await importSPKI(String(app.verification_key), "ES256");
    keyFetchedAt = now;
  } catch {
    if (!verificationKey) throw new PrivyUnavailable("privy app key unavailable");
  }
  return verificationKey;
}

// The Privy user id a valid access token names, and when the token was issued (unix seconds, if it says). A signature
// that fails against the cached key gets one more try against a re-read key; the re-read is rate-limited, so bad
// tokens can't hammer Privy with it.
export async function privyTokenClaims(token: string): Promise<{ userId: string; issuedAt?: number }> {
  const verify = async (maxAgeMs: number) => {
    const key = await appVerificationKey(maxAgeMs);
    const { payload } = await jwtVerify(token, key, { issuer: "privy.io", audience: APP_ID });
    if (!payload.sub) throw new Error("no subject");
    return { userId: payload.sub, issuedAt: typeof payload.iat === "number" ? payload.iat : undefined };
  };
  try {
    return await verify(KEY_TTL_MS);
  } catch (err) {
    if ((err as { code?: unknown })?.code !== "ERR_JWS_SIGNATURE_VERIFICATION_FAILED") throw err;
    return await verify(KEY_RETRY_MS);
  }
}

// True when a token was issued at most maxAgeS seconds ago (and not more than a minute in the future, for clock skew).
// A token without an iat is never fresh.
export function tokenIsFresh(issuedAt: number | undefined, nowMs: number, maxAgeS: number): boolean {
  if (typeof issuedAt !== "number" || !Number.isFinite(issuedAt)) return false;
  const nowS = nowMs / 1000;
  return issuedAt <= nowS + 60 && nowS - issuedAt <= maxAgeS;
}

async function userFrom(res: Response, what: string): Promise<PrivyUserRecord | null> {
  if (res.status === 404) return null;
  if (!res.ok) throw refusal(res.status, what);
  try {
    const user = await res.json();
    return user && typeof user === "object" ? user as PrivyUserRecord : null;
  } catch {
    throw new PrivyUnavailable(`${what}: unreadable reply`);
  }
}

// The user record Privy holds for this id, read with the app secret; null when Privy has no such user.
export async function privyUser(userId: string, secret: string): Promise<PrivyUserRecord | null> {
  const res = await privyFetch(`${PRIVY}/users/${encodeURIComponent(userId)}`, { headers: adminHeaders(secret) });
  return await userFrom(res, "privy user");
}

// The user Privy has for this email address (Privy's "get user by email"); null when there is none.
export async function privyUserByEmail(email: string, secret: string): Promise<PrivyUserRecord | null> {
  const res = await privyFetch(`${PRIVY_API}/users/email/address`, {
    method: "POST",
    headers: { ...adminHeaders(secret), "Content-Type": "application/json" },
    body: JSON.stringify({ address: email }),
  });
  return await userFrom(res, "privy user by email");
}

// Deletes a Privy user (and with it any embedded wallet). "gone" when Privy had no such user.
export async function deletePrivyUser(userId: string, secret: string): Promise<"deleted" | "gone"> {
  const res = await privyFetch(`${PRIVY}/users/${encodeURIComponent(userId)}`, { method: "DELETE", headers: adminHeaders(secret) });
  await res.body?.cancel();
  if (res.status === 404) return "gone";
  if (!res.ok) throw refusal(res.status, "privy delete");
  return "deleted";
}

function linkedAccounts(user: PrivyUserRecord | null): PrivyLinkedAccount[] {
  const accounts = user?.linked_accounts;
  return Array.isArray(accounts) ? accounts.filter((a): a is PrivyLinkedAccount => !!a && typeof a === "object") : [];
}

// The email address of the user's linked email account, exactly as Privy stores it (Privy verified it with a one-time
// code when it was linked); null when there is none.
export function linkedEmail(user: PrivyUserRecord | null): string | null {
  const address = linkedAccounts(user).find((a) => a.type === "email")?.address;
  return typeof address === "string" ? address : null;
}

// True when deleting this Privy user can lose nothing but the one email login: its only linked account is that email
// (no wallet, no other login method). Anything else — an embedded or external wallet, Apple/Google sign-in merged in
// by email, a passkey, a phone — means the Privy user is also another way into DyorHQ, so it must be kept.
export function onlyLinkedToEmail(user: PrivyUserRecord | null, email: string): boolean {
  const accounts = linkedAccounts(user);
  return accounts.length === 1 && accounts[0].type === "email" && typeof accounts[0].address === "string" &&
    accounts[0].address.trim().toLowerCase() === email.trim().toLowerCase();
}
