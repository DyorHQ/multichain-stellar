// send (docs/DESIGN-stellar-parity.md §5.2, §6.4, §6.8, §12.6): XLM that creates an account, then XLM to it again, each
// with a memo the intent binds and Horizon shows, each paid by the user; the recipient check; USDC to that account
// refused before signing (no trustline: recipient_no_trust), and to an account that doesn't exist (recipient_missing);
// a muxed (M…) address refused (muxed_unsupported).
import { Keypair, MuxedAccount, Account } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";
import { client, expectFeePaidBy, expectRefusal, horizonTx, logged, setUp } from "./auth.ts";

export default async function send(t: E2E): Promise<string> {
  await setUp(t);
  const { api, ONE, runPlan } = t;
  const { call } = client(t, t.token);
  const user = t.user.publicKey();
  const to = Keypair.random().publicKey();

  const sends: [string, Record<string, unknown>, { type: string; value: string }][] = [
    ["creates the account", { asset: "XLM", to, amount: (5n * ONE).toString(), memo: "e2e create" }, { type: "text", value: "e2e create" }],
    ["pays it again", { asset: "XLM", to, amount: ONE.toString(), memo: "42", memoType: "id" }, { type: "id", value: "42" }],
  ];
  for (const [what, body, memo] of sends) {
    const plan = await api("POST", "/send", body);
    const intent = plan.steps[0].intent;
    if (intent.to !== to || JSON.stringify(intent.memo) !== JSON.stringify(memo)) throw new Error(`the send that ${what} binds ${intent.to} ${JSON.stringify(intent.memo)}`);
    const [status] = await runPlan(plan);
    await expectFeePaidBy(t, status.hash, user, BigInt(status.feeCharged));
    const h = await horizonTx(t, status.hash);
    if (h.memoType !== memo.type || h.memo !== memo.value) throw new Error(`the send that ${what} carries ${h.memoType} ${h.memo}`);
    const row = await logged(t, status.hash);
    if (row.fee_payer !== "user" || row.step_kind !== "payment" || row.section !== "spot") throw new Error(`the send's log row: ${JSON.stringify(row)}`);
  }

  // The recipient check, then the sends it predicts.
  const r = await api("GET", `/recipient/${to}?asset=USDC`);
  if (JSON.stringify(r) !== JSON.stringify({ kind: "account", exists: true, trusts: false })) throw new Error(`recipient: ${JSON.stringify(r)}`);
  if ((await api("GET", `/recipient/${to}?asset=XLM`)).trusts !== null) throw new Error("recipient: XLM needs no trustline");
  expectRefusal(await call("POST", "/send", { asset: "USDC", to, amount: "100000" }), 409, "recipient_no_trust", "USDC to an account without a USDC trustline");
  const missing = Keypair.random().publicKey();
  expectRefusal(await call("POST", "/send", { asset: "USDC", to: missing, amount: "100000" }), 409, "recipient_missing", "USDC to an account that doesn't exist");
  const muxed = new MuxedAccount(new Account(to, "0"), "7").accountId();
  expectRefusal(await call("POST", "/send", { asset: "XLM", to: muxed, amount: ONE.toString() }), 400, "muxed_unsupported", "a send to an M… address");
  expectRefusal(await call("GET", `/recipient/${muxed}`), 400, "muxed_unsupported", "the recipient check of an M… address");
  return "created an account with 5 XLM (text memo), sent 1 more (id memo), both bound and paid by the user; USDC refused before signing without a trustline and to a missing account; M… refused";
}
