// The Lite API's routes (lite/index.ts and lite/routes/*.ts):
// - ROUTES lists every route in the order they match, each with a path that must reach it and no other;
// - only sign-in, config, fees, market data and the local media stand-in skip the session check;
// - GET /v1/config serves every field of docs/DESIGN-stellar-parity.md §6.2;
// - routes answer as they did before they moved from lite/index.ts into lite/routes/: the answers recorded then are
//   in backend/tests/fixtures/routes/<name>.json, and every request must get the same status, headers and body bytes
//   (config, which grew on purpose, keeps every recorded field).
// A package that adds a route adds it to ROUTES. One that changes a route's answer on purpose records them again, and
// the diff shows what changed:
//   ROUTES_RECORD=1 deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/router.test.ts
import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import testnetDeployment from "../../supabase/functions/_shared/deployments/testnet.json" with { type: "json" };
import { fakeSql, fixtureUrl, goOffline, record, RecordedRoute, ROUTE_REQUESTS, routeRows, send, setTestEnv, SPONSOR, TOKEN, userToken } from "../fixtures/routes/harness.ts";

setTestEnv();
goOffline();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
replaceSql(fakeSql(routeRows));
const { handle, isPublic, router } = await import("../../supabase/functions/lite/index.ts");

const ID = "3f1c2a9e-0000-4000-8000-000000000002";

/** [route, a path that reaches it, answers without a session]. */
const ROUTES: [string, string, boolean][] = [
  ["POST /v1/auth/challenge", "/v1/auth/challenge", true],
  ["POST /v1/auth/verify", "/v1/auth/verify", true],
  ["GET /v1/config", "/v1/config", true],
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
  // Public once it reads the reference cache (§6.6); until then its handler signs in.
  ["GET /v1/prices", "/v1/prices", false],
  ["GET /v1/launches", "/v1/launches", false],
  ["GET /v1/launches/:token", `/v1/launches/${TOKEN}`, false],
  ["POST /v1/launches/:token/quote", `/v1/launches/${TOKEN}/quote`, false],
  ["POST /v1/launches/build", "/v1/launches/build", false],
  ["POST /v1/launches/metadata", "/v1/launches/metadata", false],
  ["GET /v1/economics", "/v1/economics", false],
  ["GET /v1/launchpad/me", "/v1/launchpad/me", false],
  ["GET /v1/earn/markets", "/v1/earn/markets", false],
  ["GET /v1/earn/positions", "/v1/earn/positions", false],
  ["POST /v1/earn/build", "/v1/earn/build", false],
  ["GET /v1/earn/history", "/v1/earn/history", false],
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

/** Registered in their final place, answering 501 until written. */
const NOT_WRITTEN = [
  "GET /v1/recipient/:address",
  "POST /v1/launches/metadata",
  "GET /v1/economics",
  "GET /v1/launchpad/me",
  "GET /v1/earn/history",
  "GET /v1/moments/mine",
  "PUT /v1/local-media/upload/:token",
  "GET /v1/local-media/lite-media/*path",
];

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
    assertEquals([owned.status, await owned.json()], [200, { editions: [] }]);
    const mine = await handle(request("GET /v1/moments/mine", "/v1/moments/mine", token));
    assertEquals([mine.status, (await mine.json()).error.code], [501, "not_implemented"]);
  });

  Deno.test("config, fees and markets need no session; the rest do", () => {
    for (const r of ["GET /v1/config", "GET /v1/fees", "GET /v1/markets", "GET /v1/markets/:id", "GET /v1/markets/:id/history", "POST /v1/auth/verify"]) {
      assert(isPublic(r), r);
    }
    for (const r of ["GET /v1/assets", "GET /v1/holdings", "GET /v1/portfolio", "GET /v1/feesx", "GET /v1/marketsx", "GET /v1/configs", "GET /v1/account"]) {
      assert(!isPublic(r), r);
    }
    for (const [spec, , open] of ROUTES) if (open) assert(isPublic(spec), spec);
  });

  Deno.test("without a session, every route answers 401 but the open ones", async () => {
    for (const [spec, path, open] of ROUTES) {
      const res = await quietly(() => handle(request(spec, path, null)));
      const body = await res.json();
      if (open) assertNotEquals(res.status, 401, spec);
      else assertEquals([res.status, body.error.message], [401, "Sign in on Stellar to continue."], spec);
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
