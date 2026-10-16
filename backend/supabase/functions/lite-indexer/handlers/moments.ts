// The Moments contract's events (docs/DESIGN-stellar-parity.md §6.11): publish, collect, and its editions' mint and
// transfer (the contract is the collection too). Decoding is pure (decode*); recording is idempotent (by event id, or as
// the state the event describes), so a page read twice changes nothing.
// - publish: the row, with the metadata the API recorded for its URI (lite.moment_metadata), or else read from our own
//   storage and nowhere else; the terms it was published under (get_moment, read once); listed only with a title and
//   an image, from its creator's own metadata, unless the deployment made it as a smoke test.
// - collect: the collect, the Moment's minted count, collects and collectors, and its editions held by the collector.
// - mint, transfer: who holds the edition now. An owner is set only by an event newer than the one that set it last.
// A read the contract doesn't answer leaves its column empty, never the event unrecorded: the API reads the terms
// later (moments.ts withTerms).
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { localMediaEnabled, readLocal } from "../../_shared/localmedia.ts";
import { anyUpload, mediaBase } from "../../_shared/media.ts";
import { type MomentMetadataFields, takenParts } from "../../_shared/moments.ts";
import { sv, view } from "../../_shared/stellar.ts";
import type { ContractEvent } from "../jobs/main_events.ts";

type Decodable = Pick<ContractEvent, "topics" | "data">;

export interface Published {
  id: number;
  creator: string;
  uri: string;
  price: bigint;
  quote: string;
  maxEditions: number;
  deadline: Date;
}

/** publish [publish, moment_id, creator] {uri, price, quote, max_editions, deadline}. */
export function decodePublish({ topics, data }: Decodable): Published {
  return {
    id: Number(topics[1]),
    creator: String(topics[2]),
    uri: String(data.uri ?? ""),
    price: BigInt(data.price),
    quote: String(data.quote),
    maxEditions: Number(data.max_editions),
    deadline: new Date(Number(data.deadline) * 1000),
  };
}

export interface Collected {
  id: number;
  collector: string;
  quantity: number;
  firstTokenId: number;
  paid: bigint;
  minted: number;
}

/** collect [collect, moment_id, collector] {quantity, first_token_id, paid, minted}. */
export function decodeCollect({ topics, data }: Decodable): Collected {
  return {
    id: Number(topics[1]),
    collector: String(topics[2]),
    quantity: Number(data.quantity),
    firstTokenId: Number(data.first_token_id),
    paid: BigInt(data.paid),
    minted: Number(data.minted),
  };
}

/** The editions a collect minted: first_token_id, then the next quantity − 1 ids. */
export function editionsOf(c: Collected): number[] {
  return Array.from({ length: c.quantity }, (_, i) => c.firstTokenId + i);
}

export interface Moved {
  tokenId: number;
  /** Null for a mint. */
  from: string | null;
  to: string;
}

/** OpenZeppelin's NFT events (stellar-tokens 0.7.2): mint [mint, to] {token_id} and transfer [transfer, from, to]
 *  {token_id}; the token id also as the bare value. */
export function decodeMove({ topics, data }: Decodable): Moved {
  const tokenId = Number(data !== null && typeof data === "object" && !Array.isArray(data) ? data.token_id : Array.isArray(data) ? data[0] : data);
  if (topics[0] === "mint") return { tokenId, from: null, to: String(topics[1]) };
  return { tokenId, from: String(topics[1]), to: String(topics[2]) };
}

/** Listed in the feed: a title and an image (the photo, or the video's poster), and not one of the deployment's smoke
 *  Moments. */
export function listedFor(meta: Pick<MomentMetadataFields, "title" | "posterUrl"> | null, id: number, smoke: number[]): boolean {
  return Boolean(meta?.title && meta.posterUrl) && !smoke.includes(id);
}

/** A metadata JSON's fields, as far as they hold: its name (at most 80 characters), description, Place and Date
 *  attributes, and media only on our storage: `image` an uploaded image, `animation_url` an uploaded video. A video
 *  without an image has no poster. Null without a name or media. */
export function metadataFromJson(json: unknown): MomentMetadataFields | null {
  if (json === null || typeof json !== "object" || Array.isArray(json)) return null;
  const m = json as Record<string, unknown>;
  const title = typeof m.name === "string" ? m.name.trim().slice(0, 80) : "";
  const image = anyUpload(m.image, "image");
  const video = anyUpload(m.animation_url, "video");
  if (!title || !(image || video)) return null;
  const attribute = (name: string): string | null => {
    const a = Array.isArray(m.attributes) ? m.attributes.find((x) => x?.trait_type === name) : null;
    return typeof a?.value === "string" && a.value.trim() ? a.value.trim() : null;
  };
  const place = attribute("Place");
  const date = attribute("Date");
  return {
    title,
    description: typeof m.description === "string" && m.description.trim() ? m.description.trim().slice(0, 500) : null,
    place: place ? place.slice(0, 64) : null,
    takenOn: takenParts(date)?.text ?? null,
    mediaType: video ? "video" : "image",
    mediaUrl: (video ?? image)!,
    // An empty poster means none: the Moment stays off the feed.
    posterUrl: image ?? "",
  };
}

/** The metadata of a Moment published with `uri` by `creator`: what the API recorded, written by that creator; else
 *  the JSON at `uri`, read only from our own storage, under the creator's own folder (3 s, at most 64 KB). */
async function metadataFor(uri: string, creator: string): Promise<MomentMetadataFields | null> {
  const rows = await sql()`select * from lite.moment_metadata where uri = ${uri}`;
  if (rows.length) {
    const r = rows[0];
    if (r.address !== creator) return null;
    return {
      title: r.title,
      description: r.description ?? null,
      place: r.place ?? null,
      takenOn: r.taken_on ? (r.taken_on instanceof Date ? r.taken_on.toISOString() : String(r.taken_on)).slice(0, 10) : null,
      mediaType: r.media_type,
      mediaUrl: r.media_url,
      posterUrl: r.poster_url,
    };
  }
  const base = mediaBase();
  if (!base || !uri.startsWith(`${base}moments/${creator}/`)) return null;
  try {
    if (localMediaEnabled()) return metadataFromJson(JSON.parse(new TextDecoder().decode((await readLocal(uri.slice(base.length))).bytes)));
    const res = await fetch(uri, { signal: AbortSignal.timeout(3_000), redirect: "error" });
    if (!res.ok || Number(res.headers.get("content-length") ?? "0") > 65_536) {
      await res.body?.cancel();
      return null;
    }
    const text = await res.text();
    return text.length > 65_536 ? null : metadataFromJson(JSON.parse(text));
  } catch {
    return null;
  }
}

/** The terms a Moment was published under, or null when the contract doesn't answer. */
async function termsOf(contract: string, id: number): Promise<{ platformBps: number; royaltyBps: number } | null> {
  try {
    const m = await view(contract, "get_moment", [sv.u32(id)]);
    return { platformBps: Number(m.platform_bps), royaltyBps: Number(m.royalty_bps) };
  } catch {
    return null;
  }
}

/** Sets who holds `tokens` (moment `momentId` when known) as of event `eventId`, unless a newer event already did. */
async function hold(contract: string, tokens: number[], owner: string, momentId: number | null, eventId: string, ledger: number): Promise<void> {
  await sql()`
    insert into lite.moment_editions (contract, token_id, moment_id, owner, owner_event, updated_ledger)
    select ${contract}, t, ${momentId}, ${owner}, ${eventId}, ${ledger} from unnest(${tokens}::int[]) as t
    on conflict (contract, token_id) do update set
      moment_id = coalesce(excluded.moment_id, lite.moment_editions.moment_id),
      owner = case when excluded.owner_event >= lite.moment_editions.owner_event then excluded.owner else lite.moment_editions.owner end,
      owner_event = greatest(excluded.owner_event, lite.moment_editions.owner_event),
      updated_ledger = greatest(excluded.updated_ledger, lite.moment_editions.updated_ledger),
      updated_at = now()`;
}

export async function momentsEvent(event: ContractEvent): Promise<void> {
  const { raw: e, kind, ts } = event;
  const net = env.network;
  const contract = net.contracts.moments!;
  if (kind === "publish") {
    const p = decodePublish(event);
    const meta = await metadataFor(p.uri, p.creator);
    const terms = await termsOf(contract, p.id);
    const listed = listedFor(meta, p.id, net.deployment?.smoke.moments ?? []);
    await sql()`
      insert into lite.moments (id, creator, uri, title, media_url, price, quote, max_editions, deadline, created_ledger, created_at,
                                description, place, taken_on, media_type, poster_url, platform_bps, royalty_bps, listed)
      values (${p.id}, ${p.creator}, ${p.uri}, ${meta?.title ?? null}, ${meta?.mediaUrl ?? null}, ${p.price.toString()}, ${p.quote},
              ${p.maxEditions}, ${p.deadline}, ${e.ledger}, ${ts}, ${meta?.description ?? null}, ${meta?.place ?? null},
              ${takenParts(meta?.takenOn)?.day ?? null}, ${meta?.mediaType ?? null}, ${meta?.posterUrl || null}, ${terms?.platformBps ?? null},
              ${terms?.royaltyBps ?? null}, ${listed})
      on conflict (id) do nothing`;
  } else if (kind === "collect") {
    const c = decodeCollect(event);
    // A collect of a Moment published before the indexed window (none in a deployment indexed from its start) is
    // skipped rather than stopping the indexer.
    const inserted = await sql()`
      insert into lite.moment_collects (event_id, moment_id, collector, quantity, first_token_id, paid, tx_hash, ledger, ts)
      select ${e.id}, ${c.id}, ${c.collector}, ${c.quantity}, ${c.firstTokenId}, ${c.paid.toString()}, ${e.txHash ?? null}, ${e.ledger}, ${ts}
       where exists (select 1 from lite.moments where id = ${c.id})
      on conflict (event_id) do nothing returning event_id`;
    if (inserted.length) {
      await sql()`
        update lite.moments set minted = greatest(minted, ${c.minted}), collects = collects + 1,
               collectors = (select count(distinct collector) from lite.moment_collects where moment_id = ${c.id}), updated_at = now()
         where id = ${c.id}`;
    }
    const known = await sql()`select 1 from lite.moments where id = ${c.id}`;
    await hold(contract, editionsOf(c), c.collector, known.length ? c.id : null, String(e.id), e.ledger);
  } else if (kind === "mint" || kind === "transfer") {
    const m = decodeMove(event);
    await hold(contract, [m.tokenId], m.to, null, String(e.id), e.ledger);
  }
}
