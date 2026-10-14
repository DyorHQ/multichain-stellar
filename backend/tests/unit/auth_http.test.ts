import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

Deno.env.set("LITE_JWT_SECRET", "test-secret-test-secret-test-secret-0123456789");
Deno.env.set("LITE_NETWORK", "testnet");
for (const name of ["LITE_INVITE_REQUIRED", "LITE_JWT_TTL_S", "LITE_REFRESH_TTL_S"]) Deno.env.delete(name);

const { challengeMessage, createChallenge, hex, SEP53_PREFIX, sha256, signJwt, verifyChallenge, verifyJwt, verifySep53 } = await import("../../supabase/functions/_shared/auth.ts");
const { ApiError, Router, json, amountArg } = await import("../../supabase/functions/_shared/http.ts");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { fakeSql } = await import("../fixtures/routes/harness.ts");

Deno.test("SEP-53: a signature over the prefixed hash verifies; anything else doesn't", async () => {
  const kp = Keypair.random();
  const msg = challengeMessage("testnet", kp.publicKey(), "nonce123", "2026-10-11T00:00:00Z");
  const sig = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + msg))).toString("base64");
  assert(await verifySep53(kp.publicKey(), msg, sig));
  assert(!(await verifySep53(kp.publicKey(), msg + "x", sig)));
  assert(!(await verifySep53(Keypair.random().publicKey(), msg, sig)));
  // A raw signature over the message (no SEP-53 prefix) is refused.
  const raw = kp.sign(Buffer.from(msg)).toString("base64");
  assert(!(await verifySep53(kp.publicKey(), msg, raw)));
});

Deno.test("JWT: round trip, expiry, tampering, audience", async () => {
  const now = Math.floor(Date.now() / 1000);
  const t = await signJwt({ sub: "GABC", aud: "dyorhq-lite", net: "testnet", exp: now + 60 });
  assertEquals((await verifyJwt(t)).sub, "GABC");
  await assertRejects(async () => verifyJwt(await signJwt({ sub: "G", aud: "dyorhq-lite", net: "testnet", exp: now - 1 })));
  await assertRejects(async () => verifyJwt(await signJwt({ sub: "G", aud: "other", net: "testnet", exp: now + 60 })));
  await assertRejects(async () => verifyJwt(await signJwt({ sub: "G", aud: "dyorhq-lite", net: "mainnet", exp: now + 60 })));
  const [h, b, s] = t.split(".");
  const forged = btoa(JSON.stringify({ sub: "GEVIL", aud: "dyorhq-lite", net: "testnet", exp: now + 60 })).replace(/=+$/, "");
  await assertRejects(() => verifyJwt(`${h}.${forged}.${s}`));
  void b;
});

Deno.test("router: params, prefix-agnostic, 404", async () => {
  const r = new Router().on("GET /v1/launches/:token", ({ params }) => Promise.resolve(json({ token: params.token })));
  const ok = await r.handle(new Request("http://x/functions/v1/lite/v1/launches/CABC"));
  assertEquals((await ok.json()).token, "CABC");
  assertEquals((await r.handle(new Request("http://x/lite/v1/nope"))).status, 404);
});

Deno.test("router: a trailing *name takes the rest of the path, one segment or more", async () => {
  const r = new Router().on("GET /v1/files/*path", ({ params }) => Promise.resolve(json({ path: params.path })));
  const ok = await r.handle(new Request("http://x/lite/v1/files/uploads/GABC/a%20b.jpg"));
  assertEquals((await ok.json()).path, "uploads/GABC/a b.jpg");
  assertEquals((await r.handle(new Request("http://x/lite/v1/files"))).status, 404);
  // No segment may step out of the directory or smuggle a separator.
  for (const bad of ["uploads/../secrets", "uploads/%2E%2E/x", "uploads/a%2Fb"]) {
    assertEquals(r.match("GET", `/lite/v1/files/${bad}`), null, bad);
  }
});

Deno.test("router: the check runs after the match and before the handler, and can answer instead", async () => {
  const seen: string[] = [];
  const r = new Router()
    .before((req, route) => {
      seen.push(route);
      if (!req.headers.get("authorization")) return Promise.reject(new ApiError(401, "unauthorized", "Sign in."));
      return Promise.resolve();
    })
    .on("GET /v1/launches/:token", ({ params }) => Promise.resolve(json({ token: params.token })));
  assertEquals((await r.handle(new Request("http://x/lite/v1/launches/CABC"))).status, 401);
  assertEquals((await (await r.handle(new Request("http://x/lite/v1/launches/CABC", { headers: { authorization: "Bearer t" } }))).json()).token, "CABC");
  assertEquals((await r.handle(new Request("http://x/lite/v1/nope"))).status, 404);
  assertEquals(seen, ["GET /v1/launches/:token", "GET /v1/launches/:token"]);
  assertEquals(r.specs, ["GET /v1/launches/:token"]);
});

Deno.test("amounts are whole base units in strings", () => {
  assertEquals(amountArg("10000000", "a"), 10_000_000n);
  for (const bad of ["1.5", "-1", "0", 5, "abc", ""]) {
    try {
      amountArg(bad, "a");
      throw new Error(`accepted ${bad}`);
    } catch (e) {
      assertEquals((e as { code?: string }).code, "bad_amount");
    }
  }
});

// ------------------------------------------------------------------------------------------------ sign-in answers
// docs/DESIGN-stellar-parity.md §5.9, §6.18: verify answers an hour's access token and a refresh token that starts a
// family, stored only as its SHA-256. The database is a stand-in that knows one existing tester.

/** The stand-in database behind a sign-in; `migrated`: lite.auth_refresh exists (migration 12). Answers what was
 *  stored in it. */
function signInDb(migrated: boolean): { refresh: unknown[][]; params: unknown[] } {
  const nonces = new Map<string, string>();
  const refresh: unknown[][] = [];
  const params: unknown[] = [];
  replaceSql(fakeSql((q, ps) => {
    params.push(...ps);
    if (q.startsWith("insert into lite.auth_nonces")) {
      nonces.set(ps[0] as string, ps[2] as string);
      return [];
    }
    if (q.startsWith("update lite.auth_nonces set used_at")) {
      const message = nonces.get(ps[0] as string);
      nonces.delete(ps[0] as string);
      return message ? [{ message }] : [];
    }
    if (q === "select address, label, revoked_at from lite.testers where address = ?") return [{ address: ps[0], label: "Internal QA", revoked_at: null }];
    if (q === "select to_regclass(?) is not null as present") return [{ present: migrated }];
    if (q.startsWith("insert into lite.auth_refresh (family, address, token_hash, expires_at) values")) {
      refresh.push(ps);
      return [];
    }
    throw new Error(`unexpected query: ${q}`);
  }));
  return { refresh, params };
}

async function signIn(kp: Keypair) {
  const ch = await createChallenge(kp.publicKey());
  const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
  return await verifyChallenge({ address: kp.publicKey(), nonce: ch.nonce, signature });
}

const fixture = async (name: string) => JSON.parse(await Deno.readTextFile(new URL(`../fixtures/api/${name}.json`, import.meta.url)));
const claimsOf = (jwt: string) => JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")));
const near = (iso: string, ms: number) => Math.abs(new Date(iso).getTime() - (Date.now() + ms)) < 5_000;

Deno.test("verify: an hour's access token and a 30-day refresh token, stored only as its SHA-256", async () => {
  const db = signInDb(true);
  const kp = Keypair.random();
  const v = await signIn(kp);
  assertEquals(Object.keys(v), Object.keys(await fixture("auth-verify")));
  const claims = claimsOf(v.token);
  assertEquals([claims.sub, claims.exp - claims.iat], [kp.publicKey(), 3600]);
  assertEquals(v.expiresAt, new Date(claims.exp * 1000).toISOString());
  assertEquals((await verifyJwt(v.token)).sub, kp.publicKey());
  assertEquals(v.tester, { address: kp.publicKey(), label: "Internal QA" });
  assert(/^lrt_[A-Za-z0-9_-]{43}$/.test(v.refreshToken!), v.refreshToken);
  assert(near(v.refreshExpiresAt!, 30 * 86_400_000), v.refreshExpiresAt);
  // One row: a new family, this address, the token's hash; the token itself was never sent to the database.
  assertEquals(db.refresh.length, 1);
  const [family, address, hash, expires] = db.refresh[0];
  assert(/^[0-9a-f-]{36}$/.test(family as string));
  assertEquals([address, hash, (expires as Date).toISOString()], [kp.publicKey(), hex(await sha256(v.refreshToken!)), v.refreshExpiresAt]);
  assert(!db.params.some((p) => typeof p === "string" && p.includes(v.refreshToken!.slice(4))), "the refresh token reached the database");
  // Each sign-in starts its own family with a token of its own.
  const again = await signIn(kp);
  assert(again.refreshToken !== v.refreshToken);
  assert(db.refresh[1][0] !== family);
});

Deno.test("verify before migration 12: the older answer, without a refresh token", async () => {
  const db = signInDb(false);
  const v = await signIn(Keypair.random());
  assertEquals(Object.keys(v), Object.keys(await fixture("auth-verify.legacy")));
  const claims = claimsOf(v.token);
  assertEquals(claims.exp - claims.iat, 3600);
  assertEquals(db.refresh, []);
});

Deno.test("LITE_JWT_TTL_S and LITE_REFRESH_TTL_S shorten both lifetimes on testnet", async () => {
  Deno.env.set("LITE_JWT_TTL_S", "120");
  Deno.env.set("LITE_REFRESH_TTL_S", "600");
  try {
    signInDb(true);
    const v = await signIn(Keypair.random());
    const claims = claimsOf(v.token);
    assertEquals(claims.exp - claims.iat, 120);
    assert(near(v.refreshExpiresAt!, 600_000), v.refreshExpiresAt);
  } finally {
    Deno.env.delete("LITE_JWT_TTL_S");
    Deno.env.delete("LITE_REFRESH_TTL_S");
  }
});
