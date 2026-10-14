// Clearing what the indexer built from chain events, when its cursor no longer describes the chain: the ledger went
// backwards (a testnet reset) or other contracts are pinned (a new deployment). docs/DESIGN-stellar-parity.md §6.1.
import { sql } from "../../_shared/db.ts";
import { NetworkName } from "../../_shared/networks.ts";

export type ResetReason = "ledger_backwards" | "new_deployment";

/** Every table the indexer fills from events, and its cursors. Metadata and reference tables are kept. A table that
 *  a later migration adds is skipped until that migration is applied. */
export const INDEXED_TABLES = [
  "lite.launch_trades",
  "lite.launches",
  "lite.moment_collects",
  "lite.moments",
  "lite.pool_swaps",
  "lite.creator_claims",
  "lite.token_events",
  "lite.token_balances",
  "lite.watch_contracts",
  "lite.watch_groups",
  "lite.moment_editions",
  "lite.indexer_cursors",
];

/** Testnet clears for either reason. Mainnet never clears for a ledger "going backwards", which there can only be an
 *  RPC lagging behind, and clears for a new deployment only when LITE_INDEXER_ALLOW_RESET says so. */
export function resetAllowed(reason: ResetReason, network: NetworkName, allowReset: boolean): boolean {
  if (network === "testnet") return true;
  return reason === "new_deployment" && allowReset;
}

/** Truncates every indexed table that exists, in one statement. Returns the tables cleared. */
export async function clearIndexed(): Promise<string[]> {
  const rows = await sql()`select t from unnest(${INDEXED_TABLES}::text[]) as t where to_regclass(t) is not null`;
  const tables = rows.map((r) => r.t as string);
  // The names come from INDEXED_TABLES above, never from input.
  if (tables.length) await sql().unsafe(`truncate ${tables.join(", ")}`);
  return tables;
}
