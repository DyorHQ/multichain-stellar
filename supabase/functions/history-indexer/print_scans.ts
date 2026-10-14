// Prints the bundled scan definitions as migration 32's "Verify after apply" query prints the deployed rows, one
// canonical line per scan, so the two can be diffed after `apply_migration` (and after any redefining migration).
//
//   deno run supabase/functions/history-indexer/print_scans.ts
import { bundledDefs, canonicalLines } from "./scans.ts";

for (const line of canonicalLines(bundledDefs())) console.log(line);
