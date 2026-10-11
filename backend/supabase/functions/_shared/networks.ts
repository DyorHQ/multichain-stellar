// Network registry: the single source of truth for chains, assets and contracts. The app reads it through
// GET /v1/config and pins the contract allowlist at build time (ios/Packages/StellarKit/.../PinnedContracts.swift is
// generated from this file and deployments/*.json by backend/scripts/gen-pinned.ts).
import testnetDeployment from "./deployments/testnet.json" with { type: "json" };

export type NetworkName = "testnet" | "mainnet";

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
  logo?: string;
}

export interface AnchorInfo {
  domain: string;
  name: string;
  assets: string[];
  countries: string[];
  kinds: ("deposit" | "withdraw")[];
}

export interface NetworkConfig {
  name: NetworkName;
  passphrase: string;
  rpcUrl: string;
  horizonUrl: string;
  friendbotUrl: string | null;
  /** Account activation: testnet funds new accounts with Friendbot (10,000 test XLM to play with);
   *  mainnet creates them with sponsored reserves and 0 XLM. */
  activation: "friendbot" | "sponsored";
  assets: AssetInfo[];
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
  anchors: AnchorInfo[];
  bridge: {
    /** Monad side of the bridge for this network. */
    monad: { chainId: number; rpcUrl: string; domain: number; usdc: string; tokenMessenger: string; messageTransmitter: string } | null;
    routes: ("cctp" | "oneclick")[];
  };
}

const TESTNET_XLM = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
const TESTNET_USDC = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA";
const TESTNET_BLEND_USDC = "CAQCFVLOBK5GIULPNZRGATJJMIZL5BSP7X5YJVMGCPTUEPFM4AVSRCJU";

export const TESTNET: NetworkConfig = {
  name: "testnet",
  passphrase: "Test SDF Network ; September 2015",
  rpcUrl: "https://soroban-testnet.stellar.org",
  horizonUrl: "https://horizon-testnet.stellar.org",
  friendbotUrl: "https://friendbot.stellar.org",
  activation: "friendbot",
  assets: [
    { id: "XLM", code: "XLM", name: "Stellar Lumens", decimals: 7, contract: TESTNET_XLM, classic: "native", note: "Test XLM" },
    {
      id: "USDC",
      code: "USDC",
      name: "USD Coin",
      decimals: 7,
      contract: TESTNET_USDC,
      classic: "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5",
      note: "Circle test USDC (testanchor, CCTP)",
    },
    {
      id: "BUSDC",
      code: "USDC",
      name: "Blend test USDC",
      decimals: 7,
      contract: TESTNET_BLEND_USDC,
      classic: "USDC:GATALTGTWIOT6BUDBCZM3Q4OQ4BO2COLOAZ7IYSKPLC2PMSOPPGF5V56",
      note: "Only Blend's testnet pool uses it; mainnet has one USDC",
    },
  ],
  contracts: {
    launchpad: testnetDeployment.launchpad ?? null,
    moments: testnetDeployment.moments ?? null,
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
  anchors: [
    { domain: "testanchor.stellar.org", name: "Stellar Test Anchor", assets: ["USDC", "XLM"], countries: ["*"], kinds: ["deposit", "withdraw"] },
  ],
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
  horizonUrl: "https://horizon.stellar.org",
  friendbotUrl: null,
  activation: "sponsored",
  assets: [
    { id: "XLM", code: "XLM", name: "Stellar Lumens", decimals: 7, contract: "CAS3J7GYLGXMF6TDJBBYYSE3HQ6BBSMLNUQ34T6TZMYMW2EVH34XOWMA", classic: "native" },
    {
      id: "USDC",
      code: "USDC",
      name: "USD Coin",
      decimals: 7,
      contract: MAINNET_USDC,
      classic: "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN",
    },
  ],
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
  anchors: [],
  bridge: { monad: null, routes: ["oneclick"] },
};

export function networkByName(name: string | undefined): NetworkConfig {
  return name === "mainnet" ? MAINNET : TESTNET;
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
