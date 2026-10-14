// What aurora-proxy forwards (security audit 2026-09-26, SB-2 and SB-11). The bridge is a same-wallet EVM bridge: the
// app funds a deposit address from the signed-in wallet and receives on the destination chain at that same address.
// So a quote may only deliver to, and refund to, the session's wallet — otherwise any session could use DyorHQ's
// Aurora key as a free bridge to arbitrary recipients — and the integrator fee and referral are DyorHQ's to set, not
// the caller's: the caller's `appFees` is dropped and replaced by the server's (appFee below; when none is configured,
// the fee configured on the key in Aurora Studio applies), and `referral` is always "dyorhq". Only the fields the app
// sends are forwarded.
export const REFERRAL = "dyorhq";
const MAX_FIELD = 256;

export type Forward = { body: string } | { error: string; status: number };
export type AppFee = { recipient: string; fee: number };

// DyorHQ's integrator fee from the function's environment, in the shape the app used to send it (AuroraAppFee):
// AURORA_FEE_RECIPIENT, the NEAR account that receives it (a named account such as "name.near", or a 64-hex implicit
// account), and AURORA_FEE_BPS, the fee in basis points (default 10, at most 100). null when no recipient is set;
// "invalid" when either value is malformed, which the caller logs and treats as none.
export function appFee(recipient: string | undefined, bps: string | undefined): AppFee | null | "invalid" {
  const account = (recipient ?? "").trim();
  if (!account) return null;
  if (account.length < 2 || account.length > 64 || !/^(?:[a-z0-9]+(?:[-_][a-z0-9]+)*\.)*[a-z0-9]+(?:[-_][a-z0-9]+)*$/.test(account)) {
    return "invalid";
  }
  const raw = (bps ?? "").trim();
  const fee = raw === "" ? 10 : Number(raw);
  if (!Number.isInteger(fee) || fee < 1 || fee > 100) return "invalid";
  return { recipient: account, fee };
}

const bad = (error: string): Forward => ({ error, status: 400 });

function object(raw: string): Record<string, unknown> | null {
  try {
    const value = JSON.parse(raw);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

const text = (v: unknown) => typeof v === "string" && v.length > 0 && v.length <= MAX_FIELD;

// POST /quote. `wallet` is the session's wallet (lowercase 0x address); `fee` is DyorHQ's integrator fee, if any.
export function quoteBody(raw: string, wallet: string, fee: AppFee | null = null): Forward {
  const q = object(raw);
  if (!q) return bad("invalid json");
  if (typeof q.recipient !== "string" || typeof q.refundTo !== "string" ||
      q.recipient.toLowerCase() !== wallet || q.refundTo.toLowerCase() !== wallet) {
    return { error: "the bridge only sends to, and refunds to, your own wallet", status: 403 };
  }
  if (q.depositType !== "ORIGIN_CHAIN" || q.refundType !== "ORIGIN_CHAIN" || q.recipientType !== "DESTINATION_CHAIN") {
    return bad("unsupported deposit, refund or recipient type");
  }
  if (!text(q.amount) || !/^[0-9]{1,78}$/.test(q.amount as string)) return bad("amount must be an integer string");
  if (!text(q.originAsset) || !text(q.destinationAsset) || !text(q.swapType)) return bad("missing assets or swap type");
  if (!Number.isInteger(q.slippageTolerance) || (q.slippageTolerance as number) < 0 || (q.slippageTolerance as number) > 10_000) {
    return bad("slippageTolerance must be basis points");
  }
  if (q.dry !== undefined && typeof q.dry !== "boolean") return bad("dry must be a boolean");
  const forward: Record<string, unknown> = {
    swapType: q.swapType, depositType: q.depositType, amount: q.amount, originAsset: q.originAsset,
    destinationAsset: q.destinationAsset, slippageTolerance: q.slippageTolerance, refundTo: q.refundTo,
    refundType: q.refundType, recipient: q.recipient, recipientType: q.recipientType, referral: REFERRAL,
  };
  if (q.dry !== undefined) forward.dry = q.dry;
  if (fee) forward.appFees = [{ recipient: fee.recipient, fee: fee.fee }];
  return { body: JSON.stringify(forward) };
}

// POST /deposit/submit: the deposit's tx hash, its deposit address and optional memo — nothing else.
export function submitBody(raw: string): Forward {
  const s = object(raw);
  if (!s) return bad("invalid json");
  if (!text(s.txHash) || !text(s.depositAddress)) return bad("txHash and depositAddress are required");
  if (s.memo !== undefined && s.memo !== null && !text(s.memo)) return bad("memo must be a short string");
  const forward: Record<string, unknown> = { txHash: s.txHash, depositAddress: s.depositAddress };
  if (typeof s.memo === "string") forward.memo = s.memo;
  return { body: JSON.stringify(forward) };
}

// An upstream error as the client sees it: Aurora's own short message (the app shows it — "amount too low" and the
// like), scrubbed and capped, never the raw body. Aurora refusing DyorHQ's key is "not configured" (503), not the
// caller's sign-in; Aurora's own failures are 502.
export function upstreamError(raw: string, status: number, scrub: (s: string) => string): { body: { error: string }; status: number } {
  if (status === 401 || status === 403) return { body: { error: "bridge not configured" }, status: 503 };
  const parsed = object(raw);
  const said = typeof parsed?.message === "string" ? parsed.message : typeof parsed?.error === "string" ? parsed.error : "";
  const message = scrub(said).replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 200);
  const clientError = status >= 400 && status < 500 && status !== 429;
  return {
    body: { error: message || (clientError ? "Aurora refused the request" : "Aurora is unavailable — try again") },
    status: clientError ? status : status === 429 ? 429 : 502,
  };
}
