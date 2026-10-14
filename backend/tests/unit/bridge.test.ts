import { assert, assertEquals } from "jsr:@std/assert@1";

const { encodeApprove, encodeDepositForBurnWithHook, encodeReceiveMessage, evmToBytes32, forwarderHookData } = await import("../../supabase/functions/_shared/bridge.ts");

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
