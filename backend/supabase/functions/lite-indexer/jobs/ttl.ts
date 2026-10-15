// Rent upkeep (docs/DESIGN-stellar-parity.md §4.8b): the keeper keeps the app's contracts, live launches and the
// Moments still collecting from archiving, the entries checked longest ago first (_shared/ttl.ts).
import { env } from "../../_shared/env.ts";
import { upkeep, upkeepEntries } from "../../_shared/ttl.ts";

/** How long a run may keep sending extensions, from its start. It is a late job (lite-indexer/index.ts): what it doesn't
 *  extend in time comes first the next minute. */
const RUN_MS = 15_000;

export async function ttl() {
  const started = Date.now();
  const policy = env.network.ttlPolicy;
  return await upkeep(await upkeepEntries(policy), policy, started + RUN_MS);
}
