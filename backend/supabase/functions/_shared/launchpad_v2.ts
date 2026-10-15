// Launchpad v2 (docs/DESIGN-stellar-contracts-v2.md §5, §8, §20.2–20.3): the launchpad block of /v1/economics, a
// launch's live reads, the launch preview with its XLM check, trade and refund quotes, and the plan builders of every
// v2 launch action. v1 stays in launchpad.ts for the retired generation.
// - Everything is read live from launchpad-v2, the launch token and the lp-locker, so whoever deploys them sets what
//   users see (the economics block kept 5 minutes, as economics.ts keeps v1's). Launches are keyed by their token's
//   address; there are no on-chain indices (L15).
// - A launch binds its terms by value: the builder passes preview_launch_terms' own value as `expected`, and refuses
//   terms that aren't this deployment's pins (the locker, the token's WASM, the durations, the executors, at most the
//   pinned launch fee) before anyone signs (§20.4, F18).
// - The 10 XLM launch fee (O6) goes to the launchpad whatever the quote. Create refuses with insufficient_xlm and the
//   shortfall when the account can't keep its minimum balance, the XLM its open offers sell, the fee, the network fees
//   and a 0.5 XLM buffer (F18, V12); the preview's maxInitialBuy is exactly what is left for an XLM quote.
// - Every refusal of a v2 contract is named from _shared/v2_errors.ts (V10), with its stable code where it has one.
//   Time-gated actions are refused before simulating with not_available and the time they open: the fallback venue
//   from fallback_at only, mark_stuck after the grace, the public rescue after rescue_public (§5.4, F14).
// - A recipient change on a graduated launch collects the pool fees first when the locker's interval allows (F3); what
//   one harvest round can't take crosses the change, and the plan says so: harvestBacklog (V7).
// - Aquarius is off on every deployment today (O7): its venue appears only where the deployment enables it, and every
//   label names the launch's own venue.
// The builders are exported as LAUNCH_V2_BUILDERS; the API registers them with the routes (CT-18).
import { Account, Contract, Keypair, rpc, scValToNative, xdr } from "@stellar/stellar-sdk";
import type { ContractErrorCode, PlanView, XlmPosition } from "./contract.ts";
import { env } from "./env.ts";
import { baseReserve, feeCeiling, positionOf } from "./fees.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { checkLaunchUri, launchName, launchSymbol } from "./launch_metadata.ts";
import { ratio } from "./launchpad.ts";
import { DeploymentV2, LAUNCH_DURATION_KEYS, VenueKindV2 } from "./deployments/index.ts";
import { assetById, NetworkConfig } from "./networks.ts";
import { Builder, createPlan, StepSpec } from "./plans.ts";
import {
  classicBalances,
  fromStroops,
  invoke,
  isAccountId,
  isContractId,
  newTx,
  requireAccount,
  rpcServer,
  sv,
  view,
} from "./stellar.ts";
import { ERR_BASE, errorsFor, HOST_ERRORS, NamedError, ORIGIN_FOREIGN, ORIGIN_HOST, V2_ERRORS } from "./v2_errors.ts";
import { Intent } from "./verify.ts";

const BPS = 10_000n;
/** lp-locker's most per harvest round: 0.5% of the position (MAX_HARVEST_ROUND_BPS, §8.2). */
export const MAX_HARVEST_ROUND_BPS = 50n;
/** A launch's harvest takes all the growth (LAUNCH_HARVEST_BPS, O1). */
export const LAUNCH_HARVEST_BPS = 10_000n;
/** launch-token-v2's exclude_pool floor (§6.2, F2): 1,000 tokens in the pool, or 0.1 of the quote (or 1,000 tokens)
 *  of pending rewards. Its exclusion_floor() view answers the same pair for every launch. */
export const EXCLUSION_MIN_POOL_TOKENS = 10_000_000_000n;
export const EXCLUSION_MIN_PENDING_QUOTE = 1_000_000n;
/** What a launch keeps back besides the minimum balance, the offers' XLM, the fee and the network fees (F18). */
export const LAUNCH_XLM_BUFFER = 5_000_000n;
/** The exec-aquarius float's target and alert, in pool payments (F11): 50 × on the owner's testnet, 10 × on
 *  testnet-qa; alert below 5 ×. */
const AQUA_FLOAT_TARGET = { production: 50n, "testnet-qa": 10n } as const;
const AQUA_FLOAT_ALERT = 5n;
/** Harvest rounds a backlog is counted to: past this many hours it is "about as many as this". */
const MAX_DRAIN_ROUNDS = 10_000;
/** The launchpad block of /v1/economics is read again after 5 minutes (economics.ts's ECONOMICS_TTL_MS). */
export const ECONOMICS_V2_TTL_MS = 5 * 60_000;

const PHASES = ["curve", "completed", "graduated", "rescued"] as const;
export type PhaseV2 = typeof PHASES[number];
const VENUE_KINDS: readonly VenueKindV2[] = ["Soroswap", "Aquarius", "HoldOnly", "QaFail"];

/** The step kinds of v2's plans: v1's builders keep launch_create, launch_buy and the rest (launchpad.ts). */
export const LAUNCH_V2_STEPS = {
  create: "launch_v2_create",
  buy: "launch_v2_buy",
  sell: "launch_v2_sell",
  refund: "launch_v2_refund",
  graduate: "launch_v2_graduate",
  graduate_fallback: "launch_v2_graduate_fallback",
  mark_stuck: "launch_v2_mark_stuck",
  rescue: "launch_v2_rescue",
  claim: "launch_v2_claim",
  claim_owed: "launch_v2_claim_owed",
  claim_rewards: "launch_v2_claim_rewards",
  harvest: "launch_v2_harvest",
  recipient_transfer: "launch_v2_recipient_transfer",
  recipient_cancel: "launch_v2_recipient_cancel",
  recipient_execute: "launch_v2_recipient_execute",
} as const;
export type LaunchV2Action = Exclude<keyof typeof LAUNCH_V2_STEPS, "harvest">;

const nowSecs = (nowMs: number) => Math.floor(nowMs / 1000);
/** A contract's time (seconds, 0 where it doesn't apply) as ISO, or null. */
const isoAt = (secs: unknown): string | null => (Number(secs) > 0 ? new Date(Number(secs) * 1000).toISOString() : null);
const short = (a: string) => `${a.slice(0, 4)}…${a.slice(-4)}`;
const big = (v: unknown): bigint => BigInt(v as bigint | number | string);

// ------------------------------------------------------------------------------------------------ the deployment

/** v2's launchpad and locker on `net`; 503 not_deployed until its deployment file exists (§20.1). */
function deployed(net: NetworkConfig): { pad: string; locker: string; v2: DeploymentV2 } {
  const { launchpadV2: pad, lpLocker: locker } = net.contracts;
  if (!pad || !locker || !net.deploymentV2) throw new ApiError(503, "not_deployed", "Launchpad v2 isn't deployed on this network yet.");
  return { pad, locker, v2: net.deploymentV2 };
}

/** An asset a launch may be quoted in: the registry's XLM and USDC, and testnet-qa's own classic asset. */
export interface QuoteAsset {
  id: string;
  code: string;
  contract: string;
  /** "native" or CODE:ISSUER. */
  classic: string;
  decimals: number;
}

function quoteAssets(net: NetworkConfig): QuoteAsset[] {
  const registry = ["XLM", "USDC"].flatMap((id) => {
    const a = assetById(net, id);
    return a && a.classic ? [{ id: a.id, code: a.code, contract: a.contract, classic: a.classic, decimals: a.decimals }] : [];
  });
  const qa = net.deploymentV2?.qaAsset;
  return qa ? [...registry, { id: "QA", code: qa.code, contract: qa.sac, classic: `${qa.code}:${qa.issuer}`, decimals: 7 }] : registry;
}

function quoteAssetOf(net: NetworkConfig, idOrContract: string): QuoteAsset | undefined {
  return quoteAssets(net).find((q) => q.id === idOrContract || q.contract === idOrContract);
}

/** A launch's quote as the API names it: its asset's id and code, or the contract itself for one we don't know. */
function quoteNamed(net: NetworkConfig, contract: string): { id: string; code: string; decimals: number } {
  const q = quoteAssetOf(net, contract);
  return q ? { id: q.id, code: q.code, decimals: q.decimals } : { id: contract, code: short(contract), decimals: 7 };
}

// ------------------------------------------------------------------------------------------------ values

/** A contract struct: a map of its fields by name, in the order Soroban requires. */
function struct(fields: Record<string, xdr.ScVal>): xdr.ScVal {
  return xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));
}

/** A read-only call's return value as the contract encoded it: what launch() takes back as `expected`. */
async function viewRaw(contract: string, fn: string, args: xdr.ScVal[]): Promise<xdr.ScVal> {
  const source = new Account(Keypair.random().publicKey(), "0");
  const tx = newTx(source, 30).addOperation(new Contract(contract).call(fn, ...args)).build();
  const r = await rpcServer().simulateTransaction(tx);
  if (rpc.Api.isSimulationError(r)) throw new ApiError(422, "simulation_failed", "The contract refused this.", { raw: r.error.slice(0, 600) });
  if (!r.result) throw new ApiError(502, "rpc_unavailable", "Stellar RPC didn't answer. Try again.");
  return r.result.retval;
}

/** Base units as a decimal string, above zero unless `zero` allows it; 400 bad_amount otherwise. */
function unitsArg(v: unknown, name: string, zero = false): bigint {
  if (typeof v !== "string" || !/^[0-9]{1,30}$/.test(v) || (!zero && BigInt(v) === 0n)) {
    throw bad("bad_amount", `${name} must be a whole number of base units${zero ? "" : " above 0"}, as a string.`);
  }
  return BigInt(v);
}

function tokenArg(v: unknown): string {
  if (typeof v !== "string" || !isContractId(v)) throw bad("bad_arg", "token is required: the launch token's contract id (C…).");
  return v;
}

/** A G… or C… address (never a muxed one). */
function addressArg(v: unknown, name: string): string {
  if (typeof v !== "string" || !(isAccountId(v) || isContractId(v))) throw bad("bad_address", `${name} must be a Stellar address (G… or C…).`);
  return v;
}

/** A v2 ticker: 2–10 ASCII letters or digits as typed (Soroswap's pair reads each token's symbol as UTF-8, so the
 *  contracts refuse any other), then launchSymbol's rules: upper case, not a reserved one. */
export function launchSymbolV2(raw: unknown): string {
  const typed = typeof raw === "string" ? raw.trim() : "";
  if (!/^[A-Za-z0-9]{2,10}$/.test(typed)) throw bad("bad_symbol", "Ticker: 2–10 letters (A–Z) or digits, without accents, spaces or symbols.");
  return launchSymbol(typed);
}

// ------------------------------------------------------------------------------------------------ refusals

/** The namespaced v2 error in a simulation's error text (§4, V10): the first contract error in DyorHQ's range, with
 *  the tag of the contract that raised it. A SAC's or a DEX's code is never in that range. */
export function v2ErrorOf(raw: string): { origin: number; code: number } | null {
  for (const m of raw.matchAll(/Error\(Contract, #(\d+)\)/g)) {
    const code = Number(m[1]);
    if (code >= ERR_BASE + 100 && code < ERR_BASE + 1_100) return { origin: Math.floor((code - ERR_BASE) / 100), code };
  }
  return null;
}

/** A failure as a graduation would record it (dyor-common grad_failure): a v2 contract's namespaced code, origin 0 and
 *  the raw code for any other contract, origin 99 and the ScErrorCode for the host's own. Null when the text has none. */
export function failureOf(raw: string): { origin: number; code: number } | null {
  const v2 = v2ErrorOf(raw);
  if (v2) return v2;
  const contract = /Error\(Contract, #(\d+)\)/.exec(raw);
  if (contract) return { origin: ORIGIN_FOREIGN, code: Number(contract[1]) };
  const host = /Error\((?:WasmVm|Context|Storage|Object|Crypto|Events|Budget|Value|Auth), (\w+)\)/.exec(raw);
  const named = host ? HOST_ERRORS.find((e) => e.name === host[1]) : undefined;
  return named ? { origin: ORIGIN_HOST, code: named.code } : null;
}

/** Refusals with a stable code (§6.13), by "<contract> <error>". */
const CONTRACT_CODES: Record<string, ContractErrorCode> = {
  "launchpad-v2 LaunchesDisabled": "launch.disabled",
  "launchpad-v2 NotWhitelisted": "launch.disabled",
  "launchpad-v2 QuoteNotAllowed": "launch.disabled",
  "launchpad-v2 CurveClosed": "launch.closed",
  "launchpad-v2 AlreadyGraduated": "launch.closed",
  "launchpad-v2 SlippageExceeded": "launch.slippage",
  "launchpad-v2 NothingToClaim": "launch.nothing_to_claim",
  "launch-token-v2 NothingToClaim": "launch.nothing_to_claim",
};

const REFUSAL_TEXT: Record<string, string> = {
  "launchpad-v2 LaunchesDisabled": "New launches are paused.",
  "launchpad-v2 NotWhitelisted": "New launches are open to listed creators only right now.",
  "launchpad-v2 QuoteNotAllowed": "Launches in this asset are paused.",
  "launchpad-v2 CurveClosed": "This curve isn't taking trades now.",
  "launchpad-v2 AlreadyGraduated": "This coin has graduated already.",
  "launchpad-v2 SlippageExceeded": "The price moved past your limit. Nothing was sent.",
  "launchpad-v2 NothingToClaim": "Nothing to claim yet.",
  "launchpad-v2 TermsChanged": "The launchpad's terms just changed. Review them again.",
  "launchpad-v2 WrongPhase": "This coin isn't in that phase.",
  "launchpad-v2 FallbackTooEarly": "The fallback venue isn't open yet.",
  "launchpad-v2 FallbackNotAllowed": "The fallback venue isn't open yet.",
  "launchpad-v2 GraceNotElapsed": "Graduation can't be marked delayed yet.",
  "launchpad-v2 NotStuck": "Refunds can't be opened yet.",
  "launchpad-v2 NoProposal": "There is no pending change.",
  "launchpad-v2 TimelockNotElapsed": "The change can't be made yet.",
  "launchpad-v2 TimelockExpired": "The change's window has closed.",
  "launch-token-v2 NothingToClaim": "Nothing to claim yet.",
  "launch-token-v2 ExcludedAccount": "This address doesn't earn holder rewards.",
  "lp-locker TooSoon": "The pool fees were just collected. Try again shortly.",
  "lp-locker NothingToHarvest": "There are no pool fees to collect yet.",
};

function rawOf(err: unknown): string | null {
  return err instanceof ApiError && err.code === "simulation_failed" ? String((err.detail as { raw?: unknown } | undefined)?.raw ?? "") : null;
}

/** A v2 contract's refusal as the API answers it: simulation_failed, named (V10), with its stable code where it has
 *  one, and the simulation's own text when there was one. */
function refusalFor(e: NamedError, raw: string | null): ApiError {
  const key = `${e.source} ${e.name}`;
  const contractCode = CONTRACT_CODES[key];
  return new ApiError(422, "simulation_failed", REFUSAL_TEXT[key] ?? `The contract refused this (${e.name}).`, {
    ...(contractCode ? { contractCode } : {}),
    contractError: { origin: e.origin, code: e.code, name: e.name, contract: e.source },
    ...(raw === null ? {} : { raw }),
  });
}

/** A refusal the builder knows of before simulating (nothing to claim), answered as the contract's own would be. */
function refusalOf(contract: string, name: string): ApiError {
  return refusalFor(V2_ERRORS.find((e) => e.source === contract && e.name === name)!, null);
}

/** `err` as the API answers it: a v2 contract's refusal named, and the launchpad's UnknownLaunch as 404. Anything else
 *  unchanged. */
export function v2Refusal(err: unknown): unknown {
  const raw = rawOf(err);
  const e = raw === null ? null : v2ErrorOf(raw);
  const named = e ? errorsFor(e.origin, e.code)[0] : undefined;
  if (!named) return err;
  if (named.source === "launchpad-v2" && named.name === "UnknownLaunch") return notFound("Launch");
  return refusalFor(named, raw);
}

async function refusing<T>(run: () => Promise<T>): Promise<T> {
  try {
    return await run();
  } catch (err) {
    throw v2Refusal(err);
  }
}

/** An action that isn't open now: 409 not_available, with when it opens where that is known. */
function notAvailable(message: string, availableAt: string | null = null): ApiError {
  return new ApiError(409, "not_available", message, { availableAt });
}

// ------------------------------------------------------------------------------------------------ decoding

export interface VenueV2 {
  id: number;
  kind: VenueKindV2;
  /** What the app shows: the launch's own venue, never another's (Soroswap, Aquarius 0.3%, …). */
  name: string;
  executor: string;
  enabled: boolean;
  feeFraction: number;
}

/** A venue's name as every label shows it. */
export function venueName(kind: VenueKindV2, feeFraction = 0): string {
  switch (kind) {
    case "Soroswap":
      return "Soroswap";
    case "Aquarius":
      return `Aquarius ${feeFraction / 100}%`;
    case "QaFail":
      return "the QA test venue";
    default:
      return "a hold-only venue";
  }
}

function venueOf(v: any): VenueV2 {
  const kind = VENUE_KINDS[Number(v.kind)] ?? "HoldOnly";
  const feeFraction = Number(v.params?.fee_fraction ?? 0);
  return { id: Number(v.id), kind, name: venueName(kind, feeFraction), executor: String(v.executor), enabled: v.enabled === true, feeFraction };
}

/** launchpad-v2's durations in seconds, camel-cased as the API serves them. */
export interface LaunchDurationsJson {
  grace: number;
  fallbackDelay: number;
  rescueAdmin: number;
  rescuePublic: number;
  lockedFallback: number;
  takeoverDelay: number;
  takeoverWindow: number;
  timelock: number;
  timelockWindow: number;
  harvestInterval: number;
}

const camel = (k: string) => k.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());

function durationsOf(d: any): LaunchDurationsJson {
  return Object.fromEntries(LAUNCH_DURATION_KEYS.map((k) => [camel(k), Number(d[k])])) as unknown as LaunchDurationsJson;
}

/** LaunchTerms (§5.3), everything a launch binds: amounts in base units, times in seconds. */
export interface LaunchTermsJson {
  supply: string;
  feeBps: number;
  protocolShareBps: number;
  maxCreatorFeeBps: number;
  snipeSchedule: number[];
  snipeStepSecs: number;
  /** In XLM stroops, paid to the launchpad (O6). */
  launchFee: string;
  /** The XLM Stellar Asset Contract. */
  feeAsset: string;
  quote: string;
  phantom: string;
  threshold: string;
  venue: VenueV2;
  fallback: VenueV2;
  venueLocked: boolean;
  locker: string;
  tokenWasmHash: string;
  durations: LaunchDurationsJson;
}

export function termsOf(t: any): LaunchTermsJson {
  return {
    supply: String(t.supply),
    feeBps: Number(t.fee_bps),
    protocolShareBps: Number(t.protocol_share_bps),
    maxCreatorFeeBps: Number(t.max_creator_fee_bps),
    snipeSchedule: (t.snipe_schedule as unknown[]).map(Number),
    snipeStepSecs: Number(t.snipe_step_secs),
    launchFee: String(t.launch_fee),
    feeAsset: String(t.fee_asset),
    quote: String(t.quote),
    phantom: String(t.phantom),
    threshold: String(t.threshold),
    venue: venueOf(t.venue),
    fallback: venueOf(t.fallback),
    venueLocked: t.venue_locked === true,
    locker: String(t.locker),
    tokenWasmHash: Buffer.from(t.token_wasm_hash as Uint8Array).toString("hex"),
    durations: durationsOf(t.durations),
  };
}

/** A launch's record (§5.3): what never changes about it. */
interface LaunchRecord {
  token: string;
  creator: string;
  quote: string;
  name: string;
  symbol: string;
  createdAt: number;
  feeBps: number;
  protocolShareBps: number;
  creatorFeeBps: number;
  venue: VenueV2;
  fallback: VenueV2;
  venueLocked: boolean;
  holderSharing: boolean;
}

/** A launch's moving state (§5.3). */
interface CurveState {
  phase: PhaseV2;
  realQuote: bigint;
  threshold: bigint;
  creatorFees: bigint;
  completedAt: number;
  stuckSince: number;
  fallbackAllowed: boolean;
  pool: string | null;
  graduatedVenue: number | null;
  refundQuote: bigint;
  refundSupply: bigint;
  refunded: bigint;
}

async function launchOf(pad: string, token: string): Promise<LaunchRecord> {
  if (!isContractId(token)) throw notFound("Launch");
  const l = await refusing(() => view(pad, "get_launch", [sv.addr(token)]));
  return {
    token: String(l.token),
    creator: String(l.creator),
    quote: String(l.quote),
    name: String(l.name),
    symbol: String(l.symbol),
    createdAt: Number(l.created_at),
    feeBps: Number(l.fee_bps),
    protocolShareBps: Number(l.protocol_share_bps),
    creatorFeeBps: Number(l.creator_fee_bps),
    venue: venueOf(l.venue),
    fallback: venueOf(l.fallback),
    venueLocked: l.venue_locked === true,
    holderSharing: l.holder_sharing === true,
  };
}

async function curveOf(pad: string, token: string): Promise<CurveState> {
  const c = await refusing(() => view(pad, "get_curve", [sv.addr(token)]));
  const known = (v: unknown) => v !== null && v !== undefined;
  return {
    phase: PHASES[Number(c.phase)] ?? "curve",
    realQuote: big(c.real_quote),
    threshold: big(c.threshold),
    creatorFees: big(c.creator_fees),
    completedAt: Number(c.completed_at),
    stuckSince: Number(c.stuck_since),
    fallbackAllowed: c.fallback_allowed === true,
    pool: known(c.pool) ? String(c.pool) : null,
    graduatedVenue: known(c.graduated_venue) ? Number(c.graduated_venue) : null,
    refundQuote: big(c.refund_quote),
    refundSupply: big(c.refund_supply),
    refunded: big(c.refunded),
  };
}

/** Refuses terms the app's pins wouldn't sign (§20.4, F18): a launch fee above the pinned bound, another locker or
 *  token WASM, durations other than the deployment's, an executor that isn't one of its own. */
export function checkTermsPinned(terms: LaunchTermsJson, net: NetworkConfig): void {
  const v2 = deployed(net).v2;
  const unpinned = (field: string) =>
    new ApiError(409, "terms_unpinned", "The launchpad's terms don't match this app's. Update the app or try again later.", { field });
  if (BigInt(terms.launchFee) > net.maxLaunchFeeStroops) throw unpinned("launchFee");
  if (terms.locker !== net.contracts.lpLocker) throw unpinned("locker");
  if (terms.tokenWasmHash !== v2.runtimeWasmHashes.launchTokenV2) throw unpinned("tokenWasmHash");
  for (const k of LAUNCH_DURATION_KEYS) {
    if (terms.durations[camel(k) as keyof LaunchDurationsJson] !== v2.durations.launch[k]) throw unpinned(`durations.${camel(k)}`);
  }
  const executors = [v2.contracts.execSoroswap, v2.contracts.execAquarius, v2.qa?.qaExecFail].filter(Boolean);
  for (const v of [terms.venue, terms.fallback]) if (!executors.includes(v.executor)) throw unpinned("venue");
}

// ------------------------------------------------------------------------------------------------ /v1/economics

export interface QuoteV2 {
  asset: string;
  code: string;
  contract: string;
  phantom: string;
  threshold: string;
  enabled: boolean;
  /** Venue ids a launch in this quote may choose; empty: every enabled venue. */
  venuesAllowed: number[];
  /** Always a Soroswap venue. */
  fallbackVenue: number;
  /** The allowlist leaves the fallback out: it waits `lockedFallback` or the admin's allow_fallback (§5.3). */
  venueLocked: boolean;
  /** The venue create picks when none is asked for; null when none is open. */
  defaultVenue: number | null;
  /** preview_launch_terms(quote, defaultVenue): what a launch on it binds now. Null while the quote is off. */
  terms: LaunchTermsJson | null;
}

/** The launchpad block of /v1/economics (§20.2). The admin is never served. */
export interface LaunchpadV2Economics {
  contract: string;
  generation: 2;
  launchesEnabled: boolean;
  whitelistEnabled: boolean;
  supply: string;
  feeBps: number;
  protocolShareBps: number;
  maxCreatorFeeBps: number;
  snipeSchedule: number[];
  snipeStepSecs: number;
  /** Booked on the launch and swept to the treasury by anyone (O6, §5.5). */
  launchFee: { asset: "XLM"; contract: string; amount: string; booked: true };
  treasury: string;
  locker: string;
  venues: VenueV2[];
  quotes: QuoteV2[];
  durations: LaunchDurationsJson;
  /** After graduation (§8.2, §14.4): every interval, at most roundCapBps of the position, all of the growth, both sides
   *  split by the launch's own pinned protocolShareBps (V1); holders paid in the quote and the token (F1); the treasury
   *  holds the launch tokens it receives (V2). `split` is what new launches pin. */
  harvest: {
    intervalSecs: number;
    roundCapBps: number;
    harvestBps: number;
    split: { protocolBps: number; creatorOrHoldersBps: number };
    splitPinnedPerLaunch: true;
    sides: ["quote", "token"];
    holdersPaidIn: ["quote", "token"];
    treasuryLaunchTokens: "held";
  };
  /** exclude_pool's floor (F2). */
  exclusionFloor: { minPoolTokens: string; minPendingQuote: string; minPendingTokens: string };
  /** exec-aquarius's float (F11), where the deployment has the Aquarius venue; null elsewhere (O7). */
  aquariusFloat: { asset: string; amount: string; poolPayment: string; target: string; alertBelow: string } | null;
}

let cachedEconomics: { key: string; at: number; value: LaunchpadV2Economics } | null = null;

/** Drops the isolate's reads (tests). */
export function forgetLaunchV2Reads(): void {
  cachedEconomics = null;
}

/** Whether a venue is one this deployment offers: Aquarius only where it is enabled (O7). */
function offered(v: VenueV2, v2: DeploymentV2): boolean {
  return v.kind !== "Aquarius" || v2.aquarius.enabled;
}

/** The venue create picks for a quote: its fallback (Soroswap) when every venue is allowed, else the first allowed
 *  venue that is open. */
function defaultVenue(econ: any, venues: VenueV2[], v2: DeploymentV2): number | null {
  const allowed = (econ.venues_allowed as unknown[]).map(Number);
  const open = (id: number) => venues.some((v) => v.id === id && v.enabled && offered(v, v2));
  if (allowed.length === 0) return open(Number(econ.fallback_venue)) ? Number(econ.fallback_venue) : null;
  return allowed.find(open) ?? null;
}

async function quoteEconomics(pad: string, q: QuoteAsset, venues: VenueV2[], v2: DeploymentV2): Promise<QuoteV2 | null> {
  const econ = await view(pad, "quote_economics", [sv.addr(q.contract)]);
  if (econ === null || econ === undefined) return null;
  const allowed = (econ.venues_allowed as unknown[]).map(Number);
  const fallback = Number(econ.fallback_venue);
  const venue = econ.enabled === true ? defaultVenue(econ, venues, v2) : null;
  const terms = venue === null ? null : termsOf(await view(pad, "preview_launch_terms", [sv.addr(q.contract), sv.u32(venue)]));
  return {
    asset: q.id,
    code: q.code,
    contract: q.contract,
    phantom: String(econ.phantom),
    threshold: String(econ.threshold),
    enabled: econ.enabled === true,
    venuesAllowed: allowed,
    fallbackVenue: fallback,
    venueLocked: allowed.length > 0 && !allowed.includes(fallback),
    defaultVenue: venue,
    terms,
  };
}

async function aquariusFloat(v2: DeploymentV2): Promise<LaunchpadV2Economics["aquariusFloat"]> {
  const exec = v2.contracts.execAquarius;
  if (!v2.aquarius.enabled || !exec) return null;
  const [float, payment] = await Promise.all([view(exec, "float"), view(exec, "pool_payment")]);
  const amount = big(payment[1]);
  return {
    asset: String(payment[0]),
    amount: String(float),
    poolPayment: amount.toString(),
    target: (amount * AQUA_FLOAT_TARGET[v2.durations.set]).toString(),
    alertBelow: (amount * AQUA_FLOAT_ALERT).toString(),
  };
}

/** /v1/economics' launchpad block for v2 (§20.2), read live and kept 5 minutes; when a read fails, the last answer
 *  read is served, and without one 502 rpc_unavailable. Null where v2 isn't deployed. */
export async function launchpadV2Economics(net: NetworkConfig = env.network, now: number = Date.now()): Promise<LaunchpadV2Economics | null> {
  if (!net.contracts.launchpadV2 || !net.deploymentV2) return null;
  const { pad, v2 } = deployed(net);
  const key = `${net.passphrase}|${pad}`;
  if (cachedEconomics && cachedEconomics.key === key && now - cachedEconomics.at < ECONOMICS_V2_TTL_MS && now >= cachedEconomics.at) {
    return cachedEconomics.value;
  }
  try {
    const [cfg, table] = await Promise.all([view(pad, "config"), view(pad, "venues")]);
    const venues = (table as unknown[]).map(venueOf).filter((v) => offered(v, v2));
    const assets = quoteAssets(net);
    const [quotes, float] = await Promise.all([Promise.all(assets.map((q) => quoteEconomics(pad, q, venues, v2))), aquariusFloat(v2)]);
    const ps = Number(cfg.protocol_share_bps);
    const durations = durationsOf(cfg.durations);
    const value: LaunchpadV2Economics = {
      contract: pad,
      generation: 2,
      launchesEnabled: cfg.launches_enabled === true,
      whitelistEnabled: cfg.whitelist_enabled === true,
      supply: String(cfg.supply),
      feeBps: Number(cfg.fee_bps),
      protocolShareBps: ps,
      maxCreatorFeeBps: Number(cfg.max_creator_fee_bps),
      snipeSchedule: (cfg.snipe_schedule as unknown[]).map(Number),
      snipeStepSecs: Number(cfg.snipe_step_secs),
      launchFee: { asset: "XLM", contract: String(cfg.xlm), amount: String(cfg.launch_fee), booked: true },
      treasury: String(cfg.treasury),
      locker: String(cfg.locker),
      venues,
      quotes: quotes.filter((q): q is QuoteV2 => q !== null),
      durations,
      harvest: {
        intervalSecs: durations.harvestInterval,
        roundCapBps: Number(MAX_HARVEST_ROUND_BPS),
        harvestBps: Number(LAUNCH_HARVEST_BPS),
        split: { protocolBps: ps, creatorOrHoldersBps: Number(BPS) - ps },
        splitPinnedPerLaunch: true,
        sides: ["quote", "token"],
        holdersPaidIn: ["quote", "token"],
        treasuryLaunchTokens: "held",
      },
      exclusionFloor: {
        minPoolTokens: EXCLUSION_MIN_POOL_TOKENS.toString(),
        minPendingQuote: EXCLUSION_MIN_PENDING_QUOTE.toString(),
        minPendingTokens: EXCLUSION_MIN_POOL_TOKENS.toString(),
      },
      aquariusFloat: float,
    };
    cachedEconomics = { key, at: now, value };
    return value;
  } catch (err) {
    if (cachedEconomics && cachedEconomics.key === key) return cachedEconomics.value;
    throw new ApiError(502, "rpc_unavailable", "The launchpad's terms couldn't be read just now. Try again.", { raw: String((err as Error).message ?? err).slice(0, 300) });
  }
}

// ------------------------------------------------------------------------------------------------ live reads

/** Why a graduation is delayed (V10): a recorded failure's pair (the indexer's grad_fail), or what graduate fails with
 *  in a simulation now. */
export interface GraduationFailure {
  origin: number;
  code: number;
  /** From v2_errors.ts; null for a pair it doesn't know. */
  name: string | null;
  contract: string | null;
  source: "recorded" | "simulated";
}

export interface LaunchStatusV2 {
  token: string;
  phase: PhaseV2;
  completedAt: string | null;
  stuck: boolean;
  stuckSince: string | null;
  /** When mark_stuck opens: completion + grace. */
  markStuckAt: string | null;
  /** When graduate_fallback opens: stuck_since + fallbackDelay, later for a venue-locked launch (F14). */
  fallbackAt: string | null;
  rescueAdminAt: string | null;
  rescuePublicAt: string | null;
  venue: VenueV2;
  fallback: VenueV2;
  venueLocked: boolean;
  fallbackAllowed: boolean;
  pool: string | null;
  graduatedVenue: VenueV2 | null;
  /** Refund mode (Rescued): the fixed rate, in quote per whole token, for every holder in any order (O2). */
  refund: { quote: string; supply: string; refunded: string; rate: string } | null;
  failure: GraduationFailure | null;
  /** What a plan may do now: the time-gated ones open at the times above. */
  actions: { buy: boolean; sell: boolean; graduate: boolean; graduateFallback: boolean; markStuck: boolean; rescue: boolean; refund: boolean };
}

export interface LaunchStateV2 {
  status: LaunchStatusV2;
  quote: { id: string; code: string; contract: string };
  /** Who the creator fees and the creator side of harvests go to now. */
  recipient: string;
  /** The admin's takeover (§5.4): `open` inside its window, `lapsed` after it. */
  pendingTakeover: { new: string; effectiveAt: string; expiresAt: string; state: "waiting" | "open" | "lapsed" } | null;
  /** Curve fees booked for the current recipient, in the quote. */
  creatorFees: string;
  /** Holder rewards in both assets (L13, F1): the quote, and the launch token after graduation. */
  rewards: {
    sharing: boolean;
    eligible: string | null;
    queuedQuote: string;
    queuedToken: string;
    releasableFromLedger: number | null;
    /** The viewer's, claimable now (null without a viewer). */
    pendingQuote: string | null;
    pendingToken: string | null;
  };
  /** The viewer's: owed fees from before a recipient change (L14), in the quote. */
  you: { isRecipient: boolean; creatorOwed: string } | null;
}

function failureNamed(f: { origin: number; code: number }, source: GraduationFailure["source"]): GraduationFailure {
  const named = errorsFor(f.origin, f.code);
  return {
    origin: f.origin,
    code: f.code,
    name: named.length ? [...new Set(named.map((e) => e.name))].join(" or ") : null,
    contract: named.length ? [...new Set(named.map((e) => e.source))].join(" or ") : null,
    source,
  };
}

/** What graduate does now, simulated: the failure it would record, or that it aborts with; null when it would
 *  graduate (the keeper will) or when RPC can't say. */
async function simulatedFailure(pad: string, token: string): Promise<GraduationFailure | null> {
  try {
    const outcome = await view(pad, "graduate", [sv.addr(token)]);
    if (Array.isArray(outcome) && outcome[0] === "Failed") return failureNamed({ origin: Number(outcome[1].origin), code: Number(outcome[1].code) }, "simulated");
    return null;
  } catch (err) {
    const raw = rawOf(err);
    const f = raw === null ? null : failureOf(raw);
    return f ? failureNamed(f, "simulated") : null;
  }
}

/** What a status read may say about a stuck launch's failure: the indexer's recorded one, a simulation now (the
 *  default), or nothing (a builder that only needs the times). */
export interface StatusOptions {
  failure?: { origin: number; code: number } | null;
  probe?: boolean;
  now?: number;
}

/** status(token) and the curve it reads, with the stuck launch's failure. */
async function readStatus(pad: string, token: string, launch: LaunchRecord, opts: StatusOptions): Promise<{ status: LaunchStatusV2; curve: CurveState }> {
  const [s, curve] = await Promise.all([refusing(() => view(pad, "status", [sv.addr(token)])), curveOf(pad, token)]);
  const stuck = curve.phase === "completed" && curve.stuckSince > 0;
  const failure = !stuck
    ? null
    : opts.failure
    ? failureNamed(opts.failure, "recorded")
    : opts.probe === false
    ? null
    : await simulatedFailure(pad, token);
  return { status: statusOf(token, s, launch, curve, failure, opts.now ?? Date.now()), curve };
}

function statusOf(token: string, s: any, launch: LaunchRecord, curve: CurveState, failure: GraduationFailure | null, nowMs: number): LaunchStatusV2 {
  const now = nowSecs(nowMs);
  const phase = PHASES[Number(s.phase)] ?? curve.phase;
  const completed = phase === "completed";
  const stuck = completed && Number(s.stuck_since) > 0;
  const fallbackAt = Number(s.fallback_at);
  const rescued = phase === "rescued";
  const refundSupply = big(s.refund_supply);
  return {
    token,
    phase,
    completedAt: isoAt(s.completed_at),
    stuck,
    stuckSince: isoAt(s.stuck_since),
    markStuckAt: isoAt(s.mark_stuck_at),
    fallbackAt: isoAt(fallbackAt),
    rescueAdminAt: isoAt(s.rescue_admin_at),
    rescuePublicAt: isoAt(s.rescue_public_at),
    venue: launch.venue,
    fallback: launch.fallback,
    venueLocked: launch.venueLocked,
    fallbackAllowed: curve.fallbackAllowed,
    pool: curve.pool,
    graduatedVenue: curve.graduatedVenue === null ? null : [launch.venue, launch.fallback].find((v) => v.id === curve.graduatedVenue) ?? null,
    refund: rescued && refundSupply > 0n
      ? { quote: String(s.refund_quote), supply: refundSupply.toString(), refunded: curve.refunded.toString(), rate: ratio(big(s.refund_quote), refundSupply) }
      : null,
    failure: stuck ? failure : null,
    actions: {
      buy: phase === "curve",
      sell: phase === "curve",
      graduate: completed,
      graduateFallback: stuck && fallbackAt > 0 && now >= fallbackAt,
      markStuck: completed && !stuck && Number(s.mark_stuck_at) > 0 && now >= Number(s.mark_stuck_at),
      rescue: stuck && Number(s.rescue_public_at) > 0 && now >= Number(s.rescue_public_at),
      refund: rescued,
    },
  };
}

/** status(token) with the launch's venues and refund figures (§5.3, V10): `failure` is the indexer's recorded one
 *  when the caller has it; otherwise a stuck launch's is simulated. */
export async function launchStatusV2(token: string, opts: StatusOptions = {}): Promise<LaunchStatusV2> {
  const { pad } = deployed(env.network);
  return (await readStatus(pad, token, await launchOf(pad, token), opts)).status;
}

/** A launch's live reads for its page (§20.2–20.3): status, the recipient and a pending takeover, booked creator
 *  fees, holder rewards in both assets, and the viewer's owed fees. */
export async function launchStateV2(token: string, viewer: string | null, opts: StatusOptions = {}): Promise<LaunchStateV2> {
  const net = env.network;
  const { pad } = deployed(net);
  const nowMs = opts.now ?? Date.now();
  const launch = await launchOf(pad, token);
  const t = sv.addr(token);
  const [{ status, curve }, recipient, takeover, sharing, queued, pending, owed] = await Promise.all([
    readStatus(pad, token, launch, opts),
    view(pad, "creator_fee_recipient", [t]),
    view(pad, "pending_recipient_change", [t]),
    view(token, "sharing"),
    view(token, "queued_rewards"),
    viewer ? view(token, "pending_rewards", [sv.addr(viewer)]) : Promise.resolve(null),
    viewer ? view(pad, "creator_owed", [sv.addr(viewer), sv.addr(launch.quote)]) : Promise.resolve(null),
  ]);
  const now = nowSecs(nowMs);
  const q = quoteNamed(net, launch.quote);
  const on = sharing !== null && sharing !== undefined;
  return {
    status,
    quote: { id: q.id, code: q.code, contract: launch.quote },
    recipient: String(recipient),
    pendingTakeover: takeover
      ? {
        new: String(takeover.new),
        effectiveAt: isoAt(takeover.effective_at)!,
        expiresAt: isoAt(takeover.expires_at)!,
        state: now < Number(takeover.effective_at) ? "waiting" : now <= Number(takeover.expires_at) ? "open" : "lapsed",
      }
      : null,
    creatorFees: curve.creatorFees.toString(),
    rewards: {
      sharing: on,
      eligible: on ? String(sharing.eligible) : null,
      queuedQuote: String(queued[0]),
      queuedToken: String(queued[1]),
      releasableFromLedger: on && (big(queued[0]) > 0n || big(queued[1]) > 0n) ? Number(queued[2]) : null,
      pendingQuote: pending ? String(pending[0]) : null,
      pendingToken: pending ? String(pending[1]) : null,
    },
    you: viewer ? { isRecipient: String(recipient) === viewer, creatorOwed: String(owed ?? 0) } : null,
  };
}

// ------------------------------------------------------------------------------------------------ quotes

export interface TradeQuoteV2 {
  side: "buy" | "sell" | "refund";
  used?: string;
  tokensOut?: string;
  quoteOut?: string;
  fees: string;
  baseFee?: string;
  creatorFee?: string;
  snipeFee?: string;
  /** What a full curve leaves of a buy. */
  refund?: string;
  /** Refunds: the fixed rate, in quote per whole token (O2). */
  rate?: string;
}

/** What the curve would do now (buy, sell), or a rescued launch's refund pays: every fee apart, none on a refund. */
export async function quoteTradeV2(user: string, token: string, side: "buy" | "sell" | "refund", amount: bigint): Promise<TradeQuoteV2> {
  const { pad } = deployed(env.network);
  if (!isContractId(token)) throw notFound("Launch");
  const t = sv.addr(token);
  if (side === "buy") {
    const q = await refusing(() => view(pad, "quote_buy", [t, sv.addr(user), sv.i128(amount)]));
    const [used, baseFee, creatorFee, snipeFee] = [big(q.used), big(q.base_fee), big(q.creator_fee), big(q.snipe_fee)];
    return {
      side,
      used: used.toString(),
      tokensOut: String(q.tokens_out),
      fees: (baseFee + creatorFee + snipeFee).toString(),
      baseFee: baseFee.toString(),
      creatorFee: creatorFee.toString(),
      snipeFee: snipeFee.toString(),
      refund: (amount - used).toString(),
    };
  }
  if (side === "sell") {
    const q = await refusing(() => view(pad, "quote_sell", [t, sv.i128(amount)]));
    const [baseFee, creatorFee] = [big(q.base_fee), big(q.creator_fee)];
    return { side, quoteOut: String(q.quote_out), fees: (baseFee + creatorFee).toString(), baseFee: baseFee.toString(), creatorFee: creatorFee.toString() };
  }
  const [out, curve] = await Promise.all([refusing(() => view(pad, "quote_refund", [t, sv.i128(amount)])), curveOf(pad, token)]);
  return { side, quoteOut: String(out), fees: "0", rate: ratio(curve.refundQuote, curve.refundSupply) };
}

// ------------------------------------------------------------------------------------------------ XLM for a launch

/** What a launch leaves an account in XLM (§20.3, F18, V12), in stroops. */
export interface LaunchXlm {
  balance: string;
  /** (2 + subentries + sponsoring − sponsored) × the base reserve. */
  minBalance: string;
  /** XLM the account's open DEX offers sell: the network won't spend it. */
  sellingLiabilities: string;
  launchFee: string;
  /** The launch's network fee: its simulated resource fee and rent, with the API's margin. */
  fees: string;
  buffer: string;
  /** balance − minBalance − sellingLiabilities − launchFee − fees − buffer: what an XLM initial buy may take. Negative
   *  when even a launch without one doesn't fit. */
  spendable: string;
}

/** The XLM a launch leaves to spend on its initial buy: may be negative. */
export function launchXlmOf(position: XlmPosition, launchFee: bigint, fees: bigint): LaunchXlm {
  const spendable = BigInt(position.balance) - BigInt(position.minBalance) - BigInt(position.sellingLiabilities) - launchFee - fees - LAUNCH_XLM_BUFFER;
  return {
    balance: position.balance,
    minBalance: position.minBalance,
    sellingLiabilities: position.sellingLiabilities,
    launchFee: launchFee.toString(),
    fees: fees.toString(),
    buffer: LAUNCH_XLM_BUFFER.toString(),
    spendable: spendable.toString(),
  };
}

/** Refuses a launch whose XLM doesn't fit (F18): 409 insufficient_xlm with how much more XLM it needs. `need` is the
 *  XLM initial buy (0 for another quote). */
export function assertLaunchXlm(xlm: LaunchXlm, need: bigint): void {
  const shortfall = need - BigInt(xlm.spendable);
  if (shortfall <= 0n) return;
  throw new ApiError(
    409,
    "insufficient_xlm",
    `Not enough XLM: ${fromStroops(shortfall)} XLM more covers the ${fromStroops(xlm.launchFee)} XLM launch fee${need > 0n ? ", your first buy" : ""}, the network fee and the XLM your account keeps.`,
    { shortfall: shortfall.toString(), need: need.toString(), ...xlm },
  );
}

/** The account's XLM position and its balance of `quote` (the XLM balance for XLM). Null when the account is missing. */
async function balancesOf(user: string, quote: QuoteAsset): Promise<{ position: XlmPosition; quoteBalance: bigint } | null> {
  const [acct, reserve] = await Promise.all([classicBalances(user), baseReserve()]);
  const position = positionOf(acct, reserve);
  if (!acct || !position) return null;
  const line = acct.balances.find((b) => b.asset === quote.classic);
  return { position, quoteBalance: line ? BigInt(line.balance) : 0n };
}

/** A launch's parameters as launch() takes them (LaunchParams, §5.3). */
export interface LaunchInput {
  quote: string;
  name: string;
  symbol: string;
  uri: string;
  creatorFeeBps: number;
  venue: number;
  holderSharing: boolean;
  recipient: string | null;
  exempt: string[];
  initialBuy: bigint;
  minOut: bigint;
  nonce: bigint;
}

function launchParams(p: LaunchInput): xdr.ScVal {
  return struct({
    quote: sv.addr(p.quote),
    name: sv.str(p.name),
    symbol: sv.str(p.symbol),
    uri: sv.str(p.uri),
    creator_fee_bps: sv.u32(p.creatorFeeBps),
    venue: sv.u32(p.venue),
    holder_sharing: sv.bool(p.holderSharing),
    creator_fee_recipient: p.recipient ? sv.addr(p.recipient) : xdr.ScVal.scvVoid(),
    snipe_exempt: sv.vec(p.exempt.map(sv.addr)),
    initial_buy: sv.i128(p.initialBuy),
    min_tokens_out: sv.i128(p.minOut),
    nonce: sv.u64(p.nonce),
  });
}

/** A random 64-bit nonce (L15): with the creator, it fixes the token's address. */
export function launchNonce(): bigint {
  return crypto.getRandomValues(new BigUint64Array(1))[0];
}

/** The network fee of `p`'s launch, simulated: the fee its transaction would declare. Null when it can't be simulated
 *  (not enough of either asset to try). */
async function launchFeeOf(user: string, pad: string, p: LaunchInput, terms: xdr.ScVal): Promise<bigint | null> {
  try {
    const acct = await requireAccount(user);
    return BigInt((await invoke(acct, pad, "launch", [sv.addr(user), launchParams(p), terms])).fee);
  } catch (err) {
    if (err instanceof ApiError && ["simulation_failed", "needs_restore"].includes(err.code)) return null;
    throw err;
  }
}

/** The quote, the venue and the terms of a launch to be: the venue asked for (it must be open to the quote), or the
 *  quote's default. */
async function launchTermsFor(net: NetworkConfig, quoteId: string, venueId?: unknown): Promise<{ quote: QuoteAsset; venue: number; raw: xdr.ScVal; terms: LaunchTermsJson }> {
  const { pad, v2 } = deployed(net);
  const quote = quoteAssetOf(net, quoteId);
  if (!quote) throw bad("bad_quote", "Launches are quoted in XLM or USDC.");
  const [econ, table] = await Promise.all([view(pad, "quote_economics", [sv.addr(quote.contract)]), view(pad, "venues")]);
  if (!econ || econ.enabled !== true) throw bad("bad_quote", `Launches in ${quote.code} aren't open.`);
  const venues = (table as unknown[]).map(venueOf);
  let venue: number | null;
  if (venueId === undefined || venueId === null) {
    venue = defaultVenue(econ, venues, v2);
  } else {
    venue = Number(venueId);
    const v = venues.find((x) => x.id === venue);
    const allowed = (econ.venues_allowed as unknown[]).map(Number);
    if (!Number.isInteger(venue) || !v || !v.enabled || !offered(v, v2) || (allowed.length > 0 && !allowed.includes(venue))) {
      throw bad("bad_venue", `That venue isn't open to launches in ${quote.code}.`);
    }
  }
  if (venue === null) throw bad("bad_venue", `No venue is open to launches in ${quote.code}.`);
  const raw = await refusing(() => viewRaw(pad, "preview_launch_terms", [sv.addr(quote.contract), sv.u32(venue!)]));
  const terms = termsOf(scValToNative(raw));
  checkTermsPinned(terms, net);
  return { quote, venue, raw, terms };
}

export interface LaunchPreviewV2 {
  quote: { id: string; code: string; contract: string };
  venue: VenueV2;
  terms: LaunchTermsJson;
  launchFee: { asset: "XLM"; amount: string; booked: true; to: string };
  xlm: LaunchXlm;
  quoteBalance: string;
  /** The Create screen's Max: for an XLM quote what the launch leaves (xlm.spendable, at least 0); for another quote
   *  its balance. */
  maxInitialBuy: string;
  /** XLM missing before any buy; null when a launch fits. */
  shortfall: string | null;
}

/** The launch preview: the terms a launch would bind now, its fee, and Max (§20.3, F18, V12). The network
 *  fee is the launch's own, simulated with the form's details (the longest name, ticker and URI where they are still
 *  empty), and for an XLM quote simulated again at Max, so a buy of exactly Max passes create's check. */
export async function launchPreviewV2(user: string, input: Partial<LaunchV2BuildInput>): Promise<LaunchPreviewV2> {
  const net = env.network;
  const { pad } = deployed(net);
  const { quote, venue, raw, terms } = await launchTermsFor(net, String(input.quote ?? "XLM"), input.venue);
  const balances = await balancesOf(user, quote);
  if (!balances) throw new ApiError(409, "account_inactive", "Activate your Stellar account first.");
  const launchFee = BigInt(terms.launchFee);
  const xlmQuote = quote.contract === terms.feeAsset;
  const p: LaunchInput = {
    quote: quote.contract,
    name: typeof input.name === "string" && input.name.trim() ? input.name.trim() : "N".repeat(32),
    symbol: typeof input.symbol === "string" && input.symbol.trim() ? input.symbol.trim().toUpperCase() : "S".repeat(10),
    uri: typeof input.uri === "string" && input.uri ? input.uri : "u".repeat(net.limits.uriMax),
    creatorFeeBps: Number.isInteger(input.creatorFeeBps) ? Number(input.creatorFeeBps) : 0,
    venue,
    holderSharing: input.holderSharing !== false,
    recipient: typeof input.recipient === "string" && input.recipient ? input.recipient : null,
    exempt: Array.isArray(input.exempt) ? input.exempt.filter((a): a is string => typeof a === "string") : [],
    // A buy of one unit costs what any buy does: the curve's entries and the creator's token balance.
    initialBuy: xlmQuote || balances.quoteBalance > 0n ? 1n : 0n,
    minOut: 0n,
    nonce: launchNonce(),
  };
  let fees = await launchFeeOf(user, pad, p, raw) ?? await feeCeiling("launch_create");
  let xlm = launchXlmOf(balances.position, launchFee, fees);
  if (xlmQuote && BigInt(xlm.spendable) > 1n) {
    // A buy that completes the curve does more (the clamp, the complete event): price Max itself.
    const atMax = await launchFeeOf(user, pad, { ...p, initialBuy: BigInt(xlm.spendable) }, raw);
    if (atMax !== null && atMax > fees) {
      fees = atMax;
      xlm = launchXlmOf(balances.position, launchFee, fees);
    }
  }
  const spendable = BigInt(xlm.spendable);
  const max = xlmQuote ? (spendable > 0n ? spendable : 0n) : balances.quoteBalance;
  return {
    quote: { id: quote.id, code: quote.code, contract: quote.contract },
    venue: terms.venue,
    terms,
    launchFee: { asset: "XLM", amount: terms.launchFee, booked: true, to: pad },
    xlm,
    quoteBalance: balances.quoteBalance.toString(),
    maxInitialBuy: max.toString(),
    shortfall: spendable < 0n ? (-spendable).toString() : null,
  };
}

// ------------------------------------------------------------------------------------------------ harvests (V7)

const isqrt = (n: bigint): bigint => {
  if (n < 2n) return n;
  let x = 1n << BigInt(Math.ceil(n.toString(2).length / 2));
  for (;;) {
    const y = (x + n / x) >> 1n;
    if (y >= x) return x;
    x = y;
  }
};

/** A locked Soroswap position and its pool, as one harvest round reads them (§8.2). Amounts in base units; `principal`
 *  and every value in √k units. */
export interface PoolPosition {
  reserveToken: bigint;
  reserveQuote: bigint;
  totalLp: bigint;
  lp: bigint;
  principal: bigint;
}

export interface HarvestRound {
  /** The position's value: isqrt(r_b·r_q)·lp/total. */
  current: bigint;
  growth: bigint;
  /** 0.5% of `current`: the most one round takes. */
  cap: bigint;
  take: bigint;
  /** 0 when the round can't run: no growth, or too little to pay out on both sides. */
  lpToBurn: bigint;
  tokenOut: bigint;
  quoteOut: bigint;
}

/** One harvest round of a launch's position, as lp-locker computes it (lp-locker/src/harvest.rs `round`): take the
 *  growth up to 0.5% of the position, and burn LP of at most that value (§8.2's amended dl = take·total/(isqrt + 1)). */
export function harvestRound(p: PoolPosition): HarvestRound {
  const root = isqrt(p.reserveToken * p.reserveQuote);
  const current = p.totalLp === 0n ? 0n : (root * p.lp) / p.totalLp;
  const growth = current > p.principal ? current - p.principal : 0n;
  const cap = (current * MAX_HARVEST_ROUND_BPS) / BPS;
  const all = (growth * LAUNCH_HARVEST_BPS) / BPS;
  const take = growth === 0n ? 0n : all < cap ? all : cap;
  const r: HarvestRound = { current, growth, cap, take, lpToBurn: 0n, tokenOut: 0n, quoteOut: 0n };
  if (take === 0n) return r;
  const lpToBurn = (take * p.totalLp) / (root + 1n);
  const tokenOut = (lpToBurn * p.reserveToken) / p.totalLp;
  const quoteOut = (lpToBurn * p.reserveQuote) / p.totalLp;
  // Soroswap refuses a withdrawal that pays nothing on one side.
  return tokenOut > 0n && quoteOut > 0n ? { ...r, lpToBurn, tokenOut, quoteOut } : r;
}

/** The position after `r`: the pair paid out both sides of the LP burned. A launch compounds nothing (harvest_bps =
 *  BPS), so its principal stays. */
export function afterRound(p: PoolPosition, r: HarvestRound): PoolPosition {
  return {
    reserveToken: p.reserveToken - r.tokenOut,
    reserveQuote: p.reserveQuote - r.quoteOut,
    totalLp: p.totalLp - r.lpToBurn,
    lp: p.lp - r.lpToBurn,
    principal: p.principal,
  };
}

/** The pool fees a recipient change would hand to the new recipient (V7). */
export interface HarvestBacklog {
  /** The growth not yet harvested at the change, as the quote and the launch token it withdraws now. */
  residualQuote: string;
  residualToken: string;
  /** Harvests it takes with no further volume: one per interval. */
  roundsToDrain: number;
  nextHarvestAt: string;
  /** When the last of them can run. */
  drainedBy: string;
}

/** The backlog of a position whose next harvest can run at `nextAt` (seconds): null when one round takes all of its
 *  growth, so at most one interval of fees crosses the change (§5.5's declared exception). */
export function harvestBacklog(p: PoolPosition, nextAt: number, intervalSecs: number): HarvestBacklog | null {
  const first = harvestRound(p);
  if (first.growth <= first.cap) return null;
  let state = p;
  let rounds = 0;
  for (let r = first; r.lpToBurn > 0n && rounds < MAX_DRAIN_ROUNDS; r = harvestRound(state)) {
    state = afterRound(state, r);
    rounds++;
  }
  const root = isqrt(p.reserveToken * p.reserveQuote);
  const lp = (first.growth * p.totalLp) / (root + 1n);
  return {
    residualQuote: ((lp * p.reserveQuote) / p.totalLp).toString(),
    residualToken: ((lp * p.reserveToken) / p.totalLp).toString(),
    roundsToDrain: rounds,
    nextHarvestAt: isoAt(nextAt)!,
    drainedBy: isoAt(nextAt + Math.max(0, rounds - 1) * intervalSecs)!,
  };
}

/** A graduated launch's locked position, read live: null for a pool the locker doesn't harvest (only Soroswap's on
 *  every deployment today, O7). */
async function lockedPosition(locker: string, pool: string, token: string): Promise<{ position: PoolPosition; nextAt: number } | null> {
  const pos = await view(locker, "position", [sv.addr(pool)]);
  if (!pos || VENUE_KINDS[Number(pos.kind)] !== "Soroswap") return null;
  const [reserves, token0, total] = await Promise.all([view(pool, "get_reserves"), view(pool, "token_0"), view(pool, "total_supply")]);
  const tokenFirst = String(token0) === token;
  const interval = env.network.deploymentV2!.durations.launch.harvest_interval;
  return {
    position: {
      reserveToken: big(reserves[tokenFirst ? 0 : 1]),
      reserveQuote: big(reserves[tokenFirst ? 1 : 0]),
      totalLp: big(total),
      lp: big(pos.lp),
      principal: big(pos.principal),
    },
    nextAt: Number(pos.last_harvest) + interval,
  };
}

// ------------------------------------------------------------------------------------------------ plans

export interface LaunchV2BuildInput {
  action: LaunchV2Action;
  token?: string;
  /** create: "XLM", "USDC" (testnet-qa: "QA") or the asset's contract. */
  quote?: string;
  venue?: number;
  name?: string;
  symbol?: string;
  uri?: string;
  creatorFeeBps?: number;
  /** create: share fees with holders; on unless false (L5, the app's default). */
  holderSharing?: boolean;
  /** create: who receives the creator fees (the creator when absent). */
  recipient?: string;
  /** create: buyers who pay no snipe tax, besides the creator and the recipient (at most 32). */
  exempt?: string[];
  /** create: the initial buy; buy, sell, refund: the amount, in base units. */
  amount?: string;
  minOut?: string;
  /** claim_owed: the asset owed ("XLM", "USDC" or its contract); the launch's quote when absent. */
  asset?: string;
  /** recipient_transfer: the new recipient. */
  to?: string;
}

/** A v2 intent: the review's fields, plus the terms a launch binds and a recipient change's harvest backlog. */
export type LaunchV2Intent = Intent & { terms?: LaunchTermsJson; harvestBacklog?: HarvestBacklog | null };

/** A recipient change's plan (§5.5, F3, V7): on a graduated launch whose locker can harvest now, a harvest step first;
 *  and the backlog that will still cross the change after it (null when one round takes all the growth). */
export async function recipientSteps(
  user: string,
  action: "recipient_transfer" | "recipient_execute",
  token: string,
  to: string | null,
  nowMs: number = Date.now(),
): Promise<{ steps: { label: string; spec: StepSpec }[]; harvestBacklog: HarvestBacklog | null }> {
  const { pad, locker, v2 } = deployed(env.network);
  const launch = await launchOf(pad, token);
  const [curve, current, takeover] = await Promise.all([
    curveOf(pad, token),
    view(pad, "creator_fee_recipient", [sv.addr(token)]),
    view(pad, "pending_recipient_change", [sv.addr(token)]),
  ]);
  const now = nowSecs(nowMs);
  let next: string;
  if (action === "recipient_transfer") {
    if (String(current) !== user) throw bad("bad_arg", "Only the coin's current fee recipient can hand the fees on.");
    next = addressArg(to, "to");
    if (next === user) throw bad("bad_arg", "That address receives the fees already.");
  } else {
    takeoverOpen(takeover, now);
    next = String(takeover.new);
  }
  const kind = LAUNCH_V2_STEPS[action];
  const change = {
    label: action === "recipient_transfer" ? `Hand ${launch.symbol}'s creator fees to ${short(next)}` : `Hand ${launch.symbol}'s creator fees to ${short(next)} (takeover)`,
    spec: { kind, token, ...(action === "recipient_transfer" ? { to: next } : {}) },
  };
  const locked = curve.phase === "graduated" && curve.pool ? await lockedPosition(locker, curve.pool, token) : null;
  if (!locked) return { steps: [change], harvestBacklog: null };
  const interval = v2.durations.launch.harvest_interval;
  const round = harvestRound(locked.position);
  if (now < locked.nextAt || round.lpToBurn === 0n) return { steps: [change], harvestBacklog: harvestBacklog(locked.position, locked.nextAt, interval) };
  return {
    steps: [{ label: `Collect ${launch.symbol}'s pool fees first`, spec: { kind: LAUNCH_V2_STEPS.harvest, token, pool: curve.pool! } }, change],
    harvestBacklog: harvestBacklog(afterRound(locked.position, round), now + interval, interval),
  };
}

/** A pending takeover inside its window, or 409 not_available. */
function takeoverOpen(takeover: any, now: number): void {
  if (!takeover) throw notAvailable("There is no pending fee recipient change for this coin.");
  if (now < Number(takeover.effective_at)) throw notAvailable("This change can be made later.", isoAt(takeover.effective_at));
  if (now > Number(takeover.expires_at)) throw notAvailable("This change's window has closed.");
}

/** A v2 launch action's plan (§20.3), each step built by its builder below. Create takes a name
 *  of at most 32 bytes, a 2–10 character ASCII ticker that doesn't imitate a reserved one, a URI that is empty or
 *  metadata this address wrote, the venue (the quote's default when absent), sharing, a recipient and up to 32
 *  exemptions; the builder picks the nonce. A recipient change answers the harvest backlog it leaves (V7). */
export async function buildLaunchV2(user: string, input: Partial<LaunchV2BuildInput>): Promise<PlanView & { harvestBacklog?: HarvestBacklog | null }> {
  const net = env.network;
  const { pad } = deployed(net);
  const action = input.action;
  if (typeof action !== "string" || !Object.hasOwn(LAUNCH_V2_STEPS, action) || (action as string) === "harvest") throw bad("bad_action", "Unknown action.");
  const kind = `launch_${action}`;
  if (action === "create") {
    const name = launchName(input.name);
    const symbol = launchSymbolV2(input.symbol);
    const { quote, venue, terms } = await launchTermsFor(net, String(input.quote ?? "XLM"), input.venue);
    const fee = Number(input.creatorFeeBps ?? 0);
    if (!Number.isInteger(fee) || fee < 0 || fee > terms.maxCreatorFeeBps) throw bad("bad_fee", `Creator fee: 0–${terms.maxCreatorFeeBps / 100}%.`);
    const uri = typeof input.uri === "string" ? input.uri : "";
    if (uri.length > net.limits.uriMax) throw bad("bad_uri", "Metadata link is too long.");
    await checkLaunchUri(user, uri, name, symbol);
    const recipient = input.recipient === undefined || input.recipient === null || input.recipient === "" ? null : addressArg(input.recipient, "recipient");
    if (input.exempt !== undefined && !Array.isArray(input.exempt)) throw bad("bad_arg", "exempt lists Stellar addresses.");
    const exempt = [...new Set((input.exempt ?? []).map((a) => addressArg(a, "exempt")))];
    if (exempt.length > 32) throw bad("bad_arg", "At most 32 exempt addresses.");
    const spec = {
      kind: LAUNCH_V2_STEPS.create,
      quote: quote.contract,
      venue,
      name,
      symbol,
      uri,
      creatorFeeBps: fee,
      holderSharing: input.holderSharing !== false,
      recipient,
      exempt,
      initialBuy: (input.amount === undefined ? 0n : unitsArg(input.amount, "amount", true)).toString(),
      minOut: (input.minOut === undefined ? 0n : unitsArg(input.minOut, "minOut", true)).toString(),
      nonce: launchNonce().toString(),
    };
    return await createPlan(user, kind, [{ label: `Launch ${symbol} on ${terms.venue.name}`, spec }]);
  }
  if (action === "claim_owed") {
    // Owed fees are per asset, not per launch: a token only names its quote.
    const asset = input.asset !== undefined
      ? quoteAssetOf(net, String(input.asset))?.contract
      : (await launchOf(pad, tokenArg(input.token))).quote;
    if (!asset) throw bad("bad_asset", "Owed fees are in a launch's quote asset.");
    const spec = { kind: LAUNCH_V2_STEPS.claim_owed, asset };
    return await createPlan(user, kind, [{ label: `Claim creator fees owed to you in ${quoteNamed(net, asset).code}`, spec }]);
  }
  const token = tokenArg(input.token);
  if (action === "recipient_transfer" || action === "recipient_execute") {
    const build = async () => {
      const plan = await recipientSteps(user, action, token, input.to ?? null);
      return { ...(await createPlan(user, kind, plan.steps)), harvestBacklog: plan.harvestBacklog };
    };
    try {
      return await build();
    } catch (err) {
      // The keeper harvested between the read and the step's simulation: plan again from what it left.
      const named = (err as ApiError)?.detail as { contractError?: { contract?: string; name?: string } } | undefined;
      if (named?.contractError?.contract === "lp-locker" && ["TooSoon", "NothingToHarvest"].includes(String(named.contractError.name))) return await build();
      throw err;
    }
  }
  const launch = await launchOf(pad, token);
  const spec: StepSpec = { kind: LAUNCH_V2_STEPS[action], token };
  switch (action) {
    case "buy":
    case "sell":
      spec.amount = unitsArg(input.amount, "amount").toString();
      spec.minOut = unitsArg(input.minOut, "minOut").toString();
      return await createPlan(user, kind, [{ label: `${action === "buy" ? "Buy" : "Sell"} ${launch.symbol}`, spec }]);
    case "refund":
      spec.amount = unitsArg(input.amount, "amount").toString();
      return await createPlan(user, kind, [{ label: `Refund ${launch.symbol}`, spec }]);
    default:
      return await createPlan(user, kind, [{ label: actionLabel(action, launch), spec }]);
  }
}

function actionLabel(action: LaunchV2Action, launch: LaunchRecord): string {
  switch (action) {
    case "graduate":
      return `Graduate ${launch.symbol} to ${launch.venue.name}`;
    case "graduate_fallback":
      return `Graduate ${launch.symbol} to ${launch.fallback.name} (fallback)`;
    case "mark_stuck":
      return `Mark ${launch.symbol}'s graduation delayed`;
    case "rescue":
      return `Open refunds for ${launch.symbol}`;
    case "claim":
      return `Pay out ${launch.symbol}'s creator fees`;
    case "claim_rewards":
      return `Claim your ${launch.symbol} holder rewards`;
    case "recipient_cancel":
      return `Veto the change of ${launch.symbol}'s fee recipient`;
    default:
      return launch.symbol;
  }
}

// ------------------------------------------------------------------------------------------------ builders

/** The launch a step acts on, and its quote named. */
async function stepLaunch(spec: StepSpec) {
  const net = env.network;
  const { pad, locker, v2 } = deployed(net);
  const token = tokenArg(spec.token);
  const launch = await launchOf(pad, token);
  return { net, pad, locker, v2, token, launch, quote: quoteNamed(net, launch.quote) };
}

/** launch(user, params, expected): the fee to the launchpad, and the terms by value (§5.5, O6, F18). */
export const launchCreateStepV2: Builder = async (user, spec) => {
  const net = env.network;
  const { pad } = deployed(net);
  const { quote, venue, raw, terms } = await launchTermsFor(net, String(spec.quote), spec.venue);
  const p: LaunchInput = {
    quote: quote.contract,
    name: String(spec.name),
    symbol: String(spec.symbol),
    uri: String(spec.uri ?? ""),
    creatorFeeBps: Number(spec.creatorFeeBps ?? 0),
    venue,
    holderSharing: spec.holderSharing !== false,
    recipient: typeof spec.recipient === "string" ? spec.recipient : null,
    exempt: Array.isArray(spec.exempt) ? spec.exempt.map(String) : [],
    initialBuy: BigInt(String(spec.initialBuy ?? "0")),
    minOut: BigInt(String(spec.minOut ?? "0")),
    nonce: BigInt(String(spec.nonce)),
  };
  const launchFee = BigInt(terms.launchFee);
  const xlmQuote = quote.contract === terms.feeAsset;
  const xlmNeed = xlmQuote ? p.initialBuy : 0n;
  const [acct, balances, token] = await Promise.all([
    requireAccount(user),
    balancesOf(user, quote),
    refusing(() => view(pad, "token_address", [sv.addr(user), sv.u64(p.nonce)])),
  ]);
  if (!balances) throw new ApiError(409, "account_inactive", "Activate your Stellar account first.");
  // Short even before the network fee: say so with the fee's estimate, rather than as a failed simulation.
  const before = launchXlmOf(balances.position, launchFee, 0n);
  if (BigInt(before.spendable) < xlmNeed) assertLaunchXlm(launchXlmOf(balances.position, launchFee, await feeCeiling("launch_create")), xlmNeed);
  const tx = await refusing(() => invoke(acct, pad, "launch", [sv.addr(user), launchParams(p), raw]));
  assertLaunchXlm(launchXlmOf(balances.position, launchFee, BigInt(tx.fee)), xlmNeed);

  const spend: Record<string, string> = {};
  if (launchFee + xlmNeed > 0n) spend[terms.feeAsset] = (launchFee + xlmNeed).toString();
  if (!xlmQuote && p.initialBuy > 0n) spend[quote.contract] = p.initialBuy.toString();
  const d = terms.durations;
  const intent: LaunchV2Intent = {
    kind: "launch_create",
    summary: `Launch ${p.symbol} on ${terms.venue.name} for a ${fromStroops(launchFee)} XLM fee${p.initialBuy > 0n ? ` and buy with ${fromStroops(p.initialBuy)} ${quote.code}` : ""}`,
    spend,
    ...(p.initialBuy > 0n ? { receive: { [String(token)]: p.minOut.toString() } } : {}),
    calls: [{ contract: pad, fn: "launch" }],
    display: {
      generation: 2,
      token: String(token),
      name: p.name,
      symbol: p.symbol,
      quote: quote.code,
      quoteContract: quote.contract,
      initialBuy: p.initialBuy.toString(),
      minOut: p.minOut.toString(),
      launchFee: terms.launchFee,
      launchFeeAsset: "XLM",
      launchFeeTo: pad,
      launchFeeBooked: true,
      venue: terms.venue.name,
      venueId: terms.venue.id,
      venueKind: terms.venue.kind,
      fallbackVenue: terms.fallback.name,
      fallbackVenueId: terms.fallback.id,
      venueLocked: terms.venueLocked,
      holderSharing: p.holderSharing,
      recipient: p.recipient ?? user,
      exemptCount: p.exempt.length,
      creatorFeeBps: p.creatorFeeBps,
      feeBps: terms.feeBps,
      protocolShareBps: terms.protocolShareBps,
      maxCreatorFeeBps: terms.maxCreatorFeeBps,
      supply: terms.supply,
      phantom: terms.phantom,
      threshold: terms.threshold,
      snipeSchedule: terms.snipeSchedule.join(","),
      snipeStepSecs: terms.snipeStepSecs,
      locker: terms.locker,
      tokenWasmHash: terms.tokenWasmHash,
      grace: d.grace,
      fallbackDelay: d.fallbackDelay,
      rescueAdmin: d.rescueAdmin,
      rescuePublic: d.rescuePublic,
      lockedFallback: d.lockedFallback,
      takeoverDelay: d.takeoverDelay,
      takeoverWindow: d.takeoverWindow,
      timelock: d.timelock,
      timelockWindow: d.timelockWindow,
      harvestInterval: d.harvestInterval,
    },
    terms,
  };
  return { tx, intent, stepKind: "launch_create" };
};

/** buy and sell (Curve phase) act for the user and bind the client's minimum through intent.receive. */
function tradeStep(side: "buy" | "sell"): Builder {
  return async (user, spec) => {
    const { pad, token, launch, quote } = await stepLaunch(spec);
    const acct = await requireAccount(user);
    const amount = String(spec.amount);
    const minOut = String(spec.minOut ?? "0");
    const tx = await refusing(() => invoke(acct, pad, side, [sv.addr(user), sv.addr(token), sv.i128(amount), sv.i128(minOut)]));
    const [pay, get] = side === "buy" ? [launch.quote, token] : [token, launch.quote];
    return {
      tx,
      intent: {
        kind: `launch_${side}`,
        summary: side === "buy" ? `Buy ${launch.symbol} with ${fromStroops(amount)} ${quote.code}` : `Sell ${fromStroops(amount)} ${launch.symbol}`,
        spend: { [pay]: amount },
        receive: { [get]: minOut },
        calls: [{ contract: pad, fn: side }],
        display: { generation: 2, token, symbol: launch.symbol, quote: quote.code, amount, minOut },
      },
      stepKind: side === "buy" ? "launch_buy" : "launch_sell",
    };
  };
}

/** refund(user, token, tokens_in) (Rescued): the tokens are burned, for the fixed pro-rata rate (O2). */
export const launchRefundStepV2: Builder = async (user, spec) => {
  const { pad, token, launch, quote } = await stepLaunch(spec);
  const amount = BigInt(String(spec.amount));
  const [acct, q] = await Promise.all([requireAccount(user), quoteTradeV2(user, token, "refund", amount)]);
  const tx = await refusing(() => invoke(acct, pad, "refund", [sv.addr(user), sv.addr(token), sv.i128(amount)]));
  return {
    tx,
    intent: {
      kind: "launch_refund",
      summary: `Refund: ${fromStroops(q.quoteOut!, quote.decimals)} ${quote.code} for ${fromStroops(amount)} ${launch.symbol}, no fees`,
      spend: { [token]: amount.toString() },
      calls: [{ contract: pad, fn: "refund" }],
      display: { generation: 2, token, symbol: launch.symbol, quote: quote.code, amount: amount.toString(), quoteOut: q.quoteOut!, rate: q.rate!, burned: true, fees: "0" },
    },
  };
};

/** graduate, graduate_fallback, mark_stuck and rescue: anyone's to call and pay for, each only when status says it is
 *  open; the label names the launch's own venue. */
function phaseStep(action: "graduate" | "graduate_fallback" | "mark_stuck" | "rescue"): Builder {
  return async (user, spec) => {
    const { pad, token, launch } = await stepLaunch(spec);
    const { status } = await readStatus(pad, token, launch, { probe: false });
    const open = {
      graduate: status.actions.graduate,
      graduate_fallback: status.actions.graduateFallback,
      mark_stuck: status.actions.markStuck,
      rescue: status.actions.rescue,
    }[action];
    if (!open) {
      const at = { graduate: null, graduate_fallback: status.fallbackAt, mark_stuck: status.markStuckAt, rescue: status.rescuePublicAt }[action];
      const what = { graduate: "graduate", graduate_fallback: "use its fallback venue", mark_stuck: "be marked delayed", rescue: "open refunds" }[action];
      throw notAvailable(`${launch.symbol} can't ${what} now.`, at);
    }
    const acct = await requireAccount(user);
    const tx = await refusing(() => invoke(acct, pad, action, [sv.addr(token)]));
    const venue = action === "graduate_fallback" ? launch.fallback : launch.venue;
    const summary = {
      graduate: `Graduate ${launch.symbol} to ${venue.name}`,
      graduate_fallback: `Graduate ${launch.symbol} to ${venue.name}, its fallback venue`,
      mark_stuck: `Mark ${launch.symbol}'s graduation delayed`,
      rescue: `Open refunds for ${launch.symbol}`,
    }[action];
    return {
      tx,
      intent: {
        kind: `launch_${action}`,
        summary,
        spend: {},
        calls: [{ contract: pad, fn: action }],
        display: { generation: 2, token, symbol: launch.symbol, venue: venue.name, venueId: venue.id, venueKind: venue.kind, fallbackAt: status.fallbackAt, rescuePublicAt: status.rescuePublicAt },
      },
      ...(action === "graduate" ? { stepKind: "launch_graduate" as const } : {}),
    };
  };
}

/** claim_creator_fees(token): anyone's to call; the launchpad pays the current recipient. */
export const launchClaimStepV2: Builder = async (user, spec) => {
  const { pad, token, launch, quote } = await stepLaunch(spec);
  const [acct, curve, recipient] = await Promise.all([requireAccount(user), curveOf(pad, token), view(pad, "creator_fee_recipient", [sv.addr(token)])]);
  if (curve.creatorFees <= 0n) throw refusalOf("launchpad-v2", "NothingToClaim");
  const tx = await refusing(() => invoke(acct, pad, "claim_creator_fees", [sv.addr(token)]));
  return {
    tx,
    intent: {
      kind: "launch_claim",
      summary: `Pay ${fromStroops(curve.creatorFees, quote.decimals)} ${quote.code} of ${launch.symbol}'s creator fees to ${short(String(recipient))}`,
      spend: {},
      calls: [{ contract: pad, fn: "claim_creator_fees" }],
      display: { generation: 2, token, symbol: launch.symbol, quote: quote.code, amount: curve.creatorFees.toString(), to: String(recipient) },
    },
    stepKind: "launch_claim",
  };
};

/** claim_owed(user, asset): what recipient changes left the user, paid to the user (L14). */
export const launchClaimOwedStepV2: Builder = async (user, spec) => {
  const net = env.network;
  const { pad } = deployed(net);
  const asset = String(spec.asset);
  const owed = big(await view(pad, "creator_owed", [sv.addr(user), sv.addr(asset)]));
  if (owed <= 0n) throw refusalOf("launchpad-v2", "NothingToClaim");
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, pad, "claim_owed", [sv.addr(user), sv.addr(asset)]));
  const q = quoteNamed(net, asset);
  return {
    tx,
    intent: {
      kind: "launch_claim_owed",
      summary: `Claim ${fromStroops(owed, q.decimals)} ${q.code} of creator fees owed to you`,
      spend: {},
      calls: [{ contract: pad, fn: "claim_owed" }],
      display: { generation: 2, asset: q.code, assetContract: asset, amount: owed.toString(), to: user },
    },
  };
};

/** token.claim(user): the user's holder rewards in both assets (L13, F1). */
export const launchClaimRewardsStepV2: Builder = async (user, spec) => {
  const { token, launch, quote } = await stepLaunch(spec);
  const pending = await view(token, "pending_rewards", [sv.addr(user)]);
  const [inQuote, inToken] = [big(pending[0]), big(pending[1])];
  if (inQuote <= 0n && inToken <= 0n) throw refusalOf("launch-token-v2", "NothingToClaim");
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, token, "claim", [sv.addr(user)]));
  const parts = [inQuote > 0n ? `${fromStroops(inQuote, quote.decimals)} ${quote.code}` : null, inToken > 0n ? `${fromStroops(inToken)} ${launch.symbol}` : null];
  return {
    tx,
    intent: {
      kind: "launch_claim_rewards",
      summary: `Claim ${parts.filter(Boolean).join(" and ")} of ${launch.symbol} holder rewards`,
      spend: {},
      calls: [{ contract: token, fn: "claim" }],
      display: { generation: 2, token, symbol: launch.symbol, quote: quote.code, pendingQuote: inQuote.toString(), pendingToken: inToken.toString() },
    },
  };
};

/** locker.harvest(pool): anyone's to call; the first step of a recipient change when the interval allows (F3). */
export const launchHarvestStepV2: Builder = async (user, spec) => {
  const { locker, token, launch, quote } = await stepLaunch(spec);
  if (typeof spec.pool !== "string" || !isContractId(spec.pool)) throw bad("bad_arg", "pool is required: the graduated launch's pool (C…).");
  const pool = spec.pool;
  const locked = await lockedPosition(locker, pool, token);
  const round = locked ? harvestRound(locked.position) : null;
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, locker, "harvest", [sv.addr(pool)]));
  return {
    tx,
    intent: {
      kind: "launch_harvest",
      summary: `Collect ${launch.symbol}'s pool fees before its fee recipient changes`,
      spend: {},
      calls: [{ contract: locker, fn: "harvest" }],
      display: {
        generation: 2,
        token,
        symbol: launch.symbol,
        quote: quote.code,
        pool,
        estQuote: round ? round.quoteOut.toString() : null,
        estToken: round ? round.tokenOut.toString() : null,
        protocolShareBps: launch.protocolShareBps,
        holderSharing: launch.holderSharing,
      },
    },
  };
};

/** transfer_creator_fee_recipient (by the current recipient) and execute_recipient_change (anyone, inside the
 *  takeover's window): the fees booked so far stay with the current recipient (L14); pool fees not yet harvested go
 *  to the new one, and the intent carries what that is when one round can't take it (V7). */
function recipientChangeStep(action: "recipient_transfer" | "recipient_execute"): Builder {
  return async (user, spec) => {
    const { pad, locker, v2, token, launch, quote } = await stepLaunch(spec);
    const [curve, current, takeover] = await Promise.all([curveOf(pad, token), view(pad, "creator_fee_recipient", [sv.addr(token)]), view(pad, "pending_recipient_change", [sv.addr(token)])]);
    const now = nowSecs(Date.now());
    let next: string;
    if (action === "recipient_transfer") {
      if (String(current) !== user) throw bad("bad_arg", "Only the coin's current fee recipient can hand the fees on.");
      next = addressArg(spec.to, "to");
    } else {
      takeoverOpen(takeover, now);
      next = String(takeover.new);
    }
    const locked = curve.phase === "graduated" && curve.pool ? await lockedPosition(locker, curve.pool, token) : null;
    const backlog = locked ? harvestBacklog(locked.position, Math.max(locked.nextAt, now), v2.durations.launch.harvest_interval) : null;
    const acct = await requireAccount(user);
    const fn = action === "recipient_transfer" ? "transfer_creator_fee_recipient" : "execute_recipient_change";
    const args = action === "recipient_transfer" ? [sv.addr(token), sv.addr(next)] : [sv.addr(token)];
    const tx = await refusing(() => invoke(acct, pad, fn, args));
    const intent: LaunchV2Intent = {
      kind: `launch_${action}`,
      summary: `Hand ${launch.symbol}'s creator fees to ${short(next)}`,
      spend: {},
      to: next,
      calls: [{ contract: pad, fn }],
      display: {
        generation: 2,
        token,
        symbol: launch.symbol,
        quote: quote.code,
        currentRecipient: String(current),
        newRecipient: next,
        byTakeover: action === "recipient_execute",
        bookedStay: curve.creatorFees.toString(),
        graduated: curve.phase === "graduated",
        backlogQuote: backlog?.residualQuote ?? null,
        backlogToken: backlog?.residualToken ?? null,
        backlogRounds: backlog?.roundsToDrain ?? null,
        backlogNextAt: backlog?.nextHarvestAt ?? null,
        backlogDrainedBy: backlog?.drainedBy ?? null,
      },
      harvestBacklog: backlog,
    };
    return { tx, intent };
  };
}

/** cancel_recipient_change(token, user): the current recipient's veto of a takeover (§5.4). */
export const launchRecipientCancelStepV2: Builder = async (user, spec) => {
  const { pad, token, launch } = await stepLaunch(spec);
  const [current, takeover] = await Promise.all([view(pad, "creator_fee_recipient", [sv.addr(token)]), view(pad, "pending_recipient_change", [sv.addr(token)])]);
  if (String(current) !== user) throw bad("bad_arg", "Only the coin's current fee recipient can veto a change.");
  if (!takeover) throw notAvailable("There is no pending fee recipient change for this coin.");
  const acct = await requireAccount(user);
  const tx = await refusing(() => invoke(acct, pad, "cancel_recipient_change", [sv.addr(token), sv.addr(user)]));
  return {
    tx,
    intent: {
      kind: "launch_recipient_cancel",
      summary: `Veto the change of ${launch.symbol}'s fee recipient to ${short(String(takeover.new))}`,
      spend: {},
      calls: [{ contract: pad, fn: "cancel_recipient_change" }],
      display: { generation: 2, token, symbol: launch.symbol, proposed: String(takeover.new), effectiveAt: isoAt(takeover.effective_at), expiresAt: isoAt(takeover.expires_at) },
    },
  };
};

export const launchBuyStepV2 = tradeStep("buy");
export const launchSellStepV2 = tradeStep("sell");
export const launchGraduateStepV2 = phaseStep("graduate");
export const launchGraduateFallbackStepV2 = phaseStep("graduate_fallback");
export const launchMarkStuckStepV2 = phaseStep("mark_stuck");
export const launchRescueStepV2 = phaseStep("rescue");
export const launchRecipientTransferStepV2 = recipientChangeStep("recipient_transfer");
export const launchRecipientExecuteStepV2 = recipientChangeStep("recipient_execute");

/** Every v2 step's builder by its kind, for the API to register (plans.ts registerBuilder). */
export const LAUNCH_V2_BUILDERS: Readonly<Record<string, Builder>> = {
  [LAUNCH_V2_STEPS.create]: launchCreateStepV2,
  [LAUNCH_V2_STEPS.buy]: launchBuyStepV2,
  [LAUNCH_V2_STEPS.sell]: launchSellStepV2,
  [LAUNCH_V2_STEPS.refund]: launchRefundStepV2,
  [LAUNCH_V2_STEPS.graduate]: launchGraduateStepV2,
  [LAUNCH_V2_STEPS.graduate_fallback]: launchGraduateFallbackStepV2,
  [LAUNCH_V2_STEPS.mark_stuck]: launchMarkStuckStepV2,
  [LAUNCH_V2_STEPS.rescue]: launchRescueStepV2,
  [LAUNCH_V2_STEPS.claim]: launchClaimStepV2,
  [LAUNCH_V2_STEPS.claim_owed]: launchClaimOwedStepV2,
  [LAUNCH_V2_STEPS.claim_rewards]: launchClaimRewardsStepV2,
  [LAUNCH_V2_STEPS.harvest]: launchHarvestStepV2,
  [LAUNCH_V2_STEPS.recipient_transfer]: launchRecipientTransferStepV2,
  [LAUNCH_V2_STEPS.recipient_cancel]: launchRecipientCancelStepV2,
  [LAUNCH_V2_STEPS.recipient_execute]: launchRecipientExecuteStepV2,
};

