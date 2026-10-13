// Creates the Lite function secrets without ever printing one (docs/RUNBOOK-testnet.md §1 and §3).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts
//     Writes .secrets/testnet-functions.env (git-ignored, mode 600): LITE_NETWORK, LITE_MIN_BUILD, a new sponsor's
//     SPONSOR_SECRET, LITE_JWT_SECRET and LITE_CRON_SECRET. Funds the sponsor through Friendbot and prints only its
//     public key. Refuses to overwrite an existing file.
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
import { Keypair } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";

const root = new URL("../../", import.meta.url).pathname;
const envFile = `${root}.secrets/testnet-functions.env`;
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

function projectRef(arg: string | undefined, usage: string): string {
  if (!arg || !/^[a-z]{20}$/.test(arg)) throw new Error(`usage: ${usage}`);
  return arg;
}

async function writeSecretFile(name: string, text: string) {
  const out = `${root}.secrets/${name}`;
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

if (Deno.args[0] === "--db-role") {
  const ref = projectRef(Deno.args[1], "--db-role <20-letter project ref> <pooler host>");
  const host = Deno.args[2] ?? "";
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

if (Deno.args[0] === "--vault-sql") {
  const ref = projectRef(Deno.args[1], "--vault-sql <20-letter project ref>");
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

if (await exists(envFile)) throw new Error(`${envFile} exists; move it aside first (it holds the current sponsor)`);
const sponsor = Keypair.random();
await Deno.mkdir(`${root}.secrets`, { recursive: true });
await Deno.writeTextFile(
  envFile,
  [
    "LITE_NETWORK=testnet",
    "LITE_MIN_BUILD=1",
    `SPONSOR_SECRET=${sponsor.secret()}`,
    `LITE_JWT_SECRET=${random(36)}`,
    `LITE_CRON_SECRET=${random(24)}`,
    "",
  ].join("\n"),
  { mode: 0o600 },
);
const r = await fetch(`${TESTNET.friendbotUrl}?addr=${sponsor.publicKey()}`);
if (!r.ok) throw new Error(`friendbot failed for ${sponsor.publicKey()}: ${r.status}`);
await r.body?.cancel();
console.log("sponsor", sponsor.publicKey(), "funded; secrets in", envFile, "(git-ignored)");
