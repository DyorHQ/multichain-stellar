// Deploys the DyorHQ v2 contracts (docs/DESIGN-stellar-contracts-v2.md §3.4, §14, §16, §17) and writes
// backend/supabase/functions/_shared/deployments/<name>-v2.json.
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/deploy-contracts-v2.ts \
//     --deployment testnet|testnet-qa [--dry-run [--offline]] [--aquarius auto|off] [--fund-aqua-float] [--generation n]
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
// moments-v2 (§3.4); the admin's configuration with venue ids read back from venues() (F8); 30 days of TTL for every
// instance and WASM (L-g); the deployment file; the next steps (L-h). A dry run prints the plan and sends nothing;
// --offline also skips the read-only network checks. A run that failed halfway can be run again: what is already
// on chain and matches the plan is skipped, and anything that differs is refused.
import { Address, Asset, Keypair, Operation, scValToNative } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";
import { keepAlive } from "../supabase/functions/_shared/ttl.ts";
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
  preflight,
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

export const USAGE =
  "usage: deploy-contracts-v2.ts --deployment testnet|testnet-qa [--dry-run [--offline]] [--aquarius auto|off] [--fund-aqua-float] [--generation n]";

export interface DeployOptions {
  deployment: string;
  dryRun: boolean;
  offline: boolean;
  aquarius: "auto" | "off";
  fundAquaFloat: boolean;
  generation: number;
}

export function parseArgs(args: string[]): DeployOptions {
  const o: DeployOptions = { deployment: "", dryRun: false, offline: false, aquarius: "auto", fundAquaFloat: false, generation: 1 };
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
    else if (a === "--aquarius") {
      const v = value();
      if (v !== "auto" && v !== "off") throw new Error(`--aquarius is auto or off\n${USAGE}`);
      o.aquarius = v;
    } else if (a === "--generation") {
      const v = value();
      if (!/^[1-9]\d{0,5}$/.test(v)) throw new Error(`--generation is a whole number from 1\n${USAGE}`);
      o.generation = Number(v);
    } else throw new Error(`unknown argument ${a}\n${USAGE}`);
  }
  if (!o.deployment) throw new Error(USAGE);
  if (o.offline && !o.dryRun) throw new Error("--offline goes with --dry-run only");
  if (o.fundAquaFloat && o.aquarius === "off") throw new Error("--fund-aqua-float and --aquarius off contradict each other");
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
  /** Extends every given instance and WASM to 30 days, paid by `payer` (ttl.ts keepAlive). */
  keepAlive(contracts: string[], codeHashes: string[], payer: Keypair): Promise<{ extended: number; fee: string }>;
  now(): Date;
}

export function realCtx(): DeployCtx {
  const env = (n: string) => Deno.env.get(n);
  const root = repoRoot();
  return {
    io: consoleIo(),
    env,
    secretsDir: secretsDir(env),
    root,
    deploymentsDir: `${root}backend/supabase/functions/_shared/deployments`,
    chain: testnetChain({
      rpcUrl: env("STELLAR_RPC_URL")?.trim() || TESTNET.rpcUrl,
      horizonUrl: TESTNET.horizonUrl,
      friendbotUrl: TESTNET.friendbotUrl!,
    }),
    keepAlive: async (contracts, hashes, payer) => {
      const r = await keepAlive(contracts, hashes, 31, 30, payer);
      return { extended: r.extended, fee: r.fee };
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

const minDeployerXlm = (plan: Plan) => (plan.opts.fundAquaFloat ? 2_500n : 1_000n) * STROOPS_PER_XLM;

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
  say("After the constructors, signed by the admin");
  say(`  set_quote for ${lp.quotes.map((q) => q.asset).join(", ")}, with venue ids read back from venues() (F8)`);
  say("  set_launch_fee, set_fees and set_venue_enabled only where the chain differs from the economics file (the");
  say("  constructor already takes the launch fee, starts at §14.1's fees and enables every initial venue)");
  say("  then every v2 instance and WASM is extended to 30 days, paid by the deployer");
  say(`  and backend/supabase/functions/_shared/deployments/${profile.deploymentFile} is written`);
}

// ------------------------------------------------------------------------------------------------ main

export async function main(args: string[], ctx: DeployCtx): Promise<number> {
  const io = ctx.io;
  try {
    const opts = parseArgs(args);
    const profile = profileFor(opts.deployment);
    const smoke = ctx.env("SMOKE") === "1";
    guard(profile, { durations: profile.durationSet, qaExecFail: profile.qaExecFail, failingMomentsStack: profile.failingMomentsStack, keyGeneration: profile.keyGeneration, smoke });
    if (smoke) throw new Error("SMOKE=1: the testnet-qa smoke run comes with CT-11's --smoke; unset SMOKE for this deploy");
    const net = ctx.env("LITE_NETWORK");
    if (net && net !== "testnet") throw new Error(`LITE_NETWORK is ${net}: v2 deploys to testnet only (unset it)`);
    // The TTL step (_shared/ttl.ts) reads the functions' network settings: keep them on testnet's own deployment.
    const liteDeployment = ctx.env("LITE_DEPLOYMENT");
    if (liteDeployment && liteDeployment !== "testnet") throw new Error(`LITE_DEPLOYMENT is ${liteDeployment}: unset it for this script`);
    if (opts.fundAquaFloat && profile.name !== "testnet") throw new Error("--fund-aqua-float is for the owner's testnet; testnet-qa acquires its float by default");
    const economics = parseEconomics(JSON.parse(await Deno.readTextFile(`${ctx.root}backend/scripts/economics/${profile.economicsFile}`)), profile);
    const fixtures = await loadAquariusFixtures(ctx.root);
    if (fixtures.router !== network().aquariusRouter) throw new Error("networks.ts and fixtures.json name different Aquarius routers");
    const keys = profile.name === "testnet" ? await ownerKeys(ctx, opts.dryRun) : await qaKeys(ctx, opts.dryRun);

    const chain = opts.offline ? null : ctx.chain;
    if (!opts.offline && !chain) throw new Error("no network: use --dry-run --offline");
    const reader = chain ? (opts.dryRun ? readOnlyChain(chain) : chain) : null;

    // The Aquarius decision first: whether exec-aquarius and the venue are in the plan.
    const live = reader ? await aquariusLiveCheck(reader, fixtures) : null;
    const payment = reader ? await routerPayment(reader, fixtures) : null;
    let aqua = planAquarius({
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

async function dryRunChecks(io: Io, plan: Plan, reader: Chain | null): Promise<number> {
  const say = (l = "") => io.out(l);
  const blockers: string[] = [];
  if (!plan.reviewed.ok) blockers.push("the reviewed-hash check");
  if (plan.guards.some((g) => g.result && !g.result.ok)) blockers.push("the constructor guard");
  if (plan.wasms.some((w) => !w.bytes)) blockers.push("WASMs absent from contracts/dist");
  if (!plan.keys.deployKey) blockers.push("no deploy key");
  say();
  if (!reader) {
    say("Network checks: skipped (--offline)");
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
    const live = await aquariusLiveCheck(reader, plan.fixtures);
    say("Aquarius router against contracts/testdata/fixtures.json (ruling a)");
    for (const l of live.lines) say(`  ${l.ok ? "✓" : "✗"} ${l.label}: live ${l.live ?? "unreadable"}, fixture ${l.fixture}`);
    if (plan.aqua.enabled && plan.aqua.swap) {
      const d = await depthCheck(routerEstimate(reader, plan.fixtures), plan.aqua.target ?? 0n);
      say(`  ${d.ok ? "✓" : "✗"} depth check: 1 XLM → ${fmtUnits(d.rate1)} AQUA; ${fmtUnits(d.spend)} XLM → ${fmtUnits(d.out)} AQUA for a minimum of ${fmtUnits(d.minOut)}${d.reason ? ` (${d.reason})` : ""}`);
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

  // 1. Nothing is sent before the reviewed-hash gate and the constructor guard pass.
  const absent = plan.wasms.filter((w) => !w.bytes);
  if (absent.length) throw new Error(`absent from contracts/dist: ${absent.map((w) => WASMS[w.key].file).join(", ")} (build with contracts/build.sh)`);
  if (!plan.reviewed.ok) throw new Error(`reviewed-hash check failed; nothing was sent:\n  ${plan.reviewed.problems.join("\n  ")}`);
  const badGuards = plan.guards.filter((g) => !g.result?.ok);
  if (badGuards.length) {
    throw new Error(`constructor guard: ${badGuards.map((g) => `${WASMS[g.wasm].file} (${g.result?.differences.join("; ")})`).join(", ")}; nothing was sent`);
  }
  const deployer = plan.keys.deployKey!;
  const admin = plan.keys.adminKey!;
  // The re-run check (L-c), read-only and before anything is sent: skip what matches, refuse what differs.
  const reconcileOrRefuse = async (p: Plan): Promise<Reconciled[]> => {
    const states = await reconcile(plannedContracts(p.constructorPlan, p.ctors), chain);
    const conflicts = states.filter((s) => s.state === "conflict");
    if (conflicts.length) {
      throw new Error(
        `contracts at the planned ids differ from the plan; nothing was sent (use a new --generation, or fix the inputs):\n  ${
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
          plan = await rebuild(next);
          states = await reconcileOrRefuse(plan);
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

  // 6. The float, now that exec-aquarius exists.
  if (plan.aqua.enabled) {
    const execId = plan.ids.get("exec-aquarius")!.id;
    if (aquaHeld > 0n) done(`sent ${fmtUnits(aquaHeld)} AQUA to exec-aquarius`, await fundFloat(chain, deployer, plan.fixtures, execId, aquaHeld));
    const float = await floatOf(chain, execId);
    const target = plan.aqua.target ?? 0n;
    say(`  AQUA float ${fmtUnits(float)} of a ${fmtUnits(target)} target${float < target ? ": fund exec-aquarius " + execId + " with AQUA (or re-run with --fund-aqua-float)" : " ✓"}`);
  }

  // 7. The admin's configuration, with venue ids read back from venues() (F8).
  const launchpad = plan.ids.get("launchpad-v2")!.id;
  const assets = quoteAssets(plan);
  const state = await readLaunchpadState((fn, args) => chain.view(launchpad, fn, args), [...assets.values()]);
  const calls = launchpadCalls(launchpad, plan.economics, initialVenues(plan.constructorPlan), state, assets);
  for (const call of calls) done(call.describe, await invoke(chain, admin, call.contract, call.fn, call.args));
  if (calls.length === 0) say("  launchpad-v2 already has the planned fees, venues and quotes");
  const venues = readVenues(scValToNative(await chain.view(launchpad, "venues", [])));
  const quotesRead: Record<string, unknown> = {};
  for (const [k, a] of assets) quotesRead[k] = scValToNative(await chain.view(launchpad, "quote_economics", [new Address(a).toScVal()]));

  // 8. TTL: 30 days for every v2 instance and WASM, paid by the deployer (L-g).
  const contracts = [...plan.ids.values()].map((p) => p.id);
  const hashes = plan.wasms.map((w) => w.sha256!);
  const ttl = await ctx.keepAlive(contracts, hashes, deployer);
  fees += BigInt(ttl.fee);
  say(`  extended ${ttl.extended} instance and WASM entries to 30 days, paid by the deployer (fee at most ${fmtXlm(BigInt(ttl.fee))})`);

  // 9. The deployment file: ids, the venue table as read, hashes, public roles, durations; never a key.
  const file = `${ctx.deploymentsDir}/${plan.profile.deploymentFile}`;
  const record = await deploymentRecord(ctx, plan, venues, quotesRead, startLedger, file);
  await Deno.mkdir(ctx.deploymentsDir, { recursive: true });
  await Deno.writeTextFile(file, JSON.stringify(record, null, 2) + "\n");

  say();
  say(`Done: ${fmtXlm(fees)} in fees (at most). Wrote ${file}`);
  say("Next steps:");
  say(`  1. Send that file to the lead to commit; CT-12 binds the app's pins to it later.`);
  say("  2. Do NOT run the v1 cutover (admin-v2.ts cutover-v1) until the lead says the app serves v2: v1 must keep working until then (§17 steps 6–7).");
  return 0;
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
