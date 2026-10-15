// Swap aggregation (docs/DESIGN-stellar-parity.md §6.8): SDEX (Horizon path finding), Soroswap (router) and Aquarius
// (find-path API) quote in parallel; every venue's route is kept with the quote, and /swap/build redeems the one the
// user picked, the best by default. The swap pays its user (`to` and the minimum out are bound, as WP-11's call rules
// check). Where activation is sponsored, a swap of a registry asset into XLM by an account with no XLM to spend is the
// account's one starter swap, which DyorHQ pays for (§4.3).
import { Asset, Operation, xdr } from "@stellar/stellar-sdk";
import type { QuoteRoute, StarterSwapReason, SwapQuote, SwapRoute, SwapVenue } from "./contract.ts";
import { resolveAsset, ResolvedAsset } from "./assets.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { baseReserve, positionOf, starterSwapEligibility } from "./fees.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById } from "./networks.ts";
import { createPlan, registerBuilder, StepSpec } from "./plans.ts";
import { starterUsed } from "./sponsor.ts";
import { classicAsset, classicBalances, fromStroops, horizon, invoke, newTx, requireAccount, sv, view } from "./stellar.ts";
import { Intent } from "./verify.ts";

export type Venue = SwapVenue;

export interface Route {
  venue: Venue;
  amountOut: string;
  /** Hops as contract ids (SDEX: classic specs). */
  path: string[];
  /** Aquarius: the swap chain from find-path. */
  chainXdr?: string;
}

/** A route as a quote stores it: its minimum out at the quote's slippage, and its price impact where known. */
interface PricedRoute extends Route {
  minOut: string;
  priceImpactBps: number | null;
}

const VENUE_NAMES: Record<Venue, string> = { sdex: "SDEX", soroswap: "Soroswap", aquarius: "Aquarius" };

async function quoteSdex(sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<Route | null> {
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

/** Soroswap's output for `amountIn` along `path`, or null. */
async function soroswapOut(path: string[], amountIn: bigint): Promise<bigint | null> {
  try {
    const amounts = (await view(env.network.contracts.soroswapRouter, "router_get_amounts_out", [sv.i128(amountIn), sv.vec(path.map(sv.addr))])) as bigint[];
    return BigInt(amounts[amounts.length - 1]);
  } catch {
    return null;
  }
}

async function quoteSoroswap(sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<Route | null> {
  const hubs = env.network.assets.filter((a) => a.id === "XLM" || a.id === "USDC").map((a) => a.contract);
  const paths: string[][] = [[sell.contract, buy.contract]];
  for (const h of hubs) if (h !== sell.contract && h !== buy.contract) paths.push([sell.contract, h, buy.contract]);
  const results = await Promise.all(paths.map(async (p): Promise<Route | null> => {
    const out = await soroswapOut(p, amountIn);
    return out === null ? null : { venue: "soroswap", amountOut: out.toString(), path: p };
  }));
  return pickBest(results.filter((r): r is Route => r !== null));
}

async function quoteAquarius(sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<Route | null> {
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

/** Soroswap's price impact in basis points: how much worse the rate for `amountIn` is than for a thousandth of it.
 *  Null where the small trade rounds to nothing. */
async function soroswapImpact(route: Route, amountIn: bigint): Promise<number | null> {
  const small = amountIn / 1_000n;
  if (small === 0n) return null;
  const smallOut = await soroswapOut(route.path, small);
  if (!smallOut || smallOut === 0n) return null;
  // rate(full) / rate(small) = (out × small) / (smallOut × amountIn)
  const ratio = (BigInt(route.amountOut) * small * 10_000n) / (smallOut * amountIn);
  return Math.max(0, 10_000 - Number(ratio));
}

function minOut(amountOut: string, slippageBps: number): string {
  return ((BigInt(amountOut) * BigInt(10_000 - slippageBps)) / 10_000n).toString();
}

/** What a swap needs to know of the user's account: whether it can receive `buy` without a new trustline (the
 *  classic asset to enable first, or null), and the XLM it can spend. */
async function holder(user: string, buy: ResolvedAsset): Promise<{ enable: string | null; spendable: bigint }> {
  const [acct, reserve] = await Promise.all([classicBalances(user), baseReserve()]);
  const line = buy.classic && buy.classic !== "native" ? buy.classic : null;
  return {
    enable: line && !acct?.balances.some((b) => b.asset === line) ? line : null,
    spendable: BigInt(positionOf(acct, reserve)?.spendable ?? "0"),
  };
}

/** Whether this would be the account's starter swap (§4.3), from the quote's facts. */
async function starterSwapFor(user: string, sell: ResolvedAsset, buy: ResolvedAsset, spendable: bigint, out: string): Promise<{ eligible: boolean; reason: StarterSwapReason | null }> {
  const input = {
    activation: env.network.activation,
    buysXlm: buy.id === "XLM",
    sellsRegistryAsset: Boolean(assetById(env.network, sell.id)) && sell.id !== "XLM",
    spendable,
    minOut: BigInt(out),
    used: false,
  };
  const policy = env.network.feePolicy;
  const first = starterSwapEligibility(input, policy);
  if (!first.eligible) return first;
  return starterSwapEligibility({ ...input, used: await starterUsed(user) }, policy);
}

export async function quote(user: string, sellId: string, buyId: string, amountIn: bigint, slippageBps: number): Promise<SwapQuote> {
  const sell = await resolveAsset(sellId);
  const buy = await resolveAsset(buyId);
  if (sell.contract === buy.contract) throw bad("same_asset", "Pick two different assets.");
  if (slippageBps < 1 || slippageBps > 1_000) throw bad("bad_slippage", "Slippage must be between 0.01% and 10%.");
  const [found, account] = await Promise.all([
    Promise.all([quoteSdex(sell, buy, amountIn), quoteSoroswap(sell, buy, amountIn), quoteAquarius(sell, buy, amountIn)]),
    holder(user, buy),
  ]);
  const routes = found.filter((r): r is Route => r !== null && BigInt(r.amountOut) > 0n);
  const best = pickBest(routes);
  if (!best) throw new ApiError(404, "no_route", `No route from ${sell.code} to ${buy.code} right now.`);
  const ranked = [best, ...routes.filter((r) => r !== best).sort((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? 1 : -1))];
  const priced: PricedRoute[] = await Promise.all(ranked.map(async (r) => ({
    ...r,
    minOut: minOut(r.amountOut, slippageBps),
    priceImpactBps: r.venue === "soroswap" ? await soroswapImpact(r, amountIn) : null,
  })));
  const starterSwap = await starterSwapFor(user, sell, buy, account.spendable, priced[0].minOut);
  const request = { sell: sell.id, buy: buy.id, amountIn: amountIn.toString(), slippageBps };
  const [head, ...rest] = priced;
  const rows = await sql()`
    insert into lite.swap_quotes (address, request, best, alternatives)
    values (${user}, ${sql().json(request)}, ${sql().json(head as any)}, ${sql().json(rest as any)})
    returning id, expires_at`;
  const legacy = ({ venue, amountOut, path, chainXdr }: PricedRoute): SwapRoute => ({ venue, amountOut, path, ...(chainXdr ? { chainXdr } : {}) });
  const routeView = (r: PricedRoute, i: number): QuoteRoute => ({
    venue: r.venue,
    amountOut: r.amountOut,
    minOut: r.minOut,
    priceImpactBps: r.priceImpactBps,
    path: r.path,
    best: i === 0,
  });
  return {
    quoteId: rows[0].id as string,
    sell: sell.id,
    buy: buy.id,
    amountIn: amountIn.toString(),
    slippageBps,
    best: { ...legacy(head), minOut: head.minOut },
    alternatives: rest.map(legacy),
    expiresAt: new Date(rows[0].expires_at as Date).toISOString(),
    routes: priced.map(routeView),
    needsEnable: account.enable ? [buy.id] : [],
    starterSwap,
  };
}

function swapSpec(req: { sell: string; buy: string; amountIn: string }, r: PricedRoute | (Route & { minOut: string })): StepSpec {
  return { kind: `swap_${r.venue}`, sell: req.sell, buy: req.buy, amountIn: req.amountIn, minOut: r.minOut, path: r.path, chainXdr: r.chainXdr ?? null };
}

/** POST /v1/swap/build: the route of `venue` (the best when absent), after a user-paid trust step when the bought asset
 *  isn't enabled. A starter swap is marked for DyorHQ to pay, with its SDEX route to fall back on (§4.3). */
export async function buildSwap(user: string, quoteId: string, venue?: Venue) {
  if (!/^[0-9a-f-]{36}$/.test(quoteId)) throw notFound("Quote");
  const rows = await sql()`select request, best, alternatives, expires_at from lite.swap_quotes where id = ${quoteId} and address = ${user}`;
  if (rows.length === 0) throw notFound("Quote");
  if ((rows[0].expires_at as Date).getTime() < Date.now() - 60_000) throw new ApiError(410, "quote_expired", "This price is out of date. Get a new quote.");
  const req = rows[0].request as { sell: string; buy: string; amountIn: string; slippageBps?: number };
  const quoted = [rows[0].best, ...((rows[0].alternatives ?? []) as unknown[])] as (Route & { minOut?: string })[];
  // Quotes stored before every route kept its minimum carry one only for the best.
  const routes = quoted.map((r) => ({ ...r, minOut: r.minOut ?? minOut(r.amountOut, req.slippageBps ?? 100) }));
  const route = venue ? routes.find((r) => r.venue === venue) : routes[0];
  if (!route) throw bad("bad_arg", `This quote has no ${VENUE_NAMES[venue!]} route.`);
  const sell = await resolveAsset(req.sell);
  const buy = await resolveAsset(req.buy);
  const account = await holder(user, buy);
  const steps: { label: string; spec: StepSpec }[] = [];
  if (account.enable) steps.push({ label: `Enable ${buy.code}`, spec: { kind: "trust", asset: account.enable } });
  const spec = swapSpec(req, route);
  const starter = await starterSwapFor(user, sell, buy, account.spendable, route.minOut);
  if (starter.eligible) {
    const sdex = route.venue === "sdex" ? null : routes.find((r) => r.venue === "sdex");
    spec.starter = true;
    spec.fallback = sdex ? swapSpec(req, sdex) : null;
  }
  steps.push({ label: `Swap via ${VENUE_NAMES[route.venue]}`, spec });
  return await createPlan(user, "swap", steps);
}

function swapIntent(user: string, sell: ResolvedAsset, buy: ResolvedAsset, amountIn: string, out: string, venue: string): Intent {
  return {
    kind: "swap",
    summary: `Swap ${fromStroops(amountIn, sell.decimals)} ${sell.code} for at least ${fromStroops(out, buy.decimals)} ${buy.code}`,
    spend: { [sell.contract]: amountIn },
    receive: { [buy.contract]: out },
    display: { venue, sell: sell.code, buy: buy.code, amountIn, minOut: out },
    to: user,
  };
}

registerBuilder("swap_sdex", async (user, spec) => {
  const sell = await resolveAsset(String(spec.sell));
  const buy = await resolveAsset(String(spec.buy));
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
  const intent = swapIntent(user, sell, buy, String(spec.amountIn), String(spec.minOut), VENUE_NAMES.sdex);
  intent.ops = ["pathPaymentStrictSend"];
  return { tx, intent };
});

registerBuilder("swap_soroswap", async (user, spec) => {
  const sell = await resolveAsset(String(spec.sell));
  const buy = await resolveAsset(String(spec.buy));
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
  const intent = swapIntent(user, sell, buy, String(spec.amountIn), String(spec.minOut), VENUE_NAMES.soroswap);
  intent.calls = [{ contract: router, fn: "swap_exact_tokens_for_tokens" }];
  return { tx, intent };
});

registerBuilder("swap_aquarius", async (user, spec) => {
  const sell = await resolveAsset(String(spec.sell));
  const buy = await resolveAsset(String(spec.buy));
  const router = env.network.contracts.aquariusRouter!;
  const chain = xdr.ScVal.fromXDR(String(spec.chainXdr), "base64");
  const acct = await requireAccount(user);
  const tx = await invoke(acct, router, "swap_chained", [sv.addr(user), chain, sv.addr(sell.contract), sv.u128(String(spec.amountIn)), sv.u128(String(spec.minOut))]);
  const intent = swapIntent(user, sell, buy, String(spec.amountIn), String(spec.minOut), VENUE_NAMES.aquarius);
  intent.calls = [{ contract: router, fn: "swap_chained" }];
  return { tx, intent };
});

