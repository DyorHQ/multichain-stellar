// Every 10 minutes (docs/DESIGN-stellar-parity.md §6.11): indexed launch-token balances against a live balance(), 60 a
// run, those checked longest ago (or never) first. A mismatch (events not read yet, or a gap in them) is overwritten
// with the live balance and counted, unless the row already holds something newer than that read: an event after its
// ledger, or a read at a later ledger (an RPC node behind the others answered), so a lagging read or an overlapping
// run never takes a balance back. Each balance keeps the ledger it was read at: the watch job counts no event up to
// that ledger again (lite.reconcile_balance, jobs/watch.ts).
import { Account, Contract, Keypair, rpc, TransactionBuilder } from "@stellar/stellar-sdk";
import { sql } from "../../_shared/db.ts";
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
  /** Read live and written. */
  checked: number;
  /** Of those, overwritten with the live balance. */
  mismatched: number;
  /** Newer than the live read: left as they are, checked again next run. */
  newer: number;
  /** Couldn't be read: checked again next run. */
  failed: number;
}

export async function reconcileBalances(): Promise<ReconcileReport> {
  const rows = await sql()`select token, address from lite.token_balances order by checked_at nulls first, updated_at limit ${RECONCILE_PER_RUN}`;
  const report: ReconcileReport = { checked: 0, mismatched: 0, newer: 0, failed: 0 };
  for (let i = 0; i < rows.length; i += PARALLEL) {
    await Promise.all(rows.slice(i, i + PARALLEL).map(async (r) => {
      const live = await balanceAt(String(r.token), String(r.address));
      if (!live) {
        report.failed++;
        return;
      }
      const [{ outcome }] = await sql()`
        select lite.reconcile_balance(${r.token}, ${r.address}, ${live.balance.toString()}, ${live.ledger}) as outcome`;
      if (outcome === "same" || outcome === "corrected") report.checked++;
      if (outcome === "corrected") report.mismatched++;
      if (outcome === "newer") report.newer++;
    }));
  }
  return report;
}

export const reconcile: (() => Promise<unknown>) | null = reconcileBalances;
