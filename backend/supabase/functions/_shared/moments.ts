// Moments (docs/DESIGN-stellar-parity.md §6.9): SEP-50 editions in one collection, published by a creator and
// collected in XLM or USDC, with no coin and no graduation. The board, a Moment's page and an account's editions read
// what the indexer recorded (lite-indexer/handlers/moments.ts); My Moments adds DyorHQ's own history. The metadata JSON
// is written by the API to lite-media, so the URI on chain always resolves to something we checked, and only the
// Moments a creator published with their own metadata are listed. This is the retired generation 1
// (DESIGN-stellar-contracts-v2 §17): lite.moments holds v2's Moments too (moments_v2.ts serves those), and every read
// here is v1's only.
import type { ContractErrorCode, Edition, MomentDetail, MomentRow, MomentState, MyMoments, View } from "./contract.ts";
import { num, sql } from "./db.ts";
import { env } from "./env.ts";
import { amountArg, ApiError, bad, notFound } from "./http.ts";
import { ownUpload, putPublicObject } from "./media.ts";
import { AssetInfo, assetById, NetworkConfig, NetworkName, PriceRef } from "./networks.ts";
import { createPlan, PlanView, registerBuilder, StepSpec } from "./plans.ts";
import { referencePrices, RefPrice, usdOf } from "./refprices.ts";
import { classicBalances, fromStroops, invoke, requireAccount, sv, view } from "./stellar.ts";
import type { Intent } from "./verify.ts";

type Row = Record<string, any>;
type Prices = Record<PriceRef, RefPrice>;

/** Whom a viewer route answers for (lite/routes/auth.ts viewer()). */
export interface MomentViewer {
  address: string | null;
  scope: View;
}

export function momentsId(net: NetworkConfig = env.network): string {
  const id = net.contracts.moments;
  if (!id) throw new ApiError(503, "not_deployed", "Moments isn't deployed on this network yet.");
  return id;
}

// ------------------------------------------------------------------------------------------------ refusals

/** The Moments contract's errors with a stable code (contracts/moments Error): PriceTooLow, Closed, SoldOut. The
 *  others keep the simulation's own message. */
const REFUSALS: Record<number, ContractErrorCode> = { 3: "moment.price_too_low", 7: "moment.closed", 8: "moment.sold_out" };

/** The contract's UnknownMoment. */
const UNKNOWN_MOMENT = 6;

/** The number of the error the Moments contract itself failed with, from a simulation's error text: the host logs the
 *  contract that failed "with contract error". A failure further down (a token's balance, a missing trustline) is
 *  logged by that token's contract, and Moments only passes it on. */
export function momentsError(raw: string, contract: string): number | null {
  const failed = /contract:(C[A-Z2-7]{55}), topics:\[error, Error\(Contract, #(\d+)\)\]/g;
  for (const m of raw.matchAll(failed)) if (m[1] === contract) return Number(m[2]);
  return null;
}

/** A contract's refusal as the API answers it (§6.13): simulation_failed, its stable code, and what its copy shows. */
export function refusal(code: ContractErrorCode, detail: { minPrice?: string; quoteCode?: string; raw?: string } = {}): ApiError {
  const min = detail.minPrice !== undefined ? `${fromStroops(detail.minPrice)} ${detail.quoteCode ?? ""}`.trim() : "";
  const text: Partial<Record<ContractErrorCode, string>> = {
    "moment.closed": "This Moment's collect window has closed.",
    "moment.sold_out": "This Moment is sold out.",
    "moment.price_too_low": min ? `The price is below the minimum (${min}).` : "The price is below the minimum.",
  };
  return new ApiError(422, "simulation_failed", text[code] ?? "The contract refused this.", { contractCode: code, ...detail });
}

function rawOf(err: unknown): string | null {
  return err instanceof ApiError && err.code === "simulation_failed" ? String((err.detail as { raw?: unknown } | undefined)?.raw ?? "") : null;
}

/** Runs a simulation against the Moments contract; its own refusals get their stable codes, and an unknown Moment is
 *  404. `detail` fills a price refusal's minimum. */
async function refusing<T>(contract: string, run: () => Promise<T>, detail: { minPrice?: string; quoteCode?: string } = {}): Promise<T> {
  try {
    return await run();
  } catch (err) {
    const raw = rawOf(err);
    const n = raw === null ? null : momentsError(raw, contract);
    if (n === UNKNOWN_MOMENT) throw notFound("Moment");
    if (n !== null && REFUSALS[n]) throw refusal(REFUSALS[n], { ...detail, raw: raw! });
    throw err;
  }
}

// ------------------------------------------------------------------------------------------------ rows

const iso = (v: unknown): string => new Date(v as string).toISOString();
const known = (v: unknown): boolean => v !== null && v !== undefined;
/** A USD amount: to the cent. */
const usdAmount = (v: number): number => Math.round(v * 100) / 100 || 0;

/** A calendar day ("2026-10-14"), however the driver handed it over. */
function dayText(v: unknown): string | null {
  if (!known(v)) return null;
  return (v instanceof Date ? v.toISOString() : String(v)).slice(0, 10);
}

/** When a Moment happened, as a row records it: the date and time its creator gave (`taken_at`,
 *  "2026-10-14T18:30:00+02:00"), else the day (`taken_on`, "2026-10-14"); null for neither. Each reader of a Moment's
 *  date (the feeds, the v2 publish's on-chain `date`) answers this one value. */
export function takenText(takenAt: unknown, takenOn: unknown): string | null {
  if (typeof takenAt === "string" && takenAt) return takenAt;
  return dayText(takenOn);
}

/** collecting until the window closes or the editions sell out; sold out wins over a closed window. */
export function momentState(maxEditions: number, minted: number, deadline: Date, now: number): MomentState {
  if (maxEditions > 0 && minted >= maxEditions) return "sold_out";
  return deadline.getTime() > now ? "collecting" : "closed";
}

/** `units` of `asset` in USD, to the cent; null without a price. */
function usdOfUnits(units: string, asset: AssetInfo | undefined, prices: Prices): number | null {
  const usd = usdOf(asset, prices);
  if (usd === null || !asset) return null;
  return usdAmount((Number(units) / 10 ** asset.decimals) * usd);
}

/** A photo or a video: as recorded, else (a row indexed before migration 09) from the media's extension. */
function mediaTypeOf(r: Row): "image" | "video" | undefined {
  if (r.media_type === "image" || r.media_type === "video") return r.media_type;
  if (typeof r.media_url !== "string") return undefined;
  return /\.(mp4|mov)$/i.test(r.media_url) ? "video" : "image";
}

/** A lite.moments row as the API's MomentRow (§6.9). */
export function momentRowOf(r: Row, prices: Prices, now: number, net: NetworkConfig = env.network): MomentRow {
  const quote = assetById(net, String(r.quote));
  const maxEditions = Number(r.max_editions);
  const minted = Number(r.minted);
  const state = momentState(maxEditions, minted, new Date(r.deadline), now);
  const price = num(r.price);
  return {
    id: Number(r.id),
    creator: String(r.creator),
    uri: String(r.uri),
    title: r.title ?? null,
    mediaUrl: r.media_url ?? null,
    price,
    quote: String(r.quote),
    maxEditions,
    minted,
    deadline: iso(r.deadline),
    open: state === "collecting",
    createdAt: iso(r.created_at),
    description: r.description ?? null,
    place: r.place ?? null,
    takenOn: takenText(r.taken_at, r.taken_on),
    mediaType: mediaTypeOf(r),
    posterUrl: r.poster_url ?? null,
    quoteCode: quote?.code,
    priceUsd: usdOfUnits(price, quote, prices),
    collects: Number(r.collects ?? 0),
    collectors: Number(r.collectors ?? 0),
    state,
    platformBps: known(r.platform_bps) ? Number(r.platform_bps) : undefined,
    royaltyBps: known(r.royalty_bps) ? Number(r.royalty_bps) : undefined,
    publishedAt: iso(r.created_at),
  };
}

/** A Moment's terms (its platform share and royalty), read from the contract once for a row indexed without them. */
async function withTerms(r: Row, net: NetworkConfig = env.network): Promise<Row> {
  if (known(r.platform_bps) || !net.contracts.moments) return r;
  try {
    const m = await view(net.contracts.moments, "get_moment", [sv.u32(Number(r.id))]);
    const platform = Number(m.platform_bps);
    const royalty = Number(m.royalty_bps);
    await sql()`update lite.moments set platform_bps = ${platform}, royalty_bps = ${royalty} where id = ${r.id} and platform_bps is null`;
    return { ...r, platform_bps: platform, royalty_bps: royalty };
  } catch {
    return r;
  }
}

function editionOf(r: Row): Edition {
  return {
    tokenId: Number(r.token_id),
    momentId: Number(r.moment_id),
    title: r.title ?? null,
    mediaUrl: r.media_url ?? null,
    posterUrl: r.poster_url ?? null,
    mediaType: mediaTypeOf(r) ?? null,
    contract: String(r.contract),
  };
}

// ------------------------------------------------------------------------------------------------ reads

export type MomentFilter = "all" | "collecting" | "closed";

export function filterArg(v: string | null): MomentFilter {
  if (v === null || v === "" || v === "all") return "all";
  if (v === "collecting" || v === "closed") return v;
  throw bad("bad_arg", "filter is all, collecting or closed.");
}

/** v1's Moments: lite.moments holds v2's too (migration 20261015000012), keyed by their NFT address with no number. A
 *  v1 Moment has its contract's number, which holds on a database without that migration too, where every row is
 *  v1's. The reads by number, and the editions and collects joined on it, are v1's already. */
function v1Moment() {
  return sql()`id is not null`;
}

/** GET /v1/moments: listed Moments, newest first. `closed` holds the sold out ones and those whose window closed. */
export async function feed(filter: MomentFilter, limit: number, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MomentRow[]> {
  const at = new Date(now);
  const collecting = sql()`deadline > ${at} and (max_editions = 0 or minted < max_editions)`;
  const where = filter === "collecting" ? sql()`and ${collecting}` : filter === "closed" ? sql()`and not (${collecting})` : sql()``;
  const [rows, prices] = await Promise.all([
    sql()`select * from lite.moments where listed and title is not null and ${v1Moment()} ${where} order by created_at desc, id desc limit ${limit}`,
    referencePrices(now, net),
  ]);
  return rows.map((r) => momentRowOf(r, prices, now, net));
}

/** GET /v1/moments/:id: the Moment, its newest 50 collects, who collected most, what its creator has earned and, for
 *  the viewer's account, the editions it still holds and (owner view) what it spent. 404 for a Moment without a
 *  title: one published without DyorHQ's metadata is never served. */
export async function momentDetail(id: number, v: MomentViewer, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MomentDetail> {
  const rows = await sql()`select * from lite.moments where id = ${id}`;
  if (rows.length === 0 || !known(rows[0].title)) throw notFound("Moment");
  const r = await withTerms(rows[0], net);
  const [collects, largest, earned, prices, you] = await Promise.all([
    sql()`select collector, quantity, first_token_id, ts from lite.moment_collects where moment_id = ${id} order by ts desc limit 50`,
    sql()`
      select collector, sum(quantity)::int as editions from lite.moment_collects where moment_id = ${id}
       group by collector order by editions desc, min(ts) asc limit 1`,
    known(r.platform_bps)
      ? sql()`select coalesce(sum(lite.moment_creator_share(paid, ${Number(r.platform_bps)})), 0) as earned from lite.moment_collects where moment_id = ${id}`
      : Promise.resolve(null),
    referencePrices(now, net),
    yours(id, v),
  ]);
  return {
    moment: momentRowOf(r, prices, now, net),
    collectors: collects.map((c) => ({ collector: String(c.collector), quantity: Number(c.quantity), firstTokenId: Number(c.first_token_id), ts: iso(c.ts) })),
    collectorsSummary: {
      count: Number(r.collectors ?? 0),
      largest: largest.length ? { address: String(largest[0].collector), editions: Number(largest[0].editions) } : null,
    },
    you,
    ...(earned ? { creatorEarned: num(earned[0].earned) } : {}),
    view: v.scope,
  };
}

/** The viewer's part in Moment `id`: the editions it holds and, in the owner view, what it paid for its collects (DyorHQ's
 *  history, null in the public view); null with no account named. */
async function yours(id: number, v: MomentViewer): Promise<MomentDetail["you"]> {
  if (v.address === null) return null;
  const [held, spent] = await Promise.all([
    sql()`select token_id from lite.moment_editions where moment_id = ${id} and owner = ${v.address} order by token_id`,
    v.scope === "owner"
      ? sql()`select coalesce(sum(paid), 0) as spent from lite.moment_collects where moment_id = ${id} and collector = ${v.address}`
      : Promise.resolve(null),
  ]);
  return { editions: held.map((e) => Number(e.token_id)), spent: spent ? num(spent[0].spent) : null };
}

/** GET /v1/moments/owned: the editions `address` holds, from indexed ownership (mints, collects and transfers). */
export async function owned(address: string): Promise<Edition[]> {
  const rows = await sql()`
    select e.token_id, e.moment_id, e.contract, m.title, m.media_url, m.poster_url, m.media_type
      from lite.moment_editions e join lite.moments m on m.id = e.moment_id
     where e.owner = ${address}
     order by e.moment_id desc, e.token_id asc
     limit 500`;
  return rows.map(editionOf);
}

/** Adds `amount` to `map[key]`, keeping base units as decimal strings. */
function addTo(map: Record<string, string>, key: string, amount: bigint): void {
  map[key] = (BigInt(map[key] ?? "0") + amount).toString();
}

/** GET /v1/moments/mine: the Moments `user` published, with what each has paid them, the editions they hold, and the
 *  totals: editions held, the Moments they're from, what the user spent collecting and earned publishing, per quote. */
export async function mine(user: string, now: number = Date.now(), net: NetworkConfig = env.network): Promise<MyMoments> {
  const [createdRows, heldRows, spentRows, prices] = await Promise.all([
    sql()`select * from lite.moments where creator = ${user} and title is not null and ${v1Moment()} order by created_at desc, id desc limit 200`,
    sql()`
      select e.token_id, e.contract, m.* from lite.moment_editions e join lite.moments m on m.id = e.moment_id
       where e.owner = ${user} and m.title is not null
       order by e.moment_id desc, e.token_id asc
       limit 500`,
    sql()`
      select m.quote, sum(c.paid) as spent from lite.moment_collects c join lite.moments m on m.id = c.moment_id
       where c.collector = ${user} group by m.quote`,
    referencePrices(now, net),
  ]);
  const created = await Promise.all(createdRows.map((r) => withTerms(r, net)));
  const proceedsRows = created.length
    ? await sql()`
        select c.moment_id, sum(lite.moment_creator_share(c.paid, m.platform_bps)) as proceeds
          from lite.moment_collects c join lite.moments m on m.id = c.moment_id
         where m.creator = ${user} and m.platform_bps is not null group by c.moment_id`
    : [];
  const proceedsOf = (id: number) => num(proceedsRows.find((p) => Number(p.moment_id) === id)?.proceeds ?? "0");
  const quoteId = (quote: string) => assetById(net, quote)?.id ?? quote;

  const spentByQuote: Record<string, string> = {};
  for (const s of spentRows) if (BigInt(num(s.spent)) > 0n) addTo(spentByQuote, quoteId(String(s.quote)), BigInt(num(s.spent)));
  const earnedByQuote: Record<string, string> = {};
  const createdOut = created.map((r) => {
    const row = momentRowOf(r, prices, now, net);
    const proceeds = proceedsOf(row.id);
    if (BigInt(proceeds) > 0n) addTo(earnedByQuote, quoteId(row.quote), BigInt(proceeds));
    return { ...row, proceeds, proceedsUsd: usdOfUnits(proceeds, assetById(net, row.quote), prices) };
  });
  const collected = heldRows.map((r) => ({
    tokenId: Number(r.token_id),
    momentId: Number(r.id),
    contract: String(r.contract),
    moment: momentRowOf(r, prices, now, net),
  }));
  return {
    created: createdOut,
    collected,
    totals: { editions: collected.length, moments: new Set(collected.map((c) => c.momentId)).size, spentByQuote, earnedByQuote },
  };
}

// ------------------------------------------------------------------------------------------------ metadata

export interface MetadataInput {
  title?: unknown;
  description?: unknown;
  mediaUrl?: unknown;
  mediaType?: unknown;
  posterUrl?: unknown;
  place?: unknown;
  takenOn?: unknown;
}

/** What a Moment's metadata says, checked. */
export interface MomentMetadataFields {
  title: string;
  description: string | null;
  place: string | null;
  /** When it happened: a date and time with its offset ("2026-10-14T18:30:00+02:00"), or a day ("2026-10-14"). */
  takenOn: string | null;
  mediaType: "image" | "video";
  mediaUrl: string;
  /** The photo itself, or the video's poster. */
  posterUrl: string;
}

/** An optional text field: trimmed, null when empty, 400 past `max` characters. */
function optionalText(v: unknown, name: string, max: number): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v !== "string") throw bad("bad_arg", `${name} must be text.`);
  const t = v.trim();
  if (t.length > max) throw bad("bad_arg", `${name}: at most ${max} characters.`);
  return t || null;
}

/** How far ahead of the server's clock a date and time may be: a phone's clock that runs a little fast. */
export const TAKEN_SKEW_MS = 5 * 60_000;

const DAY_FORM = /^(\d{4})-(\d{2})-(\d{2})$/;
/** ISO 8601 with a time and an offset: minutes, seconds and a fraction optional, "Z" or ±hh:mm. */
const DATE_TIME_FORM = /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,9})?)?(Z|[+-](\d{2}):(\d{2}))$/;

/** Whether `day` ("2026-10-14") is a real calendar day. */
function realDay(day: string): boolean {
  const t = Date.parse(`${day}T00:00:00.000Z`);
  return !Number.isNaN(t) && new Date(t).toISOString().slice(0, 10) === day;
}

/** When a Moment happened, as Publish sends it (`takenOn`), checked and written one way:
 *  - a day, "2026-10-14": a real day no later than tomorrow (the phone's today, wherever it is), as it is;
 *  - a date and time, ISO 8601 with its offset ("2026-10-14T18:30+02:00", "…T16:30:27.5Z"): a real day and time, an
 *    offset of at most 14 hours, not later than now (give or take a phone clock's `TAKEN_SKEW_MS`), written to the
 *    second with the creator's own offset ("2026-10-14T18:30:00+02:00", at most 25 bytes, within the contract's 32).
 *  Null for none. Its `day` is the creator's own calendar day, what `taken_on` keeps. */
export function takenArg(v: unknown, now: number): { text: string; day: string; time: boolean } | null {
  if (v === undefined || v === null || v === "") return null;
  const bad_ = bad("bad_arg", "takenOn is a date, YYYY-MM-DD, or a date and time with its offset (ISO 8601), not in the future.");
  if (typeof v !== "string") throw bad_;
  if (DAY_FORM.test(v)) {
    if (!realDay(v) || Date.parse(`${v}T00:00:00.000Z`) > now + 86_400_000) throw bad_;
    return { text: v, day: v, time: false };
  }
  const m = DATE_TIME_FORM.exec(v);
  if (!m) throw bad_;
  const [, day, hh, mm, ss = "00", zone, oh = "00", om = "00"] = m;
  if (!realDay(day) || Number(hh) > 23 || Number(mm) > 59 || Number(ss) > 59 || Number(om) > 59 || Number(oh) * 60 + Number(om) > 14 * 60) {
    throw bad_;
  }
  const offset = zone === "Z" || Number(oh) + Number(om) === 0 ? "Z" : `${zone[0]}${oh}:${om}`;
  const text = `${day}T${hh}:${mm}:${ss}${offset}`;
  const at = Date.parse(text);
  if (Number.isNaN(at) || at > now + TAKEN_SKEW_MS) throw bad_;
  return { text, day, time: true };
}

/** The metadata a request describes, checked: a title (1–80 characters), the user's own upload of the media, and for a
 *  video the user's own upload of its poster (400 bad_media without one). A photo is its own poster. */
export function metadataFields(user: string, input: MetadataInput, now: number = Date.now()): MomentMetadataFields {
  const title = typeof input.title === "string" ? input.title.trim() : "";
  if (!title || title.length > 80) throw bad("bad_title", "Title: 1–80 characters.");
  const description = optionalText(input.description, "description", 500);
  const place = optionalText(input.place, "place", 64);
  const takenOn = takenArg(input.takenOn, now)?.text ?? null;
  const mediaType = input.mediaType;
  if (mediaType !== "image" && mediaType !== "video") throw bad("bad_media", "mediaType is image or video.");
  const mediaUrl = ownUpload(input.mediaUrl, user, mediaType);
  if (!mediaUrl) throw bad("bad_media", "Upload the media through DyorHQ first.");
  let posterUrl = mediaUrl;
  if (mediaType === "video") {
    const poster = ownUpload(input.posterUrl, user, "image");
    if (!poster) throw bad("bad_media", "A video needs its cover frame: upload it as an image and send it as posterUrl.");
    posterUrl = poster;
  }
  return { title, description, place, takenOn, mediaType, mediaUrl, posterUrl };
}

/** What a network is called in a Moment's attributes. */
export function networkLabel(name: NetworkName): string {
  return name === "testnet" ? "Stellar Testnet" : "Stellar";
}

/** A Moment's SEP-50 metadata JSON: name, description, image (always: the photo, or the video's poster),
 *  animation_url (videos only), external_url (only where Moments have a public link) and attributes. */
export function sep50Json(creator: string, m: MomentMetadataFields, network: NetworkName, externalUrl: string | null): Record<string, unknown> {
  const attributes = [
    { trait_type: "Creator", value: creator },
    { trait_type: "Network", value: networkLabel(network) },
    ...(m.place ? [{ trait_type: "Place", value: m.place }] : []),
    ...(m.takenOn ? [{ trait_type: "Date", value: m.takenOn }] : []),
  ];
  return {
    name: m.title,
    description: m.description ?? "",
    image: m.posterUrl,
    ...(m.mediaType === "video" ? { animation_url: m.mediaUrl } : {}),
    ...(externalUrl ? { external_url: externalUrl } : {}),
    attributes,
  };
}

/** POST /v1/moments/metadata: writes the Moment's SEP-50 JSON to lite-media and records it (lite.moment_metadata), so
 *  the indexer joins it by URI. Answers the URI to publish with and the poster. The external link is the metadata's
 *  own id under LITE_MOMENT_LINK_BASE, written only when that is set: no Stellar Moment link route exists yet. */
export async function writeMetadata(user: string, input: MetadataInput, now: number = Date.now()): Promise<{ uri: string; posterUrl: string }> {
  const m = metadataFields(user, input, now);
  const id = crypto.randomUUID();
  const linkBase = env.momentLinkBase;
  const external = linkBase ? `${linkBase.replace(/\/*$/, "/")}${id}` : null;
  const json = sep50Json(user, m, env.network.name, external);
  const uri = await putPublicObject(`moments/${user}/${id}.json`, JSON.stringify(json), "application/json");
  // The day goes where every reader of a Moment's date has it; a time, with the creator's offset, beside it.
  const taken = takenArg(m.takenOn, Number.POSITIVE_INFINITY);
  await sql()`
    insert into lite.moment_metadata (uri, address, title, description, place, taken_on, taken_at, media_type, media_url, poster_url)
    values (${uri}, ${user}, ${m.title}, ${m.description}, ${m.place}, ${taken?.day ?? null}, ${taken?.time ? taken.text : null}, ${m.mediaType},
            ${m.mediaUrl}, ${m.posterUrl})`;
  return { uri, posterUrl: m.posterUrl };
}

// ------------------------------------------------------------------------------------------------ plans

/** The terms a Moment is published under now (config() and quote_rule(quote), read live): the platform share, the
 *  royalty, whether publishing is on, and the quote's minimum price and whether it is enabled. */
export interface PublishPolicy {
  platformBps: number;
  royaltyBps: number;
  publishingEnabled: boolean;
  minPrice: string | null;
  quoteEnabled: boolean;
}

export async function publishPolicy(contract: string, quote: string): Promise<PublishPolicy> {
  const [config, rule] = await Promise.all([view(contract, "config"), view(contract, "quote_rule", [sv.addr(quote)])]);
  return {
    platformBps: Number(config.platform_bps),
    royaltyBps: Number(config.royalty_bps),
    publishingEnabled: config.publishing_enabled === true,
    minPrice: rule ? String(rule.min_price) : null,
    quoteEnabled: Boolean(rule?.enabled),
  };
}

/** Refuses a publish the policy wouldn't take: publishing paused, a quote that isn't enabled, a price under the
 *  minimum (moment.price_too_low, with the minimum). */
export function checkPublish(policy: PublishPolicy, price: bigint, quote: AssetInfo): void {
  if (!policy.publishingEnabled) throw new ApiError(422, "simulation_failed", "Publishing new Moments is paused.");
  if (!policy.quoteEnabled || policy.minPrice === null) throw bad("bad_quote", `Moments can't be priced in ${quote.code} right now.`);
  if (price < BigInt(policy.minPrice)) throw refusal("moment.price_too_low", { minPrice: policy.minPrice, quoteCode: quote.code });
}

function quoteArg(v: unknown, net: NetworkConfig): AssetInfo {
  const quote = assetById(net, String(v ?? "USDC"));
  if (!quote || !["XLM", "USDC"].includes(quote.id)) throw bad("bad_quote", "Moments are priced in XLM or USDC.");
  return quote;
}

type Steps = { label: string; spec: StepSpec }[];

/** A publish's steps: the user's own metadata URI, a price at or above the quote's minimum, 0 (open) to
 *  limits.momentMaxEditions editions, a window within limits.momentWindowSecs; after a user-paid trust step when the
 *  price is in a classic asset (USDC) the creator hasn't enabled, since collects pay the creator in it. */
export async function publishSteps(user: string, input: Record<string, unknown>, net: NetworkConfig = env.network): Promise<Steps> {
  const c = momentsId(net);
  const limits = net.limits;
  const quote = quoteArg(input.quote, net);
  const uri = typeof input.uri === "string" ? input.uri : "";
  if (!uri || uri.length > limits.uriMax) throw bad("bad_uri", "Create the metadata through DyorHQ first.");
  const price = amountArg(input.price, "price");
  const max = Number(input.maxEditions ?? 0);
  const windowSecs = Number(input.windowSecs ?? 86_400);
  const [minWindow, maxWindow] = limits.momentWindowSecs;
  if (!Number.isInteger(max) || max < 0 || max > limits.momentMaxEditions) {
    throw bad("bad_editions", `Editions: 0 (open) to ${limits.momentMaxEditions.toLocaleString("en-US")}.`);
  }
  if (!Number.isInteger(windowSecs) || windowSecs < minWindow || windowSecs > maxWindow) throw bad("bad_window", "Collect window: 1 hour to 30 days.");
  const written = await sql()`select 1 from lite.moment_metadata where uri = ${uri} and address = ${user}`;
  if (written.length === 0) throw bad("bad_uri", "Create the metadata through DyorHQ first.");
  checkPublish(await publishPolicy(c, quote.contract), price, quote);
  const steps: Steps = [];
  if (quote.classic && quote.classic !== "native") {
    const account = await classicBalances(user);
    if (account && !account.balances.some((b) => b.asset === quote.classic)) {
      steps.push({ label: `Enable ${quote.code}`, spec: { kind: "trust", asset: quote.classic } });
    }
  }
  steps.push({
    label: "Publish Moment",
    spec: { kind: "moment_publish", uri, price: price.toString(), quote: quote.contract, maxEditions: max, windowSecs },
  });
  return steps;
}

/** A collect's step: 1 to limits.collectMax editions of a Moment still collecting, at its price (read live). */
export async function collectSteps(input: Record<string, unknown>, net: NetworkConfig = env.network, now: number = Date.now()): Promise<Steps> {
  const c = momentsId(net);
  const limits = net.limits;
  const id = Number(input.momentId);
  const qty = Number(input.quantity ?? 1);
  if (!Number.isInteger(id) || id < 1 || id > 2 ** 32 - 1) throw bad("bad_moment", "Unknown Moment.");
  if (!Number.isInteger(qty) || qty < 1 || qty > limits.collectMax) throw bad("bad_quantity", `Collect 1–${limits.collectMax} at a time.`);
  const m = await refusing(c, () => view(c, "get_moment", [sv.u32(id)]));
  if (Number(m.max_editions) > 0 && Number(m.minted) + qty > Number(m.max_editions)) throw refusal("moment.sold_out");
  if (Number(m.deadline) * 1000 <= now) throw refusal("moment.closed");
  const total = (BigInt(m.price) * BigInt(qty)).toString();
  return [{ label: `Collect ${qty}`, spec: { kind: "moment_collect", momentId: id, quantity: qty, maxTotal: total, quote: String(m.quote) } }];
}

/** POST /v1/moments/build: a publish or a collect plan. */
export async function buildMoment(user: string, input: Record<string, unknown>, net: NetworkConfig = env.network): Promise<PlanView> {
  momentsId(net);
  if (input.action === "publish") return await createPlan(user, "moment_publish", await publishSteps(user, input, net));
  if (input.action === "collect") return await createPlan(user, "moment_collect", await collectSteps(input, net));
  throw bad("bad_action", "Unknown action.");
}

/** A publish step's intent. `display` carries the terms the step was built under (platformBps, royaltyBps, minPrice),
 *  which the review compares with what the user was shown (§8.11.4). */
export function publishIntent(contract: string, spec: StepSpec, quote: AssetInfo, policy: PublishPolicy): Intent {
  return {
    kind: "moment_publish",
    summary: `Publish a Moment at ${fromStroops(String(spec.price), quote.decimals)} ${quote.code}`,
    spend: {},
    calls: [{ contract, fn: "publish" }],
    display: {
      price: String(spec.price),
      quote: quote.code,
      editions: Number(spec.maxEditions),
      windowSecs: Number(spec.windowSecs),
      platformBps: policy.platformBps,
      royaltyBps: policy.royaltyBps,
      minPrice: policy.minPrice,
    },
  };
}

/** A collect step's intent: the most it may spend, in the Moment's quote. */
export function collectIntent(contract: string, spec: StepSpec, quote: AssetInfo | undefined): Intent {
  return {
    kind: "moment_collect",
    summary: `Collect ${spec.quantity} for ${fromStroops(String(spec.maxTotal), quote?.decimals ?? 7)} ${quote?.code ?? ""}`.trim(),
    spend: { [String(spec.quote)]: String(spec.maxTotal) },
    calls: [{ contract, fn: "collect" }],
    display: { momentId: Number(spec.momentId), quantity: Number(spec.quantity), total: String(spec.maxTotal), quote: quote?.code ?? "" },
  };
}

registerBuilder("moment_publish", async (user, spec) => {
  const c = momentsId();
  const quote = assetById(env.network, String(spec.quote));
  if (!quote) throw bad("bad_quote", "Moments are priced in XLM or USDC.");
  // The terms as they stand when the step is built, read with config() and quote_rule() of their own.
  const policy = await publishPolicy(c, quote.contract);
  checkPublish(policy, BigInt(String(spec.price)), quote);
  const acct = await requireAccount(user);
  const tx = await refusing(c, () =>
    invoke(acct, c, "publish", [
      sv.addr(user),
      sv.str(String(spec.uri)),
      sv.i128(String(spec.price)),
      sv.addr(quote.contract),
      sv.u32(Number(spec.maxEditions)),
      sv.u64(BigInt(Number(spec.windowSecs))),
    ]), { minPrice: policy.minPrice ?? undefined, quoteCode: quote.code });
  return { tx, intent: publishIntent(c, spec, quote, policy) };
});

registerBuilder("moment_collect", async (user, spec) => {
  const c = momentsId();
  const acct = await requireAccount(user);
  // The collector is the user: the editions are minted to them, and they pay.
  const tx = await refusing(c, () => invoke(acct, c, "collect", [sv.addr(user), sv.u32(Number(spec.momentId)), sv.u32(Number(spec.quantity)), sv.i128(String(spec.maxTotal))]));
  return { tx, intent: collectIntent(c, spec, assetById(env.network, String(spec.quote))) };
});
