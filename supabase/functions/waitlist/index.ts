// waitlist: stores a website waitlist signup (audit 2026-09-26, LR-4: the form only opened a mail draft, so nothing
// was stored and nobody could tell whether they had joined).
//
//   POST application/json { email, source?, website }   (no Authorization; verify_jwt = false in supabase/config.toml)
//     200 { ok: true }   for every well-formed request — new address, address already on the list, or a filled
//                        honeypot alike — so the endpoint cannot be used to test which emails signed up
//     400                malformed input (not JSON, not an object, a bad email or source, body over 2 KB)
//     403                a browser page on any origin but https://dyorhq.fun and https://www.dyorhq.fun
//     429 { retryAfter } this client network's budget is spent (5 per 15 minutes, 20 per day, per IPv4 address or IPv6
//                        /48; 500 per hour overall)
//     503                storage or the rate gate unavailable — try again
//
// `website` is a honeypot the form hides from people: a non-empty value is answered 200 and not stored. The email is
// trimmed, lowercased and checked (normalizeEmail in signup.ts); `source` is an optional short tag. Rate limits run
// through edge_rate_gate (migration 27), which never stores the client's address (only an HMAC of it under a salt no
// API role can read). IPv6 counts per /48, not /64: a tunnel broker hands out a /48 for free, and 65,536 /64 budgets
// would let one party spend the overall cap. A proxy pool with many IPv4 addresses still can; a challenge (e.g.
// Cloudflare Turnstile on the form) would be the next step if that happens. The row is inserted with ON CONFLICT DO NOTHING into public.waitlist (migration 29: RLS on, no
// policies, service role only). Nothing about the request is logged.
//
// Deploy:  supabase functions deploy waitlist --no-verify-jwt   (after migrations 27 and 29)
//          URL: https://fmnjqrguvopusfufmirs.supabase.co/functions/v1/waitlist
import { createClient } from "npm:@supabase/supabase-js@2";
import { clientNet } from "../_shared/net.ts";
import { rateGate } from "../_shared/rate.ts";
import { corsFor, MAX_BODY, parseSignup } from "./signup.ts";

const PREFLIGHT = {
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
  "Access-Control-Max-Age": "86400",
};

function json(body: unknown, status: number, headers: Record<string, string>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const cors = corsFor(origin);
  if (req.method === "OPTIONS") {
    return cors && origin !== null
      ? new Response(null, { status: 204, headers: { ...cors, ...PREFLIGHT } })
      : new Response(null, { status: 403, headers: { Vary: "Origin" } });
  }
  if (!cors) return json({ error: "origin not allowed" }, 403, { Vary: "Origin" });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405, cors);

  const contentType = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!/^application\/json\s*(;|$)/.test(contentType)) return json({ error: "expected application/json" }, 400, cors);
  let body: string;
  try { body = await req.text(); } catch { return json({ error: "invalid request" }, 400, cors); }
  if (new TextEncoder().encode(body).length > MAX_BODY) return json({ error: "invalid request" }, 400, cors);
  const signup = parseSignup(body);
  if (!signup) return json({ error: "invalid email" }, 400, cors);
  if (signup.bot) return json({ ok: true }, 200, cors);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "temporarily unavailable — try again later" }, 503, cors);
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

  const refused = await rateGate(db, "waitlist", "all", clientNet(req, 48), cors);
  if (refused) return refused;

  const { error } = await db.from("waitlist")
    .upsert({ email: signup.email, source: signup.source }, { onConflict: "email", ignoreDuplicates: true });
  if (error) return json({ error: "temporarily unavailable — try again later" }, 503, cors);
  return json({ ok: true }, 200, cors);
});
