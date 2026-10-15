// What DyorHQ pays for (docs/DESIGN-stellar-parity.md §4.3): an account's setup ("activate") and, where activation is
// sponsored, one starter swap into XLM ("starter"). Each is reserved in lite.sponsorships before anything is sent,
// against limits kept in Postgres (lite.reserve_sponsorship, migration 05), never in memory: once per address and
// kind, at most LITE_SPONSOR_MAX_ATTEMPTS attempts, a daily count and fee cap per kind, and a daily cap per IP, which
// is stored only as an HMAC under LITE_JWT_SECRET. A reservation is then sent, released (nothing reached the network)
// or settled from its transaction's outcome.
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError } from "./http.ts";

export type SponsorKind = "activate" | "starter";

/** Why lite.sponsorship_refusal refused. */
export type Refusal = "once" | "attempts" | "daily_count" | "daily_fee" | "ip";

/** Today, UTC, as the database counts the daily caps: "2026-10-14". */
export function utcDay(at: Date = new Date()): string {
  return at.toISOString().slice(0, 10);
}

/** HMAC-SHA256(LITE_JWT_SECRET, ip + "|" + day) in hex: the IP's daily count without the IP. */
export async function ipHash(ip: string, day = utcDay()): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", enc.encode(env.jwtSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${ip}|${day}`)));
  return Array.from(mac, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** The limits a sponsorship of `kind` is checked against (§6.14). */
function limits(kind: SponsorKind) {
  return {
    attempts: env.sponsorMaxAttempts,
    perDay: kind === "activate" ? env.sponsorActivationsPerDay : env.sponsorStartersPerDay,
    feeCap: env.sponsorDailyFeeCap,
    perIp: env.sponsorPerIpPerDay,
  };
}

/** The answer to a refusal (§6.13): one already used is 409 already_set_up; a cap is 429 sponsor_limit. */
export function refusalError(kind: SponsorKind, refusal: Refusal): ApiError {
  if (refusal === "once") {
    return kind === "activate"
      ? new ApiError(409, "already_set_up", "Your account is already set up.")
      : new ApiError(409, "already_set_up", "DyorHQ already paid for this account's first swap into XLM.");
  }
  return new ApiError(429, "sponsor_limit", "DyorHQ's free setup is busy today. Try again tomorrow.", { limit: refusal });
}

/** Throws when DyorHQ wouldn't sponsor `kind` for this address from this IP now, reserving nothing: a plan the sponsor
 *  pays for is offered only when it could be sent. */
export async function assertSponsorAvailable(address: string, kind: SponsorKind, ip: string, fee: bigint): Promise<void> {
  const l = limits(kind);
  const rows = await sql()`
    select lite.sponsorship_refusal(${address}, ${kind}, ${await ipHash(ip)}, ${fee.toString()}::bigint,
                                    ${l.attempts}::int, ${l.perDay}::int, ${l.feeCap.toString()}::bigint, ${l.perIp}::int) as refusal`;
  const refusal = rows[0]?.refusal as Refusal | null;
  if (refusal) throw refusalError(kind, refusal);
}

/** Reserves a sponsorship of at most `fee` stroops: its id, or the refusal as an error. */
export async function reserveSponsorship(address: string, kind: SponsorKind, ip: string, fee: bigint): Promise<string> {
  const l = limits(kind);
  const rows = await sql()`
    select id, refusal from lite.reserve_sponsorship(${address}, ${kind}, ${await ipHash(ip)}, ${fee.toString()}::bigint,
                                                     ${l.attempts}::int, ${l.perDay}::int, ${l.feeCap.toString()}::bigint, ${l.perIp}::int)`;
  const { id, refusal } = rows[0] as { id: string | null; refusal: Refusal | null };
  if (!id) throw refusalError(kind, refusal ?? "once");
  return id;
}

/** The reserved sponsorship's transaction reached the network. */
export async function sponsorshipSent(id: string, hash: string): Promise<void> {
  await sql()`update lite.sponsorships set status = 'sent', tx_hash = ${hash}, updated_at = now() where id = ${id} and status = 'reserved'`;
}

/** Nothing reached the network: the reservation costs nothing, and the address may try again (an attempt used). */
export async function releaseSponsorship(id: string): Promise<void> {
  await sql()`update lite.sponsorships set status = 'released', updated_at = now() where id = ${id} and status = 'reserved'`;
}

/** The sponsored transaction `hash` landed or failed, at `feeCharged` stroops (which the daily fee cap counts from then
 *  on instead of the reserved fee). */
export async function settleSponsorship(hash: string, status: "success" | "failed", feeCharged?: string | null): Promise<void> {
  await sql()`update lite.sponsorships set status = ${status}, fee_charged = ${feeCharged ?? null}, updated_at = now()
               where tx_hash = ${hash} and status = 'sent'`;
}

/** Whether this address has a starter swap reserved, sent or done: then it has had its one. */
export async function starterUsed(address: string): Promise<boolean> {
  const rows = await sql()`
    select 1 from lite.sponsorships where address = ${address} and kind = 'starter' and status in ('reserved', 'sent', 'success') limit 1`;
  return rows.length > 0;
}
