// What a settled step delivered and where it counts (docs/DESIGN-stellar-parity.md §6.11, §12.5): amountOut from an
// SDEX path payment's result (fee-bumped too), Soroswap's Vec<i128>, Aquarius's u128 and the curve's buy and sell; the
// section of each intent kind; settle() recording status, fee, outcome, the plan step and the sponsorship; and
// GET /v1/tx/:hash answering the contract's TxStatus (fixture tx-status.json).
import { Account, Asset, Keypair, nativeToScVal, Operation, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assertEquals } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { outcomeOf, sectionOf, settle, trackTx } = await import("../../supabase/functions/_shared/plans.ts");

const fixture = JSON.parse(await Deno.readTextFile(new URL("../fixtures/api/tx-status.json", import.meta.url)));

/** A transaction result whose one operation is a pathPaymentStrictSend that delivered `amount`. */
function sdexResult(amount: string, feeBumped = false): string {
  const last = new xdr.SimplePaymentResult({ destination: Keypair.random().xdrAccountId(), asset: Asset.native().toXDRObject(), amount: xdr.Int64.fromString(amount) });
  const op = xdr.OperationResult.opInner(
    xdr.OperationResultTr.pathPaymentStrictSend(xdr.PathPaymentStrictSendResult.pathPaymentStrictSendSuccess(new xdr.PathPaymentStrictSendResultSuccess({ offers: [], last }))),
  );
  const fee = xdr.Int64.fromString("200");
  const result = feeBumped
    ? xdr.TransactionResultResult.txFeeBumpInnerSuccess(
      new xdr.InnerTransactionResultPair({
        transactionHash: Buffer.alloc(32),
        result: new xdr.InnerTransactionResult({ feeCharged: fee, result: xdr.InnerTransactionResultResult.txSuccess([op]), ext: new xdr.InnerTransactionResultExt(0) }),
      }),
    )
    : xdr.TransactionResultResult.txSuccess([op]);
  return new xdr.TransactionResult({ feeCharged: fee, result, ext: new xdr.TransactionResultExt(0) }).toXDR("base64");
}

Deno.test("amountOut: an SDEX path payment's last amount, from the result, fee-bumped or not", () => {
  assertEquals(outcomeOf("swap_sdex", { resultXdr: sdexResult("1903400") }), { amountOut: "1903400" });
  assertEquals(outcomeOf("swap_sdex", { resultXdr: sdexResult("77", true) }), { amountOut: "77" });
  assertEquals(outcomeOf("swap_sdex", { resultXdr: undefined }), { amountOut: null });
  assertEquals(outcomeOf("swap_sdex", { resultXdr: "not xdr" }), { amountOut: null });
});

Deno.test("amountOut: Soroswap's last amount, Aquarius's u128, the curve's tokens or quote out; others' return value", () => {
  assertEquals(outcomeOf("swap_soroswap", { returnValue: [100000000n, 18938032n] }), { amountOut: "18938032" });
  assertEquals(outcomeOf("swap_soroswap", { returnValue: [] }), { amountOut: null });
  assertEquals(outcomeOf("swap_aquarius", { returnValue: 18938032n }), { amountOut: "18938032" });
  assertEquals(outcomeOf("launch_buy", { returnValue: 120000000000n }), { amountOut: "120000000000" });
  assertEquals(outcomeOf("launch_buy", { returnValue: { tokens_out: 5n, used: 9n } }), { amountOut: "5" });
  assertEquals(outcomeOf("launch_sell", { returnValue: 4200n }), { amountOut: "4200" });
  assertEquals(outcomeOf("launch_sell", { returnValue: { quote_out: 7n } }), { amountOut: "7" });
  assertEquals(outcomeOf("launch_claim", { returnValue: 31n }), { amountOut: "31" });
  // A new launch's or Moment's id is no amount; a classic step returns nothing.
  assertEquals(outcomeOf("launch_create", { returnValue: "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V" }), { amountOut: null });
  assertEquals(outcomeOf("payment", { returnValue: undefined }), { amountOut: null });
  assertEquals(outcomeOf(null, { returnValue: { a: 1 } }), { amountOut: null });
});

Deno.test("sections: swaps by their sides, sends spot, setup and restores account, then each area's own", () => {
  const LAUNCH = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
  const launches = new Set([LAUNCH]);
  const swap = (spend: string, receive: string) => ({ kind: "swap", spend: { [spend]: "1" }, receive: { [receive]: "1" } });
  assertEquals(sectionOf(swap("CXLM", "CUSDC"), launches), "spot");
  assertEquals(sectionOf(swap("CXLM", LAUNCH), launches), "launch");
  assertEquals(sectionOf(swap(LAUNCH, "CXLM"), launches), "launch");
  const of = (kind: string) => sectionOf({ kind, spend: {} }, launches);
  assertEquals(
    ["payment", "trust", "activate", "faucet", "restore", "earn_deposit", "earn_withdraw", "launch_buy", "launch_create", "moment_collect", "moment_publish", "approve", "bridge_out", "other"].map(of),
    ["spot", "account", "account", "account", "account", "earn", "earn", "launch", "launch", "moments", "moments", "bridge", "bridge", null],
  );
});

/** Records every query; answers the settle's own. */
function settleDb(steps: unknown[] | null) {
  const seen: { q: string; ps: unknown[] }[] = [];
  replaceSql(fakeSql((q, ps) => {
    seen.push({ q, ps });
    if (q.startsWith("update lite.tx_log set status")) return [{ hash: ps.at(-1) }];
    if (q === "select steps from lite.plans where id = ?") return steps ? [{ steps }] : [];
    if (q.startsWith("update lite.plans set steps") || q.startsWith("update lite.sponsorships")) return [];
    if (q.startsWith("select hash, status, plan_id")) return [{ hash: fixture.hash, status: "pending", plan_id: null, step_id: null, step_kind: "swap_soroswap", fee_payer: "user" }];
    throw new Error(`unexpected query: ${q}`);
  }));
  return seen;
}

Deno.test("settle: the status, ledger, fee charged and amountOut; the plan step done; a sponsor's transaction settles its sponsorship", async () => {
  const planId = crypto.randomUUID();
  const seen = settleDb([{ id: "s1", label: "Swap", spec: { kind: "swap_sdex" }, status: "submitted" }]);
  const row = { hash: "ab".repeat(32), status: "pending", plan_id: planId, step_id: "s1", step_kind: "swap_sdex", fee_payer: "sponsor" };
  const settled = await settle(row, { status: "SUCCESS", ledger: 5_201_234, feeCharged: "200", resultXdr: sdexResult("20000000", true) });
  assertEquals([settled.status, settled.fee_charged, settled.result], ["success", "200", { amountOut: "20000000" }]);
  const update = seen.find((s) => s.q.startsWith("update lite.tx_log set status"))!;
  assertEquals(update.ps, ["success", 5_201_234, "200", null, { amountOut: "20000000" }, "ab".repeat(32)]);
  const steps = seen.find((s) => s.q.startsWith("update lite.plans set steps"))!.ps[0] as { status: string }[];
  assertEquals(steps[0].status, "done");
  assertEquals(seen.find((s) => s.q.startsWith("update lite.sponsorships"))!.ps, ["success", "200", "ab".repeat(32)]);

  // A failed one delivers nothing, and fails its step.
  const seen2 = settleDb([{ id: "s1", label: "Swap", spec: { kind: "swap_sdex" }, status: "submitted" }]);
  const failed = await settle({ ...row, fee_payer: "user" }, { status: "FAILED", ledger: 5_201_235, feeCharged: "100", error: "pathPaymentStrictSendUnderDestmin" });
  assertEquals([failed.status, failed.result, failed.error], ["failed", { amountOut: null }, "pathPaymentStrictSendUnderDestmin"]);
  assertEquals((seen2.find((s) => s.q.startsWith("update lite.plans set steps"))!.ps[0] as { status: string }[])[0].status, "failed");
  assertEquals(seen2.some((s) => s.q.startsWith("update lite.sponsorships")), false);
});

Deno.test("GET /v1/tx/:hash settles a landed swap and answers the contract's TxStatus (tx-status.json)", async () => {
  settleDb(null);
  const envelope = new TransactionBuilder(new Account(USER.publicKey(), "1"), { fee: "100", networkPassphrase: "Test SDF Network ; September 2015" })
    .addOperation(Operation.bumpSequence({ bumpTo: "2" }))
    .setTimeout(600)
    .build()
    .toEnvelope()
    .toXDR("base64");
  const returnValue = nativeToScVal([100000000n, 18938032n], { type: ["i128", "i128"] as any });
  const meta = new xdr.TransactionMeta(
    3,
    new xdr.TransactionMetaV3({
      ext: new xdr.ExtensionPoint(0),
      txChangesBefore: [],
      operations: [],
      txChangesAfter: [],
      sorobanMeta: new xdr.SorobanTransactionMeta({ ext: new xdr.SorobanTransactionMetaExt(0), events: [], returnValue, diagnosticEvents: [] }),
    }),
  );
  const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("41210"), result: xdr.TransactionResultResult.txSuccess([]), ext: new xdr.TransactionResultExt(0) });
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const req = input instanceof Request ? input : new Request(String(input), init);
    const body = await req.json();
    if (body.method !== "getTransaction") throw new Error(`unexpected RPC ${body.method}`);
    return Response.json({
      jsonrpc: "2.0",
      id: body.id,
      result: {
        status: "SUCCESS",
        latestLedger: 5_201_300,
        latestLedgerCloseTime: "1791971000",
        oldestLedger: 5_100_000,
        oldestLedgerCloseTime: "1791000000",
        ledger: 5_201_234,
        createdAt: "1791970900",
        applicationOrder: 1,
        feeBump: false,
        envelopeXdr: envelope,
        resultXdr: result.toXDR("base64"),
        resultMetaXdr: meta.toXDR("base64"),
      },
    });
  }) as typeof fetch;
  const status = await trackTx(USER.publicKey(), fixture.hash);
  assertEquals(JSON.parse(JSON.stringify(status, (_k, v) => (typeof v === "bigint" ? v.toString() : v))), fixture);
});
