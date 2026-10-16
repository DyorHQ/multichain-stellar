// A sponsored account's setup (docs/DESIGN-stellar-parity.md §4.3): POST /v1/account/activate hands out the setup
// transaction with no signature of the sponsor's, so nobody can send it past the sponsorship caps; the sponsor signs only
// in submitStep, after lite.reserve_sponsorship counted it. A submission the caps refuse sends nothing and is signed by
// nobody but its user; one they allow goes out with both signatures, the reservation first.
import { Keypair, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv, SPONSOR } from "../fixtures/routes/harness.ts";

setTestEnv();
Deno.env.set("LITE_ACTIVATION", "sponsored");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { activate } = await import("../../supabase/functions/_shared/account.ts");
const { submitStep } = await import("../../supabase/functions/_shared/plans.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const PASS = TESTNET.passphrase;
const ledger = new Map<string, bigint>([[SPONSOR.publicKey(), 1_000_000_000n]]);

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

/** Every envelope sent to RPC, and the order of what happened (queries and sends). */
const sentToNetwork: string[] = [];
const events: string[] = [];

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org") {
    const [, root] = url.pathname.split("/");
    if (root === "accounts") return Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
    if (root === "ledgers") return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    if (body.method === "getLedgerEntries") return Response.json({ jsonrpc: "2.0", id: body.id, result: accountEntries(body.params.keys) });
    if (body.method === "getFeeStats") {
      return Response.json({ jsonrpc: "2.0", id: body.id, result: { sorobanInclusionFee: { p90: "150" }, inclusionFee: { p90: "100" }, latestLedger: 5_400_000 } });
    }
    if (body.method === "sendTransaction") {
      sentToNetwork.push(body.params.transaction);
      events.push("send");
      const tx = TransactionBuilder.fromXDR(body.params.transaction, PASS) as Transaction;
      return Response.json({ jsonrpc: "2.0", id: body.id, result: { status: "PENDING", hash: tx.hash().toString("hex"), latestLedger: 5_400_000, latestLedgerCloseTime: "0" } });
    }
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** The database: plans as stored, and what lite.reserve_sponsorship answers. */
const plans = new Map<string, { kind: string; steps: unknown[] }>();
let reservation: { id: string | null; refusal: string | null } = { id: null, refusal: "day" };
const queries: string[] = [];

replaceSql(fakeSql((q, ps) => {
  queries.push(q);
  if (q.includes("lite.sponsorship_refusal")) return [{ refusal: null }];
  if (q.startsWith("select step_kind, percentile_disc(0.9)")) return [];
  if (q.startsWith("insert into lite.plans")) {
    const id = crypto.randomUUID();
    plans.set(id, { kind: String(ps[1]), steps: structuredClone(ps[2]) as unknown[] });
    return [{ id, expires_at: new Date(Date.now() + 1_800_000) }];
  }
  if (q === "select kind, steps, expires_at from lite.plans where id = ? and address = ?") {
    const p = plans.get(String(ps[0]));
    return p ? [{ kind: p.kind, steps: structuredClone(p.steps), expires_at: new Date(Date.now() + 1_800_000) }] : [];
  }
  if (q.startsWith("update lite.plans set steps")) {
    const p = plans.get(String(ps[1]));
    if (p) p.steps = structuredClone(ps[0]) as unknown[];
    return [];
  }
  if (q.startsWith("select id, refusal from lite.reserve_sponsorship(")) {
    events.push("reserve");
    return [reservation];
  }
  if (q.startsWith("update lite.sponsorships set status = 'sent'")) return [];
  if (q.startsWith("update lite.sponsorships set status = 'released'")) return [];
  if (q.startsWith("insert into lite.tx_log")) return [];
  if (q.includes("from lite.launches")) return [];
  throw new Error(`unexpected query: ${q}`);
}));

const signedBySponsor = (tx: Transaction) =>
  tx.signatures.some((s) => Buffer.from(s.hint()).equals(SPONSOR.signatureHint()) && SPONSOR.verify(tx.hash(), s.signature()));

async function setUp() {
  const user = Keypair.random();
  const plan = await activate(user.publicKey(), "198.51.100.7") as any;
  const step = plan.steps[0];
  const tx = TransactionBuilder.fromXDR(step.xdr, PASS) as Transaction;
  return { user, plan, step, tx };
}

Deno.test("activate hands out the setup transaction with no signature of the sponsor's, and reserves nothing", async () => {
  queries.length = 0;
  const { plan, step, tx } = await setUp();
  assertEquals([step.feePayer, step.sponsorReason], ["sponsor", "setup"]);
  assertEquals(tx.source, SPONSOR.publicKey());
  assertEquals(tx.signatures.length, 0, "the envelope the caller gets is unsigned");
  assert(!signedBySponsor(tx));
  assert(!queries.some((q) => q.includes("reserve_sponsorship")), "nothing was reserved");
  // The stored step is the same unsigned envelope: rebuilding or reading it back gives nobody a sponsor signature.
  const stored = plans.get(plan.planId)!.steps[0] as { xdr: string };
  assertEquals((TransactionBuilder.fromXDR(stored.xdr, PASS) as Transaction).signatures.length, 0);
  assertEquals(sentToNetwork.length, 0);
});

Deno.test("a setup beyond the sponsorship caps is refused: nothing is sent, and the sponsor signs nothing", async () => {
  const { user, plan, step, tx } = await setUp();
  reservation = { id: null, refusal: "day" };
  sentToNetwork.length = 0;
  events.length = 0;
  tx.sign(user);
  const e = await assertRejects(() => submitStep(user.publicKey(), plan.planId, step.id, tx.toEnvelope().toXDR("base64"), "198.51.100.7"), ApiError);
  assertEquals([e.status, e.code], [429, "sponsor_limit"]);
  assertEquals(events, ["reserve"]);
  assertEquals(sentToNetwork, []);
  // The plan keeps no envelope the sponsor signed.
  for (const s of plans.get(plan.planId)!.steps as { xdr?: string }[]) {
    if (s.xdr) assert(!signedBySponsor(TransactionBuilder.fromXDR(s.xdr, PASS) as Transaction));
  }
});

Deno.test("a setup within the caps: the sponsorship is reserved first, then the sponsor signs and it goes out with both signatures", async () => {
  const { user, plan, step, tx } = await setUp();
  reservation = { id: "8e1f6d2a-0000-4000-8000-000000000009", refusal: null };
  sentToNetwork.length = 0;
  events.length = 0;
  tx.sign(user);
  const answer = await submitStep(user.publicKey(), plan.planId, step.id, tx.toEnvelope().toXDR("base64"), "198.51.100.7");
  assertEquals(answer, { hash: tx.hash().toString("hex"), status: "pending" });
  assertEquals(events, ["reserve", "send"]);
  const sent = TransactionBuilder.fromXDR(sentToNetwork[0], PASS) as Transaction;
  assertEquals(sent.hash().toString("hex"), step.hash);
  assertEquals(sent.signatures.length, 2);
  assert(signedBySponsor(sent), "the sponsor signed what was sent");
});
