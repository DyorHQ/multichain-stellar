// deno test --no-config --node-modules-dir=none supabase/functions/wallet-auth/
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { decodeProtectedHeader, exportJWK, generateKeyPair, jwtVerify } from "npm:jose@5";
import { v5 as uuidv5 } from "npm:uuid@9";
import { MIN_SESSION_S, mintSession, SESSION_S, sessionLifetime, sessionSigner } from "./session.ts";

const WALLET = "0x" + "ab".repeat(20);
const NOW_S = 1_790_000_000;

Deno.test("HS256 with APP_JWT_SECRET when no signing JWK is configured (unchanged default)", async () => {
  const secret = "test-secret-" + "x".repeat(32);
  const signer = await sessionSigner({ secret });
  assertEquals(signer?.alg, "HS256");
  const token = await mintSession(WALLET, signer!, NOW_S);
  assertEquals(decodeProtectedHeader(token), { alg: "HS256", typ: "JWT" });
  const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), { audience: "authenticated", currentDate: new Date(NOW_S * 1000) });
  assertEquals(payload.role, "authenticated");
  assertEquals(payload.wallet_address, WALLET);
  assertEquals(payload.exp! - payload.iat!, SESSION_S);
  // The same per-wallet sub as before the signer was split out (storage owner ids depend on it).
  assertEquals(payload.sub, uuidv5(WALLET, "6f9b1c2e-1c2a-4b6e-9c3d-0a1b2c3d4e5f"));
});

Deno.test("ES256 with APP_JWT_SIGNING_JWK: kid in the header, verifiable with the public key, preferred over the secret", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const jwk = { ...(await exportJWK(privateKey)), kid: "3a18cfe2-7226-43b0-bbb4-7c5242f2406e", key_ops: ["sign", "verify"], ext: true };
  const signer = await sessionSigner({ jwk: JSON.stringify(jwk), secret: "ignored" });
  assertEquals(signer?.alg, "ES256");
  const token = await mintSession(WALLET, signer!, NOW_S);
  assertEquals(decodeProtectedHeader(token), { alg: "ES256", kid: jwk.kid, typ: "JWT" });
  const { payload } = await jwtVerify(token, publicKey, { audience: "authenticated", currentDate: new Date(NOW_S * 1000) });
  assertEquals([payload.role, payload.wallet_address], ["authenticated", WALLET]);
});

Deno.test("a malformed signing JWK is refused, never silently replaced by the secret", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const priv = await exportJWK(privateKey);
  for (const bad of [
    "not json",
    JSON.stringify({ ...priv }), // no kid
    JSON.stringify({ ...(await exportJWK(publicKey)), kid: "k" }), // public key only
    JSON.stringify({ ...priv, kid: "k", crv: "P-384" }),
    JSON.stringify({ ...priv, kid: "has space" }),
  ]) {
    await assertRejects(() => sessionSigner({ jwk: bad, secret: "fallback" }), Error, "APP_JWT_SIGNING_JWK");
  }
  assertEquals(await sessionSigner({}), null);
});

Deno.test("SB-10: WALLET_AUTH_SESSION_S shortens the session, within [15 min, 12 h]; 12 h by default", async () => {
  assertEquals(SESSION_S, 12 * 60 * 60);
  assertEquals(sessionLifetime(undefined), SESSION_S);
  assertEquals(sessionLifetime(""), SESSION_S);
  assertEquals(sessionLifetime("two hours"), SESSION_S);
  assertEquals(sessionLifetime("7200.5"), SESSION_S);
  assertEquals(sessionLifetime("7200"), 7200);
  assertEquals(sessionLifetime("60"), MIN_SESSION_S);
  assertEquals(sessionLifetime("100000"), SESSION_S);
  const secret = "test-secret-" + "x".repeat(32);
  const token = await mintSession(WALLET, (await sessionSigner({ secret }))!, NOW_S, 7200);
  const { payload } = await jwtVerify(token, new TextEncoder().encode(secret), { audience: "authenticated", currentDate: new Date(NOW_S * 1000) });
  assertEquals(payload.exp! - payload.iat!, 7200);
});
