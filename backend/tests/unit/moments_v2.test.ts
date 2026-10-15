// Moments v2 (docs/DESIGN-stellar-contracts-v2.md §9, §20.2–20.3; CT-14), against a fake moments-v2 that answers as the
// contract does (contracts/moments-v2 on main):
// - the economics block: the policy, the pending policy, the terms with every duration and the harvest stated
//   3,333 : 6,667 (finding V3), both pauses, the completion gross and the FDV at open; kept 5 minutes; never the admin
//   keys; the main stack only, never testnet-qa's failing one (finding F5);
// - the terms go back to publish by value;
// - status: when a Moment may expire, the later of its deadline and the earlier of the recorded-failure clock and the
//   backstop (finding V11), its failure named from v2_errors.ts (finding V10) and simulated at most once a minute, and
//   its progress to the threshold, which the contract's zeroed reserve doesn't tell once it graduates or expires;
// - vesting: the tranches from graduation and the contract's claimable;
// - the builders, keyed by the NFT address: publish (random nonce, the derived NFT and coin, the media's hash, the
//   terms by value and on display), collect (max_total spent in USDC only), claim, claim all (≤ 20, unknown Moments
//   skipped), withdraw, graduate (only an attempt worth its fee) and expire; their refusals, before anyone signs, with
//   §6.13's stable codes only where the API contract has one; and the call rules each transaction is checked with:
//   the account each call acts for, collect's USDC pull, and every builder's transaction against its intent.
import { Account, Address, nativeToScVal, Operation, SorobanDataBuilder, StrKey, Transaction, TransactionBuilder, xdr } from "@stellar/stellar-sdk";
import { Buffer } from "node:buffer";
import { createHash } from "node:crypto";
import { assert, assertEquals, assertNotEquals, assertThrows } from "jsr:@std/assert@1";
import { contractIdFor } from "../../scripts/lib/contract-ids.ts";
import { fakeSql, OTHER, type Row, setTestEnv, USER } from "../fixtures/routes/harness.ts";

setTestEnv();
const STORAGE = "https://example.supabase.co";
Deno.env.set("SUPABASE_URL", STORAGE);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "service-role-for-unit-tests");
const { replaceSql } = await import("../../supabase/functions/_shared/db.ts");
const { TESTNET, withDeploymentV2 } = await import("../../supabase/functions/_shared/networks.ts");
const { DURATION_SETS_V2, parseDeploymentV2 } = await import("../../supabase/functions/_shared/deployments/index.ts");
const { ApiError } = await import("../../supabase/functions/_shared/http.ts");
const { native, sponsor } = await import("../../supabase/functions/_shared/stellar.ts");
const { verifyTransaction, VerifyError } = await import("../../supabase/functions/_shared/verify.ts");
const { forgetReferencePrices } = await import("../../supabase/functions/_shared/refprices.ts");
const mv = await import("../../supabase/functions/_shared/moments_v2.ts");

const ME = USER.publicKey();
const SOMEONE = OTHER.publicKey();
const C = (n: number) => StrKey.encodeContract(new Uint8Array(32).fill(n) as any);
const G = (n: number) => StrKey.encodeEd25519PublicKey(new Uint8Array(32).fill(n) as any);
const H = (n: number) => n.toString(16).padStart(2, "0").repeat(32);
const USDC = TESTNET.assets.find((a) => a.id === "USDC")!;
const NOW = Date.UTC(2026, 9, 15, 12, 0);
const NOW_S = NOW / 1000;
const DAY = 86_400;
const iso = (secs: number) => new Date(secs * 1000).toISOString();

// ------------------------------------------------------------------------------------------------ the deployment

/** A v2 deployment file as deploy-contracts-v2.ts's deploymentRecord() writes it (backend/tests/unit/v2_errors.test.ts). */
function record(deployment: "testnet" | "testnet-qa"): Record<string, any> {
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
      lpLocker: C(2),
      momentsGraduator: C(3),
      launchpadV2: C(4),
      momentsV2: C(5),
      ...(qa ? { qaExecFail: C(6), momentsGraduatorQaFail: C(7), momentsV2QaFail: C(8) } : {}),
    },
    wasmHashes: {
      launchpadV2: H(1),
      launchTokenV2: H(2),
      execSoroswap: H(3),
      lpLocker: H(4),
      momentsV2: H(5),
      momentNft: H(6),
      momentCoin: H(7),
      momentsGraduator: H(8),
      ...(qa ? { qaExecFail: H(9) } : {}),
    },
    venues: [{ id: 0, kind: "Soroswap", executor: C(1), feeFraction: 0, enabled: true }, ...(qa ? [{ id: 2, kind: "QaFail", executor: C(6), feeFraction: 0, enabled: true }] : [])],
    quotes: {},
    aquarius: { enabled: false, reason: "--aquarius off" },
    ...(qa ? { qaAsset: { code: "DYORQA", issuer: G(7), sac: C(9) } } : {}),
    durations: { set: qa ? "testnet-qa" : "production", launch: set.launch, moments: set.moments },
    ttl: { threshold: 120_960, extend_to: 518_400 },
    deployLedger: 5_300_000,
    deployedAt: "2026-10-15T09:00:00.000Z",
  };
}

const NET = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-v2", record("testnet")));
const QA_NET = withDeploymentV2(TESTNET, parseDeploymentV2("testnet-qa-v2", record("testnet-qa")));
const MOMENTS = C(5);
const GRADUATOR = C(3);
const PROD = DURATION_SETS_V2.production.moments;

// ------------------------------------------------------------------------------------------------ a fake moments-v2

const i128 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "i128" });
const u32 = (n: number) => nativeToScVal(n, { type: "u32" });
const u64 = (n: bigint | number) => nativeToScVal(BigInt(n), { type: "u64" });
const addr = (a: string) => new Address(a).toScVal();
const str = (s: string) => nativeToScVal(s, { type: "string" });
const sym = (s: string) => xdr.ScVal.scvSymbol(s);
const bool = (b: boolean) => xdr.ScVal.scvBool(b);
const bytes = (hex: string) => xdr.ScVal.scvBytes(Buffer.from(hex, "hex"));
const struct = (fields: Record<string, xdr.ScVal>) =>
  xdr.ScVal.scvMap(Object.keys(fields).sort().map((k) => new xdr.ScMapEntry({ key: xdr.ScVal.scvSymbol(k), val: fields[k] })));

interface Policy {
  threshold: bigint;
  min_price: bigint;
  creator_bps: number;
  platform_bps: number;
  reserve_bps: number;
  max_creator_alloc_bps: number;
  expiry_creator_bps: number;
  royalty_bps: number;
  platform: string;
  treasury: string;
}

/** testnet's policy (§14.2): T = 10 USDC, 0.10 USDC minimum, 20/5/75, 10% allocation, 70% expiry share, 5% royalty. */
const POLICY: Policy = {
  threshold: 100_000_000n,
  min_price: 1_000_000n,
  creator_bps: 2_000,
  platform_bps: 500,
  reserve_bps: 7_500,
  max_creator_alloc_bps: 1_000,
  expiry_creator_bps: 7_000,
  royalty_bps: 500,
  platform: G(5),
  treasury: G(6),
};

interface Moment {
  creator: string;
  coin: string;
  price: bigint;
  creator_alloc_bps: number;
  published_at: number;
  deadline: number;
  nonce: bigint;
}

interface Ledger {
  state: number;
  completed_at: number;
  stuck_since: number;
  ended_at: number;
  graduated_at: number;
  reserve: bigint;
  creator_claimable: bigint;
  platform_claimable: bigint;
  treasury_claimable: bigint;
  total_gross: bigint;
  collects: number;
  editions: number;
  entitlements: bigint;
  creator_claimed: bigint;
  minted_by_vesting: bigint;
  pool: string | null;
  liquidity: bigint;
}

const NFT_A = C(20); // Collecting
const NFT_P = C(21); // GraduationPending
const NFT_G = C(22); // Graduated
const NFT_E = C(23); // Expired
const NFT_QA = C(24); // on testnet-qa's failing stack only

const LEDGER0: Ledger = {
  state: 0,
  completed_at: 0,
  stuck_since: 0,
  ended_at: 0,
  graduated_at: 0,
  reserve: 0n,
  creator_claimable: 0n,
  platform_claimable: 0n,
  treasury_claimable: 0n,
  total_gross: 0n,
  collects: 0,
  editions: 0,
  entitlements: 0n,
  creator_claimed: 0n,
  minted_by_vesting: 0n,
  pool: null,
  liquidity: 0n,
};

/** What simulating graduate answers: the outcome, a failed simulation, or no answer at all (RPC unreachable). */
type GradAnswer = ["Graduated", string] | ["Failed", number, number] | { error: string } | "unreachable";

/** What the fake chain holds. `reset()` puts it back before each test. */
const chain = {
  config: { publishing_paused: false, guardian_paused: false },
  policy: { ...POLICY },
  durations: { ...PROD } as Record<string, number>,
  executor: C(1),
  pending: null as null | { policy: Policy; eta: number; expires: number },
  moments: new Map<string, { m: Moment; l: Ledger }>(),
  positions: new Map<string, { entitlement: bigint; claimed: bigint }>(),
  claimable: new Map<string, [bigint, bigint]>(),
  quotes: new Map<string, { gross: bigint; editions: number; entitlement: bigint; terminal: boolean }>(),
  graduate: new Map<string, GradAnswer>(),
  /** Every call to a contract, as fn@contract. */
  calls: [] as string[],
  /** Simulate user authorization on every call (a permissionless call included). */
  authEverything: false,
  rpcDown: false,
};

function reset() {
  chain.config = { publishing_paused: false, guardian_paused: false };
  chain.policy = { ...POLICY };
  chain.durations = { ...PROD };
  chain.executor = C(1);
  chain.pending = null;
  chain.moments = new Map<string, { m: Moment; l: Ledger }>([
    [NFT_A, { m: moment(SOMEONE, 0, NOW_S + DAY), l: { ...LEDGER0, reserve: 7_500_000n, total_gross: 10_000_000n, collects: 1, editions: 1, entitlements: 2_000_000_000n } }],
    [NFT_P, { m: moment(SOMEONE, 1_000, NOW_S - 3_600), l: { ...LEDGER0, state: 1, completed_at: NOW_S - 7_200, reserve: 100_000_000n, total_gross: 133_333_334n, collects: 4, editions: 14 } }],
    [NFT_G, { m: moment(ME, 1_000, NOW_S - 40 * DAY), l: { ...LEDGER0, state: 2, completed_at: NOW_S - 31 * DAY - 60, graduated_at: NOW_S - 31 * DAY, ended_at: NOW_S - 31 * DAY, creator_claimable: 5_000_000n, creator_claimed: 20_000_000_000_000n, pool: C(30), liquidity: 9n } }],
    [NFT_E, { m: moment(SOMEONE, 0, NOW_S - 10 * DAY), l: { ...LEDGER0, state: 3, ended_at: NOW_S - 9 * DAY } }],
  ]);
  chain.positions = new Map<string, { entitlement: bigint; claimed: bigint }>([[`${NFT_G}|${ME}`, { entitlement: 1_000_000_000n, claimed: 600_000_000n }]]);
  chain.claimable = new Map<string, [bigint, bigint]>([[`${NFT_G}|${ME}`, [200_000_000n, 16_000_000_000_000n]]]);
  chain.quotes = new Map<string, { gross: bigint; editions: number; entitlement: bigint; terminal: boolean }>([[NFT_A, { gross: 30_000_000n, editions: 3, entitlement: 6_000_000_000n, terminal: false }]]);
  chain.graduate = new Map<string, GradAnswer>([[NFT_P, ["Failed", 10, 11_003]]]);
  chain.calls = [];
  chain.authEverything = false;
  chain.rpcDown = false;
  trustlines = [];
  metadata.clear();
  mv.forgetMomentsV2();
  forgetReferencePrices();
}

function moment(creator: string, alloc: number, deadline: number): Moment {
  return { creator, coin: C(40), price: 10_000_000n, creator_alloc_bps: alloc, published_at: deadline - 2 * DAY, deadline, nonce: 7n };
}

const policyVal = (p: Policy) =>
  struct({
    threshold: i128(p.threshold),
    min_price: i128(p.min_price),
    creator_bps: u32(p.creator_bps),
    platform_bps: u32(p.platform_bps),
    reserve_bps: u32(p.reserve_bps),
    max_creator_alloc_bps: u32(p.max_creator_alloc_bps),
    expiry_creator_bps: u32(p.expiry_creator_bps),
    royalty_bps: u32(p.royalty_bps),
    platform: addr(p.platform),
    treasury: addr(p.treasury),
  });

const durationsVal = () => struct(Object.fromEntries(Object.entries(chain.durations).map(([k, v]) => [k, u64(v)])));

/** moments-v2 terms(), as the contract builds it (policy.rs terms). */
const termsVal = () =>
  struct({
    policy: policyVal(chain.policy),
    external_base: str("https://dyorhq.fun/moments/"),
    nft_wasm_hash: bytes(H(6)),
    coin_wasm_hash: bytes(H(7)),
    graduator: addr(GRADUATOR),
    executor: addr(chain.executor),
    locker: addr(C(2)),
    durations: durationsVal(),
    harvest_bps: u32(6_667),
    harvest_creator_bps: u32(4_000),
  });

function momentVal(nft: string, m: Moment) {
  const r = BigInt(chain.policy.reserve_bps);
  return struct({
    nft: addr(nft),
    creator: addr(m.creator),
    platform: addr(chain.policy.platform),
    treasury: addr(chain.policy.treasury),
    coin: addr(m.coin),
    price: i128(m.price),
    threshold: i128(chain.policy.threshold),
    rate_num: i128(1_000_000_000_000_000n * (10_000n - BigInt(m.creator_alloc_bps)) * r),
    rate_den: i128(10_000n * chain.policy.threshold * (10_000n + r)),
    creator_bps: u32(2_000),
    platform_bps: u32(500),
    reserve_bps: u32(7_500),
    creator_alloc_bps: u32(m.creator_alloc_bps),
    expiry_creator_bps: u32(7_000),
    royalty_bps: u32(500),
    nonce: u64(m.nonce),
    published_at: u64(m.published_at),
    deadline: u64(m.deadline),
  });
}

function ledgerVal(l: Ledger) {
  return struct({
    state: u32(l.state),
    completed_at: u64(l.completed_at),
    stuck_since: u64(l.stuck_since),
    ended_at: u64(l.ended_at),
    graduated_at: u64(l.graduated_at),
    reserve: i128(l.reserve),
    creator_claimable: i128(l.creator_claimable),
    platform_claimable: i128(l.platform_claimable),
    treasury_claimable: i128(l.treasury_claimable),
    total_gross: i128(l.total_gross),
    collects: u32(l.collects),
    editions: u32(l.editions),
    entitlements: i128(l.entitlements),
    creator_claimed: i128(l.creator_claimed),
    minted_by_vesting: i128(l.minted_by_vesting),
    pool: l.pool ? addr(l.pool) : xdr.ScVal.scvVoid(),
    liquidity: i128(l.liquidity),
  });
}

/** The host's log of moments-v2 failing with `code` (simulateTransaction's error text). */
function errorLog(code: number, contract = MOMENTS): string {
  return `HostError: Error(Contract, #${code})\n\nEvent log (newest first):\n   0: [Diagnostic Event] contract:${contract}, topics:[error, Error(Contract, #${code})], data:"escalating error to VM trap from failed host function call: fail_with_error"\n   1: [Diagnostic Event] contract:${contract}, topics:[error, Error(Contract, #${code})], data:["failing with contract error", ${code}]`;
}

/** The NFT address `creator` publishing with `nonce` gets (§9.2, L15), derived as the network does. */
function nftAddress(creator: string, nonce: bigint): string {
  const nonceBe = Buffer.alloc(8);
  nonceBe.writeBigUInt64BE(nonce);
  const salt = sha256(Buffer.concat([Buffer.from("dyorhq/moment-nft/v2"), addr(creator).toXDR(), nonceBe]));
  return contractIdFor(MOMENTS, salt, TESTNET.passphrase);
}

/** The coin moments-graduator deploys for `nft` (§12). */
function coinAddress(nft: string): string {
  return contractIdFor(GRADUATOR, sha256(Buffer.concat([Buffer.from("dyorhq/moment-coin/v2"), addr(nft).toXDR()])), TESTNET.passphrase);
}

function sha256(data: Uint8Array): Uint8Array {
  // node:crypto is synchronous, unlike WebCrypto.
  return new Uint8Array(createHash("sha256").update(data).digest());
}

const UNKNOWN = { error: errorLog(10_708) };

function answer(contract: string, fn: string, args: xdr.ScVal[]): xdr.ScVal | { error: string } | "unreachable" {
  chain.calls.push(`${fn}@${contract === MOMENTS ? "moments" : contract === GRADUATOR ? "graduator" : contract.slice(0, 6)}`);
  if (contract === GRADUATOR && fn === "coin_address") return addr(coinAddress(String(native(args[0]))));
  if (contract !== MOMENTS) return { error: "HostError: Error(Storage, MissingValue)" };
  const nft = args.length && fn !== "nft_address" && fn !== "publish" && fn !== "claim_all" ? String(native(fn === "claim" ? args[1] : args[0])) : "";
  const known = chain.moments.get(nft);
  switch (fn) {
    case "config":
      return struct({ governance: addr(G(2)), guardian: addr(G(4)), usdc: addr(USDC.contract), publishing_paused: bool(chain.config.publishing_paused), guardian_paused: bool(chain.config.guardian_paused) });
    case "terms":
      return termsVal();
    case "pending_policy":
      return chain.pending ? struct({ policy: policyVal(chain.pending.policy), eta: u64(chain.pending.eta), expires: u64(chain.pending.expires) }) : xdr.ScVal.scvVoid();
    case "nft_address":
      return addr(nftAddress(String(native(args[0])), BigInt(native(args[1]))));
    case "publish": {
      const p = native(args[1]);
      return addr(nftAddress(String(native(args[0])), BigInt(p.nonce)));
    }
    case "get_moment":
      return known ? momentVal(nft, known.m) : UNKNOWN;
    case "ledger":
      return known ? ledgerVal(known.l) : UNKNOWN;
    case "position":
    case "claimable": {
      const id = String(native(args[0]));
      if (!chain.moments.has(id)) return UNKNOWN;
      const key = `${id}|${String(native(args[1]))}`;
      if (fn === "position") {
        const p = chain.positions.get(key) ?? { entitlement: 0n, claimed: 0n };
        return struct({ entitlement: i128(p.entitlement), claimed: i128(p.claimed) });
      }
      const c = chain.claimable.get(key) ?? [0n, 0n];
      return xdr.ScVal.scvVec([i128(c[0]), i128(c[1])]);
    }
    case "quote":
    case "collect": {
      const id = String(native(args[fn === "quote" ? 0 : 1]));
      const m = chain.moments.get(id);
      if (!m) return UNKNOWN;
      if (m.l.state !== 0) return { error: errorLog(10_709) };
      if (NOW_S >= m.m.deadline) return { error: errorLog(10_710) };
      const qty = Number(native(args[fn === "quote" ? 1 : 2]));
      if (qty < 1 || qty > 20) return { error: errorLog(10_711) };
      const q = chain.quotes.get(id)!;
      if (fn === "collect") return struct({ first_rank: u32(2), editions: u32(q.editions), gross: i128(q.gross), entitlement: i128(q.entitlement) });
      return struct({
        gross: i128(q.gross),
        editions: u32(q.editions),
        entitlement: i128(q.entitlement),
        reserve_in: i128((q.gross * 3n) / 4n),
        creator_in: i128(q.gross / 5n),
        platform_in: i128(q.gross / 20n),
        excess: i128(10_000_000n * BigInt(qty) - q.gross),
        terminal: bool(q.terminal),
      });
    }
    case "claim":
      return known ? xdr.ScVal.scvVec([i128(1n), i128(0n)]) : UNKNOWN;
    case "claim_all":
      return i128(1n);
    case "withdraw_creator":
      return known ? i128(known.l.creator_claimable) : UNKNOWN;
    case "graduate": {
      if (!known) return UNKNOWN;
      if (known.l.state !== 1) return { error: errorLog(10_714) };
      const g = chain.graduate.get(nft) ?? (["Graduated", C(30)] as GradAnswer);
      if (g === "unreachable" || !Array.isArray(g)) return g;
      return g[0] === "Graduated" ? xdr.ScVal.scvVec([sym("Graduated"), addr(g[1])]) : xdr.ScVal.scvVec([sym("Failed"), struct({ origin: u32(g[1]), code: u32(g[2]) })]);
    }
    case "expire":
      return known ? xdr.ScVal.scvVoid() : UNKNOWN;
  }
  return { error: errorLog(10_701) };
}

const authorized = (contract: string, fn: string, args: xdr.ScVal[], subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizedInvocation({
    function: xdr.SorobanAuthorizedFunction.sorobanAuthorizedFunctionTypeContractFn(
      new xdr.InvokeContractArgs({ contractAddress: new Address(contract).toScAddress(), functionName: fn, args }),
    ),
    subInvocations: subs,
  });

/** The authorization the host records for the source account: the call itself for the functions that require the
 *  user's auth, with collect's USDC pull under it; nothing for the functions anyone may call. */
function authFor(contract: string, fn: string, args: xdr.ScVal[]): xdr.SorobanAuthorizationEntry[] {
  const own = ["publish", "collect", "claim", "claim_all"].includes(fn) || chain.authEverything;
  if (contract !== MOMENTS || !own) return [];
  const subs = fn === "collect" ? [authorized(USDC.contract, "transfer", [args[0], addr(MOMENTS), i128(chain.quotes.get(String(native(args[1])))!.gross)])] : [];
  return [new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: authorized(contract, fn, args, subs) })];
}

function simulate(transaction: string) {
  const tx = TransactionBuilder.fromXDR(transaction, TESTNET.passphrase) as Transaction;
  const call = (tx.operations[0] as any).func.invokeContract();
  const contract = Address.fromScAddress(call.contractAddress()).toString();
  const fn = call.functionName().toString();
  const a = answer(contract, fn, call.args());
  if (a === "unreachable") return null;
  if (!(a instanceof xdr.ScVal)) return { latestLedger: 1, error: a.error };
  return {
    latestLedger: 1,
    minResourceFee: "1000",
    transactionData: new SorobanDataBuilder().setResources(1_000_000, 1_000, 1_000).setResourceFee(1_000).build().toXDR("base64"),
    results: [{ auth: authFor(contract, fn, call.args()).map((e) => e.toXDR("base64")), xdr: a.toXDR("base64") }],
    events: [],
  };
}

function accountEntry(key: string) {
  const id = xdr.LedgerKey.fromXDR(key, "base64").account().accountId();
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
  return { entries: [{ key, xdr: val.toXDR("base64"), lastModifiedLedgerSeq: 1 }], latestLedger: 1 };
}

/** The account's trustlines on Horizon. */
let trustlines: string[] = [];
const BASE = `${STORAGE}/storage/v1/object/public/lite-media/`;
const PHOTO = `${BASE}uploads/${ME}/7dedfd8a-9584-4cd0-a43a-cd036723818b.jpg`;
const PHOTO_BYTES = new TextEncoder().encode("the photo's bytes");
const URI = `${BASE}moments/${ME}/41019444-f54f-4a9e-ac88-2667a92257fa.json`;

globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(String(input), init);
  const url = new URL(req.url);
  if (url.host === "soroban-testnet.stellar.org") {
    if (chain.rpcDown) return new Response("unavailable", { status: 503 });
    const body = await req.json();
    const result = body.method === "simulateTransaction"
      ? simulate(body.params.transaction)
      : body.method === "getLedgerEntries"
      ? accountEntry(body.params.keys[0])
      : null;
    if (body.method === "simulateTransaction" && result === null) return new Response("unavailable", { status: 503 });
    return Response.json({ jsonrpc: "2.0", id: body.id, result });
  }
  if (url.host === "horizon-testnet.stellar.org" && url.pathname.startsWith("/accounts/")) {
    const id = url.pathname.split("/")[2];
    return Response.json({
      id,
      account_id: id,
      sequence: "1",
      subentry_count: trustlines.length,
      thresholds: { low_threshold: 0, med_threshold: 0, high_threshold: 0 },
      flags: { auth_required: false, auth_revocable: false, auth_immutable: false, auth_clawback_enabled: false },
      signers: [{ key: id, weight: 1, type: "ed25519_public_key" }],
      balances: [
        ...trustlines.map((line) => ({ asset_type: "credit_alphanum4", asset_code: line.split(":")[0], asset_issuer: line.split(":")[1], balance: "5.0000000", limit: "922337203685.4775807" })),
        { asset_type: "native", balance: "100.0000000", selling_liabilities: "0.0000000" },
      ],
      _links: {},
    });
  }
  if (req.url === PHOTO) return new Response(PHOTO_BYTES);
  return new Response("offline", { status: 503 });
}) as typeof fetch;

/** lite.moment_metadata rows, by URI and address. */
const metadata = new Map<string, Row>();
let queries: string[] = [];
replaceSql(fakeSql((q, p) => {
  queries.push(q);
  if (q === "select title, place, taken_on, media_type, media_url from lite.moment_metadata where uri = ? and address = ?") {
    const row = metadata.get(`${p[0]}|${p[1]}`);
    return row ? [row] : [];
  }
  if (q === "select ref, usd, source, market, change_24h, volume_24h_usd, quoted_at from lite.ref_quotes") {
    return [{ ref: "USDC", usd: "1.0000", source: "kraken", market: "Kraken USDC/USD", change_24h: "0", volume_24h_usd: "1", quoted_at: new Date(NOW) }];
  }
  throw new Error(`unexpected query: ${q}`);
}));

function writeMetadata(title = "Accra at dusk") {
  metadata.set(`${URI}|${ME}`, { title, place: "Accra", taken_on: "2026-10-14", media_type: "image", media_url: PHOTO });
}

/** The error `run` threw: status, code, its stable contract code (§6.13) and the contract error it names (V10). */
async function refusedWith(run: () => unknown): Promise<[number, string, unknown, unknown]> {
  try {
    await run();
  } catch (err) {
    assert(err instanceof ApiError, String(err));
    const detail = err.detail as { contractCode?: string; contractError?: { name: string } } | undefined;
    return [err.status, err.code, detail?.contractCode, detail?.contractError?.name];
  }
  throw new Error("not refused");
}

const argsOf = (tx: Transaction) => (tx.operations[0] as any).func.invokeContract().args() as xdr.ScVal[];
const fnOf = (tx: Transaction) => (tx.operations[0] as any).func.invokeContract().functionName().toString() as string;
const v2Ctx = (user = ME) => ({ user, contract: MOMENTS, usdc: USDC.contract });
/** The server verifier's context, as plans.ts builds it: moments-v2 and the registry's tokens. */
const verifyCtx = { user: ME, sponsor: sponsor().publicKey(), passphrase: TESTNET.passphrase, allowedContracts: new Set([MOMENTS, ...TESTNET.assets.map((a) => a.contract)]) };

function assertRuleRefuses(tx: Transaction, intent: any, message: string, user = ME) {
  const err = assertThrows(() => mv.verifyMomentsV2Call(tx, intent, v2Ctx(user)), VerifyError);
  assertEquals(err.message, message);
}

// ------------------------------------------------------------------------------------------------ economics

Deno.test("economics: the policy, the pending policy and the terms with every duration and the harvest stated 3,333 : 6,667, both pauses, the completion gross and the FDV at open; never the admin keys", async () => {
  reset();
  const pendingPolicy = { ...POLICY, threshold: 200_000_000n };
  chain.pending = { policy: pendingPolicy, eta: NOW_S + 3_600, expires: NOW_S + 3_600 + 7 * DAY };
  const e = await mv.momentsEconomicsV2(NET, NOW);
  const policy = {
    threshold: "100000000",
    minPrice: "1000000",
    creatorBps: 2_000,
    platformBps: 500,
    reserveBps: 7_500,
    maxCreatorAllocBps: 1_000,
    expiryCreatorBps: 7_000,
    royaltyBps: 500,
    platform: G(5),
    treasury: G(6),
  };
  assertEquals(e.policy, policy);
  assertEquals(e.terms, {
    policy,
    externalBase: "https://dyorhq.fun/moments/",
    nftWasmHash: H(6),
    coinWasmHash: H(7),
    graduator: GRADUATOR,
    executor: C(1),
    locker: C(2),
    durations: {
      vestPeriod: 30 * DAY,
      stuckExpiry: 7 * DAY,
      pendingBackstop: 30 * DAY,
      timelock: 2 * DAY,
      timelockWindow: 7 * DAY,
      minWindow: 3_600,
      maxWindow: 30 * DAY,
      harvestInterval: 3_600,
    },
    harvestBps: 6_667,
    harvestCreatorBps: 4_000,
    harvest: { intervalSecs: 3_600, harvestedBps: 6_667, compoundedBps: 3_333, ratio: "3,333 : 6,667", quoteSide: { creatorBps: 4_000, platformBps: 6_000 }, coinSide: "burned" },
  });
  assertEquals(e.pendingPolicy, { policy: { ...policy, threshold: "200000000" }, eta: iso(NOW_S + 3_600), expires: iso(NOW_S + 3_600 + 7 * DAY), state: "waiting" });
  assertEquals([e.publishingPaused, e.guardianPaused, e.contract, e.quote], [false, false, MOMENTS, { asset: "USDC", contract: USDC.contract }]);
  assertEquals([e.supply, e.maxPerCollect, e.maxClaimIds], ["1000000000000000", 20, 20]);
  // T = 10 USDC at a 75% reserve: 13.3333334 USDC completes a Moment; at a 10% allocation the FDV opens at $25.93 (§14.2).
  assertEquals([e.completionGross, e.maxPrice], ["133333334", "133333334"]);
  assertEquals([e.fdvAtOpen, e.fdvAtOpenUsd], ["259259259", 25.93]);
  assertEquals(e.fdvByAllocation.length, 11);
  assertEquals(e.fdvByAllocation[0], { allocationBps: 0, fdv: "233333333", fdvUsd: 23.33 });
  assertEquals(e.fdvByAllocation[10], { allocationBps: 1_000, fdv: "259259259", fdvUsd: 25.93 });
  // The FDV is S over the bundle rate the contract promises collectors at.
  const rate = mv.bundleRate(100_000_000n, 7_500, 1_000);
  assertEquals((mv.SUPPLY * rate.den) / rate.num, 259_259_259n);
  // Governance and the guardian are never served.
  const text = JSON.stringify(e);
  for (const key of [G(2), G(4)]) assert(!text.includes(key), key);

  // A pending policy is ready from its eta and lapsed after it expires (clients treat now > expires as lapsed).
  assertEquals((await mv.momentsEconomicsV2(NET, (NOW_S + 3_600) * 1000)).pendingPolicy?.state, "ready");
  assertEquals((await mv.momentsEconomicsV2(NET, (NOW_S + 3_600 + 7 * DAY + 1) * 1000)).pendingPolicy?.state, "lapsed");
});

Deno.test("economics: kept 5 minutes; when RPC fails the last read is served, and without one 502; 503 not_deployed without a v2 deployment", async () => {
  reset();
  await mv.momentsEconomicsV2(NET, NOW);
  assertEquals(chain.calls.sort(), ["config@moments", "pending_policy@moments", "terms@moments"]);
  chain.policy.royalty_bps = 0;
  const kept = await mv.momentsEconomicsV2(NET, NOW + mv.MOMENTS_ECONOMICS_TTL_MS - 1);
  assertEquals([chain.calls.length, kept.policy.royaltyBps], [3, 500]);
  assertEquals((await mv.momentsEconomicsV2(NET, NOW + mv.MOMENTS_ECONOMICS_TTL_MS)).policy.royaltyBps, 0);
  chain.rpcDown = true;
  assertEquals((await mv.momentsEconomicsV2(NET, NOW + 3 * mv.MOMENTS_ECONOMICS_TTL_MS)).policy.royaltyBps, 0);
  mv.forgetMomentsV2();
  assertEquals((await refusedWith(() => mv.momentsEconomicsV2(NET, NOW))).slice(0, 2), [502, "rpc_unavailable"]);
  chain.rpcDown = false;
  assertEquals((await refusedWith(() => mv.momentsEconomicsV2(TESTNET, NOW))).slice(0, 2), [503, "not_deployed"]);
});

Deno.test("only the main Moments stack is served: testnet-qa's failing stack never appears (finding F5)", async () => {
  reset();
  const e = await mv.momentsEconomicsV2(QA_NET, NOW);
  assertEquals(e.contract, MOMENTS);
  assert(chain.calls.every((c) => c.endsWith("@moments")), chain.calls.join());
  const text = JSON.stringify(e);
  for (const qa of [C(6), C(7), C(8)]) assert(!text.includes(qa), qa);
  // A Moment of the failing stack is unknown to the main one.
  assertEquals((await refusedWith(() => mv.momentStatusV2(NFT_QA, { net: QA_NET, now: NOW }))).slice(0, 2), [404, "not_found"]);
});

Deno.test("the terms go back to publish by value: decoded from terms() and encoded again, the same XDR", () => {
  reset();
  chain.pending = null;
  const terms = mv.termsOf(native(termsVal()));
  assertEquals(mv.termsScVal(terms).toXDR("base64"), termsVal().toXDR("base64"));
  assertEquals(Object.keys(mv.termsDisplay(terms)).sort(), [...mv.TERMS_DISPLAY_KEYS].sort());
});

// ------------------------------------------------------------------------------------------------ status

Deno.test("expiry: Collecting at its deadline; pending without a recorded failure at the backstop, with one at the earlier clock; never before the deadline (finding V11)", () => {
  const d = { stuckExpiry: 7 * DAY, pendingBackstop: 30 * DAY };
  const T0 = 1_800_000_000;
  const at = (deadline: number, state: "collecting" | "graduation_pending" | "graduated" | "expired", completedAt = 0, stuckSince = 0) => {
    const e = mv.expiryOf({ deadline }, { state, completedAt, stuckSince }, d);
    return [e.at, e.by, e.backstopAt, e.failureAt];
  };
  assertEquals(at(T0, "collecting"), [T0, "deadline", null, null]);
  // No recorded failure: the backstop, 30 days after completion.
  assertEquals(at(T0 - DAY, "graduation_pending", T0), [T0 + 30 * DAY, "backstop", T0 + 30 * DAY, null]);
  // A recorded failure: the earlier of 7 days after it and the backstop.
  assertEquals(at(T0 - DAY, "graduation_pending", T0, T0 + 3_600), [T0 + 3_600 + 7 * DAY, "failure", T0 + 30 * DAY, T0 + 3_600 + 7 * DAY]);
  assertEquals(at(T0 - DAY, "graduation_pending", T0, T0 + 29 * DAY), [T0 + 30 * DAY, "backstop", T0 + 30 * DAY, T0 + 36 * DAY]);
  // Both clocks at once: the failure's, the branch the contract checks first (its expired event says backstop=false).
  assertEquals(at(T0 - DAY, "graduation_pending", T0, T0 + 23 * DAY), [T0 + 30 * DAY, "failure", T0 + 30 * DAY, T0 + 30 * DAY]);
  // Never before the deadline, whichever clock runs.
  assertEquals(at(T0 + 40 * DAY, "graduation_pending", T0), [T0 + 40 * DAY, "deadline", T0 + 30 * DAY, null]);
  assertEquals(at(T0 + 20 * DAY, "graduation_pending", T0, T0 + 60), [T0 + 20 * DAY, "deadline", T0 + 30 * DAY, T0 + 60 + 7 * DAY]);
  assertEquals(at(T0, "graduated", T0), [null, null, null, null]);
  assertEquals(at(T0, "expired"), [null, null, null, null]);
});

Deno.test("status: a pending Moment shows its expiry and, with a recorded failure, its origin, code and name (finding V10): recorded when the indexer has it, else simulated", async () => {
  reset();
  // Pending, no recorded failure: the backstop's time, and no failure (nothing is simulated).
  let s = await mv.momentStatusV2(NFT_P, { net: NET, now: NOW });
  assertEquals([s.state, s.expiresAt, s.expiresBy, s.backstopAt, s.failureExpiresAt, s.expirable, s.graduatable, s.failure], [
    "graduation_pending",
    iso(NOW_S - 7_200 + 30 * DAY),
    "backstop",
    iso(NOW_S - 7_200 + 30 * DAY),
    null,
    false,
    true,
    null,
  ]);
  assertEquals(chain.calls.filter((c) => c.startsWith("graduate")), []);
  assertEquals([s.progress, s.reserve, s.threshold, s.completedAt, s.stuckSince], [1, "100000000", "100000000", iso(NOW_S - 7_200), null]);

  // A recorded failure: the earlier clock, and the failure an attempt records now, named.
  chain.moments.get(NFT_P)!.l.stuck_since = NOW_S - 3_600;
  s = await mv.momentStatusV2(NFT_P, { net: NET, now: NOW });
  assertEquals([s.expiresAt, s.expiresBy, s.stuckSince], [iso(NOW_S - 3_600 + 7 * DAY), "failure", iso(NOW_S - 3_600)]);
  assertEquals(s.failure, { origin: 10, code: 11_003, name: "GraduationInvalid", source: "moments-graduator", seen: "simulated" });
  // The indexer's recorded grad_fail wins: exec-soroswap's LiquidityTooLow (3, 10304).
  s = await mv.momentStatusV2(NFT_P, { net: NET, now: NOW, recorded: { origin: 3, code: 10_304 } });
  assertEquals(s.failure, { origin: 3, code: 10_304, name: "LiquidityTooLow", source: "exec-soroswap", seen: "recorded" });
  // An attempt that would graduate now: no reason to show, once the minute a simulation is kept has passed.
  chain.graduate.set(NFT_P, ["Graduated", C(30)]);
  assertEquals((await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + 1_000 })).failure?.name, "GraduationInvalid");
  assertEquals((await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + mv.MOMENT_FAILURE_TTL_MS })).failure, null);
  // Expirable once the clock has run.
  assertEquals((await mv.momentStatusV2(NFT_P, { net: NET, now: (NOW_S - 3_600 + 7 * DAY) * 1000 })).expirable, true);

  // Collecting: its deadline. Graduated and Expired: no expiry.
  s = await mv.momentStatusV2(NFT_A, { net: NET, now: NOW });
  assertEquals([s.state, s.expiresAt, s.expiresBy, s.expirable, s.graduatable], ["collecting", iso(NOW_S + DAY), "deadline", false, false]);
  s = await mv.momentStatusV2(NFT_G, { net: NET, now: NOW });
  assertEquals([s.state, s.expiresAt, s.pool, s.proceeds.creator], ["graduated", null, C(30), "5000000"]);
  assertEquals((await mv.momentStatusV2(NFT_E, { net: NET, now: NOW })).state, "expired");
  // An unknown Moment is 404; something that isn't a contract address is 400.
  assertEquals((await refusedWith(() => mv.momentStatusV2(C(99), { net: NET, now: NOW }))).slice(0, 2), [404, "not_found"]);
  assertEquals((await refusedWith(() => mv.momentStatusV2("12", { net: NET, now: NOW }))).slice(0, 2), [400, "bad_moment"]);
});

Deno.test("status: a graduation is simulated at most once a minute per Moment for its failure, however often the status is read; a new recorded failure or the indexer's own needs none", async () => {
  reset();
  const graduations = () => chain.calls.filter((c) => c.startsWith("graduate@")).length;
  chain.moments.get(NFT_P)!.l.stuck_since = NOW_S - 3_600;
  for (let i = 0; i < 5; i++) await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + i * 1_000 });
  assertEquals(graduations(), 1);
  // The indexer's failure: nothing to simulate.
  await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + mv.MOMENT_FAILURE_TTL_MS, recorded: { origin: 3, code: 10_304 } });
  assertEquals(graduations(), 1);
  // A minute later, or after another recorded failure (a later stuck_since), it is simulated again.
  await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + mv.MOMENT_FAILURE_TTL_MS });
  assertEquals(graduations(), 2);
  chain.moments.get(NFT_P)!.l.stuck_since = NOW_S - 60;
  await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + mv.MOMENT_FAILURE_TTL_MS + 1_000 });
  assertEquals(graduations(), 3);
  // The simulation unanswered: the status stands, with the last failure seen, and the next read tries again.
  chain.graduate.set(NFT_P, "unreachable");
  const s = await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + 3 * mv.MOMENT_FAILURE_TTL_MS });
  assertEquals([s.state, s.failure?.name, graduations()], ["graduation_pending", "GraduationInvalid", 4]);
  // One that would abort shows no reason (only the backstop ends it).
  chain.graduate.set(NFT_P, { error: "HostError: Error(Budget, ExceededLimit)" });
  assertEquals((await mv.momentStatusV2(NFT_P, { net: NET, now: NOW + 3 * mv.MOMENT_FAILURE_TTL_MS + 1 })).failure, null);
  assertEquals(graduations(), 5);
});

Deno.test("status: progress to the threshold is 1 for a Moment that completed, graduated or expired since, though the contract zeroes its reserve; an expired one that never completed shows how far it got", async () => {
  reset();
  const progress = async (nft: string) => (await mv.momentStatusV2(nft, { net: NET, now: NOW })).progress;
  assertEquals(await progress(NFT_A), 0.075);
  assertEquals(await progress(NFT_P), 1);
  // Graduated: reserve 0 on chain, the threshold reached.
  assertEquals([await progress(NFT_G), (await mv.momentStatusV2(NFT_G, { net: NET, now: NOW })).reserve], [1, "0"]);
  // Expired while Collecting: the reserve share of what was collected (75% of 4 USDC of a 10 USDC threshold).
  chain.moments.get(NFT_E)!.l.total_gross = 40_000_000n;
  assertEquals(await progress(NFT_E), 0.3);
  // Expired after completing (the backstop or a recorded failure): it had reached the threshold.
  chain.moments.get(NFT_E)!.l.completed_at = NOW_S - 40 * DAY;
  assertEquals(await progress(NFT_E), 1);
  // Never 1 for one that didn't complete, whatever the rounding of its collects.
  const m = { threshold: 100_000_000n, reserveBps: 7_500 };
  assertEquals(mv.progressOf(m, { state: "expired", completedAt: 0, reserve: 0n, totalGross: 133_333_340n }), 0.999999);
  assertEquals(mv.progressOf(m, { state: "collecting", completedAt: 0, reserve: 0n, totalGross: 0n }), 0);
});

// ------------------------------------------------------------------------------------------------ vesting

Deno.test("vesting: collectors 60/80/100% at 0/1/2 periods and the creator 20% + 16% a period from graduation, with the contract's claimable", async () => {
  reset();
  const start = NOW_S - 31 * DAY;
  const v = await mv.momentVestingV2(NFT_G, ME, NET, NOW);
  assertEquals([v.state, v.vests, v.vestPeriodSecs, v.startsAt, v.periodsElapsed, v.coin], ["graduated", true, 30 * DAY, iso(start), 1, C(40)]);
  assertEquals(v.claimable, { collector: "200000000", creator: "16000000000000", total: "16000200000000" });
  assertEquals(v.collector, {
    total: "1000000000",
    claimed: "600000000",
    claimable: "200000000",
    vested: "800000000",
    tranches: [
      { period: 0, at: iso(start), vestedBps: 6_000, vested: "600000000" },
      { period: 1, at: iso(start + 30 * DAY), vestedBps: 8_000, vested: "800000000" },
      { period: 2, at: iso(start + 60 * DAY), vestedBps: 10_000, vested: "1000000000" },
    ],
    nextAt: iso(start + 60 * DAY),
    fullAt: iso(start + 60 * DAY),
  });
  // The creator's allocation: 10% of S, 36% vested after one period.
  assertEquals([v.creator?.total, v.creator?.claimed, v.creator?.vested, v.creator?.nextAt, v.creator?.fullAt], [
    "100000000000000",
    "20000000000000",
    "36000000000000",
    iso(start + 60 * DAY),
    iso(start + 150 * DAY),
  ]);
  assertEquals(v.creator?.tranches.map((t) => t.vestedBps), [2_000, 3_600, 5_200, 6_800, 8_400, 10_000]);

  // Someone else: no creator side, nothing promised.
  const other = await mv.momentVestingV2(NFT_G, SOMEONE, NET, NOW);
  assertEquals([other.collector, other.creator, other.claimable.total], [null, null, "0"]);
  // Before graduation the schedule has no times yet; an expired Moment's coins never exist.
  chain.positions.set(`${NFT_A}|${ME}`, { entitlement: 2_000_000_000n, claimed: 0n });
  const early = await mv.momentVestingV2(NFT_A, ME, NET, NOW);
  assertEquals([early.startsAt, early.collector?.tranches.map((t) => t.at), early.collector?.nextAt, early.claimable.total], [null, [null, null, null], null, "0"]);
  chain.positions.set(`${NFT_E}|${ME}`, { entitlement: 2_000_000_000n, claimed: 0n });
  const expired = await mv.momentVestingV2(NFT_E, ME, NET, NOW);
  assertEquals([expired.vests, expired.collector, expired.creator], [false, null, null]);
  assertEquals((await refusedWith(() => mv.momentVestingV2(NFT_G, "nobody", NET, NOW))).slice(0, 2), [400, "bad_arg"]);
});

// ------------------------------------------------------------------------------------------------ publish

Deno.test("publish refuses a bad ticker or name before reading anything, with a clear error", async () => {
  reset();
  writeMetadata();
  queries = [];
  const base = { action: "publish", uri: URI, symbol: "DUSK", price: "10000000", allocationBps: 500, windowSecs: 86_400 };
  for (const symbol of ["D", "DUSKATDUSK1", "DU-SK", "DÜSK", "", 42]) {
    const err = await refusedWith(() => mv.momentV2Steps(ME, { ...base, symbol }, NET, NOW));
    assertEquals(err.slice(0, 2), [400, "bad_symbol"], String(symbol));
  }
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { ...base, symbol: "U5DC" }, NET, NOW))).slice(0, 2), [400, "look_alike_symbol"]);
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { ...base, name: "x".repeat(33) }, NET, NOW))).slice(0, 2), [400, "bad_name"]);
  assertEquals([chain.calls, queries], [[], []]);
  // A title too long for the NFT's name, with no name given.
  writeMetadata("Accra at dusk, from the lighthouse at Jamestown");
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, base, NET, NOW))).slice(0, 2), [400, "bad_name"]);
  // Only the creator's own metadata.
  assertEquals((await refusedWith(() => mv.momentV2Steps(SOMEONE, base, NET, NOW))).slice(0, 2), [400, "bad_uri"]);
});

Deno.test("publish refuses a price outside the minimum and the ceiling, an allocation above the maximum, a window outside the durations, and a pause", async () => {
  reset();
  writeMetadata();
  const base = { action: "publish", uri: URI, symbol: "DUSK", price: "10000000", allocationBps: 500, windowSecs: 86_400 };
  const refused = (over: Record<string, unknown>) => refusedWith(() => mv.momentV2Steps(ME, { ...base, ...over }, NET, NOW));
  assertEquals(await refused({ price: "999999" }), [422, "simulation_failed", "moment.price_too_low", "PriceTooLow"]);
  // No stable code in the API contract (§6.13): named, with its own text.
  assertEquals(await refused({ price: "133333335" }), [422, "simulation_failed", undefined, "PriceTooHigh"]);
  assertEquals((await refused({ allocationBps: 1_001 })).slice(0, 2), [400, "bad_arg"]);
  assertEquals((await refused({ windowSecs: 3_599 })).slice(0, 2), [400, "bad_window"]);
  assertEquals((await refused({ windowSecs: 30 * DAY + 1 })).slice(0, 2), [400, "bad_window"]);
  // Either pause: governance's on publishing, or the guardian's on everything.
  chain.config.publishing_paused = true;
  assertEquals(await refused({}), [422, "simulation_failed", undefined, "PublishingPaused"]);
  chain.config.publishing_paused = false;
  chain.config.guardian_paused = true;
  assertEquals(await refused({}), [422, "simulation_failed", undefined, "PublishingPaused"]);
  // The ceiling itself and the minimum are fine.
  chain.config.guardian_paused = false;
  assertEquals((await mv.momentV2Steps(ME, { ...base, price: "133333334" }, NET, NOW)).kind, "moment_publish");
  assertEquals((await mv.momentV2Steps(ME, { ...base, price: "1000000", allocationBps: 0, windowSecs: 3_600 }, NET, NOW)).kind, "moment_publish");
});

Deno.test("publish is refused when the live terms don't match the deployment's pins: the durations, the executor (503)", async () => {
  reset();
  writeMetadata();
  const base = { action: "publish", uri: URI, symbol: "DUSK", price: "10000000" };
  chain.durations.pending_backstop = 29 * DAY;
  const err = await mv.momentV2Steps(ME, base, NET, NOW).catch((e) => e);
  assertEquals([err.status, err.code, err.detail.differs], [503, "not_deployed", ["durations.pendingBackstop"]]);
  chain.durations.pending_backstop = 30 * DAY;
  chain.executor = C(6);
  assertEquals((await mv.momentV2Steps(ME, base, NET, NOW).catch((e) => e)).detail.differs, ["executor"]);
});

Deno.test("publish: a random 64-bit nonce, the NFT and coin addresses the contracts derive, the media's SHA-256, the provenance, and a USDC trust step when the creator lacks it", async () => {
  reset();
  writeMetadata();
  const input = { action: "publish", uri: URI, name: "Dusk", symbol: "dusk", price: "10000000", allocationBps: 500, windowSecs: 86_400 };
  const first = await mv.momentV2Steps(ME, input, NET, NOW);
  assertEquals([first.kind, first.steps.map((s) => s.label)], ["moment_publish", ["Enable USDC", "Publish DUSK"]]);
  assertEquals(first.steps[0].spec, { kind: "trust", asset: USDC.classic });
  const spec = first.steps[1].spec;
  const nonce = BigInt(String(spec.nonce));
  assert(nonce >= 0n && nonce < 2n ** 64n);
  assertEquals(spec.nft, nftAddress(ME, nonce));
  assertEquals(spec.coin, coinAddress(String(spec.nft)));
  const hash = Buffer.from(sha256(PHOTO_BYTES)).toString("hex");
  assertEquals(spec, {
    kind: "moment_v2_publish",
    uri: URI,
    name: "Dusk",
    symbol: "DUSK",
    price: "10000000",
    allocationBps: 500,
    windowSecs: 86_400,
    place: "Accra",
    date: "2026-10-14",
    mediaHash: hash,
    nonce: spec.nonce,
    nft: spec.nft,
    coin: spec.coin,
  });
  // Another plan, another nonce; with the trustline, no trust step.
  trustlines = [USDC.classic!];
  const second = await mv.momentV2Steps(ME, input, NET, NOW);
  assertEquals(second.steps.map((s) => s.label), ["Publish DUSK"]);
  assertNotEquals(second.steps[0].spec.nonce, spec.nonce);
});

Deno.test("publish's transaction passes the terms by value, and its intent the policy values and durations the phone shows for the terms guard", async () => {
  reset();
  writeMetadata();
  trustlines = [USDC.classic!];
  const e = await mv.momentsEconomicsV2(NET, NOW);
  const { steps } = await mv.momentV2Steps(ME, { action: "publish", uri: URI, name: "Dusk", symbol: "DUSK", price: "10000000", allocationBps: 1_000, windowSecs: 86_400 }, NET, NOW);
  const spec = steps[0].spec;
  const built = await mv.momentPublishStep(ME, spec, NET);
  const { tx, intent } = built;
  assertEquals([fnOf(tx), intent.kind, intent.spend, intent.calls, built.stepKind], ["publish", "moment_publish", {}, [{ contract: MOMENTS, fn: "publish" }], "moment_publish"]);
  const args = argsOf(tx);
  assertEquals(native(args[0]), ME);
  // The terms, exactly as terms() answered them.
  assertEquals(args[2].toXDR("base64"), termsVal().toXDR("base64"));
  const p = native(args[1]);
  assertEquals(
    [p.name, p.symbol, p.metadata_uri, Buffer.from(p.media_hash).toString("hex"), p.place, p.date, p.price, p.creator_alloc_bps, p.window_secs, String(p.nonce)],
    ["Dusk", "DUSK", URI, spec.mediaHash, "Accra", "2026-10-14", 10_000_000n, 1_000, 86_400n, spec.nonce],
  );
  // What the phone shows: every policy value and duration, as /v1/economics serves them, so its guard can compare.
  const shown = mv.termsDisplay(e.terms);
  for (const k of mv.TERMS_DISPLAY_KEYS) assertEquals(intent.display![k], shown[k], k);
  assertEquals(
    [intent.display!.pendingBackstop, intent.display!.stuckExpiry, intent.display!.vestPeriod, intent.display!.harvestBps, intent.display!.minPrice, intent.display!.treasury],
    [30 * DAY, 7 * DAY, 30 * DAY, 6_667, "1000000", G(6)],
  );
  assertEquals(
    [intent.display!.generation, intent.display!.nft, intent.display!.coin, intent.display!.allocationBps, intent.display!.completionGross, intent.display!.fdvAtOpen],
    [2, spec.nft, spec.coin, 1_000, "133333334", "259259259"],
  );
  mv.verifyMomentsV2Call(tx, intent, v2Ctx());

  // Terms that change before the step is built show in the intent: the phone's guard sees they differ.
  chain.policy.royalty_bps = 300;
  const later = await mv.momentPublishStep(ME, spec, NET);
  assertEquals([later.intent.display!.royaltyBps, shown.royaltyBps], [300, 500]);
  // A display that isn't what the transaction passes is refused.
  assertRuleRefuses(tx, { ...intent, display: { ...intent.display, royaltyBps: 0 } }, "the terms are not the ones shown");
  assertRuleRefuses(tx, { ...intent, display: { ...intent.display, price: "20000000" } }, "the call's arguments are not as expected");
  assertRuleRefuses(tx, intent, "the transaction is not from your account", SOMEONE);
});

// ------------------------------------------------------------------------------------------------ collect

Deno.test("collect spends max_total in USDC only: the quote's gross, which a terminal collect clamps to what completes the reserve", async () => {
  reset();
  const { kind, steps } = await mv.momentV2Steps(ME, { action: "collect", nft: NFT_A, quantity: 3 }, NET, NOW);
  assertEquals([kind, steps[0].label, steps[0].spec], ["moment_collect", "Collect 3", {
    kind: "moment_v2_collect",
    nft: NFT_A,
    quantity: 3,
    maxTotal: "30000000",
    editions: 3,
    entitlement: "6000000000",
    terminal: false,
  }]);
  const built = await mv.momentCollectStep(ME, steps[0].spec, NET);
  const { tx, intent } = built;
  assertEquals([intent.kind, intent.spend, intent.calls, built.stepKind], ["moment_collect", { [USDC.contract]: "30000000" }, [{ contract: MOMENTS, fn: "collect" }], "moment_collect"]);
  assertEquals(argsOf(tx).map(native), [ME, NFT_A, 3, 30_000_000n]);
  assertEquals(intent.display, { generation: 2, nft: NFT_A, quantity: 3, editions: 3, total: "30000000", quote: "USDC", entitlement: "6000000000", terminal: false });
  mv.verifyMomentsV2Call(tx, intent, v2Ctx());
  // The server's verifier passes it too: the collector is the user, and the USDC it authorizes is within the spend.
  assertEquals(verifyTransaction(tx, intent, verifyCtx).outflow, { [USDC.contract]: "30000000" });

  // The terminal collect: 20 asked, the 14 the clamped gross pays for.
  chain.quotes.set(NFT_A, { gross: 133_333_334n, editions: 14, entitlement: 28_000_000_000n, terminal: true });
  const terminal = await mv.momentV2Steps(ME, { action: "collect", nft: NFT_A, quantity: 20 }, NET, NOW);
  assertEquals([terminal.steps[0].label, terminal.steps[0].spec.maxTotal, terminal.steps[0].spec.terminal], ["Collect 14", "133333334", true]);

  // The rules refuse a spend below the call's max_total, another asset, another Moment and another account.
  assertRuleRefuses(tx, { ...intent, spend: { [USDC.contract]: "29999999" } }, "the call's arguments are not as expected");
  assertRuleRefuses(tx, { ...intent, spend: { [USDC.contract]: "30000000", [TESTNET.assets[0].contract]: "1" } }, "the call's arguments are not as expected");
  assertRuleRefuses(tx, { ...intent, display: { ...intent.display, nft: NFT_P } }, "the call is for another Moment than the one shown");
  assertRuleRefuses(tx, { ...intent, display: { ...intent.display, quantity: 2 } }, "the call's arguments are not as expected");
});

Deno.test("collect's refusals: a closed window, a Moment no longer collecting (worded by its state), an unknown one (404) and a bad quantity, before anyone signs", async () => {
  reset();
  const collect = (nft: string, quantity: unknown = 1) => refusedWith(() => mv.momentV2Steps(ME, { action: "collect", nft, quantity }, NET, NOW));
  const message = (nft: string) => mv.momentV2Steps(ME, { action: "collect", nft }, NET, NOW).then(() => "", (e) => e.message);
  // The contract refuses every state but Collecting alike (NotCollecting): the text says which, read from the ledger.
  assertEquals(await collect(NFT_P), [422, "simulation_failed", undefined, "NotCollecting"]);
  assertEquals(await message(NFT_P), "This Moment reached its goal and isn't collecting any more.");
  assertEquals(await message(NFT_G), "This Moment reached its goal and has graduated. It isn't collecting any more.");
  // An expired Moment may never have reached its goal.
  assertEquals(await message(NFT_E), "This Moment has ended. It isn't collecting any more.");
  chain.moments.get(NFT_A)!.m.deadline = NOW_S;
  assertEquals(await collect(NFT_A), [422, "simulation_failed", "moment.closed", "WindowClosed"]);
  assertEquals((await collect(C(99))).slice(0, 2), [404, "not_found"]);
  assertEquals((await collect(NFT_A, 0)).slice(0, 2), [400, "bad_quantity"]);
  assertEquals((await collect(NFT_A, 21)).slice(0, 2), [400, "bad_quantity"]);
  assertEquals((await collect("7")).slice(0, 2), [400, "bad_moment"]);
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { action: "mark_stuck", nft: NFT_P }, NET, NOW))).slice(0, 2), [400, "bad_action"]);
});

// ------------------------------------------------------------------------------------------------ claims and proceeds

Deno.test("claim and claim all act for the user and spend nothing; claim all takes at most 20 and leaves out Moments with nothing due", async () => {
  reset();
  const claim = await mv.momentV2Steps(ME, { action: "claim", nft: NFT_G }, NET, NOW);
  assertEquals([claim.kind, claim.steps[0].spec], ["moment_claim", { kind: "moment_v2_claim", nft: NFT_G, coin: C(40), collector: "200000000", creator: "16000000000000" }]);
  const one = await mv.momentClaimStep(ME, claim.steps[0].spec, NET);
  assertEquals([fnOf(one.tx), argsOf(one.tx).map(native), one.intent.spend], ["claim", [ME, NFT_G], {}]);
  assertEquals(one.intent.display, { generation: 2, nft: NFT_G, coin: C(40), collectorAmount: "200000000", creatorAmount: "16000000000000", total: "16000200000000" });
  mv.verifyMomentsV2Call(one.tx, one.intent, v2Ctx());
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { action: "claim", nft: NFT_A }, NET, NOW))), [422, "simulation_failed", undefined, "NothingToClaim"]);

  const all = await mv.momentV2Steps(ME, { action: "claim_all", nfts: [NFT_A, NFT_G, NFT_P, NFT_G] }, NET, NOW);
  assertEquals([all.kind, all.steps[0].label, all.steps[0].spec], ["moment_claim_all", "Claim coins from 1 Moment", { kind: "moment_v2_claim_all", nfts: [NFT_G], total: "16000200000000" }]);
  const many = await mv.momentClaimAllStep(ME, all.steps[0].spec, NET);
  assertEquals([fnOf(many.tx), argsOf(many.tx).map(native), many.intent.spend], ["claim_all", [ME, [NFT_G]], {}]);
  mv.verifyMomentsV2Call(many.tx, many.intent, v2Ctx());
  assertRuleRefuses(many.tx, { ...many.intent, display: { ...many.intent.display, nfts: `${NFT_G},${NFT_A}` } }, "the call is for another Moment than the one shown");
  const twentyOne = Array.from({ length: 21 }, (_, i) => C(100 + i));
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { action: "claim_all", nfts: twentyOne }, NET, NOW))).slice(0, 2), [400, "bad_arg"]);
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { action: "claim_all", nfts: [NFT_A, NFT_P] }, NET, NOW))), [422, "simulation_failed", undefined, "NothingToClaim"]);
  // A Moment the main stack doesn't have (another stack's, a v1 id) is skipped, as the contract's claim_all skips it.
  const skipped = await mv.momentV2Steps(ME, { action: "claim_all", nfts: [C(99), NFT_G, NFT_QA] }, NET, NOW);
  assertEquals(skipped.steps[0].spec, { kind: "moment_v2_claim_all", nfts: [NFT_G], total: "16000200000000" });
  assertEquals((await refusedWith(() => mv.momentV2Steps(ME, { action: "claim_all", nfts: [C(99)] }, NET, NOW))), [422, "simulation_failed", undefined, "NothingToClaim"]);
  // A claim for another account is refused by the rules.
  assertRuleRefuses(one.tx, one.intent, "the transaction is not from your account", SOMEONE);
});

Deno.test("withdraw: the creator's proceeds only, after a USDC trust step when needed; anyone may call it, so it carries no authorization", async () => {
  reset();
  const plan = await mv.momentV2Steps(ME, { action: "withdraw", nft: NFT_G }, NET, NOW);
  assertEquals([plan.kind, plan.steps.map((s) => s.label)], ["moment_withdraw", ["Enable USDC", "Withdraw proceeds"]]);
  const built = await mv.momentWithdrawStep(ME, plan.steps[1].spec, NET);
  assertEquals([fnOf(built.tx), argsOf(built.tx).map(native), built.intent.spend, (built.tx.operations[0] as any).auth ?? []], ["withdraw_creator", [NFT_G], {}, []]);
  assertEquals(built.intent.display, { generation: 2, nft: NFT_G, amount: "5000000", quote: "USDC", to: ME });
  mv.verifyMomentsV2Call(built.tx, built.intent, v2Ctx());
  trustlines = [USDC.classic!];
  assertEquals((await mv.momentV2Steps(ME, { action: "withdraw", nft: NFT_G }, NET, NOW)).steps.map((s) => s.label), ["Withdraw proceeds"]);
  assertEquals((await refusedWith(() => mv.momentV2Steps(SOMEONE, { action: "withdraw", nft: NFT_G }, NET, NOW))).slice(0, 2), [400, "bad_arg"]);
  chain.moments.get(NFT_G)!.l.creator_claimable = 0n;
  assertEquals(await refusedWith(() => mv.momentV2Steps(ME, { action: "withdraw", nft: NFT_G }, NET, NOW)), [422, "simulation_failed", undefined, "NothingToWithdraw"]);

  // A permissionless call that carries the user's authorization is refused.
  chain.authEverything = true;
  const signed = await mv.momentWithdrawStep(ME, plan.steps[1].spec, NET).catch((e) => e);
  assertEquals([signed.status, signed.code, signed.detail.reason], [500, "self_check_failed", "a call anyone may make carries your authorization"]);
});

// ------------------------------------------------------------------------------------------------ graduate and expire

Deno.test("graduate is anyone's: the intent says whether it graduates or records a named failure; an abort is refused with the expiry time; there is no mark_stuck (finding F15)", async () => {
  reset();
  const failing = await mv.momentV2Steps(ME, { action: "graduate", nft: NFT_P }, NET, NOW);
  assertEquals([failing.kind, failing.steps[0].spec], ["moment_graduate", { kind: "moment_v2_graduate", nft: NFT_P, outcome: "failed", origin: 10, code: 11_003 }]);
  const built = await mv.momentGraduateStep(ME, failing.steps[0].spec, NET);
  assertEquals([fnOf(built.tx), argsOf(built.tx).map(native), built.intent.spend, (built.tx.operations[0] as any).auth ?? []], ["graduate", [NFT_P], {}, []]);
  assertEquals(built.intent.display, { generation: 2, nft: NFT_P, outcome: "failed", failureOrigin: 10, failureCode: 11_003, failureName: "GraduationInvalid" });
  mv.verifyMomentsV2Call(built.tx, built.intent, v2Ctx());
  assertEquals(verifyTransaction(built.tx, built.intent, verifyCtx).outflow, {});

  chain.graduate.set(NFT_P, ["Graduated", C(30)]);
  const ok = await mv.momentV2Steps(ME, { action: "graduate", nft: NFT_P }, NET, NOW);
  assertEquals((await mv.momentGraduateStep(ME, ok.steps[0].spec, NET)).intent.display!.outcome, "graduated");
  // An attempt that aborts (moments-v2's own GraduationInvalid, 10_731) records nothing: refused, with when it can expire.
  chain.graduate.set(NFT_P, { error: errorLog(10_731) });
  const aborted = await mv.momentV2Steps(ME, { action: "graduate", nft: NFT_P }, NET, NOW).catch((e) => e);
  assertEquals([aborted.status, aborted.code, aborted.detail.contractCode, aborted.detail.expiresAt], [422, "simulation_failed", undefined, iso(NOW_S - 7_200 + 30 * DAY)]);
  assertEquals(aborted.message, `This Moment's graduation can't run, and the attempt can't be recorded. It can expire from ${iso(NOW_S - 7_200 + 30 * DAY)}.`);
  assertEquals(await refusedWith(() => mv.momentV2Steps(ME, { action: "graduate", nft: NFT_A }, NET, NOW)), [422, "simulation_failed", undefined, "WrongState"]);
  assertEquals(Object.keys(mv.PLAN_KINDS).includes("mark_stuck"), false);
});

Deno.test("graduate after a recorded failure: offered only when it would graduate; another failing attempt changes nothing on chain, so it is refused, at the plan and as the step is built (§20.6)", async () => {
  reset();
  const graduate = () => mv.momentV2Steps(ME, { action: "graduate", nft: NFT_P }, NET, NOW);
  // The first failure is worth recording: it starts the stuck clock.
  const first = await graduate();
  assertEquals(first.steps[0].spec.outcome, "failed");

  // Recorded: an attempt that fails again keeps stuck_since and the expiry time, so the user would pay for nothing.
  chain.moments.get(NFT_P)!.l.stuck_since = NOW_S - 3_600;
  const failureAt = iso(NOW_S - 3_600 + 7 * DAY);
  const again = await graduate().catch((e) => e);
  assertEquals([again.status, again.code, again.detail.expiresAt, again.detail.failure], [422, "simulation_failed", failureAt, {
    origin: 10,
    code: 11_003,
    name: "GraduationInvalid",
    source: "moments-graduator",
    seen: "simulated",
  }]);
  assertEquals(again.message, `This Moment's graduation still fails, and its failure is already recorded: another attempt changes nothing. It can expire from ${failureAt}.`);
  // A plan made before the failure was recorded isn't built either: the step simulates again.
  const late = await mv.momentGraduateStep(ME, first.steps[0].spec, NET).catch((e) => e);
  assertEquals([late.status, late.detail.expiresAt], [422, failureAt]);

  // One that would graduate is offered, and its step says so whatever the plan found.
  chain.graduate.set(NFT_P, ["Graduated", C(30)]);
  assertEquals((await graduate()).steps[0].spec.outcome, "graduated");
  const built = await mv.momentGraduateStep(ME, first.steps[0].spec, NET);
  assertEquals([built.intent.display!.outcome, built.intent.display!.failureName, built.intent.summary], ["graduated", null, "Graduate the Moment"]);
});

Deno.test("expire: refused before the Moment's expiry time, with that time; then the backstop or the failure clock, 70/30; anyone's to call", async () => {
  reset();
  const expire = (nft: string, now: number) => mv.momentV2Steps(ME, { action: "expire", nft }, NET, now);
  // Pending without a recorded failure: the backstop, 30 days after completion.
  const backstopAt = NOW_S - 7_200 + 30 * DAY;
  const early = await expire(NFT_P, NOW).catch((e) => e);
  assertEquals([early.status, early.detail.contractCode, early.detail.contractError.name, early.detail.expiresAt], [422, undefined, "NotExpirable", iso(backstopAt)]);
  const late = await expire(NFT_P, backstopAt * 1000);
  assertEquals([late.kind, late.steps[0].spec], ["moment_expire", { kind: "moment_v2_expire", nft: NFT_P, backstop: true, reserve: "100000000", creatorShare: "70000000", treasuryShare: "30000000" }]);
  const built = await mv.momentExpireStep(ME, late.steps[0].spec, NET);
  assertEquals([fnOf(built.tx), argsOf(built.tx).map(native), built.intent.spend, (built.tx.operations[0] as any).auth ?? []], ["expire", [NFT_P], {}, []]);
  assertEquals(built.intent.display, { generation: 2, nft: NFT_P, backstop: true, reserve: "100000000", creatorShare: "70000000", treasuryShare: "30000000", quote: "USDC" });
  mv.verifyMomentsV2Call(built.tx, built.intent, v2Ctx());
  // A recorded failure: 7 days after it, not the backstop.
  chain.moments.get(NFT_P)!.l.stuck_since = NOW_S - 3_600;
  assertEquals((await expire(NFT_P, (NOW_S - 3_600 + 7 * DAY) * 1000)).steps[0].spec.backstop, false);
  // Its clock running out with the backstop's: the failure branch, as the status labels it.
  chain.moments.get(NFT_P)!.l.stuck_since = backstopAt - 7 * DAY;
  assertEquals((await mv.momentStatusV2(NFT_P, { net: NET, now: NOW, recorded: { origin: 3, code: 10_304 } })).expiresBy, "failure");
  assertEquals((await expire(NFT_P, backstopAt * 1000)).steps[0].spec.backstop, false);
  // Collecting: from its deadline. Graduated and Expired: never.
  assertEquals((await expire(NFT_A, NOW).catch((e) => e)).detail.expiresAt, iso(NOW_S + DAY));
  assertEquals((await expire(NFT_A, (NOW_S + DAY) * 1000)).steps[0].spec.backstop, false);
  assertEquals(await refusedWith(() => expire(NFT_G, NOW)), [422, "simulation_failed", undefined, "WrongState"]);
  assertEquals(await refusedWith(() => expire(NFT_E, NOW)), [422, "simulation_failed", undefined, "WrongState"]);
});

// ------------------------------------------------------------------------------------------------ the call rules

/** `tx`'s call again from the user, with other arguments and authorization: what a builder bug or a tampered server
 *  could hand the phone. */
function recalled(tx: Transaction, args: xdr.ScVal[], auth: xdr.SorobanAuthorizationEntry[] = (tx.operations[0] as any).auth ?? []): Transaction {
  return new TransactionBuilder(new Account(ME, "1"), { fee: "100", networkPassphrase: TESTNET.passphrase })
    .addOperation(Operation.invokeContractFunction({ contract: MOMENTS, function: fnOf(tx), args, auth }))
    .setTimeout(300)
    .build();
}

/** The source account's authorization of moments-v2's `fn(args)`, with `subs` under it. */
const sourceAuth = (fn: string, args: xdr.ScVal[], subs: xdr.SorobanAuthorizedInvocation[] = []) =>
  new xdr.SorobanAuthorizationEntry({ credentials: xdr.SorobanCredentials.sorobanCredentialsSourceAccount(), rootInvocation: authorized(MOMENTS, fn, args, subs) });

Deno.test("the call rules: publish, collect, claim and claim all refuse a call for another account, sent from the user's own", async () => {
  reset();
  writeMetadata();
  trustlines = [USDC.classic!];
  const forAnother = (tx: Transaction, intent: any) => {
    const args = argsOf(tx);
    assertRuleRefuses(recalled(tx, [addr(SOMEONE), ...args.slice(1)]), intent, "the call acts for another account");
    // A contract address in its place too.
    assertRuleRefuses(recalled(tx, [addr(MOMENTS), ...args.slice(1)]), intent, "the call acts for another account");
  };
  const { steps } = await mv.momentV2Steps(ME, { action: "publish", uri: URI, symbol: "DUSK", price: "10000000" }, NET, NOW);
  const publish = await mv.momentPublishStep(ME, steps[0].spec, NET);
  forAnother(publish.tx, publish.intent);
  const collect = await mv.momentCollectStep(ME, (await mv.momentV2Steps(ME, { action: "collect", nft: NFT_A, quantity: 3 }, NET, NOW)).steps[0].spec, NET);
  forAnother(collect.tx, collect.intent);
  const claim = await mv.momentClaimStep(ME, (await mv.momentV2Steps(ME, { action: "claim", nft: NFT_G }, NET, NOW)).steps[0].spec, NET);
  forAnother(claim.tx, claim.intent);
  const all = await mv.momentClaimAllStep(ME, (await mv.momentV2Steps(ME, { action: "claim_all", nfts: [NFT_G] }, NET, NOW)).steps[0].spec, NET);
  forAnother(all.tx, all.intent);
  // Each as built passes.
  for (const b of [publish, collect, claim, all]) mv.verifyMomentsV2Call(b.tx, b.intent, v2Ctx());
});

Deno.test("the call rules: collect's only sub-authorization is the USDC pull from the user to moments-v2, within the spend", async () => {
  reset();
  const { tx, intent } = await mv.momentCollectStep(ME, (await mv.momentV2Steps(ME, { action: "collect", nft: NFT_A, quantity: 3 }, NET, NOW)).steps[0].spec, NET);
  const args = argsOf(tx);
  const pull = (token = USDC.contract, from = ME, to = MOMENTS, amount = 30_000_000n, fn = "transfer", subs: xdr.SorobanAuthorizedInvocation[] = []) =>
    authorized(token, fn, [addr(from), addr(to), i128(amount)], subs);
  const withSubs = (...subs: xdr.SorobanAuthorizedInvocation[]) => recalled(tx, args, [sourceAuth("collect", args, subs)]);
  // As the host records it: passes.
  mv.verifyMomentsV2Call(withSubs(pull()), intent, v2Ctx());
  mv.verifyMomentsV2Call(withSubs(pull(USDC.contract, ME, MOMENTS, 29_000_000n)), intent, v2Ctx());

  const SPENDS_MORE = "the transaction spends more than this action declares";
  // Another token, another recipient, another payer, more than the spend, another token function.
  assertRuleRefuses(withSubs(pull(TESTNET.assets[0].contract)), intent, SPENDS_MORE);
  assertRuleRefuses(withSubs(pull(USDC.contract, ME, SOMEONE)), intent, SPENDS_MORE);
  assertRuleRefuses(withSubs(pull(USDC.contract, SOMEONE)), intent, SPENDS_MORE);
  assertRuleRefuses(withSubs(pull(USDC.contract, ME, MOMENTS, 30_000_001n)), intent, SPENDS_MORE);
  assertRuleRefuses(withSubs(pull(USDC.contract, ME, MOMENTS, 30_000_000n, "approve")), intent, SPENDS_MORE);
  // More than the one pull: a second one, or anything under it.
  const COVERS_MORE = "the authorization covers more than this call";
  assertRuleRefuses(withSubs(pull(), pull()), intent, COVERS_MORE);
  assertRuleRefuses(withSubs(pull(USDC.contract, ME, MOMENTS, 30_000_000n, "transfer", [pull()])), intent, COVERS_MORE);
  assertRuleRefuses(withSubs(), intent, COVERS_MORE);
  // A second authorization entry, a root that isn't the call, or another signer.
  assertRuleRefuses(recalled(tx, args, [sourceAuth("collect", args, [pull()]), sourceAuth("claim", [addr(ME), addr(NFT_G)])]), intent, "the transaction asks for more authorization than this call");
  assertRuleRefuses(recalled(tx, args, [sourceAuth("collect", [addr(ME), addr(NFT_A), u32(3), i128(40_000_000n)], [pull()])]), intent, "the authorization is not for this call");
  const signer = new xdr.SorobanAuthorizationEntry({
    credentials: xdr.SorobanCredentials.sorobanCredentialsAddress(
      new xdr.SorobanAddressCredentials({ address: new Address(SOMEONE).toScAddress(), nonce: xdr.Int64.fromString("1"), signatureExpirationLedger: 1, signature: xdr.ScVal.scvVoid() }),
    ),
    rootInvocation: authorized(MOMENTS, "collect", args, [pull()]),
  });
  assertRuleRefuses(recalled(tx, args, [signer]), intent, "the transaction needs a signature from another address");
});

/** Every builder's transaction, as plans.ts builds the step. */
async function everyBuilt() {
  writeMetadata();
  trustlines = [USDC.classic!];
  const step = async (input: Record<string, unknown>, now = NOW) => (await mv.momentV2Steps(ME, input, NET, now)).steps[0].spec;
  const backstopAt = NOW_S - 7_200 + 30 * DAY;
  return {
    publish: await mv.momentPublishStep(ME, await step({ action: "publish", uri: URI, symbol: "DUSK", price: "10000000" }), NET),
    collect: await mv.momentCollectStep(ME, await step({ action: "collect", nft: NFT_A, quantity: 3 }), NET),
    claim: await mv.momentClaimStep(ME, await step({ action: "claim", nft: NFT_G }), NET),
    claim_all: await mv.momentClaimAllStep(ME, await step({ action: "claim_all", nfts: [NFT_G] }), NET),
    withdraw: await mv.momentWithdrawStep(ME, await step({ action: "withdraw", nft: NFT_G }), NET),
    graduate: await mv.momentGraduateStep(ME, await step({ action: "graduate", nft: NFT_P }), NET),
    expire: await mv.momentExpireStep(ME, await step({ action: "expire", nft: NFT_P }, backstopAt * 1000), NET),
  };
}

Deno.test("every builder's transaction verifies against its intent with the v2 call rules (moments_v2.ts, which the verifiers take over in CT-16)", async () => {
  reset();
  for (const [action, b] of Object.entries(await everyBuilt())) {
    mv.verifyMomentsV2Call(b.tx, b.intent, v2Ctx());
    assertEquals(b.intent.kind, mv.PLAN_KINDS[action as keyof typeof mv.PLAN_KINDS], action);
  }
});

// plans.ts runs the server verifier on every step it builds. Until CT-16 gives verify.ts the v2 rules, chosen per
// contract (v1's publish and collect share v2's names, §20.4), it refuses publish (v1's arity) and the functions it has
// no rule for, and plans.ts answers 500 self_check_failed for them: CT-16 turns this test on.
Deno.test({
  name: "the server verifier (verify.ts) passes every builder's transaction against its intent, as plans.ts runs it",
  ignore: true,
  fn: async () => {
    reset();
    for (const [action, b] of Object.entries(await everyBuilt())) {
      try {
        verifyTransaction(b.tx, b.intent, verifyCtx);
      } catch (err) {
        throw new Error(`${action}: ${(err as Error).message}`);
      }
    }
  },
});

// ------------------------------------------------------------------------------------------------ refusals

Deno.test("refusals: moments-v2's own errors by name, from their namespaced codes; another contract's code isn't moments-v2's", () => {
  assertEquals(mv.momentsV2ErrorName(errorLog(10_708)), "UnknownMoment");
  assertEquals(mv.momentsV2ErrorName(errorLog(10_731)), "GraduationInvalid");
  // A token's balance error passes through moments-v2's frame with the token's own code.
  assertEquals(mv.momentsV2ErrorName(errorLog(10)), null);
  // The graduator's GraduationInvalid is origin 10, not moments-v2's.
  assertEquals(mv.momentsV2ErrorName(errorLog(11_003, GRADUATOR)), null);
  // Nothing hardcodes a code: the names come from v2_errors.ts.
  const err = mv.refusalV2("NotExpirable", { expiresAt: "2026-11-14T12:00:00.000Z" });
  assertEquals([err.status, err.code, (err.detail as Row).contractError, (err.detail as Row).expiresAt], [
    422,
    "simulation_failed",
    { origin: 7, code: 10_713, name: "NotExpirable", contract: "moments-v2" },
    "2026-11-14T12:00:00.000Z",
  ]);
  // A stable code only where the API contract has one with the same meaning (contract.ts ContractErrorCode, §6.13).
  assertEquals((mv.refusalV2("WindowClosed").detail as Row).contractCode, "moment.closed");
  assertEquals((mv.refusalV2("PriceTooLow").detail as Row).contractCode, "moment.price_too_low");
  for (const name of ["PublishingPaused", "TermsChanged", "PriceTooHigh", "NotCollecting", "NothingToClaim", "NothingToWithdraw", "NotExpirable", "WrongState"] as const) {
    assertEquals((mv.refusalV2(name).detail as Row).contractCode, undefined, name);
  }
});
