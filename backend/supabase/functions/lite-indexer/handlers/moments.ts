// The Moments contract's events: publish, collect.
import { sql } from "../../_shared/db.ts";
import type { ContractEvent } from "../jobs/main_events.ts";

async function fetchMetadata(uri: string): Promise<{ title: string | null; media: string | null }> {
  if (!uri.startsWith("https://")) return { title: null, media: null };
  try {
    const res = await fetch(uri, { signal: AbortSignal.timeout(3_000) });
    if (!res.ok) return { title: null, media: null };
    const m = await res.json();
    return { title: typeof m.name === "string" ? m.name.slice(0, 80) : null, media: typeof (m.image ?? m.animation_url) === "string" ? (m.image ?? m.animation_url) : null };
  } catch {
    return { title: null, media: null };
  }
}

export async function momentsEvent({ raw: e, kind, topics, data, ts }: ContractEvent): Promise<void> {
  if (kind === "publish") {
    const meta = await fetchMetadata(String(data.uri));
    await sql()`
      insert into lite.moments (id, creator, uri, title, media_url, price, quote, max_editions, deadline, created_ledger, created_at)
      values (${Number(topics[1])}, ${topics[2]}, ${data.uri}, ${meta.title}, ${meta.media}, ${String(data.price)}, ${data.quote}, ${Number(data.max_editions)},
              ${new Date(Number(data.deadline) * 1000)}, ${e.ledger}, ${ts})
      on conflict (id) do nothing`;
  } else if (kind === "collect") {
    const inserted = await sql()`
      insert into lite.moment_collects (event_id, moment_id, collector, quantity, first_token_id, paid, tx_hash, ledger, ts)
      values (${e.id}, ${Number(topics[1])}, ${topics[2]}, ${Number(data.quantity)}, ${Number(data.first_token_id)}, ${String(data.paid)}, ${e.txHash ?? null}, ${e.ledger}, ${ts})
      on conflict (event_id) do nothing returning event_id`;
    if (inserted.length) await sql()`update lite.moments set minted = ${Number(data.minted)}, updated_at = now() where id = ${Number(topics[1])}`;
  }
}
