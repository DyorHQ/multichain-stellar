// The launchpad's events: launch, trade, complete, graduate.
import { sql } from "../../_shared/db.ts";
import type { ContractEvent } from "../jobs/main_events.ts";

export async function launchpadEvent({ raw: e, kind, topics, data, ts }: ContractEvent): Promise<void> {
  if (kind === "launch") {
    await sql()`
      insert into lite.launches (token, creator, quote, name, symbol, uri, launch_index, supply, phantom, threshold, creator_fee_bps, quote_reserve, token_reserve, created_ledger, created_at)
      values (${topics[1]}, ${topics[2]}, ${data.quote}, ${data.name}, ${data.symbol}, ${data.uri}, ${data.index}, ${String(data.supply)}, ${String(data.phantom)}, ${String(data.threshold)},
              ${data.creator_fee_bps}, ${String(data.phantom)}, ${String(data.supply)}, ${e.ledger}, ${ts})
      on conflict (token) do nothing`;
  } else if (kind === "trade") {
    const price = Number(data.quote_reserve) / Number(data.token_reserve);
    const inserted = await sql()`
      insert into lite.launch_trades (event_id, token, trader, side, quote_amount, token_amount, fees, price, tx_hash, ledger, ts)
      values (${e.id}, ${topics[1]}, ${topics[2]}, ${data.is_buy ? "buy" : "sell"}, ${String(data.quote_amount)}, ${String(data.token_amount)}, ${String(data.fees)},
              ${price}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
      on conflict (event_id) do nothing returning event_id`;
    if (inserted.length) {
      await sql()`
        update lite.launches set quote_reserve = ${String(data.quote_reserve)}, token_reserve = ${String(data.token_reserve)}, real_quote = ${String(data.real_quote)},
               last_price = ${price}, volume_quote = volume_quote + ${String(data.quote_amount)}, trades = trades + 1, updated_at = now()
         where token = ${topics[1]}`;
    }
  } else if (kind === "complete") {
    await sql()`update lite.launches set completed = true, updated_at = now() where token = ${topics[1]}`;
  } else if (kind === "graduate") {
    await sql()`update lite.launches set graduated = true, completed = true, pair = ${data.pair}, updated_at = now() where token = ${topics[1]}`;
  }
}
