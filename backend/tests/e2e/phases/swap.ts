// swap (docs/DESIGN-stellar-parity.md §6.8, §6.11, §12.6): a quote keeps every venue's route (one marked best), says
// what needs enabling and that testnet has no starter swap; 50 XLM for USDC through the best route, then a little
// through another venue picked by name, each paid by the user, each settled with what it delivered (result.amountOut,
// at least the quote's minimum) in the API's answer and its log row.
import type { E2E } from "../lite_e2e.ts";
import { expectFeePaidBy, logged, setUp } from "./auth.ts";

export default async function swap(t: E2E): Promise<string> {
  await setUp(t);
  const { api, bal, ONE, runPlan } = t;
  const user = t.user.publicKey();

  async function swapVia(amount: bigint, venue?: string) {
    const q = await api("POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: amount.toString(), slippageBps: 300 });
    const best = q.routes.filter((r: any) => r.best);
    if (best.length !== 1 || !q.routes[0].best) throw new Error(`routes: ${JSON.stringify(q.routes)}`);
    if (q.best.venue !== best[0].venue || q.best.minOut !== best[0].minOut) throw new Error("the legacy best isn't the best route");
    if (JSON.stringify(q.needsEnable) !== "[]" || q.starterSwap?.eligible !== false || q.starterSwap?.reason !== "activation") {
      throw new Error(`needsEnable ${JSON.stringify(q.needsEnable)}, starterSwap ${JSON.stringify(q.starterSwap)}`);
    }
    const route = venue ? q.routes.find((r: any) => r.venue === venue) : best[0];
    const plan = await api("POST", "/swap/build", { quoteId: q.quoteId, ...(venue ? { venue } : {}) });
    const step = plan.steps[plan.steps.length - 1];
    if (step.stepKind !== `swap_${route.venue}` || step.feePayer !== "user" || step.intent.to !== user) throw new Error(`the swap step: ${JSON.stringify(step).slice(0, 300)}`);
    const before = await api("GET", "/account");
    const [status] = await runPlan(plan);
    const after = await api("GET", "/account");
    const out = status.result?.amountOut;
    if (status.feePayer !== "user" || !out || BigInt(out) < BigInt(route.minOut)) throw new Error(`the swap's status: ${JSON.stringify(status)}`);
    if (bal(after, "USDC") - bal(before, "USDC") !== BigInt(out)) throw new Error(`USDC rose by ${bal(after, "USDC") - bal(before, "USDC")}, amountOut says ${out}`);
    await expectFeePaidBy(t, status.hash, user, BigInt(status.feeCharged));
    const row = await logged(t, status.hash);
    if (row.fee_payer !== "user" || row.step_kind !== `swap_${route.venue}` || row.section !== "spot" || row.result?.amountOut !== out) throw new Error(`the swap's log row: ${JSON.stringify(row)}`);
    return { q, route, out };
  }

  const first = await swapVia(50n * ONE);
  const other = first.q.routes.find((r: any) => !r.best);
  const second = other ? await swapVia(5n * ONE, other.venue) : null;
  const quotes = first.q.routes.map((r: any) => `${r.venue}:${(Number(r.amountOut) / 1e7).toFixed(2)}`).join(" ");
  return `50 XLM → ${(Number(first.out) / 1e7).toFixed(4)} USDC via ${first.route.venue} (quotes ${quotes})` +
    (second ? `; 5 XLM → ${(Number(second.out) / 1e7).toFixed(4)} USDC via ${second.route.venue}, picked by name` : "; one venue quoted") +
    "; each paid by the user, amountOut in the status and the log";
}
