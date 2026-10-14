// Every live and retired deployment the keepers cover, read from contracts/deployments/*.json (the records are
// the source of truth for module addresses). Retired deployments stay covered: their graduations, sweeps and
// buybacks are permissionless and holders there are just as exposed.
//
// The LIVE records are required: a missing, unparsable or wrong-chain 143.json / moments-143.json throws, so the
// keeper exits 1 and pages instead of silently dropping the live stacks. Their factory addresses are also pinned
// here as a second source (`LIVE_FACTORIES`); keeper.mjs raises a critical alert when a record disagrees with the pin
// (for example after a deploy script overwrote it with simulated addresses). Update the pin together with the
// record when a new stack goes live.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const DEPLOYMENTS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "deployments");
export const CHAIN_ID = 143;

/** The live factories as deployed on Monad (the v2 release, 2026-09-28: launchpad v2 and Moments cohort 4). */
export const LIVE_FACTORIES = Object.freeze({
  launchpad: "0x3B1f5f562f5F61B980aBfDDbebD6cdF9a73b0b5b",
  moments: "0x95eb7F5A88B10D9dF32aC54F48C767927fa80840",
});

/** Moments factories left open on chain once retired (owner decision 2026-09-28: the previous stacks are retired in the
    app only, and builds before 16 can still publish there): cohort 3, retired by the v2 release. The governance watch
    reports their open publishing instead of alerting. */
export const OPEN_ON_CHAIN_MOMENTS = Object.freeze(["0x0FD4aC52bbf387DBB3156805769bFC0c260F7E26"]);

// [file, label, required]
const MOMENTS_FILES = [
  ["moments-143.json", "cohort4 (live)", true],
  ["moments-143-cohort3.json", "cohort3 (retired)", false],
  ["moments-143-cohort2.json", "cohort2 (retired)", false],
  ["moments-143-cohort1.json", "cohort1 (retired)", false],
  ["moments-143-v1.1-preview.json", "v1.1-preview (= cohort1)", false],
  ["moments-143-v1.json", "v1 (retired)", false],
];

// `legacyRecord` stacks (0xad3d) predate the venue choice: getLaunchedToken returns 16 fields (no graduationVenue),
// every launch graduates on Monday Trade through `graduationExecutor`, and there is no mondayExecutor() or
// graduateFallback(). The flag comes from the record.
const LAUNCHPAD_FILES = [
  ["143.json", "launchpad (live)", true],
  ["143-retired-0x6B1C.json", "launchpad 0x6B1C (retired)", false],
  ["143-retired-0x10F3.json", "launchpad 0x10F3 (retired)", false],
  ["143-retired-0x2F02.json", "launchpad 0x2F02 (retired)", false],
  ["143-retired-0xad3d.json", "launchpad 0xad3d (retired)", false],
];

function read(dir, file) {
  return JSON.parse(readFileSync(join(dir, file), "utf8"));
}

/** Reads one record. A required record must exist and parse; every record must be for chain 143. */
function load(dir, file, required) {
  let d;
  try {
    d = read(dir, file);
  } catch (e) {
    if (required) throw new Error(`required deployment record ${file} is missing or unreadable (${e.code ?? e.message})`);
    return null;
  }
  if (Number(d.chainId) !== CHAIN_ID) throw new Error(`deployment record ${file} is for chain ${d.chainId}, not ${CHAIN_ID}`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(d.factory ?? "")) throw new Error(`deployment record ${file} has no factory address`);
  return d;
}

/** Moments cohorts, de-duplicated by collect address (v1.1-preview is the cohort-1 record). */
export function momentsCohorts(dir = DEPLOYMENTS) {
  const seen = new Set();
  const out = [];
  for (const [file, label, required] of MOMENTS_FILES) {
    const d = load(dir, file, required);
    if (!d) continue;
    const k = d.collect.toLowerCase();
    if (seen.has(k)) continue;
    seen.add(k);
    const openOnChain = OPEN_ON_CHAIN_MOMENTS.some((f) => f.toLowerCase() === d.factory.toLowerCase());
    out.push({ label, file, live: required, openOnChain, ...d });
  }
  return out;
}

export function launchpads(dir = DEPLOYMENTS) {
  const out = [];
  for (const [file, label, required] of LAUNCHPAD_FILES) {
    const d = load(dir, file, required);
    if (d) out.push({ label, file, live: required, legacyRecord: d.legacyRecord === true, ...d });
  }
  return out;
}

/** Live records whose factory differs from the pin: [{ file, recorded, pinned }]. */
export function pinMismatches({ cohorts, pads }) {
  const out = [];
  for (const [list, pinned] of [
    [pads, LIVE_FACTORIES.launchpad],
    [cohorts, LIVE_FACTORIES.moments],
  ]) {
    for (const r of list.filter((x) => x.live)) {
      if (r.factory.toLowerCase() !== pinned.toLowerCase()) out.push({ file: r.file, recorded: r.factory, pinned });
    }
  }
  return out;
}
