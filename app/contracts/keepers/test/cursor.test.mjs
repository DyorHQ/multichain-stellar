// Build 17, K2 / E2: log scans see every block. With --logs-cursor each scan starts right after the last block it
// fully scanned; the first run starts at --logs-from (governance: 108,860,011, after the 13 reviewed setup events of
// the v2 deploy); a run scans at most --logs-max-blocks and warns when it is behind; the cursor never passes a block
// that was not scanned. Chunks are inclusive spans of 1,000 blocks, which rpc3 accepts (it refuses 1,001).
import { test } from "node:test";
import assert from "node:assert/strict";
import { planScan, readCursor, writeCursor, DEFAULT_LOGS_CHUNK, DEFAULT_LOGS_MAX_BLOCKS, LOGS_HEAD_MARGIN } from "../lib/cursor.mjs";
import { governanceJob, momentsGraduationJob, getLogsChunked } from "../lib/jobs.mjs";
import { makeReporter } from "../lib/report.mjs";
import { makeSender } from "../lib/send.mjs";
import { parseKeeperArgs } from "../lib/options.mjs";

const a = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const ZERO = a(0);
const NOW = 1_790_000_000n;
const GOV_FROM = 108_860_011n;
const LAST_SETUP_EVENT = 108_860_010n; // GovernanceTransferStarted on Moments 0x95eb, the 13th reviewed setup event

// ---------------------------------------------------------------- planScan

test("E2 planScan: ad hoc runs keep --logs-lookback's meaning; no lookback and no cursor means no scan", () => {
  assert.deepEqual(planScan({ head: 10_000n, lookback: 99n }), { from: 9_901n, to: 10_000n, behind: 0n, first: true });
  assert.deepEqual(planScan({ head: 50n, lookback: 99n }), { from: 0n, to: 50n, behind: 0n, first: true });
  assert.equal(planScan({ head: 10_000n }), null);
});

test("E2 planScan: first cursor run starts at --logs-from, else head - lookback, else the head; later runs at cursor + 1", () => {
  assert.equal(planScan({ useCursor: true, head: 108_861_000n, from: GOV_FROM }).from, GOV_FROM);
  assert.equal(planScan({ useCursor: true, head: 5_000n, lookback: 1_000n }).from, 4_000n);
  assert.deepEqual(planScan({ useCursor: true, head: 5_000n }), { from: 5_000n, to: 5_000n, behind: 0n, first: true });
  assert.deepEqual(planScan({ useCursor: true, head: 5_000n, cursor: 4_200n, from: GOV_FROM }), { from: 4_201n, to: 5_000n, behind: 0n, first: false }, "--logs-from only applies to the first run");
});

test("E2 planScan: a run is capped at --logs-max-blocks and says how far behind it is; a cursor at or past the head scans nothing", () => {
  assert.deepEqual(planScan({ useCursor: true, head: 1_000_000n, cursor: 99n, maxBlocks: 200_000n }), { from: 100n, to: 200_099n, behind: 799_901n, first: false });
  assert.equal(planScan({ useCursor: true, head: 1_000n, cursor: 1_000n }).empty, true);
  assert.equal(planScan({ useCursor: true, head: 990n, cursor: 1_000n }).empty, true, "a fallback RPC a few blocks behind");
});

test("E2: cursors are stored as strings (JSON has no bigint) and read back as bigint", () => {
  const state = {};
  assert.equal(readCursor(state, "gov:moments"), undefined);
  writeCursor(state, "gov:moments", 108_862_500n);
  assert.deepEqual(state.cursors, { "gov:moments": "108862500" });
  assert.equal(readCursor(JSON.parse(JSON.stringify(state)), "gov:moments"), 108_862_500n);
});

test("E2 options: --logs-chunk defaults to 1000 and --logs-max-blocks to 200,000; --logs-from takes a block number", () => {
  const o = parseKeeperArgs(["governance"], {});
  assert.equal(o.logsChunk, DEFAULT_LOGS_CHUNK);
  assert.equal(o.logsChunk, 1000n);
  assert.equal(o.logsMaxBlocks, DEFAULT_LOGS_MAX_BLOCKS);
  assert.equal(o.logsCursor, false);
  assert.equal(o.logsFrom, undefined);
  const c = parseKeeperArgs(["governance", "--logs-cursor", "--logs-from", "108,860,011"], {});
  assert.equal(c.logsCursor, true);
  assert.equal(c.logsFrom, GOV_FROM);
  assert.throws(() => parseKeeperArgs(["governance", "--logs-chunk", "0"], {}), /--logs-chunk must be a whole number of at least 1/);
  assert.throws(() => parseKeeperArgs(["governance", "--logs-from=-5"], {}), /--logs-from must be a whole number/);
});

// ---------------------------------------------------------------- the rpc3 boundary

/** Like rpc3 on 2026-09-29: a span of more than 1,000 blocks (inclusive) is refused with -32062. */
function rpc3Like(onCall = () => []) {
  const calls = [];
  return {
    calls,
    async getLogs(req) {
      calls.push(req);
      if (req.toBlock - req.fromBlock + 1n > 1000n) throw Object.assign(new Error("RPC Request failed."), { code: -32062, details: "Block range is too large" });
      return onCall(req);
    },
  };
}

test("E2 boundary: a 1,000-block chunk is an inclusive span rpc3 accepts, so it never halves; 1,001 would be refused", async () => {
  const ok = rpc3Like();
  await getLogsChunked(ok, { address: a(1), from: 0n, to: 2_999n, chunk: 1000n });
  assert.deepEqual(ok.calls.map((c) => [c.fromBlock, c.toBlock]), [[0n, 999n], [1_000n, 1_999n], [2_000n, 2_999n]]);
  const over = rpc3Like();
  await getLogsChunked(over, { address: a(1), from: 0n, to: 2_999n, chunk: 1001n });
  assert.deepEqual([over.calls[0].fromBlock, over.calls[0].toBlock], [0n, 1_000n]);
  assert.equal(over.calls[1].toBlock - over.calls[1].fromBlock + 1n, 500n, "refused, then halved");
});

// ---------------------------------------------------------------- governance with a cursor

const cohort = { label: "cohort4 (live)", factory: a(0xf4), live: false, governance: a(0x6d) };
const expected = { owner: a(0x6d), treasury: a(0x7), feesRecipient: a(0x8), momentsGovernance: a(0x6d) };

function govChain({ head, getLogs }) {
  const reads = { governance: a(0x6d), pendingGovernance: ZERO, pendingPolicyAt: 0n, publishingPaused: true };
  const calls = [];
  return {
    calls,
    head,
    async getBlock() {
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return this.head;
    },
    async getLogs(req) {
      calls.push([req.fromBlock, req.toBlock]);
      if (req.toBlock - req.fromBlock + 1n > 1000n) throw Object.assign(new Error("RPC Request failed."), { details: "Block range is too large" });
      return getLogs ? getLogs(req) : [];
    },
    async readContract({ functionName }) {
      return reads[functionName];
    },
  };
}

async function gov(client, state, extra = {}) {
  const reporter = makeReporter({ log: () => {} });
  await governanceJob({ client, launchpads: [], cohorts: [cohort], reporter, state, expected, logsCursor: true, logsFrom: GOV_FROM, ...extra });
  return reporter.alerts;
}

test("E2 governance: the first run starts at 108,860,011, so the 13 reviewed setup events never page", async () => {
  const setup = (req) => (req.fromBlock <= LAST_SETUP_EVENT && LAST_SETUP_EVENT <= req.toBlock ? [{ address: cohort.factory, eventName: "GovernanceTransferStarted", blockNumber: LAST_SETUP_EVENT, transactionHash: "0x01", logIndex: 0 }] : []);
  const client = govChain({ head: 108_862_500n, getLogs: setup });
  const state = {};
  assert.deepEqual(await gov(client, state), []);
  assert.deepEqual(client.calls, [[108_860_011n, 108_861_010n], [108_861_011n, 108_862_010n], [108_862_011n, 108_862_490n]], "up to 10 blocks short of the head");
  assert.equal(readCursor(state, "gov:moments"), 108_862_490n);
  // The same scan started one block earlier would have raised it: the start block is what keeps it quiet.
  const early = await gov(govChain({ head: 108_862_500n, getLogs: setup }), {}, { logsFrom: LAST_SETUP_EVENT });
  assert.equal(early.length, 1);
  assert.match(early[0].reason, /GovernanceTransferStarted in block 108860010/);
});

test("E2 governance: the next run starts right after the cursor, however late it runs, and raises what it finds", async () => {
  const state = { cursors: { "gov:moments": "108862500" } };
  const client = govChain({
    head: 108_875_000n, // ~63 minutes later: more than a 10,000-block lookback would have covered
    getLogs: (req) => (req.fromBlock <= 108_870_000n && 108_870_000n <= req.toBlock ? [{ address: cohort.factory, eventName: "PolicyProposed", blockNumber: 108_870_000n, transactionHash: "0x02", logIndex: 3 }] : []),
  });
  const alerts = await gov(client, state);
  assert.equal(client.calls[0][0], 108_862_501n, "no gap, no overlap");
  assert.equal(client.calls.at(-1)[1], 108_874_990n);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "critical");
  assert.match(alerts[0].reason, /PolicyProposed in block 108870000/);
  assert.equal(readCursor(state, "gov:moments"), 108_874_990n);
});

test("E2 governance: a failed read keeps the cursor at the last fully scanned chunk; the next run resumes there", async () => {
  const state = { cursors: { "gov:moments": "9999" } };
  let fail = true;
  const client = govChain({
    head: 13_000n,
    getLogs: (req) => {
      if (fail && req.fromBlock === 11_000n) throw new Error("internal error");
      return [];
    },
  });
  const alerts = await gov(client, state);
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].reason, /could not be checked/);
  assert.equal(readCursor(state, "gov:moments"), 10_999n, "10,000-10,999 was scanned; 11,000 was not");
  fail = false;
  client.calls.length = 0;
  assert.deepEqual(await gov(client, state), []);
  assert.equal(client.calls[0][0], 11_000n);
  assert.equal(readCursor(state, "gov:moments"), 12_990n);
});

test("E2 governance: a run capped by --logs-max-blocks warns that the scan is behind, then catches up", async () => {
  const state = { cursors: { "gov:moments": "0" } };
  const client = govChain({ head: 3_000n });
  const first = await gov(client, state, { logsMaxBlocks: 1_500n });
  assert.equal(first.length, 1);
  assert.equal(first[0].severity, "warning");
  assert.equal(first[0].key, "logs:behind:gov:moments");
  assert.match(first[0].reason, /1490 blocks behind \(scanned through block 1500 of 2990, the head 3000 less a 10-block margin; at most --logs-max-blocks 1500 per run\)/);
  assert.equal(readCursor(state, "gov:moments"), 1_500n);
  assert.deepEqual(await gov(client, state, { logsMaxBlocks: 1_500n }), [], "caught up");
  assert.equal(readCursor(state, "gov:moments"), 2_990n);
});

test("E2 governance: a scan stops starting chunks at its share of --max-runtime and keeps what it finished", async () => {
  let clock = 0;
  const state = { cursors: { "gov:moments": "0" } };
  const client = govChain({ head: 5_000n, getLogs: () => ((clock += 40_000), []) }); // each chunk takes 40 s
  const alerts = await gov(client, state, { logsUntil: 100_000, logsNow: () => clock });
  assert.equal(client.calls.length, 3, "started at 0 s, 40 s and 80 s; not at 120 s");
  assert.equal(readCursor(state, "gov:moments"), 3_000n);
  assert.equal(alerts.length, 1);
  assert.match(alerts[0].reason, /1990 blocks behind .* it used its share of --max-runtime/);
});

test("E2 governance: scans share the time left, so one long catch-up never starves the other contract kinds", async () => {
  let clock = 0;
  const state = {};
  const pad = { label: "launchpad (live)", factory: a(0xfa), feeVault: a(0xfe), live: false, owner: a(0x6d) };
  const reads = { governance: a(0x6d), pendingGovernance: ZERO, pendingPolicyAt: 0n, publishingPaused: true, owner: a(0x6d), pendingOwner: ZERO, protocolFeeRecipient: a(0x7), launchCount: 1n, lpFeeRecipient: a(0x8), modulesSealed: true };
  const client = {
    calls: [],
    async getBlock() {
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return 100_000n;
    },
    async getLogs(req) {
      this.calls.push(req.address.includes(pad.factory) ? "launchpads" : req.address.includes(pad.feeVault) ? "fee vaults" : "moments");
      clock += 10_000; // 10 s a chunk
      return [];
    },
    async readContract({ functionName }) {
      if (functionName in reads) return reads[functionName];
      if (["hook", "graduationExecutor", "locker", "escrow", "holderFeeSharing", "launchAndBuyRouter", "router", "launchDeployer", "mondayExecutor"].includes(functionName)) return ZERO;
      throw new Error("execution reverted");
    },
  };
  const reporter = makeReporter({ log: () => {} });
  await governanceJob({ client, launchpads: [pad], cohorts: [cohort], reporter, state, expected, logsCursor: true, logsFrom: 1n, logsUntil: 120_000, logsNow: () => clock });
  const count = (k) => client.calls.filter((c) => c === k).length;
  assert.deepEqual([count("launchpads"), count("fee vaults"), count("moments")], [4, 4, 4], "40 s each of the 120 s");
  assert.deepEqual(Object.keys(state.cursors).sort(), ["gov:fee-vaults", "gov:launchpads", "gov:moments"]);
  assert.equal(reporter.alerts.filter((x) => /blocks behind/.test(x.reason)).length, 3);
});

// Measured 2026-10-01: rpc3 and rpc4 answer an eth_getLogs range that reaches past their own head with the logs up to
// that head and no error, and the head read can come from a backend a few blocks ahead of the one that answers.
test("E2: a cursor scan stops 10 blocks short of the head it read, so a backend a few blocks behind loses no event", async () => {
  assert.equal(LOGS_HEAD_MARGIN, 10n);
  const state = { cursors: { "gov:moments": "4000" } };
  const event = { address: cohort.factory, eventName: "PolicyProposed", blockNumber: 4_998n, transactionHash: "0x04", logIndex: 0 };
  // getBlockNumber reaches a backend at 5,000; getLogs one at 4,996, which answers for blocks up to its own head only.
  let backendHead = 4_996n;
  const client = govChain({ head: 5_000n, getLogs: (req) => (req.fromBlock <= event.blockNumber && event.blockNumber <= req.toBlock && event.blockNumber <= backendHead ? [event] : []) });
  assert.deepEqual(await gov(client, state), []);
  assert.equal(readCursor(state, "gov:moments"), 4_990n, "not 5,000: blocks 4,991-5,000 are left for the next run");
  backendHead = 5_100n;
  client.head = 5_100n;
  const next = await gov(client, state);
  assert.equal(next.length, 1, "the event in block 4,998 is found by the next run");
  assert.match(next[0].reason, /PolicyProposed in block 4998/);
});

test("E2: a cursor ahead of the head (a lagging fallback RPC) scans nothing and is left alone", async () => {
  const state = { cursors: { "gov:moments": "5000" } };
  const client = govChain({ head: 4_990n });
  assert.deepEqual(await gov(client, state), []);
  assert.deepEqual(client.calls, []);
  assert.equal(readCursor(state, "gov:moments"), 5_000n);
});

test("E2: an RPC whose head is minutes below the cursor (stuck, or another chain) is a warning; nothing is scanned", async () => {
  const state = { cursors: { "gov:moments": "5000" } };
  const client = govChain({ head: 4_000n });
  const alerts = await gov(client, state);
  assert.deepEqual(client.calls, []);
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "warning");
  assert.equal(alerts[0].key, "logs:headbehind:gov:moments");
  assert.match(alerts[0].reason, /the RPC's head 4000 is 1000 blocks below this scan's cursor 5000/);
  assert.equal(readCursor(state, "gov:moments"), 5_000n, "left alone");
});

test("E2 MO-1: each cohort's GraduationFailed scan keeps its own cursor", async () => {
  const c1 = { label: "cohort4 (live)", factory: a(0xf1), collect: a(0xc1), graduation: a(0x91) };
  const c3 = { label: "cohort3 (retired)", factory: a(0xf3), collect: a(0xc3), graduation: a(0x93) };
  const client = {
    head: 20_500n,
    calls: [],
    async getBlock() {
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return this.head;
    },
    async readContract({ functionName }) {
      if (functionName === "momentCount") return 0n;
      throw new Error(`unmocked ${functionName}`);
    },
    async getLogs(req) {
      this.calls.push([req.address, req.fromBlock, req.toBlock]);
      return req.address === c3.collect && req.fromBlock <= 20_100n && 20_100n <= req.toBlock ? [{ args: { momentId: 1n }, blockNumber: 20_100n, transactionHash: "0x03", logIndex: 0 }] : [];
    },
  };
  const state = { cursors: { [`mo1:GraduationFailed:${c1.collect}`]: "20000" } };
  const reporter = makeReporter({ log: () => {} });
  await momentsGraduationJob({ client, cohorts: [c1, c3], sender: makeSender({ rpcUrl: "http://x", log: () => {} }), reporter, state, logsCursor: true });
  assert.deepEqual(client.calls, [[c1.collect, 20_001n, 20_490n], [c3.collect, 20_490n, 20_490n]], "cohort 3 had no cursor and no --logs-from: it starts at the head (less the margin)");
  assert.deepEqual(state.cursors, { [`mo1:GraduationFailed:${c1.collect}`]: "20490", [`mo1:GraduationFailed:${c3.collect}`]: "20490" });
  assert.deepEqual(reporter.alerts, []);
});
