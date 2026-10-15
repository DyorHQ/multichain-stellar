// The owner's files (CT-11a lead decision L-a). Every file lives in a fresh temporary directory; the keys are made
// here, and no message may carry a value.
import { assert, assertEquals, assertFalse, assertStringIncludes, assertThrows, assertRejects } from "jsr:@std/assert@1";
import { Buffer } from "node:buffer";
import { Keypair } from "@stellar/stellar-sdk";
import {
  completeRoles,
  consoleIo,
  createQaKeys,
  KEYS_FILE,
  loadKeysFile,
  loadQaKeys,
  looksLikeSeed,
  parseKeysFile,
  parseRolesFile,
  QA_KEYS_FILE,
  recordingIo,
  redact,
  refuseRoleEnv,
  requireRoles,
  rolesErrors,
  safe,
  secretFromEnvFile,
  secretsDir,
  terminalSafe,
  writeSecretFile,
} from "./owner-files.ts";

const kp = (n: number) => Keypair.fromRawEd25519Seed(Buffer.alloc(32, n));
const ADMIN = kp(1);
const GUARDIAN = kp(2);
const TREASURY = kp(3);
const OTHER = kp(4);

const roles = (o: Record<string, string>) => Object.entries(o).map(([k, v]) => `${k}=${v}`).join("\n") + "\n";
const full = {
  ADMIN_PUBLIC: ADMIN.publicKey(),
  GOVERNANCE_PUBLIC: ADMIN.publicKey(),
  LAUNCHPAD_GUARDIAN_PUBLIC: GUARDIAN.publicKey(),
  MOMENTS_GUARDIAN_PUBLIC: GUARDIAN.publicKey(),
  TREASURY_PUBLIC: TREASURY.publicKey(),
  PLATFORM_PUBLIC: TREASURY.publicKey(),
};

/** No line names a value: no seed, and none of the secrets used here. */
function noValue(messages: string[], ...secrets: string[]) {
  const all = messages.join("\n");
  assertFalse(looksLikeSeed(all), "a message carries something shaped like a seed");
  for (const s of secrets) assertFalse(all.includes(s), "a message carries a secret");
}

Deno.test("roles file: an S-seed is refused by line number, never by value", () => {
  const f = parseRolesFile(`# owner roles\n${roles({ ...full, ADMIN_PUBLIC: ADMIN.secret() })}`);
  assertEquals(f.errors.length, 1);
  assertStringIncludes(f.errors[0], "line 2: holds a secret seed");
  noValue(f.errors, ADMIN.secret());
  // Also in a comment.
  const c = parseRolesFile(`${roles(full)}# old key ${OTHER.secret()}\n`);
  assertStringIncludes(c.errors[0], "line 7: holds a secret seed");
  noValue(c.errors, OTHER.secret());
});

Deno.test("roles file: a name ending in _SECRET or an unknown name is refused by line number", () => {
  const f = parseRolesFile(`${roles(full)}ADMIN_SECRET=xyz\nFOO_PUBLIC=${OTHER.publicKey()}\n`);
  assertEquals(f.errors.length, 2);
  assertStringIncludes(f.errors[0], "line 7: ADMIN_SECRET is a secret's name");
  assertStringIncludes(f.errors[1], "line 8: unknown name FOO_PUBLIC");
  noValue(f.errors);
  const bad = parseRolesFile(`ADMIN_PUBLIC=not-an-address\n`);
  assertEquals(bad.errors, ["testnet-owner-v2.env line 1: ADMIN_PUBLIC is not a valid G-address"]);
  const garbage = parseRolesFile(`this is not an env line ${OTHER.publicKey()}\n`);
  assertEquals(garbage.errors, ["testnet-owner-v2.env line 1: not NAME=value"]);
  const twice = parseRolesFile(`${roles(full)}ADMIN_PUBLIC=${OTHER.publicKey()}\n`);
  assertStringIncludes(twice.errors[0], "line 7: ADMIN_PUBLIC is set twice");
});

Deno.test("roles file: LAUNCHPAD_GUARDIAN = ADMIN and MOMENTS_GUARDIAN = GOVERNANCE are refused", () => {
  const a = parseRolesFile(roles({ ...full, LAUNCHPAD_GUARDIAN_PUBLIC: ADMIN.publicKey() }));
  assertEquals(a.errors, []);
  assertThrows(() => requireRoles(a), Error, "LAUNCHPAD_GUARDIAN_PUBLIC must differ from ADMIN_PUBLIC");
  const g = parseRolesFile(roles({ ...full, MOMENTS_GUARDIAN_PUBLIC: ADMIN.publicKey() }));
  assertThrows(() => requireRoles(g), Error, "MOMENTS_GUARDIAN_PUBLIC must differ from GOVERNANCE_PUBLIC");
});

Deno.test("roles file: GOVERNANCE = ADMIN, one guardian for both roles and PLATFORM = TREASURY are accepted", () => {
  assertEquals(requireRoles(parseRolesFile(roles(full))), full);
  // And all six different, written with export and quotes.
  const six = {
    ADMIN_PUBLIC: ADMIN.publicKey(),
    GOVERNANCE_PUBLIC: OTHER.publicKey(),
    LAUNCHPAD_GUARDIAN_PUBLIC: GUARDIAN.publicKey(),
    MOMENTS_GUARDIAN_PUBLIC: kp(5).publicKey(),
    TREASURY_PUBLIC: TREASURY.publicKey(),
    PLATFORM_PUBLIC: kp(6).publicKey(),
  };
  const text = Object.entries(six).map(([k, v], i) => (i % 2 ? `export ${k}="${v}"` : `${k}=${v} # mine`)).join("\n");
  assertEquals(requireRoles(parseRolesFile(text)), six);
  // Empty roles are reported as empty, not as malformed.
  const partial = parseRolesFile("ADMIN_PUBLIC=\nTREASURY_PUBLIC=" + TREASURY.publicKey() + "\n");
  assertEquals(partial.errors, []);
  assertEquals(partial.empty, ["ADMIN_PUBLIC", "GOVERNANCE_PUBLIC", "LAUNCHPAD_GUARDIAN_PUBLIC", "MOMENTS_GUARDIAN_PUBLIC", "PLATFORM_PUBLIC"]);
  assertEquals(rolesErrors(partial).length, 5);
});

Deno.test("role names set in the environment are refused", () => {
  const env = (vars: Record<string, string>) => (n: string) => vars[n];
  assertThrows(() => refuseRoleEnv(env({ ADMIN_PUBLIC: ADMIN.publicKey() })), Error, "ADMIN_PUBLIC is set in the environment");
  assertThrows(() => refuseRoleEnv(env({ TREASURY_PUBLIC: "x", PLATFORM_PUBLIC: "y" })), Error, "TREASURY_PUBLIC, PLATFORM_PUBLIC are set");
  refuseRoleEnv(env({ DEPLOYER_SECRET: "set", ADMIN_PUBLIC: "" }));
});

Deno.test("keys file: wider than mode 600 is refused; 600 is read; bad lines are named by number only", async () => {
  const dir = await Deno.makeTempDir();
  try {
    const path = `${dir}/${KEYS_FILE}`;
    await Deno.writeTextFile(path, `ADMIN_SECRET=${ADMIN.secret()}\n`);
    await Deno.chmod(path, 0o644);
    await assertRejects(() => loadKeysFile(dir), Error, "mode 644");
    await Deno.chmod(path, 0o640);
    await assertRejects(() => loadKeysFile(dir), Error, "chmod 600");
    await Deno.chmod(path, 0o600);
    assertEquals((await loadKeysFile(dir))!.keys.ADMIN_SECRET!.publicKey(), ADMIN.publicKey());
    await Deno.chmod(path, 0o400);
    assert(await loadKeysFile(dir));
    const bad = parseKeysFile(`ADMIN_SECRET=${ADMIN.secret()}x\nNOPE=${GUARDIAN.secret()}\n`);
    assertEquals(bad.errors.length, 2);
    noValue(bad.errors, ADMIN.secret(), GUARDIAN.secret());
    assertEquals(await loadKeysFile(`${dir}/nothing`), null);
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("completing the roles generates exactly the missing keys and keeps every role and secret already set", () => {
  let n = 10;
  const generate = () => kp(n++);
  // Nothing set: three keys, each filling its pair of roles.
  const fresh = completeRoles(parseRolesFile(""), null, generate);
  assertEquals(fresh.generated, ["ADMIN_SECRET", "GUARDIAN_SECRET", "TREASURY_SECRET"]);
  assertEquals(fresh.roles.GOVERNANCE_PUBLIC, fresh.roles.ADMIN_PUBLIC);
  assertEquals(fresh.roles.MOMENTS_GUARDIAN_PUBLIC, fresh.roles.LAUNCHPAD_GUARDIAN_PUBLIC);
  assertEquals(fresh.roles.PLATFORM_PUBLIC, fresh.roles.TREASURY_PUBLIC);
  assertEquals(requireRoles(parseRolesFile(fresh.rolesText)), fresh.roles);
  const keys = parseKeysFile(fresh.keysText);
  assertEquals(keys.keys.ADMIN_SECRET!.publicKey(), fresh.roles.ADMIN_PUBLIC);

  // The owner brought the admin and the platform: only guardian and treasury are made, and no role is touched.
  const mine = parseRolesFile(`# mine\nADMIN_PUBLIC=${OTHER.publicKey()}\nGOVERNANCE_PUBLIC=\nPLATFORM_PUBLIC=${kp(7).publicKey()}\n`);
  const c = completeRoles(mine, null, generate);
  assertEquals(c.generated, ["GUARDIAN_SECRET", "TREASURY_SECRET"]);
  assertEquals(c.roles.ADMIN_PUBLIC, OTHER.publicKey());
  assertEquals(c.roles.GOVERNANCE_PUBLIC, OTHER.publicKey(), "an empty governance follows the admin, with no key made");
  assertEquals(c.roles.PLATFORM_PUBLIC, kp(7).publicKey());
  assertStringIncludes(c.rolesText, `# mine\nADMIN_PUBLIC=${OTHER.publicKey()}\nGOVERNANCE_PUBLIC=${OTHER.publicKey()}\n`);

  // A second run with both files changes nothing and makes nothing.
  const again = completeRoles(parseRolesFile(c.rolesText), parseKeysFile(c.keysText), generate);
  assertEquals([again.generated, again.filled], [[], []]);
  assertEquals(again.rolesText, c.rolesText);
  assertEquals(again.keysText, c.keysText);

  // A secret in the keys file is reused for its empty role, never replaced.
  const reuse = completeRoles(parseRolesFile(""), parseKeysFile(`ADMIN_SECRET=${ADMIN.secret()}\n`), generate);
  assertEquals(reuse.reused, ["ADMIN_SECRET"]);
  assertEquals(reuse.roles.ADMIN_PUBLIC, ADMIN.publicKey());
  assertEquals(reuse.generated, ["GUARDIAN_SECRET", "TREASURY_SECRET"]);
  assertEquals(reuse.keysText.split(ADMIN.secret()).length, 2, "the admin secret is written once");

  // A keys-file key that isn't the role's: kept, and noted without a value.
  const note = completeRoles(parseRolesFile(roles(full)), parseKeysFile(`ADMIN_SECRET=${OTHER.secret()}\n`), generate);
  assertEquals(note.generated, []);
  assertStringIncludes(note.notes[0], "ADMIN_SECRET in the keys file is not ADMIN_PUBLIC's key");
  noValue(note.notes, OTHER.secret());

  // A broken roles file is refused before anything is generated.
  assertThrows(() => completeRoles(parseRolesFile(`ADMIN_PUBLIC=${ADMIN.secret()}\n`), null, generate), Error, "line 1");
});

Deno.test("secret files are written with mode 600; the QA key file is never overwritten", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await writeSecretFile(`${dir}/x.env`, "A=1\n");
    assertEquals((await Deno.stat(`${dir}/x.env`)).mode! & 0o777, 0o600);
    const qa = await createQaKeys(dir);
    assertEquals((await Deno.stat(`${dir}/${QA_KEYS_FILE}`)).mode! & 0o777, 0o600);
    assertEquals((await loadQaKeys(dir))!.DEPLOYER_SECRET.publicKey(), qa.DEPLOYER_SECRET.publicKey());
    await assertRejects(() => createQaKeys(dir), Error, "never overwritten");
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("a secret read from an env file is checked and never echoed", async () => {
  const dir = await Deno.makeTempDir();
  try {
    await Deno.writeTextFile(`${dir}/f.env`, `SPONSOR_SECRET=${OTHER.secret()}\nexport KEEPER_SECRET="${GUARDIAN.secret()}"\n`);
    assertEquals((await secretFromEnvFile(`${dir}/f.env`, "KEEPER_SECRET"))!.publicKey(), GUARDIAN.publicKey());
    assertEquals(await secretFromEnvFile(`${dir}/f.env`, "DEPLOYER_SECRET"), null);
    assertEquals(await secretFromEnvFile(`${dir}/none.env`, "KEEPER_SECRET"), null);
    await Deno.writeTextFile(`${dir}/g.env`, `KEEPER_SECRET=SBAD${GUARDIAN.secret().slice(4, 20)}\n`);
    const e = await assertRejects(() => secretFromEnvFile(`${dir}/g.env`, "KEEPER_SECRET"), Error, "not a valid secret seed");
    noValue([e.message], GUARDIAN.secret());
  } finally {
    await Deno.remove(dir, { recursive: true });
  }
});

Deno.test("the secrets directory is $DYOR_SECRETS_DIR when it is set", () => {
  assertEquals(secretsDir((n) => (n === "DYOR_SECRETS_DIR" ? "/tmp/x/" : undefined)), "/tmp/x");
  assert(secretsDir(() => undefined).endsWith("/.secrets"));
});

Deno.test("the console redacts anything shaped like a seed and escapes control characters, as a last line of defence", () => {
  const printed: string[] = [];
  const [log, error] = [console.log, console.error];
  console.log = (l: string) => void printed.push(`out ${l}`);
  console.error = (l: string) => void printed.push(`err ${l}`);
  try {
    const io = consoleIo();
    io.out(`oops ${ADMIN.secret()} there`);
    io.err(`${ADMIN.secret()}\nsecond line\x1b[8m`);
  } finally {
    [console.log, console.error] = [log, error];
  }
  assertEquals(printed, ["out oops S…[redacted] there", "err S…[redacted]\nsecond line\\x1b[8m"]);
  assertEquals(redact(ADMIN.publicKey()), ADMIN.publicKey());
});

Deno.test("the test recorder keeps exactly what a script writes, so a leak can't hide behind the console's redaction", () => {
  const io = recordingIo();
  io.out(`oops ${ADMIN.secret()} there`);
  io.err("\x1b[8m");
  assertEquals(io.stdout, [`oops ${ADMIN.secret()} there`]);
  assertEquals(io.stderr, ["\x1b[8m"]);
});

Deno.test("safe() keeps printable ASCII only: controls show as \\xNN, every other character as \\u{…}, a backslash as \\\\", () => {
  assertEquals(safe("a\nb\r\tc\x00\x1b[8m\x7f\x9b"), "a\\x0ab\\x0d\\x09c\\x00\\x1b[8m\\x7f\\u{9b}");
  // The review's look-alikes (craft3.ts n3): Cyrillic у, a right-to-left override, a line separator, the Hangul filler
  // and a combining long stroke. None of them may pass for ASCII or move the text around.
  assertEquals(safe("d\u0443orhq"), "d\\u{443}orhq");
  assertEquals(safe("evil\u202edcba\u200b"), "evil\\u{202e}dcba\\u{200b}");
  assertEquals(safe("a\u2028b\u3164c\u0336d"), "a\\u{2028}b\\u{3164}c\\u{336}d");
  assertEquals(safe("\u{1f600}\ud800"), "\\u{1f600}\\u{d800}", "astral characters and lone surrogates too");
  // A backslash in the text itself can't pass for an escape.
  assertEquals(safe("x\\u{443}"), "x\\\\u{443}");
  assertEquals(safe("set_launches_enabled(false) G…"), "set_launches_enabled(false) G\\u{2026}");
});

Deno.test("terminalSafe() escapes controls, format characters and separators for the console, keeps newlines and the scripts' own marks", () => {
  assertEquals(terminalSafe("one\ntwo\x1b[2J"), "one\ntwo\\x1b[2J");
  assertEquals(terminalSafe("✓ G…ABC → 10 XLM ✗"), "✓ G…ABC → 10 XLM ✗");
  assertEquals(terminalSafe("a\u202eb\u2028c\u2029d\x9b"), "a\\u{202e}b\\u{2028}c\\u{2029}d\\x9b");
});
