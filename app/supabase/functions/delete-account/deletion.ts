// The pure rules delete-account applies (security audit 2026-09-26, SB-7 and SB-10).

// How old the Privy access token for a Privy-login deletion may be (SB-10). Deleting the Privy user also deletes its
// embedded wallet, so ideally a token that leaked in the last hour is not enough — but the builds in use send their
// cached Privy token (Session.swift, user.getAccessToken()), which may be up to an hour old (Privy's token lifetime),
// and they delete their server rows before calling, so refusing it would leave a half-deleted account. The default is
// therefore the old behaviour, an hour. DELETE_ACCOUNT_TOKEN_MAX_AGE_S tightens it (e.g. 900) once the first build
// that refreshes its Privy session right before calling has shipped and every older build is expired; it is clamped
// to between a minute and an hour.
export const DEFAULT_TOKEN_MAX_AGE_S = 60 * 60;

export function tokenMaxAge(configured: string | undefined): number {
  const n = Number(configured);
  if (configured === undefined || configured.trim() === "" || !Number.isInteger(n)) return DEFAULT_TOKEN_MAX_AGE_S;
  return Math.min(3600, Math.max(60, n));
}

// Which deletion the request asks for: "email-password" (the bearer is the wallet's own Supabase session, SB-7) or
// "privy" (the bearer is a Privy access token — every build before SB-7 sends "{}"). null for anything else.
export function deletionMethod(body: unknown): "privy" | "email-password" | null {
  if (body === null || typeof body !== "object" || Array.isArray(body)) return null;
  const method = (body as { method?: unknown }).method;
  if (method === undefined) return "privy";
  return method === "email-password" ? "email-password" : null;
}

// The Email & Password path's answer when the caller has no binding row: nothing identifies a Privy user any more (the
// app deleted its email_accounts row first, or never had one), so the deletion must not be reported as done. The app
// calls before deleting its rows; a retry after they are gone gets this.
export const NO_BINDING = { deleted: false, privy: "unknown", error: "no email binding" } as const;

// The caller's own binding, from PostgREST's answer to GET /rest/v1/email_accounts?select=email,wallet made with the
// caller's session (RLS "owner reads own email binding" returns only rows whose wallet is the session's). null when
// there is none; "invalid" for anything that is not one well-formed row.
export function ownBinding(rows: unknown): { email: string; wallet: string } | null | "invalid" {
  if (!Array.isArray(rows)) return "invalid";
  if (rows.length === 0) return null;
  const row = rows[0] as { email?: unknown; wallet?: unknown } | null;
  if (rows.length !== 1 || !row || typeof row.email !== "string" || !row.email.includes("@") ||
      typeof row.wallet !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(row.wallet)) return "invalid";
  return { email: row.email, wallet: row.wallet };
}

// The role and wallet a session JWT claims, read WITHOUT verifying it — call it only on a token PostgREST has just
// accepted. The Email & Password path requires role authenticated and a wallet equal to the binding's, so a token that
// PostgREST lets see more than the caller's own row (a service-role key) can never select someone else's binding.
export function sessionClaims(token: string): { role?: string; wallet?: string } {
  const part = token.split(".")[1];
  if (!part) return {};
  try {
    const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(part.length + (4 - part.length % 4) % 4, "=");
    const claims = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))));
    return {
      role: typeof claims?.role === "string" ? claims.role : undefined,
      wallet: typeof claims?.wallet_address === "string" ? claims.wallet_address.toLowerCase() : undefined,
    };
  } catch {
    return {};
  }
}
