// Swap aggregation (docs/DESIGN-stellar-parity.md §6.8): SDEX (Horizon path finding) and Soroswap (router) quote in
// parallel, and Aquarius (find-path API) where it is on (SWAP_VENUES); every venue's route that both verifiers would
// sign is kept with the quote, and /swap/build redeems the one the user picked, the best by default. The swap pays its user (`to` and the minimum out
// are bound, as WP-11's call rules check). Where activation is sponsored, a swap of a registry asset into XLM by an
// account with no XLM to spend is the account's one starter swap, which DyorHQ pays for (§4.3).
import { Address, Asset, Operation, xdr } from "@stellar/stellar-sdk";
import type { QuoteRoute, StarterSwapReason, SwapQuote, SwapRoute, SwapVenue } from "./contract.ts";
import { resolveAsset, ResolvedAsset } from "./assets.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { baseReserve, positionOf, starterSwapEligibility } from "./fees.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById, contractAllowlist } from "./networks.ts";
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

/** The venues a quote asks. Aquarius is off for now (decision O7, 2026-10-15: Soroswap only, so Aquarius isn't tested):
 *  no quote asks find-path, so no Aquarius route or price impact is ever offered. Its quote, impact and builder stay
 *  here for later. */
export const SWAP_VENUES: readonly Venue[] = ["sdex", "soroswap"];

/** Every path Horizon finds on the Stellar DEX from `sell` to `buy` for `amountIn`, with what it brings, the best first. */
async function sdexRoutes(sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<Route[]> {
  if (!sell.classic || !buy.classic) return [];
  try {
    const call = horizon().strictSendPaths(classicAsset(sell.classic), fromStroops(amountIn), [classicAsset(buy.classic)]);
    const res = await call.call();
    const toSpec = (p: any) => (p.asset_type === "native" ? "native" : `${p.asset_code}:${p.asset_issuer}`);
    return res.records
      .sort((a: any, b: any) => Number(b.destination_amount) - Number(a.destination_amount))
      .map((r: any): Route => {
        const [i, f = ""] = String(r.destination_amount).split(".");
        const out = BigInt(i) * 10_000_000n + BigInt((f + "0000000").slice(0, 7));
        return { venue: "sdex", amountOut: out.toString(), path: [sell.classic!, ...r.path.map(toSpec), buy.classic!] };
      });
  } catch {
    return [];
  }
}

async function quoteSdex(sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<Route | null> {
  return (await sdexRoutes(sell, buy, amountIn))[0] ?? null;
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

/** The tokens a route's contract call runs the code of, as both verifiers read them from the call (verify.ts
 *  routeListed, TxVerifier): a Soroswap path, or each hop's pool tokens and token out of an Aquarius chain; null for a
 *  chain that isn't (tokens, pool, token out) hops. None for the Stellar DEX: a path payment runs no token code. */
function routeTokens(route: Route): string[] | null {
  if (route.venue === "sdex") return [];
  if (route.venue === "soroswap") return route.path;
  try {
    const hops = xdr.ScVal.fromXDR(String(route.chainXdr), "base64").vec();
    if (!hops || hops.length === 0) return null;
    const tokens: string[] = [];
    for (const h of hops) {
      const hop = h.vec();
      const pool = hop?.length === 3 ? hop[0].vec() : null;
      if (!hop || !pool) return null;
      tokens.push(...pool.map((t) => Address.fromScAddress(t.address()).toString()), Address.fromScAddress(hop[2].address()).toString());
    }
    return tokens;
  } catch {
    return null;
  }
}

/** Whether both verifiers would sign `route`: every token it goes through is on the allowlist, but for the one sold and
 *  the one bought, the user's own choice. A route through any other token is never offered, since /swap/build would
 *  be refused for it (testnet's Aquarius routes XLM → USDC through AQUA and USDT). */
function signable(route: Route, sell: ResolvedAsset, buy: ResolvedAsset): boolean {
  const tokens = routeTokens(route);
  if (tokens === null) return false;
  const listed = new Set(Object.values(contractAllowlist(env.network)).flat());
  return tokens.every((t) => t === sell.contract || t === buy.contract || listed.has(t));
}

function pickBest(routes: Route[]): Route | null {
  const valid = routes.filter((r) => BigInt(r.amountOut) > 0n);
  if (valid.length === 0) return null;
  return valid.reduce((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? b : a));
}

/** What `route`'s venue brings for `amountIn` along the very same way: Soroswap's path, the Stellar DEX's path when
 *  Horizon still finds it, Aquarius's chain when find-path answers that amount with the same one. Null when the venue
 *  doesn't answer, or answers along another path or chain: that prices other pools, so it never stands in. */
async function venueOut(route: Route, sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<bigint | null> {
  switch (route.venue) {
    case "soroswap":
      return await soroswapOut(route.path, amountIn);
    case "sdex": {
      const same = (await sdexRoutes(sell, buy, amountIn)).find((r) => r.path.join() === route.path.join());
      return same ? BigInt(same.amountOut) : null;
    }
    case "aquarius": {
      const found = await quoteAquarius(sell, buy, amountIn);
      return found && found.chainXdr === route.chainXdr ? BigInt(found.amountOut) : null;
    }
  }
}

/** A route's price impact in basis points, for every venue as Monad works it out for its pools: how much worse the rate
 *  for `amountIn` is than the same path's rate for a thousandth of it. Null where the small trade rounds to nothing, or
 *  the venue doesn't answer it along that path (`venueOut`). */
async function priceImpact(route: Route, sell: ResolvedAsset, buy: ResolvedAsset, amountIn: bigint): Promise<number | null> {
  const small = amountIn / 1_000n;
  if (small === 0n) return null;
  const smallOut = await venueOut(route, sell, buy, small);
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

/** POST /v1/swap/quote: every route of `venues` (Swap's, SWAP_VENUES) for `amountIn` of `sellId`, the best first. */
export async function quote(user: string, sellId: string, buyId: string, amountIn: bigint, slippageBps: number,
  venues: readonly Venue[] = SWAP_VENUES): Promise<SwapQuote> {
  const sell = await resolveAsset(sellId);
  const buy = await resolveAsset(buyId);
  if (sell.contract === buy.contract) throw bad("same_asset", "Pick two different assets.");
  if (slippageBps < 1 || slippageBps > 1_000) throw bad("bad_slippage", "Slippage must be between 0.01% and 10%.");
  const ask = (venue: Venue, find: () => Promise<Route | null>) => (venues.includes(venue) ? find() : Promise.resolve(null));
  const [found, account] = await Promise.all([
    Promise.all([
      ask("sdex", () => quoteSdex(sell, buy, amountIn)),
      ask("soroswap", () => quoteSoroswap(sell, buy, amountIn)),
      ask("aquarius", () => quoteAquarius(sell, buy, amountIn)),
    ]),
    holder(user, buy),
  ]);
  const routes = found.filter((r): r is Route => r !== null && BigInt(r.amountOut) > 0n && signable(r, sell, buy));
  const best = pickBest(routes);
  if (!best) throw new ApiError(404, "no_route", `No route from ${sell.code} to ${buy.code} right now.`);
  const ranked = [best, ...routes.filter((r) => r !== best).sort((a, b) => (BigInt(b.amountOut) > BigInt(a.amountOut) ? 1 : -1))];
  const priced: PricedRoute[] = await Promise.all(ranked.map(async (r) => ({
    ...r,
    minOut: minOut(r.amountOut, slippageBps),
    priceImpactBps: await priceImpact(r, sell, buy, amountIn),
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

/** A swap step's label: the venue it goes through. */
function swapLabel(venue: Venue): string {
  return `Swap via ${VENUE_NAMES[venue]}`;
}

/** POST /v1/swap/build: the route of `venue` (the best when absent), after a user-paid trust step when the bought asset
 *  isn't enabled. A starter swap is marked for DyorHQ to pay, with its SDEX route to fall back on (§4.3), which the
 *  plan takes only if that route qualifies too (plans.ts). */
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
  // A swap always names a minimum above 0 (both verifiers refuse one of 0): an output that rounds to nothing is refused.
  if (!/^[0-9]+$/.test(String(route.minOut)) || BigInt(route.minOut) <= 0n) {
    throw bad("bad_amount", "This amount is too small to swap: the least it would bring rounds to 0.");
  }
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
    spec.fallback = sdex ? { label: swapLabel("sdex"), spec: swapSpec(req, sdex) } : null;
  }
  steps.push({ label: swapLabel(route.venue), spec });
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

