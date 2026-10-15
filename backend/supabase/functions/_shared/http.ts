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
/** A route that is registered in its final place but not written yet. */
export const notImplemented = () => new ApiError(501, "not_implemented", "This isn't available yet.");

/** Public reads (config, fees, markets) may be cached for 30 s (docs/DESIGN-stellar-parity.md §6.0). */
export const PUBLIC_CACHE = { "cache-control": "public, max-age=30" };

/** A viewer route's public view (no token, ?address=) may be cached for 15 s (§6.0). */
export const PUBLIC_VIEW_CACHE = { "cache-control": "public, max-age=15" };

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

/** Sign-in's routes (lite/routes/auth.ts) read a body that isn't a JSON object as one with no fields, so their 400 names
 *  the field that is missing. */
const SIGN_IN = /\/v1\/auth\//;

/** The JSON object a request carries; an empty body reads as {}. Other JSON (null, an array, a string, a number) is
 *  400 bad_arg, so no handler reads a field of something that has none; on sign-in's routes it reads as {}. */
export async function readJson<T = Record<string, unknown>>(req: Request): Promise<T> {
  const text = await req.text();
  if (text.length > 64 * 1024) throw bad("too_large", "Request body is too large.");
  if (!text) return {} as T;
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw bad("bad_json", "Request body is not valid JSON.");
  }
  if (body !== null && typeof body === "object" && !Array.isArray(body)) return body as T;
  if (SIGN_IN.test(new URL(req.url).pathname)) return {} as T;
  throw bad("bad_arg", "The request body must be a JSON object.");
}

export type Handler = (ctx: { req: Request; params: Record<string, string>; url: URL }) => Promise<Response>;

/** Runs after a request matched `route` ("GET /v1/account") and before its handler. Throwing answers the request. */
export type Guard = (req: Request, route: string) => Promise<void>;

interface Route {
  spec: string;
  method: string;
  parts: string[];
  handler: Handler;
}

export interface Match {
  spec: string;
  params: Record<string, string>;
  handler: Handler;
}

/** Routes like "GET /v1/launches/:token". A last segment "*name" takes the rest of the path, one segment or more. The
 *  path is matched from its "/v1/" segment, so the same table works behind Supabase's /functions/v1/<name>/ prefix
 *  and when served locally. The first route registered that matches wins. */
export class Router {
  private routes: Route[] = [];
  private guard: Guard | null = null;

  on(spec: string, handler: Handler): this {
    const [method, path] = spec.split(" ");
    this.routes.push({ spec, method, parts: path.split("/").filter(Boolean), handler });
    return this;
  }

  /** Checks every request a route matched before the route's handler runs. */
  before(guard: Guard): this {
    this.guard = guard;
    return this;
  }

  /** Every route, in the order they match. */
  get specs(): string[] {
    return this.routes.map((r) => r.spec);
  }

  /** The route a request for `pathname` reaches, or null. */
  match(method: string, pathname: string): Match | null {
    const all = pathname.split("/").filter(Boolean);
    // Supabase serves this function under /functions/v1/<name>/ (or /<name>/ inside the runtime): the API's own
    // "v1" is the last one.
    const start = all.lastIndexOf("v1");
    const parts = start >= 0 ? all.slice(start) : all;
    for (const r of this.routes) {
      if (r.method !== method) continue;
      const params = matchParts(r.parts, parts);
      if (params) return { spec: r.spec, params, handler: r.handler };
    }
    return null;
  }

  async handle(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const m = this.match(req.method, url.pathname);
    if (!m) return errorResponse(new ApiError(404, "no_route", `No route for ${req.method} ${url.pathname}`));
    try {
      if (this.guard) await this.guard(req, m.spec);
      return await m.handler({ req, params: m.params, url });
    } catch (err) {
      return errorResponse(err);
    }
  }
}

function matchParts(pattern: string[], parts: string[]): Record<string, string> | null {
  const rest = pattern.length > 0 && pattern[pattern.length - 1].startsWith("*");
  if (rest ? parts.length < pattern.length : parts.length !== pattern.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < pattern.length; i++) {
    const p = pattern[i];
    if (p.startsWith("*")) {
      // The rest, segment by segment: none may decode to a separator or step out of the directory.
      const segments = parts.slice(i).map(decodeURIComponent);
      if (segments.some((s) => s.includes("/") || s === "." || s === "..")) return null;
      params[p.slice(1)] = segments.join("/");
      break;
    }
    if (p.startsWith(":")) params[p.slice(1)] = decodeURIComponent(parts[i]);
    else if (p !== parts[i]) return null;
  }
  return params;
}

/** Token bucket per key, per isolate. Best effort: Edge Function isolates are short-lived, so the database's limits
 *  (lite.reserve_sponsorship) are the hard ones for anything that costs DyorHQ money. */
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
