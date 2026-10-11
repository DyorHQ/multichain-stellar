// Database access (postgres.js over SUPABASE_DB_URL). One small pool per isolate; `prepare: false` because Supabase
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

export async function closeDb(): Promise<void> {
  if (client) {
    await client.end({ timeout: 2 });
    client = null;
  }
}

export type Json = Record<string, unknown> | unknown[];

/** postgres.js returns numeric as string; amounts stay strings end to end (base units). */
export function num(v: unknown): string {
  return v === null || v === undefined ? "0" : String(v);
}
