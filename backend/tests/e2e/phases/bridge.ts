// bridge: a quote, a burn on Stellar for Monad, and the Monad → Stellar steps.
import type { E2E } from "../lite_e2e.ts";

export default async function bridge({ api, ONE, runPlan }: E2E): Promise<string> {
  const q = await api("POST", "/bridge/quote", { direction: "stellar_to_monad", amount: (1n * ONE).toString() });
  const start = await api("POST", "/bridge/start", { direction: "stellar_to_monad", amount: "1000000", monadAddress: "0x000000000000000000000000000000000000dEaD" });
  const outs = await runPlan(start.plan);
  const r = outs[outs.length - 1];
  // The phone reports the burn's transaction hash (the fee-bump hash it got from /tx/submit; Iris indexes that one).
  const hash = r.hash as string;
  await api("POST", `/bridge/${start.transfer.id}/source`, { txHash: hash });
  const back = await api("POST", "/bridge/start", { direction: "monad_to_stellar", amount: "1000000", monadAddress: "0x000000000000000000000000000000000000dEaD" });
  return `quote ${q.route} eta ${q.etaSeconds}s; burned 0.1 USDC on Stellar for Monad (tx ${hash.slice(0, 10)}…, awaiting Iris); Monad→Stellar returns ${back.evmSteps.length} EVM steps`;
}
