// One way to name an asset from its id (docs/DESIGN-stellar-parity.md §9): the registry (XLM, USDC, BUSDC, by id or
// contract), then a DyorHQ launch (lite.launches), then any other token contract's own symbol() and name(), then a
// classic CODE:ISSUER. Anything else is 400 unsupported_asset. Every answer carries the asset's real code: there is
// no stand-in name, so a payload never shows a placeholder for a token it couldn't name.
import { Asset, StrKey } from "@stellar/stellar-sdk";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError } from "./http.ts";
import { AssetInfo, assetById, contractAllowlist } from "./networks.ts";
import { isContractId, view } from "./stellar.ts";

export interface ResolvedAsset extends AssetInfo {
  /** native: XLM; classic: a trustline asset (its SAC is `contract`); launch: a DyorHQ launch; sac: any other token
   *  contract (SEP-41). */
  kind: "native" | "classic" | "sac" | "launch";
  /** In DyorHQ's registry, or launched on DyorHQ's launchpad. */
  verified: boolean;
  /** A logo bundled in the app, or null. */
  logo: string | null;
}

export function unsupported(id: string): ApiError {
  return new ApiError(400, "unsupported_asset", "DyorHQ doesn't support that token on Stellar.", { asset: id.slice(0, 80) });
}

/** A registry asset as a resolved one. */
export function registryAsset(a: AssetInfo): ResolvedAsset {
  return { ...a, kind: a.classic === "native" ? "native" : a.classic ? "classic" : "sac", verified: true, logo: a.logo ?? null };
}

/** "CODE:G…" (a classic asset's code, 1 to 12 letters or digits, and its issuer), or null. */
export function classicSpec(id: string): { code: string; issuer: string } | null {
  const m = id.match(/^([A-Za-z0-9]{1,12}):(G[A-Z2-7]{55})$/);
  if (!m || !StrKey.isValidEd25519PublicKey(m[2])) return null;
  return { code: m[1], issuer: m[2] };
}

/** A classic asset from its CODE:ISSUER: the registry's entry when it is one, otherwise an unverified asset named by
 *  its own code. Its SAC is its contract. No network or database call. */
export function classicAssetInfo(spec: string): ResolvedAsset {
  const c = classicSpec(spec);
  if (!c) throw unsupported(spec);
  const id = `${c.code}:${c.issuer}`;
  const known = env.network.assets.find((a) => a.classic === id);
  if (known) return registryAsset(known);
  const contract = new Asset(c.code, c.issuer).contractId(env.network.passphrase);
  return { id, code: c.code, name: c.code, decimals: 7, contract, classic: id, kind: "classic", verified: false, logo: null };
}

const CACHE_MAX = 500;
const onChain = new Map<string, ResolvedAsset>();

/** The asset `id` names, or 400 unsupported_asset. */
export async function resolveAsset(id: string): Promise<ResolvedAsset> {
  const known = assetById(env.network, id);
  if (known) return registryAsset(known);
  if (isContractId(id)) {
    const launch = await sql()`select token, symbol, name from lite.launches where token = ${id}`;
    if (launch.length) {
      const l = launch[0];
      return { id, code: String(l.symbol), name: String(l.name), decimals: 7, contract: id, classic: null, kind: "launch", verified: true, logo: null };
    }
    return await tokenContract(id);
  }
  if (classicSpec(id)) return classicAssetInfo(id);
  throw unsupported(id);
}

/** Any other token contract, named by itself: a classic asset's SAC (its name() is "CODE:ISSUER" and it is that
 *  asset's contract) resolves as the classic asset; a SEP-41 token by its own symbol() and name(), unverified. Kept
 *  per isolate. */
async function tokenContract(id: string): Promise<ResolvedAsset> {
  const cached = onChain.get(id);
  if (cached) return cached;
  let symbol: unknown, name: unknown, decimals: unknown;
  try {
    [symbol, name, decimals] = await Promise.all([view(id, "symbol"), view(id, "name"), view(id, "decimals")]);
  } catch {
    throw unsupported(id);
  }
  if (typeof symbol !== "string" || typeof name !== "string" || symbol === "" || !Number.isInteger(Number(decimals))) throw unsupported(id);
  const sac = name === "native" ? null : classicSpec(name);
  let asset: ResolvedAsset;
  if (name === "native" && Asset.native().contractId(env.network.passphrase) === id) {
    asset = registryAsset(assetById(env.network, "XLM")!);
  } else if (sac && new Asset(sac.code, sac.issuer).contractId(env.network.passphrase) === id) {
    asset = classicAssetInfo(name);
  } else {
    asset = { id, code: symbol, name, decimals: Number(decimals), contract: id, classic: null, kind: "sac", verified: false, logo: null };
  }
  if (onChain.size >= CACHE_MAX) onChain.clear();
  onChain.set(id, asset);
  return asset;
}

/** The launch tokens among `contracts` (DyorHQ's launchpad created them; lite.launches). The registry's and the pinned
 *  contracts never are, so only the others are looked up. */
export async function launchTokensAmong(contracts: string[]): Promise<string[]> {
  const known = new Set([...env.network.assets.map((a) => a.contract), ...Object.values(contractAllowlist(env.network)).flat()]);
  const ids = [...new Set(contracts.filter((c) => isContractId(c) && !known.has(c)))];
  if (ids.length === 0) return [];
  const rows = await sql()`select token from lite.launches where token = any(${ids})`;
  return rows.map((r) => String(r.token));
}

