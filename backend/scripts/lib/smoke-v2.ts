// The testnet-qa contract smoke (CT-11; docs/DESIGN-stellar-contracts-v2.md §17 step 4, §18.4): deploy-contracts-v2.ts
// --deployment testnet-qa --smoke. It rehearses the owner's deploy on testnet-qa by direct contract calls, with the
// QA durations:
//
// - one launch: launch (XLM quote, holder sharing on, the 10 XLM launch fee), a buy after the snipe window that
//   completes the curve, the keeper's graduate on the Soroswap venue (ids read from venues(), F8), two swaps on the
//   new pool, a harvest after the QA harvest interval, and both claims: the holder's (quote and launch-token rewards,
//   F1) and the protocol sweep to the treasury (claim_protocol_fees, F9);
// - one Moment: publish, a terminal collect, the keeper's graduate, and the first vest claims (collector and creator).
//
// Every transaction's hash and fee are printed. The keeper is the QA deployer; the creator, the buyer and the collector
// are fresh throwaway accounts made for this run and funded by Friendbot (testnet-qa only, O3). Their keys exist only in
// memory; only addresses are printed. The collector's USDC (Circle's, the asset Moments use) comes from the Soroswap
// XLM → USDC route after a depth check (F10). A dry run prints the plan and runs the read-only checks only.
import { Buffer } from "node:buffer";
import { Address, Asset, hash, type Keypair, Operation, scValToNative, xdr } from "@stellar/stellar-sdk";
import type { Io, QaKeyName } from "./owner-files.ts";
import { type Chain, fmtUnits, fmtXlm, invoke, send, STROOPS_PER_XLM, type TxOutcome } from "./preflight-v2.ts";
import { WASMS, type WasmKey } from "./v2-constructors.ts";
import { param, type Param, T, toScVal } from "./wasm-spec.ts";

// ------------------------------------------------------------------------------------------------ the calls

/** launchpad-v2's LaunchParams (§5.3). */
export const LaunchParamsT = T.struct("LaunchParams", [
  ["quote", T.address],
  ["name", T.string],
  ["symbol", T.string],
  ["uri", T.string],
  ["creator_fee_bps", T.u32],
  ["venue", T.u32],
  ["holder_sharing", T.bool],
  ["creator_fee_recipient", T.option(T.address)],
  ["snipe_exempt", T.vec(T.address)],
  ["initial_buy", T.i128],
  ["min_tokens_out", T.i128],
  ["nonce", T.u64],
]);

/** moments-v2's PublishParams (§9.1). */
export const PublishParamsT = T.struct("PublishParams", [
  ["name", T.string],
  ["symbol", T.string],
  ["metadata_uri", T.string],
  ["media_hash", T.bytesN(32)],
  ["place", T.string],
  ["date", T.string],
  ["price", T.i128],
  ["creator_alloc_bps", T.u32],
  ["window_secs", T.u64],
  ["nonce", T.u64],
]);

/** The terms structs are passed back exactly as the views returned them (P2), so they are declared by name only. */
const opaque = (name: string): Param["type"] => ({ kind: "udt", name, def: null });

/** Every contract function the smoke calls, with the parameters it passes: a test compares them with the contract
 *  specs of the dist WASMs, so a renamed function or a changed parameter is caught before a rehearsal. */
export const SMOKE_CALLS: { wasm: WasmKey | "soroswap-router"; fn: string; params: Param[] }[] = [
  { wasm: "launchpad-v2", fn: "venues", params: [] },
  { wasm: "launchpad-v2", fn: "preview_launch_terms", params: [param("quote", T.address), param("venue", T.u32)] },
  { wasm: "launchpad-v2", fn: "token_address", params: [param("creator", T.address), param("nonce", T.u64)] },
  { wasm: "launchpad-v2", fn: "launch", params: [param("creator", T.address), param("p", LaunchParamsT), param("expected", opaque("LaunchTerms"))] },
  { wasm: "launchpad-v2", fn: "quote_buy", params: [param("token", T.address), param("buyer", T.address), param("quote_in", T.i128)] },
  { wasm: "launchpad-v2", fn: "buy", params: [param("buyer", T.address), param("token", T.address), param("quote_in", T.i128), param("min_tokens_out", T.i128)] },
  { wasm: "launchpad-v2", fn: "status", params: [param("token", T.address)] },
  { wasm: "launchpad-v2", fn: "graduate", params: [param("token", T.address)] },
  { wasm: "launchpad-v2", fn: "claim_protocol_fees", params: [param("tokens", T.vec(T.address))] },
  { wasm: "launch-token-v2", fn: "balance", params: [param("account", T.address)] },
  { wasm: "launch-token-v2", fn: "pending_rewards", params: [param("account", T.address)] },
  { wasm: "launch-token-v2", fn: "claim", params: [param("holder", T.address)] },
  { wasm: "lp-locker", fn: "harvestable", params: [param("pool", T.address)] },
  { wasm: "lp-locker", fn: "harvest", params: [param("pool", T.address)] },
  { wasm: "moments-v2", fn: "policy", params: [] },
  { wasm: "moments-v2", fn: "terms", params: [] },
  { wasm: "moments-v2", fn: "nft_address", params: [param("creator", T.address), param("nonce", T.u64)] },
  { wasm: "moments-v2", fn: "publish", params: [param("creator", T.address), param("p", PublishParamsT), param("expected", opaque("MomentsTerms"))] },
  { wasm: "moments-v2", fn: "quote", params: [param("nft", T.address), param("qty", T.u32)] },
  { wasm: "moments-v2", fn: "collect", params: [param("collector", T.address), param("nft", T.address), param("qty", T.u32), param("max_total", T.i128)] },
  { wasm: "moments-v2", fn: "ledger", params: [param("nft", T.address)] },
  { wasm: "moments-v2", fn: "get_moment", params: [param("nft", T.address)] },
  { wasm: "moments-v2", fn: "graduate", params: [param("nft", T.address)] },
  { wasm: "moments-v2", fn: "claimable", params: [param("nft", T.address), param("account", T.address)] },
  { wasm: "moments-v2", fn: "claim", params: [param("account", T.address), param("nft", T.address)] },
  { wasm: "moment-coin", fn: "balance", params: [param("account", T.address)] },
  { wasm: "soroswap-router", fn: "router_get_amounts_out", params: [param("amount_in", T.i128), param("path", T.vec(T.address))] },
  { wasm: "soroswap-router", fn: "router_get_amounts_in", params: [param("amount_out", T.i128), param("path", T.vec(T.address))] },
  {
    wasm: "soroswap-router",
    fn: "swap_exact_tokens_for_tokens",
    params: [param("amount_in", T.i128), param("amount_out_min", T.i128), param("path", T.vec(T.address)), param("to", T.address), param("deadline", T.u64)],
  },
  {
    wasm: "soroswap-router",
    fn: "swap_tokens_for_exact_tokens",
    params: [param("amount_out", T.i128), param("amount_in_max", T.i128), param("path", T.vec(T.address)), param("to", T.address), param("deadline", T.u64)],
  },
];

function encode(wasm: WasmKey | "soroswap-router", fn: string, values: unknown[]): xdr.ScVal[] {
  const c = SMOKE_CALLS.find((x) => x.wasm === wasm && x.fn === fn);
  if (!c) throw new Error(`internal: ${wasm}.${fn} isn't in SMOKE_CALLS`);
  if (values.length !== c.params.length) throw new Error(`internal: ${wasm}.${fn} takes ${c.params.length} arguments`);
  return c.params.map((p, i) => (values[i] instanceof xdr.ScVal ? values[i] as xdr.ScVal : toScVal(p.type, values[i], `${fn}.${p.name}`)));
}

// ------------------------------------------------------------------------------------------------ the run

/** The deployment file's parts the smoke reads (deploy-contracts-v2.ts deploymentRecord). */
export interface SmokeDeployment {
  deployment: string;
  deployer: string;
  contracts: Record<string, string>;
  wasmHashes: Record<string, string | null>;
  durations: { set: string; launch: Record<string, number>; moments: Record<string, number> };
  roles: { treasury: string };
}

export interface SmokeNetwork {
  xlmSac: string;
  usdcSac: string;
  /** CODE:ISSUER of Circle's testnet USDC. */
  usdcClassic: string;
  soroswapRouter: string;
}

export interface SmokeCtx {
  io: Io;
  chain: Chain;
  deployment: SmokeDeployment;
  qa: Record<QaKeyName, Keypair>;
  network: SmokeNetwork;
  /** A fresh throwaway key (the run's creator, buyer and collector). */
  newKey(): Keypair;
  /** A random u64 for the launch and publish nonces. */
  nonce(): bigint;
  sleep(ms: number): Promise<void>;
  /** Wall-clock seconds, for swap deadlines. */
  nowSecs(): number;
  dryRun: boolean;
}

/** Budgets and limits (stroops / 7-decimal units). */
export const SMOKE = {
  /** The buyer's budget for the buy that completes the XLM curve; the clamp pulls only what completes it. */
  buyBudget: 5_000n * STROOPS_PER_XLM,
  /** The XLM each swap on the new pool spends, and the launch tokens sold back. */
  swapXlm: 100n * STROOPS_PER_XLM,
  /** The USDC route's cap (F10's depth check spends at most this). */
  maxUsdcSpend: 2_000n * STROOPS_PER_XLM,
  /** USDC above the terminal collect's gross. */
  usdcMargin: 10_000_000n,
  creatorFeeBps: 100,
  /** Polls: every `pollMs`, for at most the given time. */
  pollMs: 5_000,
  snipeWaitMs: 180_000,
  harvestWaitMs: 300_000,
  rewardsWaitMs: 120_000,
} as const;

const BPS = 10_000n;
const ONE = 10_000_000n;

export interface SmokeResult {
  transactions: { label: string; hash: string; fee: bigint }[];
  fees: bigint;
  launch?: { token: string; pool: string; holderQuote: bigint; holderToken: bigint; protocol: bigint };
  moment?: { nft: string; pool: string; collector: bigint; creator: bigint };
}

/** Thrown for a smoke step that failed; the message names the step. */
export class SmokeError extends Error {}

/** The contracts the smoke uses, read from the deployment file, each checked on chain against its recorded WASM. */
export async function checkDeployment(ctx: Pick<SmokeCtx, "chain" | "deployment" | "qa" | "io">): Promise<void> {
  const d = ctx.deployment;
  const fail = (why: string): never => {
    throw new SmokeError(`the deployment file can't be smoked: ${why}`);
  };
  if (d.deployment !== "testnet-qa") fail(`it is for ${d.deployment}, not testnet-qa`);
  if (d.durations?.set !== "testnet-qa") fail(`its durations are the ${d.durations?.set} set, not testnet-qa's`);
  if (d.deployer !== ctx.qa.DEPLOYER_SECRET.publicKey()) fail(`its deployer ${d.deployer} isn't the QA keys' deployer: the keys belong to another deployment`);
  for (const [name, wasm] of [["launchpadV2", "launchpadV2"], ["lpLocker", "lpLocker"], ["momentsV2", "momentsV2"], ["momentsGraduator", "momentsGraduator"], ["execSoroswap", "execSoroswap"]]) {
    const id = d.contracts?.[name];
    if (!id) fail(`it has no ${name}`);
    const onChain = await ctx.chain.contractWasmHash(id);
    if (onChain === null) fail(`${name} ${id} isn't on testnet`);
    if (onChain !== d.wasmHashes?.[wasm]) fail(`${name} ${id} runs WASM ${onChain}, the file records ${d.wasmHashes?.[wasm]}`);
  }
}

/** Runs the smoke (or, with dryRun, prints its plan). Throws a SmokeError naming the step that failed. */
export async function runSmoke(ctx: SmokeCtx): Promise<SmokeResult> {
  const { io, chain, deployment: d, network: net } = ctx;
  const say = (l = "") => io.out(l);
  const result: SmokeResult = { transactions: [], fees: 0n };
  const launchpad = d.contracts.launchpadV2;
  const locker = d.contracts.lpLocker;
  const moments = d.contracts.momentsV2;
  const keeper = ctx.qa.DEPLOYER_SECRET;
  const ld = d.durations.launch;
  const md = d.durations.moments;

  say(`Smoke · testnet-qa · launchpad-v2 ${launchpad} · moments-v2 ${moments}${ctx.dryRun ? " · DRY RUN: nothing is sent" : ""}`);
  say(`  durations (${d.durations.set}): harvest_interval ${ld.harvest_interval} s; Moments vest_period ${md.vest_period} s`);
  say(`  keeper (graduate, harvest, protocol sweep): the QA deployer ${keeper.publicKey()}`);
  await checkDeployment(ctx);
  say("  ✓ the deployment file is testnet-qa's, its deployer is the QA keys', and each contract runs its recorded WASM");

  const view = async (contract: string, wasm: WasmKey | "soroswap-router", fn: string, values: unknown[] = []) =>
    scValToNative(await chain.view(contract, fn, encode(wasm, fn, values)));
  const step = async <T>(label: string, f: () => Promise<T>): Promise<T> => {
    try {
      return await f();
    } catch (e) {
      if (e instanceof SmokeError) throw e;
      throw new SmokeError(`${label}: ${(e as Error).message}`);
    }
  };
  const record = (label: string, o: TxOutcome) => {
    result.transactions.push({ label, hash: o.hash, fee: o.feeCharged });
    result.fees += o.feeCharged;
    say(`  ${label}: ${o.hash} (fee ${fmtXlm(o.feeCharged)})`);
  };
  const call = async (label: string, signer: Keypair, contract: string, wasm: WasmKey | "soroswap-router", fn: string, values: unknown[]) =>
    await step(label, async () => {
      const o = await invoke(chain, signer, contract, fn, encode(wasm, fn, values));
      record(label, o);
      return o.returnValue ? scValToNative(o.returnValue) : null;
    });
  const waitFor = async <T>(label: string, maxMs: number, probe: () => Promise<T | null>): Promise<T> =>
    await step(label, async () => {
      let waited = 0;
      let last = "";
      for (;;) {
        try {
          const r = await probe();
          if (r !== null) return r;
        } catch (e) {
          last = (e as Error).message;
        }
        if (waited >= maxMs) throw new Error(`still not ready after ${maxMs / 1000} s${last ? ` (${last})` : ""}`);
        await ctx.sleep(SMOKE.pollMs);
        waited += SMOKE.pollMs;
      }
    });

  // The venue the launch graduates on, as venues() reports it (F8): the enabled Soroswap venue.
  const venues = await step("reading venues()", async () => (await view(launchpad, "launchpad-v2", "venues")) as { id: number; kind: number; executor: string; enabled: boolean }[]);
  const soroswap = venues.find((v) => Number(v.kind) === 0 && v.enabled && v.executor === d.contracts.execSoroswap);
  if (!soroswap) throw new SmokeError(`venues() has no enabled Soroswap venue with executor ${d.contracts.execSoroswap}`);
  const venueId = Number(soroswap.id);
  const policy = await step("reading moments-v2 policy()", async () => (await view(moments, "moments-v2", "policy")) as Record<string, bigint | number | string>);
  const threshold = BigInt(policy.threshold as bigint);
  const reserveBps = BigInt(policy.reserve_bps as number);
  const gross = (threshold * BPS + reserveBps - 1n) / reserveBps;
  const usdcNeeded = gross + SMOKE.usdcMargin;
  const price = BigInt(policy.min_price as bigint) > ONE ? BigInt(policy.min_price as bigint) : ONE;
  const qty = Number((gross + price - 1n) / price);
  if (qty > 20) throw new SmokeError(`at ${fmtUnits(price)} USDC an edition, ${qty} editions complete the Moment: more than one collect (20) takes`);
  say(`  launch: XLM quote, Soroswap venue ${venueId} (read from venues()), holder sharing on, creator fee ${SMOKE.creatorFeeBps} bps`);
  say(`  Moment: ${fmtUnits(price)} USDC an edition; a collect of ${qty} completes the ${fmtUnits(threshold)} USDC threshold (${fmtUnits(gross)} USDC gross)`);

  // F10: the collector's USDC through Soroswap's XLM → USDC route, after a depth check.
  const route = [net.xlmSac, net.usdcSac];
  let depth = { rate1: 0n, spend: 0n, ok: false, problem: "" };
  try {
    const rate1 = BigInt(((await view(net.soroswapRouter, "soroswap-router", "router_get_amounts_out", [ONE, route])) as bigint[])[1]);
    const spend = BigInt(((await view(net.soroswapRouter, "soroswap-router", "router_get_amounts_in", [usdcNeeded, route])) as bigint[])[0]);
    // The average rate (usdcNeeded / spend) within 3% of the 1-XLM rate, for at most maxUsdcSpend.
    const ok = rate1 > 0n && spend > 0n && spend <= SMOKE.maxUsdcSpend && usdcNeeded * ONE * 100n >= rate1 * 97n * spend;
    depth = { rate1, spend, ok, problem: "" };
  } catch (e) {
    depth.problem = (e as Error).message;
  }
  say(
    depth.problem
      ? `  ✗ XLM → USDC depth check: the route didn't quote (${depth.problem})`
      : `  ${depth.ok ? "✓" : "✗"} XLM → USDC depth check: 1 XLM → ${fmtUnits(depth.rate1)} USDC; ${fmtUnits(usdcNeeded)} USDC costs ${fmtUnits(depth.spend)} XLM`,
  );
  const thin = "testnet XLM→USDC liquidity too thin for the Moment's collect (F10): the launch part runs, the Moment part doesn't; " +
    "a person tops a collector up from Circle's testnet faucet";
  if (!depth.ok) say(`  ${thin}`);

  if (ctx.dryRun) {
    say("  plan: fund a creator, a buyer and a collector through Friendbot; launch; wait out the snipe window; buy to completion;");
    say("        graduate; swap both ways on the pool; wait harvest_interval; harvest; the holder's claim; claim_protocol_fees;");
    say("        the collector's USDC trustline and swap; publish; collect; graduate; the collector's and the creator's first vest claims");
    say("Dry run: nothing was sent.");
    return result;
  }

  // ---------------------------------------------------------------- accounts
  const creator = ctx.newKey();
  const buyer = ctx.newKey();
  const collector = ctx.newKey();
  say("Accounts (throwaway, funded by Friendbot; keys kept in memory only)");
  for (const [label, kp] of [["creator", creator], ["buyer", buyer], ["collector", collector]] as const) {
    await step(`funding the ${label}`, async () => {
      if (!(await chain.account(kp.publicKey()))) await chain.friendbot(kp.publicKey());
    });
    // Horizon can lag the ledger Friendbot's payment closed in by a moment.
    await waitFor(`the ${label}'s account after Friendbot`, 60_000, async () => ((await chain.account(kp.publicKey())) ? true : null));
    say(`  ${label.padEnd(9)} ${kp.publicKey()}`);
  }

  // ---------------------------------------------------------------- the launch
  say("Launch");
  const launchNonce = ctx.nonce();
  const symbol = `SMK${(launchNonce % 100_000n).toString().padStart(5, "0")}`;
  const terms = await step("reading preview_launch_terms", () => chain.view(launchpad, "preview_launch_terms", encode("launchpad-v2", "preview_launch_terms", [net.xlmSac, venueId])));
  const predicted = String(await view(launchpad, "launchpad-v2", "token_address", [creator.publicKey(), launchNonce]));
  const params = {
    quote: net.xlmSac,
    name: "DyorHQ testnet-qa smoke",
    symbol,
    uri: "https://dyorhq.fun/testnet-qa/smoke.json",
    creator_fee_bps: SMOKE.creatorFeeBps,
    venue: venueId,
    holder_sharing: true,
    creator_fee_recipient: null,
    snipe_exempt: [],
    initial_buy: 0n,
    min_tokens_out: 0n,
    nonce: launchNonce,
  };
  const token = String(await call(`launch ${symbol}`, creator, launchpad, "launchpad-v2", "launch", [creator.publicKey(), params, terms]));
  if (token !== predicted) throw new SmokeError(`launch returned ${token}, token_address predicted ${predicted}`);
  say(`  token ${token}`);

  // The snipe tax steps down every snipe_step_secs; the buy waits until the window is over (quote_buy shows it).
  // quote_buy's snipe_fee is what's left after the net and the two fees (curve.rs), so after the window it still
  // holds their rounding and the completing buy's clamp, a few stroops; inside the window it is at least the last
  // step's 30 bps. Over when it is at most 1 bp of what the buy spends.
  const quote = await waitFor("waiting out the snipe window", SMOKE.snipeWaitMs, async () => {
    const q = (await view(launchpad, "launchpad-v2", "quote_buy", [token, buyer.publicKey(), SMOKE.buyBudget])) as Record<string, bigint>;
    return snipeWindowOver(BigInt(q.snipe_fee), BigInt(q.used)) ? q : null;
  });
  say(`  the buy completes the curve: ${fmtUnits(BigInt(quote.used))} XLM in, ${fmtUnits(BigInt(quote.tokens_out))} tokens out`);
  const bought = BigInt(await call("buy (completes the curve)", buyer, launchpad, "launchpad-v2", "buy", [buyer.publicKey(), token, SMOKE.buyBudget, (BigInt(quote.tokens_out) * 99n) / 100n]) as bigint);
  const phase = Number(((await view(launchpad, "launchpad-v2", "status", [token])) as Record<string, unknown>).phase);
  if (phase !== 1) throw new SmokeError(`after the buy the launch is in phase ${phase}, not Completed (1)`);
  say(`  ✓ completed; the buyer holds ${fmtUnits(bought)} tokens`);

  const outcome = await call("keeper graduate (Soroswap)", keeper, launchpad, "launchpad-v2", "graduate", [token]);
  const pool = graduatedPool(outcome, "the launch");
  say(`  ✓ graduated: pool ${pool}`);

  // Fee growth for the harvest: a sell and a buy through Soroswap's router.
  const deadline = () => BigInt(ctx.nowSecs() + 900);
  const sellPath = [token, net.xlmSac];
  const held = BigInt(await view(token, "launch-token-v2", "balance", [buyer.publicKey()]) as bigint);
  const sellAmount = held / 20n;
  const sellOut = BigInt(((await view(net.soroswapRouter, "soroswap-router", "router_get_amounts_out", [sellAmount, sellPath])) as bigint[])[1]);
  await call("swap: sell 5% of the tokens on the pool", buyer, net.soroswapRouter, "soroswap-router", "swap_exact_tokens_for_tokens", [sellAmount, (sellOut * 97n) / 100n, sellPath, buyer.publicKey(), deadline()]);
  const buyPath = [net.xlmSac, token];
  const buyOut = BigInt(((await view(net.soroswapRouter, "soroswap-router", "router_get_amounts_out", [SMOKE.swapXlm, buyPath])) as bigint[])[1]);
  await call(`swap: buy with ${fmtUnits(SMOKE.swapXlm)} XLM on the pool`, buyer, net.soroswapRouter, "soroswap-router", "swap_exact_tokens_for_tokens", [SMOKE.swapXlm, (buyOut * 97n) / 100n, buyPath, buyer.publicKey(), deadline()]);
  const h = (await view(locker, "lp-locker", "harvestable", [pool])) as bigint[];
  if (BigInt(h[1]) === 0n) throw new SmokeError(`the swaps left nothing to harvest (harvestable: growth ${h[0]}, lp_to_burn ${h[1]})`);
  say(`  harvestable: lp_to_burn ${h[1]}, about ${fmtUnits(BigInt(h[2]))} tokens and ${fmtUnits(BigInt(h[3]))} XLM; allowed from ${h[4]} (unix s)`);

  // harvest_interval after the graduation registered the position: simulate until the locker accepts it.
  await waitFor(`waiting for the harvest interval (${ld.harvest_interval} s)`, SMOKE.harvestWaitMs, async () => {
    await chain.view(locker, "harvest", encode("lp-locker", "harvest", [pool]));
    return true;
  });
  const harvested = (await call("keeper harvest", keeper, locker, "lp-locker", "harvest", [pool])) as bigint[];
  say(`  ✓ harvested ${fmtUnits(BigInt(harvested[0]))} tokens and ${fmtUnits(BigInt(harvested[1]))} XLM, split 50/50 between the treasury and the holders`);

  // The holder's claim: quote and launch-token rewards (F1). Notified rewards are released from the next ledger on.
  await waitFor("waiting for the harvest's holder rewards", SMOKE.rewardsWaitMs, async () => {
    const p = (await view(token, "launch-token-v2", "pending_rewards", [buyer.publicKey()])) as bigint[];
    return BigInt(p[0]) > 0n && BigInt(p[1]) > 0n ? p : null;
  });
  const claimed = (await call("holder claim (quote and token rewards)", buyer, token, "launch-token-v2", "claim", [buyer.publicKey()])) as bigint[];
  const [holderQuote, holderToken] = [BigInt(claimed[0]), BigInt(claimed[1])];
  if (holderQuote <= 0n || holderToken <= 0n) throw new SmokeError(`the holder's claim paid ${holderQuote} XLM and ${holderToken} tokens: both must be above 0`);
  say(`  ✓ the holder claimed ${fmtUnits(holderQuote)} XLM and ${fmtUnits(holderToken)} tokens`);

  // The protocol sweep: the booked protocol fees and the 10 XLM launch fee to the treasury (F9).
  const swept = (await call("claim_protocol_fees (to the treasury)", keeper, launchpad, "launchpad-v2", "claim_protocol_fees", [[token]])) as [string, bigint][];
  const xlmSwept = swept.filter(([a]) => a === net.xlmSac).reduce((s, [, n]) => s + BigInt(n), 0n);
  if (xlmSwept <= 0n) throw new SmokeError("claim_protocol_fees paid the treasury no XLM");
  say(`  ✓ the treasury ${d.roles.treasury} received ${fmtUnits(xlmSwept)} XLM (protocol fees and the launch fee)`);
  result.launch = { token, pool, holderQuote, holderToken, protocol: xlmSwept };

  // ---------------------------------------------------------------- the Moment
  say("Moment");
  if (!depth.ok) throw new SmokeError(thin);
  const [usdcCode, usdcIssuer] = net.usdcClassic.split(":");
  await step("the collector's USDC trustline", async () => {
    record("collector trusts USDC", await send(chain, collector, Operation.changeTrust({ asset: new Asset(usdcCode, usdcIssuer) })));
  });
  await call(`swap: ${fmtUnits(usdcNeeded)} USDC for at most ${fmtUnits((depth.spend * 103n) / 100n)} XLM`, collector, net.soroswapRouter, "soroswap-router", "swap_tokens_for_exact_tokens", [
    usdcNeeded,
    (depth.spend * 103n) / 100n,
    route,
    collector.publicKey(),
    deadline(),
  ]);
  const momentNonce = ctx.nonce();
  const mSymbol = `SMM${(momentNonce % 100_000n).toString().padStart(5, "0")}`;
  const mTerms = await step("reading terms()", () => chain.view(moments, "terms", []));
  const predictedNft = String(await view(moments, "moments-v2", "nft_address", [creator.publicKey(), momentNonce]));
  const publishParams = {
    name: "DyorHQ testnet-qa smoke",
    symbol: mSymbol,
    metadata_uri: "https://dyorhq.fun/testnet-qa/smoke-moment.json",
    media_hash: Uint8Array.from(hash(Buffer.from(`dyorhq testnet-qa smoke ${momentNonce}`))),
    place: "testnet-qa",
    date: new Date(ctx.nowSecs() * 1000).toISOString().slice(0, 10),
    price,
    creator_alloc_bps: Number(policy.max_creator_alloc_bps),
    window_secs: BigInt(Math.max(md.min_window, 1_800)),
    nonce: momentNonce,
  };
  const nft = String(await call(`publish ${mSymbol}`, creator, moments, "moments-v2", "publish", [creator.publicKey(), publishParams, mTerms]));
  if (nft !== predictedNft) throw new SmokeError(`publish returned ${nft}, nft_address predicted ${predictedNft}`);
  say(`  NFT ${nft}`);
  const cq = (await view(moments, "moments-v2", "quote", [nft, qty])) as Record<string, unknown>;
  if (!cq.terminal) throw new SmokeError(`a collect of ${qty} editions doesn't complete the Moment`);
  const collected = (await call(`collect ${qty} (terminal)`, collector, moments, "moments-v2", "collect", [collector.publicKey(), nft, qty, BigInt(cq.gross as bigint)])) as Record<string, bigint | number>;
  say(`  ✓ collected ${collected.editions} editions for ${fmtUnits(BigInt(collected.gross))} USDC; ${fmtUnits(BigInt(collected.entitlement))} coins promised`);
  const state = Number(((await view(moments, "moments-v2", "ledger", [nft])) as Record<string, unknown>).state);
  if (state !== 1) throw new SmokeError(`after the terminal collect the Moment is in state ${state}, not GraduationPending (1)`);

  const mOutcome = await call("keeper graduate (Moment)", keeper, moments, "moments-v2", "graduate", [nft]);
  const mPool = graduatedPool(mOutcome, "the Moment");
  say(`  ✓ graduated: pool ${mPool}`);

  // The first vest claims: 60% of the collector's coins and 20% of the creator's allocation at graduation.
  const coin = String(((await view(moments, "moments-v2", "get_moment", [nft])) as Record<string, unknown>).coin);
  const due = (await view(moments, "moments-v2", "claimable", [nft, collector.publicKey()])) as bigint[];
  const c1 = (await call("collector's first vest claim", collector, moments, "moments-v2", "claim", [collector.publicKey(), nft])) as bigint[];
  if (BigInt(c1[0]) <= 0n || BigInt(c1[0]) !== BigInt(due[0])) throw new SmokeError(`the collector's first claim paid ${c1[0]} coins, claimable() said ${due[0]}`);
  const c2 = (await call("creator's first vest claim", creator, moments, "moments-v2", "claim", [creator.publicKey(), nft])) as bigint[];
  if (BigInt(c2[1]) <= 0n) throw new SmokeError(`the creator's first claim paid ${c2[1]} coins`);
  const coins = BigInt(await view(coin, "moment-coin", "balance", [collector.publicKey()]) as bigint);
  if (coins !== BigInt(c1[0])) throw new SmokeError(`the collector holds ${coins} coins of ${coin}, not the ${c1[0]} claimed`);
  say(`  ✓ the collector claimed ${fmtUnits(BigInt(c1[0]))} coins (coin ${coin}) and the creator ${fmtUnits(BigInt(c2[1]))}`);
  result.moment = { nft, pool: mPool, collector: BigInt(c1[0]), creator: BigInt(c2[1]) };

  say();
  say(`Smoke passed: ${result.transactions.length} transactions, ${fmtXlm(result.fees)} in fees.`);
  return result;
}

/** The pool of a `Graduated` outcome; a `Failed` one stops the smoke with its namespaced origin and code (V10). */
function graduatedPool(outcome: unknown, what: string): string {
  const o = outcome as unknown[];
  if (Array.isArray(o) && o[0] === "Graduated" && typeof o[1] === "string") return o[1];
  if (Array.isArray(o) && o[0] === "Failed") {
    const f = o[1] as { origin?: unknown; code?: unknown };
    throw new SmokeError(`${what}'s graduation recorded a failure: origin ${f?.origin}, code ${f?.code}`);
  }
  throw new SmokeError(`${what}'s graduation returned ${JSON.stringify(outcome, (_k, v) => (typeof v === "bigint" ? v.toString() : v))}`);
}

/** Whether a quote_buy is past the snipe window: its snipe_fee is rounding only, at most 1 bp of `used`. Inside the
 *  window it is at least the schedule's last step (30 bps); after it, the curve's floored fees and the completing
 *  buy's clamp leave a few stroops there. */
export function snipeWindowOver(snipeFee: bigint, used: bigint): boolean {
  return snipeFee * 10_000n <= used;
}

/** The deployment file the smoke reads: testnet-qa's, never the owner's. */
export function smokeFileName(): string {
  return "testnet-qa-v2.json";
}

/** WASM file of each smoked contract, for the spec test. */
export const SMOKE_WASM_FILE = (k: WasmKey) => WASMS[k].file;
