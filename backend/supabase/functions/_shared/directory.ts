// The asset directory (docs/DESIGN-stellar-parity.md §6.5): what a classic asset's issuer publishes about it, for the
// holdings rows of trustlines outside the registry (WP-18) and a token page's home domain (markets.ts). Horizon's
// /assets links the issuer's stellar.toml; its [[CURRENCIES]] entry for the asset gives a name and an image. The toml
// is read over https only, within 3 s and 100 KB, from a public host name; images are kept only when https. Answers
// are kept in lite.asset_directory: 7 days when definite (including "nothing published"), an hour when a fetch
// failed. The phone shows the name; v1 shows no directory logo (the app's media policy accepts DyorHQ's own storage
// only, §3.8).
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { NetworkConfig } from "./networks.ts";
import { isAccountId } from "./stellar.ts";

export interface DirectoryEntry {
  /** "CODE:ISSUER". */
  asset: string;
  /** The host the issuer's stellar.toml is served from. */
  homeDomain: string | null;
  /** SEP-1 `name`, at most 64 characters. */
  name: string | null;
  /** SEP-1 `image`, https only. */
  image: string | null;
}

const KEEP_MS = 7 * 86_400_000;
const RETRY_MS = 3_600_000;
const TIMEOUT_MS = 3_000;
const MAX_TOML_BYTES = 100 * 1024;
/** Misses looked up at once. */
const PARALLEL = 5;
const MAX_REDIRECTS = 2;

/** "CODE:ISSUER", a classic asset other than XLM. */
export function isClassicAsset(asset: string): boolean {
  const m = /^([A-Za-z0-9]{1,12}):(G[A-Z2-7]{55})$/.exec(asset);
  return m !== null && isAccountId(m[2]);
}

/** One asset's entry; see directory(). */
export async function directoryEntry(asset: string, net: NetworkConfig = env.network): Promise<DirectoryEntry> {
  return (await directory([asset], net)).get(asset) ?? empty(asset);
}

/** The directory's entries for classic assets ("CODE:ISSUER"): from lite.asset_directory while kept, otherwise read
 *  from the issuer's stellar.toml and kept. Anything that isn't a classic asset gets an empty entry. */
export async function directory(assets: string[], net: NetworkConfig = env.network): Promise<Map<string, DirectoryEntry>> {
  const wanted = [...new Set(assets.filter(isClassicAsset))];
  const out = new Map<string, DirectoryEntry>(assets.map((a) => [a, empty(a)]));
  if (wanted.length === 0) return out;
  const rows = await sql()`
    select asset, home_domain, name, image from lite.asset_directory where asset = any(${wanted}::text[]) and expires_at > now()`;
  for (const r of rows) out.set(r.asset, { asset: r.asset, homeDomain: r.home_domain, name: r.name, image: r.image });
  const misses = wanted.filter((a) => !rows.some((r) => r.asset === a));
  for (let i = 0; i < misses.length; i += PARALLEL) {
    await Promise.all(misses.slice(i, i + PARALLEL).map(async (asset) => {
      const { entry, definite } = await lookUp(asset, net);
      await sql()`
        insert into lite.asset_directory (asset, home_domain, name, image, fetched_at, expires_at)
        values (${asset}, ${entry.homeDomain}, ${entry.name}, ${entry.image}, now(), ${new Date(Date.now() + (definite ? KEEP_MS : RETRY_MS))})
        on conflict (asset) do update set home_domain = excluded.home_domain, name = excluded.name, image = excluded.image,
          fetched_at = excluded.fetched_at, expires_at = excluded.expires_at`;
      out.set(asset, entry);
    }));
  }
  return out;
}

const empty = (asset: string): DirectoryEntry => ({ asset, homeDomain: null, name: null, image: null });

/** A fetch that failed for now (a timeout, a 5xx, a 429): worth retrying soon, unlike an answer. */
class Transient extends Error {}

/** Reads an asset's entry from Horizon and its issuer's stellar.toml. `definite` is false when a fetch failed. */
async function lookUp(asset: string, net: NetworkConfig): Promise<{ entry: DirectoryEntry; definite: boolean }> {
  const [code, issuer] = asset.split(":");
  try {
    const page = JSON.parse(await fetchText(`${net.horizonUrl}/assets?asset_code=${code}&asset_issuer=${issuer}&limit=1`, 64 * 1024, false));
    const link = page?._embedded?.records?.[0]?._links?.toml?.href;
    const url = typeof link === "string" ? publicHttpsUrl(link) : null;
    if (!url) return { entry: empty(asset), definite: true };
    const homeDomain = url.hostname;
    let toml: string;
    try {
      toml = await fetchText(url.href, MAX_TOML_BYTES, true);
    } catch (err) {
      if (err instanceof Transient) throw err;
      return { entry: { ...empty(asset), homeDomain }, definite: true };
    }
    const currency = currencyFor(toml, code, issuer);
    return { entry: { asset, homeDomain, name: currency.name, image: currency.image }, definite: true };
  } catch (err) {
    if (err instanceof Transient) return { entry: empty(asset), definite: false };
    // Horizon answered something that isn't a page: as good as nothing published.
    return { entry: empty(asset), definite: true };
  }
}

/** The body of `url` as text, within TIMEOUT_MS and `maxBytes`. With `external`, a redirect is followed (at most
 *  twice) only to another public https URL. A timeout, network error, 429 or 5xx throws Transient; any other refusal
 *  throws Error. */
async function fetchText(url: string, maxBytes: number, external: boolean): Promise<string> {
  const signal = AbortSignal.timeout(TIMEOUT_MS);
  let target = url;
  for (let hop = 0;; hop++) {
    let res: Response;
    try {
      res = await fetch(target, { signal, redirect: external ? "manual" : "follow", headers: { accept: "text/plain, application/json" } });
    } catch (err) {
      throw new Transient(String((err as Error)?.message ?? err));
    }
    if (external && res.status >= 300 && res.status < 400) {
      await res.body?.cancel();
      const next = res.headers.get("location");
      const resolved = next ? publicHttpsUrl(new URL(next, target).href) : null;
      if (!resolved || hop >= MAX_REDIRECTS) throw new Error("redirect refused");
      target = resolved.href;
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      if (res.status === 429 || res.status >= 500) throw new Transient(`HTTP ${res.status}`);
      throw new Error(`HTTP ${res.status}`);
    }
    return await readCapped(res, maxBytes);
  }
}

async function readCapped(res: Response, maxBytes: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel();
        throw new Error(`larger than ${maxBytes} bytes`);
      }
      chunks.push(value);
    }
  } catch (err) {
    if (err instanceof Error && err.message.startsWith("larger than")) throw err;
    throw new Transient(String((err as Error)?.message ?? err));
  }
  const all = new Uint8Array(size);
  let at = 0;
  for (const c of chunks) {
    all.set(c, at);
    at += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

/** `href` when it is https on the default port and its host a public DNS name (not an IP address, localhost or a
 *  reserved name); null otherwise. Issuers choose their home domain, so the server never fetches anything else. */
export function publicHttpsUrl(href: string): URL | null {
  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || url.port !== "" || url.username !== "" || url.password !== "") return null;
  if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host) || /^[0-9.]+$/.test(host)) return null;
  if (/(^|\.)(localhost|local|internal|invalid|test|example|arpa|home|lan|corp)$/.test(host)) return null;
  return url;
}

// ------------------------------------------------------------------------------------------------ stellar.toml

/** The `[[CURRENCIES]]` tables of a stellar.toml, each as its string fields. A small reader for SEP-1's shape: table
 *  headers, `key = "basic"` and `key = 'literal'` strings, comments; other values (numbers, booleans, arrays, inline
 *  tables, multi-line strings) are skipped, across lines where they span them. */
export function parseCurrencies(toml: string): Record<string, string>[] {
  const out: Record<string, string>[] = [];
  let current: Record<string, string> | null = null;
  const lines = toml.replace(/\r\n?/g, "\n").split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (line === "" || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      const header = /^\[\[\s*([A-Za-z0-9_.-]+)\s*\]\]\s*(#.*)?$/.exec(line);
      current = header && header[1] === "CURRENCIES" ? {} : null;
      if (current) out.push(current);
      continue;
    }
    const kv = /^("?)([A-Za-z0-9_-]+)\1\s*=\s*(.*)$/.exec(line);
    if (!kv) continue;
    const [, , key, rest] = kv;
    if (rest.startsWith('"""') || rest.startsWith("'''")) {
      // A multi-line string: skip to its closing quotes.
      const quote = rest.slice(0, 3);
      if (rest.slice(3).includes(quote)) continue;
      while (i + 1 < lines.length && !lines[++i].includes(quote));
      continue;
    }
    if (rest.startsWith('"') || rest.startsWith("'")) {
      const value = readString(rest);
      if (current && value !== null && !(key in current)) current[key] = value;
      continue;
    }
    if (rest.startsWith("[") || rest.startsWith("{")) {
      // An array or inline table, maybe over several lines: skip to where its brackets close.
      let depth = bracketDepth(rest);
      while (depth > 0 && i + 1 < lines.length) depth += bracketDepth(lines[++i]);
    }
  }
  return out;
}

/** A TOML basic ("…", with escapes) or literal ('…') string at the start of `s`; null when it doesn't close. */
function readString(s: string): string | null {
  if (s.startsWith("'")) {
    const end = s.indexOf("'", 1);
    return end < 0 ? null : s.slice(1, end);
  }
  let out = "";
  for (let i = 1; i < s.length; i++) {
    const c = s[i];
    if (c === '"') return out;
    if (c !== "\\") {
      out += c;
      continue;
    }
    const e = s[++i];
    const simple: Record<string, string> = { b: "\b", t: "\t", n: "\n", f: "\f", r: "\r", '"': '"', "\\": "\\" };
    if (e in simple) out += simple[e];
    else if (e === "u" || e === "U") {
      const len = e === "u" ? 4 : 8;
      const cp = parseInt(s.slice(i + 1, i + 1 + len), 16);
      if (!Number.isFinite(cp) || cp > 0x10ffff) return null;
      out += String.fromCodePoint(cp);
      i += len;
    } else return null;
  }
  return null;
}

/** How much `line` opens arrays and inline tables, outside strings and comments. */
function bracketDepth(line: string): number {
  let depth = 0;
  let quote: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (quote) {
      if (c === "\\" && quote === '"') i++;
      else if (c === quote) quote = null;
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "#") break;
    else if (c === "[" || c === "{") depth++;
    else if (c === "]" || c === "}") depth--;
  }
  return depth;
}

/** The name and image a stellar.toml gives the asset `code` issued by `issuer`: the name trimmed to 64 characters
 *  without control characters, the image only when it is https. */
export function currencyFor(toml: string, code: string, issuer: string): { name: string | null; image: string | null } {
  const c = parseCurrencies(toml).find((x) => x.code === code && x.issuer === issuer);
  // deno-lint-ignore no-control-regex
  const name = c?.name?.replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, 64) || null;
  let image: string | null = null;
  if (c?.image) {
    try {
      const url = new URL(c.image);
      if (url.protocol === "https:") image = url.href;
    } catch {
      // not a URL
    }
  }
  return { name, image };
}
