import { test } from "node:test";
import assert from "node:assert/strict";
import { signerArgs, castSendArgv, castEnv, makeSender, assertNoKeyEnv } from "../lib/send.mjs";

const RPC = "http://127.0.0.1:8545";
const TO = "0x0000000000000000000000000000000000000abc";

test("signers: keystore, named account, ledger", () => {
  assert.deepEqual(signerArgs({ keystore: "/k.json", passwordFile: "/pw" }), ["--keystore", "/k.json", "--password-file", "/pw"]);
  assert.deepEqual(signerArgs({ account: "keeper" }), ["--account", "keeper"]);
  assert.deepEqual(signerArgs({ ledger: true, hdPath: "m/44'/60'/1'/0/0" }), ["--ledger", "--mnemonic-derivation-path", "m/44'/60'/1'/0/0"]);
});

test("signers: raw keys and mnemonics are refused; a signer is required", () => {
  assert.throws(() => signerArgs({ privateKey: "0x01" }), /raw keys/);
  assert.throws(() => signerArgs({ mnemonic: "test test" }), /raw keys/);
  assert.throws(() => signerArgs({}), /needs a signer/);
});

test("signers: --unlocked only with an explicit local-anvil opt-in", () => {
  assert.throws(() => signerArgs({ unlocked: TO }), /anvil/);
  assert.deepEqual(signerArgs({ unlocked: TO }, { allowUnlocked: true }), ["--unlocked", "--from", TO]);
});

test("private keys in the environment stop the keeper", () => {
  assert.throws(() => assertNoKeyEnv({ PRIVATE_KEY: "0x01" }), /PRIVATE_KEY/);
  assert.doesNotThrow(() => assertNoKeyEnv({}));
});

test("castSendArgv builds the exact cast command; the RPC URL goes through ETH_RPC_URL, never argv", () => {
  assert.deepEqual(castSendArgv({ to: TO, signature: "graduate(uint256)", args: [7n], gasLimit: 5_000_000n, signer: { account: "keeper" } }), [
    "send", TO, "graduate(uint256)", "7", "--gas-limit", "5000000", "--account", "keeper",
  ]);
  assert.equal(castEnv(RPC, { PATH: "/bin" }).ETH_RPC_URL, RPC);
  assert.equal(castEnv(RPC, { PATH: "/bin" }).PATH, "/bin");
});

test("dry-run (default) never spawns cast and needs no signer", async () => {
  let spawned = 0;
  const logs = [];
  const s = makeSender({ rpcUrl: RPC, log: (l) => logs.push(l), spawn: () => spawned++ });
  const r = await s.call({ to: TO, signature: "graduate(uint256)", args: [1n] });
  assert.equal(r.dryRun, true);
  assert.equal(spawned, 0);
  assert.match(logs[0], /^\[dry-run\] graduate\(uint256\): ETH_RPC_URL=<rpc> cast send 0x0+abc 'graduate\(uint256\)' 1 '<signer>'$/);
});

test("a keyed RPC URL never reaches the printed command or cast's argv (sec2: SEC-5)", async () => {
  const keyed = "https://rpc3.monad.xyz/?apikey=FAKE_SECRET_123";
  const logs = [];
  const calls = [];
  const s = makeSender({ send: true, rpcUrl: keyed, signer: { account: "keeper" }, log: (l) => logs.push(l), spawn: (bin, argv, opts) => (calls.push({ argv, env: opts.env }), { status: 0, stdout: "ok" }) });
  await s.call({ to: TO, signature: "graduate(uint256)", args: [1n], gasLimit: 900_000n });
  assert.ok(!logs.join("\n").includes("FAKE_SECRET_123"), "printed command");
  assert.ok(!calls[0].argv.join(" ").includes("FAKE_SECRET_123"), "argv (visible in ps)");
  assert.equal(calls[0].env.ETH_RPC_URL, keyed, "cast gets it from its environment");
});

test("send mode spawns cast with the signer and surfaces failures", async () => {
  const calls = [];
  const s = makeSender({ send: true, rpcUrl: RPC, signer: { keystore: "/k.json" }, log: () => {}, spawn: (bin, argv) => (calls.push([bin, argv]), { status: 0, stdout: "ok" }) });
  await s.call({ to: TO, signature: "graduate(uint256)", args: [1n] });
  assert.equal(calls[0][0], "cast");
  assert.deepEqual(calls[0][1].slice(-2), ["--keystore", "/k.json"]);
  const bad = makeSender({ send: true, rpcUrl: RPC, signer: { keystore: "/k.json" }, log: () => {}, spawn: () => ({ status: 1, stderr: "execution reverted" }) });
  await assert.rejects(bad.call({ to: TO, signature: "graduate(uint256)", args: [1n] }), /execution reverted/);
});

test("send mode without a signer refuses to start", () => {
  assert.throws(() => makeSender({ send: true, rpcUrl: RPC, signer: {} }), /needs a signer/);
});

// sec2 (SEC-5): the keeper used to print the full --rpc-url in its header and error stacks, and cron appends stdout to
// a log file, so a keyed endpoint wrote its API key to disk on every run.
test("redact: URLs shrink to their origin and configured secrets disappear, in logs and in alerts", async () => {
  const { redact, rpcLabel } = await import("../lib/redact.mjs");
  const { makeReporter } = await import("../lib/report.mjs");
  const keyed = "https://monad-mainnet.g.alchemy.com/v2/FAKE_SECRET_123";
  assert.equal(rpcLabel(keyed), "https://monad-mainnet.g.alchemy.com/…");
  assert.equal(rpcLabel("https://rpc1.monad.xyz"), "https://rpc1.monad.xyz");
  assert.equal(rpcLabel("https://user:pw@rpc.example/?apikey=K"), "https://rpc.example/…");
  const text = redact(`HTTP request failed.\nURL: ${keyed}\nRequest body: {}; also FAKE_SECRET_123 alone`, [keyed, "FAKE_SECRET_123"]);
  assert.ok(!text.includes("FAKE_SECRET_123"), text);
  // Punctuation after a URL is not part of it: it stays, and the key still goes.
  assert.equal(redact("error sending request for url (http://127.0.0.1:8814/); not retried"), "error sending request for url (http://127.0.0.1:8814); not retried");
  assert.equal(redact(`failed (${keyed}), then: ${keyed}.`), "failed (https://monad-mainnet.g.alchemy.com/…), then: https://monad-mainnet.g.alchemy.com/….");
  const lines = [];
  const reporter = makeReporter({ log: (l) => lines.push(l), scrub: (s) => redact(s, [keyed]) });
  reporter.alert({ job: "x", target: "y", severity: "critical", reason: `read failed: ${keyed}` });
  assert.ok(!lines.join("\n").includes("FAKE_SECRET_123"));
  assert.ok(!JSON.stringify(reporter.alerts).includes("FAKE_SECRET_123"), "what the webhook would post");
});
