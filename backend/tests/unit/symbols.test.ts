// Tickers that imitate another (docs/DESIGN-stellar-parity.md §6.9, §6.11, §12.5): the look-alike fold (0→O, 1/L→I,
// 5→S, 8→B, after accents and Cyrillic and Greek capitals drawn like Latin ones are taken as those); the reserved list
// is the network's own plus every registry code; create and metadata refuse a reserved-looking ticker with 400
// look_alike_symbol, an invalid one with 400 bad_symbol, and a name over 32 UTF-8 bytes with 400 bad_name.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { foldSymbol, reservedSymbols, symbolLooksReserved } = await import("../../supabase/functions/_shared/symbols.ts");
const { launchName, launchSymbol } = await import("../../supabase/functions/_shared/launch_metadata.ts");
const { MAINNET, TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");

Deno.test("the fold: 0→O, 1→I, L→I, 5→S, 8→B, in upper case", () => {
  assertEquals(foldSymbol("usdc"), "USDC");
  assertEquals(foldSymbol("U5DC"), "USDC");
  assertEquals(foldSymbol("XLM"), "XIM");
  assertEquals(foldSymbol("X1M"), "XIM");
  assertEquals(foldSymbol("M0N"), "MON");
  assertEquals(foldSymbol("8TC"), "BTC");
  assertEquals(foldSymbol("ECAT"), "ECAT");
});

Deno.test("the fold sees through accents, full-width letters and Cyrillic or Greek capitals drawn like Latin ones", () => {
  assertEquals(foldSymbol("USDĆ"), "USDC");
  assertEquals(foldSymbol("ＵＳＤＣ"), "USDC");
  // Cyrillic С (U+0421) and Greek Χ (U+03A7).
  assertEquals(foldSymbol("USD\u0421"), "USDC");
  assertEquals(foldSymbol("\u03A7LM"), "XIM");
});

Deno.test("reserved: the network's list and every registry code, in upper case", () => {
  for (const net of [TESTNET, MAINNET]) {
    const reserved = reservedSymbols(net);
    for (const code of net.assets.map((a) => a.code)) assert(reserved.includes(code), `${net.name} ${code}`);
    for (const s of net.reservedSymbols) assert(reserved.includes(s.toUpperCase()), `${net.name} ${s}`);
    assertEquals(reserved.length, new Set(reserved).size, "no duplicates");
  }
});

Deno.test("a ticker looks reserved when it folds to a reserved one's fold", () => {
  for (const s of ["XLM", "xlm", "XIM", "X1M", "USDC", "U5DC", "USDĆ", "USD\u0421", "EURC", "BTC", "8TC", "MON", "M0N", "DYOR", "DY0R", "AQUA"]) {
    assert(symbolLooksReserved(s, TESTNET), s);
  }
  for (const s of ["ECAT", "CHECK", "XLMM", "USD", "MOON", "DYORX", "GRAD", "FULL", ""]) assert(!symbolLooksReserved(s, TESTNET), s);
});

Deno.test("create and metadata: tickers of 2–10 of A–Z and 0–9, refused when they look reserved; names of at most 32 bytes", () => {
  assertEquals(launchSymbol(" ecat "), "ECAT");
  assertEquals(launchSymbol("AB"), "AB");
  assertEquals(launchSymbol("ABCDEFGHIJ"), "ABCDEFGHIJ");
  const code = (fn: () => unknown) => {
    try {
      fn();
    } catch (err) {
      assert(err instanceof ApiError);
      return [err.status, err.code];
    }
    throw new Error("not refused");
  };
  for (const s of ["A", "ABCDEFGHIJK", "EC-AT", "ÉCAT", "", undefined, 7]) assertEquals(code(() => launchSymbol(s)), [400, "bad_symbol"], String(s));
  for (const s of ["XLM", "U5DC", "x1m", "USDC"]) assertEquals(code(() => launchSymbol(s)), [400, "look_alike_symbol"], s);
  assertEquals(launchName("  E2E Cat "), "E2E Cat");
  assertEquals(launchName("a".repeat(32)), "a".repeat(32));
  // 16 two-byte letters fit; one more byte doesn't. Emoji are four bytes each.
  assertEquals(launchName("é".repeat(16)), "é".repeat(16));
  assertThrows(() => launchName("é".repeat(16) + "x"), ApiError, "at most 32 bytes");
  assertThrows(() => launchName("🐱".repeat(9)), ApiError, "at most 32 bytes");
  assertThrows(() => launchName("   "), ApiError, "Name: 1–32 characters.");
  assertThrows(() => launchName(undefined), ApiError, "Name: 1–32 characters.");
});
