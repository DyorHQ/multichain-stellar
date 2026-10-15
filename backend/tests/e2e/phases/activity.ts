// activity (docs/DESIGN-stellar-parity.md §6.10, §12.6), after the swap, launch and earn phases:
// - every item carries its section and its words; a transaction its hash and payer, the user's settled ones their fee,
//   a settled swap what it delivered and what it bought (by its real code, never a stand-in, §9), newest first;
// - filters: section=spot&kind=swap&period=day gives the day's spot swaps only; section=earn&market=<pool>:<asset> that
//   market's deposits and withdrawals only; market=<launch coin> the items about that coin. The Earn and launch checks
//   run whenever the account logged a deposit or a launch trade (the earn and launch phases ran), indexed or not;
// - a bad filter is 400, and without a session, 401 (DyorHQ's history).
import type { E2E } from "../lite_e2e.ts";
import { client, expectRefusal, setUp } from "./auth.ts";

/** The old stand-in for a token's name (§9), spelled in two parts so the placeholder scan finds it only where it would
 *  be a placeholder. */
const PLACEHOLDER = ["TOK", "EN"].join("");

export default async function activity(t: E2E): Promise<string> {
  await setUp(t);
  const me = t.user.publicKey();
  const { call } = client(t, t.token);

  const all = await call("GET", "/activity");
  const items = all.body?.items as any[];
  if (all.status !== 200 || !items?.length) throw new Error(`/activity → ${all.status} ${JSON.stringify(all.body).slice(0, 200)}`);
  if (new RegExp(`\\b${PLACEHOLDER}\\b|"Token"`).test(JSON.stringify(items))) throw new Error("an item names a token by a stand-in");
  if (items.some((i, n) => n > 0 && i.at > items[n - 1].at)) throw new Error("the items aren't newest first");
  for (const i of items) {
    if (!i.section || !i.title) throw new Error(`an item without its section or words: ${JSON.stringify(i)}`);
    if (i.type !== "tx") continue;
    if (i.hash !== i.id || !i.feePayer) throw new Error(`a transaction without its hash or payer: ${JSON.stringify(i)}`);
    if (i.feePayer === "user" && i.status !== "pending" && i.feeCharged === null) throw new Error(`a settled transaction without its fee: ${JSON.stringify(i)}`);
    if (i.kind === "swap" && i.status === "success" && (!i.result?.amountOut || !i.symbol)) throw new Error(`a swap without its outcome: ${JSON.stringify(i)}`);
  }

  // The day's spot swaps.
  const swaps = (await call("GET", "/activity?section=spot&kind=swap&period=day")).body.items as any[];
  const since = Date.now() - 86_400_000;
  if (!swaps.length || swaps.some((i) => i.section !== "spot" || i.kind !== "swap" || Date.parse(i.at) < since)) throw new Error(`the day's spot swaps: ${JSON.stringify(swaps.slice(0, 3))}`);

  // An Earn market's history: its deposits and withdrawals only.
  const [deposit] = await t.db`select intent from lite.tx_log where address = ${me} and kind = 'earn_deposit' and status = 'success' limit 1`;
  let earn = "no Earn market (the earn phase didn't run)";
  if (deposit) {
    const pool = deposit.intent.calls.find((c: any) => c.fn === "submit").contract;
    const asset = Object.keys(deposit.intent.spend)[0];
    const market = (await call("GET", `/activity?section=earn&market=${pool}:${asset}`)).body.items as any[];
    if (!market.length || market.some((i) => !["earn_deposit", "earn_withdraw"].includes(i.kind) || i.ref?.market !== `${pool}:${asset}`)) throw new Error(`the Earn market's history: ${JSON.stringify(market.slice(0, 3))}`);
    // The phone's market id runs the pool and the asset together.
    const keyed = (await call("GET", `/activity?section=earn&market=${pool}${asset}`)).body.items as any[];
    if (JSON.stringify(keyed.map((i) => i.id)) !== JSON.stringify(market.map((i) => i.id))) throw new Error("the market's id, run together, finds other items");
    earn = `${market.length} item(s) in the Earn market`;
  }

  // A launch coin's items: the coin of the account's latest logged trade.
  const [coin] = await t.db`
    select intent -> 'display' ->> 'token' as token from lite.tx_log
     where address = ${me} and kind in ('launch_buy', 'launch_sell') and status = 'success' order by created_at desc limit 1`;
  let launch = "no launch coin (the launch phase didn't run)";
  if (coin?.token) {
    const about = (await call("GET", `/activity?market=${coin.token}`)).body.items as any[];
    if (!about.length || about.some((i) => i.ref?.token !== coin.token)) throw new Error(`the coin's items: ${JSON.stringify(about.slice(0, 3))}`);
    launch = `${about.length} item(s) about the launch coin`;
  }

  expectRefusal(await call("GET", "/activity?period=year"), 400, "bad_arg", "/activity?period=year");
  expectRefusal(await call("GET", "/activity?market=nope"), 400, "bad_arg", "/activity?market=nope");
  const anonymous = await client(t, null).call("GET", "/activity");
  if (anonymous.status !== 401) throw new Error(`/activity without a session → ${anonymous.status}`);

  const sections = [...new Set(items.map((i) => i.section))].join(", ");
  return `${items.length} item(s) (${sections}), each with its section and words, fees and outcomes; ${swaps.length} spot swap(s) today; ${earn}; ${launch}; 401 without a session`;
}
