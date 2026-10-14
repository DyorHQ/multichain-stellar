// send: XLM that creates an account, XLM to it again, and USDC to it refused before signing.
import { Keypair } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";

export default async function send(t: E2E): Promise<string> {
  const { API, api, ONE, runPlan } = t;
  const to = Keypair.random().publicKey();
  await runPlan(await api("POST", "/send", { asset: "XLM", to, amount: (5n * ONE).toString() })); // creates the account
  await runPlan(await api("POST", "/send", { asset: "XLM", to, amount: (1n * ONE).toString() }));
  const r = await fetch(`${API}/v1/send`, { method: "POST", headers: { authorization: `Bearer ${t.token}` }, body: JSON.stringify({ asset: "USDC", to, amount: "100000" }) });
  const body = await r.json();
  if (body.error?.code !== "recipient_cannot_receive") throw new Error(`expected recipient_cannot_receive, got ${JSON.stringify(body)}`);
  return "created a new account with 5 XLM, sent 1 more; USDC to an account without a trustline refused before signing";
}
