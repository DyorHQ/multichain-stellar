// One way to name an asset (docs/DESIGN-stellar-parity.md §9, §12.5): resolveAsset() takes the registry (by id or
// contract, or a registry asset's CODE:ISSUER), then a DyorHQ launch, then a token contract's own symbol() and name()
// (a classic asset's SAC resolves as that asset), then a classic CODE:ISSUER; anything else is 400 unsupported_asset.
// And no payload ever stands in "Token"/TOKEN for a token's name: the account view (owner and public), a send's plan and
// a swap's refusal all carry the token's real code.
import { Address, Asset, Keypair, nativeToScVal, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, OTHER, setTestEnv, TOKEN, USER, XLM_SAC } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { resolveAsset } = await import("../../supabase/functions/_shared/assets.ts");
const { accountView } = await import("../../supabase/functions/_shared/account.ts");
const { quote } = await import("../../supabase/functions/_shared/swap.ts");
const { createPlan } = await import("../../supabase/functions/_shared/plans.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const PASS = TESTNET.passphrase;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const EURC_ISSUER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(9) as any).publicKey();
const EURC = `EURC:${EURC_ISSUER}`;
const EURC_SAC = new Asset("EURC", EURC_ISSUER).contractId(PASS);
/** Another SEP-41 token: not a launch, not a SAC. */
const AQUA = StrKey.encodeContract(new Uint8Array(32).fill(11) as any);
/** The code a token without a known name used to get (§9); spelled in two parts so the placeholder scan finds it only
 *  where it would be a placeholder. */
const PLACEHOLDER = ["TOK", "EN"].join("");
/** A contract that answers nothing. */
const SILENT = StrKey.encodeContract(new Uint8Array(32).fill(12) as any);

// ------------------------------------------------------------------------------------------------ the network

const horizonAccounts = new Map<string, Record<string, unknown>>();
/** symbol(), name(), decimals(), balance() and transfer() answers by contract. */
const contracts: Record<string, Record<string, xdr.ScVal>> = {
  [AQUA]: { symbol: nativeToScVal("AQUA", { type: "string" }), name: nativeToScVal("Aquarius", { type: "string" }), decimals: nativeToScVal(7, { type: "u32" }) },
  [EURC_SAC]: { symbol: nativeToScVal("EURC", { type: "string" }), name: nativeToScVal(EURC, { type: "string" }), decimals: nativeToScVal(7, { type: "u32" }) },
  [TOKEN]: { balance: nativeToScVal(12_000_000_000_000n, { type: "i128" }), transfer: xdr.ScVal.scvVoid() },
};

function simulate(params: { transaction: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const answer = contracts[contract]?.[call.functionName().toString()];
  if (!answer) return { latestLedger: 1, error: "HostError: Error(WasmVm, MissingValue)" };
  const transactionData = new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64");
  return { latestLedger: 1, minResourceFee: "1000", transactionData, results: [{ auth: [], xdr: answer.toXDR("base64") }], events: [] };
}

function accountEntry(address: string) {
  const id = Keypair.fromPublicKey(address).xdrAccountId();
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: id }));
  const val = xdr.LedgerEntryData.account(new xdr.AccountEntry({
    accountId: id,
    balance: xdr.Int64.fromString("100000000000"),
    seqNum: xdr.Int64.fromString("22096910953218048"),
    numSubEntries: 1,
    inflationDest: null,
    flags: 0,
    homeDomain: "",
    thresholds: Buffer.from([1, 0, 0, 0]),
    signers: [],
    ext: new xdr.AccountEntryExt(0),
  }));
  return { entries: [{ key: key.toXDR("base64"), xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }], latestLedger: 1 };
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
    const a = horizonAccounts.get(url.pathname.split("/")[2]);
    return a ? Response.json(a) : Response.json({ status: 404 }, { status: 404 });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    const result = body.method === "simulateTransaction"
      ? simulate(body.params)
      : body.method === "getFeeStats"
      ? { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: 1 }
      : body.method === "getLedgerEntries"
      ? accountEntry(USER.publicKey())
      : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** The user's account on Horizon: 10,000 XLM, USDC and EURC enabled. */
horizonAccounts.set(USER.publicKey(), {
  id: USER.publicKey(),
  account_id: USER.publicKey(),
  sequence: "22096910953218048",
  subentry_count: 2,
  num_sponsoring: 0,
  num_sponsored: 0,
  signers: [],
  balances: [
    { balance: "5.2300000", limit: "922337203685.4775807", selling_liabilities: "0", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] },
    { balance: "3.0000000", limit: "922337203685.4775807", selling_liabilities: "0", asset_type: "credit_alphanum4", asset_code: "EURC", asset_issuer: EURC_ISSUER },
    { balance: "10000.0000000", selling_liabilities: "0.0000000", asset_type: "native" },
  ],
});

const LAUNCH_ROW = { token: TOKEN, symbol: "ECAT", name: "E2E Cat" };

replaceSql(fakeSql((q, ps) => {
  if (q === "select token, symbol, name from lite.launches where token = ?") return ps[0] === TOKEN ? [LAUNCH_ROW] : [];
  if (q.startsWith("select token from lite.launches where token = any(")) return (ps[0] as string[]).includes(TOKEN) ? [{ token: TOKEN }] : [];
  if (q.includes("from lite.launch_trades t join lite.launches l")) return [{ ...LAUNCH_ROW, net: "12000000000000" }];
  if (q.startsWith("select 1 from lite.tx_log where address = ? and kind = 'faucet'")) return [];
  if (q.startsWith("insert into lite.plans")) return [{ id: "647e7a41-adef-4b9d-a81a-c96fcd55b14f", expires_at: new Date(Date.now() + 1_800_000) }];
  throw new Error(`unexpected query: ${q}`);
}));

// ------------------------------------------------------------------------------------------------ resolution

Deno.test("the registry: by id, by contract, and a registry asset's CODE:ISSUER", async () => {
  for (const [id, code, kind, logo] of [["XLM", "XLM", "native", "XLM"], ["USDC", "USDC", "classic", "USDC"], ["BUSDC", "USDC", "classic", null], [XLM_SAC, "XLM", "native", "XLM"], [USDC.classic!, "USDC", "classic", "USDC"]]) {
    const a = await resolveAsset(id!);
    assertEquals([a.code, a.kind, a.verified, a.logo], [code, kind, true, logo], id!);
  }
  assertEquals((await resolveAsset(USDC.classic!)).id, "USDC");
});

Deno.test("a launch, by lite.launches: its own ticker and name", async () => {
  assertEquals(await resolveAsset(TOKEN), { id: TOKEN, code: "ECAT", name: "E2E Cat", decimals: 7, contract: TOKEN, classic: null, kind: "launch", verified: true, logo: null });
});

Deno.test("any other token contract by its own symbol() and name(); a classic asset's SAC as that asset", async () => {
  assertEquals(await resolveAsset(AQUA), { id: AQUA, code: "AQUA", name: "Aquarius", decimals: 7, contract: AQUA, classic: null, kind: "sac", verified: false, logo: null });
  const sac = await resolveAsset(EURC_SAC);
  assertEquals([sac.id, sac.code, sac.classic, sac.kind, sac.verified], [EURC, "EURC", EURC, "classic", false]);
});

Deno.test("a classic CODE:ISSUER outside the registry: named by its code, its SAC as its contract, unverified", async () => {
  assertEquals(await resolveAsset(EURC), { id: EURC, code: "EURC", name: "EURC", decimals: 7, contract: EURC_SAC, classic: EURC, kind: "classic", verified: false, logo: null });
});

Deno.test("anything else is 400 unsupported_asset: never a stand-in name", async () => {
  for (const id of [SILENT, PLACEHOLDER, "XLM:",`EURC:${EURC_ISSUER.slice(0, -1)}A`, "WAYTOOLONGCODE:" + EURC_ISSUER, "C" + "A".repeat(55), ""]) {
    const e = await assertRejects(() => resolveAsset(id), ApiError, undefined, id);
    assertEquals([e.status, e.code], [400, "unsupported_asset"], id);
  }
});

// ------------------------------------------------------------------------------------------------ never a stand-in

/** Throws when `payload` names a token by the old stand-in (PLACEHOLDER, or "Token" as its name). */
function noToken(payload: unknown, what: string) {
  const text = JSON.stringify(payload, (_k, v) => (typeof v === "bigint" ? v.toString() : v));
  assert(!new RegExp(`\\b${PLACEHOLDER}\\b|"Token"`).test(text), `${what} names a token ${PLACEHOLDER}: ${text.slice(0, 300)}`);
  return text;
}

Deno.test("the account view, owner's and public, names the launch token and the foreign trustline by their codes", async () => {
  for (const scope of ["owner", "public"] as const) {
    const v = await accountView(USER.publicKey(), scope);
    noToken(v, `the ${scope} view`);
    const launch = v.balances.find((b) => b.asset === TOKEN)!;
    assertEquals([launch.code, launch.name, launch.kind, launch.balance], ["ECAT", "E2E Cat", "launch", "12000000000000"], scope);
    const eurc = v.balances.find((b) => b.asset === EURC)!;
    assertEquals([eurc.code, eurc.kind, eurc.verified, eurc.balance], ["EURC", "classic", false, "30000000"], scope);
  }
});

Deno.test("a send of a launch token is planned with its code; a swap with no route says it too", async () => {
  const plan = await createPlan(USER.publicKey(), "payment", [{ label: "Send", spec: { kind: "payment", asset: TOKEN, to: OTHER.publicKey(), amount: "10000000" } }]);
  const text = noToken(plan, "the send's plan");
  assert(text.includes('"summary":"Send 1 ECAT"') && text.includes('"asset":"ECAT"'), text.slice(0, 400));
  assertEquals([plan.steps[0].stepKind, plan.steps[0].intent?.to], ["payment_token", OTHER.publicKey()]);
  const e = await assertRejects(() => quote(USER.publicKey(), "XLM", TOKEN, 10_000_000n, 100), ApiError);
  assertEquals([e.code, e.message], ["no_route", "No route from XLM to ECAT right now."]);
});
