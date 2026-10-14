// Build 17, K1 through a whole run (lib/run.mjs) against a mocked chain, sender and webhook:
//  - E7: the sending address comes from the signer; a different --sim-from refuses the run; the balance check always
//    runs for the wallet that pays.
//  - E9: --max-runtime stops a hung run (critical alert, state saved, exit 1, nothing sent afterwards); a watchdog
//    never sends and marks its posts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseKeeperArgs } from "../lib/options.mjs";
import { runKeeper } from "../lib/run.mjs";
import { signerAddress } from "../lib/send.mjs";
import { EXIT } from "../lib/report.mjs";
import { momentsCohorts } from "../lib/deployments.mjs";
import { tempDir } from "./tmp.mjs";

const NOW = 1_790_000_000n;
const SIGNER = "0x1111111111111111111111111111111111111111";
const OTHER = "0x2222222222222222222222222222222222222222";
const MON = 10n ** 18n;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const opts = (argv, over = {}) => ({ ...parseKeeperArgs(argv, {}), ...over });

/** A chain with one live Moment stuck in GraduationPending whose retry simulates OK. */
/** `blockDelay` and `hang` apply to the jobs' block reads, not to the run's own first look at the head. */
function chain({ balance = 50n * MON, blockDelay = 0, hang = false, headAge = 2, clock = NOW } = {}) {
  const reads = {
    momentCount: 1n,
    state: 1,
    ledger: { state: 1, completedAt: NOW, stuckSince: NOW, endedAt: 0n, reserve: 1n },
    getMoment: { deadline: NOW + 20n * 86_400n, creator: SIGNER, platform: SIGNER, treasury: SIGNER, coin: SIGNER, nft: SIGNER },
  };
  return {
    balances: [],
    sims: [],
    blocks: 0,
    async getCode() {
      return "0x6000";
    },
    async getBalance({ address }) {
      this.balances.push(address);
      return balance;
    },
    async getBlock() {
      if (this.blocks++ === 0) return { number: 1000n, timestamp: clock - BigInt(headAge) };
      if (hang) await new Promise(() => {});
      if (blockDelay) await sleep(blockDelay);
      return { timestamp: NOW };
    },
    async getBlockNumber() {
      return 1000n;
    },
    async getGasPrice() {
      return 100n;
    },
    async readContract({ functionName }) {
      if (functionName in reads) return reads[functionName];
      throw new Error("execution reverted");
    },
    async simulateContract(req) {
      this.sims.push(req);
      return { result: null };
    },
  };
}

/** A sender whose live sends (`calls`) all succeed; in a dry run it sends nothing, as makeSender. */
function fakeSender(calls) {
  return ({ send }) => ({
    sent: [],
    live: send === true,
    async call(tx) {
      if (send !== true) return { dryRun: true };
      calls.push(tx);
      return { dryRun: false, receipt: { status: 1, transactionHash: `0x${"cd".repeat(32)}` }, spentWei: 1n };
    },
  });
}

function world({ client = chain(), signer = SIGNER, sends = [], posts = [], lines = [] } = {}) {
  return {
    client,
    sends,
    posts,
    lines,
    deps: {
      log: (l) => lines.push(l),
      env: {},
      makeClient: () => client,
      makeSenderFn: fakeSender(sends),
      signerAddressFn: () => signer,
      pickRpc: async (urls) => ({ url: urls[0], healthy: true }),
      now: () => Number(NOW) * 1000, // the chain's clock: its head is fresh
      fetchImpl: async (url, init) => (posts.push({ url, body: JSON.parse(init.body) }), { ok: true, status: 204 }),
    },
  };
}

// ---------------------------------------------------------------- E7

test("E7: signerAddress derives the sender with `cast wallet address` and the same keystore options as the sends", () => {
  const calls = [];
  const spawn = (bin, argv, o) => (calls.push({ bin, argv, o }), { status: 0, stdout: `${SIGNER}\n` });
  assert.equal(signerAddress({ keystore: "/ks/dyor-keeper-grad", passwordFile: "/run/creds/pw" }, { spawn, castBin: "cast" }), SIGNER);
  assert.deepEqual(calls[0].argv, ["wallet", "address", "--keystore", "/ks/dyor-keeper-grad", "--password-file", "/run/creds/pw"]);
  assert.equal(calls[0].o.killSignal, "SIGKILL");
  assert.ok(calls[0].o.timeout > 0, "a password prompt with no terminal cannot hang the run");
  signerAddress({ account: "dyor-keeper-grad" }, { spawn });
  assert.deepEqual(calls[1].argv, ["wallet", "address", "--account", "dyor-keeper-grad"]);
  assert.equal(signerAddress({ unlocked: OTHER }, { allowUnlocked: true, spawn }), OTHER, "anvil only: the address is given");
  assert.equal(calls.length, 2);
});

test("E7: a signer whose address cannot be derived stops the run", () => {
  const fail = (r) => () => signerAddress({ keystore: "/k" }, { spawn: () => r });
  assert.throws(fail({ status: 1, stdout: "", stderr: "Error: Failed to decrypt keystore: Mac Mismatch" }), /Mac Mismatch/);
  assert.throws(fail({ status: 0, stdout: "not an address" }), /could not derive/);
  assert.throws(fail({ status: null, signal: "SIGKILL", error: Object.assign(new Error("x"), { code: "ETIMEDOUT" }) }), /timed out/);
  assert.throws(() => signerAddress({}, { spawn: () => ({}) }), /needs a signer/);
});

test("E7: in send mode a --sim-from that is not the signer refuses the run before anything is read or sent", async () => {
  const w = world();
  await assert.rejects(runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, simFrom: OTHER }), w.deps), /--sim-from 0x2+ is not the signer's address 0x1+: refusing to run/);
  assert.deepEqual(w.sends, []);
  assert.deepEqual(w.client.balances, []);
  assert.deepEqual(w.client.sims, []);
});

test("E7: in send mode the signer's address is used for the simulations and the balance check, which always runs", async () => {
  const w = world({ client: chain({ balance: 5n * MON }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--min-balance", "10", "--webhook", "https://hooks.example/x"], { send: true, signer: { account: "k" } }), w.deps);
  assert.equal(code, EXIT.ALERT);
  assert.deepEqual(w.client.balances, [SIGNER]);
  assert.ok(w.client.sims.length > 0 && w.client.sims.every((s) => s.account === SIGNER), "simulated as the sender");
  assert.equal(w.sends.length, 1, "the retry is sent");
  const low = w.posts[0].body.alerts.find((x) => /below --min-balance 10/.test(x.reason));
  assert.equal(low.severity, "warning");
  assert.equal(low.target, SIGNER);
  // The same address given explicitly (any case) is fine.
  const same = world();
  await runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, simFrom: SIGNER.toUpperCase().replace("0X", "0x") }), same.deps);
  assert.equal(same.sends.length, 1);
});

test("E7: a dry run checks the balance of --sim-from when given, and reads none without it", async () => {
  const w = world({ client: chain({ balance: 1n }) });
  await runKeeper(opts(["moments-graduation", "--only-live"], { simFrom: OTHER }), w.deps);
  assert.deepEqual(w.client.balances, [OTHER]);
  const none = world();
  await runKeeper(opts(["moments-graduation", "--only-live"]), none.deps);
  assert.deepEqual(none.client.balances, []);
});

test("the run header names the RPC by its origin only, and the sending address", async () => {
  const w = world();
  const keyed = "https://monad.example/v2/FAKE_KEY_123";
  await runKeeper(opts(["moments-graduation", "--only-live", "--rpc-url", keyed, "--rpc-url", "https://rpc4.monad.xyz"], { send: true, signer: { account: "k" } }), w.deps);
  const header = w.lines.find((l) => l.startsWith("keeper:"));
  assert.equal(header, `keeper: moments-graduation · SEND · rpc https://monad.example/… → https://rpc4.monad.xyz · cast via https://monad.example/… · from ${SIGNER}`);
  assert.ok(!w.lines.join("\n").includes("FAKE_KEY_123"));
});

// ---------------------------------------------------------------- K2: a stale RPC

test("K2: an RPC whose head is stale is an alert (warning from 2 min, critical from 10) and the run sends nothing", async () => {
  const seen = {};
  for (const age of [30, 180, 3_600]) {
    const w = world({ client: chain({ headAge: age }) });
    const code = await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x"], { send: true, signer: { account: "k" } }), w.deps);
    const stale = w.posts[0]?.body.alerts.find((x) => x.key === "rpc:stale");
    seen[age] = [code, stale?.severity ?? "none", w.sends.length];
    if (stale) {
      assert.match(stale.reason, new RegExp(`RPC stale: its latest block 1000 is ${age}s old .*sends nothing`));
      assert.ok(w.lines.some((l) => /not sending graduate .*: the RPC's head is stale/.test(l)), "the retry is held, not failed");
      assert.ok(!w.posts[0].body.alerts.some((x) => /send failed/.test(x.reason)), "no failed-send alert, so no backoff");
    }
  }
  // Fresh: the retry is sent and succeeds, so the Moment it graduated is nothing for a human (exit 0, nothing posted).
  assert.deepEqual(seen, { 30: [EXIT.OK, "none", 1], 180: [EXIT.ALERT, "warning", 0], 3600: [EXIT.ALERT, "critical", 0] });
});

test("K2: a stale RPC resolves nothing: a posted alert its job no longer raises stays open", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const w = world();
  const o = opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile]);
  await runKeeper(o, w.deps);
  assert.ok(w.posts[0].body.alerts.some((x) => x.key.startsWith("mo1:pending:")));
  // The Moment no longer reads as pending, but the head is an hour old: that proves nothing.
  const stale = world({ client: { ...chain({ headAge: 3_600 }), readContract: async ({ functionName }) => (functionName === "momentCount" ? 1n : functionName === "state" ? 2 : 0n) } });
  await runKeeper(o, stale.deps);
  assert.ok(!stale.posts.some((p) => p.body.alerts.some((x) => x.kind === "resolved")), JSON.stringify(stale.posts));
});

// ---------------------------------------------------------------- E9

test("E9: --role watchdog refuses --send; unknown roles and a bad --max-runtime are usage errors", () => {
  assert.throws(() => parseKeeperArgs(["all", "--role", "watchdog", "--send"], {}), /watchdog never sends/);
  assert.throws(() => parseKeeperArgs(["all", "--role", "boss"], {}), /--role must be one of keeper, watchdog/);
  assert.throws(() => parseKeeperArgs(["all", "--max-runtime", "0"], {}), /--max-runtime must be a positive/);
  assert.equal(parseKeeperArgs(["all"], {}).maxRuntime, 240);
  assert.equal(parseKeeperArgs(["all"], {}).role, "keeper");
});

test("E9: runKeeper itself refuses a watchdog that would send", async () => {
  const w = world();
  await assert.rejects(runKeeper(opts(["governance"], { role: "watchdog", send: true, signer: { account: "k" } }), w.deps), /watchdog never sends/);
  assert.deepEqual(w.sends, []);
});

test("E9: every watchdog post is marked [watchdog]", async () => {
  const w = world({ client: chain({ balance: 0n }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--role", "watchdog", "--webhook", "https://hooks.example/x"], { simFrom: OTHER }), w.deps);
  assert.equal(code, EXIT.ALERT);
  assert.equal(w.posts.length, 1);
  assert.match(w.posts[0].body.text, /^\[watchdog\] DyorHQ keeper/);
  assert.ok(w.lines.some((l) => /· watchdog ·/.test(l)));
});

test("E9: a run past --max-runtime raises a critical alert, saves its state, posts, and exits 1", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const w = world({ client: chain({ hang: true }) });
  const t0 = Date.now();
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { maxRuntime: 0.2 }), w.deps);
  assert.equal(code, EXIT.ERROR);
  assert.ok(Date.now() - t0 < 2000, "stopped at the deadline, not when the read returned");
  const overrun = w.posts[0].body.alerts.find((x) => x.target === "run");
  assert.equal(overrun.severity, "critical");
  assert.match(overrun.reason, /exceeded --max-runtime 0\.2s during moments-graduation/);
  assert.equal(JSON.parse(readFileSync(stateFile, "utf8")).version, 1, "the state was saved");
});

test("E9: once the deadline has passed nothing more is sent, even when a late read lets the job go on", async () => {
  const w = world({ client: chain({ blockDelay: 300 }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, maxRuntime: 0.1 }), w.deps);
  assert.equal(code, EXIT.ERROR);
  await sleep(600); // the job wakes up, finds the pending Moment and tries to send its retry
  assert.ok(w.client.sims.length > 0, "the job did go on after the deadline");
  assert.deepEqual(w.sends, [], "but its send was refused");
});

test("E9: after an overrun the run saves and posts what it had at the deadline; a late scan result is left to the next run", async () => {
  const live = momentsCohorts().find((c) => c.live);
  const scanId = `mo1:GraduationFailed:${live.collect.toLowerCase()}`;
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  writeFileSync(stateFile, JSON.stringify({ version: 1, cursors: { [scanId]: "1000" } }));
  const event = { args: { momentId: 1n }, blockNumber: 1_500n, transactionHash: `0x${"fa".repeat(32)}`, logIndex: 0 };
  const client = (logsDelay) => ({
    ...chain(),
    async readContract({ functionName }) {
      if (functionName === "momentCount") return 0n;
      throw new Error("execution reverted");
    },
    async getBlockNumber() {
      return 2_000n;
    },
    async getLogs({ fromBlock, toBlock }) {
      if (logsDelay) await sleep(logsDelay);
      return fromBlock <= 1_500n && 1_500n <= toBlock ? [event] : [];
    },
  });
  const slowPost = world({ client: client(400) });
  // The webhook is slow too: the scan answers (and would move the cursor past the event) while the run posts.
  slowPost.deps.fetchImpl = async (url, init) => (slowPost.posts.push({ url, body: JSON.parse(init.body) }), await sleep(600), { ok: true, status: 204 });
  const o = opts(["moments-graduation", "--only-live", "--logs-cursor", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { maxRuntime: 0.2 });
  assert.equal(await runKeeper(o, slowPost.deps), EXIT.ERROR);
  await sleep(300);
  assert.ok(slowPost.lines.some((l) => /GraduationFailed emitted in block 1500/.test(l)), "the late scan did find it (stdout)");
  assert.ok(!slowPost.posts.some((p) => p.body.alerts.some((x) => /GraduationFailed/.test(x.reason))), "after the posts were planned");
  assert.equal(JSON.parse(readFileSync(stateFile, "utf8")).cursors[scanId], "1000", "so the saved cursor did not move past it");
  const next = world({ client: client(0) });
  await runKeeper({ ...o, maxRuntime: 240 }, next.deps);
  assert.ok(next.posts[0].body.alerts.some((x) => /GraduationFailed emitted in block 1500/.test(x.reason)), "the next run posts it");
});

test("E9: a send the job reaches after the deadline is refused without a failure or backoff in the saved state", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const w = world({ client: chain({ blockDelay: 300 }) });
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--state-file", stateFile], { send: true, signer: { account: "k" }, maxRuntime: 0.1 }), w.deps);
  assert.equal(code, EXIT.ERROR);
  await sleep(600);
  assert.deepEqual(w.sends, []);
  assert.ok(w.lines.some((l) => /not sending graduate .*stopped by --max-runtime/.test(l)));
  const saved = JSON.parse(readFileSync(stateFile, "utf8"));
  assert.equal(saved.budget?.backoff, undefined, "no backoff for a send that never went out");
});

test("E9: every send is told the time left before the deadline (send.mjs bounds cast by it)", async () => {
  const w = world();
  await runKeeper(opts(["moments-graduation", "--only-live"], { send: true, signer: { account: "k" }, maxRuntime: 240 }), w.deps);
  assert.equal(w.sends.length, 1);
  assert.ok(w.sends[0].timeLeftMs > 230_000 && w.sends[0].timeLeftMs <= 240_000, String(w.sends[0].timeLeftMs));
});

test("E9: a normal run finishes well inside the deadline and exits by its alerts", async () => {
  const w = world();
  const code = await runKeeper(opts(["moments-graduation", "--only-live"]), w.deps);
  assert.equal(code, EXIT.ALERT, "the pending Moment is a warning");
  assert.equal(momentsCohorts().filter((c) => c.live).length, 1);
});

test("K3: a Moment the run itself graduates is nothing for a human: a new one is never posted, an earlier post resolves", async () => {
  const fresh = world();
  const o = (stateFile, send) => opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], send ? { send: true, signer: { account: "k" } } : {});
  assert.equal(await runKeeper(o(join(tempDir("keeper-run-"), "state.json"), true), fresh.deps), EXIT.OK);
  assert.equal(fresh.sends.length, 1);
  assert.deepEqual(fresh.posts, [], "not posted as pending, then as resolved");
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const dry = world();
  await runKeeper(o(stateFile, false), dry.deps);
  assert.equal(dry.posts[0].body.alerts.find((a) => a.key.startsWith("mo1:pending:"))?.severity, "warning", "a dry run leaves it to a human");
  const live = world();
  await runKeeper(o(stateFile, true), live.deps);
  assert.deepEqual(live.posts[0].body.alerts.map((a) => `${a.kind} ${a.key.split(":")[0]}`), ["resolved mo1"]);
});

// ---------------------------------------------------------------- K3: sends are saved as they go

test("K3: a keeper killed while cast runs leaves the send in flight: the next run reports it, keeps it counted and backs off", async () => {
  const dir = tempDir("keeper-kill-");
  const stateFile = join(dir, "state.json");
  const started = join(dir, "cast-started");
  // A cast that hangs (as one waiting for a receipt), after saying it started.
  const cast = join(dir, "cast");
  writeFileSync(cast, `#!/bin/sh\ntouch "${started}"\nexec sleep 60\n`, { mode: 0o755 });
  const lib = new URL("../lib/", import.meta.url).href;
  const child = join(dir, "child.mjs");
  writeFileSync(
    child,
    `import { runKeeper } from "${lib}run.mjs";
import { parseKeeperArgs } from "${lib}options.mjs";
import { makeSender } from "${lib}send.mjs";
const NOW = ${NOW}n;
const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: NOW }, getMoment: { deadline: NOW + 20n * 86400n } };
const client = { getCode: async () => "0x60", getBalance: async () => 10n ** 20n, getBlock: async () => ({ number: 1n, timestamp: NOW }), getBlockNumber: async () => 1n, getGasPrice: async () => 100n * 10n ** 9n, readContract: async ({ functionName }) => { if (functionName in reads) return reads[functionName]; throw new Error("execution reverted"); }, simulateContract: async () => ({ result: null }) };
const o = parseKeeperArgs(["moments-graduation", "--only-live", "--send", "--account", "k", "--state-file", ${JSON.stringify(stateFile)}], {});
await runKeeper(o, { log: () => {}, env: {}, makeClient: () => client, makeSenderFn: (s) => makeSender({ ...s, castBin: ${JSON.stringify(cast)}, log: () => {} }), signerAddressFn: () => "${SIGNER}", pickRpc: async (u) => ({ url: u[0], healthy: true }), now: () => Number(NOW) * 1000 });
`,
  );
  const p = spawn(process.execPath, [child], { detached: true, stdio: "ignore" });
  for (let i = 0; i < 100 && !existsSync(started); i++) await sleep(100);
  assert.ok(existsSync(started), "cast started");
  process.kill(-p.pid, "SIGKILL"); // the keeper and its cast, as a deploy or the OOM killer would
  await new Promise((r) => (p.exitCode !== null || p.signalCode !== null ? r() : p.on("exit", r)));

  const saved = JSON.parse(readFileSync(stateFile, "utf8"));
  assert.equal(saved.budget.spend.length, 1, "the send was saved before cast ran");
  assert.match(saved.budget.spend[0].inFlight, /^graduate\(uint256\) to 0x/);
  assert.equal(saved.budget.spend[0].wei, String(5_000_000n * 100n * 10n ** 9n), "at its worst case: 5M gas x 100 gwei");
  assert.equal(Object.keys(saved.budget.backoff).length, 1, "and its target backed off");

  const w = world();
  const code = await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { send: true, signer: { account: "k" } }), w.deps);
  assert.equal(code, EXIT.ALERT);
  assert.deepEqual(w.sends, [], "backed off: not sent again at once");
  const unknown = w.posts[0].body.alerts.find((a) => a.key.startsWith("send:inflight:"));
  assert.equal(unknown.severity, "critical");
  assert.match(unknown.reason, /outcome UNKNOWN for graduate\(uint256\) to 0x.*stopped while cast ran.*counted as up to 0\.5 MON spent/);
  const after = JSON.parse(readFileSync(stateFile, "utf8"));
  assert.equal(after.budget.spend.length, 1, "still counted");
  assert.equal(after.budget.spend[0].inFlight, undefined, "reported once");
});

test("K3: a live send is saved before cast runs and its outcome saved after it", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const w = world();
  const seen = [];
  w.deps.makeSenderFn = () => ({
    sent: [],
    live: true,
    async call() {
      seen.push(JSON.parse(readFileSync(stateFile, "utf8")));
      return { dryRun: false, receipt: { status: 1, transactionHash: `0x${"cd".repeat(32)}` }, spentWei: 7n };
    },
  });
  await runKeeper(opts(["moments-graduation", "--only-live", "--state-file", stateFile], { send: true, signer: { account: "k" } }), w.deps);
  assert.equal(seen.length, 1);
  assert.ok(seen[0].budget.spend[0].inFlight, "in flight while cast ran");
  const saved = JSON.parse(readFileSync(stateFile, "utf8"));
  assert.deepEqual(saved.budget.spend.map((e) => [e.wei, e.tx, e.inFlight]), [["7", `0x${"cd".repeat(32)}`, undefined]], "replaced by the receipt's cost");
  assert.deepEqual(saved.budget.backoff, {}, "the provisional backoff is gone after a success");
});

test("K3: a failed send's alert is saved with its spend, before the run posts (a run killed in between still has it posted)", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  const w = world();
  const { MinedRevert } = await import("../lib/send.mjs");
  w.deps.makeSenderFn = () => ({
    sent: [],
    live: true,
    async call() {
      throw new MinedRevert({ txHash: `0x${"ab".repeat(32)}`, gasLimit: 5_000_000n, gasUsed: 5_000_000n, effectiveGasPrice: 1n, spentWei: 5_000_000n });
    },
  });
  let onDisk;
  w.deps.fetchImpl = async (url, init) => ((onDisk ??= JSON.parse(readFileSync(stateFile, "utf8"))), w.posts.push({ url, body: JSON.parse(init.body) }), { ok: true, status: 204 });
  await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { send: true, signer: { account: "k" } }), w.deps);
  const key = Object.keys(onDisk.notify.keys).find((k) => k.startsWith("send:"));
  assert.ok(key, "in the history on disk when the post started");
  assert.equal(onDisk.notify.keys[key].posted, undefined);
  assert.match(onDisk.notify.keys[key].reason, /mined but REVERTED/);
  assert.equal(onDisk.budget.spend[0].wei, "5000000");
  assert.ok(w.posts[0].body.alerts.some((a) => a.key === key), "and posted by this run");
});

test("K3: after a corrupt state file is reset, sends are held for 24 hours (the cap's lost window), then resume", async () => {
  const stateFile = join(tempDir("keeper-run-"), "state.json");
  writeFileSync(stateFile, '{"budget": {"spend": [');
  // A run `s` seconds after the reset, against a head that is fresh then.
  const at = (s = 0) => {
    const w = world({ client: chain({ clock: NOW + BigInt(s) }) });
    w.deps.now = () => (Number(NOW) + s) * 1000;
    return w;
  };
  const o = opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { send: true, signer: { account: "k" } });
  const first = at();
  await runKeeper(o, first.deps);
  assert.deepEqual(first.sends, [], "the reset run sends nothing");
  const reset = first.posts[0].body.alerts.find((a) => a.target === "state file" && /was unreadable/.test(a.reason));
  assert.equal(reset.severity, "critical");
  assert.match(reset.reason, /sends are held until/);
  assert.equal(first.posts[0].body.alerts.find((a) => a.key === "budget:resethold")?.severity, "warning", "a standing warning until the hold ends");
  // An hour later: still held.
  const later = at(3_600);
  await runKeeper(o, later.deps);
  assert.deepEqual(later.sends, []);
  assert.ok(later.lines.some((l) => /not sending graduate .*the state file was reset; sends are held until/.test(l)));
  // A day later the ledger it lost would have left the window anyway: sends resume.
  const day = at(86_400);
  await runKeeper(o, day.deps);
  assert.equal(day.sends.length, 1);
  assert.equal(JSON.parse(readFileSync(stateFile, "utf8")).budget.heldUntil, undefined);
});

test("K3: a state file that cannot be written holds every send, and the run still posts its alerts and exits 1", { skip: process.getuid?.() === 0 && "root ignores file modes" }, async () => {
  const dir = tempDir("keeper-ro-");
  const stateFile = join(dir, "state.json");
  writeFileSync(stateFile, JSON.stringify({ version: 1 }));
  chmodSync(dir, 0o500); // the file reads, but no temp file can be written next to it (a full or read-only volume)
  try {
    const w = world();
    const code = await runKeeper(opts(["moments-graduation", "--only-live", "--webhook", "https://hooks.example/x", "--state-file", stateFile], { send: true, signer: { account: "k" } }), w.deps);
    assert.equal(code, EXIT.ERROR);
    assert.deepEqual(w.sends, [], "nothing is sent while the ledger cannot be kept");
    const alerts = w.posts[0].body.alerts;
    assert.equal(alerts.find((a) => a.key === "keeper:state:write")?.severity, "critical");
    assert.ok(alerts.some((a) => a.key.startsWith("mo1:pending:")), "the run's own alerts are posted too");
    assert.ok(w.lines.some((l) => /not sending graduate .*state file could not be saved/.test(l)));
  } finally {
    chmodSync(dir, 0o700);
  }
});
