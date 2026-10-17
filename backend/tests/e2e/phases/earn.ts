// earn (docs/DESIGN-stellar-parity.md §6.10, §12.6), after the auth phase:
// - Blend's markets answer with no token, cached 30 s: XLM and Blend's test USDC, each with its pool status and Blend's
//   rates as fractions, its USD figures at the reference price of /v1/markets (Blend's test USDC at USDC's), or all
//   null without one;
// - the account's first deposit (100 XLM) declares a network fee within the 3 XLM cap, and is charged no more;
// - the owner's positions record it, then a withdrawal of 40 XLM: deposited, withdrawn, and earned = supplied +
//   withdrawn − deposited, at least 0 and complete;
// - the public view of the account (?address=, no token) shows the position with DyorHQ's record null, cached 15 s;
// - a snapshot run (the indexer's earn job, run here: a package's stack has no indexer loop) fills the market's week
//   and month of rate history, which answers with no token;
// - a withdrawal of everything, asked for the supplied figure just read as the app's Withdraw asks for it, declares at
//   least that figure and leaves nothing in the pool, though interest grew the position since; then a 10 XLM deposit
//   leaves a position for the phases after this one.
import { Transaction, TransactionBuilder } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";

/** Blend rounds a deposit's worth down by up to a stroop, and interest makes that up within seconds at testnet's rates:
 *  positions are read again for up to this long until earned is at least 0. */
const EARNED_WAIT_MS = 30_000;
/** The API keeps reference prices 15 s per isolate: a read made just before the refprices job may still be served. */
const READ_CACHE_MS = 15_000;
/** The newest history point is the snapshot just taken. */
const SNAPSHOT_SLACK_MS = 10 * 60_000;

interface Answer {
  status: number;
  body: any;
  cache: string | null;
}

export default async function earn(t: E2E): Promise<string> {
  if (!t.token) throw new Error("no session: run the auth phase first");
  const { API, ONE, api, runPlan, user } = t;
  const address = user.publicKey();
  const cap = BigInt(t.config.fees.maxFee);
  const xlm = (n: bigint) => `${(Number(n) / Number(ONE)).toFixed(7).replace(/\.?0+$/, "")} XLM`;

  /** A request with no token: the answer whatever its status. */
  async function open(path: string): Promise<Answer> {
    const res = await fetch(`${API}/v1${path}`);
    return { status: res.status, body: await res.json(), cache: res.headers.get("cache-control") };
  }
  function expect(a: Answer, status: number, cache: string | null, what: string): any {
    if (a.status !== status || (cache !== null && a.cache !== cache)) {
      throw new Error(`${what}: ${a.status} cache-control ${a.cache} ${JSON.stringify(a.body?.error ?? a.body).slice(0, 300)}`);
    }
    return a.body;
  }

  // 1. Markets, with no token, priced as /v1/markets prices their reference assets.
  const { refprices } = await import("../../../supabase/functions/lite-indexer/jobs/refprices.ts");
  await refprices();
  const registry = new Map((t.config.assets as any[]).map((a) => [a.contract as string, a]));
  async function priced(): Promise<{ markets: any[]; mismatch: string | null }> {
    const m = expect(await open("/earn/markets"), 200, "public, max-age=30", "GET /earn/markets");
    const refs = new Map((expect(await open("/markets"), 200, null, "GET /markets").rows as any[]).map((r) => [r.id as string, r.priceUsd]));
    const off = (m.markets as any[]).find((r) => r.priceUsd !== (refs.get(registry.get(r.asset)?.priceRef) ?? null));
    return { markets: m.markets, mismatch: off ? `${off.code}: ${off.priceUsd}, reference ${refs.get(registry.get(off.asset)?.priceRef)}` : null };
  }
  let read = await priced();
  if (read.mismatch) {
    await new Promise((r) => setTimeout(r, READ_CACHE_MS + 1_000));
    read = await priced();
  }
  if (read.mismatch) throw new Error(`an Earn market isn't priced at its reference: ${read.mismatch}`);
  const ids = read.markets.map((r: any) => registry.get(r.asset)?.id);
  if (!ids.includes("XLM") || !ids.includes("BUSDC") || ids.some((id: unknown) => id === undefined)) throw new Error(`markets: ${JSON.stringify(ids)}`);
  for (const r of read.markets) {
    const fractions = [r.supplyApy, r.borrowApy].every((v) => typeof v === "number" && v >= 0) && r.utilization >= 0 && r.utilization <= 1;
    const usd = r.priceUsd === null
      ? r.totalSuppliedUsd === null && r.freeLiquidityUsd === null
      : r.priceUsd > 0 && r.totalSuppliedUsd >= 0 && r.freeLiquidityUsd >= 0 && r.freeLiquidityUsd <= r.totalSuppliedUsd;
    if (!["active", "on_ice", "frozen"].includes(r.poolStatus) || !fractions || !(r.totalSupplied > 0) || !usd) {
      throw new Error(`market ${r.code}: ${JSON.stringify(r)}`);
    }
  }
  const market = read.markets.find((r: any) => registry.get(r.asset)?.id === "XLM");
  if (market.poolStatus === "frozen") throw new Error(`${market.poolName} is frozen: Blend takes no deposits`);

  // 2. The first deposit: its declared fee within the cap, and its charge no more.
  const deposited = 100n * ONE;
  const dep = await api("POST", "/earn/build", { action: "deposit", pool: market.pool, asset: market.asset, amount: deposited.toString() });
  const step = dep.steps.find((s: any) => s.intent?.kind === "earn_deposit");
  if (!step?.xdr) throw new Error(`deposit plan: ${JSON.stringify(dep.steps.map((s: any) => [s.label, s.status]))}`);
  const declared = BigInt((TransactionBuilder.fromXDR(step.xdr, t.config.passphrase) as Transaction).fee);
  if (declared > cap) throw new Error(`the first deposit declares ${xlm(declared)}, above the ${xlm(cap)} cap`);
  if (step.maxFee !== undefined && BigInt(step.maxFee) !== declared) throw new Error(`the step says ${step.maxFee}, the transaction declares ${declared}`);
  const sent = await runPlan(dep);
  const charged = await feeCharged(t, sent[sent.length - 1].hash);
  if (charged > declared) throw new Error(`the first deposit was charged ${xlm(charged)}, more than it declared (${xlm(declared)})`);

  // 3. Positions: what was deposited, then withdrawn; earned = supplied + withdrawn − deposited, at least 0.
  async function position(withdrawn: bigint): Promise<any> {
    const until = Date.now() + EARNED_WAIT_MS;
    for (;;) {
      const p = await api("GET", "/earn/positions");
      const row = p.positions.find((r: any) => r.pool === market.pool && r.asset === market.asset);
      if (p.view !== "owner" || !row) throw new Error(`positions: ${JSON.stringify(p)}`);
      const consistent = BigInt(row.supplied) + BigInt(row.withdrawn) - BigInt(row.deposited) === BigInt(row.earned);
      if (row.deposited !== deposited.toString() || row.withdrawn !== withdrawn.toString() || row.earnedComplete !== true || !consistent) {
        throw new Error(`position: ${JSON.stringify(row)}`);
      }
      if (BigInt(row.earned) >= 0n) return row;
      if (Date.now() > until) throw new Error(`earned is ${row.earned} stroops ${EARNED_WAIT_MS / 1000} s after the deposit: ${JSON.stringify(row)}`);
      await new Promise((r) => setTimeout(r, 5_000));
    }
  }
  const afterDeposit = await position(0n);
  if (BigInt(afterDeposit.supplied) < deposited) throw new Error(`supplied ${afterDeposit.supplied} after depositing ${deposited}`);

  const withdrawn = 40n * ONE;
  const wd = await api("POST", "/earn/build", { action: "withdraw", pool: market.pool, asset: market.asset, amount: withdrawn.toString() });
  await runPlan(wd);
  const afterWithdrawal = await position(withdrawn);

  // 4. The public view: the position, with DyorHQ's record null.
  const pub = expect(await open(`/earn/positions?address=${address}`), 200, "public, max-age=15", "the public view of /earn/positions");
  const seen = pub.positions.find((r: any) => r.pool === market.pool && r.asset === market.asset);
  if (pub.view !== "public" || !seen || !(BigInt(seen.supplied) > 0n) || seen.deposited !== null || seen.withdrawn !== null || seen.earned !== null || seen.earnedComplete !== false) {
    throw new Error(`the public view: ${JSON.stringify(pub)}`);
  }
  const anyone = await open("/earn/positions");
  if (anyone.status !== 400 || anyone.body.error?.code !== "address_required") throw new Error(`/earn/positions with neither a token nor ?address=: ${anyone.status}`);

  // 5. A snapshot run fills the history, which answers with no token.
  const { earn: snapshot } = await import("../../../supabase/functions/lite-indexer/jobs/earn.ts");
  const run = await snapshot() as { markets?: number; skipped?: string; errors?: string[] };
  if (run.skipped || run.errors || !(run.markets! >= read.markets.length)) throw new Error(`the earn job: ${JSON.stringify(run)}`);
  const counts: string[] = [];
  for (const range of ["week", "month"]) {
    const h = expect(await open(`/earn/history?pool=${market.pool}&asset=${market.asset}&range=${range}`), 200, "public, max-age=30", `${range}'s history`);
    const points = h.points as { t: string; supplyApy: number; utilization: number }[];
    const newest = points.length ? Date.parse(points[points.length - 1].t) : 0;
    if (points.length === 0 || Date.now() - newest > SNAPSHOT_SLACK_MS) throw new Error(`${range}'s history: ${JSON.stringify(points.slice(-3))}`);
    if (points.some((p, i) => !(p.supplyApy >= 0) || !(p.utilization >= 0 && p.utilization <= 1) || (i > 0 && p.t <= points[i - 1].t))) {
      throw new Error(`${range}'s history: points out of order or out of range`);
    }
    counts.push(`${range} ${points.length}`);
  }
  const bad = await open(`/earn/history?pool=${market.pool}&asset=${market.asset}&range=day`);
  if (bad.status !== 400 || bad.body.error?.code !== "bad_range") throw new Error(`history for a day: ${bad.status}`);

  // 6. Everything back: what the screen showed, and the interest earned since, with no dust left in the pool.
  const shown = (await position(withdrawn)).supplied;
  const everything = await api("POST", "/earn/build", { action: "withdraw", pool: market.pool, asset: market.asset, amount: shown, all: true });
  const declaredAll = BigInt(everything.steps[everything.steps.length - 1].intent?.receive?.[market.asset] ?? "0");
  if (declaredAll < BigInt(shown)) throw new Error(`a withdrawal of everything declares ${declaredAll}, less than the ${shown} shown`);
  await runPlan(everything);
  const left = (await api("GET", "/earn/positions")).positions.find((r: any) => r.pool === market.pool && r.asset === market.asset);
  if (left) throw new Error(`a withdrawal of everything left ${left.supplied} stroops in the pool: ${JSON.stringify(left)}`);
  const again = await api("POST", "/earn/build", { action: "deposit", pool: market.pool, asset: market.asset, amount: (10n * ONE).toString() });
  await runPlan(again);

  return `${market.poolName} ${market.poolStatus}, XLM supply APY ${(market.supplyApy * 100).toFixed(2)}% (testnet); ` +
    `first deposit of 100 XLM declared ${xlm(declared)} and was charged ${xlm(charged)} (cap ${xlm(cap)}); ` +
    `earned ${afterDeposit.earned} stroops, then ${afterWithdrawal.earned} after withdrawing 40; history points ${counts.join(", ")}; ` +
    `everything back (${shown} shown, ${declaredAll} declared), nothing left, then 10 XLM supplied again`;
}

/** The fee Horizon charged for a transaction (it may trail RPC by a few seconds). */
async function feeCharged(t: E2E, hash: string): Promise<bigint> {
  for (let i = 0; i < 20; i++) {
    const res = await fetch(`${t.config.horizonUrl}/transactions/${hash}`);
    if (res.ok) return BigInt((await res.json()).fee_charged);
    await res.body?.cancel();
    await new Promise((r) => setTimeout(r, 1_500));
  }
  throw new Error(`Horizon doesn't know ${hash}`);
}
