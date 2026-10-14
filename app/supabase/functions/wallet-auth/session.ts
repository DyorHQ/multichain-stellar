// The Supabase session wallet-auth mints: role authenticated, the wallet_address claim every RLS policy keys off, and
// a stable per-wallet sub, valid for SESSION_S (12 hours) unless WALLET_AUTH_SESSION_S sets a shorter lifetime.
// A session cannot be revoked before it expires (security audit 2026-09-26, SB-10): a shorter lifetime narrows that
// window, but the app does not sign in again on its own when a session ends (it shows the backend features as signed
// out until the next sign-in), so shortening it is an owner decision to take together with an app change.
//
// Two signing keys (security audit 2026-09-26, OH-7):
//   * APP_JWT_SIGNING_JWK — a dedicated asymmetric key: a private P-256 JWK with a kid (`supabase gen signing-key
//     --algorithm ES256`), imported into the project's JWT signing keys so PostgREST, Storage and the Edge Functions
//     gateway accept what it signs. Sessions are ES256 with that kid in the header. When it is set it is used, and if
//     it is malformed the function refuses to mint rather than fall back.
//   * APP_JWT_SECRET — the project's legacy JWT secret (HS256), used when no JWK is configured (the default until the
//     owner switches; see supabase/README.md).
import { importJWK, type KeyLike, SignJWT } from "npm:jose@5";
import { v5 as uuidv5 } from "npm:uuid@9";

const NAMESPACE = "6f9b1c2e-1c2a-4b6e-9c3d-0a1b2c3d4e5f"; // stable namespace for wallet->uuid mapping
export const SESSION_S = 12 * 60 * 60;
export const MIN_SESSION_S = 15 * 60;

// The session lifetime WALLET_AUTH_SESSION_S configures: whole seconds from 15 minutes to 12 hours (clamped); SESSION_S
// when unset or not a whole number.
export function sessionLifetime(configured: string | undefined): number {
  const raw = (configured ?? "").trim();
  const n = Number(raw);
  if (raw === "" || !Number.isInteger(n)) return SESSION_S;
  return Math.min(SESSION_S, Math.max(MIN_SESSION_S, n));
}

export type SessionSigner =
  | { alg: "ES256"; kid: string; key: KeyLike | Uint8Array }
  | { alg: "HS256"; key: Uint8Array };

// The signer the configuration names, or null when neither key is configured. Throws when APP_JWT_SIGNING_JWK is set
// but is not a private P-256 JWK with a kid (the message names the variable, never its value).
export async function sessionSigner(config: { jwk?: string; secret?: string }): Promise<SessionSigner | null> {
  if (config.jwk) {
    let jwk: Record<string, unknown>;
    try { jwk = JSON.parse(config.jwk); } catch { throw new Error("APP_JWT_SIGNING_JWK is not JSON"); }
    const { kty, crv, x, y, d, kid } = jwk ?? {};
    if (kty !== "EC" || crv !== "P-256" || typeof x !== "string" || typeof y !== "string" || typeof d !== "string" ||
        typeof kid !== "string" || !/^[A-Za-z0-9._-]{1,128}$/.test(kid)) {
      throw new Error("APP_JWT_SIGNING_JWK must be a private P-256 JWK with a kid");
    }
    // Only the key material: key_ops, use and ext from a generator must not narrow what WebCrypto may do with it.
    const key = await importJWK({ kty, crv, x, y, d }, "ES256");
    return { alg: "ES256", kid, key };
  }
  if (config.secret) return { alg: "HS256", key: new TextEncoder().encode(config.secret) };
  return null;
}

// A session for `wallet` (lowercase 0x address) issued at `nowS` (unix seconds), valid for `lifetimeS`.
export async function mintSession(wallet: string, signer: SessionSigner, nowS: number, lifetimeS = SESSION_S): Promise<string> {
  const header = signer.alg === "ES256"
    ? { alg: "ES256", kid: signer.kid, typ: "JWT" }
    : { alg: "HS256", typ: "JWT" };
  return await new SignJWT({ role: "authenticated", wallet_address: wallet })
    .setProtectedHeader(header)
    .setSubject(uuidv5(wallet, NAMESPACE))
    .setAudience("authenticated")
    .setIssuedAt(nowS)
    .setExpirationTime(nowS + lifetimeS)
    .sign(signer.key);
}
