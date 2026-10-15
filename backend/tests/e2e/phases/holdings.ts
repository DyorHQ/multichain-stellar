// holdings (docs/DESIGN-stellar-parity.md §6.5, §12.6), after the auth, swap, launch and earn phases. A package stack
// runs without the indexer loop, so the phase runs the refprices job once itself; then:
// - the owner's holdings are complete (every part read, a total that is the parts' sum) and carry the 24-hour change;
//   XLM and USDC under spot at their reference prices; every launch coin the account traded and still holds under
//   launch only, read live (never stale here), with its cost basis; the Earn position with DyorHQ's record;
// - the public view (?address=, no token) has the same balances and totals, DyorHQ's history null, cached 15 s; with
//   neither a token nor ?address=, 400 address_required.
import type { E2E } from "../lite_e2e.ts";
import { client, expectRefusal, setUp } from "./auth.ts";

/** The API keeps reference prices 15 s per isolate: a read made just before the job may still be served. */
const READ_CACHE_MS = 15_000;

export default async function holdings(t: E2E): Promise<string> {
  await setUp(t);
  const me = t.user.publicKey();
  const { refprices } = await import("../../../supabase/functions/lite-indexer/jobs/refprices.ts");
  const job = await refprices() as { skipped?: string };
  if (job.skipped) throw new Error(`refprices: ${job.skipped}`);

  let h = await t.api("GET", "/holdings");
  if (h.spot.find((r: any) => r.id === "XLM")?.priceUsd === null) {
    await new Promise((r) => setTimeout(r, READ_CACHE_MS + 1_000));
    h = await t.api("GET", "/holdings");
  }
  if (h.view !== "owner" || h.address !== me || !h.exists) throw new Error(`the owner's holdings: ${JSON.stringify(h).slice(0, 300)}`);
  if (JSON.stringify(h.parts) !== JSON.stringify({ spot: "ok", earn: "ok", launch: "ok", moments: "ok" })) throw new Error(`parts: ${JSON.stringify(h.parts)}`);
  const { totals } = h;
  if (!totals.complete || typeof totals.total !== "number" || totals.moments !== 0) throw new Error(`totals: ${JSON.stringify(totals)}`);
  if (Math.abs(totals.total - (totals.spot + totals.earn + totals.launch + totals.moments)) > 0.0001) throw new Error(`the total isn't its parts' sum: ${JSON.stringify(totals)}`);
  if (typeof h.change24h.usd !== "number") throw new Error(`no 24-hour change: ${JSON.stringify(h.change24h)}`);

  // Spot: XLM and USDC, priced; never a launch coin.
  const xlm = h.spot.find((r: any) => r.id === "XLM");
  const usdc = h.spot.find((r: any) => r.id === "USDC");
  if (!xlm || !usdc?.enabled || xlm.priceUsd === null || !(xlm.valueUsd > 0)) throw new Error(`spot: ${JSON.stringify(h.spot)}`);
  const coins = new Set<string>((await t.db`select token from lite.launches`).map((l) => String(l.token)));
  if (h.spot.some((r: any) => coins.has(r.contract))) throw new Error("a launch coin is listed under spot");

  // Launch: every coin the index says the account holds, read live.
  const indexed = await t.db`select token from lite.token_balances where address = ${me} and balance > 0`;
  const missing = indexed.filter((r) => !h.launch.some((l: any) => l.token === r.token));
  if (missing.length) throw new Error(`launch: ${missing.map((r) => r.token).join(", ")} held but not listed`);
  const traded = await t.db`
    select distinct token from (select token from lite.launch_trades where trader = ${me} union select token from lite.pool_swaps where trader = ${me}) as f`;
  const held = h.launch.filter((l: any) => traded.some((r) => r.token === l.token));
  for (const l of h.launch) {
    if (l.stale || !(BigInt(l.balance) > 0n) || !l.symbol || !["curve", "completed", "graduated"].includes(l.phase)) throw new Error(`a launch holding: ${JSON.stringify(l)}`);
  }
  if (held.some((l: any) => l.costBasisUsd === null)) throw new Error(`a coin bought through DyorHQ has no cost basis: ${JSON.stringify(held)}`);

  // Earn: the position the earn phase left, with its record.
  const deposits = await t.db`select 1 from lite.tx_log where address = ${me} and kind = 'earn_deposit' and status = 'success'`;
  if (deposits.length && !h.earn.some((p: any) => p.deposited !== null && p.earnedComplete === true && BigInt(p.supplied) > 0n)) throw new Error(`earn: ${JSON.stringify(h.earn)}`);
  if (h.moments.count !== h.moments.editions.length) throw new Error(`moments: ${JSON.stringify(h.moments)}`);

  // The public view: the same balances, DyorHQ's history null, cached 15 s.
  const anyone = client(t, null);
  const pub = await anyone.call("GET", `/holdings?address=${me}`);
  if (pub.status !== 200 || pub.headers.get("cache-control") !== "public, max-age=15" || pub.body.view !== "public") {
    throw new Error(`the public view: ${pub.status} ${pub.headers.get("cache-control")} ${JSON.stringify(pub.body).slice(0, 200)}`);
  }
  const balances = (x: any) => JSON.stringify([x.spot.map((r: any) => [r.id, r.balance]), x.earn.map((p: any) => [p.pool, p.asset]), x.launch.map((l: any) => l.token)]);
  if (balances(pub.body) !== balances(h)) throw new Error(`the public view's holdings differ: ${balances(pub.body)} vs ${balances(h)}`);
  if (pub.body.earn.some((p: any) => p.deposited !== null || p.withdrawn !== null || p.earned !== null || p.earnedComplete !== false)) throw new Error(`public earn: ${JSON.stringify(pub.body.earn)}`);
  if (pub.body.launch.some((l: any) => l.costBasisUsd !== null || l.pnlUsd !== null || l.stale !== false)) throw new Error(`public launch: ${JSON.stringify(pub.body.launch)}`);
  const again = await anyone.call("GET", `/holdings?address=${me}`);
  if (JSON.stringify(again.body) !== JSON.stringify(pub.body)) throw new Error("the public view wasn't kept 15 s");
  expectRefusal(await anyone.call("GET", "/holdings"), 400, "address_required", "/holdings with neither a token nor ?address=");

  const usd = (v: number | null) => (v === null ? "null" : `$${v.toFixed(2)}`);
  return `total ${usd(totals.total)} (spot ${usd(totals.spot)}, earn ${usd(totals.earn)}, launch ${usd(totals.launch)}, moments 0), complete; ` +
    `24h ${usd(h.change24h.usd)}${h.change24h.pct === null ? "" : ` (${(h.change24h.pct * 100).toFixed(2)}%)`}; ` +
    `${h.launch.length} launch coin(s) read live, ${h.earn.length} Earn position(s); the public view the same, history null, cached 15 s`;
}
