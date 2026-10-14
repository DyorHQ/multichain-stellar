// email-pepper: the server half of the v2 email+password wallet, which makes it impossible to guess passwords offline.
//
// The app derives S = PBKDF2(password, email) as before, then sends only two hashes here:
//   e = SHA256("dyorhq/email-pepper/v1/email:" + normalized email)
//   t = SHA256("dyorhq/email-pepper/v1/t:" || S)
// and receives p = HMAC-SHA256(K, "dyorhq/email-pepper/v1" || 0x00 || e || t). The wallet key is HKDF(S || p), so a
// password guess can only be tested by asking this endpoint — which is rate limited. K is 32 random bytes generated
// inside Postgres and kept in Supabase Vault ('email_pepper_key'); it never leaves the database: the HMAC and the rate
// limits all run in the SECURITY DEFINER function public.email_pepper_hmac (migration 20), executable only by the
// service role. The server only ever sees t — a hash of S — never the password or S itself.
//
// Two budgets per email hash, so knowing someone's email is not enough to lock them out:
//   * anonymous — no Authorization header: 10 / 15 min and 50 / 24 h per e. e needs no secret, so anyone who knows the
//     email can spend this one.
//   * verified — "Authorization: Bearer <Privy access token>": 20 / 24 h per e, counted separately, so an exhausted
//     anonymous budget never blocks the owner. The proof is the one email-rebind accepts: any valid, unexpired Privy
//     access token (verified against the Privy app's public key; issuer privy.io, audience = the app id) for the Privy
//     user whose linked email — which Privy verified with a one-time code when it was linked — hashes to e. The email
//     is read back from Privy with the app secret; the client never asserts it. (The server does not check how or when
//     the token was issued; the app sends one it got from the email one-time-code flow moments before.) The request's
//     e must be the hash of exactly that email (same normalisation as the app, see normalizeEmail), so a proof for one
//     email can never pay for another. An invalid or expired token is a 401: it never falls back to the anonymous
//     budget.
// The budgets add up: whoever can pass the email's one-time code (the owner, or anyone who has taken over the mailbox)
// gets up to 50 + 20 = 70 online guesses per email per 24 h; everyone else, 50.
// Anonymous requests also count toward, and are held to, their client network's limit (60 / 15 min; an IPv4 address or
// an IPv6 /64). Verified requests are neither (migration 24, security audit 2026-09-26 SB-4). A 429 says which limit
// fired.
//
// Checking a proof costs one call to Privy's API (with the app secret, under Privy's app-wide rate limit), made before
// the database can count anything. So that call is cached per Privy user for a few minutes in this instance, and each
// uncached one must first pass the database's lookup gate (10 per Privy user per 15 min; 30 per client network per
// 15 min, which holds a Privy user only from their third uncached lookup in 15 minutes on, migration 24) — a flood of
// valid tokens cannot turn into a flood of Privy API calls. So nobody sharing a network (a NAT, a carrier-grade NAT)
// can refuse a verified owner their first two uncached lookups in any 15 minutes; a third can still meet a network
// spent by others (429 "network"). Repeat requests from one Privy user are usually answered from the cache. The Privy app key is cached for an hour and
// refetched early — at most every 5 minutes — when a token's signature fails against it, in case Privy rotated it.
// Every Privy call has a timeout; an outage is a retryable 503, never a refusal (../_shared/privy.ts).
//
// Nothing about the request or the answer is logged: e, t and p are sensitive (p together with S is the wallet key),
// and so is the Privy token.
//
// Deploy:  supabase functions deploy email-pepper --no-verify-jwt   (called before sign-in, so there is no session;
//          the bearer, when present, is a Privy token, not a Supabase JWT)
// Secrets: PRIVY_APP_SECRET (shared with email-rebind / delete-account; only needed for verified requests) and
//          optionally PRIVY_APP_ID. SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
//
//   POST { e: <64 lowercase hex>, t: <64 lowercase hex> }   [Authorization: Bearer <Privy access token>]
//     200 { p: <64 lowercase hex> }
//     400 malformed input, or (with a token) "the verified email does not match" e / no verified email on the account
//     401 (with a token) invalid or expired Privy access token
//     429 { error: "too many attempts", retryAfter: <seconds>, limit: "email" | "network" | "proof" }
//           email    this request's budget for e (the anonymous one, or with a token the verified one)
//           network  the client network's limit: for an anonymous request the pepper's (proving the email lifts it);
//                    with a token, the lookup gate's, from the Privy user's third uncached lookup in 15 minutes on
//           proof    (with a token) this Privy user's lookups; the anonymous budget does not need one
//     503 pepper or email verification temporarily unavailable
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { linkedEmail, privyTokenClaims, privyUser, PrivyUnavailable } from "../_shared/privy.ts";

const HEX64 = /^[0-9a-f]{64}$/;
const MAX_BODY = 1024;
const EMAIL_LABEL = "dyorhq/email-pepper/v1/email:";
const PRIVY_USER_LABEL = "dyorhq/email-pepper/v1/privy-user:";
const LOOKUP_TTL_MS = 5 * 60_000; // how long a Privy user's email answer is reused in this instance
const LOOKUP_CACHE_MAX = 1000;
const LIMITS = ["email", "network", "proof"];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
  });
}

// The email exactly as the app's EmailWallet.normalize sees it — Swift's
// `email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()` — so the hash of the email Privy attests is
// byte-for-byte the e the app sent for the same address. JavaScript's own trim()/toLowerCase() differ from it:
//   trim   Foundation's CharacterSet.whitespacesAndNewlines, as enumerated on Apple's runtime: U+0009–000D, 0020, 0085,
//          00A0, 1680, 2000–200B, 2028, 2029, 202F, 205F, 3000 — U+200B is in, U+FEFF is not (String.prototype.trim
//          is the other way round) — stripped scalar by scalar from both ends;
//   lower  Swift's String.lowercased() maps each scalar to its own full lowercase mapping with no context, so a final
//          "Σ" becomes "σ" (a whole-string toLowerCase() gives "ς").
// Shared test vectors: ios/DyorKit/Tests/DyorKitTests/Fixtures/email-pepper.json (EmailWalletTests asserts them too).
const EDGE_SPACE = "[\\t-\\r \\u0085\\u00A0\\u1680\\u2000-\\u200B\\u2028\\u2029\\u202F\\u205F\\u3000]+";
const TRIM = new RegExp(`^${EDGE_SPACE}|${EDGE_SPACE}$`, "gu");
export function normalizeEmail(email: string): string {
  return Array.from(email.replace(TRIM, ""), (scalar) => scalar.toLowerCase()).join("");
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

// e for an email: SHA256(utf8("dyorhq/email-pepper/v1/email:" + normalizeEmail(email))), as 64 lowercase hex.
export function emailHash(email: string): Promise<string> {
  return sha256Hex(EMAIL_LABEL + normalizeEmail(email));
}

// The Privy access token the caller presents, or null for an anonymous request. A bearer equal to the request's own
// apikey header is not a proof — it is the publishable key, which supabase-js also sends as the bearer — so it counts
// as absent. Anything else in Authorization must verify as a Privy token (an empty or non-Bearer value included).
function privyBearer(req: Request): string | null {
  const auth = req.headers.get("authorization");
  if (auth === null) return null;
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  const apikey = (req.headers.get("apikey") ?? "").trim();
  return apikey !== "" && token === apikey ? null : token;
}

// Privy's answer (the email, or null for none) per Privy user, reused for LOOKUP_TTL_MS: repeat requests — one token,
// or several for one user — ask Privy once. Bounded; the oldest entry goes first.
const lookups = new Map<string, { email: string | null; until: number }>();
function cachedLookup(userId: string): { email: string | null } | undefined {
  const hit = lookups.get(userId);
  if (hit && hit.until > Date.now()) return hit;
  lookups.delete(userId);
  return undefined;
}
function cacheLookup(userId: string, email: string | null) {
  lookups.delete(userId);
  if (lookups.size >= LOOKUP_CACHE_MAX) lookups.delete(lookups.keys().next().value!);
  lookups.set(userId, { email, until: Date.now() + LOOKUP_TTL_MS });
}

// A database refusal ({ retryAfter, limit }) as the 429 the app reads; null when it is not one.
function tooManyAttempts(result: { retryAfter?: unknown; limit?: unknown }): Response | null {
  if (typeof result.retryAfter !== "number") return null;
  const retryAfter = Math.max(1, Math.ceil(result.retryAfter));
  const limit = typeof result.limit === "string" && LIMITS.includes(result.limit) ? { limit: result.limit } : {};
  return json({ error: "too many attempts", retryAfter, ...limit }, 429, { "Retry-After": String(retryAfter) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "server not configured" }, 500);

  let e: unknown, t: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) throw new Error("too large");
    ({ e, t } = JSON.parse(text) ?? {});
  } catch {
    return json({ error: "expected { e, t }" }, 400);
  }
  if (typeof e !== "string" || typeof t !== "string" || !HEX64.test(e) || !HEX64.test(t)) {
    return json({ error: "e and t must each be 64 lowercase hex characters" }, 400);
  }

  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const net = clientNet(req);

  // The verified budget: only for a caller whose valid Privy token names a user holding the very email e names.
  let verified = false;
  const token = privyBearer(req);
  if (token !== null) {
    let userId: string;
    try {
      ({ userId } = await privyTokenClaims(token));
    } catch (err) {
      if (err instanceof PrivyUnavailable) return json({ error: "email verification unavailable" }, 503);
      return json({ error: "invalid Privy access token" }, 401);
    }
    const secret = Deno.env.get("PRIVY_APP_SECRET");
    if (!secret) return json({ error: "PRIVY_APP_SECRET is not configured" }, 500);
    let verifiedEmail: string | null;
    const hit = cachedLookup(userId);
    if (hit) {
      verifiedEmail = hit.email;
    } else {
      const gate = await db.rpc("email_pepper_lookup_gate", { p_subject: await sha256Hex(PRIVY_USER_LABEL + userId), p_ip: net });
      if (gate.error || !gate.data || typeof gate.data !== "object") return json({ error: "pepper unavailable" }, 503);
      const refused = tooManyAttempts(gate.data);
      if (refused) return refused;
      if ((gate.data as { ok?: unknown }).ok !== true) return json({ error: "pepper unavailable" }, 503);
      try { verifiedEmail = linkedEmail(await privyUser(userId, secret)); } catch { return json({ error: "email verification unavailable" }, 503); }
      cacheLookup(userId, verifiedEmail);
    }
    if (!verifiedEmail) return json({ error: "no verified email on this Privy account" }, 400);
    if (await emailHash(verifiedEmail) !== e) return json({ error: "the verified email does not match" }, 400);
    verified = true;
  }

  const { data, error } = await db.rpc("email_pepper_hmac", { p_e: e, p_t: t, p_ip: net, p_verified: verified });
  if (error || !data || typeof data !== "object") return json({ error: "pepper unavailable" }, 503);

  const result = data as { p?: unknown; retryAfter?: unknown; limit?: unknown };
  const refused = tooManyAttempts(result);
  if (refused) return refused;
  if (typeof result.p !== "string" || !HEX64.test(result.p)) return json({ error: "pepper unavailable" }, 503);
  return json({ p: result.p });
});
