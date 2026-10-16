// Stellar wallets for Privy sign-ins (_shared/privy.ts, lite/routes/privy.ts; DyorHQ/internal
// ios-app/stellar-v2/privy-stellar-wallets.md §5.1), with Privy's API stood in for: a token is believed only with
// Privy's ES256 signature for DyorHQ's app; a user's wallet is found, or made once with the idempotency key; a signature
// request is relayed exactly as the phone authorized it, and Privy's answer is believed only when it verifies for the
// wallet's address. No network, no database.
import { Keypair } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const APP_ID = "cmttp2squ00lk0djrso3z0yvm";
const SECRET = "test-app-secret-not-a-real-one";
const USER_ID = "did:privy:cmuserabc123";
const WALLET = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(9) as any);
const WALLET_ID = "wl0privy0stellar1";

const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const privy = await import("../../supabase/functions/_shared/privy.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");

// ---------------------------------------------------------------------------------------------- Privy's keys

const enc = new TextEncoder();
const b64url = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const pair = () => crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as Promise<CryptoKeyPair>;
const APP_KEY = await pair();
const OTHER_KEY = await pair();

async function pem(key: CryptoKey): Promise<string> {
  const der = new Uint8Array(await crypto.subtle.exportKey("spki", key));
  return `-----BEGIN PUBLIC KEY-----\n${btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n")}\n-----END PUBLIC KEY-----`;
}
const APP_PEM = await pem(APP_KEY.publicKey);

/** A token as Privy signs one (ES256), with `claims` over an identity token's for USER_ID, an hour from now. */
async function token(claims: Record<string, unknown> = {}, key = APP_KEY.privateKey, alg = "ES256"): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(enc.encode(JSON.stringify({ alg, typ: "JWT", kid: "k1" })));
  const p = b64url(enc.encode(JSON.stringify({
    iss: "privy.io",
    aud: APP_ID,
    sub: USER_ID,
    iat: now,
    exp: now + 3600,
    linked_accounts: "[]",
    ...claims,
  })));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${h}.${p}`)));
  return `${h}.${p}.${b64url(sig)}`;
}

// ---------------------------------------------------------------------------------------------- Privy's API

interface Call {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: string | null;
}

/** Privy, as these tests need it: its app config (the verification key), a user's wallets, wallet creation and
 *  raw_sign, each answer set per test. Returns the calls made, in order. */
function privyApi(opts: {
  appConfig?: () => Response;
  wallets?: unknown[];
  create?: () => Response;
  rawSign?: (body: { params: { hash: string } }) => Response;
} = {}): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    const body = typeof init?.body === "string" ? init.body : null;
    calls.push({ method: init?.method ?? "GET", url: url.toString(), headers, body });
    if (url.host === "auth.privy.io" && url.pathname === `/api/v1/apps/${APP_ID}`) {
      return opts.appConfig?.() ?? Response.json({ id: APP_ID, verification_key: APP_PEM });
    }
    if (url.host === "api.privy.io" && url.pathname === "/v1/wallets" && (init?.method ?? "GET") === "GET") {
      return Response.json({ data: opts.wallets ?? [], next_cursor: null });
    }
    if (url.host === "api.privy.io" && url.pathname === "/v1/wallets" && init?.method === "POST") {
      return opts.create?.() ?? Response.json({ id: WALLET_ID, address: WALLET.publicKey(), chain_type: "stellar", created_at: 1 });
    }
    if (url.host === "api.privy.io" && /^\/v1\/wallets\/[^/]+\/raw_sign$/.test(url.pathname)) {
      const parsed = JSON.parse(body ?? "{}");
      if (opts.rawSign) return opts.rawSign(parsed);
      const sig = WALLET.sign(Buffer.from(parsed.params.hash.slice(2), "hex"));
      return Response.json({ method: "raw_sign", data: { signature: `0x${sig.toString("hex")}`, encoding: "hex" } });
    }
    return new Response("offline", { status: 503 });
  }) as typeof fetch;
  return calls;
}

// ---------------------------------------------------------------------------------------------- the database

/** lite.privy_wallets in memory, through the route's own statements; any other query fails the request. */
function walletTable(rows: { user_id: string; wallet_id: string; address: string }[] = []) {
  replaceSql(fakeSql((q, params) => {
    if (q === "select wallet_id, address from lite.privy_wallets where user_id = ?") {
      return rows.filter((r) => r.user_id === params[0]).map(({ wallet_id, address }) => ({ wallet_id, address }));
    }
    if (q === "insert into lite.privy_wallets (user_id, wallet_id, address) values (?, ?, ?) on conflict (user_id) do nothing") {
      if (!rows.some((r) => r.user_id === params[0])) rows.push({ user_id: params[0] as string, wallet_id: params[1] as string, address: params[2] as string });
      return [];
    }
    if (q === "select address from lite.privy_wallets where wallet_id = ?") {
      return rows.filter((r) => r.wallet_id === params[0]).map(({ address }) => ({ address }));
    }
    if (q.startsWith("select value from lite.app_config")) return [{ value: { enabled: true } }];
    throw new Error(`unexpected query: ${q}`);
  }));
  return rows;
}

function enable(on = true) {
  if (on) {
    Deno.env.set("LITE_PRIVY_WALLETS", "on");
    Deno.env.set("PRIVY_APP_SECRET", SECRET);
  } else {
    Deno.env.delete("LITE_PRIVY_WALLETS");
    Deno.env.delete("PRIVY_APP_SECRET");
  }
}

/** One request through the API, from an address of its own (the routes rate-limit per IP). */
let ip = 0;
async function post(path: string, body: unknown): Promise<{ status: number; body: any }> {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "cf-connecting-ip": `10.0.${Math.floor(++ip / 250)}.${ip % 250}` },
    body: JSON.stringify(body),
  }));
  return { status: res.status, body: await res.json() };
}

const HASH = `0x${"ab".repeat(32)}`;
const signRequest = (over: Record<string, unknown> = {}) => ({
  walletId: WALLET_ID,
  hash: HASH,
  expiresAt: Date.now() + 120_000,
  authorization: "MEUCIQDphoneSignedThisRequestAAAAAAAAAAAAAAAAAAAAAAIgBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
  ...over,
});

/** console.error held back (the routes log Privy's refusals), and what was logged. */
async function quietly<T>(fn: () => Promise<T>): Promise<{ result: T; logged: string }> {
  const error = console.error;
  let logged = "";
  console.error = (...a: unknown[]) => void (logged += a.map(String).join(" ") + "\n");
  try {
    return { result: await fn(), logged };
  } finally {
    console.error = error;
  }
}

// ---------------------------------------------------------------------------------------------- tokens

Deno.test("a token is the user's only with Privy's ES256 signature for DyorHQ's app, unexpired", async () => {
  enable();
  privy.resetPrivyKey();
  const calls = privyApi();
  assertEquals(await privy.privyUserId(await token()), USER_ID);
  // An access token (no linked_accounts, a session id) is a Privy token too.
  assertEquals(await privy.privyUserId(await token({ linked_accounts: undefined, sid: "s1" })), USER_ID);
  const refused = [
    await token({ aud: "another-app" }),
    await token({ iss: "evil.example" }),
    await token({ exp: Math.floor(Date.now() / 1000) - 3600 }),
    await token({ iat: Math.floor(Date.now() / 1000) + 3600 }),
    await token({ sub: "did:privy:../../admin" }),
    await token({ sub: 42 }),
    await token({}, OTHER_KEY.privateKey),
    await token({}, APP_KEY.privateKey, "HS256"),
    "not.a.jwt",
    "only-one-part",
  ];
  const good = await token();
  const [h, , s] = good.split(".");
  refused.push(`${h}.${b64url(enc.encode(JSON.stringify({ iss: "privy.io", aud: APP_ID, sub: "did:privy:someoneelse", exp: 9e9 })))}.${s}`);
  for (const t of refused) await assertRejects(() => privy.privyUserId(t), privy.PrivyTokenInvalid, undefined, t.slice(0, 40));
  // The app's key was read once: a signature that fails doesn't make every request re-read it.
  assertEquals(calls.filter((c) => c.url.includes("auth.privy.io")).length, 1);
});

Deno.test("no verification key from Privy: PrivyUnavailable, never a refused token", async () => {
  enable();
  privy.resetPrivyKey();
  privyApi({ appConfig: () => new Response("down", { status: 502 }) });
  await assertRejects(async () => privy.privyUserId(await token()), privy.PrivyUnavailable);
});

// ---------------------------------------------------------------------------------------------- POST /v1/privy/wallet

Deno.test("both routes are off without LITE_PRIVY_WALLETS=on and the app secret: 503, and Privy isn't asked", async () => {
  walletTable();
  for (const [flag, secret] of [[undefined, SECRET], ["on", undefined], ["off", SECRET]]) {
    enable(false);
    if (flag) Deno.env.set("LITE_PRIVY_WALLETS", flag);
    if (secret) Deno.env.set("PRIVY_APP_SECRET", secret);
    const calls = privyApi();
    for (const [path, body] of [["/v1/privy/wallet", { privyToken: await token() }], ["/v1/privy/sign", signRequest()]] as const) {
      const res = await post(path, body);
      assertEquals([res.status, res.body.error.code], [503, "privy_unavailable"], `${path} ${flag} ${!!secret}`);
    }
    assertEquals(calls.length, 0);
  }
  enable();
});

Deno.test("a user's first call makes their wallet once, owned by them, with the idempotency key; later calls read the row", async () => {
  enable();
  privy.resetPrivyKey();
  const rows = walletTable();
  const calls = privyApi();
  const first = await post("/v1/privy/wallet", { privyToken: await token() });
  assertEquals([first.status, first.body], [200, { walletId: WALLET_ID, address: WALLET.publicKey() }]);
  const [list, create] = calls.filter((c) => c.url.startsWith("https://api.privy.io"));
  assertEquals(list.method, "GET");
  assertEquals(new URL(list.url).searchParams.get("user_id"), USER_ID);
  assertEquals(new URL(list.url).searchParams.get("chain_type"), "stellar");
  assertEquals(create.method, "POST");
  assertEquals(JSON.parse(create.body!), { chain_type: "stellar", owner: { user_id: USER_ID } });
  assertEquals(create.headers["privy-idempotency-key"], await privy.creationKey(USER_ID));
  assertEquals(create.headers["privy-app-id"], APP_ID);
  assertEquals(create.headers["authorization"], `Basic ${btoa(`${APP_ID}:${SECRET}`)}`);
  assertEquals(rows, [{ user_id: USER_ID, wallet_id: WALLET_ID, address: WALLET.publicKey() }]);

  const before = calls.length;
  const again = await post("/v1/privy/wallet", { privyToken: await token() });
  assertEquals([again.status, again.body], [200, { walletId: WALLET_ID, address: WALLET.publicKey() }]);
  assertEquals(calls.length, before, "a kept wallet asks Privy nothing");
});

Deno.test("a wallet Privy already lists for the user is kept, the oldest first; nothing is made", async () => {
  enable();
  privy.resetPrivyKey();
  const rows = walletTable();
  const newer = Keypair.random();
  const calls = privyApi({
    wallets: [
      { id: "wlnewer", address: newer.publicKey(), chain_type: "stellar", created_at: 20 },
      { id: "wlevm", address: "0x1234", chain_type: "ethereum", created_at: 1 },
      { id: WALLET_ID, address: WALLET.publicKey(), chain_type: "stellar", created_at: 10 },
    ],
  });
  const res = await post("/v1/privy/wallet", { privyToken: await token() });
  assertEquals([res.status, res.body], [200, { walletId: WALLET_ID, address: WALLET.publicKey() }]);
  assertEquals(calls.filter((c) => c.method === "POST").length, 0);
  assertEquals(rows.length, 1);
});

Deno.test("POST /v1/privy/wallet: no token 400, a bad one 401, Privy down or refusing 503 (never the token in a log)", async () => {
  enable();
  privy.resetPrivyKey();
  walletTable();
  privyApi();
  assertEquals((await post("/v1/privy/wallet", {})).body.error.code, "bad_arg");
  assertEquals((await post("/v1/privy/wallet", { privyToken: 7 })).body.error.code, "bad_arg");
  const bad = await post("/v1/privy/wallet", { privyToken: await token({ aud: "x" }) });
  assertEquals([bad.status, bad.body.error.code], [401, "privy_token_invalid"]);
  const failures = [() => new Response("no", { status: 500 }), () => new Response("no", { status: 400 }), () => Response.json({ id: "x", chain_type: "ethereum" })];
  for (const [i, create] of failures.entries()) {
    walletTable();
    privyApi({ create });
    // A user of its own each time: a user may ask 5 times a minute.
    const t = await token({ sub: `did:privy:cmfailing${i}` });
    const { result, logged } = await quietly(() => post("/v1/privy/wallet", { privyToken: t }));
    assertEquals([result.status, result.body.error.code], [503, "privy_unavailable"]);
    assert(!logged.includes(t) && !logged.includes(SECRET));
  }
});

// ---------------------------------------------------------------------------------------------- POST /v1/privy/sign

Deno.test("a signature request is relayed exactly as the phone authorized it, and answered once it verifies", async () => {
  enable();
  walletTable([{ user_id: USER_ID, wallet_id: WALLET_ID, address: WALLET.publicKey() }]);
  const calls = privyApi();
  const req = signRequest();
  const res = await post("/v1/privy/sign", req);
  assertEquals(res.status, 200);
  const sig = Buffer.from(res.body.signature.slice(2), "hex");
  assert(WALLET.verify(Buffer.from(HASH.slice(2), "hex"), sig));
  assertEquals(calls.length, 1);
  const [call] = calls;
  assertEquals([call.method, call.url], ["POST", `https://api.privy.io/v1/wallets/${WALLET_ID}/raw_sign`]);
  // The body and the privy-* headers are the ones the phone signed, and nothing else Privy reads.
  assertEquals(call.body, JSON.stringify({ params: { hash: HASH } }));
  assertEquals(call.headers["privy-authorization-signature"], req.authorization);
  assertEquals(call.headers["privy-request-expiry"], String(req.expiresAt));
  assertEquals(call.headers["privy-app-id"], APP_ID);
  assertEquals(Object.keys(call.headers).filter((k) => k.startsWith("privy-")).sort(), ["privy-app-id", "privy-authorization-signature", "privy-request-expiry"]);
  assertEquals(call.headers["authorization"], `Basic ${btoa(`${APP_ID}:${SECRET}`)}`);
});

Deno.test("POST /v1/privy/sign checks its input before asking Privy; a wallet DyorHQ didn't make is 404", async () => {
  enable();
  walletTable([{ user_id: USER_ID, wallet_id: WALLET_ID, address: WALLET.publicKey() }]);
  const calls = privyApi();
  const cases: [Record<string, unknown>, number, string][] = [
    [{ hash: HASH.toUpperCase().replace("0X", "0x") }, 400, "bad_hash"],
    [{ hash: HASH.slice(2) }, 400, "bad_hash"],
    [{ hash: `${HASH}00` }, 400, "bad_hash"],
    [{ hash: undefined }, 400, "bad_hash"],
    [{ expiresAt: Date.now() - 1 }, 400, "bad_arg"],
    [{ expiresAt: Date.now() + 10 * 60_000 }, 400, "bad_arg"],
    [{ expiresAt: String(Date.now() + 60_000) }, 400, "bad_arg"],
    [{ authorization: "" }, 400, "bad_arg"],
    [{ authorization: "not base64!" }, 400, "bad_arg"],
    [{ authorization: "A".repeat(600) }, 400, "bad_arg"],
    [{ walletId: "../other" }, 400, "bad_arg"],
    [{ walletId: undefined }, 400, "bad_arg"],
    [{ walletId: "wlsomeoneelses" }, 404, "not_found"],
  ];
  for (const [over, status, code] of cases) {
    const res = await post("/v1/privy/sign", signRequest(over));
    assertEquals([res.status, res.body.error.code], [status, code], JSON.stringify(over));
  }
  assertEquals(calls.length, 0);
});

Deno.test("POST /v1/privy/sign: Privy's refusals and outages, and a signature that doesn't verify, are never passed on", async () => {
  enable();
  walletTable([{ user_id: USER_ID, wallet_id: WALLET_ID, address: WALLET.publicKey() }]);
  const other = Keypair.random();
  const cases: [(b: { params: { hash: string } }) => Response, number, string][] = [
    [() => new Response("bad authorization", { status: 401 }), 403, "privy_refused"],
    [() => new Response("expired", { status: 400 }), 403, "privy_refused"],
    [() => new Response("slow down", { status: 429 }), 503, "privy_unavailable"],
    [() => new Response("oops", { status: 500 }), 503, "privy_unavailable"],
    [() => Response.json({ data: { signature: "0x1234" } }), 503, "privy_unavailable"],
    // Another key's signature, or the wallet's over another hash: refused here, whatever Privy says.
    [(b) => Response.json({ data: { signature: `0x${other.sign(Buffer.from(b.params.hash.slice(2), "hex")).toString("hex")}` } }), 502, "privy_bad_signature"],
    [() => Response.json({ data: { signature: `0x${WALLET.sign(Buffer.alloc(32, 1)).toString("hex")}` } }), 502, "privy_bad_signature"],
  ];
  for (const [rawSign, status, code] of cases) {
    privyApi({ rawSign });
    const { result } = await quietly(() => post("/v1/privy/sign", signRequest()));
    assertEquals([result.status, result.body.error.code], [status, code]);
    assertEquals(result.body.signature, undefined);
  }
});

Deno.test("POST /v1/privy/wallet: at most 5 a minute per user, whatever the caller's address", async () => {
  enable();
  privy.resetPrivyKey();
  walletTable([{ user_id: "did:privy:cmbusy", wallet_id: WALLET_ID, address: WALLET.publicKey() }]);
  privyApi();
  const t = await token({ sub: "did:privy:cmbusy" });
  const statuses: number[] = [];
  for (let i = 0; i < 6; i++) statuses.push((await post("/v1/privy/wallet", { privyToken: t })).status);
  assertEquals(statuses, [200, 200, 200, 200, 200, 429]);
});

Deno.test("POST /v1/privy/sign: at most 30 a minute per wallet, whatever the caller's address", async () => {
  enable();
  walletTable([{ user_id: USER_ID, wallet_id: "wlratelimited", address: WALLET.publicKey() }]);
  privyApi({ rawSign: () => new Response("no", { status: 401 }) });
  const statuses: number[] = [];
  for (let i = 0; i < 31; i++) statuses.push((await post("/v1/privy/sign", signRequest({ walletId: "wlratelimited" }))).status);
  assertEquals(statuses.filter((s) => s === 403).length, 30);
  assertEquals(statuses.at(-1), 429);
});
