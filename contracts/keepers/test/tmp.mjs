// Temporary folders for the keeper tests. Some hold fake keystores, passwords or webhook URLs: every folder made
// through tempDir is removed when the test file's tests end (each test file runs in its own process).
import { after } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const made = [];
after(() => {
  for (const d of made.splice(0)) rmSync(d, { recursive: true, force: true });
});

/** A new folder under the OS temp folder, named `<prefix>XXXXXX`, removed after the file's tests. */
export function tempDir(prefix) {
  const d = mkdtempSync(join(tmpdir(), prefix));
  made.push(d);
  return d;
}
