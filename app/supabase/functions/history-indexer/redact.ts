// Keyed URLs out of every line the indexer writes. A keyed endpoint's URL (ALCHEMY_MONAD_RPC, a MONAD_LOGS_ENDPOINTS
// entry) carries its key in the path or the query, and text from the runtime can quote it: a failed fetch's cause reads
// "error sending request for url (<the whole URL>)", `new URL(bad)` throws "Invalid URL: '<input>'", and a provider's
// error message may echo the request. So log lines, error lines, thrown messages and run summaries all pass through a
// redactor, which replaces the URL — whole, origin plus path, host plus path, path and query, and each long path segment
// or query value — with the endpoint's label, and then cuts the path and query off any other URL left in the text
// ("https://host/…"). Never pass an Error object to console.* (it prints the cause); pass redact(String(message)).
export type Redact = (text: string) => string;

export type Keyed = { url: string; label: string };

const MIN_PART = 6;      // composite parts (the URL, host + path, path + query) at least this long are replaced
const MIN_SEGMENT = 12;  // a single path segment or query value at least this long is replaced (a key is longer)
const OTHER_URL = /\b(https?:\/\/[^\s/?#"'<>()\\]+)[/?#][^\s"'<>()\\]*/gi;

function decoded(part: string): string {
  try { return decodeURIComponent(part); } catch { return part; }
}

export function redactor(keyed: readonly Keyed[]): Redact {
  const pairs: [string, string][] = [];
  for (const { url, label } of keyed) {
    const parts = new Set<string>([url, url.trim()]);
    const segments = new Set<string>();
    let parsed: URL | null = null;
    try { parsed = new URL(url.trim()); } catch { parsed = null; } // never rethrown: the message would quote the URL
    if (parsed) {
      const path = parsed.pathname, search = parsed.search;
      for (const p of [parsed.href, parsed.href.replace(/\/+$/, ""), parsed.origin + path + search, parsed.origin + path,
                       parsed.host + path + search, parsed.host + path, path + search, path, search]) {
        if (p.length > 1 && p !== "/") parts.add(p);
      }
      for (const seg of path.split("/")) { segments.add(seg); segments.add(decoded(seg)); }
      for (const [k, v] of parsed.searchParams) { segments.add(v); segments.add(`${k}=${v}`); }
      for (const raw of search.replace(/^\?/, "").split("&")) segments.add(raw);
      if (parsed.username) segments.add(decoded(parsed.username));
      if (parsed.password) segments.add(decoded(parsed.password));
    }
    for (const p of parts) if (p.length >= MIN_PART) pairs.push([p, label]);
    for (const s of segments) if (s.length >= MIN_SEGMENT) pairs.push([s, label]);
  }
  pairs.sort((a, b) => b[0].length - a[0].length); // the longest first: a whole URL before its parts
  return (text: string) => {
    let out = String(text);
    for (const [part, label] of pairs) if (out.includes(part)) out = out.split(part).join(label);
    return out.replace(OTHER_URL, (_m, origin: string) => `${origin}/…`);
  };
}

// No keyed URL to replace: only the paths and queries cut off any URL in the text.
export const scrubUrls: Redact = redactor([]);
