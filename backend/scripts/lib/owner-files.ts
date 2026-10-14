// The owner's files for the v2 testnet deployment (CT-11a lead decision L-a), read and written only by the scripts,
// plus the output rules every script of the kit follows: nothing a script prints can carry a secret.
//
// In the secrets directory ($DYOR_SECRETS_DIR when it is set, else <repo>/.secrets, which is git-ignored):
// - testnet-owner-v2.env       the roles file: public G-addresses only, exactly ADMIN_PUBLIC, GOVERNANCE_PUBLIC,
//                              LAUNCHPAD_GUARDIAN_PUBLIC, MOMENTS_GUARDIAN_PUBLIC, TREASURY_PUBLIC, PLATFORM_PUBLIC.
//                              The only source of the roles: a role name set in the environment is refused.
// - testnet-owner-v2.keys.env  the keys `owner-v2.ts keys` generated: ADMIN_SECRET, GUARDIAN_SECRET, TREASURY_SECRET.
//                              Mode 600; a wider mode is refused.
// - testnet-qa-v2.env          testnet-qa's throwaway keys, written and read by deploy-contracts-v2.ts only (mode 600).
// - testnet-functions.env      the functions' secrets (KEEPER_SECRET is looked up, never printed).
// - testnet-deployer.env       the v1 deployer, which is the live v1 admin (DEPLOYER_SECRET, never printed).
import { Keypair, StrKey } from "@stellar/stellar-sdk";
import { roleRuleErrors, ROLE_NAMES, type V2Roles } from "./v2-profile.ts";

export const ROLES_FILE = "testnet-owner-v2.env";
export const KEYS_FILE = "testnet-owner-v2.keys.env";
export const QA_KEYS_FILE = "testnet-qa-v2.env";
export const FUNCTIONS_FILE = "testnet-functions.env";
export const V1_DEPLOYER_FILE = "testnet-deployer.env";

export type RoleName = keyof V2Roles;
export type KeyName = "ADMIN_SECRET" | "GUARDIAN_SECRET" | "TREASURY_SECRET";
export const KEY_NAMES: readonly KeyName[] = ["ADMIN_SECRET", "GUARDIAN_SECRET", "TREASURY_SECRET"];

/** The repository's root (this file is backend/scripts/lib/owner-files.ts). */
export function repoRoot(): string {
  return new URL("../../../", import.meta.url).pathname;
}

/** $DYOR_SECRETS_DIR when it is set, else <repo>/.secrets. */
export function secretsDir(env: (name: string) => string | undefined = (n) => Deno.env.get(n)): string {
  const dir = env("DYOR_SECRETS_DIR")?.trim();
  return dir ? dir.replace(/\/+$/, "") : `${repoRoot()}.secrets`;
}

// ------------------------------------------------------------------------------------------------ output

/** Anything shaped like a Stellar secret seed. */
const SEED = /S[A-Z2-7]{55}/g;

/** Replaces anything shaped like a secret seed. Every line a script prints goes through it, as a last line of defence:
 *  the scripts never put a secret in a message in the first place. */
export function redact(text: string): string {
  return text.replace(SEED, "S…[redacted]");
}

export function looksLikeSeed(text: string): boolean {
  SEED.lastIndex = 0;
  const found = SEED.test(text);
  SEED.lastIndex = 0;
  return found;
}

/** Where a script prints. */
export interface Io {
  out(line: string): void;
  err(line: string): void;
}

export function consoleIo(): Io {
  return { out: (l) => console.log(redact(l)), err: (l) => console.error(redact(l)) };
}

/** An Io that records what it is given (redacted, as the console one prints it). For tests. */
export function recordingIo(): Io & { stdout: string[]; stderr: string[] } {
  const stdout: string[] = [];
  const stderr: string[] = [];
  return { stdout, stderr, out: (l) => void stdout.push(redact(l)), err: (l) => void stderr.push(redact(l)) };
}

// ------------------------------------------------------------------------------------------------ env files

interface Line {
  /** 1-based. */
  number: number;
  raw: string;
  /** A `NAME=value` line (with an optional `export `); null for blank lines and comments. */
  name: string | null;
  value: string;
}

/** Splits an env file into lines. A malformed line is reported by number only: its text could hold a secret. */
function lines(text: string, file: string): { lines: Line[]; errors: string[] } {
  const out: Line[] = [];
  const errors: string[] = [];
  text.split(/\r?\n/).forEach((raw, i) => {
    const number = i + 1;
    const t = raw.trim();
    if (t === "" || t.startsWith("#")) {
      out.push({ number, raw, name: null, value: "" });
      return;
    }
    const m = t.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
    if (!m) {
      errors.push(`${file} line ${number}: not NAME=value`);
      out.push({ number, raw, name: null, value: "" });
      return;
    }
    let value = m[2].trim();
    const q = value.match(/^"([^"]*)"\s*(#.*)?$/) ?? value.match(/^'([^']*)'\s*(#.*)?$/);
    if (q) value = q[1];
    else value = value.replace(/\s+#.*$/, "").trim();
    out.push({ number, raw, name: m[1], value });
  });
  return { lines: out, errors };
}

export interface RolesFile {
  /** The roles that have a value. */
  roles: Partial<V2Roles>;
  /** Role names present with an empty value (`ADMIN_PUBLIC=`), or absent. */
  empty: RoleName[];
  /** Role names whose line is refused (a bad address, set twice). */
  invalid: RoleName[];
  /** Line-numbered problems; never a value. */
  errors: string[];
  /** The file's text, for in-place completion by `keys`. */
  text: string;
}

/** Parses the roles file. Refused, by line number and never by value: an S-seed anywhere, a name ending in _SECRET,
 *  an unknown name, a name given twice, a value that isn't a G-address. Empty values are allowed (`keys` fills
 *  them). */
export function parseRolesFile(text: string): RolesFile {
  const { lines: ls, errors } = lines(text, ROLES_FILE);
  const roles: Partial<V2Roles> = {};
  const seen = new Set<string>();
  const invalid = new Set<RoleName>();
  for (const l of ls) {
    if (looksLikeSeed(l.raw)) {
      errors.push(`${ROLES_FILE} line ${l.number}: holds a secret seed (S…). Public G-addresses only: move it to a password manager`);
      if (l.name && (ROLE_NAMES as readonly string[]).includes(l.name)) invalid.add(l.name as RoleName);
      continue;
    }
    if (l.name === null) continue;
    if (/_SECRET$/.test(l.name)) {
      errors.push(`${ROLES_FILE} line ${l.number}: ${l.name} is a secret's name; the roles file holds public addresses only`);
      continue;
    }
    if (!(ROLE_NAMES as readonly string[]).includes(l.name)) {
      errors.push(`${ROLES_FILE} line ${l.number}: unknown name ${l.name} (expected ${ROLE_NAMES.join(", ")})`);
      continue;
    }
    const name = l.name as RoleName;
    if (seen.has(name)) {
      errors.push(`${ROLES_FILE} line ${l.number}: ${name} is set twice`);
      invalid.add(name);
      continue;
    }
    seen.add(name);
    if (l.value === "") continue;
    if (!StrKey.isValidEd25519PublicKey(l.value)) {
      errors.push(`${ROLES_FILE} line ${l.number}: ${name} is not a valid G-address`);
      invalid.add(name);
      continue;
    }
    roles[name] = l.value;
  }
  for (const n of invalid) delete roles[n];
  const empty = ROLE_NAMES.filter((n) => !roles[n] && !invalid.has(n));
  return { roles, empty, invalid: [...invalid], errors, text };
}

/** Every role present, plus the cross-role rules (L-a): LAUNCHPAD_GUARDIAN ≠ ADMIN, MOMENTS_GUARDIAN ≠ GOVERNANCE. */
export function rolesErrors(f: RolesFile): string[] {
  const errors = [...f.errors];
  for (const n of f.empty) errors.push(`${ROLES_FILE}: ${n} is empty (run owner-v2.ts keys, or fill it in)`);
  return [...errors, ...roleRuleErrors(f.roles)];
}

/** The complete roles, or an error listing every problem. */
export function requireRoles(f: RolesFile): V2Roles {
  const errors = rolesErrors(f);
  if (errors.length) throw new Error(`the roles file isn't usable:\n  ${errors.join("\n  ")}`);
  return f.roles as V2Roles;
}

/** L-a: roles come only from the roles file. */
export function refuseRoleEnv(env: (name: string) => string | undefined): void {
  const set = ROLE_NAMES.filter((n) => (env(n) ?? "") !== "");
  if (set.length) {
    throw new Error(
      `${set.join(", ")} ${set.length === 1 ? "is" : "are"} set in the environment. Roles come only from the roles file ` +
        `(${ROLES_FILE} in the secrets directory): unset ${set.length === 1 ? "it" : "them"} and edit that file instead.`,
    );
  }
}

export interface KeysFile {
  keys: Partial<Record<KeyName, Keypair>>;
  errors: string[];
  text: string;
}

/** Parses the keys file: ADMIN_SECRET, GUARDIAN_SECRET, TREASURY_SECRET, each a valid seed. Problems are reported by
 *  line number only. */
export function parseKeysFile(text: string): KeysFile {
  const { lines: ls, errors } = lines(text, KEYS_FILE);
  const keys: Partial<Record<KeyName, Keypair>> = {};
  for (const l of ls) {
    if (l.name === null) continue;
    if (!(KEY_NAMES as readonly string[]).includes(l.name)) {
      errors.push(`${KEYS_FILE} line ${l.number}: unknown name (expected ${KEY_NAMES.join(", ")})`);
      continue;
    }
    if (keys[l.name as KeyName]) {
      errors.push(`${KEYS_FILE} line ${l.number}: ${l.name} is set twice`);
      continue;
    }
    if (l.value === "") continue;
    if (!StrKey.isValidEd25519SecretSeed(l.value)) {
      errors.push(`${KEYS_FILE} line ${l.number}: ${l.name} is not a valid secret seed`);
      continue;
    }
    keys[l.name as KeyName] = Keypair.fromSecret(l.value);
  }
  return { keys, errors, text };
}

/** The mode problem of a secret file, or null. Anything readable or writable by group or others is refused. */
export async function modeProblem(path: string): Promise<string | null> {
  const st = await Deno.stat(path);
  const mode = (st.mode ?? 0) & 0o777;
  if ((mode & 0o077) !== 0) {
    return `${path} has mode ${mode.toString(8).padStart(3, "0")}; run: chmod 600 ${path}`;
  }
  return null;
}

export async function readIfExists(path: string): Promise<string | null> {
  try {
    return await Deno.readTextFile(path);
  } catch (e) {
    if (e instanceof Deno.errors.NotFound) return null;
    throw e;
  }
}

/** Reads the keys file (null when it doesn't exist). A wider mode than 600, or a malformed line, is refused. */
export async function loadKeysFile(dir: string): Promise<KeysFile | null> {
  const path = `${dir}/${KEYS_FILE}`;
  const text = await readIfExists(path);
  if (text === null) return null;
  const mode = await modeProblem(path);
  if (mode) throw new Error(`refused: ${mode}`);
  const f = parseKeysFile(text);
  if (f.errors.length) throw new Error(`the keys file isn't usable:\n  ${f.errors.join("\n  ")}`);
  return f;
}

export async function loadRolesFile(dir: string): Promise<RolesFile | null> {
  const text = await readIfExists(`${dir}/${ROLES_FILE}`);
  return text === null ? null : parseRolesFile(text);
}

/** Reads one secret (`name=S…`) out of an env file the script owns the reading of, such as KEEPER_SECRET from
 *  testnet-functions.env. Null when the file or the name is missing. The value is never printed: a bad one is
 *  reported by name only. */
export async function secretFromEnvFile(path: string, name: string): Promise<Keypair | null> {
  const text = await readIfExists(path);
  if (text === null) return null;
  let found: string | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const m = raw.trim().match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['"]?([^'"\s#]*)['"]?/);
    if (m && m[1] === name) found = m[2];
  }
  if (!found) return null;
  if (!StrKey.isValidEd25519SecretSeed(found)) throw new Error(`${name} in ${path} is not a valid secret seed`);
  return Keypair.fromSecret(found);
}

/** A secret from the environment (typed with `read -rs`), checked; null when unset. */
export function secretFromEnv(env: (name: string) => string | undefined, name: string): Keypair | null {
  const v = env(name)?.trim();
  if (!v) return null;
  if (!StrKey.isValidEd25519SecretSeed(v)) throw new Error(`${name} in the environment is not a valid secret seed`);
  return Keypair.fromSecret(v);
}

/** Writes a secret file atomically with mode 600. */
export async function writeSecretFile(path: string, text: string): Promise<void> {
  const tmp = `${path}.tmp-${crypto.randomUUID()}`;
  await Deno.writeTextFile(tmp, text, { mode: 0o600 });
  await Deno.chmod(tmp, 0o600);
  await Deno.rename(tmp, path);
}

// ------------------------------------------------------------------------------------------------ completing them

/** Which roles each generated key may fill: its primary role, then the secondary when that is empty (L-a). */
export const KEY_GROUPS: readonly { key: KeyName; label: string; primary: RoleName; secondary: RoleName }[] = [
  { key: "ADMIN_SECRET", label: "admin", primary: "ADMIN_PUBLIC", secondary: "GOVERNANCE_PUBLIC" },
  { key: "GUARDIAN_SECRET", label: "guardian", primary: "LAUNCHPAD_GUARDIAN_PUBLIC", secondary: "MOMENTS_GUARDIAN_PUBLIC" },
  { key: "TREASURY_SECRET", label: "treasury", primary: "TREASURY_PUBLIC", secondary: "PLATFORM_PUBLIC" },
];

export interface Completion {
  roles: V2Roles;
  /** Keys created in this run (at most three). */
  generated: KeyName[];
  /** Keys taken from an existing keys file to fill an empty role. */
  reused: KeyName[];
  /** The roles this run filled in. */
  filled: RoleName[];
  rolesText: string;
  keysText: string;
  /** Notes for the owner (never a value). */
  notes: string[];
}

/** Completes the roles: an empty primary role gets its group's key (taken from the keys file when it has one, else
 *  generated); an empty secondary role then gets the primary's address. Roles and secrets already set are never
 *  changed. At most three keys are generated: admin, guardian, treasury. */
export function completeRoles(
  roles: RolesFile,
  keys: KeysFile | null,
  generate: () => Keypair = () => Keypair.random(),
): Completion {
  if (roles.errors.length) throw new Error(`fix the roles file first:\n  ${roles.errors.join("\n  ")}`);
  if (keys?.errors.length) throw new Error(`fix the keys file first:\n  ${keys.errors.join("\n  ")}`);
  const r: Partial<V2Roles> = { ...roles.roles };
  const k: Partial<Record<KeyName, Keypair>> = { ...(keys?.keys ?? {}) };
  const generated: KeyName[] = [];
  const reused: KeyName[] = [];
  const filled: RoleName[] = [];
  const notes: string[] = [];
  for (const g of KEY_GROUPS) {
    if (!r[g.primary]) {
      if (k[g.key]) reused.push(g.key);
      else {
        k[g.key] = generate();
        generated.push(g.key);
      }
      r[g.primary] = k[g.key]!.publicKey();
      filled.push(g.primary);
    } else if (k[g.key] && k[g.key]!.publicKey() !== r[g.primary]) {
      notes.push(`${g.key} in the keys file is not ${g.primary}'s key: you bring ${g.primary}'s key yourself`);
    }
    if (!r[g.secondary]) {
      r[g.secondary] = r[g.primary];
      filled.push(g.secondary);
    }
  }
  return {
    roles: r as V2Roles,
    generated,
    reused,
    filled,
    rolesText: fillRolesText(roles.text, r as V2Roles, filled),
    keysText: appendKeys(keys?.text ?? null, k, generated),
    notes,
  };
}

const ROLES_HEADER = [
  "# DyorHQ v2 on Stellar testnet: the owner's roles (public G-addresses only; never a secret).",
  "# Read by backend/scripts/owner-v2.ts, deploy-contracts-v2.ts and admin-v2.ts. Edit this file to change a role.",
  "# PLATFORM receives the Moments platform share and 60% of harvested Moments USDC (it needs a USDC trustline).",
];

function fillRolesText(text: string, roles: V2Roles, filled: RoleName[]): string {
  if (filled.length === 0) return text;
  const src = text === "" ? [...ROLES_HEADER] : text.replace(/\n$/, "").split(/\r?\n/);
  const done = new Set<RoleName>();
  const out = src.map((raw) => {
    const m = raw.trim().match(/^(?:export\s+)?([A-Z_]+)\s*=\s*(.*)$/);
    if (!m) return raw;
    const name = m[1] as RoleName;
    const rest = m[2].trim().replace(/^(["'])\1$/, "");
    if (filled.includes(name) && (rest === "" || rest.startsWith("#"))) {
      done.add(name);
      return `${name}=${roles[name]}`;
    }
    return raw;
  });
  for (const n of ROLE_NAMES) if (filled.includes(n) && !done.has(n)) out.push(`${n}=${roles[n]}`);
  return out.join("\n") + "\n";
}

const KEYS_HEADER = [
  "# DyorHQ v2 on Stellar testnet: secret keys generated by backend/scripts/owner-v2.ts keys. Mode 600.",
  "# Copy this file's contents into your password manager. Never commit, paste or print it.",
];

function appendKeys(text: string | null, keys: Partial<Record<KeyName, Keypair>>, generated: KeyName[]): string {
  const base = text === null || text === "" ? KEYS_HEADER.join("\n") + "\n" : text.endsWith("\n") ? text : text + "\n";
  return base + generated.map((n) => `${n}=${keys[n]!.secret()}\n`).join("");
}

// ------------------------------------------------------------------------------------------------ testnet-qa keys

/** testnet-qa's throwaway keys (§17 step 4). Platform is the treasury there. */
export const QA_KEY_NAMES = [
  "DEPLOYER_SECRET",
  "ADMIN_SECRET",
  "LAUNCHPAD_GUARDIAN_SECRET",
  "GOVERNANCE_SECRET",
  "MOMENTS_GUARDIAN_SECRET",
  "TREASURY_SECRET",
  "QA_ISSUER_SECRET",
  "QA_ADMIN_SECRET",
] as const;
export type QaKeyName = typeof QA_KEY_NAMES[number];

/** Reads testnet-qa's keys; null when the file doesn't exist. Mode and names are checked. */
export async function loadQaKeys(dir: string): Promise<Record<QaKeyName, Keypair> | null> {
  const path = `${dir}/${QA_KEYS_FILE}`;
  const text = await readIfExists(path);
  if (text === null) return null;
  const mode = await modeProblem(path);
  if (mode) throw new Error(`refused: ${mode}`);
  const { lines: ls, errors } = lines(text, QA_KEYS_FILE);
  const out: Partial<Record<QaKeyName, Keypair>> = {};
  for (const l of ls) {
    if (l.name === null) continue;
    if (!(QA_KEY_NAMES as readonly string[]).includes(l.name) || !StrKey.isValidEd25519SecretSeed(l.value)) {
      errors.push(`${QA_KEYS_FILE} line ${l.number}: not one of the QA keys`);
      continue;
    }
    out[l.name as QaKeyName] = Keypair.fromSecret(l.value);
  }
  const missing = QA_KEY_NAMES.filter((n) => !out[n]);
  if (missing.length) errors.push(`${QA_KEYS_FILE}: ${missing.join(", ")} missing`);
  if (errors.length) throw new Error(`testnet-qa's key file isn't usable:\n  ${errors.join("\n  ")}`);
  return out as Record<QaKeyName, Keypair>;
}

/** Generates testnet-qa's keys into a new file (mode 600). Refuses to overwrite one. */
export async function createQaKeys(dir: string, generate: () => Keypair = () => Keypair.random()): Promise<Record<QaKeyName, Keypair>> {
  const path = `${dir}/${QA_KEYS_FILE}`;
  if ((await readIfExists(path)) !== null) throw new Error(`${path} exists; it is never overwritten`);
  const keys = Object.fromEntries(QA_KEY_NAMES.map((n) => [n, generate()])) as Record<QaKeyName, Keypair>;
  await Deno.mkdir(dir, { recursive: true });
  const text = [
    "# DyorHQ v2 testnet-qa: throwaway QA keys, written and read only by deploy-contracts-v2.ts. Mode 600.",
    ...QA_KEY_NAMES.map((n) => `${n}=${keys[n].secret()}`),
    "",
  ].join("\n");
  await writeSecretFile(path, text);
  return keys;
}
