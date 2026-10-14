// Pure decision logic for the keepers. No I/O, no clocks, no RPC: every input is passed in, so each rule is
// unit-tested in keepers/test/decide.test.mjs. Amounts are bigint; times are unix seconds as bigint.

export const MOMENT_STATE = Object.freeze({ Collecting: 0, GraduationPending: 1, Graduated: 2, Expired: 3 });
export const LAUNCH_PHASE = Object.freeze({ NotGraduated: 0, Swept: 1, PoolCreated: 2, Rescued: 3 });
export const VENUE = Object.freeze({ UniswapV4: 0, Monday: 1 });

export const STUCK_GRACE = 7n * 24n * 3600n; // MomentTypes.STUCK_GRACE
export const RESCUE_DELAY = 7n * 24n * 3600n; // LaunchpadFactory.RESCUE_DELAY
export const GRADUATION_GAS = 2_000_000n; // LaunchpadFactory.GRADUATION_GAS (automatic graduation budget)

// ------------------------------------------------------------------------------------------------ MO-1

/**
 * When can `MomentCollect.expire(id)` wind a GraduationPending Moment down (70/30 creator/treasury)?
 * v1 rule: max(deadline, stuckSince + STUCK_GRACE). stuckSince == 0 cannot happen for a live pending Moment
 * (the terminal collect either graduates or starts the clock), but it is handled like the contract does.
 */
export function expirableAt({ deadline, stuckSince }) {
  const grace = stuckSince + STUCK_GRACE;
  return deadline > grace ? deadline : grace;
}

/**
 * MO-1: what to do with one Moment.
 *  - GraduationPending + the retry simulates OK -> "graduate" (send MomentGraduation.graduate(id)).
 *  - GraduationPending + the retry reverts      -> "alert" (a human must look: graduation is genuinely failing).
 * Every pending Moment is at least a warning: on the live contracts it only exists after a failed graduation.
 * Severity escalates as expiry approaches or when earlier runs already failed to clear it.
 */
export function decideMomentGraduation({ state, deadline, stuckSince, now, simulateOk, simulateError, previousFailures = 0, urgentWindow = 24n * 3600n }) {
  if (state !== MOMENT_STATE.GraduationPending) return { action: "none" };
  const expiry = expirableAt({ deadline, stuckSince });
  const secondsLeft = expiry > now ? expiry - now : 0n;
  const failures = simulateOk ? previousFailures : previousFailures + 1;
  let severity = "warning";
  if (!simulateOk || secondsLeft <= urgentWindow || failures >= 2) severity = "critical";
  if (secondsLeft === 0n) severity = "critical";
  return {
    action: simulateOk ? "graduate" : "alert",
    severity,
    expirableAt: expiry,
    secondsLeft,
    failures,
    reason: simulateOk
      ? `GraduationPending (stuck since ${stuckSince}); retry simulates OK`
      : `GraduationPending and the graduate() retry REVERTS: ${simulateError ?? "unknown error"}`,
  };
}

// ------------------------------------------------------------------------------------------------ MO-2

/**
 * MO-2: run a buyback round when it is allowed (interval), worth it (MIN_AMOUNT), and the Moment is graduated.
 * Running it often keeps the idle USDC that a sandwich could extract small.
 */
export function decideBuyback({ state, accrued, carry, lastRun, now, minAmount = 1_000_000n, minInterval = 3600n }) {
  if (state !== MOMENT_STATE.Graduated) return { action: "none", reason: "not graduated" };
  const budget = accrued + carry;
  if (budget < minAmount) return { action: "none", reason: `budget ${budget} < MIN_AMOUNT ${minAmount}` };
  if (now < lastRun + minInterval) return { action: "none", reason: `too soon (next at ${lastRun + minInterval})` };
  return { action: "execute", budget };
}

/** Floor of `simulated * (1 - slippageBps/10000)`; the keeper's own execute is bounded by its simulation. */
export function minOutWithSlippage(simulated, slippageBps) {
  if (slippageBps < 0n || slippageBps > 10_000n) throw new Error("slippageBps out of range");
  return (simulated * (10_000n - slippageBps)) / 10_000n;
}

/**
 * MO-2 monitor: USDC idle in a cohort's shared locker is what a spot-price sandwich could extract. On a v2 locker the
 * balance is per Moment (`perMoment`): each round adds at most 0.5% of the position, so a remainder there is normal,
 * and only one Moment's own large remainder is worth a look (a price held away from the market across rounds can
 * spend it).
 */
export function decideLockerIdle({ lockerUsdc, alertAbove, perMoment = false }) {
  if (lockerUsdc <= alertAbove) return { action: "none" };
  const where = perMoment ? "locker holds this Moment" : "locker holds";
  return { action: "alert", severity: "warning", reason: `${where} ${lockerUsdc} idle USDC units (> ${alertAbove})` };
}

// ------------------------------------------------------------------------------------------------ LP-2

/**
 * LP-2: sweep a v4 pool's hook fees. Holder-sharing launches are swept as soon as the quote-asset backlog is worth the
 * sweep (`minHolders`, see `minHolderSweep`): a backlog is capturable by a one-block holder, but a dust backlog is not
 * worth capturing, and sweeping it on every run would let anyone drain the keeper's gas. Everything else is swept only
 * above `minOther`.
 */
export function decideSweep({ holderFeeSharing, isQuote, pending, minHolders = 1n, minOther }) {
  if (pending === 0n) return { action: "none" };
  if (holderFeeSharing && isQuote) {
    return pending >= minHolders ? { action: "sweep", reason: "holder rewards backlog" } : { action: "none", reason: `holder backlog ${pending} below the sweep floor ${minHolders}` };
  }
  if (minOther !== undefined && pending >= minOther) return { action: "sweep", reason: "fee backlog" };
  return { action: "none" };
}

/**
 * The smallest holder backlog worth a sweep. Native MON: twice the sweep's gas cost (Monad bills the gas limit). An
 * ERC-20 quote has no on-chain MON price here, so the floor is 0.01 whole tokens (1 cent of a dollar stablecoin).
 */
export function minHolderSweep({ isNative, gasLimit, gasPrice = 0n, decimals = 18 }) {
  if (isNative) {
    const floor = 2n * gasLimit * gasPrice;
    return floor > 0n ? floor : 1n;
  }
  return 10n ** BigInt(Math.max(0, Number(decimals) - 2));
}

/** estimateGas x 1.2, never above `cap` (the fixed limit a job used before; also the fallback when estimation fails). */
export function gasWithMargin(estimate, cap) {
  const g = (estimate * 12n) / 10n;
  return g < cap ? g : cap;
}

// ------------------------------------------------------------------------------------------------ LP-1

const Q96 = 1n << 96n;

export function isqrt(n) {
  if (n < 0n) throw new Error("negative");
  if (n < 2n) return n;
  // Newton's method from an upper bound (2^ceil(bits/2) >= sqrt(n)) decreases monotonically to floor(sqrt(n)).
  let x = 1n << BigInt(Math.ceil(n.toString(2).length / 2));
  for (;;) {
    const y = (x + n / x) >> 1n;
    if (y >= x) return x;
    x = y;
  }
}

/**
 * The exact sqrtPriceX96 the (v1) MondayGraduationExecutor opens / realigns the Monday pool at, for a curve that
 * completes with `quoteAmount` raised and `tokenAmount` left (at completion: graduationThreshold and
 * reservedTokens). Mirrors MondayGraduationExecutor.graduate + FullRangeLiquidity.sqrtPriceX96.
 */
export function mondayTargetSqrtPriceX96({ token, quote, quoteAmount, tokenAmount, phantomQuote }) {
  const tokensToPool = (tokenAmount * quoteAmount) / (phantomQuote + quoteAmount);
  const quoteToPool = quoteAmount - quoteAmount / 1_000_000n;
  const tokenIs0 = BigInt(token) < BigInt(quote);
  const [amount0, amount1] = tokenIs0 ? [tokensToPool, quoteToPool] : [quoteToPool, tokensToPool];
  const ratioX192 = (amount1 << 192n) / amount0;
  return isqrt(ratioX192);
}

/** floor(log_{1.0001}(price)) for a sqrtPriceX96, via float math — accurate to ±1 tick, enough for a scan. */
export function tickAtSqrtPrice(sqrtPriceX96) {
  const ratio = Number(sqrtPriceX96) / Number(Q96);
  return Math.floor(Math.log(ratio * ratio) / Math.log(1.0001));
}

/** v3 tickBitmap position of a compressed tick. */
export function bitmapPosition(compressed) {
  return { word: compressed >> 8, bit: ((compressed % 256) + 256) % 256 };
}

/**
 * Number of initialized ticks strictly a swap from `tickFrom` to `tickTo` would cross, given the pool's tickBitmap
 * words (a Map word -> bigint). A tick exactly at the destination is not crossed.
 */
export function countInitializedTicksBetween({ words, tickSpacing, tickFrom, tickTo }) {
  const lo = Math.min(tickFrom, tickTo);
  const hi = Math.max(tickFrom, tickTo);
  const cLo = Math.ceil(lo / tickSpacing);
  const cHi = Math.floor(hi / tickSpacing);
  let count = 0;
  for (let c = cLo; c <= cHi; c++) {
    const t = c * tickSpacing;
    if (t === tickTo) continue;
    const { word, bit } = bitmapPosition(c);
    const w = words.get(word) ?? 0n;
    if ((w >> BigInt(bit)) & 1n) count++;
  }
  return count;
}

/** The bitmap words a scan between two ticks has to read. */
export function bitmapWordsBetween({ tickSpacing, tickFrom, tickTo }) {
  const lo = Math.floor(Math.min(tickFrom, tickTo) / tickSpacing);
  const hi = Math.ceil(Math.max(tickFrom, tickTo) / tickSpacing);
  const words = [];
  for (let w = lo >> 8; w <= hi >> 8; w++) words.push(w);
  return words;
}

/**
 * LP-1: how dangerous is a pre-existing Monday pool for a Monday-venue launch that has not graduated?
 *  - "none":     no pool, or created but uninitialized (the executor initializes it), or already at the target.
 *  - "light":    squatted, but the realign crosses few enough ticks to fit the automatic 2M-gas graduation.
 *  - "heavy":    the automatic graduation will fail (> 2M); a plain `graduate(token)` with a big gas limit, or the
 *                v1 `graduateFallback` whose Monday retry gets 63/64 of the gas, still completes ON MONDAY.
 *  - "blocking": the realign needs more than one transaction can give the Monday retry. For an ordinary pair this is
 *                recoverable: the live `graduateFallback` with >= ~12M gas (the keeper sends 29.9M) graduates on
 *                Uniswap v4, because the out-of-gas happens frames below it and each reverted frame hands back the
 *                1/64 it kept (test/sec2/Sec2LiveV1.t.sol). For a Monday-only pair (aBIL) the fallback needs the owner's
 *                `allowV4Fallback`, so holders are frozen until the owner acts: only then is it critical. On a v2
 *                factory (`valveDelay` set) the fallback opens to anyone after that delay stuck, so the freeze is bounded.
 * `crossGas` is the per-crossed-tick cost: ~28.7k was measured on Monday Trade's real bytecode under Monad's gas
 * schedule (debug_traceCall, 2026-09-26 audit); 30k keeps a margin. `baseGas` is the rest of a Monday graduation.
 */
export function assessMondaySquat({ poolExists, sqrtPriceX96, targetSqrtPriceX96, ticksToCross, mondayOnly = false, valveDelay, crossGas = 30_000n, baseGas = 700_000n, txGasCap = 30_000_000n }) {
  if (!poolExists) return { level: "none", reason: "no Monday pool yet" };
  if (sqrtPriceX96 === 0n) return { level: "none", reason: "pool created but not initialized (the executor initializes it)" };
  if (sqrtPriceX96 === targetSqrtPriceX96) return { level: "none", reason: "pool already at the graduation price" };
  const blockedTail = !mondayOnly
    ? "graduateFallback with >= ~12M gas (the keeper sends 29.9M) still graduates it on Uniswap v4"
    : valveDelay !== undefined
      ? `Monday-only launch: once it completes, holders are frozen until the v4 fallback opens to anyone after ${valveDelay}s stuck, or until the owner's allowV4Fallback(token) opens it at once`
      : "Monday-only pair: the v4 fallback needs the owner's allowV4Fallback(token), so holders are frozen until the owner acts";
  const bounded = mondayOnly && valveDelay !== undefined;
  if (ticksToCross === undefined || ticksToCross === null) {
    return { level: "blocking", mondayOnly, bounded, reason: `pool is mispriced and its tick density could not be read — treat as blocking; ${blockedTail}`, estimatedGas: undefined };
  }
  const estimatedGas = baseGas + BigInt(ticksToCross) * crossGas;
  // v1 graduateFallback: the Monday retry gets 63/64 of what is left.
  const fallbackMondayBudget = (txGasCap * 63n) / 64n;
  if (estimatedGas <= GRADUATION_GAS) return { level: "light", mondayOnly, estimatedGas, reason: `${ticksToCross} initialized ticks to cross; fits the automatic graduation` };
  if (estimatedGas < fallbackMondayBudget) return { level: "heavy", mondayOnly, estimatedGas, reason: `${ticksToCross} initialized ticks; automatic graduation will fail, a high-gas retry graduates on Monday` };
  return { level: "blocking", mondayOnly, bounded, estimatedGas, reason: `${ticksToCross} initialized ticks (~${estimatedGas} gas) exceed one transaction, so the Monday graduation cannot finish; ${blockedTail}` };
}

/** Alert severity of a squat seen BEFORE completion: only a blocking squat on a Monday-only pair freezes holders, and
    on a v2 factory (`bounded`) only until its public fallback delay has passed. */
export function squatSeverity({ level, mondayOnly, bounded = false }) {
  if (level === "blocking") return mondayOnly && !bounded ? "critical" : "warning";
  if (level === "heavy") return "warning";
  return "info";
}

/**
 * LP-1 (+ stuck v4 launches): what to do with a launch whose curve completed but which did not graduate.
 * `simGraduate` / `simFallback` are simulation outcomes (true = would succeed).
 */
export function decideStuckLaunch({ phase, venue, completed, rescued, stuckSince, now, simGraduate, simFallback, mondayOnly = false, v4FallbackAllowed = false, valveDelay }) {
  if (phase !== LAUNCH_PHASE.NotGraduated || !completed || rescued) return { action: "none" };
  const rescueAt = stuckSince === 0n ? 0n : stuckSince + RESCUE_DELAY;
  if (simGraduate) return { action: "graduate", severity: "warning", rescueAt, reason: "completed but not graduated; graduate() simulates OK" };
  if (venue === VENUE.Monday && simFallback) return { action: "graduateFallback", severity: "warning", rescueAt, reason: "Monday graduation fails; the v4 fallback simulates OK" };
  let reason = "v4 graduation fails: investigate";
  const failing = "Monday graduation AND the v4 fallback fail: investigate; pre-align the Monday pool (README, LP-1 manual procedure) or rescue after the delay";
  if (venue === VENUE.Monday) {
    if (!mondayOnly || v4FallbackAllowed) {
      reason = failing;
    } else if (valveDelay === undefined) {
      // v1 factory: no public valve
      reason = "Monday-only pair: holders are frozen (curve closed, no pool) until the OWNER calls allowV4Fallback(token), or pre-aligns the Monday pool (README, LP-1 manual procedure); rescue needs the owner too";
    } else {
      const valveAt = stuckSince + valveDelay;
      reason =
        now < valveAt
          ? `Monday-only launch: holders are frozen (curve closed, no pool) until the v4 fallback opens to anyone at ${valveAt}, unless the OWNER calls allowV4Fallback(token) now or pre-aligns the Monday pool (README, LP-1 manual procedure); the keeper sends the fallback once it simulates`
          : `Monday-only launch past its public fallback time (${valveAt}), and ${failing}`;
    }
  }
  return { action: "alert", severity: "critical", rescueAt, reason };
}
