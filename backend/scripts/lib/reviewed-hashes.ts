// The reviewed-WASM gate (docs/DESIGN-stellar-contracts-v2.md §17 step 3, §19.1; decision L16, finding F13).
//
// CT-19's exit writes contracts/review/reviewed-wasm.sha256: the lines of contracts/dist/SHA256SUMS for the reviewed
// v2 WASMs (`<sha256>  dist/<file>.wasm`) plus the commit they were built from. deploy-contracts-v2.ts refuses to
// upload any WASM whose sha256 differs from that file, a WASM the file doesn't list, or a run without the file, for
// testnet-qa and the owner's testnet alike. A dry run prints the comparison instead of stopping.
import { Buffer } from "node:buffer";

export const REVIEWED_FILE = "contracts/review/reviewed-wasm.sha256";

export interface Reviewed {
  /** WASM file name (no directory) → sha256 hex. */
  hashes: Map<string, string>;
  /** The commit the reviewed WASMs were built from, when the file names one. */
  commit: string | null;
}

/** Parses the reviewed file. Accepted lines: `<64 hex>  [*][dir/]<name>.wasm`, a commit line (`commit <sha>` or
 *  `# commit: <sha>`), other `#` comments and blank lines. Anything else, or a name listed twice with two hashes, is an
 *  error naming the line. */
export function parseReviewed(text: string): Reviewed {
  const hashes = new Map<string, string>();
  let commit: string | null = null;
  const lines = text.split(/\r?\n/);
  lines.forEach((raw, i) => {
    const line = raw.trim();
    if (line === "") return;
    const c = line.match(/^#?\s*commit\b[:\s]*([0-9a-f]{7,64})\b/i);
    if (c) {
      commit = c[1].toLowerCase();
      return;
    }
    if (line.startsWith("#")) return;
    const m = line.match(/^([0-9a-fA-F]{64})\s+\*?(?:\S*\/)?([A-Za-z0-9_.-]+\.wasm)$/);
    if (!m) throw new Error(`${REVIEWED_FILE} line ${i + 1}: expected "<sha256>  dist/<name>.wasm"`);
    const [, h, name] = m;
    const prev = hashes.get(name);
    if (prev && prev !== h.toLowerCase()) throw new Error(`${REVIEWED_FILE} line ${i + 1}: ${name} is listed twice`);
    hashes.set(name, h.toLowerCase());
  });
  return { hashes, commit };
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", Uint8Array.from(bytes));
  return Buffer.from(new Uint8Array(digest)).toString("hex");
}

export interface WasmHash {
  file: string;
  /** null when the file is absent from dist. */
  sha256: string | null;
}

export type HashStatus = "match" | "mismatch" | "not-reviewed" | "absent" | "no-reviewed-file";

export interface HashRow extends WasmHash {
  reviewed: string | null;
  status: HashStatus;
}

export interface HashCheck {
  deployment: string;
  ok: boolean;
  /** No reviewed file at all. */
  missingFile: boolean;
  commit: string | null;
  rows: HashRow[];
  /** One line per refusal reason. */
  problems: string[];
}

/** Compares the WASMs a run would upload with the reviewed list. `reviewedText` null: the file is missing. The check
 *  is the same for every deployment (there is no exemption: testnet-qa and testnet alike, F13). */
export function checkReviewed(deployment: string, reviewedText: string | null, wasms: WasmHash[]): HashCheck {
  const problems: string[] = [];
  let reviewed: Reviewed | null = null;
  if (reviewedText === null) {
    problems.push(`${REVIEWED_FILE} is missing: a real deploy stops here (CT-19 writes it when the review exits)`);
  } else {
    try {
      reviewed = parseReviewed(reviewedText);
    } catch (e) {
      problems.push((e as Error).message);
    }
  }
  const rows: HashRow[] = wasms.map((w) => {
    const want = reviewed?.hashes.get(w.file) ?? null;
    let status: HashStatus;
    if (w.sha256 === null) status = "absent";
    else if (!reviewed) status = "no-reviewed-file";
    else if (want === null) status = "not-reviewed";
    else status = want === w.sha256 ? "match" : "mismatch";
    if (status === "absent") problems.push(`${w.file} is absent from contracts/dist`);
    if (status === "not-reviewed") problems.push(`${w.file} is not in the reviewed list`);
    if (status === "mismatch") problems.push(`${w.file} differs from the reviewed build (sha256 ${w.sha256}, reviewed ${want})`);
    return { ...w, reviewed: want, status };
  });
  return { deployment, ok: problems.length === 0, missingFile: reviewedText === null, commit: reviewed?.commit ?? null, rows, problems };
}

/** For a real run: throws with every problem when the check fails. */
export function requireReviewed(check: HashCheck): void {
  if (!check.ok) {
    throw new Error(`reviewed-hash check failed for ${check.deployment}; nothing was deployed:\n  ${check.problems.join("\n  ")}`);
  }
}

/** The dry run's lines. */
export function describeReviewed(check: HashCheck): string[] {
  const out: string[] = [];
  if (check.missingFile) out.push(`missing: a real deploy stops here (${REVIEWED_FILE} is written by CT-19)`);
  else out.push(`${REVIEWED_FILE}${check.commit ? ` (built from ${check.commit})` : ""}`);
  for (const r of check.rows) {
    const label = {
      match: "✓ matches the reviewed hash",
      mismatch: `✗ differs from the reviewed hash ${r.reviewed}`,
      "not-reviewed": "✗ not in the reviewed list",
      absent: "✗ absent from dist",
      "no-reviewed-file": "– nothing to compare with",
    }[r.status];
    out.push(`  ${r.file.padEnd(30)} ${r.sha256 ?? "-".padEnd(64)}  ${label}`);
  }
  out.push(check.ok ? "  ✓ every WASM matches the reviewed list" : "  ✗ a real deploy stops here");
  return out;
}
