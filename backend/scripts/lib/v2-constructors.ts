// The v2 contracts' interfaces as the deploy kit uses them (docs/DESIGN-stellar-contracts-v2.md §3.4, §5.3, §7, §8,
// §9.1, §10–§12, §14): each constructor's parameters (names and types, for the constructor guard of
// lib/wasm-spec.ts) and the values a deployment passes, the config views a re-run compares (L-c), the economics files
// and the admin calls the deploy makes after the constructors (L-b, F8).
//
// Binding status, 2026-10-14 (main 9354d56):
// - exec-soroswap, exec-aquarius, qa-exec-fail, launch-token-v2, lp-locker, moment-nft, moment-coin: merged; the
//   declarations match their code.
// - launchpad-v2 (CT-05), moments-graduator (CT-08), moments-v2 (CT-09): not merged yet; their constructors are the
//   ones the lead pinned in the CT-05, CT-08 and CT-09 entries ("LEAD NOTES AFTER CT-04/06/07"). The guard refuses
//   to deploy any WASM whose constructor differs, so a drift can't reach the chain. CT-11 re-checks them, and the
//   views and admin calls below (config(), venues(), quote_economics(), set_quote, …), against the merged code.
//
// The deploy deploys exec-soroswap, exec-aquarius (when enabled), lp-locker, moments-graduator, launchpad-v2 and
// moments-v2 (plus qa-exec-fail and the failing Moments stack on testnet-qa). launch-token-v2, moment-nft and
// moment-coin are only uploaded: their WASM hashes are constructor arguments, and their constructors are compared too.
import { Buffer } from "node:buffer";
import { scValToNative, xdr } from "@stellar/stellar-sdk";
import { type PlannedContract, sameValue, type ViewCheck } from "./contract-ids.ts";
import type { SingletonName, TtlPolicy, V2Profile, V2Roles } from "./v2-profile.ts";
import { param, type Param, renderParams, renderValue, type SpecType, T, toScVal } from "./wasm-spec.ts";

// ------------------------------------------------------------------------------------------------ dyor-common types

/** dyor_common::VenueKind (§4). */
export const VenueKindT = T.enumU32("VenueKind", [["Soroswap", 0], ["Aquarius", 1], ["HoldOnly", 2], ["QaFail", 3]]);
export const VenueParamsT = T.struct("VenueParams", [["fee_fraction", T.u32]]);
export const TtlPolicyT = T.struct("TtlPolicy", [["threshold", T.u32], ["extend_to", T.u32]]);
export const LaunchDurationsT = T.struct("LaunchDurations", [
  ["grace", T.u64],
  ["fallback_delay", T.u64],
  ["rescue_admin", T.u64],
  ["rescue_public", T.u64],
  ["locked_fallback", T.u64],
  ["takeover_delay", T.u64],
  ["takeover_window", T.u64],
  ["timelock", T.u64],
  ["timelock_window", T.u64],
  ["harvest_interval", T.u64],
]);
export const MomentsDurationsT = T.struct("MomentsDurations", [
  ["vest_period", T.u64],
  ["stuck_expiry", T.u64],
  ["pending_backstop", T.u64],
  ["timelock", T.u64],
  ["timelock_window", T.u64],
  ["min_window", T.u64],
  ["max_window", T.u64],
  ["harvest_interval", T.u64],
]);
/** qa-exec-fail's Mode (§7.3). */
export const ModeT = T.enumU32("Mode", [["Fail", 0], ["ExhaustBudget", 1], ["BogusSuccess", 2]]);

// Defined in launchpad-v2 and moments-v2 (pinned by the lead; CT-05 and CT-09 not merged yet).
/** One entry of launchpad-v2's initial venue table: ids are 0.. in table order, and every initial venue is enabled. */
export const VenueInitT = T.struct("VenueInit", [["kind", VenueKindT], ["executor", T.address], ["params", VenueParamsT]]);
/** moments-v2's Policy (§9.1). */
export const PolicyT = T.struct("Policy", [
  ["threshold", T.i128],
  ["min_price", T.i128],
  ["creator_bps", T.u32],
  ["platform_bps", T.u32],
  ["reserve_bps", T.u32],
  ["max_creator_alloc_bps", T.u32],
  ["expiry_creator_bps", T.u32],
  ["royalty_bps", T.u32],
  ["platform", T.address],
  ["treasury", T.address],
]);

// ------------------------------------------------------------------------------------------------ the WASMs

export type WasmKey =
  | "launchpad-v2"
  | "launch-token-v2"
  | "exec-soroswap"
  | "exec-aquarius"
  | "qa-exec-fail"
  | "lp-locker"
  | "moments-v2"
  | "moment-nft"
  | "moment-coin"
  | "moments-graduator";

export type Binding = "merged" | "pinned";

export interface WasmInfo {
  file: string;
  binding: Binding;
  /** Where the declaration comes from. */
  source: string;
}

export const WASMS: Record<WasmKey, WasmInfo> = {
  "launchpad-v2": { file: "dyor_launchpad_v2.wasm", binding: "pinned", source: "constructor pinned by the lead (CT-05)" },
  "launch-token-v2": { file: "dyor_launch_token_v2.wasm", binding: "merged", source: "main, CT-01" },
  "exec-soroswap": { file: "dyor_exec_soroswap.wasm", binding: "merged", source: "main, CT-02" },
  "exec-aquarius": { file: "dyor_exec_aquarius.wasm", binding: "merged", source: "main, CT-03" },
  "qa-exec-fail": { file: "dyor_qa_exec_fail.wasm", binding: "merged", source: "main, CT-02" },
  "lp-locker": { file: "dyor_lp_locker.wasm", binding: "merged", source: "main, CT-04" },
  "moments-v2": { file: "dyor_moments_v2.wasm", binding: "pinned", source: "constructor pinned by the lead (CT-09)" },
  "moment-nft": { file: "dyor_moment_nft.wasm", binding: "merged", source: "main, CT-06" },
  "moment-coin": { file: "dyor_moment_coin.wasm", binding: "merged", source: "main, CT-07" },
  "moments-graduator": { file: "dyor_moments_graduator.wasm", binding: "pinned", source: "constructor pinned by the lead (CT-08)" },
};

/** The WASM each singleton runs. */
export const SINGLETON_WASM: Record<SingletonName, WasmKey> = {
  "exec-soroswap": "exec-soroswap",
  "exec-aquarius": "exec-aquarius",
  "qa-exec-fail": "qa-exec-fail",
  "lp-locker": "lp-locker",
  "moments-graduator": "moments-graduator",
  "launchpad-v2": "launchpad-v2",
  "moments-v2": "moments-v2",
  "moments-graduator-qa-fail": "moments-graduator",
  "moments-v2-qa-fail": "moments-v2",
};

/** The constructors of contracts the v2 singletons deploy at run time: launchpad-v2 deploys launch tokens (§6.4),
 *  moments-v2 Moment NFTs (§10) and the graduator coins (§11). The deploy script never calls them; the guard still
 *  compares them, so all ten v2 WASMs are checked. */
export const RUNTIME_CONSTRUCTORS: Record<"launch-token-v2" | "moment-nft" | "moment-coin", Param[]> = {
  "launch-token-v2": [
    param("launchpad", T.address),
    param("locker", T.address),
    param("name", T.string),
    param("symbol", T.string),
    param("supply", T.i128),
    param("lock_from", T.vec(T.address)),
    param("fixed_excluded", T.vec(T.address)),
    param("sharing_quote", T.option(T.address)),
    param("soroswap_factory", T.address),
    param("aquarius_router", T.address),
    param("treasury", T.address),
  ],
  "moment-nft": [
    param("minter", T.address),
    param("name", T.string),
    param("symbol", T.string),
    param("metadata_uri", T.string),
    param("creator", T.address),
    param("royalty_bps", T.u32),
    param("media_hash", T.bytesN(32)),
    param("place", T.string),
    param("date", T.string),
    param("external_url", T.string),
  ],
  "moment-coin": [
    param("minter", T.address),
    param("name", T.string),
    param("symbol", T.string),
    param("cap", T.i128),
    param("initial_to", T.address),
    param("initial_amount", T.i128),
  ],
};

// ------------------------------------------------------------------------------------------------ economics

export type VenueKey = "soroswap" | "aquarius" | "qa-exec-fail";
export type VenueKindName = "Soroswap" | "Aquarius" | "HoldOnly" | "QaFail";
export const VENUE_KIND_VALUE: Record<VenueKindName, number> = { Soroswap: 0, Aquarius: 1, HoldOnly: 2, QaFail: 3 };

export interface EconomicsV2 {
  deployment: "testnet" | "testnet-qa";
  launchpad: {
    /** Token supply in base units (1,000,000,000 at 7 dp). */
    supply: string;
    /** XLM stroops, booked per launch (O6). */
    launchFee: string;
    feeBps: number;
    protocolShareBps: number;
    maxCreatorFeeBps: number;
    snipeSchedule: number[];
    snipeStepSecs: number;
    maxExemptions: number;
    /** The initial venue table, in id order (ids are read back from venues(), F8). */
    venues: { key: VenueKey; kind: VenueKindName; feeFraction: number; enabled: boolean }[];
    quotes: {
      /** "XLM", "USDC" (networks.ts) or "QA" (testnet-qa's test asset). */
      asset: "XLM" | "USDC" | "QA";
      phantom: string;
      threshold: string;
      enabled: boolean;
      /** Venue keys; empty = every enabled venue. */
      venuesAllowed: VenueKey[];
      fallback: VenueKey;
    }[];
    aquarius: { maxPoolPayment: string; floatTargetMultiple: number; alertBelowMultiple: number; maxSwapXlm: string };
  };
  moments: {
    quote: "USDC";
    /** Coin supply S in base units (100,000,000 at 7 dp). */
    supply: string;
    externalBase: string;
    policy: {
      threshold: string;
      minPrice: string;
      creatorBps: number;
      platformBps: number;
      reserveBps: number;
      maxCreatorAllocBps: number;
      expiryCreatorBps: number;
      royaltyBps: number;
    };
    harvestBps: number;
    harvestCreatorBps: number;
    batch: number;
  };
  /** testnet-qa's classic test asset (issued by the QA issuer key), for the venue-locked quote. */
  qaAsset?: { code: string };
}

/** √10 − 1 in 1e8 fixed point: the threshold of a phantom (graduation at 10× the launch FDV), as v1 computed it. */
export const thresholdOf = (phantom: bigint) => (phantom * 216_227_766n) / 100_000_000n;

/** Reads and checks an economics file against its deployment (spec §14.1–14.2). */
export function parseEconomics(json: unknown, profile: V2Profile): EconomicsV2 {
  const e = json as EconomicsV2;
  const fail = (why: string): never => {
    throw new Error(`economics/${profile.economicsFile}: ${why}`);
  };
  if (e?.deployment !== profile.name) fail(`it is for ${String(e?.deployment)}, not ${profile.name}`);
  const lp = e.launchpad;
  for (const q of lp.quotes) {
    if (q.asset === "QA" && !profile.qaExecFail) fail("the QA quote is testnet-qa only");
    if (BigInt(q.threshold) !== thresholdOf(BigInt(q.phantom))) fail(`${q.asset}'s threshold isn't phantom · (√10 − 1)`);
    if (q.fallback !== "soroswap") fail(`${q.asset}'s fallback must be the Soroswap venue`);
    for (const v of [...q.venuesAllowed, q.fallback]) if (!lp.venues.some((x) => x.key === v)) fail(`${q.asset} names an unknown venue ${v}`);
  }
  if (lp.venues[0]?.kind !== "Soroswap") fail("the Soroswap venue comes first");
  if (lp.venues.some((v) => v.kind === "QaFail") && !profile.qaExecFail) fail("the qa-exec-fail venue is testnet-qa only");
  for (const v of lp.venues) {
    if (v.kind === "Aquarius" && ![10, 30, 100].includes(v.feeFraction)) fail("Aquarius's fee_fraction is 10, 30 or 100");
    if (v.kind !== "Aquarius" && v.feeFraction !== 0) fail(`${v.key}'s fee_fraction must be 0`);
  }
  const p = e.moments.policy;
  if (p.creatorBps + p.platformBps + p.reserveBps !== 10_000 || p.reserveBps <= 0) fail("the Moments split must sum to 10,000 with a reserve");
  const T_ = BigInt(p.threshold);
  if (T_ < 10_000_000n || T_ > 10_000_000_000_000n) fail("the Moments threshold must be 1 to 1,000,000 USDC");
  if (BigInt(p.minPrice) < 100_000n) fail("the Moments minimum price must be at least 0.01 USDC");
  if (p.maxCreatorAllocBps > 1_000 || p.expiryCreatorBps > 10_000 || p.royaltyBps > 1_000) fail("a Moments policy cap is exceeded");
  if (!/^https:\/\/[^\s]{1,248}$/.test(e.moments.externalBase)) fail("externalBase must be an https URL of at most 256 bytes");
  return e;
}

// ------------------------------------------------------------------------------------------------ the plan

export interface NetworkContracts {
  xlmSac: string;
  usdcSac: string;
  soroswapFactory: string;
  aquariusRouter: string;
}

export interface ConstructorPlan {
  profile: V2Profile;
  roles: V2Roles;
  /** Planned ids of the singletons deployed in this run. */
  ids: Partial<Record<SingletonName, string>>;
  /** sha256 hex of each WASM in dist; absent from dist: undefined (a dry run shows it, a real run refuses). */
  wasmHashes: Partial<Record<WasmKey, string>>;
  network: NetworkContracts;
  economics: EconomicsV2;
  aquarius: { enabled: boolean; paymentAsset: string };
  /** testnet-qa: qa-exec-fail's admin. */
  qaAdmin?: string;
}

export interface Ctor {
  contract: SingletonName;
  wasm: WasmKey;
  params: Param[];
  /** Native values, in parameter order; a WASM hash not known yet is the string "(<file> absent from dist)". */
  values: unknown[];
}

const durations = (d: object) => ({ ...d });
const ttl = (t: TtlPolicy) => ({ threshold: t.threshold, extend_to: t.extend_to });

function need(p: ConstructorPlan, name: SingletonName): string {
  const id = p.ids[name];
  if (!id) throw new Error(`${name} is not planned in this deployment`);
  return id;
}

function wasmHash(p: ConstructorPlan, key: WasmKey): string {
  return p.wasmHashes[key] ?? `(${WASMS[key].file} absent from dist)`;
}

/** The initial venue table (§3.4, §14.1): Soroswap first, then Aquarius when it is on, then qa-exec-fail on
 *  testnet-qa. Each economics venue maps to the executor this run deploys. */
export function initialVenues(p: ConstructorPlan): { key: VenueKey; kind: VenueKindName; executor: string; fee_fraction: number; enabled: boolean }[] {
  const exec: Record<VenueKey, SingletonName> = { soroswap: "exec-soroswap", aquarius: "exec-aquarius", "qa-exec-fail": "qa-exec-fail" };
  return p.economics.launchpad.venues
    .filter((v) => (v.key === "aquarius" ? p.aquarius.enabled : v.key === "qa-exec-fail" ? p.profile.qaExecFail : true))
    .map((v) => ({ key: v.key, kind: v.kind, executor: need(p, exec[v.key]), fee_fraction: v.feeFraction, enabled: v.enabled }));
}

/** Every constructor this deployment calls, in deploy order. */
export function constructors(p: ConstructorPlan): Ctor[] {
  const out: Ctor[] = [];
  const has = (n: SingletonName) => p.ids[n] !== undefined;
  const lpd = p.profile.launchDurations;
  const md = p.profile.momentsDurations;
  const launchpad = need(p, "launchpad-v2");
  const moments = need(p, "moments-v2");
  const graduator = need(p, "moments-graduator");
  const locker = need(p, "lp-locker");
  const execSoroswap = need(p, "exec-soroswap");

  out.push({
    contract: "exec-soroswap",
    wasm: "exec-soroswap",
    params: [param("factory", T.address), param("callers", T.vec(T.address))],
    values: [p.network.soroswapFactory, [launchpad, graduator]],
  });
  if (has("exec-aquarius")) {
    out.push({
      contract: "exec-aquarius",
      wasm: "exec-aquarius",
      params: [param("router", T.address), param("payment_asset", T.address), param("max_pool_payment", T.i128), param("callers", T.vec(T.address))],
      values: [p.network.aquariusRouter, p.aquarius.paymentAsset, BigInt(p.economics.launchpad.aquarius.maxPoolPayment), [launchpad, graduator]],
    });
  }
  if (has("qa-exec-fail")) {
    if (!p.qaAdmin) throw new Error("qa-exec-fail needs the QA admin");
    out.push({
      contract: "qa-exec-fail",
      wasm: "qa-exec-fail",
      params: [param("callers", T.vec(T.address)), param("qa_admin", T.address), param("default_mode", ModeT)],
      values: [[launchpad, need(p, "moments-graduator-qa-fail")], p.qaAdmin, "Fail"],
    });
  }
  out.push({
    contract: "lp-locker",
    wasm: "lp-locker",
    params: [
      param("owners", T.vec(T.address)),
      param("soroswap_factory", T.address),
      param("aquarius_router", T.option(T.address)),
      param("harvest_interval", T.u64),
    ],
    // `None` where Aquarius is no venue (CT-04's constructor). Both owners require the same interval (F6).
    values: [[launchpad, moments], p.network.soroswapFactory, p.aquarius.enabled ? p.network.aquariusRouter : null, lpd.harvest_interval],
  });
  const graduatorParams = [
    param("moments", T.address),
    param("coin_wasm_hash", T.bytesN(32)),
    param("executor", T.address),
    param("locker", T.address),
    param("soroswap_factory", T.address),
  ];
  out.push({
    contract: "moments-graduator",
    wasm: "moments-graduator",
    params: graduatorParams,
    values: [moments, wasmHash(p, "moment-coin"), execSoroswap, locker, p.network.soroswapFactory],
  });
  const venues = initialVenues(p);
  out.push({
    contract: "launchpad-v2",
    wasm: "launchpad-v2",
    params: [
      param("admin", T.address),
      param("guardian", T.option(T.address)),
      param("treasury", T.address),
      param("xlm", T.address),
      param("token_wasm_hash", T.bytesN(32)),
      param("locker", T.address),
      param("soroswap_factory", T.address),
      param("aquarius_router", T.address),
      param("launch_fee", T.i128),
      param("venues", T.vec(VenueInitT)),
      param("durations", LaunchDurationsT),
      param("ttl", TtlPolicyT),
    ],
    values: [
      p.roles.ADMIN_PUBLIC,
      p.roles.LAUNCHPAD_GUARDIAN_PUBLIC,
      p.roles.TREASURY_PUBLIC,
      p.network.xlmSac,
      wasmHash(p, "launch-token-v2"),
      locker,
      p.network.soroswapFactory,
      // Always set, also without the Aquarius venue: every token gets it to exclude Aquarius pools (F2).
      p.network.aquariusRouter,
      // 10 XLM (O6). Quotes are not constructor arguments: the admin sets them after the deploy.
      BigInt(p.economics.launchpad.launchFee),
      venues.map((v) => ({ kind: v.kind, executor: v.executor, params: { fee_fraction: v.fee_fraction } })),
      durations(lpd),
      ttl(p.profile.ttl),
    ],
  });
  const momentsParams = [
    param("governance", T.address),
    param("guardian", T.option(T.address)),
    param("usdc", T.address),
    param("nft_wasm_hash", T.bytesN(32)),
    param("graduator", T.address),
    param("locker", T.address),
    param("executor", T.address),
    param("soroswap_factory", T.address),
    param("external_base", T.string),
    param("policy", PolicyT),
    param("durations", MomentsDurationsT),
    param("ttl", TtlPolicyT),
  ];
  const momentsValues = (grad: string, executor: string) => [
    p.roles.GOVERNANCE_PUBLIC,
    p.roles.MOMENTS_GUARDIAN_PUBLIC,
    p.network.usdcSac,
    wasmHash(p, "moment-nft"),
    grad,
    locker,
    executor,
    p.network.soroswapFactory,
    p.economics.moments.externalBase,
    policy(p),
    durations(md),
    ttl(p.profile.ttl),
  ];
  out.push({ contract: "moments-v2", wasm: "moments-v2", params: momentsParams, values: momentsValues(graduator, execSoroswap) });
  if (has("moments-graduator-qa-fail")) {
    const qaGrad = need(p, "moments-graduator-qa-fail");
    const qaExec = need(p, "qa-exec-fail");
    out.push({
      contract: "moments-graduator-qa-fail",
      wasm: "moments-graduator",
      params: graduatorParams,
      values: [need(p, "moments-v2-qa-fail"), wasmHash(p, "moment-coin"), qaExec, locker, p.network.soroswapFactory],
    });
    out.push({ contract: "moments-v2-qa-fail", wasm: "moments-v2", params: momentsParams, values: momentsValues(qaGrad, qaExec) });
  }
  return out;
}

/** moments-v2's policy (§9.1, §14.2): platform and treasury are the roles (L-f). */
export function policy(p: ConstructorPlan) {
  const m = p.economics.moments.policy;
  return {
    threshold: BigInt(m.threshold),
    min_price: BigInt(m.minPrice),
    creator_bps: m.creatorBps,
    platform_bps: m.platformBps,
    reserve_bps: m.reserveBps,
    max_creator_alloc_bps: m.maxCreatorAllocBps,
    expiry_creator_bps: m.expiryCreatorBps,
    royalty_bps: m.royaltyBps,
    platform: p.roles.PLATFORM_PUBLIC,
    treasury: p.roles.TREASURY_PUBLIC,
  };
}

/** The constructor's ScVal arguments (a real run; every WASM hash must be known). */
export function encodeArgs(c: Ctor): xdr.ScVal[] {
  return c.params.map((prm, i) => toScVal(prm.type, c.values[i], `${c.contract}.${prm.name}`));
}

/** The dry run's lines for one constructor. */
export function describeCtor(c: Ctor, names: Map<string, string>): string[] {
  const info = WASMS[c.wasm];
  const out = [`  ${c.contract} ← ${info.file} (${info.binding}: ${info.source})`, `    __constructor${renderParams(c.params)}`];
  c.params.forEach((prm, i) => out.push(`      ${prm.name} = ${renderValue(prm.type, c.values[i], names)}`));
  return out;
}

// ------------------------------------------------------------------------------------------------ re-run checks

const field = (k: string) => (v: unknown) => (v as Record<string, unknown> | null)?.[k];
const hex = (v: unknown) => (v instanceof Uint8Array ? Buffer.from(v).toString("hex") : v);

/** What a re-run compares on a contract already at its planned id (L-c). */
export function plannedContracts(p: ConstructorPlan, ctors: Ctor[]): PlannedContract[] {
  return ctors.map((c) => {
    const v = Object.fromEntries(c.params.map((prm, i) => [prm.name, c.values[i]]));
    const view = (label: string, fn: string, expected: unknown, pick?: (n: unknown) => unknown, args: xdr.ScVal[] = []): ViewCheck => ({
      label: `${c.contract} ${label}`,
      fn,
      args,
      expected,
      pick,
    });
    const views: ViewCheck[] = [];
    switch (c.wasm) {
      case "exec-soroswap":
        views.push(view("factory()", "factory", v.factory), view("callers()", "callers", v.callers));
        break;
      case "exec-aquarius":
        views.push(view("max_pool_payment()", "max_pool_payment", v.max_pool_payment));
        break;
      case "qa-exec-fail":
        views.push(
          view("callers()", "callers", v.callers),
          view("qa_admin()", "qa_admin", v.qa_admin),
          view("default mode", "mode", 0, undefined, [toScVal(T.address, need(p, c.contract))]),
        );
        break;
      case "lp-locker":
        views.push(
          view("owners()", "owners", v.owners),
          view("soroswap_factory()", "soroswap_factory", v.soroswap_factory),
          view("aquarius_router()", "aquarius_router", v.aquarius_router),
          view("harvest_interval()", "harvest_interval", v.harvest_interval),
        );
        break;
      case "launchpad-v2":
        for (const k of ["admin", "guardian", "treasury", "xlm", "token_wasm_hash", "locker", "soroswap_factory", "aquarius_router", "durations", "ttl"]) {
          views.push(view(`config().${k}`, "config", v[k], (n) => hex(field(k)(n))));
        }
        views.push(view("config().supply", "config", BigInt(p.economics.launchpad.supply), field("supply")));
        views.push(view(
          "venues() (kind, executor, params)",
          "venues",
          (v.venues as { kind: string; executor: string; params: unknown }[]).map((x) => ({ kind: VENUE_KIND_VALUE[x.kind as VenueKindName], executor: x.executor, params: x.params })),
          (n) => (n as Record<string, unknown>[]).map((x) => ({ kind: x.kind, executor: x.executor, params: x.params })),
        ));
        break;
      case "moments-v2":
        for (const k of ["governance", "guardian", "usdc", "nft_wasm_hash", "graduator", "locker", "executor", "soroswap_factory", "durations", "ttl"]) {
          views.push(view(`config().${k}`, "config", v[k], (n) => hex(field(k)(n))));
        }
        views.push(view("policy()", "policy", v.policy));
        break;
      case "moments-graduator":
        break; // §12 has no config view; the WASM hash is compared.
    }
    const wasm = p.wasmHashes[c.wasm];
    if (!wasm) throw new Error(`${WASMS[c.wasm].file} is absent from dist`);
    return { name: c.contract, id: need(p, c.contract), wasmHash: wasm, views, stored: identityLeaves(c) };
  });
}

/** The constructor arguments that identify a contract's configuration (every address, WASM hash and string, with
 *  where it came from), which its instance storage must hold. Integers and enums are left to the views. The v2
 *  contracts keep their constructor arguments in instance storage (§5.2, §8.1, §9.1; the merged executors and the
 *  locker do; CT-11 confirms launchpad-v2, moments-v2 and moments-graduator once merged). */
export function identityLeaves(c: Ctor): { label: string; value: string }[] {
  const out = new Map<string, string>();
  const walk = (t: SpecType, v: unknown, label: string) => {
    if (v === null || v === undefined) return;
    switch (t.kind) {
      case "prim":
        if (t.name === "Address" || t.name === "String") out.set(String(v), out.get(String(v)) ?? label);
        return;
      case "bytesN": {
        const hex = typeof v === "string" ? v : Buffer.from(v as Uint8Array).toString("hex");
        if (/^([0-9a-f]{2})+$/.test(hex)) out.set(hex, out.get(hex) ?? label);
        return;
      }
      case "option":
        return walk(t.value, v, label);
      case "vec":
        (v as unknown[]).forEach((x, i) => walk(t.element, x, `${label}[${i}]`));
        return;
      case "tuple":
        t.items.forEach((it, i) => walk(it, (v as unknown[])[i], `${label}.${i}`));
        return;
      case "udt":
        if (t.def?.kind === "struct") for (const f of t.def.fields) walk(f.type, (v as Record<string, unknown>)[f.name], `${label}.${f.name}`);
        return;
    }
  };
  c.params.forEach((prm, i) => walk(prm.type, c.values[i], prm.name));
  return [...out.entries()].map(([value, label]) => ({ label, value }));
}

// ------------------------------------------------------------------------------------------------ after the constructors

export interface VenueOnChain {
  id: number;
  kind: number;
  executor: string;
  fee_fraction: number;
  enabled: boolean;
}

/** venues() as read from the chain (F8). */
export function readVenues(native: unknown): VenueOnChain[] {
  if (!Array.isArray(native)) throw new Error("venues() didn't return a list");
  return native.map((v: any) => ({
    id: Number(v.id),
    kind: Number(v.kind),
    executor: String(v.executor),
    fee_fraction: Number(v.params?.fee_fraction ?? 0),
    enabled: Boolean(v.enabled),
  }));
}

/** Maps each planned venue to the id venues() gives it, by kind and executor; never from constants (F8). */
export function venueIds(
  planned: { key: VenueKey; kind: VenueKindName; executor: string }[],
  onChain: VenueOnChain[],
): Map<VenueKey, number> {
  const out = new Map<VenueKey, number>();
  for (const v of planned) {
    const found = onChain.find((x) => x.kind === VENUE_KIND_VALUE[v.kind] && x.executor === v.executor);
    if (!found) throw new Error(`venues() has no ${v.kind} venue with executor ${v.executor}`);
    out.set(v.key, found.id);
  }
  return out;
}

export interface AdminCall {
  contract: string;
  fn: string;
  args: xdr.ScVal[];
  /** "set_quote(USDC, …)": what the run prints. */
  describe: string;
}

export interface LaunchpadState {
  config: Record<string, unknown>;
  venues: VenueOnChain[];
  /** quote_economics(asset) per quote asset contract; null when unset. */
  quotes: Map<string, Record<string, unknown> | null>;
}

const sv = {
  u32: (n: number) => toScVal(T.u32, n),
  i128: (n: bigint) => toScVal(T.i128, n),
  bool: (b: boolean) => toScVal(T.bool, b),
  addr: (a: string) => toScVal(T.address, a),
  u32s: (ns: number[]) => toScVal(T.vec(T.u32), ns),
};

/** The admin calls that bring launchpad-v2 to the economics file, given its state read from the chain: the launch
 *  fee, the fees, the venues to enable and the quotes (with venue ids as read, F8). Calls whose value is already on
 *  chain are left out, so a re-run sends nothing new. */
export function launchpadCalls(
  launchpad: string,
  econ: EconomicsV2,
  planned: { key: VenueKey; kind: VenueKindName; executor: string; enabled: boolean }[],
  state: LaunchpadState,
  quoteAssets: Map<"XLM" | "USDC" | "QA", string>,
): AdminCall[] {
  const lp = econ.launchpad;
  const calls: AdminCall[] = [];
  const cfg = state.config;
  if (!sameValue(cfg.launch_fee, BigInt(lp.launchFee))) {
    calls.push({ contract: launchpad, fn: "set_launch_fee", args: [sv.i128(BigInt(lp.launchFee))], describe: `set_launch_fee(${lp.launchFee})` });
  }
  const fees = [lp.feeBps, lp.protocolShareBps, lp.maxCreatorFeeBps, lp.snipeSchedule, lp.snipeStepSecs];
  const now = [cfg.fee_bps, cfg.protocol_share_bps, cfg.max_creator_fee_bps, cfg.snipe_schedule, cfg.snipe_step_secs];
  if (!sameValue(now, fees)) {
    calls.push({
      contract: launchpad,
      fn: "set_fees",
      args: [sv.u32(lp.feeBps), sv.u32(lp.protocolShareBps), sv.u32(lp.maxCreatorFeeBps), sv.u32s(lp.snipeSchedule), sv.u32(lp.snipeStepSecs)],
      describe: `set_fees(${lp.feeBps}, ${lp.protocolShareBps}, ${lp.maxCreatorFeeBps}, [${lp.snipeSchedule.join(", ")}], ${lp.snipeStepSecs})`,
    });
  }
  const ids = venueIds(planned, state.venues);
  for (const v of planned) {
    const id = ids.get(v.key)!;
    const on = state.venues.find((x) => x.id === id)!;
    if (on.enabled !== v.enabled) {
      calls.push({ contract: launchpad, fn: "set_venue_enabled", args: [sv.u32(id), sv.bool(v.enabled)], describe: `set_venue_enabled(${id} ${v.key}, ${v.enabled})` });
    }
  }
  for (const q of lp.quotes) {
    const asset = quoteAssets.get(q.asset);
    if (!asset) throw new Error(`no contract for the ${q.asset} quote`);
    const allowed = q.venuesAllowed.map((k) => {
      const id = ids.get(k);
      if (id === undefined) throw new Error(`the ${q.asset} quote allows venue ${k}, which this deployment doesn't have`);
      return id;
    });
    const fallback = ids.get(q.fallback);
    if (fallback === undefined) throw new Error(`the ${q.asset} quote's fallback ${q.fallback} isn't deployed`);
    const want = { phantom: BigInt(q.phantom), threshold: BigInt(q.threshold), enabled: q.enabled, venues_allowed: allowed, fallback_venue: fallback };
    const have = state.quotes.get(asset) ?? null;
    if (have && sameValue(pickQuote(have), want)) continue;
    calls.push({
      contract: launchpad,
      fn: "set_quote",
      args: [sv.addr(asset), sv.i128(want.phantom), sv.i128(want.threshold), sv.bool(q.enabled), sv.u32s(allowed), sv.u32(fallback)],
      describe: `set_quote(${q.asset}, phantom ${q.phantom}, threshold ${q.threshold}, ${q.enabled ? "enabled" : "disabled"}, venues [${allowed.join(", ")}], fallback ${fallback})`,
    });
  }
  return calls;
}

const pickQuote = (q: Record<string, unknown>) => ({
  phantom: q.phantom,
  threshold: q.threshold,
  enabled: q.enabled,
  venues_allowed: q.venues_allowed,
  fallback_venue: q.fallback_venue,
});

/** launchpad-v2's state as launchpadCalls reads it. */
export async function readLaunchpadState(
  view: (fn: string, args: xdr.ScVal[]) => Promise<xdr.ScVal>,
  quoteAssets: string[],
): Promise<LaunchpadState> {
  const config = scValToNative(await view("config", [])) as Record<string, unknown>;
  const venues = readVenues(scValToNative(await view("venues", [])));
  const quotes = new Map<string, Record<string, unknown> | null>();
  for (const a of quoteAssets) quotes.set(a, (scValToNative(await view("quote_economics", [sv.addr(a)])) ?? null) as Record<string, unknown> | null);
  return { config, venues, quotes };
}

