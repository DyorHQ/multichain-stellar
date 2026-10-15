// GET /v1/economics (public; docs/DESIGN-stellar-parity.md §6.9): the launchpad's and the Moments contract's terms,
// read live from the contracts (the launchpad's config() and quote_economics(quote), Moments' config() and
// quote_rule(quote)), so whoever deploys them sets what users see. Kept 5 minutes per isolate, never stored; when a
// read fails, the last answer that was read is served, and without one the request fails.
// - The admin is never served.
// - Moments' treasury is: the publish review shows where the platform fee goes.
// - A quote asset the contract has no terms for is left out; terms that are switched off are served as such.
// - The per-collect cap is a constant of the Moments contract (MAX_PER_COLLECT) and the edition cap the API's own
//   limit; both are the network's limits (networks.ts), as /v1/config serves them.
import type { Economics } from "./contract.ts";
import { env } from "./env.ts";
import { ApiError } from "./http.ts";
import { AssetInfo, NetworkConfig } from "./networks.ts";
import { sv, view } from "./stellar.ts";

/** The assets launches and Moments are priced in. */
export const QUOTES = ["XLM", "USDC"];

/** How long a read is served. */
export const ECONOMICS_TTL_MS = 5 * 60_000;

let cached: { key: string; at: number; value: Economics } | null = null;

/** Drops the isolate's copy (tests). */
export function forgetEconomics(): void {
  cached = null;
}

function quoteAssets(net: NetworkConfig): AssetInfo[] {
  return QUOTES.map((id) => net.assets.find((a) => a.id === id)).filter((a): a is AssetInfo => a !== undefined);
}

async function launchpadTerms(contract: string, net: NetworkConfig): Promise<Economics["launchpad"]> {
  const assets = quoteAssets(net);
  const [cfg, ...terms] = await Promise.all([view(contract, "config"), ...assets.map((a) => view(contract, "quote_economics", [sv.addr(a.contract)]))]);
  return {
    contract,
    launchesEnabled: cfg.launches_enabled === true,
    supply: String(cfg.supply),
    feeBps: Number(cfg.fee_bps),
    protocolShareBps: Number(cfg.protocol_share_bps),
    maxCreatorFeeBps: Number(cfg.max_creator_fee_bps),
    snipeSchedule: (cfg.snipe_schedule as unknown[]).map(Number),
    quotes: assets.flatMap((a, i) => {
      const t = terms[i];
      return t ? [{ asset: a.id, contract: a.contract, phantom: String(t.phantom), threshold: String(t.threshold), enabled: t.enabled === true }] : [];
    }),
  };
}

async function momentsTerms(contract: string, net: NetworkConfig): Promise<Economics["moments"]> {
  const assets = quoteAssets(net);
  const [cfg, ...rules] = await Promise.all([view(contract, "config"), ...assets.map((a) => view(contract, "quote_rule", [sv.addr(a.contract)]))]);
  return {
    contract,
    platformBps: Number(cfg.platform_bps),
    royaltyBps: Number(cfg.royalty_bps),
    publishingEnabled: cfg.publishing_enabled === true,
    treasury: String(cfg.treasury),
    maxPerCollect: net.limits.collectMax,
    maxEditions: net.limits.momentMaxEditions,
    quotes: assets.flatMap((a, i) => {
      const r = rules[i];
      return r ? [{ asset: a.id, minPrice: String(r.min_price), enabled: r.enabled === true }] : [];
    }),
  };
}

/** The terms, each null where its contract isn't deployed. */
export async function economics(net: NetworkConfig = env.network, now: number = Date.now()): Promise<Economics> {
  const { launchpad, moments } = net.contracts;
  const key = `${net.passphrase}|${launchpad ?? ""}|${moments ?? ""}`;
  if (cached && cached.key === key && now - cached.at < ECONOMICS_TTL_MS && now >= cached.at) return cached.value;
  try {
    const [l, m] = await Promise.all([launchpad ? launchpadTerms(launchpad, net) : null, moments ? momentsTerms(moments, net) : null]);
    const value: Economics = { launchpad: l, moments: m };
    cached = { key, at: now, value };
    return value;
  } catch (err) {
    if (cached && cached.key === key) return cached.value;
    throw new ApiError(502, "rpc_unavailable", "The launchpad's terms couldn't be read just now. Try again.", { raw: String((err as Error).message ?? err).slice(0, 300) });
  }
}
