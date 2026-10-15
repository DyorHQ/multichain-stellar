// Daily: drops reference candles past their retention (docs/DESIGN-stellar-parity.md §6.12): 15-minute candles after
// 35 days, hourly ones after 400 days. Daily candles are kept, so `all` history reaches back to the first one.
import { sql, tableExists } from "../../_shared/db.ts";
import { CANDLE_KEEP_MS, INTERVALS } from "../../_shared/refprices.ts";

export async function purge(now: () => number = Date.now): Promise<Record<string, number> | { skipped: string }> {
  if (!(await tableExists("lite.ref_candles"))) return { skipped: "migration 06 isn't applied" };
  const out: Record<string, number> = {};
  for (const interval of INTERVALS) {
    const keep = CANDLE_KEEP_MS[interval];
    if (keep === null) continue;
    const deleted = await sql()`delete from lite.ref_candles where interval_s = ${interval} and bucket < ${new Date(now() - keep)}`;
    out[`refCandles${interval / 60}m`] = deleted.count;
  }
  return out;
}
