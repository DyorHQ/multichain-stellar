// Settle (docs/DESIGN-stellar-parity.md §4.8, §6.11): the outcome of logged transactions still pending, from RPC: the
// users' (lite.tx_log: status, the fee charged, what the step delivered, its plan step and sponsorship) and the
// keeper's (lite.keeper_log).
import { sql, tableExists } from "../../_shared/db.ts";
import { LoggedTx, settle } from "../../_shared/plans.ts";
import { txStatus } from "../../_shared/stellar.ts";

/** A transaction still unseen this long after it was logged has expired without landing (a step is valid for 10
 *  minutes): it failed, and charged nothing. */
const EXPIRED_MS = 15 * 60_000;

/** Settles the logged transactions the phone stopped polling. Answers how many it settled. */
export async function settlePending(): Promise<number> {
  const rows = await sql()`
    select hash, status, plan_id, step_id, step_kind, fee_payer, created_at from lite.tx_log
     where status = 'pending' and created_at < now() - interval '5 seconds' order by created_at limit 50`;
  let n = 0;
  for (const r of rows) {
    let s = await txStatus(r.hash as string);
    if (s.status === "PENDING") {
      if (Date.now() - new Date(r.created_at as Date).getTime() < EXPIRED_MS) continue;
      s = { status: "FAILED", feeCharged: "0", error: "txNotFound" };
    }
    await settle(r as unknown as LoggedTx, s);
    n++;
  }
  return n + await settleKeeperLog();
}

async function settleKeeperLog(): Promise<number> {
  if (!(await tableExists("lite.keeper_log"))) return 0;
  const rows = await sql()`
    select hash, created_at from lite.keeper_log where status = 'pending' and created_at < now() - interval '5 seconds' order by created_at limit 20`;
  let n = 0;
  for (const r of rows) {
    let s = await txStatus(r.hash as string);
    if (s.status === "PENDING") {
      if (Date.now() - new Date(r.created_at as Date).getTime() < EXPIRED_MS) continue;
      s = { status: "FAILED", feeCharged: "0", error: "txNotFound" };
    }
    await sql()`update lite.keeper_log set status = ${s.status === "SUCCESS" ? "success" : "failed"}, ledger = ${s.ledger ?? null},
                fee_charged = ${s.feeCharged ?? null}, error = ${s.error ?? null}, updated_at = now()
                where hash = ${r.hash as string} and status = 'pending'`;
    n++;
  }
  return n;
}
