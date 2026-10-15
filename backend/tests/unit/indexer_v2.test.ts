// Contracts v2 in the indexer and the keeper (docs/DESIGN-stellar-contracts-v2.md §13, §20.5, §20.6; CT-15):
// - decoders: every v2 event the indexer reads, from synthetic event XDR encoded as #[contractevent] publishes it
//   (topics, then the data map, or the single value), decoded the way RPC's answer is: reward events in both assets (the
//   quote and the launch token itself), grad_fail with its namespaced origin and code named from v2_errors.ts (V10) and
//   fallback_at, expired with its backstop flag (V11), the locker's harvested with take and compounded, and the pool
//   discovery of the Soroswap factory and the Aquarius router;
// - generations: a v2 deployment, or another one, never clears v1's rows; a different v1 deployment clears v1's only;
// - the keeper: graduate_fallback only from fallback_at and only when the simulated graduate fails (F14); one
//   recoverable failure recorded, then only successes; no Moments mark_stuck (F15); exclude_pool only when its
//   simulation passes (F2); exclude_treasury on every graduated sharing launch after a treasury change (V2); keeper_skip
//   honoured on testnet-qa by every job, rescue and expire included, and ignored with a warning elsewhere (V5); a call
//   that needs anyone's authorization is never sent;
// - alerts with synthetic state: the AQUA float, a launch stuck past fallback_delay, a Moment pending an hour and a day
//   before its backstop, a graduation out of budget; a grad_fail of exec-soroswap's LiquidityTooLow (3, 10304) doesn't
//   fire PaymentUnavailable's;
// - TTL upkeep: the graduation and harvest paths (every v2 singleton and WASM, Soroswap's factory and pair code) checked
//   every run, archived ones restored in a transaction of their own before anything graduates; v2's quotes, per-launch
//   and per-Moment entries, unvested positions and owed fees in the rotation;
// - the indexer's jobs: v2 runs inside them, each part whatever the others do.
import { Account, Address, Keypair, nativeToScVal, Operation, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertFalse } from "jsr:@std/assert@1";
import type { PathReport } from "../../supabase/functions/_shared/ttl.ts";
import type { Chain, KeeperJobV2, KeeperV2Report, LaunchStatus, MomentStatus, Sim } from "../../supabase/functions/lite-indexer/v2_keeper.ts";
import { fakeSql, type Row, setTestEnv, SPONSOR } from "../fixtures/routes/harness.ts";

setTestEnv();
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET, withDeploymentV2 } = await import("../../supabase/functions/_shared/networks.ts");
const { DURATION_SETS_V2, parseDeploymentV2 } = await import("../../supabase/functions/_shared/deployments/index.ts");
const { native, rpcServer } = await import("../../supabase/functions/_shared/stellar.ts");
const ev = await import("../../supabase/functions/lite-indexer/v2_events.ts");
const k = await import("../../supabase/functions/lite-indexer/v2_keeper.ts");
const ttl = await import("../../supabase/functions/_shared/ttl.ts");
const { decodeMove } = await import("../../supabase/functions/lite-indexer/handlers/moments.ts");
const { deploymentKey } = await import("../../supabase/functions/lite-indexer/jobs/main_events.ts");

const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const G = (n: number) => StrKey.encodeEd25519PublicKey(new Uint8Array(32).fill(n) as any);
const H = (n: number) => n.toString(16).padStart(2, "0").repeat(32);

const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!.contract;
const TOKEN = C(40);
const NFT = C(41);
const POOL = C(42);
const COIN = C(43);
const HOLDER = G(20);
const CREATOR = G(21);

// ------------------------------------------------------------------------------------------------ deployments

/** A v2 deployment file as deploy-contracts-v2.ts writes it (deploymentRecord). */
function deploymentFile(deployment: "testnet" | "testnet-qa", aquarius = false): Record<string, unknown> {
  const qa = deployment === "testnet-qa";
  const set = DURATION_SETS_V2[qa ? "testnet-qa" : "production"];
  return {
    network: "testnet",
    deployment,
    name: qa ? "testnet-qa-v2" : "testnet-v2",
    generation: 1,
    deployer: G(1),
    contracts: {
      execSoroswap: C(1),
      ...(aquarius ? { execAquarius: C(10) } : {}),
      ...(qa ? { qaExecFail: C(6) } : {}),
      lpLocker: C(2),
      momentsGraduator: C(3),
      launchpadV2: C(4),
      momentsV2: C(5),
      ...(qa ? { momentsGraduatorQaFail: C(7), momentsV2QaFail: C(8) } : {}),
    },
    wasmHashes: {
      launchpadV2: H(1),
      launchTokenV2: H(2),
      execSoroswap: H(3),
      ...(aquarius ? { execAquarius: H(10) } : {}),
      ...(qa ? { qaExecFail: H(9) } : {}),
      lpLocker: H(4),
      momentsV2: H(5),
      momentNft: H(6),
      momentCoin: H(7),
      momentsGraduator: H(8),
    },
    venues: [
      { id: 0, kind: "Soroswap", executor: C(1), feeFraction: 0, enabled: true },
      ...(aquarius ? [{ id: 1, kind: "Aquarius", executor: C(10), feeFraction: 30, enabled: true }] : []),
      ...(qa ? [{ id: 2, kind: "QaFail", executor: C(6), feeFraction: 0, enabled: true }] : []),
    ],
    quotes: { XLM: { enabled: true }, USDC: { enabled: true }, ...(qa ? { QA: { enabled: true } } : {}) },
    aquarius: { enabled: aquarius, reason: aquarius ? null : "--aquarius off" },
    ...(qa ? { qaAsset: { code: "DYORQA", issuer: G(7), sac: C(9) } } : {}),
    durations: { set: qa ? "testnet-qa" : "production", launch: set.launch, moments: set.moments },
    ttl: { threshold: 120_960, extend_to: 518_400 },
    deployLedger: 5_300_000,
    deployedAt: "2026-10-15T18:00:00.000Z",
  };
}

const NET = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-v2", deploymentFile("testnet")));
const QA_NET = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-qa-v2", deploymentFile("testnet-qa")));
const AQUA_NET = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-v2", deploymentFile("testnet", true)));
const PAD = C(4);
const MOMENTS = C(5);
const LOCKER = C(2);

// ------------------------------------------------------------------------------------------------ event XDR

const sym = (s: string) => xdr.ScVal.scvSymbol(s);
const str = (s: string) => xdr.ScVal.scvString(s);
const addr = (id: string) => new Address(id).toScVal();
const i128 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const u64 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "u64" });
const bool = (b: boolean) => xdr.ScVal.scvBool(b);
const vec = (...items: xdr.ScVal[]) => xdr.ScVal.scvVec(items);
/** A #[contracttype] struct, or a #[contractevent]'s data map: its fields by name, sorted as the host keeps them. */
const map = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((key) => new xdr.ScMapEntry({ key: sym(key), val: fields[key] })));

/** An event as #[contractevent] publishes it and getEvents returns it: base64 XDR topics and value. */
function eventXdr(topics: xdr.ScVal[], data: xdr.ScVal): { topic: string[]; value: string } {
  return { topic: topics.map((t) => t.toXDR("base64")), value: data.toXDR("base64") };
}

/** The XDR decoded as the indexer decodes RPC's answer. */
function decoded(topics: xdr.ScVal[], data: xdr.ScVal) {
  const e = eventXdr(topics, data);
  return { topics: e.topic.map((t) => native(xdr.ScVal.fromXDR(t, "base64"))), data: native(xdr.ScVal.fromXDR(e.value, "base64")) };
}

const T0 = 1_760_520_000; // 2025-10-15T09:20:00Z, in seconds

// ------------------------------------------------------------------------------------------------ launchpad-v2 decoders

Deno.test("decoders: launch, fee_booked and trade, with the launch's venue, sharing, recipient and fee split", () => {
  const launch = ev.decodeLaunchV2(decoded([sym("launch"), addr(TOKEN), addr(CREATOR)], map({
    quote: addr(XLM),
    name: str("Accra Cat"),
    symbol: str("ACAT"),
    uri: str("https://example.supabase.co/storage/v1/object/public/lite-media/launches/x.json"),
    nonce: u64(18_446_744_073_709_551_615n),
    supply: i128(10_000_000_000_000_000n),
    phantom: i128(20_000_000_000n),
    threshold: i128(43_245_553_200n),
    fee_bps: u32(100),
    protocol_share_bps: u32(5_000),
    creator_fee_bps: u32(200),
    venue: u32(0),
    fallback_venue: u32(0),
    venue_locked: bool(false),
    holder_sharing: bool(true),
    recipient: addr(G(22)),
    launch_fee: i128(100_000_000n),
  })));
  assertEquals(launch, {
    token: TOKEN,
    creator: CREATOR,
    quote: XLM,
    name: "Accra Cat",
    symbol: "ACAT",
    uri: "https://example.supabase.co/storage/v1/object/public/lite-media/launches/x.json",
    nonce: 18_446_744_073_709_551_615n,
    supply: 10_000_000_000_000_000n,
    phantom: 20_000_000_000n,
    threshold: 43_245_553_200n,
    feeBps: 100,
    protocolShareBps: 5_000,
    creatorFeeBps: 200,
    venue: 0,
    fallbackVenue: 0,
    venueLocked: false,
    holderSharing: true,
    recipient: G(22),
    launchFee: 100_000_000n,
  });
  assertEquals(ev.decodeFeeBooked(decoded([sym("fee_booked"), addr(TOKEN), addr(CREATOR)], map({ asset: addr(XLM), amount: i128(100_000_000n) }))), {
    token: TOKEN,
    payer: CREATOR,
    asset: XLM,
    amount: 100_000_000n,
  });
  const trade = ev.decodeTradeV2(decoded([sym("trade"), addr(TOKEN), addr(HOLDER)], map({
    is_buy: bool(true),
    quote_amount: i128(1_000_000_000n),
    token_amount: i128(4_000_000_000_000n),
    base_fee: i128(10_000_000n),
    snipe_fee: i128(3_000_000n),
    creator_fee: i128(20_000_000n),
    protocol_part: i128(6_500_000n),
    creator_part: i128(0n),
    holder_part: i128(26_500_000n),
    quote_reserve: i128(20_967_000_000n),
    token_reserve: i128(9_996_000_000_000_000n),
    real_quote: i128(967_000_000n),
  })));
  assertEquals([trade.side, trade.fees, trade.protocolPart, trade.creatorPart, trade.holderPart, trade.realQuote], ["buy", 33_000_000n, 6_500_000n, 0n, 26_500_000n, 967_000_000n]);
  assertEquals(trade.price, "0.000002097539015606");
});

Deno.test("decoders: complete, grad_ok, stuck, rescued, refund and the fee claims", () => {
  assertEquals(ev.decodeCompleteV2(decoded([sym("complete"), addr(TOKEN)], map({ real_quote: i128(43_245_553_200n), completed_at: u64(T0) }))), {
    token: TOKEN,
    realQuote: 43_245_553_200n,
    completedAt: new Date(T0 * 1000),
  });
  const ok = ev.decodeGradOkV2(decoded([sym("grad_ok"), addr(TOKEN)], map({
    venue: u32(0),
    pool: addr(POOL),
    pool_tokens: i128(2_000_000_000_000_000n),
    pool_quote: i128(43_245_553_200n),
    liquidity: i128(9_300_000_000_000n),
    burned: i128(1_500_000_000_000_000n),
    fallback: bool(true),
  })));
  assertEquals([ok.venue, ok.pool, ok.burned, ok.fallback, ok.price], [0, POOL, 1_500_000_000_000_000n, true, "0.0000216227766"]);
  assertEquals(ev.decodeStuck(decoded([sym("stuck"), addr(TOKEN)], u64(T0 + 3_600))), { token: TOKEN, stuckSince: new Date((T0 + 3_600) * 1000) });
  assertEquals(ev.decodeRescued(decoded([sym("rescued"), addr(TOKEN)], map({
    stuck_since: u64(T0),
    by_admin: bool(false),
    refund_quote: i128(43_245_553_200n),
    refund_supply: i128(8_000_000_000_000_000n),
    burned: i128(2_000_000_000_000_000n),
  }))), { token: TOKEN, byAdmin: false, refundQuote: 43_245_553_200n, refundSupply: 8_000_000_000_000_000n, burned: 2_000_000_000_000_000n });
  assertEquals(ev.decodeRefund(decoded([sym("refund"), addr(TOKEN), addr(HOLDER)], map({ tokens_in: i128(10n ** 13n), quote_out: i128(54_056_941n) }))), {
    token: TOKEN,
    holder: HOLDER,
    tokensIn: 10n ** 13n,
    quoteOut: 54_056_941n,
  });
  assertEquals(ev.decodeCreatorFees(decoded([sym("cr_claim"), addr(TOKEN), addr(G(22))], i128(5_000_000n))), { token: TOKEN, account: G(22), amount: 5_000_000n });
  assertEquals(ev.decodeCreatorFees(decoded([sym("cr_owed"), addr(TOKEN), addr(G(22))], i128(7n))), { token: TOKEN, account: G(22), amount: 7n });
  assertEquals(ev.decodeOwed(decoded([sym("owed_claim"), addr(G(22)), addr(XLM)], i128(7n))), { account: G(22), asset: XLM, amount: 7n, owed: null });
  assertEquals(ev.decodeProtocolClaim(decoded([sym("pr_claim"), addr(TOKEN)], map({ treasury: addr(G(5)), quote_amount: i128(9n), launch_fee_amount: i128(100_000_000n) }))), {
    token: TOKEN,
    treasury: G(5),
    quoteAmount: 9n,
    launchFeeAmount: 100_000_000n,
  });
  const prop = ev.decodeRecipient(decoded([sym("recip_prop"), addr(TOKEN)], map({ new: addr(G(23)), effective_at: u64(T0 + 120), expires_at: u64(T0 + 420) })));
  assertEquals([prop.recipient, prop.effectiveAt, prop.expiresAt], [G(23), new Date((T0 + 120) * 1000), new Date((T0 + 420) * 1000)]);
  const set = ev.decodeRecipient(decoded([sym("recip_set"), addr(TOKEN)], map({ old: addr(G(22)), new: addr(G(23)), by_takeover: bool(true) })));
  assertEquals([set.recipient, set.byTakeover], [G(23), true]);
});

Deno.test("decoders: a launch's grad_fail carries the venue, the namespaced origin and code with their name (V10), stuck_since and fallback_at", () => {
  const f = ev.decodeLaunchGradFail(decoded([sym("grad_fail"), addr(TOKEN)], map({
    venue: u32(1),
    origin: u32(4),
    code: u32(10_404),
    stuck_since: u64(T0),
    fallback_at: u64(T0 + 3_600),
  })));
  assertEquals(f, {
    token: TOKEN,
    venue: 1,
    origin: 4,
    code: 10_404,
    name: "PaymentUnavailable",
    stuckSince: new Date(T0 * 1000),
    fallbackAt: new Date((T0 + 3_600) * 1000),
  });
  // exec-soroswap's LiquidityTooLow: its local 4, on chain 10_304.
  assertEquals(ev.decodeLaunchGradFail(decoded([sym("grad_fail"), addr(TOKEN)], map({ venue: u32(0), origin: u32(3), code: u32(10_304), stuck_since: u64(T0), fallback_at: u64(0) }))).name, "LiquidityTooLow");
  // An origin-0 code (a contract outside DyorHQ) is named from the foreign table; an unknown pair has no name.
  assertEquals(ev.decodeLaunchGradFail(decoded([sym("grad_fail"), addr(TOKEN)], map({ venue: u32(0), origin: u32(7), code: u32(1), stuck_since: u64(T0), fallback_at: u64(0) }))).name, null);
});

// ------------------------------------------------------------------------------------------------ moments-v2 decoders

const DURATIONS = map({
  vest_period: u64(600),
  stuck_expiry: u64(300),
  pending_backstop: u64(1_800),
  timelock: u64(120),
  timelock_window: u64(600),
  min_window: u64(120),
  max_window: u64(2_592_000),
  harvest_interval: u64(60),
});

Deno.test("decoders: publish with nft, nonce, coin, rate, threshold, durations and metadata_uri; collect; complete", () => {
  const p = ev.decodePublishV2(decoded([sym("publish"), addr(NFT), addr(CREATOR)], map({
    nonce: u64(7n),
    coin: addr(COIN),
    name: str("Accra at dusk"),
    symbol: str("DUSK"),
    metadata_uri: str("https://example.supabase.co/storage/v1/object/public/lite-media/moments/m.json"),
    price: i128(1_000_000n),
    threshold: i128(100_000_000n),
    creator_alloc_bps: u32(1_000),
    rate_num: i128(675_000_000_000_000_000n),
    rate_den: i128(1_350_000_000n),
    deadline: u64(T0 + 86_400),
    durations: DURATIONS,
  })));
  assertEquals(p, {
    nft: NFT,
    creator: CREATOR,
    nonce: 7n,
    coin: COIN,
    name: "Accra at dusk",
    symbol: "DUSK",
    metadataUri: "https://example.supabase.co/storage/v1/object/public/lite-media/moments/m.json",
    price: 1_000_000n,
    threshold: 100_000_000n,
    creatorAllocBps: 1_000,
    rateNum: 675_000_000_000_000_000n,
    rateDen: 1_350_000_000n,
    deadline: new Date((T0 + 86_400) * 1000),
    durations: { vest_period: 600, stuck_expiry: 300, pending_backstop: 1_800, timelock: 120, timelock_window: 600, min_window: 120, max_window: 2_592_000, harvest_interval: 60 },
  });
  assertEquals(ev.decodeCollectV2(decoded([sym("collect"), addr(NFT), addr(HOLDER)], map({
    gross: i128(3_000_000n),
    editions: u32(3),
    first_rank: u32(5),
    entitlement: i128(1_500_000_000_000n),
    reserve_in: i128(2_250_000n),
    creator_in: i128(600_000n),
    platform_in: i128(150_000n),
    excess: i128(0n),
    reserve: i128(9_000_000n),
  }))), { nft: NFT, collector: HOLDER, gross: 3_000_000n, editions: 3, firstRank: 5, entitlement: 1_500_000_000_000n, reserve: 9_000_000n });
  assertEquals(ev.decodeMomentComplete(decoded([sym("complete"), addr(NFT)], map({ reserve: i128(100_000_000n), total_gross: i128(133_333_334n), completed_at: u64(T0) }))), {
    nft: NFT,
    reserve: 100_000_000n,
    totalGross: 133_333_334n,
    completedAt: new Date(T0 * 1000),
  });
});

Deno.test("decoders: a Moment's grad_ok and grad_fail (origin, code, name and the stuck clock it started, F15)", () => {
  assertEquals(ev.decodeMomentGradOk(decoded([sym("grad_ok"), addr(NFT)], map({
    coin: addr(COIN),
    pool: addr(POOL),
    lp_token: addr(POOL),
    liquidity: i128(1_000n),
    pool_coins: i128(5n),
    coin_used: i128(5n),
    usdc_used: i128(99_990_000n),
    usdc_returned: i128(10_000n),
  }))), { nft: NFT, coin: COIN, pool: POOL, lpToken: POOL, liquidity: 1_000n, poolCoins: 5n, usdcUsed: 99_990_000n });
  assertEquals(ev.decodeMomentGradFail(decoded([sym("grad_fail"), addr(NFT)], map({ origin: u32(10), code: u32(11_003), stuck_since: u64(T0) }))), {
    nft: NFT,
    origin: 10,
    code: 11_003,
    name: "GraduationInvalid",
    stuckSince: new Date(T0 * 1000),
  });
});

Deno.test("decoders: expired carries whether the backstop applied (V11); vest_claim; withdrawn per role", () => {
  const expired = (backstop: boolean) =>
    ev.decodeExpired(decoded([sym("expired"), addr(NFT)], map({
      reserve: i128(100_000_000n),
      creator_share: i128(70_000_000n),
      treasury_share: i128(30_000_000n),
      backstop: bool(backstop),
    })));
  assertEquals(expired(true), { nft: NFT, reserve: 100_000_000n, creatorShare: 70_000_000n, treasuryShare: 30_000_000n, backstop: true });
  assertEquals(expired(false).backstop, false);
  assertEquals(ev.decodeVestClaim(decoded([sym("vest_claim"), addr(NFT), addr(HOLDER)], map({ collector_amount: i128(900n), creator_amount: i128(0n) }))), {
    nft: NFT,
    account: HOLDER,
    collectorAmount: 900n,
    creatorAmount: 0n,
  });
  assertEquals(ev.decodeWithdrawn(decoded([sym("withdrawn"), addr(NFT), sym("platform")], map({ to: addr(G(24)), amount: i128(150_000n) }))), {
    nft: NFT,
    role: "platform",
    to: G(24),
    amount: 150_000n,
  });
});

Deno.test("decoders: the Moment NFT's mint and transfer {token_id}, as OpenZeppelin publishes them", () => {
  assertEquals(decodeMove(decoded([sym("mint"), addr(HOLDER)], map({ token_id: u32(5) }))), { tokenId: 5, from: null, to: HOLDER });
  assertEquals(decodeMove(decoded([sym("transfer"), addr(HOLDER), addr(G(25))], map({ token_id: u32(5) }))), { tokenId: 5, from: HOLDER, to: G(25) });
});

// ------------------------------------------------------------------------------------------------ the locker and launch tokens

Deno.test("decoders: lock_reg for a launch and a Moment, harvested with take and compounded, owed_credit and owed_paid", () => {
  const reg = (reference: xdr.ScVal) =>
    ev.decodeLockReg(decoded([sym("lock_reg"), addr(POOL), addr(PAD)], map({
      kind: vec(sym("Soroswap")),
      lp_token: addr(POOL),
      lp: i128(9_300n),
      base: addr(TOKEN),
      quote: addr(XLM),
      reference,
      harvest_bps: u32(10_000),
      principal: i128(9_300n),
    })));
  assertEquals(reg(vec(sym("Launch"), addr(TOKEN))), {
    pool: POOL,
    owner: PAD,
    kind: "Soroswap",
    lpToken: POOL,
    lp: 9_300n,
    base: TOKEN,
    quote: XLM,
    refKind: "launch",
    ref: TOKEN,
    harvestBps: 10_000,
    principal: 9_300n,
  });
  assertEquals([reg(vec(sym("Moment"), addr(NFT))).refKind, reg(vec(sym("Moment"), addr(NFT))).ref], ["moment", NFT]);
  assertEquals(ev.decodeHarvested(decoded([sym("harvested"), addr(POOL)], map({
    lp_burned: i128(12n),
    base_out: i128(1_200n),
    quote_out: i128(34n),
    growth: i128(20n),
    take: i128(20n),
    compounded: i128(0n),
    principal: i128(9_300n),
  }))), { pool: POOL, lpBurned: 12n, baseOut: 1_200n, quoteOut: 34n, growth: 20n, take: 20n, compounded: 0n, principal: 9_300n });
  assertEquals(ev.decodeOwed(decoded([sym("owed_credit"), addr(G(22)), addr(USDC)], map({ amount: i128(5n), owed: i128(15n) }))), { account: G(22), asset: USDC, amount: 5n, owed: 15n });
  assertEquals(ev.decodeOwed(decoded([sym("owed_paid"), addr(G(22)), addr(USDC)], map({ amount: i128(15n) }))), { account: G(22), asset: USDC, amount: 15n, owed: null });
});

Deno.test("decoders: a launch token's reward events in both assets, the quote and the token itself (F1); excluded", () => {
  for (const asset of [XLM, TOKEN]) {
    assertEquals(ev.decodeRewardEvent(decoded([sym("rwd_queue"), addr(asset)], map({ notifier: addr(LOCKER), amount: i128(500n), releasable_from: u32(5_300_100) }))), {
      kind: "queued",
      asset,
      notifier: LOCKER,
      amount: 500n,
      releasableFrom: 5_300_100,
    });
    assertEquals(ev.decodeRewardEvent(decoded([sym("rwd_add"), addr(asset)], map({ amount: i128(500n), eligible: i128(10n ** 16n), acc: i128(50_000n) }))), {
      kind: "released",
      asset,
      amount: 500n,
      eligible: 10n ** 16n,
      acc: 50_000n,
    });
    assertEquals(ev.decodeRewardEvent(decoded([sym("rwd_proto"), addr(asset)], map({ amount: i128(3n), eligible: i128(0n) }))), { kind: "to_protocol", asset, amount: 3n, eligible: 0n });
    assertEquals(ev.decodeRewardEvent(decoded([sym("rwd_claim"), addr(asset), addr(HOLDER)], map({ amount: i128(250n) }))), { kind: "claimed", asset, holder: HOLDER, amount: 250n });
    assertEquals(ev.decodeRewardEvent(decoded([sym("rwd_sweep"), addr(asset), addr(G(5))], map({ amount: i128(3n) }))), { kind: "swept", asset, treasury: G(5), amount: 3n });
  }
  assertEquals(ev.decodeRewardEvent(decoded([sym("transfer"), addr(HOLDER), addr(G(25))], i128(1n))), null);
  assertEquals(ev.decodeExcluded(decoded([sym("excluded"), addr(POOL)], map({ by_pool: bool(true), stranded_q: i128(4n), stranded_t: i128(9n) }))), {
    account: POOL,
    byPool: true,
    strandedQuote: 4n,
    strandedToken: 9n,
  });
});

Deno.test("pool discovery: Soroswap's new_pair and the Aquarius router's add_pool make a candidate per sharing launch among the tokens", () => {
  const pair = ev.decodeNewPool(decoded([str("SoroswapFactory"), sym("new_pair")], map({ token_0: addr(XLM), token_1: addr(TOKEN), pair: addr(POOL), new_pairs_length: u32(812) })));
  assertEquals(pair, { pool: POOL, tokens: [XLM, TOKEN], kind: "soroswap" });
  assertEquals(ev.poolCandidates(pair!, new Set([TOKEN])), [{ token: TOKEN, other: XLM }]);
  assertEquals(ev.poolCandidates(pair!, new Set([C(77)])), []);
  // add_pool [add_pool, tokens] [pool, pool_type, pool_index, init_args] (contracts/testdata/fixtures.json).
  const aqua = ev.decodeNewPool(decoded([sym("add_pool"), vec(addr(TOKEN), addr(USDC))], vec(addr(C(44)), sym("constant"), xdr.ScVal.scvBytes(new Uint8Array(32) as any), vec(u32(30)))));
  assertEquals(aqua, { pool: C(44), tokens: [TOKEN, USDC], kind: "aquarius" });
  assertEquals(ev.poolCandidates(aqua!, new Set([TOKEN])), [{ token: TOKEN, other: USDC }]);
  // A three-token pool can't be checked against a pair.
  assertEquals(ev.poolCandidates({ pool: C(45), tokens: [TOKEN, XLM, USDC], kind: "aquarius" }, new Set([TOKEN])), []);
  assertEquals(ev.decodeNewPool(decoded([str("SoroswapFactory"), sym("fee_to")], addr(G(1)))), null);
});

// ------------------------------------------------------------------------------------------------ keys and generations

Deno.test("generations: v2's key names its singletons and testnet-qa's failing stack; its filter reads the router's add_pool only", () => {
  assertEquals(ev.v2Key(TESTNET), null);
  assertEquals(ev.v2Key(NET), [TESTNET.passphrase, PAD, MOMENTS, LOCKER, ""].join("|"));
  assertEquals(ev.v2Key(QA_NET), [TESTNET.passphrase, PAD, MOMENTS, LOCKER, C(8)].join("|"));
  assertEquals(ev.momentsContracts(QA_NET), [MOMENTS, C(8)]);
  const filters = ev.v2Filters(QA_NET);
  assertEquals(filters[0].contractIds, [PAD, MOMENTS, C(8), LOCKER]);
  assertEquals(filters[1].contractIds, [TESTNET.contracts.soroswapFactory]);
  assertEquals(filters[2], { type: "contract", contractIds: [TESTNET.contracts.aquariusRouter!], topics: [[sym("add_pool").toXDR("base64"), "*"]] });
  // The failing stack's Moments are never listed (F5).
  assert(ev.listedV2({ title: "t", posterUrl: "p" }, MOMENTS, QA_NET));
  assertFalse(ev.listedV2({ title: "t", posterUrl: "p" }, C(8), QA_NET));
  assertFalse(ev.listedV2({ title: "t", posterUrl: "" }, MOMENTS, QA_NET));
});

Deno.test("generations: a cursor continues under its own key, starts over under another, and waits when the ledger went backwards", () => {
  const row = { name: "events_v2", ledger: 5_350_000, cursor: "c", key: "k" };
  assertEquals(ev.cursorAction(null, "k", 5_350_010), "restart");
  assertEquals(ev.cursorAction(row, "k", 5_350_010), "continue");
  assertEquals(ev.cursorAction(row, "other", 5_350_010), "restart");
  assertEquals(ev.cursorAction(row, "k", 5_000), "backwards");
});

// A fake RPC for the generations' cursors: the latest ledger, and getEvents with no events, each request kept. A test
// that needs more of RPC (the TTL upkeep's reads and transactions) answers through `rpcAnswer` while it runs.
const rpcCalls: { method: string; params: any }[] = [];
const LATEST = 5_400_000;
let rpcAnswer: ((method: string, params: any) => unknown) | null = null;
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  if (new URL(req.url).host !== "soroban-testnet.stellar.org") return new Response("offline", { status: 503 });
  const body = await req.json();
  rpcCalls.push({ method: body.method, params: body.params });
  if (rpcAnswer) {
    try {
      return Response.json({ jsonrpc: "2.0", id: body.id, result: rpcAnswer(body.method, body.params) });
    } catch (err) {
      return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32000, message: String((err as Error).message) } });
    }
  }
  if (body.method !== "getEvents") return Response.json({ jsonrpc: "2.0", id: body.id, error: { code: -32601, message: `no ${body.method} here` } });
  const result = { latestLedger: LATEST, oldestLedger: LATEST - 120_000, events: [], cursor: `${(BigInt(LATEST) << 32n).toString().padStart(19, "0")}-0000000000` };
  return Response.json({ jsonrpc: "2.0", id: body.id, result });
}) as typeof fetch;
// getLatestLedger's answer carries the ledger's header and metadata XDR, which these tests don't need.
rpcServer().getLatestLedger = () => Promise.resolve({ id: "x", protocolVersion: 23, sequence: LATEST } as any);

/** The database behind indexGenerations: its cursors as given, every write kept. */
function cursorDb(cursors: Row[]): [string, unknown[]][] {
  const writes: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select to_regclass(")) return [{ present: true }];
    if (q.startsWith("select name, ledger, cursor, network_id from lite.indexer_cursors")) return cursors;
    writes.push([q, p]);
    if (q.startsWith("insert into lite.indexer_cursors") || q.startsWith("delete from")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  return writes;
}

const deletes = (writes: [string, unknown[]][]) => writes.filter(([q]) => q.startsWith("delete") || q.startsWith("truncate")).map(([q]) => q);

Deno.test("generations: deploying v2, or another v2, clears no v1 row and reads v2 from its deploy ledger", async () => {
  const v1Key = deploymentKey(NET);
  for (const v2Row of [[], [{ name: "events_v2", ledger: LATEST - 10, cursor: "0001-0", network_id: "an older v2 deployment" }]]) {
    rpcCalls.length = 0;
    const writes = cursorDb([{ name: "events", ledger: LATEST - 5, cursor: "0002-0", network_id: v1Key }, ...v2Row]);
    const r = await ev.indexGenerations(NET);
    assertEquals(deletes(writes), [], "nothing is cleared");
    assertEquals([r.reset, (r.v2 as { restarted: boolean }).restarted, (r.v1 as { restarted: boolean }).restarted], [false, true, false]);
    const reads = rpcCalls.filter((c) => c.method === "getEvents").map((c) => c.params);
    // v1 goes on from its cursor; v2 starts at its deployment's ledger, inside RPC's window.
    assertEquals(reads[0].pagination.cursor, "0002-0");
    assertEquals(reads[1].startLedger, 5_300_000);
    assertEquals(writes.filter(([q]) => q.startsWith("insert into lite.indexer_cursors")).map(([, p]) => [p[0], p[3]]), [["events", v1Key], ["events_v2", ev.v2Key(NET)]]);
  }
});

Deno.test("generations: another v1 deployment clears v1's rows only, never v2's", async () => {
  const writes = cursorDb([
    { name: "events", ledger: LATEST - 5, cursor: "0002-0", network_id: `${TESTNET.passphrase}|${C(60)}|${C(61)}` },
    { name: "events_v2", ledger: LATEST - 5, cursor: "0003-0", network_id: ev.v2Key(NET) },
  ]);
  await ev.indexGenerations(NET);
  assertEquals(deletes(writes), [
    "delete from lite.launches where generation = 1",
    "delete from lite.moments where generation = 1",
    "delete from lite.moment_editions where contract = ?",
    "delete from lite.watch_groups g where not exists (select 1 from lite.watch_contracts w where w.group_id = g.id)",
  ]);
  assertEquals(writes.find(([q]) => q.startsWith("delete from lite.moment_editions"))![1], [C(61)]);
});

// ------------------------------------------------------------------------------------------------ recording

/** The database behind a handler: every query kept; inserts into v2_events are new, alerts fire. */
function recordingDb(): [string, unknown[]][] {
  const writes: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    writes.push([q, p]);
    if (q.startsWith("insert into lite.v2_events")) return [{ event_id: p[0] }];
    if (q.startsWith("insert into lite.keeper_alerts")) return [{ kind: p[0] }];
    return [];
  }));
  return writes;
}

const rpcEvent = (id: string) => ({ id, ledger: 5_300_500, ledgerClosedAt: "2026-10-15T19:00:00Z", txHash: "ab".repeat(32) }) as any;

Deno.test("recording: a grad_fail names its failure on the launch; exec-aquarius' PaymentUnavailable alerts, exec-soroswap's LiquidityTooLow doesn't (V10)", async () => {
  const warned: string[] = [];
  const warn = console.warn;
  console.warn = (...a: unknown[]) => void warned.push(a.join(" "));
  try {
    const fail = (origin: number, code: number) => decoded([sym("grad_fail"), addr(TOKEN)], map({ venue: u32(1), origin: u32(origin), code: u32(code), stuck_since: u64(T0), fallback_at: u64(T0 + 3_600) }));
    let writes = recordingDb();
    await ev.launchpadV2Event(rpcEvent("0001-1"), fail(3, 10_304), AQUA_NET);
    const update = writes.find(([q]) => q.startsWith("update lite.launches set stuck_since"))!;
    assertEquals(update[1].slice(2, 7), [1, 3, 10_304, "LiquidityTooLow", new Date("2026-10-15T19:00:00Z")]);
    assertEquals(writes.filter(([q]) => q.startsWith("insert into lite.keeper_alerts")), []);
    for (const [code, name] of [[10_404, "PaymentUnavailable"], [10_405, "PaymentTooHigh"]] as const) {
      writes = recordingDb();
      await ev.launchpadV2Event(rpcEvent(`0001-${code}`), fail(4, code), AQUA_NET);
      const alert = writes.find(([q]) => q.startsWith("insert into lite.keeper_alerts"))!;
      assertEquals(alert[1].slice(0, 3), ["payment_failure", TOKEN, `0001-${code}`]);
      assert(warned.some((w) => w.includes(`exec-aquarius ${name} (4, ${code})`)));
    }
    // A page read again: the event is known, nothing moves and nothing fires.
    replaceSql(fakeSql((q) => {
      if (q.startsWith("insert into lite.v2_events")) return [];
      throw new Error(`unexpected query: ${q}`);
    }));
    await ev.launchpadV2Event(rpcEvent("0001-10404"), fail(4, 10_404), AQUA_NET);
  } finally {
    console.warn = warn;
  }
});

Deno.test("recording: a Moment's expired keeps its backstop flag; a launch token's reward events add up per asset", async () => {
  let writes = recordingDb();
  await ev.momentsV2Event(rpcEvent("0002-1"), decoded([sym("expired"), addr(NFT)], map({ reserve: i128(9n), creator_share: i128(6n), treasury_share: i128(3n), backstop: bool(true) })), MOMENTS, NET);
  const expired = writes.find(([q]) => q.startsWith("update lite.moments set state = 'expired'"))!;
  assertEquals(expired[1].slice(1, 4), [true, "6", "3"]);

  writes = recordingDb();
  const members = new Map([[TOKEN, { contract: TOKEN, role: "launch_token" as const, ref: TOKEN }]]);
  const tokenEvent = (id: string, topics: xdr.ScVal[], data: xdr.ScVal) => ({ ...rpcEvent(id), contractId: TOKEN, topic: topics, value: data }) as any;
  assert(await ev.handleWatchedV2(tokenEvent("0003-1", [sym("rwd_add"), addr(XLM)], map({ amount: i128(500n), eligible: i128(10n), acc: i128(7n) })), members));
  assert(await ev.handleWatchedV2(tokenEvent("0003-2", [sym("rwd_add"), addr(TOKEN)], map({ amount: i128(800n), eligible: i128(10n), acc: i128(9n) })), members));
  assertFalse(await ev.handleWatchedV2(tokenEvent("0003-3", [sym("transfer"), addr(HOLDER), addr(G(25))], i128(1n)), members), "SEP-41 events are jobs/watch.ts's");
  const rewards = writes.filter(([q]) => q.startsWith("insert into lite.launch_rewards")).map(([, p]) => [p[1], p[3]]);
  assertEquals(rewards, [[XLM, "500"], [TOKEN, "800"]]);
  assertEquals(writes.filter(([q]) => q.startsWith("insert into lite.reward_releases")).map(([, p]) => [p[2], p[3], p[4]]), [[XLM, "released", "500"], [TOKEN, "released", "800"]]);
});

// ------------------------------------------------------------------------------------------------ keeper decisions

const graduated = (pool = POOL): Sim => ({ ok: true, value: ["Graduated", pool], auth: 0 });
const failed = (origin = 3, code = 10_304): Sim => ({ ok: true, value: ["Failed", { origin, code }], auth: 0 });
const aborted = (code = 10_134): Sim => ({ ok: false, error: `HostError: Error(Contract, #${code})`, code });
const fine: Sim = { ok: true, value: undefined, auth: 0 };

/** A simulator answering by function name, recording what it was asked. */
function sims(answers: Record<string, Sim>) {
  const asked: string[] = [];
  return { asked, sim: (fn: string) => (asked.push(fn), Promise.resolve(answers[fn] ?? aborted(10_118))) };
}
const noSkip = () => false;
const MIN = 60_000;
const NOW = T0 * 1000;
const stuck = (over: Partial<LaunchStatus> = {}): LaunchStatus => ({ phase: 1, stuckSince: NOW - 2 * MIN, markStuckAt: NOW - 5 * MIN, fallbackAt: NOW + MIN, rescuePublicAt: NOW + 60 * MIN, ...over });

Deno.test("keeper: graduate_fallback only from fallback_at, and only when the simulated graduate fails (F14)", async () => {
  // During fallback_delay: graduate is simulated every run and sent when it would succeed; the fallback isn't touched.
  let s = sims({ graduate: failed(), graduate_fallback: graduated() });
  assertEquals(await k.decideLaunch(stuck(), NOW, s.sim, noSkip), null);
  assertEquals(s.asked, ["graduate"]);
  s = sims({ graduate: graduated(), graduate_fallback: graduated() });
  assertEquals(await k.decideLaunch(stuck(), NOW, s.sim, noSkip), { fn: "graduate" });
  // From fallback_at: the creator's venue still first.
  s = sims({ graduate: graduated(), graduate_fallback: graduated() });
  assertEquals(await k.decideLaunch(stuck({ fallbackAt: NOW }), NOW, s.sim, noSkip), { fn: "graduate" });
  assertEquals(s.asked, ["graduate"]);
  // The venue fails (recoverably, or aborting): the fallback, when its own simulation graduates.
  for (const g of [failed(), aborted()]) {
    s = sims({ graduate: g, graduate_fallback: graduated() });
    assertEquals(await k.decideLaunch(stuck({ fallbackAt: NOW }), NOW, s.sim, noSkip), { fn: "graduate_fallback" });
  }
  // A fallback that would fail too isn't sent.
  s = sims({ graduate: failed(), graduate_fallback: failed() });
  assertEquals(await k.decideLaunch(stuck({ fallbackAt: NOW }), NOW, s.sim, noSkip), null);
  // Not stuck yet: there is no fallback_at.
  s = sims({ graduate: aborted(), graduate_fallback: graduated() });
  assertEquals(await k.decideLaunch(stuck({ stuckSince: 0, fallbackAt: 0, markStuckAt: NOW + MIN }), NOW, s.sim, noSkip), null);
  assertFalse(s.asked.includes("graduate_fallback"));
});

Deno.test("keeper: one recoverable failure is sent so it is recorded, then only attempts that would succeed; aborts never", async () => {
  const fresh = stuck({ stuckSince: 0, fallbackAt: 0, markStuckAt: NOW + MIN });
  assertEquals(await k.decideLaunch(fresh, NOW, sims({ graduate: failed() }).sim, noSkip), { fn: "graduate", recordsFailure: true });
  assertEquals(await k.decideLaunch(stuck(), NOW, sims({ graduate: failed() }).sim, noSkip), null, "the failure is recorded already");
  assertEquals(await k.decideLaunch(fresh, NOW, sims({ graduate: aborted() }).sim, noSkip), null, "an abort records nothing and isn't sent");
  // mark_stuck once the grace has passed with nothing recorded.
  assertEquals(await k.decideLaunch({ ...fresh, markStuckAt: NOW }, NOW, sims({ graduate: aborted(), mark_stuck: fine }).sim, noSkip), { fn: "mark_stuck" });
  // rescue from rescue_public_at, after the venues.
  const s = sims({ graduate: failed(), graduate_fallback: failed(), rescue: fine });
  assertEquals(await k.decideLaunch(stuck({ fallbackAt: NOW - MIN, rescuePublicAt: NOW }), NOW, s.sim, noSkip), { fn: "rescue" });
  assertEquals(s.asked, ["graduate", "graduate_fallback", "rescue"]);
  // Not completed: nothing at all.
  for (const phase of [0, 2, 3]) assertEquals(await k.decideLaunch(stuck({ phase }), NOW, sims({}).sim, noSkip), null);
});

const pending = (over: Partial<MomentStatus> = {}): MomentStatus => ({
  state: 1,
  completedAt: NOW - 10 * MIN,
  stuckSince: 0,
  deadline: NOW - MIN,
  stuckExpiryMs: 5 * MIN,
  pendingBackstopMs: 30 * MIN,
  ...over,
});

Deno.test("keeper: Moments graduate like launches but never get mark_stuck (F15); expire past the deadline, the backstop included (V11)", async () => {
  assertEquals(await k.decideMoment(pending(), NOW, sims({ graduate: graduated() }).sim, noSkip), { fn: "graduate" });
  assertEquals(await k.decideMoment(pending(), NOW, sims({ graduate: failed(10, 11_003) }).sim, noSkip), { fn: "graduate", recordsFailure: true });
  // A graduate that aborts records nothing: the Moment waits for its backstop, with no mark_stuck to call.
  const s = sims({ graduate: aborted(), expire: fine, mark_stuck: fine });
  assertEquals(await k.decideMoment(pending(), NOW, s.sim, noSkip), null);
  assertEquals(await k.decideMoment(pending(), NOW + 21 * MIN, s.sim, noSkip), { fn: "expire" });
  assertFalse(s.asked.includes("mark_stuck"));
  // Every state and simulation: only graduate or expire.
  const outcomes = [graduated(), failed(), aborted()];
  for (const state of [0, 1, 2, 3]) {
    for (const g of outcomes) {
      for (const stuckSince of [0, NOW - 6 * MIN]) {
        const d = await k.decideMoment(pending({ state, stuckSince }), NOW + 40 * MIN, sims({ graduate: g, expire: fine, mark_stuck: fine }).sim, noSkip);
        assert(d === null || d.fn === "graduate" || d.fn === "expire");
      }
    }
  }
  // expire's rules: never before the deadline; Collecting after it; pending after stuck_expiry or at the backstop.
  assertFalse(k.expirable(pending({ deadline: NOW + MIN, stuckSince: NOW - 60 * MIN }), NOW));
  assert(k.expirable(pending({ state: 0 }), NOW));
  assert(k.expirable(pending({ stuckSince: NOW - 5 * MIN }), NOW));
  assertFalse(k.expirable(pending({ stuckSince: NOW - 4 * MIN }), NOW));
  assertFalse(k.expirable(pending(), NOW));
  assert(k.expirable(pending(), NOW + 20 * MIN));
  assertFalse(k.expirable(pending({ state: 2 }), NOW + 60 * MIN));
});

Deno.test("keeper: harvests above the floor once the interval allows; fee sweeps in batches of at most 20 per quote; exclude_pool's verdicts", () => {
  assert(k.harvestDue([5n, 1n, 0n, 0n, BigInt(T0)], NOW, 0n));
  assertFalse(k.harvestDue([5n, 0n, 0n, 0n, BigInt(T0)], NOW, 0n), "nothing to burn");
  assertFalse(k.harvestDue([5n, 1n, 0n, 0n, BigInt(T0 + 1)], NOW, 0n), "before next_at");
  assertFalse(k.harvestDue([5n, 1n, 0n, 0n, BigInt(T0)], NOW, 5n), "not above the floor");
  assertEquals(k.harvestFloor(TESTNET), 0n);
  const rows = [...Array.from({ length: 23 }, (_, i) => ({ token: C(100 + i), quote: XLM })), { token: C(200), quote: USDC }];
  const batches = k.feeBatches(rows);
  // One quote per call, in a fixed order (USDC's contract sorts first on testnet).
  assertEquals(batches.map((b) => [b.quote, b.tokens.length]), [[USDC, 1], [XLM, 20], [XLM, 3]]);
  assertEquals(k.poolVerdict({ ok: true, value: true, auth: 0 }), "send");
  assertEquals(k.poolVerdict({ ok: true, value: false, auth: 0 }), "excluded");
  assertEquals(k.poolVerdict(aborted(10_214)), "below_floor");
  assertEquals(k.poolVerdict(aborted(10_209)), "rejected");
  assertEquals(k.poolVerdict(aborted(10_211)), "rejected");
  assertEquals(k.poolVerdict({ ok: false, error: "rpc down", code: null }), "retry");
});

Deno.test("keeper: a call that asks for anyone's authorization is refused", () => {
  const source = Keypair.random();
  const build = (auth: xdr.SorobanAuthorizationEntry[]) =>
    new TransactionBuilder(new Account(source.publicKey(), "1"), { fee: "100", networkPassphrase: TESTNET.passphrase })
      .addOperation(Operation.invokeContractFunction({ contract: PAD, function: "rescue", args: [addr(TOKEN)], auth }))
      .setTimeout(30)
      .build();
  assertEquals(k.authEntries(build([])), 0);
  const entry = new xdr.SorobanAuthorizationEntry({
    credentials: xdr.SorobanCredentials.sorobanCredentialsAddress(new xdr.SorobanAddressCredentials({
      address: new Address(G(2)).toScAddress(),
      nonce: xdr.Int64.fromString("1"),
      signatureExpirationLedger: 0,
      signature: xdr.ScVal.scvVoid(),
    })),
    rootInvocation: new xdr.SorobanAuthorizedInvocation({
      function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(new xdr.InvokeContractArgs({
        contractAddress: new Address(PAD).toScAddress(),
        functionName: "rescue",
        args: [addr(TOKEN)],
      })),
      subInvocations: [],
    }),
  });
  assertEquals(k.authEntries(build([entry])), 1);
});

// ------------------------------------------------------------------------------------------------ keeper runs

/** The keeper's chain in a test: simulations and views answered by contract, function and first argument; every send
 *  and restore kept and confirmed; the paths as `path` says (all live by default). */
class FakeChain implements Chain {
  sent: { job: string; contract: string; fn: string; target: string }[] = [];
  simulated: { contract: string; fn: string; target: string }[] = [];
  restored: string[] = [];
  pathChecks = 0;
  path: PathReport = { entries: 20, archived: [], restored: false, extended: [] };
  constructor(
    readonly simAnswer: (contract: string, fn: string, target: string) => Sim,
    readonly viewAnswer: (contract: string, fn: string, target: string) => unknown,
    readonly at: number = NOW,
  ) {}
  restore(_preamble: unknown, target: string) {
    this.restored.push(target);
    return Promise.resolve(true);
  }
  keepPathAlive() {
    this.pathChecks++;
    return Promise.resolve(this.path);
  }
  private target(args: xdr.ScVal[]): string {
    return args.length && args[0].switch().name === "scvAddress" ? Address.fromScVal(args[0]).toString() : args.length ? String(native(args[args.length - 1])) : "";
  }
  simulate(contract: string, fn: string, args: xdr.ScVal[]) {
    const target = fn === "exclude_pool" ? Address.fromScVal(args[2]).toString() : this.target(args);
    this.simulated.push({ contract, fn, target });
    return Promise.resolve(this.simAnswer(contract, fn, target));
  }
  send(job: KeeperJobV2, contract: string, fn: string, _args: xdr.ScVal[], target: string) {
    this.sent.push({ job, contract, fn, target });
    return Promise.resolve(true);
  }
  view(contract: string, fn: string, args: xdr.ScVal[] = []) {
    return Promise.resolve(this.viewAnswer(contract, fn, this.target(args)));
  }
  now() {
    return this.at;
  }
}

interface KeeperState {
  skip?: Row[];
  completed?: string[];
  moments?: Row[];
  positions?: Row[];
  graduated?: { token: string; checked: string | null }[];
  pools?: Row[];
}

/** The database behind a keeper run, from `state`; every write kept. */
function keeperDb(state: KeeperState): [string, unknown[]][] {
  const writes: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select to_regclass(")) return [{ present: true }];
    if (q === "select kind, target, jobs, until from lite.keeper_skip") return state.skip ?? [];
    if (q.startsWith("select token from lite.launches where generation = 2 and contract = ? and phase = 'completed'")) return (state.completed ?? []).map((token) => ({ token }));
    if (q.startsWith("select nft, contract, deadline, durations from lite.moments")) return state.moments ?? [];
    if (q.startsWith("select pool, ref_kind, ref from lite.locker_positions")) return state.positions ?? [];
    if (q.startsWith("select token from lite.launches where generation = 2 and contract = ? and phase = 'graduated'")) {
      return (state.graduated ?? []).filter((g) => g.checked !== p[1]).map((g) => ({ token: g.token }));
    }
    if (q.startsWith("select c.pool, c.token, c.other, c.kind from lite.pool_candidates")) return state.pools ?? [];
    writes.push([q, p]);
    if (q.startsWith("update lite.launches set treasury_checked")) {
      const g = state.graduated!.find((x) => x.token === p[1]);
      if (g) g.checked = String(p[0]);
      return [];
    }
    if (q.startsWith("update lite.pool_candidates")) return [];
    if (q.startsWith("insert into lite.keeper_alerts")) return [{ kind: p[0] }];
    throw new Error(`unexpected query: ${q}`);
  }));
  return writes;
}

const L_FALLBACK = C(50);
const L_RESCUE = C(51);
const L_MARK = C(52);
const L_GRAD = C(53);
const M_GRAD = C(54);
const M_EXPIRE = C(55);
const M_POOL = C(56);

/** One of each job, due: a launch for each of graduate, fallback, mark_stuck and rescue, a Moment to graduate and one to
 *  expire, a position to harvest. */
function everyJob(): { chain: FakeChain; state: KeeperState } {
  const secs = (ms: number) => BigInt(Math.floor(ms / 1000));
  const status: Record<string, unknown> = {
    [L_FALLBACK]: { phase: 1, stuck_since: secs(NOW - 2 * MIN), mark_stuck_at: secs(NOW - 3 * MIN), fallback_at: secs(NOW - MIN), rescue_public_at: secs(NOW + 60 * MIN) },
    [L_RESCUE]: { phase: 1, stuck_since: secs(NOW - 20 * MIN), mark_stuck_at: secs(NOW - 21 * MIN), fallback_at: secs(NOW - 19 * MIN), rescue_public_at: secs(NOW) },
    [L_MARK]: { phase: 1, stuck_since: 0n, mark_stuck_at: secs(NOW - MIN), fallback_at: 0n, rescue_public_at: 0n },
    [L_GRAD]: { phase: 1, stuck_since: 0n, mark_stuck_at: secs(NOW + MIN), fallback_at: 0n, rescue_public_at: 0n },
  };
  const ledgers: Record<string, unknown> = {
    [M_GRAD]: { state: 1, completed_at: secs(NOW - MIN), stuck_since: 0n },
    [M_EXPIRE]: { state: 0, completed_at: 0n, stuck_since: 0n },
  };
  const chain = new FakeChain(
    (_c, fn, target) => {
      if (fn === "graduate") return target === L_GRAD || target === M_GRAD ? graduated() : target === L_MARK ? aborted() : failed();
      if (fn === "graduate_fallback") return target === L_FALLBACK ? graduated() : failed();
      return fine;
    },
    (_c, fn, target) => {
      if (fn === "status") return status[target];
      if (fn === "ledger") return ledgers[target];
      if (fn === "treasury") return G(5);
      if (fn === "harvestable") return [10n, 2n, 0n, 0n, secs(NOW)];
      throw new Error(`no view ${fn}`);
    },
  );
  const state: KeeperState = {
    completed: [L_FALLBACK, L_RESCUE, L_MARK, L_GRAD],
    moments: [
      { nft: M_GRAD, contract: MOMENTS, deadline: new Date(NOW - MIN), durations: { stuck_expiry: 300, pending_backstop: 1_800 } },
      { nft: M_EXPIRE, contract: C(8), deadline: new Date(NOW - MIN), durations: { stuck_expiry: 300, pending_backstop: 1_800 } },
    ],
    positions: [{ pool: M_POOL, ref_kind: "launch", ref: L_GRAD }],
  };
  return { chain, state };
}

const SKIP_ALL: Row[] = [
  { kind: "launch", target: L_FALLBACK, jobs: ["fallback"], until: null },
  { kind: "launch", target: L_RESCUE, jobs: ["fallback", "rescue"], until: null },
  { kind: "launch", target: L_MARK, jobs: ["mark_stuck"], until: new Date(NOW + 60 * MIN) },
  { kind: "launch", target: L_GRAD, jobs: ["graduate", "harvest"], until: null },
  { kind: "moment", target: M_GRAD, jobs: ["graduate", "expire"], until: null },
  { kind: "moment", target: M_EXPIRE, jobs: ["expire"], until: null },
];

async function withDeployment<T>(name: string | undefined, fn: () => Promise<T>): Promise<T> {
  if (name) Deno.env.set("LITE_DEPLOYMENT", name);
  else Deno.env.delete("LITE_DEPLOYMENT");
  try {
    return await fn();
  } finally {
    Deno.env.delete("LITE_DEPLOYMENT");
  }
}

Deno.test("keeper run: with nothing held off, each due job is sent once (graduate, fallback, mark_stuck, rescue, expire, harvest)", async () => {
  const { chain, state } = everyJob();
  keeperDb(state);
  await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, chain));
  assertEquals(chain.sent.map((s) => [s.job, s.target]), [
    ["graduate_fallback", L_FALLBACK],
    ["rescue", L_RESCUE],
    ["mark_stuck", L_MARK],
    ["graduate", L_GRAD],
    ["graduate", M_GRAD],
    ["expire", M_EXPIRE],
    ["harvest", L_GRAD],
  ]);
  // The failing stack's Moment is expired on its own contract.
  assertEquals(chain.sent.find((s) => s.target === M_EXPIRE)!.contract, C(8));
  assertFalse(chain.sent.some((s) => s.fn === "mark_stuck" && (s.target === M_GRAD || s.target === M_EXPIRE)), "Moments have no mark_stuck");
});

Deno.test("keeper run: on testnet-qa, keeper_skip holds off every job, rescue and expire included, by launch token or Moment NFT (V5)", async () => {
  const { chain, state } = everyJob();
  keeperDb({ ...state, skip: SKIP_ALL });
  const r = await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, chain));
  assertEquals(chain.sent, []);
  assertEquals((r as KeeperV2Report).skippedRows, 0);
  // A row whose `until` has passed no longer holds anything off.
  const again = everyJob();
  keeperDb({ ...again.state, skip: [{ kind: "launch", target: L_MARK, jobs: ["mark_stuck"], until: new Date(NOW - 1) }] });
  await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, again.chain));
  assert(again.chain.sent.some((s) => s.job === "mark_stuck" && s.target === L_MARK));
});

Deno.test("keeper run: anywhere but testnet-qa, keeper_skip is ignored, with a warning", async () => {
  const warned: string[] = [];
  const warn = console.warn;
  console.warn = (...a: unknown[]) => void warned.push(a.join(" "));
  try {
    const { chain, state } = everyJob();
    keeperDb({ ...state, skip: SKIP_ALL });
    const r = await withDeployment(undefined, () => k.keeperV2(QA_NET, chain));
    assertEquals(chain.sent.length, 7);
    assertEquals((r as KeeperV2Report).skippedRows, 6);
    assert(warned.some((w) => w.includes("6 lite.keeper_skip row(s) ignored") && w.includes("testnet-qa only")));
  } finally {
    console.warn = warn;
  }
});

Deno.test("keeper run: after a treasury change, every graduated sharing launch is sent exclude_treasury, and only once (V2)", async () => {
  const graduatedLaunches = [C(70), C(71), C(72)].map((token) => ({ token, checked: G(4) as string | null }));
  const view = (_c: string, fn: string) => (fn === "treasury" ? G(5) : undefined);
  // The treasury is excluded already on C(72) (a harvest or a sweep excluded it since): no transaction for it.
  let chain = new FakeChain((c, fn) => (fn === "exclude_treasury" ? { ok: true, value: c !== C(72), auth: 0 } : fine), view);
  const writes = keeperDb({ graduated: graduatedLaunches });
  await k.keeperV2(NET, chain);
  assertEquals(chain.sent.map((s) => [s.job, s.contract]), [["exclude_treasury", C(70)], ["exclude_treasury", C(71)]]);
  assertEquals(writes.filter(([q]) => q.startsWith("update lite.launches set treasury_checked")).map(([, p]) => p), [[G(5), C(70)], [G(5), C(71)], [G(5), C(72)]]);
  // The next run: nothing left for this treasury.
  chain = new FakeChain(() => ({ ok: true, value: true, auth: 0 }), view);
  keeperDb({ graduated: graduatedLaunches });
  await k.keeperV2(NET, chain);
  assertEquals(chain.sent, []);
});

Deno.test("keeper run: exclude_pool is sent only when its simulation passes; a pool under the floor is checked again in an hour (F2)", async () => {
  const pool = (n: number) => ({ pool: C(n), token: TOKEN, other: XLM, kind: "soroswap" });
  const answers: Record<string, Sim> = {
    [C(80)]: { ok: true, value: true, auth: 0 },
    [C(81)]: aborted(10_214),
    [C(82)]: aborted(10_209),
    [C(83)]: { ok: true, value: false, auth: 0 },
  };
  const chain = new FakeChain((_c, fn, target) => (fn === "exclude_pool" ? answers[target] : fine), (_c, fn) => (fn === "treasury" ? G(5) : undefined));
  const writes = keeperDb({ pools: [pool(80), pool(81), pool(82), pool(83)] });
  await k.keeperV2(NET, chain);
  assertEquals(chain.sent.map((s) => [s.job, s.target]), [["exclude_pool", C(80)]]);
  const updates = writes.filter(([q]) => q.startsWith("update lite.pool_candidates")).map(([, p]) => [p[p.length - 2], p[0], p[1]]);
  assertEquals(updates, [[C(80), "excluded", null], [C(81), "below_floor", "1 hour"], [C(82), "rejected", null], [C(83), "excluded", null]]);
});

Deno.test("keeper run: fees go out in batches of up to 20 launches per quote, and launch tokens' protocol shares are swept, at most every 10 minutes", async () => {
  const run = async (lastSweep: Date | null) => {
    const chain = new FakeChain(() => fine, () => undefined);
    replaceSql(fakeSql((q) => {
      if (q.startsWith("select to_regclass(")) return [{ present: true }];
      if (q.startsWith("select max(created_at) as at from lite.keeper_log where job in ('claim_protocol_fees', 'sweep_protocol')")) return [{ at: lastSweep }];
      if (q.startsWith("select token, quote from lite.launches")) {
        return [...Array.from({ length: 21 }, (_, i) => ({ token: C(100 + i), quote: XLM })), { token: C(130), quote: USDC }];
      }
      if (q.startsWith("select distinct r.token from lite.launch_rewards")) return [{ token: C(100) }];
      throw new Error(`unexpected query: ${q}`);
    }));
    return { report: await k.keeperV2Fees(NET, chain), sent: chain.sent.map((s) => [s.job, s.target]) };
  };
  const all = [["claim_protocol_fees", USDC], ["claim_protocol_fees", XLM], ["claim_protocol_fees", XLM], ["sweep_protocol", C(100)]];
  assertEquals((await run(null)).sent, all);
  assertEquals((await run(new Date(NOW - 11 * MIN))).sent, all);
  // A sweep 5 minutes ago: nothing this run.
  const recent = await run(new Date(NOW - 5 * MIN));
  assertEquals([recent.sent, recent.report], [[], { skipped: "swept less than 10 minutes ago" }]);
});

// ------------------------------------------------------------------------------------------------ alerts

Deno.test("alerts: the AQUA float under 5 × the pool payment, a launch stuck past fallback_delay, a Moment pending an hour and a day before its backstop", () => {
  assertEquals(k.floatAlert(C(10), 50_000_000n, 10_000_000n, NOW), null);
  const low = k.floatAlert(C(10), 49_999_999n, 10_000_000n, NOW)!;
  assertEquals([low.kind, low.target], ["aqua_float", C(10)]);

  assertEquals(k.stuckAlert(TOKEN, NOW - 59 * MIN, 60 * MIN, NOW), null);
  assertEquals(k.stuckAlert(TOKEN, 0, 60 * MIN, NOW), null, "not stuck");
  assertEquals(k.stuckAlert(TOKEN, NOW - 60 * MIN, 60 * MIN, NOW)!.kind, "launch_stuck");

  const day = 24 * 60 * MIN;
  const moment = { state: 1, completedAt: NOW - 59 * MIN, stuckSince: 0, pendingBackstopMs: 30 * day };
  assertEquals(k.pendingAlerts(NFT, moment, NOW), []);
  assertEquals(k.pendingAlerts(NFT, { ...moment, completedAt: NOW - 60 * MIN }, NOW).map((a) => a.kind), ["moment_pending"]);
  assertEquals(k.pendingAlerts(NFT, { ...moment, completedAt: NOW - 29 * day }, NOW).map((a) => a.kind), ["moment_pending", "moment_backstop"]);
  assertEquals(k.pendingAlerts(NFT, { ...moment, completedAt: NOW - 29 * day, stuckSince: NOW - day }, NOW), [], "a recorded failure has its own clock");
  assertEquals(k.pendingAlerts(NFT, { ...moment, state: 2, completedAt: NOW - 29 * day }, NOW), []);
});

Deno.test("alerts: grad_fail alerts on exec-aquarius' payment pair only, never on a bare local code (V10)", () => {
  assertEquals(k.gradFailAlert("launch", TOKEN, { origin: 4, code: 10_404 }, "e1")!.kind, "payment_failure");
  assertEquals(k.gradFailAlert("launch", TOKEN, { origin: 4, code: 10_405 }, "e2")!.kind, "payment_failure");
  // exec-soroswap's LiquidityTooLow is local 4 (10_304 on chain); a bare 4 or 10_404 from another origin isn't the pair.
  assertEquals(k.gradFailAlert("launch", TOKEN, { origin: 3, code: 10_304 }, "e3"), null);
  assertEquals(k.gradFailAlert("launch", TOKEN, { origin: 4, code: 4 }, "e4"), null);
  assertEquals(k.gradFailAlert("launch", TOKEN, { origin: 0, code: 10_404 }, "e5"), null);
  assertEquals(k.gradFailAlert("moment", NFT, { origin: 4, code: 10_407 }, "e6"), null);
});

Deno.test("keeper run: a stuck launch past fallback_delay and a Moment pending an hour fire their alerts once", async () => {
  const secs = (ms: number) => BigInt(Math.floor(ms / 1000));
  // The launch's venue and fallback fail recoverably (its failure is recorded already); the Moment's graduate aborts, so
  // nothing records a failure for it (its clock is the backstop's).
  const chain = new FakeChain(
    (c, fn) => (c === MOMENTS ? aborted() : fn === "graduate" || fn === "graduate_fallback" ? failed() : aborted()),
    (_c, fn) => {
      if (fn === "status") return { phase: 1, stuck_since: secs(NOW - 61 * MIN), mark_stuck_at: secs(NOW - 70 * MIN), fallback_at: secs(NOW - MIN), rescue_public_at: secs(NOW + 30 * 24 * 60 * MIN) };
      if (fn === "ledger") return { state: 1, completed_at: secs(NOW - 61 * MIN), stuck_since: 0n };
      if (fn === "treasury") return G(5);
      throw new Error(fn);
    },
  );
  const writes = keeperDb({
    completed: [TOKEN],
    moments: [{ nft: NFT, contract: MOMENTS, deadline: new Date(NOW + 60 * MIN), durations: { stuck_expiry: 604_800, pending_backstop: 2_592_000 } }],
  });
  const warn = console.warn;
  console.warn = () => {};
  try {
    const r = await k.keeperV2(NET, chain) as KeeperV2Report;
    assertEquals(writes.filter(([q]) => q.startsWith("insert into lite.keeper_alerts")).map(([, p]) => [p[0], p[1]]), [["launch_stuck", TOKEN], ["moment_pending", NFT]]);
    assertEquals(r.alerts.length, 2);
    assertEquals(chain.sent, []);
  } finally {
    console.warn = warn;
  }
});


// ------------------------------------------------------------------------------------------------ TTL upkeep

const SOROSWAP_CODE = { factory: H(11), pair: H(12) };

/** v2's graduation and harvest paths on testnet-qa, in v2PathEntries' order. */
const QA_PATH = [
  "instance launchpad-v2",
  "instance moments-v2",
  "instance lp-locker",
  "instance exec-soroswap",
  "instance moments-graduator",
  "instance qa-exec-fail",
  "instance moments-v2 (failing stack)",
  "instance moments-graduator (failing stack)",
  "code launchpadV2",
  "code launchTokenV2",
  "code execSoroswap",
  "code qaExecFail",
  "code lpLocker",
  "code momentsV2",
  "code momentNft",
  "code momentCoin",
  "code momentsGraduator",
  "instance soroswap factory",
  "soroswap PairWasmHash",
  "code soroswap factory",
  "code soroswap pair",
];

Deno.test("TTL upkeep: the paths (every v2 singleton and WASM, Soroswap's factory, PairWasmHash and pair code) are critical; quotes, launches, Moments, coins, positions, unvested collectors and owed fees join the rotation", async () => {
  const LP = C(90);
  const queries: [string, unknown[]][] = [];
  replaceSql(fakeSql((q, p) => {
    queries.push([q, p]);
    if (q.startsWith("select to_regclass(")) return [{ present: true }];
    if (q.startsWith("select l.token, l.holder_sharing, l.pair, p.lp_token from lite.launches")) return [{ token: TOKEN, holder_sharing: true, pair: POOL, lp_token: POOL }];
    if (q.startsWith("select m.nft, m.contract, m.coin, m.pool, m.state, p.lp_token from lite.moments")) {
      return [{ nft: NFT, contract: C(8), coin: COIN, pool: LP, state: "graduated", lp_token: LP }, { nft: C(91), contract: MOMENTS, coin: C(92), pool: null, state: "collecting", lp_token: null }];
    }
    if (q.startsWith("select p.nft, p.account, m.contract from lite.moment_positions")) return [{ nft: NFT, account: HOLDER, contract: C(8) }];
    if (q.startsWith("select contract, account, asset from lite.creator_owed")) return [{ contract: PAD, account: G(22), asset: XLM }, { contract: LOCKER, account: G(23), asset: USDC }];
    throw new Error(`unexpected query: ${q}`);
  }));
  const entries = await ttl.v2UpkeepEntries(QA_NET, SOROSWAP_CODE);
  assertEquals(entries.filter((e) => e.critical).map((e) => e.label), QA_PATH);
  const labels = entries.filter((e) => !e.critical).map((e) => e.label);
  assertEquals(labels, [
    "quote launchpad-v2 XLM",
    "instance asset XLM",
    "quote launchpad-v2 USDC",
    "instance asset USDC",
    "quote launchpad-v2 QA",
    "instance asset QA",
    `instance ${TOKEN}`,
    `launch ${TOKEN}`,
    `curve ${TOKEN}`,
    `recipient ${TOKEN}`,
    `sharing ${TOKEN}`,
    `instance pool ${POOL}`,
    `locker position ${POOL}`,
    `locker tracked ${POOL}`,
    `instance ${NFT}`,
    `moment ${NFT}`,
    `ledger ${NFT}`,
    `instance coin ${COIN}`,
    `instance pool ${LP}`,
    `locker position ${LP}`,
    `locker tracked ${LP}`,
    `instance ${C(91)}`,
    `moment ${C(91)}`,
    `ledger ${C(91)}`,
    `vesting ${NFT} ${HOLDER}`,
    `CreatorOwed ${G(22)} ${XLM}`,
    `Owed ${G(23)} ${USDC}`,
  ]);
  // Each query names this deployment's contracts and 12 months of activity.
  assertEquals(queries.filter(([q]) => !q.startsWith("select to_regclass")).map(([, p]) => p), [[PAD, 365], [[MOMENTS, C(8)], 365], [[MOMENTS, C(8)]], [[PAD, LOCKER]]]);
  // The keys are the contracts' own: a graduated sharing launch's Curve(token) (harvest_payees reads it, CT-05 N2), its
  // token's unit Sharing entry, a collector's vesting Position(nft, account) in the failing stack's contract, the
  // factory's PairWasmHash and the pair code it names.
  const key = (label: string) => entries.find((e) => e.label === label)!.key;
  const curve = key(`curve ${TOKEN}`).contractData();
  assertEquals(Address.fromScAddress(curve.contract()).toString(), PAD);
  assertEquals(curve.key().toXDR("base64"), vec(sym("Curve"), addr(TOKEN)).toXDR("base64"));
  assertEquals(curve.durability().name, "persistent");
  assertEquals(key(`sharing ${TOKEN}`).contractData().key().toXDR("base64"), vec(sym("Sharing")).toXDR("base64"));
  const position = key(`vesting ${NFT} ${HOLDER}`).contractData();
  assertEquals(Address.fromScAddress(position.contract()).toString(), C(8));
  assertEquals(position.key().toXDR("base64"), vec(sym("Position"), addr(NFT), addr(HOLDER)).toXDR("base64"));
  assertEquals(key(`locker tracked ${POOL}`).contractData().key().toXDR("base64"), vec(sym("Tracked"), addr(POOL)).toXDR("base64"));
  assertEquals(key(`Owed ${G(23)} ${USDC}`).contractData().key().toXDR("base64"), vec(sym("Owed"), addr(G(23)), addr(USDC)).toXDR("base64"));
  const pairHash = key("soroswap PairWasmHash").contractData();
  assertEquals([Address.fromScAddress(pairHash.contract()).toString(), pairHash.key().toXDR("base64")], [TESTNET.contracts.soroswapFactory, vec(sym("PairWasmHash")).toXDR("base64")]);
  assertEquals(key("code soroswap pair").contractCode().hash().toString("hex"), H(12));
  assertEquals(key("code launchTokenV2").contractCode().hash().toString("hex"), H(2));

  // Before migration 20261015000012 only the paths and the quotes; without a v2 deployment, nothing (and no query).
  replaceSql(fakeSql((q) => (q.startsWith("select to_regclass(") ? [{ present: false }] : [])));
  // Soroswap's code unread: its factory instance and PairWasmHash are still on the path.
  assertEquals((await ttl.v2UpkeepEntries(NET, null)).map((e) => e.label), [
    "instance launchpad-v2",
    "instance moments-v2",
    "instance lp-locker",
    "instance exec-soroswap",
    "instance moments-graduator",
    "code launchpadV2",
    "code launchTokenV2",
    "code execSoroswap",
    "code lpLocker",
    "code momentsV2",
    "code momentNft",
    "code momentCoin",
    "code momentsGraduator",
    "instance soroswap factory",
    "soroswap PairWasmHash",
    "quote launchpad-v2 XLM",
    "instance asset XLM",
    "quote launchpad-v2 USDC",
    "instance asset USDC",
  ]);
  replaceSql(fakeSql((q) => {
    throw new Error(`unexpected query: ${q}`);
  }));
  assertEquals(await ttl.v2UpkeepEntries(TESTNET), []);
});

Deno.test("TTL upkeep: Soroswap's code is read from the factory's instance and PairWasmHash entry, once an hour", async () => {
  const factory = C(160);
  const instance = xdr.ScVal.scvContractInstance(new xdr.ScContractInstance({ executable: xdr.ContractExecutable.contractExecutableWasm(Buffer.from(H(11), "hex") as any), storage: null }));
  let reads = 0;
  rpcAnswer = (method, params) => {
    if (method !== "getLedgerEntries") throw new Error(`unexpected RPC ${method}`);
    reads++;
    const entries = (params.keys as string[]).map((k) => {
      const data = xdr.LedgerKey.fromXDR(k, "base64").contractData();
      const val = data.key().switch().name === "scvLedgerKeyContractInstance" ? instance : xdr.ScVal.scvBytes(Buffer.from(H(12), "hex") as any);
      const entry = xdr.LedgerEntryData.contractData(new xdr.ContractDataEntry({ ext: new xdr.ExtensionPoint(0), contract: data.contract(), key: data.key(), durability: data.durability(), val }));
      return { key: k, xdr: entry.toXDR("base64"), lastModifiedLedgerSeq: 1, liveUntilLedgerSeq: LATEST + 100 };
    });
    return { entries, latestLedger: LATEST };
  };
  try {
    assertEquals(await ttl.soroswapCode(factory, NOW), SOROSWAP_CODE);
    assertEquals(await ttl.soroswapCode(factory, NOW + 59 * MIN), SOROSWAP_CODE);
    assertEquals(reads, 1);
    await ttl.soroswapCode(factory, NOW + 61 * MIN);
    assertEquals(reads, 2);
  } finally {
    rpcAnswer = null;
  }
});

/** RPC behind an upkeep run: the entries `liveUntil` has, live until then (absent ones archived), the keeper's account,
 *  and every simulation, send and status of its transactions, which it keeps. */
function upkeepRpc(liveUntil: Map<string, number>, latest: number): Transaction[] {
  const sent: Transaction[] = [];
  const keeperAccount = Keypair.fromPublicKey(SPONSOR.publicKey()).xdrAccountId();
  rpcAnswer = (method, params) => {
    switch (method) {
      case "getFeeStats":
        return { sorobanInclusionFee: { p90: "100" }, inclusionFee: { p90: "100" }, latestLedger: latest };
      case "getLedgerEntries": {
        const entries = (params.keys as string[]).flatMap((k) => {
          const key = xdr.LedgerKey.fromXDR(k, "base64");
          if (key.switch().name === "account") {
            const account = new xdr.AccountEntry({
              accountId: keeperAccount,
              balance: xdr.Int64.fromString("100000000000"),
              seqNum: xdr.Int64.fromString("77"),
              numSubEntries: 0,
              inflationDest: null,
              flags: 0,
              homeDomain: "",
              thresholds: Buffer.from([1, 0, 0, 0]) as any,
              signers: [],
              ext: new xdr.AccountEntryExt(0),
            });
            return [{ key: k, xdr: xdr.LedgerEntryData.account(account).toXDR("base64"), lastModifiedLedgerSeq: 1 }];
          }
          if (!liveUntil.has(k)) return [];
          const data = key.switch().name === "contractCode"
            ? xdr.LedgerEntryData.contractCode(new xdr.ContractCodeEntry({ ext: new xdr.ContractCodeEntryExt(0), hash: key.contractCode().hash(), code: Buffer.alloc(0) as any }))
            : xdr.LedgerEntryData.contractData(
              new xdr.ContractDataEntry({ ext: new xdr.ExtensionPoint(0), contract: key.contractData().contract(), key: key.contractData().key(), durability: key.contractData().durability(), val: xdr.ScVal.scvVoid() }),
            );
          return [{ key: k, xdr: data.toXDR("base64"), lastModifiedLedgerSeq: 1, liveUntilLedgerSeq: liveUntil.get(k) }];
        });
        return { entries, latestLedger: latest };
      }
      case "simulateTransaction": {
        const tx = TransactionBuilder.fromXDR(params.transaction, TESTNET.passphrase) as Transaction;
        const fp = (tx.toEnvelope().v1().tx().ext().sorobanData() as xdr.SorobanTransactionData).resources().footprint();
        const data = new SorobanDataBuilder().setReadOnly(fp.readOnly()).setReadWrite(fp.readWrite()).setResources(0, 500, 0).build();
        return { latestLedger: latest, minResourceFee: "20000", transactionData: data.toXDR("base64"), results: [{ auth: [], xdr: xdr.ScVal.scvVoid().toXDR("base64") }], events: [] };
      }
      case "sendTransaction": {
        const tx = TransactionBuilder.fromXDR(params.transaction, TESTNET.passphrase) as Transaction;
        sent.push(tx);
        return { status: "PENDING", hash: tx.hash().toString("hex"), latestLedger: latest, latestLedgerCloseTime: "0" };
      }
      case "getTransaction": {
        const tx = sent.find((t) => t.hash().toString("hex") === params.hash)!;
        const result = new xdr.TransactionResult({ feeCharged: xdr.Int64.fromString("70150"), result: xdr.TransactionResultResult.txSuccess([]), ext: new xdr.TransactionResultExt(0) });
        const meta = new xdr.TransactionMeta(3, new xdr.TransactionMetaV3({ ext: new xdr.ExtensionPoint(0), txChangesBefore: [], operations: [], txChangesAfter: [], sorobanMeta: null }));
        return {
          status: "SUCCESS",
          latestLedger: latest,
          latestLedgerCloseTime: "0",
          oldestLedger: 1,
          oldestLedgerCloseTime: "0",
          ledger: latest + 1,
          createdAt: "0",
          applicationOrder: 1,
          feeBump: false,
          envelopeXdr: tx.toEnvelope().toXDR("base64"),
          resultXdr: result.toXDR("base64"),
          resultMetaXdr: meta.toXDR("base64"),
        };
      }
    }
    throw new Error(`unexpected RPC ${method}`);
  };
  return sent;
}

const DAY_LEDGERS = 17_280;
const footprint = (tx: Transaction) => (tx.toEnvelope().v1().tx().ext().sorobanData() as xdr.SorobanTransactionData).resources().footprint();
const keyIds = (keys: xdr.LedgerKey[]) => keys.map((k) => k.toXDR("base64"));

Deno.test("TTL upkeep run: the paths are checked every run whatever perRun; an archived WASM on them is restored in a transaction of its own, then extended; an archived entry off them isn't restored", async () => {
  const latest = 5_400_000;
  const path = ttl.v2PathEntries(QA_NET, SOROSWAP_CODE);
  const code = path.find((e) => e.label === "code launchTokenV2")!;
  const low = path.find((e) => e.label === "instance launchpad-v2")!;
  const offPath = { key: ttl.instanceKey(C(170)), label: "instance off the path" };
  const liveUntil = new Map(path.map((e) => [e.key.toXDR("base64"), latest + 20 * DAY_LEDGERS]));
  liveUntil.delete(code.key.toXDR("base64"));
  liveUntil.set(low.key.toXDR("base64"), latest + DAY_LEDGERS);
  const sent = upkeepRpc(liveUntil, latest);
  const logged: unknown[] = [];
  replaceSql(fakeSql((q, p) => {
    if (q.startsWith("select key, checked_at from lite.ttl_checks")) return [];
    if (q.startsWith("select to_regclass(")) return [{ present: true }];
    if (q.startsWith("insert into lite.keeper_log")) {
      logged.push(p[4]);
      return [];
    }
    if (q.startsWith("insert into lite.ttl_checks") || q.startsWith("delete from lite.ttl_checks")) return [];
    throw new Error(`unexpected query: ${q}`);
  }));
  try {
    const policy = { thresholdDays: 10, extendToDays: 30, perRun: path.length + 1, idleDays: 90 };
    const report = await ttl.upkeep([offPath, ...path], policy, Date.now() + 10_000);
    assertEquals([report.checked, report.restored, report.low, report.extended, report.missing, report.hashes.length], [path.length + 1, 1, 1, 2, 1, 2]);
    // First the restore of the archived WASM alone, then one extension of it and the low instance.
    assertEquals(sent.map((t) => t.operations[0].type), ["restoreFootprint", "extendFootprintTtl"]);
    assertEquals([keyIds(footprint(sent[0]).readWrite()), keyIds(footprint(sent[0]).readOnly())], [[code.key.toXDR("base64")], []]);
    assertEquals(keyIds(footprint(sent[1]).readOnly()), [code.key.toXDR("base64"), low.key.toXDR("base64")]);
    assertEquals((sent[1].operations[0] as any).extendTo, 30 * DAY_LEDGERS);
    assertEquals(logged, [{ restored: ["code launchTokenV2"] }, { entries: ["code launchTokenV2", "instance launchpad-v2"] }]);

    // All live: a perRun of 1 still checks the whole path, and sends nothing.
    for (const e of path) liveUntil.set(e.key.toXDR("base64"), latest + 20 * DAY_LEDGERS);
    sent.length = 0;
    const quiet = await ttl.upkeep([offPath, ...path], { ...policy, perRun: 1 }, Date.now() + 10_000);
    assertEquals([quiet.checked, quiet.restored, quiet.low, sent.length], [path.length, 0, 0, 0]);
  } finally {
    rpcAnswer = null;
  }
});

Deno.test("TTL upkeep before a graduation: upkeepPath restores the path's archived entries first, then extends them with the low ones", async () => {
  const latest = 5_400_000;
  const path = ttl.v2PathEntries(NET, SOROSWAP_CODE);
  const pairCode = path.find((e) => e.label === "code soroswap pair")!;
  const factory = path.find((e) => e.label === "instance soroswap factory")!;
  const liveUntil = new Map(path.map((e) => [e.key.toXDR("base64"), latest + 20 * DAY_LEDGERS]));
  // Past its TTL though RPC still returns it: archived all the same.
  liveUntil.set(pairCode.key.toXDR("base64"), latest - 1);
  liveUntil.set(factory.key.toXDR("base64"), latest + 2 * DAY_LEDGERS);
  const sent = upkeepRpc(liveUntil, latest);
  replaceSql(fakeSql((q) => (q.startsWith("select to_regclass(") ? [{ present: true }] : [])));
  try {
    const report = await ttl.upkeepPath(path, TESTNET.ttlPolicy, Date.now() + 10_000);
    assertEquals(report, { entries: path.length, archived: ["code soroswap pair"], restored: true, extended: ["code soroswap pair", "instance soroswap factory"] });
    assertEquals(sent.map((t) => t.operations[0].type), ["restoreFootprint", "extendFootprintTtl"]);
    assertEquals(keyIds(footprint(sent[0]).readWrite()), [pairCode.key.toXDR("base64")]);
  } finally {
    rpcAnswer = null;
  }
});

// ------------------------------------------------------------------------------------------------ the paths in the keeper

Deno.test("keeper run: with an entry of the paths archived, nothing graduates, expires or harvests in that run; the exclusions still run", async () => {
  const { chain, state } = everyJob();
  chain.path = { entries: 20, archived: ["code momentCoin"], restored: true, extended: ["code momentCoin"] };
  const writes = keeperDb({ ...state, graduated: [{ token: C(70), checked: G(4) }] });
  const warned: string[] = [];
  const warn = console.warn;
  console.warn = (...a: unknown[]) => void warned.push(a.join(" "));
  try {
    const r = await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, chain)) as KeeperV2Report;
    assertEquals(chain.pathChecks, 1);
    assertEquals(r.path, chain.path);
    assertEquals([chain.sent, chain.simulated.filter((s) => s.fn !== "exclude_treasury")], [[], []]);
    assert(warned.some((w) => w.includes("archived entries (code momentCoin), restored; graduations and harvests wait")));
    // The treasury's exclusion, which runs no graduation code, still runs.
    assert(writes.some(([q]) => q.startsWith("update lite.launches set treasury_checked")));
  } finally {
    console.warn = warn;
  }
  // Nothing to graduate, expire or harvest: the paths aren't checked.
  const idle = new FakeChain(() => fine, (_c, fn) => (fn === "treasury" ? G(5) : undefined));
  keeperDb({});
  const r = await k.keeperV2(NET, idle) as KeeperV2Report;
  assertEquals([idle.pathChecks, r.path], [0, undefined]);
});

Deno.test("keeper run: archived data on a graduation's or a harvest's footprint is restored in a transaction of its own first, unless keeper_skip holds the graduation", async () => {
  const preamble = { minResourceFee: "100", transactionData: new SorobanDataBuilder().build().toXDR("base64") };
  const needsRestore: Sim = { ok: false, error: "needs_restore", code: null, restore: preamble };
  const secs = (ms: number) => BigInt(Math.floor(ms / 1000));
  const GRADUATED = C(57);
  const make = () =>
    new FakeChain(
      (_c, fn) => (fn === "graduate" || fn === "harvest" ? needsRestore : fine),
      (_c, fn) => {
        if (fn === "status") return { phase: 1, stuck_since: 0n, mark_stuck_at: secs(NOW - MIN), fallback_at: 0n, rescue_public_at: 0n };
        if (fn === "ledger") return { state: 1, completed_at: secs(NOW - MIN), stuck_since: 0n };
        if (fn === "treasury") return G(5);
        if (fn === "harvestable") return [10n, 2n, 0n, 0n, secs(NOW)];
        throw new Error(fn);
      },
    );
  const state = {
    completed: [TOKEN],
    moments: [{ nft: NFT, contract: MOMENTS, deadline: new Date(NOW + 60 * MIN), durations: { stuck_expiry: 604_800, pending_backstop: 2_592_000 } }],
    // A graduated launch whose Curve archived: its harvest reads it.
    positions: [{ pool: M_POOL, ref_kind: "launch", ref: GRADUATED }],
  };
  let chain = make();
  let writes = keeperDb(state);
  let r = await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, chain)) as KeeperV2Report;
  assertEquals(chain.restored, [TOKEN, NFT, GRADUATED]);
  assertEquals(r.sent.map((s) => [s.job, s.target]), [["restore", TOKEN], ["restore", NFT], ["restore", GRADUATED]]);
  assertEquals(chain.sent, [], "the graduations and the harvest wait for the next run (and mark_stuck too)");
  assertEquals(writes.filter(([q]) => q.startsWith("insert into lite.keeper_alerts")), []);

  chain = make();
  writes = keeperDb({ ...state, skip: [{ kind: "launch", target: TOKEN, jobs: ["graduate"], until: null }, { kind: "moment", target: NFT, jobs: ["graduate"], until: null }] });
  r = await withDeployment("testnet-qa", () => k.keeperV2(QA_NET, chain)) as KeeperV2Report;
  assertEquals(chain.restored, [GRADUATED]);
  // mark_stuck isn't held: an aborting graduate records nothing, so the launch's clock starts with it.
  assertEquals(chain.sent.map((s) => [s.job, s.target]), [["mark_stuck", TOKEN]]);
});

Deno.test("keeper run: a graduation whose simulation runs out of budget is alerted once an hour, logged and reported", async () => {
  const budget: Sim = { ok: false, error: "HostError: Error(Budget, ExceededLimit)\n\nEvent log (newest first): …", code: null };
  assert(k.overBudget(budget));
  assertFalse(k.overBudget(aborted()));
  assertFalse(k.overBudget(failed()));
  const secs = (ms: number) => BigInt(Math.floor(ms / 1000));
  const chain = new FakeChain(
    (_c, fn) => (fn === "graduate" || fn === "graduate_fallback" ? budget : fine),
    (_c, fn) => {
      if (fn === "status") return { phase: 1, stuck_since: secs(NOW - 2 * MIN), mark_stuck_at: secs(NOW - 3 * MIN), fallback_at: secs(NOW - MIN), rescue_public_at: secs(NOW + 60 * MIN) };
      if (fn === "ledger") return { state: 1, completed_at: secs(NOW - 10 * MIN), stuck_since: 0n };
      if (fn === "treasury") return G(5);
      throw new Error(fn);
    },
  );
  const writes = keeperDb({ completed: [TOKEN], moments: [{ nft: NFT, contract: MOMENTS, deadline: new Date(NOW + 60 * MIN), durations: { stuck_expiry: 604_800, pending_backstop: 2_592_000 } }] });
  const warned: string[] = [];
  const warn = console.warn;
  console.warn = (...a: unknown[]) => void warned.push(a.join(" "));
  try {
    const r = await k.keeperV2(NET, chain) as KeeperV2Report;
    assertEquals(r.overBudget, [`${TOKEN} graduate`, `${TOKEN} graduate_fallback`, `${NFT} graduate`]);
    const alerts = writes.filter(([q]) => q.startsWith("insert into lite.keeper_alerts")).map(([, p]) => p.slice(0, 3));
    const hour = Math.floor(NOW / 3_600_000);
    assertEquals(alerts, [["graduation_budget", TOKEN, `graduate:${hour}`], ["graduation_budget", TOKEN, `graduate_fallback:${hour}`], ["graduation_budget", NFT, `graduate:${hour}`]]);
    assert(warned.some((w) => w.includes(`launch ${TOKEN}: graduate runs out of budget`)));
    assertEquals(chain.sent, [], "an attempt that would abort is never sent");
  } finally {
    console.warn = warn;
  }
});

// ------------------------------------------------------------------------------------------------ the indexer's jobs

Deno.test("the indexer runs v2 inside its jobs: each part runs whatever the others do, and the job fails only when all do", async () => {
  const { inTurn } = await import("../../supabase/functions/lite-indexer/index.ts");
  const order: string[] = [];
  const part = (name: string, fails = false) => () => (order.push(name), fails ? Promise.reject(new Error(`${name} down`)) : Promise.resolve(name));
  assertEquals(await inTurn({ v2: part("v2", true), v1: part("v1"), fees: part("fees") }), { v2: { error: "v2 down" }, v1: "v1", fees: "fees" });
  assertEquals(order, ["v2", "v1", "fees"]);
  let error = "";
  await inTurn({ v1: part("v1", true), v2: part("v2", true) }).catch((err) => (error = err.message));
  assertEquals(error, "v1 down");
});
