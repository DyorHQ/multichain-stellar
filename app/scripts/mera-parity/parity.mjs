// Mera parity check: the native Swift port (ios/DyorKit/Sources/DyorKit/Services/Mera) against the real
// @category-labs/mera 0.2.0, run through the library's public API the way Mera's "Create passkey accounts" recipe does
// (with @scure/bip39 and @scure/bip32, all three pinned exactly in package.json).
//
// No authenticator and no network: a fake WebAuthn client stands in for the passkey, the way Mera's own tests do
// (test/passkey.test.ts `stubClient`), and answers each PRF salt with a fixed output. The expected values are the
// literals in ios/DyorKit/Tests/DyorKitTests/MeraTests.swift, read from that file, so the Swift tests and this script
// always check the same vectors. Checked: Mera's default PRF salt; for PRF 0x000102…1f the 24-word phrase, seed,
// the keys and addresses at index 0 and 1, and the vault key (HKDF info "mera.v1.encrypt.secret"); and the vault
// the Swift test seals, which Mera must open.
//
//   cd scripts/mera-parity && npm ci --ignore-scripts --no-audit --no-fund && npm run parity
//
// Exit status: 0 every value matches, 1 a mismatch, 2 setup (wrong Node or package version, MeraTests.swift changed
// shape). Key-shaped values (private keys, seed, phrase) are compared but never printed.
import { readFileSync } from "node:fs";
import {
  createPasskeyWithPrfOutput,
  createSecp256k1SigningSession,
  createSecretVaultWithExistingPasskey,
  decryptSecretVaultWithPasskey,
  getEvmAddress,
  getPasskeyPrfOutput,
  isMeraError,
  parseSecretVault,
} from "@category-labs/mera";
import { HDKey } from "@scure/bip32";
import { entropyToMnemonic, mnemonicToSeedSync } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";

const PINS = { "@category-labs/mera": "0.2.0", "@scure/bip39": "2.3.0", "@scure/bip32": "2.3.0" };
// Mera's HKDF info for vault keys (secret.ts SECRET_ENCRYPTION_INFO); Mera.Vault.info in the port.
const VAULT_INFO = "mera.v1.encrypt.secret";
const TESTS_PATH = "ios/DyorKit/Tests/DyorKitTests/MeraTests.swift";

function setupError(message) {
  console.error(`mera-parity: ${message}`);
  process.exit(2);
}

// MARK: Setup

if (Number(process.versions.node.split(".")[0]) < 22) setupError(`Node 22 or later is required (this is ${process.version})`);
for (const [name, version] of Object.entries(PINS)) {
  let installed;
  try {
    installed = JSON.parse(readFileSync(new URL(`./node_modules/${name}/package.json`, import.meta.url), "utf8")).version;
  } catch {
    setupError(`${name} is not installed; run npm ci --ignore-scripts --no-audit --no-fund in scripts/mera-parity`);
  }
  if (installed !== version) setupError(`${name} ${installed} is installed, but the check is pinned to ${version}; run npm ci`);
}

// MARK: Vectors from MeraTests.swift

const swift = readFileSync(new URL(`../../${TESTS_PATH}`, import.meta.url), "utf8");
function vector(name, pattern) {
  const match = swift.match(pattern);
  if (!match) setupError(`${TESTS_PATH} has no ${name} in the shape this script reads (${pattern}); update the pattern with the test`);
  return match[1];
}
const fromHex = (hex) => Uint8Array.from(Buffer.from(hex.replace(/^0x/, ""), "hex"));
const toHex = (bytes) => `0x${Buffer.from(bytes).toString("hex")}`;
const base64url = (bytes) => Buffer.from(bytes).toString("base64url"); // unpadded, as Mera writes it

const expected = {
  rpId: vector("relying party", /XCTAssertEqual\(Mera\.relyingParty, "([^"]+)"\)/),
  prf: fromHex(vector("PRF", /let prf = Data\(hex: "(0x[0-9a-f]{64})"\)!/)),
  accountSalt: vector("account salt", /XCTAssertEqual\(Mera\.accountSalt\.hexString, "(0x[0-9a-f]{64})"\)/),
  phrase: vector("phrase", /XCTAssertEqual\(phrase, "([a-z ]+)"\)/),
  seed: vector("seed", /XCTAssertEqual\(Mnemonic\.seed\(phrase: phrase!\)\?\.hexString, "(0x[0-9a-f]{128})"\)/),
  key0: vector("index-0 private key", /XCTAssertEqual\(a0\.privateKey\.hexString, "(0x[0-9a-f]{64})"\)/),
  address0: vector("index-0 address", /XCTAssertEqual\(a0\.address\.checksummed, "(0x[0-9a-fA-F]{40})"\)/),
  address1: vector("index-1 address", /XCTAssertEqual\(a1\.address\.checksummed, "(0x[0-9a-fA-F]{40})"\)/),
  vaultKey: vector("vault key for the PRF", /Mera\.Vault\.key\(prf: prf\)[^"\n]*"(0x[0-9a-f]{64})"/),
  vaultPRF: fromHex(vector("vault PRF", /let vaultPRF = Data\(hex: "(0x[0-9a-f]{64})"\)!/)),
  vaultPRFKey: vector("vault key for the vault PRF", /Mera\.Vault\.key\(prf: vaultPRF\)[^"\n]*"(0x[0-9a-f]{64})"/),
  nonce: fromHex(vector("vault nonce", /let nonce = Data\(hex: "(0x[0-9a-f]{24})"\)!/)),
  prfSalt: new Uint8Array(32).fill(Number(vector("vault salt", /let salt = Data\(repeating: (\d+), count: 32\)/))),
  credentialId: Uint8Array.from(vector("vault credential", /credentialID: Data\(\[([0-9, ]+)\]\)/).split(",").map(Number)),
  credentialIdText: vector("vault credential text", /XCTAssertEqual\(vault\.credential\.credentialId, "([A-Za-z0-9_-]+)"\)/),
  secret: vector("vault secret", /Mera\.Vault\.seal\(secret: Data\("([^"]*)"\.utf8\)/),
  ciphertext: fromHex(vector("vault ciphertext", /XCTAssertEqual\(Mera\.Base64URL\.decode\(vault\.ciphertext\)\?\.hexString, "(0x[0-9a-f]+)"\)/)),
};

// MARK: A passkey without an authenticator

/** One credential whose PRF gives `answer(salt)`, like the `stubClient` in Mera's tests. It keeps every request so the
 *  script can check what Mera asked the authenticator for, and refuses a salt it has no output for. */
function fakePasskey(credentialId, answer) {
  const requests = [];
  const evaluate = (salt) => {
    const output = answer(salt);
    if (!output) throw new Error(`fake passkey: no PRF output for salt ${toHex(salt)}`);
    return new Uint8Array(output);
  };
  const client = {
    async createCredential(request) {
      requests.push(request);
      return { credentialId: new Uint8Array(credentialId), transports: ["internal"], prfEnabled: true, prfOutput: evaluate(request.prfSalt) };
    },
    async getCredential(request) {
      requests.push(request);
      if (request.allowCredential && toHex(request.allowCredential.credentialId) !== toHex(credentialId)) {
        throw new Error("fake passkey: the assertion is pinned to another credential");
      }
      return { credentialId: new Uint8Array(credentialId), prfOutput: evaluate(request.prfSalt) };
    },
  };
  return { client, requests };
}

// MARK: Checks

const results = [];
/** Records one comparison. `secret` values are compared but never printed. */
function check(name, actual, wanted, { secret = false } = {}) {
  const ok = actual === wanted;
  results.push({ name, ok, detail: ok || secret ? "" : `expected ${wanted}, got ${actual}` });
}
async function attempt(name, body) {
  try {
    await body();
  } catch (error) {
    results.push({ name, ok: false, detail: isMeraError(error) ? `${error.code}: ${error.message}` : String(error?.message ?? error) });
  }
}
async function vaultKey(prfOutput) {
  const material = await crypto.subtle.importKey("raw", prfOutput, "HKDF", false, ["deriveBits"]);
  const params = { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(VAULT_INFO) };
  return new Uint8Array(await crypto.subtle.deriveBits(params, material, 256));
}
/** Mera's recipe, verbatim: BIP-32 over the BIP-44 Ethereum path, then Mera's signing session and address. */
function deriveEvmAccount(seed, index) {
  const node = HDKey.fromMasterSeed(seed).derive(`m/44'/60'/0'/0/${index}`);
  if (node.privateKey === null) throw new Error("derivation produced no key");
  const session = createSecp256k1SigningSession({ privateKey: node.privateKey });
  const account = { key: toHex(node.privateKey), address: getEvmAddress(session.publicKey) };
  session.end();
  node.wipePrivateData();
  return account;
}

// The account passkey answers only Swift's account salt, so Mera reaching it at all proves the default salts agree.
const account = fakePasskey(Uint8Array.of(9, 9, 9, 9), (salt) => (toHex(salt) === expected.accountSalt ? expected.prf : undefined));
let prfOutput;
await attempt("create a passkey account", async () => {
  const created = await createPasskeyWithPrfOutput({
    rp: { id: expected.rpId, name: "DyorHQ" },
    user: { name: "DyorHQ · parity", displayName: "DyorHQ · parity" },
    webAuthnClient: account.client,
  });
  check("create: one ceremony, for the DyorHQ rpId", `${account.requests.length} ${account.requests[0]?.rp?.id}`, `1 ${expected.rpId}`);
  check("create: PRF output", toHex(created.prfOutput), toHex(expected.prf), { secret: true });
  prfOutput = created.prfOutput;
});
// The salt Mera asked the authenticator to evaluate, recorded whether or not the fake passkey could answer it.
check("account salt (Mera's default PRF salt)", toHex(account.requests[0]?.prfSalt ?? new Uint8Array()), expected.accountSalt);
await attempt("sign in: discoverable and pinned assertions", async () => {
  const discoverable = await getPasskeyPrfOutput({ rpId: expected.rpId, webAuthnClient: account.client });
  const pinned = await getPasskeyPrfOutput({ rpId: expected.rpId, credential: { credentialId: base64url(Uint8Array.of(9, 9, 9, 9)) }, webAuthnClient: account.client });
  check("sign in: discoverable and pinned assertions", toHex(discoverable.prfOutput) === toHex(expected.prf) && toHex(pinned.prfOutput) === toHex(expected.prf), true);
});

const addresses = [];
await attempt("phrase, seed and accounts", async () => {
  if (!prfOutput) throw new Error("no PRF output from the create ceremony");
  const phrase = entropyToMnemonic(prfOutput, wordlist);
  check("24-word phrase", phrase, expected.phrase, { secret: true });
  check("24 words", phrase.split(" ").length, 24);
  const seed = mnemonicToSeedSync(phrase);
  check("BIP-39 seed", toHex(seed), expected.seed, { secret: true });
  const a0 = deriveEvmAccount(seed, 0);
  const a1 = deriveEvmAccount(seed, 1);
  check("index-0 private key", a0.key, expected.key0, { secret: true });
  check("index-0 address", a0.address, expected.address0);
  check("index-1 address", a1.address, expected.address1);
  addresses.push(a0.address, a1.address);
  seed.fill(0);
});

await attempt("vault keys", async () => {
  check(`vault key, PRF 0x0001…1f, info "${VAULT_INFO}"`, toHex(await vaultKey(expected.prf)), expected.vaultKey, { secret: true });
  check(`vault key, the Swift vault's PRF`, toHex(await vaultKey(expected.vaultPRF)), expected.vaultPRFKey, { secret: true });
});

// The key above is Mera's own: a vault Mera seals for PRF 0x0001…1f (random salt and nonce) opens with it.
await attempt("Mera's vault opens with that key", async () => {
  const sealing = fakePasskey(Uint8Array.of(9, 9, 9, 9), () => expected.prf);
  const vault = await createSecretVaultWithExistingPasskey({ rpId: expected.rpId, secret: new TextEncoder().encode("parity"), webAuthnClient: sealing.client });
  const key = await crypto.subtle.importKey("raw", await vaultKey(expected.prf), "AES-GCM", false, ["decrypt"]);
  const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv: Buffer.from(vault.nonce, "base64url") }, key, Buffer.from(vault.ciphertext, "base64url"));
  check("Mera's vault opens with that key", Buffer.from(opened).toString("utf8"), "parity");
});

// The vault the Swift test seals (MeraTests.testVaultKeyAndCiphertextMatchWebCrypto), opened by Mera.
const swiftVault = JSON.stringify({
  version: 1,
  credential: { credentialId: base64url(expected.credentialId) },
  prfSalt: base64url(expected.prfSalt),
  nonce: base64url(expected.nonce),
  ciphertext: base64url(expected.ciphertext),
});
await attempt("Swift vault: parseSecretVault accepts it", async () => {
  const parsed = parseSecretVault(swiftVault);
  check("Swift vault: parseSecretVault accepts it", parsed.credential.credentialId, expected.credentialIdText);
});
await attempt("Swift vault: Mera decrypts it", async () => {
  // Answers only the vault's own salt, on the vault's own credential.
  const passkey = fakePasskey(expected.credentialId, (salt) => (toHex(salt) === toHex(expected.prfSalt) ? expected.vaultPRF : undefined));
  const secret = await decryptSecretVaultWithPasskey({ rpId: expected.rpId, vault: swiftVault, webAuthnClient: passkey.client });
  check("Swift vault: Mera decrypts it", Buffer.from(secret).toString("utf8"), expected.secret);
});
await attempt("Swift vault: another passkey fails with DECRYPT_FAILED", async () => {
  const other = fakePasskey(expected.credentialId, () => expected.prf);
  let code = "opened";
  try {
    await decryptSecretVaultWithPasskey({ rpId: expected.rpId, vault: swiftVault, webAuthnClient: other.client });
  } catch (error) {
    code = isMeraError(error) ? error.code : String(error);
  }
  check("Swift vault: another passkey fails with DECRYPT_FAILED", code, "DECRYPT_FAILED");
});
await attempt("Swift vault: same bytes when sealed here", async () => {
  const key = await crypto.subtle.importKey("raw", await vaultKey(expected.vaultPRF), "AES-GCM", false, ["encrypt"]);
  const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv: expected.nonce }, key, new TextEncoder().encode(expected.secret));
  check("Swift vault: same bytes when sealed here", toHex(new Uint8Array(sealed)), toHex(expected.ciphertext));
});

// MARK: Report

console.log(`Mera parity: @category-labs/mera ${PINS["@category-labs/mera"]} against the Swift port (vectors from ${TESTS_PATH})`);
for (const { name, ok, detail } of results) console.log(`  ${ok ? "ok  " : "FAIL"}  ${name}${detail ? `: ${detail}` : ""}`);
const failed = results.filter((result) => !result.ok).length;
if (failed > 0) {
  console.log(`${failed} of ${results.length} checks failed.`);
  process.exit(1);
}
console.log(`All ${results.length} checks match. Index 0 ${addresses[0]}, index 1 ${addresses[1]}.`);
