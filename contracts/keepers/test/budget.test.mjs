// Build 17, K3 / E8: the spend guard. A price re-squatted between simulation and inclusion could make the keeper pay
// ~3 MON every 5 minutes, bounded only by its balance. After a failed send its target is backed off (30 min doubling to
// 6 h); --max-spend-per-day caps the rolling 24-hour spend (worst case: gas limit x gas price): above it the keeper
// holds its sends, keeps simulating and alerts critical.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseEther } from "viem";
import { backoffFor, noteSendFailure, noteSendSuccess, recordSpend, spendAllowed, spentSince, BACKOFF_START_S, BACKOFF_MAX_S } from "../lib/budget.mjs";
import { makeSender } from "../lib/send.mjs";
import { makeReporter } from "../lib/report.mjs";
import { launchpadGraduationJob, momentsGraduationJob, MONDAY_GAS } from "../lib/jobs.mjs";
import { parseKeeperArgs } from "../lib/options.mjs";

const T0 = 1_790_000_000;
const HASH = `0x${"ab".repeat(32)}`;
const GWEI102 = 102_000_000_000n;
const receipt = (status) => JSON.stringify({ status, transactionHash: HASH, gasUsed: "0x5208", effectiveGasPrice: `0x${GWEI102.toString(16)}` });

test("E8: backoff after a failed send: 30 min, 1 h, 2 h, 4 h, then 6 h at most; a success clears it", () => {
  assert.equal(BACKOFF_START_S, 1_800);
  assert.equal(BACKOFF_MAX_S, 21_600);
  const state = {};
  const waits = [];
  for (let i = 0; i < 6; i++) waits.push(noteSendFailure(state, "lp1:x", T0).until - T0);
  assert.deepEqual(waits, [1_800, 3_600, 7_200, 14_400, 21_600, 21_600]);
  assert.ok(backoffFor(state, "lp1:x", T0 + 100));
  assert.equal(backoffFor(state, "lp1:x", T0 + 21_600), undefined, "over once its time has passed");
  assert.equal(backoffFor(state, "other", T0), undefined, "per target");
  noteSendSuccess(state, "lp1:x");
  assert.deepEqual(state.budget.backoff, {});
});

test("E8: the cap is a rolling 24 hours of recorded spend, the worst case of the next send included", () => {
  const state = {};
  recordSpend(state, { at: T0 - 90_000, wei: parseEther("10"), job: "j", target: "old" }); // 25 h ago
  recordSpend(state, { at: T0 - 3_600, wei: parseEther("17"), job: "j", target: "a" });
  assert.equal(spentSince(state, T0 - 86_400), parseEther("17"));
  const cap = parseEther("20");
  assert.deepEqual(spendAllowed(state, { at: T0, costWei: parseEther("2"), capWei: cap }), { ok: true, spent: parseEther("17") });
  assert.equal(spendAllowed(state, { at: T0, costWei: MONDAY_GAS * GWEI102, capWei: cap }).ok, false, "a 3.05 MON Monday send does not fit");
  assert.equal(spendAllowed(state, { at: T0, costWei: MONDAY_GAS * GWEI102 }).ok, true, "no cap: always");
});

test("E8 options: --max-spend-per-day takes MON", () => {
  assert.equal(parseKeeperArgs(["all", "--max-spend-per-day", "20"], {}).maxSpendPerDay, parseEther("20"));
  assert.equal(parseKeeperArgs(["all"], {}).maxSpendPerDay, undefined);
  assert.throws(() => parseKeeperArgs(["all", "--max-spend-per-day", "lots"], {}), /positive amount of MON/);
  assert.throws(() => parseKeeperArgs(["all", "--max-spend-per-day", "0"], {}), /positive amount of MON/);
});

// A completed Monday launch whose Monday graduation simulates OK: the keeper sends graduate(token) at 29.9M gas.
const a = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const pad = { label: "launchpad (live)", factory: a(0xfa), live: true };
const token = a(0x7001);
function stuckLaunchChain(sims) {
  const reads = {
    mondayExecutor: "0x0000000000000000000000000000000000000000",
    launchCount: 1n,
    getLaunches: [token],
    getLaunchedToken: { phase: 0, graduationVenue: 1, curve: a(0xc0), pairToken: a(0), graduationThreshold: 1n },
    completed: true,
    rescued: false,
    stuckSince: BigInt(T0 - 600),
    launchMondayOnly: false,
  };
  return {
    getBlock: async () => ({ timestamp: BigInt(T0) }),
    getGasPrice: async () => GWEI102,
    readContract: async ({ functionName }) => {
      if (functionName in reads) return reads[functionName];
      throw new Error("execution reverted");
    },
    simulateContract: async ({ functionName }) => (sims.push(functionName), { result: null }),
  };
}

function live(spawnResults) {
  const spawned = [];
  const sender = makeSender({ send: true, rpcUrl: "http://127.0.0.1:1", signer: { account: "k" }, log: () => {}, spawn: (bin, argv) => (spawned.push(argv), spawnResults.shift() ?? { status: 0, stdout: receipt("0x1") }) });
  return { sender, spawned };
}

async function runLp1({ state, sender, at, capWei, sims = [] }) {
  const reporter = makeReporter({ log: () => {} });
  const lines = [];
  reporter.info = (m) => lines.push(m);
  await launchpadGraduationJob({ client: stuckLaunchChain(sims), launchpads: [pad], sender, reporter, state, budget: { capWei, clock: () => at } });
  return { alerts: reporter.alerts, lines, sims };
}

test("E8: a reverted send backs its target off; the next runs do not pay again until the backoff ends", async () => {
  const state = {};
  const { sender, spawned } = live([{ status: 0, stdout: receipt("0x0") }]);
  const first = await runLp1({ state, sender, at: T0 });
  assert.equal(spawned.length, 1);
  assert.match(first.alerts.find((x) => /REVERTED/.test(x.reason)).reason, /; not retried before 2026-09-21T14:43:20\.000Z$/);
  const again = await runLp1({ state, sender, at: T0 + 300 }); // the next 5-minute run
  assert.equal(spawned.length, 1, "not sent again");
  assert.ok(again.lines.some((l) => /not sending graduate .*1 failed send\(s\), backing off until/.test(l)));
  assert.ok(again.sims.length > 0, "it still simulates");
  assert.ok(again.alerts.some((x) => x.key === `lp1:stuck:${pad.factory}:${token}`), "and the stuck launch still alerts");
  await runLp1({ state, sender, at: T0 + 1_800 });
  assert.equal(spawned.length, 2, "sent again after 30 minutes (and this time it succeeds)");
  assert.equal(state.budget.backoff[`launchpad-graduation:${pad.label} ${token}`], undefined, "a success clears the backoff");
});

test("E8: over --max-spend-per-day the keeper holds the send, keeps simulating and alerts critical; old spend frees the cap", async () => {
  const state = {};
  recordSpend(state, { at: T0 - 3_600, wei: parseEther("18"), job: "launchpad-graduation", target: "earlier" });
  const { sender, spawned } = live([]);
  const capWei = parseEther("20");
  const held = await runLp1({ state, sender, at: T0, capWei });
  assert.equal(spawned.length, 0, "cast never ran");
  assert.ok(held.sims.includes("graduate"), "simulated");
  const cap = held.alerts.find((x) => x.key === "budget:cap");
  assert.equal(cap.severity, "critical");
  assert.match(cap.reason, /--max-spend-per-day 20 MON reached: 18 MON spent in the last 24 h, and graduate .* could cost up to 3\.0498 MON/);
  const later = await runLp1({ state, sender, at: T0 - 3_600 + 86_401, capWei }); // the 18 MON left the window
  assert.equal(spawned.length, 1);
  assert.equal(later.alerts.find((x) => x.key === "budget:cap"), undefined);
});

test("E8: a send whose gas price cannot be read is held, never counted as free (18 of 20 MON spent: no 3 MON send)", async () => {
  const cases = {
    "rate limited": async () => {
      throw Object.assign(new Error("HTTP request failed. Status: 429"), { name: "HttpRequestError", status: 429 });
    },
    zero: async () => 0n,
  };
  for (const [what, getGasPrice] of Object.entries(cases)) {
    const state = {};
    recordSpend(state, { at: T0 - 3_600, wei: parseEther("18"), job: "launchpad-graduation", target: "earlier" });
    const { sender, spawned } = live([]);
    const reporter = makeReporter({ log: () => {} });
    await launchpadGraduationJob({ client: { ...stuckLaunchChain([]), getGasPrice }, launchpads: [pad], sender, reporter, state, budget: { capWei: parseEther("20"), clock: () => T0 } });
    assert.equal(spawned.length, 0, `${what}: cast never ran`);
    const held = reporter.alerts.find((x) => x.key.startsWith("send:gasprice:"));
    assert.ok(held, what);
    assert.match(held.reason, /send held: the gas price could not be read/);
    assert.equal(held.rpc === true, what === "rate limited", `${what}: an RPC failure joins the one "RPC degraded" alert`);
    assert.ok(reporter.incomplete.has("launchpad-graduation"), "nothing of the job resolves");
    assert.equal(spentSince(state, 0), parseEther("18"), "nothing recorded");
  }
});

test("E8: a dry run is never held back by the cap or a backoff", async () => {
  const state = {};
  recordSpend(state, { at: T0, wei: parseEther("100"), job: "j", target: "t" });
  noteSendFailure(state, "moments-graduation:cohort4 (live) moment #1", T0);
  const sender = makeSender({ rpcUrl: "http://x", log: () => {} });
  const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: BigInt(T0) }, getMoment: { deadline: BigInt(T0 + 864_000) } };
  const client = { getBlock: async () => ({ timestamp: BigInt(T0) }), readContract: async ({ functionName }) => reads[functionName], simulateContract: async () => ({ result: null }) };
  await momentsGraduationJob({ client, cohorts: [{ label: "cohort4 (live)", factory: a(1), collect: a(2), graduation: a(3) }], sender, reporter: makeReporter({ log: () => {} }), state, budget: { capWei: 1n, clock: () => T0 } });
  assert.equal(sender.sent.length, 1, "printed as before");
});
