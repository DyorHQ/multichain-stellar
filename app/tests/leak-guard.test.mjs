import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash, randomBytes, randomInt } from "node:crypto";
import { appendFileSync, chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

/* The leak guard (scripts/dev/secret-scan.sh, scripts/dev/forbidden-paths.sh, scripts/dev/install-hooks.sh and the
   .githooks/ they install) exercised in throwaway repositories. Every secret below is FAKE, generated at run time —
   never test with real values — and no output may contain one. */
const root = fileURLToPath(new URL("..", import.meta.url));
const GUARD = ["scripts/dev/secret-scan.sh", "scripts/dev/forbidden-paths.sh", "scripts/dev/install-hooks.sh",
  "scripts/dev/bip39-english.txt", ".githooks/pre-commit", ".githooks/pre-merge-commit", ".githooks/commit-msg",
  ".githooks/pre-push", ".leakguard"];

const ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const pick = (chars, n) => Array.from({ length: n }, () => chars[randomInt(chars.length)]).join("");
const alnum = (n) => pick(ALNUM, n);
const upper = (n) => pick("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", n);
const digits = (n) => pick("123456789", 1) + pick("0123456789", n - 1);
const hex = (bytes) => randomBytes(bytes).toString("hex");
const uuid = () => [hex(4), hex(2), hex(2), hex(2), hex(6)].join("-");
const b64url = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const jwt = (payload) => `${b64url({ alg: "HS256", typ: "JWT" })}.${b64url(payload)}.${randomBytes(32).toString("base64url")}`;

const scannerSource = readFileSync(path.join(root, "scripts/dev/secret-scan.sh"), "utf8");
// The public test keys the scanner masks (anvil/hardhat and the fork-only dev keys), read from the scanner itself.
const publicKeys = scannerSource.slice(scannerSource.indexOf("PUBLIC_TEST_KEYS="), scannerSource.indexOf("| tr ' ' '|'))\"")).match(/[0-9a-f]{64}/g);
// Frequent English words: a run of mostly these is a sentence to the scanner, so fake phrases avoid them.
const common = new Set(scannerSource.slice(scannerSource.indexOf("COMMON_WORDS=$(echo"), scannerSource.indexOf("usage() {")).match(/[a-z]+/g));
const words = readFileSync(path.join(root, "scripts/dev/bip39-english.txt"), "utf8").trim().split("\n");
const rare = words.filter((w) => !common.has(w));
function seedWords(n = 12) {
  for (;;) {
    const p = Array.from({ length: n }, () => rare[randomInt(rare.length)]);
    if (new Set(p).size >= Math.min(10, n) && p.some((w, i) => i > 0 && w <= p[i - 1])) return p;
  }
}
const seedPhrase = (n = 12) => seedWords(n).join(" ");

let dir, env, fakeEnvValue;
const secretsSeen = []; // every fake value that must never be printed
const fake = (v) => (secretsSeen.push(v), v);
const run = (cmd, args, cwd, extraEnv = {}) => {
  const r = spawnSync(cmd, args, { cwd, env: { ...env, ...extraEnv }, encoding: "utf8" });
  const out = `${r.stdout}${r.stderr}`;
  for (const s of secretsSeen) assert.ok(!out.includes(s), `a fake secret value was printed by ${cmd} ${args.join(" ")}`);
  return { status: r.status, out };
};
const git = (cwd, ...args) => run("git", args, cwd);
const write = (repo, file, data) => {
  mkdirSync(path.dirname(path.join(repo, file)), { recursive: true });
  writeFileSync(path.join(repo, file), data);
};
// The test repositories push to local bare remotes, which IOS-app's @push-url line would refuse.
const anyRemote = (t) => t.replace(/^@push-url .*$/gm, "@push-url *");
function newRepo(name, { withGuard = true, leakguard = anyRemote } = {}) {
  const repo = path.join(dir, name);
  mkdirSync(repo);
  git(repo, "init", "-q", "-b", "main");
  if (withGuard) {
    for (const f of GUARD) {
      mkdirSync(path.dirname(path.join(repo, f)), { recursive: true });
      copyFileSync(path.join(root, f), path.join(repo, f));
      if (!f.endsWith(".txt") && f !== ".leakguard") chmodSync(path.join(repo, f), 0o755);
    }
    write(repo, ".leakguard", leakguard(readFileSync(path.join(root, ".leakguard"), "utf8")));
    git(repo, "add", "--", ...GUARD);
    assert.equal(git(repo, "commit", "-q", "-m", "leak guard").status, 0);
  }
  return repo;
}
const scan = (repo, ...args) => run("/bin/bash", [path.join(repo, "scripts/dev/secret-scan.sh"), ...args], repo);
const paths = (repo, ...args) => run("/bin/bash", [path.join(repo, "scripts/dev/forbidden-paths.sh"), ...args], repo);
const installHooks = (repo, ...args) => run("/bin/bash", [path.join(repo, "scripts/dev/install-hooks.sh"), ...args], repo);
const bareRemote = (name) => {
  const remote = path.join(dir, `${name}.git`);
  git(dir, "init", "-q", "--bare", remote);
  return remote;
};

before(() => {
  dir = mkdtempSync(path.join(tmpdir(), "leak-guard-test-"));
  const globalConfig = path.join(dir, "gitconfig");
  writeFileSync(globalConfig, "[user]\n\tname = Leak Guard Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n");
  fakeEnvValue = fake(`fake_${alnum(28)}`);
  const envFile = path.join(dir, "fake.env");
  writeFileSync(envFile, `FAKE_API_KEY=${fakeEnvValue}\nNEXT_PUBLIC_SITE=https://example.invalid\n`);
  // Only the fake env file is a value source, and neither the user's git config nor a hook manager takes part.
  env = { ...process.env, SECRET_SCAN_ENV: envFile, GIT_CONFIG_GLOBAL: globalConfig, GIT_CONFIG_NOSYSTEM: "1" };
  delete env.SECRET_SCAN_XCCONFIG;
  delete env.SECRET_SCAN_EXTRA_SOURCES;
  delete env.BASH_ENV;
});
after(() => rmSync(dir, { recursive: true, force: true }));

test("every secret pattern and heuristic fires, and no value is printed", () => {
  const repo = newRepo("patterns");
  // Each random part is registered with fake(): no output may contain it.
  const cases = [
    ["Alchemy keyed RPC URL", `https://monad-mainnet.g.alchemy.com/v2/${fake(alnum(32))}`],
    ["Infura keyed RPC URL", `https://mainnet.infura.io/v3/${fake(hex(16))}`],
    ["QuickNode keyed RPC URL", `https://x.monad-mainnet.quiknode.pro/${fake(hex(20))}/`],
    ["Chainstack keyed RPC URL", `MONAD_RPC=https://monad-mainnet.core.chainstack.com/${fake(hex(16))}`],
    ["dRPC keyed RPC URL (dkey=)", `https://lb.drpc.org/ogrpc?network=monad&dkey=${fake(alnum(30))}`],
    ["Ankr keyed RPC URL", `https://rpc.ankr.com/monad/${fake(hex(32))}`],
    ["Blast API keyed RPC URL", `https://monad.blastapi.io/${fake(uuid())}`],
    ["GetBlock keyed RPC URL", `https://go.getblock.io/${fake(hex(16))}`],
    ["NodeReal keyed RPC URL", `https://monad.nodereal.io/v1/${fake(hex(16))}`],
    ["Tenderly keyed RPC URL", `https://monad.gateway.tenderly.co/${fake(alnum(24))}`],
    ["keyed RPC URL (key in the path)", `const rpc = "https://rpc.monad-node.invalid/v2/${fake(hex(16))}";`],
    ["Pimlico keyed URL (apikey=)", `https://api.pimlico.io/v2/143/rpc?apikey=${fake(alnum(24))}`],
    ["Pimlico API key (pim_)", `const bundler = "pim_${fake(alnum(22))}";`],
    ["API key or token in a URL query (apikey= / key= / access_token=)", `https://api.example.invalid/v1?api_key=${fake(alnum(24))}`],
    ["PEM private key", `-----BEGIN EC ${"PRIVATE"} KEY-----${fake(alnum(16))}`],
    ["age secret key", `AGE-SECRET-${"KEY"}-1${fake(upper(58))}`],
    ["private key assignment (KEY=0x + 64 hex)", `DEPLOYER_KEY=0x${fake(hex(32))}`],
    ["private key assignment (KEY=0x + 64 hex)", `  uint256 deployerKey = 0x${fake(hex(32))};`],
    ["private key assignment (private_key / --private-key + 64 hex)", `cast send --private-key ${fake(hex(32))} 0x1`],
    ["private key assignment (private_key / --private-key + 64 hex)", `export PRIVATE_KEY=0X${fake(hex(32).toUpperCase())}`],
    ["Supabase secret key (sb_secret_)", `sb_${"secret"}_${fake(alnum(32))}`],
    ["Supabase access token (sbp_)", `token: sbp_${fake(hex(20))}`],
    ["Supabase service_role JWT", fake(jwt({ iss: "supabase", ref: alnum(20).toLowerCase(), role: "service_role" }))],
    ["JSON Web Token", `Authorization: Bearer ${fake(jwt({ sub: alnum(12), iat: 1790000000 }))}`],
    ["Privy app secret (privy_app_secret_)", `privy_app_${"secret"}_${fake(alnum(40))}`],
    ["Privy authorization key (wallet-auth:)", `wallet-auth:${fake(randomBytes(48).toString("base64"))}`],
    ["GitHub token (ghp_/gho_/ghs_/ghu_/ghr_)", `gh${"p"}_${fake(alnum(36))}`],
    ["GitHub fine-grained token (github_pat_)", `github_${"pat"}_${fake(alnum(22))}_${fake(alnum(59))}`],
    ["AWS access key id (AKIA/ASIA)", `aws_access_key_id = AK${"IA"}${fake(upper(16))}`],
    ["AWS secret access key assignment", `aws_secret_access_key = ${fake(alnum(40))}`],
    ["Slack token (xox*)", `xox${"b"}-${digits(12)}-${fake(alnum(24))}`],
    ["Slack webhook URL", `https://hooks.slack.com/services/T${upper(8)}/B${upper(8)}/${fake(alnum(24))}`],
    ["Discord webhook URL", `https://discord.com/api/webhooks/${digits(18)}/${fake(alnum(68))}`],
    ["Stripe live key (sk_live_/rk_live_)", `sk_${"live"}_${fake(alnum(24))}`],
    ["Anthropic API key (sk-ant-)", `sk-${"ant"}-api03-${fake(alnum(80))}`],
    ["OpenAI API key (sk-proj-/sk-svcacct-/sk-admin-)", `sk-${"proj"}-${fake(alnum(48))}`],
    ["OpenAI-style API key (sk-…)", `key: sk-${fake(alnum(48))}`],
    ["Google API key (AIza)", `AI${"za"}${fake(alnum(35))}`],
    ["npm token (npm_)", `//registry.npmjs.org/:_authToken=npm_${fake(alnum(36))}`],
    ["Telegram bot token", `bot ${digits(10)}:AA${fake(alnum(33))}`],
    ["known secret variable with a literal value", `AURORA_API_KEY=${fake(alnum(32))}`],
    ["UUID given to a key-named variable", `let auroraKey = "${fake(uuid())}"`],
    ["BIP-39 seed phrase (12+ wordlist words)", `const phrase = "${fake(seedPhrase(12))}";`],
    ["32-byte hex key passed to a key or wallet constructor", `const account = privateKeyToAccount("0x${fake(hex(32))}");`],
    ["32-byte hex key after a key-like name", `const deployerKey = "0x" + "${fake(hex(16))}" + "${fake(hex(16))}";`],
    ["32-byte hex key after a key-like name", `RELAYER_PK=0x${fake(hex(32))}`],
    ["32-byte hex key after a key-like name", `| Treasury | 0x${fake(hex(32))} |`],
    ["32-byte hex key after a key-like name", `    vm.startBroadcast(0x${fake(hex(32))});`],
    ["32-byte hex key after a key-like name", `wallet: ${fake(hex(32))}`],
    ["FAKE_API_KEY (fake.env)", `const k = "${fakeEnvValue}";`],
  ];
  const lines = cases.map(([, text]) => text);
  const arrayStart = lines.length + 1;
  const arrayKey = fake(hex(32));
  write(repo, "src/leaky.ts", `${lines.join("\n")}\nconst signerKeys = [\n  "0x${arrayKey}",\n];\n`);
  // Seed phrases over several lines, numbered, joined by hyphens or as a JSON array.
  const multi = {
    "notes/seed-lines.txt": fake(seedWords(24).join("\n")),
    "notes/seed-numbered.md": seedWords(24).map((w, i) => `${i + 1}. ${w}`).join(" "),
    "notes/seed-hyphen.txt": fake(seedWords(24).join("-")),
    "notes/seed-rows.txt": [0, 1, 2].map(() => fake(seedWords(8).join(" "))).join("\n"),
    "app/mnemonic.json": `{\n  "words": [\n${seedWords(12).map((w) => `    "${w}"`).join(",\n")}\n  ]\n}`,
  };
  for (const [f, text] of Object.entries(multi)) write(repo, f, `${text}\n`);
  git(repo, "add", "src/leaky.ts", ...Object.keys(multi));
  const { status, out } = scan(repo, "--staged");
  assert.equal(status, 1, out);
  cases.forEach(([name], i) => assert.ok(out.includes(`src/leaky.ts:${i + 1}: ${name}`), `${name} (line ${i + 1}) did not fire:\n${out}`));
  assert.ok(out.includes(`src/leaky.ts:${arrayStart + 1}: 32-byte hex key in a key-named array`), out);
  for (const f of Object.keys(multi)) assert.match(out, new RegExp(`${f.replace(/\./g, "\\.")}:\\d+: BIP-39 seed phrase`), `${f}:\n${out}`);

  // --all reads the same files from the working tree, --path from the directory.
  git(repo, "commit", "-q", "--no-verify", "-m", "fake secrets");
  for (const args of [["--all"], ["--path", "src"]]) {
    const r = scan(repo, ...args);
    assert.equal(r.status, 1, r.out);
    for (const [name] of cases) assert.ok(r.out.includes(name), `${args[0]}: ${name} missing:\n${r.out}`);
  }
});

test("public identifiers, placeholders, prose and UI word lists do not fire", () => {
  const repo = newRepo("public");
  const [anvil0] = publicKeys;
  const forkKey = publicKeys[publicKeys.length - 1];
  const anonKey = jwt({ iss: "supabase", ref: alnum(20).toLowerCase(), role: "anon", iat: 1700000000, exp: 2000000000 });
  const exampleJwt = `${b64url({ alg: "HS256", typ: "JWT" })}.${Buffer.from('{"sub":"1234567890","name":"John Doe","iat":1516239022}').toString("base64url")}.${alnum(43)}`;
  const tabs = rare.filter((w, i) => i % 97 === 5).slice(0, 13).reverse(); // 13 quoted words, as a UI tab list
  const text = [
    `export const SUPABASE_ANON_KEY = "${anonKey}";`,
    `const publishable = "sb_publishable_${alnum(31)}";`,
    `const factory = "0x${hex(20)}"; const DEPLOYER = "0x${hex(20)}";`,
    `const anvil = privateKeyToAccount("0x${anvil0}");`,
    `const keys = ["0x${anvil0}", "0x${forkKey}"];`,
    `const topics = ["0x${hex(32)}", "0x${hex(32)}"];`,
    `const txHash = "0x${hex(32)}";`,
    "const mnemonic = \"test test test test test test test test test test test junk\";",
    "const vector = \"abandon amount liar amount expire adjust cage candy arch gather drum bullet absurd math era live bid rhythm alien crouch range attend journey unaware\";",
    `const list = "${words.slice(100, 140).join(" ")}";`,
    `const example = "AKIA${"IOSFODNN7EXAMPLE"}";`,
    "AURORA_API_KEY=<your aurora key>",
    "AURORA_API_KEY=${AURORA_API_KEY}",
    "AURORA_API_KEY=your-aurora-api-key-here",
    "const url = \"https://monad-mainnet.g.alchemy.com/v2/YOUR_ALCHEMY_API_KEY\";",
    "https://api.pimlico.io/v2/143/rpc?apikey=YOUR_API_KEY",
    "https://api.example.invalid/v1?api_key=REPLACE_WITH_YOUR_KEY",
    `PRIVATE_KEY=0x${"0".repeat(64)}`,
    `const tokenForDocs = "${exampleJwt}";`,
    `static let publicKey = 0x${hex(32)}`,
    'const AURORA_API_KEY = Deno.env.get("AURORA_API_KEY");',
    `const tabs = [${tabs.map((w) => `"${w}"`).join(", ")}];`,
    "// You can also sell any token that you hold, open more long or short order limit",
    "Recovery words are shown once: write them down and keep them offline, never in a screenshot.",
  ].join("\n");
  write(repo, "app/public.ts", `${text}\n`);
  write(repo, ".env.example", "PINATA_JWT=\nAURORA_API_KEY=\n");
  git(repo, "add", "app/public.ts", ".env.example");
  const staged = scan(repo, "--staged");
  assert.equal(staged.status, 0, staged.out);
  assert.equal(paths(repo, "--staged").status, 0);
  git(repo, "commit", "-q", "--no-verify", "-m", "public values");
  const all = scan(repo, "--all");
  assert.equal(all.status, 0, all.out);
});

test("test vectors need a reviewed @allow line, committed before them", () => {
  const repo = newRepo("vectors");
  const vectors = `const attemptKeys = [\n  "0x${fake(hex(32))}",\n];\nconst account = privateKeyToAccount("0x${fake(hex(32))}");\n`;
  write(repo, "tests/vectors.test.mjs", vectors);
  git(repo, "add", "tests/vectors.test.mjs");
  let r = scan(repo, "--staged");
  assert.equal(r.status, 1, "test directories are no longer exempt");
  assert.match(r.out, /tests\/vectors\.test\.mjs:2: 32-byte hex key in a key-named array/);

  // In the same commit as the vectors, an @allow line does not count yet.
  appendFileSync(path.join(repo, ".leakguard"), [
    "@allow tests/*.test.mjs 32-byte hex key in a key-named array",
    "@allow tests/*.test.mjs 32-byte hex key passed to a key or wallet constructor",
    "@allow tests/*.test.mjs FAKE_API_KEY (fake.env)", // values from .env can never be allowed
    "",
  ].join("\n"));
  git(repo, "add", ".leakguard");
  assert.equal(scan(repo, "--staged").status, 1, "a commit allowed its own finding");
  git(repo, "reset", "-q", "--", "tests/vectors.test.mjs");
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "allow the test vectors").status, 0);

  write(repo, "tests/vectors.test.mjs", `${vectors}const k = "${fakeEnvValue}";\n`);
  git(repo, "add", "tests/vectors.test.mjs");
  r = scan(repo, "--staged");
  assert.equal(r.status, 1, r.out);
  assert.doesNotMatch(r.out, /vectors\.test\.mjs:\d+: 32-byte hex key/, "the allowed findings still fired");
  assert.match(r.out, /tests\/vectors\.test\.mjs:5: FAKE_API_KEY \(fake\.env\)/, "a value was allowed");
  assert.match(r.out, /2 finding\(s\) allowed by \.leakguard @allow/);
  assert.match(r.out, /"@allow tests\/\*\.test\.mjs FAKE_API_KEY \(fake\.env\)": no finding has that name; ignored/);
});

test("archives, office files and UTF-16 text are unpacked and checked", () => {
  const repo = newRepo("archives");
  const work = path.join(dir, "archive-src");
  mkdirSync(work, { recursive: true });
  const keyLine = () => `PRIVATE_KEY=0x${fake(hex(32))}\n`;
  const py = (code) => {
    const r = run("python3", ["-c", code], work);
    assert.equal(r.status, 0, r.out);
  };
  writeFileSync(path.join(work, "k1.txt"), keyLine());
  writeFileSync(path.join(work, "k2.txt"), keyLine());
  writeFileSync(path.join(work, "k3.xml"), `<w:t>${keyLine()}</w:t>`);
  writeFileSync(path.join(work, "k4.txt"), keyLine());
  // A zip under a name that is not .zip, a zip inside a zip, and an office document (a zip of XML).
  py(`import zipfile
with zipfile.ZipFile("data.bin", "w", zipfile.ZIP_DEFLATED) as z: z.write("k1.txt")
with zipfile.ZipFile("inner.zip", "w", zipfile.ZIP_DEFLATED) as z: z.write("k2.txt")
with zipfile.ZipFile("outer.zip", "w", zipfile.ZIP_DEFLATED) as z: z.write("inner.zip")
with zipfile.ZipFile("report.docx", "w", zipfile.ZIP_DEFLATED) as z: z.write("k3.xml", "word/document.xml")`);
  assert.equal(run("tar", ["-czf", "k4.tar.gz", "k4.txt"], work).status, 0);
  const files = {
    "assets/data.bin": readFileSync(path.join(work, "data.bin")),
    "assets/outer.zip": readFileSync(path.join(work, "outer.zip")),
    "assets/report.docx": readFileSync(path.join(work, "report.docx")),
    "assets/k4.tar.gz": readFileSync(path.join(work, "k4.tar.gz")),
    "assets/k5.log.gz": gzipSync(Buffer.from(keyLine())),
    "assets/strings.txt": Buffer.from(`﻿${keyLine()}`, "utf16le"),
    "assets/broken.zip": Buffer.concat([Buffer.from("PK\x03\x04"), randomBytes(64)]),
  };
  for (const [f, data] of Object.entries(files)) write(repo, f, data);
  git(repo, "add", ...Object.keys(files));
  const r = scan(repo, "--staged");
  assert.equal(r.status, 1, r.out);
  for (const f of ["data.bin", "outer.zip", "report.docx", "k4.tar.gz", "k5.log.gz"]) {
    assert.match(r.out, new RegExp(`assets/${f.replace(/\./g, "\\.")} \\(inside the archive\\): private key assignment`), `${f}:\n${r.out}`);
  }
  assert.match(r.out, /assets\/strings\.txt \(UTF-16 text\): private key assignment/);
  assert.match(r.out, /assets\/broken\.zip: compressed archive that cannot be unpacked for scanning/);
  git(repo, "commit", "-q", "--no-verify", "-m", "archives");
  const h = scan(repo, "--history", "HEAD^..HEAD");
  assert.equal(h.status, 1);
  assert.match(h.out, /[0-9a-f]+:assets\/outer\.zip \(inside the archive\): private key assignment/);
  const all = scan(repo, "--all");
  assert.match(all.out, /assets\/data\.bin \(inside the archive\): private key assignment/);
});

test("forbidden-paths: secrets and internal documents are denied, developer files are not", () => {
  const cfg = path.join(root, ".leakguard");
  const denied = [".env", "app/.env.production", "prod.env", ".dev.vars", "ios/DyorHQ/Config/Secrets.xcconfig",
    "AuthKey_ABC.p8", "certs/dist.p12", "key.pem", "id_ed25519", "build/DyorHQ-1.0-14.xcarchive/Info.plist", "DyorHQ.ipa",
    ".claude/settings.local.json", "ios/.claude/settings.local.json", "HANDOFF.md", "notes/owner-RUNBOOK.md",
    "docs/security-audit-2026-09-26/REPORT.md", "Docs/Security-Audit-2027/checklist.md", "docs/moments-spec.md",
    "ios/docs/mera/MERA-PLAN.md", "reviews/moments-security-review.md", "contracts/deployments/relaunch.log",
    "contracts/broadcast/Deploy.s.sol/143/run-latest.json", "contracts/cache/Deploy.s.sol/143/run-latest.json",
    "notes/relaunch-2026-10-01.md", "decisions.md", "CLAUDE.local.md",
    // copies and renames of secret files
    ".env copy", ".env-prod", ".env_local", ".env~", "deploy.env.txt", ".envrc", ".dev.vars.production",
    "Secrets.xcconfig.bak", "ios/Secrets copy.xcconfig", "Secrets-Release.xcconfig", "keys/deployer.key.txt",
    "keys/AuthKey_X.p8.txt", "wallet.json", "keystore/UTC--2026-09-27T00-00-00.000Z--1111", "contracts/.ENV",
    // internal documents outside docs/, and transcripts
    "REPORT.md", "scratch/REPORT.md", "findings.json", "contracts/AUDIT.md", "notes/launchpad-audit-2026-09-26.md",
    "SECURITY_REVIEW.md", "Security Review.md", "HAND-OFF.md", "app/VULNERABILITIES.md", "supabase/threat-model.md",
    "relaunch-notes.txt", "notes/confidential.txt", "session.jsonl", "notes/export.pdf"];
  const allowed = [".env.example", ".env.sample", ".env.template", ".env.local.example", ".dev.vars.example",
    "ios/DyorHQ/Config/Secrets.example.xcconfig", "docs/README.md", "docs/app-wiring.md",
    "docs/swap-spec.md", "contracts/test/audit/Z_LiveDeployment.t.sol", "contracts/script/relaunch/relaunch-new-wallets.sh",
    "contracts/deployments/143.json", ".claude/settings.json", ".claude/launch.json", "CLAUDE.md",
    "supabase/migrations/23_default_privileges_least_privilege.sql", "public/brand/dyorhq-brand-guide.md",
    "tests/web-security.test.mjs", "contracts/keepers/lib/report.mjs", "ios/README.md",
    "ios/DyorHQ/App/HandoffActivity.swift", "ios/Handoff.plist", "app/RunbookLink.tsx", "contracts/src/AuditReporter.sol",
    "src/RelaunchBanner.tsx", "public/incident-free.svg", "public/decisions-matrix.png"];
  const r = run("/bin/bash", [path.join(root, "scripts/dev/forbidden-paths.sh"), "--config", cfg, "--check", ...denied, ...allowed], dir);
  assert.equal(r.status, 1);
  for (const p of denied) assert.ok(r.out.includes(`${p}: forbidden path`), `${p} was not denied:\n${r.out}`);
  for (const p of allowed) assert.ok(!r.out.includes(`${p}: forbidden path`), `${p} was denied:\n${r.out}`);
  const clean = run("/bin/bash", [path.join(root, "scripts/dev/forbidden-paths.sh"), "--config", cfg, "--check", ...allowed], dir);
  assert.equal(clean.status, 0, clean.out);

  // Braces, root anchors and @only.
  const policy = path.join(dir, "policy.leakguard");
  writeFileSync(policy, "*notes*.{md,txt}\n@only /README.md\n@only /src/*.{ts,tsx}\n@only /notes/*\n");
  const p2 = run("/bin/bash", [path.join(root, "scripts/dev/forbidden-paths.sh"), "--config", policy, "--check",
    "README.md", "src/a.ts", "src/b.tsx", "docs/README.md", "index.html", "notes/notes.md", "notes/x.png"], dir);
  assert.equal(p2.status, 1);
  for (const p of ["docs/README.md", "index.html"]) assert.ok(p2.out.includes(`${p}: forbidden path (not in the .leakguard @only list)`), p2.out);
  assert.ok(p2.out.includes('notes/notes.md: forbidden path (matches "*notes*.md")'), p2.out);
  for (const p of ["README.md", "src/a.ts", "src/b.tsx", "notes/x.png"]) {
    assert.ok(!p2.out.split("\n").some((l) => l.startsWith(`${p}:`)), `${p} was denied:\n${p2.out}`);
  }
});

test("the hooks block forbidden paths and secrets in commits and pushes; a clean commit passes", () => {
  const repo = newRepo("hooks");
  const inst = installHooks(repo);
  assert.equal(inst.status, 0, inst.out);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").out.trim(), ".githooks");
  assert.equal(installHooks(repo, "--check").status, 0);

  // A forbidden path.
  write(repo, "HANDOFF.md", "# where things stand\n");
  git(repo, "add", "HANDOFF.md");
  let c = git(repo, "commit", "-m", "handoff");
  assert.notEqual(c.status, 0, "a HANDOFF.md commit went through");
  assert.match(c.out, /HANDOFF\.md: forbidden path/);
  git(repo, "rm", "-q", "--cached", "HANDOFF.md");

  // An env file with a fake secret: both checkers refuse it.
  write(repo, ".env", `SERVICE_TOKEN=${fake(alnum(40))}\n`);
  git(repo, "add", "-f", ".env");
  c = git(repo, "commit", "-m", "env");
  assert.notEqual(c.status, 0, "a .env commit went through");
  assert.match(c.out, /\.env: forbidden path/);
  assert.match(c.out, /\.env: env file must not be committed/);
  git(repo, "rm", "-q", "--cached", ".env");

  // A fake key in code.
  write(repo, "src/deploy.ts", `export const DEPLOYER_KEY = "0x${fake(hex(32))}";\n`);
  git(repo, "add", "src/deploy.ts");
  c = git(repo, "commit", "-m", "key");
  assert.notEqual(c.status, 0, "a commit with a fake key went through");
  assert.match(c.out, /src\/deploy\.ts:1: private key assignment/);
  git(repo, "rm", "-q", "--cached", "src/deploy.ts");

  // A clean commit.
  write(repo, "src/ok.ts", "export const ok = 1;\n");
  git(repo, "add", "src/ok.ts");
  c = git(repo, "commit", "-m", "clean");
  assert.equal(c.status, 0, c.out);

  // --no-verify skips the commit hooks, so the push is refused instead, and history scans find it.
  const remote = bareRemote("remote");
  git(repo, "remote", "add", "origin", remote);
  write(repo, "src/deploy.ts", `export const DEPLOYER_KEY = "0x${fake(hex(32))}";\n`);
  write(repo, "docs/owner-runbook.md", "# steps\n");
  git(repo, "add", "src/deploy.ts", "docs/owner-runbook.md");
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "sneaky").status, 0);
  const p = git(repo, "push", "-q", "origin", "main");
  assert.notEqual(p.status, 0, "a push with a fake key went through");
  assert.match(p.out, /src\/deploy\.ts:1: private key assignment/);
  assert.match(p.out, /docs\/owner-runbook\.md: forbidden path/);
  assert.equal(git(remote, "rev-parse", "-q", "--verify", "refs/heads/main").status, 1, "the remote received the branch");
  const h = scan(repo, "--history", "--all");
  assert.equal(h.status, 1);
  assert.match(h.out, /[0-9a-f]+:src\/deploy\.ts:1: private key assignment/);
  const hp = paths(repo, "--history", "--all");
  assert.equal(hp.status, 1);
  assert.match(hp.out, /[0-9a-f]+:docs\/owner-runbook\.md: forbidden path/);
});

test("a commit cannot exempt itself: .leakguard counts only once committed", () => {
  const repo = newRepo("self-exempt");
  assert.equal(installHooks(repo).status, 0);
  // An unstaged "!" line does not count.
  appendFileSync(path.join(repo, ".leakguard"), "!HANDOFF.md\n");
  write(repo, "HANDOFF.md", "# internal\n");
  git(repo, "add", "HANDOFF.md");
  let c = git(repo, "commit", "-m", "handoff");
  assert.notEqual(c.status, 0, "an unstaged .leakguard exemption let HANDOFF.md through");
  // Nor a staged one in the same commit.
  git(repo, "add", ".leakguard");
  c = git(repo, "commit", "-m", "handoff and its exemption");
  assert.notEqual(c.status, 0, "a commit exempted its own path");
  assert.match(c.out, /HANDOFF\.md: forbidden path/);
  // Committed on its own first, it works.
  git(repo, "reset", "-q", "--", "HANDOFF.md");
  assert.equal(git(repo, "commit", "-q", "-m", "exempt HANDOFF.md").status, 0);
  git(repo, "add", "HANDOFF.md");
  assert.equal(git(repo, "commit", "-q", "-m", "handoff").status, 0);

  // Secret material: a wildcard "!" never exempts it, an exact path does.
  appendFileSync(path.join(repo, ".leakguard"), "!*.pem\n!certs/public-test.pem\n");
  git(repo, "add", ".leakguard");
  assert.equal(git(repo, "commit", "-q", "-m", "exempt the public test certificate").status, 0);
  write(repo, "certs/deploy.pem", "placeholder\n");
  git(repo, "add", "certs/deploy.pem");
  c = git(repo, "commit", "-m", "pem");
  assert.notEqual(c.status, 0, "a wildcard exemption let a .pem through");
  assert.match(c.out, /certs\/deploy\.pem: forbidden path \(matches "\*\.pem"\)/);
  git(repo, "rm", "-q", "--cached", "certs/deploy.pem");
  write(repo, "certs/public-test.pem", "placeholder\n");
  git(repo, "add", "certs/public-test.pem");
  assert.equal(git(repo, "commit", "-q", "-m", "public test certificate").status, 0);

  // Pushing a branch that exempts and adds a path in one commit (made with --no-verify): the remote's .leakguard,
  // which lacks the exemption, still counts.
  const remote = bareRemote("self-exempt-remote");
  git(repo, "remote", "add", "origin", remote);
  assert.equal(git(repo, "push", "-q", "origin", "main").status, 0);
  git(repo, "fetch", "-q", "origin");
  appendFileSync(path.join(repo, ".leakguard"), "!notes/decisions.md\n");
  write(repo, "notes/decisions.md", "# decisions\n");
  git(repo, "add", ".leakguard", "notes/decisions.md");
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "sneaky").status, 0);
  const p = git(repo, "push", "-q", "origin", "main");
  assert.notEqual(p.status, 0, "a push exempted its own path");
  assert.match(p.out, /notes\/decisions\.md: forbidden path/);
});

test("@only, @pin and @push-url", () => {
  const repo = newRepo("policy", { leakguard: (t) => t });
  const readme = "# accounts\n";
  write(repo, "README.md", readme);
  const sha = createHash("sha256").update(readme).digest("hex");
  appendFileSync(path.join(repo, ".leakguard"), [
    "@only /README.md", "@only /.leakguard", "@only /.githooks/*", "@only /scripts/dev/*",
    `@pin README.md ${sha}`, "@push-url */allowed-remote", ""].join("\n"));
  git(repo, "add", "README.md", ".leakguard");
  assert.equal(git(repo, "commit", "-q", "-m", "policy").status, 0);
  assert.equal(installHooks(repo).status, 0);
  assert.equal(paths(repo).status, 0);

  write(repo, "index.html", "<script>1</script>\n");
  git(repo, "add", "index.html");
  let c = git(repo, "commit", "-m", "page");
  assert.notEqual(c.status, 0);
  assert.match(c.out, /index\.html: forbidden path \(not in the \.leakguard @only list\)/);
  git(repo, "rm", "-q", "--cached", "index.html");

  write(repo, "README.md", "# changed\n");
  git(repo, "add", "README.md");
  c = git(repo, "commit", "-m", "readme");
  assert.notEqual(c.status, 0);
  assert.match(c.out, /README\.md: pinned file changed/);
  git(repo, "checkout", "-q", "HEAD", "--", "README.md");

  git(repo, "rm", "-q", "README.md");
  c = git(repo, "commit", "-m", "remove readme");
  assert.notEqual(c.status, 0);
  assert.match(c.out, /README\.md: deletes a pinned file/);
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "remove readme").status, 0);
  const h = paths(repo, "--history", "HEAD^..HEAD");
  assert.equal(h.status, 1);
  assert.match(h.out, /[0-9a-f]+:README\.md: deletes a pinned file/);
  assert.match(paths(repo).out, /README\.md: pinned file is missing/);
  git(repo, "reset", "-q", "--hard", "HEAD^");

  const other = bareRemote("elsewhere");
  git(repo, "remote", "add", "other", other);
  const p = git(repo, "push", "-q", "other", "main");
  assert.notEqual(p.status, 0, "a push to an unlisted remote went through");
  assert.match(p.out, /push to .*elsewhere: not a remote this repository may push to/);
  const allowed = bareRemote("allowed-remote");
  git(repo, "remote", "add", "origin", allowed);
  const ok = git(repo, "push", "-q", "origin", "main");
  assert.equal(ok.status, 0, ok.out);
});

test("pre-push checks commits that only another remote has", () => {
  const repo = newRepo("remotes");
  assert.equal(installHooks(repo).status, 0);
  const priv = bareRemote("private");
  const pub = bareRemote("public");
  git(repo, "remote", "add", "priv", priv);
  git(repo, "remote", "add", "pub", pub);
  write(repo, "k.txt", `DEPLOYER_KEY=0x${fake(hex(32))}\n`);
  git(repo, "add", "k.txt");
  assert.equal(git(repo, "commit", "-q", "--no-verify", "-m", "key").status, 0);
  assert.equal(git(repo, "push", "-q", "--no-verify", "priv", "HEAD:refs/heads/work").status, 0);
  const p = git(repo, "push", "-q", "pub", "HEAD:refs/heads/main");
  assert.notEqual(p.status, 0, "a commit already on another remote went to this one unchecked");
  assert.match(p.out, /k\.txt:1: private key assignment/);
});

test("commit and tag messages are checked; public repositories reject audit finding IDs", () => {
  const repo = newRepo("messages");
  assert.equal(installHooks(repo).status, 0);
  const remote = bareRemote("messages-remote");
  git(repo, "remote", "add", "origin", remote);
  assert.equal(git(repo, "push", "-q", "origin", "main").status, 0);

  let c = git(repo, "commit", "--allow-empty", "-m", `rotate DEPLOYER_KEY=0x${fake(hex(32))}`);
  assert.notEqual(c.status, 0, "a key in a commit message went through");
  assert.match(c.out, /\(commit message\):1: private key assignment/);
  assert.equal(git(repo, "commit", "-q", "--allow-empty", "--no-verify", "-m", `rotate DEPLOYER_KEY=0x${fake(hex(32))}`).status, 0);
  let p = git(repo, "push", "-q", "origin", "main");
  assert.notEqual(p.status, 0, "a pushed commit message with a key went through");
  assert.match(p.out, /[0-9a-f]+:\(commit message\):1: private key assignment/);
  git(repo, "reset", "-q", "--hard", "HEAD^");

  assert.equal(git(repo, "tag", "-a", "v1", "-m", `deployer DEPLOYER_KEY=0x${fake(hex(32))}`).status, 0);
  p = git(repo, "push", "-q", "origin", "v1");
  assert.notEqual(p.status, 0, "an annotated tag message with a key went through");
  assert.match(p.out, /v1:\(tag message\):1: private key assignment/);
  const h = scan(repo, "--history", "--all");
  assert.match(h.out, /v1:\(tag message\):1: private key assignment/);

  // The internal-document marker: refused here, allowed in a repository marked @internal.
  const marker = ["dyorhq", "internal"].join(":");
  write(repo, "notes.md", `<!-- ${marker} -->\n# notes\n`);
  git(repo, "add", "notes.md");
  c = git(repo, "commit", "-m", "notes");
  assert.notEqual(c.status, 0, "an internal document went through");
  assert.match(c.out, /notes\.md:1: internal-document marker/);

  const pub = newRepo("public-repo", { leakguard: (t) => `${anyRemote(t)}\n@public\n` });
  assert.equal(installHooks(pub).status, 0);
  c = git(pub, "commit", "--allow-empty", "-m", "Fix the waitlist form (LR-4)");
  assert.notEqual(c.status, 0, "an audit finding ID went into a public commit message");
  assert.match(c.out, /\(commit message\):1: internal audit finding ID/);
  assert.equal(git(pub, "commit", "-q", "--allow-empty", "-m", "Fix the waitlist form").status, 0);

  const internal = newRepo("internal-repo", { leakguard: (t) => `${anyRemote(t)}\n@internal\n` });
  assert.equal(installHooks(internal).status, 0);
  write(internal, "notes.md", `<!-- ${marker} -->\n# notes\n`);
  git(internal, "add", "notes.md");
  c = git(internal, "commit", "-m", "notes (SEC-5)");
  assert.equal(c.status, 0, c.out);
});

test("worktrees on branches without .githooks keep their secret scan (dispatchers)", () => {
  const repo = newRepo("dispatch");
  // A branch from before the guard existed, checked out in a second worktree.
  git(repo, "checkout", "-q", "--orphan", "old");
  git(repo, "rm", "-rq", "--cached", ".");
  for (const f of GUARD) rmSync(path.join(repo, f), { force: true });
  write(repo, "README.md", "old branch\n");
  git(repo, "add", "README.md");
  git(repo, "commit", "-q", "-m", "old");
  git(repo, "checkout", "-q", "main");
  const old = path.join(dir, "dispatch-old");
  assert.equal(git(repo, "worktree", "add", "-q", old, "old").status, 0);

  // Through the old installer entry point, which now delegates to install-hooks.sh.
  const inst = scan(repo, "--install-hook");
  assert.equal(inst.status, 0, inst.out);
  assert.match(inst.out, /dispatchers/);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").status, 1, "core.hooksPath would disable the old worktree's hooks");
  assert.equal(installHooks(repo, "--check").status, 0);

  write(old, "keys.txt", `KEY=0x${fake(hex(32))}\n`);
  git(old, "add", "keys.txt");
  let c = git(old, "commit", "-m", "old branch key");
  assert.notEqual(c.status, 0, "the old worktree committed a fake key");
  assert.match(c.out, /keys\.txt:1: private key assignment/);
  git(old, "rm", "-q", "--cached", "keys.txt");
  write(old, "notes.txt", "fine\n");
  git(old, "add", "notes.txt");
  assert.equal(git(old, "commit", "-q", "-m", "old branch clean").status, 0);

  write(repo, "docs/security-review-q3.md", "# review\n");
  git(repo, "add", "docs/security-review-q3.md");
  c = git(repo, "commit", "-m", "review");
  assert.notEqual(c.status, 0, "the guarded worktree committed an internal document");
  assert.match(c.out, /docs\/security-review-q3\.md: forbidden path/);
});

test("install-hooks leaves another tool's hooks alone", () => {
  const repo = newRepo("foreign");
  const hook = path.join(repo, ".git/hooks/post-checkout");
  writeFileSync(hook, "#!/bin/sh\ngit lfs post-checkout \"$@\"\n");
  chmodSync(hook, 0o755);
  const r = installHooks(repo);
  assert.equal(r.status, 2, r.out);
  assert.match(r.out, /another tool's hooks .*post-checkout/);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").status, 1, "core.hooksPath was set anyway");
  assert.equal(installHooks(repo, "--force").status, 0);
  assert.equal(git(repo, "config", "--get", "core.hooksPath").out.trim(), ".githooks");
});

test("a single compressed file is read even when a tar tool takes it for an archive and unpacks nothing", () => {
  const repo = newRepo("lenienttar");
  write(repo, "logs/k6.log.gz", gzipSync(Buffer.from(`PRIVATE_KEY=0x${fake(hex(32))}\n`)));
  git(repo, "add", "logs/k6.log.gz");
  // Tar tools that list and "extract" anything, as some Linux builds do for a compressed file that is not a tar.
  const bin = path.join(dir, "lenient-tar-bin");
  mkdirSync(bin, { recursive: true });
  for (const tool of ["bsdtar", "tar"]) {
    writeFileSync(path.join(bin, tool), "#!/bin/sh\nexit 0\n");
    chmodSync(path.join(bin, tool), 0o755);
  }
  const r = run("/bin/bash", [path.join(repo, "scripts/dev/secret-scan.sh"), "--staged"], repo, { PATH: `${bin}:${process.env.PATH}` });
  assert.equal(r.status, 1, r.out);
  assert.match(r.out, /logs\/k6\.log\.gz \(inside the archive\): private key assignment/);
});

test("the scanner fails closed when a helper is broken, and reads odd file names", () => {
  const repo = newRepo("failclosed");
  write(repo, "src/deploy.ts", `export const DEPLOYER_KEY = "0x${fake(hex(32))}";\n`);
  git(repo, "add", "src/deploy.ts");
  const bin = path.join(dir, "broken-bin");
  mkdirSync(bin, { recursive: true });
  writeFileSync(path.join(bin, "awk"), "#!/bin/sh\nexit 1\n");
  chmodSync(path.join(bin, "awk"), 0o755);
  const r = run("/bin/bash", [path.join(repo, "scripts/dev/secret-scan.sh"), "--staged"], repo, { PATH: `${bin}:${process.env.PATH}` });
  assert.equal(r.status, 2, `a broken awk reported clean:\n${r.out}`);
  assert.match(r.out, /self-check failed/);

  // A file whose name looks like an awk assignment is still read.
  git(repo, "commit", "-q", "--no-verify", "-m", "key");
  write(repo, "a=b.ts", `const signerKeys = ["0x${fake(hex(32))}"];\n`);
  git(repo, "add", "a=b.ts");
  git(repo, "commit", "-q", "--no-verify", "-m", "odd name");
  const all = scan(repo, "--all");
  assert.match(all.out, /(^|\n)a=b\.ts:1: 32-byte hex key in a key-named array/);
});
