// Contract deployments by name (docs/DESIGN-stellar-parity.md §6.16): the live testnet one, a QA one where the owner
// allowed it (testnet-qa.json, read when present) and none on mainnet yet. LITE_DEPLOYMENT picks one and defaults to
// the network's name. deploy-contracts.ts writes the files; gen-pinned.ts pins the app to one of them.
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

// The files also record the admin and the treasury, for the runbook. Nothing here reads them: the API never depends
// on who they are.
function load(id: string, raw: Record<string, unknown>): Deployment {
  const text = (k: string): string => {
    const v = raw[k];
    if (typeof v !== "string" || v === "") throw new Error(`deployments/${id}.json: ${k} is missing`);
    return v;
  };
  const network = text("network");
  if (network !== "testnet" && network !== "mainnet") throw new Error(`deployments/${id}.json: network is ${network}`);
  if (!Number.isInteger(raw.deployLedger)) throw new Error(`deployments/${id}.json: deployLedger is missing`);
  const smoke = (raw.smoke ?? {}) as { launches?: unknown[]; moments?: unknown[] };
  return {
    id,
    network,
    launchpad: text("launchpad"),
    moments: text("moments"),
    launchTokenWasmHash: text("launchTokenWasmHash"),
    launchpadWasmHash: text("launchpadWasmHash"),
    momentsWasmHash: text("momentsWasmHash"),
    deployLedger: raw.deployLedger as number,
    deployedAt: text("deployedAt"),
    smoke: { launches: (smoke.launches ?? []).map(String), moments: (smoke.moments ?? []).map(Number) },
    indexFromLedger: Number.isInteger(raw.indexFromLedger) ? raw.indexFromLedger as number : null,
  };
}

/** A deployment file that exists only where it was made: no hosted function has testnet-qa.json. */
function ifPresent(file: string): Record<string, unknown> | null {
  let text: string;
  try {
    text = Deno.readTextFileSync(new URL(file, import.meta.url));
  } catch {
    return null;
  }
  return JSON.parse(text);
}

const testnetQa = ifPresent("./testnet-qa.json");

export const DEPLOYMENTS: Record<string, Deployment | null> = {
  testnet: load("testnet", testnet),
  ...(testnetQa ? { "testnet-qa": load("testnet-qa", testnetQa) } : {}),
  mainnet: null,
};

/** The deployment called `name`; null where the network has none yet. Throws on a name nobody deployed. */
export function deploymentByName(name: string): Deployment | null {
  if (!Object.hasOwn(DEPLOYMENTS, name)) throw new Error(`Unknown deployment "${name}" (LITE_DEPLOYMENT): ${Object.keys(DEPLOYMENTS).join(", ")}`);
  return DEPLOYMENTS[name];
}
