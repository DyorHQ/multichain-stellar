// email-rebind: moves an OTP-verified email to a NEW deterministic wallet — the "forgot password" / re-verify path.
//
// Every email → address binding (sign-up and re-bind alike) is written here: direct PostgREST writes to
// email_accounts were revoked in migration 16, so the service role below is the only writer. The function requires
// TWO independent proofs before it writes:
//
//   1. Ownership of the EMAIL — the caller passes the Privy access token issued after a fresh email one-time-code
//      login (same OTP as sign-up). The token is verified against the app's public key, must have been issued within
//      the last 15 minutes (security audit 2026-09-26, SB-10), and the email is read back from Privy with the app
//      secret, so the client can never assert an email it did not just verify.
//   2. Control of the NEW WALLET — the caller signs a challenge (EIP-191 personal_sign) that names the email and the
//      new address. The signer is recovered from the signature; only the holder of the new private key can produce it.
//
// The two proofs are bound together by the challenge (it carries the same email Privy attests), so this can only ever
// bind an email you verified to a wallet you hold — it cannot hijack someone else's email or point at a wallet you
// don't control.
//
// An email that is already bound to ANOTHER wallet is never moved silently once REBIND_REQUIRE_REPLACE=on (GE-1,
// rebind.ts): the request must then carry "replace": "<that wallet>", which the app sends only after showing the user
// that wallet (and what it holds) and getting their confirmation. Otherwise the answer is 409
// {"error":"email_already_bound","current":"<that wallet>"} and nothing is written. Until the switch is on, a request
// without "replace" moves the binding as every earlier version did (still as a compare-and-set); a request with it is
// honoured either way. A first sign-up and a same-wallet re-bind are unchanged.
//
//   POST { message, signature, replace? }   Authorization: Bearer <Privy access token>
//     200 { rebound: true, address }
//     400 malformed body, expired challenge, no verified email, email mismatch
//     401 invalid, expired or stale (> 15 min) Privy token; signature does not match
//     409 { error: "email_already_bound", current }
//     429 too many Privy lookups for this user (Retry-After)
//     503 Privy or the database unavailable — retry (RO-9: every Privy call has a timeout)
//
// Deploy:  supabase functions deploy email-rebind --no-verify-jwt   (the bearer is a Privy token, not a Supabase JWT)
//          Safe to deploy now with REBIND_REQUIRE_REPLACE unset. Set REBIND_REQUIRE_REPLACE=on only once the first app
//          build that handles the 409 (balance warning, same-password and legacy rules, then "replace") has shipped
//          AND every older build is expired in App Store Connect / TestFlight (app_config ios.min_build alone does not
//          stop builds that never read it). Builds without that handling send no "replace", so with the switch on they
//          get the 409 in three flows: Forgot Password; the pre-v2 upgrade (Log In finds the legacy binding, then binds
//          the v2 wallet — legacy users could no longer log in); and Sign Up again with an email already in use.
// Secrets: PRIVY_APP_SECRET (shared with delete-account). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected.
// Needs migration 20 (email_pepper_lookup_gate) applied before this version is deployed.
import { recoverMessageAddress } from "npm:viem@2";
import { createClient } from "npm:@supabase/supabase-js@2";
import { linkedEmail, privyTokenClaims, privyUser, PrivyUnavailable, tokenIsFresh } from "../_shared/privy.ts";
import { decideRebind, field, parseReplace, REBIND_WINDOW_MS, replaceRequired, TOKEN_MAX_AGE_S } from "./rebind.ts";

// The Privy-lookup budget's subject: the same hash email-pepper uses, so the two functions share one budget per user.
const PRIVY_USER_LABEL = "dyorhq/email-pepper/v1/privy-user:";
const UNAVAILABLE = "email verification is unavailable right now — try again in a minute";
const REQUIRE_REPLACE = replaceRequired(Deno.env.get("REBIND_REQUIRE_REPLACE"));

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "missing Privy access token" }, 401);

  let userId: string;
  try {
    const claims = await privyTokenClaims(token);
    if (!tokenIsFresh(claims.issuedAt, Date.now(), TOKEN_MAX_AGE_S)) {
      return json({ error: "this verification expired — request a new code" }, 401);
    }
    userId = claims.userId;
  } catch (err) {
    if (err instanceof PrivyUnavailable) return json({ error: UNAVAILABLE, retryable: true }, 503);
    return json({ error: "invalid Privy access token" }, 401);
  }

  const secret = Deno.env.get("PRIVY_APP_SECRET");
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret || !url || !serviceKey) {
    console.error("email-rebind: PRIVY_APP_SECRET / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing"); // logs only (SB-11)
    return json({ error: "email verification is not available right now" }, 500);
  }

  let message: string, signature: string, replace: string | undefined;
  try {
    const body = await req.json();
    message = String(body.message ?? "");
    signature = String(body.signature ?? "");
    const parsed = parseReplace(body.replace);
    if (!message || !signature.startsWith("0x") || parsed === "invalid") throw new Error("bad body");
    replace = parsed;
  } catch {
    return json({ error: "expected { message, signature, replace? }" }, 400);
  }

  // The challenge must be recent and carry the address it claims to bind. These checks, and the signature below, cost
  // nothing external, so they run BEFORE the Privy admin call: a flood of junk bodies behind one valid token must not
  // become a flood of calls against Privy's app-wide rate limit (security audit 2026-09-26, SB-3).
  const claimedEmail = (field(message, "Email") ?? "").toLowerCase();
  const claimedAddress = (field(message, "Address") ?? "").toLowerCase();
  const issuedAt = Date.parse(field(message, "Issued At") ?? "");
  if (!Number.isFinite(issuedAt) || Math.abs(Date.now() - issuedAt) > REBIND_WINDOW_MS) {
    return json({ error: "this reset expired — start again" }, 400);
  }

  // Proof #2 — recover the signer of the challenge; it must be the address the challenge binds.
  let recovered: string;
  try {
    recovered = (await recoverMessageAddress({ message, signature: signature as `0x${string}` })).toLowerCase();
  } catch {
    return json({ error: "invalid wallet signature" }, 401);
  }
  if (!/^0x[0-9a-f]{40}$/.test(claimedAddress) || recovered !== claimedAddress) {
    return json({ error: "wallet signature did not match" }, 401);
  }

  // Each Privy admin call first passes email_pepper_lookup_gate (migration 20): at most 10 lookups per Privy user per
  // 15 minutes, a budget shared with the email-pepper function (same subject hash), so one token replaying one valid
  // challenge cannot turn into a stream of calls under Privy's app-wide rate limit.
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const gate = await admin.rpc("email_pepper_lookup_gate", { p_subject: await sha256Hex(PRIVY_USER_LABEL + userId), p_ip: null });
  if (gate.error || !gate.data || typeof gate.data !== "object") return json({ error: UNAVAILABLE, retryable: true }, 503);
  const retryAfter = (gate.data as { retryAfter?: unknown }).retryAfter;
  if (typeof retryAfter === "number") {
    const wait = Math.max(1, Math.ceil(retryAfter));
    return new Response(JSON.stringify({ error: "too many attempts — try again in a few minutes", retryAfter: wait }), {
      status: 429,
      headers: { ...cors, "Content-Type": "application/json", "Retry-After": String(wait) },
    });
  }
  if ((gate.data as { ok?: unknown }).ok !== true) return json({ error: UNAVAILABLE, retryable: true }, 503);

  // Proof #1 — the email Privy attests for this token; the challenge must name that exact email.
  let verifiedEmail: string | null;
  try {
    verifiedEmail = linkedEmail(await privyUser(userId, secret))?.trim().toLowerCase() || null;
  } catch {
    return json({ error: UNAVAILABLE, retryable: true }, 503);
  }
  if (!verifiedEmail) return json({ error: "no verified email on this Privy account" }, 400);
  if (claimedEmail !== verifiedEmail) return json({ error: "the code you entered was for a different email" }, 400);

  // Both proofs hold. Write with the service role (the only path allowed past the owner RLS), never moving the email
  // off another wallet without the client's confirmation (GE-1). A write that loses a race re-reads and decides again.
  for (let attempt = 0; attempt < 3; attempt++) {
    const existing = await admin.from("email_accounts").select("wallet").eq("email", verifiedEmail).maybeSingle();
    if (existing.error) {
      console.error("email-rebind read failed:", existing.error.message); // function logs only; never the client
      return json({ error: "could not save the binding — try again", retryable: true }, 503);
    }
    const current = typeof existing.data?.wallet === "string" ? existing.data.wallet : null;
    const decision = decideRebind(current, recovered, replace, REQUIRE_REPLACE);
    if (decision.action === "conflict") return json({ error: "email_already_bound", current: decision.current }, 409);

    const verified_at = new Date().toISOString();
    const write = decision.action === "insert"
      ? await admin.from("email_accounts")
        .upsert({ email: verifiedEmail, wallet: recovered, verified_at }, { onConflict: "email", ignoreDuplicates: true })
        .select("email")
      : await admin.from("email_accounts")
        .update({ wallet: recovered, verified_at })
        .eq("email", verifiedEmail).eq("wallet", decision.from)
        .select("email");
    if (write.error) {
      console.error("email-rebind write failed:", write.error.message); // function logs only; never the client
      return json({ error: "could not save the binding — try again", retryable: true }, 503);
    }
    if ((write.data ?? []).length === 1) return json({ rebound: true, address: recovered });
  }
  return json({ error: "could not save the binding — try again", retryable: true }, 503);
});
