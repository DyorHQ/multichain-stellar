// GET /v1/prices, kept for older clients (docs/DESIGN-stellar-parity.md §6.6): USD prices by asset id, from the
// reference cache (refprices.ts). Registry assets are priced through their reference (BUSDC as USDC), launch tokens as
// their last price × their quote's USD price. An unknown price is left out, never filled in.
import type { Prices } from "./contract.ts";
import { num, sql } from "./db.ts";
import { env } from "./env.ts";
import { assetById } from "./networks.ts";
import { referencePrices, usdOf } from "./refprices.ts";

export async function prices(now: number = Date.now()): Promise<Prices> {
  const net = env.network;
  const ref = await referencePrices(now, net);
  const usd: Record<string, number> = {};
  for (const a of net.assets) {
    const p = usdOf(a, ref);
    if (p !== null) usd[a.id] = p;
  }
  const launches = await sql()`select token, quote, last_price from lite.launches where last_price is not null order by volume_quote desc limit 100`;
  for (const l of launches) {
    const quoteUsd = usdOf(assetById(net, l.quote as string), ref);
    if (quoteUsd !== null) usd[l.token as string] = Number(num(l.last_price)) * quoteUsd;
  }
  return {
    usd,
    reference: net.pricing.kind === "reference" ? "Mainnet reference prices; testnet assets have no value." : "Market prices.",
    at: new Date(now).toISOString(),
  };
}
