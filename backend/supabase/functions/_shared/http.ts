// Minimal HTTP plumbing for the Lite API: JSON in/out, typed errors, a tiny router and a best-effort rate limiter.

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public detail?: unknown) {
    super(message);
  }
}

export const bad = (code: string, message: string, detail?: unknown) => new ApiError(400, code, message, detail);
export const unauthorized = (message = "Sign in again.") => new ApiError(401, "unauthorized", message);
export const forbidden = (code: string, message: string) => new ApiError(403, code, message);
export const notFound = (what: string) => new ApiError(404, "not_found", `${what} not found.`);

export function json(body: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body, (_k, v) => (typeof v === "bigint" ? v.toString() : v)), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

export function errorResponse(err: unknown): Response {
  if (err instanceof ApiError) {
    return json({ error: { code: err.code, message: err.message, detail: err.detail ?? null } }, err.status);
  }
  console.error("unhandled", err);
  return json({ error: { code: "internal", message: "Something went wrong on our side. Try again." } }, 500);
}

export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  const text = await req.text();
  if (text.length > 64 * 1024) throw bad("too_large", "Request body is too large.");
  if (!text) return {} as T;
  try {
    return JSON.parse(text) as T;
  } catch {
    throw bad("bad_json", "Request body is not valid JSON.");
  }
}

export type Handler = (ctx: { req: Request; params: Record<string, string>; url: URL }) => Promise<Response>;

interface Route {
  method: string;
  parts: string[];
  handler: Handler;
}

/** Routes like "GET /v1/launches/:token". The path is matched from its "/v1/" segment, so the same table works
 *  behind Supabase's /functions/v1/<name>/ prefix and when served locally. */
export class Router {
  private routes: Route[] = [];

  on(spec: string, handler: Handler): this {
    const [method, path] = spec.split(" ");
    this.routes.push({ method, parts: path.split("/").filter(Boolean), handler });
    return this;
  }

  async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const all = url.pathname.split("/").filter(Boolean);
    const start = all.indexOf("v1");
    const parts = start >= 0 ? all.slice(start) : all;
    for (const r of this.routes) {
      if (r.method !== req.method || r.parts.length !== parts.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < parts.length; i++) {
        if (r.parts[i].startsWith(":")) params[r.parts[i].slice(1)] = decodeURIComponent(parts[i]);
        else if (r.parts[i] !== parts[i]) {
          ok = false;
          break;
        }
      }
      if (ok) {
        try {
          return await r.handler({ req, params, url });
        } catch (err) {
          return errorResponse(err);
        }
      }
    }
    return errorResponse(new ApiError(404, "no_route", `No route for ${req.method} ${url.pathname}`));
  }
}

/** Token bucket per key, per isolate. Best effort: Edge Function isolates are short-lived, so the database budget
 *  (sponsor_usage) is the hard limit for anything that costs money. */
const buckets = new Map<string, { tokens: number; at: number }>();

export function rateLimit(key: string, perMinute: number): void {
  const now = Date.now();
  const b = buckets.get(key) ?? { tokens: perMinute, at: now };
  b.tokens = Math.min(perMinute, b.tokens + ((now - b.at) / 60_000) * perMinute);
  b.at = now;
  if (b.tokens < 1) throw new ApiError(429, "rate_limited", "Too many requests. Wait a moment and try again.");
  b.tokens -= 1;
  buckets.set(key, b);
  if (buckets.size > 10_000) buckets.clear();
}

export function clientIp(req: Request): string {
  return req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? req.headers.get("cf-connecting-ip") ?? "unknown";
}

// ---------------------------------------------------------------------------------------------- validation helpers

const STROOPS = /^[0-9]{1,30}$/;

/** An amount in base units (stroops for 7-decimal assets), as a decimal string. */
export function amountArg(v: unknown, name: string): bigint {
  if (typeof v !== "string" || !STROOPS.test(v)) throw bad("bad_amount", `${name} must be a whole number of base units, as a string.`);
  const n = BigInt(v);
  if (n <= 0n) throw bad("bad_amount", `${name} must be positive.`);
  return n;
}

export function stringArg(v: unknown, name: string, max = 256): string {
  if (typeof v !== "string" || v.length === 0 || v.length > max) throw bad("bad_arg", `${name} is missing or too long.`);
  return v;
}

export function intArg(v: unknown, name: string, min: number, max: number): number {
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw bad("bad_arg", `${name} must be an integer from ${min} to ${max}.`);
  return n;
}
