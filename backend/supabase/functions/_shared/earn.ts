// Earn (Lite's replacement for Perps): supply to Blend v2 lending pools, earn the supply APY, withdraw any time
// the pool has liquidity. Reads use Blend's SDK; transactions are built here with the same stellar-sdk as the rest.
import { PoolV2 } from "@blend-capital/blend-sdk";
import { xdr } from "@stellar/stellar-sdk";
import { accountView, needsTrustline } from "./account.ts";
import { env } from "./env.ts";
import { ApiError, bad } from "./http.ts";
import { assetById } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { fromStroops, invoke, requireAccount, sv } from "./stellar.ts";
import { Intent } from "./verify.ts";

/** Blend RequestType (pool v2). */
export const REQUEST = { Supply: 0, Withdraw: 1 } as const;

export interface Market {
  pool: string;
  poolName: string;
  asset: string;
  code: string;
  decimals: number;
  /** Fractions: 0.05 = 5%. Testnet rates are not real-world rates. */
  supplyApy: number;
  borrowApy: number;
  utilization: number;
  totalSupplied: number;
  note?: string;
}

const cache = new Map<string, { at: number; pool: PoolV2 }>();

async function loadPool(id: string): Promise<PoolV2> {
  const hit = cache.get(id);
  if (hit && Date.now() - hit.at < 60_000) return hit.pool;
  const pool = await PoolV2.load({ rpc: env.network.rpcUrl, passphrase: env.network.passphrase }, id);
  cache.set(id, { at: Date.now(), pool });
  return pool;
}

function poolConfig(id: string) {
  const p = env.network.contracts.blendPools.find((x) => x.id === id);
  if (!p) throw bad("bad_pool", "Unknown pool.");
  return p;
}

export async function markets(): Promise<Market[]> {
  const out: Market[] = [];
  for (const p of env.network.contracts.blendPools) {
    const pool = await loadPool(p.id);
    for (const [assetId, r] of pool.reserves) {
      // Only assets in the network registry: the phone signs for pinned token contracts only, so a reserve outside it
      // (Blend's test wETH and wBTC) could never be supplied from Lite.
      const reg = assetById(env.network, assetId);
      if (!reg) continue;
      out.push({
        pool: p.id,
        poolName: p.name,
        asset: assetId,
        code: reg.code,
        decimals: r.config.decimals,
        supplyApy: r.estSupplyApy,
        borrowApy: r.estBorrowApy,
        utilization: r.getUtilizationFloat(),
        totalSupplied: r.totalSupplyFloat(),
        note: reg.note,
      });
    }
  }
  return out;
}

export async function positions(user: string) {
  const out: { pool: string; asset: string; code: string; supplied: string; bTokens: string }[] = [];
  for (const p of env.network.contracts.blendPools) {
    const pool = await loadPool(p.id);
    const pu = await pool.loadUser(user);
    for (const [assetId, r] of pool.reserves) {
      const reg = assetById(env.network, assetId);
      if (!reg) continue; // as in markets(): Lite can't have supplied an asset outside the registry
      const supplied = pu.getSupply(r);
      const collateral = pu.getCollateral(r);
      const total = supplied + collateral;
      if (total > 0n) {
        out.push({
          pool: p.id,
          asset: assetId,
          code: reg.code,
          supplied: total.toString(),
          bTokens: (pu.getSupplyBTokens(r) + pu.getCollateralBTokens(r)).toString(),
        });
      }
    }
  }
  return out;
}

export async function buildEarn(user: string, action: "deposit" | "withdraw", poolId: string, asset: string, amount: bigint): Promise<PlanView> {
  poolConfig(poolId);
  const pool = await loadPool(poolId);
  if (!pool.reserves.has(asset)) throw bad("bad_asset", "This pool doesn't have that asset.");
  const reg = assetById(env.network, asset);
  if (!reg) throw bad("bad_asset", "Lite doesn't support that asset.");
  const steps: { label: string; spec: { kind: string; [k: string]: unknown } }[] = [];
  if (action === "withdraw" && reg) {
    const acct = await accountView(user);
    const trust = needsTrustline(acct.balances, reg.id);
    if (trust) steps.push({ label: `Enable ${reg.code}`, spec: { kind: "trust", asset: trust } });
  }
  steps.push({
    label: action === "deposit" ? "Deposit to Earn" : "Withdraw from Earn",
    spec: { kind: "blend_submit", pool: poolId, asset, amount: amount.toString(), requestType: action === "deposit" ? REQUEST.Supply : REQUEST.Withdraw },
  });
  return await createPlan(user, action === "deposit" ? "earn_deposit" : "earn_withdraw", steps);
}

function requestVec(asset: string, amount: string, type: number): xdr.ScVal {
  // struct Request { address, amount, request_type } — map keys in sorted order.
  const entry = (k: string, v: xdr.ScVal) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: v });
  return sv.vec([xdr.ScVal.scvMap([entry("address", sv.addr(asset)), entry("amount", sv.i128(amount)), entry("request_type", sv.u32(type))])]);
}

registerBuilder("blend_submit", async (user, spec) => {
  const poolId = String(spec.pool);
  const asset = String(spec.asset);
  const amount = String(spec.amount);
  const type = Number(spec.requestType);
  if (type !== REQUEST.Supply && type !== REQUEST.Withdraw) throw new ApiError(400, "bad_request_type", "Only deposit and withdraw are offered.");
  const acct = await requireAccount(user);
  const tx = await invoke(acct, poolId, "submit", [sv.addr(user), sv.addr(user), sv.addr(user), requestVec(asset, amount, type)]);
  const reg = assetById(env.network, asset);
  const code = reg?.code ?? "token";
  const human = fromStroops(amount, reg?.decimals ?? 7);
  const intent: Intent =
    type === REQUEST.Supply
      ? { kind: "earn_deposit", summary: `Deposit ${human} ${code} to earn`, spend: { [asset]: amount }, calls: [{ contract: poolId, fn: "submit" }], display: { asset: code, amount, pool: poolConfig(poolId).name } }
      : { kind: "earn_withdraw", summary: `Withdraw ${human} ${code}`, spend: {}, receive: { [asset]: amount }, calls: [{ contract: poolId, fn: "submit" }], display: { asset: code, amount, pool: poolConfig(poolId).name } };
  return { tx, intent };
});
