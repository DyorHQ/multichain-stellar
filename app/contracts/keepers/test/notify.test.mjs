// Build 17, K3 / E3 and E4: alerts people can live with.
//  E3: stable keys; post when new or escalated; repeat criticals hourly and warnings every 12 h; "resolved" only after a
//      completed job; info never posted; one-off events once.
//  E4: Slack {text}; Discord {content, allowed_mentions:{parse:[]}} in chunks of <= 1,900; Telegram in chunks of
//      <= 4,000; 3 retries; what was not delivered is posted by the next run; --webhook-file; the URL never leaks.
import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { planPosts, commitPosts, webhookKind, buildPayloads, deliver, readWebhookFile, formatItem, REPEAT_DEFAULTS } from "../lib/notify.mjs";
import { momentsGraduationJob, governanceJob } from "../lib/jobs.mjs";
import { makeReporter, EXIT } from "../lib/report.mjs";
import { makeSender } from "../lib/send.mjs";
import { parseKeeperArgs } from "../lib/options.mjs";
import { runKeeper } from "../lib/run.mjs";
import { tempDir } from "./tmp.mjs";

const T0 = 1_790_000_000;
const alert = (key, severity, extra = {}) => ({ key, severity, job: "launchpad-graduation", target: `t ${key}`, reason: `r ${key}`, ...extra });
const done = new Set(["launchpad-graduation", "keeper"]);

/** One run of the notifier with every post delivered; returns the kinds posted. */
function cycle(history, alerts, { now, completed = done, holds, deliveredAll = true } = {}) {
  const items = planPosts({ alerts, completed, holds, history, now });
  commitPosts(history, items, new Set(deliveredAll ? items.map((i) => i.key) : []), now);
  return items.map((i) => `${i.kind}:${i.key}`);
}

// ---------------------------------------------------------------- E3

test("E3: a key is posted when new, then only on its repeat cadence: criticals hourly, warnings every 12 h", () => {
  assert.deepEqual(REPEAT_DEFAULTS, { critical: 3_600, warning: 43_200 });
  const h = {};
  assert.deepEqual(cycle(h, [alert("c", "critical"), alert("w", "warning")], { now: T0 }), ["new:c", "new:w"]);
  assert.deepEqual(cycle(h, [alert("c", "critical"), alert("w", "warning")], { now: T0 + 300 }), [], "5 minutes later: nothing");
  assert.deepEqual(cycle(h, [alert("c", "critical"), alert("w", "warning")], { now: T0 + 3_600 }), ["repeat:c"]);
  assert.deepEqual(cycle(h, [alert("c", "critical"), alert("w", "warning")], { now: T0 + 43_200 }), ["repeat:c", "repeat:w"]);
});

test("E3: a severity rise is posted at once (escalated); a fall is not, and a later rise posts again", () => {
  const h = {};
  cycle(h, [alert("k", "warning")], { now: T0 });
  const items = planPosts({ alerts: [alert("k", "critical")], completed: done, history: h, now: T0 + 60 });
  assert.equal(items[0].kind, "escalated");
  assert.equal(items[0].was, "warning");
  assert.match(formatItem(items[0]), /^\[CRITICAL, was warning\] launchpad-graduation · t k: r k$/);
  commitPosts(h, items, new Set(["k"]), T0 + 60);
  assert.deepEqual(cycle(h, [alert("k", "warning")], { now: T0 + 120 }), [], "quieter: no post");
  assert.deepEqual(cycle(h, [alert("k", "critical")], { now: T0 + 180 }), ["escalated:k"]);
});

test("E3: 'resolved' is posted only when a job that COMPLETED no longer raises the key", () => {
  const h = {};
  cycle(h, [alert("k", "critical")], { now: T0 });
  assert.deepEqual(cycle(h, [], { now: T0 + 60, completed: new Set() }), [], "the job did not finish (a read failed): it may still stand");
  assert.ok(h.k, "still remembered");
  const items = planPosts({ alerts: [], completed: done, history: h, now: T0 + 120 });
  assert.deepEqual(items.map((i) => i.kind), ["resolved"]);
  assert.match(formatItem(items[0]), /^\[resolved, was critical\] launchpad-graduation · t k: r k$/);
  commitPosts(h, items, new Set(["k"]), T0 + 120);
  assert.deepEqual(h, {}, "a delivered resolve forgets the key");
});

test("E3: a condition that clears before it was ever delivered is dropped silently", () => {
  const h = {};
  cycle(h, [alert("k", "warning")], { now: T0, deliveredAll: false });
  assert.deepEqual(cycle(h, [], { now: T0 + 60 }), []);
  assert.deepEqual(h, {});
});

test("E3: info is never posted; RPC-skipped items are left to the one 'RPC degraded' alert", () => {
  const h = {};
  assert.deepEqual(cycle(h, [alert("i", "info"), alert("r", "critical", { rpc: true })], { now: T0 }), []);
  assert.deepEqual(h, {});
});

test("E3: one-off events (a governance log, a failed send) post once, never repeat or resolve, and are forgotten after a week", () => {
  const h = {};
  const ev = alert("gov:event:0xabc:3", "critical", { once: true, job: "governance" });
  assert.deepEqual(cycle(h, [ev], { now: T0 }), ["new:gov:event:0xabc:3"]);
  assert.deepEqual(cycle(h, [ev], { now: T0 + 7_200 }), [], "re-scanned: not posted again, not repeated");
  assert.deepEqual(cycle(h, [], { now: T0 + 7_300, completed: new Set(["governance"]) }), [], "never 'resolved'");
  assert.ok(h["gov:event:0xabc:3"]);
  cycle(h, [], { now: T0 + 7_200 + 8 * 86_400 });
  assert.deepEqual(h, {});
});

test("E3: a one-off event whose post failed is posted by the next run, which no longer raises it; then never again", () => {
  const h = {};
  const ev = alert("gov:event:0xabc:3", "critical", { once: true, job: "governance" });
  assert.deepEqual(cycle(h, [ev], { now: T0, deliveredAll: false }), ["new:gov:event:0xabc:3"]);
  assert.equal(h["gov:event:0xabc:3"].posted, undefined);
  const items = planPosts({ alerts: [], completed: new Set(), history: h, now: T0 + 300 });
  assert.deepEqual(items.map((i) => `${i.kind}:${i.key}:${i.severity}`), ["new:gov:event:0xabc:3:critical"], "posted from its history, even by a run whose job did not complete");
  assert.equal(formatItem(items[0]), "[CRITICAL, raised 2026-09-21T14:13:20Z, not delivered then] governance · t gov:event:0xabc:3: r gov:event:0xabc:3");
  commitPosts(h, items, new Set(), T0 + 300); // still down
  assert.equal(cycle(h, [], { now: T0 + 600 }).length, 1, "and again");
  assert.deepEqual(cycle(h, [], { now: T0 + 900 }), [], "delivered: never again");
  assert.ok(h["gov:event:0xabc:3"].posted);
  // Undelivered for a week: forgotten (the run's exit code and the keeper log have said so all week).
  const lost = {};
  cycle(lost, [ev], { now: T0, deliveredAll: false });
  assert.deepEqual(cycle(lost, [], { now: T0 + 8 * 86_400, deliveredAll: false }), []);
  assert.deepEqual(lost, {});
});

test("E3 through the governance scan: an event found while the webhook was down is posted when it is back", async () => {
  const fac = "0x00000000000000000000000000000000000000f4";
  const cohort = { label: "cohort4 (live)", factory: fac, live: false, governance: fac };
  const reads = { governance: fac, pendingGovernance: "0x0000000000000000000000000000000000000000", pendingPolicyAt: 0n, publishingPaused: true };
  const event = { address: fac, eventName: "PolicyProposed", blockNumber: 1_500n, transactionHash: `0x${"ee".repeat(32)}`, logIndex: 4 };
  const client = (head) => ({
    getBlock: async () => ({ timestamp: 1_790_000_000n }),
    getBlockNumber: async () => head,
    readContract: async ({ functionName }) => reads[functionName],
    getLogs: async ({ fromBlock, toBlock }) => (fromBlock <= event.blockNumber && event.blockNumber <= toBlock ? [event] : []),
  });
  const state = { cursors: { "gov:moments": "1000" } };
  const history = {};
  const run = async (head, now, delivered) => {
    const reporter = makeReporter({ log: () => {} });
    await governanceJob({ client: client(head), launchpads: [], cohorts: [cohort], reporter, state, expected: { momentsGovernance: fac }, logsCursor: true });
    return cycle(history, reporter.alerts, { now, completed: new Set(["governance"]), deliveredAll: delivered });
  };
  const key = `gov:event:${event.transactionHash}:4`;
  assert.deepEqual(await run(2_000n, T0, false), [`new:${key}`], "found; Discord is down");
  assert.ok(BigInt(state.cursors["gov:moments"]) >= 1_500n, "the cursor moved past the event");
  assert.deepEqual(await run(3_000n, T0 + 900, true), [`new:${key}`], "not raised again, but posted");
  assert.deepEqual(await run(4_000n, T0 + 1_800, true), []);
});

test("E3: a held key (a throttled condition confirmed again) is not taken as resolved", () => {
  const h = {};
  cycle(h, [alert("gov:unfrozen:0xf", "warning", { job: "governance" })], { now: T0 });
  assert.deepEqual(cycle(h, [], { now: T0 + 900, completed: new Set(["governance"]), holds: new Set(["gov:unfrozen:0xf"]) }), []);
  assert.ok(h["gov:unfrozen:0xf"]);
});

test("E3: undelivered posts are posted again by the next run (new stays new; resolved stays pending)", () => {
  const h = {};
  cycle(h, [alert("k", "critical")], { now: T0, deliveredAll: false });
  assert.deepEqual(cycle(h, [alert("k", "critical")], { now: T0 + 300 }), ["new:k"]);
  cycle(h, [], { now: T0 + 600, deliveredAll: false });
  assert.equal(h.k.resolving, true);
  assert.deepEqual(cycle(h, [], { now: T0 + 900 }), ["resolved:k"]);
  assert.deepEqual(h, {});
});

test("E3: the most urgent lines come first", () => {
  const h = {};
  cycle(h, [alert("old", "critical"), alert("gone", "warning")], { now: T0 });
  const items = planPosts({ alerts: [alert("w", "warning"), alert("old", "critical"), alert("c", "critical")], completed: done, history: h, now: T0 + 3_600 });
  assert.deepEqual(items.map((i) => `${i.kind}:${i.key}`), ["new:c", "new:w", "repeat:old", "resolved:gone"]);
});

// A pending Moment's reason carries its seconds left, which change every run; its key does not.
test("E3: a standing condition whose wording changes every run keeps one key and is not re-posted", async () => {
  const cohort = { label: "cohort4 (live)", factory: "0x00000000000000000000000000000000000000f1", collect: "0x00000000000000000000000000000000000000c1", graduation: "0x0000000000000000000000000000000000000091" };
  const runAt = async (ts) => {
    const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: 1_790_000_000n }, getMoment: { deadline: 1_791_000_000n } };
    const client = { getBlock: async () => ({ timestamp: ts }), readContract: async ({ functionName }) => reads[functionName], simulateContract: async () => ({ result: null }) };
    const reporter = makeReporter({ log: () => {} });
    await momentsGraduationJob({ client, cohorts: [cohort], sender: makeSender({ rpcUrl: "http://x", log: () => {} }), reporter, state: {} });
    return reporter.alerts;
  };
  const [a1] = await runAt(1_790_000_000n);
  const [a2] = await runAt(1_790_000_300n);
  assert.notEqual(a1.reason, a2.reason);
  assert.equal(a1.key, a2.key);
  assert.equal(a1.key, `mo1:pending:${cohort.collect}:1`);
  const h = {};
  assert.equal(cycle(h, [a1], { now: T0 }).length, 1);
  assert.deepEqual(cycle(h, [a2], { now: T0 + 300 }), []);
});

test("E3: the once-a-day unfrozen-factory warning is held between its days, so it never flaps to 'resolved'", async () => {
  const pad = { label: "launchpad (live)", factory: "0x00000000000000000000000000000000000000fa", live: true };
  const reads = { owner: "0x0000000000000000000000000000000000000006", pendingOwner: "0x0000000000000000000000000000000000000000", protocolFeeRecipient: "0x0000000000000000000000000000000000000007", launchCount: 0n };
  const client = {
    getBlock: async () => ({ timestamp: 1_790_000_000n }),
    readContract: async ({ functionName }) => {
      if (functionName in reads) return reads[functionName];
      if (functionName === "modulesSealed") return false;
      return "0x0000000000000000000000000000000000000000";
    },
  };
  const expected = { owner: reads.owner, treasury: reads.protocolFeeRecipient };
  const state = {};
  const history = {};
  for (const [n, now] of [[1, T0], [2, T0 + 900]]) {
    const reporter = makeReporter({ log: () => {} });
    await governanceJob({ client, launchpads: [pad], cohorts: [], reporter, state, expected });
    const kinds = cycle(history, reporter.alerts, { now, completed: new Set(["governance"]), holds: reporter.holds });
    assert.deepEqual(kinds, n === 1 ? [`new:gov:unfrozen:${pad.factory}`] : [], `run ${n}`);
  }
});

// Every alert needs a stable key, or the notifier falls back to job:target and two conditions on one target collide.
test("E3: every alert raised in the keeper code names its key", () => {
  const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "lib");
  for (const file of ["jobs.mjs", "run.mjs"]) {
    const src = readFileSync(join(dir, file), "utf8");
    const calls = [...src.matchAll(/reporter\.alert\(\{/g)];
    assert.ok(calls.length > 5, file);
    for (const m of calls) {
      const stmt = src.slice(m.index, src.indexOf("});", m.index));
      assert.match(stmt, /\bkey\b/, `${file}: ${stmt.slice(0, 120)}`);
    }
  }
  const jobs = readFileSync(join(dir, "jobs.mjs"), "utf8");
  for (const m of jobs.matchAll(/\bcritical\((?!target, reason, key)([^;]*)\);/g)) {
    assert.match(m[1], /, `[a-zA-Z-]+:\$\{/, `governance critical() without a key: ${m[1].slice(0, 100)}`);
  }
});

// ---------------------------------------------------------------- E4

test("E4: the payload is chosen from the webhook host", () => {
  assert.equal(webhookKind("https://hooks.slack.com/services/T/B/X"), "slack");
  assert.equal(webhookKind("https://discord.com/api/webhooks/1/tok"), "discord");
  assert.equal(webhookKind("https://discordapp.com/api/webhooks/1/tok"), "discord");
  assert.equal(webhookKind("https://discord.com/api/webhooks/1/tok/slack"), "discord-slack");
  assert.equal(webhookKind("https://api.telegram.org/bot123:abc/sendMessage"), "telegram");
  assert.equal(webhookKind("https://hooks.example/x"), "generic");
  assert.equal(webhookKind("not a url"), "generic");
});

const many = (n, severity = "warning") =>
  Array.from({ length: n }, (_, i) => ({ key: `k${i}`, kind: "new", severity, job: "governance", target: `target ${i}`, reason: `${"x".repeat(150)} #${i} @everyone`, firstSeen: T0 }));

test("E4: Discord gets {content, allowed_mentions:{parse:[]}} in chunks of at most 1,900 characters, in order", () => {
  const items = many(40);
  const payloads = buildPayloads({ kind: "discord", items, title: "DyorHQ keeper (governance)" });
  assert.ok(payloads.length >= 4);
  for (const p of payloads) {
    assert.deepEqual(Object.keys(p.body).sort(), ["allowed_mentions", "content"]);
    assert.deepEqual(p.body.allowed_mentions, { parse: [] }, "an @everyone in a reason pings nobody");
    assert.ok(p.body.content.length <= 1_900, String(p.body.content.length));
  }
  assert.match(payloads[0].body.content, /^DyorHQ keeper \(governance\): 40 new \(1\/\d+\)\n/);
  assert.deepEqual(payloads.flatMap((p) => p.keys), items.map((i) => i.key), "every line, once, in order");
  const one = buildPayloads({ kind: "discord", items: [{ ...items[0], reason: "y".repeat(5_000) }], title: "t" });
  assert.equal(one.length, 1);
  assert.ok(one[0].body.content.length <= 1_900, "an over-long line is cut, not sent whole");
});

test("E4: Telegram gets chat_id and chunks of at most 4,000; warnings arrive silently, criticals loud", () => {
  const warn = buildPayloads({ kind: "telegram", items: many(60), title: "t", chatId: "-100123" });
  assert.ok(warn.length >= 2);
  for (const p of warn) {
    assert.equal(p.body.chat_id, "-100123");
    assert.ok(p.body.text.length <= 4_000);
    assert.equal(p.body.disable_notification, true);
  }
  const crit = buildPayloads({ kind: "telegram", items: many(2, "critical"), title: "t", chatId: "1" });
  assert.equal(crit[0].body.disable_notification, false);
  const resolved = buildPayloads({ kind: "telegram", items: [{ key: "k", kind: "resolved", severity: "resolved", was: "critical", job: "j", target: "t", reason: "r" }], title: "t", chatId: "1" });
  assert.equal(resolved[0].body.disable_notification, true, "a resolve is good news: silent");
});

test("E4: Slack (and Discord's /slack URL) get {text}; any other host the original {text, alerts}", () => {
  assert.deepEqual(Object.keys(buildPayloads({ kind: "slack", items: many(1), title: "t" })[0].body), ["text"]);
  assert.deepEqual(Object.keys(buildPayloads({ kind: "discord-slack", items: many(1), title: "t" })[0].body), ["text"]);
  const g = buildPayloads({ kind: "generic", items: many(30), title: "t" });
  assert.equal(g.length, 1, "no size limit is known for a generic receiver");
  assert.deepEqual(Object.keys(g[0].body).sort(), ["alerts", "text"]);
  assert.deepEqual(Object.keys(g[0].body.alerts[0]).sort(), ["job", "key", "kind", "reason", "severity", "target"]);
});

const DISCORD = "https://discord.com/api/webhooks/123/SECRET_WEBHOOK_TOKEN";
function fakeFetch(statuses) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
    const s = statuses.shift() ?? 204;
    if (s instanceof Error) throw s;
    return { ok: s >= 200 && s < 300, status: s, headers: { get: () => null }, json: async () => (s === 429 ? { retry_after: 2.5 } : {}) };
  };
  fn.calls = calls;
  return fn;
}

test("E4: a POST is retried 3 times with backoff; a 429's retry_after is honoured", async () => {
  const waits = [];
  const f = fakeFetch([500, 429, Object.assign(new TypeError("fetch failed"), { cause: { code: "ECONNRESET" } }), 204]);
  const r = await deliver(DISCORD, [{ body: { content: "x" }, keys: ["a"] }], { fetchImpl: f, sleep: async (ms) => waits.push(ms) });
  assert.equal(r.error, undefined);
  assert.deepEqual([...r.delivered], ["a"]);
  assert.equal(f.calls.length, 4, "1 + 3 retries");
  assert.deepEqual(waits, [1_000, 2_500, 4_000]);
});

test("E4: a failed delivery names the channel and status, never the URL or its token; later chunks are not sent", async () => {
  const f = fakeFetch([204, 500, 500, 500, 500]);
  const r = await deliver(DISCORD, [{ body: { content: "1" }, keys: ["a"] }, { body: { content: "2" }, keys: ["b"] }, { body: { content: "3" }, keys: ["c"] }], { fetchImpl: f, sleep: async () => {} });
  assert.deepEqual([...r.delivered], ["a"]);
  assert.equal(r.error, "discord webhook POST 2/3 to https://discord.com failed: HTTP 500");
  assert.equal(f.calls.length, 5);
  const bad = await deliver(DISCORD, [{ body: {}, keys: ["a"] }], { fetchImpl: fakeFetch([404]), sleep: async () => {} });
  assert.match(bad.error, /HTTP 404$/, "a bad URL is not retried");
  assert.ok(!JSON.stringify([r, bad]).includes("SECRET_WEBHOOK_TOKEN"));
});

test("E4: --webhook-file holds the URL; its content is never echoed", () => {
  const dir = tempDir("keeper-hook-");
  writeFileSync(join(dir, "hook"), `\n  ${DISCORD}  \n`, { mode: 0o600 });
  assert.equal(readWebhookFile(join(dir, "hook")), DISCORD);
  writeFileSync(join(dir, "junk"), "SECRET_WEBHOOK_TOKEN not a url");
  assert.throws(() => readWebhookFile(join(dir, "junk")), (e) => /does not hold an http\(s\) URL/.test(e.message) && !e.message.includes("SECRET"));
  assert.throws(() => readWebhookFile(join(dir, "missing")), /cannot read --webhook-file \(ENOENT\)/);
  assert.throws(() => parseKeeperArgs(["governance", "--webhook", DISCORD, "--webhook-file", join(dir, "hook")], {}), /not both/);
  const o = parseKeeperArgs(["governance", "--webhook-file", join(dir, "hook")], { KEEPER_WEBHOOK_URL: "https://env.example/x" });
  assert.equal(o.webhook, undefined, "--webhook-file wins over the environment");
  assert.equal(o.webhookFile, join(dir, "hook"));
});

// ---------------------------------------------------------------- through a run

function pendingChain() {
  const reads = { momentCount: 1n, state: 1, ledger: { stuckSince: 1_790_000_000n }, getMoment: { deadline: 1_791_000_000n } };
  return {
    getCode: async () => "0x60",
    getBalance: async () => 10n ** 20n,
    getBlock: async () => ({ timestamp: 1_790_000_000n }),
    getBlockNumber: async () => 1_000n,
    readContract: async ({ functionName }) => {
      if (functionName in reads) return reads[functionName];
      throw new Error("execution reverted");
    },
    simulateContract: async () => {
      throw new Error("execution reverted: NotPending");
    },
  };
}

test("E4 through a run: the Discord URL comes from --webhook-file, a failed post exits 1, and the next run posts it again", async () => {
  const dir = tempDir("keeper-run-hook-");
  writeFileSync(join(dir, "hook"), DISCORD, { mode: 0o600 });
  const stateFile = join(dir, "state.json");
  const lines = [];
  let up = false;
  const posts = [];
  const deps = {
    log: (l) => lines.push(l),
    env: {},
    makeClient: () => pendingChain(),
    fetchImpl: async (url, init) => {
      posts.push({ url, body: JSON.parse(init.body) });
      return { ok: up, status: up ? 204 : 503, headers: { get: () => null }, json: async () => ({}) };
    },
  };
  const o = parseKeeperArgs(["moments-graduation", "--only-live", "--webhook-file", join(dir, "hook"), "--state-file", stateFile], {});
  assert.equal(await runKeeper(o, deps), EXIT.ERROR, "alerts not delivered: the keeper failed");
  assert.equal(posts.length, 4, "1 + 3 retries");
  assert.equal(posts[0].url, DISCORD);
  assert.ok(lines.some((l) => /alerts NOT delivered \(discord webhook POST 1\/1 to https:\/\/discord\.com failed: HTTP 503\)/.test(l)));
  assert.ok(!lines.join("\n").includes("SECRET_WEBHOOK_TOKEN"), "the token never reaches stdout");
  const saved = JSON.parse(readFileSync(stateFile, "utf8"));
  assert.equal(saved.notify.keys["mo1:pending:0x95eb7f5a88b10d9df32ac54f48c767927fa80840:1"]?.posted, undefined, "left unposted");
  up = true;
  posts.length = 0;
  assert.equal(await runKeeper(o, deps), EXIT.ALERT);
  assert.equal(posts.length, 1);
  assert.deepEqual(Object.keys(posts[0].body).sort(), ["allowed_mentions", "content"]);
  assert.match(posts[0].body.content, /\[CRITICAL\] moments-graduation · cohort4 \(live\) moment #1: GraduationPending and the graduate\(\) retry REVERTS/);
  posts.length = 0;
  assert.equal(await runKeeper(o, deps), EXIT.ALERT, "still alerting on stdout and by exit code");
  assert.equal(posts.length, 0, "but nothing new to post");
});

test("E4: a Telegram webhook without KEEPER_TELEGRAM_CHAT_ID refuses to run", async () => {
  const o = parseKeeperArgs(["governance", "--webhook", "https://api.telegram.org/bot1:x/sendMessage"], {});
  await assert.rejects(runKeeper(o, { log: () => {}, env: {}, makeClient: () => pendingChain() }), /KEEPER_TELEGRAM_CHAT_ID/);
});
