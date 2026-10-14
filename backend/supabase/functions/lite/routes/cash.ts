// Cash: anchors for adding cash and cashing out (SEP-24), and tracking a transfer with one (§6.10).
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { bad, json, readJson, Router, stringArg } from "../../_shared/http.ts";
import { user } from "./auth.ts";

export function register(router: Router): void {
  router.on("GET /v1/cash/anchors", async ({ req, url }) => {
    await user(req);
    const country = (url.searchParams.get("country") ?? "*").toUpperCase();
    const anchors = env.network.anchors.filter((a) => a.countries.includes("*") || a.countries.includes(country));
    return json({ anchors });
  });

  router.on("POST /v1/cash/track", async ({ req }) => {
    const u = await user(req);
    const body = await readJson<{ anchor: string; kind: string; asset: string; amount?: string; anchorTxId: string; status?: string }>(req);
    if (!env.network.anchors.some((a) => a.domain === body.anchor)) throw bad("bad_anchor", "Unknown anchor.");
    if (body.kind !== "deposit" && body.kind !== "withdraw") throw bad("bad_kind", "kind is deposit or withdraw.");
    const rows = await sql()`
      insert into lite.anchor_transfers (address, anchor, kind, asset, amount, anchor_tx_id, status)
      values (${u}, ${body.anchor}, ${body.kind}, ${stringArg(body.asset, "asset", 20)}, ${body.amount ?? null}, ${stringArg(body.anchorTxId, "anchorTxId", 100)}, ${body.status ?? "incomplete"})
      on conflict (anchor, anchor_tx_id) do update set status = excluded.status, amount = coalesce(excluded.amount, lite.anchor_transfers.amount), updated_at = now()
      returning id`;
    return json({ id: rows[0].id });
  });
}
