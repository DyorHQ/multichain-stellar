// Every 10 minutes (docs/DESIGN-stellar-parity.md §6.11): indexed launch-token balances against a live balance(), 60 a
// run, those checked longest ago (or never) first. A mismatch (events not read yet, or a gap in them) is overwritten
// with the live balance and counted. Each balance keeps the ledger it was read at: the watch job counts no event up to
// that ledger again (jobs/watch.ts).
import { Account, Contract, Keypair, rpc, TransactionBuilder } from "@stellar/stellar-sdk";
import { num, sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { native, rpcServer, sv } from "../../_shared/stellar.ts";

/** Balances checked per run. */
export const RECONCILE_PER_RUN = 60;
/** Reads at once. */
const PARALLEL = 10;

/** `address`'s balance of `token` and the ledger it was read at; null when it can't be read. */
export async function balanceAt(token: string, address: string): Promise<{ balance: bigint; ledger: number } | null> {
  try {
    const source = new Account(Keypair.random().publicKey(), "0");
    const tx = new TransactionBuilder(source, { fee: "100", networkPassphrase: env.network.passphrase })
      .setTimeout(30)
      .addOperation(new Contract(token).call("balance", sv.addr(address)))
      .build();
    const r = await rpcServer().simulateTransaction(tx);
    if (rpc.Api.isSimulationError(r) || !r.result) return null;
    return { balance: BigInt(native(r.result.retval)), ledger: r.latestLedger };
  } catch {
    return null;
  }
}

export interface ReconcileReport {
  checked: number;
  /** Overwritten with the live balance. */
  mismatched: number;
  /** Couldn't be read: checked again next run. */
  failed: number;
}

export async function reconcileBalances(): Promise<ReconcileReport> {
  const rows = await sql()`select token, address, balance from lite.token_balances order by checked_at nulls first, updated_at limit ${RECONCILE_PER_RUN}`;
  const report: ReconcileReport = { checked: 0, mismatched: 0, failed: 0 };
  for (let i = 0; i < rows.length; i += PARALLEL) {
    await Promise.all(rows.slice(i, i + PARALLEL).map(async (r) => {
      const live = await balanceAt(String(r.token), String(r.address));
      if (!live) {
        report.failed++;
        return;
      }
      const differs = live.balance !== BigInt(num(r.balance).split(".")[0]);
      await sql()`
        update lite.token_balances set balance = ${live.balance.toString()}, checked_ledger = ${live.ledger}, checked_at = now(),
               updated_at = case when ${differs} then now() else updated_at end
         where token = ${r.token} and address = ${r.address}`;
      report.checked++;
      if (differs) report.mismatched++;
    }));
  }
  return report;
}

export const reconcile: (() => Promise<unknown>) | null = reconcileBalances;
