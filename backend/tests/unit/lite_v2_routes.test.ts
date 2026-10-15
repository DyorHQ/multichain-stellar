// Contracts v2 in the API's routing (lite/index.ts): which generation answers each route both generations share (the
// generation of a launch: the indexer's row, else launchpad-v2), the wrapping that puts v2 in front of each shared
// route's v1 handler, v2's own routes, and GET /v1/economics' v2 body as the app's v1 model still decodes it
// (StellarKit Models+Launch.swift StellarEconomics) beside its v2 model (StellarEconomicsV2).
import { Address, nativeToScVal, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertFalse, assertRejects } from "jsr:@std/assert@1";
import type { Economics } from "../../supabase/functions/_shared/contract.ts";
import type { LaunchpadV2Economics } from "../../supabase/functions/_shared/launchpad_v2.ts";
import type { MomentsV2Economics, MomentsV2Policy } from "../../supabase/functions/_shared/moments_v2.ts";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();

const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const G = (n: number) => StrKey.encodeEd25519PublicKey(new Uint8Array(32).fill(n) as any);
const H = (n: number) => n.toString(16).padStart(2, "0").repeat(32);

const PAD = C(4);
const MOMENTS = C(5);
/** Launches the indexer has a row for: one per generation. */
const V1_TOKEN = C(30);
const V2_TOKEN = C(31);
/** Launches the indexer hasn't seen: one launchpad-v2 has, one it doesn't (a v1 launch, or no launch), and one asked
 *  while the RPC is down. */
const NEW_V2_TOKEN = C(32);
const NOT_V2_TOKEN = C(33);
const RPC_DOWN_TOKEN = C(34);

// testnet's v2 deployment, bundled as the owner's file is (deployments/index.ts BUNDLED_V2), before anything reads
// env.network. Mainnet has none: the tests that need a network without v2 use it.
const { BUNDLED_V2, DURATION_SETS_V2 } = await import("../../supabase/functions/_shared/deployments/index.ts");
(BUNDLED_V2 as Record<string, Record<string, unknown>>)["testnet-v2"] = {
  network: "testnet",
  deployment: "testnet",
  name: "testnet-v2",
  generation: 1,
  deployer: G(1),
  contracts: { execSoroswap: C(1), lpLocker: C(2), momentsGraduator: C(3), launchpadV2: PAD, momentsV2: MOMENTS },
  wasmHashes: { launchpadV2: H(1), launchTokenV2: H(2), execSoroswap: H(3), lpLocker: H(4), momentsV2: H(5), momentNft: H(6), momentCoin: H(7), momentsGraduator: H(8) },
  venues: [{ id: 0, kind: "Soroswap", executor: C(1), feeFraction: 0, enabled: true }],
  quotes: {},
  aquarius: { enabled: false, reason: "--aquarius off" },
  durations: { set: "production", launch: DURATION_SETS_V2.production.launch, moments: DURATION_SETS_V2.production.moments },
  ttl: { threshold: 120_960, extend_to: 518_400 },
  deployLedger: 5_300_000,
  deployedAt: "2026-10-15T18:00:00.000Z",
};

const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { env } = await import("../../supabase/functions/_shared/env.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
type Handler = import("../../supabase/functions/_shared/http.ts").Handler;
const { TESTNET, withDeploymentV2 } = await import("../../supabase/functions/_shared/networks.ts");
const { V2_ERRORS } = await import("../../supabase/functions/_shared/v2_errors.ts");
const lite = await import("../../supabase/functions/lite/index.ts");

const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!.contract;

// ------------------------------------------------------------------------------------------------ the stand-ins

/** The indexer's lite.launches rows (generation by token), and the queries asked of it. */
const GENERATIONS: Record<string, number> = { [V1_TOKEN]: 1, [V2_TOKEN]: 2 };
let queries: string[] = [];
replaceSql(fakeSql((q, params) => {
  queries.push(q);
  if (q === "select generation from lite.launches where token = ?") {
    const g = GENERATIONS[String(params[0])];
    return g === undefined ? [] : [{ generation: g }];
  }
  throw new Error(`unexpected query: ${q}`);
}));

const UNKNOWN_LAUNCH = V2_ERRORS.find((e) => e.source === "launchpad-v2" && e.name === "UnknownLaunch")!.code;

/** launchpad-v2's get_launch on testnet's RPC: NEW_V2_TOKEN is a launch, NOT_V2_TOKEN isn't (UnknownLaunch), and the RPC
 *  is down for RPC_DOWN_TOKEN. Everything else is offline. */
let rpcAsked: string[] = [];
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  if (new URL(req.url).host !== "soroban-testnet.stellar.org") return new Response("offline: unit tests make no network calls", { status: 503 });
  const body = await req.json();
  if (body.method !== "simulateTransaction") return new Response("offline", { status: 503 });
  const tx = TransactionBuilder.fromXDR(body.params.transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const token = Address.fromScVal(call.args()[0]).toString();
  rpcAsked.push(`${contract === PAD ? "launchpad-v2" : contract} ${call.functionName().toString()} ${token}`);
  if (token === RPC_DOWN_TOKEN) return new Response("unavailable", { status: 503 });
  const result = token === NEW_V2_TOKEN
    ? {
      latestLedger: 1,
      minResourceFee: "100",
      transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
      results: [{ auth: [], xdr: nativeToScVal({ token: NEW_V2_TOKEN }).toXDR("base64") }],
      events: [],
    }
    : { latestLedger: 1, error: `HostError: Error(Contract, #${UNKNOWN_LAUNCH})\n\nEvent log (newest first):\n   0: [Diagnostic Event] topics:[error, Error(Contract, #${UNKNOWN_LAUNCH})]` };
  return Response.json({ jsonrpc: "2.0", id: body.id, result });
}) as typeof fetch;

function fresh(): void {
  queries = [];
  rpcAsked = [];
}

/** Runs `f` on mainnet, which has no v2 deployment, and then back on testnet. */
async function withoutV2<R>(f: () => Promise<R>): Promise<R> {
  Deno.env.set("LITE_NETWORK", "mainnet");
  try {
    assertEquals(env.network.deploymentV2, null);
    return await f();
  } finally {
    Deno.env.set("LITE_NETWORK", "testnet");
  }
}

/** A stand-in for a route module's v1 handler: what it was asked, and the body it could still read. */
function v1Handler(): { handler: Handler; bodies: unknown[] } {
  const bodies: unknown[] = [];
  const handler: Handler = async ({ req }) => {
    const text = await req.text();
    bodies.push(text ? JSON.parse(text) : null);
    return new Response("v1");
  };
  return { handler, bodies };
}

/** A shared route's handler (SHARED_ROUTES) around `v1`, asked `method` `path` with `body` and no session. */
function ask(spec: string, v1: Handler, path: string, body?: unknown, params: Record<string, string> = {}): Promise<Response> {
  const url = new URL(`http://127.0.0.1${path}`);
  const req = new Request(url, { method: spec.split(" ")[0], headers: { "content-type": "application/json" }, body: body === undefined ? undefined : JSON.stringify(body) });
  return lite.SHARED_ROUTES[spec](v1)({ req, params, url });
}

/** Throws unless `p` fails as v2's handler does without a session: 401, never v1's answer. */
async function v2Answered(p: Promise<Response>, v1: { bodies: unknown[] }, what: string): Promise<void> {
  const err = await assertRejects(() => p, ApiError, undefined, what);
  assertEquals((err as InstanceType<typeof ApiError>).status, 401, what);
  assertEquals(v1.bodies.length, 0, `${what}: v1's handler ran`);
}

// ------------------------------------------------------------------------------------------------ a launch's generation

Deno.test("a launch's generation: the indexer's row first, then launchpad-v2, and v1 for a token launchpad-v2 doesn't know", async () => {
  const net = env.network;
  assertEquals(net.contracts.launchpadV2, PAD);

  fresh();
  assertEquals(await lite.launchGeneration(net, V2_TOKEN), 2);
  assertEquals(await lite.launchGeneration(net, V1_TOKEN), 1);
  assertEquals(rpcAsked, [], "an indexed launch never asks the chain");
  assertEquals(queries.length, 2);

  fresh();
  assertEquals(await lite.launchGeneration(net, NEW_V2_TOKEN), 2, "a v2 launch the indexer hasn't seen yet");
  assertEquals(await lite.launchGeneration(net, NOT_V2_TOKEN), 1, "launchpad-v2's UnknownLaunch: v1's to answer (404 if no launch)");
  assertEquals(rpcAsked, [`launchpad-v2 get_launch ${NEW_V2_TOKEN}`, `launchpad-v2 get_launch ${NOT_V2_TOKEN}`]);

  fresh();
  await assertRejects(() => lite.launchGeneration(net, RPC_DOWN_TOKEN), Error, undefined, "an RPC that doesn't answer is an error, never a guess");

  fresh();
  assertEquals(await lite.launchGeneration(net, "not-a-contract"), 1);
  assertEquals(await lite.launchGeneration(withDeploymentV2(net, null), V2_TOKEN), 1, "a network without launchpad-v2 is v1's");
  assertEquals([...queries, ...rpcAsked], [], "neither reads anything");
});

// ------------------------------------------------------------------------------------------------ the requests

Deno.test("POST /v1/launches/build: create and v2's own actions are v2's; harvest, unknown actions and v1 launches are v1's", async () => {
  const asked: string[] = [];
  const generationOf = (token: string) => {
    asked.push(token);
    return Promise.resolve(token === V2_TOKEN ? 2 as const : 1 as const);
  };
  const net = env.network;
  const v2 = (b: Record<string, unknown>) => lite.isLaunchV2Request(net, b, generationOf);

  for (const action of ["create", "refund", "graduate_fallback", "mark_stuck", "rescue", "claim_owed", "claim_rewards", "recipient_transfer", "recipient_cancel", "recipient_execute"]) {
    assert(await v2({ action, token: V1_TOKEN }), `${action} is v2's alone`);
  }
  assertEquals(asked, [], "none of them asks the launch's generation");

  // harvest is a step v2's plans add themselves (V7), never a request; anything unknown is v1's to refuse.
  for (const b of [{ action: "harvest", token: V2_TOKEN }, { action: "bogus" }, { action: "toString" }, { action: 7 }, {}]) {
    assertFalse(await v2(b), JSON.stringify(b));
  }
  assertEquals(asked, []);

  for (const action of ["buy", "sell", "graduate", "claim"]) {
    assert(await v2({ action, token: V2_TOKEN }), `${action} on a v2 launch`);
    assertFalse(await v2({ action, token: V1_TOKEN }), `${action} on a v1 launch`);
  }
  // v1's claim without a token claims every launch the creator made.
  assertFalse(await v2({ action: "claim" }));
  assertFalse(await v2({ action: "buy", token: 31 }));
  assertEquals(asked.length, 8, "only a shared action naming a token asks its generation");

  fresh();
  assert(await lite.isLaunchV2Request(net, { action: "sell", token: V2_TOKEN }), "by default the indexer's row says");
  assertFalse(await lite.isLaunchV2Request(net, { action: "sell", token: NOT_V2_TOKEN }), "and launchpad-v2 where it has none");
});

Deno.test("POST /v1/moments/build: every v2 action is v2's but a collect naming a v1 Moment's number", () => {
  for (const action of ["publish", "collect", "claim", "claim_all", "withdraw", "graduate", "expire"]) {
    assert(lite.isMomentV2Request({ action, nft: C(40) }), action);
  }
  assertFalse(lite.isMomentV2Request({ action: "collect", momentId: 3, quantity: 1 }), "v1's collect names momentId");
  assertFalse(lite.isMomentV2Request({ action: "collect", momentId: 3, nft: C(40) }), "momentId decides");
  for (const b of [{ action: "bogus" }, { action: "toString" }, { action: 1 }, {}]) assertFalse(lite.isMomentV2Request(b), JSON.stringify(b));
});

// ------------------------------------------------------------------------------------------------ the shared routes

Deno.test("the shared routes wrap their module's v1 handler, and only they do", () => {
  const router = new lite.LiteRouter();
  const plain: Handler = () => Promise.resolve(new Response("plain"));
  for (const spec of Object.keys(lite.SHARED_ROUTES)) router.on(spec, plain);
  router.on("GET /v1/moments/:id", plain);
  for (const spec of Object.keys(lite.SHARED_ROUTES)) {
    const path = spec.split(" ")[1].replace(":token", V1_TOKEN);
    const m = router.match(spec.split(" ")[0], path)!;
    assertEquals(m.spec, spec);
    assert(m.handler !== plain, `${spec} is wrapped`);
  }
  assert(router.match("GET", "/v1/moments/3")!.handler === plain, "any other route is registered as given");

  for (const spec of Object.keys(lite.SHARED_ROUTES)) {
    assertEquals(lite.router.specs.filter((s) => s === spec).length, 1, `the API registers ${spec} once`);
  }
});

Deno.test("v2's own routes: registered where they match, with their auth classes", () => {
  const routes: [string, string, string, "public" | "viewer" | "session"][] = [
    ["POST /v1/launches/preview", "POST", "/v1/launches/preview", "session"],
    ["GET /v1/launches/:token/state", "GET", `/v1/launches/${V2_TOKEN}/state`, "viewer"],
    ["GET /v1/moments/:nft/status", "GET", `/v1/moments/${C(40)}/status`, "public"],
    ["GET /v1/moments/:nft/vesting", "GET", `/v1/moments/${C(40)}/vesting`, "viewer"],
  ];
  for (const [spec, method, path, auth] of routes) {
    assertEquals(lite.router.match(method, path)?.spec, spec, `${method} ${path}`);
    assertEquals(lite.isPublic(spec), auth === "public", `${spec} is ${auth}`);
    assertEquals(lite.isViewer(spec), auth === "viewer", `${spec} is ${auth}`);
  }
  // v1's routes beside them still match as before.
  assertEquals(lite.router.match("GET", `/v1/launches/${V1_TOKEN}`)?.spec, "GET /v1/launches/:token");
  assertEquals(lite.router.match("POST", `/v1/launches/${V1_TOKEN}/quote`)?.spec, "POST /v1/launches/:token/quote");
  assertEquals(lite.router.match("GET", "/v1/moments/3")?.spec, "GET /v1/moments/:id");
});

Deno.test("without a v2 deployment every shared route is v1's, its request intact", async () => {
  await withoutV2(async () => {
    const cases: [string, string, unknown, Record<string, string>][] = [
      ["GET /v1/economics", "/v1/economics", undefined, {}],
      ["POST /v1/launches/:token/quote", `/v1/launches/${V2_TOKEN}/quote`, { side: "buy", amount: "10000000" }, { token: V2_TOKEN }],
      ["POST /v1/launches/build", "/v1/launches/build", { action: "create", name: "Cat", symbol: "CAT" }, {}],
      ["POST /v1/moments/build", "/v1/moments/build", { action: "publish", uri: "u" }, {}],
    ];
    for (const [spec, path, body, params] of cases) {
      fresh();
      const v1 = v1Handler();
      assertEquals(await (await ask(spec, v1.handler, path, body, params)).text(), "v1", spec);
      assertEquals(v1.bodies, [body ?? null], `${spec}: v1 reads the request's body`);
      assertEquals([...queries, ...rpcAsked], [], `${spec}: nothing is asked of v2`);
    }
  });
});

Deno.test("with v2 deployed, each shared route answers v2's requests and leaves v1's to v1, its body intact", async () => {
  const launchBuild = "POST /v1/launches/build";
  for (const body of [{ action: "harvest", token: V2_TOKEN }, { action: "claim" }, { action: "buy", token: V1_TOKEN, amount: "1" }, { action: "bogus" }]) {
    const v1 = v1Handler();
    assertEquals(await (await ask(launchBuild, v1.handler, "/v1/launches/build", body)).text(), "v1", JSON.stringify(body));
    assertEquals(v1.bodies, [body], `${JSON.stringify(body)}: v1 reads the body the wrapper read first`);
  }
  for (const body of [{ action: "create", name: "Cat", symbol: "CAT" }, { action: "buy", token: V2_TOKEN, amount: "1" }, { action: "rescue", token: V1_TOKEN }]) {
    const v1 = v1Handler();
    await v2Answered(ask(launchBuild, v1.handler, "/v1/launches/build", body), v1, `${launchBuild} ${JSON.stringify(body)}`);
  }

  const momentBuild = "POST /v1/moments/build";
  const v1Collect = { action: "collect", momentId: 3, quantity: 1 };
  const m1 = v1Handler();
  assertEquals(await (await ask(momentBuild, m1.handler, "/v1/moments/build", v1Collect)).text(), "v1");
  assertEquals(m1.bodies, [v1Collect]);
  const m2 = v1Handler();
  await v2Answered(ask(momentBuild, m2.handler, "/v1/moments/build", { action: "collect", nft: C(40), quantity: 1 }), m2, "a v2 collect");

  const quote = "POST /v1/launches/:token/quote";
  const trade = { side: "buy", amount: "10000000" };
  const q1 = v1Handler();
  assertEquals(await (await ask(quote, q1.handler, `/v1/launches/${V1_TOKEN}/quote`, trade, { token: V1_TOKEN })).text(), "v1");
  assertEquals(q1.bodies, [trade]);
  const q2 = v1Handler();
  await v2Answered(ask(quote, q2.handler, `/v1/launches/${V2_TOKEN}/quote`, trade, { token: V2_TOKEN }), q2, "a quote on a v2 launch");
});

Deno.test("a launch quote's body is checked before its launch's generation: 400 on a token of either generation, nothing asked", async () => {
  const quote = "POST /v1/launches/:token/quote";
  const cases: [unknown, number, string, string][] = [
    [{ side: "hold", amount: "1" }, 400, "bad_side", "side is buy, sell or refund."],
    [{ side: "buy", amount: "0" }, 400, "bad_amount", "amount must be positive."],
    [{ side: "refund", amount: "1.5" }, 400, "bad_amount", "amount must be a whole number of base units, as a string."],
    [[], 400, "bad_arg", "The request body must be a JSON object."],
  ];
  for (const token of [V1_TOKEN, V2_TOKEN, RPC_DOWN_TOKEN]) {
    for (const [body, status, code, message] of cases) {
      fresh();
      const v1 = v1Handler();
      const err = await assertRejects(() => ask(quote, v1.handler, `/v1/launches/${token}/quote`, body, { token }), ApiError);
      const e = err as InstanceType<typeof ApiError>;
      assertEquals([e.status, e.code, e.message], [status, code, message], `${token} ${JSON.stringify(body)}`);
      assertEquals([...queries, ...rpcAsked, ...v1.bodies], [], `${JSON.stringify(body)}: nothing asked, v1 not run`);
    }
  }
});

// ------------------------------------------------------------------------------------------------ the economics

const POLICY: MomentsV2Policy = {
  threshold: "100000000",
  minPrice: "1000000",
  creatorBps: 2_000,
  platformBps: 500,
  reserveBps: 7_500,
  maxCreatorAllocBps: 1_000,
  expiryCreatorBps: 5_000,
  royaltyBps: 500,
  platform: G(6),
  treasury: G(5),
};

const LAUNCHPAD: LaunchpadV2Economics = {
  contract: PAD,
  generation: 2,
  launchesEnabled: true,
  whitelistEnabled: false,
  supply: "10000000000000000",
  feeBps: 100,
  protocolShareBps: 5_000,
  maxCreatorFeeBps: 100,
  snipeSchedule: [5_000, 2_500, 1_000],
  snipeStepSecs: 5,
  launchFee: { asset: "XLM", contract: XLM, amount: "100000000", booked: true },
  treasury: G(5),
  locker: C(2),
  venues: [{ id: 0, kind: "Soroswap", name: "Soroswap", executor: C(1), enabled: true, feeFraction: 0 }],
  quotes: [
    {
      asset: "XLM",
      code: "XLM",
      contract: XLM,
      phantom: "30000000000",
      threshold: "43245553200",
      enabled: true,
      venuesAllowed: [],
      fallbackVenue: 0,
      venueLocked: false,
      defaultVenue: 0,
      terms: null,
    },
  ],
  durations: {
    grace: 3_600,
    fallbackDelay: 86_400,
    rescueAdmin: 604_800,
    rescuePublic: 1_209_600,
    lockedFallback: 604_800,
    takeoverDelay: 172_800,
    takeoverWindow: 604_800,
    timelock: 172_800,
    timelockWindow: 604_800,
    harvestInterval: 86_400,
  },
  harvest: {
    intervalSecs: 86_400,
    roundCapBps: 1_000,
    harvestBps: 5_000,
    split: { protocolBps: 5_000, creatorOrHoldersBps: 5_000 },
    splitPinnedPerLaunch: true,
    sides: ["quote", "token"],
    holdersPaidIn: ["quote", "token"],
    treasuryLaunchTokens: "held",
  },
  exclusionFloor: { minPoolTokens: "1", minPendingQuote: "1", minPendingTokens: "1" },
  aquariusFloat: null,
};

function momentsBlock(paused: { publishing?: boolean; guardian?: boolean } = {}): MomentsV2Economics {
  return {
    generation: 2,
    contract: MOMENTS,
    quote: { asset: "USDC", contract: USDC },
    supply: "1000000000000000",
    maxPerCollect: 20,
    maxClaimIds: 25,
    policy: POLICY,
    pendingPolicy: null,
    terms: {
      policy: POLICY,
      externalBase: "https://dyorhq.fun/m/",
      nftWasmHash: H(6),
      coinWasmHash: H(7),
      graduator: C(3),
      executor: C(1),
      locker: C(2),
      durations: { vestPeriod: 86_400, stuckExpiry: 86_400, pendingBackstop: 259_200, timelock: 172_800, timelockWindow: 604_800, minWindow: 3_600, maxWindow: 2_592_000, harvestInterval: 86_400 },
      harvestBps: 5_000,
      harvestCreatorBps: 5_000,
      harvest: { intervalSecs: 86_400, harvestedBps: 5_000, compoundedBps: 5_000, ratio: "1:1", quoteSide: { creatorBps: 5_000, platformBps: 5_000 }, coinSide: "burned" },
    },
    publishingPaused: paused.publishing ?? false,
    guardianPaused: paused.guardian ?? false,
    completionGross: "133333334",
    maxPrice: "133333334",
    fdvAtOpen: "1500000000",
    fdvAtOpenUsd: 150,
    fdvByAllocation: [{ allocationBps: 0, fdv: "1333333340", fdvUsd: 133.33 }],
  };
}

type Field = "string" | "int" | "boolean" | "array";

/** StellarEconomics, v1's model (StellarKit Models+Launch.swift): every field it decodes, none optional inside a block,
 *  with the JSON it decodes from (an Int from a whole number). */
const V1_MODEL: Record<string, Record<string, Field>> = {
  launchpad: {
    contract: "string",
    launchesEnabled: "boolean",
    supply: "string",
    feeBps: "int",
    protocolShareBps: "int",
    maxCreatorFeeBps: "int",
    snipeSchedule: "array",
    quotes: "array",
  },
  launchpadQuote: { asset: "string", contract: "string", phantom: "string", threshold: "string", enabled: "boolean" },
  moments: {
    contract: "string",
    platformBps: "int",
    royaltyBps: "int",
    publishingEnabled: "boolean",
    treasury: "string",
    maxPerCollect: "int",
    maxEditions: "int",
    quotes: "array",
  },
  momentsQuote: { asset: "string", minPrice: "string", enabled: "boolean" },
};

/** Whether `v` decodes as `field`. */
const DECODES: Record<Field, (v: unknown) => boolean> = {
  string: (v) => typeof v === "string",
  int: Number.isInteger,
  boolean: (v) => typeof v === "boolean",
  array: Array.isArray,
};

function decodes(what: string, v: Record<string, unknown>, model: Record<string, Field>): void {
  for (const [key, field] of Object.entries(model)) {
    const got = v[key];
    const ok = DECODES[field](got);
    assert(ok, `${what}.${key}: ${JSON.stringify(got)} doesn't decode as ${field}`);
  }
}

Deno.test("GET /v1/economics' v2 body still decodes as the app's v1 model, and its v2 blocks are untouched", () => {
  const net = env.network;
  const moments = momentsBlock();
  const body = lite.economicsBodyV2(LAUNCHPAD, moments, net);
  // The API contract's v1 shape (contract.ts Economics), checked by the compiler.
  const asV1: Economics = body;
  assert(asV1.moments !== null);

  const wire = JSON.parse(JSON.stringify(body));
  decodes("launchpad", wire.launchpad, V1_MODEL.launchpad);
  assert(wire.launchpad.snipeSchedule.every(Number.isInteger));
  for (const q of wire.launchpad.quotes) decodes("launchpad.quotes[]", q, V1_MODEL.launchpadQuote);
  decodes("moments", wire.moments, V1_MODEL.moments);
  for (const q of wire.moments.quotes) decodes("moments.quotes[]", q, V1_MODEL.momentsQuote);

  // v1's names state v2's terms.
  assertEquals(wire.moments.platformBps, POLICY.platformBps);
  assertEquals(wire.moments.royaltyBps, POLICY.royaltyBps);
  assertEquals(wire.moments.treasury, POLICY.treasury);
  assertEquals(wire.moments.maxEditions, net.limits.momentMaxEditions);
  assertEquals(wire.moments.publishingEnabled, true);
  assertEquals(wire.moments.quotes, [{ asset: "USDC", minPrice: POLICY.minPrice, enabled: true }]);

  // StellarEconomicsV2 reads each block by its generation 2; v1's names add to the Moments block and replace nothing.
  assertEquals(wire.launchpad, JSON.parse(JSON.stringify(LAUNCHPAD)));
  for (const [key, value] of Object.entries(JSON.parse(JSON.stringify(moments)))) assertEquals(wire.moments[key], value, `moments.${key}`);
  assertEquals(wire.moments.generation, 2);

  for (const paused of [{ publishing: true }, { guardian: true }]) {
    const closed = lite.economicsBodyV2(LAUNCHPAD, momentsBlock(paused), net).moments;
    assertFalse(closed.publishingEnabled, JSON.stringify(paused));
    assertFalse(closed.quotes[0].enabled, JSON.stringify(paused));
  }
  assertEquals(lite.economicsBodyV2(null, moments, net).launchpad, null, "v1's model reads a missing launchpad as not deployed");
});
