// delete-account: deletes the caller's Privy user — and with it the embedded wallet — so that in-app account
// deletion is complete (App Store guideline 5.1.1(v)). The app deletes its own Supabase rows separately, under the
// wallet's row-level security. Two ways in:
//
//   * A Privy login (email code, Apple, Google): POST {} with the Privy access token as the bearer. It is verified
//     against the app's public verification key and must have been issued within DELETE_ACCOUNT_TOKEN_MAX_AGE_S
//     (default an hour, the old behaviour: the builds in use send their cached token; security audit 2026-09-26,
//     SB-10, deletion.ts), then the user is deleted with the app secret, which lives only in this function's
//     environment.
//       200 { deleted: true } | { deleted: true, alreadyGone: true }
//   * An Email & Password account (SB-7), which keeps no Privy session: its sign-up created a Privy user through the
//     email one-time code, and nothing deleted it. POST { "method": "email-password" } with the wallet's own Supabase
//     session as the bearer, BEFORE the app deletes its email_accounts row. The binding is read with that session
//     (PostgREST verifies it, and RLS returns only the caller's own row), so only the wallet the email is bound to can
//     ask. The Privy user holding that email is deleted only when that email is its only linked account — anything
//     else (an embedded or external wallet, Apple/Google sign-in merged in by email, a passkey) means it is also another
//     way into DyorHQ, and it is kept.
//       200 { deleted: true, privy: "deleted" | "none" } | { deleted: false, privy: "kept" }
//       409 { deleted: false, privy: "unknown", error: "no email binding" }   the caller has no binding row (it was
//           already deleted, or never existed): nothing was deleted, and it is not reported as done
//
// Errors: 401 invalid or stale token / no wallet session; 429 too many Privy lookups (Retry-After); 503 Privy or the
// database unavailable — retry (RO-9: every Privy call has a timeout); 502 Privy refused.
//
// Deploy:  supabase functions deploy delete-account --no-verify-jwt   (the bearer is a Privy token or a wallet session)
//          Safe to deploy now: with DELETE_ACCOUNT_TOKEN_MAX_AGE_S unset a Privy token may be an hour old, as before.
//          Set it to 900 only once the first build that refreshes its Privy session right before deleting has shipped
//          and every older build is expired in App Store Connect / TestFlight. No build sends {"method":
//          "email-password"} yet: that path is ready for the build that calls it before deleting its rows.
// Secrets: supabase secrets set PRIVY_APP_SECRET=...   (PRIVY_APP_ID defaults to the DyorHQ app)
//          SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / the publishable key are auto-injected (the rate-limit gate needs
//          migration 20 applied).
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  deletePrivyUser, onlyLinkedToEmail, privyTokenClaims, PrivyUnavailable, privyUserByEmail, tokenIsFresh,
} from "../_shared/privy.ts";
import { deletionMethod, NO_BINDING, ownBinding, sessionClaims, tokenMaxAge } from "./deletion.ts";

// The Privy-lookup budget's subjects: the same hash email-pepper and email-rebind use (one budget per Privy user),
// and one per wallet for the Email & Password path.
const PRIVY_USER_LABEL = "dyorhq/email-pepper/v1/privy-user:";
const WALLET_LABEL = "dyorhq/delete-account/v1/wallet:";
const UNAVAILABLE = "account deletion is unavailable right now — try again in a minute";

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json", ...extra } });
}

// The project's publishable key, for reading the caller's binding through PostgREST with the caller's own session.
function publishableKey(): string | null {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") ?? "{}");
    if (typeof keys?.default === "string" && keys.default) return keys.default;
  } catch { /* fall through to the legacy anon key */ }
  return Deno.env.get("SUPABASE_ANON_KEY") ?? null;
}

// Every Privy admin call first passes email_pepper_lookup_gate (migration 20): at most 10 per subject per 15 minutes,
// so one valid token or session cannot turn into a stream of calls under Privy's app-wide rate limit (SB-3). A refusal
// leaves everything as it was; the app stops before erasing the device and can retry. null to proceed.
async function lookupGate(url: string, serviceKey: string, subject: string): Promise<Response | null> {
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const gate = await db.rpc("email_pepper_lookup_gate", { p_subject: await sha256Hex(subject), p_ip: null });
  if (gate.error || !gate.data || typeof gate.data !== "object") return json({ error: UNAVAILABLE, retryable: true }, 503);
  const retryAfter = (gate.data as { retryAfter?: unknown }).retryAfter;
  if (typeof retryAfter === "number") {
    const wait = Math.max(1, Math.ceil(retryAfter));
    return json({ error: "too many attempts — try again in a few minutes", retryAfter: wait }, 429, { "Retry-After": String(wait) });
  }
  if ((gate.data as { ok?: unknown }).ok !== true) return json({ error: UNAVAILABLE, retryable: true }, 503);
  return null;
}

// A failed Privy deletion as the response the app reads: retryable (503) or not (502).
function deletionFailed(err: unknown): Response {
  if (err instanceof PrivyUnavailable) return json({ error: UNAVAILABLE, retryable: true }, 503);
  console.error("delete-account: Privy refused the deletion:", (err as Error)?.message); // function logs only (SB-11)
  return json({ error: "account deletion failed — contact support" }, 502);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "missing access token" }, 401);

  let method: "privy" | "email-password" | null;
  try {
    const text = await req.text();
    method = deletionMethod(text.trim() === "" ? {} : JSON.parse(text));
  } catch {
    method = null;
  }
  if (!method) return json({ error: "expected {} or { \"method\": \"email-password\" }" }, 400);

  // Checked only once the caller is authenticated (below). The app matches this exact message to explain that deletion
  // is not enabled on the server yet.
  const secret = Deno.env.get("PRIVY_APP_SECRET");
  const secretMissing = () => json({ error: "PRIVY_APP_SECRET is not configured" }, 500);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "server not configured" }, 500);

  if (method === "privy") {
    let userId: string;
    try {
      const claims = await privyTokenClaims(token);
      if (!tokenIsFresh(claims.issuedAt, Date.now(), tokenMaxAge(Deno.env.get("DELETE_ACCOUNT_TOKEN_MAX_AGE_S")))) {
        return json({ error: "sign in again to delete your account", reauthenticate: true }, 401);
      }
      userId = claims.userId;
    } catch (err) {
      if (err instanceof PrivyUnavailable) return json({ error: UNAVAILABLE, retryable: true }, 503);
      return json({ error: "invalid Privy access token" }, 401);
    }
    if (!secret) return secretMissing();
    const refused = await lookupGate(url, serviceKey, PRIVY_USER_LABEL + userId);
    if (refused) return refused;
    try {
      return (await deletePrivyUser(userId, secret)) === "gone" ? json({ deleted: true, alreadyGone: true }) : json({ deleted: true });
    } catch (err) {
      return deletionFailed(err);
    }
  }

  // Email & Password (SB-7): the caller's own binding, read with the caller's own session.
  const apikey = publishableKey();
  if (!apikey) return json({ error: "server not configured" }, 500);
  let rows: unknown;
  try {
    const res = await fetch(`${url}/rest/v1/email_accounts?select=email,wallet`, {
      headers: { apikey, Authorization: `Bearer ${token}`, Accept: "application/json" },
      signal: AbortSignal.timeout(8_000),
    });
    if (res.status === 401 || res.status === 403) return json({ error: "a signed-in wallet session is required" }, 401);
    if (!res.ok) return json({ error: UNAVAILABLE, retryable: true }, 503);
    rows = await res.json();
  } catch {
    return json({ error: UNAVAILABLE, retryable: true }, 503);
  }
  const binding = ownBinding(rows);
  if (binding === "invalid") return json({ error: UNAVAILABLE, retryable: true }, 503);
  const session = sessionClaims(token);
  if (session.role !== "authenticated" || !session.wallet) return json({ error: "a signed-in wallet session is required" }, 401);
  if (binding === null) return json(NO_BINDING, 409);
  if (session.wallet !== binding.wallet.toLowerCase()) return json({ error: "a signed-in wallet session is required" }, 401);

  if (!secret) return secretMissing();
  const refused = await lookupGate(url, serviceKey, WALLET_LABEL + binding.wallet.toLowerCase());
  if (refused) return refused;
  try {
    const user = await privyUserByEmail(binding.email, secret);
    if (!user || typeof user.id !== "string") return json({ deleted: true, privy: "none" });
    if (!onlyLinkedToEmail(user, binding.email)) return json({ deleted: false, privy: "kept" });
    return json({ deleted: true, privy: (await deletePrivyUser(user.id, secret)) === "gone" ? "none" : "deleted" });
  } catch (err) {
    return deletionFailed(err);
  }
});
