// deno test --no-config --node-modules-dir=none supabase/functions/wallet-auth/
import { assertEquals } from "jsr:@std/assert@1";
import { getAddress } from "npm:viem@2";
import { legacySignIn, parseSignIn, siweMessage } from "./sign_in.ts";

const LOWER = "0x52908400098527886e0f7030069857d2e4169ee7"; // an EIP-55 test vector (mixed case when checksummed)
const CHECKSUMMED = getAddress(LOWER);
const NONCE = "ab".repeat(32);
const NOW = Date.parse("2026-09-26T12:00:00.000Z");
const iso = (ms: number) => new Date(ms).toISOString();
const message = (issued = NOW, expires = NOW + 10 * 60_000, address: string = CHECKSUMMED, nonce = NONCE) =>
  siweMessage(address, nonce, iso(issued), iso(expires));

Deno.test("EIP-4361: the contract's message is accepted, for the address in any case", () => {
  assertEquals(CHECKSUMMED, "0x52908400098527886E0F7030069857D2E4169EE7");
  assertEquals(message(), [
    "dyorhq.fun wants you to sign in with your Ethereum account:",
    CHECKSUMMED,
    "",
    "Sign in to DyorHQ.",
    "",
    "URI: https://dyorhq.fun",
    "Version: 1",
    "Chain ID: 143",
    `Nonce: ${NONCE}`,
    "Issued At: 2026-09-26T12:00:00.000Z",
    "Expiration Time: 2026-09-26T12:10:00.000Z",
  ].join("\n"));
  for (const address of [LOWER, CHECKSUMMED, LOWER.toUpperCase().replace("0X", "0x")]) {
    assertEquals(parseSignIn(message(), address, NOW), { nonce: NONCE, format: "eip4361" });
  }
});

Deno.test("EIP-4361: the address line must be the request's address with its EIP-55 checksum", () => {
  const status = (m: string, address = LOWER) => { const r = parseSignIn(m, address, NOW); return "status" in r ? r.status : 200; };
  assertEquals(status(message(NOW, NOW + 600_000, LOWER)), 400); // right address, no checksum
  assertEquals(status(message(NOW, NOW + 600_000, CHECKSUMMED.replace("E0F", "e0f"))), 400); // broken checksum
  assertEquals(status(message(), "0x" + "1".repeat(40)), 400); // another wallet
  assertEquals(status(message(), "not an address"), 400);
});

Deno.test("EIP-4361: domain, URI, version, chain, statement and layout are fixed", () => {
  const good = message();
  for (const [from, to] of [
    ["dyorhq.fun wants", "evil.fun wants"],
    ["URI: https://dyorhq.fun", "URI: https://dyorhq.fun.evil.com"],
    ["Version: 1", "Version: 2"],
    ["Chain ID: 143", "Chain ID: 1"],
    ["Sign in to DyorHQ.", "Sign in to DyorHQ!"],
    [`Nonce: ${NONCE}`, `Nonce: ${NONCE.toUpperCase()}`],
    [`Nonce: ${NONCE}`, `Nonce: ${NONCE.slice(2)}`],
    ["\n\nSign in", "\nSign in"],
  ]) {
    const r = parseSignIn(good.replace(from, to), LOWER, NOW);
    assertEquals("status" in r && r.status, 400, `${from} -> ${to}`);
  }
  for (const altered of [good + "\n", good + "\nResources:", "\n" + good, good.replaceAll("\n", "\r\n"), good.replace("Z\nExpiration", "Z \nExpiration")]) {
    const r = parseSignIn(altered, LOWER, NOW);
    assertEquals("status" in r && r.status, 400, JSON.stringify(altered.slice(-40)));
  }
});

Deno.test("EIP-4361: Issued At and Expiration Time", () => {
  const verdict = (issued: number, expires: number, now = NOW) => {
    const r = parseSignIn(message(issued, expires), LOWER, now);
    return "status" in r ? r.status : "ok";
  };
  assertEquals(verdict(NOW, NOW + 600_000), "ok");
  assertEquals(verdict(NOW - 9 * 60_000, NOW + 60_000), "ok"); // signed 9 minutes ago, still unexpired
  assertEquals(verdict(NOW + 9 * 60_000, NOW + 19 * 60_000), "ok"); // a client clock up to 10 minutes ahead
  assertEquals(verdict(NOW - 11 * 60_000, NOW + 60_000), 401); // issued too long ago
  assertEquals(verdict(NOW + 11 * 60_000, NOW + 12 * 60_000), 401); // issued too far ahead
  assertEquals(verdict(NOW - 60_000, NOW), 401); // expires now
  assertEquals(verdict(NOW - 120_000, NOW - 60_000), 401); // expired
  assertEquals(verdict(NOW, NOW + 600_001), 401); // valid for more than 10 minutes
  assertEquals(verdict(NOW + 60_000, NOW + 30_000), 401); // expires before it was issued
  // Timestamps must be strict ISO-8601 UTC with milliseconds, and real dates.
  for (const [issued, expires] of [
    ["2026-09-26T12:00:00Z", "2026-09-26T12:10:00.000Z"],
    ["2026-09-26T12:00:00.000+00:00", "2026-09-26T12:10:00.000Z"],
    ["2026-02-30T12:00:00.000Z", "2026-02-30T12:10:00.000Z"],
    ["2026-09-26T12:00:00.000Z", "2026-09-26T12:10:00.0000Z"],
  ]) {
    const r = parseSignIn(siweMessage(CHECKSUMMED, NONCE, issued, expires), LOWER, NOW);
    assertEquals("status" in r && r.status, 400, issued);
  }
});

Deno.test("legacy template: still accepted, with the address exactly as sent, and nothing appended", () => {
  const legacy = (address: string, issued = NOW) => `DyorHQ Sign-In\n\nWallet: ${address}\nNonce: ${NONCE}\nIssued At: ${issued}`;
  assertEquals(parseSignIn(legacy(LOWER), LOWER, NOW), { nonce: NONCE, format: "legacy" });
  assertEquals(parseSignIn(legacy(CHECKSUMMED), CHECKSUMMED, NOW), { nonce: NONCE, format: "legacy" });
  assertEquals((parseSignIn(legacy(CHECKSUMMED), LOWER, NOW) as { status: number }).status, 400);
  assertEquals((parseSignIn(legacy(LOWER) + "\n", LOWER, NOW) as { status: number }).status, 400);
  assertEquals((parseSignIn(legacy(LOWER, NOW - 11 * 60_000), LOWER, NOW) as { status: number }).status, 401);
});

Deno.test("IOSK-7: WALLET_AUTH_LEGACY_SIGNIN=off refuses the legacy template and nothing else", () => {
  const legacy = `DyorHQ Sign-In\n\nWallet: ${LOWER}\nNonce: ${NONCE}\nIssued At: ${NOW}`;
  const refused = parseSignIn(legacy, LOWER, NOW, { legacy: false });
  assertEquals("status" in refused ? refused.status : 200, 400);
  assertEquals(parseSignIn(message(), LOWER, NOW, { legacy: false }), { nonce: NONCE, format: "eip4361" });
  assertEquals(parseSignIn(legacy, LOWER, NOW, { legacy: true }), { nonce: NONCE, format: "legacy" });
  assertEquals(legacySignIn(undefined), true);
  assertEquals(legacySignIn(""), true);
  assertEquals(legacySignIn("on"), true);
  assertEquals(legacySignIn("off"), false);
  assertEquals(legacySignIn(" OFF "), false);
});
