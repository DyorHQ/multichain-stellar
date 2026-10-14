// deno test --no-config --node-modules-dir=none -A supabase/functions/_shared/
import { assert, assertEquals, assertInstanceOf, assertRejects } from "jsr:@std/assert@1";
import { exportSPKI, generateKeyPair, SignJWT } from "npm:jose@5";
import {
  APP_ID, deletePrivyUser, linkedEmail, onlyLinkedToEmail, PrivyRefused, privyTokenClaims, PrivyUnavailable, privyUser,
  privyUserByEmail, tokenIsFresh,
} from "./privy.ts";

type Reply = Response | Error;
// Replaces fetch with a script of replies (or errors), recording each request.
function stubFetch(replies: Reply[]) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), init });
    const next = replies.shift() ?? new Error("unexpected fetch");
    return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
  }) as typeof fetch;
  return { calls, restore: () => { globalThis.fetch = original; } };
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.test("admin reads: 404 is 'no such user'; timeouts, 429 and 5xx are PrivyUnavailable; other refusals PrivyRefused", async () => {
  const { calls, restore } = stubFetch([
    json({ id: "did:privy:1", linked_accounts: [{ type: "email", address: "A@x.io" }] }),
    new Response("nope", { status: 404 }),
    new DOMException("timed out", "TimeoutError"),
    new Response("slow down", { status: 429 }),
    new Response("down", { status: 503 }),
    new Response("forbidden", { status: 403 }),
    new Response("not json", { status: 200 }),
  ]);
  try {
    assertEquals(linkedEmail(await privyUser("did:privy:1", "s")), "A@x.io");
    assertEquals(await privyUser("did:privy:2", "s"), null);
    await assertRejects(() => privyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => privyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => privyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => privyUser("u", "s"), PrivyRefused);
    await assertRejects(() => privyUser("u", "s"), PrivyUnavailable);
    for (const call of calls) assertInstanceOf(call.init?.signal, AbortSignal, "every Privy call carries a timeout");
    assertEquals(calls[0].url, "https://auth.privy.io/api/v1/users/did%3Aprivy%3A1");
    assertEquals(new Headers(calls[0].init?.headers).get("privy-app-id"), APP_ID);
  } finally { restore(); }
});

Deno.test("lookup by email posts the address to Privy's documented endpoint", async () => {
  const { calls, restore } = stubFetch([json({ id: "did:privy:9", linked_accounts: [] }), new Response("", { status: 404 })]);
  try {
    assertEquals((await privyUserByEmail("a@x.io", "s"))?.id, "did:privy:9");
    assertEquals(await privyUserByEmail("b@x.io", "s"), null);
    assertEquals(calls[0].url, "https://api.privy.io/v1/users/email/address");
    assertEquals(calls[0].init?.method, "POST");
    assertEquals(JSON.parse(String(calls[0].init?.body)), { address: "a@x.io" });
  } finally { restore(); }
});

Deno.test("delete: deleted, gone on 404, retryable on 5xx/429/timeout, refused otherwise", async () => {
  const { restore } = stubFetch([
    new Response(null, { status: 200 }), new Response(null, { status: 404 }), new Response(null, { status: 502 }),
    new Response(null, { status: 429 }), new TypeError("connection reset"), new Response(null, { status: 401 }),
  ]);
  try {
    assertEquals(await deletePrivyUser("u", "s"), "deleted");
    assertEquals(await deletePrivyUser("u", "s"), "gone");
    await assertRejects(() => deletePrivyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => deletePrivyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => deletePrivyUser("u", "s"), PrivyUnavailable);
    await assertRejects(() => deletePrivyUser("u", "s"), PrivyRefused);
  } finally { restore(); }
});

Deno.test("token claims: an unreachable key is PrivyUnavailable, not an invalid token; a valid token yields sub and iat", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const token = await new SignJWT({ sid: "s" }).setProtectedHeader({ alg: "ES256" }).setIssuer("privy.io").setAudience(APP_ID)
    .setSubject("did:privy:7").setIssuedAt(1_790_000_000).setExpirationTime("2h").sign(privateKey);
  let stub = stubFetch([new Response("down", { status: 500 })]);
  try { await assertRejects(() => privyTokenClaims(token), PrivyUnavailable); } finally { stub.restore(); }
  stub = stubFetch([json({ verification_key: await exportSPKI(publicKey) })]);
  try {
    assertEquals(await privyTokenClaims(token), { userId: "did:privy:7", issuedAt: 1_790_000_000 });
    const other = await generateKeyPair("ES256");
    const forged = await new SignJWT({}).setProtectedHeader({ alg: "ES256" }).setIssuer("privy.io").setAudience(APP_ID)
      .setSubject("did:privy:7").setIssuedAt().setExpirationTime("1h").sign(other.privateKey);
    const err = await privyTokenClaims(forged).then(() => null, (e) => e);
    assert(err && !(err instanceof PrivyUnavailable), "a forged token is an invalid token, not an outage");
    const wrongAudience = await new SignJWT({}).setProtectedHeader({ alg: "ES256" }).setIssuer("privy.io").setAudience("other")
      .setSubject("did:privy:7").setIssuedAt().setExpirationTime("1h").sign(privateKey);
    assert(!((await privyTokenClaims(wrongAudience).then(() => null, (e) => e)) instanceof PrivyUnavailable));
  } finally { stub.restore(); }
});

Deno.test("tokenIsFresh: within maxAge, tolerates a minute of clock skew, and never without an iat", () => {
  const now = 1_790_000_000_000;
  assert(tokenIsFresh(now / 1000 - 899, now, 900));
  assert(!tokenIsFresh(now / 1000 - 901, now, 900));
  assert(tokenIsFresh(now / 1000 + 59, now, 900));
  assert(!tokenIsFresh(now / 1000 + 61, now, 900));
  assert(!tokenIsFresh(undefined, now, 900));
  assert(!tokenIsFresh(Number.NaN, now, 900));
});

Deno.test("onlyLinkedToEmail: deletable only when the email login is all the Privy user has", () => {
  const user = (...accounts: unknown[]) => ({ id: "u", linked_accounts: accounts });
  assert(onlyLinkedToEmail(user({ type: "email", address: "Me@X.io" }), "me@x.io"));
  assert(!onlyLinkedToEmail(user({ type: "email", address: "me@x.io" }, { type: "wallet", address: "0x1" }), "me@x.io"));
  assert(!onlyLinkedToEmail(user({ type: "email", address: "me@x.io" }, { type: "google_oauth", email: "me@x.io" }), "me@x.io"));
  assert(!onlyLinkedToEmail(user({ type: "email", address: "other@x.io" }), "me@x.io"));
  assert(!onlyLinkedToEmail(user(), "me@x.io"));
  assert(!onlyLinkedToEmail(null, "me@x.io"));
  assert(!onlyLinkedToEmail({ id: "u", linked_accounts: "garbage" }, "me@x.io"));
});
