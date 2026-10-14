// deno test --no-config --node-modules-dir=none -A supabase/functions/history-indexer/
import { assertEquals } from "jsr:@std/assert@1";
import { CronGate, cronAuthorized, plausibleToken, type RpcClient, vaultDigest } from "./auth.ts";

const SECRET = "s".repeat(20) + "-cron-header-value-48"; // 41 characters, a test value
const VAULT = "0123456789abcdef".repeat(4);                // the shape migration 33 generates (a test value)

Deno.test("cronAuthorized (the optional Edge secret): only the exact header, and only with a configured secret of 32+ characters", async () => {
  assertEquals(await cronAuthorized(SECRET, SECRET), true);
  assertEquals(await cronAuthorized(SECRET + " ", SECRET), false);
  assertEquals(await cronAuthorized(SECRET.toUpperCase(), SECRET), false);
  assertEquals(await cronAuthorized("", SECRET), false);
  assertEquals(await cronAuthorized(null, SECRET), false);
  // A prefix of the secret (what an attacker learning it byte by byte would send) is refused like anything else.
  assertEquals(await cronAuthorized(SECRET.slice(0, 32), SECRET), false);
  assertEquals(await cronAuthorized(SECRET.slice(0, -1), SECRET), false);
  // No secret, or a short one, refuses everything — even a header equal to it.
  assertEquals(await cronAuthorized("", undefined), false);
  assertEquals(await cronAuthorized("x", ""), false);
  const short = "a".repeat(31);
  assertEquals(await cronAuthorized(short, short), false);
  assertEquals(await cronAuthorized("a".repeat(32), "a".repeat(32)), true);
});

Deno.test("plausibleToken: present, 32–512 visible ASCII characters — the check before any database call", () => {
  for (const ok of [VAULT, "A".repeat(32), "x".repeat(512), "abcDEF0123+/=".repeat(5)]) assertEquals(plausibleToken(ok), true, ok);
  for (const bad of [null, undefined, "", "a".repeat(31), "x".repeat(513), VAULT.slice(0, 31) + " " + VAULT.slice(32), VAULT + "\n", "é".repeat(40)]) {
    assertEquals(plausibleToken(bad), false, String(bad).slice(0, 20));
  }
});

// The digest migration 32's history_cron_digest() answers for a secret: SHA-256, 64 lowercase hex characters.
async function hexDigest(value: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return Array.from(d, (b) => b.toString(16).padStart(2, "0")).join("");
}
async function bytesDigest(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

// A fake database: counts the fetches, answers with `answer()` (the current secret's digest, "none", or null).
function fakeVault(answer: () => Promise<Uint8Array | "none" | null>) {
  const state = { fetches: 0 };
  return { state, fetch: async () => { state.fetches++; return await answer(); } };
}

Deno.test("CronGate: the header compared with the Vault digest; the digest fetched once a minute; no header ever sent to the database", async () => {
  const T0 = Date.parse("2026-10-09T12:00:00Z");
  const g = new CronGate();
  const vault = fakeVault(() => bytesDigest(VAULT));
  // The cheap check: no fetch for an implausible header.
  for (const bad of [null, "", "short", "x".repeat(600), VAULT.slice(0, 40) + " " + VAULT.slice(41)]) {
    assertEquals(await g.authorize(bad, undefined, vault.fetch, T0), "denied");
  }
  assertEquals(vault.state.fetches, 0);
  // The Vault secret: one fetch, then the kept digest until a minute has passed.
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0), "ok");
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + 30_000), "ok");
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + 59_999), "ok");
  assertEquals(vault.state.fetches, 1);
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + 60_000), "ok");
  assertEquals(vault.state.fetches, 2);
  // Near misses: refused, and they cost no fetch.
  for (const wrong of [VAULT.slice(0, 63) + "0", VAULT.toUpperCase(), VAULT.slice(0, 32), VAULT + VAULT, "x".repeat(64)]) {
    assertEquals(await g.authorize(wrong, undefined, vault.fetch, T0 + 60_001), "denied", wrong.slice(0, 20));
  }
  assertEquals(vault.state.fetches, 2);
  // The optional Edge secret is accepted without the database; a wrong header with it configured still compares with Vault.
  const env = fakeVault(async () => "none");
  assertEquals(await new CronGate().authorize(SECRET, SECRET, env.fetch, T0), "ok");
  assertEquals(env.state.fetches, 0);
  assertEquals(await new CronGate().authorize(SECRET, "short", env.fetch, T0), "denied");
  assertEquals(await new CronGate().authorize(VAULT, SECRET, env.fetch, T0), "denied");
  assertEquals(env.state.fetches, 2);
});

Deno.test("CronGate: a flood of wrong headers never locks the cron tick out and never loads the database", async () => {
  const T0 = Date.parse("2026-10-09T12:00:00Z");
  const g = new CronGate();
  const vault = fakeVault(() => bytesDigest(VAULT));
  // Ten minutes of 20 wrong headers a second (every one plausibly shaped), with the real tick every 30 s — from a cold
  // isolate, so the first fetch may be started by the flood.
  let fetchesAtMost = 0;
  for (let ms = 0; ms <= 600_000; ms += 50) {
    assertEquals(await g.authorize("g".repeat(40) + ms, undefined, vault.fetch, T0 + ms), "denied");
    if (ms % 30_000 === 0) assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + ms), "ok", `the tick at ${ms} ms`);
    fetchesAtMost = Math.floor(ms / 60_000) + 1;
  }
  assertEquals(vault.state.fetches, fetchesAtMost, "one fetch a minute, whatever the traffic");
  // A concurrent burst on a cold isolate: one fetch, shared by every request.
  const cold = new CronGate();
  const slow = fakeVault(async () => { await new Promise((r) => setTimeout(r, 20)); return bytesDigest(VAULT); });
  const verdicts = await Promise.all([
    ...Array.from({ length: 500 }, (_, k) => cold.authorize("h".repeat(40) + k, undefined, slow.fetch, T0)),
    cold.authorize(VAULT, undefined, slow.fetch, T0),
  ]);
  assertEquals(slow.state.fetches, 1);
  assertEquals(verdicts.filter((v) => v === "denied").length, 500);
  assertEquals(verdicts[500], "ok");
});

Deno.test("CronGate: a database that cannot be asked is 503 and retried every 5 s; no secret refuses all; rotation within a minute", async () => {
  const T0 = Date.parse("2026-10-09T12:00:00Z");
  let answer: Uint8Array | "none" | null = null;
  const vault = fakeVault(async () => answer);
  const g = new CronGate();
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0), "unavailable");
  for (let ms = 1; ms < 5_000; ms += 100) assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + ms), "unavailable");
  assertEquals(vault.state.fetches, 1, "no new fetch inside the 5 s");
  // A thrown fetch is the same.
  const thrown = new CronGate();
  assertEquals(await thrown.authorize(VAULT, undefined, () => Promise.reject(new Error("network")), T0), "unavailable");
  // The database answers again: the next request after 5 s fetches and passes.
  answer = await bytesDigest(VAULT);
  assertEquals(await g.authorize(VAULT, undefined, vault.fetch, T0 + 5_000), "ok");
  assertEquals(vault.state.fetches, 2);
  // No usable secret ("none"): every header refused; asked again after 15 s (migration 33 applied meanwhile).
  const n = new CronGate();
  answer = "none";
  assertEquals(await n.authorize(VAULT, undefined, vault.fetch, T0), "denied");
  answer = await bytesDigest(VAULT);
  assertEquals(await n.authorize(VAULT, undefined, vault.fetch, T0 + 14_999), "denied");
  assertEquals(await n.authorize(VAULT, undefined, vault.fetch, T0 + 15_000), "ok");
  // Rotation: the old value still passes, the new one is refused, until the kept digest is a minute old; then the reverse.
  const NEW = "fedcba9876543210".repeat(4);
  const r = new CronGate();
  answer = await bytesDigest(VAULT);
  assertEquals(await r.authorize(VAULT, undefined, vault.fetch, T0), "ok");
  answer = await bytesDigest(NEW); // the owner rotated
  assertEquals(await r.authorize(VAULT, undefined, vault.fetch, T0 + 59_000), "ok");
  assertEquals(await r.authorize(NEW, undefined, vault.fetch, T0 + 59_000), "denied");
  assertEquals(await r.authorize(VAULT, undefined, vault.fetch, T0 + 60_000), "denied");
  assertEquals(await r.authorize(NEW, undefined, vault.fetch, T0 + 60_000), "ok");
});

Deno.test("vaultDigest: history_cron_digest with no arguments; only 64 lowercase hex characters are a digest; errors are 'could not ask'", async () => {
  const sent: { fn: string; args: Record<string, unknown>; aborted: boolean }[] = [];
  const client = (result: { data: unknown; error: unknown } | "throw"): RpcClient => ({
    rpc(fn, args) {
      const entry = { fn, args, aborted: false };
      sent.push(entry);
      const run = () => (result === "throw" ? Promise.reject(new Error("network")) : Promise.resolve(result));
      return { then: (ok, ko) => run().then(ok, ko), abortSignal: (_s: AbortSignal) => { entry.aborted = true; return run(); } };
    },
  });
  const hex = await hexDigest(VAULT);
  assertEquals(await vaultDigest(client({ data: hex, error: null }))(), await bytesDigest(VAULT));
  assertEquals(sent[0], { fn: "history_cron_digest", args: {}, aborted: true });
  assertEquals(await vaultDigest(client({ data: null, error: null }))(), "none");
  for (const odd of [hex.toUpperCase(), hex.slice(0, 63), hex + "0", "\\x" + hex, true, 1, { hex }]) {
    assertEquals(await vaultDigest(client({ data: odd, error: null }))(), null, String(odd).slice(0, 20));
  }
  assertEquals(await vaultDigest(client({ data: null, error: { code: "PGRST202", message: "not found" } }))(), null);
  assertEquals(await vaultDigest(client("throw"))(), null);
});
