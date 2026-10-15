// Portfolio's figures (docs/DESIGN-stellar-parity.md §6.7): each section's volume, fees paid, P&L, fees received and
// trades over a period, and the network fees the user paid in it. Pure: portfolio.ts reads the rows and today's
// prices, this adds them up. Every USD figure is at today's prices, as Monad's PortfolioModel counts them, to 4
// decimals; an asset without a price adds nothing, and a P&L that misses one says so (pnlComplete false).
// - spot: the user's successful swaps logged in the spot section: volume at the sold side's price (the bought side's
//   when the sold one has none); P&L what was bought less what was sold; no fees (a venue's fee is in its price).
// - launch: every curve trade and pool swap of the account (lite.launch_trades, lite.pool_swaps), through DyorHQ or
//   not: volume in the quote asset, the curve's fees, P&L quote received − quote spent + the tokens bought less sold;
//   fees received are the creator fees claimed. A trade made through DyorHQ is also a logged transaction, which adds
//   its network fee only: nothing is counted twice.
// - earn: deposits and withdrawals; P&L what a position has earned (supplied now + withdrawn − deposited) when its
//   whole record is in the period. Blend keeps no history per account, so a position recorded before the period, still
//   open or moved in it, can't be split: it adds nothing, and the P&L says it is incomplete. So does a position with no
//   deposit recorded (made elsewhere).
// - moments: collects (what was paid), the platform's share of them as fees, and the creator's proceeds from the
//   user's own Moments as fees received; P&L 0 (an edition has no market: pending, not a loss).
// - bridge: completed transfers, and Circle's fee on each: its burn message's feeExecuted (BurnMessageV2).
// Network fees are the fee_charged of the section's logged transactions the user paid for, settled either way (a
// failed transaction charges its fee too): in stroops, and in USD at XLM's price. Never part of `fees`.
import type { BridgeDirection, Intent, Section, Stats } from "./contract.ts";

export type PortfolioSection = "spot" | "earn" | "launch" | "moments" | "bridge";
export const PORTFOLIO_SECTIONS: PortfolioSection[] = ["spot", "earn", "launch", "moments", "bridge"];

/** Today's prices. */
export interface PriceBook {
  /** USD per whole unit of the asset (a contract id), or null without a price. */
  usd(asset: string): number | null;
  decimals(asset: string): number;
  /** XLM's, for network fees. */
  xlmUsd: number | null;
}

/** One of the account's logged transactions in the period (lite.tx_log). */
export interface LoggedTx {
  kind: string;
  /** As logged (migration 10 gives every row its kind's); null for a kind no section counts. */
  section: Section | null;
  status: string;
  feePayer: string | null;
  feeCharged: bigint | null;
  intent: Pick<Intent, "spend" | "receive" | "display"> | null;
  /** What the step delivered (result.amountOut). */
  amountOut: bigint | null;
}

/** A curve trade or pool swap of the account's in the period, in its launch's quote asset. Pool swaps have no `fees`:
 *  the pool's is in its price. */
export interface LaunchFill {
  token: string;
  quote: string;
  side: "buy" | "sell";
  quoteAmount: bigint;
  tokenAmount: bigint;
  fees: bigint;
}

/** One recorded Earn deposit or withdrawal (all time: an earlier one decides whether a position's P&L is the
 *  period's). `market` is `<pool>:<asset>`. */
export interface EarnFlow {
  market: string;
  asset: string;
  deposit: boolean;
  amount: bigint;
  at: number;
}

/** A collect by the user in the period: what it paid in the Moment's quote, and the platform's share then. */
export interface Collect {
  quote: string;
  paid: bigint;
  /** Null for a Moment indexed without its terms: no fee is counted for it. */
  platformBps: number | null;
}

/** A completed bridge transfer in the period: its amount in the sending side's units, and Circle's fee in CCTP's
 *  (6 decimals; null when the transfer's message isn't kept). */
export interface BridgeRecord {
  direction: BridgeDirection;
  asset: string;
  amount: bigint;
  decimals: number;
  fee: bigint | null;
}

export interface StatsInput {
  /** The period's start (ms); null for all time. */
  since: number | null;
  prices: PriceBook;
  txs: LoggedTx[];
  launchFills: LaunchFill[];
  /** Creator fees the user claimed in the period, in each launch's quote. */
  creatorClaims: { quote: string; amount: bigint }[];
  collects: Collect[];
  /** The creator's share of collects of the user's Moments in the period, by quote. */
  proceeds: { quote: string; amount: bigint }[];
  bridges: BridgeRecord[];
  earnFlows: EarnFlow[];
  /** What the account supplies now, by market; null when the pools couldn't be read. */
  supplied: Map<string, bigint> | null;
}

/** CCTP messages carry USDC in 6 decimals. */
export const CCTP_DECIMALS = 6;

/** MessageV2's header is 148 bytes; BurnMessageV2's feeExecuted is the uint256 at 164 in its body (Circle's
 *  evm-cctp-contracts, src/messages/v2). */
const FEE_EXECUTED_AT = 148 + 164;

/** The fee Circle took from a burn, in CCTP's 6 decimals, from its attested message (hex, with or without 0x); null
 *  when there is none to read. */
export function feeExecuted(message: unknown): bigint | null {
  if (typeof message !== "string") return null;
  const hex = message.replace(/^0x/, "");
  if (!/^[0-9a-fA-F]*$/.test(hex) || hex.length < (FEE_EXECUTED_AT + 32) * 2) return null;
  return BigInt(`0x${hex.slice(FEE_EXECUTED_AT * 2, (FEE_EXECUTED_AT + 32) * 2)}`);
}

const STROOPS_PER_XLM = 10_000_000;

/** USD to 4 decimals, never -0. */
export function usd4(v: number): number {
  return Math.round(v * 10_000) / 10_000 || 0;
}

/** `units` of `asset` in USD today; null without a price. */
function valueOf(prices: PriceBook, asset: string, units: bigint, decimals = prices.decimals(asset)): number | null {
  const p = prices.usd(asset);
  return p === null ? null : (Number(units) / 10 ** decimals) * p;
}

/** A section's figures as they add up, before rounding. */
interface Tally {
  volume: number;
  fees: number;
  pnl: number;
  claimedFees: number;
  trades: number;
  pnlComplete: boolean;
  networkFees: bigint;
}

const tally = (): Tally => ({ volume: 0, fees: 0, pnl: 0, claimedFees: 0, trades: 0, pnlComplete: true, networkFees: 0n });

function statsOf(t: Tally, xlmUsd: number | null): Stats {
  return {
    volume: usd4(t.volume),
    fees: usd4(t.fees),
    pnl: usd4(t.pnl),
    claimedFees: usd4(t.claimedFees),
    trades: t.trades,
    pnlComplete: t.pnlComplete,
    networkFeesXlm: t.networkFees.toString(),
    networkFeesUsd: xlmUsd === null ? null : usd4((Number(t.networkFees) / STROOPS_PER_XLM) * xlmUsd),
  };
}

/** The one asset a side of an intent names: its only spend or receive key. */
function sideOf(amounts: Record<string, string> | undefined): { asset: string; amount: bigint } | null {
  const entries = Object.entries(amounts ?? {});
  if (entries.length !== 1 || !/^[0-9]{1,30}$/.test(entries[0][1])) return null;
  return { asset: entries[0][0], amount: BigInt(entries[0][1]) };
}

function spot(input: StatsInput): Tally {
  const t = tally();
  const { prices } = input;
  for (const tx of input.txs) {
    if (tx.kind !== "swap" || tx.section !== "spot" || tx.status !== "success") continue;
    const sell = sideOf(tx.intent?.spend);
    const buy = sideOf(tx.intent?.receive);
    t.trades += 1;
    if (!sell || !buy) {
      t.pnlComplete = false;
      continue;
    }
    // A strict-send swap spends exactly what it sells (display.amountIn, the intent's spend otherwise).
    const shown = tx.intent?.display?.amountIn;
    const amountIn = typeof shown === "string" && /^[0-9]{1,30}$/.test(shown) ? BigInt(shown) : sell.amount;
    const sold = valueOf(prices, sell.asset, amountIn);
    const bought = tx.amountOut === null ? null : valueOf(prices, buy.asset, tx.amountOut);
    t.volume += sold ?? bought ?? 0;
    if (sold === null || bought === null) t.pnlComplete = false;
    else t.pnl += bought - sold;
  }
  return t;
}

function launch(input: StatsInput): Tally {
  const t = tally();
  const { prices } = input;
  const held = new Map<string, bigint>();
  for (const f of input.launchFills) {
    t.trades += 1;
    const quote = valueOf(prices, f.quote, f.quoteAmount);
    const fees = valueOf(prices, f.quote, f.fees);
    t.volume += quote ?? 0;
    t.fees += fees ?? 0;
    if (quote === null) t.pnlComplete = false;
    else t.pnl += f.side === "sell" ? quote : -quote;
    held.set(f.token, (held.get(f.token) ?? 0n) + (f.side === "buy" ? f.tokenAmount : -f.tokenAmount));
  }
  for (const [token, delta] of held) {
    if (delta === 0n) continue;
    const v = valueOf(prices, token, delta);
    if (v === null) t.pnlComplete = false;
    else t.pnl += v;
  }
  for (const c of input.creatorClaims) t.claimedFees += valueOf(prices, c.quote, c.amount) ?? 0;
  return t;
}

function earn(input: StatsInput): Tally {
  const t = tally();
  const { prices, since } = input;
  const inPeriod = (f: EarnFlow) => since === null || f.at > since;
  const markets = new Map<string, { asset: string; deposited: bigint; withdrawn: bigint; deposits: number; before: boolean; moved: boolean }>();
  const marketOf = (key: string, asset: string) => {
    let m = markets.get(key);
    if (!m) markets.set(key, m = { asset, deposited: 0n, withdrawn: 0n, deposits: 0, before: false, moved: false });
    return m;
  };
  for (const f of input.earnFlows) {
    const m = marketOf(f.market, f.asset);
    if (f.deposit) {
      m.deposited += f.amount;
      m.deposits += 1;
    } else {
      m.withdrawn += f.amount;
    }
    if (inPeriod(f)) {
      m.moved = true;
      t.trades += 1;
      t.volume += valueOf(prices, f.asset, f.amount) ?? 0;
    } else {
      m.before = true;
    }
  }
  if (input.supplied === null) {
    // The pools couldn't be read: no position's earnings are known.
    if ([...markets.values()].some((m) => m.moved || m.deposited > m.withdrawn)) t.pnlComplete = false;
    return t;
  }
  for (const [key, amount] of input.supplied) if (amount > 0n) marketOf(key, key.split(":")[1]);
  for (const [key, m] of markets) {
    const supplied = input.supplied.get(key) ?? 0n;
    if (m.deposits === 0) {
      // Deposits made elsewhere, or before DyorHQ recorded them.
      if (supplied > 0n) t.pnlComplete = false;
      continue;
    }
    if (m.before) {
      if (supplied > 0n || m.moved) t.pnlComplete = false;
      continue;
    }
    const earned = valueOf(prices, m.asset, supplied + m.withdrawn - m.deposited);
    if (earned === null) t.pnlComplete = false;
    else t.pnl += earned;
  }
  return t;
}

function moments(input: StatsInput): Tally {
  const t = tally();
  const { prices } = input;
  for (const c of input.collects) {
    t.trades += 1;
    const paid = valueOf(prices, c.quote, c.paid);
    t.volume += paid ?? 0;
    if (paid !== null && c.platformBps !== null) t.fees += (paid * c.platformBps) / 10_000;
  }
  for (const p of input.proceeds) t.claimedFees += valueOf(prices, p.quote, p.amount) ?? 0;
  return t;
}

function bridge(input: StatsInput): Tally {
  const t = tally();
  const { prices } = input;
  for (const b of input.bridges) {
    t.trades += 1;
    t.volume += valueOf(prices, b.asset, b.amount, b.decimals) ?? 0;
    if (b.fee !== null) t.fees += valueOf(prices, b.asset, b.fee, CCTP_DECIMALS) ?? 0;
  }
  return t;
}

const SECTIONS: Record<PortfolioSection, (input: StatsInput) => Tally> = { spot, earn, launch, moments, bridge };

/** Every section's figures for the period, and their totals: the sum of the sections' (rounded) figures. */
export function portfolioStats(input: StatsInput): { totals: Stats; sections: Record<PortfolioSection, Stats> } {
  const sections = {} as Record<PortfolioSection, Stats>;
  for (const name of PORTFOLIO_SECTIONS) {
    const t = SECTIONS[name](input);
    for (const tx of input.txs) {
      if (tx.section === name && tx.feePayer === "user" && tx.feeCharged !== null) t.networkFees += tx.feeCharged;
    }
    sections[name] = statsOf(t, input.prices.xlmUsd);
  }
  const all = PORTFOLIO_SECTIONS.map((s) => sections[s]);
  const sum = (f: (s: Stats) => number) => usd4(all.reduce((a, s) => a + f(s), 0));
  const fees = all.map((s) => s.networkFeesUsd);
  return {
    totals: {
      volume: sum((s) => s.volume),
      fees: sum((s) => s.fees),
      pnl: sum((s) => s.pnl),
      claimedFees: sum((s) => s.claimedFees),
      trades: all.reduce((a, s) => a + s.trades, 0),
      pnlComplete: all.every((s) => s.pnlComplete),
      networkFeesXlm: all.reduce((a, s) => a + BigInt(s.networkFeesXlm), 0n).toString(),
      networkFeesUsd: fees.some((f) => f === null) ? null : sum((s) => s.networkFeesUsd!),
    },
    sections,
  };
}
