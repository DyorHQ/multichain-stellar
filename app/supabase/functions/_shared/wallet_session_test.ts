// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { createLocalJWKSet, exportJWK, generateKeyPair, type JWTVerifyGetKey, SignJWT, UnsecuredJWT } from "npm:jose@5";
import { mintSession, sessionSigner } from "../wallet-auth/session.ts";
import { type SessionKeys, sessionKeys, SessionKeysUnavailable, sessionWallet } from "./wallet_session.ts";

const WALLET = "0x" + "ab".repeat(20);
const SECRET = "test-secret-" + "x".repeat(32);
const nowS = () => Math.floor(Date.now() / 1000);

async function es256Keys(kid = "k1") {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const priv = { ...(await exportJWK(privateKey)), kid };
  const pub = { ...(await exportJWK(publicKey)), kid, alg: "ES256", use: "sig" };
  return { privateKey, privateJwk: JSON.stringify(priv), jwks: createLocalJWKSet({ keys: [pub] }) };
}

const hsKeys = (): SessionKeys => ({ secret: new TextEncoder().encode(SECRET), jwks: null });

// A token with arbitrary claims, signed with the test secret (HS256).
function hsToken(claims: Record<string, unknown>, expS: number | null = nowS() + 600, aud = "authenticated") {
  const jwt = new SignJWT(claims).setProtectedHeader({ alg: "HS256", typ: "JWT" }).setAudience(aud).setIssuedAt();
  if (expS !== null) jwt.setExpirationTime(expS);
  return jwt.sign(new TextEncoder().encode(SECRET));
}

Deno.test("SB-9: a wallet-auth session verifies — HS256 with the secret, ES256 with the project's JWKS", async () => {
  const hs = await mintSession(WALLET, (await sessionSigner({ secret: SECRET }))!, nowS());
  assertEquals(await sessionWallet(`Bearer ${hs}`, hsKeys()), WALLET);
  assertEquals(await sessionWallet(`bearer   ${hs} `, hsKeys()), WALLET);
  const { privateJwk, jwks } = await es256Keys();
  const es = await mintSession(WALLET, (await sessionSigner({ jwk: privateJwk }))!, nowS());
  assertEquals(await sessionWallet(`Bearer ${es}`, { secret: null, jwks }), WALLET);
});

Deno.test("SB-9: anything but a valid, unexpired wallet session is not one", async () => {
  const keys = hsKeys();
  const expired = await mintSession(WALLET, (await sessionSigner({ secret: SECRET }))!, nowS() - 13 * 3600);
  const otherSecret = await mintSession(WALLET, (await sessionSigner({ secret: SECRET + "?" }))!, nowS());
  const cases: Record<string, string | null> = {
    "no header": null,
    "empty": "",
    "not a JWT": "Bearer nope",
    "publishable key": "Bearer sb_publishable_xxxxxxxxxxxxxxxx",
    "expired": `Bearer ${expired}`,
    "another secret": `Bearer ${otherSecret}`,
    "anon role": `Bearer ${await hsToken({ role: "anon" })}`,
    "service role": `Bearer ${await hsToken({ role: "service_role", wallet_address: WALLET })}`,
    "no wallet": `Bearer ${await hsToken({ role: "authenticated" })}`,
    "malformed wallet": `Bearer ${await hsToken({ role: "authenticated", wallet_address: "0x1234" })}`,
    "other audience": `Bearer ${await hsToken({ role: "authenticated", wallet_address: WALLET }, nowS() + 600, "anon")}`,
    "no exp": `Bearer ${await hsToken({ role: "authenticated", wallet_address: WALLET }, null)}`,
    "alg none": `Bearer ${new UnsecuredJWT({ role: "authenticated", wallet_address: WALLET, aud: "authenticated", exp: nowS() + 600 }).encode()}`,
  };
  for (const [name, header] of Object.entries(cases)) {
    assertEquals(await sessionWallet(header, keys), null, name);
  }
  // An ES256 token signed by a key the project does not publish (another project, or forged).
  const ours = await es256Keys("ours");
  const theirs = await es256Keys("theirs");
  const foreign = await mintSession(WALLET, (await sessionSigner({ jwk: theirs.privateJwk }))!, nowS());
  assertEquals(await sessionWallet(`Bearer ${foreign}`, { secret: null, jwks: ours.jwks }), null);
  // The same kid as ours, but not our key.
  const impostor = await es256Keys("ours");
  const forged = await mintSession(WALLET, (await sessionSigner({ jwk: impostor.privateJwk }))!, nowS());
  assertEquals(await sessionWallet(`Bearer ${forged}`, { secret: null, jwks: ours.jwks }), null);
});

Deno.test("SB-9: without APP_JWT_SECRET no HS256 token is a session (the state after the move to an ES256 key)", async () => {
  const hs = await mintSession(WALLET, (await sessionSigner({ secret: SECRET }))!, nowS());
  assertEquals(await sessionWallet(`Bearer ${hs}`, { secret: null, jwks: null }), null);
});

Deno.test("SB-9: an unreachable or unset JWKS is an outage (503), never 'not signed in'", async () => {
  const { privateJwk } = await es256Keys();
  const es = await mintSession(WALLET, (await sessionSigner({ jwk: privateJwk }))!, nowS());
  await assertRejects(() => sessionWallet(`Bearer ${es}`, { secret: null, jwks: null }), SessionKeysUnavailable);
  const unreachable: JWTVerifyGetKey = () => Promise.reject(new TypeError("error sending request"));
  await assertRejects(() => sessionWallet(`Bearer ${es}`, { secret: null, jwks: unreachable }), SessionKeysUnavailable);
  const timedOut: JWTVerifyGetKey = () => Promise.reject(Object.assign(new Error("request timed out"), { code: "ERR_JWKS_TIMEOUT" }));
  await assertRejects(() => sessionWallet(`Bearer ${es}`, { secret: null, jwks: timedOut }), SessionKeysUnavailable);
});

Deno.test("sessionKeys: from APP_JWT_SECRET and SUPABASE_URL, each optional", () => {
  const env = (vars: Record<string, string>) => ({ get: (name: string) => vars[name] });
  assertEquals(sessionKeys(env({})), { secret: null, jwks: null });
  const keys = sessionKeys(env({ APP_JWT_SECRET: SECRET, SUPABASE_URL: "https://example.supabase.co" }));
  assertEquals(keys.secret, new TextEncoder().encode(SECRET));
  assertEquals(typeof keys.jwks, "function");
});
