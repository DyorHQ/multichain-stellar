// The caller's network for per-IP limits, from Cloudflare's cf-connecting-ip (set at the edge; a client cannot forge
// it through Cloudflare, and the functions' request logs show it on every call). IPv4 counts per address, IPv6 per
// /64 by default — one subscriber's allocation — so rotating addresses inside a /64 buys no fresh bucket. A caller whose
// limit exists to stop one party from rotating addresses (wallet-auth's new wallets, the waitlist) asks for /48: that
// is what a tunnel broker hands out for free, 65,536 /64s. X-Forwarded-For is deliberately NOT used: its first entry is
// whatever the client sent, so it would let a caller pick a fresh bucket per request, or fill someone else's. null when
// absent or unparseable — per-subject limits still apply, and unknown callers don't share (and exhaust) one bucket.
//
// Shared by email-pepper (its network limits, migration 20) and the edge_rate_gate callers (migration 27).
export function clientNet(req: Request, v6Prefix: 48 | 56 | 64 = 64): string | null {
  const raw = (req.headers.get("cf-connecting-ip") ?? "").trim();
  const v4 = raw.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const octets = v4.slice(1).map(Number);
    return octets.every((o) => o <= 255) ? octets.join(".") : null;
  }
  if (!raw.includes(":") || !/^[0-9a-fA-F:.]+$/.test(raw)) return null;
  let host: string;
  try { host = new URL(`http://[${raw}]/`).hostname; } catch { return null; }
  if (!host.startsWith("[") || !host.endsWith("]")) return null;
  // The URL parser validates and serialises IPv6 as lowercase hex groups with at most one "::" (never dotted).
  const [head, tail = ""] = host.slice(1, -1).split("::");
  const h = head ? head.split(":") : [], t = tail ? tail.split(":") : [];
  const groups = host.includes("::") ? [...h, ...Array(8 - h.length - t.length).fill("0"), ...t] : h;
  if (groups.length !== 8) return null;
  const g = groups.map((x) => parseInt(x, 16));
  if (g.slice(0, 5).every((x) => x === 0) && g[5] === 0xffff) { // IPv4-mapped: count as that IPv4 address
    return [g[6] >> 8, g[6] & 255, g[7] >> 8, g[7] & 255].join(".");
  }
  // The prefix's whole groups, then (for /56) the high byte of the next one.
  const kept = g.slice(0, Math.ceil(v6Prefix / 16)).map((x, i) => (i + 1) * 16 > v6Prefix ? x & 0xff00 : x);
  return `${kept.map((x) => x.toString(16)).join(":")}::/${v6Prefix}`;
}
