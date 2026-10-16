// Contract deployments by name (docs/DESIGN-stellar-parity.md §6.16), in two generations
// (docs/DESIGN-stellar-contracts-v2.md §17, §20.1): v1 (retired) and v2 (live). LITE_DEPLOYMENT picks a deployment and
// defaults to the network's name:
// - testnet: v1 from testnet.json, v2 from the owner's testnet-v2.json, imported here (BUNDLED_V2); both are bundled,
//   so the hosted functions never read a file;
// - testnet-qa: v2 from testnet-qa-v2.json and v1 from testnet-qa.json, each where it was made (read when testnet-qa is
//   first selected);
// - mainnet: nothing deployed yet.
// deploy-contracts.ts writes the v1 files, from economics.<name>.json beside them, and deploy-contracts-v2.ts the v2
// ones; gen-pinned.ts pins the app to one deployment. Every format is checked here (parseDeployment,
// parseDeploymentV2, parseEconomics).
import type { AssetInfo, NetworkConfig } from "../networks.ts";
import testnet from "./testnet.json" with { type: "json" };
import testnetV2 from "./testnet-v2.json" with { type: "json" };

/** The contract generations (DESIGN-stellar-contracts-v2 §17). v1 is retired: immutable and never redeployed, its
 *  launches keep selling and claiming and its Moments stay collectible to their deadlines. v2 is live. */
export const GENERATIONS = [
  { generation: 1, name: "v1", status: "retired" },
  { generation: 2, name: "v2", status: "live" },
] as const;

/** A v1 deployment. */
export interface Deployment {
  /** Its name: "testnet", "testnet-qa". */
  id: string;
  network: "testnet" | "mainnet";
  launchpad: string;
  moments: string;
  launchTokenWasmHash: string;
  launchpadWasmHash: string;
  momentsWasmHash: string;
  deployLedger: number;
  deployedAt: string;
  /** What the deploy's own smoke test created: indexed, never listed in a live feed. */
  smoke: { launches: string[]; moments: number[] };
  /** The first ledger worth indexing, after configuration and any smoke test. Null: from deployLedger. */
  indexFromLedger: number | null;
}

/** Every deployment name and its network, deployed or not: deploy-contracts.ts makes them, LITE_DEPLOYMENT selects. */
export const DEPLOYMENT_NETWORKS: Record<string, "testnet" | "mainnet"> = {
  testnet: "testnet",
  "testnet-qa": "testnet",
  mainnet: "mainnet",
};

const CONTRACT_ID = /^C[A-Z2-7]{55}$/;
const ACCOUNT_ID = /^G[A-Z2-7]{55}$/;
const WASM_HASH = /^[0-9a-f]{64}$/;

/** deployments/<id>.json, checked: throws on anything a deploy wouldn't have written. The files also record the admin
 *  and the treasury, for the runbook. Nothing here reads them: the API never depends on who they are. */
export function parseDeployment(id: string, raw: Record<string, unknown>): Deployment {
  const fail = (what: string): never => {
    throw new Error(`deployments/${id}.json: ${what}`);
  };
  const text = (k: string): string => {
    const v = raw[k];
    if (typeof v !== "string" || v === "") fail(`${k} is missing`);
    return v as string;
  };
  const network = text("network");
  if (network !== "testnet" && network !== "mainnet") fail(`network is ${network}`);
  if (!Number.isInteger(raw.deployLedger)) fail("deployLedger is missing");
  const deployLedger = raw.deployLedger as number;
  // A smoke id that doesn't parse would leave a test item listed: refuse the file instead.
  const smoke = (raw.smoke ?? {}) as { launches?: unknown; moments?: unknown };
  const launches = smoke.launches ?? [];
  const moments = smoke.moments ?? [];
  if (!Array.isArray(launches) || !launches.every((t) => typeof t === "string" && CONTRACT_ID.test(t))) {
    fail("smoke.launches must list launch token contract ids (C…)");
  }
  if (!Array.isArray(moments) || !moments.every((m) => Number.isInteger(m) && (m as number) > 0)) {
    fail("smoke.moments must list Moment ids (whole numbers from 1)");
  }
  const from = raw.indexFromLedger ?? null;
  if (from !== null && !(Number.isInteger(from) && (from as number) >= deployLedger)) {
    fail("indexFromLedger must be a ledger at or after deployLedger, or null");
  }
  return {
    id,
    network: network as Deployment["network"],
    launchpad: text("launchpad"),
    moments: text("moments"),
    launchTokenWasmHash: text("launchTokenWasmHash"),
    launchpadWasmHash: text("launchpadWasmHash"),
    momentsWasmHash: text("momentsWasmHash"),
    deployLedger,
    deployedAt: text("deployedAt"),
    smoke: { launches: launches as string[], moments: moments as number[] },
    indexFromLedger: from as number | null,
  };
}

export const DEPLOYMENTS: Record<string, Deployment | null> = {
  testnet: parseDeployment("testnet", testnet),
  mainnet: null,
};

const QA = "testnet-qa";

const files = new Map<string, Record<string, unknown> | null>();

/** deployments/<file>.json, read on first use; null when there is no such file. Only testnet-qa's files are read this
 *  way: they exist only where they were made, and testnet-qa is served only there (local-stack.sh). A hosted function
 *  can't read a file while it serves a request (Supabase allows synchronous file reads only while a module loads), so
 *  the hosted deployment's files are imported instead. A malformed file throws when its deployment is selected, never
 *  while importing this module, so it can't break networks.ts and the main deployment. */
function readDeploymentFile(file: string): Record<string, unknown> | null {
  if (!files.has(file)) {
    let text: string | null = null;
    try {
      text = Deno.readTextFileSync(new URL(`./${file}.json`, import.meta.url));
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
    }
    let raw: unknown = null;
    if (text !== null) {
      try {
        raw = JSON.parse(text);
      } catch (e) {
        throw new Error(`deployments/${file}.json is not valid JSON: ${(e as Error).message}`);
      }
      if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
        throw new Error(`deployments/${file}.json is not an object`);
      }
    }
    files.set(file, raw as Record<string, unknown> | null);
  }
  return files.get(file)!;
}

function knownName(name: string): void {
  if (!Object.hasOwn(DEPLOYMENT_NETWORKS, name)) {
    throw new Error(`Unknown deployment "${name}" (LITE_DEPLOYMENT): ${Object.keys(DEPLOYMENT_NETWORKS).join(", ")}`);
  }
}

/** The v1 deployment called `name`; null where it has none: testnet-qa without testnet-qa.json, mainnet. Throws on a
 *  name nobody deployed. */
export function deploymentByName(name: string): Deployment | null {
  knownName(name);
  if (Object.hasOwn(DEPLOYMENTS, name)) return DEPLOYMENTS[name];
  const raw = readDeploymentFile(name);
  return raw ? parseDeployment(name, raw) : null;
}

/** Both generations of the deployment called `name` (LITE_DEPLOYMENT), each null where it has none yet. Throws on a
 *  name nobody deployed, and on testnet-qa where neither of its files exists. */
export function deploymentsByName(name: string): { v1: Deployment | null; v2: DeploymentV2 | null } {
  const v1 = deploymentByName(name);
  const v2 = deploymentV2ByName(name);
  if (name === QA && !v1 && !v2) {
    throw new Error(`No deployments/${QA}.json or ${V2_FILES[QA]}.json here (LITE_DEPLOYMENT): they exist only where they were made`);
  }
  return { v1, v2 };
}

// ------------------------------------------------------------------------------------------------ v2

/** Each deployment's v2 file, as deploy-contracts-v2.ts names it (its profile's deploymentFile). */
export const V2_FILES: Record<string, string> = { testnet: "testnet-v2", [QA]: "testnet-qa-v2" };

/** launchpad-v2's durations in seconds (dyor_common::LaunchDurations), named as in the contract and the file. */
export interface LaunchDurationsV2 {
  grace: number;
  /** After stuck_since, how long only the creator's venue may be retried before graduate_fallback (finding F14). */
  fallback_delay: number;
  rescue_admin: number;
  rescue_public: number;
  locked_fallback: number;
  takeover_delay: number;
  takeover_window: number;
  timelock: number;
  timelock_window: number;
  /** The locker's harvest interval (finding F6). */
  harvest_interval: number;
}

/** moments-v2's durations in seconds (dyor_common::MomentsDurations). */
export interface MomentsDurationsV2 {
  vest_period: number;
  stuck_expiry: number;
  /** After completed_at, when a Moment still pending graduation may expire without a recorded failure (finding V11). */
  pending_backstop: number;
  timelock: number;
  timelock_window: number;
  min_window: number;
  max_window: number;
  harvest_interval: number;
}

export const LAUNCH_DURATION_KEYS: readonly (keyof LaunchDurationsV2)[] = [
  "grace",
  "fallback_delay",
  "rescue_admin",
  "rescue_public",
  "locked_fallback",
  "takeover_delay",
  "takeover_window",
  "timelock",
  "timelock_window",
  "harvest_interval",
];

export const MOMENTS_DURATION_KEYS: readonly (keyof MomentsDurationsV2)[] = [
  "vest_period",
  "stuck_expiry",
  "pending_backstop",
  "timelock",
  "timelock_window",
  "min_window",
  "max_window",
  "harvest_interval",
];

const MINUTE = 60;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** dyor-common's two duration sets (contracts/common/src/durations.rs, §14.3), which deploy-contracts-v2.ts deploys
 *  and no other (lib/v2-profile.ts checkDurations; a unit test compares the values): production on every deployment
 *  but testnet-qa. The pins and the verifiers bind the production values for the owner's testnet. */
export const DURATION_SETS_V2: Readonly<
  Record<"production" | "testnet-qa", { launch: LaunchDurationsV2; moments: MomentsDurationsV2 }>
> = {
  production: {
    launch: {
      grace: HOUR,
      fallback_delay: HOUR,
      rescue_admin: 7 * DAY,
      rescue_public: 30 * DAY,
      locked_fallback: DAY,
      takeover_delay: 3 * DAY,
      takeover_window: 3 * DAY,
      timelock: 48 * HOUR,
      timelock_window: 7 * DAY,
      harvest_interval: HOUR,
    },
    moments: {
      vest_period: 30 * DAY,
      stuck_expiry: 7 * DAY,
      pending_backstop: 30 * DAY,
      timelock: 48 * HOUR,
      timelock_window: 7 * DAY,
      min_window: HOUR,
      max_window: 30 * DAY,
      harvest_interval: HOUR,
    },
  },
  "testnet-qa": {
    launch: {
      grace: MINUTE,
      fallback_delay: MINUTE,
      rescue_admin: 5 * MINUTE,
      rescue_public: 15 * MINUTE,
      locked_fallback: 2 * MINUTE,
      takeover_delay: 2 * MINUTE,
      takeover_window: 5 * MINUTE,
      timelock: 2 * MINUTE,
      timelock_window: 10 * MINUTE,
      harvest_interval: MINUTE,
    },
    moments: {
      vest_period: 10 * MINUTE,
      stuck_expiry: 5 * MINUTE,
      pending_backstop: 30 * MINUTE,
      timelock: 2 * MINUTE,
      timelock_window: 10 * MINUTE,
      min_window: 2 * MINUTE,
      max_window: 30 * DAY,
      harvest_interval: MINUTE,
    },
  },
};

export type VenueKindV2 = "Soroswap" | "Aquarius" | "HoldOnly" | "QaFail";

/** One row of launchpad-v2's venue table, as the deploy read it back from venues() (finding F8). */
export interface VenueV2 {
  id: number;
  kind: VenueKindV2;
  executor: string;
  feeFraction: number;
  enabled: boolean;
}

/** A v2 deployment: deployments/<name>-v2.json, as deploy-contracts-v2.ts's deploymentRecord() writes it. */
export interface DeploymentV2 {
  /** The file's name: "testnet-v2", "testnet-qa-v2". */
  id: string;
  /** The deployment it belongs to (LITE_DEPLOYMENT): "testnet", "testnet-qa". */
  deployment: string;
  network: "testnet";
  /** deploy-contracts-v2.ts's --generation: the redeploy counter in the salts, not the contract generation. */
  saltGeneration: number;
  /** The singletons. execAquarius only where the deployment has the Aquarius venue. */
  contracts: {
    launchpadV2: string;
    momentsV2: string;
    lpLocker: string;
    execSoroswap: string;
    execAquarius: string | null;
    momentsGraduator: string;
  };
  /** testnet-qa only (decision O3): the failing venue and the failing Moments stack, which the indexer watches and the
   *  e2e calls directly. Never in contractAllowlist and never pinned in the app (findings F4, F5). Null elsewhere. */
  qa: { qaExecFail: string; momentsV2QaFail: string; momentsGraduatorQaFail: string } | null;
  /** testnet-qa's own classic quote asset (the venue-locked one); null elsewhere. */
  qaAsset: { code: string; issuer: string; sac: string } | null;
  /** The sha256 of every WASM the deploy uploaded, by camel-case name (launchpadV2, launchTokenV2, …). */
  wasmHashes: Record<string, string>;
  /** The contracts the singletons create at runtime have no fixed address: they are recognised by these hashes. */
  runtimeWasmHashes: { launchTokenV2: string; momentNft: string; momentCoin: string };
  venues: VenueV2[];
  /** launchpad-v2's quote_economics() per quote ("XLM", "USDC", "QA"), as read at deploy time. Live reads win. */
  quotes: Record<string, unknown>;
  aquarius: { enabled: boolean; reason: string | null };
  /** Both duration sets: "production" everywhere but testnet-qa (§14.3, decision O3). */
  durations: { set: "production" | "testnet-qa"; launch: LaunchDurationsV2; moments: MomentsDurationsV2 };
  ttl: { threshold: number; extend_to: number };
  deployLedger: number;
  deployedAt: string;
}

const SINGLETON_KEYS = ["launchpadV2", "momentsV2", "lpLocker", "execSoroswap", "momentsGraduator"] as const;
const QA_CONTRACTS = ["qaExecFail", "momentsV2QaFail", "momentsGraduatorQaFail"] as const;
const RUNTIME_KEYS = ["launchTokenV2", "momentNft", "momentCoin"] as const;
const VENUE_KINDS: readonly VenueKindV2[] = ["Soroswap", "Aquarius", "HoldOnly", "QaFail"];

/** deployments/<id>.json of v2, checked: throws on anything deploy-contracts-v2.ts wouldn't have written, and on any
 *  test-only piece (qa-exec-fail, the failing Moments stack, the QA durations) outside testnet-qa (decision O3). The
 *  durations must be the deployment's own set exactly, value by value, not only by its label (§14.3). The
 *  file also records the deployer and the roles (admin, guardians, treasury), for the runbook. Nothing here reads them:
 *  the API never depends on who they are, and the treasury is settable (decision O6, finding A15e). */
export function parseDeploymentV2(id: string, raw: Record<string, unknown>): DeploymentV2 {
  const fail = (what: string): never => {
    throw new Error(`deployments/${id}.json: ${what}`);
  };
  const object = (v: unknown, what: string): Record<string, unknown> => {
    if (typeof v !== "object" || v === null || Array.isArray(v)) fail(`${what} must be an object`);
    return v as Record<string, unknown>;
  };
  const text = (k: string): string => {
    const v = raw[k];
    if (typeof v !== "string" || v === "") fail(`${k} is missing`);
    return v as string;
  };
  const whole = (v: unknown, what: string, min = 0): number => {
    if (!Number.isSafeInteger(v) || (v as number) < min) fail(`${what} must be a whole number from ${min}`);
    return v as number;
  };
  const deployment = text("deployment");
  if (V2_FILES[deployment] !== id) fail(`it is ${deployment}'s v2 deployment, not ${id}`);
  if (text("name") !== id) fail(`name is ${raw.name}`);
  if (text("network") !== "testnet") fail(`network is ${raw.network}: v2 is on testnet only (decision O4)`);
  const qaDeployment = deployment === QA;

  const contracts = object(raw.contracts, "contracts");
  const known = [...SINGLETON_KEYS, "execAquarius", ...QA_CONTRACTS] as string[];
  const unknown = Object.keys(contracts).filter((k) => !known.includes(k));
  if (unknown.length) fail(`contracts: unknown ${unknown.join(", ")}`);
  const contract = (k: string): string => {
    const v = contracts[k];
    if (typeof v !== "string" || !CONTRACT_ID.test(v)) fail(`contracts.${k} must be a contract id (C…)`);
    return v as string;
  };
  const singletons = Object.fromEntries(SINGLETON_KEYS.map((k) => [k, contract(k)])) as Record<typeof SINGLETON_KEYS[number], string>;
  const aquarius = object(raw.aquarius, "aquarius");
  if (typeof aquarius.enabled !== "boolean") fail("aquarius.enabled must be true or false");
  if (aquarius.reason !== null && typeof aquarius.reason !== "string") fail("aquarius.reason must be text or null");
  if (aquarius.enabled !== ("execAquarius" in contracts)) {
    fail(`contracts.execAquarius must be there exactly when aquarius.enabled is true`);
  }
  const execAquarius = aquarius.enabled ? contract("execAquarius") : null;
  const qaThere = QA_CONTRACTS.filter((k) => k in contracts);
  if (!qaDeployment && qaThere.length) fail(`${qaThere.join(", ")}: testnet-qa only (decision O3, finding F4)`);
  if (qaDeployment && qaThere.length !== QA_CONTRACTS.length) fail(`testnet-qa needs ${QA_CONTRACTS.join(", ")} (finding F5)`);
  const qa = qaDeployment ? Object.fromEntries(QA_CONTRACTS.map((k) => [k, contract(k)])) as DeploymentV2["qa"] : null;

  const hashes = object(raw.wasmHashes, "wasmHashes");
  const needHashes = ["launchpadV2", "launchTokenV2", "execSoroswap", "lpLocker", "momentsV2", "momentNft", "momentCoin", "momentsGraduator"];
  if (execAquarius) needHashes.push("execAquarius");
  if (qaDeployment) needHashes.push("qaExecFail");
  for (const k of needHashes) {
    if (typeof hashes[k] !== "string" || !WASM_HASH.test(hashes[k] as string)) fail(`wasmHashes.${k} must be a sha256 in hex`);
  }
  const extraHashes = Object.keys(hashes).filter((k) => !needHashes.includes(k));
  if (extraHashes.length) fail(`wasmHashes: unexpected ${extraHashes.join(", ")}`);
  const wasmHashes = hashes as Record<string, string>;
  const runtimeWasmHashes = Object.fromEntries(RUNTIME_KEYS.map((k) => [k, wasmHashes[k]])) as DeploymentV2["runtimeWasmHashes"];

  // Each venue's executor is this deployment's executor of that kind, read back from the chain (finding F8).
  const executorOf: Partial<Record<VenueKindV2, string | null>> = {
    Soroswap: singletons.execSoroswap,
    Aquarius: execAquarius,
    QaFail: qa?.qaExecFail ?? null,
  };
  if (!Array.isArray(raw.venues) || raw.venues.length === 0) fail("venues must list the venue table");
  const venues = (raw.venues as unknown[]).map((v, i): VenueV2 => {
    const row = object(v, `venues[${i}]`);
    const kind = row.kind as VenueKindV2;
    if (!VENUE_KINDS.includes(kind)) fail(`venues[${i}].kind is ${row.kind}`);
    if (typeof row.executor !== "string" || !CONTRACT_ID.test(row.executor)) fail(`venues[${i}].executor must be a contract id`);
    if (kind in executorOf && row.executor !== executorOf[kind]) fail(`venues[${i}]: a ${kind} venue whose executor isn't this deployment's`);
    if (typeof row.enabled !== "boolean") fail(`venues[${i}].enabled must be true or false`);
    return { id: whole(row.id, `venues[${i}].id`), kind, executor: row.executor as string, feeFraction: whole(row.feeFraction, `venues[${i}].feeFraction`), enabled: row.enabled as boolean };
  });
  if (new Set(venues.map((v) => v.id)).size !== venues.length) fail("venues: an id repeats");
  if (!venues.some((v) => v.kind === "Soroswap")) fail("venues: no Soroswap venue (every quote's fallback is one)");

  const durations = object(raw.durations, "durations");
  const set = durations.set;
  if (set !== (qaDeployment ? "testnet-qa" : "production")) {
    fail(`durations.set is ${set}: ${deployment} deploys the ${qaDeployment ? "testnet-qa" : "production"} set (decision O3)`);
  }
  const durationSet = <K extends string>(v: unknown, what: string, keys: readonly K[]): Record<K, number> => {
    const d = object(v, what);
    const extra = Object.keys(d).filter((k) => !(keys as readonly string[]).includes(k));
    if (extra.length) fail(`${what}: unknown ${extra.join(", ")}`);
    return Object.fromEntries(keys.map((k) => [k, whole(d[k], `${what}.${k}`, 1)])) as Record<K, number>;
  };
  const launch = durationSet(durations.launch, "durations.launch", LAUNCH_DURATION_KEYS);
  const moments = durationSet(durations.moments, "durations.moments", MOMENTS_DURATION_KEYS);
  // A set labelled production but holding other values would be pinned in the app: compare every value,
  // harvest_interval (equal in both, finding F6), fallback_delay and pending_backstop included.
  const own = DURATION_SETS_V2[set as "production" | "testnet-qa"];
  for (const [what, got, want] of [["launch", launch, own.launch], ["moments", moments, own.moments]] as const) {
    for (const [k, v] of Object.entries(want)) {
      const value = (got as Record<string, number>)[k];
      if (value !== v) fail(`durations.${what}.${k} is ${value} s: the ${set} set has ${v} s (§14.3)`);
    }
  }

  const ttl = object(raw.ttl, "ttl");
  const quotes = object(raw.quotes, "quotes");
  const qaAsset = raw.qaAsset === undefined ? null : object(raw.qaAsset, "qaAsset");
  if (!qaDeployment && qaAsset) fail("qaAsset: testnet-qa only (decision O3)");
  if (qaAsset && !(typeof qaAsset.code === "string" && ACCOUNT_ID.test(String(qaAsset.issuer)) && CONTRACT_ID.test(String(qaAsset.sac)))) {
    fail("qaAsset must be {code, issuer, sac}");
  }
  if (typeof raw.deployer !== "string" || !ACCOUNT_ID.test(raw.deployer)) fail("deployer must be an account (G…)");
  return {
    id,
    deployment,
    network: "testnet",
    saltGeneration: whole(raw.generation, "generation", 1),
    contracts: { ...singletons, execAquarius },
    qa,
    qaAsset: qaAsset ? { code: qaAsset.code as string, issuer: qaAsset.issuer as string, sac: qaAsset.sac as string } : null,
    wasmHashes,
    runtimeWasmHashes,
    venues,
    quotes,
    aquarius: { enabled: aquarius.enabled as boolean, reason: (aquarius.reason as string | null) ?? null },
    durations: { set: set as "production" | "testnet-qa", launch, moments },
    ttl: { threshold: whole(ttl.threshold, "ttl.threshold", 1), extend_to: whole(ttl.extend_to, "ttl.extend_to", 1) },
    deployLedger: whole(raw.deployLedger, "deployLedger", 1),
    deployedAt: text("deployedAt"),
  };
}

/** v2 files bundled with the functions, by file. testnet's v2 deployment comes from here only: a hosted function has
 *  only what is imported, and it can't read a file while serving. The owner's testnet-v2.json is imported beside
 *  testnet.json (a unit test and gen-pinned.ts check it is). testnet-qa-v2.json is never bundled: it is read where it
 *  exists. */
export const BUNDLED_V2: Readonly<Record<string, Record<string, unknown>>> = { "testnet-v2": testnetV2 };

const v2Parsed = new Map<string, DeploymentV2 | null>();

/** The v2 deployment of the deployment called `name`; null until its file exists (bundled, or testnet-qa's on disk),
 *  and the v2 routes answer not_deployed. Throws on a name nobody deployed. */
export function deploymentV2ByName(name: string): DeploymentV2 | null {
  knownName(name);
  const file = V2_FILES[name];
  if (!file) return null;
  if (!v2Parsed.has(file)) {
    const raw = BUNDLED_V2[file] ?? (name === QA ? readDeploymentFile(file) : null);
    v2Parsed.set(file, raw ? parseDeploymentV2(file, raw) : null);
  }
  return v2Parsed.get(file)!;
}

/** One quote asset's launch curve: the launchpad's set_quote arguments, in base units. */
export interface CurveQuote {
  asset: AssetInfo;
  phantom: bigint;
  threshold: bigint;
  enabled: boolean;
}

/** One quote asset's minimum Moment price: Moments' set_quote arguments, in base units. */
export interface MomentsQuote {
  asset: AssetInfo;
  minPrice: bigint;
  enabled: boolean;
}

/** What deploy-contracts.ts configures a new deployment with, from economics.<name>.json. */
export interface Economics {
  launchpad: CurveQuote[];
  moments: MomentsQuote[];
}

/** economics.<name>.json, checked against the network's asset registry (networks.ts): throws on anything unexpected,
 *  so a deploy never sets a quote nobody meant. Amounts are base units, as strings:
 *    {"launchpad": {"XLM": {"phantom": "…", "threshold": "…", "enabled": true}, …},
 *     "moments": {"XLM": {"minPrice": "…", "enabled": true}, …}} */
export function parseEconomics(file: string, raw: unknown, net: Pick<NetworkConfig, "name" | "assets">): Economics {
  const bad = (what: string): never => {
    throw new Error(`${file}: ${what}`);
  };
  const object = (v: unknown, what: string, keys: string[]): Record<string, unknown> => {
    if (typeof v !== "object" || v === null || Array.isArray(v)) bad(`${what} must be an object`);
    const extra = Object.keys(v as object).filter((k) => !keys.includes(k));
    if (extra.length) bad(`${what}: unknown ${extra.join(", ")} (expected ${keys.join(", ")})`);
    return v as Record<string, unknown>;
  };
  const amount = (v: unknown, what: string): bigint => {
    if (typeof v !== "string" || !/^[1-9][0-9]{0,29}$/.test(v)) {
      bad(`${what} must be a positive whole number of base units, as a string`);
    }
    return BigInt(v as string);
  };
  const quotes = (section: string, fields: string[]): [AssetInfo, Record<string, unknown>][] => {
    const byAsset = (raw as Record<string, unknown>)[section];
    if (typeof byAsset !== "object" || byAsset === null || Array.isArray(byAsset)) {
      bad(`"${section}" must map asset ids to their settings`);
    }
    const entries = Object.entries(byAsset as object);
    if (!entries.length) bad(`"${section}" lists no quote asset`);
    return entries.map(([id, v]) => {
      const asset = net.assets.find((a) => a.id === id) ??
        bad(`${section}.${id}: not an asset of ${net.name} (networks.ts)`);
      const settings = object(v, `${section}.${id}`, [...fields, "enabled"]);
      if (typeof settings.enabled !== "boolean") bad(`${section}.${id}.enabled must be true or false`);
      return [asset, settings];
    });
  };
  object(raw, file, ["launchpad", "moments"]);
  const launchpad = quotes("launchpad", ["phantom", "threshold"]).map(([asset, v]) => ({
    asset,
    phantom: amount(v.phantom, `launchpad.${asset.id}.phantom`),
    threshold: amount(v.threshold, `launchpad.${asset.id}.threshold`),
    enabled: v.enabled as boolean,
  }));
  const moments = quotes("moments", ["minPrice"]).map(([asset, v]) => ({
    asset,
    minPrice: amount(v.minPrice, `moments.${asset.id}.minPrice`),
    enabled: v.enabled as boolean,
  }));
  return { launchpad, moments };
}
