// Reference prices in USD. Testnet assets have no market price, so Lite shows testnet balances at mainnet
// reference prices (XLM from the mainnet SDEX XLM/USDC book), labeled as such in the app.
import { sql, num } from "./db.ts";
import { env } from "./env.ts";

let cached: { at: number; xlm: number } | null = null;

export async function xlmUsd(): Promise<number> {
  if (cached && Date.now() - cached.at < 60_000) return cached.xlm;
  const url = "https://horizon.stellar.org/order_book?selling_asset_type=native&buying_asset_type=credit_alphanum4" +
    "&buying_asset_code=USDC&buying_asset_issuer=GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN&limit=1";
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(5_000) });
    const b = await res.json();
    const bid = Number(b.bids?.[0]?.price ?? 0);
    const ask = Number(b.asks?.[0]?.price ?? 0);
    const mid = bid && ask ? (bid + ask) / 2 : bid || ask;
    if (mid > 0) cached = { at: Date.now(), xlm: mid };
  } catch {
    // keep the last good value
  }
  return cached?.xlm ?? 0;
}

export async function prices() {
  const xlm = await xlmUsd();
  const out: Record<string, number> = { XLM: xlm, USDC: 1, BUSDC: 1 };
  const xlmContract = env.network.assets.find((a) => a.id === "XLM")!.contract;
  const launches = await sql()`select token, quote, last_price from lite.launches where last_price is not null order by volume_quote desc limit 100`;
  for (const l of launches) {
    const quoteUsd = l.quote === xlmContract ? xlm : 1;
    out[l.token as string] = Number(num(l.last_price)) * quoteUsd;
  }
  return { usd: out, reference: env.network.name === "testnet" ? "Mainnet reference prices; testnet assets have no value." : "Market prices.", at: new Date().toISOString() };
}
