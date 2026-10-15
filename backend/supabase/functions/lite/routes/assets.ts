// Asset search: GET /v1/assets?q= (§6.6), for the token picker and Home's search. A viewer route: `held` is about the
// token's account, in the public view about ?address=, and false with neither. At most 30 results, each found once:
// - registry assets whose code or name contains q (case-insensitively), or whose id, contract or CODE:G… is q;
// - listed DyorHQ launches (launchpad.ts launchSearch): the token id exactly, or the ticker or name containing q;
// - the account's other trustlines whose code contains q, then an exact CODE:G…: unverified, named as their issuer
//   publishes them (directory.ts) or not at all;
// - an exact C… that is none of those: the token's own symbol(), name() and decimals(), read live, unverified. A launch
//   the launchpad lists no more (a deployment's smoke launch) is never found (§9).
// With no q: the registry, and the account's other trustlines.
import { classicAssetInfo, classicSpec, resolveAsset } from "../../_shared/assets.ts";
import type { AssetResult, AssetSearch } from "../../_shared/contract.ts";
import { sql } from "../../_shared/db.ts";
import { directory } from "../../_shared/directory.ts";
import { env } from "../../_shared/env.ts";
import { bad, json, PUBLIC_VIEW_CACHE, Router } from "../../_shared/http.ts";
import { launchSearch } from "../../_shared/launchpad.ts";
import { AssetInfo } from "../../_shared/networks.ts";
import { ClassicAccount, classicBalances, isContractId, sv, view } from "../../_shared/stellar.ts";
import { viewer } from "./auth.ts";

export const MAX_RESULTS = 30;
/** The longest q: a CODE:G… (12 + 1 + 56 characters). */
const Q_MAX = 69;

function registryResult(a: AssetInfo, held: boolean): AssetResult {
  return { id: a.id, kind: "registry", code: a.code, name: a.name, contract: a.contract, classic: a.classic, verified: true, held };
}

function classicResult(asset: string, name: string | null, held: boolean): AssetResult {
  const info = classicAssetInfo(asset);
  return { id: info.id, kind: "classic", code: info.code, name, contract: info.contract, classic: info.classic, verified: false, held };
}

/** Whether `account` holds some of a token contract, read live; false when that read fails. */
async function holdsToken(contract: string, account: string): Promise<boolean> {
  try {
    return BigInt(await view(contract, "balance", [sv.addr(account)])) > 0n;
  } catch {
    return false;
  }
}

export async function searchAssets(q: string, account: string | null): Promise<AssetResult[]> {
  const net = env.network;
  const lower = q.toLowerCase();
  const contains = (s: string | null) => s !== null && s.toLowerCase().includes(lower);
  const [acct, launches, heldLaunches] = await Promise.all([
    account ? classicBalances(account) : Promise.resolve(null as ClassicAccount | null),
    launchSearch(q),
    account && q ? sql()`select token from lite.token_balances where address = ${account} and balance > 0` : Promise.resolve([]),
  ]);
  const balance = (classic: string | null) => BigInt(acct?.balances.find((b) => b.asset === classic)?.balance ?? "0");
  const out: AssetResult[] = [];
  const add = (r: AssetResult) => {
    if (out.length < MAX_RESULTS && !out.some((x) => x.id === r.id)) out.push(r);
  };

  for (const a of net.assets) {
    if (!q || a.id === q || a.contract === q || a.classic === q || contains(a.code) || contains(a.name)) add(registryResult(a, balance(a.classic) > 0n));
  }
  const held = new Set(heldLaunches.map((t) => String(t.token)));
  for (const l of launches) add({ ...(l as Omit<AssetResult, "held">), held: held.has(String(l.id)) });

  const lines = (acct?.balances ?? [])
    .map((b) => b.asset)
    .filter((asset) => asset !== "native" && !net.assets.some((a) => a.classic === asset) && (!q || contains(asset.split(":")[0])));
  const exact = classicSpec(q) && !net.assets.some((a) => a.classic === q) ? [q] : [];
  const classics = [...new Set([...lines, ...exact])];
  if (classics.length) {
    const names = await directory(classics, net);
    for (const asset of classics) add(classicResult(asset, names.get(asset)?.name ?? null, balance(asset) > 0n));
  }

  if (isContractId(q) && !out.some((r) => r.contract === q)) {
    // A launch is found above when it is listed; resolveAsset names any other contract as it names itself.
    const asset = await resolveAsset(q).catch(() => null);
    if (asset && asset.kind === "sac") {
      add({ id: asset.id, kind: "contract", code: asset.code, name: asset.name, contract: asset.contract, classic: null, verified: false, held: account ? await holdsToken(q, account) : false });
    } else if (asset && asset.kind !== "launch") {
      const registry = net.assets.find((a) => a.contract === asset.contract);
      if (registry) add(registryResult(registry, balance(registry.classic) > 0n));
      else add(classicResult(asset.classic!, (await directory([asset.classic!], net)).get(asset.classic!)?.name ?? null, balance(asset.classic) > 0n));
    }
  }
  return out;
}

export function register(router: Router): void {
  router.on("GET /v1/assets", async ({ req, url }) => {
    const v = await viewer(req);
    const q = (url.searchParams.get("q") ?? "").trim();
    if (q.length > Q_MAX) throw bad("bad_arg", `q is at most ${Q_MAX} characters.`);
    const body: AssetSearch = { results: await searchAssets(q, v.address), view: v.scope };
    return v.scope === "public" ? json(body, 200, PUBLIC_VIEW_CACHE) : json(body);
  });
}
