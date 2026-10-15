// WP-17's payloads equal the API contract's fixtures (backend/tests/fixtures/api/; docs/DESIGN-stellar-parity.md
// §6.0, §12.5): bridge-quote, bridge-start-in, bridge-start-out, bridge-source, bridge-claimed and bridge-status,
// produced by _shared/bridge.ts from seeded Iris, Horizon, RPC and database answers that carry the fixtures' figures.
//
// Three parts are compared otherwise, each for its reason:
// - bridge-start-out's plan is plans.ts's (WP-10): its envelopes, fees and payers. The bridge's own part is compared:
//   the transfer, the steps' labels and kinds, and the allowance's intent.
// - bridge-start-in's hook data: the API sends Circle's CctpForwarder layout (24 zero bytes, a version and a length
//   before the address: developers.circle.com/cctp/references/stellar, "Hook format"). WP-03's fixture writes
//   "cctp-forward" and the address instead. The fixture may hold either until it is corrected; the rest of the call
//   equals it.
// - bridge-status's claim: the API puts the attestation's offset at 0x80, as the ABI does (the two offset words and
//   the 32-byte message with its length), which Monad testnet's MessageTransmitterV2 accepted (docs/VERIFICATION.md).
//   WP-03's fixture puts it at 0xa0, past its length word. The fixture may hold either until it is corrected; the rest
//   of the answer equals it.
import { Keypair, SorobanDataBuilder, StrKey, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals } from "jsr:@std/assert@1";
import { fakeSql, setTestEnv } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const bridge = await import("../../supabase/functions/_shared/bridge.ts");
const { rpcServer } = await import("../../supabase/functions/_shared/stellar.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");

const fixture = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`../fixtures/api/${name}.json`, import.meta.url)));

/** The fixtures' account, and the Monad address bridge-status names. */
const ME = "GCLJGH5ZEKQ4G5FLKD6Z5667CUAWQZCNZRMDZLSZKARC6GMOTN46BNYH";
const MONAD_ADDRESS = "0x663b5d4f0412dbf5b0fb0773e7f0602d11a80dda";
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const MONAD = TESTNET.bridge.monad!;
const CCTP = TESTNET.contracts.cctp!;

// ------------------------------------------------------------------------------------------------ the seeded world

/** Iris's fee table for Monad → Stellar where a standard transfer costs 1 basis point: the fixture's fee of 1,250 on
 *  12.5 USDC. */
const IRIS_FEES = [{ finalityThreshold: 1000, minimumFee: 1 }, { finalityThreshold: 2000, minimumFee: 1 }];

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

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.origin === TESTNET.apis.iris && url.pathname === `/v2/burn/USDC/fees/${MONAD.domain}/${CCTP.domain}`) return Response.json(IRIS_FEES);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === `/accounts/${ME}`) {
    return Response.json({
      id: ME,
      account_id: ME,
      sequence: "22096910953218050",
      subentry_count: 1,
      num_sponsoring: 0,
      num_sponsored: 0,
      signers: [],
      balances: [
        { balance: "5.2300000", limit: "922337203685.4775807", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] },
        { balance: "10000.0000000", asset_type: "native" },
      ],
    });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    const result = body.method === "getLedgerEntries"
      ? accountEntry(ME)
      : body.method === "simulateTransaction"
      ? {
        latestLedger: 1,
        minResourceFee: "1000",
        transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
        results: [{ auth: [], xdr: xdr.ScVal.scvVoid().toXDR("base64") }],
        events: [],
      }
      : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  return new Response("offline: unit tests make no network calls", { status: 503 });
}) as typeof fetch;

// RPC's latest ledger carries a whole ledger's metadata: set on the client instead.
rpcServer().getLatestLedger = () => Promise.resolve({ id: "ab".repeat(32), protocolVersion: 23, sequence: 5_000_000 } as any);

const STATUS_ROW = {
  id: "67904f04-179c-49db-a5b8-edeb7d2f64ed",
  address: ME,
  direction: "stellar_to_monad",
  route: "cctp",
  amount: "125000000",
  recipient: MONAD_ADDRESS,
  source_tx: "cb98bc255c80110ab67a1ff91bee66d33ca71cecb9621f0985d24566caa44f95",
  message: "0x28850e5d54517caaaab0a200a46f9e438629b436c204a61e1e0fe28d4718e9eb",
  attestation: "0x82d293b351dbcde9250c26351b0f6c2efa7b300e29c0de7ea2d871148690caa9d72614b420f2a245f656d8ea25f8e110dbcf5dc2051fc933e0a3b97bf2993a901b",
  dest_tx: null,
  status: "relaying",
  error: null,
  relay_day: null,
  created_at: new Date("2026-10-14T09:41:00.000Z"),
  updated_at: new Date("2026-10-14T09:44:30.000Z"),
};

replaceSql(fakeSql((q, params) => {
  // Two transfers from Monad completed so far: too few for a time.
  if (q.startsWith("select extract(epoch from updated_at - created_at)::float8 as seconds")) return [{ seconds: 212.4 }, { seconds: 187.9 }];
  // The user's relays of the day: none yet, under the lock or not.
  if (q.startsWith("select pg_advisory_xact_lock(")) return [{ pg_advisory_xact_lock: "" }];
  if (q.startsWith("select count(*)::int as relays from lite.bridge_transfers")) return [{ relays: 0 }];
  if (q.startsWith("insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day) values (?, 'monad_to_stellar'")) {
    return [{ id: "c69ef4a0-421e-418d-a93b-92081f4a0fcb", status: "awaiting_source" }];
  }
  if (q.startsWith("insert into lite.bridge_transfers (address, direction, route, amount, recipient) values (?, 'stellar_to_monad'")) {
    return [{ id: "67904f04-179c-49db-a5b8-edeb7d2f64ed", status: "awaiting_source" }];
  }
  // bridge-source's transfer, started today.
  if (q.startsWith("select relay_day < (now() at time zone 'utc')::date as late from lite.bridge_transfers")) return [{ late: false }];
  if (q.startsWith("update lite.bridge_transfers set source_tx")) return [{ id: params[1], status: "attesting" }];
  if (q.startsWith("update lite.bridge_transfers set dest_tx")) return [{ id: params[1] }];
  if (q === "select * from lite.bridge_transfers where id = ? and address = ?") return params[0] === STATUS_ROW.id ? [STATUS_ROW] : [];
  throw new Error(`unexpected query: ${q}`);
}));

const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const lengthWord = (n: number) => n.toString(16).padStart(64, "0");

// ------------------------------------------------------------------------------------------------ the payloads

Deno.test("POST /v1/bridge/quote equals bridge-quote.json: Circle's fee from Iris, and no time from two transfers", async () => {
  assertEquals(await bridge.bridgeQuote({ direction: "monad_to_stellar", amount: 12_500_000n }), fixture("bridge-quote"));
});

Deno.test("POST /v1/bridge/start from Monad equals bridge-start-in.json, with Circle's hook layout", async () => {
  const f = fixture("bridge-start-in");
  const start = await bridge.startBridge(ME, { direction: "monad_to_stellar", amount: 12_500_000n, monadAddress: MONAD_ADDRESS });
  assertEquals(start.transfer, f.transfer);
  assertEquals(start.evmSteps![0], f.evmSteps[0]);
  const { data, ...burn } = start.evmSteps![1];
  const { data: fixtureData, ...fixtureBurn } = f.evmSteps[1];
  assertEquals(burn, fixtureBurn);
  // The selector and the eight head words (amount, Stellar's domain, the forwarder as recipient, USDC, the forwarder as
  // caller, no max fee, standard finality, the hook's offset), as the fixture has them.
  const head = 2 + 8 + 8 * 64;
  assertEquals(data.slice(0, head), fixtureData.slice(0, head));
  assertEquals(data.slice(10 + 64 * 2, 10 + 64 * 3), hex(StrKey.decodeContract(CCTP.forwarder)));
  // Then the hook: its length and Circle's layout of the user's address (88 bytes, padded to 96).
  const circles = lengthWord(88) + hex(bridge.forwarderHookData(ME)).padEnd(192, "0");
  assertEquals(data.slice(head), circles);
  // The fixture's hook is Circle's layout once corrected; until then, WP-03's "cctp-forward" and the address (68 bytes).
  const wp03 = lengthWord(68) + hex(new TextEncoder().encode(`cctp-forward${ME}`)).padEnd(192, "0");
  assert([circles, wp03].includes(fixtureData.slice(head)), `bridge-start-in.json's hook: ${fixtureData.slice(head)}`);
});

Deno.test("POST /v1/bridge/start to Monad equals bridge-start-out.json: the transfer, the plan's steps and the allowance", async () => {
  const f = fixture("bridge-start-out");
  assertEquals(await bridge.newOutboundTransfer(ME, 125_000_000n, MONAD_ADDRESS), f.transfer);
  const steps = bridge.outboundSteps(125_000_000n, MONAD_ADDRESS);
  assertEquals(steps.map((s) => [s.label, s.spec.kind]), f.plan.steps.map((s: { label: string; stepKind: string }) => [s.label, s.stepKind]));
  const { tx, intent } = await bridge.approveForBridge(ME, steps[0].spec);
  assertEquals([tx.source, intent], [ME, f.plan.steps[0].intent]);
  // The burn, built once the allowance confirms, binds the Monad address (§5.2).
  const burn = await bridge.burnToMonad(ME, steps[1].spec);
  assertEquals([burn.tx.source, burn.intent.to], [ME, MONAD_ADDRESS]);
});

Deno.test("POST /v1/bridge/:id/source equals bridge-source.json", async () => {
  const f = fixture("bridge-source");
  assertEquals(await bridge.setSourceTx(ME, f.id, "0x" + "cd".repeat(32)), f);
});

Deno.test("POST /v1/bridge/:id/claimed equals bridge-claimed.json", async () => {
  const f = fixture("bridge-claimed");
  assertEquals(await bridge.markClaimed(ME, f.id, "0x" + "ef".repeat(32)), f);
});

Deno.test("GET /v1/bridge/:id equals bridge-status.json, with the ABI's offset for the attestation", async () => {
  const f = fixture("bridge-status");
  const status = await bridge.transferStatus(ME, STATUS_ROW.id);
  const { data, ...claim } = status.claim!;
  const { data: fixtureData, ...fixtureClaim } = f.claim;
  assertEquals({ ...status, claim }, { ...f, claim: fixtureClaim });
  // receiveMessage(message, attestation): the offsets 0x40 and 0x80, then each with its length.
  const words = (d: string) => d.slice(10).match(/.{64}/g)!;
  assertEquals([data.slice(0, 10), words(data)[0], words(data)[1]], ["0x57ecfd28", lengthWord(0x40), lengthWord(0x80)]);
  // The fixture's attestation offset is the ABI's once corrected; until then, WP-03's 0xa0. Every other word is the same.
  assert([lengthWord(0x80), lengthWord(0xa0)].includes(words(fixtureData)[1]), `bridge-status.json's second offset: ${words(fixtureData)[1]}`);
  assertEquals([data.slice(0, 10), words(data)[0], ...words(data).slice(2)], [fixtureData.slice(0, 10), words(fixtureData)[0], ...words(fixtureData).slice(2)]);
});
