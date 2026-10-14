// The Edge Functions' side of edge_rate_gate (migration 27): per-subject, per-network and overall budgets for pin-media,
// aurora-proxy, waitlist and wallet-auth's first sign-ins. The gate records an allowed call and answers {"ok": true},
// or refuses with {"retryAfter": seconds, "limit": "subject" | "network" | "global"}. Anything else — the RPC failing
// (including before migration 27 is applied), an unexpected answer — fails closed as a retryable 503, so an outage can
// never turn into unlimited use.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export type RateScope = "pin-media" | "aurora" | "aurora-status" | "waitlist" | "wallet-auth";
const LIMITS = new Set(["subject", "network", "global"]);

// null when the call may proceed, else the Response to send (with `headers`, e.g. the function's CORS headers).
export function gateRefusal(data: unknown, failed: boolean, headers: Record<string, string>): Response | null {
  const reply = (body: unknown, status: number, extra: Record<string, string> = {}) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...headers, "Content-Type": "application/json", "Cache-Control": "no-store", ...extra },
    });
  if (failed || !data || typeof data !== "object") {
    return reply({ error: "temporarily unavailable — try again in a minute", retryable: true }, 503);
  }
  const result = data as { ok?: unknown; retryAfter?: unknown; limit?: unknown };
  if (typeof result.retryAfter === "number" && Number.isFinite(result.retryAfter)) {
    const retryAfter = Math.min(86_400, Math.max(1, Math.ceil(result.retryAfter)));
    const limit = typeof result.limit === "string" && LIMITS.has(result.limit) ? { limit: result.limit } : {};
    return reply({ error: "too many requests — try again later", retryAfter, ...limit }, 429, { "Retry-After": String(retryAfter) });
  }
  if (result.ok !== true) return reply({ error: "temporarily unavailable — try again in a minute", retryable: true }, 503);
  return null;
}

// Passes one call through the gate: null to proceed, else the refusal to send.
export async function rateGate(db: SupabaseClient, scope: RateScope, subject: string | null, net: string | null,
                               headers: Record<string, string>): Promise<Response | null> {
  try {
    const { data, error } = await db.rpc("edge_rate_gate", { p_scope: scope, p_subject: subject, p_ip: net });
    return gateRefusal(data, Boolean(error), headers);
  } catch {
    return gateRefusal(null, true, headers);
  }
}
