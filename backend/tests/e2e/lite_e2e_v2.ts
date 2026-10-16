// End-to-end journeys of contracts v2 on testnet-qa (docs/DESIGN-stellar-contracts-v2.md §18.4). It plays the phone
// through the Lite API, as lite_e2e.ts does: the same build → verify → sign → submit → poll loop StellarKit's
// PlanRunner runs, with the deployment's v2 pins and the contracts v2 creates at runtime proven by their WASM hash. Where
// needed it plays the keeper and testnet-qa's roles (admin, guardians, governance, the QA admin and issuer) by direct
// contract calls signed with the QA keys, which it reads from the secrets directory itself and never prints.
//
//   LITE_DEPLOYMENT=testnet-qa LITE_API=http://127.0.0.1:<PORT_BASE>/lite \
//     deno run -A --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e_v2.ts [journeys...]
//   deno test --config backend/supabase/functions/deno.json backend/tests/e2e/lite_e2e_v2.ts      (its unit tests)
//
// CT-20b runs it after the CT-19 gate (decision L16); nothing else does. What it holds to:
// - testnet-qa only. It refuses any LITE_DEPLOYMENT but testnet-qa, an API or a database (LITE_DB_URL, where it writes
//   invites and keeper_skip rows) that isn't a local stack's on this machine, and a stack that serves another deployment
//   than deployments/testnet-qa-v2.json.
// - No contract id or venue id is written here (finding F8): the v2 contracts, the failing stack, the QA asset and the
//   roles come from deployments/testnet-qa-v2.json; the quote assets, the venue table and the treasury from
//   /v1/economics, checked against the file; Soroswap's router, a registry contract, from /v1/config.
// - Hybrid fees: every phone step is the user's to pay (feePayer user, the user the source), its activation's Enable USDC
//   included; Friendbot funds a new account server-side (testnet activates no other way), and a direct call is paid by
//   the key that signs it (the QA deployer pays the keeper's).
// - The keeper is itself "anyone" (finding V5). Before each step the stack's keeper could race, the run inserts a
//   lite.keeper_skip row (honoured on testnet-qa only), and it deletes its rows when it ends: jobs fallback and rescue
//   for both rescue launches, graduate and expire for the Moment that must not be expirable, expire for every Moment
//   the run expires itself, and the job of any other step the run takes itself (fallback, mark_stuck). Where the run
//   waits for the keeper (a graduation, a grad_fail, a harvest, a protocol sweep) and the stack's keeper doesn't come,
//   the run plays it.
// - Funding (finding F10): one fresh Friendbot account per actor; the stuck, fallback, rescue and refund journeys are
//   quoted in XLM, the venue-locked ones in the QA asset its issuer mints. USDC (Circle's, the asset Moments and the
//   USDC quote use) comes once from the app's own route, /v1/swap/quote and /v1/swap/build XLM → USDC, for what the
//   included journeys need, times 1.13 (finding V6: 130 USDC for the full list), after a depth check. When the check
//   fails, the USDC journeys stop with "testnet XLM→USDC liquidity too thin" and the XLM ones run.
// - The Aquarius journey runs only when the deployment file says aquarius.enabled (finding V8; off under O7).
// - For each state only testnet-qa reaches, the API's answer is held to the shape the phone decodes (finding F4;
//   StellarKit's LaunchpadV2.swift and MomentsV2.swift). The failing Moments stack never reaches the API (finding F5):
//   those journeys are direct calls, the chain's views and the indexer's rows, and their states (a recorded or simulated
//   failure, its stuck expiry, the backstop) are held to that shape as the API's own status read makes them, pointed at
//   the failing stack (moments_v2.ts momentStatusV2, the code behind GET /v1/moments/:nft/status).
// - Journeys run side by side, each with its own accounts; a key that several journeys sign with sends one transaction
//   at a time. With the QA durations the full run takes about an hour (the Moment's vesting: 5 periods of 10 minutes).
import { Address, Asset, hash, Keypair, Operation, scValToNative, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { Buffer } from "node:buffer";
import postgres from "postgres";
import { type Chain, invoke, send, testnetChain, type TxOutcome } from "../../scripts/lib/preflight-v2.ts";
import { loadQaKeys, type QaKeyName, redact, secretsDir } from "../../scripts/lib/owner-files.ts";
import { PublishParamsT } from "../../scripts/lib/smoke-v2.ts";
import { ModeT, VenueKindT, VenueParamsT } from "../../scripts/lib/v2-constructors.ts";
import { T, toScVal } from "../../scripts/lib/wasm-spec.ts";
import { hex, SEP53_PREFIX, sha256 } from "../../supabase/functions/_shared/auth.ts";
import { type DeploymentV2, deploymentV2ByName } from "../../supabase/functions/_shared/deployments/index.ts";
import { momentStatusV2 } from "../../supabase/functions/_shared/moments_v2.ts";
import { TESTNET, withDeploymentV2 } from "../../supabase/functions/_shared/networks.ts";
import { type NamedError, V2_ERRORS } from "../../supabase/functions/_shared/v2_errors.ts";
import { type V2Pins, v2Pins, verifyTransaction } from "../../supabase/functions/_shared/verify.ts";

const ONE = 10_000_000n;
const BPS = 10_000n;
const QA = "testnet-qa";
const NOTE = "lite_e2e_v2";

// ------------------------------------------------------------------------------------------------ journeys and USDC

/** Every journey of §18.4, in the order they start. */
export const JOURNEYS = [
  "launch",
  "fallback",
  "mode2",
  "rescueAdmin",
  "rescuePublic",
  "lockedAllow",
  "lockedDelay",
  "aquarius",
  "governance",
  "moment",
  "momentExpiry",
  "failingMode0",
  "failingMode2",
  "notExpirable",
  "backstop",
] as const;
export type Journey = typeof JOURNEYS[number];

const FAILING_MOMENTS = ["failingMode0", "failingMode2", "notExpirable", "backstop"] as const;
/** The journeys that need USDC: the USDC-quote launch, and every Moment (v2 Moments are priced in USDC only). */
export const USDC_JOURNEYS: readonly Journey[] = ["launch", "moment", "momentExpiry", ...FAILING_MOMENTS];

/** What each USDC pool's harvest swaps cost: a buy of this much and a sell of what it bought, whose 0.3% fee each way
 *  and slippage are lost (§18.4: about 3 USDC for the two USDC pools). */
export const HARVEST_SWAP_USDC = 15_000_000n;
/** Every Moment's edition price in this run, so the Collecting-expiry Moment's one partial collect: 1 USDC. */
export const EDITION_PRICE = ONE;
/** The creator fee every launch of the run sets: 1%. */
export const CREATOR_FEE_BPS = 100;
/** The margin on the USDC the run acquires, for price moves and retries (§18.4: about 13%), in percent. */
export const USDC_MARGIN_PCT = 113n;

/** The live terms a journey's USDC need is computed from, in base units (7 decimals). */
export interface UsdcTerms {
  /** The USDC quote's curve threshold (net of fees), and the curve's fee. */
  launchThreshold: bigint;
  launchFeeBps: number;
  /** The creator fee the run's launch sets. */
  creatorFeeBps: number;
  /** The gross that completes a Moment from empty: on the main stack and on the failing stack. */
  momentGross: bigint;
  failingMomentGross: bigint;
  /** The Collecting-expiry Moment's one partial collect. */
  partialCollect: bigint;
}

/** The gross that buys `net` through a curve that takes `totalBps` in fees: ceil(net · BPS / (BPS − totalBps)). */
export function grossForNet(net: bigint, totalBps: number): bigint {
  const d = BPS - BigInt(totalBps);
  return (net * BPS + d - 1n) / d;
}

/** The gross that completes a Moment of threshold `t` whose collects keep `reserveBps` (moments-v2 completion). */
export function completionGross(t: bigint, reserveBps: number): bigint {
  const r = BigInt(reserveBps);
  return (t * BPS + r - 1n) / r;
}

/** Each included journey's USDC (§18.4's table, finding V6): the USDC-quote launch to completion with both fees, plus
 *  its pool's harvest swaps; the main-stack Moment to graduation, plus its pool's swaps; the Collecting-expiry
 *  Moment's partial collect; each failing-stack Moment to completion. */
export function usdcNeeds(journeys: readonly Journey[], t: UsdcTerms): Partial<Record<Journey, bigint>> {
  const needs: Partial<Record<Journey, bigint>> = {};
  if (journeys.includes("launch")) needs.launch = grossForNet(t.launchThreshold, t.launchFeeBps + t.creatorFeeBps) + HARVEST_SWAP_USDC;
  if (journeys.includes("moment")) needs.moment = t.momentGross + HARVEST_SWAP_USDC;
  if (journeys.includes("momentExpiry")) needs.momentExpiry = t.partialCollect;
  for (const j of FAILING_MOMENTS) if (journeys.includes(j)) needs[j] = t.failingMomentGross;
  return needs;
}

/** The USDC the run acquires: what its journeys need, times 1.13, rounded up to a whole USDC; 0 with none. */
export function usdcToAcquire(journeys: readonly Journey[], t: UsdcTerms): bigint {
  const sum = Object.values(usdcNeeds(journeys, t)).reduce((a, b) => a + (b ?? 0n), 0n);
  if (sum === 0n) return 0n;
  const withMargin = (sum * USDC_MARGIN_PCT + 99n) / 100n;
  return ((withMargin + ONE - 1n) / ONE) * ONE;
}

/** The depth check's numbers: the USDC 1 XLM buys, and the XLM that buys `need` at 97% of that rate with what it
 *  quotes. */
export interface Depth {
  ok: boolean;
  rate1: bigint;
  sell: bigint;
  out: bigint;
  reason: string | null;
}

/** The depth check (finding F10): quote 1 XLM, then the XLM that would buy `need` at 97% of that rate. Enough when that
 *  quote returns at least `need`, which is an average rate within 3% of the 1-XLM rate. `quote` answers the USDC a sale
 *  of so many stroops returns (the API's best route). */
export async function checkDepth(quote: (sellStroops: bigint) => Promise<bigint>, need: bigint): Promise<Depth> {
  let rate1 = 0n;
  let sell = 0n;
  let out = 0n;
  try {
    rate1 = await quote(ONE);
    if (rate1 <= 0n) return { ok: false, rate1, sell, out, reason: "1 XLM quotes no USDC" };
    sell = (need * ONE * 100n + rate1 * 97n - 1n) / (rate1 * 97n);
    out = await quote(sell);
  } catch (e) {
    return { ok: false, rate1, sell, out, reason: `the route didn't quote (${(e as Error).message})` };
  }
  const ok = out >= need && out * ONE * 100n >= rate1 * 97n * sell;
  const reason = ok
    ? null
    : `${units(need)} USDC wants ${units(sell)} XLM at 97% of the 1-XLM rate (${units(rate1)} USDC), and that sale quotes ${units(out)} USDC`;
  return { ok, rate1, sell, out, reason };
}

/** The depth check on one venue's route: what it found, and the venue the run then buys on. */
export interface VenueDepth extends Depth {
  venue: string | null;
}

/** The depth check per venue (F10): each venue the 1-XLM quote prices, best rate first, is held to checkDepth against its
 *  own 1-XLM rate and its own quote for the full sale; the first that passes is the venue the run buys on. A thin pool
 *  with the best small-trade rate (testnet's Soroswap XLM/USDC) must not hide a deep route (SDEX), and a deep route
 *  must not pass against another venue's rate. `quotes` answers each venue's USDC for a sale of so many stroops. */
export async function checkDepthByVenue(quotes: (sellStroops: bigint) => Promise<Record<string, bigint>>, need: bigint): Promise<VenueDepth> {
  let first: Record<string, bigint>;
  try {
    first = await quotes(ONE);
  } catch (e) {
    return { ok: false, rate1: 0n, sell: 0n, out: 0n, reason: `the route didn't quote (${(e as Error).message})`, venue: null };
  }
  const venues = Object.entries(first).filter(([, out]) => out > 0n).sort(([, a], [, b]) => (b > a ? 1 : b < a ? -1 : 0)).map(([v]) => v);
  if (venues.length === 0) return { ok: false, rate1: 0n, sell: 0n, out: 0n, reason: "1 XLM quotes no USDC", venue: null };
  const tried: string[] = [];
  let last: VenueDepth | null = null;
  for (const venue of venues) {
    const d = await checkDepth(async (sell) => (sell === ONE ? first[venue] : (await quotes(sell))[venue] ?? 0n), need);
    if (d.ok) return { ...d, venue };
    tried.push(`${venue}: ${d.reason}`);
    last ??= { ...d, venue: null };
  }
  return { ...last!, reason: tried.join("; ") };
}

/** The message a failed depth check stops the USDC journeys with. */
export const THIN = "testnet XLM→USDC liquidity too thin";

/** The journeys a run takes after the depth check: all of them; with a failed check the others only, and why. */
export function afterDepth(journeys: readonly Journey[], depth: Depth): { run: Journey[]; stopped: Journey[]; message: string | null } {
  if (depth.ok) return { run: [...journeys], stopped: [], message: null };
  const stopped = journeys.filter((j) => USDC_JOURNEYS.includes(j));
  return {
    run: journeys.filter((j) => !stopped.includes(j)),
    stopped,
    message: `${THIN} (${depth.reason}): the USDC journeys (${stopped.join(", ")}) stop here and the others run. ` +
      "Topping a USDC account up from Circle's testnet faucet is then a step for a person.",
  };
}

/** The hosts of this machine. */
const LOOPBACK = new Set(["127.0.0.1", "localhost", "[::1]"]);

/** Why the run won't start against this environment, or null: testnet-qa only, through a local stack on this machine,
 *  whose database (LITE_DB_URL when set, else the stack's own) takes the run's invites and keeper_skip rows. LITE_DB_URL
 *  is never printed: it may hold a password. */
export function deploymentRefusal(read: (name: string) => string | undefined): string | null {
  const deployment = read("LITE_DEPLOYMENT");
  if (deployment !== QA) {
    return `lite_e2e_v2 runs on testnet-qa only: LITE_DEPLOYMENT is ${deployment === undefined ? "unset" : `"${deployment}"`}; ` +
      "start the local stack with --deployment testnet-qa and set LITE_DEPLOYMENT=testnet-qa";
  }
  const api = read("LITE_API");
  if (!api) return "set LITE_API to the local stack pointed at testnet-qa: http://127.0.0.1:<PORT_BASE>/lite";
  let host: string;
  try {
    host = new URL(api).hostname;
  } catch {
    return `LITE_API isn't a URL: ${api}`;
  }
  if (!LOOPBACK.has(host)) return `lite_e2e_v2 runs against a local stack only: LITE_API is on ${host}`;
  const db = read("LITE_DB_URL");
  if (db) {
    let dbHost: string;
    try {
      dbHost = new URL(db).hostname;
    } catch {
      return "LITE_DB_URL isn't a URL";
    }
    if (!LOOPBACK.has(dbHost)) {
      return `lite_e2e_v2 writes invites and keeper_skip rows to the local stack's database only: LITE_DB_URL is on ${dbHost || "no host"}`;
    }
  }
  return null;
}

/** Base units (7 decimals) as a decimal string. */
function units(n: bigint): string {
  const neg = n < 0n;
  const a = neg ? -n : n;
  const frac = (a % ONE).toString().padStart(7, "0").replace(/0+$/, "");
  return `${neg ? "-" : ""}${a / ONE}${frac ? `.${frac}` : ""}`;
}

// ------------------------------------------------------------------------------------------------ the run's context

/** The contracts and venues the run uses, read from the deployment file and /v1/economics (finding F8). */
interface Ids {
  launchpad: string;
  locker: string;
  moments: string;
  execSoroswap: string;
  qaExecFail: string;
  momentsFail: string;
  graduatorFail: string;
  xlm: string;
  usdc: string;
  qaSac: string;
  router: string;
  venues: { soroswap: number; qaFail: number; aquarius: number | null };
}

/** The deployment file's roles (testnet-qa's public keys). */
interface Roles {
  admin: string;
  governance: string;
  launchpadGuardian: string;
  momentsGuardian: string;
  treasury: string;
  qaAdmin: string;
  qaIssuer: string;
}

interface Run {
  api: string;
  db: postgres.Sql;
  chain: Chain;
  d: DeploymentV2;
  roles: Roles;
  qa: Record<QaKeyName, Keypair>;
  config: any;
  econ: any;
  ids: Ids;
  pins: V2Pins;
  /** What each USDC journey gets, and the account that hands it out. */
  usdc: { needs: Partial<Record<Journey, bigint>>; bank: Phone | null };
  /** The lite.keeper_skip rows this run inserted. */
  skips: number[];
  fees: { phone: bigint; direct: bigint };
}

/** An account the run holds the key of. */
interface Actor {
  label: string;
  kp: Keypair;
  address: string;
}

/** An account signed in to the API: the phone. */
interface Phone extends Actor {
  token: string;
}

/** The longest the run waits for one thing, in ms. */
const WAIT = {
  poll: 5_000,
  account: 60_000,
  snipe: 240_000,
  keeper: 150_000,
  indexer: 240_000,
  harvest: 300_000,
  rewards: 180_000,
};
/** The ledger's clock trails the wall clock by up to a ledger: a wait for a contract time adds this. */
const LEDGER_SLACK_MS = 7_000;
/** The API allows 20 sign-in requests a minute per IP (routes/auth.ts); a sign-in is two. */
const SIGN_IN_SPACING_MS = 6_500;
/** A budget that completes a 4,324.56-unit curve with its fees; the curve takes only what completes it. */
const CURVE_BUDGET = 5_000n * ONE;
/** The creator's own first buy on an XLM or QA curve (creators pay no snipe tax). */
const CREATOR_BUY = 100n * ONE;
/** A 1×1 PNG, a Moment's media. */
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));

const say = (line: string) => console.log(redact(line));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const nowSecs = () => Math.floor(Date.now() / 1000);
const short = (a: string) => `${a.slice(0, 6)}…`;

const sc = {
  addr: (a: string) => toScVal(T.address, a),
  addrs: (a: string[]) => toScVal(T.vec(T.address), a),
  i128: (n: bigint) => toScVal(T.i128, n),
  u32: (n: number) => toScVal(T.u32, n),
  u64: (n: bigint | number) => toScVal(T.u64, BigInt(n)),
};

/** One transaction at a time per signing key: journeys run side by side, and a source account has one sequence. */
const queues = new Map<string, Promise<unknown>>();
function serial<R>(key: string, f: () => Promise<R>): Promise<R> {
  const next = (queues.get(key) ?? Promise.resolve()).then(f, f);
  queues.set(key, next.catch(() => {}));
  return next;
}

/** Polls `probe` until it answers something other than null, for at most `maxMs`. */
async function until<R>(what: string, maxMs: number, probe: () => Promise<R | null>): Promise<R> {
  const end = Date.now() + maxMs;
  let last = "";
  for (;;) {
    try {
      const r = await probe();
      if (r !== null) return r;
    } catch (e) {
      last = (e as Error).message;
    }
    if (Date.now() >= end) throw new Error(`${what}: still not there after ${Math.round(maxMs / 1000)} s${last ? ` (${last})` : ""}`);
    await sleep(WAIT.poll);
  }
}

/** Waits until a contract time (unix seconds, or ISO) has passed on the ledger. */
async function sleepUntil(at: number | string, what: string): Promise<void> {
  const ms = (typeof at === "number" ? at * 1000 : Date.parse(at)) + LEDGER_SLACK_MS - Date.now();
  if (ms <= 0) return;
  say(`    … ${what}: ${Math.ceil(ms / 1000)} s`);
  await sleep(ms);
}

// ------------------------------------------------------------------------------------------------ the API, as the phone

interface Answer {
  status: number;
  body: any;
}

async function call(r: Run, token: string | null, method: string, path: string, body?: unknown): Promise<Answer> {
  for (let attempt = 0;; attempt++) {
    const res = await fetch(`${r.api}/v1${path}`, {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (res.status === 429 && attempt < 6) {
      await sleep(10_000);
      continue;
    }
    return { status: res.status, body: text ? JSON.parse(text) : null };
  }
}

async function api(r: Run, token: string | null, method: string, path: string, body?: unknown): Promise<any> {
  const a = await call(r, token, method, path, body);
  if (a.status < 200 || a.status > 299) throw new Error(`${method} ${path} → ${a.status} ${JSON.stringify(a.body?.error ?? a.body)}`);
  return a.body;
}

/** The error of a refusal `status` `code`; throws on any other answer. */
function refused(a: Answer, status: number, code: string, what: string): any {
  if (a.status !== status || a.body?.error?.code !== code) throw new Error(`${what}: expected ${status} ${code}, got ${a.status} ${JSON.stringify(a.body)}`);
  say(`    ✓ ${what}: ${status} ${code}`);
  return a.body.error;
}

/** A v2 contract's error by name (v2_errors.ts): nothing here writes a code. */
function named(source: string, name: string): NamedError {
  const e = V2_ERRORS.find((x) => x.source === source && x.name === name);
  if (!e) throw new Error(`internal: v2_errors.ts has no ${source} ${name}`);
  return e;
}

/** A refusal the API names from the contract's error (422 simulation_failed, detail.contractError, V10). */
function refusedNamed(a: Answer, source: string, name: string, what: string): void {
  const e = named(source, name);
  const c = refused(a, 422, "simulation_failed", what).detail?.contractError;
  if (c?.origin !== e.origin || c?.code !== e.code || c?.name !== name || c?.contract !== source) {
    throw new Error(`${what}: named ${JSON.stringify(c)}, expected ${source} ${name} (origin ${e.origin}, code ${e.code})`);
  }
}

const signIns = { last: 0 };

/** A new account as the phone makes one: signed in (an invite written first where the stack needs one), then
 *  activated: Friendbot funds it server-side, and enabling USDC is a plan the user pays, held to hybrid fees like every
 *  other. */
async function phone(r: Run, label: string): Promise<Phone> {
  const kp = Keypair.random();
  await serial("sign-in", async () => {
    const wait = signIns.last + SIGN_IN_SPACING_MS - Date.now();
    if (wait > 0) await sleep(wait);
    signIns.last = Date.now();
  });
  let inviteCode: string | undefined;
  if (r.config.inviteRequired !== false) {
    inviteCode = `E2E-${crypto.randomUUID().slice(0, 8).toUpperCase()}`;
    await r.db`insert into lite.invites (code_hash, label, max_uses) values (${hex(await sha256(inviteCode))}, ${NOTE}, 1)`;
  }
  const ch = await api(r, null, "POST", "/auth/challenge", { address: kp.publicKey() });
  const signature = kp.sign(Buffer.from(await sha256(SEP53_PREFIX + ch.message))).toString("base64");
  const v = await api(r, null, "POST", "/auth/verify", { address: kp.publicKey(), nonce: ch.nonce, signature, ...(inviteCode ? { inviteCode } : {}) });
  const p: Phone = { label, kp, address: kp.publicKey(), token: v.token };
  const act = await api(r, p.token, "POST", "/account/activate");
  if (act.planId) {
    if (act.kind !== "trust") throw new Error(`${label}: activation answered a ${act.kind} plan; testnet-qa activates with Friendbot, leaving the user's Enable USDC`);
    await runPlan(r, p, act);
  }
  say(`  ${label}: ${p.address}`);
  return p;
}

/** Every contract a transaction calls: its invocation and its authorization trees. */
function contractsIn(tx: Transaction): Set<string> {
  const out = new Set<string>();
  const walk = (inv: xdr.SorobanAuthorizedInvocation) => {
    const f = inv.function();
    if (f.switch() === xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn()) {
      out.add(Address.fromScAddress(f.contractFn().contractAddress()).toString());
    }
    inv.subInvocations().forEach(walk);
  };
  for (const op of tx.operations) {
    if (op.type !== "invokeHostFunction") continue;
    if (op.func.switch() === xdr.HostFunctionType.hostFunctionTypeInvokeContract()) {
      out.add(Address.fromScAddress(op.func.invokeContract().contractAddress()).toString());
    }
    for (const a of op.auth ?? []) walk(a.rootInvocation());
  }
  return out;
}

/** The phone's loop as `p`: for each step, build it if needed; hold it to hybrid fees; verify it against the pinned
 *  allowlist and v2's pins, a contract made at runtime counting only by its WASM hash (PlanRunner); sign, submit, and
 *  wait for it to settle. `extra` adds contracts the deployment owns that the app never pins (testnet-qa's QA asset). */
async function runPlan(r: Run, p: Actor & { token: string }, plan: any, extra: string[] = []): Promise<{ status: any; step: any }[]> {
  return await serial(p.address, async () => {
    const outs: { status: any; step: any }[] = [];
    for (let i = 0; i < plan.steps.length; i++) {
      let step = plan.steps[i];
      if (!step.xdr) step = (await api(r, p.token, "POST", `/plans/${plan.planId}/steps/${step.id}/build`)).steps[i];
      if (step.feePayer !== "user") throw new Error(`${step.label}: paid by ${step.feePayer}, not the user (hybrid fees)`);
      const tx = TransactionBuilder.fromXDR(step.xdr, r.config.passphrase) as Transaction;
      if (tx.source !== p.address) throw new Error(`${step.label}: the transaction's source is ${tx.source}, not the user`);
      const allowed = new Set<string>([...Object.values(r.config.allowlist as Record<string, string[]>).flat(), ...extra]);
      const runtime: Record<string, string> = {};
      for (const c of contractsIn(tx)) {
        if (allowed.has(c)) continue;
        const h = await r.chain.contractWasmHash(c);
        if (h) runtime[c] = h;
      }
      verifyTransaction(tx, step.intent, {
        user: p.address,
        sponsor: r.config.sponsor,
        passphrase: r.config.passphrase,
        allowedContracts: allowed,
        v2: r.pins,
        runtimeContracts: runtime,
      });
      tx.sign(p.kp);
      const sent = await api(r, p.token, "POST", "/tx/submit", { planId: plan.planId, stepId: step.id, signedXdr: tx.toEnvelope().toXDR("base64") });
      let status = sent;
      for (let k = 0; k < 60 && status.status === "pending"; k++) {
        await sleep(1_500);
        status = await api(r, p.token, "GET", `/tx/${sent.hash}`);
      }
      if (status.status !== "success") throw new Error(`step ${step.id} (${step.label}) ${status.status} ${status.error ?? ""}`);
      if (status.feePayer !== "user") throw new Error(`${step.label}: settled as paid by ${status.feePayer}`);
      r.fees.phone += BigInt(status.feeCharged ?? "0");
      say(`    ✓ ${p.label}: ${step.label} ${sent.hash}`);
      outs.push({ status, step });
    }
    return outs;
  });
}

// ------------------------------------------------------------------------------------------------ the chain, directly

interface Sent {
  hash: string;
  value: any;
}

function sentOf(r: Run, label: string, o: TxOutcome): Sent {
  r.fees.direct += o.feeCharged;
  say(`    ✓ ${label} ${o.hash}`);
  return { hash: o.hash, value: o.returnValue ? scValToNative(o.returnValue) : null };
}

/** A contract call signed (and paid) by `signer`. */
async function direct(r: Run, label: string, signer: Keypair, contract: string, fn: string, args: xdr.ScVal[]): Promise<Sent> {
  return sentOf(r, label, await serial(signer.publicKey(), () => invoke(r.chain, signer, contract, fn, args)));
}

/** A classic operation signed (and paid) by `signer`. */
async function directOp(r: Run, label: string, signer: Keypair, op: xdr.Operation): Promise<Sent> {
  return sentOf(r, label, await serial(signer.publicKey(), () => send(r.chain, signer, op)));
}

async function view(r: Run, contract: string, fn: string, args: xdr.ScVal[] = []): Promise<any> {
  return scValToNative(await r.chain.view(contract, fn, args));
}

/** Throws unless `attempt` fails with the v2 error `source` `name`: a simulation's error names its code. */
async function refusedBy(what: string, source: string, name: string, attempt: () => Promise<unknown>): Promise<void> {
  const code = named(source, name).code;
  try {
    await attempt();
  } catch (e) {
    const m = String((e as Error).message ?? e);
    if (m.includes(`#${code}`)) {
      say(`    ✓ ${what}: refused, ${source} ${name}`);
      return;
    }
    throw new Error(`${what}: expected ${source} ${name} (#${code}), got: ${m}`);
  }
  throw new Error(`${what}: expected ${source} ${name}, but it went through`);
}

/** A graduation outcome that recorded a failure, held to its namespaced origin and code (V10). */
function expectFailed(outcome: unknown, source: string, name: string, what: string): void {
  const e = named(source, name);
  const o = outcome as [string, { origin: unknown; code: unknown }] | null;
  if (!Array.isArray(o) || o[0] !== "Failed" || Number(o[1]?.origin) !== e.origin || Number(o[1]?.code) !== e.code) {
    throw new Error(`${what}: expected Failed ${source} ${name} (origin ${e.origin}, code ${e.code}), got ${JSON.stringify(outcome)}`);
  }
  say(`    ✓ ${what}: Failed, origin ${e.origin} code ${e.code} (${source} ${name})`);
}

/** The pool of a Graduated outcome. */
function expectGraduated(outcome: unknown, what: string): string {
  const o = outcome as [string, string] | null;
  if (!Array.isArray(o) || o[0] !== "Graduated" || typeof o[1] !== "string") throw new Error(`${what}: expected Graduated, got ${JSON.stringify(outcome)}`);
  return o[1];
}

/** Waits up to WAIT.keeper for the stack's keeper to have done what `done` checks; when it hasn't, the run does it as
 *  the keeper would, and waits again. Answers who did it. */
async function keeperOr<R>(what: string, done: () => Promise<R | null>, act: () => Promise<unknown>, maxMs = WAIT.keeper): Promise<{ value: R; by: "keeper" | "run" }> {
  try {
    return { value: await until(what, maxMs, done), by: "keeper" };
  } catch { /* the stack's keeper didn't: the run plays it */ }
  say(`    · ${what}: not by the stack's keeper within ${maxMs / 1000} s; the run does it`);
  try {
    await act();
  } catch (e) {
    // The keeper may have got there in the meantime.
    const v = await done().catch(() => null);
    if (v === null) throw e;
    return { value: v, by: "keeper" };
  }
  return { value: await until(what, WAIT.indexer, done), by: "run" };
}

/** A lite.keeper_skip row (F5, V5), inserted before the step the keeper could race; the run deletes it at the end. */
async function keeperSkip(r: Run, kind: "launch" | "moment", target: string, jobs: string[], why: string): Promise<void> {
  const [row] = await r.db`
    insert into lite.keeper_skip (kind, target, jobs, note) values (${kind}, ${target}, ${r.db.array(jobs)}, ${`${NOTE}: ${why}`})
    returning id`;
  r.skips.push(Number(row.id));
  say(`    · keeper_skip ${kind} ${short(target)}: ${jobs.join(", ")} (${why})`);
}

/** A key funded by Friendbot for direct calls only (the failing stack's actors, a guardian handoff's new key), with a
 *  USDC trustline when asked. */
async function keyAccount(r: Run, label: string, o: { usdc?: boolean } = {}): Promise<Actor> {
  const kp = Keypair.random();
  await r.chain.friendbot(kp.publicKey());
  await until(`${label}'s account`, WAIT.account, async () => ((await r.chain.account(kp.publicKey())) ? true : null));
  const a: Actor = { label, kp, address: kp.publicKey() };
  if (o.usdc) await directOp(r, `${label} trusts USDC`, kp, Operation.changeTrust({ asset: usdcAsset(r) }));
  say(`  ${label}: ${a.address}`);
  return a;
}

function usdcAsset(r: Run): Asset {
  const usdc = (r.config.assets as any[]).find((a) => a.id === "USDC");
  const [code, issuer] = String(usdc.classic).split(":");
  return new Asset(code, issuer);
}

async function balance(r: Run, sac: string, who: string): Promise<bigint> {
  return BigInt(await view(r, sac, "balance", [sc.addr(who)]));
}

/** USDC from the run's bank, sent the way the phone sends (POST /v1/send). */
async function usdcTo(r: Run, to: Actor, amount: bigint): Promise<void> {
  const bank = r.usdc.bank;
  if (!bank) throw new Error("internal: no USDC was acquired for a USDC journey");
  const plan = await api(r, bank.token, "POST", "/send", { asset: "USDC", to: to.address, amount: amount.toString() });
  await runPlan(r, bank, plan);
}

/** testnet-qa's QA asset for `to`: its trustline, then a payment from the QA issuer. */
async function qaTo(r: Run, to: Actor, amount: bigint): Promise<void> {
  const asset = new Asset(r.d.qaAsset!.code, r.d.qaAsset!.issuer);
  await directOp(r, `${to.label} trusts ${asset.code}`, to.kp, Operation.changeTrust({ asset }));
  await directOp(r, `QA issuer pays ${to.label} ${units(amount)} ${asset.code}`, r.qa.QA_ISSUER_SECRET, Operation.payment({ destination: to.address, asset, amount: units(amount) }));
}

/** qa-exec-fail's mode for a launch token or a Moment's coin (the QA admin's), read back. */
async function setMode(r: Run, target: string, mode: "Fail" | "ExhaustBudget" | "BogusSuccess"): Promise<void> {
  await direct(r, `QA admin: qa-exec-fail mode ${mode} for ${short(target)}`, r.qa.QA_ADMIN_SECRET, r.ids.qaExecFail, "set_mode", [sc.addr(target), toScVal(ModeT, mode)]);
  const got = await view(r, r.ids.qaExecFail, "mode", [sc.addr(target)]);
  const want = { Fail: 0, ExhaustBudget: 1, BogusSuccess: 2 }[mode];
  if (Number(got) !== want) throw new Error(`qa-exec-fail's mode for ${target} is ${got}, not ${want}`);
}

/** A swap on Soroswap's router, exact in, 3% below its quote. Answers what came out. */
async function swapped(r: Run, who: Actor, amountIn: bigint, path: string[]): Promise<bigint> {
  const quoted = (await view(r, r.ids.router, "router_get_amounts_out", [sc.i128(amountIn), sc.addrs(path)])) as bigint[];
  const out = BigInt(quoted[quoted.length - 1]);
  const s = await direct(r, `${who.label}: swap ${units(amountIn)} on the pool`, who.kp, r.ids.router, "swap_exact_tokens_for_tokens", [
    sc.i128(amountIn),
    sc.i128((out * 97n) / 100n),
    sc.addrs(path),
    sc.addr(who.address),
    sc.u64(nowSecs() + 900),
  ]);
  const got = s.value as bigint[];
  return BigInt(got[got.length - 1]);
}

/** A round trip on a pool, for fee growth before a harvest: `quote` in, then the tokens it bought back. */
async function roundTrip(r: Run, who: Actor, quote: string, token: string, amount: bigint): Promise<void> {
  const bought = await swapped(r, who, amount, [quote, token]);
  await swapped(r, who, bought, [token, quote]);
}

/** The locker's last harvest of `pool` (unix s). */
async function lastHarvest(r: Run, pool: string): Promise<number> {
  const p = await view(r, r.ids.locker, "position", [sc.addr(pool)]);
  if (!p) throw new Error(`the locker holds no position for ${pool}`);
  return Number(p.last_harvest);
}

/** A harvest of `pool` after the one at `since` (the locker's last_harvest before the run's swaps, so it takes their
 *  fee growth): the stack's keeper harvests a position with growth once per interval; when it doesn't, the run does
 *  once the locker allows it. */
async function harvested(r: Run, pool: string, since: number): Promise<"keeper" | "run"> {
  const last = async () => {
    const at = await lastHarvest(r, pool);
    return at > since ? at : null;
  };
  const { by } = await keeperOr(`a harvest of ${short(pool)}`, last, async () => {
    await until("the harvest interval", WAIT.harvest, async () => {
      await r.chain.view(r.ids.locker, "harvest", [sc.addr(pool)]);
      return true;
    });
    await direct(r, "keeper: harvest", r.qa.DEPLOYER_SECRET, r.ids.locker, "harvest", [sc.addr(pool)]);
  }, WAIT.harvest);
  return by;
}

// ------------------------------------------------------------------------------------------------ shapes (F4)

type Kind = "string" | "number" | "boolean" | "object" | "array";
/** Each field and its JSON type; "?" lets it be null. */
type Shape = Record<string, `${Kind}` | `${Kind}?`>;

const SHAPES = {
  venue: { id: "number", kind: "string", name: "string", executor: "string", enabled: "boolean", feeFraction: "number" },
  launchStatus: {
    token: "string",
    phase: "string",
    completedAt: "string?",
    stuck: "boolean",
    stuckSince: "string?",
    markStuckAt: "string?",
    fallbackAt: "string?",
    rescueAdminAt: "string?",
    rescuePublicAt: "string?",
    venue: "object",
    fallback: "object",
    venueLocked: "boolean",
    fallbackAllowed: "boolean",
    pool: "string?",
    graduatedVenue: "object?",
    refund: "object?",
    failure: "object?",
    actions: "object",
  },
  actions: { buy: "boolean", sell: "boolean", graduate: "boolean", graduateFallback: "boolean", markStuck: "boolean", rescue: "boolean", refund: "boolean" },
  failure: { origin: "number", code: "number", name: "string?", contract: "string?", source: "string" },
  refund: { quote: "string", supply: "string", refunded: "string", rate: "string" },
  launchState: { status: "object", quote: "object", recipient: "string", pendingTakeover: "object?", creatorFees: "string", rewards: "object", you: "object?" },
  quote: { id: "string", code: "string", contract: "string" },
  takeover: { new: "string", effectiveAt: "string", expiresAt: "string", state: "string" },
  rewards: {
    sharing: "boolean",
    eligible: "string?",
    queuedQuote: "string",
    queuedToken: "string",
    releasableFromLedger: "number?",
    pendingQuote: "string?",
    pendingToken: "string?",
  },
  you: { isRecipient: "boolean", creatorOwed: "string" },
  tradeQuote: { side: "string", fees: "string" },
  momentStatus: {
    generation: "number",
    nft: "string",
    creator: "string",
    coin: "string",
    pool: "string?",
    state: "string",
    price: "string",
    threshold: "string",
    reserve: "string",
    totalGross: "string",
    progress: "number",
    collects: "number",
    editions: "number",
    entitlements: "string",
    creatorAllocBps: "number",
    creatorBps: "number",
    platformBps: "number",
    reserveBps: "number",
    expiryCreatorBps: "number",
    royaltyBps: "number",
    rate: "object",
    publishedAt: "string",
    deadline: "string",
    completedAt: "string?",
    stuckSince: "string?",
    graduatedAt: "string?",
    endedAt: "string?",
    expiresAt: "string?",
    expiresBy: "string?",
    backstopAt: "string?",
    failureExpiresAt: "string?",
    expirable: "boolean",
    graduatable: "boolean",
    failure: "object?",
    proceeds: "object",
  },
  proceeds: { creator: "string", platform: "string", treasury: "string" },
  vesting: {
    generation: "number",
    nft: "string",
    account: "string",
    coin: "string",
    state: "string",
    vests: "boolean",
    vestPeriodSecs: "number",
    startsAt: "string?",
    periodsElapsed: "number?",
    claimable: "object",
    collector: "object?",
    creator: "object?",
  },
  vestingSide: { total: "string", claimed: "string", claimable: "string", vested: "string", tranches: "array", nextAt: "string?", fullAt: "string?" },
  economicsLaunchpad: {
    contract: "string",
    generation: "number",
    launchesEnabled: "boolean",
    whitelistEnabled: "boolean",
    supply: "string",
    feeBps: "number",
    protocolShareBps: "number",
    maxCreatorFeeBps: "number",
    snipeSchedule: "array",
    snipeStepSecs: "number",
    launchFee: "object",
    treasury: "string",
    locker: "string",
    venues: "array",
    quotes: "array",
    durations: "object",
    harvest: "object",
    exclusionFloor: "object",
    aquariusFloat: "object?",
  },
  economicsQuote: {
    asset: "string",
    code: "string",
    contract: "string",
    phantom: "string",
    threshold: "string",
    enabled: "boolean",
    venuesAllowed: "array",
    fallbackVenue: "number",
    venueLocked: "boolean",
    defaultVenue: "number?",
    terms: "object?",
  },
  economicsMoments: {
    generation: "number",
    contract: "string",
    quote: "object",
    supply: "string",
    maxPerCollect: "number",
    maxClaimIds: "number",
    policy: "object",
    pendingPolicy: "object?",
    terms: "object",
    publishingPaused: "boolean",
    guardianPaused: "boolean",
    completionGross: "string",
    maxPrice: "string",
    fdvAtOpen: "string",
    fdvAtOpenUsd: "number?",
    fdvByAllocation: "array",
    // v1's names for the same terms (StellarEconomics.Moments), which the app's v1 model still decodes.
    platformBps: "number",
    royaltyBps: "number",
    publishingEnabled: "boolean",
    treasury: "string",
    maxEditions: "number",
    quotes: "array",
  },
  economicsMomentsQuoteV1: { asset: "string", minPrice: "string", enabled: "boolean" },
} satisfies Record<string, Shape>;

/** Throws unless every field of `shape` is in `v` with its JSON type (F4: what the phone's model decodes). */
function shaped(what: string, v: any, shape: Shape): void {
  if (v === null || typeof v !== "object" || Array.isArray(v)) throw new Error(`${what}: not an object: ${JSON.stringify(v)}`);
  for (const [key, spec] of Object.entries(shape)) {
    const optional = spec.endsWith("?");
    const kind = spec.replace("?", "") as Kind;
    const got = v[key];
    if (got === null || got === undefined) {
      if (optional && got === null) continue;
      throw new Error(`${what}.${key}: ${got === undefined ? "missing" : "null"} (${spec})`);
    }
    const actual = Array.isArray(got) ? "array" : typeof got;
    if (actual !== kind) throw new Error(`${what}.${key}: ${actual}, expected ${spec}`);
  }
}

function launchStateShaped(what: string, s: any): void {
  shaped(what, s, SHAPES.launchState);
  shaped(`${what}.status`, s.status, SHAPES.launchStatus);
  shaped(`${what}.status.venue`, s.status.venue, SHAPES.venue);
  shaped(`${what}.status.fallback`, s.status.fallback, SHAPES.venue);
  shaped(`${what}.status.actions`, s.status.actions, SHAPES.actions);
  if (s.status.graduatedVenue) shaped(`${what}.status.graduatedVenue`, s.status.graduatedVenue, SHAPES.venue);
  if (s.status.failure) shaped(`${what}.status.failure`, s.status.failure, SHAPES.failure);
  if (s.status.refund) shaped(`${what}.status.refund`, s.status.refund, SHAPES.refund);
  shaped(`${what}.quote`, s.quote, SHAPES.quote);
  if (s.pendingTakeover) shaped(`${what}.pendingTakeover`, s.pendingTakeover, SHAPES.takeover);
  shaped(`${what}.rewards`, s.rewards, SHAPES.rewards);
  if (s.you) shaped(`${what}.you`, s.you, SHAPES.you);
}

function momentStatusShaped(what: string, s: any): void {
  shaped(what, s, SHAPES.momentStatus);
  shaped(`${what}.proceeds`, s.proceeds, SHAPES.proceeds);
  if (s.failure) shaped(`${what}.failure`, s.failure, { origin: "number", code: "number", name: "string?", source: "string?", seen: "string" });
}

function vestingShaped(what: string, v: any): void {
  shaped(what, v, SHAPES.vesting);
  if (v.collector) shaped(`${what}.collector`, v.collector, SHAPES.vestingSide);
  if (v.creator) shaped(`${what}.creator`, v.creator, SHAPES.vestingSide);
}

// ------------------------------------------------------------------------------------------------ launches

interface LaunchSpec {
  journey: Journey;
  quote: "XLM" | "USDC" | "QA";
  venue: number;
  sharing: boolean;
  /** qa-exec-fail's mode for the token, set before the curve completes. */
  mode?: "Fail" | "ExhaustBudget" | "BogusSuccess";
  /** keeper_skip jobs, inserted before the curve completes. */
  skip?: string[];
  creatorBuy: bigint;
  buyBudget: bigint;
  /** Contracts the deployment owns that the app never pins (the QA asset's). */
  extra?: string[];
}

interface Launched {
  token: string;
  symbol: string;
  creator: Phone;
  buyer: Phone;
  quote: string;
  extra: string[];
}

/** A ticker the contracts take: 2–10 ASCII letters or digits. */
function ticker(prefix: string): string {
  return `${prefix}${crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000}`.slice(0, 10);
}

function quoteOf(r: Run, asset: "XLM" | "USDC" | "QA"): any {
  const q = (r.econ.launchpad.quotes as any[]).find((x) => x.asset === asset);
  if (!q) throw new Error(`/v1/economics has no ${asset} quote`);
  return q;
}

async function launchState(r: Run, token: string, viewer: Phone | null, what = "the launch's state"): Promise<any> {
  const s = await api(r, viewer?.token ?? null, "GET", `/launches/${token}/state`);
  launchStateShaped(what, s);
  return s;
}

/** Create, as the phone: the preview's 10 XLM fee to the launchpad (O6), the plan's terms, the XLM the creator paid. */
async function created(r: Run, creator: Phone, s: LaunchSpec): Promise<{ token: string; symbol: string }> {
  const symbol = ticker("E2E");
  const body = { action: "create", quote: s.quote, venue: s.venue, name: `E2E v2 ${s.journey}`, symbol, creatorFeeBps: CREATOR_FEE_BPS, holderSharing: s.sharing };
  const fee = r.econ.launchpad.launchFee;
  if (BigInt(fee.amount) !== 10n * ONE || fee.asset !== "XLM" || fee.booked !== true) throw new Error(`the launch fee is ${JSON.stringify(fee)}, not 10 XLM booked (O6)`);
  const preview = await api(r, creator.token, "POST", "/launches/preview", body);
  if (preview.launchFee.amount !== fee.amount || preview.launchFee.to !== r.ids.launchpad || preview.venue.id !== s.venue || preview.shortfall !== null) {
    throw new Error(`the preview: fee ${JSON.stringify(preview.launchFee)}, venue ${preview.venue?.id}, shortfall ${preview.shortfall}`);
  }
  const before = await balance(r, r.ids.xlm, creator.address);
  const plan = await api(r, creator.token, "POST", "/launches/build", body);
  const [{ status, step }] = await runPlan(r, creator, plan, s.extra);
  const d = step.intent.display;
  const token = String(status.returnValue ?? d.token);
  if (token !== d.token || d.launchFee !== fee.amount || d.launchFeeTo !== r.ids.launchpad || d.venueId !== s.venue || d.holderSharing !== s.sharing) {
    throw new Error(`the create step: ${JSON.stringify(d)}, returned ${token}`);
  }
  const paid = before - (await balance(r, r.ids.xlm, creator.address));
  if (paid !== BigInt(fee.amount) + BigInt(status.feeCharged)) throw new Error(`the creator paid ${units(paid)} XLM, not the 10 XLM fee and the network fee`);
  say(`    ✓ ${s.journey}: launched ${symbol} ${token} for the 10 XLM fee, to the launchpad`);
  return { token, symbol };
}

/** A buy as the phone, at 1% under a fresh quote; after the snipe window when asked (quote_buy's snipe fee is down to
 *  rounding: 1 bp of what the buy spends). Answers the quote it was bought at. */
async function bought(r: Run, p: Phone, token: string, amount: bigint, o: { afterSnipe: boolean; extra?: string[] }): Promise<any> {
  const quote = () => api(r, p.token, "POST", `/launches/${token}/quote`, { side: "buy", amount: amount.toString() });
  const q = o.afterSnipe
    ? await until("the snipe window", WAIT.snipe, async () => {
      const q = await quote();
      return BigInt(q.snipeFee ?? "0") * BPS <= BigInt(q.used) ? q : null;
    })
    : await quote();
  const minOut = (BigInt(q.tokensOut) * 99n) / 100n;
  const plan = await api(r, p.token, "POST", "/launches/build", { action: "buy", token, amount: amount.toString(), minOut: minOut.toString() });
  await runPlan(r, p, plan, o.extra);
  return q;
}

/** A launch from create to a completed curve: the creator's own buy (no snipe tax for the creator), the mode and the
 *  keeper_skip rows before the curve completes, then the buyer's buy that completes it after the snipe window. */
async function launchedAndCompleted(r: Run, s: LaunchSpec, creator: Phone, buyer: Phone): Promise<Launched> {
  const extra = s.extra ?? [];
  const { token, symbol } = await created(r, creator, s);
  if (s.mode) await setMode(r, token, s.mode);
  const own = await bought(r, creator, token, s.creatorBuy, { afterSnipe: false, extra });
  if (BigInt(own.snipeFee ?? "0") !== 0n) throw new Error(`the creator's buy paid a snipe tax of ${own.snipeFee}`);
  if (s.skip) await keeperSkip(r, "launch", token, s.skip, `${s.journey}: before the curve completes`);
  await bought(r, buyer, token, s.buyBudget, { afterSnipe: true, extra });
  const st = await launchState(r, token, buyer);
  if (st.status.phase === "curve") throw new Error(`${s.journey}: the buy didn't complete the curve`);
  return { token, symbol, creator, buyer, quote: quoteOf(r, s.quote).contract, extra };
}

/** A phase action as the phone (graduate, graduate_fallback, mark_stuck, rescue): its return value. */
async function phased(r: Run, p: Phone, l: Launched, action: string): Promise<unknown> {
  const plan = await api(r, p.token, "POST", "/launches/build", { action, token: l.token });
  const [{ status }] = await runPlan(r, p, plan, l.extra);
  return status.returnValue;
}

/** A phase action refused before it opens: 409 not_available, with when it opens. */
async function phaseRefused(r: Run, p: Phone, l: Launched, action: string, availableAt: string | null, what: string): Promise<void> {
  const e = refused(await call(r, p.token, "POST", "/launches/build", { action, token: l.token }), 409, "not_available", what);
  if (availableAt !== null && e.detail?.availableAt !== availableAt) throw new Error(`${what}: opens at ${e.detail?.availableAt}, the state says ${availableAt}`);
}

/** The launch's recorded graduation failure (V10): the indexer's grad_fail, named in the state the phone reads and
 *  in the launch's row. */
async function recordedLaunchFailure(r: Run, l: Launched, source: string, name: string): Promise<any> {
  const e = named(source, name);
  const st = await until(`the indexer's grad_fail for ${l.symbol}`, WAIT.indexer, async () => {
    const s = await launchState(r, l.token, l.buyer, "a stuck launch's state");
    return s.status.failure?.source === "recorded" ? s : null;
  });
  const f = st.status.failure;
  if (f.origin !== e.origin || f.code !== e.code || f.name !== name || f.contract !== source) throw new Error(`${l.symbol}'s failure: ${JSON.stringify(f)}, expected ${source} ${name}`);
  const [row] = await r.db`select fail_origin, fail_code, fail_name from lite.launches where token = ${l.token}`;
  if (Number(row?.fail_origin) !== e.origin || Number(row?.fail_code) !== e.code || row?.fail_name !== name) throw new Error(`${l.symbol}'s row: ${JSON.stringify(row)}`);
  say(`    ✓ ${l.symbol}: grad_fail recorded as origin ${e.origin} code ${e.code} (${source} ${name})`);
  return st;
}

/** Refunds of a rescued launch, pro rata (O2): each holder's quote is floor(tokens · refund_quote / refund_supply), the
 *  quote route says so with no fees, and the refund pays it. */
async function refunded(r: Run, l: Launched, holders: Phone[]): Promise<string> {
  const st = await launchState(r, l.token, l.buyer, "a rescued launch's state");
  if (st.status.phase !== "rescued" || !st.status.refund || !st.status.actions.refund) throw new Error(`${l.symbol} isn't in refund mode: ${JSON.stringify(st.status)}`);
  const quote = BigInt(st.status.refund.quote);
  const supply = BigInt(st.status.refund.supply);
  const paid: string[] = [];
  for (const h of holders) {
    const tokens = await balance(r, l.token, h.address);
    const want = (tokens * quote) / supply;
    const q = await api(r, h.token, "POST", `/launches/${l.token}/quote`, { side: "refund", amount: tokens.toString() });
    shaped("a refund quote", q, SHAPES.tradeQuote);
    if (q.side !== "refund" || BigInt(q.quoteOut) !== want || BigInt(q.fees) !== 0n || typeof q.rate !== "string") throw new Error(`the refund quote: ${JSON.stringify(q)}, expected ${want}`);
    const plan = await api(r, h.token, "POST", "/launches/build", { action: "refund", token: l.token, amount: tokens.toString() });
    const [{ status }] = await runPlan(r, h, plan, l.extra);
    if (BigInt(status.returnValue) !== want) throw new Error(`${h.label}'s refund paid ${status.returnValue}, pro rata is ${want}`);
    if ((await balance(r, l.token, h.address)) !== 0n) throw new Error(`${h.label} still holds ${l.symbol} after refunding all of it`);
    paid.push(`${h.label} ${units(want)} for ${units(tokens)}`);
  }
  return paid.join(", ");
}

/** The protocol's booked fees of a launch swept to the treasury (F9): by the stack's keeper, or by the run as it.
 *  The launch's row then books none, and a sweep the run sends pays the treasury in the quote. */
async function protocolSwept(r: Run, l: Launched): Promise<string> {
  const due = async () => {
    const [row] = await r.db`select protocol_fees_due, launch_fee_due from lite.launches where token = ${l.token}`;
    return row && BigInt(row.protocol_fees_due) === 0n && BigInt(row.launch_fee_due) === 0n ? row : null;
  };
  let paid: [string, bigint][] = [];
  const { by } = await keeperOr(`the protocol sweep of ${l.symbol}`, due, async () => {
    const s = await direct(r, `keeper: claim_protocol_fees ${l.symbol}`, r.qa.DEPLOYER_SECRET, r.ids.launchpad, "claim_protocol_fees", [sc.addrs([l.token])]);
    paid = (s.value as [string, bigint][]).map(([a, n]) => [String(a), BigInt(n)]);
  });
  if (by === "run" && paid.length > 0 && !paid.some(([a, n]) => a === l.quote && n > 0n)) throw new Error(`the sweep paid the treasury nothing in the quote: ${JSON.stringify(paid.map(([a, n]) => [a, String(n)]))}`);
  return `swept to the treasury by the ${by}`;
}

/** A launch's graduation on its own venue: by the stack's keeper, or by the phone (anyone may). */
async function graduated(r: Run, l: Launched, by: Phone): Promise<{ pool: string; who: string }> {
  const { value, by: who } = await keeperOr(`${l.symbol}'s graduation`, async () => {
    const s = await launchState(r, l.token, by);
    return s.status.phase === "graduated" ? s : null;
  }, async () => expectGraduated(await phased(r, by, l, "graduate"), `${l.symbol}'s graduation`));
  if (!value.status.pool || value.status.graduatedVenue?.id !== value.status.venue.id) throw new Error(`${l.symbol} graduated: ${JSON.stringify(value.status)}`);
  return { pool: value.status.pool, who };
}

// ------------------------------------------------------------------------------------------------ the launch journeys

/** The USDC-quote launch: the 10 XLM fee, buys with holder sharing on, completion, the keeper's graduation on Soroswap,
 *  swaps, a harvest, holder rewards in the quote and the launch token, the creator's fees, the protocol sweep, and the
 *  treasury's holder rewards at 0 (V2). */
async function journeyLaunch(r: Run): Promise<string> {
  const creator = await phone(r, "launch creator");
  const buyer = await phone(r, "launch buyer");
  const q = quoteOf(r, "USDC");
  if (q.defaultVenue !== r.ids.venues.soroswap || q.venueLocked) throw new Error(`the USDC quote: ${JSON.stringify(q)}`);
  await usdcTo(r, creator, ONE);
  await usdcTo(r, buyer, r.usdc.needs.launch! - ONE);
  const l = await launchedAndCompleted(r, {
    journey: "launch",
    quote: "USDC",
    venue: q.defaultVenue,
    sharing: true,
    creatorBuy: ONE,
    buyBudget: await balance(r, r.ids.usdc, buyer.address),
  }, creator, buyer);
  const g = await graduated(r, l, buyer);
  const st = await launchState(r, l.token, buyer, "a graduated launch's state");
  if (st.status.graduatedVenue.kind !== "Soroswap" || !st.rewards.sharing) throw new Error(`graduated: ${JSON.stringify(st.status.graduatedVenue)}, sharing ${st.rewards.sharing}`);

  const since = await lastHarvest(r, g.pool);
  const left = await balance(r, r.ids.usdc, buyer.address);
  await roundTrip(r, buyer, r.ids.usdc, l.token, left < HARVEST_SWAP_USDC ? left : HARVEST_SWAP_USDC);
  const harvest = await harvested(r, g.pool, since);

  // Holder rewards in both assets (F1), released from the ledger after the harvest notified them.
  const rewarded = await until("the harvest's holder rewards", WAIT.rewards, async () => {
    const s = await launchState(r, l.token, buyer, "a sharing launch's state");
    return BigInt(s.rewards.pendingQuote ?? "0") > 0n && BigInt(s.rewards.pendingToken ?? "0") > 0n ? s : null;
  });
  const plan = await api(r, buyer.token, "POST", "/launches/build", { action: "claim_rewards", token: l.token });
  const [{ status }] = await runPlan(r, buyer, plan);
  const [inQuote, inToken] = (status.returnValue as string[]).map(BigInt);
  if (inQuote <= 0n || inToken <= 0n) throw new Error(`the holder's claim paid ${inQuote} USDC and ${inToken} tokens`);

  // The treasury holds the launch tokens it is paid and earns no holder rewards (V2).
  const treasury = r.econ.launchpad.treasury;
  const [tq, tt] = (await view(r, l.token, "pending_rewards", [sc.addr(treasury)])) as bigint[];
  if (BigInt(tq) !== 0n || BigInt(tt) !== 0n || (await view(r, l.token, "is_excluded", [sc.addr(treasury)])) !== true) {
    throw new Error(`the treasury's holder rewards: ${tq} and ${tt}; it must be excluded and earn none`);
  }
  if ((await balance(r, l.token, treasury)) <= 0n) throw new Error("the treasury holds none of the launch tokens its harvest share paid it");

  // The creator's curve fees, paid out by anyone to the current recipient.
  const fees = BigInt(rewarded.creatorFees);
  if (fees <= 0n) throw new Error("no creator fees are booked");
  const [{ status: claim }] = await runPlan(r, creator, await api(r, creator.token, "POST", "/launches/build", { action: "claim", token: l.token }));
  if (BigInt(claim.returnValue) !== fees) throw new Error(`the creator's claim paid ${claim.returnValue}, not the ${units(fees)} USDC booked`);
  const swept = await protocolSwept(r, l);
  return `${l.symbol}: graduated on Soroswap by the ${g.who}; harvest by the ${harvest}; holder claimed ${units(inQuote)} USDC and ${units(inToken)} ${l.symbol}; ` +
    `creator claimed ${units(fees)} USDC; the treasury earns no rewards; ${swept}`;
}

/** The failing venue (mode 0) → stuck → graduate_fallback refused before fallback_delay → the fallback; then, with
 *  holder sharing off, the creator paid both sides of a harvest, a takeover vetoed and then executed, the old
 *  recipient's owed fees, and a recipient change with its harvest step and backlog (F3, V7). */
async function journeyFallback(r: Run): Promise<string> {
  const creator = await phone(r, "fallback creator");
  const buyer = await phone(r, "fallback buyer");
  const next = await phone(r, "fallback new recipient");
  const l = await launchedAndCompleted(r, {
    journey: "fallback",
    quote: "XLM",
    venue: r.ids.venues.qaFail,
    sharing: false,
    mode: "Fail",
    skip: ["fallback"],
    creatorBuy: CREATOR_BUY,
    buyBudget: CURVE_BUDGET,
  }, creator, buyer);
  expectFailed(await phased(r, buyer, l, "graduate"), "qa-exec-fail", "ForcedFailure", "graduate on the failing venue");
  const early = await launchState(r, l.token, buyer, "a stuck launch's state");
  if (!early.status.stuck || !early.status.fallbackAt) throw new Error(`not stuck after the failure: ${JSON.stringify(early.status)}`);
  await phaseRefused(r, buyer, l, "graduate_fallback", early.status.fallbackAt, "graduate_fallback before fallback_delay");
  await refusedBy("graduate_fallback before fallback_delay", "launchpad-v2", "FallbackTooEarly", () => r.chain.view(r.ids.launchpad, "graduate_fallback", [sc.addr(l.token)]));
  await recordedLaunchFailure(r, l, "qa-exec-fail", "ForcedFailure");
  await sleepUntil(early.status.fallbackAt, "the fallback opens");
  const pool = expectGraduated(await phased(r, buyer, l, "graduate_fallback"), "the fallback");
  const st = await launchState(r, l.token, creator, "a launch graduated on its fallback");
  if (st.status.graduatedVenue?.id !== r.ids.venues.soroswap || st.status.pool !== pool) throw new Error(`graduated on ${JSON.stringify(st.status.graduatedVenue)}`);

  // Holder sharing off: the creator side of the harvest goes to the recipient, in XLM and in the launch token.
  const xlm0 = await balance(r, r.ids.xlm, creator.address);
  const tok0 = await balance(r, l.token, creator.address);
  const since = await lastHarvest(r, pool);
  await roundTrip(r, buyer, r.ids.xlm, l.token, 100n * ONE);
  const harvest = await harvested(r, pool, since);
  const xlm1 = await balance(r, r.ids.xlm, creator.address);
  const tok1 = await balance(r, l.token, creator.address);
  if (xlm1 <= xlm0 || tok1 <= tok0) throw new Error(`the recipient's harvest payout: ${units(xlm1 - xlm0)} XLM, ${units(tok1 - tok0)} tokens`);

  // A takeover: proposed by the admin, vetoed by the recipient, proposed again and executed after takeover_delay.
  const booked = BigInt(st.creatorFees);
  if (booked <= 0n) throw new Error("no creator fees are booked before the takeover");
  const propose = () => direct(r, "admin: propose a takeover", r.qa.ADMIN_SECRET, r.ids.launchpad, "propose_creator_fee_recipient", [sc.addr(l.token), sc.addr(next.address)]);
  await propose();
  const proposed = await launchState(r, l.token, creator, "a launch with a takeover pending");
  if (proposed.pendingTakeover?.new !== next.address || proposed.pendingTakeover.state !== "waiting") throw new Error(`the takeover: ${JSON.stringify(proposed.pendingTakeover)}`);
  await runPlan(r, creator, await api(r, creator.token, "POST", "/launches/build", { action: "recipient_cancel", token: l.token }));
  if ((await launchState(r, l.token, creator)).pendingTakeover !== null) throw new Error("the recipient's veto left the takeover pending");
  await propose();
  const again = await launchState(r, l.token, creator);
  await phaseRefusedTakeover(r, next, l);
  await sleepUntil(again.pendingTakeover.effectiveAt, "the takeover's delay");
  await runPlan(r, next, await api(r, next.token, "POST", "/launches/build", { action: "recipient_execute", token: l.token }));
  const taken = await launchState(r, l.token, creator, "a launch after a takeover");
  if (taken.recipient !== next.address || BigInt(taken.you.creatorOwed) !== booked) throw new Error(`after the takeover: recipient ${taken.recipient}, owed ${taken.you.creatorOwed} of ${booked}`);
  const [{ status }] = await runPlan(r, creator, await api(r, creator.token, "POST", "/launches/build", { action: "claim_owed", asset: "XLM" }));
  if (BigInt(status.returnValue) !== booked) throw new Error(`claim_owed paid ${status.returnValue}, not the ${units(booked)} XLM owed`);

  // A recipient change on a graduated launch without sharing: a harvest step first when the locker allows it (F3), and
  // the backlog that still crosses the change (V7), null when one round takes all of it.
  const change = await api(r, next.token, "POST", "/launches/build", { action: "recipient_transfer", token: l.token, to: creator.address });
  if (!("harvestBacklog" in change)) throw new Error("the recipient change answers no harvestBacklog");
  if (change.harvestBacklog !== null) {
    shaped("a harvest backlog", change.harvestBacklog, {
      residualQuote: "string",
      residualToken: "string",
      growthQuote: "string",
      growthToken: "string",
      roundsToDrain: "number",
      nextHarvestAt: "string",
      drainedBy: "string",
    });
  }
  await runPlan(r, next, change);
  if ((await launchState(r, l.token, creator)).recipient !== creator.address) throw new Error("the recipient change didn't take");
  return `${l.symbol}: ForcedFailure recorded; the fallback refused before ${early.status.fallbackAt}, then graduated on Soroswap; ` +
    `harvest by the ${harvest} paid the recipient both sides; takeover vetoed, then executed; ${units(booked)} XLM owed and claimed; ` +
    `recipient changed back with ${change.steps.length} step(s)`;
}

/** The takeover's execute is refused before its delay: 409 from the builder, or the contract's TimelockNotElapsed. */
async function phaseRefusedTakeover(r: Run, p: Phone, l: Launched): Promise<void> {
  const a = await call(r, p.token, "POST", "/launches/build", { action: "recipient_execute", token: l.token });
  if (a.status === 409) {
    refused(a, 409, "not_available", "the takeover before its delay");
    return;
  }
  refusedNamed(a, "launchpad-v2", "TimelockNotElapsed", "the takeover before its delay");
}

/** Mode 2: the venue reports a success it didn't make, launchpad-v2's checks refuse it at simulation (GraduationInvalid,
 *  nothing recorded), mark_stuck after the grace, then the fallback. */
async function journeyMode2(r: Run): Promise<string> {
  const creator = await phone(r, "mode-2 creator");
  const buyer = await phone(r, "mode-2 buyer");
  const l = await launchedAndCompleted(r, {
    journey: "mode2",
    quote: "XLM",
    venue: r.ids.venues.qaFail,
    sharing: true,
    mode: "BogusSuccess",
    skip: ["mark_stuck", "fallback"],
    creatorBuy: CREATOR_BUY,
    buyBudget: CURVE_BUDGET,
  }, creator, buyer);
  refusedNamed(await call(r, buyer.token, "POST", "/launches/build", { action: "graduate", token: l.token }), "launchpad-v2", "GraduationInvalid", "graduate (mode 2) at simulation");
  const st = await launchState(r, l.token, buyer, "a completed launch's state");
  if (st.status.stuck) throw new Error("mode 2 recorded a failure: an abort records none");
  if (nowSecs() + 5 < Date.parse(st.status.markStuckAt) / 1000) await phaseRefused(r, buyer, l, "mark_stuck", st.status.markStuckAt, "mark_stuck before the grace");
  await sleepUntil(st.status.markStuckAt, "the grace");
  await phased(r, buyer, l, "mark_stuck");
  const stuck = await launchState(r, l.token, buyer, "a launch marked stuck");
  if (!stuck.status.stuck || stuck.status.failure?.source === "recorded") throw new Error(`after mark_stuck: ${JSON.stringify(stuck.status)}`);
  await sleepUntil(stuck.status.fallbackAt, "the fallback opens");
  expectGraduated(await phased(r, buyer, l, "graduate_fallback"), "the fallback after mark_stuck");
  return `${l.symbol}: GraduationInvalid at simulation (nothing recorded); marked stuck at ${stuck.status.stuckSince}; graduated on its fallback`;
}

/** Mode 1: graduate exhausts its budget (nothing recorded), mark_stuck after the grace; the stranger's rescue refused
 *  before rescue_public, the admin's before rescue_admin; the QA admin rescues; pro-rata refunds. */
async function journeyRescueAdmin(r: Run): Promise<string> {
  const creator = await phone(r, "admin-rescue creator");
  const buyer = await phone(r, "admin-rescue buyer");
  const stranger = await phone(r, "admin-rescue stranger");
  const l = await launchedAndCompleted(r, {
    journey: "rescueAdmin",
    quote: "XLM",
    venue: r.ids.venues.qaFail,
    sharing: true,
    mode: "ExhaustBudget",
    skip: ["mark_stuck", "fallback", "rescue"],
    creatorBuy: CREATOR_BUY,
    buyBudget: CURVE_BUDGET,
  }, creator, buyer);
  refused(await call(r, buyer.token, "POST", "/launches/build", { action: "graduate", token: l.token }), 422, "simulation_failed", "graduate (mode 1) at simulation");
  const st = await launchState(r, l.token, buyer);
  await sleepUntil(st.status.markStuckAt, "the grace");
  await phased(r, buyer, l, "mark_stuck");
  const stuck = await launchState(r, l.token, buyer, "a launch marked stuck after a mode-1 failure");
  if (!stuck.status.stuck) throw new Error("mark_stuck didn't take");
  await phaseRefused(r, stranger, l, "rescue", stuck.status.rescuePublicAt, "a stranger's rescue before rescue_public");
  if (nowSecs() + 5 < Date.parse(stuck.status.rescueAdminAt) / 1000) {
    await refusedBy("the admin's rescue before rescue_admin", "launchpad-v2", "NotStuck", () => r.chain.view(r.ids.launchpad, "rescue", [sc.addr(l.token)]));
  }
  await sleepUntil(stuck.status.rescueAdminAt, "rescue_admin");
  await direct(r, `QA admin: rescue ${l.symbol}`, r.qa.ADMIN_SECRET, r.ids.launchpad, "rescue", [sc.addr(l.token)]);
  return `${l.symbol}: mode 1 aborted (nothing recorded), marked stuck, rescued by the QA admin; refunds ${await refunded(r, l, [creator, buyer])}`;
}

/** Mode 0, stuck: a stranger's rescue refused before rescue_public, then done by the stranger; pro-rata refunds. */
async function journeyRescuePublic(r: Run): Promise<string> {
  const creator = await phone(r, "public-rescue creator");
  const buyer = await phone(r, "public-rescue buyer");
  const stranger = await phone(r, "public-rescue stranger");
  const l = await launchedAndCompleted(r, {
    journey: "rescuePublic",
    quote: "XLM",
    venue: r.ids.venues.qaFail,
    sharing: true,
    mode: "Fail",
    skip: ["fallback", "rescue"],
    creatorBuy: CREATOR_BUY,
    buyBudget: CURVE_BUDGET,
  }, creator, buyer);
  expectFailed(await phased(r, buyer, l, "graduate"), "qa-exec-fail", "ForcedFailure", "graduate on the failing venue");
  const st = await recordedLaunchFailure(r, l, "qa-exec-fail", "ForcedFailure");
  await phaseRefused(r, stranger, l, "rescue", st.status.rescuePublicAt, "a stranger's rescue before rescue_public");
  await sleepUntil(st.status.rescuePublicAt, "rescue_public");
  await phased(r, stranger, l, "rescue");
  return `${l.symbol}: stuck on ForcedFailure, rescued by a stranger at rescue_public; refunds ${await refunded(r, l, [creator, buyer])}`;
}

/** A launch quoted in the QA asset, which is locked to the failing venue, completed and stuck. */
async function lockedLaunch(r: Run, journey: Journey): Promise<{ l: Launched; buyer: Phone; st: any }> {
  const creator = await phone(r, `${journey} creator`);
  const buyer = await phone(r, `${journey} buyer`);
  const q = quoteOf(r, "QA");
  if (!q.venueLocked || q.contract !== r.ids.qaSac || q.defaultVenue !== r.ids.venues.qaFail) throw new Error(`the QA quote: ${JSON.stringify(q)}`);
  await qaTo(r, creator, CREATOR_BUY + ONE);
  await qaTo(r, buyer, CURVE_BUDGET);
  const l = await launchedAndCompleted(r, {
    journey,
    quote: "QA",
    venue: q.defaultVenue,
    sharing: false,
    mode: "Fail",
    skip: ["fallback"],
    creatorBuy: CREATOR_BUY,
    buyBudget: CURVE_BUDGET,
    extra: [r.ids.qaSac],
  }, creator, buyer);
  expectFailed(await phased(r, buyer, l, "graduate"), "qa-exec-fail", "ForcedFailure", "graduate on the locked venue");
  const st = await launchState(r, l.token, buyer, "a venue-locked stuck launch");
  if (!st.status.venueLocked || st.status.fallbackAllowed || !st.status.stuck) throw new Error(`the locked launch: ${JSON.stringify(st.status)}`);
  const lockedAt = Date.parse(st.status.stuckSince) / 1000 + r.d.durations.launch.locked_fallback;
  if (Date.parse(st.status.fallbackAt) / 1000 !== lockedAt) throw new Error(`fallbackAt ${st.status.fallbackAt}: a locked launch waits locked_fallback`);
  return { l, buyer, st };
}

/** A venue-locked launch: the admin's allow_fallback opens the fallback from fallback_delay, without locked_fallback. */
async function journeyLockedAllow(r: Run): Promise<string> {
  const { l, buyer } = await lockedLaunch(r, "lockedAllow");
  await direct(r, `admin: allow_fallback ${l.symbol}`, r.qa.ADMIN_SECRET, r.ids.launchpad, "allow_fallback", [sc.addr(l.token)]);
  const st = await launchState(r, l.token, buyer, "a locked launch the admin allowed");
  const opens = Date.parse(st.status.stuckSince) / 1000 + r.d.durations.launch.fallback_delay;
  if (!st.status.fallbackAllowed || Date.parse(st.status.fallbackAt) / 1000 !== opens) throw new Error(`after allow_fallback: ${JSON.stringify(st.status)}`);
  if (nowSecs() + 5 < opens) await phaseRefused(r, buyer, l, "graduate_fallback", st.status.fallbackAt, "the allowed fallback before fallback_delay");
  await sleepUntil(st.status.fallbackAt, "fallback_delay");
  expectGraduated(await phased(r, buyer, l, "graduate_fallback"), "the allowed fallback");
  return `${l.symbol}: locked to the failing venue, allowed by the admin, graduated on Soroswap at fallback_delay; ${await protocolSwept(r, l)} in the QA asset`;
}

/** A venue-locked launch's delay path: after fallback_delay the fallback is still refused (FallbackNotAllowed) until
 *  locked_fallback. */
async function journeyLockedDelay(r: Run): Promise<string> {
  const { l, buyer, st } = await lockedLaunch(r, "lockedDelay");
  await sleepUntil(Date.parse(st.status.stuckSince) / 1000 + r.d.durations.launch.fallback_delay, "fallback_delay");
  await phaseRefused(r, buyer, l, "graduate_fallback", st.status.fallbackAt, "a locked fallback after fallback_delay, before locked_fallback");
  await refusedBy("a locked fallback before locked_fallback", "launchpad-v2", "FallbackNotAllowed", () => r.chain.view(r.ids.launchpad, "graduate_fallback", [sc.addr(l.token)]));
  await sleepUntil(st.status.fallbackAt, "locked_fallback");
  expectGraduated(await phased(r, buyer, l, "graduate_fallback"), "the locked fallback");
  return `${l.symbol}: the fallback refused until locked_fallback (${st.status.fallbackAt}), then graduated on Soroswap; ${await protocolSwept(r, l)} in the QA asset`;
}

/** Aquarius (only when the deployment file enables it, V8): an XLM launch graduated by the keeper on the Aquarius venue. */
async function journeyAquarius(r: Run): Promise<string> {
  const venue = r.ids.venues.aquarius;
  if (venue === null) throw new Error("internal: the Aquarius journey without an Aquarius venue");
  const creator = await phone(r, "Aquarius creator");
  const buyer = await phone(r, "Aquarius buyer");
  const l = await launchedAndCompleted(r, { journey: "aquarius", quote: "XLM", venue, sharing: true, creatorBuy: CREATOR_BUY, buyBudget: CURVE_BUDGET }, creator, buyer);
  const g = await graduated(r, l, buyer);
  const st = await launchState(r, l.token, buyer, "a launch graduated on Aquarius");
  if (st.status.graduatedVenue?.kind !== "Aquarius") throw new Error(`graduated on ${JSON.stringify(st.status.graduatedVenue)}`);
  return `${l.symbol}: graduated on ${st.status.graduatedVenue.name} by the ${g.who}`;
}

// ------------------------------------------------------------------------------------------------ roles

/** Timelocks and the guardian: launchpad-v2's treasury (a proposal refused before its eta and cancelled by the
 *  guardian, then the treasury it has applied after it), a venue (refused before its eta, cancelled by the guardian:
 *  an applied venue would stay in the table for good), the admin's replacement of the guardian (the guardian it has,
 *  applied after its eta), the guardian's handoff to a new key and back; moments-v2's policy timelock (a proposal the
 *  guardian cancels, then the policy it has applied after its eta). Every applied change leaves the role as it was. */
async function journeyGovernance(r: Run): Promise<string> {
  const pad = r.ids.launchpad;
  const admin = r.qa.ADMIN_SECRET;
  const guardian = r.qa.LAUNCHPAD_GUARDIAN_SECRET;
  const anyone = r.qa.DEPLOYER_SECRET;
  if ((await view(r, pad, "guardian")) !== r.roles.launchpadGuardian) throw new Error("launchpad-v2's guardian isn't the deployment file's");

  // The treasury.
  const treasury = String(await view(r, pad, "treasury"));
  await direct(r, "admin: propose_treasury (a fresh address)", admin, pad, "propose_treasury", [sc.addr(Keypair.random().publicKey())]);
  await refusedBy("apply_treasury before its eta", "launchpad-v2", "TimelockNotElapsed", () => r.chain.view(pad, "apply_treasury", []));
  await direct(r, "guardian: cancel_treasury", guardian, pad, "cancel_treasury", [sc.addr(guardian.publicKey())]);
  if ((await view(r, pad, "pending_treasury")) !== null) throw new Error("the guardian's cancel left the treasury proposal");
  await direct(r, "admin: propose_treasury (the treasury it has)", admin, pad, "propose_treasury", [sc.addr(treasury)]);
  await sleepUntil(Number((await view(r, pad, "pending_treasury")).eta), "the treasury timelock");
  await direct(r, "anyone: apply_treasury", anyone, pad, "apply_treasury", []);
  if ((await view(r, pad, "treasury")) !== treasury || (await view(r, pad, "pending_treasury")) !== null) throw new Error("apply_treasury changed the treasury");

  // A venue.
  const venues = ((await view(r, pad, "venues")) as unknown[]).length;
  const proposal = await direct(r, "admin: propose_venue (Soroswap)", admin, pad, "propose_venue", [
    toScVal(VenueKindT, "Soroswap"),
    sc.addr(r.ids.execSoroswap),
    toScVal(VenueParamsT, { fee_fraction: 0 }),
  ]);
  const id = Number(proposal.value);
  await refusedBy("apply_venue before its eta", "launchpad-v2", "TimelockNotElapsed", () => r.chain.view(pad, "apply_venue", [sc.u32(id)]));
  await direct(r, "guardian: cancel_venue", guardian, pad, "cancel_venue", [sc.addr(guardian.publicKey()), sc.u32(id)]);
  if ((await view(r, pad, "pending_venue", [sc.u32(id)])) !== null || ((await view(r, pad, "venues")) as unknown[]).length !== venues) {
    throw new Error("the guardian's cancel left the venue proposal");
  }

  // The admin's replacement of the guardian (F16).
  await direct(r, "admin: propose_guardian (the guardian it has)", admin, pad, "propose_guardian", [toScVal(T.option(T.address), guardian.publicKey())]);
  await refusedBy("apply_guardian before its eta", "launchpad-v2", "TimelockNotElapsed", () => r.chain.view(pad, "apply_guardian", []));
  await sleepUntil(Number((await view(r, pad, "pending_guardian")).eta), "the guardian timelock");
  await direct(r, "anyone: apply_guardian", anyone, pad, "apply_guardian", []);
  if ((await view(r, pad, "guardian")) !== guardian.publicKey()) throw new Error("apply_guardian changed the guardian");

  // The guardian's handoff (L8): to a new key, which accepts, and back.
  const next = await keyAccount(r, "guardian handoff key");
  await direct(r, "guardian: transfer_guardian (to a new key)", guardian, pad, "transfer_guardian", [sc.addr(next.address)]);
  await direct(r, "new key: accept_guardian", next.kp, pad, "accept_guardian", []);
  if ((await view(r, pad, "guardian")) !== next.address) throw new Error("the handoff didn't take");
  await direct(r, "new key: transfer_guardian (back)", next.kp, pad, "transfer_guardian", [sc.addr(guardian.publicKey())]);
  await direct(r, "guardian: accept_guardian", guardian, pad, "accept_guardian", []);
  if ((await view(r, pad, "guardian")) !== guardian.publicKey()) throw new Error("the guardian didn't come back");

  // moments-v2's policy timelock.
  const m = r.ids.moments;
  const policy = await r.chain.view(m, "policy", []);
  await direct(r, "governance: propose_policy", r.qa.GOVERNANCE_SECRET, m, "propose_policy", [policy]);
  await refusedBy("apply_policy before its eta", "moments-v2", "PolicyNotReady", () => r.chain.view(m, "apply_policy", []));
  await direct(r, "Moments guardian: cancel_policy", r.qa.MOMENTS_GUARDIAN_SECRET, m, "cancel_policy", [sc.addr(r.qa.MOMENTS_GUARDIAN_SECRET.publicKey())]);
  if ((await view(r, m, "pending_policy")) !== null) throw new Error("the guardian's cancel left the policy proposal");
  await direct(r, "governance: propose_policy (the policy it has)", r.qa.GOVERNANCE_SECRET, m, "propose_policy", [policy]);
  await sleepUntil(Number((await view(r, m, "pending_policy")).eta), "the policy timelock");
  await direct(r, "anyone: apply_policy", anyone, m, "apply_policy", []);
  if ((await r.chain.view(m, "policy", [])).toXDR("base64") !== policy.toXDR("base64")) throw new Error("apply_policy changed the policy");
  return "treasury: cancelled by the guardian, applied after its timelock; venue: refused early, cancelled by the guardian; " +
    "guardian: replaced by the admin after its timelock, handed off and back; Moments policy: cancelled by the guardian, applied after its timelock";
}

// ------------------------------------------------------------------------------------------------ Moments, main stack

/** Uploads `bytes` through the API's media ticket; answers its public URL. */
async function uploaded(r: Run, p: Phone, type: string, bytes: Uint8Array): Promise<string> {
  const ticket = await api(r, p.token, "POST", "/media/upload-url", { contentType: type, bytes: bytes.length });
  const put = await fetch(ticket.uploadUrl, { method: "PUT", headers: { "content-type": type }, body: Buffer.from(bytes) });
  await put.body?.cancel();
  if (!put.ok) throw new Error(`the upload of ${type} → ${put.status}`);
  return ticket.publicUrl;
}

/** A Moment published as the phone (media, metadata, publish): its NFT address, the Moment's id. */
async function publishedMoment(r: Run, creator: Phone, journey: Journey, windowSecs: number, allocationBps: number): Promise<string> {
  const media = await uploaded(r, creator, "image/png", PNG);
  const meta = await api(r, creator.token, "POST", "/moments/metadata", {
    title: `E2E v2 ${journey}`,
    mediaUrl: media,
    mediaType: "image",
    place: "testnet-qa",
    takenOn: new Date().toISOString().slice(0, 10),
  });
  const body = { action: "publish", uri: meta.uri, symbol: ticker("EM"), price: EDITION_PRICE.toString(), allocationBps, windowSecs };
  const outs = await runPlan(r, creator, await api(r, creator.token, "POST", "/moments/build", body));
  const last = outs[outs.length - 1];
  const nft = String(last.status.returnValue ?? last.step.intent.display.nft);
  if (nft !== last.step.intent.display.nft) throw new Error(`publish returned ${nft}, the plan named ${last.step.intent.display.nft}`);
  say(`    ✓ ${journey}: published ${body.symbol} ${nft}`);
  return nft;
}

async function momentStatus(r: Run, nft: string, what = "a Moment's status"): Promise<any> {
  const s = await api(r, null, "GET", `/moments/${nft}/status`);
  momentStatusShaped(what, s);
  return s;
}

async function vesting(r: Run, p: Phone, nft: string, what = "a Moment's vesting"): Promise<any> {
  const v = await api(r, p.token, "GET", `/moments/${nft}/vesting`);
  vestingShaped(what, v);
  return v;
}

async function collected(r: Run, p: Phone, nft: string, quantity: number): Promise<void> {
  await runPlan(r, p, await api(r, p.token, "POST", "/moments/build", { action: "collect", nft, quantity }));
}

async function momentAction(r: Run, p: Phone, body: Record<string, unknown>): Promise<unknown> {
  const outs = await runPlan(r, p, await api(r, p.token, "POST", "/moments/build", body));
  return outs[outs.length - 1].status.returnValue;
}

/** The main stack's Moment: publish, a partial and a terminal collect, the keeper's graduation, the vesting schedule
 *  from period 0 to the creator's last (5 periods of the QA vest_period, F12), swaps and a harvest on its pool, the
 *  creator's proceeds, and claim_all. */
async function journeyMoment(r: Run): Promise<string> {
  const creator = await phone(r, "Moment creator");
  const a = await phone(r, "collector A");
  const b = await phone(r, "collector B");
  await usdcTo(r, a, EDITION_PRICE);
  await usdcTo(r, b, r.usdc.needs.moment! - EDITION_PRICE);
  const policy = r.econ.moments.policy;
  const nft = await publishedMoment(r, creator, "moment", 3_600, policy.maxCreatorAllocBps);
  const fresh = await momentStatus(r, nft, "a Collecting Moment");
  if (fresh.state !== "collecting" || fresh.expiresBy !== "deadline") throw new Error(`published: ${JSON.stringify(fresh)}`);
  await collected(r, a, nft, 1);
  const part = await momentStatus(r, nft);
  const gross = BigInt(r.econ.moments.completionGross) - BigInt(part.totalGross);
  const qty = Number((gross + EDITION_PRICE - 1n) / EDITION_PRICE);
  await collected(r, b, nft, qty);
  const pending = await momentStatus(r, nft, "a Moment pending graduation");
  if (pending.state !== "graduation_pending" && pending.state !== "graduated") throw new Error(`after the terminal collect: ${pending.state}`);
  if (pending.state === "graduation_pending" && (!pending.backstopAt || !pending.graduatable)) throw new Error(`pending: ${JSON.stringify(pending)}`);

  const { value: grad, by } = await keeperOr("the Moment's graduation", async () => {
    const s = await momentStatus(r, nft, "a graduated Moment");
    return s.state === "graduated" ? s : null;
  }, () => momentAction(r, b, { action: "graduate", nft }));
  const coin = grad.coin;
  const pool = grad.pool;
  const startsAt = Date.parse(grad.graduatedAt) / 1000;
  const period = r.d.durations.moments.vest_period;

  // Period 0: collectors 60%, the creator 20% of its allocation.
  for (const p of [a, b]) {
    const v = await vesting(r, p, nft, "a collector's vesting at period 0");
    if (!v.collector || v.collector.tranches.length !== 3 || BigInt(v.claimable.collector) <= 0n) throw new Error(`${p.label}'s vesting: ${JSON.stringify(v)}`);
    await momentAction(r, p, { action: "claim", nft });
  }
  const cv = await vesting(r, creator, nft, "the creator's vesting at period 0");
  if (!cv.creator || cv.creator.tranches.length !== 6) throw new Error(`the creator's vesting: ${JSON.stringify(cv)}`);
  await momentAction(r, creator, { action: "claim", nft });

  // Swaps on the Moment's pool, then a harvest: 40% of its USDC side to the creator, the coin side burned.
  const usdc0 = await balance(r, r.ids.usdc, creator.address);
  const since = await lastHarvest(r, pool);
  const left = await balance(r, r.ids.usdc, b.address);
  await roundTrip(r, b, r.ids.usdc, coin, left < HARVEST_SWAP_USDC ? left : HARVEST_SWAP_USDC);
  const harvest = await harvested(r, pool, since);
  if ((await balance(r, r.ids.usdc, creator.address)) <= usdc0) throw new Error("the harvest paid the creator no USDC");

  // The creator's proceeds: its share of every collect.
  const owed = BigInt((await momentStatus(r, nft)).proceeds.creator);
  const withdrawn = BigInt(String(await momentAction(r, creator, { action: "withdraw", nft })));
  if (withdrawn !== owed || owed <= 0n) throw new Error(`the creator's withdraw paid ${units(withdrawn)} USDC, its proceeds are ${units(owed)}`);

  // The schedule: a claim each period, collectors full after 2, the creator after 5; A claims through claim_all.
  for (let k = 1; k <= 5; k++) {
    await sleepUntil(startsAt + k * period, `vesting period ${k}`);
    if (k <= 2) {
      await momentAction(r, a, { action: "claim_all", nfts: [nft] });
      await momentAction(r, b, { action: "claim", nft });
    }
    await momentAction(r, creator, { action: "claim", nft });
  }
  for (const [p, side] of [[a, "collector"], [b, "collector"], [creator, "creator"]] as const) {
    const v = await vesting(r, p, nft, `a fully vested ${side}`);
    const s = v[side];
    if (!s || s.vested !== s.total || s.claimed !== s.total || s.nextAt !== null) throw new Error(`${p.label} isn't fully vested: ${JSON.stringify(s)}`);
  }
  return `${nft}: completed by ${qty + 1} editions, graduated by the ${by}; harvest by the ${harvest}; ${units(owed)} USDC of proceeds; ` +
    `fully vested over ${period * 5} s (collectors at 2 periods, claim_all included)`;
}

/** A second main-stack Moment left Collecting past its deadline: refused before it, then expired by the run (the
 *  keeper's expiry held off); the creator withdraws its share. */
async function journeyMomentExpiry(r: Run): Promise<string> {
  const creator = await phone(r, "expiring Moment creator");
  const collector = await phone(r, "expiring Moment collector");
  await usdcTo(r, collector, r.usdc.needs.momentExpiry!);
  const nft = await publishedMoment(r, creator, "momentExpiry", r.d.durations.moments.min_window, 0);
  await keeperSkip(r, "moment", nft, ["expire"], "momentExpiry: the run expires it itself");
  await collected(r, collector, nft, 1);
  const st = await momentStatus(r, nft, "a Collecting Moment with one collect");
  if (st.state !== "collecting" || st.collects !== 1) throw new Error(`after the collect: ${JSON.stringify(st)}`);
  if (nowSecs() + 5 < Date.parse(st.deadline) / 1000) {
    refusedNamed(await call(r, collector.token, "POST", "/moments/build", { action: "expire", nft }), "moments-v2", "NotExpirable", "expire before the deadline");
  }
  await sleepUntil(st.deadline, "the Moment's deadline");
  await momentAction(r, collector, { action: "expire", nft });
  const ended = await momentStatus(r, nft, "an expired Moment");
  if (ended.state !== "expired" || ended.expirable || !ended.endedAt) throw new Error(`after expire: ${JSON.stringify(ended)}`);
  const owed = BigInt(ended.proceeds.creator);
  const withdrawn = BigInt(String(await momentAction(r, creator, { action: "withdraw", nft })));
  if (withdrawn !== owed || owed <= 0n) throw new Error(`the expired Moment's withdraw paid ${units(withdrawn)} USDC of the creator's ${units(owed)}`);
  return `${nft}: expired past its deadline (${st.deadline}); the creator withdrew ${units(owed)} USDC`;
}

// ------------------------------------------------------------------------------------------------ Moments, failing stack

interface FailingMoment {
  nft: string;
  creator: Actor;
  collector: Actor;
  completedAt: number;
  deadline: number;
}

/** A Moment on testnet-qa's failing stack (direct calls, F5): published with the shortest window, its coin's mode set,
 *  the keeper_skip row inserted, and completed by one collect. */
async function failingMoment(r: Run, journey: Journey, mode: "Fail" | "ExhaustBudget" | "BogusSuccess", skip: string[]): Promise<FailingMoment> {
  const m = r.ids.momentsFail;
  const creator = await keyAccount(r, `${journey} creator`, { usdc: true });
  const collector = await keyAccount(r, `${journey} collector`, { usdc: true });
  await usdcTo(r, collector, r.usdc.needs[journey]!);
  const nonce = crypto.getRandomValues(new BigUint64Array(1))[0];
  const nft = String(await view(r, m, "nft_address", [sc.addr(creator.address), sc.u64(nonce)]));
  const coin = String(await view(r, r.ids.graduatorFail, "coin_address", [sc.addr(nft)]));
  const params = toScVal(PublishParamsT, {
    name: `E2E v2 ${journey}`,
    symbol: ticker("EF"),
    metadata_uri: "https://dyorhq.fun/testnet-qa/e2e-v2.json",
    media_hash: Uint8Array.from(hash(Buffer.from(`${NOTE} ${journey} ${nonce}`))),
    place: "testnet-qa",
    date: new Date().toISOString().slice(0, 10),
    price: EDITION_PRICE,
    creator_alloc_bps: 0,
    window_secs: BigInt(r.d.durations.moments.min_window),
    nonce,
  });
  const published = await direct(r, `${journey}: publish (failing stack)`, creator.kp, m, "publish", [sc.addr(creator.address), params, await r.chain.view(m, "terms", [])]);
  if (published.value !== nft) throw new Error(`publish returned ${published.value}, nft_address said ${nft}`);
  await setMode(r, coin, mode);
  await keeperSkip(r, "moment", nft, skip, `${journey}: before the terminal collect`);
  const policy = await view(r, m, "policy");
  const gross = completionGross(BigInt(policy.threshold), Number(policy.reserve_bps));
  const qty = Number((gross + EDITION_PRICE - 1n) / EDITION_PRICE);
  const q = await view(r, m, "quote", [sc.addr(nft), sc.u32(qty)]);
  if (!q.terminal) throw new Error(`${journey}: a collect of ${qty} doesn't complete the Moment`);
  await direct(r, `${journey}: terminal collect`, collector.kp, m, "collect", [sc.addr(collector.address), sc.addr(nft), sc.u32(qty), sc.i128(BigInt(q.gross))]);
  const l = await view(r, m, "ledger", [sc.addr(nft)]);
  if (Number(l.state) !== 1) throw new Error(`${journey}: after the terminal collect the Moment is in state ${l.state}, not GraduationPending`);
  const deadline = Number((await view(r, m, "get_moment", [sc.addr(nft)])).deadline);
  return { nft, creator, collector, completedAt: Number(l.completed_at), deadline };
}

async function ledgerOf(r: Run, fm: FailingMoment): Promise<any> {
  return await view(r, r.ids.momentsFail, "ledger", [sc.addr(fm.nft)]);
}

/** A recorded graduation failure as the indexer's row has it, which the status route passes on (V10). */
interface Recorded {
  origin: number;
  code: number;
}

/** A failing-stack Moment's status as the API's own read makes it (moments_v2.ts momentStatusV2, the code behind
 *  GET /v1/moments/:nft/status), pointed at the failing stack the API never serves (F5), through JSON and held to the
 *  shape the phone decodes (F4). `recorded` is the indexer's grad_fail, as the route passes it; without one, a Moment
 *  stuck after a failure gets the failure a graduation attempt records now (`simulated`). */
async function failingStatus(r: Run, fm: FailingMoment, what: string, recorded: Recorded | null = null): Promise<any> {
  const net = withDeploymentV2(TESTNET, { ...r.d, contracts: { ...r.d.contracts, momentsV2: r.ids.momentsFail } });
  const s = JSON.parse(JSON.stringify(await momentStatusV2(fm.nft, { net, recorded })));
  momentStatusShaped(what, s);
  return s;
}

/** Throws unless the ISO time `iso` is the unix second `secs` (null with null). */
function sameTime(what: string, iso: string | null, secs: number | null): void {
  const ok = iso === null || secs === null ? iso === secs : Date.parse(iso) === secs * 1000;
  if (!ok) throw new Error(`${what}: ${iso}, expected ${secs === null ? null : new Date(secs * 1000).toISOString()}`);
}

/** Holds a pending failing-stack Moment's status to the expiry moments-v2's expire applies (V11), restated from the
 *  chain: the later of its deadline and the first of the failure's clock (stuck_since + stuck_expiry, only after a
 *  recorded failure) and the backstop (completed_at + pending_backstop), the failure's on a tie. */
function heldToExpiry(r: Run, fm: FailingMoment, s: any, stuckSince: number, what: string): void {
  const d = r.d.durations.moments;
  const backstopAt = fm.completedAt + d.pending_backstop;
  const failureAt = stuckSince !== 0 ? stuckSince + d.stuck_expiry : null;
  const clock = failureAt !== null && failureAt <= backstopAt ? { at: failureAt, by: "failure" } : { at: backstopAt, by: "backstop" };
  const e = fm.deadline > clock.at ? { at: fm.deadline, by: "deadline" } : clock;
  if (s.state !== "graduation_pending" || !s.graduatable) throw new Error(`${what}: ${s.state}, graduatable ${s.graduatable}`);
  if (s.expiresBy !== e.by) throw new Error(`${what}: expires by ${s.expiresBy}, expected ${e.by}`);
  sameTime(`${what}.expiresAt`, s.expiresAt, e.at);
  sameTime(`${what}.backstopAt`, s.backstopAt, backstopAt);
  sameTime(`${what}.failureExpiresAt`, s.failureExpiresAt, failureAt);
  sameTime(`${what}.stuckSince`, s.stuckSince, stuckSince === 0 ? null : stuckSince);
  sameTime(`${what}.completedAt`, s.completedAt, fm.completedAt);
  // The read answered a moment ago: at the expiry itself either answer stands.
  const now = nowSecs();
  if (Math.abs(now - e.at) > 5 && s.expirable !== now >= e.at) throw new Error(`${what}: expirable ${s.expirable} at ${new Date(now * 1000).toISOString()}`);
  say(`    ✓ ${what}: expires by ${e.by} at ${s.expiresAt}`);
}

/** Holds a failing-stack Moment's status failure to the named error, seen as `seen`. */
function failureIs(s: any, source: string, name: string, seen: "recorded" | "simulated", what: string): void {
  const e = named(source, name);
  const f = s.failure;
  if (f?.origin !== e.origin || f?.code !== e.code || f?.name !== name || f?.seen !== seen || !String(f?.source ?? "").split(" or ").includes(source)) {
    throw new Error(`${what}: failure ${JSON.stringify(f)}, expected ${source} ${name} (origin ${e.origin}, code ${e.code}), ${seen}`);
  }
}

/** Holds an expired failing-stack Moment's status: ended, with no expiry left. */
async function expiredStatus(r: Run, fm: FailingMoment, what: string): Promise<void> {
  const s = await failingStatus(r, fm, what);
  if (s.state !== "expired" || s.expirable || s.graduatable || s.expiresBy !== null || s.expiresAt !== null || !s.endedAt || s.failure !== null) {
    throw new Error(`${what}: ${JSON.stringify(s)}`);
  }
}

/** A failing-stack Moment's recorded graduation failure (V10): the indexer's grad_fail on its row, and what a graduation
 *  attempt records now, held to the namespaced origin and code. */
async function recordedMomentFailure(r: Run, fm: FailingMoment, source: string, name: string): Promise<Recorded> {
  const e = named(source, name);
  expectFailed(await view(r, r.ids.momentsFail, "graduate", [sc.addr(fm.nft)]), source, name, "a graduation attempt now");
  const row = await until("the indexer's grad_fail", WAIT.indexer, async () => {
    const [row] = await r.db`select fail_origin, fail_code, fail_name from lite.moments where nft = ${fm.nft}`;
    return row?.fail_origin !== null && row?.fail_origin !== undefined ? row : null;
  });
  if (Number(row.fail_origin) !== e.origin || Number(row.fail_code) !== e.code || row.fail_name !== name) {
    throw new Error(`the recorded failure: ${JSON.stringify(row)}, expected ${source} ${name} (origin ${e.origin}, code ${e.code})`);
  }
  say(`    ✓ grad_fail recorded as origin ${e.origin} code ${e.code} (${source} ${name})`);
  return { origin: e.origin, code: e.code };
}

/** Expires a failing-stack Moment the run holds the expiry of: refused before `opens`, done after it. */
async function expiredAt(r: Run, fm: FailingMoment, opens: number, what: string): Promise<void> {
  if (nowSecs() + 5 < opens) await refusedBy(`expire before ${what}`, "moments-v2", "NotExpirable", () => r.chain.view(r.ids.momentsFail, "expire", [sc.addr(fm.nft)]));
  await sleepUntil(opens, what);
  await direct(r, "expire (anyone)", fm.collector.kp, r.ids.momentsFail, "expire", [sc.addr(fm.nft)]);
  if (Number((await ledgerOf(r, fm)).state) !== 3) throw new Error("expire didn't end the Moment");
  const paid = await direct(r, "withdraw_creator (anyone)", fm.collector.kp, r.ids.momentsFail, "withdraw_creator", [sc.addr(fm.nft)]);
  if (BigInt(paid.value) <= 0n) throw new Error("the expired Moment paid its creator nothing");
}

/** The keeper's grad_fail on the failing stack, or the run's as the keeper. */
async function keeperGradFail(r: Run, fm: FailingMoment): Promise<{ stuckSince: number; by: string }> {
  const { value, by } = await keeperOr("the keeper's grad_fail", async () => {
    const s = Number((await ledgerOf(r, fm)).stuck_since);
    return s > 0 ? s : null;
  }, () => direct(r, "keeper: graduate (failing stack)", r.qa.DEPLOYER_SECRET, r.ids.momentsFail, "graduate", [sc.addr(fm.nft)]));
  return { stuckSince: value, by };
}

/** Mode 0: the keeper records ForcedFailure, the Moment expires after stuck_expiry. */
async function journeyFailingMode0(r: Run): Promise<string> {
  const fm = await failingMoment(r, "failingMode0", "Fail", ["expire"]);
  const { stuckSince, by } = await keeperGradFail(r, fm);
  const recorded = await recordedMomentFailure(r, fm, "qa-exec-fail", "ForcedFailure");
  const stuck = await failingStatus(r, fm, "a stuck Moment with a recorded failure", recorded);
  failureIs(stuck, "qa-exec-fail", "ForcedFailure", "recorded", "a stuck Moment with a recorded failure");
  heldToExpiry(r, fm, stuck, stuckSince, "a stuck Moment with a recorded failure");
  await expiredAt(r, fm, Math.max(fm.deadline, stuckSince + r.d.durations.moments.stuck_expiry), "stuck_expiry");
  await expiredStatus(r, fm, "a Moment expired after stuck_expiry");
  return `${fm.nft}: ForcedFailure recorded by the ${by}; expired after stuck_expiry`;
}

/** Mode 2: the graduator's own GraduationInvalid (origin 10) is recorded as a failure; the Moment expires after it. */
async function journeyFailingMode2(r: Run): Promise<string> {
  const fm = await failingMoment(r, "failingMode2", "BogusSuccess", ["expire"]);
  const { stuckSince, by } = await keeperGradFail(r, fm);
  const recorded = await recordedMomentFailure(r, fm, "moments-graduator", "GraduationInvalid");
  const stuck = await failingStatus(r, fm, "a Moment stuck on GraduationInvalid", recorded);
  failureIs(stuck, "moments-graduator", "GraduationInvalid", "recorded", "a Moment stuck on GraduationInvalid");
  heldToExpiry(r, fm, stuck, stuckSince, "a Moment stuck on GraduationInvalid");
  await expiredAt(r, fm, Math.max(fm.deadline, stuckSince + r.d.durations.moments.stuck_expiry), "stuck_expiry");
  await expiredStatus(r, fm, "a Moment expired after GraduationInvalid");
  return `${fm.nft}: the graduator's GraduationInvalid recorded by the ${by}; expired after stuck_expiry`;
}

/** A completed Moment with no recorded failure isn't expirable (V5): the keeper held off it (graduate, expire), expire
 *  is refused after its deadline and past stuck_expiry; the run's graduate records the failure, and it expires
 *  stuck_expiry later. */
async function journeyNotExpirable(r: Run): Promise<string> {
  const fm = await failingMoment(r, "notExpirable", "Fail", ["graduate", "expire"]);
  const d = r.d.durations.moments;
  await sleepUntil(Math.max(fm.deadline, fm.completedAt + d.stuck_expiry), "the deadline and stuck_expiry");
  if (Number((await ledgerOf(r, fm)).stuck_since) !== 0) throw new Error("a failure was recorded: the keeper didn't hold off");
  const waiting = await failingStatus(r, fm, "a completed Moment with no recorded failure");
  if (waiting.failure !== null) throw new Error(`with no recorded failure: ${JSON.stringify(waiting.failure)}`);
  heldToExpiry(r, fm, waiting, 0, "a completed Moment with no recorded failure");
  await refusedBy("expire with no recorded failure", "moments-v2", "NotExpirable", () => r.chain.view(r.ids.momentsFail, "expire", [sc.addr(fm.nft)]));
  const g = await direct(r, "graduate (the run)", fm.collector.kp, r.ids.momentsFail, "graduate", [sc.addr(fm.nft)]);
  expectFailed(g.value, "qa-exec-fail", "ForcedFailure", "the run's graduate");
  const stuckSince = Number((await ledgerOf(r, fm)).stuck_since);
  if (stuckSince === 0) throw new Error("the run's graduate recorded no failure");
  // Before the indexer passes the grad_fail on, the status names the failure a graduation attempt records now.
  const stuck = await failingStatus(r, fm, "a Moment stuck after the run's graduate");
  failureIs(stuck, "qa-exec-fail", "ForcedFailure", "simulated", "a Moment stuck after the run's graduate");
  heldToExpiry(r, fm, stuck, stuckSince, "a Moment stuck after the run's graduate");
  await expiredAt(r, fm, stuckSince + d.stuck_expiry, "stuck_expiry after the recorded failure");
  await expiredStatus(r, fm, "a Moment expired after the run's recorded failure");
  return `${fm.nft}: NotExpirable with no recorded failure; ForcedFailure recorded by the run; expired after stuck_expiry`;
}

/** The backstop (V11): mode 1 aborts every graduation, so nothing is recorded; expire is refused until
 *  completed_at + pending_backstop, then takes it, as a backstop expiry. */
async function journeyBackstop(r: Run): Promise<string> {
  const fm = await failingMoment(r, "backstop", "ExhaustBudget", ["expire"]);
  const d = r.d.durations.moments;
  let aborted = false;
  try {
    await r.chain.view(r.ids.momentsFail, "graduate", [sc.addr(fm.nft)]);
  } catch {
    aborted = true;
  }
  if (!aborted) throw new Error("mode 1's graduation didn't abort in simulation");
  await sleepUntil(fm.deadline + 5, "the deadline");
  if (Number((await ledgerOf(r, fm)).stuck_since) !== 0) throw new Error("mode 1 recorded a failure: an abort records none");
  const pending = await failingStatus(r, fm, "a Moment only the backstop ends");
  if (pending.failure !== null) throw new Error(`mode 1's Moment shows a failure: ${JSON.stringify(pending.failure)}`);
  heldToExpiry(r, fm, pending, 0, "a Moment only the backstop ends");
  await expiredAt(r, fm, fm.completedAt + d.pending_backstop, "completed_at + pending_backstop");
  await expiredStatus(r, fm, "a Moment expired by the backstop");
  const row = await until("the indexer's expiry", WAIT.indexer, async () => {
    const [row] = await r.db`select expired_backstop from lite.moments where nft = ${fm.nft}`;
    return row?.expired_backstop === null || row?.expired_backstop === undefined ? null : row;
  });
  if (row.expired_backstop !== true) throw new Error("the expiry wasn't recorded as the backstop's");
  return `${fm.nft}: no failure recorded; expire refused until ${d.pending_backstop} s after completion, then expired by the backstop`;
}

// ------------------------------------------------------------------------------------------------ the run

const RUNNERS: Record<Journey, (r: Run) => Promise<string>> = {
  launch: journeyLaunch,
  fallback: journeyFallback,
  mode2: journeyMode2,
  rescueAdmin: journeyRescueAdmin,
  rescuePublic: journeyRescuePublic,
  lockedAllow: journeyLockedAllow,
  lockedDelay: journeyLockedDelay,
  aquarius: journeyAquarius,
  governance: journeyGovernance,
  moment: journeyMoment,
  momentExpiry: journeyMomentExpiry,
  failingMode0: journeyFailingMode0,
  failingMode2: journeyFailingMode2,
  notExpirable: journeyNotExpirable,
  backstop: journeyBackstop,
};

/** The contracts and venue ids of the run, from the deployment file and /v1/economics, each held to the other. */
function idsOf(d: DeploymentV2, econ: any, config: any): Ids {
  const lp = econ.launchpad;
  const m = econ.moments;
  if (!d.qa || !d.qaAsset) throw new Error("the deployment file has no failing stack or QA asset: it isn't testnet-qa's");
  if (lp?.contract !== d.contracts.launchpadV2 || lp?.locker !== d.contracts.lpLocker || m?.contract !== d.contracts.momentsV2) {
    throw new Error("/v1/economics names other contracts than deployments/testnet-qa-v2.json");
  }
  const quote = (asset: string) => (lp.quotes as any[]).find((q) => q.asset === asset)?.contract as string | undefined;
  const xlm = quote("XLM");
  const usdc = quote("USDC");
  const qaSac = quote("QA");
  const registryUsdc = (config.assets as any[]).find((a) => a.id === "USDC")?.contract;
  if (!xlm || xlm !== lp.launchFee.contract) throw new Error("/v1/economics: the XLM quote isn't the launch fee's asset");
  if (!usdc || usdc !== registryUsdc || m.quote.contract !== usdc) throw new Error("/v1/economics: USDC isn't the registry's (Circle's) USDC");
  if (qaSac !== d.qaAsset.sac) throw new Error("/v1/economics: the QA quote isn't the deployment file's QA asset");
  for (const v of lp.venues as any[]) {
    const f = d.venues.find((x) => x.id === v.id);
    if (!f || f.kind !== v.kind || f.executor !== v.executor) throw new Error(`/v1/economics' venue ${v.id} isn't the deployment file's (F8)`);
  }
  const venue = (kind: string) => (lp.venues as any[]).find((v) => v.kind === kind && v.enabled)?.id as number | undefined;
  const soroswap = venue("Soroswap");
  const qaFail = venue("QaFail");
  if (soroswap === undefined || qaFail === undefined) throw new Error("/v1/economics lists no enabled Soroswap or QaFail venue");
  return {
    launchpad: d.contracts.launchpadV2,
    locker: d.contracts.lpLocker,
    moments: d.contracts.momentsV2,
    execSoroswap: d.contracts.execSoroswap,
    qaExecFail: d.qa.qaExecFail,
    momentsFail: d.qa.momentsV2QaFail,
    graduatorFail: d.qa.momentsGraduatorQaFail,
    xlm,
    usdc,
    qaSac,
    router: config.contracts.soroswapRouter,
    venues: { soroswap, qaFail, aquarius: d.aquarius.enabled ? venue("Aquarius") ?? null : null },
  };
}

/** The live terms the USDC needs are computed from. */
async function usdcTermsOf(r: Run): Promise<UsdcTerms> {
  const p = await view(r, r.ids.momentsFail, "policy");
  return {
    launchThreshold: BigInt(quoteOf(r, "USDC").threshold),
    launchFeeBps: r.econ.launchpad.feeBps,
    creatorFeeBps: CREATOR_FEE_BPS,
    momentGross: BigInt(r.econ.moments.completionGross),
    failingMomentGross: completionGross(BigInt(p.threshold), Number(p.reserve_bps)),
    partialCollect: EDITION_PRICE,
  };
}

/** The run's USDC: the depth check, then one swap through the app's route (and a top-up for its slippage). Answers the
 *  journeys left to run. */
async function acquireUsdc(r: Run, journeys: Journey[], results: Result[]): Promise<Journey[]> {
  const terms = await usdcTermsOf(r);
  const total = usdcToAcquire(journeys, terms);
  if (total === 0n) return journeys;
  say(`USDC: ${units(total)} for ${USDC_JOURNEYS.filter((j) => journeys.includes(j)).join(", ")} (their needs times 1.13)`);
  const bank = await phone(r, "USDC bank");
  // Every venue's route the API quotes (its routes list), so the check holds each venue to its own rate.
  const quotes = async (sell: bigint) => {
    const q = await api(r, bank.token, "POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: sell.toString(), slippageBps: 300 });
    return Object.fromEntries((q.routes as any[]).map((x) => [String(x.venue), BigInt(x.amountOut)]));
  };
  const depth = await checkDepthByVenue(quotes, total);
  say(`  depth check${depth.venue ? ` (${depth.venue})` : ""}: 1 XLM → ${units(depth.rate1)} USDC; ${units(depth.sell)} XLM → ${units(depth.out)} USDC: ` +
    (depth.ok ? "deep enough" : `too thin (${depth.reason})`));
  const spendable = BigInt((await api(r, bank.token, "GET", "/account")).xlm.spendable);
  const affordable = depth.ok && (depth.sell * 103n) / 100n <= spendable;
  const next = afterDepth(journeys, affordable ? depth : { ...depth, ok: false, reason: depth.reason ?? `${units(depth.sell)} XLM is more than one Friendbot account holds` });
  if (next.message) {
    say(`  ${next.message}`);
    for (const j of next.stopped) results.push({ journey: j, outcome: "SKIP", detail: next.message });
    return next.run;
  }
  // On the venue that passed the check, never on another route the API ranks first.
  const swap = async (sell: bigint) => {
    const q = await api(r, bank.token, "POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: sell.toString(), slippageBps: 300 });
    await runPlan(r, bank, await api(r, bank.token, "POST", "/swap/build", { quoteId: q.quoteId, venue: depth.venue }));
  };
  await swap(depth.sell);
  const got = await balance(r, r.ids.usdc, bank.address);
  if (got < total) await swap(((total - got) * ONE * 105n) / (depth.rate1 * 100n) + ONE);
  const held = await balance(r, r.ids.usdc, bank.address);
  if (held < total) throw new Error(`the bank holds ${units(held)} USDC after the swaps, under the ${units(total)} needed`);
  r.usdc = { needs: usdcNeeds(next.run, terms), bank };
  say(`  ✓ the bank holds ${units(held)} USDC (Circle's), bought through /v1/swap`);
  return next.run;
}

/** LITE_DB_URL, or the local stack's database behind the loopback LITE_API (Postgres on PORT_BASE + 2). */
function dbUrl(api: string): string {
  const set = Deno.env.get("LITE_DB_URL");
  if (set) return set;
  return `postgresql://lite_api@127.0.0.1:${Number(new URL(api).port) + 2}/lite`;
}

interface Result {
  journey: Journey;
  outcome: "PASS" | "FAIL" | "SKIP";
  detail: string;
}

async function main(): Promise<number> {
  const refusal = deploymentRefusal((n) => Deno.env.get(n));
  if (refusal) {
    console.error(refusal);
    return 2;
  }
  const unknown = Deno.args.filter((a) => !(JOURNEYS as readonly string[]).includes(a));
  if (unknown.length) {
    console.error(`unknown journey ${unknown.join(", ")}; journeys: ${JOURNEYS.join(" ")}`);
    return 2;
  }
  const apiBase = Deno.env.get("LITE_API")!;
  const d = deploymentV2ByName(QA);
  if (!d || !d.qa || !d.qaAsset || d.durations.set !== QA) {
    console.error("deployments/testnet-qa-v2.json is missing here, or isn't a testnet-qa deployment with its failing stack");
    return 2;
  }
  const file = JSON.parse(await Deno.readTextFile(new URL("../../supabase/functions/_shared/deployments/testnet-qa-v2.json", import.meta.url)));
  const roles = file.roles as Roles;
  const qa = await loadQaKeys(secretsDir());
  if (!qa) {
    console.error("testnet-qa's key file isn't in the secrets directory: the run needs the QA keys deploy-contracts-v2.ts wrote");
    return 2;
  }
  const keyed: [QaKeyName, string][] = [
    ["DEPLOYER_SECRET", file.deployer],
    ["ADMIN_SECRET", roles.admin],
    ["LAUNCHPAD_GUARDIAN_SECRET", roles.launchpadGuardian],
    ["GOVERNANCE_SECRET", roles.governance],
    ["MOMENTS_GUARDIAN_SECRET", roles.momentsGuardian],
    ["QA_ADMIN_SECRET", roles.qaAdmin],
    ["QA_ISSUER_SECRET", roles.qaIssuer],
  ];
  const mismatched = keyed.filter(([k, pub]) => qa[k].publicKey() !== pub).map(([k]) => k);
  if (mismatched.length) {
    console.error(`the QA keys belong to another deployment than the file's: ${mismatched.join(", ")}`);
    return 2;
  }

  const bare = { api: apiBase } as Run;
  const config = await api(bare, null, "GET", "/config");
  if (config.deployment?.id !== QA || config.contracts?.launchpadV2 !== d.contracts.launchpadV2 || config.contracts?.momentsV2 !== d.contracts.momentsV2) {
    console.error(`the stack at ${apiBase} serves ${config.deployment?.id ?? "another deployment"}, not deployments/testnet-qa-v2.json`);
    return 2;
  }
  // The API's own reads this process makes (failingStatus) go through the stack's RPC, as the run's chain does, so that
  // neither trails the other by a ledger.
  Deno.env.set("STELLAR_RPC_URL", config.rpcUrl);
  const econ = await api(bare, null, "GET", "/economics");
  if (econ.launchpad?.generation !== 2 || econ.moments?.generation !== 2) {
    console.error(`the stack at ${apiBase} doesn't serve v2's economics (generation 2): it isn't wired for contracts v2`);
    return 2;
  }
  shaped("/v1/economics' launchpad block", econ.launchpad, SHAPES.economicsLaunchpad);
  shaped("/v1/economics' Moments block", econ.moments, SHAPES.economicsMoments);
  for (const q of econ.launchpad.quotes) shaped(`/v1/economics' ${q.asset} quote`, q, SHAPES.economicsQuote);
  for (const q of econ.moments.quotes) shaped("/v1/economics' Moments quote (v1's name)", q, SHAPES.economicsMomentsQuoteV1);
  for (const v of econ.launchpad.venues) shaped("/v1/economics' venue", v, SHAPES.venue);

  const r: Run = {
    api: apiBase,
    db: postgres(dbUrl(apiBase), { onnotice: () => {} }),
    chain: testnetChain({ rpcUrl: config.rpcUrl, horizonUrl: config.horizonUrl, friendbotUrl: TESTNET.friendbotUrl! }),
    d,
    roles,
    qa,
    config,
    econ,
    ids: idsOf(d, econ, config),
    pins: v2Pins(d, TESTNET.maxLaunchFeeStroops),
    usdc: { needs: {}, bank: null },
    skips: [],
    fees: { phone: 0n, direct: 0n },
  };
  const results: Result[] = [];
  let journeys: Journey[] = Deno.args.length ? JOURNEYS.filter((j) => Deno.args.includes(j)) : [...JOURNEYS];
  if (journeys.includes("aquarius") && r.ids.venues.aquarius === null) {
    const why = `Aquarius is off on testnet-qa (deployment file: aquarius.enabled ${d.aquarius.enabled}, ${d.aquarius.reason ?? "no reason"}; O7)`;
    results.push({ journey: "aquarius", outcome: "SKIP", detail: why });
    journeys = journeys.filter((j) => j !== "aquarius");
  }
  say(`lite_e2e_v2 · testnet-qa · launchpad-v2 ${r.ids.launchpad} · moments-v2 ${r.ids.moments} · failing stack ${r.ids.momentsFail}`);
  say(`  venues: Soroswap ${r.ids.venues.soroswap}, QaFail ${r.ids.venues.qaFail}${r.ids.venues.aquarius === null ? "" : `, Aquarius ${r.ids.venues.aquarius}`}`);
  try {
    journeys = await acquireUsdc(r, journeys, results);
    const settled = await Promise.allSettled(journeys.map(async (j) => {
      say(`▶ ${j}`);
      const detail = await RUNNERS[j](r);
      say(`✓ ${j}: ${detail}`);
      return detail;
    }));
    settled.forEach((s, i) => {
      const journey = journeys[i];
      if (s.status === "fulfilled") results.push({ journey, outcome: "PASS", detail: s.value });
      else {
        results.push({ journey, outcome: "FAIL", detail: String((s.reason as Error)?.message ?? s.reason) });
        say(`✗ ${journey}: ${(s.reason as Error)?.message ?? s.reason}`);
      }
    });
  } catch (e) {
    for (const j of journeys) if (!results.some((x) => x.journey === j)) results.push({ journey: j, outcome: "FAIL", detail: `setup: ${(e as Error).message}` });
  } finally {
    if (r.skips.length) await r.db`delete from lite.keeper_skip where id = any(${r.db.array(r.skips)})`;
    await r.db.end();
  }
  results.sort((a, b) => JOURNEYS.indexOf(a.journey) - JOURNEYS.indexOf(b.journey));
  say("\n" + results.map((x) => `${x.outcome}  ${x.journey.padEnd(13)} ${x.detail}`).join("\n"));
  say(`fees: the phone's steps ${units(r.fees.phone)} XLM, direct calls (roles and keeper) ${units(r.fees.direct)} XLM`);
  return results.every((x) => x.outcome !== "FAIL") ? 0 : 1;
}

if (import.meta.main) Deno.exit(await main());

// ------------------------------------------------------------------------------------------------ unit tests

/** §18.4's terms on testnet-qa: the USDC quote's threshold 43.2455532, a 1% curve fee and the run's 1% creator fee;
 *  Moments at T = 10 USDC with a 75% reserve, on both stacks; the partial collect at 1 USDC. */
const SPEC_TERMS: UsdcTerms = {
  launchThreshold: 432_455_532n,
  launchFeeBps: 100,
  creatorFeeBps: CREATOR_FEE_BPS,
  momentGross: completionGross(100_000_000n, 7_500),
  failingMomentGross: completionGross(100_000_000n, 7_500),
  partialCollect: EDITION_PRICE,
};

function assertTest(ok: boolean, what: string): void {
  if (!ok) throw new Error(what);
}

Deno.test("USDC: the full journey list needs 130 USDC (§18.4's ≈ 114.9 times 1.13), and less as journeys are skipped (V6)", () => {
  const needs = usdcNeeds(JOURNEYS, SPEC_TERMS);
  const sum = Object.values(needs).reduce((a, b) => a + (b ?? 0n), 0n);
  assertTest(sum > 1_145_000_000n && sum < 1_152_000_000n, `the needs sum to ${units(sum)}, §18.4 says ≈ 114.9`);
  const full = usdcToAcquire(JOURNEYS, SPEC_TERMS);
  assertTest(full >= 129n * ONE && full <= 131n * ONE, `the full list acquires ${units(full)} USDC, not 130 ± 1`);
  assertTest(full === 130n * ONE, `the full list acquires ${units(full)} USDC`);
  const noFailing = usdcToAcquire(JOURNEYS.filter((j) => !(FAILING_MOMENTS as readonly string[]).includes(j)), SPEC_TERMS);
  const noLaunch = usdcToAcquire(JOURNEYS.filter((j) => j !== "launch"), SPEC_TERMS);
  const momentOnly = usdcToAcquire(["moment"], SPEC_TERMS);
  assertTest(noFailing < full && noLaunch < full && momentOnly < noFailing, `skipping shrinks it: ${units(noFailing)}, ${units(noLaunch)}, ${units(momentOnly)}`);
  assertTest(momentOnly === 17n * ONE, `the main Moment alone: (13.3333334 + 1.5) × 1.13 → ${units(momentOnly)}`);
  assertTest(usdcToAcquire(["fallback", "governance", "rescueAdmin"], SPEC_TERMS) === 0n, "XLM journeys need no USDC");
});

Deno.test("USDC: the depth check passes within 3% of the 1-XLM rate and stops the USDC journeys cleanly otherwise (F10)", async () => {
  const need = 130n * ONE;
  // 1 XLM → 0.25 USDC; a pool that gives `avg` of that rate on the full sale.
  const pool = (avgPct: bigint) => (sell: bigint) => Promise.resolve(sell === ONE ? 2_500_000n : (sell * 2_500_000n * avgPct) / (ONE * 100n));
  const deep = await checkDepth(pool(98n), need);
  assertTest(deep.ok && deep.reason === null && deep.out >= need, `2% off the 1-XLM rate passes: ${JSON.stringify(deep, (_k, v) => (typeof v === "bigint" ? String(v) : v))}`);
  assertTest(deep.sell === (need * ONE * 100n + 2_500_000n * 97n - 1n) / (2_500_000n * 97n), "it sells what buys the need at 97% of the 1-XLM rate");
  const thin = await checkDepth(pool(96n), need);
  assertTest(!thin.ok && thin.out < need && (thin.reason ?? "").includes("quotes"), `4% off fails: ${thin.reason}`);
  const dry = await checkDepth(() => Promise.resolve(0n), need);
  assertTest(!dry.ok && dry.reason === "1 XLM quotes no USDC", `no liquidity fails: ${dry.reason}`);
  const down = await checkDepth(() => Promise.reject(new Error("503")), need);
  assertTest(!down.ok && (down.reason ?? "").startsWith("the route didn't quote"), `a route that doesn't answer fails: ${down.reason}`);

  const stop = afterDepth(JOURNEYS, thin);
  assertTest(stop.stopped.length === USDC_JOURNEYS.length && stop.stopped.every((j) => USDC_JOURNEYS.includes(j)), `the USDC journeys stop: ${stop.stopped}`);
  assertTest(stop.run.length === JOURNEYS.length - USDC_JOURNEYS.length && !stop.run.some((j) => USDC_JOURNEYS.includes(j)), `the XLM ones run: ${stop.run}`);
  assertTest((stop.message ?? "").startsWith(THIN), `with the clear message: ${stop.message}`);
  const go = afterDepth(JOURNEYS, deep);
  assertTest(go.run.length === JOURNEYS.length && go.stopped.length === 0 && go.message === null, "a deep route runs everything");
});

Deno.test("USDC: the depth check holds each venue to its own 1-XLM rate, and a thin pool with the best rate hides no deep route (F10)", async () => {
  const need = 69n * ONE;
  // testnet on 2026-10-16: Soroswap's XLM/USDC pool quotes 4.03 USDC for 1 XLM but ~94% of that on the full sale; SDEX
  // quotes 0.89 flat.
  const soroswap = (sell: bigint) => sell === ONE ? 40_271_591n : (sell * 40_271_591n * 94n) / (ONE * 100n);
  const sdex = (sell: bigint) => (sell * 8_924_080n) / ONE;
  const both = (sell: bigint) => Promise.resolve({ soroswap: soroswap(sell), sdex: sdex(sell) });
  const d = await checkDepthByVenue(both, need);
  assertTest(d.ok && d.venue === "sdex" && d.rate1 === 8_924_080n && d.out >= need, `the deep venue passes on its own rate: ${d.venue} ${d.reason}`);
  // The best route alone, as the check read it before: too thin.
  assertTest(!(await checkDepth((s) => Promise.resolve(soroswap(s)), need)).ok, "the thin pool alone fails");
  // Both thin: no venue passes, and the reason names each one.
  const thin = await checkDepthByVenue((s) => Promise.resolve({ soroswap: soroswap(s), sdex: s === ONE ? 8_924_080n : (sdex(s) * 90n) / 100n }), need);
  assertTest(!thin.ok && thin.venue === null && (thin.reason ?? "").includes("soroswap:") && (thin.reason ?? "").includes("sdex:"), `no venue passes: ${thin.reason}`);
  assertTest(afterDepth(["launch", "fallback"], thin).stopped.join() === "launch", "and the USDC journeys stop");
  // A venue isn't held to another's rate: SDEX's flat 0.89 doesn't pass against Soroswap's 4.03 (it is checked alone).
  const sdexAt4 = await checkDepth((s) => Promise.resolve(s === ONE ? 40_271_591n : sdex(s)), need);
  assertTest(!sdexAt4.ok, "a deep route quoted against another venue's 1-XLM rate fails");
  const none = await checkDepthByVenue(() => Promise.resolve({ soroswap: 0n }), need);
  assertTest(!none.ok && none.reason === "1 XLM quotes no USDC", `no route: ${none.reason}`);
  const down = await checkDepthByVenue(() => Promise.reject(new Error("503")), need);
  assertTest(!down.ok && (down.reason ?? "").startsWith("the route didn't quote"), `a quote that doesn't answer: ${down.reason}`);
});

Deno.test("the run refuses every deployment but testnet-qa, and any API but a local stack", () => {
  const env = (vars: Record<string, string>) => (n: string) => vars[n];
  const local = "http://127.0.0.1:8200/lite";
  for (const deployment of [undefined, "testnet", "mainnet", "testnet-qa ", "TESTNET-QA"]) {
    const why = deploymentRefusal(env({ ...(deployment === undefined ? {} : { LITE_DEPLOYMENT: deployment }), LITE_API: local }));
    assertTest(why !== null && why.includes("testnet-qa only"), `LITE_DEPLOYMENT=${deployment} is refused: ${why}`);
  }
  assertTest(deploymentRefusal(env({ LITE_DEPLOYMENT: "testnet-qa", LITE_API: local })) === null, "testnet-qa on a local stack runs");
  assertTest(deploymentRefusal(env({ LITE_DEPLOYMENT: "testnet-qa", LITE_API: "http://localhost:8200/lite" })) === null, "localhost runs");
  for (const api of ["https://xyz.supabase.co/functions/v1/lite", "not a url", ""]) {
    assertTest(deploymentRefusal(env({ LITE_DEPLOYMENT: "testnet-qa", LITE_API: api })) !== null, `LITE_API=${api} is refused`);
  }
});

Deno.test("the run writes invites and keeper_skip rows to a local stack's database only, and never prints LITE_DB_URL", () => {
  const env = (vars: Record<string, string>) => (n: string) => vars[n];
  const run = (db?: string) => deploymentRefusal(env({ LITE_DEPLOYMENT: "testnet-qa", LITE_API: "http://127.0.0.1:8200/lite", ...(db === undefined ? {} : { LITE_DB_URL: db }) }));
  assertTest(run() === null, "without LITE_DB_URL the stack's own database (on loopback) is used");
  assertTest(run("") === null, "an empty LITE_DB_URL is unset");
  for (const db of ["postgresql://lite_api@127.0.0.1:8202/lite", "postgresql://postgres:pw@localhost:8202/postgres", "postgres://u@[::1]:8202/lite"]) {
    assertTest(run(db) === null, `${db.replace(/:[^:@/]*@/, ":…@")} is local`);
  }
  const secret = "s3cr3t-pa55";
  for (const db of [`postgresql://postgres.abcdefghij:${secret}@aws-0-eu-central-1.pooler.supabase.com:6543/postgres`, `postgresql://postgres:${secret}@db.abcdefghij.supabase.co:5432/postgres`]) {
    const why = run(db);
    assertTest(why !== null && why.includes("local stack's database only"), `a hosted database is refused: ${why}`);
    assertTest(!why!.includes(secret), "the refusal doesn't print the URL's password");
  }
  const garbled = run(`not a url ${secret}`);
  assertTest(garbled === "LITE_DB_URL isn't a URL", `a LITE_DB_URL that isn't a URL is refused without printing it: ${garbled}`);
  assertTest(run("postgresql:///lite?host=/tmp") !== null, "a URL without a host is refused");
});

Deno.test("no contract id is written in this script: every one comes from the deployment file, /v1/economics or /v1/config (F8)", async () => {
  const source = await Deno.readTextFile(new URL(import.meta.url));
  const ids = source.match(/\bC[A-Z2-7]{55}\b/g) ?? [];
  assertTest(ids.length === 0, `contract ids in the source: ${ids.join(", ")}`);
});
