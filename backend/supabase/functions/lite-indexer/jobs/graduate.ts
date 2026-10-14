// Graduation keeper: completed curves move to Soroswap.
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { invoke, loadAccount, sendSigned, sponsor, sv } from "../../_shared/stellar.ts";

/** Graduates completed curves nobody graduated yet. The call is permissionless; the sponsor pays the fee. */
export async function graduate(): Promise<number> {
  const pad = env.network.contracts.launchpad;
  if (!pad) return 0;
  const rows = await sql()`select token from lite.launches where completed and not graduated order by updated_at limit 3`;
  let n = 0;
  for (const r of rows) {
    try {
      const sp = sponsor();
      const acct = (await loadAccount(sp.publicKey()))!;
      const tx = await invoke(acct, pad, "graduate", [sv.addr(r.token as string)], 120);
      tx.sign(sp);
      await sendSigned(tx);
      n++;
    } catch (err) {
      console.warn("graduate failed", r.token, String((err as Error).message));
    }
  }
  return n;
}
