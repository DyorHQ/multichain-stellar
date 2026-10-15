// Graduation keeper (docs/DESIGN-stellar-parity.md §4.7): completed curves move to Soroswap. The call is permissionless,
// and the keeper pays for it.
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { inclusionFee } from "../../_shared/fees.ts";
import { invoke, keeper, keeperSend, requireAccount, sv, waitForTx, withInclusionBid } from "../../_shared/stellar.ts";

/** How long a run may keep graduating, from its start. */
const RUN_MS = 25_000;

/** Graduates completed curves nobody graduated yet, at most 3 a run, one transaction at a time: the keeper's account
 *  has at most one in flight. Answers how many graduated. */
export async function graduate(): Promise<number> {
  const pad = env.network.contracts.launchpad;
  if (!pad) return 0;
  const rows = await sql()`select token from lite.launches where completed and not graduated order by updated_at limit 3`;
  const until = Date.now() + RUN_MS;
  let n = 0;
  for (const r of rows) {
    if (Date.now() >= until) break;
    const token = String(r.token);
    try {
      const acct = await requireAccount(keeper().publicKey());
      const tx = withInclusionBid(await invoke(acct, pad, "graduate", [sv.addr(token)], 120), await inclusionFee("soroban"));
      const hash = await keeperSend("graduate", tx, { token });
      const s = await waitForTx(hash, Math.max(5_000, until - Date.now()));
      if (s.status === "SUCCESS") n++;
      else console.warn("graduate: not confirmed", token, s.status, s.error ?? "");
    } catch (err) {
      console.warn("graduate failed", token, String((err as Error).message));
    }
  }
  return n;
}
