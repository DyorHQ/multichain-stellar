// Settle: the outcome of logged transactions still pending, from RPC.
import { sql } from "../../_shared/db.ts";
import { settle } from "../../_shared/plans.ts";
import { txStatus } from "../../_shared/stellar.ts";

/** Settles sponsored transactions the phone stopped polling. */
export async function settlePending(): Promise<number> {
  const rows = await sql()`select hash, plan_id, step_id from lite.tx_log where status = 'pending' and created_at < now() - interval '5 seconds' order by created_at limit 50`;
  let n = 0;
  for (const r of rows) {
    const s = await txStatus(r.hash as string);
    if (s.status === "PENDING") continue;
    await settle(r.hash as string, s.status === "SUCCESS" ? "success" : "failed", s.ledger, s.feeCharged, s.error, r.plan_id as string | null, r.step_id as string | null);
    n++;
  }
  return n;
}
