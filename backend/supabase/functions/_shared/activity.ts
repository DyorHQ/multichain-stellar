// Recent Activity (docs/DESIGN-stellar-parity.md §6.10, §8.12.3) and Portfolio's activity (§6.7): the account's
// logged transactions, bridge transfers and anchor transfers, newest first. Each item carries its section, its network
// fee and who paid it, what it delivered, what it is about (a launch, a Moment or an Earn market), the asset's real
// symbol and name (never a stand-in, §9), and the server's English title and subtitle with its USD value at today's
// price, to the cent (the phone words the kinds it knows itself). Filters: section, kind, period and market (an Earn
// market, `<pool>:<asset>` or the two ids run together as the phone keys it, or an asset's id or contract).
// - A transaction counts in the section it was logged with (migration 10 gives every row one, by its kind): the
//   section filter and the items read that one, and a row of a kind no section counts is the account's.
// - An API before WP-10 logged a token it couldn't name by a stand-in (STAND_IN), in a swap's or a payment's summary
//   and display: such a row is shown with the token's code, or its short contract id, in its place.
import type postgres from "postgres";
import type { ActivityItem, BridgeDirection, DisplayValue, FeePayer, Period, Section, Usd } from "./contract.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { bad } from "./http.ts";
import { amountText, priceOf, TOKEN_DECIMALS } from "./launchpad.ts";
import { assetById, AssetInfo, NetworkConfig, PriceRef } from "./networks.ts";
import { referencePrices, RefPrice, usdOf } from "./refprices.ts";
import { isContractId } from "./stellar.ts";
import { Intent } from "./verify.ts";

type Row = postgres.Row;

const DAY = 86_400_000;

/** How far back each period reaches (the app's VolumePeriod: the last 24 hours, 7 days, 30 days, or all of it). */
export const PERIOD_MS: Record<Period, number | null> = { day: DAY, week: 7 * DAY, month: 30 * DAY, all: null };

/** The period's start, or null for all time. */
export function periodStart(period: Period, now: number): Date | null {
  const reach = PERIOD_MS[period];
  return reach === null ? null : new Date(now - reach);
}

/** ?period=, `fallback` when absent. */
export function periodArg(v: string | null, fallback: Period): Period {
  if (v === null || v === "") return fallback;
  if (Object.hasOwn(PERIOD_MS, v)) return v as Period;
  throw bad("bad_arg", "period is day, week, month or all.");
}

const SECTIONS: Section[] = ["spot", "earn", "launch", "moments", "bridge", "cash", "account"];

export function sectionArg(v: string | null): Section | null {
  if (v === null || v === "") return null;
  if ((SECTIONS as string[]).includes(v)) return v as Section;
  throw bad("bad_arg", `section is one of ${SECTIONS.join(", ")}.`);
}

export function kindArg(v: string | null): string | null {
  if (v === null || v === "") return null;
  if (/^[a-z_]{1,40}$/.test(v)) return v;
  throw bad("bad_arg", "kind is an activity kind, such as swap or launch_buy.");
}

/** What ?market= names: an Earn market (a pool and its asset) or an asset (its contract). */
export interface MarketFilter {
  pool: string | null;
  asset: string;
}

export function marketArg(v: string | null, net: NetworkConfig = env.network): MarketFilter | null {
  if (v === null || v === "") return null;
  const pair = /^(C[A-Z2-7]{55}):?(C[A-Z2-7]{55})$/.exec(v);
  if (pair && isContractId(pair[1]) && isContractId(pair[2])) return { pool: pair[1], asset: pair[2] };
  const registry = assetById(net, v);
  if (registry) return { pool: null, asset: registry.contract };
  if (isContractId(v)) return { pool: null, asset: v };
  throw bad("bad_arg", "market is an Earn market (<pool>:<asset>), an asset id or a token contract.");
}

export interface ActivityQuery {
  section: Section | null;
  kind: string | null;
  period: Period;
  market: MarketFilter | null;
  limit: number;
  /** Portfolio's: transactions that succeeded and transfers that completed, never anchor transfers. */
  settled?: boolean;
}

const iso = (v: unknown): string => new Date(v as string).toISOString();
const known = (v: unknown): boolean => v !== null && v !== undefined;
/** The name an API before WP-10 logged for a token it couldn't name (main's swap.ts and account.ts, §9). */
const STAND_IN = /\bTOKEN\b/g;
const isStandIn = (v: unknown): boolean => typeof v === "string" && /^TOKEN$/.test(v);
/** A logged text, never the stand-in. */
const text = (v: DisplayValue | undefined): string | null => (typeof v === "string" && v !== "" && !isStandIn(v) ? v : null);
const units = (v: unknown): bigint | null => (typeof v === "string" && /^[0-9]{1,30}$/.test(v) ? BigInt(v) : null);
/** A USD amount: to the cent. */
const usdAmount = (v: number | null): Usd => (v === null ? null : Math.round(v * 100) / 100 || 0);
const short = (address: string) => `${address.slice(0, 4)}…${address.slice(-4)}`;

/** The one asset an intent's spend or receive names, and how much. */
function sideOf(amounts: Record<string, string> | undefined): { asset: string; amount: bigint | null } | null {
  const entries = Object.entries(amounts ?? {});
  return entries.length === 1 ? { asset: entries[0][0], amount: units(entries[0][1]) } : null;
}

/** A side's token by its short contract id, for one that has no name to show. */
const shortOf = (side: { asset: string } | null): string | null => (side && isContractId(side.asset) ? short(side.asset) : null);

/** An asset as an item names and values it. */
interface Named {
  contract: string;
  code: string;
  name: string | null;
  decimals: number;
  /** USD per whole unit today, or null. */
  usd: number | null;
  /** The launch, when it is one. */
  launch: Row | null;
}

/** What naming the items needs: today's prices, the launches and Moments they mention. */
class Names {
  constructor(
    readonly net: NetworkConfig,
    readonly refs: Record<PriceRef, RefPrice>,
    readonly launches: Map<string, Row>,
    readonly moments: Map<number, Row>,
  ) {}

  registry(a: AssetInfo | undefined): Named | null {
    return a ? { contract: a.contract, code: a.code, name: a.name, decimals: a.decimals, usd: usdOf(a, this.refs), launch: null } : null;
  }

  /** A registry asset (by id or contract) or a launch token; null for anything else. */
  of(id: string | null): Named | null {
    if (id === null) return null;
    const registry = this.registry(assetById(this.net, id));
    if (registry) return registry;
    const l = this.launches.get(id);
    if (!l) return null;
    const quote = usdOf(assetById(this.net, String(l.quote)), this.refs);
    return { contract: id, code: String(l.symbol), name: String(l.name), decimals: TOKEN_DECIMALS, usd: quote === null ? null : Number(priceOf(l)) * quote, launch: l };
  }

  value(a: Named | null, amount: bigint | null, decimals = a?.decimals): Usd {
    return a?.usd == null || amount === null ? null : usdAmount((Number(amount) / 10 ** decimals!) * a.usd);
  }
}

type Words = Pick<ActivityItem, "ref" | "symbol" | "name" | "title" | "subtitle" | "usd">;

/** The launch kinds, worded as My Launchpad words them (launchpad.ts). */
function launchWords(kind: string, d: Record<string, DisplayValue>, launch: Row | null, out: bigint | null, n: Names): Words {
  const symbol = launch ? String(launch.symbol) : text(d.symbol) ?? "a coin";
  const quote = n.of(launch ? String(launch.quote) : text(d.quote));
  const code = quote?.code ?? text(d.quote) ?? "";
  const amount = units(d.amount);
  const base = { ref: launch ? { token: String(launch.token) } : null, symbol: launch ? symbol : text(d.symbol), name: launch ? String(launch.name) : text(d.name) };
  switch (kind) {
    case "launch_create": {
      const buy = units(d.initialBuy);
      const bought = buy !== null && buy > 0n;
      return { ...base, title: `Launched ${symbol}`, subtitle: bought ? `With a ${amountText(buy)} ${code} buy` : null, usd: bought ? n.value(quote, buy) : null };
    }
    case "launch_buy":
      return {
        ...base,
        title: `Bought ${symbol}`,
        subtitle: amount === null ? null : out !== null ? `${amountText(out)} ${symbol} for ${amountText(amount)} ${code}` : `${amountText(amount)} ${code}`,
        usd: n.value(quote, amount),
      };
    case "launch_sell":
      return {
        ...base,
        title: `Sold ${symbol}`,
        subtitle: amount === null ? null : out !== null ? `${amountText(amount)} ${symbol} for ${amountText(out)} ${code}` : `${amountText(amount)} ${symbol}`,
        usd: n.value(quote, out),
      };
    case "launch_graduate":
      return { ...base, title: `Graduated ${symbol}`, subtitle: "Moved to Soroswap", usd: null };
    default:
      return { ...base, title: "Claimed creator fees", subtitle: out !== null ? `${amountText(out)} ${code} from ${symbol}` : symbol, usd: n.value(quote, out) };
  }
}

/** The launch a create made: its creator's launch of that ticker, the one made nearest the transaction (a creator may
 *  launch a ticker twice). */
function createdBy(r: Row, d: Record<string, DisplayValue>, n: Names): Row | null {
  const at = new Date(r.created_at).getTime();
  const made = [...n.launches.values()].filter((l) => l.creator === r.address && l.symbol === d.symbol);
  made.sort((a, b) => Math.abs(new Date(a.created_at).getTime() - at) - Math.abs(new Date(b.created_at).getTime() - at));
  return made[0] ?? null;
}

/** A logged transaction's words (§8.12.3's kinds). */
function txWords(r: Row, intent: Partial<Intent>, out: bigint | null, n: Names): Words {
  const kind = String(r.kind);
  const d = (intent.display ?? {}) as Record<string, DisplayValue>;
  const spend = sideOf(intent.spend);
  const receive = sideOf(intent.receive);
  const none = { ref: null, symbol: null, name: null, subtitle: null, usd: null };
  if (kind.startsWith("launch_")) {
    const token = text(d.token);
    return launchWords(kind, d, token ? n.launches.get(token) ?? null : createdBy(r, d, n), out, n);
  }
  switch (kind) {
    case "swap": {
      const sell = n.of(spend?.asset ?? null) ?? n.of(text(d.sell));
      const buy = n.of(receive?.asset ?? null) ?? n.of(text(d.buy));
      const sellCode = sell?.code ?? text(d.sell) ?? shortOf(spend);
      const buySymbol = buy?.code ?? text(d.buy);
      const buyCode = buySymbol ?? shortOf(receive);
      const launch = sell?.launch ?? buy?.launch ?? null;
      return {
        ref: launch ? { token: String(launch.token) } : null,
        symbol: buySymbol,
        name: buy?.name ?? null,
        title: "Swapped",
        subtitle: sellCode && buyCode ? `${sellCode} → ${buyCode}` : null,
        usd: n.value(sell, units(d.amountIn) ?? spend?.amount ?? null) ?? n.value(buy, out),
      };
    }
    case "payment": {
      const asset = n.of(spend?.asset ?? null);
      const symbol = asset?.code ?? text(d.asset);
      const code = symbol ?? shortOf(spend) ?? "";
      const to = text(intent.to) ?? text(d.to);
      return {
        ref: asset?.launch ? { token: asset.contract } : null,
        symbol,
        name: asset?.name ?? null,
        title: `Sent ${code}`.trim(),
        subtitle: spend?.amount != null ? `${amountText(spend.amount, asset?.decimals)} ${code}${to ? ` to ${short(to)}` : ""}` : null,
        usd: n.value(asset, spend?.amount ?? null),
      };
    }
    case "earn_deposit":
    case "earn_withdraw": {
      const deposit = kind === "earn_deposit";
      const side = deposit ? spend : receive;
      const asset = n.of(side?.asset ?? null);
      const code = asset?.code ?? text(d.asset) ?? "";
      const pool = intent.calls?.find((c) => c.fn === "submit")?.contract;
      return {
        ref: pool && side ? { market: `${pool}:${side.asset}` } : null,
        symbol: code || null,
        name: asset?.name ?? null,
        title: `${deposit ? "Supplied" : "Withdrew"} ${code}`.trim(),
        subtitle: side?.amount != null ? `${amountText(side.amount, asset?.decimals)} ${code}${text(d.pool) ? ` · ${d.pool}` : ""}` : text(d.pool),
        usd: n.value(asset, side?.amount ?? null),
      };
    }
    case "moment_publish": {
      // A publish answers the new Moment's id, kept as what it delivered.
      const m = out !== null ? n.moments.get(Number(out)) ?? null : null;
      const price = units(d.price);
      return {
        ...none,
        ref: out !== null ? { momentId: Number(out) } : null,
        title: m?.title ? `Published ${m.title}` : "Published a Moment",
        subtitle: price !== null && text(d.quote) ? `${amountText(price)} ${d.quote} per edition` : null,
      };
    }
    case "moment_collect": {
      const id = typeof d.momentId === "number" ? d.momentId : null;
      const m = id !== null ? n.moments.get(id) ?? null : null;
      const quantity = typeof d.quantity === "number" ? d.quantity : null;
      const total = units(d.total) ?? spend?.amount ?? null;
      const quote = n.of(spend?.asset ?? null) ?? n.of(text(d.quote));
      const editions = quantity === null ? null : `${quantity} ${quantity === 1 ? "edition" : "editions"}`;
      return {
        ...none,
        ref: id !== null ? { momentId: id } : null,
        title: m?.title ? `Collected ${m.title}` : id !== null ? `Collected Moment #${id}` : "Collected a Moment",
        subtitle: [editions, total !== null ? `${amountText(total)} ${quote?.code ?? text(d.quote) ?? ""}`.trim() : null].filter(Boolean).join(" · ") || null,
        usd: n.value(quote, total),
      };
    }
    case "approve":
    case "bridge_out": {
      const asset = n.of(spend?.asset ?? null);
      const code = asset?.code ?? "USDC";
      return kind === "approve"
        ? { ...none, symbol: code, name: asset?.name ?? null, title: `Allowed ${code} for the bridge`, subtitle: text(d.spender) }
        : { ...none, symbol: code, name: asset?.name ?? null, title: `Bridged ${code}`, subtitle: "Stellar → Monad", usd: n.value(asset, spend?.amount ?? null) };
    }
    case "trust": {
      const classic = intent.trust?.[0] ?? null;
      const registry = n.registry(n.net.assets.find((a) => a.classic === classic));
      const code = registry?.code ?? text(d.asset) ?? classic?.split(":")[0] ?? "";
      return { ...none, symbol: code || null, name: registry?.name ?? null, title: `Enabled ${code}`.trim() };
    }
    case "activate":
      return { ...none, title: "Set up your account" };
    case "faucet": {
      const xlm = n.registry(assetById(n.net, "XLM"));
      const amount = n.net.faucet ? `${amountText(BigInt(n.net.faucet.amount) * 10n ** BigInt(TOKEN_DECIMALS))} ` : "";
      return { ...none, symbol: xlm?.code ?? null, name: xlm?.name ?? null, title: `Got ${amount}test XLM` };
    }
    case "restore":
      return { ...none, title: "Restored data" };
    default:
      return { ...none, title: String(intent.summary ?? "") || kind };
  }
}

/** The USDC a bridge transfer moved: 6 decimals on Monad, 7 on Stellar, in the sending side's. */
function bridgeItem(b: Row, n: Names): ActivityItem {
  const direction = b.direction as BridgeDirection;
  const inbound = direction === "monad_to_stellar";
  const usdc = n.registry(assetById(n.net, "USDC"));
  const amount = String(b.amount);
  // The transfer's Stellar transaction: the keeper's mint for one from Monad, the user's burn for one to Monad.
  const hash = inbound ? b.dest_tx : b.source_tx;
  return {
    type: "bridge",
    id: String(b.id),
    kind: direction,
    summary: inbound ? "Moved USDC from Monad" : "Sent USDC to Monad",
    amount,
    status: String(b.status),
    at: iso(b.created_at),
    display: null,
    section: "bridge",
    hash: known(hash) ? String(hash).replace(/^0x/, "") : null,
    feeCharged: null,
    feePayer: null,
    result: null,
    ref: null,
    symbol: usdc?.code ?? "USDC",
    name: usdc?.name ?? null,
    title: `Bridged ${usdc?.code ?? "USDC"}`,
    subtitle: inbound ? "Monad → Stellar" : "Stellar → Monad",
    usd: n.value(usdc, units(amount), inbound ? 6 : usdc?.decimals),
  };
}

/** An anchor's deposit or withdrawal, as tracked (its amount as the anchor wrote it). */
function cashItem(c: Row, n: Names): ActivityItem {
  const asset = n.registry(assetById(n.net, c.asset === "native" ? "XLM" : String(c.asset)));
  const code = asset?.code ?? String(c.asset);
  const amount = c.amount === null ? null : String(c.amount);
  const anchor = n.net.anchors.find((a) => a.domain === c.anchor);
  return {
    type: "cash",
    id: String(c.id),
    kind: String(c.kind),
    // display.asset: the app words the item itself, in the user's language ("native" is XLM).
    summary: c.kind === "deposit" ? `Added ${c.asset}` : `Cashed out ${c.asset}`,
    amount,
    display: { asset: String(c.asset) },
    status: String(c.status),
    at: iso(c.created_at),
    section: "cash",
    hash: null,
    feeCharged: null,
    feePayer: null,
    result: null,
    ref: null,
    symbol: code,
    name: asset?.name ?? null,
    title: c.kind === "deposit" ? `Added ${code}` : `Cashed out ${code}`,
    subtitle: anchor?.name ?? String(c.anchor),
    usd: amount !== null && /^[0-9]+(\.[0-9]+)?$/.test(amount) && asset?.usd != null ? usdAmount(Number(amount) * asset.usd) : null,
  };
}

/** A row's summary and display as logged, with each token an API before WP-10 logged by the stand-in named: by its
 *  code, or its short contract id, in the summary's order (a swap's sold token, then its bought one). */
function asLogged(kind: string, intent: Partial<Intent>, n: Names): { summary: string; display: Record<string, DisplayValue> | null } {
  const summary = String(intent.summary ?? kind);
  const display = (intent.display ?? null) as Record<string, DisplayValue> | null;
  const fields: [string, { asset: string } | null][] = kind === "swap"
    ? [["sell", sideOf(intent.spend)], ["buy", sideOf(intent.receive)]]
    : kind === "payment"
    ? [["asset", sideOf(intent.spend)]]
    : [];
  const stood = fields.filter(([field]) => isStandIn(display?.[field]));
  if (stood.length === 0) return { summary, display };
  const codes = stood.map(([, side]) => n.of(side?.asset ?? null)?.code ?? shortOf(side) ?? "a token");
  let i = 0;
  return {
    summary: summary.replace(STAND_IN, () => codes[Math.min(i++, codes.length - 1)]),
    display: { ...display, ...Object.fromEntries(stood.map(([field], k) => [field, codes[k]])) },
  };
}

function txItem(r: Row, n: Names): ActivityItem {
  const intent = (r.intent ?? {}) as Partial<Intent>;
  const result = (r.result ?? null) as { amountOut?: unknown } | null;
  const out = typeof result?.amountOut === "string" ? result.amountOut : null;
  const { summary, display } = asLogged(String(r.kind), intent, n);
  return {
    type: "tx",
    id: String(r.hash),
    kind: String(r.kind),
    summary,
    status: String(r.status),
    at: iso(r.created_at),
    display,
    section: (r.section ?? "account") as Section,
    hash: String(r.hash),
    feeCharged: known(r.fee_charged) ? String(r.fee_charged) : null,
    feePayer: known(r.fee_payer) ? r.fee_payer as FeePayer : null,
    result: result ? { amountOut: out } : null,
    ...txWords(r, intent, units(out), n),
  };
}

/** The filters of a tx_log read. */
function txFilters(user: string, q: ActivityQuery, since: Date | null): postgres.PendingQuery<Row[]> {
  const m = q.market;
  const market = m === null
    ? sql()``
    : m.pool !== null
    ? sql()`and t.intent -> 'calls' @> ${sql().json([{ contract: m.pool }])}::jsonb
            and (t.intent -> 'spend' ? ${m.asset} or t.intent -> 'receive' ? ${m.asset})`
    : sql()`and (t.intent -> 'spend' ? ${m.asset} or t.intent -> 'receive' ? ${m.asset} or t.intent -> 'display' ->> 'token' = ${m.asset})`;
  return sql()`
    where t.address = ${user}
      ${q.section ? sql()`and coalesce(t.section, 'account') = ${q.section}` : sql()``}
      ${q.kind ? sql()`and t.kind = ${q.kind}` : sql()``}
      ${since ? sql()`and t.created_at > ${since}` : sql()``}
      ${q.settled ? sql()`and t.status = 'success'` : sql()``}
      ${market}`;
}

/** The account's items for `q`, newest first: at most `q.limit`. */
export async function activity(user: string, q: ActivityQuery, now: number = Date.now(), net: NetworkConfig = env.network): Promise<ActivityItem[]> {
  const since = periodStart(q.period, now);
  const usdc = assetById(net, "USDC")?.contract;
  const xlm = assetById(net, "XLM")?.contract;
  // Transfers move USDC (bridges) or an anchor's asset: a market filter keeps them only when it names that asset.
  const bridges = (q.section === null || q.section === "bridge") && (q.market === null || (q.market.pool === null && q.market.asset === usdc));
  const cash = !q.settled && (q.section === null || q.section === "cash");
  const [txs, transfers, deposits, refs] = await Promise.all([
    sql()`
      select hash, address, kind, intent, status, ledger, created_at, section, fee_charged, fee_payer, result from lite.tx_log t
       ${txFilters(user, q, since)}
       order by t.created_at desc limit ${q.limit}`,
    bridges ? sql()`
      select id, direction, amount, status, source_tx, dest_tx, created_at from lite.bridge_transfers b
       where b.address = ${user}
         ${q.kind ? sql()`and b.direction = ${q.kind}` : sql()``}
         ${since ? sql()`and b.created_at > ${since}` : sql()``}
         ${q.settled ? sql()`and b.status = 'completed'` : sql()``}
       order by b.created_at desc limit ${q.limit}` : [],
    cash ? sql()`
      select id, anchor, kind, asset, amount, status, created_at from lite.anchor_transfers c
       where c.address = ${user}
         ${q.kind ? sql()`and c.kind = ${q.kind}` : sql()``}
         ${since ? sql()`and c.created_at > ${since}` : sql()``}
       order by c.created_at desc limit ${q.limit}` : [],
    referencePrices(now, net),
  ]);

  // The launches and Moments the transactions mention, by token, by a create's ticker, by Moment id.
  const tokens = new Set<string>();
  const symbols = new Set<string>();
  const momentIds = new Set<number>();
  for (const r of txs) {
    const intent = (r.intent ?? {}) as Partial<Intent>;
    const d = (intent.display ?? {}) as Record<string, DisplayValue>;
    for (const c of [...Object.keys(intent.spend ?? {}), ...Object.keys(intent.receive ?? {}), text(d.token)]) {
      if (c && isContractId(c) && !assetById(net, c)) tokens.add(c);
    }
    if (r.kind === "launch_create" && text(d.symbol)) symbols.add(String(d.symbol));
    if (r.kind === "moment_collect" && typeof d.momentId === "number") momentIds.add(d.momentId);
    const out = units((r.result as { amountOut?: unknown } | null)?.amountOut);
    if (r.kind === "moment_publish" && out !== null) momentIds.add(Number(out));
  }
  const [launches, moments] = await Promise.all([
    tokens.size || symbols.size
      ? sql()`select * from lite.launches where token = any(${[...tokens]}::text[]) or (creator = ${user} and symbol = any(${[...symbols]}::text[]))`
      : [],
    momentIds.size ? sql()`select id, title from lite.moments where id = any(${[...momentIds]}::int[])` : [],
  ]);
  const n = new Names(net, refs, new Map(launches.map((l) => [String(l.token), l])), new Map(moments.map((m) => [Number(m.id), m])));

  const items = [
    ...txs.map((r) => txItem(r, n)),
    ...transfers.map((b) => bridgeItem(b, n)),
    ...deposits.map((c) => cashItem(c, n)).filter((c) => q.market === null || (q.market.pool === null && q.market.asset === (c.display?.asset === "native" ? xlm : assetById(net, String(c.display?.asset))?.contract))),
  ];
  return items.sort((a, b) => Date.parse(b.at) - Date.parse(a.at)).slice(0, q.limit);
}
