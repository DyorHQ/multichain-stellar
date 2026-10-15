// prices: GET /v1/prices, kept for older clients (docs/DESIGN-stellar-parity.md §6.6, §12.6). Public and cached 30 s;
// XLM and USDC exactly as lite.ref_quotes holds them, or left out when unknown (never filled in); BUSDC is USDC. Run
// alone, the phase fills the reference cache first, as the markets phase does.
import type { E2E } from "../lite_e2e.ts";

const DAY = 86_400_000;
const READ_CACHE_MS = 15_000;

export default async function prices(t: E2E): Promise<string> {
  const quotes = async () => new Map((await t.db`select ref, usd, quoted_at from lite.ref_quotes`).map((r) => [r.ref as string, r]));
  let stored = await quotes();
  if (!stored.has("XLM") && !stored.has("USDC")) {
    const { refprices } = await import("../../../supabase/functions/lite-indexer/jobs/refprices.ts");
    await refprices();
    stored = await quotes();
  }
  /** The price /v1/prices must give a reference asset: the stored one under 24 hours old, or none. */
  const expected = (ref: string) => {
    const q = stored.get(ref);
    return q && Date.now() - new Date(q.quoted_at).getTime() <= DAY ? Number(q.usd) : undefined;
  };

  const ask = async () => {
    const res = await fetch(`${t.API}/v1/prices`);
    const body = await res.json();
    if (!res.ok) throw new Error(`GET /prices → ${res.status} ${JSON.stringify(body.error ?? body)}`);
    return { body, cache: res.headers.get("cache-control") };
  };
  let p = await ask();
  if (p.body.usd.XLM !== expected("XLM") || p.body.usd.USDC !== expected("USDC")) {
    await new Promise((r) => setTimeout(r, READ_CACHE_MS + 1_000));
    p = await ask();
  }
  if (p.cache !== "public, max-age=30") throw new Error(`/prices cache-control: ${p.cache}`);
  const usd = p.body.usd;
  for (const ref of ["XLM", "USDC"]) {
    if (usd[ref] !== expected(ref)) throw new Error(`${ref}: ${usd[ref]}, stored ${expected(ref)}`);
  }
  if (usd.BUSDC !== usd.USDC) throw new Error(`BUSDC ${usd.BUSDC} isn't USDC ${usd.USDC}`);
  const shown = (v: number | undefined) => (v === undefined ? "unknown" : `$${v}`);
  return `XLM ${shown(usd.XLM)}, USDC ${shown(usd.USDC)}, BUSDC = USDC (${p.body.reference})`;
}
