// Alerts and run state. Alerts always go to stdout; with a webhook they are also posted, deduplicated (notify.mjs).
// The process exit code tells a scheduler what happened: 0 = nothing needs a human, 2 = at least one alert, 1 = the
// keeper itself failed (including: its alerts could not be delivered).
import { closeSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, writeSync } from "node:fs";
import { basename, dirname } from "node:path";

export const EXIT = Object.freeze({ OK: 0, ERROR: 1, ALERT: 2 });

/** `scrub` is applied to every alert reason before it is stored, printed or posted (see redact.mjs): an RPC error can
    quote the endpoint URL, and with it an API key.
    Every alert gets a `key` for the notifier (the call site's stable one, else job:target); `once` marks a one-off
    event. `hold(key)` says a condition still stands without raising it again (a throttled one); `incomplete` names the
    jobs that could not check everything this run, whose alerts therefore cannot count as resolved. */
export function makeReporter({ log = console.log, scrub = (s) => s } = {}) {
  const alerts = [];
  const actions = [];
  const holds = new Set();
  const incomplete = new Set();
  return {
    alerts,
    actions,
    holds,
    incomplete,
    hold: (k) => holds.add(k),
    info: (msg) => log(scrub(`  ${msg}`)),
    action: (a) => {
      actions.push(a);
      log(scrub(`ACTION ${a.job} ${a.target}: ${a.what}`));
    },
    alert: (a) => {
      const clean = { ...a, key: a.key ?? `${a.job}:${a.target}`, reason: scrub(a.reason) };
      alerts.push(clean);
      log(`ALERT [${clean.severity}] ${clean.job} ${clean.target}: ${clean.reason}`);
    },
  };
}

/** The pre-build-17 single POST (`{text, alerts}`), kept for callers outside the keeper run; the run posts through
    notify.mjs. */
export async function postWebhook(url, alerts, { fetchImpl = globalThis.fetch, prefix = "" } = {}) {
  if (!url || alerts.length === 0) return;
  const text = alerts.map((a) => `[${a.severity}] ${a.job} ${a.target}: ${a.reason}`).join("\n");
  const body = JSON.stringify({ text: `${prefix}DyorHQ keeper: ${alerts.length} alert(s)\n${text}`, alerts }, (_, v) => (typeof v === "bigint" ? v.toString() : v));
  const res = await fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`webhook POST failed: ${res.status}`); // never echoes the webhook URL
}

// ------------------------------------------------------------------------------------------------ run state
//
// A small JSON file per scheduled unit: per-target failure counters, alert throttles, and (build 17) the spend ledger,
// log-scan cursors and alert history. Losing it silently would reset the daily spend cap and re-scan or skip blocks,
// so it is written atomically (temp file, fsync, rename) and a file that cannot be parsed is moved aside and reported,
// never silently replaced.

export const STATE_VERSION = 1;

function stamp(ms) {
  return new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d+Z$/, "Z");
}

/** How long sends are held after the state file was reset: the lost spend ledger covered at most the last 24 hours. */
export const RESET_HOLD_S = 86_400;

/**
 * Reads the state file. A missing file is a first run. A file that does not parse or is not a JSON object is renamed
 * to `<file>.corrupt-<time>` and `onProblem` gets a sentence for a critical alert; the run then starts from an empty
 * state whose sends are held for RESET_HOLD_S (`budget.heldUntil`), since the spend of the last 24 hours is lost and
 * the daily cap could otherwise be spent twice. A file written by a newer keeper (`version` above STATE_VERSION, after
 * a rollback) or one that cannot be read at all (permissions) throws: the run fails instead of forgetting.
 */
export function loadState(file, { onProblem = () => {}, now = Date.now } = {}) {
  if (!file) return { version: STATE_VERSION };
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (e) {
    if (e.code === "ENOENT") return { version: STATE_VERSION };
    throw new Error(`state file ${basename(file)} cannot be read (${e.code ?? e.message})`);
  }
  let why;
  let state;
  try {
    state = JSON.parse(text);
    if (!state || typeof state !== "object" || Array.isArray(state)) why = "not a JSON object";
    else if (Number.isInteger(state.version) && state.version > STATE_VERSION) {
      throw Object.assign(new Error(`state file ${basename(file)} was written by a newer keeper (version ${state.version}; this one reads up to ${STATE_VERSION}): refusing to run, so its spend ledger and cursors are not lost. Run the newer keeper again, or move the file aside by hand`), { newer: true });
    } else if (state.version !== undefined && !(Number.isInteger(state.version) && state.version >= 1)) {
      why = `version ${JSON.stringify(state.version)}, this keeper reads up to ${STATE_VERSION}`;
    }
  } catch (e) {
    if (e.newer) throw e;
    why = `invalid JSON: ${e.message.split("\n")[0]}`;
  }
  if (!why) return { ...state, version: STATE_VERSION }; // a file from before build 17 has no version: it is version 1
  const aside = `${file}.corrupt-${stamp(now())}`;
  let moved = true;
  try {
    renameSync(file, aside);
  } catch {
    moved = false;
  }
  const heldUntil = Math.floor(now() / 1000) + RESET_HOLD_S;
  onProblem(`state file ${basename(file)} was unreadable (${why}); ${moved ? `moved aside to ${basename(aside)}` : "could not be moved aside"}. Failure counters, the spend ledger, alert history and log cursors start over from this run, and sends are held until ${new Date(heldUntil * 1000).toISOString()} (the spend of the last 24 hours is unknown)`);
  return { version: STATE_VERSION, budget: { heldUntil } };
}

/** Writes the state atomically: a crash or a full disk leaves the previous file whole. */
export function saveState(file, state) {
  if (!file) return;
  const dir = dirname(file);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp-${process.pid}`;
  const body = `${JSON.stringify({ ...state, version: STATE_VERSION }, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2)}\n`;
  let fd;
  try {
    fd = openSync(tmp, "w", 0o600);
    writeSync(fd, body);
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    renameSync(tmp, file);
  } catch (e) {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {}
    }
    rmSync(tmp, { force: true });
    throw new Error(`state file ${basename(file)} could not be written (${e.code ?? e.message})`);
  }
  try {
    // Make the rename itself durable. Not every platform can fsync a directory; the file is complete either way.
    const dfd = openSync(dir, "r");
    try {
      fsyncSync(dfd);
    } finally {
      closeSync(dfd);
    }
  } catch {}
}
