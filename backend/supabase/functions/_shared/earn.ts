// Earn (docs/DESIGN-stellar-parity.md §6.10; Lite's counterpart of Monad's Perps): supply to Blend v2 lending pools,
// earn the supply APY, withdraw while the pool has liquidity.
// - Markets (public): each pool's reserves that are registry assets, with Blend's rates, the reserve's size and its
//   free liquidity in USD at the reference price (refprices.ts, through priceRef: Blend's test USDC as USDC), and the
//   pool's status. A pool is read through Blend's SDK and kept a minute.
// - Positions (a viewer route): what an account supplies, valued now. The owner's view adds DyorHQ's own record:
//   deposited and withdrawn, from the account's successful earn_deposit and earn_withdraw transactions, and earned =
//   supplied + withdrawn − deposited. The public view leaves those null.
// - History (public): the indexer's earn job snapshots every market into lite.earn_snapshots every 10 minutes.
// - Plans: a deposit or a withdrawal is one Blend submit from, spent by and paid to the user (verify.ts's call rule),
//   built here with the same stellar-sdk as the rest. A withdrawal of everything (`all`) leaves nothing behind.
import { PoolMetadata, PoolV2 } from "@blend-capital/blend-sdk";
import { xdr } from "@stellar/stellar-sdk";
import { accountView, needsTrustline } from "./account.ts";
import type { EarnHistory, EarnMarket, EarnMarkets, EarnPosition, View } from "./contract.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad } from "./http.ts";
import { AssetInfo, assetById, NetworkConfig } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { referencePrices, usdOf } from "./refprices.ts";
import { fromStroops, invoke, requireAccount, sv } from "./stellar.ts";
import { Intent } from "./verify.ts";

/** Blend RequestType (pool v2). */
export const REQUEST = { Supply: 0, Withdraw: 1 } as const;

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

/** Markets, and an account's public view, read a pool at most a minute old. An owner's positions and withdrawals read
 *  it now, so a deposit just made is valued at its own rate or a later one. */
const POOL_MAX_AGE_MS = MINUTE;
/** A pool's metadata (its status, reserve list and backstop rate) is kept a minute, even for a read made now. */
const METADATA_MAX_AGE_MS = MINUTE;

const TESTNET_NOTE = "Testnet rates are set by test activity, not real markets.";

export type BlendPool = NetworkConfig["contracts"]["blendPools"][number];
export type PoolStatus = NonNullable<EarnMarket["poolStatus"]>;

/** Blend v2's pool status (its config's `status`) as the app shows it (§6.10): 0 and 1 (active, set by the admin or by
 *  the backstop) active; 2 and 3 on ice, which pauses borrowing; 4 and 5 frozen, which pauses deposits too; 6, a pool
 *  still being set up, frozen. A status Blend doesn't define counts as frozen, so it never invites a deposit. */
export function poolStatusOf(status: number): PoolStatus {
  switch (status) {
    case 0:
    case 1:
      return "active";
    case 2:
    case 3:
      return "on_ice";
    default:
      return "frozen";
  }
}

// ------------------------------------------------------------------------------------------------ reading pools

/** What a market reads from a Blend reserve. */
export interface ReserveFigures {
  decimals: number;
  /** Fractions, Blend's estimates: the supply APY compounds weekly, the borrow APY daily. */
  supplyApy: number;
  borrowApy: number;
  utilization: number;
  /** Base units. */
  supplied: bigint;
  borrowed: bigint;
}

/** A pool as Earn reads it: Blend's status and the reserves by asset contract, in the pool's order. */
export interface PoolState {
  status: number;
  reserves: Map<string, ReserveFigures>;
}

/** What an account supplies to one reserve, in base units: as supply (what a withdrawal takes) and as collateral. */
export interface Supplied {
  supply: bigint;
  collateral: bigint;
}

/** Where pools are read: Blend's contracts through its SDK, or a stand-in in unit tests (replacePools). */
export interface PoolSource {
  /** The pool, read at most `maxAgeMs` ago (0: now). */
  read(pool: string, maxAgeMs: number): Promise<PoolState>;
  /** The pool, read at most `maxAgeMs` ago, and what `account` supplies to each of its reserves. */
  supplies(pool: string, account: string, maxAgeMs: number): Promise<{ state: PoolState; supplied: Map<string, Supplied> }>;
}

const loaded = new Map<string, { at: number; pool: PoolV2 }>();
const metadata = new Map<string, { at: number; meta: PoolMetadata }>();

/** The pool, loaded at most `maxAgeMs` ago, its reserves accrued to the time they were read. */
async function loadPool(id: string, maxAgeMs: number): Promise<PoolV2> {
  const hit = loaded.get(id);
  if (hit && Date.now() - hit.at < maxAgeMs) return hit.pool;
  const net = env.network;
  const network = { rpc: net.rpcUrl, passphrase: net.passphrase, opts: { allowHttp: net.rpcUrl.startsWith("http://") } };
  let meta = metadata.get(id);
  if (!meta || Date.now() - meta.at >= METADATA_MAX_AGE_MS) {
    meta = { at: Date.now(), meta: await PoolMetadata.load(network, id) };
    metadata.set(id, meta);
  }
  const pool = await PoolV2.loadWithMetadata(network, id, meta.meta);
  loaded.set(id, { at: Date.now(), pool });
  return pool;
}

function stateOf(pool: PoolV2): PoolState {
  const reserves = new Map<string, ReserveFigures>();
  for (const [asset, r] of pool.reserves) {
    reserves.set(asset, {
      decimals: r.config.decimals,
      supplyApy: r.estSupplyApy,
      borrowApy: r.estBorrowApy,
      utilization: r.getUtilizationFloat(),
      supplied: r.totalSupply(),
      borrowed: r.totalLiabilities(),
    });
  }
  return { status: pool.metadata.status, reserves };
}

/** Blend's pools on env.network's RPC. */
const blend: PoolSource = {
  async read(id, maxAgeMs) {
    return stateOf(await loadPool(id, maxAgeMs));
  },
  async supplies(id, account, maxAgeMs) {
    const pool = await loadPool(id, maxAgeMs);
    const user = await pool.loadUser(account);
    const supplied = new Map<string, Supplied>();
    for (const [asset, r] of pool.reserves) supplied.set(asset, { supply: user.getSupply(r), collateral: user.getCollateral(r) });
    return { state: stateOf(pool), supplied };
  },
};

let pools: PoolSource = blend;

/** Unit tests read pools from a stand-in instead of Blend's contracts; null puts Blend's back. */
export function replacePools(standIn: PoolSource | null): void {
  pools = standIn ?? blend;
}

function poolConfig(net: NetworkConfig, id: string): BlendPool {
  const p = net.contracts.blendPools.find((x) => x.id === id);
  if (!p) throw bad("bad_pool", "Unknown pool.");
  return p;
}

/** A registry asset; Earn offers no other (the phone signs for pinned token contracts only). */
function registryAsset(net: NetworkConfig, id: string): AssetInfo {
  const a = assetById(net, id);
  if (!a) throw bad("bad_asset", "DyorHQ doesn't support that asset on Stellar.");
  return a;
}

// ------------------------------------------------------------------------------------------------ markets

/** Base units in whole units of the asset. */
function wholeUnits(n: bigint, decimals: number): number {
  return Number(n) / 10 ** decimals;
}

/** USD to the cent, or null with no price (unknown is never 0). */
function usd(amount: number, priceUsd: number | null): number | null {
  return priceUsd === null ? null : Math.round(amount * priceUsd * 100) / 100;
}

/** A market as GET /v1/earn/markets answers it. Free liquidity is what suppliers could withdraw at once: supplied less
 *  borrowed. */
export function marketRow(pool: BlendPool, status: number, asset: AssetInfo, f: ReserveFigures, priceUsd: number | null): EarnMarket {
  const supplied = wholeUnits(f.supplied, f.decimals);
  const free = wholeUnits(f.supplied > f.borrowed ? f.supplied - f.borrowed : 0n, f.decimals);
  return {
    pool: pool.id,
    poolName: pool.name,
    asset: asset.contract,
    code: asset.code,
    decimals: f.decimals,
    supplyApy: f.supplyApy,
    borrowApy: f.borrowApy,
    utilization: f.utilization,
    totalSupplied: supplied,
    note: asset.note,
    totalSuppliedUsd: usd(supplied, priceUsd),
    freeLiquidityUsd: usd(free, priceUsd),
    priceUsd,
    poolStatus: poolStatusOf(status),
  };
}

/** GET /v1/earn/markets (public): every pool's reserves that are registry assets, in the pool's order. A reserve outside
 *  the registry (Blend's test wETH and wBTC) could never be supplied from Lite, so it isn't a market. */
export async function markets(net: NetworkConfig = env.network, now: number = Date.now()): Promise<EarnMarkets> {
  const [prices, states] = await Promise.all([
    referencePrices(now, net),
    Promise.all(net.contracts.blendPools.map((p) => pools.read(p.id, POOL_MAX_AGE_MS))),
  ]);
  const rows: EarnMarket[] = [];
  net.contracts.blendPools.forEach((p, i) => {
    for (const [id, f] of states[i].reserves) {
      const asset = assetById(net, id);
      if (asset) rows.push(marketRow(p, states[i].status, asset, f, usdOf(asset, prices)));
    }
  });
  return { markets: rows, note: net.name === "testnet" ? TESTNET_NOTE : null };
}

// ------------------------------------------------------------------------------------------------ positions

/** What DyorHQ recorded of one account in one market, in base units. */
export interface Flows {
  deposited: bigint;
  withdrawn: bigint;
  /** Successful deposits recorded. */
  deposits: number;
}

/** A logged transaction as positions read it (lite.tx_log). */
export interface LoggedFlow {
  kind: string;
  intent: Intent | null;
}

/** An account's successful earn transactions → its recorded deposits and withdrawals by market (`<pool>:<asset>`): a
 *  deposit counts what its intent spends, a withdrawal what it receives, in the pool its submit call names. */
export function flowsOf(rows: LoggedFlow[]): Map<string, Flows> {
  const out = new Map<string, Flows>();
  for (const { kind, intent } of rows) {
    const deposit = kind === "earn_deposit";
    if (!deposit && kind !== "earn_withdraw") continue;
    const pool = intent?.calls?.find((c) => c.fn === "submit")?.contract;
    const amounts = deposit ? intent?.spend : intent?.receive;
    if (!pool || !amounts) continue;
    for (const [asset, amount] of Object.entries(amounts)) {
      if (typeof amount !== "string" || !/^[0-9]{1,30}$/.test(amount)) continue;
      const key = `${pool}:${asset}`;
      const f = out.get(key) ?? { deposited: 0n, withdrawn: 0n, deposits: 0 };
      if (deposit) {
        f.deposited += BigInt(amount);
        f.deposits += 1;
      } else {
        f.withdrawn += BigInt(amount);
      }
      out.set(key, f);
    }
  }
  return out;
}

/** DyorHQ's record of a position (§6.10): earned = supplied now + withdrawn − deposited. It is complete only when a
 *  deposit was recorded; without one, the deposits (made elsewhere, or before they were recorded) are missing. */
export function earnedOf(supplied: bigint, flows: Flows | undefined): Pick<EarnPosition, "deposited" | "withdrawn" | "earned" | "earnedComplete"> {
  const f = flows ?? { deposited: 0n, withdrawn: 0n, deposits: 0 };
  return {
    deposited: f.deposited.toString(),
    withdrawn: f.withdrawn.toString(),
    earned: (supplied + f.withdrawn - f.deposited).toString(),
    earnedComplete: f.deposits > 0,
  };
}

/** The public view's record: DyorHQ's history, none of it shown. */
const NOT_SHOWN = { deposited: null, withdrawn: null, earned: null, earnedComplete: false };

/** A position as GET /v1/earn/positions and holdings' earn rows answer it; `flows` null in the public view. */
export function positionRow(pool: BlendPool, asset: AssetInfo, f: ReserveFigures, supplied: bigint, priceUsd: number | null, flows: Map<string, Flows> | null): EarnPosition {
  return {
    pool: pool.id,
    asset: asset.contract,
    code: asset.code,
    supplied: supplied.toString(),
    poolName: pool.name,
    ...(flows ? earnedOf(supplied, flows.get(`${pool.id}:${asset.contract}`)) : NOT_SHOWN),
    supplyApy: f.supplyApy,
    valueUsd: usd(wholeUnits(supplied, f.decimals), priceUsd),
  };
}

async function recordedFlows(account: string): Promise<Map<string, Flows>> {
  const rows = await sql()`
    select kind, intent from lite.tx_log
     where address = ${account} and kind in ('earn_deposit', 'earn_withdraw') and status = 'success'`;
  return flowsOf(rows as unknown as LoggedFlow[]);
}

/** GET /v1/earn/positions (a viewer route) and holdings' earn rows: each market the account supplies to, as supply or
 *  collateral, valued now. The owner's view reads the pools now and adds DyorHQ's record (earnedOf); the public view
 *  reads them as markets do and shows on-chain facts only. */
export async function positions(account: string, scope: View, net: NetworkConfig = env.network, now: number = Date.now()): Promise<EarnPosition[]> {
  const owner = scope === "owner";
  const maxAge = owner ? 0 : POOL_MAX_AGE_MS;
  const [prices, held, flows] = await Promise.all([
    referencePrices(now, net),
    Promise.all(net.contracts.blendPools.map((p) => pools.supplies(p.id, account, maxAge))),
    owner ? recordedFlows(account) : null,
  ]);
  const rows: EarnPosition[] = [];
  net.contracts.blendPools.forEach((p, i) => {
    const { state, supplied } = held[i];
    for (const [id, f] of state.reserves) {
      const asset = assetById(net, id);
      const s = supplied.get(id);
      const total = s ? s.supply + s.collateral : 0n;
      if (asset && total > 0n) rows.push(positionRow(p, asset, f, total, usdOf(asset, prices), flows));
    }
  });
  return rows;
}

// ------------------------------------------------------------------------------------------------ history

export type EarnRange = "week" | "month";

const RANGE_MS: Record<EarnRange, number> = { week: 7 * DAY, month: 30 * DAY };

/** A history point stands for an hour: the last snapshot taken in it. */
const POINT_MS = 60 * MINUTE;

/** ?range=, week when absent. */
export function rangeArg(v: string | null): EarnRange {
  if (v === null || v === "") return "week";
  if (v === "week" || v === "month") return v;
  throw bad("bad_range", "range is week or month.");
}

/** A snapshot as history reads it (postgres.js answers numeric as strings). */
export interface SnapshotRow {
  taken_at: Date | string;
  supply_apy: string | number;
  utilization: string | number;
}

/** Snapshots, oldest first → history points, oldest first: the last snapshot of each hour, at the time it was taken. */
export function historyPoints(rows: SnapshotRow[]): EarnHistory["points"] {
  const points: EarnHistory["points"] = [];
  let hour: number | null = null;
  for (const r of rows) {
    const t = new Date(r.taken_at).getTime();
    const point = { t: new Date(t).toISOString(), supplyApy: Number(r.supply_apy), utilization: Number(r.utilization) };
    if (Math.floor(t / POINT_MS) === hour) points[points.length - 1] = point;
    else points.push(point);
    hour = Math.floor(t / POINT_MS);
  }
  return points;
}

/** GET /v1/earn/history (public): one market's supply APY and utilization over the range, from the snapshots. */
export async function history(pool: string | null, asset: string | null, range: string | null, net: NetworkConfig = env.network, now: number = Date.now()): Promise<EarnHistory> {
  const reach = RANGE_MS[rangeArg(range)];
  const p = poolConfig(net, pool ?? "");
  const a = registryAsset(net, asset ?? "");
  const rows = await sql()`
    select taken_at, supply_apy, utilization from lite.earn_snapshots
     where pool = ${p.id} and asset = ${a.contract} and taken_at > ${new Date(now - reach)}
     order by taken_at`;
  return { points: historyPoints(rows as unknown as SnapshotRow[]) };
}

// ------------------------------------------------------------------------------------------------ snapshots

/** Snapshots are kept 400 days: history reaches back a month, and a longer view later has a year's. */
const SNAPSHOT_KEEP_MS = 400 * DAY;

export interface SnapshotResult {
  /** Markets snapshotted. */
  markets: number;
  errors?: string[];
}

const message = (err: unknown) => String((err as Error)?.message ?? err).slice(0, 160);

/** The earn job (lite-indexer, every 10 minutes): every market's rates, read now, into lite.earn_snapshots; snapshots
 *  older than SNAPSHOT_KEEP_MS go. A pool that can't be read, or a reserve whose figures aren't numbers, is named in the
 *  result, and the others are still taken. */
export async function snapshot(net: NetworkConfig = env.network, now: number = Date.now()): Promise<SnapshotResult> {
  const at = new Date(now);
  const errors: string[] = [];
  const states = await Promise.all(net.contracts.blendPools.map(async (p) => {
    try {
      return await pools.read(p.id, 0);
    } catch (err) {
      errors.push(`${p.name}: ${message(err)}`);
      return null;
    }
  }));
  let taken = 0;
  for (const [i, p] of net.contracts.blendPools.entries()) {
    const state = states[i];
    if (!state) continue;
    for (const [id, f] of state.reserves) {
      const asset = assetById(net, id);
      if (!asset) continue;
      if (!Number.isFinite(f.supplyApy) || !Number.isFinite(f.utilization)) {
        errors.push(`${p.name} ${asset.code}: no rate`);
        continue;
      }
      await sql()`
        insert into lite.earn_snapshots (pool, asset, taken_at, supply_apy, borrow_apy, utilization, supplied, borrowed, pool_status)
        values (${p.id}, ${asset.contract}, ${at}, ${f.supplyApy}::numeric, ${Number.isFinite(f.borrowApy) ? f.borrowApy : null}::numeric,
                ${f.utilization}::numeric, ${f.supplied.toString()}::numeric, ${f.borrowed.toString()}::numeric, ${state.status}::smallint)
        on conflict (pool, asset, taken_at) do nothing`;
      taken++;
    }
  }
  await sql()`delete from lite.earn_snapshots where taken_at < ${new Date(now - SNAPSHOT_KEEP_MS)}`;
  return { markets: taken, ...(errors.length ? { errors } : {}) };
}

// ------------------------------------------------------------------------------------------------ plans

/** POST /v1/earn/build: a deposit, or a withdrawal, after enabling the asset when its trustline is missing. A withdrawal
 *  asks for at most what the account supplies (as supply, which is what it takes): Blend pays a larger request only up
 *  to that, and the review would show more than arrives. A withdrawal of `all` takes the whole supply with whatever it
 *  earns until it lands (submitAmounts); `amount` is then the least the user accepts: what their screen showed. */
export async function buildEarn(user: string, action: "deposit" | "withdraw", poolId: string, assetId: string, amount: bigint, all = false): Promise<PlanView> {
  if (all && action !== "withdraw") throw bad("bad_arg", "all is for a withdrawal only.");
  const net = env.network;
  const pool = poolConfig(net, poolId);
  const asset = registryAsset(net, assetId);
  const steps: { label: string; spec: { kind: string; [k: string]: unknown } }[] = [];
  if (action === "withdraw") {
    const held = (await pools.supplies(pool.id, user, 0)).supplied.get(asset.contract);
    if (!held) throw bad("bad_asset", "This pool doesn't have that asset.");
    if (amount > held.supply) throw bad("bad_amount", "That's more than you can withdraw from this market.");
    const trust = needsTrustline((await accountView(user)).balances, asset.id);
    if (trust) steps.push({ label: `Enable ${asset.code}`, spec: { kind: "trust", asset: trust } });
  } else if (!(await pools.read(pool.id, POOL_MAX_AGE_MS)).reserves.has(asset.contract)) {
    throw bad("bad_asset", "This pool doesn't have that asset.");
  }
  steps.push({
    label: action === "deposit" ? "Deposit to Earn" : "Withdraw from Earn",
    spec: {
      kind: "blend_submit",
      pool: pool.id,
      asset: asset.contract,
      amount: amount.toString(),
      requestType: action === "deposit" ? REQUEST.Supply : REQUEST.Withdraw,
      ...(all ? { all: true } : {}),
    },
  });
  return await createPlan(user, action === "deposit" ? "earn_deposit" : "earn_withdraw", steps);
}

/** A withdrawal of everything asks Blend for this share more than the account supplies when its step is built: Blend
 *  pays a withdrawal larger than the supply only up to it and burns every b-token, so the interest earned until the
 *  transaction lands comes too, and no dust stays in the pool. 1% is more than a supply rate below about 50,000% a year
 *  earns in a transaction's 10-minute window (USER_TX_TIMEOUT_S). */
const ALL_HEADROOM_DIVISOR = 100n;

/** What a submit step asks Blend for (`request`) and declares it receives or spends (`receive`), in base units. A
 *  deposit and a withdrawal of an amount: that amount, both. A withdrawal of `all`: the request is the account's supply
 *  when the step is built (`supply`, read then) and 1% more, and the declared amount that supply, which is at least
 *  what the user saw (`spec.amount`) and at most what arrives; a supply below what the user saw is refused. */
export function submitAmounts(spec: { readonly [key: string]: unknown }, supply: bigint | null): { request: string; receive: string } {
  const amount = String(spec.amount);
  if (spec.all !== true) return { request: amount, receive: amount };
  if (Number(spec.requestType) !== REQUEST.Withdraw) throw bad("bad_arg", "all is for a withdrawal only.");
  if (supply === null || supply < BigInt(amount)) throw bad("bad_amount", "That's more than you can withdraw from this market.");
  return { request: (supply + supply / ALL_HEADROOM_DIVISOR + 1n).toString(), receive: supply.toString() };
}

function requestVec(asset: string, amount: string, type: number): xdr.ScVal {
  // struct Request { address, amount, request_type } — map keys in sorted order.
  const entry = (k: string, v: xdr.ScVal) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: v });
  return sv.vec([xdr.ScVal.scvMap([entry("address", sv.addr(asset)), entry("amount", sv.i128(amount)), entry("request_type", sv.u32(type))])]);
}

/** Blend's `submit(from, spender, to, requests)` with one request: from the user's position, spent from the user's
 *  account and paid to it, as verify.ts's call rule requires. */
export function submitArgs(user: string, asset: string, amount: string, type: number): xdr.ScVal[] {
  return [sv.addr(user), sv.addr(user), sv.addr(user), requestVec(asset, amount, type)];
}

/** What a submit does, as the phone checks and shows it: a deposit spends `amount`, a withdrawal receives it. */
export function submitIntent(pool: BlendPool, asset: AssetInfo, amount: string, type: number): Intent {
  const human = fromStroops(amount, asset.decimals);
  const calls = [{ contract: pool.id, fn: "submit" }];
  const display = { asset: asset.code, amount, pool: pool.name };
  return type === REQUEST.Supply
    ? { kind: "earn_deposit", summary: `Deposit ${human} ${asset.code} to earn`, spend: { [asset.contract]: amount }, calls, display }
    : { kind: "earn_withdraw", summary: `Withdraw ${human} ${asset.code}`, spend: {}, receive: { [asset.contract]: amount }, calls, display };
}

registerBuilder("blend_submit", async (user, spec) => {
  const net = env.network;
  const pool = poolConfig(net, String(spec.pool));
  const asset = registryAsset(net, String(spec.asset));
  const type = Number(spec.requestType);
  if (type !== REQUEST.Supply && type !== REQUEST.Withdraw) throw new ApiError(400, "bad_request_type", "Only deposit and withdraw are offered.");
  // A withdrawal of everything reads the supply now, when its transaction is built.
  const supply = spec.all === true ? (await pools.supplies(pool.id, user, 0)).supplied.get(asset.contract)?.supply ?? null : null;
  const { request, receive } = submitAmounts(spec, supply);
  const acct = await requireAccount(user);
  const tx = await invoke(acct, pool.id, "submit", submitArgs(user, asset.contract, request, type));
  return { tx, intent: submitIntent(pool, asset, receive, type) };
});
