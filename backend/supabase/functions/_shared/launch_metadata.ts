// A launch's metadata (docs/DESIGN-stellar-parity.md §6.9): its name, ticker, description, image and links.
// - POST /v1/launches/metadata checks them, writes the JSON {name, symbol, description, image, links} to the media
//   bucket under launches/<address>/ and records it in lite.launch_metadata, by the URI it answers. Create then takes
//   that URI, and only from the address that wrote it.
// - The indexer joins a launch to its metadata by the URI it carries on chain, under create's rule: only metadata its
//   creator wrote for its name and ticker (a launch made on the contract directly may carry anyone's URI). A launch
//   whose URI is an image its creator uploaded (as an older app created them) has that image and nothing else.
// The image must be one this address uploaded through DyorHQ (media.ts): exactly uploads/<address>/<file>, so a launch
// never shows someone else's file or one from outside our storage; links are https, and only to the sites they name.
import type { LaunchMetadataRequest, MetadataUri } from "./contract.ts";
import { sql } from "./db.ts";
import { bad } from "./http.ts";
import { publicUrl, putPublicObject } from "./media.ts";
import { symbolLooksReserved } from "./symbols.ts";

/** A launch's name: at most 32 UTF-8 bytes (the contract counts bytes). */
export const NAME_MAX_BYTES = 32;
/** A ticker: 2 to 10 of A–Z and 0–9. */
export const TICKER = /^[A-Z0-9]{2,10}$/;
export const DESCRIPTION_MAX = 500;
export const LINK_MAX = 200;

/** The links a launch may carry, by name: https, to these hosts only (none: any host). */
const LINK_HOSTS = { website: null, x: ["x.com", "twitter.com"], telegram: ["t.me"] } as const;
export type LinkName = keyof typeof LINK_HOSTS;
export type Links = Record<LinkName, string | null>;

/** An uploaded image's file name: media.ts names an upload <uuid>.<ext>, one path segment. */
const IMAGE_FILE = /^[A-Za-z0-9-]{1,64}\.(jpe?g|png|webp|gif)$/i;

const enc = new TextEncoder();

/** A launch's name, trimmed: 400 bad_name when it is empty or longer than 32 bytes. */
export function launchName(raw: unknown): string {
  const name = typeof raw === "string" ? raw.trim() : "";
  if (!name) throw bad("bad_name", "Name: 1–32 characters.");
  if (enc.encode(name).length > NAME_MAX_BYTES) {
    throw bad("bad_name", "Name: at most 32 bytes. Accented letters and emoji count as more than one.");
  }
  return name;
}

/** A launch's ticker, in upper case: 400 bad_symbol unless it is 2–10 of A–Z and 0–9, and 400 look_alike_symbol when
 *  it reads as a reserved one (symbols.ts). */
export function launchSymbol(raw: unknown): string {
  const symbol = typeof raw === "string" ? raw.trim().toUpperCase() : "";
  if (!TICKER.test(symbol)) throw bad("bad_symbol", "Ticker: 2–10 letters (A–Z) or digits.");
  if (symbolLooksReserved(symbol)) throw bad("look_alike_symbol", "That ticker looks like another token's. Choose another.");
  return symbol;
}

/** Where media lives: the bucket's public base, ending in "/". */
export function mediaBase(): string {
  return publicUrl("");
}

/** Whether `url` is an image `address` uploaded through DyorHQ: exactly <media base>uploads/<address>/<file>, the file
 *  one segment with an image's extension (nothing like "../" that would reach another folder). */
export function isOwnImage(url: string, address: string): boolean {
  const folder = `${mediaBase()}uploads/${address}/`;
  return url.startsWith(folder) && IMAGE_FILE.test(url.slice(folder.length));
}

/** An optional text field: null when absent or blank. */
function optional(raw: unknown, name: string): string | null {
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "string") throw bad("bad_arg", `${name} must be text.`);
  const v = raw.trim();
  return v === "" ? null : v;
}

/** A link of kind `kind`, or null when absent: https, at most 200 characters, no user name or password, and for x and
 *  telegram a page on their own site. */
export function launchLink(kind: LinkName, raw: unknown): string | null {
  const v = optional(raw, kind);
  if (v === null) return null;
  const hosts = LINK_HOSTS[kind];
  const refuse = () => {
    const what = kind === "website" ? "Website: an https link" : kind === "x" ? "X: a link to a profile on x.com or twitter.com" : "Telegram: a t.me link";
    return bad("bad_arg", `${what}, at most ${LINK_MAX} characters.`);
  };
  if (v.length > LINK_MAX) throw refuse();
  let url: URL;
  try {
    url = new URL(v);
  } catch {
    throw refuse();
  }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password) throw refuse();
  if (hosts !== null && (!(hosts as readonly string[]).includes(url.hostname) || url.pathname.length < 2)) throw refuse();
  return url.href;
}

/** The metadata JSON's links, as stored and served: every name, null where absent. */
export function linksOf(raw: unknown): Links {
  const v = (raw !== null && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const pick = (k: LinkName) => (typeof v[k] === "string" ? v[k] as string : null);
  return { website: pick("website"), x: pick("x"), telegram: pick("telegram") };
}

/** POST /v1/launches/metadata: checks the request, writes the JSON and records it. Answers its URI. */
export async function writeLaunchMetadata(user: string, input: Partial<LaunchMetadataRequest>): Promise<MetadataUri> {
  const name = launchName(input.name);
  const symbol = launchSymbol(input.symbol);
  const description = optional(input.description, "description");
  if (description !== null && [...description].length > DESCRIPTION_MAX) throw bad("bad_arg", `Description: at most ${DESCRIPTION_MAX} characters.`);
  const image = optional(input.imageUrl, "imageUrl");
  if (image !== null && !isOwnImage(image, user)) throw bad("bad_media", "Upload the image through DyorHQ first.");
  const links: Links = { website: launchLink("website", input.website), x: launchLink("x", input.x), telegram: launchLink("telegram", input.telegram) };
  const uri = await putPublicObject(
    `launches/${user}/${crypto.randomUUID()}.json`,
    JSON.stringify({ name, symbol, description, image, links }),
    "application/json",
  );
  await sql()`
    insert into lite.launch_metadata (uri, address, name, symbol, description, image, links)
    values (${uri}, ${user}, ${name}, ${symbol}, ${description}, ${image}, ${sql().json(links)})`;
  return { uri };
}

/** Create's rule for a launch's URI (§6.9): empty, or metadata this address wrote for this name and ticker. */
export async function checkLaunchUri(user: string, uri: string, name: string, symbol: string): Promise<void> {
  if (uri === "") return;
  const rows = await sql()`select address, name, symbol from lite.launch_metadata where uri = ${uri}`;
  if (rows.length === 0 || rows[0].address !== user) throw bad("bad_uri", "Write the coin's details through DyorHQ first.");
  if (rows[0].name !== name || rows[0].symbol !== symbol) throw bad("bad_uri", "Those details are for another name or ticker.");
}

/** What a launch shows from its URI, under create's rule (checkLaunchUri) whoever made it: the metadata recorded for it
 *  when the launch's creator wrote it for the launch's name and ticker; for an image the creator uploaded, that image
 *  alone; nothing for any other URI (someone else's metadata or image included). */
export async function metadataFor(
  uri: string,
  launch: { creator: string; name: string; symbol: string },
): Promise<{ image: string | null; description: string | null; links: Links | null }> {
  const none = { image: null, description: null, links: null };
  if (uri === "") return none;
  const rows = await sql()`select address, name, symbol, image, description, links from lite.launch_metadata where uri = ${uri}`;
  if (rows.length) {
    const m = rows[0];
    if (m.address !== launch.creator || m.name !== launch.name || m.symbol !== launch.symbol) return none;
    return { image: m.image as string | null, description: m.description as string | null, links: linksOf(m.links) };
  }
  return isOwnImage(uri, launch.creator) ? { ...none, image: uri } : none;
}
