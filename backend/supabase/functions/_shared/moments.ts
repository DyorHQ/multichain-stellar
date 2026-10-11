// Moments (Lite): publish collectible editions and collect them. Metadata JSON is written by the API to public
// storage so the URI on-chain always resolves to something we validated.
import { sql, num } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { fromStroops, invoke, requireAccount, sv, view } from "./stellar.ts";
import { putPublicObject } from "./media.ts";

function momentsId(): string {
  const id = env.network.contracts.moments;
  if (!id) throw new ApiError(503, "not_deployed", "Moments isn't deployed on this network yet.");
  return id;
}

export async function feed(limit: number) {
  const rows = await sql()`select * from lite.moments order by created_at desc limit ${limit}`;
  return rows.map(momentRow);
}

function momentRow(r: Record<string, unknown>) {
  return {
    id: r.id,
    creator: r.creator,
    uri: r.uri,
    title: r.title,
    mediaUrl: r.media_url,
    price: num(r.price),
    quote: r.quote,
    maxEditions: r.max_editions,
    minted: r.minted,
    deadline: r.deadline,
    open: new Date(r.deadline as string).getTime() > Date.now() && (Number(r.max_editions) === 0 || Number(r.minted) < Number(r.max_editions)),
    createdAt: r.created_at,
  };
}

export async function momentDetail(id: number) {
  const rows = await sql()`select * from lite.moments where id = ${id}`;
  if (rows.length === 0) throw notFound("Moment");
  const collectors = await sql()`select collector, quantity, first_token_id, ts from lite.moment_collects where moment_id = ${id} order by ts desc limit 50`;
  return { moment: momentRow(rows[0]), collectors: collectors.map((c) => ({ collector: c.collector, quantity: c.quantity, firstTokenId: c.first_token_id, ts: c.ts })) };
}

/** Editions this account collected and still owns (checked live; NFTs can be transferred). */
export async function owned(user: string) {
  const rows = await sql()`select c.moment_id, c.first_token_id, c.quantity, m.title, m.media_url from lite.moment_collects c join lite.moments m on m.id = c.moment_id
                            where c.collector = ${user} order by c.ts desc limit 40`;
  const out: { tokenId: number; momentId: number; title: string | null; mediaUrl: string | null }[] = [];
  for (const r of rows) {
    for (let i = 0; i < Number(r.quantity); i++) {
      const tokenId = Number(r.first_token_id) + i;
      const owner = await view(momentsId(), "owner_of", [sv.u32(tokenId)]).catch(() => null);
      if (owner === user) out.push({ tokenId, momentId: Number(r.moment_id), title: r.title as string | null, mediaUrl: r.media_url as string | null });
    }
  }
  return out;
}

export interface MetadataInput {
  title: string;
  description?: string;
  mediaUrl: string;
  mediaType: "image" | "video";
}

/** Writes the Moment's metadata JSON (ERC-721 / SEP-50 style) and returns its public URI. */
export async function writeMetadata(user: string, input: MetadataInput): Promise<string> {
  const title = String(input.title ?? "").trim();
  if (!title || title.length > 80) throw bad("bad_title", "Title: 1–80 characters.");
  const desc = String(input.description ?? "").slice(0, 500);
  const base = `${env.supabaseUrl}/storage/v1/object/public/${env.mediaBucket}/`;
  if (typeof input.mediaUrl !== "string" || !input.mediaUrl.startsWith(base)) throw bad("bad_media", "Upload the media through DyorHQ first.");
  const meta: Record<string, unknown> = {
    name: title,
    description: desc,
    image: input.mediaType === "image" ? input.mediaUrl : undefined,
    animation_url: input.mediaType === "video" ? input.mediaUrl : undefined,
    attributes: [{ trait_type: "Creator", value: user }, { trait_type: "Network", value: `Stellar ${env.network.name}` }],
  };
  const path = `moments/${user}/${crypto.randomUUID()}.json`;
  return await putPublicObject(path, JSON.stringify(meta), "application/json");
}

export async function buildMoment(user: string, input: Record<string, unknown>): Promise<PlanView> {
  momentsId();
  if (input.action === "publish") {
    const quote = assetById(env.network, String(input.quote ?? "USDC"));
    if (!quote || !["XLM", "USDC"].includes(quote.id)) throw bad("bad_quote", "Moments are priced in XLM or USDC.");
    const uri = String(input.uri ?? "");
    if (!uri.startsWith(`${env.supabaseUrl}/storage/v1/object/public/`)) throw bad("bad_uri", "Create the metadata through DyorHQ first.");
    const max = Number(input.maxEditions ?? 0);
    const windowSecs = Number(input.windowSecs ?? 86_400);
    if (!Number.isInteger(max) || max < 0 || max > 100_000) throw bad("bad_editions", "Editions: 0 (open) to 100,000.");
    if (!Number.isInteger(windowSecs) || windowSecs < 3_600 || windowSecs > 30 * 86_400) throw bad("bad_window", "Collect window: 1 hour to 30 days.");
    return await createPlan(user, "moment_publish", [{
      label: "Publish Moment",
      spec: { kind: "moment_publish", uri, price: String(input.price), quote: quote.contract, maxEditions: max, windowSecs },
    }]);
  }
  if (input.action === "collect") {
    const id = Number(input.momentId);
    const qty = Number(input.quantity ?? 1);
    if (!Number.isInteger(id) || id < 1) throw bad("bad_moment", "Unknown Moment.");
    if (!Number.isInteger(qty) || qty < 1 || qty > 20) throw bad("bad_quantity", "Collect 1–20 at a time.");
    const m = await view(momentsId(), "get_moment", [sv.u32(id)]);
    const total = (BigInt(m.price) * BigInt(qty)).toString();
    return await createPlan(user, "moment_collect", [{ label: `Collect ${qty}`, spec: { kind: "moment_collect", momentId: id, quantity: qty, maxTotal: total, quote: String(m.quote) } }]);
  }
  throw bad("bad_action", "Unknown action.");
}

registerBuilder("moment_publish", async (user, spec) => {
  const c = momentsId();
  const acct = await requireAccount(user);
  const tx = await invoke(acct, c, "publish", [
    sv.addr(user),
    sv.str(String(spec.uri)),
    sv.i128(String(spec.price)),
    sv.addr(String(spec.quote)),
    sv.u32(Number(spec.maxEditions)),
    sv.u64(BigInt(Number(spec.windowSecs))),
  ]);
  const q = assetById(env.network, String(spec.quote));
  return {
    tx,
    intent: {
      kind: "moment_publish",
      summary: `Publish a Moment at ${fromStroops(String(spec.price))} ${q?.code ?? ""}`,
      spend: {},
      calls: [{ contract: c, fn: "publish" }],
      display: { price: String(spec.price), quote: q?.code ?? "", editions: Number(spec.maxEditions) },
    },
  };
});

registerBuilder("moment_collect", async (user, spec) => {
  const c = momentsId();
  const acct = await requireAccount(user);
  const tx = await invoke(acct, c, "collect", [sv.addr(user), sv.u32(Number(spec.momentId)), sv.u32(Number(spec.quantity)), sv.i128(String(spec.maxTotal))]);
  const q = assetById(env.network, String(spec.quote));
  return {
    tx,
    intent: {
      kind: "moment_collect",
      summary: `Collect ${spec.quantity} for ${fromStroops(String(spec.maxTotal))} ${q?.code ?? ""}`,
      spend: { [String(spec.quote)]: String(spec.maxTotal) },
      calls: [{ contract: c, fn: "collect" }],
      display: { momentId: Number(spec.momentId), quantity: Number(spec.quantity), total: String(spec.maxTotal), quote: q?.code ?? "" },
    },
  };
});
