// The Aquarius venue's float (docs/DESIGN-stellar-contracts-v2.md §7.2; findings F11, V8; CT-11 lead rulings (a), (b)).
//
// exec-aquarius pays the router's pool-creation fee (1 AQUA on testnet today) from an AQUA float. The deploy script:
// - compares the live router (its WASM hash, ConstantPoolHash and TokenHash) with contracts/testdata/fixtures.json
//   before it enables or funds the venue (ruling a): Aquarius can upgrade them, and CT-03's gate checked those;
// - acquires the AQUA before it deploys anything, because the venue table is a launchpad constructor argument: an
//   AQUA trustline on the deployer, then a swap XLM → AQUA through the router's XLM–AQUA 0.3% pool after a depth check.
//   It estimates 1 XLM and the full amount, and requires the full amount to return at least the target plus 10% at an
//   average rate within 3% of the 1-XLM rate, spending at most 2,000 XLM;
// - on testnet-qa runs that step by default, and deploys without exec-aquarius and the Aquarius venue when the check
//   or the swap fails, or with --aquarius off (aquarius {enabled: false, reason} in the deployment file);
// - on the owner's testnet swaps only with --fund-aqua-float; otherwise it reports the float for the owner to fund.
// Target: 50 × the pool payment on testnet (50 AQUA), 10 × on testnet-qa. 1 XLM bought 22.56 AQUA on 2026-10-14, so
// 50 AQUA plus the margin costs about 2.4 XLM (ruling b).
import { Buffer } from "node:buffer";
import { Address, Asset, type Keypair, nativeToScVal, Operation, scValToNative, xdr } from "@stellar/stellar-sdk";
import { type Chain, type ChainReader, invoke, send, STROOPS_PER_XLM, type TxOutcome } from "./preflight-v2.ts";

/** What the kit needs from fixtures.json's Aquarius records (CT-03). */
export interface AquariusFixtures {
  router: string;
  routerWasmHash: string;
  constantPoolHash: string;
  tokenHash: string;
  /** CT-03's verdict: all five gate checks passed (AQUARIUS_VENUE_OK). */
  venueOk: boolean;
  aqua: { code: string; issuer: string; sac: string };
  pool: { tokens: [string, string]; xlmSac: string; poolIndex: string; feeFraction: number };
}

export function parseAquariusFixtures(json: unknown): AquariusFixtures {
  const a = (json as any)?.aquarius;
  const need = (v: unknown, what: string): string => {
    if (typeof v !== "string" || v === "") throw new Error(`contracts/testdata/fixtures.json: ${what} is missing`);
    return v;
  };
  const tokens = a?.xlm_aqua_pool?.tokens;
  if (!Array.isArray(tokens) || tokens.length !== 2) throw new Error("contracts/testdata/fixtures.json: xlm_aqua_pool.tokens is missing");
  return {
    router: need(a?.router?.contract_id, "aquarius.router.contract_id"),
    routerWasmHash: need(a?.router?.wasm_hash, "aquarius.router.wasm_hash"),
    constantPoolHash: need(a?.router?.constant_pool_hash, "aquarius.router.constant_pool_hash"),
    tokenHash: need(a?.router?.token_hash, "aquarius.router.token_hash"),
    venueOk: a?.gate?.AQUARIUS_VENUE_OK === true,
    aqua: { code: need(a?.aqua?.code, "aquarius.aqua.code"), issuer: need(a?.aqua?.issuer, "aquarius.aqua.issuer"), sac: need(a?.aqua?.sac, "aquarius.aqua.sac") },
    pool: {
      tokens: [String(tokens[0]), String(tokens[1])],
      xlmSac: need(a?.xlm_aqua_pool?.xlm_sac, "aquarius.xlm_aqua_pool.xlm_sac"),
      poolIndex: need(a?.xlm_aqua_pool?.pool_index, "aquarius.xlm_aqua_pool.pool_index"),
      feeFraction: Number(a?.xlm_aqua_pool?.fee_fraction ?? 30),
    },
  };
}

export async function loadAquariusFixtures(root: string): Promise<AquariusFixtures> {
  return parseAquariusFixtures(JSON.parse(await Deno.readTextFile(`${root}contracts/testdata/fixtures.json`)));
}

// ------------------------------------------------------------------------------------------------ ruling (a)

export interface LiveCheck {
  ok: boolean;
  /** One line per compared value. */
  lines: { ok: boolean; label: string; live: string | null; fixture: string }[];
}

const symbolKey = (k: xdr.ScVal): string | null => {
  if (k.switch().name === "scvSymbol") return k.sym().toString();
  if (k.switch().name === "scvVec") {
    const v = k.vec() ?? [];
    if (v.length === 1 && v[0].switch().name === "scvSymbol") return v[0].sym().toString();
  }
  return null;
};

/** Ruling (a): the live router's WASM hash, ConstantPoolHash and TokenHash against fixtures.json. */
export async function aquariusLiveCheck(chain: ChainReader, fx: AquariusFixtures): Promise<LiveCheck> {
  const wasm = await chain.contractWasmHash(fx.router);
  const storage = await chain.instanceStorage(fx.router);
  const stored = (name: string): string | null => {
    const e = storage?.find((x) => symbolKey(x.key) === name);
    return e && e.val.switch().name === "scvBytes" ? Buffer.from(e.val.bytes()).toString("hex") : null;
  };
  const lines = [
    { label: "router WASM hash", live: wasm, fixture: fx.routerWasmHash },
    { label: "ConstantPoolHash", live: stored("ConstantPoolHash"), fixture: fx.constantPoolHash },
    { label: "TokenHash", live: stored("TokenHash"), fixture: fx.tokenHash },
  ].map((l) => ({ ...l, ok: l.live === l.fixture }));
  return { ok: lines.every((l) => l.ok), lines };
}

// ------------------------------------------------------------------------------------------------ the depth check

export const MAX_SWAP_STROOPS = 2_000n * STROOPS_PER_XLM;
const ONE_XLM = STROOPS_PER_XLM;

export interface DepthCheck {
  ok: boolean;
  reason: string | null;
  /** AQUA per 1 XLM, in AQUA stroops. */
  rate1: bigint;
  /** What the swap must return at least: the target plus 10%. */
  minOut: bigint;
  /** XLM to spend (stroops). */
  spend: bigint;
  /** The estimate for `spend`. */
  out: bigint;
}

/** V8's depth check against the router's estimates (`estimate(xlmIn) → aquaOut`, both in stroops). */
export async function depthCheck(
  estimate: (xlmIn: bigint) => Promise<bigint>,
  target: bigint,
  maxSpend: bigint = MAX_SWAP_STROOPS,
): Promise<DepthCheck> {
  const minOut = (target * 11n + 9n) / 10n;
  const rate1 = await estimate(ONE_XLM);
  const fail = (reason: string, spend = 0n, out = 0n): DepthCheck => ({ ok: false, reason, rate1, minOut, spend, out });
  if (rate1 <= 0n) return fail("the XLM–AQUA pool quotes nothing for 1 XLM");
  // Spend what reaches the target plus 10% at 97% of the 1-XLM rate, so the full amount passes exactly when its
  // average rate is within 3% of the 1-XLM rate.
  const spend = (minOut * ONE_XLM * 100n + rate1 * 97n - 1n) / (rate1 * 97n);
  if (spend > maxSpend) return fail(`the pool is too thin: ${fmt(minOut)} AQUA would cost more than ${fmt(maxSpend)} XLM`, spend);
  const out = await estimate(spend);
  if (out < minOut) return fail(`the pool is too thin: ${fmt(spend)} XLM returns ${fmt(out)} AQUA, below ${fmt(minOut)}`, spend, out);
  // average rate = out / spend ≥ 0.97 · rate1 / 1 XLM
  if (out * ONE_XLM * 100n < rate1 * 97n * spend) {
    return fail(`the average rate of ${fmt(spend)} XLM is more than 3% below the 1-XLM rate`, spend, out);
  }
  return { ok: true, reason: null, rate1, minOut, spend, out };
}

const fmt = (stroops: bigint) => {
  const whole = stroops / ONE_XLM;
  const frac = (stroops % ONE_XLM).toString().padStart(7, "0").replace(/0+$/, "");
  return `${whole}${frac ? "." + frac : ""}`;
};

// ------------------------------------------------------------------------------------------------ the plan

export interface AquaPlanInput {
  deployment: "testnet" | "testnet-qa";
  /** --aquarius auto|off */
  aquarius: "auto" | "off";
  fundAquaFloat: boolean;
  /** testnet-qa swaps by default; the owner's testnet only with --fund-aqua-float. */
  swapByDefault: boolean;
  fixtures: AquariusFixtures;
  live: LiveCheck | null;
  /** The router's pool payment (asset, amount) read live; null when not read (offline). */
  payment: { asset: string; amount: bigint } | null;
  targetMultiple: number;
}

export interface AquaPlan {
  enabled: boolean;
  reason: string | null;
  /** Swap before deploying anything? */
  swap: boolean;
  /** The float's target in AQUA stroops (null when the payment wasn't read). */
  target: bigint | null;
  /** Notes for the run's output. */
  notes: string[];
}

/** Whether the Aquarius venue is part of this deployment, and whether the run acquires the float. Throws on the
 *  owner's testnet when the live router no longer matches the gate (ruling a): re-run CT-03's checks, or deploy with
 *  --aquarius off. */
export function planAquarius(i: AquaPlanInput): AquaPlan {
  const target = i.payment ? i.payment.amount * BigInt(i.targetMultiple) : null;
  const off = (reason: string): AquaPlan => ({ enabled: false, reason, swap: false, target, notes: [] });
  if (i.aquarius === "off") return off("--aquarius off");
  if (!i.fixtures.venueOk) return off("CT-03's gate is no-go (AQUARIUS_VENUE_OK false)");
  const stop = (why: string): never => {
    throw new Error(`${why}. Before the Aquarius venue is enabled or funded, CT-03's gate checks must be re-run (ruling a); ` +
      `or deploy without it: --aquarius off`);
  };
  if (i.live && !i.live.ok) {
    const what = i.live.lines.filter((l) => !l.ok).map((l) => l.label).join(", ");
    if (i.deployment === "testnet") stop(`the live Aquarius router differs from contracts/testdata/fixtures.json (${what})`);
    return off(`the live router differs from the CT-03 fixtures (${what})`);
  }
  if (i.payment && i.payment.asset !== i.fixtures.aqua.sac) {
    if (i.deployment === "testnet") stop(`the router's pool payment is now in ${i.payment.asset}, not AQUA`);
    return off(`the router's pool payment is in ${i.payment.asset}, not AQUA`);
  }
  const swap = i.swapByDefault || i.fundAquaFloat;
  const notes: string[] = [];
  if (!swap) notes.push("the AQUA float is not funded by this run: fund it to its target afterwards (by hand, or re-run with --fund-aqua-float)");
  return { enabled: true, reason: null, swap, target, notes };
}

/** Applies a failed depth check or swap to the plan: testnet-qa goes on without Aquarius; the owner's testnet keeps
 *  the venue and reports the float to fund. */
export function afterFailedFunding(plan: AquaPlan, deployment: "testnet" | "testnet-qa", reason: string): AquaPlan {
  if (deployment === "testnet-qa") return { ...plan, enabled: false, reason, swap: false };
  return { ...plan, swap: false, notes: [...plan.notes, `the AQUA float was not funded (${reason}); fund it to its target by hand`] };
}

// ------------------------------------------------------------------------------------------------ on chain

const u128 = (n: bigint) => nativeToScVal(n, { type: "u128" });
const addr = (a: string) => new Address(a).toScVal();

function swapArgs(fx: AquariusFixtures): xdr.ScVal[] {
  return [
    xdr.ScVal.scvVec(fx.pool.tokens.map(addr)),
    addr(fx.pool.xlmSac),
    addr(fx.aqua.sac),
    xdr.ScVal.scvBytes(Buffer.from(fx.pool.poolIndex, "hex")),
  ];
}

/** router.estimate_swap for XLM → AQUA (read-only). */
export function routerEstimate(chain: ChainReader, fx: AquariusFixtures): (xlmIn: bigint) => Promise<bigint> {
  return async (xlmIn) => BigInt(scValToNative(await chain.view(fx.router, "estimate_swap", [...swapArgs(fx), u128(xlmIn)])));
}

/** The router's payment for a new standard pool, read live. */
export async function routerPayment(chain: ChainReader, fx: AquariusFixtures): Promise<{ asset: string; amount: bigint }> {
  const amount = BigInt(scValToNative(await chain.view(fx.router, "get_standard_pool_payment_amount", [])));
  const asset = String(scValToNative(await chain.view(fx.router, "get_init_pool_payment_token", [])));
  return { asset, amount };
}

/** The deployer's AQUA (stroops); 0 without a trustline. */
export async function aquaBalance(chain: ChainReader, fx: AquariusFixtures, account: string): Promise<bigint> {
  const a = await chain.account(account);
  return a?.trustlines.find((t) => t.asset === `${fx.aqua.code}:${fx.aqua.issuer}`)?.balance ?? 0n;
}

export interface Acquired {
  trustline: TxOutcome | null;
  swap: TxOutcome | null;
  /** AQUA the deployer holds for the float after the step. */
  held: bigint;
}

/** Adds the deployer's AQUA trustline when missing, then swaps `spend` XLM for at least `minOut` AQUA. Skips the swap
 *  when the deployer already holds `minOut` (a re-run). */
export async function acquireAqua(chain: Chain, deployer: Keypair, fx: AquariusFixtures, spend: bigint, minOut: bigint): Promise<Acquired> {
  if (spend > MAX_SWAP_STROOPS) throw new Error(`refused: the AQUA swap would spend more than ${fmt(MAX_SWAP_STROOPS)} XLM`);
  const me = deployer.publicKey();
  const account = await chain.account(me);
  const asset = `${fx.aqua.code}:${fx.aqua.issuer}`;
  let trustline: TxOutcome | null = null;
  if (!account?.trustlines.some((t) => t.asset === asset)) {
    trustline = await send(chain, deployer, Operation.changeTrust({ asset: new Asset(fx.aqua.code, fx.aqua.issuer) }));
  }
  const before = await aquaBalance(chain, fx, me);
  if (before >= minOut) return { trustline, swap: null, held: before };
  const swap = await invoke(chain, deployer, fx.router, "swap", [addr(me), ...swapArgs(fx), u128(spend), u128(minOut)]);
  return { trustline, swap, held: await aquaBalance(chain, fx, me) };
}

/** Sends `amount` AQUA from the deployer to exec-aquarius through the AQUA SAC. */
export async function fundFloat(chain: Chain, deployer: Keypair, fx: AquariusFixtures, exec: string, amount: bigint): Promise<TxOutcome> {
  return await invoke(chain, deployer, fx.aqua.sac, "transfer", [addr(deployer.publicKey()), addr(exec), nativeToScVal(amount, { type: "i128" })]);
}

/** exec-aquarius's float() (stroops). */
export async function floatOf(chain: ChainReader, exec: string): Promise<bigint> {
  return BigInt(scValToNative(await chain.view(exec, "float", [])));
}
