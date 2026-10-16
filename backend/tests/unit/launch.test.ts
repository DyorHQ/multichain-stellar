// The launchpad (docs/DESIGN-stellar-parity.md §6.9, §6.11, §6.13, §12.5):
// - decoding of the launchpad's events, from events recorded on testnet on 2026-10-13 (ECAT's launch, a buy, a sell,
//   its graduation and its creator's claim): launch, trade, graduate and claim_creator;
// - what the indexer adds to a launch: listed (never a smoke launch), look_alike, metadata joined by URI (only what its
//   creator wrote for its name and ticker, or an image its creator uploaded);
// - the launchpad's own refusals get their stable codes, from simulation errors recorded on testnet: a failure further
//   down (a missing account) and another contract's get none;
// - economics are read live from the contracts (a fake RPC), kept 5 minutes, served from the last read when RPC fails,
//   and never carry the admin;
// - quotes give every fee apart and what a full curve leaves of a buy;
// - curve buys and sells act for the user and bind the client's minimum, as the verifier's call rules read them; the
//   graduation is the user's to call; only a creator claims;
// - create and metadata rules: the URI, links, the image's place;
// - positions: average cost basis and P&L over curve trades and pool swaps.
import { Address, Keypair, nativeToScVal, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { native, sponsor } = await import("../../supabase/functions/_shared/stellar.ts");
const { verifyTransaction } = await import("../../supabase/functions/_shared/verify.ts");
const lp = await import("../../supabase/functions/_shared/launchpad.ts");
const meta = await import("../../supabase/functions/_shared/launch_metadata.ts");
const { economics, forgetEconomics, ECONOMICS_TTL_MS } = await import("../../supabase/functions/_shared/economics.ts");
const h = await import("../../supabase/functions/lite-indexer/handlers/launchpad.ts");

const PAD = TESTNET.contracts.launchpad!;
const MOMENTS = TESTNET.contracts.moments!;
const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!.contract;
const ECAT = "CBL376OVOTNZA25S3ZFHIQKPLQ3XFV5SLQTHUWZPF25W2354QY4B4ZZD";
const CREATOR = "GDABJYDYBMINC3AFSTMUB3LN2E3TCENU6UCCQ6IJLF55V76A7DZJOXHG";
const PAIR = "CDHZ5QEC3KLKU5BF65YXQ664UXND3Z66GW3WT7Y4JPXZOIOB3MGLLFIN";
const ME = USER.publicKey();
const ADMIN = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(9) as any).publicKey();
const TREASURY = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(8) as any).publicKey();

// ------------------------------------------------------------------------------------------------ recorded events

/** ECAT on testnet (launchpad CDZD53…, 2026-10-13): topics and value as RPC's getEvents gave them. */
const RECORDED = {
  launch: {
    id: "0022221709818023936-0000000001",
    ledger: 5173895,
    ledgerClosedAt: "2026-10-13T12:04:22Z",
    txHash: "38dbf5eab57efa558e1d70654f3dea0d980c7f8f5713db44c08fc161c513372c",
    topic: ["AAAADwAAAAZsYXVuY2gAAA==", "AAAAEgAAAAFXv/nVdNuQa7LeSnRBT1w3cteyXCZ6Wy8uu21vvIY4Hg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc="],
    value:
      "AAAAEQAAAAEAAAAJAAAADwAAAA9jcmVhdG9yX2ZlZV9icHMAAAAAAwAAAGQAAAAPAAAABWluZGV4AAAAAAAAAwAAAAEAAAAPAAAABG5hbWUAAAAOAAAAB0UyRSBDYXQAAAAADwAAAAdwaGFudG9tAAAAAAoAAAAAAAAAAAAAAASoF8gAAAAADwAAAAVxdW90ZQAAAAAAABIAAAAB15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAAPAAAABnN1cHBseQAAAAAACgAAAAAAAAAAACOG8m/BAAAAAAAPAAAABnN5bWJvbAAAAAAADgAAAARFQ0FUAAAADwAAAAl0aHJlc2hvbGQAAAAAAAAKAAAAAAAAAAAAAAAKEaLGMAAAAA8AAAADdXJpAAAAAA4AAAAA",
  },
  buy: {
    id: "0022221709818023936-0000000004",
    ledger: 5173895,
    ledgerClosedAt: "2026-10-13T12:04:22Z",
    txHash: "38dbf5eab57efa558e1d70654f3dea0d980c7f8f5713db44c08fc161c513372c",
    topic: ["AAAADwAAAAV0cmFkZQAAAA==", "AAAAEgAAAAFXv/nVdNuQa7LeSnRBT1w3cteyXCZ6Wy8uu21vvIY4Hg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc="],
    value:
      "AAAAEQAAAAEAAAAHAAAADwAAAARmZWVzAAAACgAAAAAAAAAAAAAAAAExLQAAAAAPAAAABmlzX2J1eQAAAAAAAAAAAAEAAAAPAAAADHF1b3RlX2Ftb3VudAAAAAoAAAAAAAAAAAAAAAA7msoAAAAADwAAAA1xdW90ZV9yZXNlcnZlAAAAAAAACgAAAAAAAAAAAAAABOKBZQAAAAAPAAAACnJlYWxfcXVvdGUAAAAAAAoAAAAAAAAAAAAAAAA6aZ0AAAAADwAAAAx0b2tlbl9hbW91bnQAAAAKAAAAAAAAAAAAAajV4RoZIgAAAA8AAAANdG9rZW5fcmVzZXJ2ZQAAAAAAAAoAAAAAAAAAAAAh3hyOpube",
  },
  sell: {
    id: "0022221718407925760-0000000002",
    ledger: 5173897,
    ledgerClosedAt: "2026-10-13T12:04:32Z",
    txHash: "ede968deccf383ce138d77f5037bf76b328eec51aa56c6ea413b9cad110576e1",
    topic: ["AAAADwAAAAV0cmFkZQAAAA==", "AAAAEgAAAAFXv/nVdNuQa7LeSnRBT1w3cteyXCZ6Wy8uu21vvIY4Hg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc="],
    value:
      "AAAAEQAAAAEAAAAHAAAADwAAAARmZWVzAAAACgAAAAAAAAAAAAAAAAAfOD4AAAAPAAAABmlzX2J1eQAAAAAAAAAAAAAAAAAPAAAADHF1b3RlX2Ftb3VudAAAAAoAAAAAAAAAAAAAAAAF+cP4AAAADwAAAA1xdW90ZV9yZXNlcnZlAAAAAAAACgAAAAAAAAAAAAAABNxoaMoAAAAPAAAACnJlYWxfcXVvdGUAAAAAAAoAAAAAAAAAAAAAAAA0UKDKAAAADwAAAAx0b2tlbl9hbW91bnQAAAAKAAAAAAAAAAAAACp7ybXPUAAAAA8AAAANdG9rZW5fcmVzZXJ2ZQAAAAAAAAoAAAAAAAAAAAAiCJhYXLYu",
  },
  graduate: {
    id: "0022221726997884928-0000000009",
    ledger: 5173899,
    ledgerClosedAt: "2026-10-13T12:04:42Z",
    txHash: "8b2217f72525fbf3a08af31cff3ef2aaa1f3ef2d170272f569dc510125b580bc",
    topic: ["AAAADwAAAAhncmFkdWF0ZQ==", "AAAAEgAAAAFXv/nVdNuQa7LeSnRBT1w3cteyXCZ6Wy8uu21vvIY4Hg=="],
    value:
      "AAAAEQAAAAEAAAAFAAAADwAAAAZidXJuZWQAAAAAAAoAAAAAAAAAAAADjX6kx/bfAAAADwAAAAlsaXF1aWRpdHkAAAAAAAAKAAAAAAAAAAAAAAjLeOUp0QAAAA8AAAAEcGFpcgAAABIAAAABz57AgtqWqnQl93F4e9yl2j3n3jW3af8cS++XIcHbDLUAAAAPAAAACnBvb2xfcXVvdGUAAAAAAAoAAAAAAAAAAAAAAAoRosYxAAAADwAAAAtwb29sX3Rva2VucwAAAAAKAAAAAAAAAAAAB66Uf9hs4Q==",
  },
  claim: {
    id: "0022221744177741824-0000000001",
    ledger: 5173903,
    ledgerClosedAt: "2026-10-13T12:05:02Z",
    txHash: "eb1dbac56842d100f4606628b00e1c2ec98cfbc2af3caa27b3084f96d0106a4b",
    topic: ["AAAADwAAAA1jbGFpbV9jcmVhdG9yAAAA", "AAAAEgAAAAFXv/nVdNuQa7LeSnRBT1w3cteyXCZ6Wy8uu21vvIY4Hg==", "AAAAEgAAAAAAAAAAwBTgeAsQ0WwFlNlA7W3RNzERtPUEKHkJWXva/8D48pc="],
    value: "AAAAEQAAAAEAAAABAAAADwAAAAZhbW91bnQAAAAAAAoAAAAAAAAAAAAAAAAno253",
  },
};

/** A recorded event as main_events.ts hands it to the handler. */
function contractEvent(r: { id: string; ledger: number; ledgerClosedAt: string; txHash: string; topic: string[]; value: string }) {
  const topics = r.topic.map((t) => native(xdr.ScVal.fromXDR(t, "base64")));
  return { raw: { id: r.id, ledger: r.ledger, txHash: r.txHash }, kind: String(topics[0]), topics, data: native(xdr.ScVal.fromXDR(r.value, "base64")), ts: new Date(r.ledgerClosedAt) };
}

/** Simulation errors recorded on testnet, as the API keeps them (detail.raw: the first 600 characters). */
const errorLog = (code: number, data: string) =>
  `HostError: Error(Contract, #${code})\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${PAD}, topics:[error, Error(Contract, #${code})], data:"escalating error to VM trap from failed host function call: fail_with_error"\n   1: [Diagnostic Event] contract:${PAD}, topics:[error, Error(Contract, #${code})], data:${data}\n   2: [Diagnostic Event] topics:[fn_call, ${PAD}, buy], data:[GBDWDUE33LK4FO4EPLRXQBEXN6HH2NUXW7XHTNV52OHWO`;
const RECORDED_ERRORS = {
  slippage: errorLog(10, `["failing with contract error", 10]`),
  closed: errorLog(8, `["failing with contract error", 8]`),
  nothing: errorLog(16, `["failing with contract error", 16]`),
  disabled: errorLog(2, `["failing with contract error", 2]`),
  unknown: errorLog(7, `["failing with contract error", 7]`),
  // A buy by an account that doesn't exist: the XLM contract fails (#6 there), the launchpad only passes it on.
  noAccount:
    `HostError: Error(Contract, #6)\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${PAD}, topics:[error, Error(Contract, #6)], data:"escalating error to VM trap from failed host function call: call"\n   1: [Diagnostic Event] contract:${PAD}, topics:[error, Error(Contract, #6)], data:["contract call failed", transfer, [GBDWDUE33LK4FO4EPLRXQBEXN6HH2NUXW7XHTNV52OHWOCZBP274RAHC, ${PAD}, 10000000]]\n   2: [Failed Diagnostic Event (not emitted)`,
};

// ------------------------------------------------------------------------------------------------ a fake RPC and storage

const i128 = (n: bigint) => nativeToScVal(n, { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const addr = (a: string) => new Address(a).toScVal();
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));

type Answer = xdr.ScVal | { error: string };
/** How the fake RPC answers a contract call; every call is counted in `calls`. */
let answer: (contract: string, fn: string, args: xdr.ScVal[]) => Answer = () => ({ error: "HostError: Error(Contract, #1)" });
let calls: string[] = [];
let rpcDown = false;
/** What the fake storage was given. */
const stored: { path: string; type: string | null; body: string }[] = [];

function simulate(transaction: string) {
  const tx = TransactionBuilder.fromXDR(transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fn = call.functionName().toString();
  calls.push(`${fn}@${contract.slice(0, 6)}`);
  const a = answer(contract, fn, call.args());
  if (!(a instanceof xdr.ScVal)) return { latestLedger: 1, error: a.error };
  return {
    latestLedger: 1,
    minResourceFee: "1000",
    transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
    results: [{ auth: [], xdr: a.toXDR("base64") }],
    events: [],
  };
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
  if (url.host === "soroban-testnet.stellar.org") {
    if (rpcDown) return new Response("unavailable", { status: 503 });
    const body = await req.json();
    const result = body.method === "simulateTransaction"
      ? simulate(body.params.transaction)
      : body.method === "getLedgerEntries"
      ? accountEntry(ME)
      : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  if (url.origin === STORAGE && url.pathname.startsWith("/storage/v1/object/lite-media/")) {
    stored.push({ path: url.pathname.slice("/storage/v1/object/lite-media/".length), type: req.headers.get("content-type"), body: await req.text() });
    return Response.json({ Key: url.pathname });
  }
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** The database: answers by query, and remembers every write. */
let respond: (q: string, p: unknown[]) => Row[] = () => [];
const writes: [string, unknown[]][] = [];
replaceSql(fakeSql((q, p) => {
  if (/^(insert|update|delete)/.test(q)) writes.push([q, p]);
  return respond(q, p);
}));

const LAUNCH_OF_ECAT = (q: string) => (q === "select l.quote, l.symbol, l.creator from lite.launches l where l.token = ? and l.launch_index is not null" ? [{ quote: XLM, symbol: "ECAT", creator: CREATOR }] : null);

// ------------------------------------------------------------------------------------------------ decoding

Deno.test("decode: launch, from ECAT's recorded event", () => {
  assertEquals(h.decodeLaunch(contractEvent(RECORDED.launch)), {
    token: ECAT,
    creator: CREATOR,
    quote: XLM,
    name: "E2E Cat",
    symbol: "ECAT",
    uri: "",
    index: 1,
    supply: 10_000_000_000_000_000n,
    phantom: 20_000_000_000n,
    threshold: 43_245_553_200n,
    creatorFeeBps: 100,
  });
});

Deno.test("decode: trade, a buy and a sell, priced at the curve's reserves after it", () => {
  const buy = h.decodeTrade(contractEvent(RECORDED.buy));
  assertEquals(buy, {
    token: ECAT,
    trader: CREATOR,
    side: "buy",
    quoteAmount: 1_000_000_000n,
    tokenAmount: 467_111_534_795_042n,
    fees: 20_000_000n,
    quoteReserve: 20_980_000_000n,
    tokenReserve: 9_532_888_465_204_958n,
    realQuote: 980_000_000n,
    price: lp.ratio(20_980_000_000n, 9_532_888_465_204_958n),
  });
  assertEquals(buy.price, "0.000002200801999999");
  const sell = h.decodeTrade(contractEvent(RECORDED.sell));
  assertEquals([sell.side, sell.quoteAmount, sell.tokenAmount, sell.fees, sell.realQuote], ["sell", 100_254_712n, 46_711_153_479_504n, 2_046_014n, 877_699_274n]);
});

Deno.test("decode: graduate, the pool's opening reserves priced at the curve's final price; claim_creator", () => {
  const g = h.decodeGraduate(contractEvent(RECORDED.graduate));
  assertEquals(g, {
    token: ECAT,
    pair: PAIR,
    poolTokens: 2_162_277_660_257_505n,
    poolQuote: 43_245_553_201n,
    liquidity: 9_669_999_667_665n,
    burned: 1_000_000_000_095_967n,
    price: lp.ratio(43_245_553_201n, 2_162_277_660_257_505n),
  });
  // The curve's last trade left the same price: the pool opens where the curve ended.
  const last = 63_245_553_201n * 10n ** 18n / 3_162_277_660_353_472n;
  assert(lp.scaled(g.price) - last <= 10n ** 10n, `${g.price} against the curve's ${lp.decimalText(last)}`);
  assertEquals(h.decodeClaim(contractEvent(RECORDED.claim)), { token: ECAT, creator: CREATOR, amount: 665_022_071n });
});

Deno.test("recording a launch: listed unless the deployment made it as a smoke test, look_alike, the metadata by URI, its token watched", async () => {
  const uri = `${STORAGE}/storage/v1/object/public/lite-media/launches/${CREATOR}/aef9135a-6c53-435a-a2e4-5bb339faa0e1.json`;
  const written = { address: CREATOR, name: "E2E Cat", symbol: "ECAT", image: `${STORAGE}/storage/v1/object/public/lite-media/uploads/${CREATOR}/b4.png`, description: "A cat.", links: { website: "https://ecat.dyorhq.fun" } };
  respond = (q, p) => (q === "select address, name, symbol, image, description, links from lite.launch_metadata where uri = ?" && p[0] === uri ? [written] : []);
  const ecat = { token: ECAT, creator: CREATOR, name: "E2E Cat", symbol: "ECAT", uri };
  const smoke = { ...TESTNET, deployment: { ...TESTNET.deployment!, smoke: { launches: [ECAT], moments: [] } } };
  assertEquals(await h.launchFacts(ecat, smoke), {
    listed: false,
    lookAlike: false,
    image: `${STORAGE}/storage/v1/object/public/lite-media/uploads/${CREATOR}/b4.png`,
    description: "A cat.",
    links: { website: "https://ecat.dyorhq.fun", x: null, telegram: null },
  });
  assertEquals((await h.launchFacts({ ...ecat, symbol: "U5DC", uri: "" }, TESTNET)).listed, true);
  assertEquals((await h.launchFacts({ ...ecat, symbol: "U5DC", uri: "" }, TESTNET)).lookAlike, true);
  // Create's rule, for a launch made on the contract directly too: someone else's metadata, or the creator's for
  // another name or ticker, shows nothing.
  const none = { image: null, description: null, links: null };
  const facts = async (launch: typeof ecat) => {
    const f = await h.launchFacts(launch, TESTNET);
    return { image: f.image, description: f.description, links: f.links };
  };
  assertEquals(await facts({ ...ecat, creator: ME }), none);
  assertEquals(await facts({ ...ecat, name: "Another Cat" }), none);
  assertEquals(await facts({ ...ecat, symbol: "ECAT2" }), none);
  // An older app put the uploaded image itself in the URI: that is the image, when the creator uploaded it.
  const image = `${STORAGE}/storage/v1/object/public/lite-media/uploads/${CREATOR}/c1.jpg`;
  respond = () => [];
  assertEquals(await meta.metadataFor(image, ecat), { image, description: null, links: null });
  assertEquals(await meta.metadataFor(image, { ...ecat, creator: ME }), none);
  assertEquals(await meta.metadataFor(`${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/../${CREATOR}/c1.jpg`, { ...ecat, creator: ME }), none);
  assertEquals(await meta.metadataFor("https://elsewhere.example/cat.png", ecat), none);

  // The handler: the row (terms from get_launch), then the token watched from the launch's ledger.
  answer = (contract, fn) => (contract === PAD && fn === "get_launch" ? struct({ fee_bps: u32(100), protocol_share_bps: u32(5000) }) : { error: "HostError: Error(Contract, #1)" });
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.launch));
  const [insert, watch] = writes;
  assert(insert[0].startsWith("insert into lite.launches"), insert[0]);
  assertEquals(insert[1].slice(0, 6), [ECAT, CREATOR, XLM, "E2E Cat", "ECAT", ""]);
  assertEquals(insert[1].slice(15, 19), [100, 5000, true, false]);
  assertEquals([watch[0].startsWith("insert into lite.watch_contracts"), watch[1]], [true, [ECAT, "token", ECAT, 5173895]]);
  // Fee terms that can't be read are left for the watch job, never the event unrecorded.
  answer = () => ({ error: "HostError: Error(Contract, #1)" });
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.launch));
  assertEquals(writes[0][1].slice(15, 17), [null, null]);
});

Deno.test("recording a trade, a graduation and a claim: each once, by event id", async () => {
  respond = (q) => (q.startsWith("insert into lite.launch_trades") || q.startsWith("insert into lite.creator_claims") ? [{ event_id: "x" }] : []);
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.buy));
  assertEquals(writes.map(([q]) => q.split(" ").slice(0, 3).join(" ")), ["insert into lite.launch_trades", "update lite.launches set"]);
  assert(writes[1][0].includes("last_trade_at = greatest(last_trade_at, ?)"));
  // Read again: the trade is already there, the launch isn't moved twice.
  respond = () => [];
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.buy));
  assertEquals(writes.length, 1);
  // The graduation reads the pair's token_0 once, and watches the pair.
  answer = (contract, fn) => (contract === PAIR && fn === "token_0" ? addr(ECAT) : { error: "HostError: Error(Contract, #1)" });
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.graduate));
  assert(writes[0][0].startsWith("update lite.launches set graduated = true"));
  assert(writes[0][1].includes(true), "token_0 is the launch token");
  assertEquals(writes[1][1], [PAIR, "pair", ECAT, 5173899]);
  respond = (q) => (q.startsWith("insert into lite.creator_claims") ? [{ event_id: "x" }] : []);
  writes.length = 0;
  await h.launchpadEvent(contractEvent(RECORDED.claim));
  assertEquals(writes[1][1], ["665022071", ECAT]);
});

// ------------------------------------------------------------------------------------------------ refusals

Deno.test("refusals: the launchpad's own errors get their stable codes, a failure further down none", () => {
  assertEquals(lp.launchRefusal(RECORDED_ERRORS.slippage, PAD), "launch.slippage");
  assertEquals(lp.launchRefusal(RECORDED_ERRORS.closed, PAD), "launch.closed");
  assertEquals(lp.launchRefusal(RECORDED_ERRORS.nothing, PAD), "launch.nothing_to_claim");
  assertEquals(lp.launchRefusal(RECORDED_ERRORS.disabled, PAD), "launch.disabled");
  assertEquals([lp.launchRefusal(RECORDED_ERRORS.unknown, PAD), lp.launchpadError(RECORDED_ERRORS.unknown, PAD)], [null, 7]);
  assertEquals([lp.launchRefusal(RECORDED_ERRORS.noAccount, PAD), lp.launchpadError(RECORDED_ERRORS.noAccount, PAD)], [null, null]);
  // Another contract's refusal, whatever its number.
  assertEquals(lp.launchRefusal(RECORDED_ERRORS.slippage.replaceAll(PAD, MOMENTS), PAD), null);
});

Deno.test("refusals reach the client as simulation_failed with the contract's code (error-contract.json's shape)", async () => {
  answer = (contract, fn) => (contract === PAD && fn === "quote_buy" ? { error: RECORDED_ERRORS.closed } : { error: "HostError: Error(Contract, #1)" });
  const err = await lp.quoteTrade(ME, ECAT, "buy", 10_000_000n).catch((e) => e);
  assert(err instanceof ApiError);
  assertEquals([err.status, err.code, err.message, err.detail], [422, "simulation_failed", "This curve isn't taking trades now.", { contractCode: "launch.closed", raw: RECORDED_ERRORS.closed }]);
  // A sell quote on a curve that no longer trades is refused the same way, without asking for the quote.
  lp.forgetLaunchReads();
  answer = (contract, fn) => (contract === PAD && fn === "get_curve" ? struct({ completed: xdr.ScVal.scvBool(true), graduated: xdr.ScVal.scvBool(true), creator_fees: i128(0n) }) : { error: "x" });
  calls = [];
  const sell = await lp.quoteTrade(ME, ECAT, "sell", 10_000_000n).catch((e) => e);
  assertEquals([sell.code, sell.detail.contractCode, calls], ["simulation_failed", "launch.closed", [`get_curve@${PAD.slice(0, 6)}`]]);
  // Anything else keeps the simulation's own message.
  answer = () => ({ error: RECORDED_ERRORS.noAccount });
  const other = await lp.quoteTrade(ME, ECAT, "buy", 10_000_000n).catch((e) => e);
  assertEquals([other.code, other.detail.contractCode], ["simulation_failed", undefined]);
});

// ------------------------------------------------------------------------------------------------ quotes

Deno.test("quotes: every fee apart, and what a full curve leaves of a buy (refund)", async () => {
  const buyQuote = (used: bigint) => struct({ used: i128(used), net: i128(used - 2_000_000n), base_fee: i128(1_000_000n), creator_fee: i128(1_000_000n), snipe_fee: i128(0n), tokens_out: i128(42n) });
  answer = (_c, fn, args) => (fn === "quote_buy" ? buyQuote(BigInt(native(args[2]))) : { error: "x" });
  assertEquals(await lp.quoteTrade(ME, ECAT, "buy", 100_000_000n), {
    side: "buy",
    used: "100000000",
    tokensOut: "42",
    fees: "2000000",
    snipeFee: "0",
    baseFee: "1000000",
    creatorFee: "1000000",
    refund: "0",
  });
  // The curve fills at 60 of the 100: 40 never leave the wallet.
  answer = (_c, fn) => (fn === "quote_buy" ? buyQuote(60_000_000n) : { error: "x" });
  assertEquals((await lp.quoteTrade(ME, ECAT, "buy", 100_000_000n)).refund, "40000000");
  lp.forgetLaunchReads();
  answer = (_c, fn) =>
    fn === "get_curve"
      ? struct({ completed: xdr.ScVal.scvBool(false), graduated: xdr.ScVal.scvBool(false), creator_fees: i128(0n) })
      : fn === "quote_sell"
      ? struct({ gross: i128(100_000_000n), base_fee: i128(1_000_000n), creator_fee: i128(1_000_000n), quote_out: i128(98_000_000n) })
      : { error: "x" };
  assertEquals(await lp.quoteTrade(ME, ECAT, "sell", 10n ** 12n), { side: "sell", quoteOut: "98000000", fees: "2000000", baseFee: "1000000", creatorFee: "1000000" });
});

// ------------------------------------------------------------------------------------------------ economics

function economicsAnswers(contract: string, fn: string, args: xdr.ScVal[]): Answer {
  const quote = args[0] ? Address.fromScVal(args[0]).toString() : null;
  if (contract === PAD && fn === "config") {
    return struct({
      admin: addr(ADMIN),
      treasury: addr(TREASURY),
      token_wasm_hash: xdr.ScVal.scvBytes(Buffer.alloc(32, 1)),
      soroswap_factory: addr(TESTNET.contracts.soroswapFactory),
      supply: i128(10_000_000_000_000_000n),
      fee_bps: u32(100),
      protocol_share_bps: u32(5000),
      max_creator_fee_bps: u32(1000),
      snipe_schedule: xdr.ScVal.scvVec([u32(9800), u32(2500), u32(300), u32(30)]),
      launches_enabled: xdr.ScVal.scvBool(true),
    });
  }
  if (contract === PAD && fn === "quote_economics") {
    if (quote === XLM) return struct({ phantom: i128(20_000_000_000n), threshold: i128(43_245_553_200n), enabled: xdr.ScVal.scvBool(true) });
    return xdr.ScVal.scvVoid();
  }
  if (contract === MOMENTS && fn === "config") {
    return struct({ admin: addr(ADMIN), treasury: addr(TREASURY), platform_bps: u32(500), royalty_bps: u32(500), publishing_enabled: xdr.ScVal.scvBool(false) });
  }
  if (contract === MOMENTS && fn === "quote_rule") return struct({ min_price: i128(quote === XLM ? 1_000_000n : 100_000n), enabled: xdr.ScVal.scvBool(quote === XLM) });
  return { error: "HostError: Error(Contract, #1)" };
}

Deno.test("economics: read live from both contracts, terms as they are (a quote without terms left out), never the admin", async () => {
  forgetEconomics();
  answer = economicsAnswers;
  calls = [];
  const e = await economics(TESTNET, 1_000_000);
  assertEquals(e, {
    launchpad: {
      contract: PAD,
      launchesEnabled: true,
      supply: "10000000000000000",
      feeBps: 100,
      protocolShareBps: 5000,
      maxCreatorFeeBps: 1000,
      snipeSchedule: [9800, 2500, 300, 30],
      quotes: [{ asset: "XLM", contract: XLM, phantom: "20000000000", threshold: "43245553200", enabled: true }],
    },
    moments: {
      contract: MOMENTS,
      platformBps: 500,
      royaltyBps: 500,
      publishingEnabled: false,
      treasury: TREASURY,
      maxPerCollect: 20,
      maxEditions: 100000,
      quotes: [{ asset: "XLM", minPrice: "1000000", enabled: true }, { asset: "USDC", minPrice: "100000", enabled: false }],
    },
  });
  assertEquals(calls.length, 6);
  const text = JSON.stringify(e);
  assert(!text.includes("admin") && !text.includes(ADMIN), "the admin is never served");
  assert(!JSON.stringify(e.launchpad).includes(TREASURY), "the launchpad's treasury isn't served");
});

Deno.test("economics: kept 5 minutes; when RPC fails, the last read is served, and without one 502 rpc_unavailable", async () => {
  forgetEconomics();
  answer = economicsAnswers;
  calls = [];
  const first = await economics(TESTNET, 1_000_000);
  await economics(TESTNET, 1_000_000 + ECONOMICS_TTL_MS - 1);
  assertEquals(calls.length, 6, "read once in 5 minutes");
  await economics(TESTNET, 1_000_000 + ECONOMICS_TTL_MS);
  assertEquals(calls.length, 12, "read again after 5 minutes");
  rpcDown = true;
  try {
    assertEquals(await economics(TESTNET, 1_000_000 + 3 * ECONOMICS_TTL_MS), first);
    forgetEconomics();
    const err = await economics(TESTNET, 1_000_000).catch((e) => e);
    assertEquals([err.status, err.code], [502, "rpc_unavailable"]);
  } finally {
    rpcDown = false;
  }
  // Where nothing is deployed, nothing is read.
  forgetEconomics();
  calls = [];
  const none = { ...TESTNET, contracts: { ...TESTNET.contracts, launchpad: null, moments: null } };
  assertEquals([await economics(none, 1_000_000), calls], [{ launchpad: null, moments: null }, []]);
});

// ------------------------------------------------------------------------------------------------ plans

/** The verifier's context for a launch step, as the phone checks it (the launch token allowed). */
const verifyCtx = (token: string) => ({
  user: ME,
  sponsor: sponsor().publicKey(),
  passphrase: TESTNET.passphrase,
  allowedContracts: new Set([...Object.values({ pad: PAD }), XLM, USDC, token]),
});

Deno.test("buy and sell act for the user and bind the client's minimum where the verifier's call rules read it", async () => {
  respond = (q) => LAUNCH_OF_ECAT(q) ?? [];
  answer = (contract, fn) => (contract === PAD && (fn === "buy" || fn === "sell") ? i128(1n) : { error: "x" });
  const buy = await lp.launchBuyStep(ME, { kind: "launch_buy", token: ECAT, amount: "500000000", minOut: "11880000000000" });
  assertEquals([buy.intent.spend, buy.intent.receive], [{ [XLM]: "500000000" }, { [ECAT]: "11880000000000" }]);
  assertEquals(buy.intent.display, { token: ECAT, symbol: "ECAT", quote: "XLM", amount: "500000000", minOut: "11880000000000" });
  verifyTransaction(buy.tx, buy.intent, verifyCtx(ECAT));
  const args = (buy.tx.operations[0] as any).func.invokeContract().args().map(native);
  assertEquals(args, [ME, ECAT, 500_000_000n, 11_880_000_000_000n]);
  // A receive the call doesn't honour is refused.
  assertRejectsVerify(buy.tx, { ...buy.intent, receive: { [ECAT]: "11880000000001" } }, ECAT, "the minimum received is lower than quoted");

  const sell = await lp.launchSellStep(ME, { kind: "launch_sell", token: ECAT, amount: "1000000000000", minOut: "49000000" });
  assertEquals([sell.intent.spend, sell.intent.receive], [{ [ECAT]: "1000000000000" }, { [XLM]: "49000000" }]);
  verifyTransaction(sell.tx, sell.intent, verifyCtx(ECAT));
  assertEquals((sell.tx.operations[0] as any).func.invokeContract().args().map(native), [ME, ECAT, 1_000_000_000_000n, 49_000_000n]);
});

function assertRejectsVerify(tx: Transaction, intent: any, token: string, message: string) {
  try {
    verifyTransaction(tx, intent, verifyCtx(token));
  } catch (err) {
    assertEquals((err as Error).message, message);
    return;
  }
  throw new Error("verified");
}

Deno.test("create acts for the creator; graduation is any user's to call; claims are per launch, the creator's only", async () => {
  respond = (q) => LAUNCH_OF_ECAT(q) ?? [];
  answer = (contract, fn) => (contract === PAD && ["launch", "graduate", "claim_creator_fees", "get_curve"].includes(fn) ? (fn === "get_curve" ? struct({ creator_fees: i128(3_900_000n) }) : i128(1n)) : { error: "x" });
  const create = await lp.launchCreateStep(ME, { kind: "launch_create", quote: XLM, name: "E2E Cat", symbol: "ECAT", uri: "", creatorFeeBps: 100, initialBuy: "100000000", minOut: "0" });
  // A new v1 launch passes v1's rules only while v2 isn't pinned; once it is, new launches are v2's.
  verifyTransaction(create.tx, create.intent, { ...verifyCtx(ECAT), v2: null });
  assertRejectsVerify(create.tx, create.intent, ECAT, "this generation no longer takes new launches or Moments");
  assertEquals([create.intent.spend, (create.tx.operations[0] as any).func.invokeContract().args().map(native)[0]], [{ [XLM]: "100000000" }, ME]);
  const grad = await lp.launchGraduateStep(ME, { kind: "launch_graduate", token: ECAT });
  verifyTransaction(grad.tx, grad.intent, verifyCtx(ECAT));
  assertEquals([grad.intent.kind, grad.intent.spend, (grad.tx.operations[0] as any).func.invokeContract().args().map(native)], ["launch_graduate", {}, [ECAT]]);
  lp.forgetLaunchReads();
  const claim = await lp.launchClaimStep(CREATOR, { kind: "launch_claim", token: ECAT });
  assertEquals(claim.intent.display, { token: ECAT, symbol: "ECAT", quote: "XLM", amount: "3900000", to: CREATOR });

  // Only the coin's creator builds a claim.
  const notCreator = await lp.buildLaunch(ME, { action: "claim", token: ECAT }).catch((e) => e);
  assertEquals([notCreator.status, notCreator.code], [400, "bad_arg"]);
  // Claim all with nothing waiting: the contract's own answer.
  lp.forgetLaunchReads();
  respond = (q) => (q.startsWith("select l.token, l.symbol from lite.launches l where l.creator = ? and l.launch_index is not null") ? [{ token: ECAT, symbol: "ECAT" }] : []);
  answer = (_c, fn) => (fn === "get_curve" ? struct({ creator_fees: i128(0n) }) : { error: "x" });
  const nothing = await lp.buildLaunch(CREATOR, { action: "claim" }).catch((e) => e);
  assertEquals([nothing.status, nothing.code, nothing.detail.contractCode], [422, "simulation_failed", "launch.nothing_to_claim"]);
});

Deno.test("create's rules: a URI this creator's metadata wrote for this name and ticker, a ticker that doesn't look reserved", async () => {
  const uri = `${STORAGE}/storage/v1/object/public/lite-media/launches/${ME}/aef9135a.json`;
  respond = (q, p) => (q === "select address, name, symbol from lite.launch_metadata where uri = ?" && p[0] === uri ? [{ address: ME, name: "E2E Cat", symbol: "ECAT" }] : []);
  const refused = async (input: Record<string, unknown>, user = ME) => {
    const err = await lp.buildLaunch(user, { action: "create", quote: "XLM", name: "E2E Cat", symbol: "ECAT", ...input } as any).catch((e) => e);
    assert(err instanceof ApiError, String(err));
    return [err.status, err.code];
  };
  assertEquals(await refused({ uri }, CREATOR), [400, "bad_uri"]);
  assertEquals(await refused({ uri, name: "Another Cat" }), [400, "bad_uri"]);
  assertEquals(await refused({ uri: `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/b4.png` }), [400, "bad_uri"]);
  assertEquals(await refused({ symbol: "U5DC" }), [400, "look_alike_symbol"]);
  assertEquals(await refused({ symbol: "E" }), [422, "bad_symbol"]);
  assertEquals(await refused({ name: "🐱".repeat(9) }), [400, "bad_name"]);
  assertEquals(await refused({ creatorFeeBps: 1001 }), [400, "bad_fee"]);
  assertEquals(await refused({ quote: "BUSDC" }), [400, "bad_quote"]);
  assertEquals(await refused({ amount: "1.5" }), [400, "bad_amount"]);
  // Buy and sell need the client's minimum.
  const noMin = await lp.buildLaunch(ME, { action: "buy", token: ECAT, amount: "1000" }).catch((e) => e);
  assertEquals([noMin.status, noMin.code], [400, "bad_amount"]);
});

// ------------------------------------------------------------------------------------------------ metadata

Deno.test("a v1 ticker is 2-10 ASCII letters or digits, refused first (422 bad_symbol): Soroswap reads the symbol as UTF-8", async () => {
  respond = () => [];
  const refused = async (symbol: unknown, input: Record<string, unknown> = {}) => {
    const err = await lp.buildLaunch(ME, { action: "create", quote: "XLM", name: "E2E Cat", symbol, ...input } as any).catch((e) => e);
    assert(err instanceof ApiError, String(err));
    return [err.status, err.code, err.message];
  };
  const SAID = [422, "bad_symbol", "Use 2 to 10 letters or digits for the symbol."];
  // Too short or long, punctuation, spaces inside, and letters outside ASCII, even those whose upper case is ASCII
  // ("ß" is "SS", the dotless "ı" is "I").
  for (const symbol of ["E", "ABCDEFGHIJK", "EC-AT", "EC AT", "ÉCAT", "ßCAT", "ıCAT", "ＥＣＡＴ", "🐱CAT", "", undefined, 7]) {
    assertEquals(await refused(symbol), SAID, String(symbol));
  }
  // Before anything else: a name, fee or quote that would be refused too isn't what is said.
  assertEquals(await refused("ÉCAT", { name: "", creatorFeeBps: 5_000, quote: "BUSDC" }), SAID);
  // Letters in either case and digits pass on to the rest of the rules (here: the ticker is upper-cased and allowed).
  assertEquals(lp.v1LaunchSymbol(" ecat2 "), "ecat2");
  assertEquals(lp.v1LaunchSymbol("AB"), "AB");
  assertEquals(lp.v1LaunchSymbol("ABCDEFGHIJ"), "ABCDEFGHIJ");
});

Deno.test("metadata: written as {name, symbol, description, image, links} under launches/<address>/, recorded by its URI", async () => {
  const image = `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/b4e32bb4.png`;
  respond = () => [];
  writes.length = 0;
  stored.length = 0;
  const { uri } = await meta.writeLaunchMetadata(ME, {
    name: "E2E Cat",
    symbol: "ecat",
    description: "A cat that runs end-to-end tests.",
    imageUrl: image,
    website: "https://ecat.dyorhq.fun",
    x: "https://x.com/ecat",
  });
  assert(new RegExp(`^${STORAGE}/storage/v1/object/public/lite-media/launches/${ME}/[0-9a-f-]{36}\\.json$`).test(uri), uri);
  assertEquals(stored.length, 1);
  assertEquals([stored[0].type, JSON.parse(stored[0].body)], ["application/json", {
    name: "E2E Cat",
    symbol: "ECAT",
    description: "A cat that runs end-to-end tests.",
    image,
    links: { website: "https://ecat.dyorhq.fun/", x: "https://x.com/ecat", telegram: null },
  }]);
  assertEquals(writes[0][1].slice(0, 6), [uri, ME, "E2E Cat", "ECAT", "A cat that runs end-to-end tests.", image]);
});

Deno.test("metadata's rules: links https and to their own sites, at most 200 characters; the image this address uploaded; 500 characters of description", async () => {
  const refused = async (input: Record<string, unknown>) => {
    const err = await meta.writeLaunchMetadata(ME, { name: "E2E Cat", symbol: "ECAT", ...input }).catch((e) => e);
    assert(err instanceof ApiError, `${JSON.stringify(input)}: ${err}`);
    return [err.status, err.code];
  };
  for (
    const input of [
      { website: "http://ecat.dyorhq.fun" },
      { website: "https://user:pass@ecat.dyorhq.fun" },
      { website: `https://ecat.dyorhq.fun/${"a".repeat(200)}` },
      { website: "not a link" },
      { x: "https://twitter.example/ecat" },
      { x: "https://x.com" },
      { telegram: "https://telegram.me/ecat" },
      { description: "a".repeat(501) },
    ]
  ) assertEquals(await refused(input), [400, "bad_arg"], JSON.stringify(input));
  for (
    const imageUrl of [
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${CREATOR}/b4.png`,
      `${STORAGE}/storage/v1/object/public/lite-media/moments/${ME}/b4.png`,
      `https://elsewhere.example/storage/v1/object/public/lite-media/uploads/${ME}/b4.png`,
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/b4.mp4`,
      // Under this address's folder by its prefix only: another's file, a folder below, a query.
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/../${CREATOR}/b4.png`,
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/%2e%2e/${CREATOR}/b4.png`,
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/x/b4.png`,
      `${STORAGE}/storage/v1/object/public/lite-media/uploads/${ME}/b4.png?x=.png`,
    ]
  ) assertEquals(await refused({ imageUrl }), [400, "bad_media"], imageUrl);
  assertEquals(await refused({ symbol: "XLM" }), [400, "look_alike_symbol"]);
  // Twitter and Telegram links on their own sites pass; blanks are none.
  stored.length = 0;
  await meta.writeLaunchMetadata(ME, { name: "E2E Cat", symbol: "ECAT", x: "https://twitter.com/ecat", telegram: "https://t.me/ecat", website: " ", description: "" });
  assertEquals(JSON.parse(stored[0].body).links, { website: null, x: "https://twitter.com/ecat", telegram: "https://t.me/ecat" });
  assertEquals(JSON.parse(stored[0].body).description, null);
});

// ------------------------------------------------------------------------------------------------ positions and numbers

Deno.test("positions: average cost of what is still held; P&L = received − spent + what is held at today's price", () => {
  const price = lp.scaled("0.0000417");
  assertEquals(lp.positionOf([], 1n, price), null, "coins received by transfer have neither");
  const fills = [
    { side: "buy" as const, quote: 100_000_000n, tokens: 2_400_000_000_000n },
    { side: "sell" as const, quote: 97_200_000n, tokens: 2_400_000_000_000n },
    { side: "buy" as const, quote: 500_000_000n, tokens: 12_000_000_000_000n },
  ];
  assertEquals(lp.positionOf(fills, 12_000_000_000_000n, price), { costBasis: 500_000_000n, pnl: -2_400_000n });
  // Half the tokens sent away: half the cost basis, and only what is still held is valued.
  assertEquals(lp.positionOf(fills, 6_000_000_000_000n, price), { costBasis: 250_000_000n, pnl: -252_600_000n });
  // A sell takes its share of the cost.
  assertEquals(lp.positionOf([{ side: "buy", quote: 100n, tokens: 10n }, { side: "sell", quote: 70n, tokens: 4n }], 6n, 10n ** 18n * 10n), { costBasis: 60n, pnl: 30n });
});

Deno.test("numbers: exact quote prices from reserves, base units as decimals, amounts to read", () => {
  assertEquals(lp.ratio(250_000_000_000n, 10_000_000_000_000_000n), "0.000025");
  assertEquals(lp.ratio(1n, 3n), "0.333333333333333333");
  assertEquals(lp.decimalText(lp.scaled("41700.0000000")), "41700");
  assertEquals(lp.decimalText(lp.scaled("-0.0024")), "-0.0024");
  assertEquals(lp.decimalText(lp.scaled("41760.56338028169"), 7), "41760.5633802");
  assertEquals(lp.unitsText(21_000_000_000n), "2100");
  assertEquals(lp.unitsText(5n), "0.0000005");
  assertEquals(lp.amountText(12_000_000_000_000n), "1,200,000");
  assertEquals(lp.amountText(500_000_000n), "50");
  assertEquals(lp.amountText(-12_345_670_000n), "-1,234.567");
});

Deno.test("an unknown launch token: 404 from the launchpad's own UnknownLaunch, not a 422", async () => {
  respond = () => [];
  answer = (contract, fn) => (contract === PAD && fn === "get_launch" ? { error: RECORDED_ERRORS.unknown } : { error: "x" });
  await assertRejects(() => lp.buildLaunch(ME, { action: "graduate", token: XLM }), ApiError, "Launch not found.");
});
