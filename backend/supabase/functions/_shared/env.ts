// The functions' environment (docs/DESIGN-stellar-parity.md §6.14). Numeric defaults come in pairs, testnet / mainnet.
import { NetworkConfig, networkByName, withDeployment } from "./networks.ts";

function read(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v && v.trim() !== "" ? v.trim() : undefined;
}

function required(name: string): string {
  const v = read(name);
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

function networkName(): string {
  return read("LITE_NETWORK") ?? "testnet";
}

/** A whole number from `name`, or the network's default. */
function count(name: string, testnet: number, mainnet: number): number {
  const v = read(name);
  if (v === undefined) return networkName() === "mainnet" ? mainnet : testnet;
  const n = Number(v);
  if (!Number.isSafeInteger(n) || n < 0) throw new Error(`${name} must be a whole number`);
  return n;
}

function activation(): "friendbot" | "sponsored" {
  const net = networkName();
  const v = read("LITE_ACTIVATION") ?? (net === "mainnet" ? "sponsored" : "friendbot");
  if (v !== "friendbot" && v !== "sponsored") throw new Error("LITE_ACTIVATION is friendbot or sponsored");
  if (net === "mainnet" && v !== "sponsored") throw new Error("LITE_ACTIVATION: mainnet accounts are always sponsored");
  return v;
}

/** Off testnet, settings meant for the local stack are refused. */
function localOnly(name: string): string | undefined {
  const v = read(name);
  if (v !== undefined && networkName() !== "testnet") throw new Error(`${name} is for the local testnet stack only`);
  return v;
}

let keeperWarned = false;
let keeperSharedWarned = false;
const ignoredWarned = new Set<string>();

/** A QA override, which only testnet takes: off testnet it is ignored, with one warning per variable. */
function testnetOverride(name: string): string | undefined {
  const v = read(name);
  if (v === undefined || networkName() === "testnet") return v;
  if (!ignoredWarned.has(name)) {
    ignoredWarned.add(name);
    console.warn(`${name} is set but ignored: it applies on testnet only.`);
  }
  return undefined;
}

/** A session lifetime in seconds: `fallback`, or on testnet `name` when set, which must be at least `min`. */
function lifetime(name: string, fallback: number, min: number): number {
  const v = testnetOverride(name);
  if (v === undefined) return fallback;
  const n = Number(v);
  if (!Number.isSafeInteger(n) || n < min) throw new Error(`${name} must be a whole number of seconds, at least ${min}`);
  return n;
}

/** Lazy, so importing a module never needs secrets that its code path doesn't use (tests, scripts). */
export const env = {
  /** LITE_NETWORK (default testnet; any other name throws), with LITE_DEPLOYMENT's contracts, LITE_ACTIVATION and
   *  STELLAR_RPC_URL applied. */
  get network(): NetworkConfig {
    const base = networkByName(networkName());
    const net = { ...withDeployment(base, this.deployment), activation: activation() };
    const rpc = read("STELLAR_RPC_URL");
    return rpc ? { ...net, rpcUrl: rpc } : net;
  },
  /** The contracts' deployment (deployments/index.ts): the network's own, or testnet-qa. */
  get deployment(): string {
    return read("LITE_DEPLOYMENT") ?? networkName();
  },
  /** friendbot (testnet's default) or sponsored, which rehearses mainnet's activation on a local stack. */
  get activation(): "friendbot" | "sponsored" {
    return activation();
  },
  get jwtSecret(): string {
    return required("LITE_JWT_SECRET");
  },
  /** The access token's lifetime: an hour (§5.9). LITE_JWT_TTL_S shortens it on testnet, for QA of renewal
   *  (local-stack.sh --short-sessions): at least 60 s. */
  get jwtTtlS(): number {
    return lifetime("LITE_JWT_TTL_S", 3600, 60);
  },
  /** A refresh token's lifetime: 30 days from issue, a refresh's successor 30 days of its own (§5.9).
   *  LITE_REFRESH_TTL_S shortens it on testnet: at least 120 s. */
  get refreshTtlS(): number {
    return lifetime("LITE_REFRESH_TTL_S", 30 * 86_400, 120);
  },
  /** Whether a first sign-in needs an invite code: never on testnet (owner decision 2026-10-14), always on mainnet.
   *  LITE_INVITE_REQUIRED (1 or 0) sets it on testnet, for QA of either mode. */
  get inviteRequired(): boolean {
    const v = testnetOverride("LITE_INVITE_REQUIRED");
    if (v === undefined) return networkName() !== "testnet";
    if (v === "1" || v === "true") return true;
    if (v === "0" || v === "false") return false;
    throw new Error("LITE_INVITE_REQUIRED is 1 or 0");
  },
  /** LITE_KEEPER (on, the default, or off): off, the indexer skips every job that signs with the keeper's or the
   *  sponsor's key, so a package's local stack never races the shared keys (§6.17). */
  get keeperEnabled(): boolean {
    const v = read("LITE_KEEPER") ?? "on";
    if (v !== "on" && v !== "off") throw new Error("LITE_KEEPER is on or off");
    return v === "on";
  },
  get sponsorSecret(): string {
    return required("SPONSOR_SECRET");
  },
  /** Pays protocol upkeep: graduation, TTL and the CCTP relay (§4.7). Set, it is always the keeper's key: never the
   *  sponsor's in its place, and on testnet a KEEPER_SECRET equal to SPONSOR_SECRET is warned about (keeper sends and
   *  sponsored activations would share one sequence number). Unset, testnet falls back to the sponsor with one warning;
   *  mainnet needs its own key. */
  get keeperSecret(): string {
    const keeper = read("KEEPER_SECRET");
    if (networkName() === "mainnet") {
      if (!keeper) throw new Error("KEEPER_SECRET is not set (mainnet needs a keeper key of its own)");
      if (keeper === read("SPONSOR_SECRET")) throw new Error("KEEPER_SECRET must differ from SPONSOR_SECRET on mainnet");
      return keeper;
    }
    if (keeper) {
      if (!keeperSharedWarned && keeper === read("SPONSOR_SECRET")) {
        keeperSharedWarned = true;
        console.warn("KEEPER_SECRET is the sponsor's key: keeper sends and sponsored activations share one sequence number (testnet only).");
      }
      return keeper;
    }
    if (!keeperWarned) {
      keeperWarned = true;
      console.warn("KEEPER_SECRET is not set: the sponsor pays protocol upkeep (testnet only). Set a keeper key of its own.");
    }
    return this.sponsorSecret;
  },
  /** The lite_api role's connection (migration 20261013000004), and nothing else: never the project's full-access
   *  SUPABASE_DB_URL, which bypasses RLS and reaches every schema. Missing, the functions refuse to start. */
  get dbUrl(): string {
    return required("LITE_DB_URL");
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
  /** Whether accounts that sign in with Privy (Apple, Google, an email code, a Privy passkey) may use Stellar: their
   *  phone makes and signs with a Privy wallet of their own, talking to Privy itself; this API only says whether
   *  (`/v1/config` `privyWallets`). LITE_PRIVY_WALLETS on or off, the owner's switch: on by default on testnet, off on
   *  mainnet until the owner turns it on. Any other value reads as off, with one warning, so a typo never opens it. */
  get privyWallets(): boolean {
    const v = read("LITE_PRIVY_WALLETS");
    if (v === undefined) return networkName() !== "mainnet";
    if (v === "on" || v === "off") return v === "on";
    if (!ignoredWarned.has("LITE_PRIVY_WALLETS")) {
      ignoredWarned.add("LITE_PRIVY_WALLETS");
      console.warn("LITE_PRIVY_WALLETS is on or off: read as off.");
    }
    return false;
  },
  /** The most the sponsor pays for one transaction, in stroops: the network's maxFee. Kept for plans.ts until its
   *  per-user budget goes (§4.1). */
  get maxFeePerTx(): bigint {
    return this.network.feePolicy.maxFee;
  },
  /** Per user per UTC day, in stroops: 50 XLM. Kept, no longer configurable, for plans.ts until its per-user budget
   *  goes (§4.1). */
  get dailyFeeBudget(): bigint {
    return 500_000_000n;
  },
  /** Sponsored activations per UTC day. */
  get sponsorActivationsPerDay(): number {
    return count("LITE_SPONSOR_ACTIVATIONS_PER_DAY", 1000, 200);
  },
  /** Sponsored starter swaps per UTC day. */
  get sponsorStartersPerDay(): number {
    return count("LITE_SPONSOR_STARTERS_PER_DAY", 1000, 200);
  },
  /** Sponsorships per hashed IP per UTC day. */
  get sponsorPerIpPerDay(): number {
    return count("LITE_SPONSOR_PER_IP_PER_DAY", 5, 3);
  },
  /** The sponsor's fees per kind per UTC day, in stroops. */
  get sponsorDailyFeeCap(): bigint {
    return BigInt(count("LITE_SPONSOR_DAILY_FEE_CAP", 1_000_000_000, 200_000_000));
  },
  /** Attempts per address and kind. */
  get sponsorMaxAttempts(): number {
    return count("LITE_SPONSOR_MAX_ATTEMPTS", 3, 3);
  },
  /** The ops job warns below these balances, in XLM. */
  get sponsorMinXlm(): number {
    return count("LITE_SPONSOR_MIN_XLM", 100, 100);
  },
  get keeperMinXlm(): number {
    return count("LITE_KEEPER_MIN_XLM", 100, 100);
  },
  /** Lets the indexer clear its tables off testnet when the contracts change (lite-indexer/jobs/reset.ts). */
  get indexerAllowReset(): boolean {
    return read("LITE_INDEXER_ALLOW_RESET") === "1";
  },
  /** The base of a Moment's public link, written into its metadata as external_url; unset until that route exists. */
  get momentLinkBase(): string | undefined {
    return read("LITE_MOMENT_LINK_BASE");
  },
  /** The local stack's stand-in for Storage: where uploads are kept, and the public base they are served from. */
  get localStorageDir(): string | undefined {
    return localOnly("LITE_LOCAL_STORAGE_DIR");
  },
  get publicBase(): string | undefined {
    return localOnly("LITE_PUBLIC_BASE");
  },
  get mediaBucket(): string {
    return read("LITE_MEDIA_BUCKET") ?? "lite-media";
  },
  get minBuild(): number {
    return Number(read("LITE_MIN_BUILD") ?? "1");
  },
};
