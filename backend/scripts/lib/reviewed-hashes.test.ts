// The reviewed-WASM gate (decision L16, finding F13): the same check for testnet and testnet-qa.
import { assert, assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1";
import { checkReviewed, describeReviewed, parseReviewed, requireReviewed, sha256Hex } from "./reviewed-hashes.ts";

const wasmA = new TextEncoder().encode("\0asm launchpad-v2 build");
const wasmB = new TextEncoder().encode("\0asm lp-locker build");

async function reviewedFor(files: [string, Uint8Array][], commit = "e324f0c"): Promise<string> {
  const lines = await Promise.all(files.map(async ([f, b]) => `${await sha256Hex(b)}  dist/${f}`));
  return `${lines.join("\n")}\ncommit ${commit}\n`;
}

for (const deployment of ["testnet", "testnet-qa"]) {
  Deno.test(`${deployment}: a missing reviewed file is refused, and the dry run says a real deploy stops there`, async () => {
    const c = checkReviewed(deployment, null, [{ file: "dyor_launchpad_v2.wasm", sha256: await sha256Hex(wasmA) }]);
    assert(!c.ok);
    assert(c.missingFile);
    assertThrows(() => requireReviewed(c), Error, "nothing was deployed");
    assertStringIncludes(describeReviewed(c)[0], "missing: a real deploy stops here");
  });

  Deno.test(`${deployment}: a WASM that differs from the reviewed build by one byte is refused`, async () => {
    const reviewed = await reviewedFor([["dyor_launchpad_v2.wasm", wasmA], ["dyor_lp_locker.wasm", wasmB]]);
    const changed = Uint8Array.from(wasmA);
    changed[changed.length - 1] ^= 1;
    const c = checkReviewed(deployment, reviewed, [
      { file: "dyor_launchpad_v2.wasm", sha256: await sha256Hex(changed) },
      { file: "dyor_lp_locker.wasm", sha256: await sha256Hex(wasmB) },
    ]);
    assert(!c.ok);
    assertEquals(c.rows.map((r) => r.status), ["mismatch", "match"]);
    assertStringIncludes(c.problems[0], "dyor_launchpad_v2.wasm differs from the reviewed build");
    assertThrows(() => requireReviewed(c));
  });

  Deno.test(`${deployment}: a WASM absent from the reviewed list is refused`, async () => {
    const reviewed = await reviewedFor([["dyor_launchpad_v2.wasm", wasmA]]);
    const c = checkReviewed(deployment, reviewed, [
      { file: "dyor_launchpad_v2.wasm", sha256: await sha256Hex(wasmA) },
      { file: "dyor_lp_locker.wasm", sha256: await sha256Hex(wasmB) },
    ]);
    assert(!c.ok);
    assertEquals(c.rows[1].status, "not-reviewed");
    assertThrows(() => requireReviewed(c), Error, "dyor_lp_locker.wasm is not in the reviewed list");
  });

  Deno.test(`${deployment}: an exact match is accepted`, async () => {
    const reviewed = await reviewedFor([["dyor_launchpad_v2.wasm", wasmA], ["dyor_lp_locker.wasm", wasmB]]);
    const c = checkReviewed(deployment, reviewed, [
      { file: "dyor_launchpad_v2.wasm", sha256: await sha256Hex(wasmA) },
      { file: "dyor_lp_locker.wasm", sha256: await sha256Hex(wasmB) },
    ]);
    assert(c.ok, c.problems.join("\n"));
    assertEquals(c.commit, "e324f0c");
    requireReviewed(c);
    assertStringIncludes(describeReviewed(c).at(-1)!, "every WASM matches the reviewed list");
  });

  Deno.test(`${deployment}: a WASM absent from dist is refused even when the list has it`, async () => {
    const reviewed = await reviewedFor([["dyor_launchpad_v2.wasm", wasmA]]);
    const c = checkReviewed(deployment, reviewed, [{ file: "dyor_launchpad_v2.wasm", sha256: null }]);
    assert(!c.ok);
    assertEquals(c.rows[0].status, "absent");
  });
}

Deno.test("the reviewed file takes SHA256SUMS lines with or without a directory, comments and a commit line", () => {
  const h = "ab".repeat(32);
  const r = parseReviewed(`# reviewed by CT-19\n${h}  dist/dyor_a.wasm\n${h.toUpperCase()} *dyor_b.wasm\n\n# commit: 0123abc\n`);
  assertEquals([...r.hashes.entries()], [["dyor_a.wasm", h], ["dyor_b.wasm", h]]);
  assertEquals(r.commit, "0123abc");
  assertThrows(() => parseReviewed(`${h}  dist/dyor_a.wasm\nsomething else\n`), Error, "line 2");
  assertThrows(() => parseReviewed(`${h}  dist/dyor_a.wasm\n${"cd".repeat(32)}  dist/dyor_a.wasm\n`), Error, "listed twice");
  // A malformed reviewed file is a refusal too, not a crash.
  const c = checkReviewed("testnet", "garbage", [{ file: "dyor_a.wasm", sha256: h }]);
  assert(!c.ok);
  assertStringIncludes(c.problems[0], "line 1");
});
