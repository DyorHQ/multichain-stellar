// Contract deployments by name (docs/DESIGN-stellar-parity.md §6.16): the live testnet one, a QA one where the owner
// allowed it (testnet-qa.json, read when it is first selected) and none on mainnet yet. LITE_DEPLOYMENT picks one and
// defaults to the network's name. deploy-contracts.ts writes the files, from economics.<name>.json beside them;
// gen-pinned.ts pins the app to one of them. Both formats are checked here (parseDeployment, parseEconomics).
import type { AssetInfo, NetworkConfig } from "../networks.ts";
import testnet from "./testnet.json" with { type: "json" };

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
let testnetQa: Deployment | null | undefined;

/** The QA deployment, read on first use: its file exists only where it was made (no hosted function has
 *  testnet-qa.json). Null when there is no file. A malformed one throws here, when testnet-qa is selected, and never
 *  while importing this module, so it can't break networks.ts and the main deployment. */
function qaDeployment(): Deployment | null {
  if (testnetQa === undefined) {
    let text: string;
    try {
      text = Deno.readTextFileSync(new URL(`./${QA}.json`, import.meta.url));
    } catch (e) {
      if (!(e instanceof Deno.errors.NotFound)) throw e;
      testnetQa = null;
      return null;
    }
    let raw: unknown;
    try {
      raw = JSON.parse(text);
    } catch (e) {
      throw new Error(`deployments/${QA}.json is not valid JSON: ${(e as Error).message}`);
    }
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      throw new Error(`deployments/${QA}.json is not an object`);
    }
    testnetQa = parseDeployment(QA, raw as Record<string, unknown>);
  }
  return testnetQa;
}

/** The deployment called `name`; null where the network has none yet. Throws on a name nobody deployed. */
export function deploymentByName(name: string): Deployment | null {
  if (Object.hasOwn(DEPLOYMENTS, name)) return DEPLOYMENTS[name];
  if (name === QA) {
    const qa = qaDeployment();
    if (qa) return qa;
    throw new Error(`No deployments/${QA}.json here (LITE_DEPLOYMENT): it exists only where it was made`);
  }
  throw new Error(`Unknown deployment "${name}" (LITE_DEPLOYMENT): ${[...Object.keys(DEPLOYMENTS), QA].join(", ")}`);
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
