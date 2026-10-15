// The Lite API's routes (lite/index.ts and lite/routes/*.ts):
// - ROUTES lists every route in the order they match, each with a path that must reach it and no other;
// - three classes (docs/DESIGN-stellar-parity.md §6.0, §6.18), as the API contract gives them: public routes (sign-in,
//   config, fees, market data, economics, Earn's markets and history, the local media stand-in) skip the session
//   check; viewer routes pass it without an Authorization header (the public view, rate-limited per IP) and are checked
//   as a session when one is sent, so a bad or expired token gets 401; every other route needs the JWT;
// - GET /v1/config serves every field of docs/DESIGN-stellar-parity.md §6.2;
// - routes answer as they did before they moved from lite/index.ts into lite/routes/: the answers recorded then are
//   in backend/tests/fixtures/routes/<name>.json, and every request must get the same status, headers and body bytes
//   (config, which grew on purpose, keeps every recorded field).
// A package that adds a route adds it to ROUTES. One that changes a route's answer on purpose records them again, and
// the diff shows what changed:
//   ROUTES_RECORD=1 deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/router.test.ts
import { assert, assertEquals, assertNotEquals, assertRejects } from "jsr:@std/assert@1";
import testnetDeployment from "../../supabase/functions/_shared/deployments/testnet.json" with { type: "json" };
import { fakeSql, fixtureUrl, goOffline, OTHER, record, RecordedRoute, ROUTE_REQUESTS, routeRows, send, setTestEnv, SPONSOR, TOKEN, USER, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
// The session settings' defaults (testnet: no invite gate, an hour's access token), whatever this shell exports.
for (const name of ["LITE_INVITE_REQUIRED", "LITE_JWT_TTL_S", "LITE_REFRESH_TTL_S"]) Deno.env.delete(name);
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
replaceSql(fakeSql(routeRows));
const { guard, handle, isPublic, isViewer, router } = await import("../../supabase/functions/lite/index.ts");
const { accountViewer, viewer } = await import("../../supabase/functions/lite/routes/auth.ts");
const { ApiError, json, Router } = await import("../../supabase/functions/_shared/http.ts");
const { signJwt } = await import("../../supabase/functions/_shared/auth.ts");

const ID = "3f1c2a9e-0000-4000-8000-000000000002";

/** [route, a path that reaches it, answers without a session]. */
const ROUTES: [string, string, boolean][] = [
  ["POST /v1/auth/challenge", "/v1/auth/challenge", true],
  ["POST /v1/auth/verify", "/v1/auth/verify", true],
  ["POST /v1/auth/refresh", "/v1/auth/refresh", true],
  ["POST /v1/auth/signout", "/v1/auth/signout", true],
  ["GET /v1/config", "/v1/config", true],
  ["GET /v1/fees", "/v1/fees", true],
  ["GET /v1/account", "/v1/account", false],
  ["POST /v1/account/activate", "/v1/account/activate", false],
  ["POST /v1/account/trust", "/v1/account/trust", false],
  ["POST /v1/account/faucet", "/v1/account/faucet", false],
  ["POST /v1/send", "/v1/send", false],
  ["GET /v1/recipient/:address", "/v1/recipient/GABC", false],
  ["POST /v1/plans/:plan/steps/:step/build", `/v1/plans/${ID}/steps/s2/build`, false],
  ["POST /v1/tx/submit", "/v1/tx/submit", false],
  ["GET /v1/tx/:hash", `/v1/tx/${"ab".repeat(32)}`, false],
  ["POST /v1/swap/quote", "/v1/swap/quote", false],
  ["POST /v1/swap/build", "/v1/swap/build", false],
  // Market data reads the reference cache and needs no session (§6.6), nor do the launchpad's economics (§6.9) and
  // Earn's markets and rate history (§6.10).
  ["GET /v1/markets", "/v1/markets", true],
  ["GET /v1/markets/:id", "/v1/markets/XLM", true],
  ["GET /v1/markets/:id/history", "/v1/markets/XLM/history", true],
  ["GET /v1/prices", "/v1/prices", true],
  ["GET /v1/launches", "/v1/launches", false],
  ["GET /v1/launches/:token", `/v1/launches/${TOKEN}`, false],
  ["POST /v1/launches/:token/quote", `/v1/launches/${TOKEN}/quote`, false],
  ["POST /v1/launches/build", "/v1/launches/build", false],
  ["POST /v1/launches/metadata", "/v1/launches/metadata", false],
  ["GET /v1/economics", "/v1/economics", true],
  ["GET /v1/launchpad/me", "/v1/launchpad/me", false],
  ["GET /v1/earn/markets", "/v1/earn/markets", true],
  ["GET /v1/earn/positions", "/v1/earn/positions", false],
  ["POST /v1/earn/build", "/v1/earn/build", false],
  ["GET /v1/earn/history", "/v1/earn/history", true],
  ["GET /v1/moments", "/v1/moments", false],
  ["GET /v1/moments/owned", "/v1/moments/owned", false],
  ["GET /v1/moments/mine", "/v1/moments/mine", false],
  ["GET /v1/moments/:id", "/v1/moments/7", false],
  ["POST /v1/moments/metadata", "/v1/moments/metadata", false],
  ["POST /v1/moments/build", "/v1/moments/build", false],
  ["POST /v1/media/upload-url", "/v1/media/upload-url", false],
  ["PUT /v1/local-media/upload/:token", "/v1/local-media/upload/t0k3n", true],
  ["GET /v1/local-media/lite-media/*path", "/v1/local-media/lite-media/uploads/GABC/1.jpg", true],
  ["POST /v1/bridge/quote", "/v1/bridge/quote", false],
  ["POST /v1/bridge/start", "/v1/bridge/start", false],
  ["POST /v1/bridge/:id/source", `/v1/bridge/${ID}/source`, false],
  ["POST /v1/bridge/:id/claimed", `/v1/bridge/${ID}/claimed`, false],
  ["GET /v1/bridge/:id", `/v1/bridge/${ID}`, false],
  ["GET /v1/cash/anchors", "/v1/cash/anchors", false],
  ["POST /v1/cash/track", "/v1/cash/track", false],
  ["GET /v1/activity", "/v1/activity", false],
];

/** Viewer routes whose handlers serve the public view (§6.0) of the account ?address= names: 400 address_required
 *  without it. Earn's positions read Blend's pools, which the route harness can't reach: earn.test.ts covers their
 *  public view with a stand-in for the pool. */
const PUBLIC_VIEWS = ["GET /v1/account", "GET /v1/earn/positions", "GET /v1/moments/owned"];

/** Viewer routes whose handlers serve the public view (§6.0) and need no ?address=: what each answers with neither a
 *  token nor ?address= (the route harness has no launch at TOKEN and no Moment 7). */
const PUBLIC_BOARDS: Record<string, number> = {
  "GET /v1/launches": 200,
  "GET /v1/launches/:token": 404,
  "GET /v1/moments": 200,
  "GET /v1/moments/:id": 404,
};

/** Registered in their final place, answering 501 until written. */
const NOT_WRITTEN: string[] = [];

function request(spec: string, path: string, token: string | null): Request {
  const method = spec.split(" ")[0];
  return new Request(`http://127.0.0.1/functions/v1/lite${path}`, {
    method,
    headers: token ? { authorization: `Bearer ${token}` } : {},
    body: method === "GET" ? undefined : "{}",
  });
}

/** `got` holds everything `recorded` holds, unchanged: objects may have gained keys, nothing else may differ. */
function assertContains(got: unknown, recorded: unknown, at = "body"): void {
  if (Array.isArray(recorded)) {
    assert(Array.isArray(got) && got.length === recorded.length, `${at}: ${JSON.stringify(got)}`);
    recorded.forEach((v, i) => assertContains(got[i], v, `${at}[${i}]`));
  } else if (recorded !== null && typeof recorded === "object") {
    assert(got !== null && typeof got === "object" && !Array.isArray(got), `${at}: ${JSON.stringify(got)}`);
    for (const [k, v] of Object.entries(recorded)) assertContains((got as Record<string, unknown>)[k], v, `${at}.${k}`);
  } else {
    assertEquals(got, recorded, at);
  }
}

async function quietly<T>(fn: () => Promise<T>): Promise<T> {
  const error = console.error;
  console.error = () => {};
  try {
    return await fn();
  } finally {
    console.error = error;
  }
}

if (Deno.env.get("ROUTES_RECORD") === "1") {
  Deno.test("record every route's answers", async () => await record(handle));
} else {
  const token = await userToken();

  Deno.test("every route is in the table, in the order they match", () => {
    assertEquals(router.specs, ROUTES.map(([spec]) => spec));
  });

  Deno.test("every path reaches its own route, behind Supabase's prefix or not", () => {
    for (const [spec, path] of ROUTES) {
      const method = spec.split(" ")[0];
      assertEquals(router.match(method, `/functions/v1/lite${path}`)?.spec, spec, path);
      assertEquals(router.match(method, `/lite${path}`)?.spec, spec, path);
    }
  });

  Deno.test("Moments' static paths never reach /v1/moments/:id", async () => {
    assertEquals(router.match("GET", "/v1/moments/owned")?.spec, "GET /v1/moments/owned");
    assertEquals(router.match("GET", "/v1/moments/mine")?.spec, "GET /v1/moments/mine");
    const owned = await handle(request("GET /v1/moments/owned", "/v1/moments/owned", token));
    assertEquals([owned.status, await owned.json()], [200, { editions: [], view: "owner" }]);
    const mine = await handle(request("GET /v1/moments/mine", "/v1/moments/mine", token));
    assertEquals([mine.status, await mine.json()], [200, { created: [], collected: [], totals: { editions: 0, moments: 0, spentByQuote: {}, earnedByQuote: {} } }]);
  });

  Deno.test("public: sign-in, config, fees, market data, economics, Earn's markets and history; nothing else", () => {
    const open = [
      "POST /v1/auth/verify",
      "POST /v1/auth/refresh",
      "POST /v1/auth/signout",
      "GET /v1/config",
      "GET /v1/fees",
      "GET /v1/markets",
      "GET /v1/markets/:id",
      "GET /v1/markets/:id/history",
      "GET /v1/prices",
      "GET /v1/economics",
      "GET /v1/earn/markets",
      "GET /v1/earn/history",
    ];
    for (const r of open) assert(isPublic(r) && !isViewer(r), r);
    const closed = ["GET /v1/assets", "GET /v1/holdings", "GET /v1/portfolio", "GET /v1/feesx", "GET /v1/marketsx", "GET /v1/configs", "GET /v1/account"];
    for (const r of [...closed, "GET /v1/economicsx", "GET /v1/earn/positions", "POST /v1/earn/build", "GET /v1/earn/historyx", "GET /v1/earn/markets/x"]) {
      assert(!isPublic(r), r);
    }
    for (const [spec, , open] of ROUTES) if (open) assert(isPublic(spec), spec);
  });

  Deno.test("viewer: the on-chain reads, GET only; history, writes and quotes stay session routes", () => {
    const viewers = [
      "GET /v1/account",
      "GET /v1/holdings",
      "GET /v1/earn/positions",
      "GET /v1/moments/owned",
      "GET /v1/launches",
      "GET /v1/launches/:token",
      "GET /v1/moments",
      "GET /v1/moments/:id",
      "GET /v1/assets",
    ];
    for (const r of viewers) assert(isViewer(r) && !isPublic(r), r);
    const sessions = [
      "GET /v1/portfolio",
      "GET /v1/activity",
      "GET /v1/launchpad/me",
      "GET /v1/moments/mine",
      "GET /v1/tx/:hash",
      "POST /v1/account/activate",
      "POST /v1/launches/:token/quote",
      "POST /v1/launches/build",
      "POST /v1/moments/build",
      "POST /v1/account",
      "GET /v1/accounts",
      "GET /v1/account/x",
      "GET /v1/launches/:token/x",
    ];
    for (const r of sessions) assert(!isViewer(r) && !isPublic(r), r);
  });

  Deno.test("every route's class is the API contract's (_shared/contract.ts Routes)", async () => {
    const source = await Deno.readTextFile(new URL("../../supabase/functions/_shared/contract.ts", import.meta.url));
    const contract = new Map([...source.matchAll(/"([A-Z]+ \/v1\/[^"]+)":\s*\{\s*auth:\s*"(\w+)"/g)].map((m) => [m[1], m[2]]));
    assert(contract.size > 50, `${contract.size} routes in the contract`);
    const classOf = (spec: string) => (isPublic(spec) ? "public" : isViewer(spec) ? "viewer" : "session");
    for (const [spec, auth] of contract) {
      // The local media stand-in's upload carries its own signed token: public, as far as the session check goes.
      assertEquals(classOf(spec), auth === "upload" ? "public" : auth, spec);
    }
    // Every route served is in the contract (the media stand-in's path under its own parameter names).
    for (const spec of router.specs) {
      const named = spec.replace("lite-media/*path", "lite-media/:folder/:owner/:file");
      assert(contract.has(named), `${spec} isn't in the contract`);
    }
  });

  // Viewer routes pass the guard without a header. Those whose handlers serve the public view (PUBLIC_VIEWS) need
  // ?address= there; the launch and Moments boards and their pages (PUBLIC_BOARDS) need none. Until its package serves
  // it (WP-18) the other still asks for a session.
  Deno.test("without a session, every route answers 401 but the open ones, the public views and the public boards", async () => {
    for (const [spec, path, open] of ROUTES) {
      const res = await quietly(() => handle(request(spec, path, null)));
      const text = await res.text();
      if (PUBLIC_VIEWS.includes(spec)) assertEquals([res.status, JSON.parse(text).error.code], [400, "address_required"], spec);
      else if (Object.hasOwn(PUBLIC_BOARDS, spec)) assertEquals(res.status, PUBLIC_BOARDS[spec], spec);
      else if (open) assertNotEquals(res.status, 401, spec);
      else assertEquals([res.status, JSON.parse(text).error.message], [401, "Sign in on Stellar to continue."], spec);
    }
  });

  Deno.test("public views: ?address= with no token gets the public view, cached 15 s", async () => {
    for (const spec of PUBLIC_VIEWS.filter((s) => s !== "GET /v1/earn/positions")) {
      const [, path] = ROUTES.find(([s]) => s === spec)!;
      const res = await quietly(() => handle(request(spec, `${path}?address=${OTHER.publicKey()}`, null)));
      assertEquals([res.status, res.headers.get("cache-control"), (await res.json()).view], [200, "public, max-age=15", "public"], spec);
    }
  });

  Deno.test("the Moments feed and an account's editions: the public view with no token, cached 15 s; with a token, the owner's", async () => {
    for (const path of ["/v1/moments", `/v1/moments?address=${OTHER.publicKey()}`, `/v1/moments/owned?address=${OTHER.publicKey()}`]) {
      const res = await quietly(() => handle(request("GET /v1/moments", path, null)));
      assertEquals([res.status, res.headers.get("cache-control"), (await res.json()).view], [200, "public, max-age=15", "public"], path);
    }
    for (const path of ["/v1/moments", "/v1/moments/owned"]) {
      const owner = await quietly(() => handle(request("GET /v1/moments", path, token)));
      assertEquals([owner.status, owner.headers.get("cache-control"), (await owner.json()).view], [200, "no-store", "owner"], path);
    }
    // The local media stand-in answers only on a local testnet stack: here it isn't configured.
    for (const [spec, path] of ROUTES.filter(([s]) => s.includes("local-media"))) {
      const res = await quietly(() => handle(request(spec, path, null)));
      assertEquals([res.status, (await res.json()).error.code], [404, "not_found"], spec);
    }
  });

  Deno.test("the guard lets a viewer route through without an Authorization header, and checks one that is sent", async () => {
    const expired = await signJwt({ sub: USER.publicKey(), net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 1_760_400_060, iat: 1_760_400_000 });
    for (const spec of ROUTES.map(([s]) => s).filter(isViewer)) {
      const [, path] = ROUTES.find(([s]) => s === spec)!;
      // A stand-in handler shows whether the request got past the guard.
      const r = new Router().before(guard).on(spec, () => Promise.resolve(json({ reached: true })));
      const ask = (authorization?: string) =>
        r.handle(new Request(`http://127.0.0.1/functions/v1/lite${path}?address=${USER.publicKey()}`, { headers: authorization ? { authorization } : {} }));
      const anonymous = await ask();
      assertEquals([anonymous.status, await anonymous.json()], [200, { reached: true }], spec);
      const signedIn = await ask(`Bearer ${token}`);
      assertEquals([signedIn.status, await signedIn.json()], [200, { reached: true }], spec);
      for (const [authorization, message] of [["Bearer not-a-token", "Sign in again."], [`Bearer ${expired}`, "Your session expired. Sign in again."], ["Basic dXNlcg==", "Sign in on Stellar to continue."]]) {
        const refused = await ask(authorization);
        assertEquals([refused.status, (await refused.json()).error], [401, { code: "unauthorized", message, detail: null }], `${spec} ${authorization}`);
      }
    }
    // Session routes still need the JWT, whatever the query names.
    for (const spec of ["GET /v1/activity", "GET /v1/portfolio", "GET /v1/moments/mine", "POST /v1/send"]) {
      await assertRejects(() => guard(new Request(`http://127.0.0.1/lite/v1/x?address=${USER.publicKey()}`), spec), ApiError, "Sign in on Stellar to continue.");
    }
  });

  Deno.test("viewer routes: a bad or expired token gets 401 from the API, never the public view", async () => {
    const expired = await signJwt({ sub: USER.publicKey(), net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 1_760_400_060, iat: 1_760_400_000 });
    for (const [spec, path] of ROUTES.filter(([s]) => isViewer(s))) {
      for (const bad of ["not-a-token", expired]) {
        const res = await handle(request(spec, `${path}?address=${USER.publicKey()}`, bad));
        assertEquals([res.status, (await res.json()).error.code], [401, "unauthorized"], spec);
      }
    }
  });

  Deno.test("header-less viewer reads are limited to 120 a minute per IP", async () => {
    const r = new Router().before(guard).on("GET /v1/account", () => Promise.resolve(json({ reached: true })));
    const ask = () => r.handle(new Request("http://127.0.0.1/lite/v1/account", { headers: { "x-forwarded-for": "198.51.100.120" } }));
    for (let i = 0; i < 120; i++) assertEquals((await ask()).status, 200, `request ${i + 1}`);
    const over = await ask();
    assertEquals([over.status, (await over.json()).error.code], [429, "rate_limited"]);
  });

  Deno.test("viewer(): the token's account, or the public view of ?address=; accountViewer() needs one of them", async () => {
    const at = (query: string, authorization?: string) =>
      new Request(`http://127.0.0.1/functions/v1/lite/v1/account${query}`, { headers: authorization ? { authorization } : {} });
    const me = USER.publicKey();
    const other = OTHER.publicKey();
    assertEquals(await viewer(at(`?address=${other}`)), { address: other, scope: "public" });
    assertEquals(await viewer(at("")), { address: null, scope: "public" });
    // With a token, the token's account, whatever ?address= names.
    assertEquals(await viewer(at(`?address=${other}`, `Bearer ${token}`)), { address: me, scope: "owner" });
    await assertRejects(() => viewer(at("", "Bearer not-a-token")), ApiError, "Sign in again.");
    const badAddress = await viewer(at("?address=GNOPE")).catch((e) => e);
    assertEquals([badAddress.status, badAddress.code], [400, "bad_address"]);
    assertEquals(await accountViewer(at(`?address=${other}`)), { address: other, scope: "public" });
    assertEquals(await accountViewer(at("", `Bearer ${token}`)), { address: me, scope: "owner" });
    const missing = await accountViewer(at("")).catch((e) => e);
    const fixture = JSON.parse(await Deno.readTextFile(new URL("../fixtures/api/error-address-required.json", import.meta.url)));
    assertEquals({ error: { code: missing.code, message: missing.message, detail: null } }, fixture);
    assertEquals(missing.status, 400);
  });

  Deno.test("a POST body that is JSON but not an object is 400 bad_arg on every route that reads one (sign-in reads it as no fields)", async () => {
    const other = await signJwt({ sub: OTHER.publicKey(), net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 4_102_444_800, iat: 1_760_400_000 });
    const bodyless = ["POST /v1/account/activate", "POST /v1/account/faucet", "POST /v1/plans/:plan/steps/:step/build"];
    const reading = ROUTES.filter(([spec, , open]) => spec.startsWith("POST ") && !open && !bodyless.includes(spec) && !NOT_WRITTEN.includes(spec));
    assert(reading.length >= 15, `${reading.length} routes`);
    for (const [spec, path] of reading) {
      for (const body of ["null", "[]", '"x"', "7"]) {
        const res = await quietly(() => handle(new Request(`http://127.0.0.1/functions/v1/lite${path}`, { method: "POST", headers: { authorization: `Bearer ${other}` }, body })));
        assertEquals([res.status, (await res.json()).error.code], [400, "bad_arg"], `${spec} ${body}`);
      }
    }
  });

  Deno.test("routes not written yet answer 501, after the session check", async () => {
    for (const spec of NOT_WRITTEN) {
      const [, path] = ROUTES.find(([s]) => s === spec)!;
      const res = await handle(request(spec, path, token));
      assertEquals([res.status, (await res.json()).error.code], [501, "not_implemented"], spec);
    }
  });

  Deno.test("GET /v1/config serves every field of §6.2, with testnet's values", async () => {
    const res = await handle(request("GET /v1/config", "/v1/config", null));
    assertEquals([res.status, res.headers.get("cache-control")], [200, "public, max-age=30"]);
    const c = await res.json();
    assertEquals(Object.keys(c), [
      "network",
      "passphrase",
      "rpcUrl",
      "horizonUrl",
      "activation",
      "sponsor",
      "deployment",
      "explorer",
      "fees",
      "faucet",
      "limits",
      "pricing",
      "assets",
      "contracts",
      "allowlist",
      "anchors",
      "bridge",
      "flags",
      "minBuild",
      "inviteRequired",
    ]);
    assertEquals(c.network, "testnet");
    assertEquals(c.passphrase, "Test SDF Network ; September 2015");
    assertEquals(c.rpcUrl, "https://soroban-testnet.stellar.org");
    assertEquals(c.horizonUrl, "https://horizon-testnet.stellar.org");
    assertEquals(c.activation, "friendbot");
    assertEquals(c.sponsor, SPONSOR.publicKey());
    assertEquals(c.deployment, { id: "testnet", launchpad: testnetDeployment.launchpad, moments: testnetDeployment.moments });
    assertEquals(c.explorer, "https://stellar.expert/explorer/testnet");
    assertEquals(c.fees, { payer: "user", maxFee: "30000000", maxInclusionPerOp: "200000", starterInnerFeeMax: "1000000", starterSwap: false, fundingFloor: "1000000" });
    assertEquals(c.faucet, { amount: "10000" });
    assertEquals(c.limits, { momentMaxEditions: 100000, momentWindowSecs: [3600, 2592000], collectMax: 20, launchName: [1, 32], launchSymbol: [2, 10], uriMax: 256, uploadBytes: 26214400 });
    assertEquals(c.pricing, { kind: "reference", source: "Kraken", network: "mainnet", note: "Testnet assets have no market. XLM and USDC are valued at mainnet market prices." });
    assertEquals(Object.keys(c.assets[0]), ["id", "code", "name", "decimals", "contract", "classic", "note", "priceRef", "logo", "listed"]);
    assertEquals(c.assets.map((a: Record<string, unknown>) => [a.id, a.priceRef, a.logo, a.listed]), [["XLM", "XLM", "XLM", true], ["USDC", "USDC", "USDC", true], ["BUSDC", "USDC", null, false]]);
    assertEquals(c.contracts.launchpad, testnetDeployment.launchpad);
    assertEquals(c.flags, { enabled: true, maintenance: false });
    assertEquals(c.minBuild, 1);
    assertEquals(c.inviteRequired, false);
  });

  Deno.test("GET /v1/config: inviteRequired follows LITE_INVITE_REQUIRED on testnet, for QA", async () => {
    Deno.env.set("LITE_INVITE_REQUIRED", "1");
    try {
      assertEquals((await (await handle(request("GET /v1/config", "/v1/config", null))).json()).inviteRequired, true);
    } finally {
      Deno.env.delete("LITE_INVITE_REQUIRED");
    }
  });

  Deno.test("GET /v1/config: where activation is sponsored, the starter swap is offered", async () => {
    Deno.env.set("LITE_ACTIVATION", "sponsored");
    try {
      const c = await (await handle(request("GET /v1/config", "/v1/config", null))).json();
      assertEquals([c.activation, c.fees.starterSwap, c.fees.payer], ["sponsored", true, "user"]);
    } finally {
      Deno.env.delete("LITE_ACTIVATION");
    }
  });

  for (const r of ROUTE_REQUESTS) {
    Deno.test(`${r.method} ${r.path} answers as recorded (${r.name})`, async () => {
      const recorded: RecordedRoute = JSON.parse(await Deno.readTextFile(fixtureUrl(r.name)));
      const got = await send(handle, r, r.auth ? token : null);
      if (r.grown) {
        // Grown on purpose (r.grown says how): what was recorded is still there, unchanged.
        assertEquals([got.status, got.headers["content-type"]], [recorded.response.status, recorded.response.headers["content-type"]]);
        assertContains(got.body, recorded.response.body);
        return;
      }
      assertEquals({ status: got.status, headers: got.headers }, { status: recorded.response.status, headers: recorded.response.headers });
      assertEquals(got.text, JSON.stringify(recorded.response.body));
      if (r.auth) {
        const anonymous = await send(handle, r, null);
        assertEquals(anonymous.status, 401);
        assertEquals({ status: anonymous.status, headers: anonymous.headers }, { status: recorded.anonymous!.status, headers: recorded.anonymous!.headers });
        assertEquals(anonymous.text, JSON.stringify(recorded.anonymous!.body));
      }
    });
  }
}
