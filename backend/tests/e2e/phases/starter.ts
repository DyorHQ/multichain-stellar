// starter (docs/DESIGN-stellar-parity.md §4.3, §12.6), on a stack started with --activation sponsored
// (LITE_ACTIVATION=sponsored, the mainnet rehearsal): DyorHQ sets an account up with 0 XLM (feePayer sponsor,
// sponsorReason setup; Horizon's fee account the sponsor; the sponsorship settled `success`). A USDC → XLM swap is then
// the account's one starter swap, which DyorHQ pays for (the sponsor fee-bumps it: tx_log.fee_payer sponsor, the
// sponsorship `success`); the next swap is the user's own (has_xlm); drained of XLM again, a third gets no sponsorship
// (used) and is refused before signing (not_enough_xlm_for_fee). The phase signs in an account of its own; elsewhere it
// is skipped.
import { Asset, Horizon, Keypair, Operation, TransactionBuilder } from "@stellar/stellar-sdk";
import type { E2E } from "../lite_e2e.ts";
import { client, expectFeePaidBy, expectRefusal, logged, runAs, signIn } from "./auth.ts";

const FRIENDBOT = "https://friendbot.stellar.org";

/** Pays `amount` of the classic asset `spec` (CODE:ISSUER) to `to` from a Friendbot-funded account of the test's, which
 *  buys it with XLM on the SDEX on the way. */
async function deliver(t: E2E, to: string, spec: string, amount: string): Promise<void> {
  const funder = Keypair.random();
  const res = await fetch(`${FRIENDBOT}?addr=${funder.publicKey()}`);
  if (!res.ok) throw new Error(`Friendbot: ${res.status}`);
  await res.body?.cancel();
  const horizon = new Horizon.Server(t.config.horizonUrl);
  const [code, issuer] = spec.split(":");
  const tx = new TransactionBuilder(await horizon.loadAccount(funder.publicKey()), { fee: "1000", networkPassphrase: t.config.passphrase })
    .addOperation(Operation.pathPaymentStrictReceive({ sendAsset: Asset.native(), sendMax: "1000", destination: to, destAsset: new Asset(code, issuer), destAmount: amount, path: [] }))
    .setTimeout(60)
    .build();
  tx.sign(funder);
  await horizon.submitTransaction(tx);
}

export default async function starter(t: E2E): Promise<string | null> {
  t.config ??= await client(t, null).api("GET", "/config");
  if (t.config.activation !== "sponsored") return null;
  const kp = Keypair.random();
  const address = kp.publicKey();
  const token = await signIn(t, kp);
  // Sponsorships are capped per IP and day, and the API takes the IP Cloudflare gives it (http.ts clientIp). The local
  // stack has no Cloudflare in front, so the run sets that header itself: a TEST-NET-2 address of its own (RFC 5737),
  // and earlier runs on the same stack don't use up its cap.
  const from = { "cf-connecting-ip": `198.51.100.${1 + Math.floor(Math.random() * 254)}` };
  const { api, call } = client(t, token, from);
  const run = (plan: any) => runAs(t, kp, token, plan, [], from);
  const sponsor = t.config.sponsor;
  const sponsorships = (kind: string) => t.db`select status, fee_charged from lite.sponsorships where address = ${address} and kind = ${kind} order by created_at`;

  // 1. Setup, paid by DyorHQ.
  const act = await api("POST", "/account/activate");
  const setup = act.steps?.[0];
  if (setup?.stepKind !== "activate" || setup.feePayer !== "sponsor" || setup.sponsorReason !== "setup" || act.fees.userMax !== "0" || !act.fees.sponsored) {
    throw new Error(`the setup plan: ${JSON.stringify(act).slice(0, 400)}`);
  }
  const [created] = await run(act);
  await expectFeePaidBy(t, created.hash, sponsor, BigInt(created.feeCharged));
  if (created.feePayer !== "sponsor" || (await logged(t, created.hash)).fee_payer !== "sponsor") throw new Error("the setup isn't logged as the sponsor's");
  const [setupRow] = await sponsorships("activate");
  if (setupRow?.status !== "success") throw new Error(`the setup's sponsorship: ${JSON.stringify(setupRow)}`);
  const fresh = await api("GET", "/account");
  if (fresh.xlm.spendable !== "0" || fresh.reserves.sponsoredByDyorHQ !== 3 || fresh.firstFunding.starterSwap !== "available") {
    throw new Error(`the new account: ${JSON.stringify({ xlm: fresh.xlm, reserves: fresh.reserves, firstFunding: fresh.firstFunding })}`);
  }
  const again = await api("POST", "/account/activate");
  if (again.status !== "active") throw new Error(`a second setup: ${JSON.stringify(again).slice(0, 200)}`);

  // 2. USDC arrives; selling some for XLM is the starter swap, which DyorHQ pays for.
  const usdc = t.config.assets.find((a: any) => a.id === "USDC");
  await deliver(t, address, usdc.classic, "3");
  // Quoted, then built through the SDEX route when there is one: testnet's AMM quote APIs can trail their pools.
  const swap = async (amount: string, expected: { eligible: boolean; reason: string | null }) => {
    const q = await api("POST", "/swap/quote", { sell: "USDC", buy: "XLM", amount, slippageBps: 300 });
    if (JSON.stringify(q.starterSwap) !== JSON.stringify(expected)) throw new Error(`starterSwap ${JSON.stringify(q.starterSwap)}, expected ${JSON.stringify(expected)}`);
    return { quoteId: q.quoteId, ...(q.routes.some((r: any) => r.venue === "sdex") ? { venue: "sdex" } : {}) };
  };
  const plan1 = await api("POST", "/swap/build", await swap("10000000", { eligible: true, reason: null }));
  const s1 = plan1.steps[0];
  if (s1.feePayer !== "sponsor" || s1.sponsorReason !== "starter_swap" || BigInt(s1.maxFee) > BigInt(t.config.fees.starterInnerFeeMax) || plan1.fees.userMax !== "0") {
    throw new Error(`the starter step: ${JSON.stringify({ ...s1, xdr: undefined, intent: undefined })}`);
  }
  const [first] = await run(plan1);
  await expectFeePaidBy(t, first.hash, sponsor, BigInt(first.feeCharged));
  const firstRow = await logged(t, first.hash);
  if (first.feePayer !== "sponsor" || firstRow.fee_payer !== "sponsor" || !first.result?.amountOut) throw new Error(`the starter swap: ${JSON.stringify(first)} ${JSON.stringify(firstRow)}`);
  const starters = await sponsorships("starter");
  if (starters.length !== 1 || starters[0].status !== "success" || String(starters[0].fee_charged) !== first.feeCharged) throw new Error(`the starter's sponsorship: ${JSON.stringify(starters)}`);

  // 3. With XLM to spend, the next swap is the user's own.
  const plan2 = await api("POST", "/swap/build", await swap("5000000", { eligible: false, reason: "has_xlm" }));
  if (plan2.steps[0].feePayer !== "user") throw new Error("the second swap isn't user-paid");
  const [second] = await run(plan2);
  await expectFeePaidBy(t, second.hash, address, BigInt(second.feeCharged));

  // 4. Drained of XLM again (Max to a new account, then the rest), a third gets no sponsorship and is refused.
  const fees = await client(t, null).api("GET", "/fees");
  let xlm = (await api("GET", "/account")).xlm;
  const away = Keypair.random().publicKey();
  const keep = (BigInt(fees.estimates.payment) * 5n) / 4n;
  await run(await api("POST", "/send", { asset: "XLM", to: away, amount: (BigInt(xlm.spendable) - keep).toString() }));
  xlm = (await api("GET", "/account")).xlm;
  const rest = BigInt(xlm.spendable) - BigInt(fees.inclusionFee.classic);
  if (rest > 0n) await run(await api("POST", "/send", { asset: "XLM", to: away, amount: rest.toString() }));
  xlm = (await api("GET", "/account")).xlm;
  const third = await call("POST", "/swap/build", await swap("10000000", { eligible: false, reason: "used" }));
  expectRefusal(third, 409, "not_enough_xlm_for_fee", `a third swap with ${xlm.spendable} stroops spendable`);
  if ((await sponsorships("starter")).length !== 1) throw new Error("a second starter sponsorship was reserved");

  return `setup paid by DyorHQ (fee ${created.feeCharged}); the starter swap sponsored once (fee ${first.feeCharged}, sponsorship success); the second user-paid; drained to ${xlm.spendable} stroops, a third refused (used, not_enough_xlm_for_fee)`;
}
