// The pg_cron tick's only credential: the x-history-cron header. The function runs with verify_jwt = false, so this
// check is the gate. The value lives only in Vault (history_cron_secret): migration 33 generates it inside Postgres
// (32 random bytes, 64 hex characters) and the cron job reads it at each tick, so no person, file or Edge secret holds
// it. The function never sends a header to the database: it fetches the secret's SHA-256 once (public.history_cron_digest(),
// service_role only, migration 32; never the secret itself), keeps it for a minute, and compares each header's
// SHA-256 with it here in constant time.
//
// So no caller can make the function load the database, or lock the cron tick out: a wrong header costs one SHA-256 in
// the isolate, never a query; the digest is fetched at most once a minute per isolate (one fetch at a time, shared by
// every request waiting on it), and a failed fetch is retried at most every 5 s (503 meanwhile). There is no refusal
// counter for a flood to fill. A rotated secret takes effect within a minute: until then a warm isolate keeps
// accepting the old value and refusing the new one.
//
// Before any of it: a cheap check that the header is there and plausibly shaped (403 otherwise). An optional Edge
// secret HISTORY_CRON_SECRET (≥ 32 characters) is also accepted, compared here in constant time without the database.
export const MIN_SECRET_LENGTH = 32;
export const MAX_TOKEN_LENGTH = 512;
const TOKEN = /^[\x21-\x7e]+$/; // visible ASCII: hex, base64 and the like. Migration 32 and 33 hold the secret to the same rule.

export function plausibleToken(presented: string | null | undefined): presented is string {
  return typeof presented === "string" && presented.length >= MIN_SECRET_LENGTH && presented.length <= MAX_TOKEN_LENGTH &&
    TOKEN.test(presented);
}

async function digest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

// Fixed-length comparison of two 32-byte digests: neither a matching prefix nor where they differ shows in the timing.
function sameDigest(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < 32; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

// The optional Edge-secret path: both values hashed (SHA-256) and the digests compared in constant time, so neither the
// secret's length nor a matching prefix shows in the timing. False without a configured secret of 32+ characters.
export async function cronAuthorized(presented: string | null, secret: string | undefined): Promise<boolean> {
  if (!secret || secret.length < MIN_SECRET_LENGTH || presented === null) return false;
  const [a, b] = await Promise.all([digest(presented), digest(secret)]);
  return sameDigest(a, b);
}

// The database's answer: the Vault secret's SHA-256 (32 bytes), "none" when there is no usable secret (missing, or not
// 32–512 visible ASCII characters, or Vault unreadable), or null when it could not be asked (an error, a timeout, an
// answer that is not a digest).
export type VaultDigest = Uint8Array | "none";
export type DigestFetch = () => Promise<VaultDigest | null>;

type RpcResult = { data: unknown; error: unknown };
type RpcBuilder = PromiseLike<RpcResult> & { abortSignal?: (signal: AbortSignal) => PromiseLike<RpcResult> };
export type RpcClient = { rpc(fn: string, args: Record<string, unknown>): RpcBuilder };

const HEX_DIGEST = /^[0-9a-f]{64}$/;

// history_cron_digest over PostgREST (supabase-js rpc: a POST, no arguments). Only 64 lowercase hex characters are a
// digest; null is "none"; anything else, an error or a thrown call is "could not ask" (the caller answers 503, never 202).
export function vaultDigest(client: RpcClient, timeoutMs = 5_000): DigestFetch {
  return async () => {
    try {
      const builder = client.rpc("history_cron_digest", {});
      const { data, error } = await (builder.abortSignal ? builder.abortSignal(AbortSignal.timeout(timeoutMs)) : builder);
      if (error) return null;
      if (data === null) return "none";
      if (typeof data !== "string" || !HEX_DIGEST.test(data)) return null;
      const bytes = new Uint8Array(32);
      for (let i = 0; i < 32; i++) bytes[i] = parseInt(data.slice(2 * i, 2 * i + 2), 16);
      return bytes;
    } catch {
      return null;
    }
  };
}

export type GateVerdict = "ok" | "denied" | "unavailable";

// One per isolate (index.ts). Holds the Vault digest, never a header.
export class CronGate {
  private cached: { value: VaultDigest; until: number } | null = null;
  private retryAt = 0;
  private pending: Promise<VaultDigest | null> | null = null;
  // Fetches started (a test reads it): at most one per `keepMs` while the database answers, one per `retryMs` while not.
  fetches = 0;

  constructor(readonly keepMs = 60_000, readonly keepNoneMs = 15_000, readonly retryMs = 5_000) {}

  private vault(fetch: DigestFetch, now: number): Promise<VaultDigest | null> {
    if (this.cached && this.cached.until > now) return Promise.resolve(this.cached.value);
    if (this.pending) return this.pending;
    if (now < this.retryAt) return Promise.resolve(null);
    this.fetches++;
    const p = fetch().then((value) => {
      if (value === null) {
        this.cached = null;
        this.retryAt = now + this.retryMs;
      } else {
        this.cached = { value, until: now + (value === "none" ? this.keepNoneMs : this.keepMs) };
      }
      return value;
    }, () => {
      this.retryAt = now + this.retryMs;
      return null;
    }).finally(() => {
      if (this.pending === p) this.pending = null;
    });
    this.pending = p;
    return p;
  }

  async authorize(presented: string | null, envSecret: string | undefined, fetch: DigestFetch, now: number): Promise<GateVerdict> {
    if (!plausibleToken(presented)) return "denied";
    const given = await digest(presented);
    if (envSecret && envSecret.length >= MIN_SECRET_LENGTH && sameDigest(given, await digest(envSecret))) return "ok";
    const wanted = await this.vault(fetch, now);
    if (wanted === null) return "unavailable";
    if (wanted === "none") return "denied";
    return sameDigest(given, wanted) ? "ok" : "denied";
  }
}
