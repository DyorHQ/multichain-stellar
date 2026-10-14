// What the keeper's sends cost, kept in the run state (build 17, K1): every mined transaction, reverted or not, and
// every send whose outcome is unknown (counted at its worst case, gas limit x gas price).
//
// The spend guard (build 17, K3 / E8) reads it, because a price re-squatted between simulation and inclusion could
// otherwise make the keeper pay ~3 MON every 5 minutes, bounded only by its balance:
//  - per-target backoff: after a failed, reverted or unknown send, that target is not sent again for 30 minutes,
//    doubling with each further failure up to 6 hours; a success clears it;
//  - --max-spend-per-day: a send that would take the last 24 hours' spend (worst case: gas limit x gas price) over the
//    cap is not sent; the jobs keep simulating and alert, and the cap frees itself as old spend leaves the window.
//
// Live sends are saved as they go: before cast runs, the send is written as in flight (its worst case in the ledger and
// a provisional backoff), and its outcome replaces that. A run killed mid-send leaves the in-flight entry, which the
// next run reports as an unknown outcome and keeps counted.
//
// Times are unix seconds (numbers); amounts are wei, stored as decimal strings because JSON has no bigint.

export const DAY_S = 86_400;
/** Ledger entries are kept this long (a week of history for the digest and for audits), then dropped. */
export const SPEND_KEEP_S = 7 * DAY_S;

export function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function budgetOf(state) {
  state.budget ??= {};
  state.budget.spend ??= [];
  return state.budget;
}

/**
 * Records one send's cost. `estimated` marks a worst-case entry (the receipt was never read); `inFlight` (what is being
 * sent) marks the entry written before cast runs, which the outcome replaces (see jobs.mjs `safeSend`). Returns the
 * entry.
 */
export function recordSpend(state, { at = nowSeconds(), wei, job, target, tx, estimated = false, inFlight }) {
  const b = budgetOf(state);
  const entry = { at, wei: BigInt(wei).toString(), job, target, ...(tx ? { tx } : {}), ...(estimated ? { estimated: true } : {}), ...(inFlight ? { inFlight } : {}) };
  b.spend.push(entry);
  b.spend = b.spend.filter((e) => e.at > at - SPEND_KEEP_S);
  return entry;
}

/** Removes one entry `recordSpend` returned. */
export function dropSpend(state, entry) {
  if (state?.budget?.spend) state.budget.spend = state.budget.spend.filter((e) => e !== entry);
}

/**
 * The in-flight entries a run left behind: it was stopped (killed, out of memory, a host fault) while cast ran, so
 * each send's outcome is unknown. They stay in the ledger at their worst case, no longer in flight; returns copies.
 */
export function takeInFlight(state) {
  const out = [];
  for (const e of state?.budget?.spend ?? []) {
    if (!e.inFlight) continue;
    out.push({ ...e });
    delete e.inFlight;
  }
  return out;
}

/** Wei spent by sends recorded after `since` (unix seconds). */
export function spentSince(state, since) {
  let total = 0n;
  for (const e of state?.budget?.spend ?? []) if (e.at > since) total += BigInt(e.wei);
  return total;
}

export const BACKOFF_START_S = 1_800;
export const BACKOFF_MAX_S = 21_600;

function backoffs(state) {
  state.budget ??= {};
  state.budget.backoff ??= {};
  return state.budget.backoff;
}

/** The backoff standing for `target` at `at`, or undefined when it may be sent. */
export function backoffFor(state, target, at = nowSeconds()) {
  const b = state?.budget?.backoff?.[target];
  return b && at < b.until ? b : undefined;
}

/** After a failed send: 30 min, then 1 h, 2 h, 4 h, then 6 h at most. Returns the new backoff. */
export function noteSendFailure(state, target, at = nowSeconds()) {
  const all = backoffs(state);
  const failures = (all[target]?.failures ?? 0) + 1;
  const wait = Math.min(BACKOFF_START_S * 2 ** (failures - 1), BACKOFF_MAX_S);
  all[target] = { failures, until: at + wait };
  for (const [k, v] of Object.entries(all)) if (v.until < at - SPEND_KEEP_S) delete all[k]; // long forgotten
  return all[target];
}

export function noteSendSuccess(state, target) {
  if (state?.budget?.backoff) delete state.budget.backoff[target];
}

/** A copy of `target`'s backoff (undefined when there is none), for `restoreBackoff`. */
export function backoffSnapshot(state, target) {
  const b = state?.budget?.backoff?.[target];
  return b ? { ...b } : undefined;
}

/** Puts `target`'s backoff back as `backoffSnapshot` found it. */
export function restoreBackoff(state, target, snapshot) {
  const all = backoffs(state);
  if (snapshot) all[target] = snapshot;
  else delete all[target];
}

/**
 * May a send costing up to `costWei` go out under a cap of `capWei` per rolling 24 hours? No cap: always. Returns
 * { ok, spent } (spent: wei in the last 24 hours).
 */
export function spendAllowed(state, { at = nowSeconds(), costWei = 0n, capWei }) {
  const spent = spentSince(state, at - DAY_S);
  if (capWei === undefined || capWei === null) return { ok: true, spent };
  return { ok: spent + costWei <= capWei, spent };
}
