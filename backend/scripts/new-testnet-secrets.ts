// Creates the Lite function secrets without ever printing one (the maintainers' runbook).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts
//     Writes .secrets/testnet-functions.env (git-ignored, mode 600): LITE_NETWORK, LITE_MIN_BUILD, a new sponsor's
//     SPONSOR_SECRET, a new keeper's KEEPER_SECRET, LITE_JWT_SECRET and LITE_CRON_SECRET. Funds the sponsor and the
//     keeper through Friendbot and prints only their public keys. Refuses to overwrite an existing file.
//
//   … new-testnet-secrets.ts --add-keeper
//     For a file made before the keeper key existed: appends a new KEEPER_SECRET (the file stays mode 600), funds the
//     keeper through Friendbot and prints its public key and what to do next. When the file has a KEEPER_SECRET
//     already, prints that keeper's public key and changes nothing. Testnet only: a mainnet keeper is the owner's.
//
//   … new-testnet-secrets.ts --db-role <ref> <pooler host>
//     Adds LITE_DB_URL to that file: the lite_api role (migration 4) through the transaction pooler, with a new random
//     password. Writes .secrets/lite-api-role.sql (mode 600), which sets that password as a SCRAM verifier, so the
//     password itself never reaches the database logs (log_statement = ddl logs ALTER ROLE).
//
//   … new-testnet-secrets.ts --vault-sql <ref>
//     Writes .secrets/testnet-vault.sql (mode 600): creates or updates the two Vault entries the cron job reads,
//     lite_indexer_url and lite_cron_secret (the same value as LITE_CRON_SECRET).
//
// Each SQL file is applied with `supabase db query --linked --file <file>` and then deleted; the env file goes to
// Supabase with `supabase secrets set --project-ref <ref> --env-file .secrets/testnet-functions.env`.
//
// --dir <directory> puts every file above in that directory instead of .secrets (a temporary one, to try the script).
import { Keypair, StrKey } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";

const root = new URL("../../", import.meta.url).pathname;
const args = [...Deno.args];
const dirAt = args.indexOf("--dir");
const dir = dirAt < 0 ? `${root}.secrets` : args.splice(dirAt, 2)[1];
if (!dir) throw new Error("usage: --dir <directory>");
const envFile = `${dir}/testnet-functions.env`;
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
// base64url without padding: safe in an env file, a URL's userinfo, an HTTP header and a SQL string literal.
const random = (bytes: number) =>
  b64(crypto.getRandomValues(new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function exists(path: string) {
  try {
    await Deno.stat(path);
    return true;
  } catch {
    return false;
  }
}

/** Funds a new testnet account through Friendbot. */
async function fund(account: string) {
  const r = await fetch(`${TESTNET.friendbotUrl}?addr=${account}`);
  if (!r.ok) throw new Error(`friendbot failed for ${account}: ${r.status}`);
  await r.body?.cancel();
}

function projectRef(arg: string | undefined, usage: string): string {
  if (!arg || !/^[a-z]{20}$/.test(arg)) throw new Error(`usage: ${usage}`);
  return arg;
}

async function writeSecretFile(name: string, text: string) {
  const out = `${dir}/${name}`;
  await Deno.writeTextFile(out, text, { mode: 0o600 });
  return out;
}

// PostgreSQL's SCRAM-SHA-256 verifier (RFC 5802 / 7677): what ALTER ROLE … PASSWORD stores for a plain password.
async function scramVerifier(password: string): Promise<string> {
  const enc = new TextEncoder();
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const base = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const salted = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations: 4096 }, base, 256),
  );
  const hmac = async (key: Uint8Array, msg: string) => {
    const k = await crypto.subtle.importKey("raw", key as BufferSource, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    return new Uint8Array(await crypto.subtle.sign("HMAC", k, enc.encode(msg)));
  };
  const storedKey = new Uint8Array(await crypto.subtle.digest("SHA-256", await hmac(salted, "Client Key")));
  const serverKey = await hmac(salted, "Server Key");
  return `SCRAM-SHA-256$4096:${b64(salt)}$${b64(storedKey)}:${b64(serverKey)}`;
}

if (args[0] === "--add-keeper") {
  const text = await Deno.readTextFile(envFile);
  const value = (name: string) => text.match(new RegExp(`^${name}=(.*)$`, "m"))?.[1].trim().replace(/^["']|["']$/g, "");
  // A mainnet keeper is made, funded and kept by the owner: this script only ever makes testnet keys.
  if (value("LITE_NETWORK") !== "testnet") throw new Error(`${envFile}: LITE_NETWORK isn't testnet; refused, nothing changed`);
  const current = value("KEEPER_SECRET");
  if (current) {
    if (!StrKey.isValidEd25519SecretSeed(current)) throw new Error(`${envFile}: its KEEPER_SECRET isn't a Stellar secret key; nothing changed`);
    console.log("keeper", Keypair.fromSecret(current).publicKey(), "is in", envFile, "already; nothing changed");
    Deno.exit(0);
  }
  const keeper = Keypair.random();
  // Funded before anything is written, so a failure leaves the file as it was.
  await fund(keeper.publicKey());
  await Deno.chmod(envFile, 0o600);
  await Deno.writeTextFile(envFile, `${text.endsWith("\n") ? "" : "\n"}KEEPER_SECRET=${keeper.secret()}\n`, { append: true });
  console.log("keeper", keeper.publicKey(), "funded; KEEPER_SECRET added to", envFile, "(mode 600). Next:");
  console.log("  local stack: backend/scripts/local-stack.sh stop, then start (backend/scripts/local/make-local-env.ts copies it)");
  console.log(`  hosted, an owner action: supabase secrets set --env-file ${envFile} --project-ref fmnjqrguvopusfufmirs`);
  Deno.exit(0);
}

if (args[0] === "--db-role") {
  const ref = projectRef(args[1], "--db-role <20-letter project ref> <pooler host>");
  const host = args[2] ?? "";
  if (!/^[a-z0-9-]+\.pooler\.supabase\.com$/.test(host)) throw new Error("usage: --db-role <ref> <xxx.pooler.supabase.com>");
  const env = await Deno.readTextFile(envFile);
  if (/^LITE_DB_URL=/m.test(env)) throw new Error(`${envFile} already has LITE_DB_URL; remove that line first`);
  const password = random(32);
  const line = `LITE_DB_URL=postgresql://lite_api.${ref}:${password}@${host}:6543/postgres\n`;
  await Deno.writeTextFile(envFile, `${env.endsWith("\n") ? env : env + "\n"}${line}`, { mode: 0o600 });
  const out = await writeSecretFile("lite-api-role.sql", `alter role lite_api password '${await scramVerifier(password)}';\n`);
  console.log("added LITE_DB_URL (lite_api via", `${host}:6543) to`, envFile, "and wrote", out, "(delete it once applied)");
  Deno.exit(0);
}

if (args[0] === "--vault-sql") {
  const ref = projectRef(args[1], "--vault-sql <20-letter project ref>");
  const cron = (await Deno.readTextFile(envFile)).match(/^LITE_CRON_SECRET=([A-Za-z0-9_-]{32,})$/m)?.[1];
  if (!cron) throw new Error(`no LITE_CRON_SECRET in ${envFile}`);
  const url = `https://${ref}.supabase.co/functions/v1/lite-indexer`;
  const upsert = (name: string, value: string) => `
  select id into v_id from vault.secrets where name = '${name}';
  if v_id is null then perform vault.create_secret('${value}', '${name}');
  else perform vault.update_secret(v_id, '${value}'); end if;`;
  const sql = `do $$\ndeclare v_id uuid;\nbegin${upsert("lite_indexer_url", url)}${upsert("lite_cron_secret", cron)}\nend $$;\n`;
  const out = await writeSecretFile("testnet-vault.sql", sql);
  console.log("wrote", out, "for", url, "(delete it once applied)");
  Deno.exit(0);
}

if (args.length) throw new Error(`unknown argument ${args[0]}: --add-keeper, --db-role or --vault-sql`);
if (await exists(envFile)) throw new Error(`${envFile} exists; move it aside first (it holds the current sponsor)`);
const sponsor = Keypair.random();
const keeper = Keypair.random();
// Funded before anything is written, so a failure leaves no file with an unfunded key in it.
await fund(sponsor.publicKey());
await fund(keeper.publicKey());
await Deno.mkdir(dir, { recursive: true });
await Deno.writeTextFile(
  envFile,
  [
    "LITE_NETWORK=testnet",
    "LITE_MIN_BUILD=1",
    `SPONSOR_SECRET=${sponsor.secret()}`,
    `KEEPER_SECRET=${keeper.secret()}`,
    `LITE_JWT_SECRET=${random(36)}`,
    `LITE_CRON_SECRET=${random(24)}`,
    "",
  ].join("\n"),
  { mode: 0o600, createNew: true },
);
console.log("sponsor", sponsor.publicKey(), "and keeper", keeper.publicKey(), "funded; secrets in", envFile, "(git-ignored)");
