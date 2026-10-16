// Sign-in for Lite: the phone signs a single-use challenge with its Stellar key (SEP-53 message signing), the API
// checks the signature and the tester allowlist, then issues a short-lived HS256 access JWT and a refresh token that
// renews it without asking the user again (docs/DESIGN-stellar-parity.md §5.9, §6.18). No password, no key ever leaves
// the phone. Where invites are required (mainnet), a first sign-in binds the address to a single-use invite code; on
// testnet it registers the address as a tester, still revocable.
import { Keypair, StrKey } from "@stellar/stellar-sdk";
import type postgres from "postgres";
import type { AuthResult } from "./contract.ts";
import { sql, tableExists } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, forbidden, unauthorized } from "./http.ts";

const enc = new TextEncoder();
const NONCE_TTL_MS = 5 * 60_000;
export const SEP53_PREFIX = "Stellar Signed Message:\n";
/** A refresh token: "lrt_" and 32 random bytes in base64url. */
const REFRESH_TOKEN = /^lrt_[A-Za-z0-9_-]{43}$/;

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? enc.encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
}

export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function assertAccountId(address: unknown): string {
  if (typeof address !== "string" || !StrKey.isValidEd25519PublicKey(address)) {
    throw bad("bad_address", "That isn't a Stellar account address (G…).");
  }
  return address;
}

/** The exact text the phone signs. Names the product, network, address and nonce so a signature can't be reused
 *  anywhere else. */
export function challengeMessage(network: string, address: string, nonce: string, issuedAt: string): string {
  return `DyorHQ Lite sign-in\nNetwork: ${network}\nAddress: ${address}\nNonce: ${nonce}\nIssued: ${issuedAt}`;
}

/** SEP-53: ed25519 over sha256("Stellar Signed Message:\n" + message). */
export async function verifySep53(address: string, message: string, signatureB64: string): Promise<boolean> {
  let sig: Uint8Array;
  try {
    sig = Uint8Array.from(atob(signatureB64), (c) => c.charCodeAt(0));
  } catch {
    return false;
  }
  if (sig.length !== 64) return false;
  const digest = await sha256(SEP53_PREFIX + message);
  return Keypair.fromPublicKey(address).verify(digest as any, sig as any);
}

export async function createChallenge(address: string): Promise<{ nonce: string; message: string; expiresAt: string }> {
  assertAccountId(address);
  const nonce = b64url(crypto.getRandomValues(new Uint8Array(24)));
  const issuedAt = new Date().toISOString();
  const message = challengeMessage(env.network.name, address, nonce, issuedAt);
  const expiresAt = new Date(Date.now() + NONCE_TTL_MS);
  await sql()`insert into lite.auth_nonces (nonce, address, message, expires_at) values (${nonce}, ${address}, ${message}, ${expiresAt})`;
  return { nonce, message, expiresAt: expiresAt.toISOString() };
}

export interface VerifyInput {
  address: string;
  nonce: string;
  signature: string;
  inviteCode?: string;
}

/** A sign-in: an access token, and a refresh token that starts a new family. Before migration 12 has created
 *  lite.auth_refresh (hosted applies migrations by hand), the answer has no refresh token, as before. */
export async function verifyChallenge(input: VerifyInput): Promise<AuthResult> {
  const address = assertAccountId(input.address);
  if (typeof input.nonce !== "string" || typeof input.signature !== "string") throw bad("bad_arg", "nonce and signature are required.");
  // Consume the nonce first: whatever happens next, it can't be tried again.
  const rows = await sql()`
    update lite.auth_nonces set used_at = now()
     where nonce = ${input.nonce} and address = ${address} and used_at is null and expires_at > now()
    returning message`;
  if (rows.length === 0) throw unauthorized("That sign-in expired or was already used. Try again.");
  if (!(await verifySep53(address, rows[0].message as string, input.signature))) throw unauthorized("The signature doesn't match this address.");

  const tester = await ensureTester(address, input.inviteCode);
  const access = await accessToken(address);
  if (!(await tableExists("lite.auth_refresh"))) return { ...access, tester };
  const refresh = await newRefreshToken();
  await sql()`
    insert into lite.auth_refresh (family, address, token_hash, expires_at)
    values (${crypto.randomUUID()}, ${address}, ${refresh.hash}, ${refresh.expiresAt})`;
  return { ...access, tester, refreshToken: refresh.token, refreshExpiresAt: refresh.expiresAt.toISOString() };
}

async function ensureTester(address: string, inviteCode: unknown): Promise<{ address: string; label: string | null }> {
  const existing = await sql()`select address, label, revoked_at from lite.testers where address = ${address}`;
  if (existing.length > 0) {
    if (existing[0].revoked_at) throw forbidden("access_revoked", "Access to Stellar was turned off for this account.");
    return { address, label: (existing[0].label as string) ?? null };
  }
  if (!inviteCode) {
    if (env.inviteRequired) throw forbidden("not_invited", "DyorHQ on Stellar is invite-only while we test it. Enter your invite code.");
    // No invite gate (testnet): the first sign-in registers the address, which can be revoked like any tester.
    await sql()`insert into lite.testers (address) values (${address}) on conflict (address) do nothing`;
    return { address, label: null };
  }
  // A code that is given is checked and used, invite gate or not.
  if (typeof inviteCode !== "string") throw forbidden("bad_invite", "That code isn't valid, has expired or was already used.");
  const codeHash = hex(await sha256(inviteCode.trim().toUpperCase()));
  return await sql().begin(async (tx) => {
    const inv = await tx`
      update lite.invites set uses = uses + 1
       where code_hash = ${codeHash} and uses < max_uses and expires_at > now()
      returning id, label`;
    if (inv.length === 0) throw forbidden("bad_invite", "That code isn't valid, has expired or was already used.");
    await tx`insert into lite.testers (address, invite_id, label) values (${address}, ${inv[0].id}, ${inv[0].label})`;
    return { address, label: inv[0].label as string };
  });
}

// ------------------------------------------------------------------------------------------------ refresh tokens

export interface RefreshInput {
  address: string;
  refreshToken: string;
}

const refreshInvalid = () => new ApiError(401, "refresh_invalid", "This session can't be renewed. Sign in again.");

/** A new refresh token, what is stored of it (its SHA-256, hex) and when it expires. */
async function newRefreshToken(): Promise<{ token: string; hash: string; expiresAt: Date }> {
  const token = `lrt_${b64url(crypto.getRandomValues(new Uint8Array(32)))}`;
  return { token, hash: hex(await sha256(token)), expiresAt: new Date(Date.now() + env.refreshTtlS * 1000) };
}

/** The stored form of a presented refresh token, or null when it can't be one. */
async function refreshHash(token: unknown): Promise<string | null> {
  return typeof token === "string" && REFRESH_TOKEN.test(token) ? hex(await sha256(token)) : null;
}

function revokeFamily(q: postgres.Sql, family: string) {
  return q`update lite.auth_refresh set revoked_at = now() where family = ${family} and revoked_at is null`;
}

/** auth/refresh (§6.18): spends a refresh token and answers as a sign-in does, with its successor in the same family.
 *  A token spent before revokes its family (401 refresh_reused: a copy is in use elsewhere); one unknown, expired or
 *  revoked is refused (401 refresh_invalid); a tester who was turned off gets 403 access_revoked, and the family goes. */
export async function refreshSession(input: RefreshInput): Promise<AuthResult> {
  const address = assertAccountId(input.address);
  const hash = await refreshHash(input.refreshToken);
  // Before migration 12 no sign-in handed out a refresh token, so none can be valid.
  if (!hash || !(await tableExists("lite.auth_refresh"))) throw refreshInvalid();
  const next = await newRefreshToken();
  // One transaction spends, checks and replaces the token. A refusal returns rather than throws, so that a family it
  // revokes stays revoked.
  const outcome = await sql().begin(async (tx) => {
    const spent = await tx`
      update lite.auth_refresh set used_at = now()
       where token_hash = ${hash} and address = ${address} and used_at is null and revoked_at is null and expires_at > now()
      returning id, family`;
    if (spent.length === 0) {
      const seen = await tx`select family, used_at from lite.auth_refresh where token_hash = ${hash} and address = ${address}`;
      if (seen.length === 0 || !seen[0].used_at) return "invalid";
      await revokeFamily(tx, seen[0].family as string);
      return "reused";
    }
    const family = spent[0].family as string;
    const tester = await tx`select label from lite.testers where address = ${address} and revoked_at is null`;
    if (tester.length === 0) {
      await revokeFamily(tx, family);
      return "revoked";
    }
    const [successor] = await tx`
      insert into lite.auth_refresh (family, address, token_hash, expires_at)
      values (${family}, ${address}, ${next.hash}, ${next.expiresAt})
      returning id`;
    await tx`update lite.auth_refresh set replaced_by = ${successor.id} where id = ${spent[0].id}`;
    return { label: (tester[0].label as string) ?? null };
  });
  if (outcome === "invalid") throw refreshInvalid();
  if (outcome === "reused") throw new ApiError(401, "refresh_reused", "This session was already renewed, so it was ended. Sign in again.");
  if (outcome === "revoked") throw forbidden("access_revoked", "Access to Stellar was turned off for this account.");
  await dropExpired();
  return {
    ...(await accessToken(address)),
    tester: { address, label: outcome.label },
    refreshToken: next.token,
    refreshExpiresAt: next.expiresAt.toISOString(),
  };
}

/** auth/signout: revokes the family of `refreshToken`. A token that is unknown, malformed or revoked already changes
 *  nothing, and the caller can't tell; nor can it before migration 12, when no family exists. */
export async function revokeSession(refreshToken: unknown): Promise<void> {
  const hash = await refreshHash(refreshToken);
  if (!hash || !(await tableExists("lite.auth_refresh"))) return;
  await sql()`
    update lite.auth_refresh set revoked_at = now()
     where family = (select family from lite.auth_refresh where token_hash = ${hash}) and revoked_at is null`;
}

/** Opportunistic cleanup after a refresh: at most 500 refresh tokens that expired more than a week ago. The week keeps
 *  a late reuse of a spent token recognisable. */
async function dropExpired(): Promise<void> {
  try {
    await sql()`
      delete from lite.auth_refresh
       where id in (select id from lite.auth_refresh where expires_at < now() - interval '7 days' limit 500)`;
  } catch (err) {
    console.warn("auth_refresh: cleanup failed", String((err as Error).message ?? err).slice(0, 120));
  }
}

// ------------------------------------------------------------------------------------------------ JWT (HS256)

let hmacKey: CryptoKey | null = null;

async function key(): Promise<CryptoKey> {
  if (!hmacKey) {
    const secret = env.jwtSecret;
    if (secret.length < 32) throw new Error("LITE_JWT_SECRET must be at least 32 characters");
    hmacKey = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
  }
  return hmacKey;
}

export async function signJwt(claims: Record<string, unknown>): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = b64url(enc.encode(JSON.stringify(claims)));
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await key(), enc.encode(`${header}.${body}`)));
  return `${header}.${body}.${b64url(sig)}`;
}

/** An access token for `address`, valid for env.jwtTtlS (an hour). */
async function accessToken(address: string): Promise<{ token: string; expiresAt: string }> {
  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + env.jwtTtlS;
  const token = await signJwt({ sub: address, net: env.network.name, aud: "dyorhq-lite", iss: "dyorhq-lite", exp, iat });
  return { token, expiresAt: new Date(exp * 1000).toISOString() };
}

export async function verifyJwt(token: string): Promise<Record<string, unknown>> {
  const parts = token.split(".");
  if (parts.length !== 3) throw unauthorized();
  const ok = await crypto.subtle.verify("HMAC", await key(), b64urlDecode(parts[2]) as any, enc.encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw unauthorized();
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
  if (header.alg !== "HS256") throw unauthorized();
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  if (typeof claims.exp !== "number" || claims.exp * 1000 < Date.now()) throw unauthorized("Your session expired. Sign in again.");
  if (claims.aud !== "dyorhq-lite" || claims.net !== env.network.name) throw unauthorized();
  return claims;
}

/** The signed-in, still-allowlisted address behind a request. */
export async function requireUser(req: Request): Promise<string> {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer (.+)$/);
  if (!m) throw unauthorized("Sign in on Stellar to continue.");
  const claims = await verifyJwt(m[1]);
  const address = assertAccountId(claims.sub);
  // Revocation takes effect at once, not at token expiry.
  const rows = await sql()`select 1 from lite.testers where address = ${address} and revoked_at is null`;
  if (rows.length === 0) {
    // A token for an address this database holds no tester for was issued against another one that shares the signing
    // secret (a local stack, or this database before a reset): it signs in again here, which registers it where sign-in
    // may. Only a tester whose access was turned off is refused for good.
    const known = await sql()`select 1 from lite.testers where address = ${address}`;
    if (known.length === 0) throw unauthorized("Sign in on Stellar to continue.");
    throw new ApiError(403, "access_revoked", "Access to Stellar was turned off for this account.");
  }
  return address;
}
