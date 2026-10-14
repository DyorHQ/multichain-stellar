// deno test --no-config --node-modules-dir=none -A supabase/functions/delete-account/
import { assertEquals } from "jsr:@std/assert@1";
import { DEFAULT_TOKEN_MAX_AGE_S, deletionMethod, NO_BINDING, ownBinding, sessionClaims, tokenMaxAge } from "./deletion.ts";

Deno.test("SB-10: the Privy token may be an hour old by default (the builds in use); the override tightens it within [1 min, 1 h]", () => {
  assertEquals(DEFAULT_TOKEN_MAX_AGE_S, 3600);
  assertEquals(tokenMaxAge(undefined), 3600);
  assertEquals(tokenMaxAge(""), 3600);
  assertEquals(tokenMaxAge("abc"), 3600);
  assertEquals(tokenMaxAge("1.5"), 3600);
  assertEquals(tokenMaxAge("900"), 900);
  assertEquals(tokenMaxAge("3600"), 3600);
  assertEquals(tokenMaxAge("86400"), 3600);
  assertEquals(tokenMaxAge("5"), 60);
  assertEquals(tokenMaxAge("-1"), 60);
});

Deno.test("SB-7: the old app's {} is a Privy deletion; only method email-password selects the new path", () => {
  assertEquals(deletionMethod({}), "privy");
  assertEquals(deletionMethod({ other: 1 }), "privy");
  assertEquals(deletionMethod({ method: "email-password" }), "email-password");
  for (const bad of [null, [], "x", 1, { method: "privy" }, { method: "" }, { method: null }]) {
    assertEquals(deletionMethod(bad), null, JSON.stringify(bad));
  }
});

Deno.test("SB-7: only one well-formed row counts as the caller's binding", () => {
  const wallet = "0x" + "a".repeat(40);
  assertEquals(ownBinding([]), null);
  assertEquals(ownBinding([{ email: "me@x.io", wallet }]), { email: "me@x.io", wallet });
  for (const bad of [null, {}, "[]", [{ email: "me@x.io", wallet }, { email: "b@x.io", wallet }], [{ email: "nope", wallet }],
                     [{ email: "me@x.io", wallet: "0x1" }], [{ wallet }], [null]]) {
    assertEquals(ownBinding(bad), "invalid", JSON.stringify(bad));
  }
});

Deno.test("SB-7: with no binding row, nothing is reported as deleted", () => {
  assertEquals(NO_BINDING, { deleted: false, privy: "unknown", error: "no email binding" });
});

Deno.test("SB-7: the session's role and wallet are read from the token PostgREST accepted", () => {
  const jwt = (claims: unknown) => `h.${btoa(JSON.stringify(claims)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}.s`;
  const wallet = "0x" + "A".repeat(40);
  assertEquals(sessionClaims(jwt({ role: "authenticated", wallet_address: wallet })), { role: "authenticated", wallet: wallet.toLowerCase() });
  assertEquals(sessionClaims(jwt({ role: "service_role" })), { role: "service_role", wallet: undefined });
  assertEquals(sessionClaims("garbage"), {});
  assertEquals(sessionClaims("a.!!!.c"), {});
});
