import { test } from "node:test";
import assert from "node:assert/strict";
import {
  MOMENT_STATE,
  LAUNCH_PHASE,
  VENUE,
  STUCK_GRACE,
  expirableAt,
  decideMomentGraduation,
  decideBuyback,
  minOutWithSlippage,
  decideLockerIdle,
  decideSweep,
  isqrt,
  mondayTargetSqrtPriceX96,
  tickAtSqrtPrice,
  countInitializedTicksBetween,
  bitmapWordsBetween,
  assessMondaySquat,
  decideStuckLaunch,
  squatSeverity,
  minHolderSweep,
  gasWithMargin,
} from "../lib/decide.mjs";

const NOW = 1_790_000_000n;
const DAY = 86_400n;

// ---------------------------------------------------------------- MO-1

test("expirableAt is max(deadline, stuckSince + 7d)", () => {
  assert.equal(expirableAt({ deadline: NOW + 30n * DAY, stuckSince: NOW }), NOW + 30n * DAY);
  assert.equal(expirableAt({ deadline: NOW - DAY, stuckSince: NOW }), NOW + STUCK_GRACE);
});

test("MO-1: only GraduationPending Moments are acted on", () => {
  for (const s of [MOMENT_STATE.Collecting, MOMENT_STATE.Graduated, MOMENT_STATE.Expired]) {
    assert.equal(decideMomentGraduation({ state: s, deadline: NOW, stuckSince: 0n, now: NOW, simulateOk: true }).action, "none");
  }
});

test("MO-1: pending + retry simulates -> graduate (warning while far from expiry)", () => {
  const d = decideMomentGraduation({ state: MOMENT_STATE.GraduationPending, deadline: NOW + 20n * DAY, stuckSince: NOW, now: NOW, simulateOk: true });
  assert.equal(d.action, "graduate");
  assert.equal(d.severity, "warning");
  assert.equal(d.failures, 0);
  assert.equal(d.secondsLeft, 20n * DAY);
});

test("MO-1: pending + retry reverts -> critical alert, failure counted", () => {
  const d = decideMomentGraduation({ state: MOMENT_STATE.GraduationPending, deadline: NOW + 20n * DAY, stuckSince: NOW, now: NOW, simulateOk: false, simulateError: "AlreadyGraduated" });
  assert.equal(d.action, "alert");
  assert.equal(d.severity, "critical");
  assert.equal(d.failures, 1);
  assert.match(d.reason, /AlreadyGraduated/);
});

test("MO-1: repeated failures across runs and a near expiry escalate to critical", () => {
  const base = { state: MOMENT_STATE.GraduationPending, stuckSince: NOW - 6n * DAY, now: NOW, simulateOk: true };
  assert.equal(decideMomentGraduation({ ...base, deadline: NOW - DAY }).severity, "critical", "< 24h to expiry");
  assert.equal(decideMomentGraduation({ ...base, stuckSince: NOW, deadline: NOW + 9n * DAY, previousFailures: 2 }).severity, "critical", "seen failing before");
});

// ---------------------------------------------------------------- MO-2

test("MO-2: buyback runs when graduated, funded and due", () => {
  const ok = { state: MOMENT_STATE.Graduated, accrued: 900_000n, carry: 200_000n, lastRun: NOW - 3600n, now: NOW };
  assert.deepEqual(decideBuyback(ok), { action: "execute", budget: 1_100_000n });
  assert.equal(decideBuyback({ ...ok, carry: 0n }).action, "none", "below MIN_AMOUNT");
  assert.equal(decideBuyback({ ...ok, lastRun: NOW - 3599n }).action, "none", "interval");
  assert.equal(decideBuyback({ ...ok, state: MOMENT_STATE.GraduationPending }).action, "none");
});

test("MO-2: minOut applies slippage, floors, and rejects silly bps", () => {
  assert.equal(minOutWithSlippage(10_000n, 50n), 9_950n);
  assert.equal(minOutWithSlippage(1n, 50n), 0n);
  assert.throws(() => minOutWithSlippage(1n, 10_001n));
});

test("MO-2: idle locker USDC above the threshold alerts", () => {
  assert.equal(decideLockerIdle({ lockerUsdc: 10n, alertAbove: 10n }).action, "none");
  assert.equal(decideLockerIdle({ lockerUsdc: 11n, alertAbove: 10n }).action, "alert");
  assert.match(decideLockerIdle({ lockerUsdc: 11n, alertAbove: 10n, perMoment: true }).reason, /this Moment/);
});

// ---------------------------------------------------------------- LP-2

test("LP-2: holder-sharing quote fees are always swept; others only above the floor", () => {
  assert.equal(decideSweep({ holderFeeSharing: true, isQuote: true, pending: 1n }).action, "sweep");
  assert.equal(decideSweep({ holderFeeSharing: true, isQuote: true, pending: 0n }).action, "none");
  assert.equal(decideSweep({ holderFeeSharing: true, isQuote: false, pending: 5n }).action, "none", "token fees go to the creator, no LP-2 risk");
  assert.equal(decideSweep({ holderFeeSharing: false, isQuote: true, pending: 5n, minOther: 5n }).action, "sweep");
  assert.equal(decideSweep({ holderFeeSharing: false, isQuote: true, pending: 4n, minOther: 5n }).action, "none");
});

// ---------------------------------------------------------------- LP-1 math

test("isqrt is exact on large values", () => {
  for (const n of [0n, 1n, 2n, 99n, 10n ** 40n, (1n << 192n) * 12345n + 7n]) {
    const r = isqrt(n);
    assert.ok(r * r <= n && (r + 1n) * (r + 1n) > n, `isqrt(${n})`);
  }
});

test("Monday target price matches the executor's formula and ordering", () => {
  const quote = "0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A"; // WMON
  const lowToken = "0x0000000000000000000000000000000000001000";
  const highToken = "0xffffffffffffffffffffffffffffffffffff0000";
  const args = { quoteAmount: 16_000n * 10n ** 18n, tokenAmount: 200_000_000n * 10n ** 18n, phantomQuote: 4_000n * 10n ** 18n };
  const pLow = mondayTargetSqrtPriceX96({ token: lowToken, quote, ...args }); // token is currency0 -> quote per token
  const pHigh = mondayTargetSqrtPriceX96({ token: highToken, quote, ...args });
  // tokensToPool = 200M * 16k / 20k = 160M; quoteToPool = 16k - 16k/1e6
  const tokens = 160_000_000n * 10n ** 18n;
  const q = args.quoteAmount - args.quoteAmount / 1_000_000n;
  assert.equal(pLow, isqrt((q << 192n) / tokens));
  assert.equal(pHigh, isqrt((tokens << 192n) / q));
  // inverse prices: pLow * pHigh ≈ 2^192
  const prod = pLow * pHigh;
  const q192 = 1n << 192n;
  assert.ok(prod > (q192 * 9999n) / 10000n && prod < (q192 * 10001n) / 10000n);
});

test("tickAtSqrtPrice is within one tick", () => {
  assert.equal(tickAtSqrtPrice(1n << 96n), 0);
  const t = tickAtSqrtPrice(2n << 96n); // price 4 -> tick ≈ 13862.9
  assert.ok(t === 13862 || t === 13863);
});

test("counts only initialized ticks strictly crossed", () => {
  const spacing = 200;
  const words = new Map();
  const set = (tick) => {
    const c = tick / spacing;
    const w = c >> 8;
    const b = ((c % 256) + 256) % 256;
    words.set(w, (words.get(w) ?? 0n) | (1n << BigInt(b)));
  };
  [-400, 0, 200, 600, 51_200, 60_000].forEach(set);
  assert.equal(countInitializedTicksBetween({ words, tickSpacing: spacing, tickFrom: 700, tickTo: -500 }), 4, "-400, 0, 200, 600");
  assert.equal(countInitializedTicksBetween({ words, tickSpacing: spacing, tickFrom: -500, tickTo: 60_000 }), 5, "destination tick not crossed");
  assert.deepEqual(bitmapWordsBetween({ tickSpacing: spacing, tickFrom: -500, tickTo: 60_000 }), [-1, 0, 1]);
});

test("LP-1: squat levels", () => {
  const T = 1n << 96n;
  assert.equal(assessMondaySquat({ poolExists: false }).level, "none");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: 0n, targetSqrtPriceX96: T }).level, "none");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: T, targetSqrtPriceX96: T }).level, "none");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: 10 }).level, "light");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: 200 }).level, "heavy");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: 1_500 }).level, "blocking");
  assert.equal(assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: undefined }).level, "blocking", "unknown density is treated as the worst case");
});

test("LP-1: stuck launch -> graduate, else Monday fallback, else critical alert", () => {
  const base = { phase: LAUNCH_PHASE.NotGraduated, completed: true, rescued: false, stuckSince: NOW, now: NOW };
  assert.equal(decideStuckLaunch({ ...base, venue: VENUE.UniswapV4, simGraduate: true }).action, "graduate");
  assert.equal(decideStuckLaunch({ ...base, venue: VENUE.Monday, simGraduate: false, simFallback: true }).action, "graduateFallback");
  const blocked = decideStuckLaunch({ ...base, venue: VENUE.Monday, simGraduate: false, simFallback: false });
  assert.equal(blocked.action, "alert");
  assert.equal(blocked.severity, "critical");
  assert.equal(blocked.rescueAt, NOW + 7n * DAY);
  assert.equal(decideStuckLaunch({ ...base, venue: VENUE.UniswapV4, simGraduate: false, simFallback: true }).action, "alert", "no v4->v4 fallback");
  assert.equal(decideStuckLaunch({ ...base, completed: false, venue: VENUE.Monday }).action, "none");
  assert.equal(decideStuckLaunch({ ...base, rescued: true, venue: VENUE.Monday }).action, "none");
  assert.equal(decideStuckLaunch({ ...base, phase: LAUNCH_PHASE.PoolCreated, venue: VENUE.Monday }).action, "none");
});

// ---------------------------------------------------------------- sec2 (2026-09-26 ops audit)

test("sec2 LP-2: the holder-sweep floor is twice the gas cost for MON and 0.01 token for an ERC-20", () => {
  assert.equal(minHolderSweep({ isNative: true, gasLimit: 180_000n, gasPrice: 202_000_000_000n }), 2n * 180_000n * 202_000_000_000n);
  assert.equal(minHolderSweep({ isNative: true, gasLimit: 180_000n, gasPrice: 0n }), 1n, "no gas price known: any backlog");
  assert.equal(minHolderSweep({ isNative: false, decimals: 6 }), 10_000n, "1 cent of a dollar stablecoin");
  assert.equal(minHolderSweep({ isNative: false, decimals: 18 }), 10n ** 16n);
  assert.equal(decideSweep({ holderFeeSharing: true, isQuote: true, pending: 9_999n, minHolders: 10_000n }).action, "none");
  assert.equal(decideSweep({ holderFeeSharing: true, isQuote: true, pending: 10_000n, minHolders: 10_000n }).action, "sweep");
});

test("sec2: sends use the estimate x 1.2, never above the job's cap", () => {
  assert.equal(gasWithMargin(100_000n, 1_500_000n), 120_000n);
  assert.equal(gasWithMargin(2_000_000n, 1_500_000n), 1_500_000n);
});

test("sec2 LP-1: a blocking squat is critical only on a Monday-only pair; the per-tick cost is 30k", () => {
  const T = 1n << 96n;
  const squat = (ticks, mondayOnly) => assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: ticks, mondayOnly });
  assert.equal(squat(1_000, false).estimatedGas, 700_000n + 1_000n * 30_000n);
  const ordinary = squat(1_500, false);
  assert.equal(ordinary.level, "blocking");
  assert.match(ordinary.reason, /graduateFallback/);
  assert.equal(squatSeverity(ordinary), "warning");
  const abil = squat(1_500, true);
  assert.match(abil.reason, /allowV4Fallback/);
  assert.equal(squatSeverity(abil), "critical");
  assert.equal(squatSeverity(squat(200, true)), "warning", "heavy");
  assert.equal(squatSeverity(squat(10, true)), "info", "light");
});

test("sec2 LP-1: a stuck Monday-only launch names the owner action; once allowed it does not", () => {
  const base = { phase: LAUNCH_PHASE.NotGraduated, completed: true, rescued: false, stuckSince: NOW, now: NOW, venue: VENUE.Monday, simGraduate: false, simFallback: false };
  assert.match(decideStuckLaunch({ ...base, mondayOnly: true }).reason, /OWNER calls allowV4Fallback/);
  assert.doesNotMatch(decideStuckLaunch({ ...base, mondayOnly: true, v4FallbackAllowed: true }).reason, /OWNER/);
});

test("sec2 LP-1 (v2): a Monday-only launch's freeze is bounded by the public valve", () => {
  const base = { phase: LAUNCH_PHASE.NotGraduated, completed: true, rescued: false, stuckSince: NOW, venue: VENUE.Monday, simGraduate: false, simFallback: false, mondayOnly: true, valveDelay: DAY };
  const early = decideStuckLaunch({ ...base, now: NOW + 3600n });
  assert.equal(early.severity, "critical");
  assert.match(early.reason, new RegExp(`opens to anyone at ${NOW + DAY}`));
  const late = decideStuckLaunch({ ...base, now: NOW + DAY });
  assert.equal(late.severity, "critical");
  assert.match(late.reason, /past its public fallback time.*fallback fail/);
  assert.equal(decideStuckLaunch({ ...base, now: NOW + DAY, simFallback: true }).action, "graduateFallback");
  const T = 1n << 96n;
  const squat = assessMondaySquat({ poolExists: true, sqrtPriceX96: 2n * T, targetSqrtPriceX96: T, ticksToCross: 1_500, mondayOnly: true, valveDelay: DAY });
  assert.equal(squat.level, "blocking");
  assert.equal(squatSeverity(squat), "warning", "a bounded freeze does not page before completion");
  assert.match(squat.reason, /opens to anyone after 86400s stuck/);
});
