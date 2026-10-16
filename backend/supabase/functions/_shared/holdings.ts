// Holdings (docs/DESIGN-stellar-parity.md §6.5): everything an account holds, valued at today's prices, for Home's
// balance card, My Holdings, the allocation ring and Portfolio's assets. A viewer route (§6.0): the owner's view with a
// token, the public view of ?address= without one.
// - spot: XLM and every trustline (liquidity-pool shares aside), the registry's assets as themselves and any other as
//   an unverified classic asset, named from the asset directory (directory.ts) and priced only in the registry.
// - earn: the account's Blend positions (earn.ts).
// - launch: the DyorHQ launch tokens it holds, counted here only. For the owner, the indexed balance
//   (lite.token_balances, and every launch it traded) is confirmed by a live balance(), at most 50 at once; when that
//   read fails, the indexed one stands, marked stale. The public view reads the indexed balances only: no RPC call for
//   an unauthenticated caller. Each is valued at its launch's price (launchpad.ts).
// - moments: the editions it holds (moments.ts), worth 0: an edition has no market (as Monad counts "no market yet").
// Each part is read on its own: one that fails is "failed" in `parts`, its total null, and so is the account's total.
// Whether the account exists is never a guess: Horizon's answer (the spot part's) or, when Horizon couldn't read it,
// RPC's; when neither answers, the request fails (502) rather than say it doesn't.
// change24h is Σ value × c / (1 + c) over the priced holdings with a 24-hour change c: the USD the account's value moved
// by; pct is that over the value a day ago. It is complete when every part was read and every holding has both.
// The public view leaves DyorHQ's history null (Earn's record, a launch's cost basis and P&L), answers every account
// alike, member or not, and is kept 15 s per address.
import type postgres from "postgres";
import type { EarnPosition, Holdings, LaunchHolding, SpotHolding, Usd, View } from "./contract.ts";
import { classicAssetInfo } from "./assets.ts";
import { num, sql } from "./db.ts";
import { directory } from "./directory.ts";
import { positions } from "./earn.ts";
import { env } from "./env.ts";
import { baseReserve, positionOf as xlmPositionOf } from "./fees.ts";
import { ApiError } from "./http.ts";
import { Fill, launchRowOf, positionOf, PriceContext, scaled, unitsText } from "./launchpad.ts";
import { owned } from "./moments.ts";
import { AssetInfo, assetById, NetworkConfig, PriceRef } from "./networks.ts";
import { pricingOf, referencePrices, RefPrice, REFS } from "./refprices.ts";
import { usd4 } from "./stats.ts";
import { ClassicAccount, classicBalances, Keypair, rpcServer, sv, view, xdr } from "./stellar.ts";

type Row = postgres.Row;

const DAY = 86_400_000;
/** Live balance() reads under way at once. */
export const LIVE_READS = 50;
/** The most launch tokens a holdings answer lists. */
const LAUNCH_MAX = 500;

const big = (v: unknown): bigint => BigInt(num(v).split(".")[0]);
const known = (v: unknown): boolean => v !== null && v !== undefined;
/** A USD amount: to the cent. */
const usdAmount = (v: number): number => Math.round(v * 100) / 100 || 0;
/** A change: 4 decimals. */
const fraction4 = (v: number): number => Math.round(v * 10_000) / 10_000 || 0;

// ------------------------------------------------------------------------------------------------ spot

/** A registry asset's row, priced through its reference. Blend's test USDC, the registry's unlisted asset, is a test
 *  asset (as the markets badge it). */
function registryRow(a: AssetInfo, balance: string, refs: Record<PriceRef, RefPrice>): SpotHolding {
  const p = a.priceRef ? refs[a.priceRef] : null;
  const priceUsd = p?.usd ?? null;
  return {
    id: a.id,
    kind: "registry",
    contract: a.contract,
    classic: a.classic,
    code: a.code,
    name: a.name,
    decimals: a.decimals,
    balance,
    enabled: true,
    verified: true,
    badges: a.listed === true ? [] : ["testAsset"],
    note: a.note ?? null,
    logo: a.logo ?? null,
    priceUsd,
    valueUsd: priceUsd === null ? null : usd4((Number(balance) / 10 ** a.decimals) * priceUsd),
    change24h: priceUsd === null ? null : p!.change24h,
  };
}

/** A trustline outside the registry: unverified, named as its issuer publishes it (or not at all), unpriced. */
function classicRow(asset: string, balance: string, name: string | null): SpotHolding {
  const info = classicAssetInfo(asset);
  return {
    id: info.id,
    kind: "classic",
    contract: info.contract,
    classic: info.classic,
    code: info.code,
    name,
    decimals: info.decimals,
    balance,
    enabled: true,
    verified: false,
    badges: ["unverified"],
    note: null,
    logo: null,
    priceUsd: null,
    valueUsd: null,
    change24h: null,
  };
}

/** XLM and the registry's other assets the account has enabled, in registry order, then every other trustline. */
async function spotRows(acct: ClassicAccount | null, refs: Record<PriceRef, RefPrice>, net: NetworkConfig): Promise<SpotHolding[]> {
  if (!acct) return [];
  const rows: SpotHolding[] = [];
  for (const a of net.assets) {
    const line = acct.balances.find((b) => b.asset === a.classic);
    if (line) rows.push(registryRow(a, line.balance, refs));
  }
  const others = acct.balances.filter((b) => b.asset !== "native" && !net.assets.some((a) => a.classic === b.asset));
  const names = await directory(others.map((b) => b.asset), net);
  for (const b of others) rows.push(classicRow(b.asset, b.balance, names.get(b.asset)?.name ?? null));
  return rows;
}

// ------------------------------------------------------------------------------------------------ launch tokens

/** `fn` over `items`, at most `limit` at once, in order. */
async function mapLimited<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

/** An account's curve trades and pool swaps in `tokens`, oldest first, by token (as launchpad.ts adds a position up). */
async function fillsOf(address: string, tokens: string[]): Promise<Map<string, Fill[]>> {
  const out = new Map<string, Fill[]>();
  if (tokens.length === 0) return out;
  const rows = await sql()`
    select token, side, quote_amount, token_amount from (
      select token, side, quote_amount, token_amount, ts, event_id from lite.launch_trades where trader = ${address} and token = any(${tokens}::text[])
      union all
      select token, side, quote_amount, token_amount, ts, event_id from lite.pool_swaps where trader = ${address} and token = any(${tokens}::text[])
    ) as f order by ts, event_id`;
  for (const f of rows) {
    const token = String(f.token);
    if (!out.has(token)) out.set(token, []);
    out.get(token)!.push({ side: f.side === "sell" ? "sell" : "buy", quote: big(f.quote_amount), tokens: big(f.token_amount) });
  }
  return out;
}

/** What launchpad.ts's figures need: the reference prices now and, for a launch older than a day with a price then,
 *  a day ago. */
async function priceContext(rows: Row[], refs: Record<PriceRef, RefPrice>, net: NetworkConfig, now: number): Promise<PriceContext> {
  const p: PriceContext = { net, now, refs, dayAgo: null };
  if (rows.some((r) => known(r.price_24h) && now - new Date(r.created_at).getTime() >= DAY)) {
    const found = await sql()`select ref, lite.ref_usd_at(ref, ${new Date(now - DAY)}) as usd from unnest(${REFS}::text[]) as ref`;
    const usd = (ref: PriceRef) => found.find((f) => f.ref === ref)?.usd;
    p.dayAgo = Object.fromEntries(REFS.map((ref) => [ref, known(usd(ref)) ? Number(usd(ref)) : null])) as Record<PriceRef, number | null>;
  }
  return p;
}

/** The launch tokens `address` holds: those indexed as held and, for the owner, those it traded (an index that trails
 *  its last trade still lists them), each with its indexed balance and its price a day ago. */
function heldLaunches(address: string, owner: boolean, now: number): Promise<Row[]> {
  const traded = owner
    ? sql()`union select token from lite.launch_trades where trader = ${address}
            union select token from lite.pool_swaps where trader = ${address}`
    : sql()``;
  return sql()`
    select l.*, coalesce(tb.balance, 0) as indexed_balance, lite.token_price_at(l.token, ${new Date(now - DAY)}) as price_24h
      from lite.launches l
      left join lite.token_balances tb on tb.token = l.token and tb.address = ${address}
     where l.token in (select token from lite.token_balances where address = ${address} and balance > 0 ${traded})
     order by l.created_at desc, l.token
     limit ${LAUNCH_MAX}` as unknown as Promise<Row[]>;
}

async function launchRows(address: string, owner: boolean, refs: Record<PriceRef, RefPrice>, net: NetworkConfig, now: number): Promise<LaunchHolding[]> {
  const rows = await heldLaunches(address, owner, now);
  const tokens = rows.map((r) => String(r.token));
  const [p, balances, fills] = await Promise.all([
    priceContext(rows, refs, net, now),
    owner
      ? mapLimited(rows, LIVE_READS, async (r) => {
        try {
          return { balance: BigInt(await view(String(r.token), "balance", [sv.addr(address)])), stale: false };
        } catch {
          return { balance: big(r.indexed_balance), stale: true };
        }
      })
      : rows.map((r) => ({ balance: big(r.indexed_balance), stale: false })),
    owner ? fillsOf(address, tokens) : null,
  ]);
  const out: LaunchHolding[] = [];
  rows.forEach((r, i) => {
    const { balance, stale } = balances[i];
    if (balance <= 0n) return;
    const launch = launchRowOf(r, p);
    const quote = assetById(net, launch.quote);
    const quoteUsd = quote?.priceRef ? refs[quote.priceRef].usd : null;
    const inUsd = (v: bigint) => (quoteUsd === null ? null : usdAmount(Number(unitsText(v, quote?.decimals)) * quoteUsd));
    const position = fills ? positionOf(fills.get(launch.token) ?? [], balance, scaled(launch.priceQuote)) : null;
    out.push({
      token: launch.token,
      symbol: launch.symbol,
      name: launch.name,
      image: launch.image ?? null,
      balance: balance.toString(),
      priceUsd: launch.priceUsd,
      valueUsd: quoteUsd === null ? null : usdAmount(Number(unitsText(balance)) * Number(launch.priceQuote) * quoteUsd),
      change24h: launch.isNew ? null : launch.change24h,
      phase: launch.phase,
      progress: launch.progress,
      costBasisUsd: position ? inUsd(position.costBasis) : null,
      pnlUsd: position ? inUsd(position.pnl) : null,
      stale,
    });
  });
  return out;
}

// ------------------------------------------------------------------------------------------------ the answer

/** A part read on its own: its value, or `empty` and false when the read failed (logged). */
async function part<T>(name: string, read: () => Promise<T>, empty: T): Promise<{ ok: boolean; value: T }> {
  try {
    return { ok: true, value: await read() };
  } catch (err) {
    console.warn(`holdings: the ${name} part couldn't be read`, String((err as Error)?.message ?? err).slice(0, 200));
    return { ok: false, value: empty };
  }
}

/** Whether `address` exists, from its ledger entry read through RPC (for when Horizon couldn't read it); 502 when RPC
 *  can't tell either. The entry is read as is: the SDK's getAccount says "not found" for any failure. */
async function existsOnRpc(address: string): Promise<boolean> {
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: Keypair.fromPublicKey(address).xdrAccountId() }));
  try {
    return (await rpcServer().getLedgerEntries(key)).entries.length > 0;
  } catch (err) {
    throw new ApiError(502, "rpc_unavailable", "Stellar didn't answer. Try again.", { raw: String((err as Error)?.message ?? err).slice(0, 300) });
  }
}

/** An Earn position's 24-hour change: its asset's reference price's. */
function earnChange(p: EarnPosition, refs: Record<PriceRef, RefPrice>, net: NetworkConfig): number | null {
  const ref = assetById(net, p.asset)?.priceRef;
  return ref ? refs[ref].change24h : null;
}

/** GET /v1/holdings (§6.5): the owner's view, or the public view (`scope` "public") from on-chain and indexed data
 *  only. `exists` is Horizon's answer, or RPC's when the spot part couldn't read the account (then no XLM position). */
export async function holdings(address: string, scope: View, now: number = Date.now(), net: NetworkConfig = env.network): Promise<Holdings> {
  const owner = scope === "owner";
  const [refs, reserve] = await Promise.all([referencePrices(now, net), baseReserve()]);
  const [spot, earn, launch, moments] = await Promise.all([
    part("spot", async () => {
      const acct = await classicBalances(address);
      return { acct, rows: await spotRows(acct, refs, net) };
    }, { acct: null as ClassicAccount | null, rows: [] as SpotHolding[] }),
    part("earn", () => positions(address, scope, net, now), [] as EarnPosition[]),
    part("launch", () => launchRows(address, owner, refs, net, now), [] as LaunchHolding[]),
    part("moments", () => owned(address), []),
  ]);
  const exists = spot.ok ? spot.value.acct !== null : await existsOnRpc(address);
  const complete = spot.ok && earn.ok && launch.ok && moments.ok;
  const sum = (ok: boolean, values: Usd[]) => (ok ? usd4(values.reduce<number>((a, v) => a + (v ?? 0), 0)) : null);
  const totals = {
    spot: sum(spot.ok, spot.value.rows.map((r) => r.valueUsd)),
    earn: sum(earn.ok, earn.value.map((p) => p.valueUsd ?? null)),
    launch: sum(launch.ok, launch.value.map((l) => l.valueUsd)),
    moments: moments.ok ? 0 : null,
  };

  // What moved in 24 hours: every holding with a balance, its value and its change.
  const held: { value: Usd; change: number | null }[] = [
    ...spot.value.rows.filter((r) => BigInt(r.balance) > 0n).map((r) => ({ value: r.valueUsd, change: r.change24h })),
    ...earn.value.map((p) => ({ value: p.valueUsd ?? null, change: earnChange(p, refs, net) })),
    ...launch.value.map((l) => ({ value: l.valueUsd, change: l.change24h })),
  ];
  let moved = 0;
  let value = 0;
  for (const h of held) {
    if (h.value === null || h.change === null) continue;
    moved += (h.value * h.change) / (1 + h.change);
    value += h.value;
  }
  const dayAgo = value - moved;

  return {
    address,
    exists,
    asOf: new Date(now).toISOString(),
    pricing: pricingOf(net),
    xlm: xlmPositionOf(spot.value.acct, reserve),
    spot: spot.value.rows,
    earn: earn.value,
    launch: launch.value,
    moments: { count: moments.value.length, editions: moments.value },
    totals: {
      ...totals,
      total: complete ? usd4(totals.spot! + totals.earn! + totals.launch! + totals.moments!) : null,
      complete,
    },
    change24h: complete
      ? { usd: usdAmount(moved), pct: dayAgo > 0 ? fraction4(moved / dayAgo) : null, complete: held.every((h) => h.value !== null && h.change !== null) }
      : { usd: null, pct: null, complete: false },
    parts: { spot: spot.ok ? "ok" : "failed", earn: earn.ok ? "ok" : "failed", launch: launch.ok ? "ok" : "failed", moments: moments.ok ? "ok" : "failed" },
    view: scope,
  };
}

const PUBLIC_TTL_MS = 15_000;
const publicViews = new Map<string, { at: number; holdings: Holdings }>();

/** The public view of `address`, kept 15 s per address (§6.5): the same answer for every caller. */
export async function publicHoldings(address: string, now: number = Date.now()): Promise<Holdings> {
  const hit = publicViews.get(address);
  if (hit && now - hit.at < PUBLIC_TTL_MS && now >= hit.at) return hit.holdings;
  const h = await holdings(address, "public", now);
  if (publicViews.size >= 1_000) publicViews.clear();
  publicViews.set(address, { at: now, holdings: h });
  return h;
}

/** Drops the public views kept (tests). */
export function forgetPublicHoldings(): void {
  publicViews.clear();
}
