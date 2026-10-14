// The pure rules of the waitlist function (audit 2026-09-26, LR-4): which origins may call it, what a well-formed
// signup is, and how an email address is checked and normalised.
export const ALLOWED_ORIGINS: ReadonlySet<string> = new Set(["https://dyorhq.fun", "https://www.dyorhq.fun"]);
export const MAX_BODY = 2048;

// CORS headers for this request's Origin: {} for a request without one (not a browser page — CORS does not apply),
// the echoed origin when it is allowed, null when a browser page on any other origin is calling.
export function corsFor(origin: string | null): Record<string, string> | null {
  if (origin === null) return { Vary: "Origin" };
  if (!ALLOWED_ORIGINS.has(origin)) return null;
  return { "Access-Control-Allow-Origin": origin, Vary: "Origin" };
}

const LOCAL = /^[a-z0-9!#$%&'*+/=?^_`{|}~.-]{1,64}$/;
const LABEL = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const TLD = /^(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})$/;

// The address, trimmed and lowercased, when it is a plausible deliverable email: at most 254 characters, exactly one
// "@", a dot-atom local part of at most 64, and a domain of at least two DNS labels with an alphabetic (or punycode)
// top-level label. No IP-literal, quoted or non-ASCII forms. null otherwise.
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || /[\s\u0000-\u001f\u007f]/.test(email)) return null;
  const parts = email.split("@");
  if (parts.length !== 2) return null;
  const [local, domain] = parts;
  if (!LOCAL.test(local) || local.startsWith(".") || local.endsWith(".") || local.includes("..")) return null;
  if (domain.length > 253) return null;
  const labels = domain.split(".");
  if (labels.length < 2 || !labels.every((l) => LABEL.test(l)) || !TLD.test(labels[labels.length - 1])) return null;
  return email;
}

export type Signup = { email: string; source: string | null; bot: boolean };

// A signup from the request body {email, source?, website?}: `website` is a honeypot the form hides from people, so
// any non-empty value marks a bot (answered like everyone else, never stored). `source` is an optional short tag
// (printable ASCII, at most 64). null for a malformed body.
export function parseSignup(body: string): Signup | null {
  let value: unknown;
  try { value = JSON.parse(body); } catch { return null; }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const { email: rawEmail, source: rawSource, website } = value as Record<string, unknown>;
  const email = normalizeEmail(rawEmail);
  if (!email) return null;
  let source: string | null = null;
  if (rawSource !== undefined && rawSource !== null) {
    if (typeof rawSource !== "string") return null;
    const trimmed = rawSource.trim();
    if (!/^[\x20-\x7e]{0,64}$/.test(trimmed)) return null;
    source = trimmed || null;
  }
  const bot = website !== undefined && website !== null && website !== "";
  return { email, source, bot };
}
