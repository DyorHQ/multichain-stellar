// fees (docs/DESIGN-stellar-parity.md §1.1 decision 7, §4.5, §6.3, §6.4, §12.6): GET /v1/fees is public; Max sends the
// account's XLM to an address that doesn't exist yet, keeping back what XLMReserve's maxSend keeps (the payment's
// estimate × 5/4), and the user pays the fee; a swap is then refused before signing for its network fee (409
// not_enough_xlm_for_fee). Friendbot's test XLM is one claim per address, ever: the account's activation by Friendbot
// was its claim, so the faucet refuses it (429 faucet_used), and the test's own Friendbot account restores its XLM. An
// account that existed before it signed in claims once (its fee is Friendbot's: `external`), then is refused too. The
// public account view answers any address with no token, the claim left null.
import { Horizon, Keypair, Operation, TransactionBuilder } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";
import { client, expectFeePaidBy, expectRefusal, logged, setUp, signIn } from "./auth.ts";

const FRIENDBOT = "https://friendbot.stellar.org";

/** An account Friendbot funds outside DyorHQ, as a wallet made elsewhere is. */
async function friendbotAccount(): Promise<Keypair> {
  const kp = Keypair.random();
  const res = await fetch(`${FRIENDBOT}?addr=${kp.publicKey()}`);
  if (!res.ok) throw new Error(`Friendbot: ${res.status}`);
  await res.body?.cancel();
  return kp;
}

/** Gives `to` Friendbot's grant through an account of the test's own, merged into it: not DyorHQ's faucet. */
async function topUp(t: E2E, to: string): Promise<void> {
  const funder = await friendbotAccount();
  const horizon = new Horizon.Server(t.config.horizonUrl);
  const tx = new TransactionBuilder(await horizon.loadAccount(funder.publicKey()), { fee: "1000", networkPassphrase: t.config.passphrase })
    .addOperation(Operation.accountMerge({ destination: to }))
    .setTimeout(60)
    .build();
  tx.sign(funder);
  await horizon.submitTransaction(tx);
}

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

  // Friendbot's activation was this address's one claim: the faucet refuses it, and the test restores the XLM itself.
  const funding = (await t.api("GET", "/account")).firstFunding;
  if (funding.faucet?.claimed !== true) throw new Error(`after Friendbot's activation: ${JSON.stringify(funding)}`);
  const again = await call("POST", "/account/faucet");
  expectRefusal(again, 429, "faucet_used", "the faucet after Friendbot's activation");
  if (again.body.error.message !== "You already claimed your test XLM.") throw new Error(`faucet_used says ${JSON.stringify(again.body.error.message)}`);
  await topUp(t, user);
  const restored = (await t.api("GET", "/account")).xlm;
  if (BigInt(restored.balance) - BigInt(after.balance) < 9_999n * t.ONE) throw new Error(`the top-up added ${BigInt(restored.balance) - BigInt(after.balance)}`);

  // An account that existed before it signed in (an imported wallet) and never claimed: one claim, Friendbot's fee.
  const imported = await friendbotAccount();
  const other = client(t, await signIn(t, imported));
  const fresh = await other.api("GET", "/account");
  if (fresh.firstFunding.faucet?.claimed !== false) throw new Error(`an imported account before its claim: ${JSON.stringify(fresh.firstFunding)}`);
  const faucet = await other.api("POST", "/account/faucet");
  const claimed = await other.api("GET", "/account");
  if (BigInt(claimed.xlm.balance) - BigInt(fresh.xlm.balance) < 9_999n * t.ONE) throw new Error(`the faucet added ${BigInt(claimed.xlm.balance) - BigInt(fresh.xlm.balance)}`);
  if ((await logged(t, faucet.hash)).fee_payer !== "external") throw new Error("the faucet's row isn't paid by an external account");
  if (claimed.firstFunding.faucet?.claimed !== true) throw new Error(`an imported account after its claim: ${JSON.stringify(claimed.firstFunding)}`);
  expectRefusal(await other.call("POST", "/account/faucet"), 429, "faucet_used", "a second claim");

  // The public view: any address, no token, the same shape; DyorHQ's own records left out.
  for (const address of [user, to]) {
    const v = await anonymous.call("GET", `/account?address=${address}`);
    if (v.status !== 200 || v.body.view !== "public" || v.headers.get("cache-control") !== "public, max-age=15") throw new Error(`public view of ${address}: ${v.status} ${JSON.stringify(v.body).slice(0, 200)}`);
    if (!v.body.exists || v.body.firstFunding.starterSwap !== null || v.body.firstFunding.faucet?.claimed !== null) throw new Error(`public view of ${address}: ${JSON.stringify(v.body.firstFunding)}`);
  }
  expectRefusal(await anonymous.call("GET", "/account"), 400, "address_required", "GET /v1/account with neither a token nor ?address=");

  return `Max sent ${Number(max) / 1e7} XLM keeping ${keep} stroops (fee ${sent.feeCharged}, the user's); a ${soroban.venue} swap refused for its fee (${refused.body.error.detail.need} > ${left}); the activation was the claim (faucet_used); an imported account claimed 10,000 XLM once; public views served`;
}
