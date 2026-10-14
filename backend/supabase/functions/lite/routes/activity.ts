// Activity: the account's transactions, bridge transfers and anchor transfers, newest first (§6.10).
import { num, sql } from "../../_shared/db.ts";
import { json, Router } from "../../_shared/http.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/activity", async ({ req }) => {
    const u = await user(req);
    const txs = await sql()`select hash, kind, intent, status, ledger, created_at from lite.tx_log where address = ${u} order by created_at desc limit 50`;
    const bridges = await sql()`select id, direction, amount, status, created_at from lite.bridge_transfers where address = ${u} order by created_at desc limit 20`;
    const cash = await sql()`select id, anchor, kind, asset, amount, status, created_at from lite.anchor_transfers where address = ${u} order by created_at desc limit 20`;
    const items = [
      ...txs.map((t) => ({ type: "tx", id: t.hash, kind: t.kind, summary: (t.intent as any)?.summary ?? t.kind, display: (t.intent as any)?.display ?? null, status: t.status, at: t.created_at })),
      ...bridges.map((b) => ({ type: "bridge", id: b.id, kind: b.direction, summary: b.direction === "monad_to_stellar" ? "Moved USDC from Monad" : "Sent USDC to Monad", amount: num(b.amount), status: b.status, at: b.created_at })),
      // display.asset: the app words the item itself, in the user's language ("native" is XLM).
      ...cash.map((c) => ({ type: "cash", id: c.id, kind: c.kind, summary: c.kind === "deposit" ? `Added ${c.asset}` : `Cashed out ${c.asset}`, amount: c.amount === null ? null : num(c.amount), display: { asset: c.asset }, status: c.status, at: c.created_at })),
    ].sort((a, b) => new Date(b.at as string).getTime() - new Date(a.at as string).getTime());
    return json({ items: items.slice(0, 80) });
  });
}
