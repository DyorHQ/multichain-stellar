import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

Deno.env.set("LITE_JWT_SECRET", "test-secret-test-secret-test-secret-0123456789");
Deno.env.set("LITE_NETWORK", "testnet");

const { challengeMessage, SEP53_PREFIX, sha256, signJwt, verifyJwt, verifySep53 } = await import("../../supabase/functions/_shared/auth.ts");
const { ApiError, Router, json, amountArg } = await import("../../supabase/functions/_shared/http.ts");

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
