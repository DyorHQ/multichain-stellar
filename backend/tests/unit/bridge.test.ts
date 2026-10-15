// The bridge (docs/DESIGN-stellar-parity.md §5.7, §6.10; §12.5): the CCTP encoders; a quote's fee from Iris's fee
// table (answers captured from Iris), exact to the base unit, priced at the standard transfer's row and kept 10
// minutes; its time, the median of the last transfers that way or none with fewer than 3; the relay's limits (at least
// 1 USDC from Monad, and the 11th transfer from Monad a user starts in a UTC day gets 429, reported or not, sent
// together or not; a late report takes one of today's relays); the Monad steps, handed out only as the phone would
// sign them; the burn to Monad, bound to the address the user confirmed as WP-11's verifier holds it; the keeper's
// relay: only of a burn that is the transfer's own (decoded as Circle writes it, checked on a real attested message),
// once, recorded in lite.keeper_log once that table exists; and mainnet's 501.
//
// The network is a stand-in: Iris, Horizon and Stellar RPC answer from here, and RPC's latest ledger is set on the
// client (its answer carries a whole ledger's metadata). The database is the route harness's, answering
// _shared/bridge.ts's own statements, which run on Postgres in backend/tests/sql/bridge_test.sql; it records where
// each transaction begins and ends.
import { Address, Keypair, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { fakeSql, type Row, setTestEnv, SPONSOR, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const KEEPER = Keypair.fromRawEd25519Seed(new Uint8Array(32).fill(4) as any);
Deno.env.set("KEEPER_SECRET", KEEPER.secret());
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const bridge = await import("../../supabase/functions/_shared/bridge.ts");
const { verifyContext } = await import("../../supabase/functions/_shared/plans.ts");
const { verifyTransaction } = await import("../../supabase/functions/_shared/verify.ts");
const { rpcServer } = await import("../../supabase/functions/_shared/stellar.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const PASS = TESTNET.passphrase;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const CCTP = TESTNET.contracts.cctp!;
const MONAD = TESTNET.bridge.monad!;
const ME = USER.publicKey();
const RECIPIENT = "0x663b5d4f0412dbf5b0fb0773e7f0602d11a80dda";
const TRANSFER = "c69ef4a0-421e-418d-a93b-92081f4a0fcb";
const OUTBOUND = "67904f04-179c-49db-a5b8-edeb7d2f64ed";
const MINUTE = 60_000;

/** Iris's fee tables (GET /v2/burn/USDC/fees/{src}/{dst}) as captured on 2026-10-15: testnet (iris-api-sandbox)
 *  between Monad (15) and Stellar (27), both ways; and mainnet from Arbitrum (3) to Ethereum (0), whose fast transfer
 *  costs a fraction of a basis point. */
const IRIS = {
  monadToStellar: [{ finalityThreshold: 1000, minimumFee: 0 }, { finalityThreshold: 2000, minimumFee: 0 }],
  stellarToMonad: [{ finalityThreshold: 1000, minimumFee: 0 }, { finalityThreshold: 2000, minimumFee: 0 }],
  arbitrumToEthereum: [{ finalityThreshold: 1000, minimumFee: 1.4 }, { finalityThreshold: 2000, minimumFee: 0 }],
};
/** The same table where a standard transfer costs something too (a route with Circle's fee switch on). */
const CHARGED = [{ finalityThreshold: 1000, minimumFee: 9 }, { finalityThreshold: 2000, minimumFee: 1.3 }];

/** A real attested burn as Iris returned it on 2026-10-15 (GET /v2/messages/27?transactionHash=40abd915…, the testnet
 *  burn of docs/VERIFICATION.md): 0.1 USDC from Stellar to 0x…dEaD on Monad, so Circle's own layout and its bytes32
 *  for Stellar contracts. */
const IRIS_STELLAR_BURN = "0x" +
  "000000010000001b0000000f761deb7dba8f7c95486b249f8713b969179dc2eed1b5d2ae7db47bcff146d5afda6f9ee0" +
  "786c812344d82817ef19b648b4af120f8bd10bf658e6b99eacff24b80000000000000000000000008fe6b999dc680ccf" +
  "dd5bf7eb0974218be2542daa0000000000000000000000000000000000000000000000000000000000000000000007d0" +
  "000007d0000000015045cd5ec0729a768fd5ad02505852df4f028dce830e5ac52209ba48483b2f010000000000000000" +
  "00000000000000000000000000000000000000000000dead000000000000000000000000000000000000000000000000" +
  "00000000000186a0c014e0780b10d16c0594d940ed6dd1373111b4f504287909597bdaffc0f8f2970000000000000000" +
  "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" +
  "00000000000000000000000000000000000000000000000000000000000000000000000000000000";

// ------------------------------------------------------------------------------------------------ burn messages

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const bytes = (h: string) => new Uint8Array(Buffer.from(h.replace(/^0x/, ""), "hex"));
const u32 = (n: number) => n.toString(16).padStart(8, "0");
const b32 = (h: string) => h.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const FORWARDER = hex(StrKey.decodeContract(CCTP.forwarder));
const MINTER = hex(StrKey.decodeContract(CCTP.tokenMessengerMinter));

/** A burn message from Monad to Stellar as Iris returns it once attested (MessageV2 then BurnMessageV2): the burn
 *  inboundSteps describes for `address` and `amount`, with any field changed by `edit`. */
function burnMessage(address: string, amount: bigint, edit: Partial<Record<string, string | number | bigint>> = {}): string {
  const f = {
    version: 1,
    sourceDomain: MONAD.domain,
    destinationDomain: CCTP.domain,
    nonce: "5a".repeat(32),
    sender: b32(MONAD.tokenMessenger),
    recipient: MINTER,
    destinationCaller: FORWARDER,
    minFinalityThreshold: 2000,
    finalityThresholdExecuted: 2000,
    bodyVersion: 1,
    burnToken: b32(MONAD.usdc),
    mintRecipient: FORWARDER,
    amount,
    messageSender: b32(RECIPIENT),
    maxFee: 0n,
    feeExecuted: 0n,
    expirationBlock: 0n,
    hookData: hex(bridge.forwarderHookData(address)),
    ...edit,
  };
  const uint = (n: unknown) => b32(BigInt(n as bigint).toString(16));
  return "0x" + [
    u32(f.version as number),
    u32(f.sourceDomain as number),
    u32(f.destinationDomain as number),
    f.nonce,
    f.sender,
    f.recipient,
    f.destinationCaller,
    u32(f.minFinalityThreshold as number),
    u32(f.finalityThresholdExecuted as number),
    u32(f.bodyVersion as number),
    f.burnToken,
    f.mintRecipient,
    uint(f.amount),
    f.messageSender,
    uint(f.maxFee),
    uint(f.feeExecuted),
    uint(f.expirationBlock),
    f.hookData,
  ].join("");
}

const ATTESTATION = "0x" + "82".repeat(65);

// ------------------------------------------------------------------------------------------------ the stand-in network

const net = {
  /** Iris's answers by path and query. */
  iris: new Map<string, () => Response>(),
  /** Accounts as Horizon describes them. */
  horizon: new Map<string, Record<string, unknown>>(),
  /** Accounts RPC knows (getLedgerEntries). */
  rpcAccounts: new Set<string>(),
  simulated: [] as { contract: string; fn: string; args: xdr.ScVal[] }[],
  sent: [] as Transaction[],
  asked: [] as string[],
};

function resetNet(): void {
  net.iris.clear();
  net.horizon.clear();
  net.rpcAccounts.clear();
  net.simulated.length = 0;
  net.sent.length = 0;
  net.asked.length = 0;
  bridge.forgetIrisFees();
}

const feesPath = (src: number, dst: number) => `/v2/burn/USDC/fees/${src}/${dst}`;
const irisFees = (src: number, dst: number, table: unknown) => net.iris.set(feesPath(src, dst), () => Response.json(table));

/** Horizon's account: 10,000 XLM, and USDC enabled unless `usdc` is false. */
function horizonAccount(address: string, usdc = true): Record<string, unknown> {
  const lines = usdc
    ? [{ balance: "5.2300000", limit: "922337203685.4775807", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] }]
    : [];
  return {
    id: address,
    account_id: address,
    sequence: "22096910953218050",
    subentry_count: lines.length,
    num_sponsoring: 0,
    num_sponsored: 0,
    signers: [],
    balances: [...lines, { balance: "10000.0000000", asset_type: "native" }],
  };
}

function accountEntry(address: string) {
  const id = Keypair.fromPublicKey(address).xdrAccountId();
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: id }));
  const val = xdr.LedgerEntryData.account(
    new xdr.AccountEntry({
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
    }),
  );
  return { entries: [{ key: key.toXDR("base64"), xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }], latestLedger: 1 };
}

function rpc(method: string, params: any): unknown {
  switch (method) {
    case "getLedgerEntries": {
      const key = xdr.LedgerKey.fromXDR(params.keys[0], "base64");
      const address = StrKey.encodeEd25519PublicKey(key.account().accountId().ed25519());
      return net.rpcAccounts.has(address) ? accountEntry(address) : { entries: [], latestLedger: 1 };
    }
    case "simulateTransaction": {
      const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
      const call = (tx.operations[0] as any).func.invokeContract();
      net.simulated.push({ contract: Address.fromScAddress(call.contractAddress()).toString(), fn: call.functionName().toString(), args: call.args() });
      return {
        latestLedger: 1,
        minResourceFee: "1000",
        transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
        results: [{ auth: [], xdr: xdr.ScVal.scvVoid().toXDR("base64") }],
        events: [],
      };
    }
    case "sendTransaction": {
      const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
      net.sent.push(tx);
      return { status: "PENDING", hash: tx.hash().toString("hex"), latestLedger: 1, latestLedgerCloseTime: "1760400000" };
    }
  }
  throw new Error(`unexpected RPC call ${method}`);
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  net.asked.push(url.origin + url.pathname + url.search);
  if (url.origin === TESTNET.apis.iris) {
    const answer = net.iris.get(url.pathname + url.search);
    return answer ? answer() : Response.json({ error: "not found" }, { status: 404 });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
    const a = net.horizon.get(url.pathname.split("/")[2]);
    return a ? Response.json(a) : Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    return Response.json({ jsonrpc: "2.0", id: body.id, result: rpc(body.method, body.params) });
  }
  return new Response("offline: unit tests make no network calls", { status: 503 });
}) as typeof fetch;

rpcServer().getLatestLedger = () => Promise.resolve({ id: "ab".repeat(32), protocolVersion: 23, sequence: 5_000_000 } as any);

// ------------------------------------------------------------------------------------------------ the stand-in database

// _shared/bridge.ts's statements, as the stand-in sees them (whitespace collapsed, parameters as "?").
const LOCK = "select pg_advisory_xact_lock(hashtextextended(?, 0))";
const RELAYS = "select count(*)::int as relays from lite.bridge_transfers where address = ? and relay_day = (now() at time zone 'utc')::date";
const START_IN = "insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day) values (?, 'monad_to_stellar', 'cctp', ?, ?, (now() at time zone 'utc')::date) returning id, status";
const START_OUT = "insert into lite.bridge_transfers (address, direction, route, amount, recipient) values (?, 'stellar_to_monad', 'cctp', ?, ?) returning id, status";
const LATE = "select relay_day < (now() at time zone 'utc')::date as late from lite.bridge_transfers where id = ? and address = ? and status = 'awaiting_source'";
const REPORT = "update lite.bridge_transfers set source_tx = ?, status = 'attesting', updated_at = now(), relay_day = case when relay_day is not null then (now() at time zone 'utc')::date end where id = ? returning id, status";
const RELAYED = "select 1 from lite.bridge_transfers where message = ? and direction = 'monad_to_stellar' and status = 'completed' and id <> ?";
const COMPLETED = "update lite.bridge_transfers set message = ?, attestation = ?, dest_tx = ?, status = 'completed', updated_at = now() where id = ?";
const RELAY_ERROR = "update lite.bridge_transfers set message = ?, attestation = ?, error = ?, updated_at = now() where id = ?";
const REFUSED = "update lite.bridge_transfers set message = ?, error = ?, status = 'failed', updated_at = now() where id = ?";
const RELAYED_ALREADY = "update lite.bridge_transfers set error = 'Not relayed: its burn was relayed for another transfer.', status = 'failed', updated_at = now() where id = ?";
const RELAYING = "update lite.bridge_transfers set message = ?, attestation = ?, status = 'relaying', updated_at = now() where id = ?";

const db = {
  /** Seconds each completed transfer took, newest first, by direction. */
  durations: { monad_to_stellar: [] as number[], stellar_to_monad: [] as number[] },
  /** The user's transfers from Monad that hold one of today's relays: each start and each late report adds one. */
  relaysToday: 0,
  /** Starts another request commits right after the next count of the day's relays (a request sent alongside). */
  alongside: 0,
  /** Transfers awaiting their burn: whose, and whether they started on an earlier day. */
  awaiting: new Map<string, { address: string; late: boolean }>(),
  /** Messages already relayed for a completed transfer. */
  relayed: new Set<string>(),
  /** Whether migration 05 created lite.keeper_log ("fails": it refuses the row). */
  keeperLog: true as boolean | "fails",
  /** Transfers waiting on Iris (advanceBridges). */
  open: [] as Row[],
  /** Every statement, and "begin", "commit" and "rollback". */
  statements: [] as { q: string; params: unknown[] }[],
};

function resetDb(): void {
  db.durations = { monad_to_stellar: [], stellar_to_monad: [] };
  db.relaysToday = 0;
  db.alongside = 0;
  db.awaiting.clear();
  db.relayed.clear();
  db.keeperLog = true;
  db.open = [];
  db.statements.length = 0;
}

const ran = (prefix: string) => db.statements.filter((s) => s.q.startsWith(prefix));
const said = () => db.statements.map((s) => s.q);

const standIn = fakeSql((q, params) => {
  db.statements.push({ q, params });
  if (q.startsWith("select extract(epoch from updated_at - created_at)::float8 as seconds from lite.bridge_transfers")) {
    assertEquals(q.slice(q.indexOf(" where ")), " where direction = ? and route = 'cctp' and status = 'completed' order by updated_at desc limit ?");
    return db.durations[params[0] as "monad_to_stellar" | "stellar_to_monad"].map((seconds) => ({ seconds }));
  }
  if (q === LOCK) return [{ pg_advisory_xact_lock: "" }];
  if (q === RELAYS) {
    const relays = db.relaysToday;
    db.relaysToday += db.alongside;
    db.alongside = 0;
    return [{ relays }];
  }
  if (q === START_IN) {
    db.relaysToday++;
    db.awaiting.set(TRANSFER, { address: params[0] as string, late: false });
    return [{ id: TRANSFER, status: "awaiting_source" }];
  }
  if (q === START_OUT) return [{ id: OUTBOUND, status: "awaiting_source" }];
  if (q === LATE) {
    const t = db.awaiting.get(params[0] as string);
    return t && t.address === params[1] ? [{ late: t.late }] : [];
  }
  if (q === REPORT) {
    if (db.awaiting.get(params[1] as string)?.late) db.relaysToday++;
    db.awaiting.delete(params[1] as string);
    return [{ id: params[1], status: "attesting" }];
  }
  if (q === RELAYED) return db.relayed.has(params[0] as string) ? [{ "?column?": 1 }] : [];
  if (q === "select to_regclass(?) is not null as present") return [{ present: db.keeperLog !== false }];
  if (q.startsWith("insert into lite.keeper_log")) {
    if (db.keeperLog === "fails") throw new Error("permission denied for table keeper_log");
    return [];
  }
  if (q.startsWith("select * from lite.bridge_transfers where status = 'attesting'")) return db.open;
  if (q === COMPLETED) {
    db.relayed.add(params[0] as string);
    return [];
  }
  if ([RELAY_ERROR, REFUSED, RELAYED_ALREADY, RELAYING].includes(q)) return [];
  throw new Error(`unexpected query: ${q}`);
});
// Transactions as postgres.js runs them, marked in the statements.
const runIn = standIn.begin;
(standIn as any).begin = async (fn: (tx: unknown) => unknown) => {
  db.statements.push({ q: "begin", params: [] });
  try {
    const out = await runIn(fn as any);
    db.statements.push({ q: "commit", params: [] });
    return out;
  } catch (err) {
    db.statements.push({ q: "rollback", params: [] });
    throw err;
  }
};
replaceSql(standIn);

async function refusal(p: Promise<unknown>): Promise<{ status: number; code: string; message: string }> {
  const err = await p.then(() => null, (e) => e);
  assert(err && typeof err.status === "number", `expected a refusal, got ${err ? err.message : "an answer"}`);
  return { status: err.status, code: err.code, message: err.message };
}

const RELAY_LIMIT = { status: 429, code: "bridge_relay_limit", message: "You've bridged in many times today. Try again tomorrow." };

function fresh(): void {
  resetNet();
  resetDb();
}

// ------------------------------------------------------------------------------------------------ encoders

Deno.test("CCTP encoders: selectors, hook data layout, dynamic bytes", () => {
  assertEquals(bridge.encodeApprove("0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA", 5n).slice(0, 10), "0x095ea7b3");
  const hook = bridge.forwarderHookData("GAXNIIDVUIDR2YEE64BMR5JUFB4KYI627PWFXWHUWLU3Q2SSUFLLQUSE");
  assertEquals(hook.length, 32 + 56);
  assert(hook.slice(0, 24).every((b) => b === 0));
  assertEquals(new DataView(hook.buffer).getUint32(28), 56);
  assertEquals(new TextDecoder().decode(hook.slice(32)), "GAXNIIDVUIDR2YEE64BMR5JUFB4KYI627PWFXWHUWLU3Q2SSUFLLQUSE");
  const data = bridge.encodeDepositForBurnWithHook({ amount: 1n, destinationDomain: 27, mintRecipient: new Uint8Array(32).fill(1), burnToken: "0x534b2f3A21130d7a60830c2Df862319e593943A3", destinationCaller: new Uint8Array(32).fill(1), maxFee: 0n, minFinalityThreshold: 2000, hookData: hook });
  assertEquals(data.slice(0, 10), "0x779b432d");
  // 8 head words + length word + 3 data words (88 bytes padded to 96)
  assertEquals((data.length - 10) / 64, 8 + 1 + 3);
  const rm = bridge.encodeReceiveMessage(new Uint8Array(5), new Uint8Array(65));
  assertEquals(rm.slice(0, 10), "0x57ecfd28");
  assertEquals(bridge.evmToBytes32("0x000000000000000000000000000000000000dEaD")[31], 0xad);
});

// ------------------------------------------------------------------------------------------------ the quote's fee

Deno.test("Iris's fee in basis points, read exactly: whole, fractional, or refused", () => {
  assertEquals(bridge.parseBps(0), { num: 0n, den: 1n });
  assertEquals(bridge.parseBps(1), { num: 1n, den: 1n });
  assertEquals(bridge.parseBps(1.4), { num: 14n, den: 10n });
  assertEquals(bridge.parseBps(0.25), { num: 25n, den: 100n });
  assertEquals(bridge.parseBps(13), { num: 13n, den: 1n });
  for (const v of [-1, 10_001, Number.NaN, Number.POSITIVE_INFINITY, 1e-7, "1", null, undefined, {}]) assertEquals(bridge.parseBps(v), null, String(v));
});

Deno.test("the fee: ceil(amount × bps / 10⁴), exact to the base unit", () => {
  const bps = (v: number) => bridge.parseBps(v)!;
  assertEquals(bridge.bridgeFee(12_500_000n, bps(1)), 1_250n);
  assertEquals(bridge.bridgeFee(12_500_001n, bps(1)), 1_251n, "a part of a unit rounds up");
  assertEquals(bridge.bridgeFee(1_000_000n, bps(1.4)), 140n);
  assertEquals(bridge.bridgeFee(1_000_001n, bps(1.4)), 141n);
  assertEquals(bridge.bridgeFee(125_000_000n, bps(1.3)), 16_250n);
  assertEquals(bridge.bridgeFee(7n, bps(1.3)), 1n);
  assertEquals(bridge.bridgeFee(1_000_000_000_000n, bps(0)), 0n);
  assertEquals(bridge.bridgeFee(0n, bps(1)), 0n);
  // No float on the way: 2⁶³ base units at 1.4 bps.
  assertEquals(bridge.bridgeFee(9_223_372_036_854_775_807n, bps(1.4)), 1_291_272_085_159_669n);
});

Deno.test("Iris's fee: the standard transfer's row (finalityThreshold 2000) of the route's table", async () => {
  fresh();
  irisFees(3, 0, IRIS.arbitrumToEthereum);
  assertEquals(await bridge.irisStandardFee(3, 0), { num: 0n, den: 1n }, "not the fast transfer's 1.4");
  irisFees(15, 27, CHARGED);
  assertEquals(await bridge.irisStandardFee(15, 27), { num: 13n, den: 10n });
  assertEquals(net.asked, [`${TESTNET.apis.iris}${feesPath(3, 0)}`, `${TESTNET.apis.iris}${feesPath(15, 27)}`]);
});

Deno.test("Iris's fee is kept 10 minutes per route", async () => {
  fresh();
  irisFees(15, 27, IRIS.monadToStellar);
  irisFees(27, 15, IRIS.stellarToMonad);
  const t0 = Date.parse("2026-10-15T02:15:00.000Z");
  await bridge.irisStandardFee(15, 27, t0);
  await bridge.irisStandardFee(15, 27, t0 + 9 * MINUTE + 59_000);
  assertEquals(net.asked.length, 1);
  await bridge.irisStandardFee(27, 15, t0 + MINUTE);
  assertEquals(net.asked.length, 2, "each route has its own");
  irisFees(15, 27, CHARGED);
  assertEquals(await bridge.irisStandardFee(15, 27, t0 + 10 * MINUTE), { num: 13n, den: 10n }, "asked again after 10 minutes");
  assertEquals(net.asked.length, 3);
});

Deno.test("no fee from Iris: 502 bridge_quote_failed, and nothing kept", async () => {
  fresh();
  const answers: [string, () => Response][] = [
    ["an error", () => Response.json({ error: "boom" }, { status: 500 })],
    ["no standard row", () => Response.json([{ finalityThreshold: 1000, minimumFee: 1 }])],
    ["a fee as text", () => Response.json([{ finalityThreshold: 2000, minimumFee: "1" }])],
    ["not JSON", () => new Response("<html>", { status: 200 })],
    ["not a table", () => Response.json({ finalityThreshold: 2000, minimumFee: 0 })],
    ["unreachable", () => {
      throw new TypeError("network error");
    }],
  ];
  for (const [what, answer] of answers) {
    net.iris.set(feesPath(15, 27), answer);
    assertEquals(await refusal(bridge.irisStandardFee(15, 27)), {
      status: 502,
      code: "bridge_quote_failed",
      message: "The bridge fee isn't available right now. Try again in a minute.",
    }, what);
  }
  irisFees(15, 27, IRIS.monadToStellar);
  assertEquals(await bridge.irisStandardFee(15, 27), { num: 0n, den: 1n });
});

// ------------------------------------------------------------------------------------------------ the quote

Deno.test("a quote: Circle's fee from Iris, in the sending side's units, and what arrives, both ways", async () => {
  fresh();
  irisFees(15, 27, CHARGED);
  irisFees(27, 15, CHARGED);
  const toStellar = await bridge.bridgeQuote({ direction: "monad_to_stellar", amount: 12_500_000n });
  // 12.5 USDC on Monad (6 decimals) at 1.3 bps: 1,625 base units; 12,498,375 arrive, as 7-decimal USDC on Stellar.
  assertEquals(toStellar, {
    route: "cctp",
    direction: "monad_to_stellar",
    amountIn: "12500000",
    amountOut: "124983750",
    fee: "1625",
    feeSource: "circle-iris",
    etaSeconds: null,
    etaBasis: 0,
    note: "Testnet CCTP: Monad testnet USDC ↔ Circle test USDC on Stellar.",
  });
  // 12.5 USDC on Stellar (7 decimals): 16,250 base units of fee; Monad receives whole micro-USDC.
  const toMonad = await bridge.bridgeQuote({ direction: "stellar_to_monad", amount: 125_000_000n });
  assertEquals([toMonad.fee, toMonad.amountOut], ["16250", "12498375"]);
  assertEquals(net.asked, [`${TESTNET.apis.iris}${feesPath(15, 27)}`, `${TESTNET.apis.iris}${feesPath(27, 15)}`]);
});

Deno.test("a quote on today's testnet route: Iris charges nothing, so everything arrives", async () => {
  fresh();
  irisFees(MONAD.domain, CCTP.domain, IRIS.monadToStellar);
  irisFees(CCTP.domain, MONAD.domain, IRIS.stellarToMonad);
  const toStellar = await bridge.bridgeQuote({ direction: "monad_to_stellar", amount: 1_000_000n });
  assertEquals([toStellar.fee, toStellar.amountOut, toStellar.feeSource], ["0", "10000000", "circle-iris"]);
  const toMonad = await bridge.bridgeQuote({ direction: "stellar_to_monad", amount: 10_000_005n });
  assertEquals([toMonad.fee, toMonad.amountOut], ["0", "1000000"], "Stellar's 7th decimal isn't burnt");
});

Deno.test("a quote's time: none with fewer than 3 transfers that way, otherwise their median", async () => {
  assertEquals(bridge.etaOf([]), { etaSeconds: null, etaBasis: 0 });
  assertEquals(bridge.etaOf([95, 61]), { etaSeconds: null, etaBasis: 2 });
  assertEquals(bridge.etaOf([300, 95, 61]), { etaSeconds: 95, etaBasis: 3 });
  assertEquals(bridge.etaOf([40, 10, 30, 20]), { etaSeconds: 25, etaBasis: 4 });
  assertEquals(bridge.etaOf([61.2, 70.5, 64.4]), { etaSeconds: 64, etaBasis: 3 }, "whole seconds");
  assertEquals(bridge.etaOf([60, 61, 3_600, 62]), { etaSeconds: 62, etaBasis: 4 }, "one slow transfer doesn't move it far");

  fresh();
  irisFees(15, 27, IRIS.monadToStellar);
  irisFees(27, 15, IRIS.stellarToMonad);
  db.durations.monad_to_stellar = [95, 61];
  db.durations.stellar_to_monad = Array.from({ length: 20 }, (_, i) => 600 + 10 * i);
  const toStellar = await bridge.bridgeQuote({ direction: "monad_to_stellar", amount: 1_000_000n });
  assertEquals([toStellar.etaSeconds, toStellar.etaBasis], [null, 2]);
  const toMonad = await bridge.bridgeQuote({ direction: "stellar_to_monad", amount: 10_000_000n });
  assertEquals([toMonad.etaSeconds, toMonad.etaBasis], [695, 20]);
  // Each direction is read on its own, the last 20 transfers.
  assertEquals(ran("select extract(epoch").map((s) => s.params), [["monad_to_stellar", 20], ["stellar_to_monad", 20]]);
});

Deno.test("a quote for another direction is refused before Iris is asked", async () => {
  fresh();
  assertEquals(await refusal(bridge.bridgeQuote({ direction: "sideways", amount: 1_000_000n })), {
    status: 400,
    code: "bad_direction",
    message: "direction is monad_to_stellar or stellar_to_monad.",
  });
  assertEquals([net.asked, db.statements], [[], []]);
});

// ------------------------------------------------------------------------------------------------ the relay's limits

const startIn = (amount = 1_000_000n) => bridge.startBridge(ME, { direction: "monad_to_stellar", amount, monadAddress: RECIPIENT });

Deno.test("from Monad: at least 1 USDC, refused before anything is read", async () => {
  fresh();
  net.horizon.set(ME, horizonAccount(ME));
  assertEquals(await refusal(startIn(999_999n)), { status: 400, code: "too_small", message: "Bridge at least 1 USDC from Monad." });
  assertEquals([net.asked, db.statements], [[], []]);
  const start = await startIn(1_000_000n);
  assertEquals(start.transfer, { id: TRANSFER, status: "awaiting_source", direction: "monad_to_stellar" });
  assertEquals(ran(START_IN)[0].params, [ME, "1000000", ME]);
});

Deno.test("from Monad: a start takes one of today's 10 relays as it is recorded, under the user's lock", async () => {
  fresh();
  net.horizon.set(ME, horizonAccount(ME));
  db.relaysToday = 9;
  const tenth = await startIn();
  assertEquals(tenth.evmSteps?.length, 2);
  // A first count refuses a full day before Horizon is asked; then one transaction takes the user's lock, counts
  // again and records the transfer with today's relay day.
  assertEquals(said(), [RELAYS, "begin", LOCK, RELAYS, START_IN, "commit"]);
  assertEquals(ran(LOCK)[0].params, [`lite.bridge_relays:${ME}`]);
  assertEquals(ran(RELAYS).map((s) => s.params), [[ME], [ME]]);
  assertEquals(db.relaysToday, 10);

  db.statements.length = 0;
  net.asked.length = 0;
  assertEquals(await refusal(startIn(5_000_000n)), RELAY_LIMIT);
  assertEquals(said(), [RELAYS], "no transfer recorded");
  assertEquals(net.asked, [], "Horizon isn't asked");
  assertEquals(bridge.RELAYS_PER_DAY, 10);
});

Deno.test("from Monad: ten starts with none reported, and the 11th gets 429 before any Monad step", async () => {
  fresh();
  net.horizon.set(ME, horizonAccount(ME));
  for (let i = 1; i <= 10; i++) assertEquals((await startIn()).evmSteps?.length, 2, `start ${i}`);
  assertEquals(ran(REPORT), [], "no burn was reported");
  assertEquals(await refusal(startIn()), RELAY_LIMIT);
  assertEquals(ran(START_IN).length, 10);
});

Deno.test("from Monad: starts sent together can't pass the cap together", async () => {
  fresh();
  net.horizon.set(ME, horizonAccount(ME));
  // The first count sees 9; another start commits the day's 10th before this one takes the lock.
  db.relaysToday = 9;
  db.alongside = 1;
  assertEquals(await refusal(startIn()), RELAY_LIMIT);
  assertEquals(said(), [RELAYS, "begin", LOCK, RELAYS, "rollback"]);
  assertEquals(db.relaysToday, 10);
});

Deno.test("from Monad: USDC must be enabled on Stellar first", async () => {
  fresh();
  net.horizon.set(ME, horizonAccount(ME, false));
  assertEquals((await refusal(startIn())).code, "needs_usdc");
  fresh();
  assertEquals((await refusal(startIn())).code, "account_inactive");
  assertEquals(ran(START_IN), []);
});

Deno.test("a start is refused for another direction, a Monad address that isn't one, or Stellar amounts CCTP can't burn", async () => {
  fresh();
  const start = (direction: string, amount: bigint, monadAddress = RECIPIENT) => refusal(bridge.startBridge(ME, { direction, amount, monadAddress }));
  assertEquals((await start("sideways", 10_000_000n)).code, "bad_direction");
  assertEquals((await start("stellar_to_monad", 10_000_000n, "0x1234")).code, "bad_address");
  for (const amount of [10_000_005n, 0n, -10n]) {
    assertEquals(await start("stellar_to_monad", amount), { status: 400, code: "bad_amount", message: "Stellar → Monad moves whole micro-USDC (6 decimals)." }, String(amount));
  }
  assertEquals([net.asked, db.statements], [[], []]);
});

Deno.test("reporting a burn: a start of today's keeps its relay, whatever the day holds", async () => {
  fresh();
  const hash = "0x" + "cd".repeat(32);
  db.awaiting.set(TRANSFER, { address: ME, late: false });
  db.relaysToday = 10;
  assertEquals(await bridge.setSourceTx(ME, TRANSFER, hash), { id: TRANSFER, status: "attesting" });
  assertEquals(said(), ["begin", LOCK, RELAYS, LATE, REPORT, "commit"]);
  assertEquals(ran(LATE)[0].params, [TRANSFER, ME]);
  assertEquals(ran(REPORT)[0].params, [hash, TRANSFER]);
  assertEquals(db.relaysToday, 10);
});

Deno.test("reporting a burn: a start of an earlier day takes one of today's relays, or gets 429 while they are taken", async () => {
  fresh();
  const hash = "0x" + "cd".repeat(32);
  db.awaiting.set(TRANSFER, { address: ME, late: true });
  db.relaysToday = 10;
  assertEquals(await refusal(bridge.setSourceTx(ME, TRANSFER, hash)), RELAY_LIMIT);
  assertEquals(said(), ["begin", LOCK, RELAYS, LATE, "rollback"], "not reported: it can be, tomorrow");
  assert(db.awaiting.has(TRANSFER));

  db.statements.length = 0;
  db.relaysToday = 9;
  assertEquals(await bridge.setSourceTx(ME, TRANSFER, hash), { id: TRANSFER, status: "attesting" });
  assertEquals(said(), ["begin", LOCK, RELAYS, LATE, REPORT, "commit"]);
  assertEquals(db.relaysToday, 10, "it holds one of today's now");
});

Deno.test("reporting a burn: another user's transfer, an unknown one, a bad id or hash", async () => {
  fresh();
  const hash = "0x" + "cd".repeat(32);
  db.awaiting.set(TRANSFER, { address: SPONSOR.publicKey(), late: false });
  assertEquals(await refusal(bridge.setSourceTx(ME, TRANSFER, hash)), { status: 404, code: "not_found", message: "Transfer not found." });
  assertEquals(await refusal(bridge.setSourceTx(ME, "3f1c2a9e-0000-4000-8000-000000000002", hash)), { status: 404, code: "not_found", message: "Transfer not found." });
  assertEquals(ran(REPORT), []);
  db.statements.length = 0;
  assertEquals((await refusal(bridge.setSourceTx(ME, "not-a-transfer", hash))).code, "not_found");
  assertEquals((await refusal(bridge.setSourceTx(ME, TRANSFER, "nope"))).code, "bad_hash");
  assertEquals(db.statements, []);
});

// ------------------------------------------------------------------------------------------------ the Monad steps

const PINS = {
  chainId: MONAD.chainId,
  usdc: MONAD.usdc,
  tokenMessenger: MONAD.tokenMessenger,
  monadDomain: MONAD.domain,
  domain: CCTP.domain,
  tokenMessengerMinter: CCTP.tokenMessengerMinter,
  forwarder: CCTP.forwarder,
};

Deno.test("the Monad steps: USDC's approve, then the burn, only to the pinned USDC and TokenMessengerV2 (§5.7)", () => {
  const steps = bridge.inboundSteps(ME, 12_500_000n, PINS);
  assertEquals(steps.map((s) => [s.chainId, s.label, s.to, s.value, s.data.slice(0, 10)]), [
    [10143, "Allow USDC", MONAD.usdc, "0", "0x095ea7b3"],
    [10143, "Send to Stellar", MONAD.tokenMessenger, "0", "0x779b432d"],
  ]);
  assertEquals(bridge.inboundStepsRefusal(steps, ME, 12_500_000n, PINS), null);
});

Deno.test("the Monad steps: anything the phone would refuse is refused here first", () => {
  const amount = 12_500_000n;
  const good = () => bridge.inboundSteps(ME, amount, PINS);
  const word = (data: string, i: number) => data.slice(10 + 64 * i, 10 + 64 * (i + 1));
  const withWord = (data: string, i: number, w: string) => data.slice(0, 10 + 64 * i) + w + data.slice(10 + 64 * (i + 1));
  const other = "0x0000000000000000000000000000000000000bad";
  const otherWord = other.slice(2).padStart(64, "0");
  const burnWith = (p: Partial<Parameters<typeof bridge.encodeDepositForBurnWithHook>[0]>) => {
    const steps = good();
    const forwarder = StrKey.decodeContract(CCTP.forwarder);
    steps[1].data = bridge.encodeDepositForBurnWithHook({ amount, destinationDomain: 27, mintRecipient: forwarder, burnToken: MONAD.usdc, destinationCaller: forwarder, maxFee: 0n, minFinalityThreshold: 2000, hookData: bridge.forwarderHookData(ME), ...p });
    return steps;
  };
  const cases: [string, ReturnType<typeof good>, string][] = [
    ["another chain", good().map((s) => ({ ...s, chainId: 143 })), "a step leaves the pinned Monad chain or sends MON"],
    ["MON sent along", good().map((s, i) => (i === 1 ? { ...s, value: "1" } : s)), "a step leaves the pinned Monad chain or sends MON"],
    ["another contract", good().map((s, i) => (i === 0 ? { ...s, to: other } : s)), "a step calls a contract other than USDC and TokenMessengerV2"],
    ["a third step", [...good(), good()[0]], "a transfer to Stellar is an approve, then a burn"],
    ["the steps swapped", good().reverse(), "the first step isn't USDC's approve"],
    ["another function", good().map((s, i) => (i === 0 ? { ...s, data: "0xa9059cbb" + s.data.slice(10) } : s)), "the first step isn't USDC's approve"],
    ["another spender", good().map((s, i) => (i === 0 ? { ...s, data: withWord(s.data, 0, otherWord) } : s)), "the approve is for another spender"],
    ["a bigger allowance", good().map((s, i) => (i === 0 ? { ...s, data: bridge.encodeApprove(MONAD.tokenMessenger, amount + 1n) } : s)), "the approve is for more than the amount"],
    ["the burn's contract", good().map((s, i) => (i === 1 ? { ...s, to: MONAD.usdc } : s)), "the second step isn't TokenMessengerV2's depositForBurnWithHook"],
    ["a burn for less", burnWith({ amount: amount - 1n }), "the burn isn't for the amount"],
    ["another network", burnWith({ destinationDomain: 6 }), "the burn sends to another network"],
    ["minted to the user", burnWith({ mintRecipient: StrKey.decodeEd25519PublicKey(ME) }), "the burn isn't minted to and called by the CctpForwarder"],
    ["called by anyone", burnWith({ destinationCaller: new Uint8Array(32) }), "the burn isn't minted to and called by the CctpForwarder"],
    ["another token", burnWith({ burnToken: other }), "the burn isn't of USDC"],
    ["someone else's hook", burnWith({ hookData: bridge.forwarderHookData(SPONSOR.publicKey()) }), "the hook data isn't the user's address"],
    ["a hook with more", burnWith({ hookData: new Uint8Array([...bridge.forwarderHookData(ME), 1]) }), "the hook data isn't the user's address"],
    ["malformed", good().map((s, i) => (i === 1 ? { ...s, data: s.data + "00" } : s)), "a step's call data is malformed"],
  ];
  for (const [what, steps, reason] of cases) assertEquals(bridge.inboundStepsRefusal(steps, ME, amount, PINS), reason, what);
  assertEquals(word(good()[1].data, 1), "1b".padStart(64, "0"), "Stellar's domain, 27");
});

// ------------------------------------------------------------------------------------------------ the burn's message

Deno.test("a burn's message, decoded as Circle writes it: a real attested burn from Stellar to Monad", () => {
  const m = bridge.decodeBurnMessage(bytes(IRIS_STELLAR_BURN))!;
  assertEquals(m, {
    version: 1,
    sourceDomain: CCTP.domain,
    destinationDomain: MONAD.domain,
    // Stellar's TokenMessengerMinter sent it, as its 32-byte contract id; Monad's TokenMessengerV2 receives it.
    sender: MINTER,
    recipient: b32(MONAD.tokenMessenger),
    destinationCaller: "0".repeat(64),
    bodyVersion: 1,
    burnToken: hex(StrKey.decodeContract(USDC.contract)),
    mintRecipient: b32("0x000000000000000000000000000000000000dEaD"),
    amount: 100_000n,
    hookData: "",
  });
  assertEquals(bridge.decodeBurnMessage(bytes("28".repeat(32))), null, "too short");
  // The way it goes is the first thing the relay checks.
  assertEquals(bridge.inboundMessageRefusal(bytes(IRIS_STELLAR_BURN), { address: ME, amount: 100_000n }, PINS), "it isn't a burn from Monad to Stellar");
});

Deno.test("the relay checks the burn's message: only the transfer's own burn, as its Monad steps describe it", () => {
  const amount = 12_500_000n;
  const transfer = { address: ME, amount };
  const refused = (h: string, t = transfer) => bridge.inboundMessageRefusal(bytes(h), t, PINS);
  // The burn inboundSteps hands out, once attested, is relayed.
  assertEquals(refused(burnMessage(ME, amount)), null);
  const other = b32("0x0000000000000000000000000000000000000bad");
  const cases: [string, string, string][] = [
    ["not a burn message", "0x" + "28".repeat(32), "it isn't a CCTP v2 burn"],
    ["CCTP v1", burnMessage(ME, amount, { version: 0 }), "it isn't a CCTP v2 burn"],
    ["another body", burnMessage(ME, amount, { bodyVersion: 0 }), "it isn't a CCTP v2 burn"],
    ["from another chain", burnMessage(ME, amount, { sourceDomain: 0 }), "it isn't a burn from Monad to Stellar"],
    ["to another chain", burnMessage(ME, amount, { destinationDomain: 6 }), "it isn't a burn from Monad to Stellar"],
    ["another sender", burnMessage(ME, amount, { sender: other }), "it isn't between the pinned TokenMessengerV2 and TokenMessengerMinter"],
    ["another recipient", burnMessage(ME, amount, { recipient: FORWARDER }), "it isn't between the pinned TokenMessengerV2 and TokenMessengerMinter"],
    ["minted to the user", burnMessage(ME, amount, { mintRecipient: hex(StrKey.decodeEd25519PublicKey(ME)) }), "it isn't minted to and called by the CctpForwarder"],
    ["called by anyone", burnMessage(ME, amount, { destinationCaller: "0".repeat(64) }), "it isn't minted to and called by the CctpForwarder"],
    ["another token", burnMessage(ME, amount, { burnToken: other }), "it isn't a burn of USDC"],
    ["1 base unit", burnMessage(ME, 1n), "it isn't for the transfer's amount"],
    ["less", burnMessage(ME, amount - 1n), "it isn't for the transfer's amount"],
    ["more", burnMessage(ME, amount + 1n), "it isn't for the transfer's amount"],
    ["someone else's hook", burnMessage(SPONSOR.publicKey(), amount), "its hook data isn't the transfer's address"],
    ["no hook", burnMessage(ME, amount, { hookData: "" }), "its hook data isn't the transfer's address"],
    ["a hook with more", burnMessage(ME, amount, { hookData: hex(bridge.forwarderHookData(ME)) + "01" }), "its hook data isn't the transfer's address"],
  ];
  for (const [what, message, reason] of cases) assertEquals(refused(message), reason, what);
  // A transfer recorded under 1 USDC (before the minimum) isn't relayed, its burn matching or not.
  assertEquals(refused(burnMessage(ME, 999_999n), { address: ME, amount: 999_999n }), "it isn't for the transfer's amount");
});

// ------------------------------------------------------------------------------------------------ the burn to Monad

Deno.test("the burn to Monad binds the Monad address the user confirmed, as the verifier checks it", async () => {
  fresh();
  net.rpcAccounts.add(ME);
  const spec = { kind: "cctp_burn", amount: "125000000", recipient: RECIPIENT, usdc: USDC.contract };
  const { tx, intent } = await bridge.burnToMonad(ME, spec);
  assertEquals(intent, {
    kind: "bridge_out",
    summary: "Send 12.5 USDC to Monad 0x663b…0dda",
    spend: { [USDC.contract]: "125000000" },
    calls: [{ contract: CCTP.tokenMessengerMinter, fn: "deposit_for_burn" }],
    display: { amount: "125000000", to: RECIPIENT },
    to: RECIPIENT,
  });
  // deposit_for_burn(from, amount, destination_domain, mint_recipient, burn_token, destination_caller, max_fee,
  // min_finality_threshold).
  const [call] = net.simulated;
  assertEquals([call.contract, call.fn], [CCTP.tokenMessengerMinter, "deposit_for_burn"]);
  assertEquals(Address.fromScVal(call.args[0]).toString(), ME);
  assertEquals(call.args[2].u32(), MONAD.domain);
  assertEquals(Buffer.from(call.args[3].bytes()).toString("hex"), "0".repeat(24) + RECIPIENT.slice(2));
  assertEquals(Address.fromScVal(call.args[4]).toString(), USDC.contract);
  assertEquals(Buffer.from(call.args[5].bytes()).toString("hex"), "0".repeat(64));
  assertEquals(call.args[7].u32(), 2000);
  // As built, the step passes the verifier the phone runs (WP-11's deposit_for_burn rule); bound to another address,
  // or to none, it doesn't.
  verifyTransaction(tx, intent, verifyContext(ME));
  for (const to of ["0x000000000000000000000000000000000000dEaD", undefined]) {
    assertThrows(() => verifyTransaction(tx, { ...intent, to }, verifyContext(ME)), Error, "the destination is not the one you confirmed");
  }
});

Deno.test("the allowance before the burn is for Circle's TokenMessengerMinter only", async () => {
  fresh();
  net.rpcAccounts.add(ME);
  const [approve] = bridge.outboundSteps(125_000_000n, RECIPIENT);
  const { tx, intent } = await bridge.approveForBridge(ME, approve.spec);
  verifyTransaction(tx, intent, verifyContext(ME));
  const [call] = net.simulated;
  assertEquals([call.contract, call.fn, Address.fromScVal(call.args[1]).toString(), call.args[3].u32()], [USDC.contract, "approve", CCTP.tokenMessengerMinter, 5_002_000]);
  assertEquals((await refusal(bridge.approveForBridge(ME, { ...approve.spec, spender: SPONSOR.publicKey() }))).code, "bad_spender");
});

// ------------------------------------------------------------------------------------------------ the keeper's relay

const MESSAGE = burnMessage(ME, 12_500_000n);

Deno.test("the keeper relays mint_and_forward, and lite.keeper_log records it", async () => {
  fresh();
  net.rpcAccounts.add(KEEPER.publicKey());
  const hash = await bridge.relayMintAndForward(TRANSFER, bytes(MESSAGE), bytes(ATTESTATION));
  const [tx] = net.sent;
  assertEquals([tx.hash().toString("hex"), tx.source], [hash, KEEPER.publicKey()]);
  assert(KEEPER.verify(tx.hash(), tx.signatures[0].signature()) && tx.signatures.length === 1, "signed by the keeper alone");
  assert(KEEPER.publicKey() !== SPONSOR.publicKey(), "the keeper isn't the sponsor here");
  const call = (tx.operations[0] as any).func.invokeContract();
  assertEquals([Address.fromScAddress(call.contractAddress()).toString(), call.functionName().toString()], [CCTP.forwarder, "mint_and_forward"]);
  assertEquals(call.args().map((a: xdr.ScVal) => "0x" + Buffer.from(a.bytes()).toString("hex")), [MESSAGE, ATTESTATION]);
  const [row] = ran("insert into lite.keeper_log");
  assertEquals(row.q, "insert into lite.keeper_log (hash, job, keeper, max_fee, detail) values (?, 'relay', ?, ?, ?) on conflict (hash) do nothing");
  assertEquals(row.params, [hash, KEEPER.publicKey(), tx.fee, { transfer: TRANSFER }]);
  assertEquals(ran("select to_regclass(?)")[0].params, ["lite.keeper_log"]);
});

Deno.test("before migration 05, or when keeper_log refuses the row, the relay still stands", async () => {
  for (const keeperLog of [false, "fails"] as const) {
    fresh();
    net.rpcAccounts.add(KEEPER.publicKey());
    db.keeperLog = keeperLog;
    const warn = console.warn;
    const warnings: string[] = [];
    console.warn = (...args: unknown[]) => void warnings.push(args.join(" "));
    try {
      const hash = await bridge.relayMintAndForward(TRANSFER, bytes(MESSAGE), bytes(ATTESTATION));
      assertEquals(net.sent.map((t) => t.hash().toString("hex")), [hash], String(keeperLog));
    } finally {
      console.warn = warn;
    }
    assertEquals(warnings.length, keeperLog === "fails" ? 1 : 0, String(keeperLog));
  }
});

// The indexer's view of transfers waiting on Iris, and Iris's answers for their burns.
const inbound = (id: string, burn: string, amount = 12_500_000n) => ({ id, address: ME, direction: "monad_to_stellar", amount: amount.toString(), source_tx: burn });
const irisMessages = (domain: number, burn: string, messages: { status: string; message: string }[]) =>
  net.iris.set(
    `/v2/messages/${domain}?transactionHash=${burn}`,
    () => Response.json({ messages: messages.map((m) => ({ ...m, attestation: m.status === "complete" ? ATTESTATION : "PENDING" })) }),
  );
const updates = () => db.statements.filter((s) => s.q.startsWith("update lite.bridge_transfers"));

Deno.test("the indexer: an attested transfer from Monad is relayed by the keeper and completes; one to Monad waits for its claim", async () => {
  fresh();
  net.rpcAccounts.add(KEEPER.publicKey());
  const outbound = { id: OUTBOUND, address: ME, direction: "stellar_to_monad", amount: "125000000", source_tx: "cd".repeat(32) };
  const waiting = inbound("5d0c1b7e-0000-4000-8000-000000000003", "0x" + "ef".repeat(32));
  // Reported without its 0x: Iris is asked with it.
  db.open = [inbound(TRANSFER, "ab".repeat(32)), outbound, waiting];
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: MESSAGE }]);
  irisMessages(CCTP.domain, "cd".repeat(32), [{ status: "complete", message: IRIS_STELLAR_BURN }]);
  irisMessages(MONAD.domain, "0x" + "ef".repeat(32), [{ status: "pending_confirmations", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 2);
  const [relay] = net.sent;
  assertEquals([net.sent.length, relay.source], [1, KEEPER.publicKey()]);
  const call = (relay.operations[0] as any).func.invokeContract();
  assertEquals("0x" + Buffer.from(call.args()[0].bytes()).toString("hex"), MESSAGE, "the burn's own message");
  assertEquals(updates().map((u) => [u.q, u.params.at(-1)]), [[COMPLETED, TRANSFER], [RELAYING, OUTBOUND]]);
  assertEquals(updates()[0].params, [MESSAGE, ATTESTATION, relay.hash().toString("hex"), TRANSFER], "dest_tx is the relay");
  assertEquals(ran(RELAYED)[0].params, [MESSAGE, TRANSFER]);
  assertEquals(ran("insert into lite.keeper_log")[0].params[3], { transfer: TRANSFER });
});

Deno.test("the indexer: a burn that isn't the transfer's own fails it, and the keeper relays nothing", async () => {
  // The reviewer's case first: a 1 USDC transfer started, then a burn of 1 base unit through the forwarder reported.
  const burns: [string, string, string][] = [
    ["1 base unit", burnMessage(ME, 1n), "Not relayed: it isn't for the transfer's amount."],
    ["someone else's", burnMessage(SPONSOR.publicKey(), 1_000_000n), "Not relayed: its hook data isn't the transfer's address."],
    ["callable by anyone", burnMessage(ME, 1_000_000n, { destinationCaller: "0".repeat(64) }), "Not relayed: it isn't minted to and called by the CctpForwarder."],
    ["to another chain", burnMessage(ME, 1_000_000n, { destinationDomain: 0 }), "Not relayed: it isn't a burn from Monad to Stellar."],
    ["not a burn", "0x" + "28".repeat(32), "Not relayed: it isn't a CCTP v2 burn."],
  ];
  for (const [what, message, error] of burns) {
    fresh();
    net.rpcAccounts.add(KEEPER.publicKey());
    db.open = [inbound(TRANSFER, "0x" + "ab".repeat(32), 1_000_000n)];
    irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message }]);
    assertEquals(await bridge.advanceBridges(), 0, what);
    assertEquals([net.sent, net.simulated], [[], []], `${what}: nothing relayed, nor simulated`);
    assertEquals(updates().map((u) => [u.q, u.params]), [[REFUSED, [message, error, TRANSFER]]], what);
  }
});

Deno.test("the indexer: one burn, one relay; and the transfer's own message among several", async () => {
  // The same burn reported for a second transfer, after the first completed with it: refused, unrelayed.
  fresh();
  net.rpcAccounts.add(KEEPER.publicKey());
  db.relayed.add(MESSAGE);
  db.open = [inbound(TRANSFER, "0x" + "ab".repeat(32))];
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 0);
  assertEquals(net.sent, []);
  assertEquals(updates().map((u) => [u.q, u.params]), [[RELAYED_ALREADY, [TRANSFER]]]);

  // Two transfers with the same burn in one run: the first is relayed, the second sees it.
  fresh();
  net.rpcAccounts.add(KEEPER.publicKey());
  const twin = "5d0c1b7e-0000-4000-8000-000000000003";
  db.open = [inbound(TRANSFER, "0x" + "ab".repeat(32)), inbound(twin, "0x" + "ab".repeat(32))];
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 1);
  assertEquals(net.sent.length, 1);
  assertEquals(updates().map((u) => [u.q, u.params.at(-1)]), [[COMPLETED, TRANSFER], [RELAYED_ALREADY, twin]]);

  // A transaction with two burns: the transfer's is the second; relayed once all of them are attested.
  fresh();
  net.rpcAccounts.add(KEEPER.publicKey());
  const another = burnMessage(SPONSOR.publicKey(), 12_500_000n);
  db.open = [inbound(TRANSFER, "0x" + "ab".repeat(32))];
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: another }, { status: "pending_confirmations", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 0);
  assertEquals([net.sent, updates()], [[], []], "waits while one is pending");
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: another }, { status: "complete", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 1);
  const call = (net.sent[0].operations[0] as any).func.invokeContract();
  assertEquals("0x" + Buffer.from(call.args()[0].bytes()).toString("hex"), MESSAGE);
});

Deno.test("the indexer: a relay that fails is recorded and tried again next run", async () => {
  fresh();
  // The keeper's account doesn't exist: the relay throws before anything is sent.
  db.open = [inbound(TRANSFER, "0x" + "ab".repeat(32))];
  irisMessages(MONAD.domain, "0x" + "ab".repeat(32), [{ status: "complete", message: MESSAGE }]);
  assertEquals(await bridge.advanceBridges(), 0);
  assertEquals(updates().map((u) => [u.q, u.params]), [[RELAY_ERROR, [MESSAGE, ATTESTATION, "the keeper's account doesn't exist", TRANSFER]]]);
});

// ------------------------------------------------------------------------------------------------ mainnet

Deno.test("mainnet: starting a transfer stays 501 mainnet_route until the mainnet program", async () => {
  fresh();
  Deno.env.set("LITE_NETWORK", "mainnet");
  try {
    for (const direction of ["monad_to_stellar", "stellar_to_monad"]) {
      assertEquals(await refusal(bridge.startBridge(ME, { direction, amount: 10_000_000n, monadAddress: RECIPIENT })), {
        status: 501,
        code: "mainnet_route",
        message: "Mainnet bridging uses NEAR Intents; enable it with the mainnet launch.",
      });
    }
  } finally {
    Deno.env.set("LITE_NETWORK", "testnet");
  }
  assertEquals([net.asked, db.statements], [[], []]);
});
