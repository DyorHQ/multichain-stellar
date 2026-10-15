// fees (docs/DESIGN-stellar-parity.md §4.5, §6.3, §6.4, §12.6): GET /v1/fees is public; Max sends the account's XLM to
// an address that doesn't exist yet, keeping back what XLMReserve's maxSend keeps (the payment's estimate × 5/4), and
// the user pays the fee; a swap is then refused before signing for its network fee (409 not_enough_xlm_for_fee); the
// testnet faucet restores the XLM (its fee is Friendbot's: `external`). The public account view answers any address
// with no token.
import { Keypair } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";
import { client, expectFeePaidBy, expectRefusal, logged, setUp } from "./auth.ts";

export default async function fees(t: E2E): Promise<string> {
  await setUp(t);
  const anonymous = client(t, null);
  const { call } = client(t, t.token);
  const user = t.user.publicKey();

  // GET /v1/fees: public and cached, an estimate for every step kind, none above the cap.
  const f = await anonymous.call("GET", "/fees");
  if (f.status !== 200 || f.headers.get("cache-control") !== "public, max-age=30") throw new Error(`GET /v1/fees: ${f.status} ${f.headers.get("cache-control")}`);
  const fees = f.body;
  const cap = BigInt(t.config.fees.maxFee);
  const kinds = Object.keys(fees.estimates);
  if (kinds.length < 18 || kinds.some((k) => BigInt(fees.estimates[k]) <= 0n || BigInt(fees.estimates[k]) > cap)) throw new Error(`estimates: ${JSON.stringify(fees.estimates)}`);
  if (BigInt(fees.baseReserve) <= 0n || BigInt(fees.inclusionFee.classic) < 100n) throw new Error(`fees: ${JSON.stringify(fees)}`);

  // Max: everything spendable but the payment's estimate × 5/4 (XLMReserve.maxSend), to an address that doesn't exist.
  const before = (await t.api("GET", "/account")).xlm;
  const keep = (BigInt(fees.estimates.payment) * 5n) / 4n;
  const max = BigInt(before.spendable) - keep;
  const to = Keypair.random().publicKey();
  const plan = await t.api("POST", "/send", { asset: "XLM", to, amount: max.toString() });
  const step = plan.steps[0];
  if (step.feePayer !== "user" || step.intent.to !== to || step.intent.ops?.[0] !== "createAccount") throw new Error(`the Max send: ${JSON.stringify(step).slice(0, 300)}`);
  const [sent] = await t.runPlan(plan);
  await expectFeePaidBy(t, sent.hash, user, BigInt(sent.feeCharged));
  const after = (await t.api("GET", "/account")).xlm;
  const left = BigInt(after.spendable);
  if (left !== BigInt(before.spendable) - max - BigInt(sent.feeCharged)) throw new Error(`after Max, ${left} spendable, expected ${BigInt(before.spendable) - max - BigInt(sent.feeCharged)}`);

  // A Soroban swap of less XLM than is left now costs more in fees than the account can spend: refused before anything
  // is signed.
  const q = await t.api("POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: (left / 2n).toString() });
  const soroban = q.routes.find((r: any) => r.venue !== "sdex");
  if (!soroban) throw new Error(`no Soroban route quoted: ${JSON.stringify(q.routes.map((r: any) => r.venue))}`);
  const refused = await call("POST", "/swap/build", { quoteId: q.quoteId, venue: soroban.venue });
  expectRefusal(refused, 409, "not_enough_xlm_for_fee", `a ${soroban.venue} swap with ${left} stroops spendable`);
  if (BigInt(refused.body.error.detail.spendable) !== left || BigInt(refused.body.error.detail.need) <= left) throw new Error(`the refusal's detail: ${JSON.stringify(refused.body.error.detail)}`);

  // The faucet restores it; its fee is Friendbot's account's.
  const faucet = await t.api("POST", "/account/faucet");
  const restored = (await t.api("GET", "/account")).xlm;
  if (BigInt(restored.balance) - BigInt(after.balance) < 9_999n * t.ONE) throw new Error(`the faucet added ${BigInt(restored.balance) - BigInt(after.balance)}`);
  if ((await logged(t, faucet.hash)).fee_payer !== "external") throw new Error("the faucet's row isn't paid by an external account");

  // The public view: any address, no token, the same shape; DyorHQ's own records left out.
  for (const address of [user, to]) {
    const v = await anonymous.call("GET", `/account?address=${address}`);
    if (v.status !== 200 || v.body.view !== "public" || v.headers.get("cache-control") !== "public, max-age=15") throw new Error(`public view of ${address}: ${v.status} ${JSON.stringify(v.body).slice(0, 200)}`);
    if (!v.body.exists || v.body.firstFunding.starterSwap !== null || v.body.firstFunding.faucet?.usedToday !== null) throw new Error(`public view of ${address}: ${JSON.stringify(v.body.firstFunding)}`);
  }
  expectRefusal(await anonymous.call("GET", "/account"), 400, "address_required", "GET /v1/account with neither a token nor ?address=");

  return `Max sent ${Number(max) / 1e7} XLM keeping ${keep} stroops (fee ${sent.feeCharged}, the user's); a ${soroban.venue} swap refused for its fee (${refused.body.error.detail.need} > ${left}); the faucet restored 10,000 XLM; public views served`;
}
