// Network registry: the single source of truth for chains, assets, contracts and the network's fee policy. The app
// reads it through GET /v1/config and pins the contract allowlist, the fee caps and its RPC at build time
// (ios/Packages/StellarKit/.../PinnedContracts+*.swift is generated from this file and deployments/*.json by
// backend/scripts/gen-pinned.ts). docs/DESIGN-stellar-parity.md §4.2 and §6.2.
import { Deployment, DEPLOYMENTS, deploymentByName } from "./deployments/index.ts";

export type NetworkName = "testnet" | "mainnet";

/** The reference market an asset is valued by. */
export type PriceRef = "XLM" | "USDC";

export interface AssetInfo {
  /** Stable id used by the app and the API: "XLM", "USDC", "BUSDC", or a launch token's contract id. */
  id: string;
  code: string;
  name: string;
  decimals: number;
  /** Soroban contract (SAC for classic assets). */
  contract: string;
  /** Classic asset ("native" or CODE:ISSUER); null for Soroban-only tokens. */
  classic: string | null;
  /** Shown to users. Test assets carry a label so nobody confuses them with mainnet money. */
  note?: string;
  /** The reference market that values it; BUSDC is valued as USDC. */
  priceRef?: PriceRef | null;
  /** A logo bundled in the app ("XLM", "USDC"), or null. */
  logo?: string | null;
  /** Listed in Top Tokens and the markets. Blend's test USDC isn't: it has no market of its own. */
  listed?: boolean;
}

/** Network fees, in stroops (§4.2). The app pins maxFee, maxInclusionPerOp and starterInnerFeeMax too: a cap the
 *  server served couldn't bound the server. */
export interface FeePolicy {
  /** The most one transaction may declare (tx.fee). */
  maxFee: bigint;
  /** The most a transaction may bid for inclusion, per operation. */
  maxInclusionPerOp: bigint;
  /** The most a sponsored starter swap's inner transaction may declare. */
  starterInnerFeeMax: bigint;
  /** The most the sponsor's account-activation transaction may declare. */
  activationMaxFee: bigint;
  /** Spendable XLM below which the starter swap is offered, where activation is sponsored. */
  starterThreshold: bigint;
  /** The least XLM a starter swap must deliver. */
  starterMinXlmOut: bigint;
  /** Spendable XLM below which the app shows the add-funds card. */
  fundingFloor: bigint;
}

/** Rent upkeep by the keeper (§4.8b). */
export interface TtlPolicy {
  /** An entry with fewer days of TTL left than this is extended... */
  thresholdDays: number;
  /** ...to this many days. */
  extendToDays: number;
  /** At most this many entries checked per run, oldest check first. */
  perRun: number;
  /** A launch with no trade in this many days and no holders is left to archive. */
  idleDays: number;
}

/** Input limits the app checks before asking (§6.2); [min, max] pairs are inclusive. */
export interface Limits {
  momentMaxEditions: number;
  momentWindowSecs: [number, number];
  collectMax: number;
  /** In UTF-8 bytes. */
  launchName: [number, number];
  launchSymbol: [number, number];
  uriMax: number;
  uploadBytes: number;
}

export interface NetworkConfig {
  name: NetworkName;
  passphrase: string;
  rpcUrl: string;
  /** The keyless RPC the app is pinned to (gen-pinned.ts); config's rpcUrl never replaces it on the phone (§5.5). */
  phoneRpcUrl: string | null;
  horizonUrl: string;
  friendbotUrl: string | null;
  explorer: string;
  /** Account activation: testnet funds new accounts with Friendbot (10,000 test XLM to play with);
   *  mainnet creates them with sponsored reserves and 0 XLM. */
  activation: "friendbot" | "sponsored";
  /** Friendbot's grant, in XLM: one claim per address, ever (decision 7); null where there is no faucet. */
  faucet: { amount: string } | null;
  feePolicy: FeePolicy;
  ttlPolicy: TtlPolicy;
  limits: Limits;
  /** Where USD prices come from (§6.12): the provider's market for each reference asset. */
  reference: { provider: "Kraken"; markets: Record<PriceRef, string> };
  /** How the app labels USD values: testnet assets have no market, so testnet shows mainnet reference prices. */
  pricing: { kind: "reference" | "market"; network: "mainnet"; note: string | null };
  /** Tickers a launch may not imitate (§6.9), besides the registry's own codes. */
  reservedSymbols: string[];
  assets: AssetInfo[];
  /** The contracts' deployment (deployments/index.ts); null where nothing is deployed. */
  deployment: Deployment | null;
  contracts: {
    launchpad: string | null;
    moments: string | null;
    soroswapRouter: string;
    soroswapFactory: string;
    aquariusRouter: string | null;
    blendPools: { id: string; name: string }[];
    cctp: { tokenMessengerMinter: string; messageTransmitter: string; forwarder: string; domain: number } | null;
  };
  apis: {
    aquarius: string | null;
    soroswap: string;
    iris: string | null;
    oneClick: string | null;
  };
  bridge: {
    /** Monad side of the bridge for this network. */
    monad: { chainId: number; rpcUrl: string; domain: number; usdc: string; tokenMessenger: string; messageTransmitter: string } | null;
    routes: ("cctp" | "oneclick")[];
  };
}

const LIMITS: Limits = {
  momentMaxEditions: 100_000,
  momentWindowSecs: [3_600, 30 * 86_400],
  collectMax: 20,
  launchName: [1, 32],
  launchSymbol: [2, 10],
  uriMax: 256,
  uploadBytes: 25 * 1024 * 1024,
};

const REFERENCE: NetworkConfig["reference"] = { provider: "Kraken", markets: { XLM: "XLMUSD", USDC: "USDCUSD" } };

const RESERVED_SYMBOLS = ["XLM", "USDC", "EURC", "USDT", "PYUSD", "AQUA", "BLND", "YXLM", "BTC", "WBTC", "ETH", "WETH", "SOL", "MON", "DYOR", "DYORHQ"];

const TESTNET_XLM = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
const TESTNET_USDC = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA";
const TESTNET_BLEND_USDC = "CAQCFVLOBK5GIULPNZRGATJJMIZL5BSP7X5YJVMGCPTUEPFM4AVSRCJU";
const TESTNET_DEPLOYMENT = DEPLOYMENTS.testnet;

export const TESTNET: NetworkConfig = {
  name: "testnet",
  passphrase: "Test SDF Network ; September 2015",
  rpcUrl: "https://soroban-testnet.stellar.org",
  phoneRpcUrl: "https://soroban-testnet.stellar.org",
  horizonUrl: "https://horizon-testnet.stellar.org",
  friendbotUrl: "https://friendbot.stellar.org",
  explorer: "https://stellar.expert/explorer/testnet",
  activation: "friendbot",
  faucet: { amount: "10000" },
  // Measured on testnet (§4.2): a launch 0.42 XLM, a keeper graduation 0.80, a first Blend deposit 0.30, a 2-edition
  // collect 0.20. The starter values apply only where activation is sponsored: on testnet, the local rehearsal.
  feePolicy: {
    maxFee: 30_000_000n,
    maxInclusionPerOp: 200_000n,
    starterInnerFeeMax: 1_000_000n,
    activationMaxFee: 100_000n,
    starterThreshold: 500_000n,
    starterMinXlmOut: 10_000_000n,
    fundingFloor: 1_000_000n,
  },
  ttlPolicy: { thresholdDays: 10, extendToDays: 30, perRun: 400, idleDays: 90 },
  limits: LIMITS,
  reference: REFERENCE,
  pricing: { kind: "reference", network: "mainnet", note: "Testnet assets have no market. XLM and USDC are valued at mainnet market prices." },
  reservedSymbols: RESERVED_SYMBOLS,
  assets: [
    { id: "XLM", code: "XLM", name: "Stellar Lumens", decimals: 7, contract: TESTNET_XLM, classic: "native", note: "Test XLM", priceRef: "XLM", logo: "XLM", listed: true },
    {
      id: "USDC",
      code: "USDC",
      name: "USD Coin",
      decimals: 7,
      contract: TESTNET_USDC,
      classic: "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
      note: "Circle test USDC (testanchor, CCTP)",
      priceRef: "USDC",
      logo: "USDC",
      listed: true,
    },
    {
      id: "BUSDC",
      code: "USDC",
      name: "Blend test USDC",
      decimals: 7,
      contract: TESTNET_BLEND_USDC,
      classic: "USDC:GATALTGTWIOT6BUDBCZM3Q4OQ4BO2COLOAZ7IYSKPLC2PMSOPPGF5V56",
      note: "Only Blend's testnet pool uses it; mainnet has one USDC",
      // Not Circle's USDC, so not its logo; valued as USDC.
      priceRef: "USDC",
      logo: null,
      listed: false,
    },
  ],
  deployment: TESTNET_DEPLOYMENT,
  contracts: {
    launchpad: TESTNET_DEPLOYMENT?.launchpad ?? null,
    moments: TESTNET_DEPLOYMENT?.moments ?? null,
    soroswapRouter: "CCJUD55AG6W5HAI5LRVNKAE5WDP5XGZBUDS5WNTIVDU7O264UZZE7BRD",
    soroswapFactory: "CDP3HMUH6SMS3S7NPGNDJLULCOXXEPSHY4JKUKMBNQMATHDHWXRRJTBY",
    aquariusRouter: "CBCFTQSPDBAIZ6R6PJQKSQWKNKWH2QIV3I4J72SHWBIK3ADRRAM5A6GD",
    blendPools: [{ id: "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF", name: "Blend TestnetV2" }],
    cctp: {
      tokenMessengerMinter: "CDNG7HXAPBWICI2E3AUBP3YZWZELJLYSB6F5CC7WLDTLTHVM74SLRTHP",
      messageTransmitter: "CBJ6MTCKKZG73PMDZCJMSFRD7DQEMI4FKDH7CGDSV4W6FHCRBCQAVVJY",
      forwarder: "CA66Q2WFBND6V4UEB7RD4SAXSVIWMD6RA4X3U32ELVFGXV5PJK4T4VSZ",
      domain: 27,
    },
  },
  apis: {
    aquarius: "https://amm-api-testnet.aqua.network/api/external/v2",
    soroswap: "https://api.soroswap.finance",
    iris: "https://iris-api-sandbox.circle.com",
    oneClick: null, // NEAR Intents has no testnet
  },
  bridge: {
    monad: {
      chainId: 10143,
      rpcUrl: "https://testnet-rpc.monad.xyz",
      domain: 15,
      usdc: "0x534b2f3A21130d7a60830c2Df862319e593943A3",
      tokenMessenger: "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA",
      messageTransmitter: "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275",
    },
    routes: ["cctp"],
  },
};

const MAINNET_USDC = "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75";

/** Mainnet is described so the code paths are typed and reviewed; it is not enabled (see docs/ARCHITECTURE.md §7). */
export const MAINNET: NetworkConfig = {
  name: "mainnet",
  passphrase: "Public Global Stellar Network ; September 2015",
  rpcUrl: "", // a provider URL, set with STELLAR_RPC_URL
  phoneRpcUrl: null, // a keyless public endpoint, chosen with the mainnet program
  horizonUrl: "https://horizon.stellar.org",
  friendbotUrl: null,
  explorer: "https://stellar.expert/explorer/public",
  activation: "sponsored",
  faucet: null,
  // Testnet's values, copied: re-measure every one on mainnet before use (§4.2).
  feePolicy: {
    maxFee: 30_000_000n,
    maxInclusionPerOp: 200_000n,
    starterInnerFeeMax: 1_000_000n,
    activationMaxFee: 100_000n,
    starterThreshold: 500_000n,
    starterMinXlmOut: 10_000_000n,
    fundingFloor: 1_000_000n,
  },
  // Re-measure: mainnet rent is about 44 XLM a month for today's contracts.
  ttlPolicy: { thresholdDays: 30, extendToDays: 150, perRun: 400, idleDays: 90 },
  limits: LIMITS,
  reference: REFERENCE,
  pricing: { kind: "market", network: "mainnet", note: null },
  reservedSymbols: RESERVED_SYMBOLS,
  assets: [
    { id: "XLM", code: "XLM", name: "Stellar Lumens", decimals: 7, contract: "CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA", classic: "native", priceRef: "XLM", logo: "XLM", listed: true },
    {
      id: "USDC",
      code: "USDC",
      name: "USD Coin",
      decimals: 7,
      contract: MAINNET_USDC,
      classic: "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
      priceRef: "USDC",
      logo: "USDC",
      listed: true,
    },
  ],
  deployment: null,
  contracts: {
    launchpad: null,
    moments: null,
    soroswapRouter: "CAG5LRYQ5JVEUI5TEID72EYOVX44TTUJT5BQR2J6J77FH65PCCFAJDDH",
    soroswapFactory: "CA4HEQTL2WPEUYKYKCDOHCDNIV4QHNJ7EL4J4NQ6VADP7SYHVRYZ7AW2",
    aquariusRouter: "CBQDHNBFBZYE4MKPWBSJOPIYLW4SFSXAXUTSXJN76GNKYVYPCKWC6QUK",
    blendPools: [],
    cctp: null,
  },
  apis: { aquarius: "https://amm-api.aqua.network/api/external/v2", soroswap: "https://api.soroswap.finance", iris: "https://iris-api.circle.com", oneClick: "https://1click.chaindefuser.com" },
  bridge: { monad: null, routes: ["oneclick"] },
};

/** LITE_NETWORK's network. Anything but "testnet" or "mainnet" throws: a typo must not quietly mean testnet. */
export function networkByName(name: string): NetworkConfig {
  if (name === "testnet") return TESTNET;
  if (name === "mainnet") return MAINNET;
  throw new Error(`Unknown network "${name}" (LITE_NETWORK): testnet or mainnet.`);
}

/** `net` with the contracts of the deployment called `name` (LITE_DEPLOYMENT), which must be on that network. */
export function withDeployment(net: NetworkConfig, name: string): NetworkConfig {
  const deployment = deploymentByName(name);
  if (deployment && deployment.network !== net.name) throw new Error(`Deployment "${name}" is on ${deployment.network}, not ${net.name} (LITE_DEPLOYMENT).`);
  return { ...net, deployment, contracts: { ...net.contracts, launchpad: deployment?.launchpad ?? null, moments: deployment?.moments ?? null } };
}

export function assetById(net: NetworkConfig, id: string): AssetInfo | undefined {
  return net.assets.find((a) => a.id === id || a.contract === id);
}

/** Every contract the app may be asked to call on this network, by role. The phone refuses anything else. */
export function contractAllowlist(net: NetworkConfig): Record<string, string[]> {
  const c = net.contracts;
  const tokens = net.assets.map((a) => a.contract);
  return {
    launchpad: c.launchpad ? [c.launchpad] : [],
    moments: c.moments ? [c.moments] : [],
    soroswapRouter: [c.soroswapRouter],
    aquariusRouter: c.aquariusRouter ? [c.aquariusRouter] : [],
    blendPool: c.blendPools.map((p) => p.id),
    cctpTokenMessenger: c.cctp ? [c.cctp.tokenMessengerMinter] : [],
    token: tokens,
  };
}
