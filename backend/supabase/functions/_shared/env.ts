import { NetworkConfig, networkByName } from "./networks.ts";

function read(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v && v.trim() !== "" ? v.trim() : undefined;
}

function required(name: string): string {
  const v = read(name);
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** Lazy, so importing a module never needs secrets that its code path doesn't use (tests, scripts). */
export const env = {
  get network(): NetworkConfig {
    const net = networkByName(read("LITE_NETWORK") ?? "testnet");
    const rpc = read("STELLAR_RPC_URL");
    return rpc ? { ...net, rpcUrl: rpc } : net;
  },
  get jwtSecret(): string {
    return required("LITE_JWT_SECRET");
  },
  get sponsorSecret(): string {
    return required("SPONSOR_SECRET");
  },
  get dbUrl(): string {
    return read("LITE_DB_URL") ?? required("SUPABASE_DB_URL");
  },
  get supabaseUrl(): string | undefined {
    return read("SUPABASE_URL");
  },
  get serviceRoleKey(): string | undefined {
    return read("SUPABASE_SERVICE_ROLE_KEY");
  },
  get cronSecret(): string | undefined {
    return read("LITE_CRON_SECRET");
  },
  get soroswapApiKey(): string | undefined {
    return read("SOROSWAP_API_KEY");
  },
  get monadRelayerKey(): string | undefined {
    return read("MONAD_RELAYER_KEY");
  },
  /** Per user per UTC day, in stroops (1 XLM = 10,000,000). Testnet default 50 XLM; set it per network. */
  get dailyFeeBudget(): bigint {
    return BigInt(read("LITE_DAILY_FEE_BUDGET") ?? "500000000");
  },
  /** The most the sponsor pays for one transaction, in stroops. A launch (it deploys a token contract and pays
   *  30 days of rent) is the most expensive call, about 2 XLM on testnet; default cap 3 XLM. */
  get maxFeePerTx(): bigint {
    return BigInt(read("LITE_MAX_FEE_PER_TX") ?? "30000000");
  },
  get mediaBucket(): string {
    return read("LITE_MEDIA_BUCKET") ?? "lite-media";
  },
  get minBuild(): number {
    return Number(read("LITE_MIN_BUILD") ?? "1");
  },
};
