// Creates the testnet function secrets without ever printing one (docs/RUNBOOK-testnet.md §1 and §3).
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts
//     Writes .secrets/testnet-functions.env (git-ignored, mode 600): LITE_NETWORK, LITE_MIN_BUILD, a new sponsor's
//     SPONSOR_SECRET, LITE_JWT_SECRET and LITE_CRON_SECRET. Funds the sponsor through Friendbot and prints only its
//     public key. Refuses to overwrite an existing file. Then:
//       supabase secrets set --project-ref <ref> --env-file .secrets/testnet-functions.env
//
//   deno run -A --config backend/supabase/functions/deno.json backend/scripts/new-testnet-secrets.ts --vault-sql <ref>
//     Writes .secrets/testnet-vault.sql (mode 600): creates or updates the two Vault entries the cron job reads,
//     lite_indexer_url and lite_cron_secret (the same value as LITE_CRON_SECRET). Then:
//       supabase db query --project-ref <ref> --file .secrets/testnet-vault.sql && rm .secrets/testnet-vault.sql
import { Keypair } from "@stellar/stellar-sdk";
import { TESTNET } from "../supabase/functions/_shared/networks.ts";

const root = new URL("../../", import.meta.url).pathname;
const envFile = `${root}.secrets/testnet-functions.env`;
// base64url without padding: safe in an env file, an HTTP header and a SQL string literal.
const random = (bytes: number) =>
  btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(bytes))))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function exists(path: string) {
  try {
    await Deno.stat(path);
    return true;
  } catch {
    return false;
  }
}

if (Deno.args[0] === "--vault-sql") {
  const ref = Deno.args[1] ?? "";
  if (!/^[a-z]{20}$/.test(ref)) throw new Error("usage: --vault-sql <20-letter project ref>");
  if (ref === "fmnjqrguvopusfufmirs") throw new Error("that is the production project; Lite never writes to it");
  const cron = (await Deno.readTextFile(envFile)).match(/^LITE_CRON_SECRET=([A-Za-z0-9_-]{32,})$/m)?.[1];
  if (!cron) throw new Error(`no LITE_CRON_SECRET in ${envFile}`);
  const url = `https://${ref}.supabase.co/functions/v1/lite-indexer`;
  const upsert = (name: string, value: string) => `
  select id into v_id from vault.secrets where name = '${name}';
  if v_id is null then perform vault.create_secret('${value}', '${name}');
  else perform vault.update_secret(v_id, '${value}'); end if;`;
  const sql = `do $$\ndeclare v_id uuid;\nbegin${upsert("lite_indexer_url", url)}${upsert("lite_cron_secret", cron)}\nend $$;\n`;
  const out = `${root}.secrets/testnet-vault.sql`;
  await Deno.writeTextFile(out, sql, { mode: 0o600 });
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
