import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";

Deno.env.set("LITE_JWT_SECRET", "test-secret-test-secret-test-secret-0123456789");
Deno.env.set("LITE_NETWORK", "testnet");

const { challengeMessage, SEP53_PREFIX, sha256, signJwt, verifyJwt, verifySep53 } = await import("../../supabase/functions/_shared/auth.ts");
const { encodeApprove, encodeDepositForBurnWithHook, encodeReceiveMessage, evmToBytes32, forwarderHookData } = await import("../../supabase/functions/_shared/bridge.ts");
const { Router, json, amountArg } = await import("../../supabase/functions/_shared/http.ts");

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

Deno.test("CCTP encoders: selectors, hook data layout, dynamic bytes", () => {
  assertEquals(encodeApprove("0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", 5n).slice(0, 10), "0x095ea7b3");
  const hook = forwarderHookData("GAXNIIDVUIDR2YEE64BMR5JUFB4KYI627PWFXWHUWLU3Q2SSUFLLQUSE");
  assertEquals(hook.length, 32 + 56);
  assert(hook.slice(0, 24).every((b) => b === 0));
  assertEquals(new DataView(hook.buffer).getUint32(28), 56);
  assertEquals(new TextDecoder().decode(hook.slice(32)), "GAXNIIDVUIDR2YEE64BMR5JUFB4KYI627PWFXWHUWLU3Q2SSUFLLQUSE");
  const data = encodeDepositForBurnWithHook({ amount: 1n, destinationDomain: 27, mintRecipient: new Uint8Array(32).fill(1), burnToken: "0x534b2f3A21130d7a60830c2Df862319e593943A3", destinationCaller: new Uint8Array(32).fill(1), maxFee: 0n, minFinalityThreshold: 2000, hookData: hook });
  assertEquals(data.slice(0, 10), "0x779b432d");
  // 8 head words + length word + 3 data words (88 bytes padded to 96)
  assertEquals((data.length - 10) / 64, 8 + 1 + 3);
  const rm = encodeReceiveMessage(new Uint8Array(5), new Uint8Array(65));
  assertEquals(rm.slice(0, 10), "0x57ecfd28");
  assertEquals(evmToBytes32("0x000000000000000000000000000000000000dEaD")[31], 0xad);
});

Deno.test("router: params, prefix-agnostic, 404", async () => {
  const r = new Router().on("GET /v1/launches/:token", ({ params }) => Promise.resolve(json({ token: params.token })));
  const ok = await r.handle(new Request("http://x/functions/v1/lite/v1/launches/CABC"));
  assertEquals((await ok.json()).token, "CABC");
  assertEquals((await r.handle(new Request("http://x/lite/v1/nope"))).status, 404);
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
