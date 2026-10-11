// Creates single-use invite codes for internal testers. Only the code's SHA-256 is stored; the code is printed once.
//   LITE_DB_URL=postgres://… deno run -A --config backend/supabase/functions/deno.json backend/scripts/invite-tester.ts "Jay iPhone" [count] [days]
// Revoke a tester: update lite.testers set revoked_at = now() where address = 'G…';
import postgres from "postgres";
import { hex, sha256 } from "../supabase/functions/_shared/auth.ts";

const url = Deno.env.get("LITE_DB_URL") ?? Deno.env.get("SUPABASE_DB_URL");
if (!url) throw new Error("Set LITE_DB_URL (the dyorhq-stellar-testnet database URL; never production).");
if (url.includes("fmnjqrguvopusfufmirs")) throw new Error("That is the production project. Lite invites live in dyorhq-stellar-testnet only.");
const [label = "tester", count = "1", days = "14"] = Deno.args;
const db = postgres(url, { prepare: false, onnotice: () => {} });
const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I
for (let i = 0; i < Number(count); i++) {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const raw = Array.from(bytes, (b) => alphabet[b % alphabet.length]).join("");
  const code = `DYOR-${raw.slice(0, 5)}-${raw.slice(5)}`;
  await db`insert into lite.invites (code_hash, label, max_uses, expires_at)
           values (${hex(await sha256(code))}, ${label}, 1, now() + ${`${Number(days)} days`}::interval)`;
  console.log(code);
}
await db.end();
