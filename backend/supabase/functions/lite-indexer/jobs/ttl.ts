// Rent upkeep: extends the contracts' entries before they archive.
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { keepAlive } from "../../_shared/ttl.ts";

/** Keeps the contracts, the launch-token WASM and every launch token's instance from archiving. */
export async function ttl() {
  const c = env.network.contracts;
  const mine = [c.launchpad, c.moments].filter((x): x is string => Boolean(x));
  if (mine.length === 0) return { checked: 0, extended: 0 };
  const tokens = await sql()`select token from lite.launches order by updated_at desc limit 200`;
  const tokenHash = env.network.deployment?.launchTokenWasmHash;
  return await keepAlive([...mine, ...tokens.map((t) => t.token as string)], tokenHash ? [tokenHash] : []);
}
