// Opt-in (KEEPER_ANVIL=1; needs Foundry's anvil and cast, found on PATH, in ~/.foundry/bin, or via ANVIL_BIN /
// CAST_BIN): the case the build-17 keepers research reproduced, end to end. A real `cast send` with a gas limit to a
// contract that always reverts exits 0 with "status":"0x0"; driven through makeSender -> safeSend (the MO-1 retry)
// it must raise a critical alert and record what it cost. A plain local anvil (no fork) on 127.0.0.1 (KEEPER_ANVIL_PORT
// picks the port, else a random one) and a sender address derived from a label: never anvil's default accounts, which
// carry EIP-7702 code on Monad.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { keccak256, toBytes } from "viem";
import { makeSender } from "../lib/send.mjs";
import { makeReporter } from "../lib/report.mjs";
import { momentsGraduationJob } from "../lib/jobs.mjs";
import { spentSince } from "../lib/budget.mjs";

const enabled = process.env.KEEPER_ANVIL === "1";
const foundry = (bin) => {
  const env = process.env[`${bin.toUpperCase()}_BIN`];
  if (env) return env;
  const home = join(homedir(), ".foundry", "bin", bin);
  return existsSync(home) ? home : bin;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function rpc(url, method, params = []) {
  const res = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

test("E1 on anvil: a real mined-but-reverted cast send is a critical alert and its cost is recorded", { skip: !enabled && "set KEEPER_ANVIL=1 to run (needs anvil and cast)" }, async () => {
  const port = Number(process.env.KEEPER_ANVIL_PORT ?? 21000 + Math.floor(Math.random() * 20000));
  const url = `http://127.0.0.1:${port}`;
  const anvil = spawn(foundry("anvil"), ["--host", "127.0.0.1", "--port", String(port), "--silent"], { stdio: "ignore" });
  try {
    let up = false;
    for (let i = 0; i < 50 && !up; i++) {
      up = await rpc(url, "eth_chainId").then(() => true, () => false);
      if (!up) await sleep(200);
    }
    assert.ok(up, "anvil started");
    const from = `0x${keccak256(toBytes("dyor-keeper-anvil-test-sender")).slice(-40)}`;
    const target = "0x00000000000000000000000000000000000d0e5d";
    await rpc(url, "anvil_setCode", [target, "0x60006000fd"]); // PUSH1 0 PUSH1 0 REVERT: every call reverts
    await rpc(url, "anvil_impersonateAccount", [from]);
    await rpc(url, "anvil_setBalance", [from, "0x56BC75E2D63100000"]);

    // The Moments reads are mocked (one GraduationPending Moment whose retry "simulates"); the send is real.
    const NOW = 1_790_000_000n;
    const reads = {
      momentCount: 1n,
      state: 1,
      ledger: { state: 1, completedAt: NOW, stuckSince: NOW, endedAt: 0n, reserve: 1n },
      getMoment: { deadline: NOW + 20n * 86_400n, creator: from, platform: from, treasury: from, coin: from, nft: from },
    };
    const client = {
      getBlock: async () => ({ timestamp: NOW }),
      getGasPrice: async () => BigInt(await rpc(url, "eth_gasPrice")),
      readContract: async ({ functionName }) => reads[functionName],
      simulateContract: async () => ({ result: null }),
    };
    const cohort = { label: "anvil cohort", factory: target, collect: target, graduation: target };
    const sender = makeSender({ send: true, rpcUrl: url, signer: { unlocked: from }, allowUnlocked: true, castBin: foundry("cast"), log: () => {} });
    const reporter = makeReporter({ log: () => {} });
    const state = {};
    await momentsGraduationJob({ client, cohorts: [cohort], sender, reporter, state });

    const failed = reporter.alerts.filter((x) => /send failed/.test(x.reason));
    assert.equal(failed.length, 1, JSON.stringify(reporter.alerts));
    assert.equal(failed[0].severity, "critical");
    assert.match(failed[0].reason, /mined but REVERTED \(tx 0x[0-9a-f]{64}\)/);
    const tx = failed[0].reason.match(/tx (0x[0-9a-f]{64})/)[1];
    const receipt = await rpc(url, "eth_getTransactionReceipt", [tx]);
    assert.equal(receipt.status, "0x0", "the chain agrees: mined and reverted");
    assert.equal(state.budget.spend[0].tx, tx);
    assert.equal(spentSince(state, 0), 5_000_000n * BigInt(receipt.effectiveGasPrice), "counted at the gas limit, as Monad bills it");
  } finally {
    anvil.kill("SIGKILL");
  }
});

// The RPC goes away after cast has broadcast, while it waits for the receipt (anvil --no-mining holds the transaction
// in its pool, then a timer outside this process kills anvil): cast prints only "error sending request for url",
// which must be an unknown outcome counted at its worst case, never a free failure.
test("E1 on anvil: a send whose RPC dies after the broadcast is an unknown outcome, counted at its worst case", { skip: !enabled && "set KEEPER_ANVIL=1 to run (needs anvil and cast)", timeout: 240_000 }, async () => {
  const port = Number(process.env.KEEPER_ANVIL_LOST_PORT ?? 21000 + Math.floor(Math.random() * 20000));
  const url = `http://127.0.0.1:${port}`;
  // spawnSync (cast) blocks this process's timers, so the kill is a shell's own timer.
  const killer = spawn("sh", ["-c", `"$0" --host 127.0.0.1 --port ${port} --silent --no-mining & pid=$!; sleep 8; kill -9 $pid`, foundry("anvil")], { stdio: "ignore" });
  try {
    let up = false;
    for (let i = 0; i < 50 && !up; i++) {
      up = await rpc(url, "eth_chainId").then(() => true, () => false);
      if (!up) await sleep(100);
    }
    assert.ok(up, "anvil started");
    const from = `0x${keccak256(toBytes("dyor-keeper-anvil-lost-rpc-sender")).slice(-40)}`;
    const target = "0x00000000000000000000000000000000000d0e5e";
    await rpc(url, "anvil_impersonateAccount", [from]);
    await rpc(url, "anvil_setBalance", [from, "0x56BC75E2D63100000"]);
    const gasPrice = BigInt(await rpc(url, "eth_gasPrice"));
    const NOW = 1_790_000_000n;
    const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: NOW }, getMoment: { deadline: NOW + 20n * 86_400n } };
    const client = { getBlock: async () => ({ timestamp: NOW }), getGasPrice: async () => gasPrice, readContract: async ({ functionName }) => reads[functionName], simulateContract: async () => ({ result: null }) };
    const sender = makeSender({ send: true, rpcUrl: url, signer: { unlocked: from }, allowUnlocked: true, castBin: foundry("cast"), log: () => {} });
    const reporter = makeReporter({ log: () => {} });
    const state = {};
    await momentsGraduationJob({ client, cohorts: [{ label: "anvil cohort", factory: target, collect: target, graduation: target }], sender, reporter, state });
    const failed = reporter.alerts.filter((x) => /send failed/.test(x.reason));
    assert.equal(failed.length, 1, JSON.stringify(reporter.alerts));
    assert.equal(failed[0].severity, "critical");
    assert.match(failed[0].reason, /outcome UNKNOWN/, failed[0].reason);
    assert.equal(state.budget.spend.length, 1);
    assert.equal(state.budget.spend[0].estimated, true);
    assert.equal(spentSince(state, 0), 5_000_000n * gasPrice, "counted at the gas limit x the gas price");
  } finally {
    killer.kill("SIGKILL");
  }
});
