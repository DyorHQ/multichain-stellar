// deno test --no-config --node-modules-dir=none -A supabase/functions/aurora-proxy/
import { assertEquals } from "jsr:@std/assert@1";
import { appFee, quoteBody, REFERRAL, submitBody, upstreamError } from "./request.ts";

const WALLET = "0x" + "ab".repeat(20);
const CHECKSUMMED = "0x" + "aB".repeat(20);
// Exactly what AuroraIntents.quote sends (with an app fee, as a build with AuroraFeeRecipient would).
const appQuote = (over: Record<string, unknown> = {}) => JSON.stringify({
  dry: false, swapType: "EXACT_INPUT", depositType: "ORIGIN_CHAIN", amount: "1000000",
  originAsset: "nep245:v2_1.omni.hot.tg:143_abc", destinationAsset: "nep245:v2_1.omni.hot.tg:8453_def",
  slippageTolerance: 100, refundTo: CHECKSUMMED, refundType: "ORIGIN_CHAIN", recipient: CHECKSUMMED,
  recipientType: "DESTINATION_CHAIN", referral: "dyorhq", appFees: [{ recipient: "someone.near", fee: 10 }], ...over,
});

Deno.test("SB-2: the app's quote is forwarded without appFees, with DyorHQ's referral, and nothing else added", () => {
  const out = quoteBody(appQuote({ referral: "attacker", extra: "x" }), WALLET);
  assertEquals("body" in out, true);
  assertEquals(JSON.parse((out as { body: string }).body), {
    swapType: "EXACT_INPUT", depositType: "ORIGIN_CHAIN", amount: "1000000",
    originAsset: "nep245:v2_1.omni.hot.tg:143_abc", destinationAsset: "nep245:v2_1.omni.hot.tg:8453_def",
    slippageTolerance: 100, refundTo: CHECKSUMMED, refundType: "ORIGIN_CHAIN", recipient: CHECKSUMMED,
    recipientType: "DESTINATION_CHAIN", referral: REFERRAL, dry: false,
  });
});

Deno.test("SB-2: DyorHQ's fee comes from the server, never from the caller", () => {
  const fee = { recipient: "dyorhq-fees.near", fee: 10 };
  const out = JSON.parse((quoteBody(appQuote({ appFees: [{ recipient: "attacker.near", fee: 1000 }] }), WALLET, fee) as { body: string }).body);
  assertEquals(out.appFees, [{ recipient: "dyorhq-fees.near", fee: 10 }]);
  assertEquals(out.referral, REFERRAL);
  const none = JSON.parse((quoteBody(appQuote(), WALLET, null) as { body: string }).body);
  assertEquals("appFees" in none, false);
});

Deno.test("appFee: a NEAR account and 1–100 bps (default 10) from the environment, else none or invalid", () => {
  assertEquals(appFee(undefined, undefined), null);
  assertEquals(appFee("  ", "25"), null);
  assertEquals(appFee("dyorhq.near", undefined), { recipient: "dyorhq.near", fee: 10 });
  assertEquals(appFee(" fees_1.dyorhq.near ", "25"), { recipient: "fees_1.dyorhq.near", fee: 25 });
  assertEquals(appFee("a".repeat(64), ""), { recipient: "a".repeat(64), fee: 10 });
  for (const [recipient, bps] of [["Dyorhq.near", "10"], ["x", "10"], ["a".repeat(65), "10"], ["bad..near", "10"],
                                  [".near", "10"], ["ok.near", "0"], ["ok.near", "101"], ["ok.near", "1.5"], ["ok.near", "ten"]]) {
    assertEquals(appFee(recipient, bps), "invalid", `${recipient} ${bps}`);
  }
});

Deno.test("SB-2: recipient and refundTo must both be the session's wallet", () => {
  const other = "0x" + "cd".repeat(20);
  for (const over of [{ recipient: other }, { refundTo: other }, { recipient: undefined }, { refundTo: 5 }]) {
    assertEquals((quoteBody(appQuote(over), WALLET) as { status: number }).status, 403, JSON.stringify(over));
  }
});

Deno.test("quote shape: the app's deposit/refund/recipient types, integer amount, bps slippage", () => {
  for (const over of [
    { depositType: "INTENTS" }, { refundType: "INTENTS" }, { recipientType: "INTENTS" }, { amount: "1.5" }, { amount: 5 },
    { amount: "" }, { slippageTolerance: -1 }, { slippageTolerance: 10_001 }, { slippageTolerance: 1.5 }, { dry: "no" },
    { originAsset: "" }, { destinationAsset: "x".repeat(257) }, { swapType: undefined },
  ]) {
    assertEquals((quoteBody(appQuote(over), WALLET) as { status: number }).status, 400, JSON.stringify(over));
  }
  assertEquals((quoteBody("[]", WALLET) as { status: number }).status, 400);
  assertEquals((quoteBody("nope", WALLET) as { status: number }).status, 400);
});

Deno.test("deposit/submit forwards only txHash, depositAddress and memo", () => {
  const out = submitBody(JSON.stringify({ txHash: "0x" + "1".repeat(64), depositAddress: "0xdep", memo: null, appFees: [1] }));
  assertEquals(JSON.parse((out as { body: string }).body), { txHash: "0x" + "1".repeat(64), depositAddress: "0xdep" });
  const withMemo = submitBody(JSON.stringify({ txHash: "h", depositAddress: "d", memo: "m" }));
  assertEquals(JSON.parse((withMemo as { body: string }).body), { txHash: "h", depositAddress: "d", memo: "m" });
  for (const bad of [{}, { txHash: "h" }, { txHash: "h", depositAddress: 1 }, { txHash: "h", depositAddress: "d", memo: 7 }]) {
    assertEquals((submitBody(JSON.stringify(bad)) as { status: number }).status, 400, JSON.stringify(bad));
  }
});

Deno.test("SB-11: upstream errors keep Aurora's short message only, scrubbed", () => {
  const scrub = (s: string) => s.split("SECRETKEY").join("[redacted]");
  assertEquals(upstreamError(JSON.stringify({ message: "Amount too low", stack: "at x" }), 400, scrub),
    { body: { error: "Amount too low" }, status: 400 });
  assertEquals(upstreamError(JSON.stringify({ message: "bad path /quote/SECRETKEY" }), 400, scrub).body.error, "bad path /quote/[redacted]");
  assertEquals(upstreamError("<html>oops</html>", 500, scrub), { body: { error: "Aurora is unavailable — try again" }, status: 502 });
  assertEquals(upstreamError("{}", 404, scrub), { body: { error: "Aurora refused the request" }, status: 404 });
  assertEquals(upstreamError("{}", 429, scrub).status, 429);
  assertEquals(upstreamError(JSON.stringify({ message: "invalid key" }), 401, scrub), { body: { error: "bridge not configured" }, status: 503 });
  assertEquals(upstreamError(JSON.stringify({ message: "x".repeat(500) }), 400, scrub).body.error.length, 200);
  assertEquals(upstreamError(JSON.stringify({ message: "line\nbreak" }), 400, scrub).body.error, "line break");
});
