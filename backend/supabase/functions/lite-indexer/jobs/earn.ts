// Every 10 minutes (lite-indexer/index.ts): a snapshot of each Earn market's supply APY, borrow APY, utilization and
// size into lite.earn_snapshots, which GET /v1/earn/history reads (docs/DESIGN-stellar-parity.md §6.10). Skipped until
// migration 08 is applied.
import { tableExists } from "../../_shared/db.ts";
import { snapshot, SnapshotResult } from "../../_shared/earn.ts";

export async function earn(): Promise<SnapshotResult | { skipped: string }> {
  if (!(await tableExists("lite.earn_snapshots"))) return { skipped: "migration 08 isn't applied" };
  return await snapshot();
}
