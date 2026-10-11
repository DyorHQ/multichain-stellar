// Swap aggregation: SDEX (Horizon path finding), Soroswap (router, or its API when a key is set) and Aquarius
// (find-path API). Quotes run in parallel; the best output wins; the quote is stored and redeemed by /swap/build.
import { Asset, Operation, xdr } from "@stellar/stellar-sdk";
import { needsTrustline, accountView } from "./account.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { AssetInfo, assetById } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { classicAsset, fromStroops, horizon, invoke, isContractId, newTx, requireAccount, sv, view } from "./stellar.ts";
import { Intent } from "./verify.ts";

export type Venue = "sdex" | "soroswap" | "aquarius";

export interface Route {
  venue: Venue;
  amountOut: string;
  /** Hops as contract ids (SDEX: classic specs). */
  path: string[];
  /** Aquarius: the swap chain from find-path. */
  chainXdr?: string;
}

export interface QuoteResult {
  quoteId: string;
  sell: string;
  buy: string;
  amountIn: string;
  slippageBps: number;
  best: Route & { minOut: string };
  alternatives: Route[];
  expiresAt: string;
}

function resolve(id: string): AssetInfo {
  const a = assetById(env.network, id);
  if (a) return a;
  if (isContractId(id)) return { id, code: "TOKEN", name: "Token", decimals: 7, contract: id, classic: null };
  throw bad("bad_asset", `Unknown asset ${id}.`);
}

async function quoteSdex(sell: AssetInfo, buy: AssetInfo, amountIn: bigint): Promise<Route | null> {
  if (!sell.classic || !buy.classic) return null;
  try {
    const call = horizon().strictSendPaths(classicAsset(sell.classic), fromStroops(amountIn), [classicAsset(buy.classic)]);
    const res = await call.call();
    const best = res.records.sort((a: any, b: any) => Number(b.destination_amount) - Number(a.destination_amount))[0];
    if (!best) return null;
    const toSpec = (p: any) => (p.asset_type === "native" ? "native" : `${p.asset_code}:${p.asset_issuer}`);
    const [i, f = ""] = String(best.destination_amount).split(".");
    const out = BigInt(i) * 10_000_000n + BigInt((f + "0000000").slice(0, 7));
    return { venue: "sdex", amountOut: out.toString(), path: [sell.classic, ...best.path.map(toSpec), buy.classic] };
  } catch {
    return null;
  }
}

async function quoteSoroswap(sell: AssetInfo, buy: AssetInfo, amountIn: bigint): Promise<Route | null> {
  const router = env.network.contracts.soroswapRouter;
  const hubs = env.network.assets.filter((a) => a.id === "XLM" || a.id === "USDC").map((a) => a.contract);
  const paths: string[][] = [[sell.contract, buy.contract]];
  for (const h of hubs) if (h !== sell.contract && h !== buy.contract) paths.push([sell.contract, h, buy.contract]);
  const results: (Route | null)[] = await Promise.all(
    paths.map(async (p): Promise<Route | null> => {
      try {
        const amounts = (await view(router, "router_get_amounts_out", [sv.i128(amountIn), sv.vec(p.map(sv.addr))])) as bigint[];
        return { venue: "soroswap", amountOut: amounts[amounts.length - 1].toString(), path: p };
      } catch {
        return null;
      }
    }),
  );
  return pickBest(results.filter((r): r is Route => r !== null));
}

async function quoteAquarius(sell: AssetInfo, buy: AssetInfo, amountIn: bigint): Promise<Route | null> {
  const api = env.network.apis.aquarius;
  if (!api || !env.network.contracts.aquariusRouter) return null;
  try {
    const res = await fetch(`${api}/find-path/`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ token_in_address: sell.contract, token_out_address: buy.contract, amount: amountIn.toString() }),
      signal: AbortSignal.timeout(8_000),
    });
    if (!res.ok) return null;
    const body = await res.json();
    if (!body.success || !body.swap_chain_xdr) return null;
    return { venue: "aquarius", amountOut: String(body.amount), path: body.tokens_addresses ?? [sell.contract, buy.contract], chainXdr: body.swap_chain_xdr };
  } catch {
    return null;
  }
}

function pickBest(routes: Route[]): Route | null {
  const valid = routes.filter((r) => BigInt(r.amountOut) > 0n);
  if (valid.length === 0) return null;
  return valid.reduce((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? b : a));
}

export async function quote(user: string, sellId: string, buyId: string, amountIn: bigint, slippageBps: number): Promise<QuoteResult> {
  const sell = resolve(sellId);
  const buy = resolve(buyId);
  if (sell.contract === buy.contract) throw bad("same_asset", "Pick two different assets.");
  if (slippageBps < 1 || slippageBps > 1_000) throw bad("bad_slippage", "Slippage must be between 0.01% and 10%.");
  const routes = (await Promise.all([quoteSdex(sell, buy, amountIn), quoteSoroswap(sell, buy, amountIn), quoteAquarius(sell, buy, amountIn)])).filter(
    (r): r is Route => r !== null,
  );
  const best = pickBest(routes);
  if (!best) throw new ApiError(404, "no_route", `No route from ${sell.code} to ${buy.code} right now.`);
  const minOut = (BigInt(best.amountOut) * BigInt(10_000 - slippageBps)) / 10_000n;
  const alternatives = routes.filter((r) => r !== best).sort((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? 1 : -1));
  const request = { sell: sell.id, buy: buy.id, amountIn: amountIn.toString(), slippageBps };
  const bestWithMin = { ...best, minOut: minOut.toString() };
  const rows = await sql()`
    insert into lite.swap_quotes (address, request, best, alternatives)
    values (${user}, ${sql().json(request)}, ${sql().json(bestWithMin as any)}, ${sql().json(alternatives as any)})
    returning id, expires_at`;
  return {
    quoteId: rows[0].id as string,
    sell: sell.id,
    buy: buy.id,
    amountIn: amountIn.toString(),
    slippageBps,
    best: bestWithMin,
    alternatives,
    expiresAt: new Date(rows[0].expires_at as Date).toISOString(),
  };
}

export async function buildSwap(user: string, quoteId: string): Promise<PlanView> {
  if (!/^[0-9a-f-]{36}$/.test(quoteId)) throw notFound("Quote");
  const rows = await sql()`select request, best, expires_at from lite.swap_quotes where id = ${quoteId} and address = ${user}`;
  if (rows.length === 0) throw notFound("Quote");
  if ((rows[0].expires_at as Date).getTime() < Date.now() - 60_000) throw new ApiError(410, "quote_expired", "This price is out of date. Get a new quote.");
  const req = rows[0].request as { sell: string; buy: string; amountIn: string };
  const best = rows[0].best as Route & { minOut: string };
  const buy = resolve(req.buy);
  const steps: { label: string; spec: Record<string, unknown> & { kind: string } }[] = [];
  const acct = await accountView(user);
  const trust = needsTrustline(acct.balances, buy.id);
  if (trust) steps.push({ label: `Enable ${buy.code}`, spec: { kind: "trust", asset: trust } });
  steps.push({
    label: `Swap via ${best.venue === "sdex" ? "SDEX" : best.venue === "soroswap" ? "Soroswap" : "Aquarius"}`,
    spec: { kind: `swap_${best.venue}`, sell: req.sell, buy: req.buy, amountIn: req.amountIn, minOut: best.minOut, path: best.path, chainXdr: best.chainXdr ?? null },
  });
  return await createPlan(user, "swap", steps);
}

function swapIntent(sell: AssetInfo, buy: AssetInfo, amountIn: string, minOut: string, venue: string): Intent {
  return {
    kind: "swap",
    summary: `Swap ${fromStroops(amountIn, sell.decimals)} ${sell.code} for at least ${fromStroops(minOut, buy.decimals)} ${buy.code}`,
    spend: { [sell.contract]: amountIn },
    receive: { [buy.contract]: minOut },
    display: { venue, sell: sell.code, buy: buy.code, amountIn, minOut },
  };
}

registerBuilder("swap_sdex", async (user, spec) => {
  const sell = resolve(String(spec.sell));
  const buy = resolve(String(spec.buy));
  const path = (spec.path as string[]).slice(1, -1).map(classicAsset) as Asset[];
  const acct = await requireAccount(user);
  const tx = newTx(acct)
    .addOperation(
      Operation.pathPaymentStrictSend({
        sendAsset: classicAsset(sell.classic!),
        sendAmount: fromStroops(String(spec.amountIn)),
        destination: user,
        destAsset: classicAsset(buy.classic!),
        destMin: fromStroops(String(spec.minOut)),
        path,
      }),
    )
    .build();
  const intent = swapIntent(sell, buy, String(spec.amountIn), String(spec.minOut), "SDEX");
  intent.ops = ["pathPaymentStrictSend"];
  return { tx, intent };
});

registerBuilder("swap_soroswap", async (user, spec) => {
  const sell = resolve(String(spec.sell));
  const buy = resolve(String(spec.buy));
  const router = env.network.contracts.soroswapRouter;
  const path = spec.path as string[];
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
  const acct = await requireAccount(user);
  const tx = await invoke(acct, router, "swap_exact_tokens_for_tokens", [
    sv.i128(String(spec.amountIn)),
    sv.i128(String(spec.minOut)),
    sv.vec(path.map(sv.addr)),
    sv.addr(user),
    sv.u64(deadline),
  ]);
  const intent = swapIntent(sell, buy, String(spec.amountIn), String(spec.minOut), "Soroswap");
  intent.calls = [{ contract: router, fn: "swap_exact_tokens_for_tokens" }];
  return { tx, intent };
});

registerBuilder("swap_aquarius", async (user, spec) => {
  const sell = resolve(String(spec.sell));
  const buy = resolve(String(spec.buy));
  const router = env.network.contracts.aquariusRouter!;
  const chain = xdr.ScVal.fromXDR(String(spec.chainXdr), "base64");
  const acct = await requireAccount(user);
  const tx = await invoke(acct, router, "swap_chained", [sv.addr(user), chain, sv.addr(sell.contract), sv.u128(String(spec.amountIn)), sv.u128(String(spec.minOut))]);
  const intent = swapIntent(sell, buy, String(spec.amountIn), String(spec.minOut), "Aquarius");
  intent.calls = [{ contract: router, fn: "swap_chained" }];
  return { tx, intent };
});
