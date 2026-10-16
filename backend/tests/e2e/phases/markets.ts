// markets: Top Tokens' rows and a token page's data (docs/DESIGN-stellar-parity.md §6.6, §6.12, §12.6). A package
// stack runs without the indexer loop, so the phase runs the refprices job once itself; then, with no token:
// - GET /v1/markets is public and cached 30 s: XLM, then USDC, never BUSDC;
// - XLM and USDC are priced exactly as lite.ref_quotes holds them (Kraken, or the SDEX for XLM), or, when no provider
//   answered, null and stale: never a constant;
// - GET /v1/markets/:id gives the same row with its `about`; BUSDC is a test asset at USDC's price;
// - history: day in 900 s buckets, week and month in 3600 s, all in 86400 s, oldest first, from the provider.
import type { E2E } from "../lite_e2e.ts";

const DAY = 86_400_000;

/** The API keeps reference prices 15 s per isolate: a read made just before the job may still be served. */
const READ_CACHE_MS = 15_000;

export default async function markets(t: E2E): Promise<string> {
  const { refprices } = await import("../../../supabase/functions/lite-indexer/jobs/refprices.ts");
  const job = await refprices() as { skipped?: string; quotes?: Record<string, string | null>; candles?: Record<string, number>; errors?: string[] };
  if (job.skipped) throw new Error(`refprices: ${job.skipped}`);

  async function open(path: string): Promise<{ body: any; cache: string | null }> {
    const res = await fetch(`${t.API}/v1${path}`);
    const body = await res.json();
    if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${JSON.stringify(body.error ?? body)}`);
    return { body, cache: res.headers.get("cache-control") };
  }

  const stored = new Map((await t.db`select ref, usd, source, market, quoted_at from lite.ref_quotes`).map((r) => [r.ref as string, r]));
  /** Whether a row is priced exactly as the store says: the stored quote under 24 hours old, or null and stale. */
  const matches = (row: any): boolean => {
    const q = stored.get(row.id);
    const known = q && Date.now() - new Date(q.quoted_at).getTime() <= DAY;
    if (!known) return row.priceUsd === null && row.stale === true;
    return row.priceUsd === Number(q.usd) && row.priceSource.kind === "reference" && row.priceSource.market === q.market &&
      row.priceSource.at === new Date(q.quoted_at).toISOString();
  };

  let list = await open("/markets");
  if (list.body.rows.slice(0, 2).some((r: any) => !matches(r))) {
    await new Promise((r) => setTimeout(r, READ_CACHE_MS + 1_000));
    list = await open("/markets");
  }
  if (list.cache !== "public, max-age=30") throw new Error(`/markets cache-control: ${list.cache}`);
  const rows = list.body.rows;
  const [xlm, usdc] = rows;
  if (xlm?.id !== "XLM" || usdc?.id !== "USDC") throw new Error(`Popular order starts ${rows.slice(0, 2).map((r: any) => r.id).join(", ")}`);
  if (rows.some((r: any) => r.id === "BUSDC")) throw new Error("BUSDC is listed");
  for (const row of [xlm, usdc]) {
    if (!matches(row)) throw new Error(`${row.id}: ${JSON.stringify([row.priceUsd, row.stale, row.priceSource])} isn't the stored quote ${JSON.stringify(stored.get(row.id) ?? null)}`);
    if (row.priceUsd !== null && !(row.priceUsd > 0)) throw new Error(`${row.id}: price ${row.priceUsd}`);
    if (row.marketCapUsd !== null || row.isNew !== false || row.kind !== "registry") throw new Error(`${row.id}: ${JSON.stringify(row)}`);
  }

  // A token page: the same row, with its about.
  const page = (await open("/markets/XLM")).body;
  if (page.row.priceUsd !== xlm.priceUsd || page.about.classic !== "native" || page.about.issuer !== null) {
    throw new Error(`/markets/XLM: ${JSON.stringify(page)}`);
  }
  const busdc = (await open("/markets/BUSDC")).body.row;
  if (JSON.stringify(busdc.badges) !== '["testAsset"]' || busdc.priceUsd !== usdc.priceUsd) throw new Error(`/markets/BUSDC: ${JSON.stringify(busdc)}`);

  // History, from the stored candles.
  const counts: string[] = [];
  for (const [range, intervalS] of [["day", 900], ["week", 3600], ["month", 3600], ["all", 86_400]] as const) {
    const h = (await open(`/markets/XLM/history?range=${range}`)).body;
    if (h.intervalS !== intervalS || h.range !== range || h.source !== "Kraken") throw new Error(`${range}: ${JSON.stringify({ ...h, points: h.points.length })}`);
    const [{ n }] = await t.db`select count(*)::int as n from lite.ref_candles where ref = 'XLM' and interval_s = ${intervalS}`;
    if (n > 0 && h.points.length === 0) throw new Error(`${range}: no points, ${n} candles stored`);
    if (h.points.some((p: any, i: number) => !(p.usd > 0) || (i > 0 && p.t <= h.points[i - 1].t))) throw new Error(`${range}: points out of order or unpriced`);
    counts.push(`${range} ${h.points.length}`);
  }

  const price = (row: any) => (row.priceUsd === null ? "unknown (stale)" : `$${row.priceUsd} (${stored.get(row.id)?.source})`);
  const failed = job.errors?.length ? `; job: ${job.errors.join("; ")}` : "";
  return `XLM ${price(xlm)}, USDC ${price(usdc)}, BUSDC unlisted; history points ${counts.join(", ")}${failed}`;
}
