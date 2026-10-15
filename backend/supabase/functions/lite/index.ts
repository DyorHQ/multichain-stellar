// DyorHQ Lite API (Stellar). Deployed as the `lite` Edge Function with verify_jwt = false: the API checks the Lite JWT
// and the tester allowlist itself, here, before any route that needs a session runs. Routes live in routes/<area>.ts
// (docs/DESIGN-stellar-parity.md §6.1) and match in the order the modules register below; contracts v2's are wired
// here (below).
// Every plan step's builder registers itself when its module loads: load them all, whichever routes use them. Launchpad
// v2's builders are registered below, from the table launchpad_v2.ts exports.
import "../_shared/account.ts";
import "../_shared/swap.ts";
import "../_shared/earn.ts";
import "../_shared/launchpad.ts";
import "../_shared/moments.ts";
import "../_shared/moments_v2.ts";
import "../_shared/bridge.ts";
import { sql } from "../_shared/db.ts";
import { env } from "../_shared/env.ts";
import { amountArg, ApiError, bad, clientIp, Handler, json, PUBLIC_CACHE, PUBLIC_VIEW_CACHE, rateLimit, readJson, Router } from "../_shared/http.ts";
import {
  buildLaunchV2,
  LAUNCH_V2_BUILDERS,
  LAUNCH_V2_STEPS,
  LaunchpadV2Economics,
  LaunchV2BuildInput,
  launchpadV2Economics,
  launchPreviewV2,
  launchStateV2,
  quoteTradeV2,
  v2Refusal,
} from "../_shared/launchpad_v2.ts";
import { buildMomentV2, momentsEconomicsV2, MomentsV2Economics, momentStatusV2, momentVestingV2, PLAN_KINDS as MOMENT_V2_PLAN_KINDS } from "../_shared/moments_v2.ts";
import { NetworkConfig } from "../_shared/networks.ts";
import { registerBuilder } from "../_shared/plans.ts";
import { isContractId, sv, view } from "../_shared/stellar.ts";
import * as account from "./routes/account.ts";
import * as activity from "./routes/activity.ts";
import * as assets from "./routes/assets.ts";
import * as auth from "./routes/auth.ts";
import * as bridge from "./routes/bridge.ts";
import * as config from "./routes/config.ts";
import * as earn from "./routes/earn.ts";
import * as fees from "./routes/fees.ts";
import * as holdings from "./routes/holdings.ts";
import * as launches from "./routes/launches.ts";
import * as markets from "./routes/markets.ts";
import * as moments from "./routes/moments.ts";
import * as plans from "./routes/plans.ts";
import * as portfolio from "./routes/portfolio.ts";
import * as swap from "./routes/swap.ts";

/** Routes anyone may call (§6.0): sign-in, the network's configuration, fees, market data, the launchpad's economics,
 *  Earn's markets and rate history, a v2 Moment's status (read live from its contract), and the local stack's stand-in
 *  for public Storage, whose uploads carry their own signature. None reads an account's data. */
const PUBLIC = /^[A-Z]+ \/v1\/(auth\/|config$|fees$|markets(\/|$)|prices$|economics$|earn\/(markets|history)$|moments\/:nft\/status$|local-media\/)/;

/** Reads of on-chain facts, whose session is optional (§6.0, §6.18): with a token, the owner's view; with no
 *  Authorization header, the public view of ?address= (routes/auth.ts viewer()). A v2 launch's state, an account's
 *  vesting in a v2 Moment, and the v2 Moments feed, a v2 Moment's page and an account's v2 editions are such reads; the
 *  v2 Moments a creator published are DyorHQ's history (a session route, as v1's are). */
const VIEWER = /^GET \/v1\/(account|holdings|earn\/positions|moments\/owned|launches(\/:token(\/state)?)?|moments(\/:id|\/:nft\/vesting)?|moments\/v2(\/owned|\/:nft)?|assets)$/;

export function isPublic(route: string): boolean {
  return PUBLIC.test(route);
}

export function isViewer(route: string): boolean {
  return VIEWER.test(route);
}

/** Runs before every route's handler. Public routes, and viewer routes asked without an Authorization header, are
 *  rate-limited per IP; everything else needs a valid session (401, or 403 for a revoked tester), viewer routes that
 *  carry a token included. */
export async function guard(req: Request, route: string): Promise<void> {
  if (isPublic(route)) rateLimit(`public:${clientIp(req)}`, 300);
  else if (isViewer(route) && !auth.hasToken(req)) rateLimit(`view:${clientIp(req)}`, 120);
  else await auth.user(req);
}

// ------------------------------------------------------------------------------------------------ contracts v2

// Contracts v2 (docs/DESIGN-stellar-contracts-v2.md §20; the phone's LiteClient LaunchpadV2.swift and MomentsV2.swift).
// - v2's own routes: a launch's preview (the terms it would bind, its 10 XLM fee and Max), a launch's live state, a
//   Moment's status and an account's vesting in a Moment.
// - The routes both generations share (the economics, a launch's quote and plans, Moments' plans) keep their route
//   module's handler for v1, wrapped here: v2's requests are answered by the v2 modules, every other request as
//   before. v1 is retired but not gone: its launches keep trading and claiming and its Moments stay collectible
//   (deployments/index.ts GENERATIONS).
// - Where the network has no v2 deployment (deploymentV2 null), each shared route is v1's alone and v2's own routes
//   answer 503 not_deployed.

for (const [kind, builder] of Object.entries(LAUNCH_V2_BUILDERS)) registerBuilder(kind, builder);

/** The launch actions v1 has too (launchpad.ts buildLaunch); every other v2 action is v2's alone. */
const LAUNCH_V1_ACTIONS = new Set(["create", "buy", "sell", "graduate", "claim"]);

/** The generation of the launch `token`. The indexer's row says; a launch it hasn't indexed yet is asked of launchpad-v2,
 *  and one that launchpad-v2 doesn't know is v1's (whose routes answer 404 for a token that is no launch). */
export async function launchGeneration(net: NetworkConfig, token: string): Promise<1 | 2> {
  if (!net.contracts.launchpadV2 || !isContractId(token)) return 1;
  const [row] = await sql()`select generation from lite.launches where token = ${token}`;
  if (row) return Number(row.generation) === 2 ? 2 : 1;
  try {
    await view(net.contracts.launchpadV2, "get_launch", [sv.addr(token)]);
    return 2;
  } catch (err) {
    const refusal = v2Refusal(err);
    if (refusal instanceof ApiError && refusal.status === 404) return 1;
    throw refusal;
  }
}

/** Whether a POST /v1/launches/build body is v2's (LaunchRequestV2): create (new launches are v2's), an action only v2
 *  has, or a shared action on a v2 launch. Anything else, an unknown action included, is v1's to answer.
 *  `generationOf` is launchGeneration's answer for a token (tests answer it themselves). */
export async function isLaunchV2Request(
  net: NetworkConfig,
  b: Record<string, unknown>,
  generationOf: (token: string) => Promise<1 | 2> = (token) => launchGeneration(net, token),
): Promise<boolean> {
  const action = b.action;
  if (typeof action !== "string" || action === "harvest" || !Object.hasOwn(LAUNCH_V2_STEPS, action)) return false;
  if (action === "create" || !LAUNCH_V1_ACTIONS.has(action)) return true;
  // v1's claim without a token claims every launch the creator made; v2's names its launch.
  return typeof b.token === "string" && (await generationOf(b.token)) === 2;
}

/** Whether a POST /v1/moments/build body is v2's (MomentRequestV2): every v2 action, keyed by the NFT address, but a
 *  collect of a v1 Moment, which names its number (momentId). */
export function isMomentV2Request(b: Record<string, unknown>): boolean {
  const action = b.action;
  if (typeof action !== "string" || !Object.hasOwn(MOMENT_V2_PLAN_KINDS, action)) return false;
  return !(action === "collect" && b.momentId !== undefined);
}

/** The last graduation failure the indexer recorded for a stuck v2 launch or a v2 Moment pending graduation (V10),
 *  which the status reads name as recorded. Null when there is none, and when the database can't say: the read then
 *  simulates the failure instead. */
async function recordedFailure(read: () => Promise<Record<string, unknown>[]>): Promise<{ origin: number; code: number } | null> {
  try {
    const [row] = await read();
    return row && row.fail_origin !== null && row.fail_code !== null ? { origin: Number(row.fail_origin), code: Number(row.fail_code) } : null;
  } catch (err) {
    console.warn("recorded graduation failure unavailable:", String((err as Error).message ?? err).slice(0, 200));
    return null;
  }
}

function launchFailure(net: NetworkConfig, token: string) {
  if (!net.deploymentV2 || !isContractId(token)) return Promise.resolve(null);
  return recordedFailure(() => sql()`select fail_origin, fail_code from lite.launches where token = ${token} and generation = 2 and stuck_since is not null`);
}

function momentFailure(net: NetworkConfig, nft: string) {
  if (!net.deploymentV2 || !isContractId(nft)) return Promise.resolve(null);
  return recordedFailure(() => sql()`select fail_origin, fail_code from lite.moments where nft = ${nft} and generation = 2 and stuck_since is not null`);
}

/** v1's names for the Moments terms (StellarEconomics.Moments), from v2's block: the app's v1 model still decodes
 *  GET /v1/economics once the block is v2's. */
function momentsV1Names(m: MomentsV2Economics, net: NetworkConfig) {
  const open = !m.publishingPaused && !m.guardianPaused;
  return {
    platformBps: m.policy.platformBps,
    royaltyBps: m.policy.royaltyBps,
    publishingEnabled: open,
    treasury: m.policy.treasury,
    maxEditions: net.limits.momentMaxEditions,
    quotes: [{ asset: m.quote.asset, minPrice: m.policy.minPrice, enabled: open }],
  };
}

/** GET /v1/economics' body where v2 is deployed (§20.2), from v2's blocks, each with generation 2. The phone's v2 model
 *  reads them (StellarEconomicsV2); its v1 model still decodes them, because the launchpad block holds every field of
 *  v1's and the Moments block gains v1's names for the same terms, none of which is a v2 field. */
export function economicsBodyV2(launchpad: LaunchpadV2Economics | null, moments: MomentsV2Economics, net: NetworkConfig) {
  return { launchpad, moments: { ...moments, ...momentsV1Names(moments, net) } };
}

/** v2's blocks, read live and kept 5 minutes. */
async function economicsV2(net: NetworkConfig) {
  const [launchpad, moments] = await Promise.all([launchpadV2Economics(net), momentsEconomicsV2(net)]);
  return economicsBodyV2(launchpad, moments, net);
}

/** The routes both generations share, each wrapped around its route module's own (v1) handler. */
export const SHARED_ROUTES: Record<string, (v1: Handler) => Handler> = {
  "GET /v1/economics": (v1) => async (ctx) => {
    const net = env.network;
    return net.deploymentV2 ? json(await economicsV2(net), 200, PUBLIC_CACHE) : await v1(ctx);
  },

  // Buy, sell and, on a rescued launch, refund (at its fixed rate, no fees). The request is checked before the launch's
  // generation is looked up, so a bad body is 400 on launches of either generation, and never waits on the RPC.
  "POST /v1/launches/:token/quote": (v1) => async (ctx) => {
    const net = env.network;
    if (!net.deploymentV2) return await v1(ctx);
    const b = await readJson(ctx.req.clone());
    if (b.side !== "buy" && b.side !== "sell" && b.side !== "refund") throw bad("bad_side", "side is buy, sell or refund.");
    const amount = amountArg(b.amount, "amount");
    if ((await launchGeneration(net, ctx.params.token)) === 1) return await v1(ctx);
    return json(await quoteTradeV2(await auth.user(ctx.req), ctx.params.token, b.side, amount));
  },

  // Every v2 launch action; a recipient change answers its harvest backlog beside the plan (V7).
  "POST /v1/launches/build": (v1) => async (ctx) => {
    const net = env.network;
    if (!net.deploymentV2) return await v1(ctx);
    const b = await readJson(ctx.req.clone());
    if (!(await isLaunchV2Request(net, b))) return await v1(ctx);
    return json(await buildLaunchV2(await auth.user(ctx.req), b as Partial<LaunchV2BuildInput>));
  },

  // Publish, collect, claim, claim all, withdraw, graduate and expire, keyed by the Moment's NFT address.
  "POST /v1/moments/build": (v1) => async (ctx) => {
    if (!env.network.deploymentV2) return await v1(ctx);
    const b = await readJson(ctx.req.clone());
    return isMomentV2Request(b) ? json(await buildMomentV2(await auth.user(ctx.req), b)) : await v1(ctx);
  },
};

/** v2's own routes. */
const contractsV2 = {
  register(router: Router): void {
    // The terms a launch would bind now, its fee, the Create screen's Max and any XLM shortfall (§20.3, F18, V12).
    router.on("POST /v1/launches/preview", async ({ req }) => json(await launchPreviewV2(await auth.user(req), await readJson(req))));

    // Status, recipient, takeover, creator fees, holder rewards and the viewer's owed fees: `you` is the session's
    // account or ?address='s, null with neither.
    router.on("GET /v1/launches/:token/state", async ({ req, params }) => {
      const v = await auth.viewer(req);
      const state = await launchStateV2(params.token, v.address, { failure: await launchFailure(env.network, params.token) });
      return v.scope === "public" ? json(state, 200, PUBLIC_VIEW_CACHE) : json(state);
    });

    // A Moment's state and when it may expire (V11). Public, and kept 15 s like a viewer route's public view.
    router.on("GET /v1/moments/:nft/status", async ({ params }) => {
      const status = await momentStatusV2(params.nft, { recorded: await momentFailure(env.network, params.nft) });
      return json(status, 200, PUBLIC_VIEW_CACHE);
    });

    // The account's coins in a Moment: the session's, or ?address='s (400 address_required with neither).
    router.on("GET /v1/moments/:nft/vesting", async ({ req, params }) => {
      const v = await auth.accountViewer(req);
      const vesting = await momentVestingV2(params.nft, v.address);
      return v.scope === "public" ? json(vesting, 200, PUBLIC_VIEW_CACHE) : json(vesting);
    });
  },
};

/** A router whose shared routes answer both generations: each is registered as its module gives it, behind its v2
 *  wrapper (SHARED_ROUTES). */
export class LiteRouter extends Router {
  override on(spec: string, handler: Handler): this {
    return super.on(spec, Object.hasOwn(SHARED_ROUTES, spec) ? SHARED_ROUTES[spec](handler) : handler);
  }
}

// ------------------------------------------------------------------------------------------------ the API

const MODULES = [auth, config, fees, account, plans, swap, markets, assets, launches, earn, moments, contractsV2, bridge, holdings, portfolio, activity];

export const router = new LiteRouter().before(guard);
for (const m of MODULES) m.register(router);
for (const spec of Object.keys(SHARED_ROUTES)) {
  if (!router.specs.includes(spec)) throw new Error(`${spec}: a shared route no module registers`);
}

/** The API's request handler. Running this file serves it; tests import it. */
export function handle(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return Promise.resolve(new Response(null, { status: 204 }));
  return router.handle(req).catch((err) => {
    if (err instanceof ApiError) return json({ error: { code: err.code, message: err.message } }, err.status);
    console.error(err);
    return json({ error: { code: "internal", message: "Something went wrong on our side." } }, 500);
  });
}

if (import.meta.main) Deno.serve(handle);
