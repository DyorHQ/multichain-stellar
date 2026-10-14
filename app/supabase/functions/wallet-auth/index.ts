// wallet-auth: bridges a Privy wallet login to a Supabase session, with a server-issued single-use nonce.
//
//   1. POST { action: "nonce", address }            -> { nonce, expiresAt }
//      32 random bytes (64 lowercase hex), valid for 5 minutes, bound to lower(address). There is deliberately NO
//      per-wallet cap: wallet addresses are public, so either refusing new nonces (429) or evicting the oldest pending
//      ones would let anyone lock a chosen wallet out of sign-in by requesting nonces for it faster than its owner can
//      sign (security audit 2026-09-26, SB-1). A cap per wallet never bounded the table anyway (any number of wallets
//      can be named); expired rows are purged on every issue (an expired nonce can never be consumed), so the table only
//      ever holds about 5 minutes of issuance.
//   2. POST { address, message, signature }          -> { access_token, token_type, expires_in, wallet }
//      The wallet personal_signs an EIP-4361 (Sign-In with Ethereum) message bound to dyorhq.fun and chain 143 around
//      that nonce (security audit 2026-09-26, IOSK-7; the exact text and rules are in sign_in.ts), or — for the builds
//      that send it, until the owner retires them — the legacy
//        "DyorHQ Sign-In\n\nWallet: <address as sent>\nNonce: <nonce>\nIssued At: <unix ms>"
//      This function checks the template (anchored, no extra lines), the times (< 10 minutes), recovers the signer
//      (EIP-191), and only THEN consumes the nonce atomically — a single UPDATE … WHERE used_at IS NULL AND
//      expires_at > now(), so a signature can be exchanged for a session at most once, and nobody without the wallet's
//      signature can burn a nonce. Legacy client-generated nonces are rejected (no grace period).
//      A wallet signing in for the FIRST time (no profile row yet; the app creates one on every sign-in) then passes
//      edge_rate_gate 'wallet-auth' for its client network — an IPv4 address or IPv6 /48 — at most 30 per 15 minutes
//      and 200 per day (migration 27; security audit 2026-09-26, SB-2 / OH-6: wallets cost nothing, so every per-wallet
//      budget in pin-media, aurora-proxy and storage multiplied freely). A returning wallet is never counted or
//      refused, so nobody sharing its network can lock it out. Refused: 429 with Retry-After (the nonce is spent; the
//      app signs a new one).
//
// On success it mints a Supabase-compatible JWT carrying the `wallet_address` claim every RLS policy keys off (signed
// as session.ts describes). No private key ever touches this service; only a signature over a server nonce.
//
// Deploy:  supabase functions deploy wallet-auth --no-verify-jwt   (called before the app has a session)
//          Apply migration 19 first, and ship together with the app build that requests nonces: this version rejects
//          the old client-built message, and the old version rejects { action: "nonce" }. Apply migration 27 before
//          deploying this version: without edge_rate_gate a first sign-in fails closed (503; returning wallets are
//          unaffected).
// Options: WALLET_AUTH_LEGACY_SIGNIN=off refuses the legacy template (sign_in.ts: only once the first EIP-4361 build
//          has shipped and every older build is expired); WALLET_AUTH_SESSION_S shortens the session (session.ts).
// Secret:  APP_JWT_SECRET must equal the project's JWT Secret (Dashboard -> Settings -> API -> JWT Secret) so the
//          minted tokens are accepted by PostgREST — or, once the owner moves sessions to a dedicated asymmetric key
//          (OH-7, supabase/README.md), APP_JWT_SIGNING_JWK, which then takes precedence. SUPABASE_URL /
//          SUPABASE_SERVICE_ROLE_KEY are auto-injected; the nonces live in public.auth_nonces (migration 19: RLS on,
//          no policies, service role only).
import { recoverMessageAddress, isAddress } from "npm:viem@2";
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { rateGate } from "../_shared/rate.ts";
import { legacySignIn, parseSignIn } from "./sign_in.ts";
import { mintSession, type SessionSigner, sessionLifetime, sessionSigner } from "./session.ts";

const NONCE_TTL_MS = 5 * 60 * 1000; // a nonce must be used within 5 minutes of issue
const LEGACY_SIGNIN = legacySignIn(Deno.env.get("WALLET_AUTH_LEGACY_SIGNIN"));
const LIFETIME_S = sessionLifetime(Deno.env.get("WALLET_AUTH_SESSION_S"));

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const hex = (bytes: Uint8Array) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function admin() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

// The session signer, resolved once per isolate (a malformed key fails every request until it is fixed; see
// session.ts). null when neither key is configured.
let signer: Promise<SessionSigner | null> | null = null;
function configuredSigner(): Promise<SessionSigner | null> {
  signer ??= sessionSigner({ jwk: Deno.env.get("APP_JWT_SIGNING_JWK"), secret: Deno.env.get("APP_JWT_SECRET") });
  return signer;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // Configuration problems are named in the function logs only, never in the response (security audit 2026-09-26, SB-11).
  let sessionKey: SessionSigner | null;
  try { sessionKey = await configuredSigner(); } catch (err) { console.error("wallet-auth:", (err as Error).message); sessionKey = null; }
  if (!sessionKey) {
    console.error("wallet-auth: no usable session signing key (APP_JWT_SIGNING_JWK or APP_JWT_SECRET)");
    return json({ error: "server not configured" }, 500);
  }
  const db = admin();
  if (!db) return json({ error: "server not configured" }, 500);

  let payload: { action?: unknown; address?: unknown; message?: unknown; signature?: unknown };
  try { payload = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  if (!payload || typeof payload !== "object") return json({ error: "invalid json" }, 400);

  // ── 1. Issue a nonce ────────────────────────────────────────────────────────────────────────────────────────────
  if (payload.action === "nonce") {
    const address = payload.address;
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address) || !isAddress(address)) {
      return json({ error: "a valid wallet address is required" }, 400);
    }
    const wallet = address.toLowerCase();
    const nonce = hex(crypto.getRandomValues(new Uint8Array(32)));
    const expiresAt = Date.now() + NONCE_TTL_MS;

    // Consumption requires expires_at > now(), so deleting every expired row (used or not) changes nothing observable.
    const now = new Date().toISOString();
    const [, inserted] = await Promise.all([
      db.from("auth_nonces").delete().lt("expires_at", now),
      db.from("auth_nonces").insert({ nonce, wallet, expires_at: new Date(expiresAt).toISOString() }),
    ]);
    if (inserted.error) return json({ error: "could not issue a sign-in nonce" }, 502);
    return json({ nonce, expiresAt });
  }
  if (payload.action !== undefined) return json({ error: "unknown action" }, 400);

  // ── 2. Exchange a signed nonce for a session ────────────────────────────────────────────────────────────────────
  const { address, message, signature } = payload;
  if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address) || !isAddress(address) ||
      typeof message !== "string" || !message || typeof signature !== "string" || !/^0x[0-9a-fA-F]+$/.test(signature)) {
    return json({ error: "address, message and signature are required" }, 400);
  }

  const signIn = parseSignIn(message, address, Date.now(), { legacy: LEGACY_SIGNIN });
  if ("error" in signIn) return json({ error: signIn.error }, signIn.status);
  const nonce = signIn.nonce;

  let recovered: string;
  try { recovered = await recoverMessageAddress({ message, signature: signature as `0x${string}` }); }
  catch { return json({ error: "unreadable signature" }, 401); }
  if (recovered.toLowerCase() !== address.toLowerCase()) return json({ error: "signature does not match address" }, 401);

  const wallet = address.toLowerCase();
  const now = new Date().toISOString();
  const consumed = await db.from("auth_nonces").update({ used_at: now })
    .eq("nonce", nonce).eq("wallet", wallet).is("used_at", null).gt("expires_at", now)
    .select("nonce");
  if (consumed.error) return json({ error: "could not verify the sign-in nonce" }, 502);
  if (!consumed.data || consumed.data.length !== 1) {
    return json({ error: "sign-in nonce invalid, expired or already used" }, 401);
  }

  // A first sign-in for this wallet counts against its client network's budget (see the header).
  const known = await db.from("profiles").select("wallet").eq("wallet", wallet).limit(1);
  if (known.error || !Array.isArray(known.data)) return json({ error: "could not complete the sign-in — try again" }, 502);
  if (known.data.length === 0) {
    const refused = await rateGate(db, "wallet-auth", null, clientNet(req, 48), cors);
    if (refused) return refused;
  }

  const token = await mintSession(wallet, sessionKey, Math.floor(Date.now() / 1000), LIFETIME_S);

  return json({ access_token: token, token_type: "bearer", expires_in: LIFETIME_S, wallet });
});
