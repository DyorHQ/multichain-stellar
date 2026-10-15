// Hybrid fees on the server (docs/DESIGN-stellar-parity.md §4, §12.5): the inclusion bid's clamp and the resource-fee
// margin; prepare() on a simulation recorded from testnet, whose headroom must reach the transaction a step declares;
// minBalance and spendable from Horizon's accounts (a Friendbot one, a sponsored mainnet one, offers' selling
// liabilities, an account that sponsors others); assertAffordable's order and codes; the estimates' history, defaults
// and cap; feeCeiling; the add-funds card; starterSwapEligibility's truth table; a starter swap's SDEX fallback, taken
// only when it qualifies; and the submit path: a fee above the cap is 422 fee_too_high when a step is built and when it
// is sent, a user-paid step is sent as signed and logged as the user's, and an activation reserves its sponsorship,
// releases it when RPC refused the transaction and keeps it when RPC didn't confirm it.
import { Account, Address, Asset, Contract, Keypair, nativeToScVal, Operation, SorobanDataBuilder, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { fakeSql, OTHER, setTestEnv, SPONSOR, USER, XLM_SAC } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const fees = await import("../../supabase/functions/_shared/fees.ts");
const { classicBalances, invoke, sorobanDataOf, sv, withInclusionBid, withResourceMargin } = await import("../../supabase/functions/_shared/stellar.ts");
const { ApiError, clientIp } = await import("../../supabase/functions/_shared/http.ts");
const { createPlan, registerBuilder, submitStep } = await import("../../supabase/functions/_shared/plans.ts");
// The send's and the swaps' builders, which register themselves.
await import("../../supabase/functions/_shared/account.ts");
await import("../../supabase/functions/_shared/swap.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
type StarterInput = import("../../supabase/functions/_shared/fees.ts").StarterInput;

const PASS = TESTNET.passphrase;
const POLICY = TESTNET.feePolicy;
const ONE = 10_000_000n;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;

// ------------------------------------------------------------------------------------------------ the network

/** Horizon accounts by address; RPC answers by method. Anything else is offline. */
const horizonAccounts = new Map<string, Record<string, unknown>>();
let rpc: (method: string, params: any) => unknown = () => {
  throw new Error("offline");
};

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
    const a = horizonAccounts.get(url.pathname.split("/")[2]);
    return a ? Response.json(a) : Response.json({ title: "Resource Missing", status: 404 }, { status: 404 });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ sequence: 5_200_000, base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  if (url.host === "soroban-testnet.stellar.org") {
    const body = await req.json();
    try {
      return Response.json({ jsonrpc: "2.0", id: body.id, result: rpc(body.method, body.params) });
    } catch (err) {
      return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: String((err as Error).message) } });
    }
  }
  return new Response("offline: unit tests make no network calls", { status: 503 });
}) as typeof fetch;

/** Horizon's account record, with the native balance and any trustlines. */
function horizonAccount(address: string, o: { xlm: string; selling?: string; subentries?: number; sponsoring?: number; sponsored?: number; lines?: Record<string, unknown>[] }) {
  return {
    id: address,
    account_id: address,
    sequence: "22096910953218048",
    subentry_count: o.subentries ?? 0,
    num_sponsoring: o.sponsoring ?? 0,
    num_sponsored: o.sponsored ?? 0,
    thresholds: { low_threshold: 0, med_threshold: 0, high_threshold: 0 },
    flags: { auth_required: false, auth_revocable: false, auth_immutable: false, auth_clawback_enabled: false },
    signers: [{ weight: 1, key: address, type: "ed25519_public_key" }],
    data: {},
    balances: [
      ...(o.lines ?? []),
      { balance: o.xlm, buying_liabilities: "0.0000000", selling_liabilities: o.selling ?? "0.0000000", asset_type: "native" },
    ],
  };
}

/** RPC's getLedgerEntries answer for an account entry at `seq`. */
function accountEntry(address: string, seq: bigint) {
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: Keypair.fromPublicKey(address).xdrAccountId() }));
  const val = xdr.LedgerEntryData.account(
    new xdr.AccountEntry({
      accountId: Keypair.fromPublicKey(address).xdrAccountId(),
      balance: xdr.Int64.fromString("100000000000"),
      seqNum: xdr.Int64.fromString(seq.toString()),
      numSubEntries: 0,
      inflationDest: null,
      flags: 0,
      homeDomain: "",
      thresholds: Buffer.from([1, 0, 0, 0]),
      signers: [],
      ext: new xdr.AccountEntryExt(0),
    }),
  );
  return { entries: [{ key: key.toXDR("base64"), xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }], latestLedger: 5_200_000 };
}

function position(address: string) {
  return classicBalances(address).then((a) => fees.positionOf(a, 5_000_000n)!);
}

// ------------------------------------------------------------------------------------------------ pure parts

Deno.test("the inclusion bid: getFeeStats' p90, at least 100, at most half maxInclusionPerOp; 100 when unsaid", () => {
  const p = { maxInclusionPerOp: 200_000n };
  assertEquals([fees.inclusionBid("100", p), fees.inclusionBid("150", p), fees.inclusionBid("50", p)], [100n, 150n, 100n]);
  assertEquals([fees.inclusionBid("100001", p), fees.inclusionBid("99999999", p)], [100_000n, 100_000n]);
  assertEquals([fees.inclusionBid(undefined, p), fees.inclusionBid("1e5", p), fees.inclusionBid(150, p)], [100n, 100n, 100n]);
});

Deno.test("the resource fee: the simulation's minimum × 1.15 + 50,000, rounded up", () => {
  assertEquals([withResourceMargin(0n), withResourceMargin(1_000n), withResourceMargin(123n), withResourceMargin(1_000_000n)], [50_000n, 51_150n, 50_142n, 1_200_000n]);
});

// ------------------------------------------------------------------------------------------------ resource headroom

/** Testnet's Friendbot account. */
const FRIENDBOT = "GAIH3ULLFQ4DGSECF2AR555KZ4KNDGEKN4AFI4SU2M7B43MGK3QJZNSR";
const ROUTER = TESTNET.contracts.soroswapRouter;

/** Testnet RPC's answer to simulateTransaction, recorded on 2026-10-15 at ledger 5,201,333, for a 1 XLM transfer
 *  through the XLM SAC from testnet's Friendbot account to the Soroswap router: the call the send builder makes for
 *  XLM sent to a contract. The router's XLM balance was archived, so the answer also restores it (the transaction
 *  data's list of archived entries), and its minimum resource fee pays that rent. */
const RECORDED_TRANSFER = {
  transactionData:
    "AAAAAQAAAAEAAAABAAAAAQAAAAYAAAAB15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAAUAAAAAQAAAAIAAAAAAAAAABB90WssODNIgi6BHveqzxTRmIpvAFRyVNM+Hm2GVuCcAAAABgAAAAHXkotywnA8z+r365/0701QSlWouXn8m0UOoshCtNHOYQAAABAAAAABAAAAAgAAAA8AAAAHQmFsYW5jZQAAAAASAAAAAZNB96A3rdOBHVxq1QCdsN/bmyGg5ds2aKjp92vcpnJPAAAAAQAEFeUAAAFwAAABcAAAAAAAC1br",
  events: [
    "AAAAAQAAAAAAAAAAAAAAAgAAAAAAAAADAAAADwAAAAdmbl9jYWxsAAAAAA0AAAAg15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAAPAAAACHRyYW5zZmVyAAAAEAAAAAEAAAADAAAAEgAAAAAAAAAAEH3Rayw4M0iCLoEe96rPFNGYim8AVHJU0z4ebYZW4JwAAAASAAAAAZNB96A3rdOBHVxq1QCdsN/bmyGg5ds2aKjp92vcpnJPAAAACgAAAAAAAAAAAAAAAACYloA=",
    "AAAAAQAAAAAAAAAB15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAABAAAAAAAAAAQAAAAPAAAACHRyYW5zZmVyAAAAEgAAAAAAAAAAEH3Rayw4M0iCLoEe96rPFNGYim8AVHJU0z4ebYZW4JwAAAASAAAAAZNB96A3rdOBHVxq1QCdsN/bmyGg5ds2aKjp92vcpnJPAAAADgAAAAZuYXRpdmUAAAAAAAoAAAAAAAAAAAAAAAAAmJaA",
    "AAAAAQAAAAAAAAAB15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAACAAAAAAAAAAIAAAAPAAAACWZuX3JldHVybgAAAAAAAA8AAAAIdHJhbnNmZXIAAAAB",
  ],
  minResourceFee: "743147",
  results: [
    {
      auth: [
        "AAAAAAAAAAAAAAAB15KLcsJwPM/q9+uf9O9NUEpVqLl5/JtFDqLIQrTRzmEAAAAIdHJhbnNmZXIAAAADAAAAEgAAAAAAAAAAEH3Rayw4M0iCLoEe96rPFNGYim8AVHJU0z4ebYZW4JwAAAASAAAAAZNB96A3rdOBHVxq1QCdsN/bmyGg5ds2aKjp92vcpnJPAAAACgAAAAAAAAAAAAAAAACYloAAAAAA",
      ],
      xdr: "AAAAAQ==",
    },
  ],
  stateChanges: [
    {
      type: "updated",
      key: "AAAAAAAAAAAQfdFrLDgzSIIugR73qs8U0ZiKbwBUclTTPh5thlbgnA==",
      before:
        "AE9dswAAAAAAAAAAEH3Rayw4M0iCLoEe96rPFNGYim8AVHJU0z4ebYZW4JwBIyuRcnOkBAAAAKIAAAHCAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAwAAAAAATOeHAAAAAGrD50YAAAAA",
      after:
        "AAAAAAAAAAAAAAAAEH3Rayw4M0iCLoEe96rPFNGYim8AVHJU0z4ebYZW4JwBIyuRcdsNhAAAAKIAAAHCAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAwAAAAAATOeHAAAAAGrD50YAAAAA",
    },
    {
      type: "created",
      key: "AAAABgAAAAHXkotywnA8z+r365/0701QSlWouXn8m0UOoshCtNHOYQAAABAAAAABAAAAAgAAAA8AAAAHQmFsYW5jZQAAAAASAAAAAZNB96A3rdOBHVxq1QCdsN/bmyGg5ds2aKjp92vcpnJPAAAAAQ==",
      before: null,
      after:
        "AAFVkAAAAAYAAAAAAAAAAdeSi3LCcDzP6vfrn/TvTVBKVai5efybRQ6iyEK00c5hAAAAEAAAAAEAAAACAAAADwAAAAdCYWxhbmNlAAAAABIAAAABk0H3oDet04EdXGrVAJ2w39ubIaDl2zZoqOn3a9ymck8AAAABAAAAEQAAAAEAAAADAAAADwAAAAZhbW91bnQAAAAAAAoAAAAAAAAAAAAAABdH3lGAAAAADwAAAAphdXRob3JpemVkAAAAAAAAAAAAAQAAAA8AAAAIY2xhd2JhY2sAAAAAAAAAAAAAAAA=",
    },
  ],
  latestLedger: 5201333,
};

/** The headroom prepare() gives the recorded transfer: 267,749 instructions × 1.25 + 100,000; 368 bytes read and 368
 *  written, each × 1.2 + 1,000; the minimum resource fee, 743,147, × 1.15 + 50,000. */
const HEADROOM = { instructions: 434_687, readBytes: 1_442, writeBytes: 1_442, resourceFee: 904_620n };

function resourcesOf(tx: Transaction) {
  const data = sorobanDataOf(tx)!;
  const r = data.resources();
  return { instructions: r.instructions(), readBytes: r.diskReadBytes(), writeBytes: r.writeBytes(), resourceFee: BigInt(data.resourceFee().toString()) };
}

Deno.test("prepare(): the recorded simulation's resources and resource fee reach the assembled transaction with their headroom", async () => {
  rpc = (method) => {
    if (method === "simulateTransaction") return RECORDED_TRANSFER;
    throw new Error(`unexpected RPC ${method}`);
  };
  const recorded = new SorobanDataBuilder(RECORDED_TRANSFER.transactionData).build();
  const r = recorded.resources();
  assertEquals([r.instructions(), r.diskReadBytes(), r.writeBytes(), recorded.resourceFee().toString()], [267_749, 368, 368, "743147"]);

  const tx = await invoke(new Account(FRIENDBOT, "22096910953218048"), XLM_SAC, "transfer", [sv.addr(FRIENDBOT), sv.addr(ROUTER), sv.i128(ONE)]);
  assertEquals(resourcesOf(tx), HEADROOM);
  assertEquals(HEADROOM.resourceFee, withResourceMargin(743_147n));
  // The fee: the resource fee and the base fee the transaction was built with, 100 for its one operation.
  assertEquals(tx.fee, (HEADROOM.resourceFee + 100n).toString());
  // Everything else is the simulation's: the footprint, the archived entry it restores, the authorization.
  const data = sorobanDataOf(tx)!;
  assertEquals(data.resources().footprint().toXDR("base64"), r.footprint().toXDR("base64"));
  assertEquals(data.ext().toXDR("base64"), recorded.ext().toXDR("base64"));
  assertEquals((tx.operations[0] as Operation.InvokeHostFunction).auth?.map((a) => a.toXDR("base64")), RECORDED_TRANSFER.results[0].auth);

  // A step's inclusion bid changes the fee and nothing else.
  const bid = withInclusionBid(tx, 250n);
  assertEquals([resourcesOf(bid), bid.fee], [HEADROOM, (HEADROOM.resourceFee + 250n).toString()]);
  assertEquals(sorobanDataOf(bid)!.toXDR("base64"), data.toXDR("base64"));
});

Deno.test("a send built on the recorded simulation declares that headroom, and its maxFee is the fee it declares", async () => {
  horizonAccounts.set(FRIENDBOT, horizonAccount(FRIENDBOT, { xlm: "100000.0000000" }));
  rpc = (method) => {
    if (method === "getFeeStats") return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: 1 };
    if (method === "getLedgerEntries") return accountEntry(FRIENDBOT, 22096910953218048n);
    if (method === "simulateTransaction") return RECORDED_TRANSFER;
    throw new Error(`unexpected RPC ${method}`);
  };
  replaceSql(fakeSql((q) => {
    if (q.startsWith("insert into lite.plans")) return [{ id: "3c0e2b9a-0000-4000-8000-000000000005", expires_at: new Date(Date.now() + 1_800_000) }];
    throw new Error(`unexpected query: ${q}`);
  }));
  const plan = await createPlan(FRIENDBOT, "payment", [{ label: "Send", spec: { kind: "payment", asset: "XLM", to: ROUTER, amount: ONE.toString(), memo: null, memoType: null } }]);
  const [step] = plan.steps;
  const tx = TransactionBuilder.fromXDR(step.xdr!, PASS) as Transaction;
  assertEquals(resourcesOf(tx), HEADROOM);
  const fee = (HEADROOM.resourceFee + 100n).toString();
  assertEquals([step.stepKind, step.feePayer, step.maxFee, tx.fee, plan.fees!.userMax], ["payment_token", "user", fee, fee, fee]);
});

Deno.test("minBalance and spendable from Horizon: Friendbot, sponsored mainnet, liabilities, sponsoring", async () => {
  const usdcLine = { balance: "5.2300000", limit: "922337203685.4775807", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1] };
  const cases: [string, Parameters<typeof horizonAccount>[1], [string, string]][] = [
    // Friendbot's 10,000 XLM with USDC enabled: 3 base reserves.
    ["friendbot", { xlm: "10000.0000000", subentries: 1, lines: [usdcLine] }, ["15000000", "99985000000"]],
    // Mainnet's sponsored setup: 0 XLM, its own 2 reserves and USDC's paid by the sponsor.
    ["sponsored", { xlm: "0.0000000", subentries: 1, sponsored: 3, lines: [{ ...usdcLine, sponsor: SPONSOR.publicKey() }] }, ["0", "0"]],
    // After a starter swap delivered 2 XLM.
    ["starter", { xlm: "2.0000000", subentries: 1, sponsored: 3, lines: [usdcLine] }, ["0", "20000000"]],
    // An offer selling 20 XLM: 2 subentries, and the 20 XLM are held.
    ["offers", { xlm: "100.0000000", selling: "20.0000000", subentries: 2 }, ["20000000", "780000000"]],
    // Sponsoring 2 entries elsewhere holds their reserves here.
    ["sponsoring", { xlm: "10.0000000", sponsoring: 2 }, ["20000000", "80000000"]],
    // Below its minimum: nothing to spend.
    ["short", { xlm: "1.2000000", subentries: 1 }, ["15000000", "0"]],
  ];
  for (const [name, o, [min, spendable]] of cases) {
    const address = Keypair.random().publicKey();
    horizonAccounts.set(address, horizonAccount(address, o));
    const p = await position(address);
    assertEquals([p.minBalance, p.spendable, p.baseReserve], [min, spendable, "5000000"], name);
  }
  // Liquidity-pool shares aren't balances.
  const pooled = Keypair.random().publicKey();
  horizonAccounts.set(pooled, horizonAccount(pooled, { xlm: "5.0000000", subentries: 2, lines: [{ balance: "1.0000000", liquidity_pool_id: "ab".repeat(32), asset_type: "liquidity_pool_shares" }] }));
  assertEquals((await classicBalances(pooled))!.balances.map((b) => b.asset), ["native"]);
  assertEquals(fees.positionOf(null, 5_000_000n), null);
});

Deno.test("assertAffordable: the fee first, then the reserve, then the XLM spent; detail for the copy", () => {
  const at = { spendable: 1_000_000n, minBalance: 15_000_000n };
  const refusal = (need: { fee: bigint; reserve: bigint; amount: bigint }) => {
    const e = assertThrows(() => fees.assertAffordable(at, need), ApiError);
    return [e.status, e.code, e.message, e.detail];
  };
  assertEquals(refusal({ fee: 1_000_001n, reserve: 0n, amount: 0n }), [409, "not_enough_xlm_for_fee", "Not enough XLM for the network fee.", { need: "1000001", spendable: "1000000" }]);
  // The fee alone is too much even when the amount would be too: the fee is named.
  assertEquals(refusal({ fee: 2_000_000n, reserve: 5_000_000n, amount: 9n * ONE })[1], "not_enough_xlm_for_fee");
  assertEquals(refusal({ fee: 10_000n, reserve: 5_000_000n, amount: 0n }), [409, "not_enough_xlm_for_reserve", "Not enough XLM for Stellar's minimum balance.", { need: "5010000", spendable: "1000000" }]);
  assertEquals(refusal({ fee: 10_000n, reserve: 0n, amount: 990_001n }), [
    409,
    "not_enough_xlm",
    "Not enough XLM. 1.5 XLM stays in your account.",
    { need: "1000001", spendable: "1000000", minBalance: "15000000" },
  ]);
  fees.assertAffordable(at, { fee: 10_000n, reserve: 0n, amount: 990_000n });
  fees.assertAffordable(at, { fee: 0n, reserve: 0n, amount: 0n });
});

Deno.test("estimates: history's p90 × 5/4, the defaults without it, never above maxFee; updatedAt the newest counted", () => {
  const none = fees.estimatesFrom([], POLICY.maxFee);
  assertEquals([none.estimates.trust, none.estimates.launch_create, none.estimates.moment_collect, none.updatedAt], [10_000n, 10_000_000n, 10_000_000n, null]);
  assert(Object.values(none.basis).every((b) => b === "default"));
  // v1's 18 kinds and contracts v2's 22.
  assertEquals(Object.keys(none.estimates).length, 40);
  const at = (s: string) => new Date(`2026-10-14T${s}.000Z`);
  const est = fees.estimatesFrom([
    { stepKind: "trust", p90: 8_000n, latest: at("09:40:00") },
    { stepKind: "swap_soroswap", p90: 120_001n, latest: at("09:30:00") },
    { stepKind: "launch_graduate", p90: 40_000_000n, latest: at("08:00:00") },
    { stepKind: "faucet", p90: 1_000n, latest: at("10:00:00") },
    { stepKind: "payment", p90: 0n, latest: at("10:30:00") },
  ], POLICY.maxFee);
  assertEquals([est.estimates.trust, est.basis.trust], [10_000n, "history"]);
  assertEquals([est.estimates.swap_soroswap, est.basis.swap_soroswap], [150_002n, "history"]);
  assertEquals([est.estimates.launch_graduate, est.basis.launch_graduate], [POLICY.maxFee, "history"]);
  assertEquals([est.estimates.payment, est.basis.payment], [10_000n, "default"]);
  assertEquals(est.updatedAt, at("09:40:00"));
});

Deno.test("feeCeiling: an activation's is the sponsor's cap; others are their kind's estimate from the history", async () => {
  replaceSql(fakeSql((q) => {
    if (q.startsWith("select step_kind, percentile_disc(0.9)")) return [{ step_kind: "trust", p90: "8000", latest: new Date("2026-10-14T09:40:00Z") }];
    throw new Error(`unexpected query: ${q}`);
  }));
  assertEquals(await fees.feeCeiling("activate"), POLICY.activationMaxFee);
  assertEquals(await fees.feeCeiling("trust"), 10_000n);
  assertEquals(await fees.feeCeiling("launch_create"), 10_000_000n);
});

Deno.test("the add-funds card: needsXlm under the floor, 2 XLM for a missing account, 1 XLM plus any reserve lacking", () => {
  const p = (balance: string, min: string, spendable: string) => ({ balance, minBalance: min, sellingLiabilities: "0", spendable, baseReserve: "5000000", reserves: { base: 2, subentries: 1, sponsoring: 0, sponsored: 0 } });
  const faucet = { amount: "10000", usedToday: false };
  assertEquals(fees.firstFunding(null, POLICY, "unavailable", faucet), { needsXlm: true, suggestXlm: "20000000", starterSwap: "unavailable", faucet });
  assertEquals(fees.firstFunding(p("100000000000", "15000000", "99985000000"), POLICY, "unavailable", faucet).suggestXlm, "10000000");
  assertEquals(fees.firstFunding(p("100000000000", "15000000", "99985000000"), POLICY, null, null), { needsXlm: false, suggestXlm: "10000000", starterSwap: null, faucet: null });
  const short = fees.firstFunding(p("12000000", "15000000", "0"), POLICY, "unavailable", faucet);
  assertEquals([short.needsXlm, short.suggestXlm], [true, "13000000"]);
  assertEquals(fees.firstFunding(p("15999999", "15000000", "999999"), POLICY, null, null).needsXlm, true);
  assertEquals(fees.firstFunding(p("16000000", "15000000", "1000000"), POLICY, null, null).needsXlm, false);
});

Deno.test("starterSwapEligibility: each condition in order, and the one case that is eligible", () => {
  const ok: StarterInput = { activation: "sponsored", buysXlm: true, sellsRegistryAsset: true, spendable: 0n, minOut: 10_000_000n, used: false };
  const verdict = (o: Partial<StarterInput>) => fees.starterSwapEligibility({ ...ok, ...o }, POLICY);
  assertEquals(verdict({}), { eligible: true, reason: null });
  assertEquals(verdict({ spendable: 499_999n, minOut: 10_000_001n }), { eligible: true, reason: null });
  assertEquals(verdict({ activation: "friendbot" }), { eligible: false, reason: "activation" });
  assertEquals(verdict({ buysXlm: false }), { eligible: false, reason: "buy_not_xlm" });
  assertEquals(verdict({ sellsRegistryAsset: false }), { eligible: false, reason: "sell_not_registry" });
  assertEquals(verdict({ spendable: 500_000n }), { eligible: false, reason: "has_xlm" });
  assertEquals(verdict({ minOut: 9_999_999n }), { eligible: false, reason: "too_small" });
  assertEquals(verdict({ used: true }), { eligible: false, reason: "used" });
  // The first reason that applies is the one given.
  assertEquals(verdict({ activation: "friendbot", used: true, spendable: 9n * ONE }), { eligible: false, reason: "activation" });
  assertEquals(verdict({ spendable: 9n * ONE, minOut: 1n, used: true }), { eligible: false, reason: "has_xlm" });
  assertEquals(verdict({ minOut: 1n, used: true }), { eligible: false, reason: "too_small" });
});

// ------------------------------------------------------------------------------------------------ building and sending

/** The XLM SAC's transfer from `source`, declaring `resourceFee`, as prepare() would leave it. */
function costlyTransfer(source: string, resourceFee: bigint): Transaction {
  const data = new SorobanDataBuilder().setResources(1_000, 1_000, 1_000).setResourceFee(resourceFee).build();
  return new TransactionBuilder(new Account(source, "22096910953218048"), { fee: "100", networkPassphrase: PASS })
    .addOperation(new Contract(XLM_SAC).call("transfer", new Address(source).toScVal(), new Address(OTHER.publicKey()).toScVal(), nativeToScVal(ONE, { type: "i128" })))
    .setSorobanData(data)
    .setTimeout(600)
    .build();
}

const COSTLY_INTENT = { kind: "payment", summary: "Send 1 XLM", spend: { [XLM_SAC]: ONE.toString() }, calls: [{ contract: XLM_SAC, fn: "transfer" }], to: OTHER.publicKey() };

registerBuilder("test_costly", (user) => Promise.resolve({ tx: costlyTransfer(user, 40_000_000n), intent: COSTLY_INTENT }));

/** The database behind a plan with one built step: records every query and answers the plan's own. */
function planDb(planId: string, step: Record<string, unknown>, answer: (q: string, ps: unknown[]) => Record<string, unknown>[] | null = () => null) {
  const seen: { q: string; ps: unknown[] }[] = [];
  replaceSql(fakeSql((q, ps) => {
    seen.push({ q, ps });
    const own = answer(q, ps);
    if (own) return own;
    if (q === "select kind, steps, expires_at from lite.plans where id = ? and address = ?") {
      return ps[0] === planId ? [{ kind: "test", steps: [step], expires_at: new Date(Date.now() + 600_000) }] : [];
    }
    if (q.startsWith("update lite.plans set steps")) return [];
    if (q.startsWith("insert into lite.tx_log")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  return seen;
}

/** A built step of `tx` (unsigned, as the API stores it). */
function builtStep(tx: Transaction, intent: unknown, extra: Record<string, unknown>) {
  return { id: "s1", label: "Test", spec: { kind: "test" }, status: "built", intent, xdr: tx.toEnvelope().toXDR("base64"), hash: tx.hash().toString("hex"), maxFee: tx.fee, ...extra };
}

/** RPC's sendTransaction answer: PENDING, or ERROR with a result code. */
function sendAnswer(hash: string, error?: "txBadSeq") {
  if (!error) return { status: "PENDING", hash, latestLedger: 5_200_000, latestLedgerCloseTime: "0" };
  const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("0"), result: xdr.TransactionResultResult.txBadSeq(), ext: new xdr.TransactionResultExt(0) });
  return { status: "ERROR", hash, errorResultXdr: result.toXDR("base64"), latestLedger: 5_200_000, latestLedgerCloseTime: "0" };
}

Deno.test("a fee above maxFee is 422 fee_too_high when the step is built, before anything is stored", async () => {
  rpc = (method) => {
    if (method === "getFeeStats") return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: 1 };
    throw new Error(`unexpected RPC ${method}`);
  };
  replaceSql(fakeSql((q) => {
    throw new Error(`unexpected query: ${q}`);
  }));
  const e = await assertRejects(() => createPlan(USER.publicKey(), "test", [{ label: "Costly", spec: { kind: "test_costly" } }]), ApiError);
  assertEquals([e.status, e.code, e.detail], [422, "fee_too_high", { fee: "40000100", max: "30000000" }]);
});

Deno.test("a signed step whose fee is above maxFee is 422 fee_too_high, and nothing is sent", async () => {
  const user = USER.publicKey();
  const tx = costlyTransfer(user, 40_000_000n);
  const planId = crypto.randomUUID();
  planDb(planId, builtStep(tx, COSTLY_INTENT, { stepKind: "payment_token", feePayer: "user", sponsorReason: null }));
  rpc = (method) => {
    throw new Error(`nothing may reach RPC (${method})`);
  };
  tx.sign(USER);
  const e = await assertRejects(() => submitStep(user, planId, "s1", tx.toEnvelope().toXDR("base64"), "198.51.100.1"), ApiError);
  assertEquals([e.status, e.code, e.detail], [422, "fee_too_high", { fee: "40000100", max: "30000000" }]);
});

Deno.test("a user-paid step is sent exactly as signed and logged as the user's, with its kind and section", async () => {
  const user = USER.publicKey();
  const tx = new TransactionBuilder(new Account(user, "22096910953218048"), { fee: "100", networkPassphrase: PASS })
    .addOperation(Operation.payment({ destination: OTHER.publicKey(), asset: Asset.native(), amount: "1" }))
    .setTimeout(600)
    .build();
  const intent = { kind: "payment", summary: "Send 1 XLM", spend: { [XLM_SAC]: ONE.toString() }, ops: ["payment"], to: OTHER.publicKey() };
  const planId = crypto.randomUUID();
  const seen = planDb(planId, builtStep(tx, intent, { stepKind: "payment", feePayer: "user", sponsorReason: null }));
  tx.sign(USER);
  const signed = tx.toEnvelope().toXDR("base64");
  const sent: string[] = [];
  rpc = (method, params) => {
    if (method !== "sendTransaction") throw new Error(`unexpected RPC ${method}`);
    sent.push(params.transaction);
    return sendAnswer(tx.hash().toString("hex"));
  };
  const answer = await submitStep(user, planId, "s1", signed, "198.51.100.1");
  assertEquals(answer, { hash: tx.hash().toString("hex"), status: "pending" });
  assertEquals(sent, [signed]);
  const log = seen.find((s) => s.q.startsWith("insert into lite.tx_log"))!;
  assertEquals(log.ps.slice(0, 6), [tx.hash().toString("hex"), tx.hash().toString("hex"), user, planId, "s1", "payment"]);
  assertEquals(log.ps.slice(7), ["100", "user", "payment", "spot"]);
  const saved = seen.filter((s) => s.q.startsWith("update lite.plans set steps")).at(-1)!.ps[0] as { status: string; txHash: string }[];
  assertEquals([saved[0].status, saved[0].txHash], ["submitted", tx.hash().toString("hex")]);
});

/** DyorHQ's setup of `user`: the sponsor's transaction, as the activate builder makes it. */
function setupTx(user: string): Transaction {
  const sp = SPONSOR.publicKey();
  return new TransactionBuilder(new Account(sp, "1000"), { fee: "100", networkPassphrase: PASS })
    .addOperation(Operation.beginSponsoringFutureReserves({ sponsoredId: user, source: sp }))
    .addOperation(Operation.createAccount({ destination: user, startingBalance: "0", source: sp }))
    .addOperation(Operation.changeTrust({ asset: new Asset("USDC", USDC.classic!.split(":")[1]), source: user }))
    .addOperation(Operation.endSponsoringFutureReserves({ source: user }))
    .setTimeout(600)
    .build();
}

const SETUP_INTENT = {
  kind: "activate",
  summary: "Create your Stellar account",
  spend: {},
  ops: ["beginSponsoringFutureReserves", "createAccount", "changeTrust", "endSponsoringFutureReserves"],
  trust: [USDC.classic!],
};

Deno.test("an account's setup reserves its sponsorship first, and releases it when nothing reached the network", async () => {
  const user = Keypair.random();
  const tx = setupTx(user.publicKey());
  const planId = crypto.randomUUID();
  const seen = planDb(planId, builtStep(tx, SETUP_INTENT, { stepKind: "activate", feePayer: "sponsor", sponsorReason: "setup" }), (q) => {
    if (q.startsWith("select id, refusal from lite.reserve_sponsorship(")) return [{ id: "8e1f6d2a-0000-4000-8000-000000000001", refusal: null }];
    if (q.startsWith("update lite.sponsorships set status = 'released'")) return [];
    return null;
  });
  rpc = (method) => {
    if (method !== "sendTransaction") throw new Error(`unexpected RPC ${method}`);
    return sendAnswer(tx.hash().toString("hex"), "txBadSeq");
  };
  tx.sign(user);
  const e = await assertRejects(() => submitStep(user.publicKey(), planId, "s1", tx.toEnvelope().toXDR("base64"), "198.51.100.2"), ApiError);
  assertEquals([e.status, e.code], [422, "tx_rejected"]);
  const reserve = seen.find((s) => s.q.startsWith("select id, refusal from lite.reserve_sponsorship("))!;
  assertEquals(reserve.ps.slice(0, 2), [user.publicKey(), "activate"]);
  assert(/^[0-9a-f]{64}$/.test(String(reserve.ps[2])) && reserve.ps[2] !== "198.51.100.2", "the IP is stored only as its HMAC");
  assertEquals(reserve.ps[3], "400");
  assertEquals(seen.find((s) => s.q.startsWith("update lite.sponsorships set status = 'released'"))?.ps, ["8e1f6d2a-0000-4000-8000-000000000001"]);
  assertEquals(seen.some((s) => s.q.startsWith("insert into lite.tx_log")), false);
  const saved = seen.filter((s) => s.q.startsWith("update lite.plans set steps")).at(-1)!.ps[0] as { status: string }[];
  assertEquals(saved[0].status, "failed");
});

Deno.test("a sponsorship DyorHQ can't give is refused before anything is sent: 429 sponsor_limit", async () => {
  const user = Keypair.random();
  const tx = setupTx(user.publicKey());
  const planId = crypto.randomUUID();
  const seen = planDb(planId, builtStep(tx, SETUP_INTENT, { stepKind: "activate", feePayer: "sponsor", sponsorReason: "setup" }), (q) => {
    if (q.startsWith("select id, refusal from lite.reserve_sponsorship(")) return [{ id: null, refusal: "ip" }];
    return null;
  });
  rpc = (method) => {
    throw new Error(`nothing may reach RPC (${method})`);
  };
  tx.sign(user);
  const e = await assertRejects(() => submitStep(user.publicKey(), planId, "s1", tx.toEnvelope().toXDR("base64"), "198.51.100.3"), ApiError);
  assertEquals([e.status, e.code, e.detail], [429, "sponsor_limit", { limit: "ip" }]);
  assertEquals(seen.some((s) => s.q.startsWith("update lite.sponsorships")), false);
});

Deno.test("the IP a sponsorship counts against: Cloudflare's, else the right-most X-Forwarded-For entry, never one the caller wrote", () => {
  const ip = (headers: Record<string, string>) => clientIp(new Request("http://127.0.0.1/lite/v1/tx/submit", { method: "POST", headers }));
  assertEquals(ip({ "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "198.51.100.9, 203.0.113.7" }), "203.0.113.7");
  // A caller's own X-Forwarded-For entries come first; the proxy in front appends the address it saw.
  assertEquals(ip({ "x-forwarded-for": "198.51.100.9, 203.0.113.7" }), "203.0.113.7");
  assertEquals(ip({ "x-forwarded-for": "198.51.100.9,203.0.113.7 , " }), "203.0.113.7");
  assertEquals(ip({ "x-forwarded-for": "203.0.113.7" }), "203.0.113.7");
  assertEquals([ip({ "cf-connecting-ip": " " }), ip({})], ["unknown", "unknown"]);
});

Deno.test("a setup RPC didn't confirm may land all the same: it counts as sent, and keeps its sponsorship until it settles", async () => {
  const user = Keypair.random();
  const tx = setupTx(user.publicKey());
  const planId = crypto.randomUUID();
  const id = "8e1f6d2a-0000-4000-8000-000000000004";
  const seen = planDb(planId, builtStep(tx, SETUP_INTENT, { stepKind: "activate", feePayer: "sponsor", sponsorReason: "setup" }), (q) => {
    if (q.startsWith("select id, refusal from lite.reserve_sponsorship(")) return [{ id, refusal: null }];
    if (q.startsWith("update lite.sponsorships set status = 'sent'")) return [];
    return null;
  });
  rpc = (method) => {
    if (method !== "sendTransaction") throw new Error(`unexpected RPC ${method}`);
    throw new Error("upstream request timeout");
  };
  tx.sign(user);
  const hash = tx.hash().toString("hex");
  assertEquals(await submitStep(user.publicKey(), planId, "s1", tx.toEnvelope().toXDR("base64"), "198.51.100.4"), { hash, status: "pending" });
  // Never released: settling the transaction settles its sponsorship, success or failed (outcome.test.ts).
  assertEquals(seen.some((s) => s.q.startsWith("update lite.sponsorships set status = 'released'")), false);
  assertEquals(seen.find((s) => s.q.startsWith("update lite.sponsorships set status = 'sent'"))?.ps, [hash, id]);
  const log = seen.find((s) => s.q.startsWith("insert into lite.tx_log"))!;
  assertEquals([log.ps[0], ...log.ps.slice(7)], [hash, "400", "sponsor", "activate", "account"]);
  const saved = seen.filter((s) => s.q.startsWith("update lite.plans set steps")).at(-1)!.ps[0] as { status: string; txHash: string }[];
  assertEquals([saved[0].status, saved[0].txHash], ["submitted", hash]);
});

// ------------------------------------------------------------------------------------------------ the starter swap

/** A starter swap of 3 USDC into XLM through Soroswap (at least 2 XLM out), with its SDEX route to fall back on, whose
 *  minimum out is `sdexMinOut`. */
function starterSpec(sdexMinOut: bigint) {
  const swap = { sell: "USDC", buy: "XLM", amountIn: (3n * ONE).toString(), chainXdr: null };
  return {
    kind: "swap_soroswap",
    ...swap,
    minOut: (2n * ONE).toString(),
    path: [USDC.contract, XLM_SAC],
    starter: true,
    fallback: { label: "Swap via SDEX", spec: { kind: "swap_sdex", ...swap, minOut: sdexMinOut.toString(), path: [USDC.classic!, "native"] } },
  };
}

/** Activation sponsored; `user` set up by DyorHQ with 3 USDC and no XLM to spend; Soroswap's route simulating at a
 *  resource fee whose fee-bump (1,085,200 stroops) is above starterInnerFeeMax; no starter used yet. */
function starterNetwork(user: string) {
  Deno.env.set("LITE_ACTIVATION", "sponsored");
  const usdcLine = { balance: "3.0000000", limit: "922337203685.4775807", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC.classic!.split(":")[1], sponsor: SPONSOR.publicKey() };
  horizonAccounts.set(user, horizonAccount(user, { xlm: "0.0000000", subentries: 1, sponsored: 3, lines: [usdcLine] }));
  rpc = (method) => {
    if (method === "getFeeStats") return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: 1 };
    if (method === "getLedgerEntries") return accountEntry(user, 22096910953218048n);
    if (method === "simulateTransaction") {
      const data = new SorobanDataBuilder().setResources(2_000_000, 3_000, 1_000).build().toXDR("base64");
      return { latestLedger: 1, minResourceFee: "900000", transactionData: data, results: [{ auth: [], xdr: xdr.ScVal.scvVoid().toXDR("base64") }], events: [] };
    }
    throw new Error(`unexpected RPC ${method}`);
  };
  replaceSql(fakeSql((q) => {
    if (q.startsWith("select 1 from lite.sponsorships where address = ? and kind = 'starter'")) return [];
    if (q.startsWith("insert into lite.plans")) return [{ id: "3c0e2b9a-0000-4000-8000-000000000006", expires_at: new Date(Date.now() + 1_800_000) }];
    throw new Error(`unexpected query: ${q}`);
  }));
}

Deno.test("a starter swap its own route makes too costly for DyorHQ takes its SDEX route, named for it, when that route qualifies", async () => {
  const user = Keypair.random().publicKey();
  starterNetwork(user);
  try {
    const plan = await createPlan(user, "swap", [{ label: "Swap via Soroswap", spec: starterSpec(15_000_000n) }]);
    const [step] = plan.steps;
    assertEquals([step.label, step.stepKind, step.feePayer, step.sponsorReason], ["Swap via SDEX", "swap_sdex", "sponsor", "starter_swap"]);
    assertEquals([plan.fees!.userMax, plan.fees!.sponsored], ["0", true]);
    const op = (TransactionBuilder.fromXDR(step.xdr!, PASS) as Transaction).operations[0] as Operation.PathPaymentStrictSend;
    assertEquals([op.type, op.destMin], ["pathPaymentStrictSend", "1.5000000"]);
  } finally {
    Deno.env.delete("LITE_ACTIVATION");
  }
});

Deno.test("an SDEX route out under starterMinXlmOut isn't a starter swap: the step stays the user's, refused for its fee", async () => {
  const user = Keypair.random().publicKey();
  starterNetwork(user);
  try {
    // 0.5 XLM is under the starter's 1 XLM: nothing marked as DyorHQ's for the user to sign, and the Soroswap route the
    // user would pay for (1,085,100 stroops) is more than the account can spend.
    const e = await assertRejects(() => createPlan(user, "swap", [{ label: "Swap via Soroswap", spec: starterSpec(5_000_000n) }]), ApiError);
    assertEquals([e.status, e.code, e.detail], [409, "not_enough_xlm_for_fee", { need: "1085100", spendable: "0" }]);
  } finally {
    Deno.env.delete("LITE_ACTIVATION");
  }
});

// ------------------------------------------------------------------------------------------------ restores

const { NeedsRestore } = await import("../../supabase/functions/_shared/stellar.ts");

/** A restore preamble for `contracts`' instances: what a simulation answers when they are archived. */
function preamble(contracts: string[]) {
  const keys = contracts.map((c) =>
    xdr.LedgerKey.contractData(new xdr.LedgerKeyContractData({ contract: new Address(c).toScAddress(), key: xdr.ScVal.scvLedgerKeyContractInstance(), durability: xdr.ContractDataDurability.persistent() }))
  );
  return { minResourceFee: "5000", transactionData: new SorobanDataBuilder().setReadWrite(keys).setResources(0, 2_000, 2_000).build().toXDR("base64") };
}

/** A contract outside the allowlist. */
const STRANGER = "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526";
let archived: string[] = [];
registerBuilder("test_archived", () => Promise.reject(new NeedsRestore(preamble(archived))));

Deno.test("a simulation that finds archived data puts a user-paid restore step before the step, which waits to be built", async () => {
  const user = USER.publicKey();
  horizonAccounts.set(user, horizonAccount(user, { xlm: "10000.0000000" }));
  rpc = (method) => {
    if (method === "getFeeStats") return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: 1 };
    if (method === "getLedgerEntries") return accountEntry(user, 22096910953218048n);
    throw new Error(`unexpected RPC ${method}`);
  };
  replaceSql(fakeSql((q) => {
    if (q.startsWith("insert into lite.plans")) return [{ id: "3c0e2b9a-0000-4000-8000-000000000004", expires_at: new Date(Date.now() + 1_800_000) }];
    throw new Error(`unexpected query: ${q}`);
  }));
  archived = [ROUTER];
  const plan = await createPlan(user, "test", [{ label: "Swap", spec: { kind: "test_archived" } }]);
  const [restore, waiting] = plan.steps;
  assertEquals([restore.id, restore.label, restore.status, restore.stepKind, restore.feePayer, restore.reserveDelta], ["s1r", "Restore archived data for Swap", "built", "restore", "user", 0]);
  assertEquals([restore.intent?.kind, restore.intent?.ops, restore.intent?.display], ["restore", ["restoreFootprint"], { for: "Swap" }]);
  const tx = TransactionBuilder.fromXDR(restore.xdr!, PASS) as Transaction;
  assertEquals([tx.source, tx.operations[0].type, tx.fee], [user, "restoreFootprint", (100n + withResourceMargin(5_000n)).toString()]);
  assertEquals([waiting.id, waiting.status, waiting.xdr], ["s1", "pending", undefined]);
  assertEquals(plan.fees!.userMax, (BigInt(restore.maxFee!) + BigInt(waiting.maxFee!)).toString());

  // Data that isn't the app's own is never restored by a user's step: the step's 409 needs_restore stands.
  archived = [STRANGER];
  const e = await assertRejects(() => createPlan(user, "test", [{ label: "Swap", spec: { kind: "test_archived" } }]), ApiError);
  assertEquals([e.status, e.code], [409, "needs_restore"]);
});

// ------------------------------------------------------------------------------------------------ protocol upkeep

const ttl = await import("../../supabase/functions/_shared/ttl.ts");
const { env } = await import("../../supabase/functions/_shared/env.ts");

Deno.test("the rent rotation: each entry once, never-checked first, then the oldest check, at most perRun", () => {
  const e = (id: string) => ({ id });
  const last = new Map([["a", 300], ["b", 100], ["d", 100]]);
  assertEquals(ttl.rotation([e("a"), e("b"), e("c"), e("a"), e("d")], last, 3).map((x) => x.id), ["c", "b", "d"]);
  assertEquals(ttl.rotation([e("a"), e("b")], new Map(), 400).map((x) => x.id), ["a", "b"]);
  const policy = { thresholdDays: 10 };
  assertEquals([ttl.needsExtending(1_000 + 10 * 17_280 - 1, 1_000, policy), ttl.needsExtending(1_000 + 10 * 17_280, 1_000, policy)], [true, false]);
});

/** A contract-data key as [contract, durability, the DataKey variant's name and values]. */
function described(k: xdr.LedgerKey) {
  const d = k.contractData();
  return [Address.fromScAddress(d.contract()).toString(), d.durability().name, (d.key().vec() ?? []).map((v) => v.switch().name === "scvSymbol" ? v.sym().toString() : v.switch().name === "scvU32" ? v.u32() : Address.fromScVal(v).toString())];
}

Deno.test("the keys the keeper keeps alive: a launch's Launch and Curve entries, a Moment's, a quote's settings and protocol fees, persistent, in their contracts", () => {
  const pad = TESTNET.contracts.launchpad!;
  const moments = TESTNET.contracts.moments!;
  const token = "CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V";
  assertEquals(ttl.launchKeys(pad, token).map(described), [[pad, "persistent", ["Launch", token]], [pad, "persistent", ["Curve", token]]]);
  assertEquals(described(ttl.momentKey(moments, 3)), [moments, "persistent", ["Moment", 3]]);
  assertEquals(described(ttl.quoteKey(pad, XLM_SAC)), [pad, "persistent", ["Quote", XLM_SAC]]);
  assertEquals(described(ttl.quoteKey(moments, USDC.contract)), [moments, "persistent", ["Quote", USDC.contract]]);
  assertEquals(described(ttl.protocolFeesKey(pad, USDC.contract)), [pad, "persistent", ["ProtocolFees", USDC.contract]]);
});

Deno.test("what the keeper keeps alive: the deployment's instances and code, each quote's settings and protocol fees, live launches and collecting Moments", async () => {
  const pad = TESTNET.contracts.launchpad!;
  const moments = TESTNET.contracts.moments!;
  const [quiet, graduated, pool] = ["CBGQQP6JNUGWZAJVCWUAEEKIY7IR3PUBSKCYIZLE3DHVLLKRPYI33X2V", "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", ROUTER];
  replaceSql(fakeSql((q, ps) => {
    if (q.startsWith("select l.token, l.pair from lite.launches l")) {
      assertEquals(ps, [90]);
      return [{ token: quiet, pair: null }, { token: graduated, pair: pool }];
    }
    if (q.startsWith("select id from lite.moments where deadline > now()")) return [{ id: 3 }];
    // Contracts v2's rows (migration 20261015000012) aren't here: v2's own entries are its paths and quotes.
    if (q === "select to_regclass(?) is not null as present") return [{ present: false }];
    throw new Error(`unexpected query: ${q}`);
  }));
  // Soroswap's code isn't read here: v2's paths go without it.
  rpc = (method) => {
    throw new Error(`unexpected RPC ${method}`);
  };
  const entries = await ttl.upkeepEntries();
  // After v1's, testnet's v2 deployment adds its own (ttl.ts v2UpkeepEntries, tested in indexer_v2.test.ts).
  const v2 = await ttl.v2UpkeepEntries(env.network);
  assert(v2.length > 0, "testnet has a v2 deployment");
  assertEquals(entries.slice(entries.length - v2.length).map((e) => e.label), v2.map((e) => e.label));
  assertEquals(entries.slice(0, entries.length - v2.length).map((e) => e.label), [
    "instance launchpad",
    "instance moments",
    "code launchpad",
    "code moments",
    "code launch token",
    "quote launchpad XLM",
    "protocol fees XLM",
    "quote moments XLM",
    "quote launchpad USDC",
    "protocol fees USDC",
    "quote moments USDC",
    `instance ${quiet}`,
    `launch ${quiet}`,
    `curve ${quiet}`,
    `instance ${graduated}`,
    `launch ${graduated}`,
    `curve ${graduated}`,
    `instance pool ${pool}`,
    "moment 3",
  ]);
  const key = (label: string) => entries.find((e) => e.label === label)!.key.toXDR("base64");
  assertEquals(key("quote launchpad XLM"), ttl.quoteKey(pad, XLM_SAC).toXDR("base64"));
  assertEquals(key("protocol fees USDC"), ttl.protocolFeesKey(pad, USDC.contract).toXDR("base64"));
  assertEquals(key("quote moments USDC"), ttl.quoteKey(moments, USDC.contract).toXDR("base64"));
});

Deno.test("an upkeep run: checks the oldest first, extends the low entries from the keeper's account with prepare()'s headroom, logs it, records each check", async () => {
  const latest = 1_000_000;
  const low = ttl.instanceKey(ROUTER);
  const fine = ttl.instanceKey(TESTNET.contracts.launchpad!);
  const gone = ttl.instanceKey(TESTNET.contracts.moments!);
  // Past its TTL, so archived, though RPC still returns it: no extension can reach it.
  const lapsed = ttl.quoteKey(TESTNET.contracts.launchpad!, XLM_SAC);
  const keeperAddress = SPONSOR.publicKey();
  const sent: Transaction[] = [];
  rpc = (method, params) => {
    switch (method) {
      case "getFeeStats":
        return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: latest };
      case "getLedgerEntries": {
        const keys = (params.keys as string[]).map((k) => xdr.LedgerKey.fromXDR(k, "base64"));
        if (keys[0].switch().name === "account") return accountEntry(keeperAddress, 77n);
        const live = new Map([[low.toXDR("base64"), latest + 17_280], [fine.toXDR("base64"), latest + 20 * 17_280], [lapsed.toXDR("base64"), latest - 1]]);
        const entries = keys.filter((k) => live.has(k.toXDR("base64"))).map((k) => ({
          key: k.toXDR("base64"),
          xdr: xdr.LedgerEntryData.contractData(new xdr.ContractDataEntry({ ext: new xdr.ExtensionPoint(0), contract: k.contractData().contract(), key: k.contractData().key(), durability: k.contractData().durability(), val: xdr.ScVal.scvVoid() })).toXDR("base64"),
          lastModifiedLedgerSeq: 1,
          liveUntilLedgerSeq: live.get(k.toXDR("base64")),
        }));
        return { entries, latestLedger: latest };
      }
      case "simulateTransaction": {
        const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
        const fp = (tx.toEnvelope().v1().tx().ext().sorobanData() as xdr.SorobanTransactionData).resources().footprint();
        return { latestLedger: latest, minResourceFee: "20000", transactionData: new SorobanDataBuilder().setReadOnly(fp.readOnly()).setResources(0, 500, 0).build().toXDR("base64"), results: [{ auth: [], xdr: xdr.ScVal.scvVoid().toXDR("base64") }], events: [] };
      }
      case "sendTransaction": {
        const tx = TransactionBuilder.fromXDR(params.transaction, PASS) as Transaction;
        sent.push(tx);
        return { status: "PENDING", hash: tx.hash().toString("hex"), latestLedger: latest, latestLedgerCloseTime: "0" };
      }
      case "getTransaction": {
        const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("70150"), result: xdr.TransactionResultResult.txSuccess([]), ext: new xdr.TransactionResultExt(0) });
        const meta = new xdr.TransactionMeta(3, new xdr.TransactionMetaV3({ ext: new xdr.ExtensionPoint(0), txChangesBefore: [], operations: [], txChangesAfter: [], sorobanMeta: null }));
        return { status: "SUCCESS", latestLedger: latest, latestLedgerCloseTime: "0", oldestLedger: 1, oldestLedgerCloseTime: "0", ledger: latest + 1, createdAt: "0", applicationOrder: 1, feeBump: false, envelopeXdr: sent[0].toEnvelope().toXDR("base64"), resultXdr: result.toXDR("base64"), resultMetaXdr: meta.toXDR("base64") };
      }
    }
    throw new Error(`unexpected RPC ${method}`);
  };
  const seen: { q: string; ps: unknown[] }[] = [];
  replaceSql(fakeSql((q, ps) => {
    seen.push({ q, ps });
    if (q.startsWith("select key, checked_at from lite.ttl_checks")) return [{ key: fine.toXDR("base64"), checked_at: new Date("2026-10-01T00:00:00Z") }];
    if (q === "select to_regclass(?) is not null as present") return [{ present: true }];
    if (q.startsWith("insert into lite.keeper_log") || q.startsWith("insert into lite.ttl_checks") || q.startsWith("delete from lite.ttl_checks")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  const entries = [{ key: fine, label: "instance launchpad" }, { key: low, label: "instance router" }, { key: gone, label: "instance moments" }, { key: lapsed, label: "quote launchpad XLM" }];
  const report = await ttl.upkeep(entries, { thresholdDays: 10, extendToDays: 30, perRun: 400, idleDays: 90 }, Date.now() + 10_000);
  assertEquals([report.entries, report.checked, report.low, report.extended, report.missing, report.fee, report.hashes.length], [4, 4, 1, 1, 2, "70150", 1]);
  // One extension, from the keeper's account, of the low entry only.
  assertEquals(sent.length, 1);
  const op = sent[0].operations[0] as any;
  const fp = (sent[0].toEnvelope().v1().tx().ext().sorobanData() as xdr.SorobanTransactionData).resources().footprint();
  assertEquals([sent[0].source, op.type, op.extendTo, fp.readOnly().map((k) => k.toXDR("base64"))], [keeperAddress, "extendFootprintTtl", 30 * 17_280, [low.toXDR("base64")]]);
  // What it declares: the simulation's 0 instructions, 500 bytes read and 0 written with prepare()'s headroom, its
  // minimum resource fee of 20,000 × 1.15 + 50,000, and the inclusion bid of 100.
  assertEquals([resourcesOf(sent[0]), sent[0].fee], [{ instructions: 100_000, readBytes: 1_600, writeBytes: 1_000, resourceFee: 73_000n }, "73100"]);
  const logged = seen.find((s) => s.q.startsWith("insert into lite.keeper_log"))!;
  assertEquals(logged.ps.slice(0, 3), [sent[0].hash().toString("hex"), "ttl", keeperAddress]);
  // Every entry checked is recorded (in the order checked: never-checked first), the extended one at its new TTL; the
  // checks of entries no longer kept go.
  const [f, l, g, x] = [fine, low, gone, lapsed].map((k) => k.toXDR("base64"));
  const recorded = seen.find((s) => s.q.startsWith("insert into lite.ttl_checks"))!;
  assertEquals(recorded.ps, [
    [l, g, x, f],
    ["instance router", "instance moments", "quote launchpad XLM", "instance launchpad"],
    [latest + 30 * 17_280, null, latest - 1, latest + 20 * 17_280],
  ]);
  assertEquals(seen.find((s) => s.q.startsWith("delete from lite.ttl_checks"))!.ps, [[f, l, g, x]]);
});
