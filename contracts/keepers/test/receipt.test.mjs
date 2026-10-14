// Build 17, K1 / E1: a send is a success only when its receipt says so. `cast send` exits 0 for a transaction that was
// mined but reverted (reproduced on anvil with Foundry 1.7.1: exit 0, "status":"0x0"), and Monad bills the whole gas
// limit, so one reverted Monday graduation burns ~3 MON. Every outcome other than status 0x1 must be a critical alert,
// and what it cost must reach the spend ledger.
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCastReceipt, castSendArgv, makeSender, spentWei, MinedRevert, SendStatusUnknown, SendNotStarted, CAST_KILL_AFTER_MS } from "../lib/send.mjs";
import { makeReporter } from "../lib/report.mjs";
import { momentsGraduationJob } from "../lib/jobs.mjs";
import { spentSince } from "../lib/budget.mjs";

const TO = "0x0000000000000000000000000000000000000abc";
const HASH = `0x${"ab".repeat(32)}`;
const receiptJson = (status, { gasUsed = "0x5406", price = "0x3b9aca01" } = {}) =>
  `${JSON.stringify({ type: "0x2", status, transactionHash: HASH, gasUsed, effectiveGasPrice: price, blockNumber: "0x1", logs: [] })}\n`;

test("E1: cast's --json receipt is parsed: status, hash, gas used, effective gas price", () => {
  const ok = parseCastReceipt(receiptJson("0x1"));
  assert.deepEqual(ok, { status: 1, transactionHash: HASH, gasUsed: 0x5406n, effectiveGasPrice: 0x3b9aca01n });
  assert.equal(parseCastReceipt(receiptJson("0x0")).status, 0);
  assert.equal(parseCastReceipt(`Warning: something\n${receiptJson("0x1")}`).status, 1, "a stray line before the receipt is ignored");
});

test("E1: anything but a complete receipt is an error, never a success", () => {
  for (const bad of ["", "ok", "{", "[]", "{}", JSON.stringify({ status: "0x1" }), JSON.stringify({ status: "0x2", transactionHash: HASH, gasUsed: "0x1", effectiveGasPrice: "0x1" }), JSON.stringify({ status: "0x1", transactionHash: "0x12", gasUsed: "0x1", effectiveGasPrice: "0x1" }), JSON.stringify({ status: "0x1", transactionHash: HASH, gasUsed: "lots", effectiveGasPrice: "0x1" })]) {
    assert.throws(() => parseCastReceipt(bad), undefined, bad);
  }
});

test("E1: Monad bills the gas limit, so a send's cost is limit x price (the use only when no limit was set)", () => {
  assert.equal(spentWei({ gasLimit: 29_900_000n, gasUsed: 21_000n, effectiveGasPrice: 102_000_000_000n }), 29_900_000n * 102_000_000_000n);
  assert.equal(spentWei({ gasLimit: undefined, gasUsed: 21_000n, effectiveGasPrice: 2n }), 42_000n);
});

test("E1: sends ask cast for a JSON receipt and a receipt timeout; the signer stays last", () => {
  const argv = castSendArgv({ to: TO, signature: "graduate(uint256)", args: [7n], gasLimit: 5_000_000n, signer: { account: "keeper" }, receipt: true });
  assert.deepEqual(argv, ["send", TO, "graduate(uint256)", "7", "--gas-limit", "5000000", "--json", "--timeout", "120", "--account", "keeper"]);
});

function liveSender(result, calls = []) {
  return makeSender({ send: true, rpcUrl: "http://127.0.0.1:8545", signer: { account: "keeper" }, log: () => {}, spawn: (bin, argv, opts) => (calls.push({ argv, opts }), result) });
}

test("E1: cast runs with a kill timer (SIGKILL) so a hung send cannot block every later run", async () => {
  const calls = [];
  await liveSender({ status: 0, stdout: receiptJson("0x1") }, calls).call({ to: TO, signature: "graduate(uint256)", args: [1n], gasLimit: 100_000n });
  assert.equal(calls[0].opts.timeout, CAST_KILL_AFTER_MS);
  assert.equal(CAST_KILL_AFTER_MS, 180_000);
  assert.equal(calls[0].opts.killSignal, "SIGKILL");
  assert.ok(calls[0].argv.includes("--json"));
});

test("E1: a send never outlasts the run's deadline: cast's receipt wait and kill timer shrink to the time left", async () => {
  const calls = [];
  const tx = { to: TO, signature: "graduate(uint256)", args: [1n], gasLimit: 100_000n };
  await liveSender({ status: 0, stdout: receiptJson("0x1") }, calls).call({ ...tx, timeLeftMs: 600_000 });
  assert.equal(calls[0].opts.timeout, CAST_KILL_AFTER_MS, "plenty of time: the usual 180 s");
  assert.equal(calls[0].argv[calls[0].argv.indexOf("--timeout") + 1], "120");
  await liveSender({ status: 0, stdout: receiptJson("0x1") }, calls).call({ ...tx, timeLeftMs: 100_000 });
  assert.equal(calls[1].opts.timeout, 100_000, "killed by the deadline at the latest");
  assert.equal(calls[1].argv[calls[1].argv.indexOf("--timeout") + 1], "40", "and cast stops waiting 60 s before that");
  // 74 s left: not enough for cast's 60 s and a 15 s receipt wait. Not started: nothing broadcast, nothing to count.
  await assert.rejects(liveSender({ status: 0, stdout: receiptJson("0x1") }, calls).call({ ...tx, timeLeftMs: 74_000 }), (e) => e instanceof SendNotStarted && /only 74s left before --max-runtime/.test(e.message));
  assert.equal(calls.length, 2, "cast never ran");
});

test("E1 via safeSend: a send not started for lack of time is not a failed send (no alert, no backoff, no spend)", async () => {
  const reporter = makeReporter({ log: () => {} });
  const lines = [];
  reporter.info = (m) => lines.push(m);
  const state = {};
  const inner = liveSender({ status: 0, stdout: receiptJson("0x1") });
  const sender = { ...inner, call: (tx) => inner.call({ ...tx, timeLeftMs: 30_000 }) };
  await momentsGraduationJob({ client: pendingMomentClient(), cohorts: [cohort], sender, reporter, state });
  assert.deepEqual(reporter.alerts.filter((x) => /send failed/.test(x.reason)), []);
  assert.ok(lines.some((l) => /not sending graduate .*only 30s left before --max-runtime/.test(l)), lines.join("\n"));
  assert.equal(state.budget?.backoff?.[`moments-graduation:${cohort.label} moment #1`], undefined);
  assert.equal(spentSince(state, 0), 0n);
});

test("E1: status 0x1 resolves with the receipt and its cost; 0x0 throws MinedRevert with the hash and the cost", async () => {
  const ok = await liveSender({ status: 0, stdout: receiptJson("0x1") }).call({ to: TO, signature: "graduate(uint256)", args: [1n], gasLimit: 100_000n });
  assert.equal(ok.receipt.status, 1);
  assert.equal(ok.spentWei, 100_000n * 0x3b9aca01n);
  await assert.rejects(liveSender({ status: 0, stdout: receiptJson("0x0") }).call({ to: TO, signature: "graduate(uint256)", args: [1n], gasLimit: 29_900_000n }), (e) => {
    assert.ok(e instanceof MinedRevert);
    assert.equal(e.txHash, HASH);
    assert.equal(e.spentWei, 29_900_000n * 0x3b9aca01n);
    return true;
  });
});

test("E1: a killed cast, or a non-zero exit that names a transaction or a timeout, is an unknown outcome", async () => {
  await assert.rejects(liveSender({ status: null, signal: "SIGKILL", error: Object.assign(new Error("spawnSync cast ETIMEDOUT"), { code: "ETIMEDOUT" }) }).call({ to: TO, signature: "g()", gasLimit: 1n }), SendStatusUnknown);
  await assert.rejects(liveSender({ status: 1, stderr: `Error: transaction ${HASH} was not confirmed within the timeout` }).call({ to: TO, signature: "g()", gasLimit: 1n }), SendStatusUnknown);
  await assert.rejects(liveSender({ status: 1, stderr: "Error: insufficient funds for gas * price + value" }).call({ to: TO, signature: "g()", gasLimit: 1n }), (e) => !(e instanceof SendStatusUnknown) && /insufficient funds/.test(e.message));
});

test("E1: a non-zero exit is an unknown outcome unless cast says it stopped before broadcasting", async () => {
  const call = (stderr) => liveSender({ status: 1, stderr }).call({ to: TO, signature: "g()", gasLimit: 1n }).then(() => "ok", (e) => (e instanceof SendStatusUnknown ? "unknown" : "failed"));
  // What cast 1.7.1 prints when the RPC goes away while it waits for the receipt: no hash, no "timeout".
  assert.equal(await call("Error: error sending request for url (http://127.0.0.1:8545/)\n"), "unknown");
  assert.equal(await call(""), "unknown", "no output at all");
  assert.equal(await call("Error: server returned an error response: error code -32603: internal error"), "unknown");
  for (const pre of [
    "Error: server returned an error response: error code -32003: Insufficient funds for gas * price + value",
    "Error: server returned an error response: error code -32000: nonce too low",
    "Error: Failed to decrypt keystore: Mac Mismatch",
    "Error: No such file or directory (os error 2)",
    "error: unexpected argument '--bogus' found",
  ]) {
    assert.equal(await call(pre), "failed", pre);
  }
});

test("E1 via safeSend: a send whose RPC went away after it may have broadcast is counted at its worst case", async () => {
  const { alerts, state } = await sendThroughJob({ status: 1, stderr: "Error: error sending request for url (http://127.0.0.1:8545/)\n" });
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "critical");
  assert.match(alerts[0].reason, /outcome UNKNOWN .*error sending request for url .*counted as up to 0\.51 MON spent/);
  assert.equal(spentSince(state, 0), 5_000_000n * 102_000_000_000n);
  assert.equal(state.budget.spend[0].estimated, true);
});

test("E1: exit 0 with an unreadable receipt resolves with receipt null (the job treats it as unknown)", async () => {
  const r = await liveSender({ status: 0, stdout: "ok" }).call({ to: TO, signature: "g()", gasLimit: 1n });
  assert.equal(r.receipt, null);
  assert.match(r.receiptError, /no JSON receipt/);
});

// Through a real job: the MO-1 retry of a pending Moment, sent by a live sender whose cast is mocked.
const a = (n) => `0x${n.toString(16).padStart(40, "0")}`;
const NOW = 1_790_000_000n;
const cohort = { label: "cohort4 (live)", factory: a(0xf1), collect: a(0xc1), graduation: a(0x91) };
function pendingMomentClient({ gasPrice = 102_000_000_000n } = {}) {
  const reads = {
    momentCount: 1n,
    state: 1,
    ledger: { state: 1, completedAt: NOW, stuckSince: NOW, endedAt: 0n, reserve: 1n },
    getMoment: { deadline: NOW + 20n * 86_400n, creator: a(1), platform: a(2), treasury: a(3), coin: a(4), nft: a(5) },
  };
  return {
    async getBlock() {
      return { timestamp: NOW };
    },
    async getGasPrice() {
      return gasPrice;
    },
    async readContract({ functionName }) {
      return reads[functionName];
    },
    async simulateContract() {
      return { result: null };
    },
  };
}

async function sendThroughJob(spawnResult) {
  const reporter = makeReporter({ log: () => {} });
  const state = {};
  const sender = liveSender(spawnResult);
  await momentsGraduationJob({ client: pendingMomentClient(), cohorts: [cohort], sender, reporter, state });
  return { alerts: reporter.alerts.filter((x) => /send failed/.test(x.reason)), state };
}

test("E1 via safeSend: a mined revert is a critical alert with the tx hash and the MON spent, and the spend is recorded", async () => {
  const { alerts, state } = await sendThroughJob({ status: 0, stdout: receiptJson("0x0", { price: "0x17bfac7c00" }) });
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "critical");
  assert.match(alerts[0].reason, new RegExp(`REVERTED \\(tx ${HASH}\\); it cost 0\\.51 MON`), "5M gas at 102 gwei");
  assert.equal(spentSince(state, 0), 5_000_000n * 102_000_000_000n);
  assert.equal(state.budget.spend[0].tx, HASH);
});

test("E1 via safeSend: a timeout is critical and counted at its worst case (gas limit x gas price)", async () => {
  const { alerts, state } = await sendThroughJob({ status: null, signal: "SIGKILL", error: Object.assign(new Error("t"), { code: "ETIMEDOUT" }) });
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "critical");
  assert.match(alerts[0].reason, /outcome UNKNOWN .* killed after 180s/);
  assert.equal(spentSince(state, 0), 5_000_000n * 102_000_000_000n);
  assert.equal(state.budget.spend[0].estimated, true);
});

test("E1 via safeSend: an unreadable receipt is critical, never a silent success", async () => {
  const { alerts, state } = await sendThroughJob({ status: 0, stdout: "garbage" });
  assert.equal(alerts.length, 1);
  assert.equal(alerts[0].severity, "critical");
  assert.match(alerts[0].reason, /outcome UNKNOWN .* no readable receipt/);
  assert.equal(state.budget.spend.length, 1);
});

test("E1 via safeSend: a successful receipt raises nothing and records its cost; a dry run records nothing", async () => {
  const { alerts, state } = await sendThroughJob({ status: 0, stdout: receiptJson("0x1", { price: "0x17bfac7c00" }) });
  assert.deepEqual(alerts, []);
  assert.equal(spentSince(state, 0), 5_000_000n * 102_000_000_000n);
  const dryState = {};
  await momentsGraduationJob({ client: pendingMomentClient(), cohorts: [cohort], sender: makeSender({ rpcUrl: "http://x", log: () => {} }), reporter: makeReporter({ log: () => {} }), state: dryState });
  assert.equal(dryState.budget, undefined);
});
