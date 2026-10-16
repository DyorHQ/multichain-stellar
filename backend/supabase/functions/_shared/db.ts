// Database access (postgres.js over LITE_DB_URL, the lite_api role; never the full-access SUPABASE_DB_URL). One small pool per isolate; `prepare: false` because Supabase
// routes Edge Function traffic through the transaction pooler.
import postgres from "postgres";
import { env } from "./env.ts";

let client: postgres.Sql | null = null;

export function sql(): postgres.Sql {
  if (!client) {
    client = postgres(env.dbUrl, { prepare: false, max: 3, idle_timeout: 20, connect_timeout: 10, onnotice: () => {} });
  }
  return client;
}

/** Unit tests answer queries with a stand-in instead of a database (backend/tests/fixtures/routes/harness.ts). */
export function replaceSql(standIn: postgres.Sql | null): void {
  client = standIn;
}

export async function closeDb(): Promise<void> {
  if (client) {
    await client.end({ timeout: 2 });
    client = null;
  }
}

/** True when `name` ("lite.job_runs") exists. Code that runs before a later migration has been applied (hosted
 *  applies them by hand, in order) checks for that migration's tables first. */
export async function tableExists(name: string): Promise<boolean> {
  const rows = await sql()`select to_regclass(${name}) is not null as present`;
  return Boolean(rows[0]?.present);
}

export type Json = Record<string, unknown> | unknown[];

/** postgres.js returns numeric as string; amounts stay strings end to end (base units). */
export function num(v: unknown): string {
  return v === null || v === undefined ? "0" : String(v);
}
