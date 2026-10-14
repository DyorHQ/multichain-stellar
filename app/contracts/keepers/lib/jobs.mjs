// The keeper jobs. Each takes a viem-like `client` (readContract / simulateContract / estimateContractGas / getBlock /
// getLogs / getBlockNumber / getGasPrice), the deployment records, a `sender` (dry-run by default, see send.mjs), a
// `reporter` and a mutable `state` object, so every job runs unchanged against Monad, a local anvil, or a mock in the
// tests.
//
// Robustness rules (2026-09-26 ops audit): one failing read never ends a run. Every cohort, launchpad and item is
// isolated (`guard`): a failure becomes a critical alert and the job moves on, so a rate limit on one read cannot
// starve the items after it. Log scans run after every retry and adapt their range to the RPC's cap.
//
// Build 17, K2: an RPC failure (HTTP error, timeout, rate limit) is never mistaken for a chain answer. A simulation or
// an optional read that fails that way skips the item for this run instead of being read as "reverts" (which could
// send the v4 fallback of a launch whose Monday graduation works) or as "function missing"; such alerts are marked
// `rpc` and the run collapses them into one "RPC degraded" warning (rpc.mjs). With --logs-cursor the scans start
// where the previous run stopped (cursor.mjs).
//
// Build 17, K3: every alert carries a stable `key` (notify.mjs posts a key when new or escalated, repeats it on a
// cadence and posts "resolved" once a completed job no longer raises it; one-off events are `once`). A job whose read
// failed is marked incomplete, so none of its alerts count as resolved. Live sends go through the spend guard
// (budget.mjs): per-target backoff after a failed send, and --max-spend-per-day.
import {
  momentsFactoryAbi,
  momentsFactoryV1Abi,
  momentsFactoryV2Abi,
  momentCollectAbi,
  momentGraduationAbi,
  momentFeeHookAbi,
  momentBuybackAbi,
  momentLockerV2Abi,
  launchpadFactoryAbi,
  launchpadFactoryLegacyAbi,
  launchpadFactoryV2Abi,
  bondingCurveAbi,
  mondayExecutorAbi,
  mondayFactoryAbi,
  mondayPoolAbi,
  mondayFeeVaultAbi,
  memeHookAbi,
  memeHookV2Abi,
  erc20Abi,
} from "./abis.mjs";
import {
  MOMENT_STATE,
  LAUNCH_PHASE,
  VENUE,
  decideMomentGraduation,
  decideBuyback,
  decideLockerIdle,
  minOutWithSlippage,
  decideSweep,
  minHolderSweep,
  gasWithMargin,
  decideStuckLaunch,
  mondayTargetSqrtPriceX96,
  tickAtSqrtPrice,
  bitmapWordsBetween,
  countInitializedTicksBetween,
  assessMondaySquat,
  squatSeverity,
} from "./decide.mjs";
import { formatEther } from "viem";
import { MinedRevert, SendStatusUnknown } from "./send.mjs";
import { nowSeconds, recordSpend, dropSpend, backoffFor, backoffSnapshot, restoreBackoff, noteSendFailure, noteSendSuccess, spendAllowed } from "./budget.mjs";
import { isRangeRefusal, isTransportError, STALE_BLOCKS } from "./rpc.mjs";
import { DEFAULT_LOGS_CHUNK, DEFAULT_LOGS_MAX_BLOCKS, LOGS_HEAD_MARGIN, planScan, readCursor, writeCursor } from "./cursor.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
/** Gas for a Monday graduate / graduateFallback: just under Monad's 30M per-transaction cap. Monad bills the limit
    (~3 MON at 102 gwei), which buys the realign every bit of gas one transaction can give it. */
export const MONDAY_GAS = 29_900_000n;
const DEFAULT_SIM_ACCOUNT = "0x000000000000000000000000000000000000dEaD";
const DAY = 86_400n;

function errText(e) {
  return (e?.shortMessage || e?.message || String(e)).split("\n")[0];
}

/** A simulation: `ok: false` when the chain says the call reverts. An RPC failure throws (the item is skipped). */
async function simulate(client, req) {
  try {
    const r = await client.simulateContract(req);
    return { ok: true, result: r.result };
  } catch (e) {
    if (isTransportError(e)) throw e;
    return { ok: false, error: errText(e) };
  }
}

/** A read whose failure is expected on some deployments (a function the live or legacy bytecode lacks). An RPC failure
    is not that, and throws. */
async function readOr(client, req, fallback) {
  try {
    return await client.readContract(req);
  } catch (e) {
    if (isTransportError(e)) throw e;
    return fallback;
  }
}

/** Runs one unit of work (a cohort, a launchpad, a Moment, a launch); a failure is a critical alert, not the end. An
    RPC failure is marked `rpc`: the run collapses those into one "RPC degraded" alert. */
async function guard(reporter, job, target, fn) {
  try {
    await fn();
  } catch (e) {
    reporter.incomplete?.add(job); // what this item would have raised is unknown: nothing of this job resolves this run
    reporter.alert({ job, target, severity: "critical", key: `read:${job}:${target}`, reason: `could not be checked (read failed): ${errText(e)}`, ...(isTransportError(e) ? { rpc: true } : {}) });
  }
}

/** Gas limit for one send: estimateGas x 1.2, capped at the job's fixed limit (Monad bills the limit, not the use). */
async function gasFor(client, req, cap) {
  try {
    return gasWithMargin(await client.estimateContractGas(req), cap);
  } catch {
    return cap;
  }
}

/** The gas price for the sweep threshold (a dry estimate: 0 when unread). */
async function gasPriceOf(client) {
  try {
    return typeof client.getGasPrice === "function" ? await client.getGasPrice() : 0n;
  } catch {
    return 0n;
  }
}

/** The gas price a live send is priced at: `{ ok, price }`, or `{ ok: false, why, rpc }` when it cannot be read or the
    RPC answers 0. */
async function liveGasPrice(client) {
  if (typeof client.getGasPrice !== "function") return { ok: false, why: "this client cannot read it" };
  try {
    const price = BigInt(await client.getGasPrice());
    return price > 0n ? { ok: true, price } : { ok: false, why: `the RPC answered ${price}` };
  } catch (e) {
    return { ok: false, why: errText(e), rpc: isTransportError(e) };
  }
}

const mon = (wei) => formatEther(BigInt(wei));

/**
 * Sends one transaction; a failed send becomes an alert instead of aborting the rest of the run (other targets and
 * other jobs still get their turn). Only a receipt with status 1 is a success (build 17, K1): a transaction mined but
 * reverted, a cast that had to be killed, or a receipt that cannot be read is a critical alert, and what the send cost
 * (or may have cost, at its gas limit x the gas price) goes into the spend ledger (budget.mjs).
 *
 * Live sends pass the spend guard first (K3 / E8): a target that failed recently is backed off (30 min doubling to
 * 6 h), and a send that would take the last 24 hours over `budget.capWei` is held back with a critical alert. A dry
 * run is never held back.
 *
 * Live sends are saved as they go (`budget.persist`, the run's state file): before cast runs the send is written as in
 * flight (its worst case in the ledger and a provisional backoff), and after it the outcome replaces that and is saved
 * again. A run killed during or after a send (a deploy, the OOM killer, a host fault) so never forgets what it spent
 * or that the target failed. A state file that cannot be saved holds every later send of the run (`budget.held`).
 */
async function safeSend({ sender, reporter, client, state, budget, clock = budget?.clock ?? nowSeconds }, job, target, tx) {
  const live = sender.live === true;
  const at = clock();
  const what = tx.label ?? tx.signature;
  const targetKey = `${job}:${target}`;
  // The run refuses every send (stale RPC, past its deadline, state not saved): nothing is read, recorded or backed
  // off.
  const blocked = live ? sender.blocked?.() ?? budget?.held : undefined;
  if (blocked) {
    reporter.info(`not sending ${what}: ${blocked}`);
    return null;
  }
  let gasPrice = 0n;
  if (live) {
    const resetHold = state?.budget?.heldUntil;
    if (resetHold !== undefined && at < resetHold) {
      reporter.info(`not sending ${what}: the state file was reset; sends are held until ${new Date(resetHold * 1000).toISOString()}`);
      return null;
    }
    const held = state ? backoffFor(state, targetKey, at) : undefined;
    if (held) {
      reporter.info(`not sending ${what}: ${held.failures} failed send(s), backing off until ${new Date(held.until * 1000).toISOString()}`);
      return null;
    }
    // The gas price prices the cap and the worst case of a send whose outcome is unknown: a send it cannot price is
    // held, never counted as free.
    const gp = await liveGasPrice(client);
    if (!gp.ok) {
      reporter.incomplete?.add(job);
      reporter.alert({ job, target, severity: "warning", key: `send:gasprice:${targetKey}`, reason: `send held: the gas price could not be read (${gp.why}), so the spend cap could not count ${what}; the next run tries again`, ...(gp.rpc ? { rpc: true } : {}) });
      return null;
    }
    gasPrice = gp.price;
    if (state) {
      const cost = tx.gasLimit ? BigInt(tx.gasLimit) * gasPrice : 0n;
      const room = spendAllowed(state, { at, costWei: cost, capWei: budget?.capWei });
      if (!room.ok) {
        reporter.alert({ job, target: "spend cap", severity: "critical", key: "budget:cap", reason: `--max-spend-per-day ${mon(budget.capWei)} MON reached: ${mon(room.spent)} MON spent in the last 24 h, and ${what} could cost up to ${mon(cost)} MON. Sends are held (simulations go on) until the 24-hour window has room` });
        return null;
      }
    }
  }
  const worst = tx.gasLimit ? BigInt(tx.gasLimit) * gasPrice : 0n;
  const keep = live && !!state;
  const save = () => {
    if (!keep || !budget?.persist) return true;
    try {
      budget.persist();
      return true;
    } catch (e) {
      budget.held = `the state file could not be saved (${errText(e)})`;
      reporter.alert({ job: "keeper", target: "state file", severity: "critical", key: "keeper:state:write", reason: `${budget.held}: every later send is held, so the spend ledger and the backoffs are never lost` });
      return false;
    }
  };
  let inFlight;
  let backoffBefore;
  if (keep) {
    backoffBefore = backoffSnapshot(state, targetKey);
    inFlight = recordSpend(state, { at, wei: worst, job, target, estimated: true, inFlight: `${tx.signature} to ${tx.to}` });
    noteSendFailure(state, targetKey, at);
  }
  const settle = () => {
    if (!inFlight) return;
    dropSpend(state, inFlight);
    restoreBackoff(state, targetKey, backoffBefore);
    inFlight = undefined;
  };
  if (!save()) {
    settle();
    reporter.info(`not sending ${what}: ${budget.held}`);
    return null;
  }
  const record = (wei, extra) => {
    if (keep) recordSpend(state, { at: clock(), wei, job, target, ...extra });
  };
  const failed = (reason) => {
    const b = keep ? noteSendFailure(state, targetKey, clock()) : undefined;
    const next = b ? `; not retried before ${new Date(b.until * 1000).toISOString()}` : "";
    // Every failed send is its own event (it cost, or may have cost, gas): posted once, never "resolved". It goes into
    // the alert history at once, so a run killed before it posts still has it posted by the next run.
    reporter.alert({ job, target, severity: "critical", key: `send:${targetKey}:${tx.signature}:${at}`, once: true, reason: `${reason}${next}` });
    if (keep) budget?.remember?.(reporter.alerts[reporter.alerts.length - 1]);
  };
  let result = null;
  try {
    const r = await sender.call(tx);
    settle();
    if (!live || r?.dryRun) return r;
    if (!r?.receipt) throw new SendStatusUnknown(`cast send exited 0 but printed no readable receipt (${r?.receiptError ?? "no output"})`, { gasLimit: tx.gasLimit });
    record(r.spentWei, { tx: r.receipt.transactionHash });
    if (state) noteSendSuccess(state, targetKey);
    reporter.info(`sent ${what}: tx ${r.receipt.transactionHash} succeeded; cost ${mon(r.spentWei)} MON`);
    result = r;
  } catch (e) {
    settle();
    if (e?.notStarted) {
      reporter.info(`not sending ${what}: ${errText(e)}`);
    } else if (e instanceof MinedRevert) {
      record(e.spentWei, { tx: e.txHash });
      failed(`send failed: ${tx.signature} was mined but REVERTED (tx ${e.txHash}); it cost ${mon(e.spentWei)} MON (gas limit ${e.gasLimit ?? e.gasUsed} at ${e.effectiveGasPrice} wei; Monad bills the limit)`);
    } else if (e?.statusUnknown) {
      record(worst, { estimated: true });
      failed(`send failed: outcome UNKNOWN for ${tx.signature}: ${errText(e)}. Check the keeper address on the explorer; counted as up to ${mon(worst)} MON spent`);
    } else {
      failed(`send failed: ${errText(e)}`);
    }
  }
  save();
  return result;
}

/** Did safeSend send for real and get a successful receipt? */
const sentOk = (r) => !!r && r.dryRun !== true && r.receipt?.status === 1;

async function now(client) {
  return (await client.getBlock()).timestamp;
}

/**
 * eth_getLogs over [from, to] in chunks of at most `chunk` blocks, each an inclusive span (end = start + chunk - 1:
 * rpc3 accepts 1,000 blocks that way and refuses 1,001 with -32062; rpc4 accepts at least 1,001). An RPC that caps
 * the range lower (rpc.monad.xyz answers more than 101 blocks with HTTP 413, -32614 "eth_getLogs is limited to a 100
 * range") makes the chunk halve and retry, down to one block (rpc.mjs isRangeRefusal); an RPC failure (rate limit,
 * timeout, outage) or any other error is thrown.
 */
export async function getLogsChunked(client, { from, to, chunk = DEFAULT_LOGS_CHUNK, ...filter }) {
  const out = [];
  let size = chunk > 0n ? chunk : 1n;
  for (let start = from; start <= to; ) {
    const end = start + size - 1n < to ? start + size - 1n : to;
    try {
      out.push(...(await client.getLogs({ ...filter, fromBlock: start, toBlock: end })));
      start = end + 1n;
    } catch (e) {
      if (size > 1n && isRangeRefusal(e)) {
        size /= 2n;
        continue;
      }
      throw e;
    }
  }
  return out;
}

/** The log-scan options of a job (see cursor.mjs); scanning is on with a lookback, a cursor or a start block. */
function logOptions({ logsLookback = 0n, logsChunk = DEFAULT_LOGS_CHUNK, logsCursor = false, logsFrom, logsMaxBlocks = DEFAULT_LOGS_MAX_BLOCKS, logsUntil, logsNow = Date.now }) {
  return {
    lookback: logsLookback,
    chunk: logsChunk > 0n ? logsChunk : 1n,
    cursor: logsCursor,
    from: logsFrom,
    maxBlocks: logsMaxBlocks,
    until: logsUntil,
    now: logsNow,
    enabled: logsCursor || logsFrom !== undefined || logsLookback > 0n,
  };
}

/** The share of the scan time left that scan `i` of `n` (run one after another) may use, so a long catch-up of the first
    scan never starves the others. */
function shareOf(logs, i, n) {
  if (logs.until === undefined) return logs;
  const left = logs.until - logs.now();
  return { ...logs, until: left > 0 ? logs.now() + left / (n - i) : logs.until };
}

/**
 * One log scan. Ad hoc (no cursor): [head - lookback, head] in one go, all or nothing. With a cursor: from just after
 * the cursor to LOGS_HEAD_MARGIN blocks short of the head, chunk by chunk; after each chunk its logs are handed to
 * `onLogs` and only then the cursor moves to the chunk's last block, so no block is ever skipped. A scan that stops
 * before that (the --logs-max-blocks cap, or `until`: the share of --max-runtime scans may use) raises a "scan behind"
 * warning and the next run continues.
 */
async function scanLogs({ client, reporter, state, job, scanId, label, logs, fetchRange, onLogs }) {
  const read = await client.getBlockNumber();
  const head = logs.cursor ? (read > LOGS_HEAD_MARGIN ? read - LOGS_HEAD_MARGIN : 0n) : read;
  const cursor = logs.cursor ? readCursor(state, scanId) : undefined;
  const plan = planScan({ cursor, head, from: logs.from, lookback: logs.lookback, maxBlocks: logs.maxBlocks, useCursor: logs.cursor });
  if (plan?.empty && cursor !== undefined && cursor > read + STALE_BLOCKS) {
    // A few blocks behind is a lagging fallback (nothing to scan yet); minutes behind the last scanned block is an RPC
    // that is stuck, or not on the chain the cursor was made on.
    reporter.alert({ job, target: label, severity: "warning", key: `logs:headbehind:${scanId}`, reason: `the RPC's head ${read} is ${cursor - read} blocks below this scan's cursor ${cursor}: it is stuck or not the chain the cursor was made on, so nothing was scanned` });
  }
  if (!plan || plan.empty) return;
  if (!logs.cursor) {
    onLogs(await fetchRange(plan.from, plan.to));
    return;
  }
  let done = plan.from - 1n;
  let outOfTime = false;
  while (done < plan.to) {
    if (logs.until !== undefined && logs.now() >= logs.until) {
      outOfTime = true;
      break;
    }
    const start = done + 1n;
    const end = start + logs.chunk - 1n < plan.to ? start + logs.chunk - 1n : plan.to;
    onLogs(await fetchRange(start, end));
    done = end;
    writeCursor(state, scanId, done);
  }
  if (head > done) {
    const why = outOfTime ? "it used its share of --max-runtime" : `at most --logs-max-blocks ${logs.maxBlocks} per run`;
    reporter.alert({ job, target: label, severity: "warning", key: `logs:behind:${scanId}`, reason: `log scan is ${head - done} blocks behind (scanned through block ${done} of ${head}, the head ${read} less a ${LOGS_HEAD_MARGIN}-block margin; ${why}): it catches up over the next runs` });
  }
}

// ------------------------------------------------------------------------------------------------ MO-1

async function retryMoment({ client, c, id, t, sender, reporter, state, budget, simAccount, gasLimit }) {
  const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
  if (s !== MOMENT_STATE.GraduationPending) return;
  const ledger = await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "ledger", args: [id] });
  let m;
  try {
    m = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "getMoment", args: [id] });
  } catch {
    m = await client.readContract({ address: c.factory, abi: momentsFactoryV1Abi, functionName: "getMoment", args: [id] });
  }
  const req = { address: c.graduation, abi: momentGraduationAbi, functionName: "graduate", args: [id], account: simAccount };
  const sim = await simulate(client, { ...req, gas: gasLimit });
  const key = `moment:${c.collect.toLowerCase()}:${id}`;
  const d = decideMomentGraduation({
    state: s,
    deadline: BigInt(m.deadline),
    stuckSince: BigInt(ledger.stuckSince),
    now: t,
    simulateOk: sim.ok,
    simulateError: sim.error,
    previousFailures: state[key]?.failures ?? 0,
  });
  state[key] = { failures: d.failures, lastSeen: Number(t) };
  const target = `${c.label} moment #${id}`;
  const pending = { job: "moments-graduation", target, severity: d.severity, key: `mo1:pending:${c.collect.toLowerCase()}:${id}`, reason: `${d.reason}; expirable at ${d.expirableAt} (${d.secondsLeft}s left)` };
  if (d.action === "graduate") {
    reporter.action({ job: "moments-graduation", target, what: "graduate(id)" });
    const gas = await gasFor(client, req, gasLimit);
    const sent = await safeSend({ sender, reporter, client, state, budget }, "moments-graduation", target, { to: c.graduation, signature: "graduate(uint256)", args: [id], gasLimit: gas, label: `graduate ${target}` });
    // Graduated by this run: nothing for a human (an earlier post of it resolves; a new one is never posted).
    if (sentOk(sent)) pending.severity = "info";
  }
  reporter.alert(pending);
}

/**
 * Retries graduation of every GraduationPending Moment in every cohort; alerts on each. With `logsLookback` it then
 * reports GraduationFailed events. The retries of ALL cohorts run before any log scan: the scan is only an alerting
 * aid, and an RPC that refuses a log range must never keep a later cohort's retry from being sent.
 */
export async function momentsGraduationJob({ client, cohorts, sender, reporter, state, budget, simAccount = DEFAULT_SIM_ACCOUNT, gasLimit = 5_000_000n, ...logArgs }) {
  const logs = logOptions(logArgs);
  const t = await now(client);
  for (const c of cohorts) {
    await guard(reporter, "moments-graduation", c.label, async () => {
      const count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
      reporter.info(`${c.label}: ${count} moments`);
      for (let id = 1n; id <= count; id++) {
        await guard(reporter, "moments-graduation", `${c.label} moment #${id}`, () => retryMoment({ client, c, id, t, sender, reporter, state, budget, simAccount, gasLimit }));
      }
    });
  }
  if (!logs.enabled) return;
  const event = momentCollectAbi.find((x) => x.name === "GraduationFailed");
  for (const [i, c] of cohorts.entries()) {
    const label = `${c.label} (GraduationFailed log scan)`;
    await guard(reporter, "moments-graduation", label, () =>
      scanLogs({
        client,
        reporter,
        state,
        job: "moments-graduation",
        scanId: `mo1:GraduationFailed:${c.collect.toLowerCase()}`,
        label,
        logs: shareOf(logs, i, cohorts.length),
        fetchRange: (from, to) => getLogsChunked(client, { address: c.collect, event, from, to, chunk: logs.chunk }),
        onLogs: (found) => {
          for (const l of found) {
            reporter.alert({ job: "moments-graduation", target: `${c.label} moment #${l.args.momentId}`, severity: "warning", key: `mo1:failedlog:${l.transactionHash}:${l.logIndex}`, once: true, reason: `GraduationFailed emitted in block ${l.blockNumber} (tx ${l.transactionHash})` });
          }
        },
      }),
    );
  }
}

// ------------------------------------------------------------------------------------------------ MO-2

/**
 * Executes every due buyback round (bounded by its own simulation) and watches idle locker USDC: per Moment on a v2
 * locker (`heldOf`), where each round adds at most 0.5% of the position and a remainder is normal; for the whole
 * cohort on a v1 locker, which adds everything it holds every round.
 */
export async function buybacksJob({ client, cohorts, sender, reporter, state, budget, simAccount = DEFAULT_SIM_ACCOUNT, slippageBps = 50n, lockerIdleAlert = 50_000_000n, gasLimit = 3_000_000n }) {
  const t = await now(client);
  for (const c of cohorts) {
    await guard(reporter, "buybacks", c.label, async () => {
      const count = await client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName: "momentCount" });
      const [minAmount, minInterval] = await Promise.all([
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_AMOUNT" }),
        client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "MIN_INTERVAL" }),
      ]);
      let perMoment = false;
      for (let id = 1n; id <= count; id++) {
        const target = `${c.label} moment #${id}`;
        await guard(reporter, "buybacks", target, async () => {
          const s = Number(await client.readContract({ address: c.collect, abi: momentCollectAbi, functionName: "state", args: [id] }));
          if (s !== MOMENT_STATE.Graduated) return;
          const held = await readOr(client, { address: c.locker, abi: momentLockerV2Abi, functionName: "heldOf", args: [id, c.usdc] }, null);
          if (held !== null) {
            perMoment = true;
            const li = decideLockerIdle({ lockerUsdc: held, alertAbove: lockerIdleAlert, perMoment: true });
            if (li.action === "alert") reporter.alert({ job: "buybacks", target: `${target} locker`, severity: li.severity, key: `mo2:idle:${c.locker.toLowerCase()}:${id}`, reason: li.reason });
          }
          const [accrued, carry, lastRun] = await Promise.all([
            client.readContract({ address: c.hook, abi: momentFeeHookAbi, functionName: "buybackAccrued", args: [id] }),
            client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "carry", args: [id] }),
            client.readContract({ address: c.buyback, abi: momentBuybackAbi, functionName: "lastRun", args: [id] }),
          ]);
          const d = decideBuyback({ state: s, accrued, carry, lastRun: BigInt(lastRun), now: t, minAmount, minInterval });
          if (d.action !== "execute") return;
          const sim = await simulate(client, { address: c.buyback, abi: momentBuybackAbi, functionName: "execute", args: [id, 0n], account: simAccount, gas: gasLimit });
          if (!sim.ok) {
            reporter.alert({ job: "buybacks", target, severity: "warning", key: `mo2:simrevert:${c.buyback.toLowerCase()}:${id}`, reason: `execute() due (budget ${d.budget}) but simulation reverts: ${sim.error}` });
            return;
          }
          const minCoinOut = minOutWithSlippage(sim.result.coinBought, slippageBps);
          reporter.action({ job: "buybacks", target, what: `execute(id, ${minCoinOut}) budget ${d.budget}` });
          const gas = await gasFor(client, { address: c.buyback, abi: momentBuybackAbi, functionName: "execute", args: [id, minCoinOut], account: simAccount }, gasLimit);
          await safeSend({ sender, reporter, client, state, budget }, "buybacks", target, { to: c.buyback, signature: "execute(uint256,uint256)", args: [id, minCoinOut], gasLimit: gas, label: `buyback ${target}` });
        });
      }
      if (perMoment) return;
      const idle = await client.readContract({ address: c.usdc, abi: erc20Abi, functionName: "balanceOf", args: [c.locker] });
      const li = decideLockerIdle({ lockerUsdc: idle, alertAbove: lockerIdleAlert });
      if (li.action === "alert") reporter.alert({ job: "buybacks", target: `${c.label} locker`, severity: li.severity, key: `mo2:idle:${c.locker.toLowerCase()}`, reason: li.reason });
    });
  }
}

// ------------------------------------------------------------------------------------------------ Launchpad helpers

async function allLaunches(client, factory, page = 100n) {
  const n = await client.readContract({ address: factory, abi: launchpadFactoryAbi, functionName: "launchCount" });
  const out = [];
  for (let off = 0n; off < n; off += page) {
    const tokens = await client.readContract({ address: factory, abi: launchpadFactoryAbi, functionName: "getLaunches", args: [off, page] });
    out.push(...tokens);
  }
  return out;
}

/** A launch record in the current shape; the legacy (0xad3d) record has no venue: every launch graduates on Monday. */
async function launchRecord(client, lp, token) {
  if (lp.legacyRecord) {
    const l = await client.readContract({ address: lp.factory, abi: launchpadFactoryLegacyAbi, functionName: "getLaunchedToken", args: [token] });
    return { ...l, graduationVenue: VENUE.Monday };
  }
  return client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "getLaunchedToken", args: [token] });
}

// ------------------------------------------------------------------------------------------------ LP-2

/**
 * Sweeps hook fees of every graduated Uniswap v4 pool: holder-sharing quote fees once they are worth the sweep's gas
 * (see decide.mjs `minHolderSweep`), other fees above `minOther`. On a v2 hook the protocol's cut of holder-sharing
 * pools sits in `pendingProtocolFees` (LP-2), which is counted too; on the v1 hooks that read reverts and is 0.
 */
export async function sweepsJob({ client, launchpads, sender, reporter, state, budget, minOther, simAccount = DEFAULT_SIM_ACCOUNT, gasLimit = 1_500_000n }) {
  for (const lp of launchpads) {
    await guard(reporter, "sweeps", lp.label, async () => {
      if (lp.legacyRecord) return; // every launch on it graduates on Monday Trade: no hook fees
      const tokens = await allLaunches(client, lp.factory);
      reporter.info(`${lp.label}: ${tokens.length} launches`);
      const gasPrice = await gasPriceOf(client);
      for (const token of tokens) {
        await guard(reporter, "sweeps", `${lp.label} ${token}`, async () => {
          const l = await launchRecord(client, lp, token);
          if (Number(l.phase) !== LAUNCH_PHASE.PoolCreated || Number(l.graduationVenue) !== VENUE.UniswapV4) return;
          for (const currency of [l.pairToken, token]) {
            const [fee, tax, protocolOnly] = await Promise.all([
              client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingFees", args: [l.poolId, currency] }),
              client.readContract({ address: lp.hook, abi: memeHookAbi, functionName: "pendingCreatorTax", args: [l.poolId, currency] }),
              readOr(client, { address: lp.hook, abi: memeHookV2Abi, functionName: "pendingProtocolFees", args: [l.poolId, currency] }, 0n),
            ]);
            const pending = fee + tax + protocolOnly;
            const isQuote = currency.toLowerCase() === l.pairToken.toLowerCase();
            const req = { address: lp.hook, abi: memeHookAbi, functionName: "sweepPoolFees", args: [l.poolId, currency], account: simAccount };
            let minHolders = 1n;
            if (l.holderFeeSharing && isQuote && pending > 0n) {
              const isNative = currency === ZERO;
              const decimals = isNative ? 18 : await readOr(client, { address: currency, abi: erc20Abi, functionName: "decimals" }, 18);
              minHolders = minHolderSweep({ isNative, gasLimit: await gasFor(client, req, gasLimit), gasPrice, decimals });
            }
            const d = decideSweep({ holderFeeSharing: l.holderFeeSharing, isQuote, pending, minHolders, minOther });
            if (d.action !== "sweep") continue;
            const target = `${lp.label} ${token} (${isQuote ? "quote" : "token"} fees)`;
            // Simulate first, as the other jobs do: with a gas limit cast skips estimation, so a reverting sweep would
            // otherwise be broadcast and pay gas.
            const sim = await simulate(client, { ...req, gas: gasLimit });
            if (!sim.ok) {
              reporter.alert({ job: "sweeps", target, severity: "warning", key: `lp2:simrevert:${lp.hook.toLowerCase()}:${token.toLowerCase()}:${currency.toLowerCase()}`, reason: `sweepPoolFees would revert: ${sim.error}` });
              continue;
            }
            reporter.action({ job: "sweeps", target, what: `sweepPoolFees ${pending} (${d.reason})` });
            const gas = await gasFor(client, req, gasLimit);
            await safeSend({ sender, reporter, client, state, budget }, "sweeps", target, { to: lp.hook, signature: "sweepPoolFees(bytes32,address)", args: [l.poolId, currency], gasLimit: gas, label: `sweep ${target}` });
          }
        });
      }
    });
  }
}

// ------------------------------------------------------------------------------------------------ LP-1

async function assessSquat(client, { mondayFactory, fee, wmon, token, pairToken, curve, mondayOnly, valveDelay }) {
  const quote = pairToken === ZERO ? wmon : pairToken;
  const pool = await client.readContract({ address: mondayFactory, abi: mondayFactoryAbi, functionName: "getPool", args: [token, quote, fee] });
  if (pool === ZERO) return { pool, ...assessMondaySquat({ poolExists: false }) };
  const slot0 = await client.readContract({ address: pool, abi: mondayPoolAbi, functionName: "slot0" });
  const [reserved, phantom, threshold] = await Promise.all([
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "reservedTokens" }),
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "phantomQuote" }),
    client.readContract({ address: curve, abi: bondingCurveAbi, functionName: "graduationThreshold" }),
  ]);
  const target = mondayTargetSqrtPriceX96({ token, quote, quoteAmount: threshold, tokenAmount: reserved, phantomQuote: phantom });
  const sqrtP = BigInt(slot0[0]);
  let ticksToCross;
  if (sqrtP !== 0n && sqrtP !== target) {
    try {
      const spacing = Number(await client.readContract({ address: mondayFactory, abi: mondayFactoryAbi, functionName: "feeAmountTickSpacing", args: [fee] }));
      const tickFrom = Number(slot0[1]);
      const tickTo = tickAtSqrtPrice(target);
      const words = new Map();
      for (const w of bitmapWordsBetween({ tickSpacing: spacing, tickFrom, tickTo })) {
        if (w < -32768 || w > 32767) continue;
        words.set(w, await client.readContract({ address: pool, abi: mondayPoolAbi, functionName: "tickBitmap", args: [w] }));
      }
      ticksToCross = countInitializedTicksBetween({ words, tickSpacing: spacing, tickFrom, tickTo });
    } catch {
      ticksToCross = undefined; // unreadable -> treated as blocking
    }
  }
  return { pool, target, sqrtP, ticksToCross, ...assessMondaySquat({ poolExists: true, sqrtPriceX96: sqrtP, targetSqrtPriceX96: target, ticksToCross, mondayOnly, valveDelay }) };
}

/**
 * Is this Monday launch bound to Monday (a Monday-only quote asset, aBIL), and when may anyone take its v4 fallback?
 * A v2 factory snapshots the rule per launch (`launchMondayOnly`: a pair flagged after the launch does not bind it)
 * and opens the fallback to anyone once the launch has been stuck for `MONDAY_ONLY_FALLBACK_DELAY` (`valveDelay`).
 * The v1 factories have neither: the per-pair rule applies, and only the owner's allowV4Fallback opens it.
 */
async function mondayOnlyRule(client, lp, token, pairToken) {
  const at = { address: lp.factory, abi: launchpadFactoryV2Abi };
  const snapshot = await readOr(client, { ...at, functionName: "launchMondayOnly", args: [token] }, undefined);
  if (snapshot === undefined) {
    return { mondayOnly: await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "pairMondayOnly", args: [pairToken] }, false), valveDelay: undefined };
  }
  if (!snapshot) return { mondayOnly: false, valveDelay: undefined };
  return { mondayOnly: true, valveDelay: await readOr(client, { ...at, functionName: "MONDAY_ONLY_FALLBACK_DELAY" }, undefined) };
}

async function checkLaunch({ client, lp, token, monday, t, sender, reporter, state, budget, simAccount, mondayGas, v4Gas, watchProgressBps }) {
  const l = await launchRecord(client, lp, token);
  if (Number(l.phase) !== LAUNCH_PHASE.NotGraduated) return;
  const [completed, rescued, stuckSince] = await Promise.all([
    client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "completed" }),
    client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "rescued" }),
    client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName: "stuckSince", args: [token] }),
  ]);
  const venue = Number(l.graduationVenue);
  const target = `${lp.label} ${token}`;
  // A Monday-only quote asset (aBIL) has no permissionless v4 fallback on the live factories (on v2 only after a day
  // stuck): say so, loudly.
  const { mondayOnly, valveDelay } = venue === VENUE.Monday && !lp.legacyRecord ? await mondayOnlyRule(client, lp, token, l.pairToken) : { mondayOnly: false, valveDelay: undefined };
  const fallbackAllowed = mondayOnly && (await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "v4FallbackAllowed", args: [token] }, false));
  let squat;
  if (venue === VENUE.Monday && monday) {
    let watch = true;
    if (!completed && watchProgressBps > 0n) {
      const raised = await client.readContract({ address: l.curve, abi: bondingCurveAbi, functionName: "realQuoteReserve" });
      watch = raised * 10_000n >= l.graduationThreshold * watchProgressBps;
    }
    if (watch) {
      squat = await assessSquat(client, { ...monday, token, pairToken: l.pairToken, curve: l.curve, mondayOnly: mondayOnly && !fallbackAllowed, valveDelay });
      if (!completed && squat.level !== "none") {
        reporter.alert({ job: "launchpad-graduation", target, severity: squatSeverity(squat), key: `lp1:squat:${lp.factory.toLowerCase()}:${token.toLowerCase()}`, reason: `Monday pool ${squat.pool} squatted (${squat.level}): ${squat.reason}; pool sqrtPriceX96 ${squat.sqrtP}, graduation target ${squat.target}` });
      }
    }
  }
  if (!completed || rescued) return;
  const simG = await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduate", args: [token], account: simAccount, gas: venue === VENUE.Monday ? mondayGas : v4Gas });
  const simF = venue === VENUE.Monday && !simG.ok
    ? await simulate(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduateFallback", args: [token], account: simAccount, gas: mondayGas })
    : { ok: false };
  const d = decideStuckLaunch({ phase: Number(l.phase), venue, completed, rescued, stuckSince, now: t, simGraduate: simG.ok, simFallback: simF.ok, mondayOnly, v4FallbackAllowed: fallbackAllowed, valveDelay });
  if (d.action === "none") return;
  const extra = squat && squat.level !== "none" ? ` [Monday pool: ${squat.reason}]` : "";
  const stuck = { job: "launchpad-graduation", target, severity: d.severity, key: `lp1:stuck:${lp.factory.toLowerCase()}:${token.toLowerCase()}`, reason: `${d.reason}${d.rescueAt ? `; owner rescue possible from ${d.rescueAt}` : ""}${extra}` };
  // Monday graduation and the fallback keep a fixed, high gas limit on purpose: the realign swap must get as much gas
  // as one transaction allows. With less, a squat that more gas would realign moves to Uniswap v4 and the creator
  // loses the venue (the live fallback gives its Monday retry 63/64 of the gas; the v2 one everything above its v4
  // reserve, and refuses less than ~22.1M).
  let sent;
  if (d.action === "graduate") {
    reporter.action({ job: "launchpad-graduation", target, what: "graduate(token)" });
    const gas = venue === VENUE.Monday ? mondayGas : await gasFor(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "graduate", args: [token], account: simAccount }, v4Gas);
    sent = await safeSend({ sender, reporter, client, state, budget }, "launchpad-graduation", target, { to: lp.factory, signature: "graduate(address)", args: [token], gasLimit: gas, label: `graduate ${target}` });
  } else if (d.action === "graduateFallback") {
    reporter.action({ job: "launchpad-graduation", target, what: "graduateFallback(token)" });
    sent = await safeSend({ sender, reporter, client, state, budget }, "launchpad-graduation", target, { to: lp.factory, signature: "graduateFallback(address)", args: [token], gasLimit: mondayGas, label: `fallback ${target}` });
  }
  // Graduated by this run: nothing for a human (an earlier post of it resolves; a new one is never posted).
  if (sentOk(sent)) stuck.severity = "info";
  reporter.alert(stuck);
}

/**
 * Watches Monday-venue launches for squatted Monday pools BEFORE they complete (alert: pre-align or steer the
 * creator), and retries graduation of completed-but-stuck launches (plain graduate first, then the v4 fallback).
 */
export async function launchpadGraduationJob({ client, launchpads, sender, reporter, state, budget, simAccount = DEFAULT_SIM_ACCOUNT, mondayGas = MONDAY_GAS, v4Gas = 3_000_000n, watchProgressBps = 0n }) {
  const t = await now(client);
  for (const lp of launchpads) {
    await guard(reporter, "launchpad-graduation", lp.label, async () => {
      // The legacy factory keeps its Monday executor in the graduationExecutor slot and has no mondayExecutor().
      const mondayExec = lp.legacyRecord
        ? lp.graduationExecutor
        : await readOr(client, { address: lp.factory, abi: launchpadFactoryAbi, functionName: "mondayExecutor" }, ZERO);
      let monday;
      if (mondayExec && mondayExec !== ZERO) {
        const [mf, wmon, fee] = await Promise.all([
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "factory" }),
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "wmon" }),
          client.readContract({ address: mondayExec, abi: mondayExecutorAbi, functionName: "FEE" }),
        ]);
        monday = { mondayFactory: mf, wmon, fee };
      }
      const tokens = await allLaunches(client, lp.factory);
      for (const token of tokens) {
        await guard(reporter, "launchpad-graduation", `${lp.label} ${token}`, () =>
          checkLaunch({ client, lp, token, monday, t, sender, reporter, state, budget, simAccount, mondayGas, v4Gas, watchProgressBps }),
        );
      }
    });
  }
}

// ------------------------------------------------------------------------------------------------ governance watch

// Every owner/governance action that could redirect money, swap code or change who may launch or leave, per contract
// kind. CreatorFeeRecipientChangeProposed is the owner's most direct money lever on the live factories: anyone can
// execute it after 3 days unless the creator vetoes, and a pending takeover cannot be read from state, so this scan is
// the only way to see it in time. The v2-only events (ModulesSealed, GuardianSet, GuardianPaused) match nothing on the
// v1 contracts.
export const LAUNCHPAD_GOV_EVENTS = [
  "ModulesSet", "MondayExecutorSet", "ModulesSealed", "OwnershipTransferStarted", "FeePolicySet", "LaunchFeeSet", "MaxCreatorTaxSet",
  "PairEconomicsSet", "PairMondayOnlySet", "WhitelistSet", "WhitelistedSet", "LaunchConfigAdded", "LaunchConfigEnabled",
  "CreatorFeeRecipientChangeProposed", "V4FallbackAllowed", "LaunchRescued",
];
export const VAULT_GOV_EVENTS = ["LpFeeRecipientSet", "OwnershipTransferStarted"];
export const MOMENTS_GOV_EVENTS = [
  "GovernanceTransferStarted", "PolicyProposed", "PolicyApplied", "PolicyCancelled", "PublishingPaused", "ExternalBaseURISet", "GuardianSet", "GuardianPaused",
];

/** The events named in `names` from every ABI given; an event that more than one ABI declares with the same topic
    (signature) is listed once. */
function events(abis, names) {
  const out = new Map();
  for (const abi of abis) {
    for (const x of abi) {
      if (x.type !== "event" || !names.includes(x.name)) continue;
      out.set(`${x.name}(${x.inputs.map((i) => i.type === "tuple" ? `(${i.components.map((c) => c.type).join(",")})` : i.type).join(",")})`, x);
    }
  }
  return [...out.values()];
}

/** What a governance event says beyond its name, when a human needs it to act. */
function eventDetail(l) {
  if (l.eventName === "CreatorFeeRecipientChangeProposed") {
    const a = l.args ?? {};
    return `: owner takeover of ${a.token}'s creator fees to ${a.newRecipient}, executable by anyone from ${a.effectiveAt} to ${a.expiresAt} unless the creator (or the owner) cancels it; warn the creator now`;
  }
  return "";
}

const eqAddr = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();

/** At most one alert per `key` per day (the state file remembers when), for standing conditions that would otherwise
    print on every run. On the runs in between the condition still stands: `hold` tells the notifier (notify.mjs) so it
    is not taken as resolved. */
function throttled(state, key, t, fn, hold = () => {}) {
  const last = BigInt(state[key]?.lastAlert ?? 0);
  if (t - last < DAY) {
    hold();
    return;
  }
  state[key] = { lastAlert: Number(t) };
  fn();
}

/**
 * Governance watch (2026-09-26 ops audit): the governance key (a plain EOA, SEC-1) can still swap modules on a factory
 * with no launch, repoint fees, and propose Moments policies. This job compares every factory's and vault's roles and
 * modules with the deployment records (critical on any drift), flags a launchpad whose modules are not frozen yet,
 * pending ownership/governance transfers and policy proposals, and, with `logsLookback`, every governance event.
 * `expected` = { owner, treasury, feesRecipient, momentsGovernance, externalBaseURI } from the live records; a cohort
 * whose record names a `guardian` (v2) is held to it, and its guardian's pause is a warning. The previous
 * stacks keep their own owner key and are not paused on chain (owner decision 2026-09-28: retired in the app only), so a
 * retired stack's owner/governance is checked against its own record, and a retired cohort that is open by that decision
 * (`openOnChain`, deployments.mjs) or a retired launchpad left unfrozen (0x6B1C) is reported, not alerted; treasury and
 * fee recipients are the live ones everywhere.
 */
export async function governanceJob({ client, launchpads, cohorts, reporter, state, expected, ...logArgs }) {
  const logs = logOptions(logArgs);
  const t = await now(client);
  const job = "governance";
  const critical = (target, reason, key) => reporter.alert({ job, target, severity: "critical", reason, key: `gov:${key}` });
  for (const lp of launchpads) {
    await guard(reporter, job, lp.label, async () => {
      const fac = lp.factory.toLowerCase();
      const read = (functionName) => client.readContract({ address: lp.factory, abi: launchpadFactoryAbi, functionName });
      const modules = [
        ["hook", "hook"],
        ["graduationExecutor", "graduationExecutor"],
        ["locker", "locker"],
        ["escrow", "escrow"],
        ["holderFeeSharing", "holderFeeSharing"],
        ["router", "launchAndBuyRouter"],
        ["launchDeployer", "launchDeployer"],
        ...(lp.legacyRecord ? [] : [["mondayExecutor", "mondayExecutor"]]),
      ];
      for (const [fn, key] of modules) {
        const onChain = await read(fn);
        if (lp[key] && !eqAddr(onChain, lp[key])) critical(lp.label, `module ${fn}() is ${onChain}, the record says ${lp[key]}: a module was swapped`, `module:${fac}:${fn}`);
      }
      const [owner, pendingOwner, recipient, count] = await Promise.all([read("owner"), read("pendingOwner"), read("protocolFeeRecipient"), read("launchCount")]);
      const wantOwner = lp.live ? expected.owner : lp.owner ?? expected.owner;
      if (!eqAddr(owner, wantOwner)) critical(lp.label, `owner() is ${owner}, expected ${wantOwner}`, `owner:${fac}`);
      if (!eqAddr(pendingOwner, ZERO)) critical(lp.label, `an ownership transfer to ${pendingOwner} is pending`, `pendingOwner:${fac}`);
      if (!eqAddr(recipient, expected.treasury)) critical(lp.label, `protocolFeeRecipient() is ${recipient}, expected ${expected.treasury}`, `protocolFeeRecipient:${fac}`);
      const sealed = await readOr(client, { address: lp.factory, abi: launchpadFactoryV2Abi, functionName: "modulesSealed" }, false);
      if (count === 0n && !sealed && lp.live) {
        throttled(
          state,
          `gov:${fac}:unfrozen`,
          t,
          () => reporter.alert({ job, target: lp.label, severity: "warning", key: `gov:unfrozen:${fac}`, reason: "no launch yet and modules not sealed: the owner key can still replace any module, and the first launch freezes whatever is set. Close the factory or freeze it with a canary launch (owner runbook)" }),
          () => reporter.hold?.(`gov:unfrozen:${fac}`),
        );
      } else if (count === 0n && !sealed) {
        // Left open on chain by the same decision; a module swap there is still critical (the checks above, the event scan).
        reporter.alert({ job, target: lp.label, severity: "info", key: `gov:unfrozen:${fac}`, reason: "no launch yet and modules not sealed: retired in the app only and left open on chain (owner decision 2026-09-28)" });
      }
      if (lp.feeVault && !eqAddr(lp.feeVault, ZERO)) {
        const v = (functionName) => client.readContract({ address: lp.feeVault, abi: mondayFeeVaultAbi, functionName });
        const [vOwner, vPending, vRecipient] = await Promise.all([v("owner"), v("pendingOwner"), v("lpFeeRecipient")]);
        const target = `${lp.label} fee vault`;
        const vault = lp.feeVault.toLowerCase();
        if (!eqAddr(vOwner, wantOwner)) critical(target, `owner() is ${vOwner}, expected ${wantOwner}`, `vault-owner:${vault}`);
        if (!eqAddr(vPending, ZERO)) critical(target, `an ownership transfer to ${vPending} is pending`, `vault-pendingOwner:${vault}`);
        if (!eqAddr(vRecipient, expected.feesRecipient)) critical(target, `lpFeeRecipient() is ${vRecipient}, expected ${expected.feesRecipient}`, `vault-lpFeeRecipient:${vault}`);
      }
    });
  }
  for (const c of cohorts) {
    await guard(reporter, job, c.label, async () => {
      const fac = c.factory.toLowerCase();
      const read = (functionName) => client.readContract({ address: c.factory, abi: momentsFactoryAbi, functionName });
      const [gov, pendingGov, pendingAt, paused] = await Promise.all([read("governance"), read("pendingGovernance"), read("pendingPolicyAt"), read("publishingPaused")]);
      const wantGov = c.live ? expected.momentsGovernance : c.governance ?? expected.momentsGovernance;
      if (!eqAddr(gov, wantGov)) critical(c.label, `governance() is ${gov}, expected ${wantGov}`, `governance:${fac}`);
      if (!eqAddr(pendingGov, ZERO)) critical(c.label, `a governance transfer to ${pendingGov} is pending`, `pendingGovernance:${fac}`);
      if (BigInt(pendingAt) !== 0n) {
        reporter.alert({ job, target: c.label, severity: BigInt(pendingAt) <= t ? "critical" : "warning", key: `gov:policy:${fac}`, reason: `a policy proposal is pending, applicable from ${pendingAt}: check it is intended, or cancel it` });
      }
      if (!c.live && !paused) {
        if (c.openOnChain) reporter.alert({ job, target: c.label, severity: "info", key: `gov:publishing:${fac}`, reason: "publishing is open on chain: retired in the app only (owner decision 2026-09-28)" });
        else critical(c.label, "a retired cohort is publishing again (its policy pays retired wallets)", `publishing:${fac}`);
      }
      if (c.live && expected.externalBaseURI !== undefined) {
        const base = await read("externalBaseURI");
        if (base !== expected.externalBaseURI) critical(c.label, `externalBaseURI() is "${base}", expected "${expected.externalBaseURI}"`, `externalBaseURI:${fac}`);
      }
      // A v2 cohort's record names its guardian. Only the guardian can hand the role on or lift its own pause, and
      // governance cannot, so a changed guardian is critical and its pause (publishing stops) is a warning.
      if (c.guardian) {
        const readV2 = (functionName) => client.readContract({ address: c.factory, abi: momentsFactoryV2Abi, functionName });
        const [guardian, guardianPaused] = await Promise.all([readV2("guardian"), readV2("guardianPaused")]);
        if (!eqAddr(guardian, c.guardian)) critical(c.label, `guardian() is ${guardian}, the record says ${c.guardian}: the guardian role was handed on or renounced`, `guardian:${fac}`);
        if (guardianPaused) reporter.alert({ job, target: c.label, severity: "warning", key: `gov:guardianPaused:${fac}`, reason: "the guardian paused publishing (guardianPaused): only the guardian can lift it" });
      }
    });
  }
  if (!logs.enabled) return;
  // One scan (and one cursor) per contract kind, so each keeps its own progress.
  const scans = [
    ["launchpads", launchpads.map((l) => l.factory), events([launchpadFactoryAbi, launchpadFactoryV2Abi], LAUNCHPAD_GOV_EVENTS)],
    ["fee vaults", launchpads.map((l) => l.feeVault).filter((a) => a && !eqAddr(a, ZERO)), events([mondayFeeVaultAbi], VAULT_GOV_EVENTS)],
    ["moments", cohorts.map((c) => c.factory), events([momentsFactoryAbi, momentsFactoryV1Abi, momentsFactoryV2Abi], MOMENTS_GOV_EVENTS)],
  ].filter(([, address]) => address.length > 0);
  for (const [i, [kind, address, evs]] of scans.entries()) {
    const label = `governance event scan (${kind})`;
    await guard(reporter, job, label, () =>
      scanLogs({
        client,
        reporter,
        state,
        job,
        scanId: `gov:${kind.replace(" ", "-")}`,
        label,
        logs: shareOf(logs, i, scans.length),
        fetchRange: (from, to) => getLogsChunked(client, { address, events: evs, from, to, chunk: logs.chunk }),
        onLogs: (found) => {
          for (const l of found) {
            // An event happened once: posted once (a re-scanned block does not post it again), never "resolved".
            reporter.alert({ job, target: l.address, severity: "critical", key: `gov:event:${l.transactionHash}:${l.logIndex}`, once: true, reason: `governance event ${l.eventName} in block ${l.blockNumber} (tx ${l.transactionHash})${eventDetail(l)}` });
          }
        },
      }),
    );
  }
}
