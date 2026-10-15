// Deploys the DyorHQ v2 contracts (docs/DESIGN-stellar-contracts-v2.md §3.4, §14, §16, §17) and writes
// backend/supabase/functions/_shared/deployments/<name>-v2.json.
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts-v2.ts \
//     --deployment testnet|testnet-qa [--dry-run [--offline]] [--aquarius off|auto] [--fund-aqua-float] [--generation n]
//   ... --deployment testnet-qa --smoke [--dry-run [--offline]]
//
// --aquarius is off by default (owner decision O7, 2026-10-15: v2 launches on Soroswap only): no exec-aquarius is
//   uploaded, deployed or required in the reviewed list, and there is no Aquarius venue. --aquarius auto brings the
//   Aquarius path back (CT-03's gate, the AQUA float); --fund-aqua-float needs it.
// --smoke (testnet-qa only, O3) runs lib/smoke-v2.ts against deployments/testnet-qa-v2.json with the QA keys: one
//   launch through graduation, a harvest and both claims, one Moment through graduation and the first vest claims.
//
// --deployment testnet is the owner's (decision O5): roles from the roles file (lib/owner-files.ts), the deploy key is
//   DEPLOYER_SECRET from the environment when it is set, else ADMIN_SECRET from the keys file, and it must be
//   ADMIN_PUBLIC's key: the admin deploys and signs every admin call of the deploy (lead decision L-b).
// --deployment testnet-qa uses throwaway keys generated into testnet-qa-v2.env in the secrets directory (O3).
// Every other name, mainnet included, is refused (O4).
//
// In order: the reviewed-hash gate (F13) and the constructor guard (L-d) before anything touches the network; the
// testnet-qa accounts, QA asset and trustlines; the preflight (L-e); the Aquarius decision and AQUA float (V8, ruling
// a); the planned ids (L-c) and the re-run check; uploads; the executors, the locker, the graduator, launchpad-v2 and
// moments-v2 (§3.4); the wiring read-back (lib/wiring-v2.ts: every contract at its planned id, then the executors,
// the factory and the locker read back with views, refused on any mismatch); the admin's configuration with venue
// ids read back from venues() (F8); 75 days of TTL (past the 2026-12-16 testnet reset) for every instance and WASM
// and for the Soroswap factory's instance, factory WASM and pair WASM (L-g); the deployment file; the next steps (L-h). A dry run prints the plan
// and sends nothing; --offline also skips the read-only network checks. A run that failed halfway can be run again:
// what is already on chain and matches the plan is skipped, and anything that differs is refused.
import { Buffer } from "node:buffer";
import { Address, Asset, Keypair, nativeToScVal, Operation, scValToNative } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
import {
  acquireAqua,
  afterFailedFunding,
  type AquaPlan,
  aquaBalance,
  aquariusLiveCheck,
  type AquariusFixtures,
  depthCheck,
  floatOf,
  fundFloat,
  type LiveCheck,
  loadAquariusFixtures,
  planAquarius,
  routerEstimate,
  routerPayment,
} from "./lib/aqua-float.ts";
import { planIds, type PlannedId, reconcile, type Reconciled, saltFor, sacIdFor } from "./lib/contract-ids.ts";
import {
  consoleIo,
  createQaKeys,
  type Io,
  loadKeysFile,
  loadQaKeys,
  loadRolesFile,
  type QaKeyName,
  refuseRoleEnv,
  repoRoot,
  requireRoles,
  ROLES_FILE,
  KEYS_FILE,
  QA_KEYS_FILE,
  secretFromEnv,
  secretsDir,
} from "./lib/owner-files.ts";
import {
  allNeededPass,
  type Chain,
  type CheckLine,
  createContract,
  fmtUnits,
  fmtXlm,
  invoke,
  MIN_DEPLOYER_XLM,
  MIN_DEPLOYER_XLM_FLOAT,
  preflight,
  type ChainReader,
  readOnlyChain,
  renderCheck,
  send,
  STROOPS_PER_XLM,
  testnetChain,
  type TxOutcome,
  uploadWasm,
} from "./lib/preflight-v2.ts";
import { checkReviewed, describeReviewed, type HashCheck, REVIEWED_FILE, sha256Hex } from "./lib/reviewed-hashes.ts";
import {
  type ConstructorPlan,
  constructors,
  type Ctor,
  describeCtor,
  type EconomicsV2,
  encodeArgs,
  initialVenues,
  launchpadCalls,
  parseEconomics,
  plannedContracts,
  readLaunchpadState,
  readVenues,
  RUNTIME_CONSTRUCTORS,
  SINGLETON_WASM,
  type WasmKey,
  WASMS,
} from "./lib/v2-constructors.ts";
import {
  checkDurations,
  guard,
  profileFor,
  type SingletonName,
  singletonsFor,
  type V2Profile,
  type V2Roles,
} from "./lib/v2-profile.ts";
import { constructorGuard, type GuardResult } from "./lib/wasm-spec.ts";
import { runSmoke, type SmokeDeployment, SmokeError } from "./lib/smoke-v2.ts";
import { CODE_STEP_DAYS, extendTtl } from "./lib/ttl-extend.ts";
import { describeWiringCheck, readBackWiring, renderWiringRow, wiringChecks, type WiringPlan, wiringProblems } from "./lib/wiring-v2.ts";

export const USAGE =
  "usage: deploy-contracts-v2.ts --deployment testnet|testnet-qa [--dry-run [--offline]] [--aquarius off|auto] [--fund-aqua-float] [--generation n]\n" +
  "       deploy-contracts-v2.ts --deployment testnet-qa --smoke [--dry-run [--offline]]\n" +
  "       --aquarius is off by default (owner decision O7: Soroswap only); --fund-aqua-float needs --aquarius auto";

export interface DeployOptions {
  deployment: string;
  dryRun: boolean;
  offline: boolean;
  /** off by default (O7). */
  aquarius: "auto" | "off";
  fundAquaFloat: boolean;
  generation: number;
  /** testnet-qa's contract smoke instead of a deploy. */
  smoke: boolean;
}

export function parseArgs(args: string[]): DeployOptions {
  const o: DeployOptions = { deployment: "", dryRun: false, offline: false, aquarius: "off", fundAquaFloat: false, generation: 1, smoke: false };
  let aquariusGiven = false;
  let generationGiven = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const value = () => {
      const v = args[++i];
      if (v === undefined || v.startsWith("--")) throw new Error(`${a} needs a value\n${USAGE}`);
      return v;
    };
    if (a === "--deployment") o.deployment = value();
    else if (a === "--dry-run") o.dryRun = true;
    else if (a === "--offline") o.offline = true;
    else if (a === "--fund-aqua-float") o.fundAquaFloat = true;
    else if (a === "--smoke") o.smoke = true;
    else if (a === "--aquarius") {
      const v = value();
      if (v !== "auto" && v !== "off") throw new Error(`--aquarius is off or auto\n${USAGE}`);
      o.aquarius = v;
      aquariusGiven = true;
    } else if (a === "--generation") {
      const v = value();
      if (!/^[1-9]\d{0,5}$/.test(v)) throw new Error(`--generation is a whole number from 1\n${USAGE}`);
      o.generation = Number(v);
      generationGiven = true;
    } else throw new Error(`unknown argument ${a}\n${USAGE}`);
  }
  if (!o.deployment) throw new Error(USAGE);
  if (o.offline && !o.dryRun) throw new Error("--offline goes with --dry-run only");
  if (o.smoke && (aquariusGiven || o.fundAquaFloat || generationGiven)) {
    throw new Error("--smoke runs against the deployment file: it takes only --dry-run [--offline]");
  }
  if (o.fundAquaFloat && o.aquarius === "off") {
    throw new Error(aquariusGiven ? "--fund-aqua-float and --aquarius off contradict each other" : "--fund-aqua-float needs --aquarius auto (the default is off, owner decision O7)");
  }
  return o;
}

export interface DeployCtx {
  io: Io;
  env: (name: string) => string | undefined;
  secretsDir: string;
  /** The repository root, with a trailing slash. */
  root: string;
  /** Where the deployment file is written. */
  deploymentsDir: string;
  /** The network; null when offline. */
  chain: Chain | null;
  /** Extends every given instance and WASM with less than TTL_THRESHOLD_DAYS left to TTL_EXTEND_DAYS, paid by `payer`
   *  (lib/ttl-extend.ts: each WASM alone, in steps a transaction's fee can pay). */
  keepAlive(contracts: string[], codeHashes: string[], payer: Keypair, label?: (key: string) => string): Promise<{ extended: number; fee: string }>;
  now(): Date;
  /** The smoke's waits; real time by default. */
  sleep?(ms: number): Promise<void>;
  /** The smoke's throwaway accounts; Keypair.random by default. */
  newKey?(): Keypair;
}

export function realCtx(): DeployCtx {
  const env = (n: string) => Deno.env.get(n);
  const root = repoRoot();
  const io = consoleIo();
  const chain = testnetChain({
    rpcUrl: env("STELLAR_RPC_URL")?.trim() || TESTNET.rpcUrl,
    horizonUrl: TESTNET.horizonUrl,
    friendbotUrl: TESTNET.friendbotUrl!,
  });
  return {
    io,
    env,
    secretsDir: secretsDir(env),
    root,
    deploymentsDir: `${root}backend/supabase/functions/_shared/deployments`,
    chain,
    keepAlive: async (contracts, hashes, payer, label) => {
      const r = await extendTtl(chain, payer, contracts, hashes, TTL_EXTEND_DAYS, TTL_THRESHOLD_DAYS, (l) => io.out(`    ${l}`), label);
      return { extended: r.extended, fee: r.fee.toString() };
    },
    now: () => new Date(),
  };
}

// ------------------------------------------------------------------------------------------------ keys

interface Keys {
  roles: V2Roles;
  /** Where the roles came from (printed). */
  rolesFrom: string;
  /** The deployer's address (ADMIN_PUBLIC on testnet). */
  deployer: string;
  /** Signs the deploy; null in a dry run without a key. */
  deployKey: Keypair | null;
  deployKeyFrom: string;
  /** Signs the admin calls (the deploy key on testnet, L-b). */
  adminKey: Keypair | null;
  /** testnet-qa only. */
  qa: Record<QaKeyName, Keypair> | null;
  /** testnet-qa: the keys exist only in memory (a dry run before the first real run). */
  qaEphemeral: boolean;
}

async function ownerKeys(ctx: DeployCtx, dryRun: boolean): Promise<Keys> {
  refuseRoleEnv(ctx.env);
  const rolesFile = await loadRolesFile(ctx.secretsDir);
  const rolesPath = `${ctx.secretsDir}/${ROLES_FILE}`;
  if (!rolesFile) throw new Error(`no roles file at ${rolesPath}: run owner-v2.ts keys first`);
  const roles = requireRoles(rolesFile);
  const keysFile = await loadKeysFile(ctx.secretsDir);
  const fromEnv = secretFromEnv(ctx.env, "DEPLOYER_SECRET");
  const deployKey = fromEnv ?? keysFile?.keys.ADMIN_SECRET ?? null;
  const deployKeyFrom = fromEnv ? "DEPLOYER_SECRET from the environment" : keysFile?.keys.ADMIN_SECRET ? `ADMIN_SECRET from ${KEYS_FILE}` : "none";
  if (deployKey && deployKey.publicKey() !== roles.ADMIN_PUBLIC) {
    throw new Error(`the deploy key (${deployKeyFrom}) is ${deployKey.publicKey()}, not ADMIN_PUBLIC ${roles.ADMIN_PUBLIC}: the admin deploys (L-b)`);
  }
  if (!deployKey && !dryRun) {
    throw new Error(`no deploy key: set DEPLOYER_SECRET (read -rs DEPLOYER_SECRET && export DEPLOYER_SECRET) to ADMIN_PUBLIC's key, or keep ADMIN_SECRET in ${KEYS_FILE}`);
  }
  return { roles, rolesFrom: rolesPath, deployer: roles.ADMIN_PUBLIC, deployKey, deployKeyFrom, adminKey: deployKey, qa: null, qaEphemeral: false };
}

async function qaKeys(ctx: DeployCtx, dryRun: boolean): Promise<Keys> {
  refuseRoleEnv(ctx.env);
  if (ctx.env("DEPLOYER_SECRET")) throw new Error("testnet-qa deploys with its own throwaway keys: unset DEPLOYER_SECRET");
  let qa = await loadQaKeys(ctx.secretsDir);
  let ephemeral = false;
  if (!qa) {
    if (dryRun) {
      qa = Object.fromEntries(
        (["DEPLOYER_SECRET", "ADMIN_SECRET", "LAUNCHPAD_GUARDIAN_SECRET", "GOVERNANCE_SECRET", "MOMENTS_GUARDIAN_SECRET", "TREASURY_SECRET", "QA_ISSUER_SECRET", "QA_ADMIN_SECRET"] as QaKeyName[])
          .map((n) => [n, Keypair.random()]),
      ) as Record<QaKeyName, Keypair>;
      ephemeral = true;
    } else {
      qa = await createQaKeys(ctx.secretsDir);
      ctx.io.out(`generated testnet-qa's throwaway keys into ${ctx.secretsDir}/${QA_KEYS_FILE} (mode 600)`);
    }
  }
  const roles: V2Roles = {
    ADMIN_PUBLIC: qa.ADMIN_SECRET.publicKey(),
    GOVERNANCE_PUBLIC: qa.GOVERNANCE_SECRET.publicKey(),
    LAUNCHPAD_GUARDIAN_PUBLIC: qa.LAUNCHPAD_GUARDIAN_SECRET.publicKey(),
    MOMENTS_GUARDIAN_PUBLIC: qa.MOMENTS_GUARDIAN_SECRET.publicKey(),
    TREASURY_PUBLIC: qa.TREASURY_SECRET.publicKey(),
    PLATFORM_PUBLIC: qa.TREASURY_SECRET.publicKey(),
  };
  return {
    roles,
    rolesFrom: ephemeral ? "throwaway keys made for this dry run only" : `${ctx.secretsDir}/${QA_KEYS_FILE}`,
    deployer: qa.DEPLOYER_SECRET.publicKey(),
    deployKey: qa.DEPLOYER_SECRET,
    deployKeyFrom: `DEPLOYER_SECRET from ${QA_KEYS_FILE}`,
    adminKey: qa.ADMIN_SECRET,
    qa,
    qaEphemeral: ephemeral,
  };
}

// ------------------------------------------------------------------------------------------------ the plan

/** The TTL step (L-g) extends every v2 instance and WASM, and the Soroswap factory's instance and the factory and pair
 *  WASMs, to 75 days: every entry with less than 75 days left (the Soroswap ones have more today, so they are
 *  skipped). Testnet resets on 2026-12-16 (docs/ARCHITECTURE.md), 62 days after 2026-10-15: longer buys nothing.
 *  Testnet's max_entry_ttl (CONFIG_SETTING_STATE_ARCHIVAL, read 2026-10-15) is 3,110,400 ledgers, 180 days. A
 *  transaction's fee is at most 429 XLM, so each WASM goes alone in steps of CODE_STEP_DAYS (lib/ttl-extend.ts). The
 *  rent is paid by the deployer: at most 24 XLM a day for testnet's ~320 KB of v2 WASM at the 2026-10-15 rates, so
 *  about 1,630 XLM on the first run (MIN_DEPLOYER_XLM covers it with the uploads). Per-launch tokens, Moment NFTs and
 *  coins start at the network minimum (7 days): the keeper's TTL upkeep keeps them alive. */
export const TTL_EXTEND_DAYS = 75;
export const TTL_THRESHOLD_DAYS = 75;
/** 75 days of ledgers (17,280 a day): the read-back's target past the ledger before the extension. */
export const TTL_EXTEND_LEDGERS = TTL_EXTEND_DAYS * 17_280;
/** Testnet's max_entry_ttl as read on 2026-10-15; TTL_EXTEND_LEDGERS must stay under it (a test checks). */
export const TESTNET_MAX_ENTRY_TTL = 3_110_400;

const CAMEL: Record<SingletonName, string> = {
  "exec-soroswap": "execSoroswap",
  "exec-aquarius": "execAquarius",
  "qa-exec-fail": "qaExecFail",
  "lp-locker": "lpLocker",
  "moments-graduator": "momentsGraduator",
  "launchpad-v2": "launchpadV2",
  "moments-v2": "momentsV2",
  "moments-graduator-qa-fail": "momentsGraduatorQaFail",
  "moments-v2-qa-fail": "momentsV2QaFail",
};

const WASM_CAMEL: Record<WasmKey, string> = {
  "launchpad-v2": "launchpadV2",
  "launch-token-v2": "launchTokenV2",
  "exec-soroswap": "execSoroswap",
  "exec-aquarius": "execAquarius",
  "qa-exec-fail": "qaExecFail",
  "lp-locker": "lpLocker",
  "moments-v2": "momentsV2",
  "moment-nft": "momentNft",
  "moment-coin": "momentCoin",
  "moments-graduator": "momentsGraduator",
};

/** The WASMs a deployment uploads. */
export function wasmsFor(profile: V2Profile, aquarius: boolean): WasmKey[] {
  return (Object.keys(WASMS) as WasmKey[]).filter((k) => (k === "exec-aquarius" ? aquarius : k === "qa-exec-fail" ? profile.qaExecFail : true));
}

interface Wasm {
  key: WasmKey;
  bytes: Uint8Array | null;
  sha256: string | null;
}

async function readWasms(root: string, keys: WasmKey[]): Promise<Wasm[]> {
  const out: Wasm[] = [];
  for (const key of keys) {
    let bytes: Uint8Array | null = null;
    try {
      bytes = await Deno.readFile(`${root}contracts/dist/${WASMS[key].file}`);
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    }
    out.push({ key, bytes, sha256: bytes ? await sha256Hex(bytes) : null });
  }
  return out;
}

interface GuardRow {
  wasm: WasmKey;
  result: GuardResult | null; // null: the WASM is absent from dist
}

function guardAll(wasms: Wasm[], ctors: Ctor[]): GuardRow[] {
  const byWasm = new Map<WasmKey, Ctor>();
  for (const c of ctors) if (!byWasm.has(c.wasm)) byWasm.set(c.wasm, c);
  return wasms.map((w) => {
    const params = byWasm.get(w.key)?.params ?? RUNTIME_CONSTRUCTORS[w.key as keyof typeof RUNTIME_CONSTRUCTORS];
    if (!params) return { wasm: w.key, result: { ok: false, actual: null, differences: ["no builder for this WASM"] } };
    return { wasm: w.key, result: w.bytes ? constructorGuard(w.bytes, params) : null };
  });
}

export interface Plan {
  opts: DeployOptions;
  profile: V2Profile;
  economics: EconomicsV2;
  fixtures: AquariusFixtures;
  keys: Keys;
  aqua: AquaPlan;
  wasms: Wasm[];
  reviewed: HashCheck;
  ids: Map<string, PlannedId>;
  ctors: Ctor[];
  guards: GuardRow[];
  constructorPlan: ConstructorPlan;
  qaAsset: { code: string; issuer: string; classic: string; sac: string } | null;
}

function network() {
  const xlm = TESTNET.assets.find((a) => a.id === "XLM")!;
  const usdc = TESTNET.assets.find((a) => a.id === "USDC")!;
  return {
    xlmSac: xlm.contract,
    usdcSac: usdc.contract,
    usdcClassic: usdc.classic!,
    soroswapFactory: TESTNET.contracts.soroswapFactory,
    aquariusRouter: TESTNET.contracts.aquariusRouter!,
  };
}

/** Everything that doesn't need the network: ids, constructors, the hash check and the guard. */
async function buildPlan(opts: DeployOptions, profile: V2Profile, economics: EconomicsV2, fixtures: AquariusFixtures, keys: Keys, aqua: AquaPlan, root: string): Promise<Plan> {
  const net = network();
  const names = singletonsFor(profile, aqua.enabled);
  const ids = planIds(profile.name, opts.generation, keys.deployer, TESTNET.passphrase, names);
  const wasms = await readWasms(root, wasmsFor(profile, aqua.enabled));
  let reviewedText: string | null = null;
  try {
    reviewedText = await Deno.readTextFile(`${root}${REVIEWED_FILE}`);
  } catch (e) {
    if (!(e instanceof Deno.errors.NotFound)) throw e;
  }
  const reviewed = checkReviewed(profile.name, reviewedText, wasms.map((w) => ({ file: WASMS[w.key].file, sha256: w.sha256 })));
  const qaAsset = profile.qaExecFail && keys.qa
    ? (() => {
      const code = economics.qaAsset?.code ?? "DYORQA";
      const issuer = keys.qa!.QA_ISSUER_SECRET.publicKey();
      const classic = `${code}:${issuer}`;
      return { code, issuer, classic, sac: sacIdFor(classic, TESTNET.passphrase) };
    })()
    : null;
  const constructorPlan: ConstructorPlan = {
    profile,
    roles: keys.roles,
    ids: Object.fromEntries([...ids.values()].map((p) => [p.name, p.id])) as Partial<Record<SingletonName, string>>,
    wasmHashes: Object.fromEntries(wasms.filter((w) => w.sha256).map((w) => [w.key, w.sha256])) as Partial<Record<WasmKey, string>>,
    network: net,
    economics,
    aquarius: { enabled: aqua.enabled, paymentAsset: fixtures.aqua.sac },
    qaAdmin: keys.qa?.QA_ADMIN_SECRET.publicKey(),
  };
  const ctors = constructors(constructorPlan);
  checkDurations(profile, argOf(ctors, "launchpad-v2", "durations") as never, argOf(ctors, "moments-v2", "durations") as never);
  const guards = guardAll(wasms, ctors);
  return { opts, profile, economics, fixtures, keys, aqua, wasms, reviewed, ids, ctors, guards, constructorPlan, qaAsset };
}

/** A constructor argument by contract and parameter name. */
function argOf(ctors: Ctor[], contract: SingletonName, name: string): unknown {
  const c = ctors.find((x) => x.contract === contract);
  const i = c?.params.findIndex((p) => p.name === name) ?? -1;
  if (!c || i < 0) throw new Error(`${contract} has no constructor parameter ${name}`);
  return c.values[i];
}

function names(plan: Plan): Map<string, string> {
  const m = new Map<string, string>();
  for (const p of plan.ids.values()) m.set(p.id, p.name);
  const roles = new Map<string, string[]>();
  for (const [k, v] of Object.entries(plan.keys.roles)) roles.set(v, [...(roles.get(v) ?? []), k.replace(/_PUBLIC$/, "").toLowerCase().replace(/_/g, " ")]);
  for (const [v, labels] of roles) m.set(v, labels.join(" + "));
  const net = network();
  m.set(net.xlmSac, "XLM SAC");
  m.set(net.usdcSac, "USDC SAC");
  m.set(net.soroswapFactory, "Soroswap factory");
  m.set(net.aquariusRouter, "Aquarius router");
  m.set(plan.fixtures.aqua.sac, "AQUA SAC");
  if (plan.qaAsset) m.set(plan.qaAsset.sac, `${plan.qaAsset.code} SAC`);
  return m;
}

function quoteAssets(plan: Plan): Map<"XLM" | "USDC" | "QA", string> {
  const net = network();
  const m = new Map<"XLM" | "USDC" | "QA", string>([["XLM", net.xlmSac], ["USDC", net.usdcSac]]);
  if (plan.qaAsset) m.set("QA", plan.qaAsset.sac);
  return m;
}

/** Classic quote assets the treasury must trust (F9): USDC, and the QA asset on testnet-qa. */
function treasuryAssets(plan: Plan): string[] {
  const out = [network().usdcClassic];
  if (plan.qaAsset && plan.economics.launchpad.quotes.some((q) => q.asset === "QA" && q.enabled)) out.push(plan.qaAsset.classic);
  return out;
}

const minDeployerXlm = (plan: Plan) => (plan.opts.fundAquaFloat ? MIN_DEPLOYER_XLM_FLOAT : MIN_DEPLOYER_XLM) * STROOPS_PER_XLM;

/** The wiring read-back's inputs: the planned ids and the network's Soroswap factory. */
const wiringPlan = (plan: Plan): WiringPlan => ({ ids: plan.constructorPlan.ids, soroswapFactory: network().soroswapFactory });

function printPlan(io: Io, plan: Plan) {
  const { profile, economics: e, keys } = plan;
  const lp = e.launchpad;
  const say = (l = "") => io.out(l);
  say(`deploy-contracts-v2 · ${profile.name} · generation ${plan.opts.generation}${plan.opts.dryRun ? " · DRY RUN: nothing is sent" : ""}`);
  say();
  say(`Roles (${keys.rolesFrom})`);
  for (const [k, v] of Object.entries(keys.roles)) say(`  ${k.padEnd(26)} ${v}`);
  say(`  ${"deployer".padEnd(26)} ${keys.deployer}`);
  say(`  deploy key: ${keys.deployKey ? `${keys.deployKeyFrom} → ${keys.deployKey.publicKey()}${keys.deployKey.publicKey() === keys.deployer ? " ✓" : ""}` : "none found (a real run needs DEPLOYER_SECRET or the keys file)"}`);
  if (plan.qaAsset) say(`  QA asset ${plan.qaAsset.classic} (SAC ${plan.qaAsset.sac}); qa-exec-fail admin ${keys.qa!.QA_ADMIN_SECRET.publicKey()}`);
  say();
  say(`Economics (backend/scripts/economics/${profile.economicsFile})`);
  say(`  launch fee            ${fmtUnits(BigInt(lp.launchFee))} XLM (${BigInt(lp.launchFee).toLocaleString("en-US")} stroops), booked per launch`);
  say(`  token supply          ${fmtUnits(BigInt(lp.supply))}`);
  say(`  curve fee / protocol share / max creator fee   ${lp.feeBps} / ${lp.protocolShareBps} / ${lp.maxCreatorFeeBps} bps`);
  say(`  snipe schedule        [${lp.snipeSchedule.join(", ")}] bps, ${lp.snipeStepSecs} s steps`);
  for (const q of lp.quotes) {
    const unit = q.asset === "XLM" ? "XLM" : q.asset === "USDC" ? "USDC" : plan.qaAsset?.code ?? "QA";
    say(`  ${`${q.asset} quote`.padEnd(21)} phantom ${fmtUnits(BigInt(q.phantom))} ${unit} → threshold ${fmtUnits(BigInt(q.threshold))} ${unit}` +
      `; venues ${q.venuesAllowed.length ? q.venuesAllowed.join(", ") + " only" : "all enabled"}; fallback ${q.fallback}`);
  }
  say(`  venues                ${lp.venues.filter((v) => v.key !== "aquarius" || plan.aqua.enabled).filter((v) => v.key !== "qa-exec-fail" || profile.qaExecFail).map((v) => `${v.kind}${v.feeFraction ? ` (fee_fraction ${v.feeFraction})` : ""}`).join(", ")}`);
  const m = e.moments.policy;
  say(`  Moments threshold     ${fmtUnits(BigInt(m.threshold))} USDC; min price ${fmtUnits(BigInt(m.minPrice))} USDC; split ${m.creatorBps}/${m.platformBps}/${m.reserveBps}` +
    `; max alloc ${m.maxCreatorAllocBps}; expiry creator ${m.expiryCreatorBps}; royalty ${m.royaltyBps}`);
  say(`  Moments platform / treasury   ${keys.roles.PLATFORM_PUBLIC} / ${keys.roles.TREASURY_PUBLIC}`);
  say(`  Moments external base         ${e.moments.externalBase}`);
  say();
  say(`Durations (${profile.durationSet})`);
  say(`  launch   ${Object.entries(profile.launchDurations).map(([k, v]) => `${k} ${v}`).join(", ")}`);
  say(`  Moments  ${Object.entries(profile.momentsDurations).map(([k, v]) => `${k} ${v}`).join(", ")}`);
  say(`  TTL policy threshold ${profile.ttl.threshold}, extend_to ${profile.ttl.extend_to} ledgers`);
  say();
  const a = plan.aqua;
  say(`Aquarius: ${a.enabled ? "enabled (CT-03 gate: go)" : `disabled (${a.reason})`}`);
  if (a.enabled) {
    say(`  float target ${profile.aquaFloatTargetMultiple} × the pool payment${a.target !== null ? ` = ${fmtUnits(a.target)} AQUA` : ""}; ` +
      `alert below ${profile.aquaFloatAlertMultiple} ×; ${a.swap ? "this run acquires it (XLM → AQUA, at most 2,000 XLM)" : "this run doesn't fund it"}`);
  }
  for (const n of a.notes) say(`  note: ${n}`);
  say();
  say("Reviewed WASM hashes");
  for (const l of describeReviewed(plan.reviewed)) say(`  ${l}`);
  const absent = plan.wasms.filter((w) => !w.bytes).map((w) => WASMS[w.key].file);
  if (absent.length) say(`  absent from contracts/dist: ${absent.join(", ")}`);
  say();
  say(`Planned contract ids (deployer ${keys.deployer}${keys.qaEphemeral ? ", throwaway dry-run keys: a real run makes its own" : ""})`);
  for (const p of plan.ids.values()) say(`  ${p.name.padEnd(26)} ${p.id}  salt sha256("${p.salt}")`);
  say();
  say("Constructor arguments");
  const n = names(plan);
  for (const c of plan.ctors) for (const l of describeCtor(c, n)) say(l);
  say();
  say("Constructor guard (contractspecv0 against the builders)");
  for (const g of plan.guards) {
    const file = WASMS[g.wasm].file;
    if (!g.result) say(`  – ${file}: absent from dist, not compared`);
    else if (g.result.ok) say(`  ✓ ${file}: __constructor${g.result.actual}`);
    else {
      say(`  ✗ ${file}: differs from the builder`);
      for (const d of g.result.differences) say(`      ${d}`);
    }
  }
  say();
  say("After the constructors, before anything else is sent: the wiring read-back (views by simulation, no transaction)");
  say("  every planned contract must be at its planned id with the planned configuration (the re-run check), then:");
  for (const c of wiringChecks(wiringPlan(plan))) say(`    ${describeWiringCheck(c)}`);
  say("  any mismatch stops the run there: no admin call, no TTL step and no deployment file");
  say();
  say("After the constructors, signed by the admin");
  say(`  set_quote for ${lp.quotes.map((q) => q.asset).join(", ")}, with venue ids read back from venues() (F8)`);
  say("  set_launch_fee, set_fees and set_venue_enabled only where the chain differs from the economics file (the");
  say("  constructor already takes the launch fee, starts at §14.1's fees and enables every initial venue)");
  say(`  then every v2 instance and WASM, and the Soroswap factory's instance and its factory and pair WASMs, are extended`);
  say(`  to ${TTL_EXTEND_DAYS} days (past the 2026-12-16 testnet reset) where they have less, paid by the deployer: about 1,650 XLM`);
  say(`  of rent on the first run, each WASM alone in ${CODE_STEP_DAYS}-day steps (a transaction's fee is at most 429 XLM): 25 to 30`);
  say("  transactions");
  say(`  and backend/supabase/functions/_shared/deployments/${profile.deploymentFile} is written`);
}

// ------------------------------------------------------------------------------------------------ main

export async function main(args: string[], ctx: DeployCtx): Promise<number> {
  const io = ctx.io;
  try {
    const opts = parseArgs(args);
    const profile = profileFor(opts.deployment);
    // SMOKE=1 asks for the smoke as --smoke does; both are testnet-qa only (O3).
    const smoke = opts.smoke || ctx.env("SMOKE") === "1";
    guard(profile, { durations: profile.durationSet, qaExecFail: profile.qaExecFail, failingMomentsStack: profile.failingMomentsStack, keyGeneration: profile.keyGeneration, smoke });
    if (smoke && !opts.smoke) throw new Error("SMOKE=1 is set: run the smoke with --smoke, or unset SMOKE for this deploy");
    const net = ctx.env("LITE_NETWORK");
    if (net && net !== "testnet") throw new Error(`LITE_NETWORK is ${net}: v2 deploys to testnet only (unset it)`);
    // The functions' network settings (_shared) stay on testnet's own deployment while this runs.
    const liteDeployment = ctx.env("LITE_DEPLOYMENT");
    if (liteDeployment && liteDeployment !== "testnet") throw new Error(`LITE_DEPLOYMENT is ${liteDeployment}: unset it for this script`);
    if (opts.fundAquaFloat && profile.name !== "testnet") throw new Error("--fund-aqua-float is for the owner's testnet; testnet-qa acquires its float with --aquarius auto");
    if (opts.smoke) return await smokeMain(ctx, opts);
    const economics = parseEconomics(JSON.parse(await Deno.readTextFile(`${ctx.root}backend/scripts/economics/${profile.economicsFile}`)), profile);
    const fixtures = await loadAquariusFixtures(ctx.root);
    if (fixtures.router !== network().aquariusRouter) throw new Error("networks.ts and fixtures.json name different Aquarius routers");
    const keys = profile.name === "testnet" ? await ownerKeys(ctx, opts.dryRun) : await qaKeys(ctx, opts.dryRun);

    const chain = opts.offline ? null : ctx.chain;
    if (!opts.offline && !chain) throw new Error("no network: use --dry-run --offline");
    const reader = chain ? (opts.dryRun ? readOnlyChain(chain) : chain) : null;

    // The Aquarius decision first: whether exec-aquarius and the venue are in the plan. With --aquarius off the router
    // is never asked anything, so a router that doesn't answer can't block the deploy.
    let live: LiveCheck | null = null;
    let payment: { asset: string; amount: bigint } | null = null;
    let routerProblem: string | null = null;
    if (reader && opts.aquarius !== "off") {
      try {
        live = await aquariusLiveCheck(reader, fixtures);
        payment = await routerPayment(reader, fixtures);
      } catch (e) {
        routerProblem = `the Aquarius router didn't answer (${(e as Error).message})`;
      }
    }
    if (routerProblem && profile.name === "testnet") throw new Error(`${routerProblem}: try again later, or deploy without the Aquarius venue (--aquarius off)`);
    let aqua: AquaPlan = routerProblem
      ? { enabled: false, reason: routerProblem, swap: false, target: null, notes: [] }
      : planAquarius({
        deployment: profile.name,
        aquarius: opts.aquarius,
        fundAquaFloat: opts.fundAquaFloat,
        swapByDefault: profile.aquaSwapByDefault,
        fixtures,
        live,
        payment,
        targetMultiple: profile.aquaFloatTargetMultiple,
      });
    // A re-run follows what an earlier run of this generation deployed.
    if (reader) {
      const earlier = planIds(profile.name, opts.generation, keys.deployer, TESTNET.passphrase, ["exec-aquarius", "launchpad-v2"]);
      const execThere = (await reader.contractWasmHash(earlier.get("exec-aquarius")!.id)) !== null;
      const padThere = (await reader.contractWasmHash(earlier.get("launchpad-v2")!.id)) !== null;
      if (execThere && !aqua.enabled) {
        throw new Error(`exec-aquarius already exists for generation ${opts.generation} (an earlier run deployed it): keep Aquarius on, or use a new --generation`);
      }
      if (padThere && !execThere && aqua.enabled) {
        aqua = { ...aqua, enabled: false, swap: false, reason: `launchpad-v2 of generation ${opts.generation} was deployed without Aquarius` };
      }
    }

    const plan = await buildPlan(opts, profile, economics, fixtures, keys, aqua, ctx.root);
    printPlan(io, plan);

    if (opts.dryRun) return await dryRunChecks(io, plan, reader);
    return await deploy(ctx, plan, chain!, (a) => buildPlan(opts, profile, economics, fixtures, keys, a, ctx.root));
  } catch (e) {
    io.err(`deploy-contracts-v2: ${(e as Error).message}`);
    return 1;
  }
}

// ------------------------------------------------------------------------------------------------ the smoke

/** --smoke (testnet-qa only; main has run the guard): the contract smoke of lib/smoke-v2.ts against
 *  deployments/testnet-qa-v2.json, with the QA keys the deploy generated. A dry run sends nothing. */
async function smokeMain(ctx: DeployCtx, opts: DeployOptions): Promise<number> {
  const io = ctx.io;
  refuseRoleEnv(ctx.env);
  if (ctx.env("DEPLOYER_SECRET")) throw new Error("the smoke uses testnet-qa's own throwaway keys: unset DEPLOYER_SECRET");
  const qa = await loadQaKeys(ctx.secretsDir);
  if (!qa) throw new Error(`no ${QA_KEYS_FILE} in the secrets directory: run deploy-contracts-v2.ts --deployment testnet-qa first`);
  const path = `${ctx.deploymentsDir}/testnet-qa-v2.json`;
  let deployment: SmokeDeployment;
  try {
    deployment = JSON.parse(await Deno.readTextFile(path));
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) throw new Error(`no ${path}: run deploy-contracts-v2.ts --deployment testnet-qa first`);
    throw e;
  }
  if (opts.offline) {
    io.out(`Smoke · testnet-qa · ${path}`);
    io.out("Network checks: skipped (--offline). Dry run: nothing was sent.");
    return 0;
  }
  if (!ctx.chain) throw new Error("no network: use --dry-run --offline");
  const chain = opts.dryRun ? readOnlyChain(ctx.chain) : ctx.chain;
  const net = network();
  try {
    await runSmoke({
      io,
      chain,
      deployment,
      qa,
      network: { xlmSac: net.xlmSac, usdcSac: net.usdcSac, usdcClassic: net.usdcClassic, soroswapRouter: TESTNET.contracts.soroswapRouter },
      newKey: ctx.newKey ?? (() => Keypair.random()),
      nonce: () => BigInt.asUintN(64, BigInt(`0x${Buffer.from(crypto.getRandomValues(new Uint8Array(8))).toString("hex")}`)),
      sleep: ctx.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))),
      nowSecs: () => Math.floor(ctx.now().getTime() / 1000),
      dryRun: opts.dryRun,
    });
  } catch (e) {
    if (e instanceof SmokeError) {
      io.err(`deploy-contracts-v2: the smoke stopped: ${e.message}`);
      io.err("The transactions printed above were sent; run --smoke again for a fresh launch and Moment.");
      return 1;
    }
    throw e;
  }
  return 0;
}

async function dryRunChecks(io: Io, plan: Plan, reader: Chain | null): Promise<number> {
  const say = (l = "") => io.out(l);
  const blockers: string[] = [];
  if (!plan.reviewed.ok) blockers.push("the reviewed-hash check");
  if (plan.guards.some((g) => g.result && !g.result.ok)) blockers.push("the constructor guard");
  if (plan.wasms.some((w) => !w.bytes)) blockers.push("WASMs absent from contracts/dist");
  if (!plan.keys.deployKey) blockers.push("no deploy key");
  say();
  if (!reader) {
    say("Network checks: skipped (--offline): the preflight, what is already on chain and the wiring read-back");
  } else {
    say("Preflight (read-only)");
    const lines = plan.keys.qaEphemeral ? [] : await preflight({
      chain: reader,
      roles: plan.keys.roles,
      deployer: plan.keys.deployer,
      treasuryAssets: treasuryAssets(plan),
      platformAssets: [network().usdcClassic],
      minDeployerXlm: minDeployerXlm(plan),
      assetNames: assetNames(plan),
    });
    if (plan.keys.qaEphemeral) say("  – testnet-qa's accounts, QA asset and trustlines are created by the real run first");
    for (const l of lines) say(`  ${renderCheck(l)}`);
    if (!allNeededPass(lines)) blockers.push("the preflight");
    if (!plan.aqua.enabled) {
      say(`Aquarius router: not asked (the venue is off: ${plan.aqua.reason})`);
    } else {
      say("Aquarius router against contracts/testdata/fixtures.json (ruling a)");
      try {
        const live = await aquariusLiveCheck(reader, plan.fixtures);
        for (const l of live.lines) say(`  ${l.ok ? "✓" : "✗"} ${l.label}: live ${l.live ?? "unreadable"}, fixture ${l.fixture}`);
        if (plan.aqua.swap) {
          const d = await depthCheck(routerEstimate(reader, plan.fixtures), plan.aqua.target ?? 0n);
          say(`  ${d.ok ? "✓" : "✗"} depth check: 1 XLM → ${fmtUnits(d.rate1)} AQUA; ${fmtUnits(d.spend)} XLM → ${fmtUnits(d.out)} AQUA for a minimum of ${fmtUnits(d.minOut)}${d.reason ? ` (${d.reason})` : ""}`);
        }
      } catch (e) {
        say(`  ✗ the router didn't answer (${(e as Error).message})`);
        blockers.push("the Aquarius router");
      }
    }
    if (plan.wasms.every((w) => w.sha256)) {
      say("Already on chain (a re-run skips what matches and refuses what differs)");
      for (const w of plan.wasms) say(`  ${(await reader.codeExists(w.sha256!)) ? "uploaded" : "to upload"}  ${WASMS[w.key].file}`);
      const rec = await reconcile(plannedContracts(plan.constructorPlan, plan.ctors), reader);
      for (const r of rec) {
        if (r.state === "conflict") blockers.push(`${r.name} differs on chain`);
        say(`  ${r.state === "absent" ? "to deploy" : r.state === "deployed" ? "deployed, matches: skipped" : "✗ differs:"}  ${r.name} ${r.id}`);
        if (r.state === "conflict") for (const d of r.differences) say(`      ${d}`);
      }
      // The wiring read-back can run only once every contract is there (a re-run); otherwise the deploy runs it.
      if (rec.every((r) => r.state === "deployed")) {
        say("Wiring read-back (views, no transaction)");
        const rows = await readBackWiring(wiringPlan(plan), (id, fn, args) => reader.view(id, fn, args));
        for (const r of rows) say(`  ${renderWiringRow(r)}`);
        if (wiringProblems(rows).length) blockers.push("the wiring read-back");
      } else {
        say(`Wiring read-back: runs after the constructors (${wiringChecks(wiringPlan(plan)).length} checks, listed above)`);
      }
    } else {
      say("Already on chain: not checked until every WASM is in contracts/dist");
    }
  }
  say();
  say(blockers.length ? `A real deploy would stop at: ${blockers.join("; ")}.` : "A real deploy would go ahead.");
  say("Dry run: nothing was sent and no file was written.");
  return 0;
}

function assetNames(plan: Plan): Map<string, string> {
  const m = new Map([[network().usdcClassic, "USDC"]]);
  if (plan.qaAsset) m.set(plan.qaAsset.classic, plan.qaAsset.code);
  return m;
}

// ------------------------------------------------------------------------------------------------ the real run

/** Refuses a plan whose WASMs aren't all in dist, don't all match the reviewed list (F13) or fail the constructor
 *  guard (L-d). `checked`, when given, is the plan already checked in this run: every WASM must be the same file it
 *  was then, so a dist that changed during the run is refused too. */
export function requireDeployable(plan: Plan, checked?: Plan): void {
  const absent = plan.wasms.filter((w) => !w.bytes);
  if (absent.length) throw new Error(`absent from contracts/dist: ${absent.map((w) => WASMS[w.key].file).join(", ")} (build with contracts/build.sh); nothing was sent`);
  if (!plan.reviewed.ok) throw new Error(`reviewed-hash check failed; nothing was sent:\n  ${plan.reviewed.problems.join("\n  ")}`);
  const badGuards = plan.guards.filter((g) => !g.result?.ok);
  if (badGuards.length) {
    throw new Error(`constructor guard: ${badGuards.map((g) => `${WASMS[g.wasm].file} (${g.result?.differences.join("; ")})`).join(", ")}; nothing was sent`);
  }
  if (checked) {
    const changed = plan.wasms.filter((w) => {
      const before = checked.wasms.find((x) => x.key === w.key);
      return !before || before.sha256 !== w.sha256;
    });
    if (changed.length) throw new Error(`contracts/dist changed during this run (${changed.map((w) => WASMS[w.key].file).join(", ")}); nothing more was sent`);
  }
}

async function deploy(
  ctx: DeployCtx,
  first: Plan,
  chain: Chain,
  rebuild: (a: AquaPlan) => Promise<Plan>,
): Promise<number> {
  const io = ctx.io;
  const say = (l = "") => io.out(l);
  let plan = first;
  let fees = 0n;
  const done = (what: string, o: TxOutcome | null) => {
    if (!o) return;
    fees += o.feeCharged;
    say(`  ${what}: ${o.hash} (fee ${fmtXlm(o.feeCharged)})`);
  };

  // 1. Nothing is sent before the reviewed-hash gate and the constructor guard pass (and again for a rebuilt plan).
  requireDeployable(plan);
  const deployer = plan.keys.deployKey!;
  const admin = plan.keys.adminKey!;
  // The re-run check (L-c), read-only and before anything is sent: skip what matches, refuse what differs.
  const reconcileOrRefuse = async (p: Plan, sentAlready = false): Promise<Reconciled[]> => {
    const states = await reconcile(plannedContracts(p.constructorPlan, p.ctors), chain);
    const conflicts = states.filter((s) => s.state === "conflict");
    if (conflicts.length) {
      throw new Error(
        `contracts at the planned ids differ from the plan; nothing ${sentAlready ? "more " : ""}was sent (use a new --generation, or fix the inputs):\n  ${
          conflicts.flatMap((c) => (c as { differences: string[] }).differences).join("\n  ")
        }`,
      );
    }
    return states;
  };
  let states = await reconcileOrRefuse(plan);
  say();
  say("Deploying");

  // 2. testnet-qa: its accounts, its asset and the treasury's trustlines (before the preflight, F9).
  if (plan.keys.qa) {
    const qa = plan.keys.qa;
    for (const [name, kp] of Object.entries(qa)) {
      if (!(await chain.account(kp.publicKey()))) {
        await chain.friendbot(kp.publicKey());
        say(`  funded ${name.replace(/_SECRET$/, "").toLowerCase()} ${kp.publicKey()} through Friendbot`);
      }
    }
    const qaAsset = plan.qaAsset!;
    if ((await chain.contractWasmHash(qaAsset.sac)) === null) {
      done(`created the ${qaAsset.code} SAC ${qaAsset.sac}`, await send(chain, deployer, Operation.createStellarAssetContract({ asset: new Asset(qaAsset.code, qaAsset.issuer) })));
    }
    const treasury = qa.TREASURY_SECRET;
    const t = await chain.account(treasury.publicKey());
    for (const classic of treasuryAssets(plan)) {
      if (!t?.trustlines.some((x) => x.asset === classic)) {
        const [code, issuer] = classic.split(":");
        done(`QA treasury trusts ${code}`, await send(chain, treasury, Operation.changeTrust({ asset: new Asset(code, issuer) })));
      }
    }
  }

  // 3. The preflight (L-e).
  const lines: CheckLine[] = await preflight({
    chain,
    roles: plan.keys.roles,
    deployer: plan.keys.deployer,
    treasuryAssets: treasuryAssets(plan),
    platformAssets: [network().usdcClassic],
    minDeployerXlm: minDeployerXlm(plan),
    assetNames: assetNames(plan),
  });
  say("Preflight");
  for (const l of lines) say(`  ${renderCheck(l)}`);
  if (!allNeededPass(lines)) throw new Error("the preflight failed; nothing was deployed (owner-v2.ts check shows the same checks)");
  const startLedger = await chain.latestLedger();

  // 4. The AQUA float, before anything is deployed: the venue table is a launchpad constructor argument (V8).
  let aquaHeld = 0n;
  if (plan.aqua.enabled && plan.aqua.swap) {
    const execId = plan.ids.get("exec-aquarius")!.id;
    const target = plan.aqua.target!;
    const already = (await chain.contractWasmHash(execId)) !== null ? await floatOf(chain, execId) : 0n;
    const held = await aquaBalance(chain, plan.fixtures, deployer.publicKey());
    if (already + held >= target) {
      say(`  AQUA float: ${fmtUnits(already)} at the executor and ${fmtUnits(held)} with the deployer, target ${fmtUnits(target)}: no swap`);
      aquaHeld = held;
    } else {
      const d = await depthCheck(routerEstimate(chain, plan.fixtures), target - already);
      say(`  AQUA depth check: 1 XLM → ${fmtUnits(d.rate1)} AQUA; ${fmtUnits(d.spend)} XLM → ${fmtUnits(d.out)} AQUA (minimum ${fmtUnits(d.minOut)})`);
      let failure: string | null = d.ok ? null : d.reason;
      if (d.ok) {
        try {
          const got = await acquireAqua(chain, deployer, plan.fixtures, d.spend, d.minOut);
          done("deployer trusts AQUA", got.trustline);
          done(`swapped ${fmtUnits(d.spend)} XLM for AQUA`, got.swap);
          aquaHeld = got.held;
        } catch (e) {
          failure = `the swap failed: ${(e as Error).message}`;
        }
      }
      if (failure) {
        const next = afterFailedFunding(plan.aqua, plan.profile.name, failure);
        say(`  AQUA: ${failure}`);
        if (!next.enabled) {
          say("  testnet-qa goes on without exec-aquarius and the Aquarius venue");
          const rebuilt = await rebuild(next);
          // The rebuilt plan read contracts/dist again: the same gate and guard, and the same WASMs as checked above.
          requireDeployable(rebuilt, plan);
          plan = rebuilt;
          states = await reconcileOrRefuse(plan, true);
        } else plan = { ...plan, aqua: next };
      }
    }
  }

  // 5. Uploads, then the constructors in order (§3.4).
  for (const w of plan.wasms) done(`uploaded ${WASMS[w.key].file}`, await uploadWasm(chain, deployer, w.bytes!, w.sha256!));
  for (const c of plan.ctors) {
    const id = plan.ids.get(c.contract)!;
    const state = states.find((s) => s.name === c.contract)!;
    if (state.state === "deployed") {
      say(`  ${c.contract} ${id.id}: already deployed with the planned configuration, skipped`);
      continue;
    }
    const wasm = plan.constructorPlan.wasmHashes[SINGLETON_WASM[c.contract]]!;
    done(`deployed ${c.contract} ${id.id}`, await createContract(chain, deployer, wasm, saltFor(plan.profile.name, plan.opts.generation, c.contract), encodeArgs(c), id.id));
  }

  // 6. The wiring read-back, before anything else is sent: every planned contract at its planned id with the planned
  //    configuration (the re-run check again), then the executors, the factory and the locker read back with views
  //    (simulation, no transaction; lib/wiring-v2.ts). Any mismatch stops the run here: no float, no admin call, no
  //    TTL step and no deployment file. A re-run skips the deployed contracts and reads the wiring again.
  await requireWiring(plan, chain, reconcileOrRefuse, say);

  // 7. The float, now that exec-aquarius exists.
  if (plan.aqua.enabled) {
    const execId = plan.ids.get("exec-aquarius")!.id;
    if (aquaHeld > 0n) done(`sent ${fmtUnits(aquaHeld)} AQUA to exec-aquarius`, await fundFloat(chain, deployer, plan.fixtures, execId, aquaHeld));
    const float = await floatOf(chain, execId);
    const target = plan.aqua.target ?? 0n;
    say(`  AQUA float ${fmtUnits(float)} of a ${fmtUnits(target)} target${float < target ? ": fund exec-aquarius " + execId + " with AQUA (or re-run with --fund-aqua-float)" : " ✓"}`);
  }

  // 8. The admin's configuration, with venue ids read back from venues() (F8).
  const launchpad = plan.ids.get("launchpad-v2")!.id;
  const assets = quoteAssets(plan);
  const state = await readLaunchpadState((fn, args) => chain.view(launchpad, fn, args), [...assets.values()]);
  const calls = launchpadCalls(launchpad, plan.economics, initialVenues(plan.constructorPlan), state, assets);
  for (const call of calls) done(call.describe, await invoke(chain, admin, call.contract, call.fn, call.args));
  if (calls.length === 0) say("  launchpad-v2 already has the planned fees, venues and quotes");
  const venues = readVenues(scValToNative(await chain.view(launchpad, "venues", [])));
  const quotesRead: Record<string, unknown> = {};
  for (const [k, a] of assets) quotesRead[k] = scValToNative(await chain.view(launchpad, "quote_economics", [new Address(a).toScVal()]));

  // 9. TTL: 75 days for every v2 instance and WASM, and for the Soroswap factory's instance and the factory and pair
  //    WASMs where they have less (ExtendFootprintTTL is permissionless), paid by the deployer (L-g). The step's own
  //    report isn't trusted: every entry's live-until ledger is read back, and each must be at least 75 days past the
  //    ledger before the extension (an extension applied at ledger A sets A + 75 days).
  const soroswap = await soroswapTtlEntries(chain, network().soroswapFactory);
  for (const n of soroswap.notes) say(`  note: ${n}`);
  const contracts = [...new Set([...[...plan.ids.values()].map((p) => p.id), ...soroswap.contracts])];
  const hashes = [...new Set([...plan.wasms.map((w) => w.sha256!), ...soroswap.hashes])];
  const label = (k: string) => {
    const p = [...plan.ids.values()].find((x) => x.id === k);
    if (p) return `${p.name} ${k}`;
    const w = plan.wasms.find((x) => x.sha256 === k);
    return w ? `${WASMS[w.key].file} code` : soroswap.labels.get(k) ?? k;
  };
  const ttlFrom = await chain.latestLedger();
  let ttl: { extended: number; fee: string };
  try {
    ttl = await ctx.keepAlive(contracts, hashes, deployer, label);
  } catch (e) {
    throw new Error(`the TTL step stopped (${(e as Error).message}). Everything else is deployed. Run the same command again: it skips what is there and goes on with the TTL step.`);
  }
  fees += BigInt(ttl.fee);
  say(`  extended ${ttl.extended} instance and WASM entries to ${TTL_EXTEND_DAYS} days, paid by the deployer (fee ${fmtXlm(BigInt(ttl.fee))})`);
  const target = ttlFrom + TTL_EXTEND_LEDGERS;
  const liveUntil = await chain.liveUntil(contracts, hashes);
  const short = [...liveUntil.entries()].filter(([, l]) => l === null || l < target);
  if (short.length) {
    throw new Error(
      `the TTL step didn't reach ${TTL_EXTEND_DAYS} days (live until ledger ${target} or later) for:\n  ${
        short.map(([k, l]) => `${label(k)}: ${l === null ? "missing" : `live until ${l}`}`).join("\n  ")
      }\nEverything else is deployed. Run the same command again: it skips what is there and retries the TTL step.`,
    );
  }
  say(`  ✓ every instance and WASM lives until ledger ${target} or later (${TTL_EXTEND_DAYS} days)`);

  // 10. The deployment file: ids, the venue table as read, hashes, public roles, durations; never a key.
  const file = `${ctx.deploymentsDir}/${plan.profile.deploymentFile}`;
  const record = await deploymentRecord(ctx, plan, venues, quotesRead, startLedger, file);
  await Deno.mkdir(ctx.deploymentsDir, { recursive: true });
  await Deno.writeTextFile(file, JSON.stringify(record, null, 2) + "\n");

  say();
  say(`Done: ${fmtXlm(fees)} in fees (at most). Wrote ${file}`);
  say("Next steps:");
  say(`  1. Send that file to the lead to commit; CT-12 binds the app's pins to it later.`);
  say("  2. Do NOT run the v1 cutover (admin-v2.ts cutover-v1) until the lead says the app serves v2: v1 must keep working until then (§17 steps 6–7).");
  say(`  3. The v2 contracts and WASMs now live ${TTL_EXTEND_DAYS} days, past the 2026-12-16 testnet reset; the keeper's TTL upkeep (lite-indexer)`);
  say("     must still run before testers are invited: every launch token, Moment NFT and Moment coin starts at the network minimum");
  say("     (about 7 days) and only the keeper extends it.");
  return 0;
}

/** After the constructors (step 6): every planned contract must be deployed and match the plan, and the wiring read
 *  back from the chain must match (lib/wiring-v2.ts). Throws, naming each field and both values, on any mismatch. */
async function requireWiring(
  plan: Plan,
  chain: Chain,
  reconcileOrRefuse: (p: Plan, sentAlready?: boolean) => Promise<Reconciled[]>,
  say: (l?: string) => void,
): Promise<void> {
  const stop = "the run stopped after the constructors: no admin call, no TTL step and no deployment file";
  const after = await reconcileOrRefuse(plan, true);
  const notThere = after.filter((s) => s.state !== "deployed");
  if (notThere.length) {
    throw new Error(`${notThere.map((s) => `${s.name} ${s.id}`).join(", ")} not at the planned id after the constructors; ${stop}. Run the same command again.`);
  }
  say("  Wiring read-back (views, no transaction)");
  const rows = await readBackWiring(wiringPlan(plan), (id, fn, args) => chain.view(id, fn, args));
  for (const r of rows) say(`    ${renderWiringRow(r)}`);
  const problems = wiringProblems(rows);
  if (problems.length) {
    throw new Error(
      `the wiring read back from the chain differs from the plan; ${stop}:\n  ${problems.join("\n  ")}\n` +
        "Don't run it again with these contracts: tell the lead (a fix needs a new --generation).",
    );
  }
}

/** The Soroswap factory's instance, its WASM and the pair WASM (the code of all_pairs(0)), for the TTL step: every
 *  graduation goes through them, and extending is permissionless. Only entries live on chain are returned (an archived
 *  one needs a restore, which isn't this kit's to do); anything left out is a note. */
export async function soroswapTtlEntries(
  chain: ChainReader,
  factory: string,
): Promise<{ contracts: string[]; hashes: string[]; labels: Map<string, string>; notes: string[] }> {
  const labels = new Map<string, string>();
  const notes: string[] = [];
  const factoryCode = await chain.contractWasmHash(factory);
  if (factoryCode === null) return { contracts: [], hashes: [], labels, notes: [`the Soroswap factory ${factory} isn't on chain: its TTL isn't extended`] };
  labels.set(factory, `Soroswap factory ${factory}`);
  labels.set(factoryCode, "Soroswap factory code");
  const hashes = [factoryCode];
  try {
    const pairs = Number(scValToNative(await chain.view(factory, "all_pairs_length", [])));
    if (pairs > 0) {
      const pair = String(scValToNative(await chain.view(factory, "all_pairs", [nativeToScVal(0, { type: "u32" })])));
      const pairCode = await chain.contractWasmHash(pair);
      if (pairCode && pairCode !== factoryCode) {
        hashes.push(pairCode);
        labels.set(pairCode, "Soroswap pair code");
      } else notes.push("the Soroswap pair WASM wasn't found: its TTL isn't extended");
    } else notes.push("the Soroswap factory has no pair yet: the pair WASM's TTL isn't extended");
  } catch (e) {
    notes.push(`the Soroswap pair WASM couldn't be read (${(e as Error).message}): its TTL isn't extended`);
  }
  const latest = await chain.latestLedger();
  const live = await chain.liveUntil([factory], hashes);
  const isLive = (k: string) => (live.get(k) ?? -1) >= latest;
  const contracts = isLive(factory) ? [factory] : [];
  const kept = hashes.filter(isLive);
  for (const k of [...(contracts.length ? [] : [factory]), ...hashes.filter((h) => !kept.includes(h))]) {
    notes.push(`${labels.get(k)} isn't live on chain (archived?): its TTL isn't extended`);
  }
  return { contracts, hashes: kept, labels, notes };
}

async function deploymentRecord(
  ctx: DeployCtx,
  plan: Plan,
  venues: ReturnType<typeof readVenues>,
  quotes: Record<string, unknown>,
  startLedger: number,
  file: string,
) {
  // A re-run of the same generation keeps the first run's ledger.
  let deployLedger = startLedger;
  try {
    const prev = JSON.parse(await Deno.readTextFile(file));
    if (prev.generation === plan.opts.generation && prev.deployer === plan.keys.deployer && Number.isInteger(prev.deployLedger)) {
      deployLedger = Math.min(deployLedger, prev.deployLedger);
    }
  } catch { /* first run */ }
  const kinds = ["Soroswap", "Aquarius", "HoldOnly", "QaFail"];
  const camelIds = Object.fromEntries([...plan.ids.values()].map((p) => [CAMEL[p.name as SingletonName], p.id]));
  return {
    network: "testnet",
    deployment: plan.profile.name,
    name: plan.profile.deploymentFile.replace(/\.json$/, ""),
    generation: plan.opts.generation,
    salts: `sha256("dyorhq/v2/${plan.profile.name}/g${plan.opts.generation}/<contract>")`,
    deployer: plan.keys.deployer,
    contracts: camelIds,
    wasmHashes: Object.fromEntries(plan.wasms.map((w) => [WASM_CAMEL[w.key], w.sha256])),
    venues: venues.map((v) => ({ id: v.id, kind: kinds[v.kind] ?? String(v.kind), executor: v.executor, feeFraction: v.fee_fraction, enabled: v.enabled })),
    quotes: JSON.parse(JSON.stringify(quotes, (_k, v) => (typeof v === "bigint" ? v.toString() : v))),
    aquarius: {
      enabled: plan.aqua.enabled,
      reason: plan.aqua.reason,
      router: plan.fixtures.router,
      target: plan.aqua.target?.toString() ?? null,
    },
    roles: {
      admin: plan.keys.roles.ADMIN_PUBLIC,
      governance: plan.keys.roles.GOVERNANCE_PUBLIC,
      launchpadGuardian: plan.keys.roles.LAUNCHPAD_GUARDIAN_PUBLIC,
      momentsGuardian: plan.keys.roles.MOMENTS_GUARDIAN_PUBLIC,
      treasury: plan.keys.roles.TREASURY_PUBLIC,
      platform: plan.keys.roles.PLATFORM_PUBLIC,
      ...(plan.keys.qa ? { qaAdmin: plan.keys.qa.QA_ADMIN_SECRET.publicKey(), qaIssuer: plan.keys.qa.QA_ISSUER_SECRET.publicKey() } : {}),
    },
    ...(plan.qaAsset ? { qaAsset: { code: plan.qaAsset.code, issuer: plan.qaAsset.issuer, sac: plan.qaAsset.sac } } : {}),
    durations: { set: plan.profile.durationSet, launch: plan.profile.launchDurations, moments: plan.profile.momentsDurations },
    ttl: plan.profile.ttl,
    economics: `backend/scripts/economics/${plan.profile.economicsFile}`,
    deployLedger,
    deployedAt: ctx.now().toISOString(),
  };
}

if (import.meta.main) Deno.exit(await main(Deno.args, realCtx()));
