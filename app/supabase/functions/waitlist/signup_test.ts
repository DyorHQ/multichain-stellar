// deno test --no-config --node-modules-dir=none -A supabase/functions/waitlist/
import { assertEquals } from "jsr:@std/assert@1";
import { corsFor, normalizeEmail, parseSignup } from "./signup.ts";

Deno.test("CORS: only the two site origins; requests without an Origin are not browser pages", () => {
  assertEquals(corsFor("https://dyorhq.fun"), { "Access-Control-Allow-Origin": "https://dyorhq.fun", Vary: "Origin" });
  assertEquals(corsFor("https://www.dyorhq.fun"), { "Access-Control-Allow-Origin": "https://www.dyorhq.fun", Vary: "Origin" });
  for (const bad of ["http://dyorhq.fun", "https://dyorhq.fun.evil.com", "https://evil.dyorhq.fun", "https://dyorhq.fun:8443", "null", ""]) {
    assertEquals(corsFor(bad), null, bad);
  }
  assertEquals(corsFor(null), { Vary: "Origin" });
});

Deno.test("emails: trimmed and lowercased when plausible", () => {
  assertEquals(normalizeEmail("  Jane.Doe+list@Example.co.UK "), "jane.doe+list@example.co.uk");
  assertEquals(normalizeEmail("a@b.io"), "a@b.io");
  assertEquals(normalizeEmail("x@xn--80ak6aa92e.xn--p1ai"), "x@xn--80ak6aa92e.xn--p1ai");
  const long = "a".repeat(64) + "@" + ["b".repeat(63), "c".repeat(63), "d".repeat(58), "io"].join(".");
  assertEquals(long.length, 254);
  assertEquals(normalizeEmail(long), long);
});

Deno.test("emails: malformed ones are refused", () => {
  for (const bad of [
    undefined, null, 5, "", "a@", "@b.io", "ab.io", "a@@b.io", "a@b@c.io", "a b@c.io", "a@b .io", "a\n@b.io", "a@b.io\u0000",
    ".a@b.io", "a.@b.io", "a..b@c.io", "a@localhost", "a@b", "a@-b.io", "a@b-.io", "a@b..io", "a@b.i", "a@b.123",
    "a@[127.0.0.1]", "\"a b\"@c.io", "ü@b.io", "a@bü.io", "a".repeat(65) + "@b.io",
    "a".repeat(64) + "@" + ["b".repeat(63), "c".repeat(63), "d".repeat(59), "io"].join("."), // 255 characters
    "a@" + "b".repeat(64) + ".io",
  ]) {
    assertEquals(normalizeEmail(bad), null, JSON.stringify(bad));
  }
});

Deno.test("signups: honeypot, source tag, and malformed bodies", () => {
  assertEquals(parseSignup(JSON.stringify({ email: "A@B.io", source: " hero ", website: "" })), { email: "a@b.io", source: "hero", bot: false });
  assertEquals(parseSignup(JSON.stringify({ email: "a@b.io" })), { email: "a@b.io", source: null, bot: false });
  assertEquals(parseSignup(JSON.stringify({ email: "a@b.io", source: "", website: null })), { email: "a@b.io", source: null, bot: false });
  assertEquals(parseSignup(JSON.stringify({ email: "a@b.io", website: "http://spam" }))?.bot, true);
  assertEquals(parseSignup(JSON.stringify({ email: "a@b.io", website: 1 }))?.bot, true);
  for (const bad of ["", "nope", "[]", "null", "{}", JSON.stringify({ email: "x" }), JSON.stringify({ email: "a@b.io", source: 5 }),
                     JSON.stringify({ email: "a@b.io", source: "x".repeat(65) }), JSON.stringify({ email: "a@b.io", source: "tab\there" })]) {
    assertEquals(parseSignup(bad), null, bad);
  }
});
