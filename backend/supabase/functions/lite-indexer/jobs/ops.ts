// Every 10 minutes (docs/DESIGN-stellar-parity.md §6.11): the sponsor's and the keeper's XLM, recorded with the run in
// lite.job_runs, and a warning when either is under LITE_SPONSOR_MIN_XLM or LITE_KEEPER_MIN_XLM; runs older than a
// week are dropped.
import { sql, tableExists } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { classicBalances, fromStroops, keeper, sponsor } from "../../_shared/stellar.ts";

export interface Funds {
  address: string;
  /** XLM, as a decimal. */
  xlm: string;
  /** The warning threshold, in XLM. */
  min: number;
  low: boolean;
}

async function funds(role: "sponsor" | "keeper", address: string, min: number): Promise<Funds> {
  const acct = await classicBalances(address);
  const stroops = BigInt(acct?.balances.find((b) => b.asset === "native")?.balance ?? "0");
  const low = stroops < BigInt(min) * 10_000_000n;
  if (low) console.warn(`ops: the ${role} ${address} holds ${fromStroops(stroops)} XLM, under ${min} XLM: top it up`);
  return { address, xlm: fromStroops(stroops), min, low };
}

export async function ops(): Promise<{ sponsor: Funds; keeper: Funds; prunedRuns: number }> {
  const [s, k] = await Promise.all([
    funds("sponsor", sponsor().publicKey(), env.sponsorMinXlm),
    funds("keeper", keeper().publicKey(), env.keeperMinXlm),
  ]);
  let prunedRuns = 0;
  if (await tableExists("lite.job_runs")) {
    prunedRuns = (await sql()`delete from lite.job_runs where started_at < now() - interval '7 days'`).count;
  }
  return { sponsor: s, keeper: k, prunedRuns };
}
