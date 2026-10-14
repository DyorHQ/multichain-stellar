// The wallet a DyorHQ session (minted by wallet-auth) names, verified in code (security audit 2026-09-26, SB-9; review
// of the fixes, 2026-09-27). pin-media and aurora-proxy run with verify_jwt = true (supabase/config.toml), but that is
// a deploy setting, not code: a deploy from the dashboard, through the MCP tool or with --no-verify-jwt drops it
// silently, and a function that only decoded the token would then take any forged role:authenticated claim. So each
// function verifies the session the way PostgREST does:
//   * HS256 against the project's legacy JWT secret, APP_JWT_SECRET (what wallet-auth signs with by default);
//   * ES256 / RS256 against the project's signing keys, published at <SUPABASE_URL>/auth/v1/.well-known/jwks.json
//     (public, no API key needed; cached, and re-read when a token names a key it has not seen, e.g. the key the owner
//     imports for APP_JWT_SIGNING_JWK, OH-7);
// and requires aud "authenticated", role "authenticated", an exp in the future and a 0x wallet_address. Anything else —
// the publishable, anon or service-role key, a token from another project, a forged or expired one — is not a session.
// Without APP_JWT_SECRET no HS256 token is one: that is the state once the owner has moved sessions to an ES256 key and
// unset the secret (supabase/README.md, "Session signing key").
import { createRemoteJWKSet, decodeProtectedHeader, jwtVerify, type JWTPayload, type JWTVerifyGetKey } from "npm:jose@5";

export type SessionKeys = { secret: Uint8Array | null; jwks: JWTVerifyGetKey | null };

// The keys a token needs could not be had (the JWKS did not answer or did not parse, or SUPABASE_URL is not set): the
// caller answers 503 and logs it, never "not signed in".
export class SessionKeysUnavailable extends Error {}

// jose's codes for a token that does not verify. Any other failure (the JWKS fetch timing out or failing) means the
// keys were unavailable.
const INVALID = new Set([
  "ERR_JWS_INVALID", "ERR_JWT_INVALID", "ERR_JWS_SIGNATURE_VERIFICATION_FAILED", "ERR_JWT_EXPIRED",
  "ERR_JWT_CLAIM_VALIDATION_FAILED", "ERR_JOSE_ALG_NOT_ALLOWED", "ERR_JOSE_NOT_SUPPORTED", "ERR_JWKS_NO_MATCHING_KEY",
  "ERR_JWKS_MULTIPLE_MATCHING_KEYS",
]);

// The session's wallet (lowercase 0x address), or null when `authorization` carries no valid wallet session.
// Throws SessionKeysUnavailable when the keys needed to decide are missing.
export async function sessionWallet(authorization: string | null, keys: SessionKeys): Promise<string | null> {
  const token = (authorization ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  let alg: unknown;
  try { alg = decodeProtectedHeader(token).alg; } catch { return null; }
  let payload: JWTPayload;
  try {
    if (alg === "HS256") {
      if (!keys.secret) return null;
      ({ payload } = await jwtVerify(token, keys.secret, { algorithms: ["HS256"], audience: "authenticated", requiredClaims: ["exp"] }));
    } else if (alg === "ES256" || alg === "RS256") {
      if (!keys.jwks) throw new SessionKeysUnavailable("SUPABASE_URL is not set");
      ({ payload } = await jwtVerify(token, keys.jwks, { algorithms: ["ES256", "RS256"], audience: "authenticated", requiredClaims: ["exp"] }));
    } else {
      return null;
    }
  } catch (err) {
    if (err instanceof SessionKeysUnavailable) throw err;
    const code = (err as { code?: unknown } | null)?.code;
    if (typeof code === "string" && INVALID.has(code)) return null;
    throw new SessionKeysUnavailable("the session signing keys could not be read");
  }
  if (payload.role !== "authenticated") return null;
  const wallet = typeof payload.wallet_address === "string" ? payload.wallet_address.toLowerCase() : "";
  return /^0x[0-9a-f]{40}$/.test(wallet) ? wallet : null;
}

// The keys from the function's environment: APP_JWT_SECRET (a project-wide secret, set for wallet-auth) and the
// project's JWKS under SUPABASE_URL (injected by the platform). Build once per isolate so the JWKS cache is shared.
export function sessionKeys(env: { get(name: string): string | undefined }): SessionKeys {
  const secret = env.get("APP_JWT_SECRET");
  const url = env.get("SUPABASE_URL");
  return {
    secret: secret ? new TextEncoder().encode(secret) : null,
    jwks: url
      ? createRemoteJWKSet(new URL("/auth/v1/.well-known/jwks.json", url), {
        timeoutDuration: 5_000, cooldownDuration: 30_000, cacheMaxAge: 10 * 60_000,
      })
      : null,
  };
}
