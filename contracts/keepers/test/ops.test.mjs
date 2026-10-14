// Build 17, K4 (the Fly.io ops kit, contracts/keepers/ops): the scripts run with stub `node`, `curl`, `flock`, `cast`,
// `fly`, `setpriv`, `mount` and friends (no network beyond 127.0.0.1, no Fly account, no real key), and the static
// files are checked for what the owner decisions need:
//  - run-keeper.sh: each unit's flags; every scheduled run is a dry run unless the unit's own flag is 1 and its key is
//    usable and pinned (else a dry run that fails loudly); never --only-live; healthchecks.io /start, success on keeper
//    exit 0 or 2, /fail otherwise, with the URL only on curl's stdin and never in the output; the manual one-shot
//    (grad-now.sh) pings nothing and may send while the flag is off;
//  - entrypoint.sh: refuses without its volume; writes the Fly secrets to the secrets tmpfs (0400) without printing
//    one; never hands a secret to a keeper process's environment; a forbidden key is removed, an unpinned one never
//    sends;
//  - the crontab, fly.toml (no services, one volume, restart always) and keeper.env.example (names only);
//  - check-signers.mjs (each unit its own key; never a custody, protocol or Safe-signer key; the pinned address; the
//    funding minimums);
//  - bundle.sh and deploy-fly.sh (a reviewed commit only, the manifest must match, --check-only calls no Fly);
//  - make-keeper-secrets.sh (keystores and URLs reach `fly secrets import` on stdin, nothing secret is printed, the
//    temporary folder is gone afterwards; --print-commands runs nothing).
// Opt-in (KEEPER_ANVIL=1): check-signers on real cast keystores against a local anvil, and run-keeper.sh driving the
// real keeper on a local fork when KEEPER_ANVIL_FORK_URL is set (KEEPER_ANVIL_OPS_PORT picks the port, default 8813).
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { appendFileSync, chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkSigners, deriveFromKeystores, fundingNote, main as checkSignersMain, parseUnits, readPins, readRecords, roleAddresses } from "../ops/check-signers.mjs";

const OPS = join(dirname(fileURLToPath(import.meta.url)), "..", "ops");
const KEEPERS = dirname(OPS);
const REPO = join(KEEPERS, "..", "..");
const HC = "https://hc-ping.example/00000000-test-ping-path";
const HOOK = "https://discord.example/api/webhooks/0/test-token-path";
const ADDR = "0x1234567890abcdef1234567890ABCDEF12345678";
const GUARDIAN = "0x686C7A2886608082e698E0062EA3E4C408d43845";
const SAFE = "0x6D2A4D821e57b2B918B97CF575D81738bc16C100";
const has = (bin) => spawnSync("sh", ["-c", `command -v ${bin}`]).status === 0;
const MON = 10n ** 18n;

// Every temporary folder (some hold fake secrets) is removed when the file's tests end.
const temps = [];
const tmp = (prefix) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  temps.push(d);
  return d;
};
after(() => {
  for (const d of temps) rmSync(d, { recursive: true, force: true });
});

function putExe(bin, name, body, shell = "/bin/sh") {
  writeFileSync(join(bin, name), `#!${shell}\n${body}\n`);
  chmodSync(join(bin, name), 0o755);
}

function stubs(dir) {
  const bin = join(dir, "bin");
  mkdirSync(bin, { recursive: true });
  putExe(bin, "flock", "exit 0");
  // grad-now.sh asks `id -u`: these runs are never root, so it never switches users (the image's entrypoint test does).
  putExe(bin, "id", 'if [ "$1" = "-u" ]; then echo 501; else /usr/bin/id "$@"; fi');
  // Records its arguments and what it read on stdin (the -K - config).
  putExe(bin, "curl", 'printf "ARGS %s\\n" "$*" >> "$CURL_LOG"; while IFS= read -r l; do printf "STDIN %s\\n" "$l" >> "$CURL_LOG"; done; exit 0');
  // Records its arguments, and the RPC list it was handed through its environment.
  putExe(bin, "fake-node", 'for a in "$@"; do printf "%s\\n" "$a"; done > "$FAKE_ARGS"; printf "%s" "${KEEPER_RPC_URLS-<unset>}" > "$FAKE_RPC"; echo "keeper output line"; exit "${FAKE_EXIT:-0}"');
  return bin;
}

// One set of stubs for every run: a new executable is slow to start the first time on macOS.
const STUBS = stubs(tmp("keeper-ops-bin-"));

function unitEnv(over = {}) {
  const dir = tmp("keeper-ops-");
  const secrets = join(dir, "secrets");
  const data = join(dir, "data");
  mkdirSync(secrets);
  mkdirSync(data);
  const bin = STUBS;
  const env = {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: dir,
    KEEPER_SECRETS_DIR: secrets,
    KEEPER_DATA_DIR: data,
    KEEPER_NODE: join(bin, "fake-node"),
    KEEPER_MJS: "/nonexistent/keeper.mjs",
    FAKE_ARGS: join(dir, "args"),
    FAKE_RPC: join(dir, "rpc"),
    CURL_LOG: join(dir, "curl.log"),
    ...over,
  };
  return { dir, secrets, data, env };
}

function runScript(script, ctx, argv) {
  const r = spawnSync("bash", [join(OPS, script), ...argv], { env: ctx.env, encoding: "utf8" });
  const args = existsSync(ctx.env.FAKE_ARGS) ? readFileSync(ctx.env.FAKE_ARGS, "utf8").trim().split("\n") : null;
  const curl = existsSync(ctx.env.CURL_LOG) ? readFileSync(ctx.env.CURL_LOG, "utf8") : "";
  const rpc = existsSync(ctx.env.FAKE_RPC) ? readFileSync(ctx.env.FAKE_RPC, "utf8") : null;
  return { code: r.status, out: `${r.stdout}${r.stderr}`, args, curl, rpc };
}
const runUnit = (ctx, argv) => runScript("run-keeper.sh", ctx, argv);

/** A usable keystore for `unit` as entrypoint.sh leaves it, on the Machine KEEPER_MACHINE_ID names (`machine`). */
function signer(ctx, unit = "grad", { machine = true } = {}) {
  writeFileSync(join(ctx.secrets, `${unit}.keystore`), '{"crypto":{}}');
  writeFileSync(join(ctx.secrets, `${unit}.password`), "pw");
  writeFileSync(join(ctx.secrets, `${unit}.address`), `${ADDR}\n`);
  if (machine) writeFileSync(join(ctx.secrets, "machine.ok"), "machine-test-1\n");
}
const pings = (curl) => curl.split("\n").filter((l) => l.startsWith("STDIN url")).map((l) => l.slice(`STDIN url = "${HC}`.length, -1));
const argAfter = (args, flag) => args[args.indexOf(flag) + 1];

/** The unit table of run-keeper.sh: { unit: { jobs, flag, min_balance, cap, runtime, extra } }. */
function unitTable() {
  const src = readFileSync(join(OPS, "run-keeper.sh"), "utf8");
  const table = {};
  for (const m of src.matchAll(/^\s+(grad|sweeps|buybacks|governance)\) (.+) ;;$/gm)) {
    const row = {};
    for (const a of m[2].matchAll(/(\w+)=(\([^)]*\)|[^;\s]+)/g)) row[a[1]] = a[2];
    table[m[1]] = row;
  }
  return table;
}

// ---------------------------------------------------------------- the shell scripts as a whole

test("every ops shell script parses, never sets -x, and no unit can pass --only-live", () => {
  for (const f of readdirSync(OPS).filter((f) => f.endsWith(".sh"))) {
    const src = readFileSync(join(OPS, f), "utf8");
    const r = spawnSync("bash", ["-n", join(OPS, f)], { encoding: "utf8" });
    assert.equal(r.status, 0, `${f}: ${r.stderr}`);
    assert.ok(statSync(join(OPS, f)).mode & 0o100, `${f} is executable (supercronic and the owner run it directly)`);
    assert.ok(src.startsWith("#!/bin/bash\n"), `${f} runs under bash`);
    assert.doesNotMatch(src, /^\s*set\s+-[a-z]*x/m, `${f} must never set -x`);
    assert.doesNotMatch(src, /^\s*set\s+-o\s+xtrace/m, `${f} must never trace`);
    const code = src.split("\n").filter((l) => !l.trim().startsWith("#")).join("\n");
    assert.doesNotMatch(code, /--only-live/, `${f} must never pass --only-live (retired stacks keep their holders)`);
  }
  // The healthchecks pings discard curl's output (-o /dev/null) and read the URL from stdin (-K -).
  assert.match(readFileSync(join(OPS, "run-keeper.sh"), "utf8"), /curl -fsS -m 10 --retry 3 [^\n]*-o \/dev\/null -K -/);
});

// ---------------------------------------------------------------- run-keeper.sh

test("grad dry run with no secrets: the plan's flags, no send, no signer, no pings", () => {
  const ctx = unitEnv();
  const r = runUnit(ctx, ["grad"]);
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(r.args.slice(0, 3), ["/nonexistent/keeper.mjs", "moments-graduation", "launchpad-graduation"]);
  assert.equal(argAfter(r.args, "--state-file"), join(ctx.data, "state-grad.json"));
  assert.equal(argAfter(r.args, "--max-runtime"), "240");
  assert.equal(argAfter(r.args, "--min-balance"), "10");
  assert.equal(argAfter(r.args, "--max-spend-per-day"), "20");
  assert.ok(!r.args.includes("--rpc-url"), "the RPC list never goes on the command line");
  assert.equal(r.rpc, "https://rpc3.monad.xyz https://rpc4.monad.xyz", "rpc3 then rpc4, through the environment");
  assert.ok(r.args.includes("--logs-cursor"));
  for (const f of ["--send", "--sim-from", "--keystore", "--webhook-file", "--only-live"]) assert.ok(!r.args.includes(f), f);
  assert.equal(r.curl, "");
  assert.match(r.out, /\[grad\] keeper output line/);
  assert.match(r.out, /dry run \(no signer\)/);
});

test("each unit gets its own funding floor, spend cap, deadline and scan start, and is a dry run by default", () => {
  const want = {
    sweeps: { jobs: ["sweeps"], min: "1", cap: "3", runtime: "240" },
    buybacks: { jobs: ["buybacks"], min: "3", cap: "10", runtime: "240" },
    governance: { jobs: ["governance"], min: undefined, cap: undefined, runtime: "600" },
  };
  for (const [unit, w] of Object.entries(want)) {
    const ctx = unitEnv({ KEEPER_SEND_GRAD: "1", KEEPER_SEND_SWEEPS: "0", KEEPER_SEND_BUYBACKS: "0" });
    signer(ctx, unit);
    const r = runUnit(ctx, [unit]);
    assert.equal(r.code, 0, `${unit}: ${r.out}`);
    assert.deepEqual(r.args.slice(1, 1 + w.jobs.length), w.jobs);
    assert.equal(r.args.includes("--min-balance") ? argAfter(r.args, "--min-balance") : undefined, w.min, unit);
    assert.equal(r.args.includes("--max-spend-per-day") ? argAfter(r.args, "--max-spend-per-day") : undefined, w.cap, unit);
    assert.equal(argAfter(r.args, "--max-runtime"), w.runtime, unit);
    assert.equal(argAfter(r.args, "--state-file"), join(ctx.data, `state-${unit}.json`));
    for (const f of ["--send", "--keystore", "--password-file", "--only-live"]) assert.ok(!r.args.includes(f), `${unit} ${f}`);
  }
  const gov = runUnit(unitEnv(), ["governance"]);
  assert.equal(argAfter(gov.args, "--logs-from"), "108860011");
  assert.ok(gov.args.includes("--logs-cursor"));
});

test("the unit table matches keeper-signers.json: minimums 10 / 3 / 1 MON, daily caps 20 / 10 / 3, funding 30 / 10 / 5", () => {
  const table = unitTable();
  const json = JSON.parse(readFileSync(join(OPS, "keeper-signers.json"), "utf8"));
  assert.deepEqual(Object.keys(json.units).sort(), ["buybacks", "grad", "sweeps"]);
  for (const [unit, u] of Object.entries(json.units)) {
    assert.equal(table[unit].min_balance, u.minBalance, unit);
    assert.equal(table[unit].cap, u.maxSpendPerDay, unit);
    assert.equal(table[unit].flag, `KEEPER_SEND_${unit.toUpperCase()}`);
    assert.ok(Number(table[unit].runtime) <= 240, `${unit}: a signing run fits fly.toml's kill_timeout`);
  }
  assert.deepEqual(Object.fromEntries(Object.entries(json.units).map(([u, x]) => [u, [x.fund, x.minBalance, x.maxSpendPerDay]])), {
    grad: ["30", "10", "20"],
    buybacks: ["10", "3", "10"],
    sweeps: ["5", "1", "3"],
  });
  assert.equal(table.governance.flag, undefined, "governance has no send flag");
});

test("dry run with a keystore simulates as the keeper address; exit 2 is a success ping; no URL is printed", () => {
  const ctx = unitEnv({ FAKE_EXIT: "2" });
  signer(ctx);
  writeFileSync(join(ctx.secrets, "hc-grad"), `${HC}\n`);
  writeFileSync(join(ctx.secrets, "webhook"), `${HOOK}\n`);
  const r = runUnit(ctx, ["grad"]);
  assert.equal(r.code, 0, r.out);
  assert.equal(argAfter(r.args, "--sim-from"), ADDR);
  assert.equal(argAfter(r.args, "--webhook-file"), join(ctx.secrets, "webhook"));
  assert.ok(!r.args.includes("--send"));
  assert.deepEqual(pings(r.curl), ["/start", ""]);
  // The URL reaches curl only on stdin (-K -), never as an argument, and never in the log.
  assert.ok(r.curl.split("\n").filter((l) => l.startsWith("ARGS")).every((l) => l.includes("-K -") && l.includes("-o /dev/null") && !l.includes("hc-ping")));
  assert.ok(!r.out.includes("hc-ping") && !r.out.includes("test-token"), r.out);
});

test("keeper exit codes map to healthchecks.io: 0 and 2 ping success, 1 and anything else ping /fail", () => {
  const seen = {};
  for (const exit of ["0", "2", "1", "3", "137"]) {
    const ctx = unitEnv({ FAKE_EXIT: exit });
    writeFileSync(join(ctx.secrets, "hc-governance"), HC);
    const r = runUnit(ctx, ["governance"]);
    seen[exit] = [r.code, pings(r.curl).join(" ")];
  }
  assert.deepEqual(seen, { 0: [0, "/start "], 2: [0, "/start "], 1: [1, "/start /fail"], 3: [1, "/start /fail"], 137: [1, "/start /fail"] });
});

test("the unit's flag at 1 with a usable, pinned keystore sends through that keystore", () => {
  const ctx = unitEnv({ KEEPER_SEND_GRAD: "1" });
  signer(ctx);
  const r = runUnit(ctx, ["grad"]);
  assert.equal(r.code, 0, r.out);
  assert.ok(r.args.includes("--send"));
  assert.equal(argAfter(r.args, "--keystore"), join(ctx.secrets, "grad.keystore"));
  assert.equal(argAfter(r.args, "--password-file"), join(ctx.secrets, "grad.password"));
  assert.equal(argAfter(r.args, "--sim-from"), ADDR);
  assert.match(r.out, new RegExp(`SEND from ${ADDR}`));
  // Another unit's flag never enables this one.
  const other = unitEnv({ KEEPER_SEND_SWEEPS: "1" });
  signer(other, "grad");
  assert.ok(!runUnit(other, ["grad"]).args.includes("--send"));
});

test("sending asked for when the unit may not: a dry run, then a failed run that pages", () => {
  const ctx = unitEnv({ KEEPER_SEND_BUYBACKS: "1" });
  writeFileSync(join(ctx.secrets, "hc-buybacks"), HC);
  const r = runUnit(ctx, ["buybacks"]);
  assert.equal(r.code, 1);
  assert.ok(!r.args.includes("--send"));
  assert.deepEqual(pings(r.curl), ["/start", "/fail"]);
  assert.match(r.out, /sending is on but the buybacks keystore is not usable/);

  const marked = unitEnv({ KEEPER_SEND_GRAD: "1" });
  signer(marked);
  writeFileSync(join(marked.secrets, "grad.error"), "0xabc is a custody or protocol address\n");
  const m = runUnit(marked, ["grad"]);
  assert.equal(m.code, 1);
  assert.ok(!m.args.includes("--send") && !m.args.includes("--sim-from"));
  assert.match(m.out, /custody or protocol address/);

  // Not pinned in keeper-signers.json: dry runs as its address, never a send.
  const unpinned = unitEnv({ KEEPER_SEND_GRAD: "1" });
  signer(unpinned);
  writeFileSync(join(unpinned.secrets, "grad.nosend"), "keeper-signers.json pins no grad address yet\n");
  const u = runUnit(unpinned, ["grad"]);
  assert.equal(u.code, 1);
  assert.ok(!u.args.includes("--send") && !u.args.includes("--keystore"));
  assert.equal(argAfter(u.args, "--sim-from"), ADDR);
  assert.match(u.out, /the grad key may not send \(keeper-signers.json pins no grad address yet\): ran dry/);
  // With the flag off the same unit is a plain, successful dry run.
  delete unpinned.env.KEEPER_SEND_GRAD;
  assert.equal(runUnit(unpinned, ["grad"]).code, 0);
});

test("only the Machine KEEPER_MACHINE_ID names sends: on any other one a send flag at 1 runs dry and fails the run", () => {
  const ctx = unitEnv({ KEEPER_SEND_GRAD: "1", FLY_MACHINE_ID: "machine-test-2" });
  signer(ctx, "grad", { machine: false });
  writeFileSync(join(ctx.secrets, "hc-grad"), HC);
  const r = runUnit(ctx, ["grad"]);
  assert.equal(r.code, 1);
  assert.ok(!r.args.includes("--send") && !r.args.includes("--keystore"));
  assert.equal(argAfter(r.args, "--sim-from"), ADDR, "a dry run as its address");
  assert.match(r.out, /the grad key may not send \(this is not the keeper Machine KEEPER_MACHINE_ID names \(machine-test-2\)\): ran dry/);
  assert.deepEqual(pings(r.curl), ["/start", "/fail"]);
  const manual = runScript("grad-now.sh", ctx, ["--send"]);
  assert.equal(manual.code, 1, "not by hand either");
  assert.ok(!manual.args.includes("--send"));
  delete ctx.env.KEEPER_SEND_GRAD;
  assert.equal(runUnit(ctx, ["grad"]).code, 0, "with the flag off it is a plain dry run");
});

test("a malformed flag fails the run and pings /fail; a non-https ping URL is not used", () => {
  const bad = unitEnv({ KEEPER_SEND_SWEEPS: "yes" });
  writeFileSync(join(bad.secrets, "hc-sweeps"), HC);
  const b = runUnit(bad, ["sweeps"]);
  assert.equal(b.code, 1);
  assert.ok(!b.args.includes("--send"));
  assert.match(b.out, /KEEPER_SEND_SWEEPS must be 0 or 1/);
  assert.deepEqual(pings(b.curl), ["/start", "/fail"]);

  const notHttps = unitEnv();
  writeFileSync(join(notHttps.secrets, "hc-grad"), "http://hc-ping.example/x");
  const n = runUnit(notHttps, ["grad"]);
  assert.equal(n.code, 0);
  assert.equal(n.curl, "");
  assert.ok(!n.out.includes("hc-ping.example/x"));
});

test("the manual one-shot pings nothing, runs dry unless --send, and --send sends while the flag is off", () => {
  const ctx = unitEnv({ KEEPER_SEND_GRAD: "0" });
  signer(ctx);
  writeFileSync(join(ctx.secrets, "hc-grad"), HC);
  const dry = runUnit(ctx, ["grad", "--manual"]);
  assert.equal(dry.code, 0, dry.out);
  assert.ok(!dry.args.includes("--send"));
  const sent = runUnit(ctx, ["grad", "--manual", "--send"]);
  assert.equal(sent.code, 0, sent.out);
  assert.ok(sent.args.includes("--send"));
  assert.equal(sent.curl, "");
  // Flag on, manual dry run: still dry.
  const on = unitEnv({ KEEPER_SEND_GRAD: "1" });
  signer(on);
  assert.ok(!runUnit(on, ["grad", "--manual"]).args.includes("--send"));
});

test("grad-now.sh is the grad unit's manual one-shot: dry by default, --send sends, nothing else is accepted", () => {
  const ctx = unitEnv({ KEEPER_SEND_GRAD: "0" });
  signer(ctx);
  writeFileSync(join(ctx.secrets, "hc-grad"), HC);
  const dry = runScript("grad-now.sh", ctx, []);
  assert.equal(dry.code, 0, dry.out);
  assert.deepEqual(dry.args.slice(1, 3), ["moments-graduation", "launchpad-graduation"]);
  assert.ok(!dry.args.includes("--send"));
  assert.equal(argAfter(dry.args, "--sim-from"), ADDR);
  const send = runScript("grad-now.sh", ctx, ["--send"]);
  assert.equal(send.code, 0, send.out);
  assert.ok(send.args.includes("--send"));
  assert.equal(send.curl, "", "a manual run pings no healthchecks.io check");
  assert.equal(runScript("grad-now.sh", ctx, ["--yes"]).code, 64);
  // An unpinned grad key never sends, even by hand.
  writeFileSync(join(ctx.secrets, "grad.nosend"), "not pinned\n");
  const refused = runScript("grad-now.sh", ctx, ["--send"]);
  assert.equal(refused.code, 1);
  assert.ok(!refused.args.includes("--send"));
});

// Fork rehearsal 2026-10-01: `ps` on the Machine showed every RPC URL on the keeper's command line for the whole run,
// so a restricted provider key in KEEPER_RPC_URLS would have shown there. The list now reaches the keeper only through
// its environment, on scheduled and manual runs alike.
test("a restricted RPC key in KEEPER_RPC_URLS reaches the keeper through its environment, never its command line or the log", () => {
  const urls = "https://monad-mainnet.example/v2/FAKE-RPC-KEY-0123 https://rpc3.monad.xyz https://rpc4.monad.xyz";
  const ctx = unitEnv({ KEEPER_SEND_GRAD: "1", KEEPER_RPC_URLS: urls });
  signer(ctx);
  const runs = { scheduled: runUnit(ctx, ["grad"]), manual: runScript("grad-now.sh", ctx, ["--send"]) };
  for (const [kind, r] of Object.entries(runs)) {
    assert.equal(r.code, 0, `${kind}: ${r.out}`);
    assert.ok(r.args.includes("--send"), `${kind}: a sending run`);
    assert.equal(r.rpc, urls, `${kind}: the whole list, in order`);
    for (const a of r.args) assert.doesNotMatch(a, /FAKE-RPC-KEY|https?:\/\//, `${kind}: a URL on the command line: ${a}`);
    assert.doesNotMatch(r.out, /FAKE-RPC-KEY/, kind);
  }
});

test("usage errors: unknown unit, --send outside a manual run, a manual run of governance", () => {
  assert.equal(runUnit(unitEnv(), ["all"]).code, 64);
  assert.equal(runUnit(unitEnv(), ["grad", "--send"]).code, 64);
  assert.equal(runUnit(unitEnv(), ["governance", "--manual"]).code, 64);
});

// ---------------------------------------------------------------- crontab, fly.toml, keeper.env.example

test("the crontab schedules each unit once, at the plan's cadence, never with --send, --manual or --only-live", () => {
  const text = readFileSync(join(OPS, "crontab"), "utf8");
  const lines = text.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
  const jobs = lines.filter((l) => !/^[A-Z_]+=/.test(l));
  assert.ok(lines.includes("CRON_TZ=UTC"));
  const field = /^(\*|\d+(-\d+)?)(\/\d+)?(,(\*|\d+(-\d+)?)(\/\d+)?)*$/;
  const ranges = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
  const byUnit = Object.fromEntries(
    jobs.map((l) => {
      const f = l.split(/\s+/);
      assert.equal(f.length, 7, l);
      for (const [i, [lo, hi]] of ranges.entries()) {
        assert.match(f[i], field, `${l}: field ${i + 1}`);
        for (const n of f[i].split(/[^0-9]+/).filter(Boolean).map(Number)) if (!f[i].includes(`/${n}`)) assert.ok(n >= lo && n <= hi, `${l}: ${n} out of range`);
      }
      assert.equal(f[5], "/app/contracts/keepers/ops/run-keeper.sh");
      return [f[6], f.slice(0, 5).join(" ")];
    }),
  );
  assert.deepEqual(byUnit, { grad: "*/5 * * * *", sweeps: "2-59/15 * * * *", buybacks: "7 * * * *", governance: "11-59/15 * * * *" });
  const code = text.split("\n").filter((l) => !l.trim().startsWith("#")).join("\n");
  assert.doesNotMatch(code, /--send|--manual|--only-live/);
});

test("supercronic accepts the crontab", { skip: !has("supercronic") && "supercronic is not installed (the Dockerfile's test stage runs supercronic -test)" }, () => {
  const r = spawnSync("supercronic", ["-test", join(OPS, "crontab")], { encoding: "utf8" });
  assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
});

test("fly.toml: no public service, one volume at /data, restart always, one VM, no secret in [env]", () => {
  const toml = readFileSync(join(OPS, "fly.toml"), "utf8");
  const body = toml.split("\n").filter((l) => !l.trim().startsWith("#")).join("\n");
  for (const section of ["[http_service]", "[[services]]", "[checks]", "[[statics]]", "[processes]"]) assert.ok(!body.includes(section), section);
  assert.match(body, /^\[mounts\]\n\s+source = "keeper_state"\n\s+destination = "\/data"/m);
  assert.equal(body.match(/^\[mounts\]/gm)?.length, 1);
  assert.match(body, /^\[\[restart\]\]\n\s+policy = "always"/m);
  assert.equal(body.match(/^\[\[vm\]\]/gm)?.length, 1);
  assert.match(body, /^kill_signal = "SIGTERM"$/m);
  const kill = Number(/^kill_timeout = (\d+)$/m.exec(body)?.[1]);
  assert.ok(kill >= 240 && kill <= 300, "kill_timeout covers a signing run's 240 s deadline and is at most Fly's 300 s");
  const env = /^\[env\]\n((?:[ \t]+.+\n)*)/m.exec(body)?.[1] ?? "";
  assert.doesNotMatch(env, /KEEPER_|URL|KEY|PASSWORD|TOKEN|SECRET/i);
});

test("keeper.env.example holds names only, and they are the names the entrypoint and run-keeper.sh read", () => {
  const example = readFileSync(join(OPS, "keeper.env.example"), "utf8");
  const entry = readFileSync(join(OPS, "entrypoint.sh"), "utf8");
  const runner = readFileSync(join(OPS, "run-keeper.sh"), "utf8");
  const names = [];
  for (const line of example.split("\n")) {
    if (!line.trim() || line.startsWith("#")) continue;
    const m = /^([A-Z0-9_]+)=$/.exec(line);
    assert.ok(m, `names only, no value: ${line}`);
    names.push(m[1]);
  }
  // The per-unit names are built from the unit (KEEPER_${U}_KEYSTORE_B64, KEEPER_HC_$(upper "$unit")_URL).
  const readAs = (n) => {
    const b64 = /^KEEPER_(?:GRAD|SWEEPS|BUYBACKS)_(KEYSTORE|PASSWORD)_B64$/.exec(n);
    if (b64) return `KEEPER_\${U}_${b64[1]}_B64`;
    if (/^KEEPER_HC_(?:GRAD|SWEEPS|BUYBACKS|GOVERNANCE)_URL$/.test(n)) return 'KEEPER_HC_$(upper "$unit")_URL';
    return n;
  };
  for (const n of names) assert.ok(entry.includes(readAs(n)) || runner.includes(n), `${n} is not read by entrypoint.sh or run-keeper.sh`);
  assert.deepEqual(names.filter((n) => n.startsWith("KEEPER_SEND_")).sort(), ["KEEPER_SEND_BUYBACKS", "KEEPER_SEND_GRAD", "KEEPER_SEND_SWEEPS"]);
  assert.equal(names.length, new Set(names).size);
});

// ---------------------------------------------------------------- check-signers.mjs

test("check-signers: each unit its own key; never a record's role address or a Safe signer", () => {
  const { roles, safes } = roleAddresses(readRecords());
  const treasury = "0x5aDbDc19831D0f9dbdfBbA6ee3d618DbB9CEA371";
  const fees = "0x15ED3bb488231213b141A2f78b62358D52235Cd7";
  const deployer = "0x6f3FE7b371252ba3E3D825DD290eD10138906EfD";
  for (const a of [SAFE, GUARDIAN, treasury, fees, deployer]) assert.ok(roles.has(a.toLowerCase()), a);
  assert.ok(safes.includes(SAFE.toLowerCase()));
  const signerOfSafe = "0x9999999999999999999999999999999999999999";
  const r = checkSigners(
    [
      ["grad", "0x1111111111111111111111111111111111111111"],
      ["sweeps", "0x1111111111111111111111111111111111111111"],
      ["buybacks", GUARDIAN],
      ["extra", signerOfSafe],
      ["fine", "0x2222222222222222222222222222222222222222"],
    ],
    { roles, safeSigners: new Map([[signerOfSafe, SAFE]]) },
  );
  assert.deepEqual(r.map((x) => x.ok), [false, false, false, false, true]);
  assert.match(r[0].reason, /also the sweeps keeper/);
  assert.match(r[2].reason, /custody or protocol address.*guardian/);
  assert.match(r[3].reason, /signs for the Safe/);
  assert.deepEqual(parseUnits(["grad=0xabc"]), [["grad", "0xabc"]]);
  assert.throws(() => parseUnits(["0xabc"]));
  assert.equal(checkSigners([["grad", "0xnope"]])[0].ok, false);
});

function pinsFile(units) {
  const f = join(tmp("keeper-pins-"), "keeper-signers.json");
  const base = JSON.parse(readFileSync(join(OPS, "keeper-signers.json"), "utf8"));
  for (const [u, address] of Object.entries(units)) base.units[u].address = address;
  writeFileSync(f, JSON.stringify(base));
  return f;
}

test("check-signers: a key must derive the pinned address; an unpinned key runs dry runs only", () => {
  const pins = readPins(pinsFile({ grad: "0x1111111111111111111111111111111111111111", sweeps: "0x3333333333333333333333333333333333333333" }));
  const r = checkSigners(
    [
      ["grad", "0x1111111111111111111111111111111111111111"],
      ["sweeps", "0x2222222222222222222222222222222222222222"],
      ["buybacks", "0x4444444444444444444444444444444444444444"],
    ],
    { pins },
  );
  assert.deepEqual(r.map((x) => [x.ok, !!x.unpinned]), [[true, false], [false, false], [true, true]]);
  assert.match(r[1].reason, /derives 0x2222.*pins 0x3333/);
  assert.match(r[2].reason, /pins no buybacks address yet, so this unit runs dry runs only/);
  // The committed pins: every address empty until the owner's keys exist, and the funding numbers of the plan.
  const committed = readPins();
  for (const u of ["grad", "sweeps", "buybacks"]) assert.ok(committed.has(u), u);
  assert.equal(committed.get("grad").minBalance, 10n * MON);
  assert.equal(fundingNote("grad", "0xg", 9n * MON, committed.get("grad")), "0xg holds 9 MON, below the grad minimum of 10 MON: top it up to 30 MON");
  assert.equal(fundingNote("grad", "0xg", 10n * MON, committed.get("grad")), "");
  assert.throws(() => readPins(pinsFile({ grad: "0xnot-an-address" })), /not an address/);
});

/** A viem-like client for check-signers: the Safe answers getOwners, balances by address. */
function fakeChain({ owners = [], balances = {}, down = false } = {}) {
  const fail = () => Promise.reject(Object.assign(new Error("HTTP request failed. Status: 503"), { name: "HttpRequestError", status: 503 }));
  return () => ({
    client: {
      getCode: ({ address }) => (down ? fail() : Promise.resolve(address.toLowerCase() === SAFE.toLowerCase() ? "0x6080" : "0x")),
      readContract: () => (down ? fail() : Promise.resolve(owners)),
      getBalance: ({ address }) => (down ? fail() : Promise.resolve(balances[address.toLowerCase()] ?? 0n)),
    },
  });
}
async function checkRun(argv, chain) {
  const lines = [];
  const code = await checkSignersMain(argv, { env: {}, out: (l) => lines.push(l), makeClient: chain });
  return { code, lines };
}

test("check-signers main: OK, LOW, UNPINNED, FORBIDDEN lines and exit codes, read-only", async () => {
  const g = "0x1111111111111111111111111111111111111111";
  const s = "0x2222222222222222222222222222222222222222";
  const b = "0x3333333333333333333333333333333333333333";
  const pinned = pinsFile({ grad: g, sweeps: s, buybacks: b });
  const funded = { [g]: 30n * MON, [s]: 5n * MON, [b]: 10n * MON };

  let r = await checkRun([`grad=${g}`, `sweeps=${s}`, `buybacks=${b}`, "--signers", pinned], fakeChain({ balances: funded }));
  assert.equal(r.code, 0, r.lines.join("\n"));
  assert.deepEqual(r.lines, [`OK grad ${g} holds 30 MON (minimum 10)`, `OK sweeps ${s} holds 5 MON (minimum 1)`, `OK buybacks ${b} holds 10 MON (minimum 3)`]);

  // Below a minimum: a LOW line; it fails the check only with --require-funding.
  const low = { ...funded, [s]: MON / 2n };
  r = await checkRun([`grad=${g}`, `sweeps=${s}`, "--signers", pinned], fakeChain({ balances: low }));
  assert.equal(r.code, 0);
  assert.ok(r.lines.includes(`LOW sweeps ${s} holds 0.5 MON, below the sweeps minimum of 1 MON: top it up to 5 MON`), r.lines.join("\n"));
  assert.equal((await checkRun([`grad=${g}`, `sweeps=${s}`, "--signers", pinned, "--require-funding"], fakeChain({ balances: low }))).code, 1);

  // A Safe signer, read on chain, is forbidden; the committed (empty) pins make every unit UNPINNED.
  r = await checkRun([`grad=${g}`], fakeChain({ owners: [g], balances: funded }));
  assert.equal(r.code, 1);
  assert.match(r.lines.join("\n"), /FORBIDDEN grad .*signs for the Safe 0x6d2a/i);
  r = await checkRun([`grad=${g}`], fakeChain({ balances: funded }));
  assert.equal(r.code, 1);
  assert.match(r.lines[0], /^UNPINNED grad 0x1111.*pins no grad address yet/);

  // The RPC down: the records and pins still decide; the balance is unread (fatal only with --require-funding).
  r = await checkRun([`grad=${g}`, "--signers", pinned], fakeChain({ down: true }));
  assert.equal(r.code, 0);
  assert.match(r.lines.join("\n"), /NOTE could not read the owners of .*checked against the records only/);
  assert.match(r.lines.join("\n"), /OK grad 0x1111.* balance unread \(RPC\)/);
  assert.equal((await checkRun([`grad=${g}`, "--signers", pinned, "--require-funding"], fakeChain({ down: true }))).code, 1);

  // Usage errors.
  assert.equal((await checkRun([], fakeChain())).code, 2);
  assert.equal((await checkRun(["0xabc"], fakeChain())).code, 2);
  assert.equal((await checkRun(["--keystores", "/x", "grad=0x1"], fakeChain())).code, 2);
});

test("check-signers --keystores: each address is derived with cast from <unit>.keystore and <unit>.password; nothing secret is printed", async () => {
  const dir = tmp("keeper-ks-");
  const secret = `pw-${randomBytes(8).toString("hex")}`;
  for (const u of ["grad", "buybacks"]) {
    writeFileSync(join(dir, `${u}.keystore`), '{"crypto":{}}');
    writeFileSync(join(dir, `${u}.password`), u === "grad" ? secret : "wrong");
  }
  writeFileSync(join(dir, "sweeps.keystore"), '{"crypto":{}}'); // no password file
  const calls = [];
  const fakeCast = (bin, args) => {
    calls.push(args);
    const pw = readFileSync(args[args.indexOf("--password-file") + 1], "utf8");
    return pw === secret ? { status: 0, stdout: "0x1111111111111111111111111111111111111111\n", stderr: "" } : { status: 1, stdout: "", stderr: `Error: Mac Mismatch (${pw})` };
  };
  const { units, unusable } = deriveFromKeystores(dir, { cast: "cast", spawn: fakeCast });
  assert.deepEqual(units, [["grad", "0x1111111111111111111111111111111111111111"]]);
  assert.deepEqual(unusable.map(([u]) => u), ["sweeps", "buybacks"]);
  assert.ok(calls.every((a) => a[0] === "wallet" && a[1] === "address" && a.includes("--keystore") && a.includes("--password-file")));
  // Through main: the password and cast's error text never reach the output.
  const lines = [];
  const code = await checkSignersMain(["--keystores", dir, "--no-chain"], { env: {}, out: (l) => lines.push(l), spawn: fakeCast });
  assert.equal(code, 1);
  const out = lines.join("\n");
  assert.match(out, /FORBIDDEN sweeps sweeps.keystore and sweeps.password must both be in/);
  assert.match(out, /FORBIDDEN buybacks cast could not open the keystore with its password/);
  assert.match(out, /UNPINNED grad 0x1111/);
  assert.ok(!out.includes(secret) && !out.includes("Mac Mismatch") && !out.includes("wrong"), out);
});

// ---------------------------------------------------------------- entrypoint.sh

/** Stubs for running entrypoint.sh as a non-root user on any machine: `id -u` says 0, `mountpoint` follows
    FAKE_NOT_MOUNTED, `mount` pretends the tmpfs mounted, `chown` does nothing, `setpriv` drops its options and puts the
    stubs first on the PATH of the `env -i` it runs, and `cast` derives the address a test keystore names (when the
    password file holds the keystore's testPassword). `node` is this Node. */
const ENTRY_STUBS = (() => {
  const bin = join(tmp("keeper-entry-bin-"), "bin");
  mkdirSync(bin);
  putExe(bin, "id", 'if [ "$1" = "-u" ]; then echo "${FAKE_UID:-0}"; else /usr/bin/id "$@"; fi');
  putExe(bin, "getent", 'echo "keeper:x:10001:10001::/home/keeper:/usr/sbin/nologin"');
  putExe(bin, "mountpoint", 'exit "${FAKE_NOT_MOUNTED:-0}"');
  putExe(bin, "mount", "exit 0");
  putExe(bin, "chown", "exit 0");
  putExe(
    bin,
    "setpriv",
    `while [ $# -gt 0 ] && [ "\${1#--}" != "$1" ]; do shift; done
args=()
for a in "$@"; do case "$a" in PATH=*) args+=("PATH=${bin}:\${a#PATH=}") ;; *) args+=("$a") ;; esac; done
exec "\${args[@]}"`,
    "/bin/bash",
  );
  putExe(
    bin,
    "cast",
    `[ "$1 $2" = "wallet address" ] || exit 9
ks=$4; pw=$6
want=$(sed -n 's/.*"testPassword":"\\([^"]*\\)".*/\\1/p' "$ks")
[ -n "$want" ] && [ "$(cat "$pw")" = "$want" ] || { echo "Error: Mac Mismatch" >&2; exit 1; }
sed -n 's/.*"address":"\\([0-9a-fA-F]\\{40\\}\\)".*/0x\\1/p' "$ks"`,
  );
  symlinkSync(process.execPath, join(bin, "node"));
  return bin;
})();

/** A copy of the app as the image lays it out (/app), so a test can pin its own addresses. */
function appCopy(pins = {}) {
  const app = tmp("keeper-app-");
  mkdirSync(join(app, "contracts"));
  cpSync(KEEPERS, join(app, "contracts", "keepers"), { recursive: true, filter: (p) => !p.includes("node_modules") });
  cpSync(join(REPO, "contracts", "deployments"), join(app, "contracts", "deployments"), { recursive: true });
  symlinkSync(join(REPO, "node_modules"), join(app, "node_modules"));
  writeFileSync(join(app, "contracts", "keepers", "ops", "keeper-signers.json"), readFileSync(pinsFile(pins)));
  return app;
}

/** A local JSON-RPC that answers check-signers' reads: no code anywhere, balances by address. */
async function chainServer(balances = {}) {
  const s = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d)).on("end", () => {
      const j = JSON.parse(body);
      const result = j.method === "eth_getBalance" ? `0x${(balances[j.params[0].toLowerCase()] ?? 0n).toString(16)}` : j.method === "eth_chainId" ? "0x8f" : "0x";
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: j.id, result }));
    });
  });
  await new Promise((r) => s.listen(0, "127.0.0.1", r));
  return { url: `http://127.0.0.1:${s.address().port}`, close: () => s.close() };
}

function runAsync(cmd, args, env) {
  return new Promise((resolve) => {
    const p = spawn(cmd, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    p.on("close", (code) => resolve({ code, out }));
  });
}

const b64 = (s) => Buffer.from(s).toString("base64");
const GRAD_KEY = "0x1111111111111111111111111111111111111111";
const GRAD_PW = "pw-grad-FAKE-SECRET-1";
const fakeKeystore = (address, password) => JSON.stringify({ address: address.slice(2), crypto: { cipher: "aes-128-ctr" }, testPassword: password });

/** The Fly secrets a test Machine gets: grad a fine key, sweeps the guardian's address, buybacks not a keystore. */
function flySecrets() {
  return {
    KEEPER_GRAD_KEYSTORE_B64: b64(fakeKeystore(GRAD_KEY, GRAD_PW)),
    KEEPER_GRAD_PASSWORD_B64: b64(GRAD_PW),
    KEEPER_SWEEPS_KEYSTORE_B64: b64(fakeKeystore(GUARDIAN, "pw-sweeps-FAKE-SECRET-2")),
    KEEPER_SWEEPS_PASSWORD_B64: b64("pw-sweeps-FAKE-SECRET-2"),
    KEEPER_BUYBACKS_KEYSTORE_B64: b64("not-a-keystore-FAKE-SECRET-3"),
    KEEPER_BUYBACKS_PASSWORD_B64: b64("pw-buybacks-FAKE-SECRET-4"),
    KEEPER_WEBHOOK_URL: HOOK,
    KEEPER_HC_GRAD_URL: `${HC}/grad`,
    KEEPER_HC_GOVERNANCE_URL: `${HC}/governance`,
    KEEPER_SEND_GRAD: "1",
  };
}
const SECRET_FRAGMENTS = ["FAKE-SECRET", "test-token-path", "test-ping-path", "hc-ping.example", ...Object.values(flySecrets()).filter((v) => v.length > 8)];

async function boot({ app, secrets = flySecrets(), over = {}, rpcBalances = {}, stale = {} } = {}) {
  const dir = tmp("keeper-machine-");
  const chain = await chainServer(rpcBalances);
  const env = {
    PATH: `${ENTRY_STUBS}:/usr/bin:/bin`,
    STUB_BIN: ENTRY_STUBS,
    HOME: dir,
    KEEPER_APP_DIR: app ?? appCopy(),
    KEEPER_DATA_DIR: join(dir, "data"),
    KEEPER_SECRETS_DIR: join(dir, "run", "dyor-keeper"),
    KEEPER_RPC_URLS: chain.url,
    FLY_MACHINE_ID: "machine-test-1",
    KEEPER_MACHINE_ID: "machine-test-1",
    ...secrets,
    ...over,
  };
  for (const [k, v] of Object.entries(env)) if (v === undefined) delete env[k];
  mkdirSync(env.KEEPER_DATA_DIR);
  // Files an earlier boot left (a restarted local container keeps /dev/shm).
  if (Object.keys(stale).length) mkdirSync(env.KEEPER_SECRETS_DIR, { recursive: true });
  for (const [f, content] of Object.entries(stale)) writeFileSync(join(env.KEEPER_SECRETS_DIR, f), content);
  const childEnv = join(dir, "child-env");
  try {
    // As on the Machine with a command (a local test run): the entrypoint prepares, then runs it as keeper.
    const r = await runAsync("bash", [join(OPS, "entrypoint.sh"), "/bin/sh", "-c", 'env > "$0"', childEnv], env);
    return { ...r, dir, env, secretsDir: env.KEEPER_SECRETS_DIR, childEnv: existsSync(childEnv) ? readFileSync(childEnv, "utf8") : null };
  } finally {
    chain.close();
  }
}
const mode = (f) => (statSync(f).mode & 0o777).toString(8);

test("entrypoint: refuses to start without the state volume, or as anyone but root, and writes no secret", async () => {
  const noVolume = await boot({ over: { FAKE_NOT_MOUNTED: "1" } });
  assert.equal(noVolume.code, 1);
  assert.match(noVolume.out, /is not a mounted volume: refusing to run keepers without their state/);
  assert.equal(noVolume.childEnv, null, "nothing ran");
  assert.ok(!existsSync(noVolume.secretsDir) || readdirSync(noVolume.secretsDir).length === 0);
  const notRoot = await boot({ over: { FAKE_UID: "501" } });
  assert.equal(notRoot.code, 1);
  assert.match(notRoot.out, /start as root/);
  for (const r of [noVolume, notRoot]) for (const s of SECRET_FRAGMENTS) assert.ok(!r.out.includes(s), `printed ${s}`);
});

test("entrypoint: Fly secrets become 0400 files on the tmpfs, never output or a keeper's environment; bad keys are refused", async () => {
  const r = await boot({ rpcBalances: { [GRAD_KEY]: 12n * MON } });
  assert.equal(r.code, 0, r.out);
  for (const s of SECRET_FRAGMENTS) {
    assert.ok(!r.out.includes(s), `printed ${s}`);
    assert.ok(!r.childEnv.includes(s), `a keeper process gets ${s}`);
  }
  assert.doesNotMatch(r.childEnv, /_B64=|KEEPER_WEBHOOK_URL|KEEPER_HC_/);
  assert.match(r.childEnv, /^KEEPER_SEND_GRAD=1$/m);
  assert.match(r.childEnv, new RegExp(`^KEEPER_SECRETS_DIR=${r.secretsDir}$`, "m"));

  const at = (f) => join(r.secretsDir, f);
  assert.equal(readFileSync(at("grad.keystore"), "utf8"), fakeKeystore(GRAD_KEY, GRAD_PW));
  assert.equal(readFileSync(at("grad.password"), "utf8"), GRAD_PW);
  assert.equal(readFileSync(at("grad.address"), "utf8").trim(), GRAD_KEY);
  assert.equal(readFileSync(at("webhook"), "utf8").trim(), HOOK);
  assert.equal(readFileSync(at("hc-grad"), "utf8").trim(), `${HC}/grad`);
  for (const f of ["grad.keystore", "grad.password", "webhook", "hc-grad", "hc-governance"]) assert.equal(mode(at(f)), "400", f);
  assert.ok(!existsSync(at("hc-sweeps")));

  // sweeps derives the guardian's address: removed, never used. buybacks is not a keystore: removed.
  assert.match(readFileSync(at("sweeps.error"), "utf8"), /custody or protocol address .*guardian/);
  assert.match(readFileSync(at("buybacks.error"), "utf8"), /does not decode to a JSON keystore/);
  for (const f of ["sweeps.keystore", "sweeps.password", "buybacks.keystore", "buybacks.password"]) assert.ok(!existsSync(at(f)), f);
  // grad is fine but the committed keeper-signers.json pins no address yet: dry runs as its address, no send.
  assert.match(readFileSync(at("grad.nosend"), "utf8"), /pins no grad address yet/);
  assert.match(r.out, /grad: dry runs only/);
  assert.match(r.out, /grad: KEEPER_SEND_GRAD=1 but the unit may not send/);
  assert.doesNotMatch(r.out, /LOW grad/, "12 MON is above the grad minimum");
  assert.match(r.out, /secrets directory: tmpfs \(mounted\)/);
  assert.match(r.out, /healthchecks pings: grad governance/);
});

test("entrypoint: a key that derives its pinned address may send; a pin mismatch or a shared key is refused; LOW is reported", async () => {
  const sweepsKey = "0x2222222222222222222222222222222222222222";
  const secrets = {
    ...flySecrets(),
    KEEPER_SWEEPS_KEYSTORE_B64: b64(fakeKeystore(sweepsKey, "pw-sweeps-FAKE-SECRET-2")),
    KEEPER_BUYBACKS_KEYSTORE_B64: b64(fakeKeystore(GRAD_KEY, "pw-buybacks-FAKE-SECRET-4")), // the grad key again
  };
  const app = appCopy({ grad: GRAD_KEY, sweeps: "0x3333333333333333333333333333333333333333" });
  const r = await boot({ app, secrets, rpcBalances: { [GRAD_KEY]: 9n * MON } });
  assert.equal(r.code, 0, r.out);
  const at = (f) => join(r.secretsDir, f);
  // grad and buybacks share a key: both refused (each unit needs its own); sweeps derives another address than its pin.
  assert.match(readFileSync(at("grad.error"), "utf8"), /also the buybacks keeper/);
  assert.match(readFileSync(at("buybacks.error"), "utf8"), /also the grad keeper/);
  assert.match(readFileSync(at("sweeps.error"), "utf8"), /derives 0x2222.*pins 0x3333/);
  for (const s of SECRET_FRAGMENTS) assert.ok(!r.out.includes(s), `printed ${s}`);

  // Now a clean set: grad pinned and its own: it may send; the balance below 10 MON is reported.
  const gradOnly = Object.fromEntries(Object.entries(secrets).filter(([k]) => !/^KEEPER_(SWEEPS|BUYBACKS)_/.test(k)));
  const stale = Object.fromEntries(["error", "keystore", "password", "address"].map((x) => [`sweeps.${x}`, x === "address" ? `${GRAD_KEY}\n` : "{}"]));
  stale["grad.error"] = "an earlier boot's refusal\n";
  const clean = await boot({ app, secrets: gradOnly, rpcBalances: { [GRAD_KEY]: 9n * MON }, stale });
  assert.equal(clean.code, 0, clean.out);
  for (const f of Object.keys(stale)) assert.ok(!existsSync(join(clean.secretsDir, f)), `${f} from an earlier boot survived`);
  assert.ok(!existsSync(join(clean.secretsDir, "grad.error")) && !existsSync(join(clean.secretsDir, "grad.nosend")));
  assert.match(clean.out, new RegExp(`grad: signer ${GRAD_KEY}, sends ON`));
  assert.match(clean.out, /signer check: LOW grad 0x1111111111111111111111111111111111111111 holds 9 MON, below the grad minimum of 10 MON: top it up to 30 MON/);
  assert.match(clean.out, /sweeps: no keystore \(dry runs without a signer\)/);
});

test("check-signers run through a symlinked path still checks (macOS /var and /tmp are symlinks)", () => {
  const dir = tmp("keeper-link-");
  const link = join(dir, "check-signers.mjs");
  symlinkSync(join(OPS, "check-signers.mjs"), link);
  const r = spawnSync(process.execPath, [link, `grad=${GUARDIAN}`, "--no-chain"], { encoding: "utf8", env: { PATH: process.env.PATH, HOME: dir } });
  assert.equal(r.status, 1, `${r.stdout}${r.stderr}`);
  assert.match(r.stdout, /^FORBIDDEN grad .*guardian/m);
});

test("entrypoint: the signer check fails closed, also when the app path runs through a symlink", async () => {
  // Through a symlinked app directory, as under a stock macOS TMPDIR: the guardian key is still refused.
  const linked = join(tmp("keeper-applink-"), "app");
  symlinkSync(appCopy({ grad: GRAD_KEY }), linked);
  const r = await boot({ app: linked });
  assert.equal(r.code, 0, r.out);
  assert.match(readFileSync(join(r.secretsDir, "sweeps.error"), "utf8"), /custody or protocol address .*guardian/);
  assert.match(r.out, new RegExp(`signer check: OK grad ${GRAD_KEY}`));
  assert.match(r.out, new RegExp(`grad: signer ${GRAD_KEY}, sends ON`));

  // A check that prints nothing (exit 0) or crashes (exit 1) clears no key: none may send, not even a pinned one.
  for (const [what, body] of [["silent", "process.exit(0);\n"], ["crashed", 'throw new Error("boom");\n']]) {
    const app = appCopy({ grad: GRAD_KEY });
    writeFileSync(join(app, "contracts", "keepers", "ops", "check-signers.mjs"), body);
    const b = await boot({ app });
    assert.equal(b.code, 0, `${what}: ${b.out}`);
    assert.match(readFileSync(join(b.secretsDir, "grad.error"), "utf8"), /the signer check did not clear this key/, what);
    assert.ok(!existsSync(join(b.secretsDir, "grad.keystore")), `${what}: the key was removed`);
    assert.doesNotMatch(b.out, /sends ON/, what);
    assert.match(b.out, /grad: KEEPER_SEND_GRAD=1 but the unit may not send/, what);
  }
});

test("entrypoint: only the Machine KEEPER_MACHINE_ID names may send; a second one (scale-out, clone) or an unset pin may not", async () => {
  const app = appCopy({ grad: GRAD_KEY });
  const gradOnly = Object.fromEntries(Object.entries(flySecrets()).filter(([k]) => !/^KEEPER_(SWEEPS|BUYBACKS)_/.test(k)));
  const pinned = await boot({ app, secrets: gradOnly });
  assert.equal(readFileSync(join(pinned.secretsDir, "machine.ok"), "utf8").trim(), "machine-test-1");
  assert.match(pinned.out, /machine: machine-test-1 is the keeper Machine/);
  assert.match(pinned.out, new RegExp(`grad: signer ${GRAD_KEY}, sends ON`));
  for (const [what, over, said] of [
    ["a second Machine", { FLY_MACHINE_ID: "machine-test-2" }, /machine: machine-test-2 is NOT the keeper Machine machine-test-1: no unit sends here/],
    ["no pin", { KEEPER_MACHINE_ID: undefined }, /machine: KEEPER_MACHINE_ID is not set: no unit sends until it names this Machine \(machine-test-1\)/],
    ["not on Fly", { FLY_MACHINE_ID: undefined }, /machine: unknown is NOT the keeper Machine/],
  ]) {
    const b = await boot({ app, secrets: gradOnly, over });
    assert.equal(b.code, 0, `${what}: ${b.out}`);
    assert.ok(!existsSync(join(b.secretsDir, "machine.ok")), what);
    assert.match(b.out, said, what);
    assert.doesNotMatch(b.out, /sends ON/, what);
    assert.match(b.out, /grad: KEEPER_SEND_GRAD=1 but the unit may not send/, what);
  }
});

// ---------------------------------------------------------------- bundle.sh and deploy-fly.sh

/** A throwaway git repository holding the files a bundle takes, so bundle.sh runs the same in CI and locally. */
function scratchRepo() {
  const dir = tmp("keeper-bundle-");
  const repo = join(dir, "repo");
  mkdirSync(join(repo, "contracts"), { recursive: true });
  cpSync(KEEPERS, join(repo, "contracts", "keepers"), { recursive: true, filter: (p) => !p.includes("node_modules") });
  cpSync(join(REPO, "contracts", "deployments"), join(repo, "contracts", "deployments"), { recursive: true });
  for (const f of ["package.json", "package-lock.json"]) cpSync(join(REPO, f), join(repo, f));
  writeFileSync(join(repo, "unrelated.txt"), "not in a bundle");
  const git = (...a) => {
    const r = spawnSync("git", a, { cwd: repo, encoding: "utf8", env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" } });
    assert.equal(r.status, 0, r.stderr);
    return r.stdout.trim();
  };
  git("init", "-q");
  git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "core.hooksPath=/dev/null", "add", "-A");
  git("-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "bundle test");
  return { dir, repo, sha: git("rev-parse", "HEAD") };
}

test("bundle.sh and deploy-fly.sh: reviewed commits only, and a bundle must match its manifest", { skip: !has("git") && "git is not installed" }, () => {
  const { dir, repo, sha } = scratchRepo();
  const bundle = (args) => spawnSync("bash", [join(OPS, "bundle.sh"), ...args], { cwd: repo, encoding: "utf8" });
  const deploy = (args, cwd = dir) => spawnSync("bash", [join(OPS, "deploy-fly.sh"), ...args], { cwd, encoding: "utf8", env: { PATH: "/usr/bin:/bin" } });

  // No origin/main here: without --allow-unmerged the commit is refused.
  const refused = bundle(["HEAD", "--out", join(dir, "out0")]);
  assert.equal(refused.status, 1, refused.stderr);
  const made = bundle(["HEAD", "--out", join(dir, "out"), "--allow-unmerged"]);
  assert.equal(made.status, 0, made.stderr);
  const b = made.stdout.trim().split("\n").pop();
  assert.equal(readFileSync(join(b, "BUNDLE_COMMIT"), "utf8").trim(), sha);
  assert.equal(readFileSync(join(b, "BUNDLE_REVIEWED"), "utf8").trim(), "UNREVIEWED");
  for (const f of ["contracts/keepers/ops/Dockerfile", "contracts/keepers/ops/keeper-signers.json", "contracts/keepers/keeper.mjs", "contracts/deployments/143.json", "package-lock.json"]) assert.ok(existsSync(join(b, f)), f);
  assert.ok(!existsSync(join(b, "unrelated.txt")));
  assert.ok(existsSync(`${b}.tar.gz`));
  // The manifest: one SHA256 per file, sorted, covering every file but itself, and the tarball's hash is printed.
  const manifest = readFileSync(join(b, "BUNDLE_MANIFEST.sha256"), "utf8").trim().split("\n");
  const paths = manifest.map((l) => /^[0-9a-f]{64}  (.+)$/.exec(l)?.[1]);
  assert.ok(paths.every(Boolean));
  assert.deepEqual(paths, [...paths].sort());
  assert.ok(paths.includes("BUNDLE_COMMIT") && paths.includes("contracts/keepers/ops/run-keeper.sh") && !paths.includes("BUNDLE_MANIFEST.sha256"));
  assert.match(made.stdout, /tarball .*\.tar\.gz sha256 [0-9a-f]{64}/);

  const unreviewed = deploy([b, "--check-only"]);
  assert.equal(unreviewed.status, 1);
  assert.match(unreviewed.stderr, /not made from a reviewed commit/);

  // As bundle.sh writes a bundle of a commit on origin/main: now --check-only passes and names the safe flags.
  const remanifest = () => {
    const hash = has("sha256sum") ? "sha256sum" : "shasum -a 256";
    const r = spawnSync("sh", ["-c", `find . -type f ! -name BUNDLE_MANIFEST.sha256 | sed 's|^./||' | LC_ALL=C sort | xargs ${hash}`], { cwd: b, encoding: "utf8" });
    writeFileSync(join(b, "BUNDLE_MANIFEST.sha256"), r.stdout);
  };
  writeFileSync(join(b, "BUNDLE_REVIEWED"), `reviewed: on origin/main (${sha})\n`);
  remanifest();
  const ok = deploy([b, "--check-only"]);
  assert.equal(ok.status, 0, ok.stderr);
  for (const flag of ["--ha=false", "--no-public-ips", "--local-only", `--image-label keepers-${sha.slice(0, 12)}`, "--app dyorhq-keepers"]) assert.ok(ok.stdout.includes(flag), flag);
  assert.match(deploy([b, "--check-only", "--remote-builder", "--app", "other-app"]).stdout, /--remote-only --image-label .* --app other-app|--app other-app .*--remote-only/);
  // Run from a checkout that knows the commit, the "reviewed" claim is checked against its origin/main.
  const known = deploy([b, "--check-only"], repo);
  assert.equal(known.status, 1);
  assert.match(known.stderr, /is not on origin\/main in this checkout/);

  // A changed file, or a file the manifest does not list, is refused.
  appendFileSync(join(b, "contracts/keepers/keeper.mjs"), "\n// changed\n");
  const changed = deploy([b, "--check-only"]);
  assert.equal(changed.status, 1);
  assert.match(changed.stderr, /differ from the bundle's manifest/);
  remanifest();
  writeFileSync(join(b, "contracts/keepers/extra.mjs"), "export {};\n");
  const extra = deploy([b, "--check-only"]);
  assert.equal(extra.status, 1);
  assert.match(extra.stderr, /does not list/);
});

// ---------------------------------------------------------------- make-keeper-secrets.sh

test("make-keeper-secrets.sh: keys and URLs go to fly secrets import on stdin; nothing secret is printed or kept", () => {
  const dir = tmp("keeper-secrets-");
  const bin = join(dir, "bin");
  const tmpd = join(dir, "tmp");
  mkdirSync(bin);
  mkdirSync(tmpd);
  // A stand-in for cast: `wallet new DIR NAME` writes a keystore-shaped file whose "password" is pw-NAME (as if the
  // owner had typed it at cast's prompt); `wallet address` opens it only with that password. No key is created.
  putExe(
    bin,
    "cast",
    `case "$1 $2" in
  "--version ") echo "cast Version: 1.7.1"; exit 0 ;;
  "wallet new") printf '{"crypto":{"cipher":"test"},"name":"%s"}' "$4" > "$3/$4"; echo "Created $3/$4"; exit 0 ;;
  "wallet address") ks=$4; pwf=$6; [ "$(cat "$pwf")" = "pw-$(basename "$ks")" ] || { echo "Error: Mac Mismatch" >&2; exit 1; }
    case "$(basename "$ks")" in *grad) echo 0x1111111111111111111111111111111111111111 ;; *sweeps) echo 0x2222222222222222222222222222222222222222 ;; *) echo 0x3333333333333333333333333333333333333333 ;; esac; exit 0 ;;
esac
exit 9`,
    "/bin/bash",
  );
  putExe(bin, "fly", `case "$1 $2" in "auth whoami") echo owner@example.invalid ;; "secrets import") printf '%s\\n' "$*" > "$FLY_ARGS"; cat > "$FLY_STDIN" ;; *) exit 9 ;; esac`, "/bin/bash");
  // The owner's answers: a wrong password once for sweeps, then the right ones; the webhook, 4 ping URLs and a
  // restricted RPC URL.
  const RPC_KEYED = "https://monad-mainnet.example/v2/FAKE-RPC-KEY-0123";
  const answers = ["pw-dyor-keeper-grad", "wrong", "pw-dyor-keeper-sweeps", "pw-dyor-keeper-buybacks", HOOK, `${HC}/grad`, `${HC}/sweeps`, "", `${HC}/governance`, RPC_KEYED].join("\n") + "\n";
  const r = spawnSync("bash", [join(OPS, "make-keeper-secrets.sh"), "--app", "dyorhq-keepers"], {
    input: answers,
    encoding: "utf8",
    env: { PATH: `${bin}:/usr/bin:/bin`, HOME: dir, TMPDIR: tmpd, CAST_BIN: join(bin, "cast"), FLY_BIN: join(bin, "fly"), FLY_ARGS: join(dir, "fly-args"), FLY_STDIN: join(dir, "fly-stdin") },
  });
  const out = `${r.stdout}${r.stderr}`;
  assert.equal(r.status, 0, out);
  assert.equal(readFileSync(join(dir, "fly-args"), "utf8").trim(), "secrets import --app dyorhq-keepers --stage");
  const imported = Object.fromEntries(readFileSync(join(dir, "fly-stdin"), "utf8").trim().split("\n").map((l) => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1)]));
  assert.deepEqual(Object.keys(imported).sort(), [
    "KEEPER_BUYBACKS_KEYSTORE_B64", "KEEPER_BUYBACKS_PASSWORD_B64", "KEEPER_GRAD_KEYSTORE_B64", "KEEPER_GRAD_PASSWORD_B64",
    "KEEPER_HC_GOVERNANCE_URL", "KEEPER_HC_GRAD_URL", "KEEPER_HC_SWEEPS_URL", "KEEPER_RPC_URLS", "KEEPER_SEND_BUYBACKS",
    "KEEPER_SEND_GRAD", "KEEPER_SEND_SWEEPS", "KEEPER_SWEEPS_KEYSTORE_B64", "KEEPER_SWEEPS_PASSWORD_B64", "KEEPER_WEBHOOK_URL",
  ]);
  // The restricted RPC first, the public ones as fallbacks.
  assert.equal(imported.KEEPER_RPC_URLS, `${RPC_KEYED} https://rpc3.monad.xyz https://rpc4.monad.xyz`);
  const decode = (v) => Buffer.from(v, "base64").toString("utf8");
  assert.equal(decode(imported.KEEPER_GRAD_PASSWORD_B64), "pw-dyor-keeper-grad");
  assert.equal(JSON.parse(decode(imported.KEEPER_SWEEPS_KEYSTORE_B64)).name, "dyor-keeper-sweeps");
  assert.equal(imported.KEEPER_WEBHOOK_URL, HOOK);
  assert.equal(imported.KEEPER_SEND_GRAD, "0");
  // Only the public addresses, the names and the flag templates are printed.
  for (const secret of ["pw-dyor-keeper", "wrong", "hc-ping", "test-token", "FAKE-RPC-KEY", imported.KEEPER_GRAD_KEYSTORE_B64.slice(0, 16), imported.KEEPER_GRAD_PASSWORD_B64]) {
    assert.ok(!out.includes(secret), `printed: ${secret}`);
  }
  assert.match(out, /dyor-keeper-grad 0x1111111111111111111111111111111111111111/);
  assert.match(out, /does not open the keystore \(try 1 of 3\)/);
  assert.match(out, /keeper-signers\.json/);
  assert.match(out, /^fly secrets set KEEPER_SEND_GRAD=1 --app dyorhq-keepers$/m);
  assert.deepEqual(readdirSync(tmpd), [], "the temporary folder is deleted");
});

test("make-keeper-secrets.sh --print-commands: templates with placeholders, no secret ever on a fly command line, nothing run", () => {
  const r = spawnSync("bash", [join(OPS, "make-keeper-secrets.sh"), "--print-commands"], { encoding: "utf8", env: { PATH: "/usr/bin:/bin" } });
  assert.equal(r.status, 0, r.stderr);
  const fly = r.stdout.split("\n").filter((l) => l.startsWith("fly "));
  assert.ok(fly.length >= 5);
  for (const l of fly) {
    assert.match(l, /--app <APP>$/, l);
    assert.doesNotMatch(l, /_B64=|_URL=|PASSWORD|KEYSTORE|https?:/, `a secret on a command line: ${l}`);
  }
  for (const u of ["GRAD", "BUYBACKS", "SWEEPS"]) assert.ok(fly.includes(`fly secrets set KEEPER_SEND_${u}=1 --app <APP>`), u);
  assert.ok(fly.indexOf("fly secrets set KEEPER_MACHINE_ID=<MACHINE_ID> --app <APP>") < fly.indexOf("fly secrets set KEEPER_SEND_GRAD=1 --app <APP>"), "the Machine is pinned before the first send flag");
  assert.ok(fly.includes("fly secrets set KEEPER_MACHINE_ID=<MACHINE_ID> --app <APP>"));
  assert.ok(fly.includes("fly secrets deploy --app <APP>"));
  // Without --print-commands and without --app it is a usage error.
  assert.equal(spawnSync("bash", [join(OPS, "make-keeper-secrets.sh")], { encoding: "utf8", env: { PATH: "/usr/bin:/bin" } }).status, 64);
});

// ---------------------------------------------------------------- opt-in: real cast keystores on a local anvil

const anvilEnabled = process.env.KEEPER_ANVIL === "1";
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

test(
  "K4 on anvil: check-signers derives each address from a real cast keystore, then checks pins and funding; on a fork run-keeper.sh drives the real keeper",
  { skip: !anvilEnabled && "set KEEPER_ANVIL=1 to run (needs anvil and cast; KEEPER_ANVIL_FORK_URL for the fork part)", timeout: 600_000 },
  async (t) => {
    const port = Number(process.env.KEEPER_ANVIL_OPS_PORT ?? 8813);
    const url = `http://127.0.0.1:${port}`;
    const fork = process.env.KEEPER_ANVIL_FORK_URL;
    const anvil = spawn(foundry("anvil"), ["--host", "127.0.0.1", "--port", String(port), "--silent", ...(fork ? ["--fork-url", fork, "--no-rate-limit"] : [])], { stdio: "ignore" });
    const dir = tmp("keeper-anvil-");
    const secrets = join(dir, "secrets");
    mkdirSync(secrets, { mode: 0o700 });
    try {
      let up = false;
      for (let i = 0; i < 150 && !up; i++) {
        up = await rpc(url, "eth_chainId").then(() => true, () => false);
        if (!up) await sleep(200);
      }
      assert.ok(up, "anvil started");
      // Fresh throwaway keys (never anvil's defaults, which carry EIP-7702 code on Monad): the password reaches cast
      // through CAST_PASSWORD, never argv.
      const address = {};
      for (const unit of ["grad", "sweeps"]) {
        const pw = randomBytes(24).toString("hex");
        writeFileSync(join(secrets, `${unit}.password`), pw, { mode: 0o400 });
        const made = spawnSync(foundry("cast"), ["wallet", "new", secrets, `${unit}.keystore`], { encoding: "utf8", env: { ...process.env, CAST_PASSWORD: pw } });
        assert.equal(made.status, 0, made.stderr);
        const a = spawnSync(foundry("cast"), ["wallet", "address", "--keystore", join(secrets, `${unit}.keystore`), "--password-file", join(secrets, `${unit}.password`)], { encoding: "utf8" });
        address[unit] = a.stdout.trim().split("\n").pop();
        assert.match(address[unit], /^0x[0-9a-fA-F]{40}$/);
      }
      await rpc(url, "anvil_setBalance", [address.grad, `0x${(12n * MON).toString(16)}`]);
      await rpc(url, "anvil_setBalance", [address.sweeps, `0x${(MON / 2n).toString(16)}`]);
      const pins = pinsFile({ grad: address.grad });
      const check = (extra = []) => runAsync(process.execPath, [join(OPS, "check-signers.mjs"), "--keystores", secrets, "--rpc-url", url, "--signers", pins, ...extra], { PATH: process.env.PATH, HOME: homedir(), CAST_BIN: foundry("cast") });
      let r = await check();
      assert.equal(r.code, 1, r.out);
      assert.match(r.out, new RegExp(`OK grad ${address.grad} holds 12 MON \\(minimum 10\\)`));
      assert.match(r.out, new RegExp(`UNPINNED sweeps ${address.sweeps}`));
      assert.match(r.out, new RegExp(`LOW sweeps ${address.sweeps} holds 0.5 MON, below the sweeps minimum of 1 MON: top it up to 5 MON`));
      for (const unit of ["grad", "sweeps"]) assert.ok(!r.out.includes(readFileSync(join(secrets, `${unit}.password`), "utf8")), "a password was printed");

      if (fork) {
        // The real keeper, through run-keeper.sh, on the fork: the grad unit with its key, sending allowed by hand. Its
        // RPC is the fork only (KEEPER_RPC_URLS), so any transaction stays on 127.0.0.1.
        writeFileSync(join(secrets, "grad.address"), `${address.grad}\n`);
        writeFileSync(join(secrets, "machine.ok"), "fork-rehearsal\n"); // as entrypoint.sh writes it on the pinned Machine
        const data = join(dir, "data");
        mkdirSync(data);
        // macOS has no flock(1): a stand-in that takes no lock (the image has the real one).
        const lockBin = join(dir, "bin");
        mkdirSync(lockBin);
        if (!has("flock")) putExe(lockBin, "flock", "exit 0");
        const env = { PATH: `${lockBin}:${dirname(foundry("cast"))}:${process.env.PATH}`, HOME: dir, KEEPER_APP_DIR: REPO, KEEPER_DATA_DIR: data, KEEPER_SECRETS_DIR: secrets, KEEPER_NODE: process.execPath, KEEPER_RPC_URLS: url };
        const run = await runAsync("bash", [join(OPS, "run-keeper.sh"), "grad", "--manual", "--send"], env);
        for (const line of run.out.trim().split("\n").slice(-12)) t.diagnostic(line);
        assert.ok(/end: keeper exit [02] /.test(run.out), run.out);
        assert.match(run.out, new RegExp(`SEND from ${address.grad}`));
        assert.ok(existsSync(join(data, "state-grad.json")), "the state file was written");
        assert.ok(!run.out.includes(readFileSync(join(secrets, "grad.password"), "utf8")), "the password was printed");
        assert.doesNotMatch(run.out, /\[grad\] .*(MinedRevert|REVERTED|send failed)/, "no failed send on the fork");
      }
    } finally {
      anvil.kill("SIGKILL");
    }
  },
);
