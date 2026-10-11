// Sign-in for Lite: the phone signs a single-use challenge with its Stellar key (SEP-53 message signing), the API
// checks the signature and the tester allowlist, then issues a short-lived HS256 JWT. No password, no key ever leaves
// the phone. A first sign-in binds the address to a single-use invite code.
import { Keypair, StrKey } from "@stellar/stellar-sdk";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, forbidden, unauthorized } from "./http.ts";

const enc = new TextEncoder();
const NONCE_TTL_MS = 5 * 60_000;
const JWT_TTL_S = 12 * 3600;
export const SEP53_PREFIX = "Stellar Signed Message:\n";

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

export async function verifyChallenge(input: VerifyInput): Promise<{ token: string; expiresAt: string; tester: { address: string; label: string | null } }> {
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
  const exp = Math.floor(Date.now() / 1000) + JWT_TTL_S;
  const token = await signJwt({ sub: address, net: env.network.name, aud: "dyorhq-lite", iss: "dyorhq-lite", exp, iat: Math.floor(Date.now() / 1000) });
  return { token, expiresAt: new Date(exp * 1000).toISOString(), tester };
}

async function ensureTester(address: string, inviteCode?: string): Promise<{ address: string; label: string | null }> {
  const existing = await sql()`select address, label, revoked_at from lite.testers where address = ${address}`;
  if (existing.length > 0) {
    if (existing[0].revoked_at) throw forbidden("access_revoked", "Access to DyorHQ Lite was turned off for this account.");
    return { address, label: (existing[0].label as string) ?? null };
  }
  if (!inviteCode) throw forbidden("not_invited", "DyorHQ Lite is invite-only during testing. Enter your invite code.");
  const codeHash = hex(await sha256(inviteCode.trim().toUpperCase()));
  return await sql().begin(async (tx) => {
    const inv = await tx`
      update lite.invites set uses = uses + 1
       where code_hash = ${codeHash} and uses < max_uses and expires_at > now()
      returning id, label`;
    if (inv.length === 0) throw forbidden("bad_invite", "That invite code isn't valid or was already used.");
    await tx`insert into lite.testers (address, invite_id, label) values (${address}, ${inv[0].id}, ${inv[0].label})`;
    return { address, label: inv[0].label as string };
  });
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
  if (!m) throw unauthorized("Sign in to DyorHQ Lite to continue.");
  const claims = await verifyJwt(m[1]);
  const address = assertAccountId(claims.sub);
  // Revocation takes effect at once, not at token expiry.
  const rows = await sql()`select 1 from lite.testers where address = ${address} and revoked_at is null`;
  if (rows.length === 0) throw new ApiError(403, "access_revoked", "Access to DyorHQ Lite was turned off for this account.");
  return address;
}
