// RPC and webhook URLs can carry an API key in their path, query string or userinfo (e.g. an Alchemy or QuickNode
// endpoint). Nothing the keepers print, log or post may contain one: URLs are reduced to their origin, and any
// configured secret string is replaced outright.

/** `https://host[:port]` of a URL, or `<url>` if it does not parse. Never the path, query or userinfo. */
export function urlOrigin(url) {
  try {
    const u = new URL(url);
    return `${u.protocol}//${u.host}`;
  } catch {
    return "<url>";
  }
}

/** A printable label for an RPC endpoint: its origin, plus `/…` when the rest (possibly a key) was dropped. */
export function rpcLabel(url) {
  try {
    const u = new URL(url);
    const hidden = (u.pathname && u.pathname !== "/") || u.search || u.username || u.password;
    return `${urlOrigin(url)}${hidden ? "/…" : ""}`;
  } catch {
    return "<rpc>";
  }
}

/** Replaces every `secrets` entry (a configured URL by its label, anything else by `[redacted]`), then every
    http(s)/ws(s) URL left in `text` by its label. Punctuation right after a URL ("(url);") stays in the text. */
export function redact(text, secrets = []) {
  let s = String(text);
  for (const secret of secrets) {
    if (!secret) continue;
    const str = String(secret);
    s = s.split(str).join(/^(?:https?|wss?):\/\//i.test(str) ? rpcLabel(str) : "[redacted]");
  }
  return s.replace(/\b(?:https?|wss?):\/\/[^\s"'<>`]+/gi, (m) => {
    const tail = /[)\].,;:!?}]+$/.exec(m)?.[0] ?? "";
    return rpcLabel(m.slice(0, m.length - tail.length)) + tail;
  });
}
