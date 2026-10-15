// Portfolio (docs/DESIGN-stellar-parity.md §6.7): over a period, the volume, fees paid, P&L, fees received, trades and
// network fees of each section (Spot, Earn, Launch, Moments, Bridge) and in total, at today's prices, and the period's
// activity. A session route: it is DyorHQ's history. This reads the account's rows and today's prices; stats.ts adds
// them up.
// - The period's logged transactions (spot swaps; every section's network fees), each in the section it was logged
//   with, as Recent Activity lists it (activity.ts), the curve trades and pool swaps, creator claims, collects, the
//   creator's proceeds from its own Moments and completed bridge transfers.
// - Earn: every recorded deposit and withdrawal (an earlier one decides whether a position's P&L is the period's) and
//   what the account supplies now (earn.ts, read live); when the pools can't be read, the P&L says it is incomplete.
// - Prices: the reference prices for registry assets; a launch token at its launch's price (launchpad.ts).
// - Coverage: the account's first logged transaction; what DyorHQ doesn't see isn't counted (swaps made elsewhere).
import type postgres from "postgres";
import { activity, periodStart } from "./activity.ts";
import type { BridgeDirection, Period, Portfolio, PortfolioItem } from "./contract.ts";
import { num, sql } from "./db.ts";
import { flowsOf, LoggedFlow, positions } from "./earn.ts";
import { env } from "./env.ts";
import { priceOf, TOKEN_DECIMALS } from "./launchpad.ts";
import { assetById, NetworkConfig, PriceRef } from "./networks.ts";
import { pricingOf, referencePrices, RefPrice, usdOf } from "./refprices.ts";
import { BridgeRecord, EarnFlow, feeExecuted, LaunchFill, LoggedTx, PORTFOLIO_SECTIONS, portfolioStats, PriceBook } from "./stats.ts";

type Row = postgres.Row;

/** Shown under the figures: what they can't count. */
export const COVERAGE_NOTE = "Swaps made outside DyorHQ between non-launch assets aren't counted.";
/** The most items Portfolio's activity lists. */
const ACTIVITY_MAX = 500;

const big = (v: unknown): bigint => BigInt(num(v).split(".")[0]);
const known = (v: unknown): boolean => v !== null && v !== undefined;

/** Today's prices: registry assets through their reference, launch tokens at their launch's. */
function priceBook(net: NetworkConfig, refs: Record<PriceRef, RefPrice>, launches: Row[]): PriceBook {
  const byToken = new Map(launches.map((l) => [String(l.token), l]));
  return {
    usd(asset) {
      const registry = assetById(net, asset);
      if (registry) return usdOf(registry, refs);
      const l = byToken.get(asset);
      const quote = l ? usdOf(assetById(net, String(l.quote)), refs) : null;
      return l && quote !== null ? Number(priceOf(l)) * quote : null;
    },
    decimals(asset) {
      return assetById(net, asset)?.decimals ?? TOKEN_DECIMALS;
    },
    xlmUsd: usdOf(assetById(net, "XLM"), refs),
  };
}

/** Each recorded Earn deposit and withdrawal, by market (earn.ts flowsOf's rule). */
function earnFlows(rows: Row[]): EarnFlow[] {
  const out: EarnFlow[] = [];
  for (const r of rows) {
    for (const [market, f] of flowsOf([r as unknown as LoggedFlow])) {
      out.push({ market, asset: market.split(":")[1], deposit: r.kind === "earn_deposit", amount: f.deposited + f.withdrawn, at: new Date(r.created_at).getTime() });
    }
  }
  return out;
}

/** What the account supplies to each market now, or null when the pools can't be read (logged). */
async function suppliedNow(user: string, net: NetworkConfig, now: number): Promise<Map<string, bigint> | null> {
  try {
    return new Map((await positions(user, "owner", net, now)).map((p) => [`${p.pool}:${p.asset}`, BigInt(p.supplied)]));
  } catch (err) {
    console.warn("portfolio: the pools couldn't be read", String((err as Error)?.message ?? err).slice(0, 200));
    return null;
  }
}

/** GET /v1/portfolio?period= (§6.7). */
export async function portfolio(user: string, period: Period, now: number = Date.now(), net: NetworkConfig = env.network): Promise<Portfolio> {
  const since = periodStart(period, now);
  const [refs, txs, earnRows, fills, claims, collects, proceeds, bridges, first, items] = await Promise.all([
    referencePrices(now, net),
    sql()`
      select kind, section, status, fee_payer, fee_charged, intent, result from lite.tx_log t
       where t.address = ${user} ${since ? sql()`and t.created_at > ${since}` : sql()``}`,
    sql()`
      select kind, intent, created_at from lite.tx_log
       where address = ${user} and kind in ('earn_deposit', 'earn_withdraw') and status = 'success' order by created_at`,
    sql()`
      select f.token, l.quote, f.side, f.quote_amount, f.token_amount, f.fees from (
        select token, side, quote_amount, token_amount, fees, ts from lite.launch_trades where trader = ${user}
        union all
        select token, side, quote_amount, token_amount, 0 as fees, ts from lite.pool_swaps where trader = ${user}
      ) as f join lite.launches l on l.token = f.token
       ${since ? sql()`where f.ts > ${since}` : sql()``}`,
    sql()`
      select l.quote, c.amount from lite.creator_claims c join lite.launches l on l.token = c.token
       where c.creator = ${user} ${since ? sql()`and c.ts > ${since}` : sql()``}`,
    sql()`
      select m.quote, c.paid, m.platform_bps from lite.moment_collects c join lite.moments m on m.id = c.moment_id
       where c.collector = ${user} ${since ? sql()`and c.ts > ${since}` : sql()``}`,
    sql()`
      select m.quote, sum(lite.moment_creator_share(c.paid, m.platform_bps)) as amount
        from lite.moment_collects c join lite.moments m on m.id = c.moment_id
       where m.creator = ${user} and m.platform_bps is not null ${since ? sql()`and c.ts > ${since}` : sql()``}
       group by m.quote`,
    sql()`
      select direction, amount, message from lite.bridge_transfers b
       where b.address = ${user} and b.status = 'completed' ${since ? sql()`and b.created_at > ${since}` : sql()``}`,
    sql()`select min(created_at) as first from lite.tx_log where address = ${user}`,
    activity(user, { section: null, kind: null, period, market: null, limit: ACTIVITY_MAX, settled: true }, now, net),
  ]);
  const tokens = [...new Set(fills.map((f) => String(f.token)))];
  const [launches, supplied] = await Promise.all([
    tokens.length ? sql()`select * from lite.launches where token = any(${tokens}::text[])` : [],
    suppliedNow(user, net, now),
  ]);
  const usdc = assetById(net, "USDC")!;

  const { totals, sections } = portfolioStats({
    since: since?.getTime() ?? null,
    prices: priceBook(net, refs, launches),
    txs: txs.map((t): LoggedTx => ({
      kind: String(t.kind),
      section: t.section ?? null,
      status: String(t.status),
      feePayer: t.fee_payer ?? null,
      feeCharged: known(t.fee_charged) ? BigInt(t.fee_charged) : null,
      intent: t.intent ?? null,
      amountOut: typeof t.result?.amountOut === "string" && /^[0-9]+$/.test(t.result.amountOut) ? BigInt(t.result.amountOut) : null,
    })),
    launchFills: fills.map((f): LaunchFill => ({
      token: String(f.token),
      quote: String(f.quote),
      side: f.side === "sell" ? "sell" : "buy",
      quoteAmount: big(f.quote_amount),
      tokenAmount: big(f.token_amount),
      fees: big(f.fees),
    })),
    creatorClaims: claims.map((c) => ({ quote: String(c.quote), amount: big(c.amount) })),
    collects: collects.map((c) => ({ quote: String(c.quote), paid: big(c.paid), platformBps: known(c.platform_bps) ? Number(c.platform_bps) : null })),
    proceeds: proceeds.map((p) => ({ quote: String(p.quote), amount: big(p.amount) })),
    // USDC: 6 decimals on Monad, the sending side of a transfer from it; 7 on Stellar.
    bridges: bridges.map((b): BridgeRecord => ({
      direction: b.direction as BridgeDirection,
      asset: usdc.contract,
      amount: big(b.amount),
      decimals: b.direction === "monad_to_stellar" ? 6 : usdc.decimals,
      fee: feeExecuted(b.message),
    })),
    earnFlows: earnFlows(earnRows),
    supplied,
  });

  const activityItems: PortfolioItem[] = items
    .filter((i) => (PORTFOLIO_SECTIONS as string[]).includes(i.section ?? ""))
    .map((i) => ({ id: i.id, section: i.section!, kind: i.kind, title: i.title ?? i.summary, subtitle: i.subtitle ?? null, at: i.at, usd: i.usd ?? null, hash: i.hash ?? null }));
  return {
    period,
    since: since?.toISOString() ?? null,
    asOf: new Date(now).toISOString(),
    pricing: pricingOf(net),
    totals,
    sections,
    activity: activityItems,
    coverage: { from: known(first[0]?.first) ? new Date(first[0].first).toISOString() : null, note: COVERAGE_NOTE },
  };
}
