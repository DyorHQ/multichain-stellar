// Friendbot's test XLM is one claim per Stellar address, ever (docs/DESIGN-stellar-parity.md §1.1 decision 7, §4.1,
// §6.4): the truth table. A new account's activation by Friendbot is its claim, logged as a faucet row; a second
// activate call funds nothing; an account that existed before claims once through POST /v1/account/faucet, then 429
// faucet_used; two claims at once claim once; a merge the network refused leaves the claim to make. GET /v1/account
// answers firstFunding.faucet {amount, claimed} to the owner, and claimed null in the public view. Friendbot, Horizon,
// RPC and the database are stand-ins that keep their own ledger.
import { Keypair, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { signJwt } = await import("../../supabase/functions/_shared/auth.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const PASS = TESTNET.passphrase;
const GRANT = 100_000_000_000n; // Friendbot's 10,000 XLM, in stroops
const FRIENDBOT_HASH = "f0".repeat(32);
const CREATION_HASH = "c1".repeat(32);

// ------------------------------------------------------------------------------------------------ the world

/** The ledger: each account's XLM, in stroops. */
const ledger = new Map<string, bigint>();
/** Whom Friendbot was asked to fund, in order. */
let friendbotAsked: string[] = [];
/** How Friendbot answers a funding: Horizon's whole transaction record, its hash alone, or text that isn't either. */
let friendbotAnswers: "record" | "hash" | "text" = "record";
/** How many more times Horizon answers an account's transactions without them: it lists a ledger's transactions a
 *  few seconds after RPC shows what they did. */
let horizonLag = 0;
/** What RPC answers a sendTransaction with. */
let sendAnswer: "PENDING" | "ERROR" = "PENDING";
const sent: Transaction[] = [];

interface LogRow {
  hash: string;
  address: string;
  kind: string;
  intent: Record<string, unknown>;
  status: string;
  ledger: number | null;
  max_fee: string;
  fee_charged: string | null;
  fee_payer: string;
  section: string;
}
let txLog: LogRow[] = [];

function reset() {
  ledger.clear();
  friendbotAsked = [];
  friendbotAnswers = "record";
  horizonLag = 0;
  sendAnswer = "PENDING";
  sent.length = 0;
  txLog = [];
}

const horizonAccount = (address: string) => ({
  id: address,
  account_id: address,
  sequence: "22096910953218050",
  subentry_count: 0,
  num_sponsoring: 0,
  num_sponsored: 0,
  signers: [],
  balances: [{ balance: (Number(ledger.get(address)!) / 1e7).toFixed(7), buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "native" }],
});

/** Horizon's record of a transaction, as Friendbot answers it and Horizon lists an account's. */
const txRecord = (hash: string) => ({ id: hash, hash, successful: true, ledger: 5_400_000, max_fee: "100000", fee_charged: "100", envelope_xdr: "AAAA" });

function accountEntries(keys: string[]) {
  const entries = keys.flatMap((k) => {
    const key = xdr.LedgerKey.fromXDR(k, "base64");
    if (key.switch().name !== "account") return [];
    const address = StrKey.encodeEd25519PublicKey(key.account().accountId().ed25519());
    const balance = ledger.get(address);
    if (balance === undefined) return [];
    const val = xdr.LedgerEntryData.account(new xdr.AccountEntry({
      accountId: key.account().accountId(),
      balance: xdr.Int64.fromString(balance.toString()),
      seqNum: xdr.Int64.fromString("22096910953218050"),
      numSubEntries: 0,
      inflationDest: null,
      flags: 0,
      homeDomain: "",
      thresholds: Buffer.from([1, 0, 0, 0]),
      signers: [],
      ext: new xdr.AccountEntryExt(0),
    }));
    return [{ key: k, xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }];
  });
  return { entries, latestLedger: 5_400_000 };
}

function rpc(method: string, params: any) {
  switch (method) {
    case "getLedgerEntries":
      return accountEntries(params.keys);
    case "getFeeStats":
      return { sorobanInclusionFee: { p90: "150" }, inclusionFee: { p90: "100" }, latestLedger: 5_400_000 };
    case "sendTransaction": {
      const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
      sent.push(tx);
      const hash = tx.hash().toString("hex");
      if (sendAnswer === "ERROR") {
        const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("100"), result: xdr.TransactionResultResult.txBadSeq(), ext: new xdr.TransactionResultExt(0) });
        return { status: "ERROR", hash, errorResultXdr: result.toXDR("base64"), latestLedger: 5_400_000, latestLedgerCloseTime: "0" };
      }
      // The merge: the temporary account's XLM goes to its destination, and the temporary account is gone.
      const op = tx.operations[0] as any;
      if (op.type === "accountMerge") {
        ledger.set(op.destination, ledger.get(op.destination)! + ledger.get(tx.source)!);
        ledger.delete(tx.source);
      }
      return { status: "PENDING", hash, latestLedger: 5_400_000, latestLedgerCloseTime: "0" };
    }
    case "getTransaction": {
      const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("100"), result: xdr.TransactionResultResult.txSuccess([]), ext: new xdr.TransactionResultExt(0) });
      const meta = new xdr.TransactionMeta(3, new xdr.TransactionMetaV3({ ext: new xdr.ExtensionPoint(0), txChangesBefore: [], operations: [], txChangesAfter: [], sorobanMeta: null }));
      return {
        status: "SUCCESS", latestLedger: 5_400_001, latestLedgerCloseTime: "0", oldestLedger: 1, oldestLedgerCloseTime: "0", ledger: 5_400_001, createdAt: "0",
        applicationOrder: 1, feeBump: false, envelopeXdr: sent.at(-1)!.toEnvelope().toXDR("base64"), resultXdr: result.toXDR("base64"), resultMetaXdr: meta.toXDR("base64"),
      };
    }
  }
  throw new Error(`unexpected RPC ${method}`);
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "friendbot.stellar.org") {
    const address = url.searchParams.get("addr")!;
    friendbotAsked.push(address);
    if (ledger.has(address)) return Response.json({ detail: "createAccountAlreadyExist" }, { status: 400 });
    ledger.set(address, GRANT);
    if (friendbotAnswers === "record") return Response.json(txRecord(FRIENDBOT_HASH));
    return friendbotAnswers === "hash" ? Response.json({ hash: FRIENDBOT_HASH, successful: true }) : new Response("funded");
  }
  if (url.host === "horizon-testnet.stellar.org") {
    const [, root, address, sub] = url.pathname.split("/");
    if (root === "accounts" && sub === "transactions") {
      const listed = ledger.has(address) && horizonLag-- <= 0;
      return Response.json({ _embedded: { records: listed ? [txRecord(CREATION_HASH)] : [] }, _links: {} });
    }
    if (root === "transactions") return Response.json(txRecord(address));
    if (root === "accounts") {
      return ledger.has(address) ? Response.json(horizonAccount(address)) : Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
    }
    if (root === "ledgers") return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    return Response.json({ jsonrpc: "2.0", id: body.id, result: rpc(body.method, body.params) });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

const claimRows = (address: string) => txLog.filter((r) => r.address === address && r.kind === "faucet" && r.status !== "failed");

/** The database: the tester list, tx_log's faucet rows, and the plans a trust step makes. A transaction holds its lock
 *  until it ends, as Postgres' advisory lock does: transactions run one after another. */
const sql = fakeSql((q, ps) => {
  if (q === "select 1 from lite.testers where address = ? and revoked_at is null") return [{ "?column?": 1 }];
  if (q === "select 1 from lite.tx_log where address = ? and kind = 'faucet' and status <> 'failed' limit 1") return claimRows(String(ps[0])).slice(0, 1).map(() => ({ "?column?": 1 }));
  if (q === "select pg_advisory_xact_lock(hashtextextended(?, 0))") {
    assert(/^lite\.faucet:G[A-Z2-7]{55}$/.test(String(ps[0])), String(ps[0]));
    return [{}];
  }
  if (q.startsWith("insert into lite.tx_log (hash, inner_hash, address, kind, intent, status, ledger, max_fee, fee_charged, fee_payer, section)")) {
    const [hash, inner, address, intent, status, ledgerSeq, maxFee, feeCharged] = ps as [string, string, string, Record<string, unknown>, string, number | null, string, string | null];
    assertEquals(inner, hash);
    assert(q.endsWith("on conflict do nothing"), q);
    if (!txLog.some((r) => r.hash === hash)) {
      txLog.push({ hash, address, kind: "faucet", intent, status, ledger: ledgerSeq, max_fee: maxFee, fee_charged: feeCharged, fee_payer: "external", section: "account" });
    }
    return [];
  }
  if (q === "update lite.tx_log set status = 'failed', updated_at = now() where hash = ?") {
    for (const r of txLog) if (r.hash === ps[0]) r.status = "failed";
    return [];
  }
  if (q.startsWith("update lite.tx_log set status = ?, ledger = ?, fee_charged = ?, updated_at = now() where hash = ?")) {
    for (const r of txLog) if (r.hash === ps[3]) Object.assign(r, { status: ps[0], ledger: ps[1], fee_charged: ps[2] });
    return [];
  }
  if (q.includes("from lite.launch_trades t join lite.launches l")) return [];
  if (q.startsWith("select step_kind, percentile_disc(0.9)")) return [];
  if (q.startsWith("insert into lite.plans")) return [{ id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1_800_000) }];
  throw new Error(`unexpected query: ${q}`);
});
let held: Promise<unknown> = Promise.resolve();
(sql as any).begin = (fn: (tx: unknown) => unknown) => {
  const run = held.then(() => fn(sql));
  held = run.catch(() => {});
  return run;
};
replaceSql(sql);

const tokenFor = (address: string) => signJwt({ sub: address, net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 4_102_444_800, iat: 1_760_400_000 });

async function ask(method: string, path: string, token: string | null) {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite/v1${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "x-forwarded-for": "198.51.100.41" },
    body: method === "POST" ? "{}" : undefined,
  }));
  const text = await res.text();
  return { status: res.status, body: JSON.parse(text) };
}

const faucetOf = async (address: string) => (await ask("GET", "/account", await tokenFor(address))).body.firstFunding.faucet;

// ------------------------------------------------------------------------------------------------ the truth table

Deno.test("a new account: Friendbot's activation is its claim, logged as its faucet row; the faucet then refuses it", async () => {
  reset();
  const me = Keypair.random().publicKey();
  const token = await tokenFor(me);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: false }, "nothing claimed before the account exists");

  const act = await ask("POST", "/account/activate", token);
  assertEquals([act.status, act.body.kind], [200, "trust"], "after Friendbot, USDC is a trust plan the user pays for");
  assertEquals(friendbotAsked, [me]);
  assertEquals(ledger.get(me), GRANT);
  assertEquals(txLog, [{
    hash: FRIENDBOT_HASH,
    address: me,
    kind: "faucet",
    intent: { kind: "faucet", summary: "Funded with Friendbot", spend: {}, display: { amount: "10000" } },
    status: "success",
    ledger: 5_400_000,
    max_fee: "100000",
    fee_charged: "100",
    fee_payer: "external",
    section: "account",
  }]);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: true });

  const again = await ask("POST", "/account/faucet", token);
  assertEquals([again.status, again.body.error], [429, { code: "faucet_used", message: "You already claimed your test XLM.", detail: null }]);
  assertEquals([friendbotAsked.length, sent.length, ledger.get(me)], [1, 0, GRANT], "nothing asked of Friendbot, nothing sent");
});

Deno.test("a second activate call: the account exists, so Friendbot funds nothing more and the claim stays one", async () => {
  reset();
  const me = Keypair.random().publicKey();
  const token = await tokenFor(me);
  await ask("POST", "/account/activate", token);
  const second = await ask("POST", "/account/activate", token);
  assertEquals([second.status, second.body.kind], [200, "trust"]);
  assertEquals([friendbotAsked, txLog.length, ledger.get(me)], [[me], 1, GRANT]);
  assertEquals((await ask("POST", "/account/faucet", token)).body.error.code, "faucet_used");
});

Deno.test("Friendbot's answer with the hash alone: Horizon's record of that transaction gives its ledger and fees", async () => {
  reset();
  friendbotAnswers = "hash";
  const me = Keypair.random().publicKey();
  await ask("POST", "/account/activate", await tokenFor(me));
  assertEquals(txLog.map((r) => [r.hash, r.status, r.ledger, r.max_fee, r.fee_charged]), [[FRIENDBOT_HASH, "success", 5_400_000, "100000", "100"]]);
});

Deno.test("Friendbot's answer without its transaction: the account's first transaction on Horizon is the claim", async () => {
  reset();
  friendbotAnswers = "text";
  const me = Keypair.random().publicKey();
  await ask("POST", "/account/activate", await tokenFor(me));
  assertEquals(txLog.map((r) => [r.hash, r.address, r.status, r.fee_payer]), [[CREATION_HASH, me, "success", "external"]]);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: true });
});

Deno.test("Horizon listing Friendbot's transaction late: it is asked again, and the claim is still logged", async () => {
  reset();
  friendbotAnswers = "text";
  horizonLag = 2;
  const me = Keypair.random().publicKey();
  const act = await ask("POST", "/account/activate", await tokenFor(me));
  assertEquals([act.status, act.body.kind], [200, "trust"]);
  assertEquals(txLog.map((r) => [r.hash, r.address, r.status]), [[CREATION_HASH, me, "success"]]);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: true });
});

Deno.test("a funding nothing names: the activation is refused (504 friendbot_slow), never answered as if nothing was funded", async () => {
  reset();
  friendbotAnswers = "text";
  horizonLag = Infinity;
  const me = Keypair.random().publicKey();
  const act = await ask("POST", "/account/activate", await tokenFor(me));
  assertEquals([act.status, act.body.error.code], [504, "friendbot_slow"]);
  assertEquals([friendbotAsked, ledger.get(me)], [[me], GRANT]);
});

Deno.test("an account that existed and never claimed: the faucet once (Friendbot's, merged in), then faucet_used", async () => {
  reset();
  const me = Keypair.random().publicKey();
  ledger.set(me, 50_000_000n);
  const token = await tokenFor(me);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: false });

  const claim = await ask("POST", "/account/faucet", token);
  assertEquals(claim.status, 200);
  // Friendbot funded a temporary account, which merged into the user's and paid the fee.
  assertEquals(friendbotAsked.length, 1);
  assert(friendbotAsked[0] !== me);
  assertEquals(sent.length, 1);
  const op = sent[0].operations[0] as any;
  assertEquals([sent[0].source, op.type, op.destination, sent[0].fee], [friendbotAsked[0], "accountMerge", me, "1000"]);
  assertEquals(claim.body, { hash: sent[0].hash().toString("hex") });
  assertEquals(ledger.get(me), 50_000_000n + GRANT);
  assertEquals(txLog.map((r) => [r.hash, r.address, r.kind, r.status, r.ledger, r.max_fee, r.fee_charged, r.fee_payer, r.intent.summary]), [
    [claim.body.hash, me, "faucet", "success", 5_400_001, "1000", "100", "external", "Funded with Friendbot"],
  ]);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: true });

  const again = await ask("POST", "/account/faucet", token);
  assertEquals([again.status, again.body.error.code], [429, "faucet_used"]);
  // Activation finds the account and funds nothing.
  await ask("POST", "/account/activate", token);
  assertEquals([friendbotAsked.length, sent.length, txLog.length], [1, 1, 1]);
});

Deno.test("two claims at once claim once: the second finds the first's row under the lock", async () => {
  reset();
  const me = Keypair.random().publicKey();
  ledger.set(me, 50_000_000n);
  const token = await tokenFor(me);
  const answers = await Promise.all([ask("POST", "/account/faucet", token), ask("POST", "/account/faucet", token)]);
  assertEquals(answers.map((a) => a.status).sort(), [200, 429]);
  assertEquals([sent.length, claimRows(me).length, ledger.get(me)], [1, 1, 50_000_000n + GRANT]);
  assertEquals(friendbotAsked.length, 1, "the claim is checked under the lock before Friendbot funds anything");
});

Deno.test("a faucet tap racing a Friendbot activation: the activation's claim is logged under the same lock, so the tap claims nothing", async () => {
  reset();
  friendbotAnswers = "text"; // Friendbot's answer names no transaction: activate looks it up on Horizon,
  horizonLag = 3; //            which lists it a few seconds late: the claim is logged only then.
  const me = Keypair.random().publicKey();
  const token = await tokenFor(me);
  const activation = ask("POST", "/account/activate", token);
  while (!ledger.has(me)) await new Promise((r) => setTimeout(r, 20)); // Friendbot has funded the account
  const faucet = await ask("POST", "/account/faucet", token);
  const act = await activation;
  assertEquals([act.status, act.body.kind], [200, "trust"]);
  assertEquals([faucet.status, faucet.body.error?.code], [429, "faucet_used"]);
  assertEquals(ledger.get(me), GRANT, "one Friendbot grant");
  assertEquals(claimRows(me).length, 1);
  assertEquals(friendbotAsked, [me], "no temporary account funded for the tap");
});

Deno.test("activation and the faucet are rate-limited per address", async () => {
  reset();
  const me = Keypair.random().publicKey();
  ledger.set(me, 50_000_000n);
  const token = await tokenFor(me);
  const taps = [];
  for (let i = 0; i < 4; i++) taps.push(await ask("POST", "/account/faucet", token));
  assertEquals(taps.map((t) => t.body.error?.code ?? t.status), [200, "faucet_used", "faucet_used", "rate_limited"]);
  const activations = [];
  for (let i = 0; i < 6; i++) activations.push((await ask("POST", "/account/activate", token)).status);
  assertEquals(activations, [200, 200, 200, 200, 200, 429]);
  assertEquals(friendbotAsked.length, 1);
});

Deno.test("a merge the network refused sent nothing: the claim is still to make, and the next one goes through", async () => {
  reset();
  const me = Keypair.random().publicKey();
  ledger.set(me, 50_000_000n);
  const token = await tokenFor(me);
  sendAnswer = "ERROR";
  const refused = await ask("POST", "/account/faucet", token);
  assert(refused.status >= 400 && refused.body.error.code !== "faucet_used", JSON.stringify(refused.body));
  assertEquals(txLog.map((r) => r.status), ["failed"]);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: false });
  sendAnswer = "PENDING";
  assertEquals((await ask("POST", "/account/faucet", token)).status, 200);
  assertEquals(await faucetOf(me), { amount: "10000", claimed: true });
});

Deno.test("a viewer read: the public view says the faucet's amount and leaves its claim null", async () => {
  reset();
  const me = Keypair.random().publicKey();
  await ask("POST", "/account/activate", await tokenFor(me));
  const view = await ask("GET", `/account?address=${me}`, null);
  assertEquals([view.status, view.body.view, view.body.firstFunding.faucet], [200, "public", { amount: "10000", claimed: null }]);
});
