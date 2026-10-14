// Job-level tests: each job runs against a mocked chain (a table of view results + simulation outcomes) and a
// dry-run sender; we assert exactly which calls it would send and which alerts it raises.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, cpSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { momentsGraduationJob, buybacksJob, sweepsJob, launchpadGraduationJob, governanceJob, getLogsChunked } from "../lib/jobs.mjs";
import { makeSender } from "../lib/send.mjs";
import { makeReporter } from "../lib/report.mjs";
import { mondayTargetSqrtPriceX96, tickAtSqrtPrice } from "../lib/decide.mjs";
import { launchpads, momentsCohorts, pinMismatches, LIVE_FACTORIES, OPEN_ON_CHAIN_MOMENTS } from "../lib/deployments.mjs";

const NOW = 1_790_000_000n;
const DAY = 86_400n;
const a = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const ZERO = a(0);

function mockClient({ reads, sims = {}, head = 1000n, getLogs, estimates, gasPrice }) {
  const k = (addr, fn, args = []) => `${addr}:${fn}:${args.map(String).join(",")}`.toLowerCase();
  return {
    reads: new Map(Object.entries(reads).map(([key, v]) => [key.toLowerCase(), v])),
    logCalls: [],
    async getBlock() {
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return head;
    },
    async getLogs(req) {
      this.logCalls.push(req);
      return getLogs ? getLogs(req) : [];
    },
    ...(estimates
      ? {
          async estimateContractGas({ address, functionName, args }) {
            const e = estimates[k(address, functionName, args)];
            if (e === undefined) throw new Error("cannot estimate");
            return e;
          },
        }
      : {}),
    ...(gasPrice !== undefined
      ? {
          async getGasPrice() {
            return gasPrice;
          },
        }
      : {}),
    async readContract({ address, functionName, args }) {
      const key = k(address, functionName, args);
      if (!this.reads.has(key)) throw new Error(`unmocked read ${key}`);
      const v = this.reads.get(key);
      if (v instanceof Error) throw v;
      return v;
    },
    async simulateContract({ address, functionName, args }) {
      const s = sims[k(address, functionName, args)];
      if (s === undefined || s instanceof Error) throw s ?? new Error("execution reverted");
      return { result: s };
    },
  };
}

function harness() {
  const logs = [];
  const sender = makeSender({ rpcUrl: "http://x", log: (l) => logs.push(l) });
  const reporter = makeReporter({ log: () => {} });
  return { sender, reporter, logs, state: {} };
}

// ---------------------------------------------------------------- MO-1

const cohort = { label: "cohort4 (live)", factory: a(0xf1), collect: a(0xc1), graduation: a(0x91), hook: a(0x41), buyback: a(0xb1), locker: a(0x11), usdc: a(0x05) };
const moment = (deadline) => ({ deadline, creator: a(1), platform: a(2), treasury: a(3), coin: a(4), nft: a(5) });
const ledger = (stuckSince) => ({ state: 1, completedAt: stuckSince, stuckSince, endedAt: 0n, reserve: 1n });

test("MO-1: retries every GraduationPending Moment and alerts; skips the rest", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 3n,
      [`${cohort.collect}:state:1`]: 2, // graduated
      [`${cohort.collect}:state:2`]: 1, // pending: griefed
      [`${cohort.collect}:state:3`]: 1, // pending: genuinely failing
      [`${cohort.collect}:ledger:2`]: ledger(NOW - DAY),
      [`${cohort.collect}:ledger:3`]: ledger(NOW - 6n * DAY - 23n * 3600n),
      [`${cohort.factory}:getMoment:2`]: moment(NOW + 20n * DAY),
      [`${cohort.factory}:getMoment:3`]: moment(NOW - DAY),
    },
    sims: { [`${cohort.graduation}:graduate:2`.toLowerCase()]: null },
  });
  const h = harness();
  await momentsGraduationJob({ client, cohorts: [cohort], ...h });
  assert.equal(h.sender.sent.length, 1, "one retry sent");
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", cohort.graduation, "graduate(uint256)", "2"]);
  assert.equal(h.reporter.alerts.length, 2);
  const [g, f] = h.reporter.alerts;
  assert.equal(g.severity, "warning");
  assert.match(g.target, /#2/);
  assert.equal(f.severity, "critical", "retry reverts and expiry is < 1h away");
  assert.match(f.reason, /REVERTS/);
  assert.equal(h.state[`moment:${cohort.collect}:3`].failures, 1, "failure remembered for the next run");
});

test("MO-1: a failure seen on an earlier run escalates even when the retry now simulates", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 1n,
      [`${cohort.collect}:state:1`]: 1,
      [`${cohort.collect}:ledger:1`]: ledger(NOW),
      [`${cohort.factory}:getMoment:1`]: moment(NOW + 20n * DAY),
    },
    sims: { [`${cohort.graduation}:graduate:1`.toLowerCase()]: null },
  });
  const h = harness();
  h.state[`moment:${cohort.collect}:1`] = { failures: 2 };
  await momentsGraduationJob({ client, cohorts: [cohort], ...h });
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.equal(h.sender.sent.length, 1);
});

// ---------------------------------------------------------------- MO-2

test("MO-2: executes due buybacks with a simulated minCoinOut and flags idle locker USDC", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 2n,
      [`${cohort.buyback}:MIN_AMOUNT:`]: 1_000_000n,
      [`${cohort.buyback}:MIN_INTERVAL:`]: 3600n,
      [`${cohort.collect}:state:1`]: 2,
      [`${cohort.collect}:state:2`]: 2,
      [`${cohort.hook}:buybackAccrued:1`]: 5_000_000n,
      [`${cohort.buyback}:carry:1`]: 0n,
      [`${cohort.buyback}:lastRun:1`]: 0n,
      [`${cohort.hook}:buybackAccrued:2`]: 10n, // not worth a round
      [`${cohort.buyback}:carry:2`]: 0n,
      [`${cohort.buyback}:lastRun:2`]: 0n,
      [`${cohort.usdc}:balanceOf:${cohort.locker}`]: 75_000_000n,
    },
    sims: { [`${cohort.buyback}:execute:1,0`.toLowerCase()]: { coinBought: 1_000_000n } },
  });
  const h = harness();
  await buybacksJob({ client, cohorts: [cohort], ...h, slippageBps: 100n, lockerIdleAlert: 50_000_000n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 5), ["send", cohort.buyback, "execute(uint256,uint256)", "1", "990000"]);
  assert.equal(h.reporter.alerts.length, 1);
  assert.match(h.reporter.alerts[0].reason, /idle USDC/);
});

// A v2 locker adds at most 0.5% of a position per round, so the cohort's shared balance is mostly remainders held for
// their Moments: the alert follows each Moment's own heldOf, not the whole locker (which would fire on every run).
test("MO-2: on a v2 locker the idle alert is per Moment (heldOf), not the whole locker", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 2n,
      [`${cohort.buyback}:MIN_AMOUNT:`]: 1_000_000n,
      [`${cohort.buyback}:MIN_INTERVAL:`]: 3600n,
      [`${cohort.collect}:state:1`]: 2,
      [`${cohort.collect}:state:2`]: 2,
      [`${cohort.locker}:heldOf:1,${cohort.usdc}`]: 40_000_000n,
      [`${cohort.locker}:heldOf:2,${cohort.usdc}`]: 60_000_000n,
      [`${cohort.hook}:buybackAccrued:1`]: 10n,
      [`${cohort.buyback}:carry:1`]: 0n,
      [`${cohort.buyback}:lastRun:1`]: 0n,
      [`${cohort.hook}:buybackAccrued:2`]: 10n,
      [`${cohort.buyback}:carry:2`]: 0n,
      [`${cohort.buyback}:lastRun:2`]: 0n,
      [`${cohort.usdc}:balanceOf:${cohort.locker}`]: 100_000_000n,
    },
  });
  const h = harness();
  await buybacksJob({ client, cohorts: [cohort], ...h, lockerIdleAlert: 50_000_000n });
  assert.equal(h.reporter.alerts.length, 1, "only the Moment above the threshold");
  assert.match(h.reporter.alerts[0].target, /moment #2 locker/);
  assert.match(h.reporter.alerts[0].reason, /this Moment 60000000 idle USDC/);
});

// ---------------------------------------------------------------- Launchpad fixtures

const lp = { label: "launchpad (live)", factory: a(0xfa), hook: a(0x4a) };
const WMON = a(0x3b);
const mondayExec = a(0xe0);
const mondayFactory = a(0xe1);
const launch = (over) => ({
  token: a(0x7001),
  curve: a(0xc001),
  pairToken: ZERO,
  graduationThreshold: 16_000n * 10n ** 18n,
  holderFeeSharing: true,
  graduationVenue: 0,
  phase: 2,
  poolId: `0x${"ab".repeat(32)}`,
  exists: true,
  ...over,
});

test("LP-2: sweeps holder-sharing quote fees; leaves creator-only token fees below the floor", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 1n,
      [`${lp.factory}:getLaunches:0,100`]: [tok],
      [`${lp.factory}:getLaunchedToken:${tok}`]: l,
      [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 3n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 9n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
    },
    sims: { [`${lp.hook}:sweepPoolFees:${l.poolId},${ZERO}`.toLowerCase()]: null },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h, minOther: 10n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 5), ["send", lp.hook, "sweepPoolFees(bytes32,address)", l.poolId, ZERO]);
});

test("LP-2: a sweep that would revert is not sent (it would still pay gas) and raises an alert", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 1n,
      [`${lp.factory}:getLaunches:0,100`]: [tok],
      [`${lp.factory}:getLaunchedToken:${tok}`]: l,
      [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 3n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 0n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
    },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h, minOther: 10n });
  assert.equal(h.sender.sent.length, 0);
  assert.equal(h.reporter.alerts.length, 1);
});

test("LP-2: Monday-venue and not-yet-graduated launches are not swept", async () => {
  const t1 = a(0x7001);
  const t2 = a(0x7002);
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 2n,
      [`${lp.factory}:getLaunches:0,100`]: [t1, t2],
      [`${lp.factory}:getLaunchedToken:${t1}`]: launch({ graduationVenue: 1 }),
      [`${lp.factory}:getLaunchedToken:${t2}`]: launch({ token: t2, phase: 0 }),
    },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0);
});

// ---------------------------------------------------------------- LP-1

function lp1Reads({ tok, l, completed, stuckSince, pool, slot0, bitmap = {} }) {
  const reads = {
    [`${lp.factory}:mondayExecutor:`]: mondayExec,
    [`${mondayExec}:factory:`]: mondayFactory,
    [`${mondayExec}:wmon:`]: WMON,
    [`${mondayExec}:FEE:`]: 10_000,
    [`${lp.factory}:launchCount:`]: 1n,
    [`${lp.factory}:getLaunches:0,100`]: [tok],
    [`${lp.factory}:getLaunchedToken:${tok}`]: l,
    [`${l.curve}:completed:`]: completed,
    [`${l.curve}:rescued:`]: false,
    [`${lp.factory}:stuckSince:${tok}`]: stuckSince,
    [`${mondayFactory}:getPool:${tok},${WMON},10000`]: pool,
    [`${l.curve}:reservedTokens:`]: 200_000_000n * 10n ** 18n,
    [`${l.curve}:phantomQuote:`]: 4_000n * 10n ** 18n,
    [`${l.curve}:graduationThreshold:`]: 16_000n * 10n ** 18n,
    [`${mondayFactory}:feeAmountTickSpacing:10000`]: 200,
  };
  if (pool !== ZERO) reads[`${pool}:slot0:`] = slot0;
  for (const [w, v] of Object.entries(bitmap)) reads[`${pool}:tickBitmap:${w}`] = v;
  return reads;
}

function denseSquatReads(tok, l, pool) {
  const target = mondayTargetSqrtPriceX96({ token: tok, quote: WMON, quoteAmount: 16_000n * 10n ** 18n, tokenAmount: 200_000_000n * 10n ** 18n, phantomQuote: 4_000n * 10n ** 18n });
  const tickTo = tickAtSqrtPrice(target);
  const squatTick = 600_000;
  const full = (1n << 256n) - 1n; // every tick in every word initialized
  const bitmap = {};
  for (let w = Math.floor(Math.min(tickTo, squatTick) / 200) >> 8; w <= Math.ceil(Math.max(tickTo, squatTick) / 200) >> 8; w++) bitmap[w] = full;
  return lp1Reads({ tok, l, completed: false, stuckSince: 0n, pool, slot0: [1n << 150n, squatTick, 0, 1, 1, 0, true], bitmap });
}

// sec2: the live graduateFallback recovers a blocking squat on an ordinary pair with >= ~12M gas (test/sec2/
// Sec2LiveV1.t.sol), so before completion that is a warning; only a Monday-only pair (aBIL) freezes holders.
test("LP-1: a dense squat on an ordinary pair is a warning that names the v4 fallback", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = denseSquatReads(tok, l, a(0x9001));
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0, "nothing to send before completion");
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].severity, "warning");
  assert.match(h.reporter.alerts[0].reason, /blocking/);
  assert.match(h.reporter.alerts[0].reason, /graduateFallback/);
});

test("LP-1: a dense squat on a Monday-only pair (aBIL) raises a critical pre-completion alert naming the owner", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = denseSquatReads(tok, l, a(0x9001));
  reads[`${lp.factory}:pairMondayOnly:${l.pairToken}`] = true;
  reads[`${lp.factory}:v4FallbackAllowed:${tok}`] = false;
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.match(h.reporter.alerts[0].reason, /allowV4Fallback/);
});

test("LP-1: no Monday pool yet -> silent", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: false, stuckSince: 0n, pool: ZERO });
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts.length, 0);
});

test("LP-1: stuck Monday launch whose high-gas Monday retry works -> graduate(token) with the big gas limit", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const client = mockClient({ reads, sims: { [`${lp.factory}:graduate:${tok}`.toLowerCase()]: null } });
  const h = harness();
  await launchpadGraduationJob({ client, launchpads: [lp], ...h, mondayGas: 25_000_000n });
  assert.equal(h.sender.sent.length, 1);
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", lp.factory, "graduate(address)", tok]);
  assert.ok(h.sender.sent[0].argv.includes("25000000"));
});

test("LP-1: stuck Monday launch where both paths fail -> critical alert with the rescue time, nothing sent", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 0);
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.match(h.reporter.alerts[0].reason, /rescue possible from/);
});

test("LP-1: stuck Monday launch where only the v4 fallback works -> graduateFallback", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  const client = mockClient({ reads, sims: { [`${lp.factory}:graduateFallback:${tok}`.toLowerCase()]: null } });
  const h = harness();
  await launchpadGraduationJob({ client, launchpads: [lp], ...h });
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", lp.factory, "graduateFallback(address)", tok]);
  // The fallback's own Monday retry must get as much gas as one transaction allows: with 25M a squat that ~29.9M
  // realigns (1,100-1,200 dust ticks on the live factory) moved to Uniswap v4 and dropped the creator's venue.
  assert.ok(h.sender.sent[0].argv.includes("29900000"), "just under Monad's 30M per-transaction cap");
});

// ---------------------------------------------------------------- sec2: robustness (2026-09-26 ops audit)

const retiredCohort = { label: "cohort2 (retired)", factory: a(0xf2), collect: a(0xc2), graduation: a(0x92) };

// rpc.monad.xyz answers eth_getLogs over more than 100 blocks with -32614 "eth_getLogs is limited to a 100 range".
// Before: the MO-1 job scanned 500-block chunks per cohort before the next cohort's retries, so the first scan threw
// and a later cohort's pending Moment (1 day from expiry) never got its retry.
test("sec2 MO-1: a getLogs range cap neither aborts the job nor starves a later cohort's retry", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: 0n,
      [`${retiredCohort.factory}:momentCount:`]: 1n,
      [`${retiredCohort.collect}:state:1`]: 1,
      [`${retiredCohort.collect}:ledger:1`]: ledger(NOW - 6n * DAY),
      [`${retiredCohort.factory}:getMoment:1`]: moment(NOW - DAY),
    },
    sims: { [`${retiredCohort.graduation}:graduate:1`.toLowerCase()]: null },
    head: 1_000_000n,
    getLogs: ({ fromBlock, toBlock }) => {
      if (toBlock - fromBlock + 1n > 100n) throw Object.assign(new Error("RPC Request failed."), { details: "eth_getLogs is limited to a 100 range" });
      return [];
    },
  });
  const h = harness();
  await momentsGraduationJob({ client, cohorts: [cohort, retiredCohort], logsLookback: 1000n, logsChunk: 500n, ...h });
  assert.equal(h.sender.sent.length, 1, "the retired cohort's retry is sent");
  assert.deepEqual(h.sender.sent[0].argv.slice(0, 4), ["send", retiredCohort.graduation, "graduate(uint256)", "1"]);
  assert.ok(!h.reporter.alerts.some((x) => /could not be checked/.test(x.reason)), "the scans adapted to the cap");
  assert.equal(client.logCalls.at(-1).toBlock, 1_000_000n, "each cohort's scan reached the head");
});

test("sec2: one failing read is an alert, and the items after it are still handled", async () => {
  const client = mockClient({
    reads: {
      [`${cohort.factory}:momentCount:`]: new Error("429 Too Many Requests"),
      [`${retiredCohort.factory}:momentCount:`]: 1n,
      [`${retiredCohort.collect}:state:1`]: 1,
      [`${retiredCohort.collect}:ledger:1`]: ledger(NOW - DAY),
      [`${retiredCohort.factory}:getMoment:1`]: moment(NOW + DAY),
    },
    sims: { [`${retiredCohort.graduation}:graduate:1`.toLowerCase()]: null },
  });
  const h = harness();
  await momentsGraduationJob({ client, cohorts: [cohort, retiredCohort], ...h });
  assert.equal(h.sender.sent.length, 1);
  const failed = h.reporter.alerts.find((x) => x.target === cohort.label);
  assert.equal(failed.severity, "critical");
  assert.match(failed.reason, /429/);
});

test("sec2: getLogsChunked halves its range on a cap and returns every log", async () => {
  const client = mockClient({
    reads: {},
    getLogs: ({ fromBlock, toBlock }) => {
      if (toBlock - fromBlock + 1n > 100n) throw new Error("eth_getLogs is limited to a 100 range");
      return fromBlock <= 250n && 250n <= toBlock ? [{ blockNumber: 250n }] : [];
    },
  });
  const logs = await getLogsChunked(client, { address: a(1), from: 0n, to: 999n, chunk: 500n });
  assert.deepEqual(logs, [{ blockNumber: 250n }]);
});

// Monad bills the gas LIMIT. Before: 1 wei of pending holder fee made the keeper send a 1.5M-gas sweep, from the same
// wallet that pays the MO-1 retries; an attacker could leave dust in every pool every 15 minutes.
test("sec2 LP-2: a dust holder backlog is not swept; a real one is, with an estimated gas limit", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const base = {
    [`${lp.factory}:launchCount:`]: 1n,
    [`${lp.factory}:getLaunches:0,100`]: [tok],
    [`${lp.factory}:getLaunchedToken:${tok}`]: l,
    [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
    [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 0n,
    [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
  };
  const sims = { [`${lp.hook}:sweepPoolFees:${l.poolId},${ZERO}`.toLowerCase()]: null };
  const estimates = { [`${lp.hook}:sweepPoolFees:${l.poolId},${ZERO}`.toLowerCase()]: 150_000n };
  const gasPrice = 202_000_000_000n; // 202 gwei, as seen on Monad
  const dust = harness();
  await sweepsJob({ client: mockClient({ reads: { ...base, [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 1n }, sims, estimates, gasPrice }), launchpads: [lp], ...dust });
  assert.equal(dust.sender.sent.length, 0, "1 wei is not worth a sweep");
  const real = harness();
  await sweepsJob({ client: mockClient({ reads: { ...base, [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 10n ** 18n }, sims, estimates, gasPrice }), launchpads: [lp], ...real });
  assert.equal(real.sender.sent.length, 1);
  assert.ok(real.sender.sent[0].argv.includes("180000"), "estimateGas x 1.2, not the fixed 1.5M");
});

// v2 (LP-2) keeps the protocol's cut of holder-sharing pools in pendingProtocolFees; reading only pendingFees and
// pendingCreatorTax would show 0 forever and never sweep it.
test("sec2 LP-2: a v2 hook's pendingProtocolFees counts toward a sweep", async () => {
  const tok = a(0x7001);
  const l = launch({});
  const client = mockClient({
    reads: {
      [`${lp.factory}:launchCount:`]: 1n,
      [`${lp.factory}:getLaunches:0,100`]: [tok],
      [`${lp.factory}:getLaunchedToken:${tok}`]: l,
      [`${lp.hook}:pendingFees:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${ZERO}`]: 0n,
      [`${lp.hook}:pendingProtocolFees:${l.poolId},${ZERO}`]: 5n * 10n ** 17n,
      [`${lp.hook}:pendingFees:${l.poolId},${tok}`]: 0n,
      [`${lp.hook}:pendingCreatorTax:${l.poolId},${tok}`]: 0n,
      [`${lp.hook}:pendingProtocolFees:${l.poolId},${tok}`]: 0n,
    },
    sims: { [`${lp.hook}:sweepPoolFees:${l.poolId},${ZERO}`.toLowerCase()]: null },
  });
  const h = harness();
  await sweepsJob({ client, launchpads: [lp], ...h });
  assert.equal(h.sender.sent.length, 1);
});

test("sec2: the legacy 0xad3d factory is read with its 16-field record and its Monday executor from the record", async () => {
  const legacy = { label: "launchpad 0xad3d (retired)", factory: a(0xad), hook: a(0x4d), graduationExecutor: mondayExec, legacyRecord: true };
  const tok = a(0x7001);
  const l = launch({ phase: 0 });
  delete l.graduationVenue;
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  delete reads[`${lp.factory}:mondayExecutor:`];
  const remapped = Object.fromEntries(Object.entries(reads).map(([k2, v]) => [k2.replace(lp.factory, legacy.factory), v]));
  const client = mockClient({ reads: remapped, sims: { [`${legacy.factory}:graduate:${tok}`.toLowerCase()]: null } });
  const legacyShapes = [];
  const read = client.readContract.bind(client);
  client.readContract = async (req) => {
    if (req.functionName === "mondayExecutor") throw new Error("execution reverted"); // like the real 0xad3d
    if (req.functionName === "getLaunchedToken") legacyShapes.push(req.abi[0].outputs[0].components.length);
    return read(req);
  };
  const h = harness();
  await launchpadGraduationJob({ client, launchpads: [legacy], ...h });
  assert.deepEqual(legacyShapes, [16]);
  assert.equal(h.sender.sent.length, 1, "a stuck legacy launch is retried on Monday");
  assert.ok(h.sender.sent[0].argv.includes("29900000"), "with the Monday gas limit");
  const sw = harness();
  await sweepsJob({ client, launchpads: [legacy], ...sw });
  assert.equal(sw.reporter.alerts.length, 0, "nothing to sweep on an all-Monday factory");
});

test("sec2 LP-1: a stuck Monday-only launch tells the on-call that the OWNER must act", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  reads[`${lp.factory}:pairMondayOnly:${l.pairToken}`] = true;
  reads[`${lp.factory}:v4FallbackAllowed:${tok}`] = false;
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.match(h.reporter.alerts[0].reason, /OWNER calls allowV4Fallback/);
});

// A v2 factory snapshots the Monday-only rule per launch and opens the v4 fallback to anyone after a day stuck. Reading
// the live per-pair rule instead misjudged launches whose pair was flagged after they launched, and called every
// stuck Monday-only launch "frozen until the OWNER calls allowV4Fallback", past the public valve too.
test("sec2 LP-1 (v2): a pair flagged after the launch does not make that launch Monday-only", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = lp1Reads({ tok, l, completed: true, stuckSince: NOW - 3600n, pool: ZERO });
  reads[`${lp.factory}:launchMondayOnly:${tok}`] = false; // the v2 snapshot
  reads[`${lp.factory}:pairMondayOnly:${l.pairToken}`] = true; // flagged later
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts[0].severity, "critical");
  assert.doesNotMatch(h.reporter.alerts[0].reason, /Monday-only/);
});

test("sec2 LP-1 (v2): a stuck Monday-only launch names the public valve time, then the keeper takes the fallback", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const stuckSince = NOW - 3600n;
  const reads = lp1Reads({ tok, l, completed: true, stuckSince, pool: ZERO });
  reads[`${lp.factory}:launchMondayOnly:${tok}`] = true;
  reads[`${lp.factory}:MONDAY_ONLY_FALLBACK_DELAY:`] = DAY;
  reads[`${lp.factory}:v4FallbackAllowed:${tok}`] = false;
  const before = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...before });
  assert.equal(before.sender.sent.length, 0);
  assert.equal(before.reporter.alerts[0].severity, "critical");
  assert.match(before.reporter.alerts[0].reason, new RegExp(`opens to anyone at ${stuckSince + DAY}.*OWNER calls allowV4Fallback`));
  // a day later the fallback simulates: the keeper sends it
  reads[`${lp.factory}:stuckSince:${tok}`] = NOW - DAY - 1n;
  const after = harness();
  await launchpadGraduationJob({ client: mockClient({ reads, sims: { [`${lp.factory}:graduateFallback:${tok}`.toLowerCase()]: null } }), launchpads: [lp], ...after });
  assert.deepEqual(after.sender.sent[0].argv.slice(0, 4), ["send", lp.factory, "graduateFallback(address)", tok]);
});

test("sec2 LP-1 (v2): a blocking squat on a Monday-only launch is a warning naming the valve, not a page", async () => {
  const tok = a(0x7001);
  const l = launch({ graduationVenue: 1, phase: 0 });
  const reads = denseSquatReads(tok, l, a(0x9001));
  reads[`${lp.factory}:launchMondayOnly:${tok}`] = true;
  reads[`${lp.factory}:MONDAY_ONLY_FALLBACK_DELAY:`] = DAY;
  reads[`${lp.factory}:v4FallbackAllowed:${tok}`] = false;
  const h = harness();
  await launchpadGraduationJob({ client: mockClient({ reads }), launchpads: [lp], ...h });
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].severity, "warning");
  assert.match(h.reporter.alerts[0].reason, /opens to anyone after 86400s stuck/);
});

// ---------------------------------------------------------------- sec2: governance watch

const expected = { owner: a(0x0a), treasury: a(0x0b), feesRecipient: a(0x0c), momentsGovernance: a(0x0a), externalBaseURI: "https://dyorhq.fun/moments/c4/" };
const govPad = {
  label: "launchpad (live)",
  live: true,
  factory: a(0xfa),
  hook: a(0x4a),
  graduationExecutor: a(0x61),
  locker: a(0x62),
  escrow: a(0x63),
  holderFeeSharing: a(0x64),
  launchAndBuyRouter: a(0x65),
  launchDeployer: a(0x66),
  mondayExecutor: a(0x67),
  feeVault: a(0x68),
};
const govCohort = { label: "cohort4 (live)", factory: a(0xf1), live: true };
const oldCohort = { label: "cohort2 (retired)", factory: a(0xf2), live: false };

function govReads(over = {}) {
  return {
    [`${govPad.factory}:hook:`]: govPad.hook,
    [`${govPad.factory}:graduationExecutor:`]: govPad.graduationExecutor,
    [`${govPad.factory}:locker:`]: govPad.locker,
    [`${govPad.factory}:escrow:`]: govPad.escrow,
    [`${govPad.factory}:holderFeeSharing:`]: govPad.holderFeeSharing,
    [`${govPad.factory}:router:`]: govPad.launchAndBuyRouter,
    [`${govPad.factory}:launchDeployer:`]: govPad.launchDeployer,
    [`${govPad.factory}:mondayExecutor:`]: govPad.mondayExecutor,
    [`${govPad.factory}:owner:`]: expected.owner,
    [`${govPad.factory}:pendingOwner:`]: ZERO,
    [`${govPad.factory}:protocolFeeRecipient:`]: expected.treasury,
    [`${govPad.factory}:launchCount:`]: 3n,
    [`${govPad.feeVault}:owner:`]: expected.owner,
    [`${govPad.feeVault}:pendingOwner:`]: ZERO,
    [`${govPad.feeVault}:lpFeeRecipient:`]: expected.feesRecipient,
    [`${govCohort.factory}:governance:`]: expected.momentsGovernance,
    [`${govCohort.factory}:pendingGovernance:`]: ZERO,
    [`${govCohort.factory}:pendingPolicyAt:`]: 0n,
    [`${govCohort.factory}:publishingPaused:`]: false,
    [`${govCohort.factory}:externalBaseURI:`]: expected.externalBaseURI,
    [`${oldCohort.factory}:governance:`]: expected.momentsGovernance,
    [`${oldCohort.factory}:pendingGovernance:`]: ZERO,
    [`${oldCohort.factory}:pendingPolicyAt:`]: 0n,
    [`${oldCohort.factory}:publishingPaused:`]: true,
    ...over,
  };
}

test("sec2 governance: everything as recorded -> silent", async () => {
  const h = harness();
  await governanceJob({ client: mockClient({ reads: govReads() }), launchpads: [govPad], cohorts: [govCohort, oldCohort], expected, ...h });
  assert.deepEqual(h.reporter.alerts, []);
});

test("sec2 governance: a swapped executor, a repointed fee, an unpaused retired cohort and a pending policy all alert", async () => {
  const reads = govReads({
    [`${govPad.factory}:graduationExecutor:`]: a(0xbeef),
    [`${govPad.feeVault}:lpFeeRecipient:`]: a(0xbad),
    [`${oldCohort.factory}:publishingPaused:`]: false,
    [`${govCohort.factory}:pendingPolicyAt:`]: NOW + DAY,
  });
  const h = harness();
  await governanceJob({ client: mockClient({ reads }), launchpads: [govPad], cohorts: [govCohort, oldCohort], expected, ...h });
  const reasons = h.reporter.alerts.map((x) => `${x.severity} ${x.reason}`).join("\n");
  assert.match(reasons, /critical module graduationExecutor\(\) is 0x0+beef/);
  assert.match(reasons, /critical lpFeeRecipient\(\) is 0x0+bad/);
  assert.match(reasons, /critical a retired cohort is publishing again/);
  assert.match(reasons, /warning a policy proposal is pending/);
});

// Owner decision 2026-09-28: the previous stacks are retired in the app only. They keep their owner key and cohort 3
// stays open on chain, so with the v2 records promoted (new owner: the Safe) the watch holds each retired stack to its
// own record, and cohort 3's open publishing is a note, not a page.
test("sec2 governance: a retired stack is held to its own record's owner, and cohort 3 open on chain is only reported", async () => {
  const oldKey = a(0x0d);
  const livePad = { ...govPad, live: true };
  const retiredPad = { ...govPad, label: "launchpad 0x6B1C (retired)", factory: a(0xfb), feeVault: a(0x69), owner: oldKey, live: false };
  const retiredCohort = { ...oldCohort, governance: oldKey };
  const openCohort = { label: "cohort3 (retired)", factory: a(0xf3), live: false, openOnChain: true, governance: oldKey };
  const retiredReads = (owner) =>
    Object.fromEntries(
      Object.entries(govReads())
        .filter(([k]) => k.startsWith(`${govPad.factory}:`) || k.startsWith(`${govPad.feeVault}:`))
        .map(([k, v]) => [k.replace(govPad.factory, retiredPad.factory).replace(govPad.feeVault, retiredPad.feeVault), k.endsWith(":owner:") ? owner : v]),
    );
  const reads = (owner) =>
    govReads({
      ...retiredReads(owner),
      [`${oldCohort.factory}:governance:`]: oldKey,
      [`${openCohort.factory}:governance:`]: oldKey,
      [`${openCohort.factory}:pendingGovernance:`]: ZERO,
      [`${openCohort.factory}:pendingPolicyAt:`]: 0n,
      [`${openCohort.factory}:publishingPaused:`]: false,
    });
  const run = async (owner) => {
    const h = harness();
    await governanceJob({ client: mockClient({ reads: reads(owner) }), launchpads: [livePad, retiredPad], cohorts: [govCohort, retiredCohort, openCohort], expected, ...h });
    return h.reporter.alerts;
  };
  const asRecorded = await run(oldKey);
  assert.deepEqual(asRecorded.filter((x) => x.severity !== "info"), [], "the old key on the retired stacks is what their records say");
  assert.equal(asRecorded.length, 1);
  assert.equal(asRecorded[0].target, "cohort3 (retired)");
  assert.match(asRecorded[0].reason, /publishing is open on chain: retired in the app only/);
  const moved = (await run(a(0xbad))).filter((x) => x.severity === "critical").map((x) => `${x.target}: ${x.reason}`);
  assert.deepEqual(moved, [
    `launchpad 0x6B1C (retired): owner() is ${a(0xbad)}, expected ${oldKey}`,
    `launchpad 0x6B1C (retired) fee vault: owner() is ${a(0xbad)}, expected ${oldKey}`,
  ]);
});

// A live factory with no launch and unsealed modules lets the owner key swap every module (2026-09-26 ops audit,
// medium; 0x6B1C while it was live). A v2 factory is sealed at deploy.
test("sec2 governance: an unfrozen factory warns once a day, not on every run", async () => {
  const client = mockClient({ reads: govReads({ [`${govPad.factory}:launchCount:`]: 0n }) });
  const h = harness();
  await governanceJob({ client, launchpads: [govPad], cohorts: [], expected, ...h });
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].severity, "warning");
  assert.match(h.reporter.alerts[0].reason, /modules not sealed/);
  const again = { ...harness(), state: h.state };
  await governanceJob({ client, launchpads: [govPad], cohorts: [], expected, ...again });
  assert.equal(again.reporter.alerts.length, 0, "throttled by the state file");
  const sealed = harness();
  await governanceJob({ client: mockClient({ reads: govReads({ [`${govPad.factory}:launchCount:`]: 0n, [`${govPad.factory}:modulesSealed:`]: true }) }), launchpads: [govPad], cohorts: [], expected, ...sealed });
  assert.equal(sealed.reporter.alerts.length, 0, "a v2 factory sealed at deploy is fine");
});

// With the v2 records promoted, 0x6B1C is a retired record: no launch, modules not sealed, and left open on chain by
// the owner decision (2026-09-28). The watch reports it and does not advise closing it; a live factory still warns.
test("sec2 governance: a retired launchpad left unfrozen on chain is reported, not alerted", async () => {
  const retiredPad = { ...govPad, label: "launchpad 0x6B1C (retired)", live: false };
  const h = harness();
  await governanceJob({ client: mockClient({ reads: govReads({ [`${govPad.factory}:launchCount:`]: 0n }) }), launchpads: [retiredPad], cohorts: [], expected, ...h });
  assert.deepEqual(h.reporter.alerts.filter((x) => x.severity !== "info"), []);
  assert.equal(h.reporter.alerts.length, 1);
  assert.equal(h.reporter.alerts[0].target, "launchpad 0x6B1C (retired)");
  assert.match(h.reporter.alerts[0].reason, /modules not sealed: retired in the app only/);
  assert.doesNotMatch(h.reporter.alerts[0].reason, /Close the factory/);
});

// A v2 cohort's record names its guardian: only the guardian can hand the role on (or renounce it) and lift its own
// pause, so a different guardian() is critical and its pause, which stops publishing, is a warning.
test("sec2 governance: a v2 cohort is held to its record's guardian, and the guardian's pause is reported", async () => {
  const guardian = a(0x9d);
  const v2Cohort = { ...govCohort, guardian };
  const reads = (over = {}) => govReads({ [`${govCohort.factory}:guardian:`]: guardian, [`${govCohort.factory}:guardianPaused:`]: false, ...over });
  const run = async (over) => {
    const h = harness();
    await governanceJob({ client: mockClient({ reads: reads(over) }), launchpads: [], cohorts: [v2Cohort], expected, ...h });
    return h.reporter.alerts.map((x) => `${x.severity} ${x.reason}`);
  };
  assert.deepEqual(await run(), []);
  assert.deepEqual(await run({ [`${govCohort.factory}:guardian:`]: a(0xbad) }), [
    `critical guardian() is ${a(0xbad)}, the record says ${guardian}: the guardian role was handed on or renounced`,
  ]);
  assert.deepEqual(await run({ [`${govCohort.factory}:guardian:`]: ZERO }), [
    `critical guardian() is ${ZERO}, the record says ${guardian}: the guardian role was handed on or renounced`,
  ]);
  assert.deepEqual(await run({ [`${govCohort.factory}:guardianPaused:`]: true }), ["warning the guardian paused publishing (guardianPaused): only the guardian can lift it"]);
  // A cohort whose record names no guardian (v1) is never asked: those getters revert there.
  const h = harness();
  await governanceJob({ client: mockClient({ reads: govReads() }), launchpads: [], cohorts: [govCohort], expected, ...h });
  assert.deepEqual(h.reporter.alerts, []);
});

test("sec2 governance: every governance event in the lookback is critical", async () => {
  const client = mockClient({
    reads: govReads(),
    head: 10_000n,
    getLogs: ({ address, events, fromBlock }) =>
      fromBlock === 9_901n && address.some((x) => x === govPad.factory) && events.some((e) => e.name === "ModulesSet")
        ? [{ address: govPad.factory, eventName: "ModulesSet", blockNumber: 9_950n, transactionHash: "0xabc" }]
        : [],
  });
  const h = harness();
  await governanceJob({ client, launchpads: [govPad], cohorts: [govCohort], expected, logsLookback: 99n, ...h });
  assert.equal(h.reporter.alerts.length, 1);
  assert.match(h.reporter.alerts[0].reason, /governance event ModulesSet in block 9950/);
});

// The watch claims every owner/governance action that could redirect money or swap code; the owner's creator-fee
// takeover (proposeCreatorFeeRecipient) was missing, and it is the one a creator must hear about within 3 days.
test("sec2 governance: the event scan watches every money, code and access lever on each contract kind", async () => {
  const watched = [];
  const client = mockClient({
    reads: govReads(),
    head: 10_000n,
    getLogs: ({ address, events }) => {
      watched.push({ address, names: new Set(events.map((e) => e.name)), topics: events.length });
      return [];
    },
  });
  const h = harness();
  await governanceJob({ client, launchpads: [govPad], cohorts: [govCohort, oldCohort], expected, logsLookback: 99n, ...h });
  const byAddr = (addr) => watched.find((w) => w.address.includes(addr));
  const pad = byAddr(govPad.factory).names;
  for (const n of ["CreatorFeeRecipientChangeProposed", "V4FallbackAllowed", "LaunchRescued", "LaunchConfigAdded", "MaxCreatorTaxSet", "WhitelistedSet", "ModulesSealed", "ModulesSet", "MondayExecutorSet", "FeePolicySet", "OwnershipTransferStarted", "PairMondayOnlySet"]) {
    assert.ok(pad.has(n), `launchpad scan misses ${n}`);
  }
  const vault = byAddr(govPad.feeVault).names;
  for (const n of ["LpFeeRecipientSet", "OwnershipTransferStarted"]) assert.ok(vault.has(n), `vault scan misses ${n}`);
  const moments = byAddr(govCohort.factory);
  for (const n of ["PolicyProposed", "PolicyApplied", "PolicyCancelled", "GuardianSet", "GuardianPaused", "GovernanceTransferStarted", "PublishingPaused", "ExternalBaseURISet"]) {
    assert.ok(moments.names.has(n), `Moments scan misses ${n}`);
  }
  assert.equal(moments.topics, moments.names.size + 2, "the pre-royalty v1 cohort's PolicyProposed and PolicyApplied topics too");
});

test("sec2 governance: a creator-fee takeover proposal names the token, the new recipient and the window", async () => {
  const token = a(0x7001);
  const client = mockClient({
    reads: govReads(),
    head: 10_000n,
    getLogs: ({ address, events }) =>
      address.includes(govPad.factory) && events.some((e) => e.name === "CreatorFeeRecipientChangeProposed")
        ? [{ address: govPad.factory, eventName: "CreatorFeeRecipientChangeProposed", blockNumber: 9_990n, transactionHash: "0xdef", args: { token, newRecipient: a(0xbad), effectiveAt: NOW + 3n * DAY, expiresAt: NOW + 6n * DAY } }]
        : [],
  });
  const h = harness();
  await governanceJob({ client, launchpads: [govPad], cohorts: [], expected, logsLookback: 99n, ...h });
  assert.equal(h.reporter.alerts.length, 1);
  const [x] = h.reporter.alerts;
  assert.equal(x.severity, "critical");
  assert.match(x.reason, new RegExp(`CreatorFeeRecipientChangeProposed.*${token}.*0x0+bad.*${NOW + 3n * DAY}.*${NOW + 6n * DAY}`));
  assert.match(x.reason, /warn the creator/);
});

// ---------------------------------------------------------------- sec2: deployment records

const DEPLOYMENTS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "deployments");

function withRecords(edit, fn) {
  const dir = mkdtempSync(join(tmpdir(), "keeper-deployments-"));
  try {
    cpSync(DEPLOYMENTS, dir, { recursive: true });
    edit(dir);
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Before: a missing live record was skipped silently, so the keeper dropped the live stacks and exited 0.
test("sec2: a missing or wrong-chain LIVE record stops the keeper instead of dropping the live stack", () => {
  withRecords((d) => rmSync(join(d, "143.json")), (d) => assert.throws(() => launchpads(d), /required deployment record 143\.json/));
  withRecords((d) => rmSync(join(d, "moments-143.json")), (d) => assert.throws(() => momentsCohorts(d), /required deployment record moments-143\.json/));
  withRecords(
    (d) => {
      const f = join(d, "143.json");
      writeFileSync(f, JSON.stringify({ ...JSON.parse(readFileSync(f, "utf8")), chainId: 31337 }));
    },
    (d) => assert.throws(() => launchpads(d), /chain 31337/),
  );
});

test("sec2: the records cover every launchpad with launches, and the live factories match the pin", () => {
  const pads = launchpads();
  assert.deepEqual(
    pads.map((p) => p.factory.slice(0, 6)),
    ["0x3B1f", "0x6B1C", "0x10F3", "0x2F02", "0xad3d"],
  );
  assert.equal(pads.find((p) => p.factory.startsWith("0xad3d")).legacyRecord, true);
  assert.deepEqual(pinMismatches({ cohorts: momentsCohorts(), pads }), []);
  assert.equal(pads[0].factory, LIVE_FACTORIES.launchpad);
  // Cohort 3 is the only cohort left open on chain once retired (owner decision 2026-09-28).
  assert.deepEqual(momentsCohorts().filter((c) => c.openOnChain).map((c) => c.factory), [...OPEN_ON_CHAIN_MOMENTS]);
  const moved = withRecords(
    (d) => {
      const f = join(d, "143.json");
      writeFileSync(f, JSON.stringify({ ...JSON.parse(readFileSync(f, "utf8")), factory: a(0xdead) }));
    },
    (d) => pinMismatches({ cohorts: momentsCohorts(d), pads: launchpads(d) }),
  );
  assert.equal(moved.length, 1);
  assert.equal(moved[0].file, "143.json");
});

// The v2 release (2026-09-28): launchpad v2 and Moments cohort 4 are the live records, owned by the Owner Safe; the
// stacks they replaced keep their own records, and cohort 3 is the only cohort left open on chain.
test("sec2: the v2 records are live, and the stacks they replaced are covered as retired ones", () => {
  const safe = "0x6D2A4D821e57b2B918B97CF575D81738bc16C100";
  const pads = launchpads();
  const live = pads.filter((p) => p.live);
  assert.equal(live.length, 1);
  assert.equal(live[0].factory, LIVE_FACTORIES.launchpad);
  assert.equal(live[0].owner, safe);
  assert.equal(live[0].deployBlock, 108_859_147);
  const relaunch = pads.find((p) => p.factory === "0x6B1C8769a8d6745955aC35b91FF1F37AB76859dB");
  assert.equal(relaunch.live, false);
  assert.equal(relaunch.file, "143-retired-0x6B1C.json");
  const cohorts = momentsCohorts();
  assert.deepEqual(
    cohorts.map((c) => [c.label, c.factory.slice(0, 6), c.live, c.openOnChain]),
    [
      ["cohort4 (live)", "0x95eb", true, false],
      ["cohort3 (retired)", "0x0FD4", false, true],
      ["cohort2 (retired)", "0xc12B", false, false],
      ["cohort1 (retired)", "0x6469", false, false],
      ["v1 (retired)", "0x47D9", false, false],
    ],
  );
  assert.equal(cohorts[0].factory, LIVE_FACTORIES.moments);
  assert.equal(cohorts[0].governance, safe);
  assert.equal(cohorts[0].guardian, "0x686C7A2886608082e698E0062EA3E4C408d43845");
  assert.equal(cohorts[0].deployBlock, 108_859_966);
  assert.equal(cohorts.filter((c) => c.guardian).length, 1, "only cohort 4 has a guardian");
  // A retired record may go missing (the keeper covers what is there); the live ones may not.
  withRecords((d) => rmSync(join(d, "143-retired-0x6B1C.json")), (d) => assert.equal(launchpads(d).length, pads.length - 1));
  withRecords((d) => rmSync(join(d, "moments-143-cohort3.json")), (d) => assert.equal(momentsCohorts(d).length, cohorts.length - 1));
});
