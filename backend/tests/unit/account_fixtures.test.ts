// The package's payloads equal the API contract's fixtures (docs/DESIGN-stellar-parity.md §6.0, §12.5;
// backend/tests/fixtures/api/): the routes answer from seeded Horizon, RPC and database data, as the fixtures describe
// them. GET /v1/account's owner view (account.json), its public view for ?address= with no token
// (account.public.json, cached 15 s), the same with a token (byte for byte the owner view) and with neither (400
// address_required); a missing account (account.missing.json); activation with nothing to do (account-activate.json);
// GET /v1/recipient (recipient.json); GET /v1/fees (fees.json); POST /v1/swap/quote (swap-quote.json); and the plans of
// a send (plan-send.json) and a swap that enables USDC first (plan.json), whose transactions are built afresh, so their
// envelopes are compared by what they say rather than byte for byte.
import { Address, Keypair, nativeToScVal, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { signJwt } = await import("../../supabase/functions/_shared/auth.ts");
const { handle } = await import("../../supabase/functions/lite/index.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const fixture = async (name: string) => JSON.parse(await Deno.readTextFile(new URL(`../fixtures/api/${name}.json`, import.meta.url)));
const PASS = TESTNET.passphrase;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!;
const ME = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH";
const FRIEND = "GCRUXQPSZ5FJCMOQXCLEAWYD5AQ265VPQPG66IMLPCGC7RJ4XTOTIFDY";
const ECAT = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
const QUOTE_ID = "d5886566-dc19-4259-aa17-607202c4170c";

// ------------------------------------------------------------------------------------------------ the seeded world

const usdcLine = (balance: string) => ({ balance, limit: "922337203685.4775807", selling_liabilities: "0.0000000", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] });

/** Horizon's accounts: ME with 10,000 XLM and 5.23 USDC (one subentry); FRIEND exists. Each test sets what it needs. */
const accounts = new Map<string, Record<string, unknown>>();
function account(address: string, lines: Record<string, unknown>[]) {
  accounts.set(address, {
    id: address,
    account_id: address,
    sequence: "22096910953218050",
    subentry_count: lines.length,
    num_sponsoring: 0,
    num_sponsored: 0,
    signers: [],
    balances: [...lines, { balance: "10000.0000000", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "native" }],
  });
}

const ok = (answer: xdr.ScVal) => ({
  latestLedger: 1,
  minResourceFee: "1000",
  transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
  results: [{ auth: [], xdr: answer.toXDR("base64") }],
  events: [],
});

/** Soroswap's quote for XLM → USDC: the fixture's 18,938,032 for 10 XLM, and 18,945 for 0.01 XLM (price impact). */
function simulate(params: { transaction: string }) {
  const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fn = call.functionName().toString();
  if (contract === ECAT && fn === "balance") return ok(nativeToScVal(12_000_000_000_000n, { type: "i128" }));
  if (contract === TESTNET.contracts.soroswapRouter && fn === "router_get_amounts_out") {
    const amount = BigInt((call.args()[0].value() as any).lo().toString());
    const out = amount === 100_000_000n ? 18_938_032n : amount === 100_000n ? 18_945n : null;
    if (out !== null) return ok(nativeToScVal([amount, out], { type: ["i128", "i128"] as any }));
  }
  return { latestLedger: 1, error: "HostError: Error(Contract, #1)" };
}

function accountEntry(address: string) {
  const id = Keypair.fromPublicKey(address).xdrAccountId();
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: id }));
  const val = xdr.LedgerEntryData.account(new xdr.AccountEntry({
    accountId: id,
    balance: xdr.Int64.fromString("100000000000"),
    seqNum: xdr.Int64.fromString("22096910953218050"),
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
    const a = accounts.get(url.pathname.split("/")[2]);
    return a ? Response.json(a) : Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/paths/strict-send") {
    return Response.json({ _embedded: { records: [{ destination_amount: "1.8911200", path: [] }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    const result = body.method === "simulateTransaction"
      ? simulate(body.params)
      : body.method === "getFeeStats"
      ? { sorobanInclusionFee: { p90: "150" }, inclusionFee: { p90: "100" }, latestLedger: 1 }
      : body.method === "getLedgerEntries"
      ? accountEntry(ME)
      : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** The swap quote stored for QUOTE_ID (POST /v1/swap/build reads it back). */
const STORED_QUOTE = {
  request: { sell: "XLM", buy: "USDC", amountIn: "100000000", slippageBps: 50 },
  best: { venue: "soroswap", amountOut: "18938032", path: [XLM.contract, USDC.contract], minOut: "18843341", priceImpactBps: 4 },
  alternatives: [{ venue: "sdex", amountOut: "18911200", path: ["native", USDC.classic], minOut: "18816644", priceImpactBps: null }],
};

replaceSql(fakeSql((q, ps) => {
  if (q === "select 1 from lite.testers where address = ? and revoked_at is null") return [{ "?column?": 1 }];
  if (q.includes("from lite.launch_trades t join lite.launches l")) return [{ token: ECAT, symbol: "ECAT", name: "E2E Cat", net: "12000000000000" }];
  if (q.startsWith("select 1 from lite.tx_log where address = ? and kind = 'faucet'")) return [];
  if (q.startsWith("select step_kind, percentile_disc(0.9)")) {
    const at = (t: string) => new Date(`2026-10-14T${t}.000Z`);
    return [
      { step_kind: "swap_soroswap", p90: "400000", latest: at("09:40:00") },
      { step_kind: "launch_buy", p90: "400000", latest: at("09:12:00") },
      { step_kind: "trust", p90: "8000", latest: at("08:30:00") },
    ];
  }
  if (q.startsWith("insert into lite.swap_quotes")) return [{ id: QUOTE_ID, expires_at: new Date("2026-10-14T09:42:00.000Z") }];
  if (q.startsWith("select request, best, alternatives, expires_at from lite.swap_quotes")) {
    return ps[0] === QUOTE_ID ? [{ ...STORED_QUOTE, expires_at: new Date(Date.now() + 60_000) }] : [];
  }
  if (q.startsWith("insert into lite.plans")) return [{ id: crypto.randomUUID(), expires_at: new Date(Date.now() + 1_800_000) }];
  throw new Error(`unexpected query: ${q}`);
}));

const token = await signJwt({ sub: ME, net: "testnet", aud: "dyorhq-lite", iss: "dyorhq-lite", exp: 4_102_444_800, iat: 1_760_400_000 });

async function ask(method: string, path: string, opts: { token?: string; body?: unknown } = {}) {
  const res = await handle(new Request(`http://127.0.0.1/functions/v1/lite/v1${path}`, {
    method,
    headers: { ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}), "x-forwarded-for": "198.51.100.40" },
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  }));
  const text = await res.text();
  return { status: res.status, cache: res.headers.get("cache-control"), text, body: JSON.parse(text) };
}

/** The fixture's sponsor is a stand-in; the view names the sponsor the API runs with. */
function withSponsor(view: Record<string, unknown>, sponsor: unknown) {
  return { ...view, sponsor };
}

// ------------------------------------------------------------------------------------------------ the account

Deno.test("GET /v1/account: the owner's view is account.json", async () => {
  account(ME, [usdcLine("5.2300000")]);
  const a = await ask("GET", "/account", { token });
  assertEquals([a.status, a.cache], [200, "no-store"]);
  assertEquals(a.body, withSponsor(await fixture("account"), a.body.sponsor));
});

Deno.test("GET /v1/account?address= with no token: the public view, account.public.json, cached 15 s; a token gets the owner's view", async () => {
  account(ME, [usdcLine("5.2300000")]);
  const pub = await ask("GET", `/account?address=${ME}`);
  assertEquals([pub.status, pub.cache], [200, "public, max-age=15"]);
  assertEquals(pub.body, withSponsor(await fixture("account.public"), pub.body.sponsor));
  // With a token, ?address= changes nothing: byte for byte the owner's view.
  const owner = await ask("GET", "/account", { token });
  const named = await ask("GET", `/account?address=${FRIEND}`, { token });
  assertEquals(named.text, owner.text);
  // With neither, the route can't tell whose account it is about.
  const neither = await ask("GET", "/account");
  assertEquals([neither.status, neither.body], [400, await fixture("error-address-required")]);
});

Deno.test("GET /v1/account for an account that doesn't exist yet is account.missing.json", async () => {
  accounts.delete(ME);
  const a = await ask("GET", "/account", { token });
  assertEquals(a.body, { ...withSponsor(await fixture("account.missing"), a.body.sponsor), view: "owner" });
});

Deno.test("POST /v1/account/activate with nothing to do answers the account: account-activate.json", async () => {
  account(ME, [usdcLine("5.2300000")]);
  const a = await ask("POST", "/account/activate", { token });
  const expected = await fixture("account-activate");
  assertEquals(a.body, { status: "active", account: { ...withSponsor(expected.account, a.body.account.sponsor), view: "owner" } });
});

Deno.test("GET /v1/recipient/:address?asset=USDC for an account without USDC is recipient.json", async () => {
  account(FRIEND, []);
  const a = await ask("GET", `/recipient/${FRIEND}?asset=USDC`, { token });
  assertEquals([a.status, a.body], [200, await fixture("recipient")]);
});

// ------------------------------------------------------------------------------------------------ fees, quotes, plans

Deno.test("GET /v1/fees is fees.json: public, cached 30 s, estimates from the history where there is some", async () => {
  const a = await ask("GET", "/fees");
  assertEquals([a.status, a.cache], [200, "public, max-age=30"]);
  const expected = await fixture("fees");
  // The fixture lists some kinds' basis; the API lists every kind's.
  assertEquals({ ...a.body, estimateBasis: undefined }, { ...expected, estimateBasis: undefined });
  for (const [kind, basis] of Object.entries(expected.estimateBasis)) assertEquals(a.body.estimateBasis[kind], basis, kind);
  assertEquals(Object.keys(a.body.estimateBasis).sort(), Object.keys(expected.estimates).sort());
});

Deno.test("POST /v1/swap/quote is swap-quote.json: every venue's route, what needs enabling, the starter swap", async () => {
  account(ME, [usdcLine("5.2300000")]);
  const a = await ask("POST", "/swap/quote", { token, body: { sell: "XLM", buy: "USDC", amount: "100000000", slippageBps: 50 } });
  assertEquals([a.status, a.body], [200, await fixture("swap-quote")]);
});

/** What a built step's envelope says, for comparison with a fixture's. */
function said(step: { xdr: string; maxFee: string }) {
  const tx = TransactionBuilder.fromXDR(step.xdr, PASS) as Transaction;
  assertEquals(step.maxFee, tx.fee, "a built step's maxFee is its transaction's fee");
  const memo = tx.memo.type === "none" ? null : { type: tx.memo.type, value: tx.memo.value?.toString() };
  const ops = tx.operations.map((o: any) => ({ type: o.type, destination: o.destination, amount: o.amount, line: o.line?.toString(), asset: o.asset?.toString() }));
  return { source: tx.source, memo, ops };
}

/** A plan without what building afresh changes: ids, times, envelopes, and the fees, which said() checks instead. */
function steady(plan: any) {
  const steps = plan.steps.map(({ xdr: _x, hash: _h, builtAt: _b, maxFee, ...s }: any) => ({ ...s, ...(s.status === "built" ? {} : { maxFee }) }));
  return { kind: plan.kind, steps, sponsored: plan.fees.sponsored, newReserves: plan.fees.newReserves };
}

Deno.test("POST /v1/send is plan-send.json: the destination and memo bound, paid by the user", async () => {
  account(ME, [usdcLine("5.2300000")]);
  account(FRIEND, [usdcLine("0.0000000")]);
  const a = await ask("POST", "/send", { token, body: { asset: "USDC", to: FRIEND, amount: "125000000", memo: "invoice 42" } });
  assertEquals(a.status, 200, a.text);
  const expected = await fixture("plan-send");
  assertEquals(steady(a.body), steady(expected));
  assertEquals(said(a.body.steps[0]), said(expected.steps[0]));
  assertEquals(a.body.fees.userMax, a.body.steps[0].maxFee);
});

Deno.test("POST /v1/swap/build is plan.json: USDC enabled first at the user's cost, the swap priced at its ceiling", async () => {
  account(ME, []);
  const a = await ask("POST", "/swap/build", { token, body: { quoteId: QUOTE_ID } });
  assertEquals(a.status, 200, a.text);
  const expected = await fixture("plan");
  // The fixture's swap step is labelled "Swap"; the API says which venue.
  assertEquals(a.body.steps[1].label, "Swap via Soroswap");
  const relabel = (p: any) => ({ ...p, steps: p.steps.map((s: any) => ({ ...s, label: s.id === "s2" ? "Swap" : s.label })) });
  assertEquals(steady(relabel(a.body)), steady(expected));
  assertEquals(said(a.body.steps[0]), said(expected.steps[0]));
  assertEquals(BigInt(a.body.fees.userMax), BigInt(a.body.steps[0].maxFee) + BigInt(a.body.steps[1].maxFee));
  assert(a.body.steps[1].xdr === undefined);
});
