// Build 17, K2 / E5: RPC resilience. Reads fall back across the --rpc-url list (rpc3 -> rpc4); cast sends through the
// first endpoint that answers as chain 143; an RPC failure is never read as a chain answer, and a run's RPC failures
// are posted as one "RPC degraded" warning (critical after 3 runs in a row), not one critical per item. The research
// run on rpc1 raised 11 criticals for one rate limit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { join } from "node:path";
import { HttpRequestError, TimeoutError } from "viem";
import { isRangeRefusal, isTransportError, makeRpcClient, firstHealthy, rpcDegradedAlert, DEFAULT_RPC_URLS } from "../lib/rpc.mjs";
import { getLogsChunked, momentsGraduationJob } from "../lib/jobs.mjs";
import { makeReporter, EXIT } from "../lib/report.mjs";
import { makeSender } from "../lib/send.mjs";
import { parseKeeperArgs } from "../lib/options.mjs";
import { runKeeper } from "../lib/run.mjs";
import { redact } from "../lib/redact.mjs";
import { tempDir } from "./tmp.mjs";

const ADDRESS = "0x00000000000000000000000000000000000000f4";
const http429 = () => new HttpRequestError({ url: "https://rpc1.monad.xyz/?key=FAKE_KEY_123", status: 429, body: {} });

test("E5: RPC failures are told apart from chain answers", () => {
  assert.equal(isTransportError(http429()), true);
  assert.equal(isTransportError(new TimeoutError({ body: {}, url: "https://rpc3.monad.xyz" })), true);
  assert.equal(isTransportError(Object.assign(new Error("ContractFunctionExecutionError"), { cause: Object.assign(new Error("CallExecutionError"), { cause: http429() }) })), true, "wrapped by readContract");
  assert.equal(isTransportError(Object.assign(new Error("fetch failed"), { cause: { code: "ECONNRESET" } })), true);
  assert.equal(isTransportError(new Error("429 Too Many Requests")), true);
  assert.equal(isTransportError(new Error("execution reverted: PriceMoved")), false);
  assert.equal(isTransportError(Object.assign(new Error("RPC Request failed."), { details: "eth_getLogs is limited to a 100 range" })), false);
  assert.equal(isTransportError(Object.assign(new Error("RPC Request failed."), { code: -32062, details: "Block range is too large" })), false);
  assert.equal(isTransportError(new Error('The contract function "state" returned no data ("0x"). args: (503)')), false, "a Moment id is not a status code");
  assert.equal(isTransportError(new Error("unmocked read 0xabc:launchMondayOnly:0x1")), false);
});

test("E5: a configured RPC URL is shown by its origin in logs and alerts (a key in it never is)", () => {
  const urls = ["https://rpc3.monad.xyz", "https://monad.example/v2/FAKE_KEY_123"];
  assert.equal(redact("rpc https://rpc3.monad.xyz failed 3", urls), "rpc https://rpc3.monad.xyz failed 3");
  assert.equal(redact("POST https://monad.example/v2/FAKE_KEY_123 failed", urls), "POST https://monad.example/… failed");
  assert.equal(redact("token FAKE_KEY_123", ["FAKE_KEY_123"]), "token [redacted]");
});

test("E5: --rpc-url repeats; the default is rpc3 then rpc4, or MONAD_RPC_URL alone", () => {
  assert.deepEqual(parseKeeperArgs(["governance"], {}).rpcUrls, [...DEFAULT_RPC_URLS]);
  assert.deepEqual(DEFAULT_RPC_URLS, ["https://rpc3.monad.xyz", "https://rpc4.monad.xyz"]);
  assert.deepEqual(parseKeeperArgs(["governance"], { MONAD_RPC_URL: "https://a.example" }).rpcUrls, ["https://a.example"]);
  const o = parseKeeperArgs(["governance", "--rpc-url", "https://a.example", "--rpc-url", "https://b.example"], {});
  assert.deepEqual(o.rpcUrls, ["https://a.example", "https://b.example"]);
  assert.equal(o.rpcUrl, "https://a.example");
});

// Fork rehearsal 2026-10-01: run-keeper.sh put every RPC URL on the keeper's command line, so a restricted provider key
// showed in `ps` for the whole run. The list now comes from the environment.
test("E5: KEEPER_RPC_URLS (space-separated) is the RPC list without --rpc-url, ahead of MONAD_RPC_URL", () => {
  const keyed = "https://monad-mainnet.example/v2/FAKE_KEY_123";
  const env = { KEEPER_RPC_URLS: ` ${keyed}  https://rpc3.monad.xyz\nhttps://rpc4.monad.xyz `, MONAD_RPC_URL: "https://a.example" };
  assert.deepEqual(parseKeeperArgs(["governance"], env).rpcUrls, [keyed, "https://rpc3.monad.xyz", "https://rpc4.monad.xyz"]);
  assert.equal(parseKeeperArgs(["governance"], env).rpcUrl, keyed);
  assert.deepEqual(parseKeeperArgs(["governance", "--rpc-url", "https://b.example"], env).rpcUrls, ["https://b.example"], "--rpc-url still wins");
  assert.deepEqual(parseKeeperArgs(["governance"], { KEEPER_RPC_URLS: "  " }).rpcUrls, [...DEFAULT_RPC_URLS], "blank is unset");
  assert.deepEqual(parseKeeperArgs(["governance"], { KEEPER_RPC_URLS: "", MONAD_RPC_URL: "https://a.example" }).rpcUrls, ["https://a.example"]);
});

async function server(handler) {
  const s = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d)).on("end", () => handler(JSON.parse(body || "{}"), res));
  });
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${s.address().port}`, close: () => s.close() };
}
const answer = (result) => (req, res) => {
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ jsonrpc: "2.0", id: req.id, result }));
};

test("E5: reads fall back to the next endpoint when the first fails, and each endpoint's failures are counted", async () => {
  const down = await server((req, res) => (res.writeHead(503), res.end("down")));
  const up = await server(answer("0x10"));
  try {
    const { client, stats } = makeRpcClient([`${down.url}/v2/FAKE_KEY_123`, up.url]);
    assert.equal(await client.getBlockNumber({ cacheTime: 0 }), 16n);
    const labels = Object.keys(stats);
    assert.deepEqual(labels, [`${down.url}/…`, up.url], "stats are keyed by label, never the keyed URL");
    assert.ok(stats[labels[0]].failed >= 1);
    assert.ok(stats[labels[1]].served >= 1);
  } finally {
    down.close();
    up.close();
  }
});

// ---------------------------------------------------------------- the getLogs range caps, through viem's real transport

/** An endpoint that answers eth_getLogs like a Monad RPC measured on 2026-10-01; `spans` records each request's
    inclusive span and whether it was served. */
async function logsEndpoint(refuse) {
  const spans = [];
  const s = await server((req, res) => {
    if (req.method !== "eth_getLogs") return answer("0x10")(req, res);
    const span = BigInt(req.params[0].toBlock) - BigInt(req.params[0].fromBlock) + 1n;
    const r = refuse(span, req);
    spans.push([span, r ? "refused" : "served"]);
    if (!r) return answer([])(req, res);
    res.writeHead(r.status, { "content-type": r.json ? "application/json" : "text/html" });
    res.end(r.json ? JSON.stringify({ jsonrpc: "2.0", id: req.id, error: r.json }) : r.text);
  });
  return { ...s, spans };
}
// rpc3: more than 1,000 blocks (inclusive) -> HTTP 200 with -32062.
const rpc3Like = () => logsEndpoint((span) => span > 1000n && { status: 200, json: { code: -32062, message: "Block range is too large" } });
// rpc4: more than 1,001 -> HTTP 413 with -32614 (some of its backends; others take far more).
const rpc4Like = () => logsEndpoint((span) => span > 1001n && { status: 413, json: { code: -32614, message: "eth_getLogs is limited to a 1,000 range" } });
// rpc.monad.xyz: more than 101 -> HTTP 413 with -32614.
const monadLike = () => logsEndpoint((span) => span > 101n && { status: 413, json: { code: -32614, message: "eth_getLogs is limited to a 100 range" } });

test("K2 boundary through viem: the default --logs-chunk asks rpc3 for 1,000-block inclusive spans, so nothing is refused or falls back", async () => {
  const { logsChunk } = parseKeeperArgs(["governance"], {});
  assert.equal(logsChunk, 1000n);
  const rpc3 = await rpc3Like();
  const rpc4 = await rpc4Like();
  try {
    const { client } = makeRpcClient([rpc3.url, rpc4.url]);
    await getLogsChunked(client, { address: ADDRESS, from: 108_860_011n, to: 108_863_010n, chunk: logsChunk });
    assert.deepEqual(rpc3.spans, [[1000n, "served"], [1000n, "served"], [1000n, "served"]]);
    assert.deepEqual(rpc4.spans, [], "rpc4 is never needed");
    // One block more per request and rpc3 refuses every one: each chunk then costs a refusal and a fallback.
    rpc3.spans.length = 0;
    await getLogsChunked(client, { address: ADDRESS, from: 0n, to: 2_001n, chunk: 1001n });
    assert.deepEqual(rpc3.spans, [[1001n, "refused"], [1001n, "refused"]]);
    assert.deepEqual(rpc4.spans, [[1001n, "served"], [1001n, "served"]]);
  } finally {
    rpc3.close();
    rpc4.close();
  }
});

test("K2 fallback through viem: with rpc3 down, rpc4 serves the same 1,000-block spans and rpc3's failures are counted", async () => {
  const down = await server((req, res) => (res.writeHead(503), res.end("down")));
  const rpc4 = await rpc4Like();
  try {
    const { client, stats } = makeRpcClient([down.url, rpc4.url]);
    await getLogsChunked(client, { address: ADDRESS, from: 0n, to: 1_999n });
    assert.deepEqual(rpc4.spans, [[1000n, "served"], [1000n, "served"]]);
    assert.ok(stats[down.url].failed >= 2);
    assert.equal(stats[rpc4.url].served, 2);
  } finally {
    down.close();
    rpc4.close();
  }
});

test("K2: an HTTP 413 range refusal (rpc.monad.xyz, or a bare 413 from a proxy) halves the chunk; it is never an RPC failure", async () => {
  const monad = await monadLike();
  const proxy = await logsEndpoint((span) => span > 250n && { status: 413, text: "<html>413 Request Entity Too Large</html>" });
  try {
    await getLogsChunked(makeRpcClient([monad.url]).client, { address: ADDRESS, from: 0n, to: 999n });
    assert.deepEqual(monad.spans.slice(0, 5).map(([s, r]) => `${s} ${r}`), ["1000 refused", "500 refused", "250 refused", "125 refused", "62 served"]);
    assert.ok(monad.spans.every(([s, r]) => (r === "served") === s <= 101n));
    assert.equal(monad.spans.filter(([, r]) => r === "served").reduce((n, [s]) => n + s, 0n), 1000n, "every block once");

    await getLogsChunked(makeRpcClient([proxy.url]).client, { address: ADDRESS, from: 0n, to: 999n });
    assert.deepEqual([...new Set(proxy.spans.map(([s, r]) => `${s} ${r}`))], ["1000 refused", "500 refused", "250 served"]);
  } finally {
    monad.close();
    proxy.close();
  }
  assert.equal(isRangeRefusal(new HttpRequestError({ url: "https://x.example", status: 413, body: {} })), true);
  assert.equal(isRangeRefusal(Object.assign(new Error("RPC Request failed."), { code: -32614, details: "eth_getLogs is limited to a 100 range" })), true);
  assert.equal(isRangeRefusal(Object.assign(new Error("RPC Request failed."), { code: -32062, details: "Block range is too large" })), true);
  assert.equal(isRangeRefusal(http429()), false, "a rate limit");
  assert.equal(isRangeRefusal(new Error("429 Too Many Requests")), false);
  assert.equal(isRangeRefusal(new HttpRequestError({ url: "https://x.example", status: 503, body: {} })), false, "an outage");
});

// Measured 2026-10-01 on rpc3 and rpc4: a call to a function the contract lacks is code 3 "execution reverted"; a call
// at a block the answering backend does not have yet is -32602 "Block requested not found…"; rpc4 answers a log range
// past its head with -32602 "block range extends beyond current head block".
const BLOCK_NOT_FOUND = "Block requested not found. Request might be querying historical state that is not available. If possible, reformulate query to point to more recent blocks";

test("K2: a lagging backend, a quota or an internal error is an RPC failure, through viem's real transport; a revert is not", async () => {
  const replies = { revert: { code: 3, message: "execution reverted", data: "0x" }, lag: { code: -32602, message: BLOCK_NOT_FOUND }, internal: { code: -32603, message: "internal error" }, quota: { code: -32001, message: "daily request count exceeded, request rate limited" } };
  let mode = "revert";
  const s = await server((req, res) => {
    if (req.method !== "eth_call") return answer("0x8f")(req, res);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ jsonrpc: "2.0", id: req.id, error: replies[mode] }));
  });
  try {
    const { client } = makeRpcClient([s.url], { timeoutMs: 2_000 });
    const abi = [{ type: "function", name: "graduate", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] }];
    const failure = async (m) => {
      mode = m;
      return client.simulateContract({ address: ADDRESS, abi, functionName: "graduate", args: [503n], account: "0x000000000000000000000000000000000000dEaD" }).then(() => null, (e) => e);
    };
    assert.equal(isTransportError(await failure("revert")), false, "the chain answered: it reverts");
    for (const m of ["lag", "internal", "quota"]) assert.equal(isTransportError(await failure(m)), true, m);
  } finally {
    s.close();
  }
  const rpc4Lag = Object.assign(new Error("RPC Request failed."), { code: -32602, details: "block range extends beyond current head block" });
  assert.equal(isTransportError(rpc4Lag), true);
  assert.equal(isRangeRefusal(rpc4Lag), false, "no smaller range will do");
  assert.equal(isRangeRefusal(Object.assign(new Error("RPC Request failed."), { details: "daily request count exceeded" })), false, "a quota is not a range cap");
  assert.equal(isRangeRefusal(Object.assign(new Error("RPC Request failed."), { code: -32005, details: "query returned more than 10000 results. Try with this block range [0x1, 0x2]." })), true, "a result cap still halves");
});

test("K2: a log range past a lagging backend's head fails the read at once instead of halving down to one block", async () => {
  const calls = [];
  const client = {
    async getLogs(req) {
      calls.push(req);
      throw Object.assign(new Error("RPC Request failed."), { code: -32602, details: "block range extends beyond current head block" });
    },
  };
  await assert.rejects(getLogsChunked(client, { from: 0n, to: 999n, chunk: 1000n }), (e) => isTransportError(e));
  assert.equal(calls.length, 1);
});

test("E5: cast sends through the first endpoint that answers as chain 143 with a fresh head", async () => {
  const NOW_S = 1_790_000_000;
  const node = (chainId, headAge) => async (init) => {
    const { method } = JSON.parse(init.body);
    return { ok: true, json: async () => ({ result: method === "eth_chainId" ? chainId : { number: "0x10", timestamp: `0x${(NOW_S - headAge).toString(16)}` } }) };
  };
  const replies = {
    "https://a.example": () => Promise.reject(new Error("fetch failed")),
    "https://b.example": node("0x1", 1), // another chain
    "https://stuck.example": node("0x8f", 3_600), // Monad, but its head is an hour old
    "https://c.example": node("0x8f", 2),
  };
  const fetchImpl = (url, init) => replies[url](init);
  const now = () => NOW_S * 1000;
  assert.deepEqual(await firstHealthy(Object.keys(replies), { fetchImpl, now }), { url: "https://c.example", healthy: true });
  assert.deepEqual(await firstHealthy(["https://a.example", "https://b.example", "https://stuck.example"], { fetchImpl, now }), { url: "https://a.example", healthy: false }, "none: the first, and the run's stale-head check holds the sends");
});

test("K2 in send mode: the fresh endpoint is read first, and cast sends through it", async () => {
  const seen = {};
  const w = {
    log: () => {},
    env: {},
    pickRpc: async (urls) => ({ url: urls[1], healthy: true }),
    makeClient: (o) => {
      seen.reads = o.rpcUrls;
      return { getBlock: async () => ({ number: 1n, timestamp: 1_790_000_000n }), getCode: async () => "0x60", getBalance: async () => 10n ** 20n, readContract: async () => 0n };
    },
    makeSenderFn: (s) => ((seen.cast = s.rpcUrl), { sent: [], live: true, call: async () => ({}) }),
    signerAddressFn: () => "0x1111111111111111111111111111111111111111",
    now: () => 1_790_000_000_000,
  };
  await runKeeper(parseKeeperArgs(["moments-graduation", "--only-live", "--send", "--account", "k"], {}), w);
  assert.deepEqual(seen, { reads: ["https://rpc4.monad.xyz", "https://rpc3.monad.xyz"], cast: "https://rpc4.monad.xyz" });
});

test("E5: RPC failures collapse into one alert per run: a warning, critical after 3 runs in a row, reset by a clean run", () => {
  const state = {};
  const one = rpcDegradedAlert(state, { failures: 11, skipped: ["cohort4 (live)", "launchpad (live)"], stats: { "https://rpc1.monad.xyz": { failed: 33, served: 20 } } });
  assert.equal(one.severity, "warning");
  assert.equal(one.key, "rpc:degraded");
  assert.match(one.reason, /RPC degraded: 11 read\(s\) failed after retries and fallback \(https:\/\/rpc1\.monad\.xyz failed 33, served 20\); skipped this run: cohort4 \(live\), launchpad \(live\)\. 1 run\(s\) in a row/);
  assert.equal(rpcDegradedAlert(state, { failures: 1 }).severity, "warning");
  assert.equal(rpcDegradedAlert(state, { failures: 1 }).severity, "critical");
  assert.equal(rpcDegradedAlert(state, { failures: 0 }), null);
  assert.equal(state.rpc.degradedRuns, 0);
  assert.equal(rpcDegradedAlert(state, { failures: 2 }).severity, "warning");
});

test("E5: a simulation that fails at the RPC is not read as a revert (no REVERTS page, no failure counted)", async () => {
  const cohort = { label: "cohort4 (live)", factory: "0x00000000000000000000000000000000000000f1", collect: "0x00000000000000000000000000000000000000c1", graduation: "0x0000000000000000000000000000000000000091" };
  const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: 1n }, getMoment: { deadline: 2_000_000_000n } };
  const client = {
    getBlock: async () => ({ timestamp: 1_790_000_000n }),
    readContract: async ({ functionName }) => reads[functionName],
    simulateContract: async () => {
      throw http429();
    },
  };
  const reporter = makeReporter({ log: () => {} });
  const state = {};
  const sender = makeSender({ rpcUrl: "http://x", log: () => {} });
  await momentsGraduationJob({ client, cohorts: [cohort], sender, reporter, state });
  assert.equal(reporter.alerts.length, 1);
  assert.equal(reporter.alerts[0].rpc, true);
  assert.doesNotMatch(reporter.alerts[0].reason, /REVERTS/);
  assert.equal(state[`moment:${cohort.collect}:1`], undefined, "no failure recorded against the Moment");
  assert.equal(sender.sent.length, 0);
});

test("E5: a rate limit on eth_getLogs is not a range cap: the scan does not shrink its chunk, it fails the read", async () => {
  const calls = [];
  const client = {
    async getLogs(req) {
      calls.push(req);
      throw new Error("429 Too Many Requests");
    },
  };
  await assert.rejects(getLogsChunked(client, { from: 0n, to: 999n, chunk: 1000n }), /429/);
  assert.equal(calls.length, 1);
});

test("E5 through a run: every read failing at the RPC posts ONE 'RPC degraded' alert, with each skipped item on stdout", async () => {
  const lines = [];
  const posts = [];
  const client = {
    getCode: async () => {
      throw http429();
    },
    getBlock: async () => {
      throw http429();
    },
    getBlockNumber: async () => {
      throw http429();
    },
    readContract: async () => {
      throw http429();
    },
  };
  const stateFile = join(tempDir("keeper-rpc-"), "state.json");
  const deps = {
    log: (l) => lines.push(l),
    env: {},
    makeClient: () => ({ client, stats: { "https://rpc3.monad.xyz": { failed: 12, served: 0 }, "https://rpc4.monad.xyz": { failed: 12, served: 0 } } }),
    fetchImpl: async (url, init) => (posts.push(JSON.parse(init.body)), { ok: true, status: 204 }),
  };
  const o = parseKeeperArgs(["moments-graduation", "buybacks", "--webhook", "https://hooks.example/x", "--state-file", stateFile], {});
  // K3 dedup on top: run 1 posts the warning, run 2 has nothing new to say, run 3 posts the escalation to critical.
  const perRun = [];
  for (let run = 1; run <= 3; run++) {
    posts.length = 0;
    assert.equal(await runKeeper(o, deps), EXIT.ALERT);
    perRun.push(posts.flatMap((p) => p.alerts.map((x) => `${x.kind} ${x.severity} ${x.target}`)));
  }
  assert.deepEqual(perRun, [["new warning rpc"], [], ["escalated critical rpc"]], "one alert, critical after 3 runs in a row (state file counter)");
  assert.match(posts[0].alerts[0].reason, /RPC degraded: \d+ read\(s\) failed after retries and fallback \(https:\/\/rpc3\.monad\.xyz failed 12, served 0; https:\/\/rpc4\.monad\.xyz failed 12, served 0\); skipped this run: latest block, 143\.json, moments-143\.json, moments-graduation \(the whole job\), buybacks \(the whole job\)/);
  assert.equal(lines.filter((l) => /^ALERT \[critical\] .*HTTP request failed/.test(l)).length, 15, "each skipped item is still in the log (5 per run)");
  assert.ok(!lines.join("\n").includes("FAKE_KEY_123") && !JSON.stringify(posts).includes("FAKE_KEY_123"), "the keyed URL in viem's error never leaks");
});
