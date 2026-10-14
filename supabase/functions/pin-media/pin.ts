// The pure rules pin-media applies (security audit 2026-09-26: SB-2 for the path, RW-9 for the time budget).

// Only Moment media, and only the CALLER's own folder: `<their wallet>/moment-<keccak hex>.<jpg|mp4|mov>`, the only
// names the app pins (MomentsMath.mediaName, SocialSession.uploadAndPinMomentMedia). No other bucket, no other file
// names, no nested or encoded segments.
const PIN_PATH = /^(0x[0-9a-f]{40})\/(moment-[0-9a-f]{64}\.(?:jpg|mp4|mov))$/;

export function pinTarget(bucket: unknown, path: unknown, wallet: string): { path: string; name: string } | { error: string; status: number } {
  if ((bucket ?? "launch-media") !== "launch-media") return { error: "only launch-media can be pinned", status: 400 };
  const match = typeof path === "string" ? PIN_PATH.exec(path) : null;
  if (!match) return { error: "path must be <your wallet>/moment-<media hash>.<jpg|mp4|mov>", status: 400 };
  if (match[1] !== wallet) return { error: "you can only pin your own uploads", status: 403 };
  return { path: match[0], name: match[2] };
}

// The whole call's time budget. The app waits 25 s for this function (SupabaseClient.send, timeoutInterval 25, and it
// hears nothing until the answer), then writes the https mirror on-chain instead — so every step here must finish
// inside the budget, and a pin that cannot is abandoned (and unpinned) rather than completed after the app moved on.
export class Deadline {
  private readonly end: number;
  constructor(budgetMs: number, private readonly now: () => number = Date.now) { this.end = now() + budgetMs; }
  remaining(): number { return Math.max(0, this.end - this.now()); }
  // A timeout for the next step: at most `capMs`, never past the deadline.
  step(capMs: number): number { return Math.min(capMs, this.remaining()); }
}

// Pinata's pinFileToIPFS answer: the CID, its MimeType ("directory" when Pinata wrapped the file), and whether the
// account had already pinned that CID (isDuplicate) — a duplicate may already be referenced on-chain, so it is never
// unpinned. null when there is no CID.
export function pinataResult(text: string): { cid: string; mime: string; duplicate: boolean } | null {
  try {
    const parsed = JSON.parse(text);
    const cid = typeof parsed?.IpfsHash === "string" ? parsed.IpfsHash : "";
    if (!/^[A-Za-z0-9]{10,100}$/.test(cid)) return null;
    return { cid, mime: typeof parsed.MimeType === "string" ? parsed.MimeType : "", duplicate: parsed.isDuplicate === true };
  } catch {
    return null;
  }
}
