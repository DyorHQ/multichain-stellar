// bridge (docs/DESIGN-stellar-parity.md §6.10, §12.6): a quote's fee is Circle's, as Iris states it for a standard
// transfer, and its time is the median of the last completed transfers that way, or none with fewer than 3; a transfer
// from Monad takes at least 1 USDC and hands out Monad steps for the pinned USDC and TokenMessengerV2 only, and once a
// user's 10 relays of the day are reported the next one gets 429 (the 10 are seeded in the database and removed
// after: relaying real ones needs Monad testnet USDC); a burn on Stellar for Monad binds the Monad address (the
// driver's verifier holds it to the call, as the phone's does), goes through, and waits for Circle's attestation.
import { TESTNET } from "../../../supabase/functions/_shared/networks.ts";
import type { E2E } from "../lite_e2e.ts";

const DEAD = "0x000000000000000000000000000000000000dEaD";

/** The error message of a request that must be refused. */
async function refused(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (err) {
    return (err as Error).message;
  }
  throw new Error("expected a refusal");
}

export default async function bridge({ api, bal, db, ONE, runPlan, user }: E2E): Promise<string> {
  const me = user.publicKey();
  const monad = TESTNET.bridge.monad!;
  const cctp = TESTNET.contracts.cctp!;

  // Quotes: the fee from Iris's fee table, row finalityThreshold 2000; the time from the transfers that completed.
  const quotes: string[] = [];
  for (const [direction, amount, src, dst] of [["monad_to_stellar", 1_000_000n, monad.domain, cctp.domain], ["stellar_to_monad", 10n * ONE, cctp.domain, monad.domain]] as const) {
    const q = await api("POST", "/bridge/quote", { direction, amount: amount.toString() });
    const table = await (await fetch(`${TESTNET.apis.iris}/v2/burn/USDC/fees/${src}/${dst}`)).json();
    const [whole, frac = ""] = String(table.find((r: any) => r.finalityThreshold === 2000).minimumFee).split(".");
    const d = 10n ** BigInt(frac.length) * 10_000n;
    const fee = (amount * BigInt(whole + frac) + d - 1n) / d;
    if (q.route !== "cctp" || q.feeSource !== "circle-iris" || q.fee !== fee.toString()) throw new Error(`${direction} quote ${JSON.stringify(q)}: Iris says ${fee}`);
    const out = direction === "monad_to_stellar" ? (amount - fee) * 10n : (amount - fee) / 10n;
    if (q.amountOut !== out.toString()) throw new Error(`${direction} delivers ${q.amountOut}, not ${out}`);
    const [{ n }] = await db`select count(*)::int as n from (select 1 from lite.bridge_transfers where direction = ${direction} and route = 'cctp'
                                and status = 'completed' order by updated_at desc limit 20) recent`;
    if (q.etaBasis !== n || (n < 3) !== (q.etaSeconds === null)) throw new Error(`${direction} time ${q.etaSeconds} over ${q.etaBasis}, with ${n} completed`);
    quotes.push(`${direction} fee ${q.fee} (Iris), eta ${q.etaSeconds ?? "none"} over ${q.etaBasis}`);
  }

  // From Monad: at least 1 USDC, and the Monad steps go to the pinned contracts only.
  const small = await refused(api("POST", "/bridge/start", { direction: "monad_to_stellar", amount: "999999", monadAddress: DEAD }));
  if (!/→ 400 .*too_small/.test(small)) throw new Error(`under 1 USDC: ${small}`);
  const start = await api("POST", "/bridge/start", { direction: "monad_to_stellar", amount: "1000000", monadAddress: DEAD });
  const steps = start.evmSteps as { chainId: number; to: string; data: string }[];
  const shape = steps.map((s) => [s.chainId, s.to.toLowerCase(), s.data.slice(0, 10)].join(" "));
  const want = [`${monad.chainId} ${monad.usdc.toLowerCase()} 0x095ea7b3`, `${monad.chainId} ${monad.tokenMessenger.toLowerCase()} 0x779b432d`];
  if (shape.join() !== want.join()) throw new Error(`Monad steps ${JSON.stringify(shape)}`);
  if (!steps[1].data.includes(Buffer.from(me).toString("hex"))) throw new Error("the burn's hook doesn't carry the account");

  // The relay cap: with the day's 10 reported, the 11th transfer from Monad is refused before any Monad step.
  const [{ today }] = await db`select count(*)::int as today from lite.bridge_transfers where address = ${me} and relay_day = (now() at time zone 'utc')::date`;
  const seeded = await db`
    insert into lite.bridge_transfers (address, direction, route, amount, recipient, source_tx, status, relay_day)
    select ${me}, 'monad_to_stellar', 'cctp', 1000000, ${me}, '0x' || lpad(to_hex(i), 64, '0'), 'failed', (now() at time zone 'utc')::date
      from generate_series(1, ${10 - today}) i returning id`;
  let capped: string;
  try {
    capped = await refused(api("POST", "/bridge/start", { direction: "monad_to_stellar", amount: "1000000", monadAddress: DEAD }));
  } finally {
    await db`delete from lite.bridge_transfers where id = any(${seeded.map((r) => r.id as string)}::uuid[])`;
  }
  if (!/→ 429 .*bridge_relay_limit/.test(capped)) throw new Error(`the 11th relay: ${capped}`);

  // To Monad: 0.1 USDC, swapping some XLM first when the account holds less.
  const burn = ONE / 10n;
  if (bal(await api("GET", "/account"), "USDC") < burn) {
    const q = await api("POST", "/swap/quote", { sell: "XLM", buy: "USDC", amount: (20n * ONE).toString(), slippageBps: 300 });
    await runPlan(await api("POST", "/swap/build", { quoteId: q.quoteId }));
  }
  const out = await api("POST", "/bridge/start", { direction: "stellar_to_monad", amount: burn.toString(), monadAddress: DEAD });
  const sent = await runPlan(out.plan);
  // The phone reports the burn's transaction hash (the one /tx/submit answered; Iris indexes that one).
  const hash = sent[sent.length - 1].hash as string;
  const [logged] = await db`select intent from lite.tx_log where hash = ${hash}`;
  if (logged?.intent?.kind !== "bridge_out" || logged.intent.to !== DEAD) throw new Error(`the burn's intent ${JSON.stringify(logged?.intent)}`);
  await api("POST", `/bridge/${out.transfer.id}/source`, { txHash: hash });
  const status = await api("GET", `/bridge/${out.transfer.id}`);
  const [{ relay_day }] = await db`select relay_day from lite.bridge_transfers where id = ${out.transfer.id}`;
  if (status.status !== "attesting" || status.sourceTx !== hash || relay_day !== null) throw new Error(`after the burn: ${JSON.stringify(status)}, relay day ${relay_day}`);

  return `${quotes.join("; ")}; under 1 USDC refused; Monad steps to USDC and TokenMessengerV2 only; the 11th relay of the day refused (429); burned 0.1 USDC on Stellar for ${DEAD.slice(0, 6)}… (tx ${hash.slice(0, 10)}…, attesting)`;
}
