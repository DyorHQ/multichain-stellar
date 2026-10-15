// Launchpad v2's backend module (docs/DESIGN-stellar-contracts-v2.md §20.2–20.3), against a fake RPC and Horizon that
// answer as launchpad-v2, its launch token, the lp-locker and a Soroswap pair do, with the authorization trees their
// simulations record:
// - the economics block: the 10 XLM fee booked, venues (no Aquarius while it is off, O7), per-quote venue rules,
//   durations with fallbackDelay and harvestInterval, the harvest split and the exclusion floor, terms from
//   preview_launch_terms;
// - live reads: status with every time, the refund rate and a failure named from v2_errors.ts (recorded, or simulated
//   now), rewards in both assets, the recipient, a pending takeover and owed fees;
// - the XLM a launch needs (F18, V12): insufficient_xlm with the shortfall, and Max leaving exactly the minimum
//   balance, the offers' XLM, the fee, the network fee and the buffer behind, with and without subentries and offers;
// - every builder's intent: its calls, a spend that covers exactly what its simulated authorization takes, and the
//   display the review shows; the launch's terms passed by value; refunds burning tokens at the fixed rate; labels
//   naming the launch's own venue; the fallback refused before fallback_at;
// - recipient changes: without holder sharing, the harvest first when the locker's interval allows (F3), and the
//   recipient's part of the backlog one round can't take (V7); with sharing on, neither (harvests pay the holders);
//   the plan made again once when the keeper harvests first;
// - the server verifier (verify.ts, with v2's call rules) passes every builder's step against its own intent, and
//   plans.ts runs it on every step it builds: each step built through createPlan, as the API builds it, with its own
//   v2 step kind; a step the verifier refuses is never handed out.
import { Address, Keypair, nativeToScVal, scValToNative, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { assert, assertEquals, assertMatch, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { fakeSql, OTHER, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();

const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const G = (n: number) => StrKey.encodeEd25519PublicKey(new Uint8Array(32).fill(n) as any);
const H = (n: number) => n.toString(16).padStart(2, "0").repeat(32);

const EXEC = C(1);
const LOCKER = C(2);
const PAD = C(4);
const EXEC_AQUA = C(10);
const TOKEN = C(20);
const POOL = C(21);
const PREDICTED = C(22);
const TREASURY = G(5);
const ME = USER.publicKey();
const NEXT = OTHER.publicKey();

// testnet's v2 deployment, bundled as the owner's file will be (deployments/index.ts BUNDLED_V2), before anything reads
// env.network.
const { BUNDLED_V2, DURATION_SETS_V2 } = await import("../../supabase/functions/_shared/deployments/index.ts");
const DURATIONS = DURATION_SETS_V2.production.launch;
(BUNDLED_V2 as Record<string, Record<string, unknown>>)["testnet-v2"] = {
  network: "testnet",
  deployment: "testnet",
  name: "testnet-v2",
  generation: 1,
  deployer: G(1),
  contracts: { execSoroswap: EXEC, lpLocker: LOCKER, momentsGraduator: C(3), launchpadV2: PAD, momentsV2: C(5) },
  wasmHashes: { launchpadV2: H(1), launchTokenV2: H(2), execSoroswap: H(3), lpLocker: H(4), momentsV2: H(5), momentNft: H(6), momentCoin: H(7), momentsGraduator: H(8) },
  venues: [{ id: 0, kind: "Soroswap", executor: EXEC, feeFraction: 0, enabled: true }],
  quotes: {},
  aquarius: { enabled: false, reason: "--aquarius off" },
  durations: { set: "production", launch: DURATIONS, moments: DURATION_SETS_V2.production.moments },
  ttl: { threshold: 120_960, extend_to: 518_400 },
  deployLedger: 5_300_000,
  deployedAt: "2026-10-15T18:00:00.000Z",
};

const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET } = await import("../../supabase/functions/_shared/networks.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { createPlan, registerBuilder, verifyContext } = await import("../../supabase/functions/_shared/plans.ts");
type StepSpec = import("../../supabase/functions/_shared/plans.ts").StepSpec;
const { feeEstimates } = await import("../../supabase/functions/_shared/fees.ts");
const { verifyTransaction } = await import("../../supabase/functions/_shared/verify.ts");
const v2 = await import("../../supabase/functions/_shared/launchpad_v2.ts");

// As the API registers them with its routes (CT-18).
for (const [kind, builder] of Object.entries(v2.LAUNCH_V2_BUILDERS)) registerBuilder(kind, builder);

const XLM = TESTNET.assets.find((a) => a.id === "XLM")!.contract;
const USDC_ASSET = TESTNET.assets.find((a) => a.id === "USDC")!;
const USDC = USDC_ASSET.contract;
const HOUR = 3_600;
const nowS = () => Math.floor(Date.now() / 1000);

// ------------------------------------------------------------------------------------------------ values

const i128 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const u64 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "u64" });
const addr = (a: string) => new Address(a).toScVal();
const bool = (b: boolean) => xdr.ScVal.scvBool(b);
const str = (s: string) => nativeToScVal(s, { type: "string" });
const vec = (items: xdr.ScVal[]) => xdr.ScVal.scvVec(items);
const none = () => xdr.ScVal.scvVoid();
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));
const contractError = (code: number) => ({ error: `HostError: Error(Contract, #${code})\n\nEvent log (newest first):\n   0: [Diagnostic Event] topics:[error, Error(Contract, #${code})]` });

// ------------------------------------------------------------------------------------------------ the fake chain

type Kind = 0 | 1 | 2 | 3;
interface VenueRow {
  id: number;
  kind: Kind;
  executor: string;
  feeFraction: number;
}

const SOROSWAP: VenueRow = { id: 0, kind: 0, executor: EXEC, feeFraction: 0 };
const AQUARIUS: VenueRow = { id: 1, kind: 1, executor: EXEC_AQUA, feeFraction: 30 };
const QA_VENUE: VenueRow = { id: 2, kind: 3, executor: C(6), feeFraction: 0 };

/** Everything the fake chain answers from; each test starts from `fresh()` and changes what it needs. */
interface World {
  launchFee: bigint;
  venues: VenueRow[];
  quotes: Record<string, { allowed: number[]; fallback: number; enabled: boolean; phantom: bigint; threshold: bigint }>;
  /** Changes to the terms preview_launch_terms answers (a deployment the app doesn't pin). */
  terms: { locker?: string; harvestInterval?: number; executor?: string; feeAsset?: string };
  launch: { venue: VenueRow; fallback: VenueRow; venueLocked: boolean; sharing: boolean; quote: string; symbol: string };
  curve: {
    phase: 0 | 1 | 2 | 3;
    completedAt: number;
    stuckSince: number;
    fallbackAllowed: boolean;
    creatorFees: bigint;
    pool: string | null;
    refundQuote: bigint;
    refundSupply: bigint;
    refunded: bigint;
  };
  recipient: string;
  takeover: { new: string; effective: number; expires: number } | null;
  owed: bigint;
  pending: [bigint, bigint];
  queued: [bigint, bigint, number];
  position: { lp: bigint; principal: bigint; lastHarvest: number; kind: Kind } | null;
  pair: { token: bigint; quote: bigint; total: bigint };
  graduate: xdr.ScVal | { error: string };
  /** What the locker's harvest answers when simulated (it may change the world first: the keeper harvesting). */
  harvest: () => Answer;
  /** A simulation's minResourceFee for a launch with this initial buy. */
  launchFee_: (initialBuy: bigint) => number;
  account: { xlm: string; selling?: string; subentries?: number; sponsoring?: number; sponsored?: number; usdc?: string };
  /** RPC answers nothing. */
  down: boolean;
}

const SIM_FEE = 4_000_000;
/** What prepare() makes of SIM_FEE: the margin (stellar.ts withResourceMargin) plus the 100-stroop inclusion bid. */
const TX_FEE = (fee: number) => (BigInt(fee) * 115n + 99n) / 100n + 50_000n + 100n;

function fresh(): World {
  return {
    launchFee: 100_000_000n,
    venues: [SOROSWAP],
    quotes: {
      [XLM]: { allowed: [], fallback: 0, enabled: true, phantom: 20_000_000_000n, threshold: 43_245_553_200n },
      [USDC]: { allowed: [], fallback: 0, enabled: true, phantom: 200_000_000n, threshold: 432_455_532n },
    },
    terms: {},
    launch: { venue: SOROSWAP, fallback: SOROSWAP, venueLocked: false, sharing: true, quote: XLM, symbol: "ECAT" },
    curve: { phase: 0, completedAt: 0, stuckSince: 0, fallbackAllowed: false, creatorFees: 0n, pool: null, refundQuote: 0n, refundSupply: 0n, refunded: 0n },
    recipient: ME,
    takeover: null,
    owed: 0n,
    pending: [0n, 0n],
    queued: [0n, 0n, 0],
    position: null,
    pair: { token: 4_000_000n, quote: 1_000_000n, total: 2_000_000n },
    graduate: vec([xdr.ScVal.scvSymbol("Graduated"), addr(POOL)]),
    harvest: () => ok(vec([i128(1n), i128(1n)])),
    launchFee_: () => SIM_FEE,
    account: { xlm: "100.0000000" },
    down: false,
  };
}

let world = fresh();
/** The contract functions the fake RPC was asked to run, in order. */
let calls: string[] = [];

const venueSv = (v: VenueRow) =>
  struct({ id: u32(v.id), kind: u32(v.kind), executor: addr(v.executor), params: struct({ fee_fraction: u32(v.feeFraction) }), enabled: bool(true) });
const durationsSv = (d: object) => struct(Object.fromEntries(Object.entries(d).map(([k, v]) => [k, u64(v)])));
const SCHEDULE = vec([9_800, 2_500, 300, 30].map(u32));

function termsSv(quote: string, venueId: number): xdr.ScVal | { error: string } {
  const q = world.quotes[quote];
  if (!q || !q.enabled) return contractError(10_103);
  const venue = world.venues.find((v) => v.id === venueId);
  if (!venue || (q.allowed.length > 0 && !q.allowed.includes(venueId))) return contractError(10_109);
  const fallback = world.venues.find((v) => v.id === q.fallback)!;
  const executor = world.terms.executor;
  return struct({
    supply: i128(10_000_000_000_000_000n),
    fee_bps: u32(100),
    protocol_share_bps: u32(5_000),
    max_creator_fee_bps: u32(1_000),
    snipe_schedule: SCHEDULE,
    snipe_step_secs: u32(5),
    launch_fee: i128(world.launchFee),
    fee_asset: addr(world.terms.feeAsset ?? XLM),
    quote: addr(quote),
    phantom: i128(q.phantom),
    threshold: i128(q.threshold),
    venue: venueSv(executor ? { ...venue, executor } : venue),
    fallback: venueSv(fallback),
    venue_locked: bool(q.allowed.length > 0 && !q.allowed.includes(q.fallback)),
    locker: addr(world.terms.locker ?? LOCKER),
    token_wasm_hash: xdr.ScVal.scvBytes(Buffer.from(H(2), "hex")),
    durations: durationsSv({ ...DURATIONS, ...(world.terms.harvestInterval ? { harvest_interval: world.terms.harvestInterval } : {}) }),
  });
}

function launchSv(): xdr.ScVal {
  const l = world.launch;
  return struct({
    token: addr(TOKEN),
    creator: addr(ME),
    quote: addr(l.quote),
    name: str("E2E Cat"),
    symbol: str(l.symbol),
    uri: str(""),
    nonce: u64(7),
    created_ledger: u32(5_300_100),
    created_at: u64(nowS() - 10 * HOUR),
    fee_bps: u32(100),
    protocol_share_bps: u32(5_000),
    creator_fee_bps: u32(100),
    snipe_schedule: SCHEDULE,
    snipe_step_secs: u32(5),
    venue: venueSv(l.venue),
    fallback: venueSv(l.fallback),
    venue_locked: bool(l.venueLocked),
    holder_sharing: bool(l.sharing),
    launch_fee_paid: i128(100_000_000n),
  });
}

function curveSv(): xdr.ScVal {
  const c = world.curve;
  return struct({
    phantom: i128(20_000_000_000n),
    threshold: i128(43_245_553_200n),
    quote_reserve: i128(30_000_000_000n),
    token_reserve: i128(6_000_000_000_000_000n),
    real_quote: i128(c.phase === 1 ? 43_245_553_200n : 10_000_000_000n),
    creator_fees: i128(c.creatorFees),
    protocol_fees: i128(0n),
    launch_fee_due: i128(100_000_000n),
    holder_fees_total: i128(0n),
    phase: u32(c.phase),
    completed_at: u64(c.completedAt),
    stuck_since: u64(c.stuckSince),
    fallback_allowed: bool(c.fallbackAllowed),
    pool: c.pool ? addr(c.pool) : none(),
    graduated_venue: c.phase === 2 ? u32(world.launch.venue.id) : none(),
    burned: i128(0n),
    refund_quote: i128(c.refundQuote),
    refund_supply: i128(c.refundSupply),
    refunded: i128(c.refunded),
  });
}

/** launchpad-v2's status(): graduation.rs `status`. */
function statusSv(): xdr.ScVal {
  const c = world.curve;
  const completed = c.phase === 1;
  const stuck = completed && c.stuckSince > 0;
  const after = (secs: number) => (stuck ? c.stuckSince + secs : 0);
  let fallbackAt = after(DURATIONS.fallback_delay);
  if (stuck && world.launch.venueLocked && !c.fallbackAllowed) fallbackAt = Math.max(fallbackAt, c.stuckSince + DURATIONS.locked_fallback);
  return struct({
    phase: u32(c.phase),
    completed_at: u64(c.completedAt),
    stuck_since: u64(c.stuckSince),
    mark_stuck_at: u64(completed ? c.completedAt + DURATIONS.grace : 0),
    fallback_at: u64(fallbackAt),
    rescue_admin_at: u64(after(DURATIONS.rescue_admin)),
    rescue_public_at: u64(after(DURATIONS.rescue_public)),
    refund_quote: i128(c.refundQuote),
    refund_supply: i128(c.refundSupply),
  });
}

const RESERVES = () => vec([i128(world.pair.token), i128(world.pair.quote)]);

/** An authorization tree node: `contract.fn(args)`, with what it calls that needs the same signature. */
function invocation(contract: string, fn: string, args: xdr.ScVal[], subs: xdr.SorobanAuthorizedInvocation[] = []): xdr.SorobanAuthorizedInvocation {
  return new xdr.SorobanAuthorizedInvocation({
    function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(
      new xdr.InvokeContractArgs({ contractAddress: new Address(contract).toScAddress(), functionName: fn, args }),
    ),
    subInvocations: subs,
  });
}

/** The source account's authorization of the called function (as recording simulation answers it). */
const signed = (contract: string, fn: string, args: xdr.ScVal[], subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: invocation(contract, fn, args, subs) })];

type Answer = { value: xdr.ScVal; auth?: xdr.SorobanAuthorizationEntry[]; fee?: number } | { error: string };
const ok = (value: xdr.ScVal, auth: xdr.SorobanAuthorizationEntry[] = []): Answer => ({ value, auth });

function answer(contract: string, fn: string, args: xdr.ScVal[]): Answer {
  const arg = (i: number) => scValToNative(args[i]);
  if (contract === PAD) {
    if (["get_launch", "get_curve", "status", "creator_fee_recipient", "pending_recipient_change", "quote_buy", "quote_sell", "quote_refund"].includes(fn) && arg(0) !== TOKEN) {
      return contractError(10_111);
    }
    switch (fn) {
      case "config":
        return ok(struct({
          admin: addr(G(2)),
          guardian: addr(G(3)),
          treasury: addr(TREASURY),
          xlm: addr(XLM),
          token_wasm_hash: xdr.ScVal.scvBytes(Buffer.from(H(2), "hex")),
          locker: addr(LOCKER),
          soroswap_factory: addr(TESTNET.contracts.soroswapFactory),
          aquarius_router: addr(TESTNET.contracts.aquariusRouter!),
          supply: i128(10_000_000_000_000_000n),
          fee_bps: u32(100),
          protocol_share_bps: u32(5_000),
          max_creator_fee_bps: u32(1_000),
          snipe_schedule: SCHEDULE,
          snipe_step_secs: u32(5),
          launch_fee: i128(world.launchFee),
          launches_enabled: bool(true),
          whitelist_enabled: bool(false),
          durations: durationsSv(DURATIONS),
          ttl: struct({ threshold: u32(120_960), extend_to: u32(518_400) }),
        }));
      case "venues":
        return ok(vec(world.venues.map(venueSv)));
      case "quote_economics": {
        const q = world.quotes[arg(0)];
        return ok(q ? struct({ phantom: i128(q.phantom), threshold: i128(q.threshold), enabled: bool(q.enabled), venues_allowed: vec(q.allowed.map(u32)), fallback_venue: u32(q.fallback) }) : none());
      }
      case "preview_launch_terms": {
        const t = termsSv(arg(0), arg(1));
        return t instanceof xdr.ScVal ? ok(t) : t;
      }
      case "token_address":
        return ok(addr(PREDICTED));
      case "launch": {
        const p = scValToNative(args[1]);
        const fee = scValToNative(args[2]).launch_fee as bigint;
        const subs = [
          ...(fee > 0n ? [invocation(XLM, "transfer", [addr(ME), addr(PAD), i128(fee)])] : []),
          ...(p.initial_buy > 0n ? [invocation(String(p.quote), "transfer", [addr(ME), addr(PAD), i128(p.initial_buy)])] : []),
        ];
        return { value: addr(PREDICTED), auth: signed(PAD, fn, args, subs), fee: world.launchFee_(p.initial_buy) };
      }
      case "get_launch":
        return ok(launchSv());
      case "get_curve":
        return ok(curveSv());
      case "status":
        return ok(statusSv());
      case "creator_fee_recipient":
        return ok(addr(world.recipient));
      case "pending_recipient_change": {
        const t = world.takeover;
        return ok(t ? struct({ new: addr(t.new), effective_at: u64(t.effective), expires_at: u64(t.expires) }) : none());
      }
      case "creator_owed":
        return ok(i128(world.owed));
      case "quote_buy":
        return ok(struct({ used: i128(arg(2)), net: i128(arg(2)), base_fee: i128(1_000_000n), creator_fee: i128(1_000_000n), snipe_fee: i128(0n), tokens_out: i128(11_952_000_000_000n) }));
      case "quote_sell":
        return ok(struct({ gross: i128(100_000_000n), base_fee: i128(1_000_000n), creator_fee: i128(1_000_000n), quote_out: i128(98_000_000n) }));
      case "quote_refund":
        if (world.curve.phase !== 3) return contractError(10_118);
        return ok(i128((BigInt(arg(1)) * world.curve.refundQuote) / world.curve.refundSupply));
      case "buy":
        return ok(i128(1n), signed(PAD, fn, args, [invocation(world.launch.quote, "transfer", [addr(ME), addr(PAD), args[2]])]));
      case "sell":
        return ok(i128(1n), signed(PAD, fn, args, [invocation(TOKEN, "transfer", [addr(ME), addr(PAD), args[2]])]));
      case "refund":
        return ok(i128(1n), signed(PAD, fn, args, [invocation(TOKEN, "burn", [addr(ME), args[2]])]));
      case "graduate":
      case "graduate_fallback":
        return world.graduate instanceof xdr.ScVal ? ok(world.graduate) : world.graduate;
      case "mark_stuck":
      case "rescue":
      case "execute_recipient_change":
        return ok(none());
      case "claim_creator_fees":
        return ok(i128(world.curve.creatorFees));
      case "claim_owed":
        return ok(i128(world.owed));
      case "transfer_creator_fee_recipient":
      case "cancel_recipient_change":
        return ok(none(), signed(PAD, fn, args));
    }
  }
  if (contract === TOKEN) {
    switch (fn) {
      case "sharing":
        return ok(world.launch.sharing ? struct({ quote: addr(world.launch.quote), eligible: i128(5_000_000_000_000_000n), queued_ledger: u32(world.queued[2] - 1) }) : none());
      case "queued_rewards":
        return ok(vec([i128(world.queued[0]), i128(world.queued[1]), u32(world.queued[2])]));
      case "pending_rewards":
        return ok(vec([i128(world.pending[0]), i128(world.pending[1])]));
      case "claim":
        return ok(vec([i128(world.pending[0]), i128(world.pending[1])]), signed(TOKEN, fn, args));
    }
  }
  if (contract === LOCKER) {
    switch (fn) {
      case "position": {
        const p = world.position;
        return ok(p
          ? struct({
            owner: addr(PAD),
            kind: u32(p.kind),
            lp_token: addr(POOL),
            base: addr(TOKEN),
            quote: addr(world.launch.quote),
            reference: vec([xdr.ScVal.scvSymbol("Launch"), addr(TOKEN)]),
            lp: i128(p.lp),
            principal: i128(p.principal),
            harvest_bps: u32(10_000),
            last_harvest: u64(p.lastHarvest),
          })
          : none());
      }
      case "harvest":
        return world.harvest();
    }
  }
  if (contract === POOL) {
    switch (fn) {
      case "get_reserves":
        return ok(RESERVES());
      case "token_0":
        return ok(addr(TOKEN));
      case "total_supply":
        return ok(i128(world.pair.total));
    }
  }
  return { error: `HostError: no fake for ${fn} on ${contract}` };
}

function simulate(transaction: string) {
  const tx = TransactionBuilder.fromXDR(transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fn = call.functionName().toString();
  calls.push(fn);
  const a = answer(contract, fn, call.args());
  if ("error" in a) return { latestLedger: 1, error: a.error };
  return {
    latestLedger: 1,
    minResourceFee: String(a.fee ?? SIM_FEE),
    transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
    results: [{ auth: (a.auth ?? []).map((e) => e.toXDR("base64")), xdr: a.value.toXDR("base64") }],
    events: [],
  };
}

function accountEntry(address: string) {
  const id = Keypair.fromPublicKey(address).xdrAccountId();
  const key = xdr.LedgerKey.account(new xdr.LedgerKeyAccount({ accountId: id }));
  const val = xdr.LedgerEntryData.account(new xdr.AccountEntry({
    accountId: id,
    balance: xdr.Int64.fromString("1000000000"),
    seqNum: xdr.Int64.fromString("22096910953218050"),
    numSubEntries: 0,
    inflationDest: null,
    flags: 0,
    homeDomain: "",
    thresholds: Buffer.from([1, 0, 0, 0]),
    signers: [],
    ext: new xdr.AccountEntryExt(0),
  }));
  return { entries: [{ key: key.toXDR("base64"), xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }], latestLedger: 1 };
}

/** Horizon's record of the user's account, from world.account. */
function horizonAccount() {
  const a = world.account;
  return {
    id: ME,
    account_id: ME,
    sequence: "22096910953218050",
    subentry_count: a.subentries ?? 0,
    num_sponsoring: a.sponsoring ?? 0,
    num_sponsored: a.sponsored ?? 0,
    thresholds: { low_threshold: 0, med_threshold: 0, high_threshold: 0 },
    flags: { auth_required: false, auth_revocable: false, auth_immutable: false, auth_clawback_enabled: false },
    signers: [{ weight: 1, key: ME, type: "ed25519_public_key" }],
    data: {},
    balances: [
      ...(a.usdc !== undefined
        ? [{ balance: a.usdc, limit: "922337203685.4775807", buying_liabilities: "0.0000000", selling_liabilities: "0.0000000", asset_type: "credit_alphanum4", asset_code: "USDC", asset_issuer: USDC_ASSET.classic!.split(":")[1] }]
        : []),
      { balance: a.xlm, buying_liabilities: "0.0000000", selling_liabilities: a.selling ?? "0.0000000", asset_type: "native" },
    ],
  };
}

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "soroban-testnet.stellar.org") {
    if (world.down) return new Response("unavailable", { status: 503 });
    const body = await req.json();
    const result = body.method === "simulateTransaction" ? simulate(body.params.transaction) : body.method === "getLedgerEntries" ? accountEntry(ME) : null;
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === `/accounts/${ME}`) return Response.json(horizonAccount());
  if (url.host === "horizon-testnet.stellar.org" && url.pathname === "/ledgers") {
    return Response.json({ _embedded: { records: [{ sequence: 5_300_000, base_reserve_in_stroops: 5_000_000, base_fee_in_stroops: 100 }] }, _links: {} });
  }
  return new Response("offline: unit tests make no network calls", { status: 503 });
}) as typeof fetch;

// No fee history (every estimate is its default, fees.ts); plans are stored; TOKEN is a launch the indexer saw.
const PLAN_ID = "5b0d7f8e-1c2a-4e3b-9f6d-000000000013";
replaceSql(fakeSql((q) => {
  if (q.startsWith("insert into lite.plans")) return [{ id: PLAN_ID, expires_at: new Date(Date.now() + 15 * 60_000) }];
  if (q.startsWith("select token from lite.launches where token = any(")) return [{ token: TOKEN }];
  return [];
}));

function reset(change: (w: World) => void = () => {}): void {
  world = fresh();
  change(world);
  calls = [];
  v2.forgetLaunchV2Reads();
}

// ------------------------------------------------------------------------------------------------ checks

const ctx = () => verifyContext(ME, [TOKEN]);

/** What a step takes from the user, as its simulated authorization says: every transfer and burn the user signs for. */
function outflowOf(tx: Transaction): Record<string, string> {
  const out: Record<string, bigint> = {};
  const walk = (inv: xdr.SorobanAuthorizedInvocation) => {
    const c = inv.function().contractFn();
    const contract = Address.fromScAddress(c.contractAddress()).toString();
    const fn = c.functionName().toString();
    const args = c.args().map((a) => scValToNative(a));
    if ((fn === "transfer" || fn === "burn") && args[0] === ME) out[contract] = (out[contract] ?? 0n) + BigInt(fn === "transfer" ? args[2] : args[1]);
    inv.subInvocations().forEach(walk);
  };
  for (const op of tx.operations as any[]) for (const e of (op.auth ?? []) as xdr.SorobanAuthorizationEntry[]) walk(e.rootInvocation());
  return Object.fromEntries(Object.entries(out).map(([k, v]) => [k, v.toString()]));
}

/** The call a step makes: contract, function and its arguments as native values. */
function callOf(tx: Transaction): { contract: string; fn: string; args: unknown[] } {
  const c = (tx.operations[0] as any).func.invokeContract();
  return { contract: Address.fromScAddress(c.contractAddress()).toString(), fn: c.functionName().toString(), args: c.args().map((a: xdr.ScVal) => scValToNative(a)) };
}

/** Every step's own checks: it calls what its intent names, and declares exactly what its authorization takes. */
function assertStep(built: { tx: Transaction; intent: any }, contract: string, fn: string) {
  assertEquals(built.intent.calls, [{ contract, fn }]);
  assertEquals(callOf(built.tx).contract, contract);
  assertEquals(callOf(built.tx).fn, fn);
  assertEquals(outflowOf(built.tx), built.intent.spend, `${fn}: the spend is what the authorization takes`);
  assertEquals(built.intent.display.generation, 2);
}

async function rejects(run: () => Promise<unknown>): Promise<InstanceType<typeof ApiError>> {
  const err = await run().then(() => null, (e) => e);
  assert(err instanceof ApiError, `expected an ApiError, got ${err}`);
  return err;
}

// ------------------------------------------------------------------------------------------------ symbols and refusals

Deno.test("tickers: 2–10 ASCII letters or digits as typed, upper-cased, not a reserved one; refused before any read", async () => {
  assertEquals(v2.launchSymbolV2(" ecat "), "ECAT");
  assertEquals(v2.launchSymbolV2("Cat42"), "CAT42");
  for (const bad of ["ÉCAT", "ﬀCAT", "E CAT", "E-CAT", "C", "ABCDEFGHIJK", "", 42]) {
    assertThrows(() => v2.launchSymbolV2(bad), ApiError, "Ticker: 2–10 letters (A–Z) or digits");
  }
  assertThrows(() => v2.launchSymbolV2("usdc"), ApiError, "looks like another token's");
  reset();
  const err = await rejects(() => v2.buildLaunchV2(ME, { action: "create", name: "Café", symbol: "CAFÉ" }));
  assertEquals([err.status, err.code, calls], [400, "bad_symbol", []]);
});

Deno.test("refusals: a v2 code names its contract and error (V10), with the stable code where there is one", () => {
  assertEquals(v2.v2ErrorOf("HostError: Error(Contract, #10)\n... Error(Contract, #10114)"), { origin: 1, code: 10_114 });
  assertEquals(v2.v2ErrorOf("HostError: Error(Contract, #10)"), null);
  assertEquals(v2.failureOf("Error(Contract, #11003)"), { origin: 10, code: 11_003 });
  assertEquals(v2.failureOf("Error(Contract, #409)"), { origin: 0, code: 409 });
  assertEquals(v2.failureOf("HostError: Error(Budget, ExceededLimit)"), { origin: 99, code: 5 });
  const raw = contractError(10_114).error;
  const slip = v2.v2Refusal(new ApiError(422, "simulation_failed", "x", { raw })) as InstanceType<typeof ApiError>;
  assertEquals([slip.status, slip.code, slip.message], [422, "simulation_failed", "The price moved past your limit. Nothing was sent."]);
  assertEquals(slip.detail, { contractCode: "launch.slippage", contractError: { origin: 1, code: 10_114, name: "SlippageExceeded", contract: "launchpad-v2" }, raw });
  const locked = v2.v2Refusal(new ApiError(422, "simulation_failed", "x", { raw: contractError(10_201).error })) as InstanceType<typeof ApiError>;
  assertEquals([locked.message, (locked.detail as any).contractError.name, "contractCode" in (locked.detail as any)], ["The contract refused this (TransferLocked).", "TransferLocked", false]);
  const unknown = v2.v2Refusal(new ApiError(422, "simulation_failed", "x", { raw: contractError(10_111).error })) as InstanceType<typeof ApiError>;
  assertEquals([unknown.status, unknown.code], [404, "not_found"]);
});

// ------------------------------------------------------------------------------------------------ economics

Deno.test("economics: the 10 XLM fee booked, venues, per-quote rules, durations, the harvest split, the floor and the terms", async () => {
  reset((w) => {
    w.venues = [SOROSWAP, AQUARIUS, QA_VENUE];
    // A venue-locked quote: its allowlist leaves the Soroswap fallback out (testnet-qa's QA asset is set up so).
    w.quotes[USDC] = { ...w.quotes[USDC], allowed: [2], fallback: 0 };
  });
  const e = (await v2.launchpadV2Economics())!;
  assertEquals(e.launchFee, { asset: "XLM", contract: XLM, amount: "100000000", booked: true });
  assertEquals([e.contract, e.generation, e.treasury, e.locker, e.launchesEnabled], [PAD, 2, TREASURY, LOCKER, true]);
  // Aquarius is off on this deployment (O7): no venue for it, and no float.
  assertEquals(e.venues.map((v) => [v.id, v.kind, v.name]), [[0, "Soroswap", "Soroswap"], [2, "QaFail", "the QA test venue"]]);
  assertEquals(e.aquariusFloat, null);
  const [xlm, usdc] = e.quotes;
  assertEquals([xlm.asset, xlm.venuesAllowed, xlm.fallbackVenue, xlm.venueLocked, xlm.defaultVenue], ["XLM", [], 0, false, 0]);
  assertEquals([usdc.asset, usdc.venuesAllowed, usdc.fallbackVenue, usdc.venueLocked, usdc.defaultVenue], ["USDC", [2], 0, true, 2]);
  assertEquals(e.durations, {
    grace: 3_600,
    fallbackDelay: 3_600,
    rescueAdmin: 604_800,
    rescuePublic: 2_592_000,
    lockedFallback: 86_400,
    takeoverDelay: 259_200,
    takeoverWindow: 259_200,
    timelock: 172_800,
    timelockWindow: 604_800,
    harvestInterval: 3_600,
  });
  assertEquals(e.harvest, {
    intervalSecs: 3_600,
    roundCapBps: 50,
    harvestBps: 10_000,
    split: { protocolBps: 5_000, creatorOrHoldersBps: 5_000 },
    splitPinnedPerLaunch: true,
    sides: ["quote", "token"],
    holdersPaidIn: ["quote", "token"],
    treasuryLaunchTokens: "held",
  });
  assertEquals(e.exclusionFloor, { minPoolTokens: "10000000000", minPendingQuote: "1000000", minPendingTokens: "10000000000" });
  // The terms are preview_launch_terms' own: by value, with the durations.
  assertEquals(xlm.terms, v2.termsOf(scValToNative(termsSv(XLM, 0) as xdr.ScVal)));
  assertEquals([xlm.terms!.launchFee, xlm.terms!.venue.name, xlm.terms!.durations.fallbackDelay, xlm.terms!.durations.harvestInterval], ["100000000", "Soroswap", 3_600, 3_600]);
  assertEquals([usdc.terms!.venue.kind, usdc.terms!.fallback.kind, usdc.terms!.venueLocked], ["QaFail", "Soroswap", true]);
  assert(!("admin" in e) && !JSON.stringify(e).includes(G(2)), "the admin is never served");
});

Deno.test("economics: kept 5 minutes; the last read served when RPC fails; a quote that is off has no terms", async () => {
  reset((w) => (w.quotes[USDC].enabled = false));
  const first = (await v2.launchpadV2Economics(undefined, 1_000_000))!;
  assertEquals([first.quotes[1].enabled, first.quotes[1].terms, first.quotes[1].defaultVenue], [false, null, null]);
  const reads = calls.length;
  await v2.launchpadV2Economics(undefined, 1_000_000 + v2.ECONOMICS_V2_TTL_MS - 1);
  assertEquals(calls.length, reads);
  world.down = true;
  assertEquals(await v2.launchpadV2Economics(undefined, 1_000_000 + v2.ECONOMICS_V2_TTL_MS), first);
  v2.forgetLaunchV2Reads();
  const err = await rejects(() => v2.launchpadV2Economics(undefined, 1_000_000));
  assertEquals([err.status, err.code], [502, "rpc_unavailable"]);
});

// ------------------------------------------------------------------------------------------------ XLM for a launch

/** balance − Max: what a launch at Max leaves behind. */
const leftBehind = (balance: string, max: string) => BigInt(balance.replace(".", "")) - BigInt(max);

Deno.test("Max for an XLM quote leaves exactly the minimum balance, the 10 XLM fee, the network fee and the buffer (no subentries)", async () => {
  reset();
  const p = await v2.launchPreviewV2(ME, { quote: "XLM" });
  const fees = TX_FEE(SIM_FEE);
  assertEquals(p.xlm, { balance: "1000000000", minBalance: "10000000", sellingLiabilities: "0", launchFee: "100000000", fees: fees.toString(), buffer: "5000000", spendable: (1_000_000_000n - 10_000_000n - 100_000_000n - fees - 5_000_000n).toString() });
  assertEquals(leftBehind("100.0000000", p.maxInitialBuy), 10_000_000n + 100_000_000n + fees + v2.LAUNCH_XLM_BUFFER);
  assertEquals([p.launchFee, p.venue.name, p.shortfall, p.terms.durations.fallbackDelay], [{ asset: "XLM", amount: "100000000", booked: true, to: PAD }, "Soroswap", null, 3_600]);
});

Deno.test("Max with subentries and an open offer selling XLM keeps both back (V12), and create at Max passes while one more stroop doesn't", async () => {
  reset((w) => (w.account = { xlm: "100.0000000", selling: "25.0000000", subentries: 3, sponsoring: 1 }));
  const p = await v2.launchPreviewV2(ME, { quote: "XLM", name: "E2E Cat", symbol: "ECAT" });
  const fees = TX_FEE(SIM_FEE);
  // (2 + 3 + 1) × 0.5 XLM.
  assertEquals([p.xlm.minBalance, p.xlm.sellingLiabilities], ["30000000", "250000000"]);
  assertEquals(leftBehind("100.0000000", p.maxInitialBuy), 30_000_000n + 250_000_000n + 100_000_000n + fees + v2.LAUNCH_XLM_BUFFER);
  const spec = (initialBuy: bigint) => ({ kind: v2.LAUNCH_V2_STEPS.create, quote: XLM, venue: 0, name: "E2E Cat", symbol: "ECAT", uri: "", creatorFeeBps: 100, holderSharing: true, recipient: null, exempt: [], initialBuy: initialBuy.toString(), minOut: "0", nonce: "7" });
  const atMax = await v2.launchCreateStepV2(ME, spec(BigInt(p.maxInitialBuy)));
  assertEquals(atMax.intent.spend, { [XLM]: (100_000_000n + BigInt(p.maxInitialBuy)).toString() });
  const err = await rejects(() => v2.launchCreateStepV2(ME, spec(BigInt(p.maxInitialBuy) + 1n)));
  assertEquals([err.status, err.code, (err.detail as any).shortfall], [409, "insufficient_xlm", "1"]);
  assertMatch(err.message, /^Not enough XLM: 0\.0000001 XLM more covers the 10 XLM launch fee, your first buy, the network fee and the XLM your account keeps\.$/);
});

Deno.test("Max is priced at Max: a buy that completes the curve costs more to run, and create at that Max still passes", async () => {
  // A buy past the threshold runs the clamp and emits `complete`: a bigger resource fee than a one-unit buy.
  reset((w) => (w.launchFee_ = (buy) => (buy > 1_000_000_000n ? SIM_FEE + 200_000 : SIM_FEE)));
  world.account = { xlm: "1000.0000000" };
  const p = await v2.launchPreviewV2(ME, { quote: "XLM" });
  assertEquals(p.xlm.fees, TX_FEE(SIM_FEE + 200_000).toString());
  const built = await v2.launchCreateStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.create, quote: XLM, venue: 0, name: "N".repeat(32), symbol: "S".repeat(10), uri: "", creatorFeeBps: 0, holderSharing: true, recipient: null, exempt: [], initialBuy: p.maxInitialBuy, minOut: "0", nonce: "9" });
  assertEquals(BigInt(built.tx.fee), TX_FEE(SIM_FEE + 200_000));
});

Deno.test("insufficient_xlm: short before any fee (the fee's estimate added), or only by the network fee (exact)", async () => {
  // 11 XLM: 1 XLM minimum balance, then the 10 XLM fee leaves nothing for the buffer.
  reset((w) => (w.account = { xlm: "11.0000000" }));
  const spec = { kind: v2.LAUNCH_V2_STEPS.create, quote: USDC, venue: 0, name: "E2E Cat", symbol: "ECAT", uri: "", creatorFeeBps: 0, holderSharing: true, recipient: null, exempt: [], initialBuy: "0", minOut: "0", nonce: "7" };
  const early = await rejects(() => v2.launchCreateStepV2(ME, spec));
  // 0.5 XLM short of the buffer, plus launch_create's default estimate (fees.ts DEFAULT_ESTIMATES): 1 XLM.
  assertEquals([early.code, (early.detail as any).shortfall], ["insufficient_xlm", "15000000"]);
  assert(!calls.includes("launch"), "refused before simulating");
  // 11.6 XLM: the launch fits before the network fee, which it then can't pay with the buffer kept.
  reset((w) => (w.account = { xlm: "11.6000000" }));
  const late = await rejects(() => v2.launchCreateStepV2(ME, spec));
  assertEquals([late.code, (late.detail as any).shortfall], ["insufficient_xlm", (TX_FEE(SIM_FEE) - 1_000_000n).toString()]);
  assertEquals([(late.detail as any).minBalance, (late.detail as any).launchFee, (late.detail as any).buffer], ["10000000", "100000000", "5000000"]);
  // The preview says so too: nothing to buy with, and what is missing.
  const p = await v2.launchPreviewV2(ME, { quote: "XLM" });
  assertEquals([p.maxInitialBuy, p.shortfall], ["0", (TX_FEE(SIM_FEE) - 1_000_000n).toString()]);
});

Deno.test("Max for another quote is its balance; the XLM check still holds back the fee", async () => {
  reset((w) => (w.account = { xlm: "50.0000000", usdc: "12.5000000" }));
  const p = await v2.launchPreviewV2(ME, { quote: "USDC" });
  assertEquals([p.quote.code, p.quoteBalance, p.maxInitialBuy], ["USDC", "125000000", "125000000"]);
  assertEquals(BigInt(p.xlm.spendable), 500_000_000n - 10_000_000n - 100_000_000n - TX_FEE(SIM_FEE) - 5_000_000n);
});

// ------------------------------------------------------------------------------------------------ create

const CREATE = {
  kind: v2.LAUNCH_V2_STEPS.create,
  quote: XLM,
  venue: 0,
  name: "E2E Cat",
  symbol: "ECAT",
  uri: "",
  creatorFeeBps: 100,
  holderSharing: true,
  recipient: null,
  exempt: [G(9)],
  initialBuy: "500000000",
  minOut: "11880000000000",
  nonce: "18446744073709551615",
};

Deno.test("create: the 10 XLM fee to the launchpad plus the XLM buy in spend, the terms by value, the venue, terms and durations shown", async () => {
  reset();
  const built = await v2.launchCreateStepV2(ME, CREATE);
  assertStep(built, PAD, "launch");
  assertEquals(built.intent.spend, { [XLM]: "600000000" });
  assertEquals(built.intent.receive, { [PREDICTED]: "11880000000000" });
  const [creator, params, expected] = callOf(built.tx).args as [string, any, any];
  assertEquals(creator, ME);
  assertEquals(params, {
    quote: XLM,
    name: "E2E Cat",
    symbol: "ECAT",
    uri: "",
    creator_fee_bps: 100,
    venue: 0,
    holder_sharing: true,
    creator_fee_recipient: null,
    snipe_exempt: [G(9)],
    initial_buy: 500_000_000n,
    min_tokens_out: 11_880_000_000_000n,
    nonce: 18_446_744_073_709_551_615n,
  });
  // `expected` is exactly what preview_launch_terms answered.
  const arg2 = (built.tx.operations[0] as any).func.invokeContract().args()[2] as xdr.ScVal;
  assertEquals(arg2.toXDR("base64"), (termsSv(XLM, 0) as xdr.ScVal).toXDR("base64"));
  assertEquals(expected.launch_fee, 100_000_000n);
  const d = built.intent.display!;
  assertEquals([d.token, d.launchFee, d.launchFeeAsset, d.launchFeeTo, d.launchFeeBooked], [PREDICTED, "100000000", "XLM", PAD, true]);
  assertEquals([d.venue, d.venueId, d.fallbackVenue, d.venueLocked, d.holderSharing, d.exemptCount, d.recipient], ["Soroswap", 0, "Soroswap", false, true, 1, ME]);
  assertEquals([d.feeBps, d.protocolShareBps, d.creatorFeeBps, d.snipeSchedule, d.snipeStepSecs, d.phantom, d.threshold], [100, 5_000, 100, "9800,2500,300,30", 5, "20000000000", "43245553200"]);
  assertEquals([d.grace, d.fallbackDelay, d.rescueAdmin, d.rescuePublic, d.lockedFallback, d.takeoverDelay, d.takeoverWindow, d.harvestInterval], [3_600, 3_600, 604_800, 2_592_000, 86_400, 259_200, 259_200, 3_600]);
  assertEquals((built.intent as any).terms.durations.fallbackDelay, 3_600);
  assertEquals(built.intent.summary, "Launch ECAT on Soroswap for a 10 XLM fee and buy with 50 XLM");
  assertEquals((built as any).stepKind, "launch_create");
});

Deno.test("create in USDC: the XLM fee and the USDC buy are each declared; a recipient and no buy", async () => {
  reset((w) => (w.account = { xlm: "100.0000000", usdc: "100.0000000" }));
  const usdc = await v2.launchCreateStepV2(ME, { ...CREATE, quote: USDC });
  assertStep(usdc, PAD, "launch");
  assertEquals(usdc.intent.spend, { [XLM]: "100000000", [USDC]: "500000000" });
  const noBuy = await v2.launchCreateStepV2(ME, { ...CREATE, initialBuy: "0", minOut: "0", recipient: NEXT });
  assertStep(noBuy, PAD, "launch");
  assertEquals([noBuy.intent.spend, noBuy.intent.receive, noBuy.intent.display!.recipient], [{ [XLM]: "100000000" }, undefined, NEXT]);
  assertEquals((callOf(noBuy.tx).args[1] as any).creator_fee_recipient, NEXT);
});

Deno.test("create refuses terms the app doesn't pin: a fee above 10 XLM or not in XLM, another locker, other durations, an unpinned executor", async () => {
  for (const [change, field] of [
    [(w: World) => (w.launchFee = 100_000_001n), "launchFee"],
    [(w: World) => (w.terms.feeAsset = USDC), "feeAsset"],
    [(w: World) => (w.terms.locker = C(30)), "locker"],
    [(w: World) => (w.terms.harvestInterval = 60), "durations.harvestInterval"],
    [(w: World) => (w.terms.executor = C(31)), "venue"],
  ] as const) {
    reset(change);
    const err = await rejects(() => v2.launchCreateStepV2(ME, CREATE));
    assertEquals([err.status, err.code, (err.detail as any).field], [409, "terms_unpinned", field]);
    assert(!calls.includes("launch"));
  }
});

Deno.test("create's plan: the venue asked for must be open to the quote; the creator fee within the terms' cap", async () => {
  reset();
  const venue = await rejects(() => v2.buildLaunchV2(ME, { action: "create", name: "E2E Cat", symbol: "ECAT", quote: "XLM", venue: 1 }));
  assertEquals([venue.code, venue.message], ["bad_venue", "That venue isn't open to launches in XLM."]);
  const fee = await rejects(() => v2.buildLaunchV2(ME, { action: "create", name: "E2E Cat", symbol: "ECAT", quote: "XLM", creatorFeeBps: 1_001 }));
  assertEquals([fee.code, fee.message], ["bad_fee", "Creator fee: 0–10%."]);
  const quote = await rejects(() => v2.buildLaunchV2(ME, { action: "create", name: "E2E Cat", symbol: "ECAT", quote: "BUSDC" }));
  assertEquals(quote.code, "bad_quote");
  const exempt = await rejects(() => v2.buildLaunchV2(ME, { action: "create", name: "E2E Cat", symbol: "ECAT", exempt: ["MAAAA"] }));
  assertEquals(exempt.code, "bad_address");
});

Deno.test("the preview refuses a malformed recipient, exemption or creator fee as create does (400), simulating nothing", async () => {
  for (const [input, code] of [
    [{ recipient: "abc" }, "bad_address"],
    [{ recipient: ME.slice(0, -1) }, "bad_address"],
    [{ exempt: ["abc"] }, "bad_address"],
    [{ exempt: G(9) }, "bad_arg"],
    [{ exempt: Array.from({ length: 33 }, (_, i) => G(40 + i)) }, "bad_arg"],
    [{ creatorFeeBps: -1 }, "bad_fee"],
    [{ creatorFeeBps: 1.5 }, "bad_fee"],
    [{ creatorFeeBps: 1_001 }, "bad_fee"],
  ] as const) {
    reset();
    const err = await rejects(() => v2.launchPreviewV2(ME, { quote: "XLM", ...input } as any));
    assertEquals([err.status, err.code], [400, code], JSON.stringify(input).slice(0, 80));
    assert(!calls.includes("launch"), "nothing simulated");
  }
  // Well-formed ones are priced as given.
  reset();
  const p = await v2.launchPreviewV2(ME, { quote: "XLM", recipient: NEXT, exempt: [G(9), G(9)], creatorFeeBps: 1_000 });
  assertEquals(p.maxInitialBuy, p.xlm.spendable);
});

// ------------------------------------------------------------------------------------------------ trades and refunds

Deno.test("buy and sell (Curve phase) act for the user and bind the client's minimum", async () => {
  reset();
  const buy = await v2.launchBuyStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.buy, token: TOKEN, amount: "500000000", minOut: "11880000000000" });
  assertStep(buy, PAD, "buy");
  assertEquals([buy.intent.spend, buy.intent.receive, callOf(buy.tx).args], [{ [XLM]: "500000000" }, { [TOKEN]: "11880000000000" }, [ME, TOKEN, 500_000_000n, 11_880_000_000_000n]]);
  const sell = await v2.launchSellStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.sell, token: TOKEN, amount: "1000000000000", minOut: "49000000" });
  assertStep(sell, PAD, "sell");
  assertEquals([sell.intent.spend, sell.intent.receive], [{ [TOKEN]: "1000000000000" }, { [XLM]: "49000000" }]);
});

Deno.test("refund (Rescued): the burned launch tokens are the outflow, at the fixed rate, with no fees", async () => {
  // 40 XLM raised over 400,000,000 tokens: 0.0000001 XLM per token, the same for every holder.
  reset((w) => (w.curve = { ...w.curve, phase: 3, stuckSince: nowS() - 31 * 86_400, completedAt: nowS() - 32 * 86_400, refundQuote: 400_000_000n, refundSupply: 4_000_000_000_000_000n }));
  const built = await v2.launchRefundStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.refund, token: TOKEN, amount: "1000000000000" });
  assertStep(built, PAD, "refund");
  assertEquals(built.intent.spend, { [TOKEN]: "1000000000000" });
  assertEquals(built.intent.display, { generation: 2, token: TOKEN, symbol: "ECAT", quote: "XLM", amount: "1000000000000", quoteOut: "100000", rate: "0.0000001", burned: true, fees: "0" });
  assertEquals(built.intent.summary, "Refund: 0.01 XLM for 100000 ECAT, no fees");
  assertEquals(await v2.quoteTradeV2(ME, TOKEN, "refund", 1_000_000_000_000n), { side: "refund", quoteOut: "100000", fees: "0", rate: "0.0000001" });
  // Before rescue the contract refuses, named.
  reset();
  const early = await rejects(() => v2.launchRefundStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.refund, token: TOKEN, amount: "1" }));
  assertEquals([early.code, (early.detail as any).contractError.name], ["simulation_failed", "WrongPhase"]);
});

// ------------------------------------------------------------------------------------------------ status

const STUCK = (since: number) => (w: World) => (w.curve = { ...w.curve, phase: 1, completedAt: since - 3_600, stuckSince: since });

Deno.test("status: the times, a recorded failure named, the actions open now", async () => {
  const since = nowS() - 2 * HOUR;
  reset(STUCK(since));
  const s = await v2.launchStatusV2(TOKEN, { failure: { origin: 3, code: 10_304 } });
  const at = (secs: number) => new Date(secs * 1000).toISOString();
  assertEquals([s.phase, s.stuck, s.stuckSince, s.markStuckAt, s.fallbackAt, s.rescueAdminAt, s.rescuePublicAt], [
    "completed",
    true,
    at(since),
    at(since),
    at(since + 3_600),
    at(since + 604_800),
    at(since + 2_592_000),
  ]);
  assertEquals(s.failure, { origin: 3, code: 10_304, name: "LiquidityTooLow", contract: "exec-soroswap", source: "recorded" });
  assertEquals(s.actions, { buy: false, sell: false, graduate: true, graduateFallback: true, markStuck: false, rescue: false, refund: false });
  assertEquals([s.venue.name, s.fallback.name, s.refund], ["Soroswap", "Soroswap", null]);
  assert(!calls.includes("graduate"), "a recorded failure needs no simulation");
});

Deno.test("status: without a recorded failure, what graduate fails with now: a recoverable one, an abort, the host's budget", async () => {
  for (const [graduate, failure] of [
    [vec([xdr.ScVal.scvSymbol("Failed"), struct({ origin: u32(4), code: u32(10_404) })]), { origin: 4, code: 10_404, name: "PaymentUnavailable", contract: "exec-aquarius", source: "simulated" }],
    [contractError(10_134), { origin: 1, code: 10_134, name: "GraduationInvalid", contract: "launchpad-v2", source: "simulated" }],
    [{ error: "HostError: Error(Budget, ExceededLimit)" }, { origin: 99, code: 5, name: "ExceededLimit", contract: "host", source: "simulated" }],
    [vec([xdr.ScVal.scvSymbol("Graduated"), addr(POOL)]), null],
  ] as const) {
    reset(STUCK(nowS() - 2 * HOUR));
    world.graduate = graduate as World["graduate"];
    assertEquals((await v2.launchStatusV2(TOKEN)).failure, failure);
  }
});

Deno.test("status: a rescued launch's fixed refund rate; a venue-locked launch's later fallback", async () => {
  reset((w) => (w.curve = { ...w.curve, phase: 3, refundQuote: 432_455_532n, refundSupply: 9_000_000_000_000_000n, refunded: 1_000n }));
  const rescued = await v2.launchStatusV2(TOKEN);
  assertEquals(rescued.refund, { quote: "432455532", supply: "9000000000000000", refunded: "1000", rate: "0.000000048050614666" });
  assertEquals([rescued.actions.refund, rescued.actions.buy, rescued.failure], [true, false, null]);
  const since = nowS() - 2 * HOUR;
  reset((w) => {
    STUCK(since)(w);
    w.launch = { ...w.launch, venue: QA_VENUE, venueLocked: true };
  });
  const locked = await v2.launchStatusV2(TOKEN, { probe: false });
  assertEquals([locked.fallbackAt, locked.actions.graduateFallback, locked.venue.name], [new Date((since + 86_400) * 1000).toISOString(), false, "the QA test venue"]);
});

Deno.test("live reads: rewards in both assets, the recipient, a pending takeover and owed fees", async () => {
  const now = nowS();
  reset((w) => {
    w.curve = { ...w.curve, phase: 2, pool: POOL, creatorFees: 3_900_000n };
    w.recipient = NEXT;
    w.takeover = { new: G(11), effective: now - 60, expires: now + 3_600 };
    w.owed = 1_200_000n;
    w.pending = [250_000n, 7_000_000_000n];
    w.queued = [10_000n, 0n, 5_300_200];
  });
  const s = await v2.launchStateV2(TOKEN, ME);
  assertEquals(s.status.graduatedVenue?.name, "Soroswap");
  assertEquals([s.quote, s.recipient, s.creatorFees], [{ id: "XLM", code: "XLM", contract: XLM }, NEXT, "3900000"]);
  assertEquals(s.pendingTakeover, { new: G(11), effectiveAt: new Date((now - 60) * 1000).toISOString(), expiresAt: new Date((now + 3_600) * 1000).toISOString(), state: "open" });
  assertEquals(s.rewards, { sharing: true, eligible: "5000000000000000", queuedQuote: "10000", queuedToken: "0", releasableFromLedger: 5_300_200, pendingQuote: "250000", pendingToken: "7000000000" });
  assertEquals(s.you, { isRecipient: false, creatorOwed: "1200000" });
  world.launch.sharing = false;
  world.queued = [0n, 0n, 0];
  const off = await v2.launchStateV2(TOKEN, null);
  assertEquals([off.rewards.sharing, off.rewards.eligible, off.rewards.releasableFromLedger, off.rewards.pendingQuote, off.you], [false, null, null, null, null]);
});

// ------------------------------------------------------------------------------------------------ graduation paths

Deno.test("graduate_fallback is not offered before fallback_at, and is from it; mark_stuck and the public rescue wait for theirs", async () => {
  const since = nowS() - 10 * 60;
  reset(STUCK(since));
  const early = await rejects(() => v2.launchGraduateFallbackStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.graduate_fallback, token: TOKEN }));
  assertEquals([early.status, early.code, (early.detail as any).availableAt], [409, "not_available", new Date((since + 3_600) * 1000).toISOString()]);
  assertEquals((await v2.launchStatusV2(TOKEN, { probe: false })).actions.graduateFallback, false);
  assert(!calls.includes("graduate_fallback"), "nothing simulated");
  const rescue = await rejects(() => v2.launchRescueStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.rescue, token: TOKEN }));
  assertEquals((rescue.detail as any).availableAt, new Date((since + 2_592_000) * 1000).toISOString());

  reset(STUCK(nowS() - 3_601));
  const open = await v2.launchGraduateFallbackStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.graduate_fallback, token: TOKEN });
  assertStep(open, PAD, "graduate_fallback");
  assertEquals([open.intent.spend, callOf(open.tx).args], [{}, [TOKEN]]);

  // Completed an hour and a bit ago, never stuck: mark_stuck is open, the fallback isn't.
  reset((w) => (w.curve = { ...w.curve, phase: 1, completedAt: nowS() - 3_700 }));
  assertStep(await v2.launchMarkStuckStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.mark_stuck, token: TOKEN }), PAD, "mark_stuck");
  assertEquals((await rejects(() => v2.launchGraduateFallbackStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.graduate_fallback, token: TOKEN }))).code, "not_available");
  reset(STUCK(nowS() - 2_592_001));
  assertStep(await v2.launchRescueStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.rescue, token: TOKEN }), PAD, "rescue");
});

Deno.test("labels name the launch's own venue: never Soroswap for an Aquarius launch", async () => {
  reset((w) => {
    w.launch = { ...w.launch, venue: AQUARIUS, fallback: SOROSWAP };
    w.curve = { ...w.curve, phase: 1, completedAt: nowS() - 60 };
  });
  const grad = await v2.launchGraduateStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.graduate, token: TOKEN });
  assertStep(grad, PAD, "graduate");
  assertEquals([grad.intent.summary, grad.intent.display!.venue, grad.intent.display!.venueKind], ["Graduate ECAT to Aquarius 0.3%", "Aquarius 0.3%", "Aquarius"]);
  assert(!JSON.stringify([grad.intent.summary, grad.intent.display]).includes("Soroswap"));
  // The plan's own label, as the review lists its steps.
  const plan = await v2.buildLaunchV2(ME, { action: "graduate", token: TOKEN });
  assertEquals([plan.planId, plan.kind, plan.steps.map((s) => s.label)], [PLAN_ID, "launch_graduate", ["Graduate ECAT to Aquarius 0.3%"]]);
  assertEquals(v2.venueName("Aquarius", 100), "Aquarius 1%");
  // The fallback is Soroswap, and says so.
  reset((w) => {
    w.launch = { ...w.launch, venue: AQUARIUS, fallback: SOROSWAP };
    STUCK(nowS() - 2 * HOUR)(w);
  });
  const fallback = await v2.launchGraduateFallbackStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.graduate_fallback, token: TOKEN });
  assertEquals(fallback.intent.summary, "Graduate ECAT to Soroswap, its fallback venue");
});

// ------------------------------------------------------------------------------------------------ claims

Deno.test("claims: creator fees to the current recipient (anyone's to send), owed fees and holder rewards to the user", async () => {
  reset((w) => {
    w.curve.creatorFees = 3_900_000n;
    w.recipient = NEXT;
    w.owed = 1_200_000n;
    w.pending = [250_000n, 7_000_000_000n];
  });
  const claim = await v2.launchClaimStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.claim, token: TOKEN });
  assertStep(claim, PAD, "claim_creator_fees");
  assertEquals([claim.intent.spend, claim.intent.display!.to, claim.intent.display!.amount], [{}, NEXT, "3900000"]);
  const owed = await v2.launchClaimOwedStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.claim_owed, asset: XLM });
  assertStep(owed, PAD, "claim_owed");
  assertEquals([callOf(owed.tx).args, owed.intent.display!.amount, owed.intent.summary], [[ME, XLM], "1200000", "Claim 0.12 XLM of creator fees owed to you"]);
  const rewards = await v2.launchClaimRewardsStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.claim_rewards, token: TOKEN });
  assertStep(rewards, TOKEN, "claim");
  assertEquals([callOf(rewards.tx).args, rewards.intent.summary], [[ME], "Claim 0.025 XLM and 700 ECAT of ECAT holder rewards"]);

  reset();
  for (const [build, contract] of [[v2.launchClaimStepV2, "launchpad-v2"], [v2.launchClaimOwedStepV2, "launchpad-v2"], [v2.launchClaimRewardsStepV2, "launch-token-v2"]] as const) {
    const err = await rejects(() => build(ME, { kind: "x", token: TOKEN, asset: XLM }));
    assertEquals([err.code, (err.detail as any).contractCode, (err.detail as any).contractError.contract], ["simulation_failed", "launch.nothing_to_claim", contract]);
  }
});

// ------------------------------------------------------------------------------------------------ harvests and recipient changes

/** A pool of 4,000,000 token units and 1,000,000 quote units (√k 2,000,000) whose LP the locker holds all but the
 *  minimum-liquidity lock of, and a principal that leaves `growth` above it. */
const POSITION = (growth: bigint): import("../../supabase/functions/_shared/launchpad_v2.ts").PoolPosition => ({
  reserveToken: 4_000_000n,
  reserveQuote: 1_000_000n,
  totalLp: 2_000_000n,
  lp: 1_999_000n,
  principal: 1_999_000n - growth,
});

Deno.test("a harvest round as the locker runs it: all the growth up to 0.5% of the position, LP burned rounding down", () => {
  assertEquals(v2.harvestRound(POSITION(9_000n)), { current: 1_999_000n, growth: 9_000n, cap: 9_995n, take: 9_000n, lpToBurn: 8_999n, tokenOut: 17_998n, quoteOut: 4_499n });
  const capped = v2.harvestRound(POSITION(99_000n));
  assertEquals([capped.take, capped.lpToBurn], [9_995n, 9_994n]);
  assertEquals(v2.harvestRound(POSITION(0n)), { current: 1_999_000n, growth: 0n, cap: 9_995n, take: 0n, lpToBurn: 0n, tokenOut: 0n, quoteOut: 0n });
  // The principal never moves for a launch, and what one round leaves is the growth less what it took.
  const after = v2.afterRound(POSITION(99_000n), capped);
  assertEquals([after.principal, after.lp, after.totalLp], [1_900_000n, 1_989_006n, 1_990_006n]);
  assert(v2.harvestRound(after).growth <= 99_000n - 9_995n + 1n);
});

Deno.test("the backlog (V7): none when one round takes the growth; above one round's cap, the recipient's residual and the rounds to drain it", () => {
  const at = 1_800_000_000;
  assertEquals(v2.harvestBacklog(POSITION(9_000n), at, 3_600, 5_000), null);
  const b = v2.harvestBacklog(POSITION(99_000n), at, 3_600, 5_000)!;
  // 99,000 of √k value is 98,999 LP units: 197,998 tokens and 49,499 of the quote at today's reserves.
  assertEquals([b.growthToken, b.growthQuote], ["197998", "49499"]);
  // The new recipient gets what the treasury's 50% leaves of each side, the remainder as the locker pays its last
  // payee: 98,999 tokens and 24,750 of the quote.
  assertEquals([b.residualToken, b.residualQuote], ["98999", "24750"]);
  // The launch's own pinned split, not the launchpad's current one (V1).
  const pinned = v2.harvestBacklog(POSITION(99_000n), at, 3_600, 2_000)!;
  assertEquals([pinned.residualToken, pinned.residualQuote, pinned.roundsToDrain], ["158399", "39600", b.roundsToDrain]);
  assertEquals(b.nextHarvestAt, new Date(at * 1000).toISOString());
  assertEquals(b.drainedBy, new Date((at + (b.roundsToDrain - 1) * 3_600) * 1000).toISOString());
  // Exactly that many rounds drain it with no further volume.
  let p = POSITION(99_000n);
  for (let i = 0; i < b.roundsToDrain; i++) p = v2.afterRound(p, v2.harvestRound(p));
  assertEquals(v2.harvestRound(p).lpToBurn, 0n);
  assert(b.roundsToDrain > 1 && b.roundsToDrain <= 11, `${b.roundsToDrain} rounds of at most 0.5% each for 5% of the position`);
});

/** A graduated launch whose harvests pay its recipient (holder sharing off), harvested last at `lastHarvest`. */
const GRADUATED = (lastHarvest: number, growth: bigint) => (w: World) => {
  w.launch.sharing = false;
  w.curve = { ...w.curve, phase: 2, pool: POOL };
  w.position = { lp: 1_999_000n, principal: 1_999_000n - growth, lastHarvest, kind: 0 };
};

Deno.test("recipient transfer and execute on a graduated launch without sharing: the harvest first when the interval allows, and its backlog", async () => {
  const now = nowS();
  reset(GRADUATED(now - 3_601, 99_000n));
  const plan = await v2.recipientSteps(ME, "recipient_transfer", TOKEN, NEXT);
  assertEquals(plan.steps.map((s) => s.spec), [{ kind: v2.LAUNCH_V2_STEPS.harvest, token: TOKEN, pool: POOL }, { kind: v2.LAUNCH_V2_STEPS.recipient_transfer, token: TOKEN, to: NEXT }]);
  assertEquals(plan.steps.map((s) => s.label), ["Collect ECAT's pool fees first", `Hand ECAT's creator fees to ${NEXT.slice(0, 4)}…${NEXT.slice(-4)}`]);
  // What the harvest step leaves above one round's cap still crosses the change.
  const p = POSITION(99_000n);
  assertEquals(plan.harvestBacklog, v2.harvestBacklog(v2.afterRound(p, v2.harvestRound(p)), now + 3_600, 3_600, 5_000));
  assert(plan.harvestBacklog!.roundsToDrain > 1);

  // Under one round's cap: the harvest step still goes first, and nothing is left to report.
  reset(GRADUATED(now - 3_601, 9_000n));
  const small = await v2.recipientSteps(ME, "recipient_transfer", TOKEN, NEXT);
  assertEquals([small.steps.length, small.harvestBacklog], [2, null]);

  // Harvested 10 minutes ago: no harvest step can run; the whole backlog crosses, harvestable from the next interval.
  reset(GRADUATED(now - 600, 99_000n));
  const soon = await v2.recipientSteps(ME, "recipient_transfer", TOKEN, NEXT);
  assertEquals(soon.steps.map((s) => s.spec.kind), [v2.LAUNCH_V2_STEPS.recipient_transfer]);
  assertEquals(soon.harvestBacklog, v2.harvestBacklog(POSITION(99_000n), now - 600 + 3_600, 3_600, 5_000));

  // A takeover executes inside its window, the harvest first too.
  reset((w) => {
    GRADUATED(now - 3_601, 99_000n)(w);
    w.recipient = G(12);
    w.takeover = { new: NEXT, effective: now - 60, expires: now + 600 };
  });
  const takeover = await v2.recipientSteps(ME, "recipient_execute", TOKEN, null);
  assertEquals(takeover.steps.map((s) => s.spec), [{ kind: v2.LAUNCH_V2_STEPS.harvest, token: TOKEN, pool: POOL }, { kind: v2.LAUNCH_V2_STEPS.recipient_execute, token: TOKEN }]);

  // On the curve there is nothing to harvest.
  reset();
  const curve = await v2.recipientSteps(ME, "recipient_transfer", TOKEN, NEXT);
  assertEquals([curve.steps.length, curve.harvestBacklog], [1, null]);
});

Deno.test("recipient changes on a graduated launch with holder sharing (the app's default): no harvest step and no backlog", async () => {
  // Its harvests pay the treasury and the holders whoever the recipient is (harvest_payees), so the change moves no
  // pool fees: the same position that needs a harvest and leaves a backlog without sharing.
  const now = nowS();
  const sharing = (w: World) => {
    GRADUATED(now - 3_601, 99_000n)(w);
    w.launch.sharing = true;
  };
  reset(sharing);
  const transfer = await v2.recipientSteps(ME, "recipient_transfer", TOKEN, NEXT);
  assertEquals([transfer.steps.map((s) => s.spec.kind), transfer.harvestBacklog], [[v2.LAUNCH_V2_STEPS.recipient_transfer], null]);
  assert(!calls.includes("position"), "the locker isn't read");
  reset((w) => {
    sharing(w);
    w.recipient = G(12);
    w.takeover = { new: NEXT, effective: now - 60, expires: now + 600 };
  });
  const execute = await v2.recipientSteps(ME, "recipient_execute", TOKEN, null);
  assertEquals([execute.steps.map((s) => s.spec.kind), execute.harvestBacklog], [[v2.LAUNCH_V2_STEPS.recipient_execute], null]);

  reset(sharing);
  const step = await v2.launchRecipientTransferStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_transfer, token: TOKEN, to: NEXT });
  assertStep(step, PAD, "transfer_creator_fee_recipient");
  const d = step.intent.display!;
  assertEquals([(step.intent as any).harvestBacklog, d.holderSharing, d.poolFeesTo, d.backlogQuote, d.backlogToken, d.backlogRounds], [null, true, "holders", null, null, null]);
});

Deno.test("recipient changes: only the current recipient transfers or vetoes; a takeover only inside its window", async () => {
  const now = nowS();
  reset((w) => (w.recipient = NEXT));
  assertEquals((await rejects(() => v2.recipientSteps(ME, "recipient_transfer", TOKEN, G(13)))).message, "Only the coin's current fee recipient can hand the fees on.");
  assertEquals((await rejects(() => v2.launchRecipientCancelStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_cancel, token: TOKEN }))).code, "bad_arg");
  reset((w) => (w.takeover = { new: NEXT, effective: now + 600, expires: now + 4_200 }));
  const early = await rejects(() => v2.recipientSteps(ME, "recipient_execute", TOKEN, null));
  assertEquals([early.code, (early.detail as any).availableAt], ["not_available", new Date((now + 600) * 1000).toISOString()]);
  reset((w) => (w.takeover = { new: NEXT, effective: now - 4_200, expires: now - 600 }));
  assertEquals((await rejects(() => v2.recipientSteps(ME, "recipient_execute", TOKEN, null))).message, "This change's window has closed.");
  reset();
  assertEquals((await rejects(() => v2.recipientSteps(ME, "recipient_execute", TOKEN, null))).message, "There is no pending fee recipient change for this coin.");
});

Deno.test("the recipient change's own step: the intent carries the backlog above one round's cap, and none under it", async () => {
  const now = nowS();
  reset(GRADUATED(now - 600, 99_000n));
  world.curve.creatorFees = 3_900_000n;
  const big = await v2.launchRecipientTransferStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_transfer, token: TOKEN, to: NEXT });
  assertStep(big, PAD, "transfer_creator_fee_recipient");
  assertEquals([callOf(big.tx).args, big.intent.to, big.intent.spend], [[TOKEN, NEXT], NEXT, {}]);
  const backlog = v2.harvestBacklog(POSITION(99_000n), now - 600 + 3_600, 3_600, 5_000)!;
  assertEquals((big.intent as any).harvestBacklog, backlog);
  const d = big.intent.display!;
  assertEquals([d.backlogQuote, d.backlogToken, d.backlogRounds, d.backlogNextAt, d.backlogDrainedBy], [backlog.residualQuote, backlog.residualToken, backlog.roundsToDrain, backlog.nextHarvestAt, backlog.drainedBy]);
  assertEquals([d.currentRecipient, d.newRecipient, d.bookedStay, d.byTakeover], [ME, NEXT, "3900000", false]);
  // The new recipient's part only: the treasury keeps the launch's pinned protocol share of each harvest.
  assertEquals([d.holderSharing, d.poolFeesTo, d.protocolShareBps, BigInt(d.backlogQuote as string) < BigInt(backlog.growthQuote)], [false, "newRecipient", 5_000, true]);

  reset(GRADUATED(now - 600, 9_000n));
  const small = await v2.launchRecipientTransferStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_transfer, token: TOKEN, to: NEXT });
  assertEquals([(small.intent as any).harvestBacklog, small.intent.display!.backlogRounds], [null, null]);

  reset((w) => {
    GRADUATED(now - 600, 99_000n)(w);
    w.recipient = G(12);
    w.takeover = { new: NEXT, effective: now - 60, expires: now + 600 };
  });
  const execute = await v2.launchRecipientExecuteStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_execute, token: TOKEN });
  assertStep(execute, PAD, "execute_recipient_change");
  assertEquals([callOf(execute.tx).args, execute.intent.to, execute.intent.display!.byTakeover, (execute.intent as any).harvestBacklog.roundsToDrain], [[TOKEN], NEXT, true, backlog.roundsToDrain]);
});

Deno.test("the harvest step: the locker's harvest, anyone's to call, its estimate shown; the veto acts for the recipient", async () => {
  const now = nowS();
  reset(GRADUATED(now - 3_601, 9_000n));
  const harvest = await v2.launchHarvestStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.harvest, token: TOKEN, pool: POOL });
  assertStep(harvest, LOCKER, "harvest");
  assertEquals([callOf(harvest.tx).args, harvest.intent.display!.estQuote, harvest.intent.display!.estToken], [[POOL], "4499", "17998"]);
  reset((w) => (w.takeover = { new: NEXT, effective: now + 600, expires: now + 4_200 }));
  const veto = await v2.launchRecipientCancelStepV2(ME, { kind: v2.LAUNCH_V2_STEPS.recipient_cancel, token: TOKEN });
  assertStep(veto, PAD, "cancel_recipient_change");
  assertEquals(callOf(veto.tx).args, [TOKEN, ME]);
});

// ------------------------------------------------------------------------------------------------ the verifier

/** Every builder's step: its name, the fake chain's state it needs and its spec, as the plans give it. */
function everySpec(): [string, (w: World) => void, StepSpec][] {
  const now = nowS();
  const step = (kind: string, extra: Record<string, unknown> = {}) => ({ kind, token: TOKEN, ...extra });
  return [
    ["buy", () => {}, step(v2.LAUNCH_V2_STEPS.buy, { amount: "500000000", minOut: "1" })],
    ["sell", () => {}, step(v2.LAUNCH_V2_STEPS.sell, { amount: "500000000", minOut: "1" })],
    ["graduate", (w) => (w.curve = { ...w.curve, phase: 1, completedAt: now - 60 }), step(v2.LAUNCH_V2_STEPS.graduate)],
    ["claim", (w) => (w.curve.creatorFees = 1n), step(v2.LAUNCH_V2_STEPS.claim)],
    ["create", () => {}, CREATE],
    ["refund", (w) => (w.curve = { ...w.curve, phase: 3, refundQuote: 1n, refundSupply: 1n }), step(v2.LAUNCH_V2_STEPS.refund, { amount: "5" })],
    ["graduate_fallback", STUCK(now - 2 * HOUR), step(v2.LAUNCH_V2_STEPS.graduate_fallback)],
    ["mark_stuck", (w) => (w.curve = { ...w.curve, phase: 1, completedAt: now - 2 * HOUR }), step(v2.LAUNCH_V2_STEPS.mark_stuck)],
    ["rescue", STUCK(now - 31 * 86_400), step(v2.LAUNCH_V2_STEPS.rescue)],
    ["claim_owed", (w) => (w.owed = 1n), { kind: v2.LAUNCH_V2_STEPS.claim_owed, asset: XLM }],
    ["claim_rewards", (w) => (w.pending = [1n, 1n]), step(v2.LAUNCH_V2_STEPS.claim_rewards)],
    ["harvest", GRADUATED(now - 3_601, 9_000n), step(v2.LAUNCH_V2_STEPS.harvest, { pool: POOL })],
    ["recipient_transfer", GRADUATED(now - 600, 99_000n), step(v2.LAUNCH_V2_STEPS.recipient_transfer, { to: NEXT })],
    ["recipient_cancel", (w) => (w.takeover = { new: NEXT, effective: now, expires: now + 60 }), step(v2.LAUNCH_V2_STEPS.recipient_cancel)],
    ["recipient_execute", (w) => {
      w.recipient = G(12);
      w.takeover = { new: NEXT, effective: now - 60, expires: now + 600 };
    }, step(v2.LAUNCH_V2_STEPS.recipient_execute)],
  ];
}

Deno.test("the server verifier (verify.ts) passes every builder's step against its own intent, as plans.ts runs it", async () => {
  const specs = everySpec();
  assertEquals(specs.map(([, , spec]) => spec.kind).sort(), Object.keys(v2.LAUNCH_V2_BUILDERS).sort(), "one step per builder");
  for (const [name, change, spec] of specs) {
    reset(change);
    const built = await v2.LAUNCH_V2_BUILDERS[spec.kind](ME, spec);
    try {
      const { outflow } = verifyTransaction(built.tx, built.intent, ctx());
      assertEquals(outflow, outflowOf(built.tx), `${name}: the verifier counts what the authorization takes`);
    } catch (err) {
      throw new Error(`${name}: ${(err as Error).message}`);
    }
  }
});

Deno.test("plans.ts builds every v2 step through the verifier: each one built, with its own v2 step kind and fee estimate", async () => {
  const estimates = (await feeEstimates()).estimates as Record<string, bigint>;
  for (const [name, change, spec] of everySpec()) {
    reset(change);
    // createPlan builds the step at once (plans.ts build()): the builder, the fee caps, then verifyTransaction.
    const plan = await createPlan(ME, `launch_${name}`, [{ label: name, spec }]);
    const [s] = plan.steps;
    assertEquals([s.status, s.stepKind, s.feePayer], ["built", spec.kind, "user"], name);
    assert(estimates[spec.kind] > 0n, `${name}: ${spec.kind} has a fee estimate`);
  }
  // Unbuilt, a v2 step is priced at its own kind's estimate, under the kind it is built as.
  reset(GRADUATED(nowS() - 3_601, 99_000n));
  const plan = await v2.buildLaunchV2(ME, { action: "recipient_transfer", token: TOKEN, to: NEXT });
  assertEquals(plan.steps.map((s) => [s.status, s.stepKind]), [["built", v2.LAUNCH_V2_STEPS.harvest], ["pending", v2.LAUNCH_V2_STEPS.recipient_transfer]]);
  assertEquals(plan.steps[1].maxFee, estimates[v2.LAUNCH_V2_STEPS.recipient_transfer].toString());
});

Deno.test("plans.ts hands out no v2 step its verifier refuses: 500 self_check_failed", async () => {
  // A token.claim whose intent says it spends: a claim spends nothing (§20.4), whatever the builder says.
  registerBuilder("launch_v2_test_spends", async (user, spec) => {
    const built = await v2.launchClaimRewardsStepV2(user, { ...spec, kind: v2.LAUNCH_V2_STEPS.claim_rewards });
    return { ...built, intent: { ...built.intent, spend: { [XLM]: "1" } } };
  });
  reset((w) => (w.pending = [1n, 1n]));
  const err = await rejects(() => createPlan(ME, "launch_claim_rewards", [{ label: "claim", spec: { kind: "launch_v2_test_spends", token: TOKEN } }]));
  assertEquals([err.status, err.code, (err.detail as { reason: string }).reason], [500, "self_check_failed", "a claim must not spend anything"]);
});

Deno.test("every step kind has its builder, and plans name v2's kinds apart from v1's", () => {
  assertEquals(Object.keys(v2.LAUNCH_V2_BUILDERS).sort(), Object.values(v2.LAUNCH_V2_STEPS).sort());
  for (const kind of Object.keys(v2.LAUNCH_V2_BUILDERS)) assertMatch(kind, /^launch_v2_/);
});

Deno.test("no economics block where v2 isn't deployed; a launch that isn't one is 404", async () => {
  const { withDeploymentV2 } = await import("../../supabase/functions/_shared/networks.ts");
  assertEquals(await v2.launchpadV2Economics(withDeploymentV2(TESTNET, null)), null);
  await assertRejects(() => v2.quoteTradeV2(ME, "not-a-token", "buy", 1n), ApiError, "Launch not found.");
  reset();
  await assertRejects(() => v2.launchStatusV2(C(40)), ApiError, "Launch not found.");
});

Deno.test("plans: a buy's plan, built and checked as the phone will see it", async () => {
  reset();
  const plan = await v2.buildLaunchV2(ME, { action: "buy", token: TOKEN, amount: "500000000", minOut: "11880000000000" });
  assertEquals([plan.kind, plan.steps.length, plan.steps[0].label, plan.steps[0].status, plan.steps[0].stepKind], ["launch_buy", 1, "Buy ECAT", "built", "launch_v2_buy"]);
  assertEquals(plan.steps[0].intent!.spend, { [XLM]: "500000000" });
  const unknown = await rejects(() => v2.buildLaunchV2(ME, { action: "harvest" as any, token: TOKEN }));
  assertEquals(unknown.code, "bad_action");
});

Deno.test("plans: a recipient change on a graduated launch, harvest first, answers its backlog", async () => {
  reset(GRADUATED(nowS() - 3_601, 99_000n));
  const plan = await v2.buildLaunchV2(ME, { action: "recipient_transfer", token: TOKEN, to: NEXT });
  assertEquals(plan.steps.map((s) => [s.label, s.status]), [["Collect ECAT's pool fees first", "built"], [`Hand ECAT's creator fees to ${NEXT.slice(0, 4)}…${NEXT.slice(-4)}`, "pending"]]);
  assert(plan.harvestBacklog && plan.harvestBacklog.roundsToDrain > 1);
  reset(STUCK(nowS() - 2 * HOUR));
  const fallback = await v2.buildLaunchV2(ME, { action: "graduate_fallback", token: TOKEN });
  assertEquals(fallback.steps.map((s) => s.label), ["Graduate ECAT to Soroswap (fallback)"]);
});

Deno.test("plans: a keeper harvest between the read and the harvest step's simulation makes the plan again, once", async () => {
  const label = `Hand ECAT's creator fees to ${NEXT.slice(0, 4)}…${NEXT.slice(-4)}`;
  const transfer = () => v2.buildLaunchV2(ME, { action: "recipient_transfer", token: TOKEN, to: NEXT }).then((plan) => ({ plan, err: null }), (err) => ({ plan: null, err }));
  const LOCKER_ERRORS = { TooSoon: 10_606, NothingToHarvest: 10_607, UnknownPosition: 10_604 };

  // The keeper harvests first: the locker refuses the plan's harvest, and the position was harvested just now. The
  // plan is made again from that: the change alone, with the backlog from the next interval.
  for (const name of ["TooSoon", "NothingToHarvest"] as const) {
    reset(GRADUATED(nowS() - 3_601, 99_000n));
    let harvestedAt = 0;
    world.harvest = () => {
      harvestedAt = nowS();
      world.position!.lastHarvest = harvestedAt;
      return contractError(LOCKER_ERRORS[name]);
    };
    const { plan, err } = await transfer();
    assertEquals(err, null, name);
    assertEquals(calls.filter((c) => c === "harvest").length, 1, `${name}: the harvest is simulated once`);
    assert(calls.lastIndexOf("transfer_creator_fee_recipient") > calls.indexOf("harvest"), `${name}: then the change is built on its own`);
    assertEquals(plan!.steps.map((s) => [s.label, s.status]), [[label, "built"]]);
    assertEquals(plan!.harvestBacklog, v2.harvestBacklog(POSITION(99_000n), harvestedAt + 3_600, 3_600, 5_000));
  }

  // Refused again: the plan is made again only once, and the locker's refusal is the answer.
  reset(GRADUATED(nowS() - 3_601, 99_000n));
  world.harvest = () => contractError(LOCKER_ERRORS.TooSoon);
  const twice = await transfer();
  assertEquals(calls.filter((c) => c === "harvest").length, 2);
  assertEquals([twice.err.code, twice.err.detail.contractError.name, twice.err.detail.contractError.contract], ["simulation_failed", "TooSoon", "lp-locker"]);

  // Any other refusal isn't retried.
  reset(GRADUATED(nowS() - 3_601, 99_000n));
  world.harvest = () => contractError(LOCKER_ERRORS.UnknownPosition);
  const other = await transfer();
  assertEquals(calls.filter((c) => c === "harvest").length, 1);
  assertEquals([other.err.code, other.err.detail.contractError.name], ["simulation_failed", "UnknownPosition"]);
});
