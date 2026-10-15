// portfolio (docs/DESIGN-stellar-parity.md §6.7, §12.6), after the swap, launch and earn phases, over the last day:
// - spot trades ≥ 1 (the swap phase's), launch volume > 0 (the launch phase's curve trades and pool swaps, when it ran),
//   network fees > 0 in XLM, valued at XLM's price, and never part of `fees`;
// - the totals are the sections' sums; the period starts a day before asOf; the activity lists the day's settled items
//   of the five sections, newest first; coverage starts at the account's first logged transaction;
// - all time counts at least as much as the day; without a session, 401 (DyorHQ's history).
import type { E2E } from "../lite_e2e.ts";
import { client, setUp } from "./auth.ts";

const SECTIONS = ["spot", "earn", "launch", "moments", "bridge"];

export default async function portfolio(t: E2E): Promise<string> {
  await setUp(t);
  const me = t.user.publicKey();
  const p = await t.api("GET", "/portfolio?period=day");
  if (p.period !== "day" || Date.parse(p.asOf) - Date.parse(p.since) !== 86_400_000) throw new Error(`the period: ${p.period} ${p.since} → ${p.asOf}`);
  const { sections, totals } = p;
  if (JSON.stringify(Object.keys(sections)) !== JSON.stringify(SECTIONS)) throw new Error(`sections: ${Object.keys(sections)}`);

  // The day's figures.
  if (!(sections.spot.trades >= 1) || sections.spot.fees !== 0) throw new Error(`spot: ${JSON.stringify(sections.spot)}`);
  const [fills] = await t.db`
    select count(*)::int as n from (
      select 1 from lite.launch_trades where trader = ${me} and ts > now() - interval '1 day'
      union all
      select 1 from lite.pool_swaps where trader = ${me} and ts > now() - interval '1 day') as f`;
  if (fills.n > 0 && !(sections.launch.volume > 0 && sections.launch.trades === fills.n)) throw new Error(`launch: ${JSON.stringify(sections.launch)} for ${fills.n} trades`);
  if (!(BigInt(totals.networkFeesXlm) > 0n) || !(totals.networkFeesUsd > 0)) throw new Error(`network fees: ${totals.networkFeesXlm} (${totals.networkFeesUsd})`);
  const [paid] = await t.db`
    select coalesce(sum(fee_charged), 0)::text as fees from lite.tx_log
     where address = ${me} and fee_payer = 'user' and section = any(${SECTIONS}::text[]) and created_at > ${new Date(p.since)}`;
  if (totals.networkFeesXlm !== paid.fees) throw new Error(`network fees ${totals.networkFeesXlm}, the log says ${paid.fees}`);

  // The totals are the sections'.
  const sum = (f: (s: any) => number) => SECTIONS.reduce((a, s) => a + f(sections[s]), 0);
  for (const k of ["volume", "fees", "pnl", "claimedFees", "networkFeesUsd"]) {
    if (Math.abs(totals[k] - sum((s) => s[k])) > 0.0005) throw new Error(`totals.${k} ${totals[k]} isn't the sections' ${sum((s) => s[k])}`);
  }
  if (totals.trades !== sum((s) => s.trades) || BigInt(totals.networkFeesXlm) !== SECTIONS.reduce((a, s) => a + BigInt(sections[s].networkFeesXlm), 0n)) {
    throw new Error(`totals: ${JSON.stringify(totals)}`);
  }

  // The day's activity, coverage.
  const items = p.activity as { section: string; at: string; title: string }[];
  if (items.length === 0 || items.some((i) => !SECTIONS.includes(i.section) || !i.title || Date.parse(i.at) < Date.parse(p.since))) throw new Error(`activity: ${JSON.stringify(items.slice(0, 3))}`);
  if (items.some((i, n) => n > 0 && i.at > items[n - 1].at)) throw new Error("the activity isn't newest first");
  const [first] = await t.db`select min(created_at) as first from lite.tx_log where address = ${me}`;
  if (p.coverage.from !== new Date(first.first).toISOString() || !p.coverage.note) throw new Error(`coverage: ${JSON.stringify(p.coverage)}`);

  const all = await t.api("GET", "/portfolio?period=all");
  if (all.since !== null || all.totals.trades < totals.trades || all.totals.volume < totals.volume) throw new Error(`all time: ${JSON.stringify(all.totals)}`);
  const anonymous = await client(t, null).call("GET", "/portfolio?period=day");
  if (anonymous.status !== 401) throw new Error(`/portfolio without a session → ${anonymous.status}`);

  const usd = (v: number) => `$${v.toFixed(2)}`;
  return `last day: spot ${sections.spot.trades} trade(s) ${usd(sections.spot.volume)}, launch ${sections.launch.trades} ${usd(sections.launch.volume)}, ` +
    `earn ${sections.earn.trades} ${usd(sections.earn.volume)}; volume ${usd(totals.volume)}, fees ${usd(totals.fees)}, P&L ${usd(totals.pnl)}` +
    `${totals.pnlComplete ? "" : "*"}; network fees ${Number(totals.networkFeesXlm) / 1e7} XLM, never in fees; ${items.length} item(s); 401 without a session`;
}
