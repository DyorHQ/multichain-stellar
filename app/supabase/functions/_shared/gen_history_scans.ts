// Writes history_scans.ts from history-scans.json, the canonical definitions of the wallet-history cache's five scans
// (migration 32 seeds the same definitions into history_scans; ios/DyorKit's HistoryScanParityTests checks the app's).
// The Edge Function bundles the generated module rather than importing JSON, so nothing depends on how the bundler
// handles JSON modules; history_scans_test.ts fails when the two differ.
//
//   deno run --allow-read --allow-write supabase/functions/_shared/gen_history_scans.ts
const here = new URL(".", import.meta.url);

export function generatedModule(json: string): string {
  const value = JSON.parse(json);
  return [
    "// GENERATED — do not edit. Source: supabase/functions/_shared/history-scans.json.",
    "// Regenerate: deno run --allow-read --allow-write supabase/functions/_shared/gen_history_scans.ts",
    `export const HISTORY_SCANS = ${JSON.stringify(value, null, 2)} as const;`,
    "",
  ].join("\n");
}

if (import.meta.main) {
  const json = await Deno.readTextFile(new URL("history-scans.json", here));
  await Deno.writeTextFile(new URL("history_scans.ts", here), generatedModule(json));
  console.log("wrote supabase/functions/_shared/history_scans.ts");
}
