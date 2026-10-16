// Portfolio's figures (_shared/stats.ts; docs/DESIGN-stellar-parity.md §6.7, §12.5), against numbers worked out by
// hand for one week of an account at today's prices (XLM $0.20, USDC $1, the launch token ECAT $0.00001):
// - spot: the user's logged swaps in the spot section, a sponsored starter swap included; a failed one adds only its
//   network fee;
// - launch: curve trades and a pool swap (fees from the curve only), a claim; the logged launch transactions add their
//   network fees and nothing else (no double count);
// - earn: a deposit and a withdrawal in the week, earned = supplied now + withdrawn − deposited;
// - moments: collects in XLM and USDC with the platform's 5%, the creator's proceeds as fees received;
// - bridge: transfers each way (6 decimals from Monad, 7 from Stellar), Circle's fee;
// - network fees per section from the user-paid rows only, never in `fees`; the account section's left out;
// - totals as the sum of the sections.
// Then the edge cases: unpriced sides, a missing amountOut, Earn positions older than the period or made elsewhere,
// the pools unread, XLM unpriced; and Circle's fee read from a burn message.
import { assertEquals } from "jsr:@std/assert@1";
import { feeExecuted, portfolioStats } from "../../supabase/functions/_shared/stats.ts";
import type { EarnFlow, LoggedTx, PriceBook, StatsInput } from "../../supabase/functions/_shared/stats.ts";

const XLM = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC";
const USDC = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA";
const ECAT = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
/** A SEP-41 token with no price. */
const WAVE = "CAG7HXJ65BFFSKCG4OE64UCFY7DZXSANMPNYNXO4OOGWCDP6XM7OSGWG";
const POOL = "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF";

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 9, 14, 9, 41);
const WEEK_AGO = NOW - 7 * DAY;
/** Whole units in base units (7 decimals). */
const u = (whole: number) => BigInt(Math.round(whole * 1e7));

function prices(usd: Record<string, number | null> = { [XLM]: 0.2, [USDC]: 1, [ECAT]: 0.00001 }): PriceBook {
  return { usd: (a) => usd[a] ?? null, decimals: () => 7, xlmUsd: usd[XLM] ?? null };
}

function tx(kind: string, section: LoggedTx["section"], fee: number | null, o: Partial<LoggedTx> = {}): LoggedTx {
  return { kind, section, status: "success", feePayer: "user", feeCharged: fee === null ? null : BigInt(fee), intent: null, amountOut: null, ...o };
}

function swap(sell: string, amountIn: bigint, buy: string, amountOut: bigint | null, fee: number, o: Partial<LoggedTx> = {}): LoggedTx {
  return tx("swap", "spot", fee, { intent: { spend: { [sell]: amountIn.toString() }, receive: { [buy]: "1" }, display: { amountIn: amountIn.toString() } }, amountOut, ...o });
}

function flow(asset: string, deposit: boolean, amount: bigint, daysAgo: number): EarnFlow {
  return { market: `${POOL}:${asset}`, asset, deposit, amount, at: NOW - daysAgo * DAY };
}

/** The account's week. */
function week(): StatsInput {
  return {
    since: WEEK_AGO,
    prices: prices(),
    txs: [
      // Spot: 100 XLM ($20) for 19.5 USDC; a starter swap DyorHQ paid for, 5 USDC for 24 XLM ($4.80); a swap that failed.
      swap(XLM, u(100), USDC, u(19.5), 50_000),
      swap(USDC, u(5), XLM, u(24), 100_000, { feePayer: "sponsor" }),
      swap(XLM, u(10), USDC, null, 30_000, { status: "failed" }),
      // Launch: the curve buy and the pool buy as logged (network fees only), and the claim.
      tx("launch_buy", "launch", 40_000, { intent: { spend: { [XLM]: u(100).toString() }, receive: { [ECAT]: "1" } }, amountOut: u(1_800_000) }),
      swap(XLM, u(10), ECAT, u(200_000), 60_000, { section: "launch" }),
      tx("launch_claim", "launch", 25_000),
      tx("earn_deposit", "earn", 1_250_000),
      tx("earn_withdraw", "earn", 500_000),
      tx("moment_collect", "moments", 2_000_000),
      tx("approve", "bridge", 100_000),
      tx("bridge_out", "bridge", 300_000),
      // The account section counts in none of the five.
      tx("trust", "account", 10_000),
      tx("activate", "account", 100_000, { feePayer: "sponsor" }),
    ],
    launchFills: [
      { token: ECAT, quote: XLM, side: "buy", quoteAmount: u(100), tokenAmount: u(1_800_000), fees: u(1) },
      { token: ECAT, quote: XLM, side: "sell", quoteAmount: u(15), tokenAmount: u(300_000), fees: u(0.15) },
      { token: ECAT, quote: XLM, side: "buy", quoteAmount: u(10), tokenAmount: u(200_000), fees: 0n },
    ],
    creatorClaims: [{ quote: XLM, amount: u(2) }],
    collects: [{ quote: XLM, paid: u(20), platformBps: 500 }, { quote: USDC, paid: u(3), platformBps: 500 }],
    proceeds: [{ quote: XLM, amount: u(9.5) }],
    bridges: [
      { direction: "monad_to_stellar", asset: USDC, amount: 25_000_000n, decimals: 6, fee: 2_500n },
      { direction: "stellar_to_monad", asset: USDC, amount: u(10), decimals: 7, fee: 0n },
    ],
    earnFlows: [flow(XLM, true, u(500), 3), flow(XLM, false, u(100), 1)],
    supplied: new Map([[`${POOL}:${XLM}`, u(401)]]),
  };
}

const stats = (o: Partial<{ volume: number; fees: number; pnl: number; claimedFees: number; trades: number; pnlComplete: boolean; networkFeesXlm: string; networkFeesUsd: number | null }>) => ({
  volume: 0,
  fees: 0,
  pnl: 0,
  claimedFees: 0,
  trades: 0,
  pnlComplete: true,
  networkFeesXlm: "0",
  networkFeesUsd: 0,
  ...o,
});

Deno.test("every section's figures for a week, worked out by hand", () => {
  const { sections, totals } = portfolioStats(week());
  // Spot: $20 + $5 sold; P&L (19.5 − 20) + (24 × 0.2 − 5) = −0.7; the failed swap's fee counts, the sponsor's doesn't.
  assertEquals(sections.spot, stats({ volume: 25, pnl: -0.7, trades: 2, networkFeesXlm: "80000", networkFeesUsd: 0.0016 }));
  // Earn: 500 + 100 XLM moved ($120); 401 + 100 − 500 = 1 XLM earned ($0.20).
  assertEquals(sections.earn, stats({ volume: 120, pnl: 0.2, trades: 2, networkFeesXlm: "1750000", networkFeesUsd: 0.035 }));
  // Launch: 100 + 15 + 10 XLM traded ($25); the curve's fees 1.15 XLM ($0.23); P&L (15 − 100 − 10) × 0.2 + 1,700,000
  // ECAT × $0.00001 = −19 + 17 = −2; 2 XLM claimed ($0.40); 40,000 + 60,000 + 25,000 stroops of network fees.
  assertEquals(sections.launch, stats({ volume: 25, fees: 0.23, pnl: -2, claimedFees: 0.4, trades: 3, networkFeesXlm: "125000", networkFeesUsd: 0.0025 }));
  // Moments: 20 XLM ($4) + 3 USDC paid, 5% of it to the platform; 9.5 XLM of proceeds ($1.90).
  assertEquals(sections.moments, stats({ volume: 7, fees: 0.35, claimedFees: 1.9, trades: 2, networkFeesXlm: "2000000", networkFeesUsd: 0.04 }));
  // Bridge: 25 USDC (6 decimals) + 10 USDC (7 decimals); Circle's 0.0025 USDC.
  assertEquals(sections.bridge, stats({ volume: 35, fees: 0.0025, trades: 2, networkFeesXlm: "400000", networkFeesUsd: 0.008 }));
  assertEquals(totals, stats({
    volume: 212,
    fees: 0.5825,
    pnl: -2.5,
    claimedFees: 2.3,
    trades: 11,
    networkFeesXlm: "4355000",
    networkFeesUsd: 0.0871,
  }));
});

Deno.test("a launch trade made through DyorHQ counts once: its logged transaction adds its network fee and nothing else", () => {
  const input = week();
  const without = portfolioStats({ ...input, txs: input.txs.filter((t) => t.section !== "launch") }).sections.launch;
  const withLogged = portfolioStats(input).sections.launch;
  assertEquals({ ...withLogged, networkFeesXlm: "0", networkFeesUsd: 0 }, without);
  assertEquals([without.networkFeesXlm, withLogged.networkFeesXlm], ["0", "125000"]);
});

Deno.test("network fees are never part of fees, whatever they come to", () => {
  const input = week();
  const dearer = portfolioStats({ ...input, txs: input.txs.map((t) => ({ ...t, feeCharged: t.feeCharged === null ? null : t.feeCharged * 10n })) });
  const base = portfolioStats(input);
  for (const s of ["spot", "earn", "launch", "moments", "bridge"] as const) assertEquals(dearer.sections[s].fees, base.sections[s].fees, s);
  assertEquals([dearer.totals.fees, dearer.totals.networkFeesXlm], [0.5825, "43550000"]);
});

Deno.test("spot: an unpriced side, or a swap with no amountOut, leaves the P&L incomplete", () => {
  const only = (txs: LoggedTx[]) => portfolioStats({ ...week(), txs }).sections.spot;
  // No amountOut: the volume still counts (the sold side), the P&L can't.
  assertEquals(only([swap(XLM, u(100), USDC, null, 0)]), stats({ volume: 20, trades: 1, pnlComplete: false }));
  // An unpriced token bought: volume at the sold side's price.
  assertEquals(only([swap(USDC, u(3), WAVE, u(70), 0)]), stats({ volume: 3, trades: 1, pnlComplete: false }));
  // An unpriced token sold: volume at the bought side's.
  assertEquals(only([swap(WAVE, u(70), USDC, u(2.5), 0)]), stats({ volume: 2.5, trades: 1, pnlComplete: false }));
  // Both unpriced: no volume.
  assertEquals(only([swap(WAVE, u(70), "CBWKQU57NOSEY5DXCRCIEPLZINBNKAKGPL3UYNNSJFUXU65XTXN2MDWZ", u(1), 0)]), stats({ trades: 1, pnlComplete: false }));
});

Deno.test("earn: a position recorded before the period, or made elsewhere, can't be split, and says so", () => {
  const earn = (o: Partial<StatsInput>) => portfolioStats({ ...week(), ...o }).sections.earn;
  // Deposited 20 days ago, still open: its week's interest isn't known; the week moved nothing.
  assertEquals(earn({ txs: [], earnFlows: [flow(USDC, true, u(50), 20)], supplied: new Map([[`${POOL}:${USDC}`, u(50.5)]]) }), stats({ pnlComplete: false }));
  // All of it in the period: earned 0.5 USDC.
  assertEquals(earn({ txs: [], since: null, earnFlows: [flow(USDC, true, u(50), 20)], supplied: new Map([[`${POOL}:${USDC}`, u(50.5)]]) }), stats({ volume: 50, pnl: 0.5, trades: 1 }));
  // Closed before the period: nothing to count, nothing missing.
  assertEquals(earn({ txs: [], earnFlows: [flow(USDC, true, u(50), 20), flow(USDC, false, u(50.5), 10)], supplied: new Map() }), stats({}));
  // Supplied with no deposit recorded: made elsewhere.
  assertEquals(earn({ txs: [], earnFlows: [], supplied: new Map([[`${POOL}:${XLM}`, u(10)]]) }), stats({ pnlComplete: false }));
  // The pools couldn't be read: the week's deposit counts in volume, its earnings aren't known.
  assertEquals(earn({ txs: [], earnFlows: [flow(XLM, true, u(500), 3)], supplied: null }), stats({ volume: 100, trades: 1, pnlComplete: false }));
});

Deno.test("launch and moments: an unpriced quote or token leaves the P&L incomplete; a Moment without its terms has no fee", () => {
  const input = { ...week(), prices: prices({ [XLM]: 0.2, [USDC]: 1, [ECAT]: null }) };
  const s = portfolioStats(input).sections;
  // The ECAT left over can't be valued: P&L is the quote side only, −19.
  assertEquals([s.launch.volume, s.launch.pnl, s.launch.pnlComplete], [25, -19, false]);
  const moments = portfolioStats({ ...week(), collects: [{ quote: XLM, paid: u(20), platformBps: null }] }).sections.moments;
  assertEquals([moments.volume, moments.fees, moments.trades], [4, 0, 1]);
});

Deno.test("without XLM's price, network fees have no USD value, in the sections or the totals", () => {
  const { sections, totals } = portfolioStats({ ...week(), prices: prices({ [USDC]: 1, [ECAT]: 0.00001 }) });
  assertEquals([sections.spot.networkFeesXlm, sections.spot.networkFeesUsd, totals.networkFeesUsd], ["80000", null, null]);
});

Deno.test("Circle's fee is the burn message's feeExecuted", () => {
  // A MessageV2 header (148 bytes) and a BurnMessageV2 body whose feeExecuted (body offset 164) is 2,500.
  const message = new Uint8Array(148 + 228 + 20);
  message[148 + 164 + 31] = 0xc4;
  message[148 + 164 + 30] = 0x09;
  const hex = Array.from(message, (b) => b.toString(16).padStart(2, "0")).join("");
  assertEquals([feeExecuted(`0x${hex}`), feeExecuted(hex)], [2_500n, 2_500n]);
  assertEquals([feeExecuted(null), feeExecuted("0x1234"), feeExecuted(`0x${"zz".repeat(400)}`)], [null, null, null]);
});
