// Build 17, K1 / E6: the state file (failure counters, throttles, the spend ledger, alert history, log cursors) is
// written atomically and versioned; a corrupt file is moved aside and reported, never silently reset.
import { test } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync, readFileSync, readdirSync, statSync, rmSync } from "node:fs";
import { join } from "node:path";
import { loadState, saveState, STATE_VERSION, RESET_HOLD_S } from "../lib/report.mjs";
import { tempDir } from "./tmp.mjs";

const dir = () => tempDir("keeper-state-");

test("E6: a missing state file is a first run, with no warning", () => {
  const problems = [];
  const s = loadState(join(dir(), "none.json"), { onProblem: (p) => problems.push(p) });
  assert.deepEqual(s, { version: STATE_VERSION });
  assert.deepEqual(problems, []);
  assert.deepEqual(loadState(undefined), { version: STATE_VERSION }, "no --state-file: an in-memory state");
});

test("E6: saveState writes atomically (no temp file left), versioned, owner-only, bigint-safe; loadState reads it back", () => {
  const d = dir();
  const f = join(d, "sub", "state.json");
  saveState(f, { "moment:0xabc:1": { failures: 2 }, cursors: { gov: 123n } });
  assert.deepEqual(readdirSync(join(d, "sub")), ["state.json"]);
  assert.equal(statSync(f).mode & 0o777, 0o600);
  const raw = JSON.parse(readFileSync(f, "utf8"));
  assert.equal(raw.version, STATE_VERSION);
  assert.equal(raw.cursors.gov, "123");
  assert.deepEqual(loadState(f), { "moment:0xabc:1": { failures: 2 }, cursors: { gov: "123" }, version: STATE_VERSION });
  saveState(f, { replaced: true });
  assert.deepEqual(loadState(f), { replaced: true, version: STATE_VERSION }, "a second write replaces the file whole");
  assert.deepEqual(readdirSync(join(d, "sub")), ["state.json"]);
});

test("E6: a state file from before build 17 (no version) is read as version 1", () => {
  const f = join(dir(), "old.json");
  writeFileSync(f, JSON.stringify({ "gov:0xf:unfrozen": { lastAlert: 5 } }));
  const problems = [];
  assert.deepEqual(loadState(f, { onProblem: (p) => problems.push(p) }), { "gov:0xf:unfrozen": { lastAlert: 5 }, version: 1 });
  assert.deepEqual(problems, []);
});

test("E6: a corrupt state file is moved aside and reported, not silently reset; sends are held for a day", () => {
  const at = Date.UTC(2026, 8, 29, 12, 0, 0);
  for (const [body, why] of [
    ['{"moment:0xabc:1": {"failures": 2', /invalid JSON/],
    ["[1,2]", /not a JSON object/],
    ["null", /not a JSON object/],
    [JSON.stringify({ version: 0 }), /version 0, this keeper reads up to 1/],
  ]) {
    const d = dir();
    const f = join(d, "state.json");
    writeFileSync(f, body);
    const problems = [];
    const s = loadState(f, { onProblem: (p) => problems.push(p), now: () => at });
    // The spend ledger of the last 24 hours is lost: no send until it would have left the cap's window anyway.
    assert.deepEqual(s, { version: STATE_VERSION, budget: { heldUntil: at / 1000 + RESET_HOLD_S } });
    assert.equal(RESET_HOLD_S, 86_400);
    assert.equal(problems.length, 1);
    assert.match(problems[0], why);
    assert.match(problems[0], /moved aside to state\.json\.corrupt-20260929T120000Z/);
    assert.match(problems[0], /sends are held until 2026-09-30T12:00:00\.000Z/);
    assert.deepEqual(readdirSync(d), ["state.json.corrupt-20260929T120000Z"]);
    assert.equal(readFileSync(join(d, "state.json.corrupt-20260929T120000Z"), "utf8"), body, "the evidence is kept");
  }
});

test("E6: a state file from a newer keeper (a rollback) stops the run and is left as it is", () => {
  const d = dir();
  const f = join(d, "state.json");
  const body = JSON.stringify({ version: 99, budget: { spend: [{ at: 1, wei: "5" }] } });
  writeFileSync(f, body);
  const problems = [];
  assert.throws(() => loadState(f, { onProblem: (p) => problems.push(p) }), /written by a newer keeper \(version 99; this one reads up to 1\): refusing to run/);
  assert.deepEqual(problems, []);
  assert.deepEqual(readdirSync(d), ["state.json"]);
  assert.equal(readFileSync(f, "utf8"), body);
});

test("E6: a state file that exists but cannot be read stops the run (it would otherwise forget the spend ledger)", () => {
  const d = dir();
  assert.throws(() => loadState(d), /cannot be read \(EISDIR\)/);
});

test("E6: a failed write leaves the previous file whole and no temp file behind", () => {
  const d = dir();
  const f = join(d, "state.json");
  saveState(f, { keep: 1 });
  // The target is now a directory: the rename fails after the temp file was written.
  const blocked = join(d, "blocked");
  saveState(join(blocked, "x.json"), {});
  rmSync(join(blocked, "x.json"));
  writeFileSync(join(blocked, "y"), "");
  assert.throws(() => saveState(blocked, { lost: 1 }), /could not be written/);
  assert.deepEqual(readdirSync(d).sort(), ["blocked", "state.json"]);
  assert.deepEqual(loadState(f), { keep: 1, version: STATE_VERSION });
});
