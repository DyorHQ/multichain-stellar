// The transaction verifier. The phone runs the same rules (StellarKit/TxVerifier.swift) before it signs anything,
// and the API runs this copy on every step it builds, so a builder bug is caught before a user ever sees it.
//
// Rules (docs/DESIGN-stellar-parity.md §4.4, §4.9, §5.2): the right network and source; short time bounds; the fee
// caps; the memo the user confirmed; only the operation types the intent names; the sponsor only in an account
// activation; payments and new accounts only to the address the user confirmed; contract calls only to allowlisted
// contracts and functions, each bound by its call rule; Soroban auth only through the source account; restores only as
// their own intent, of allowlisted data; and the user's total outflow per asset (classic payments + every token
// transfer/burn/approve in the authorized invocation tree) never above what the intent declares.
//
// Contracts v2 (docs/DESIGN-stellar-contracts-v2.md §20.4): the live generation's contracts are pinned by role, and
// the ones it creates at runtime (launch tokens, Moment NFTs and coins) are allowed only by their pinned WASM hash. A
// call to launchpad-v2, moments-v2 or the lp-locker is judged by that contract's own rules, since v1's launchpad and
// Moments use some of the same function names with other arguments: a launch binds its terms to the pins (the
// executors, the locker, the token's WASM and the durations) and pays exactly its terms' fee, at most the pinned bound,
// to the launchpad; refunds, collects and claims act for the user; a call anyone may make carries none of the user's
// authorization.
//
// Both verifiers judge the same vectors (backend/tests/vectors/gen-vectors.ts) and give the same reasons: the Swift
// one's are these with a capital letter and a full stop.
import { Address, Asset, scValToNative, Transaction, xdr } from "@stellar/stellar-sdk";
import {
  DeploymentV2,
  LAUNCH_DURATION_KEYS,
  LaunchDurationsV2,
  MOMENTS_DURATION_KEYS,
  MomentsDurationsV2,
} from "./deployments/index.ts";
import { env } from "./env.ts";
import type { NetworkConfig } from "./networks.ts";

export interface Intent {
  kind: string;
  /** Plain-language hint. The phone builds its own text from the fields below and never shows this one alone. */
  summary: string;
  /** Max outflow from the user's account per asset contract id, base units. */
  spend: Record<string, string>;
  /** Minimum the user receives per asset contract id, base units: bound where an operation or a call encodes it. */
  receive?: Record<string, string>;
  /** Contract calls the transaction may make. */
  calls?: { contract: string; fn: string }[];
  /** Classic operation types the transaction may contain. */
  ops?: string[];
  /** Classic assets ("CODE:ISSUER") that may get a trustline. */
  trust?: string[];
  /** Extra structured facts for display (amounts, tickers, venue). */
  display?: Record<string, string | number | boolean | null>;
  /** The destination the user typed or confirmed: a G… or C… address, or for `bridge_out` the Monad address as
   *  0x-hex. Payments, new accounts, token transfers and the CCTP mint recipient must go there. */
  to?: string;
  /** The memo the user typed or confirmed; the transaction carries exactly this one, or none when it is absent. */
  memo?: { type: "text" | "id" | "hash"; value: string };
}

/** The network's fee caps, in stroops (networks.ts FeePolicy; the app pins the same three values). */
export interface FeeCaps {
  maxFee: bigint;
  maxInclusionPerOp: bigint;
  starterInnerFeeMax: bigint;
}

/** v2's pins (DESIGN-stellar-contracts-v2 §20.1): the live generation's singletons, the WASM hashes of the contracts
 *  it creates at runtime, its durations and the launch-fee bound, as the app pins them (PinnedContracts). */
export interface V2Pins {
  launchpad: string;
  moments: string;
  locker: string;
  graduator: string;
  /** exec-soroswap: every Moment's venue. */
  soroswapExecutor: string;
  /** The executors a launch's terms may name: the deployment's own. testnet-qa's qa-exec-fail is one only on
   *  testnet-qa, whose test contracts the app never pins (finding F4). */
  executors: string[];
  runtimeWasmHashes: { launchTokenV2: string; momentNft: string; momentCoin: string };
  durations: { launch: LaunchDurationsV2; moments: MomentsDurationsV2 };
  /** The most a launch's fee may be, in stroops (decision O6, finding F18). */
  maxLaunchFeeStroops: bigint;
}

/** What v2's pins are made from: a v2 deployment (deployments/index.ts), or the copy a vector carries. */
export type V2PinSource = Pick<DeploymentV2, "contracts" | "runtimeWasmHashes"> & {
  qa?: DeploymentV2["qa"];
  durations: { launch: LaunchDurationsV2; moments: MomentsDurationsV2 };
};

export function v2Pins(d: V2PinSource, maxLaunchFeeStroops: bigint): V2Pins {
  const c = d.contracts;
  return {
    launchpad: c.launchpadV2,
    moments: c.momentsV2,
    locker: c.lpLocker,
    graduator: c.momentsGraduator,
    soroswapExecutor: c.execSoroswap,
    executors: [c.execSoroswap, c.execAquarius, d.qa?.qaExecFail].filter((e): e is string => Boolean(e)),
    runtimeWasmHashes: { ...d.runtimeWasmHashes },
    durations: { launch: d.durations.launch, moments: d.durations.moments },
    maxLaunchFeeStroops,
  };
}

/** `net`'s v2 pins; null where v2 isn't deployed, and then every call is judged by v1's rules. */
export function v2PinsOf(net: NetworkConfig): V2Pins | null {
  return net.deploymentV2 ? v2Pins(net.deploymentV2, net.maxLaunchFeeStroops) : null;
}

export interface VerifyContext {
  user: string;
  sponsor: string;
  passphrase: string;
  /** Allowed contract ids for every call the intent names (pinned in the app binary), launch tokens included. */
  allowedContracts: Set<string>;
  now?: number;
  /** The fee caps; the network's (env.network.feePolicy) when absent. */
  feePolicy?: FeeCaps;
  /** The launch-token WASM hash (hex) a restore may bring back; the deployment's when absent. */
  launchTokenWasmHash?: string;
  /** Circle's CCTP domain the bridge burns to (Monad); the network's when absent. */
  monadDomain?: number | null;
  /** v2's pins; the network's (v2PinsOf(env.network)) when absent. */
  v2?: V2Pins | null;
  /** Contracts v2 created at runtime, each with the WASM hash (hex) the chain says it runs. One counts as allowlisted
   *  only when that hash is one of v2's pinned runtime hashes. */
  runtimeContracts?: Record<string, string>;
}

const TOKEN_SPEND_FNS = new Set(["transfer", "transfer_from", "burn", "burn_from", "approve"]);
const MAX_VALIDITY_S = 30 * 60;
const MAX_I64 = 2n ** 63n - 1n;
const MIN_I64 = -(2n ** 63n);

const DESTINATION = "the destination is not the one you confirmed";
const FOR_ANOTHER = "the call acts for another account";
const ARGUMENTS = "the call's arguments are not as expected";
const MINIMUM = "the minimum received is lower than quoted";
const AMOUNT = "amount out of range";
const ANYONE = "a call anyone may make carries your authorization";
const CLAIM_SPENDS = "a claim must not spend anything";
const TICKER = "the ticker is not 2 to 10 letters or digits";
const LAUNCH_VENUE = "the launch terms name a venue this app doesn't pin";
const LAUNCH_TERMS = "the launch terms are not the ones this app pins";
const LAUNCH_FEE_LIMIT = "the launch fee is above the limit";
const LAUNCH_FEE_TO = "the launch fee goes to another address than the launchpad";
const LAUNCH_FEE_AMOUNT = "the launch fee is not the one in the terms";
const MOMENT_TERMS = "the Moment's terms are not the ones this app pins";

// Contract structs as their ScVal maps name their fields (contracts/launchpad-v2/src/storage.rs, contracts/moments-v2,
// contracts/common/src/types.rs). A struct is read only when it has exactly these fields.
const LAUNCH_PARAMS = ["quote", "name", "symbol", "uri", "creator_fee_bps", "venue", "holder_sharing", "creator_fee_recipient", "snipe_exempt", "initial_buy", "min_tokens_out", "nonce"];
const LAUNCH_TERMS_FIELDS = [
  "supply", "fee_bps", "protocol_share_bps", "max_creator_fee_bps", "snipe_schedule", "snipe_step_secs", "launch_fee", "fee_asset", "quote", "phantom",
  "threshold", "venue", "fallback", "venue_locked", "locker", "token_wasm_hash", "durations",
];
const VENUE_INFO = ["id", "kind", "executor", "params", "enabled"];
const PUBLISH_PARAMS = ["name", "symbol", "metadata_uri", "media_hash", "place", "date", "price", "creator_alloc_bps", "window_secs", "nonce"];
const MOMENTS_TERMS_FIELDS = ["policy", "external_base", "nft_wasm_hash", "coin_wasm_hash", "graduator", "executor", "locker", "durations", "harvest_bps", "harvest_creator_bps"];

export class VerifyError extends Error {}

function fail(msg: string): never {
  throw new VerifyError(msg);
}

function stroops(decimal: string): bigint {
  if (decimal.startsWith("-")) return -stroops(decimal.slice(1));
  const [i, f = ""] = decimal.split(".");
  return BigInt(i) * 10_000_000n + BigInt((f + "0000000").slice(0, 7));
}

/** Base units written as a decimal string: digits only, within i64. Anything else is null. */
function units(text: unknown): bigint | null {
  if (typeof text !== "string" || !/^[0-9]+$/.test(text)) return null;
  const n = BigInt(text);
  return n <= MAX_I64 ? n : null;
}

function assetId(a: Asset, passphrase: string): string {
  return a.contractId(passphrase);
}

/** A G… or C… address; null for any other value, muxed and pool addresses included. */
function addrOf(v: xdr.ScVal | undefined): string | null {
  if (!v || v.switch() !== xdr.ScValType.scvAddress()) return null;
  return scAddressString(v.address());
}

function scAddressString(a: xdr.ScAddress): string | null {
  const t = a.switch();
  if (t !== xdr.ScAddressType.scAddressTypeAccount() && t !== xdr.ScAddressType.scAddressTypeContract()) return null;
  return Address.fromScAddress(a).toString();
}

/** Whether `v` is the G… or C… address the user confirmed. */
function isConfirmed(v: xdr.ScVal | undefined, intent: Intent): boolean {
  const a = addrOf(v);
  return a !== null && a === intent.to;
}

/** An integer argument (i128, u128, i64, u64, u32 or i32) that fits an i64; null otherwise. */
function intOf(v: xdr.ScVal | undefined): bigint | null {
  if (!v) return null;
  switch (v.switch().name) {
    case "scvI128":
    case "scvU128":
    case "scvI64":
    case "scvU64":
    case "scvU32":
    case "scvI32": {
      const n = BigInt(scValToNative(v));
      return n >= MIN_I64 && n <= MAX_I64 ? n : null;
    }
    default:
      return null;
  }
}

function vecOf(v: xdr.ScVal | undefined): xdr.ScVal[] | null {
  if (!v || v.switch() !== xdr.ScValType.scvVec()) return null;
  return v.vec() ?? null;
}

/** The minimum the intent quotes for `asset`, or null when it quotes none. */
function minimumFor(intent: Intent, asset: string | null): bigint | null {
  if (asset === null || !intent.receive || !Object.hasOwn(intent.receive, asset)) return null;
  return units(intent.receive[asset]);
}

/** The intent's one quoted minimum, for a call whose output asset isn't among its arguments (a curve sell). */
function soleMinimum(intent: Intent): bigint | null {
  const entries = Object.values(intent.receive ?? {});
  return entries.length === 1 ? units(entries[0]) : null;
}

function atLeast(min: bigint | null, quoted: bigint | null) {
  if (min === null) fail(ARGUMENTS);
  if (quoted === null || min < quoted) fail(MINIMUM);
}

/** A Monad address (0x + 40 hex) as the 32 bytes CCTP mints to; null for anything else. */
function evmBytes32(address: string | undefined): Buffer | null {
  if (!address || !/^0x[0-9a-fA-F]{40}$/.test(address)) return null;
  return Buffer.concat([Buffer.alloc(12), Buffer.from(address.slice(2), "hex")]);
}

/** A contract struct (a map with symbol keys) that has exactly the fields `keys`, by name; null for anything else. */
function structOf(v: xdr.ScVal | undefined, keys: readonly string[]): Map<string, xdr.ScVal> | null {
  if (!v || v.switch() !== xdr.ScValType.scvMap()) return null;
  const fields = new Map<string, xdr.ScVal>();
  for (const field of v.map() ?? []) {
    const key = field.key();
    if (key.switch() !== xdr.ScValType.scvSymbol()) return null;
    // A symbol built here is text, one decoded from XDR bytes.
    const name = Buffer.from(key.sym() as string | Buffer).toString();
    if (fields.has(name)) return null;
    fields.set(name, field.val());
  }
  return fields.size === keys.length && keys.every((k) => fields.has(k)) ? fields : null;
}

/** A durations struct (u64 seconds, the fields `keys`) equal, field by field, to `pinned`. */
function sameDurations<K extends string>(v: xdr.ScVal | undefined, keys: readonly K[], pinned: Record<K, number>): boolean {
  const got = structOf(v, keys);
  return got !== null && keys.every((k) => {
    const d = got.get(k)!;
    return d.switch() === xdr.ScValType.scvU64() && BigInt(d.u64().toString()) === BigInt(pinned[k]);
  });
}

/** 32 bytes as lowercase hex (a WASM hash); null for any other value. */
function hash32(v: xdr.ScVal | undefined): string | null {
  if (!v || v.switch() !== xdr.ScValType.scvBytes() || v.bytes().length !== 32) return null;
  return Buffer.from(v.bytes()).toString("hex");
}

/** A launch or Moment ticker: 2 to 10 ASCII letters or digits, as the contracts take it (Soroswap reads a pair's
 *  symbols as UTF-8). */
function isTicker(v: xdr.ScVal | undefined): boolean {
  if (!v || v.switch() !== xdr.ScValType.scvString()) return false;
  const bytes = Buffer.from(v.str() as string | Buffer);
  return bytes.length >= 2 && bytes.length <= 10 && bytes.every((b) => (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122));
}

interface RuleContext {
  user: string;
  intent: Intent;
  allowedContracts: Set<string>;
  monadDomain: number | null;
  /** The XLM Stellar Asset Contract: a v2 launch pays its fee in it. */
  xlm: string;
  v2: V2Pins | null;
  /** The call being judged, its contract and the operation's authorizations. */
  contract: string;
  call: xdr.InvokeContractArgs;
  auth: xdr.SorobanAuthorizationEntry[];
}

/** A call rule: what the call's arguments must say for this action (§5.2). Each was written from the contract's own
 *  signature: contracts/launchpad and contracts/moments (the deployed v1 WASMs), contracts/launchpad-v2,
 *  contracts/launch-token-v2, contracts/moments-v2 and contracts/lp-locker (v2), the Soroswap and Aquarius routers'
 *  published ABIs, Blend's pool, Circle's TokenMessengerMinter and SEP-41. A function without a rule is not signed. */
type CallRule = (args: xdr.ScVal[], rc: RuleContext) => void;

function arity(args: xdr.ScVal[], n: number) {
  if (args.length !== n) fail(ARGUMENTS);
}

function actsFor(rc: RuleContext, ...accounts: (xdr.ScVal | undefined)[]) {
  for (const a of accounts) if (addrOf(a) !== rc.user) fail(FOR_ANOTHER);
}

function anAddress(v: xdr.ScVal | undefined): string {
  const a = addrOf(v);
  if (a === null) fail(ARGUMENTS);
  return a;
}

/** A call anyone may make needs nobody's authorization: it must carry none of the user's (§20.4). */
function anyone(rc: RuleContext) {
  if (rc.auth.length) fail(ANYONE);
}

/** A claim pays the user and takes nothing: its intent declares no spend (§20.4). */
function spendsNothing(rc: RuleContext) {
  if (Object.keys(rc.intent.spend).length) fail(CLAIM_SPENDS);
}

/** The intent declares at least `amount` of `asset`, with the reasons the outflow check gives. */
function declares(rc: RuleContext, asset: string, amount: bigint) {
  if (!Object.hasOwn(rc.intent.spend, asset)) fail(`the transaction spends an asset this action doesn't declare (${asset})`);
  const cap = units(rc.intent.spend[asset]);
  if (cap === null || amount > cap) fail(`the transaction spends more than this action declares (${asset})`);
}

/** The token transfers from the user inside the authorization of the call itself, in the order the call makes them. */
function ownTransfers(rc: RuleContext): { token: string | null; to: string | null; amount: bigint | null }[] {
  const call = rc.call.toXDR("base64");
  const out: { token: string | null; to: string | null; amount: bigint | null }[] = [];
  const walk = (inv: xdr.SorobanAuthorizedInvocation) => {
    const f = inv.function();
    if (f.switch() === xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn()) {
      const c = f.contractFn();
      const args = c.args();
      if (c.functionName().toString() === "transfer" && args.length === 3 && addrOf(args[0]) === rc.user) {
        out.push({ token: scAddressString(c.contractAddress()), to: addrOf(args[1]), amount: intOf(args[2]) });
      }
    }
    for (const sub of inv.subInvocations()) walk(sub);
  };
  for (const entry of rc.auth) {
    const root = entry.rootInvocation().function();
    const own = root.switch() === xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn() &&
      root.contractFn().toXDR("base64") === call;
    if (own) walk(entry.rootInvocation());
  }
  return out;
}

const CALL_RULES: Record<string, CallRule> = {
  // SEP-41 / SAC transfer(from, to, amount): a send, to the address the user confirmed.
  transfer: (args, rc) => {
    arity(args, 3);
    actsFor(rc, args[0]);
    if (!isConfirmed(args[1], rc.intent)) fail(DESTINATION);
  },
  // approve(from, spender, amount, live_until_ledger): an allowance for a pinned contract (the CCTP messenger).
  approve: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
    const spender = addrOf(args[1]);
    if (spender === null || !rc.allowedContracts.has(spender)) fail("the allowance is for a contract outside the allowlist");
  },
  // Soroswap router swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline).
  swap_exact_tokens_for_tokens: (args, rc) => {
    arity(args, 5);
    if (addrOf(args[3]) !== rc.user) fail("swap output goes to another account");
    const path = vecOf(args[2]);
    if (!path || path.length === 0) fail(ARGUMENTS);
    const out = addrOf(path[path.length - 1]);
    if (out === null) fail(ARGUMENTS);
    atLeast(intOf(args[1]), minimumFor(rc.intent, out));
  },
  // Aquarius router swap_chained(user, swaps_chain, token_in, in_amount, out_min); each hop is
  // (tokens, pool_index, token_out), so the last hop's token_out is what the user receives.
  swap_chained: (args, rc) => {
    arity(args, 5);
    actsFor(rc, args[0]);
    const chain = vecOf(args[1]);
    const hop = chain && chain.length > 0 ? vecOf(chain[chain.length - 1]) : null;
    const out = hop && hop.length === 3 ? addrOf(hop[2]) : null;
    if (out === null) fail(ARGUMENTS);
    atLeast(intOf(args[4]), minimumFor(rc.intent, out));
  },
  // Launchpad launch(creator, quote, name, symbol, uri, creator_fee_bps, initial_buy, min_tokens_out).
  launch: (args, rc) => {
    arity(args, 8);
    actsFor(rc, args[0]);
  },
  // Launchpad buy(buyer, token, quote_in, min_tokens_out).
  buy: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
    const token = addrOf(args[1]);
    if (token === null) fail(ARGUMENTS);
    atLeast(intOf(args[3]), minimumFor(rc.intent, token));
  },
  // Launchpad sell(seller, token, tokens_in, min_quote_out): the quote asset isn't an argument, so the intent quotes
  // exactly one minimum.
  sell: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
    if (addrOf(args[1]) === null) fail(ARGUMENTS);
    atLeast(intOf(args[3]), soleMinimum(rc.intent));
  },
  // Launchpad graduate(token) and claim_creator_fees(token): anyone may call them, and they pay only the launch's own
  // creator, pair and treasury, never from the caller.
  graduate: (args) => {
    arity(args, 1);
    if (addrOf(args[0]) === null) fail(ARGUMENTS);
  },
  claim_creator_fees: (args) => {
    arity(args, 1);
    if (addrOf(args[0]) === null) fail(ARGUMENTS);
  },
  // Moments publish(creator, uri, price, quote, max_editions, window_secs).
  publish: (args, rc) => {
    arity(args, 6);
    actsFor(rc, args[0]);
  },
  // Moments collect(collector, moment_id, quantity, max_total).
  collect: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
  },
  // Blend pool submit(from, spender, to, requests).
  submit: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0], args[1], args[2]);
  },
  // CCTP TokenMessengerMinter deposit_for_burn(from, amount, destination_domain, mint_recipient, burn_token,
  // destination_caller, max_fee, min_finality_threshold).
  deposit_for_burn: (args, rc) => {
    arity(args, 8);
    actsFor(rc, args[0]);
    if (args[2].switch() !== xdr.ScValType.scvU32()) fail(ARGUMENTS);
    if (rc.monadDomain === null || args[2].u32() !== rc.monadDomain) fail("the bridge sends to another network");
    if (args[3].switch() !== xdr.ScValType.scvBytes() || args[3].bytes().length !== 32) fail(ARGUMENTS);
    const recipient = evmBytes32(rc.intent.to);
    if (recipient === null || !recipient.equals(args[3].bytes())) fail(DESTINATION);
  },
  // Launch token v2 claim(holder): the holder's rewards in the quote and the token, paid to the holder.
  claim: (args, rc) => {
    arity(args, 1);
    actsFor(rc, args[0]);
    spendsNothing(rc);
  },
};

/** A call anyone may make, of one address: a launch token, a Moment NFT or a pool. */
const byAnyone: CallRule = (args, rc) => {
  arity(args, 1);
  anAddress(args[0]);
  anyone(rc);
};

/** launchpad-v2's functions (contracts/launchpad-v2/src/lib.rs). buy and sell keep v1's arguments and rules. */
const LAUNCHPAD_V2_RULES: Record<string, CallRule> = {
  // launch(creator, p: LaunchParams, expected: LaunchTerms): the terms are this app's pins, and the creator pays
  // exactly their fee, at most the pinned bound, to the launchpad (§20.4, decision O6, finding F18).
  launch: (args, rc) => {
    arity(args, 3);
    actsFor(rc, args[0]);
    const v2 = rc.v2!;
    const p = structOf(args[1], LAUNCH_PARAMS);
    const t = structOf(args[2], LAUNCH_TERMS_FIELDS);
    const venue = structOf(t?.get("venue"), VENUE_INFO);
    const fallback = structOf(t?.get("fallback"), VENUE_INFO);
    const fee = intOf(t?.get("launch_fee"));
    const initialBuy = intOf(p?.get("initial_buy"));
    const minOut = intOf(p?.get("min_tokens_out"));
    if (!p || !t || !venue || !fallback || fee === null || fee < 0n || initialBuy === null || minOut === null) fail(ARGUMENTS);
    if (!isTicker(p.get("symbol"))) fail(TICKER);
    for (const v of [venue, fallback]) {
      const executor = addrOf(v.get("executor"));
      if (executor === null || !v2.executors.includes(executor)) fail(LAUNCH_VENUE);
    }
    const pinned = addrOf(t.get("locker")) === v2.locker &&
      hash32(t.get("token_wasm_hash")) === v2.runtimeWasmHashes.launchTokenV2 &&
      sameDurations(t.get("durations"), LAUNCH_DURATION_KEYS, v2.durations.launch) &&
      addrOf(t.get("fee_asset")) === rc.xlm;
    if (!pinned) fail(LAUNCH_TERMS);
    if (fee > v2.maxLaunchFeeStroops) fail(LAUNCH_FEE_LIMIT);
    // The fee is the first XLM the launch takes; anything else it takes (the initial buy) goes to the launchpad too.
    const transfers = ownTransfers(rc);
    const feeAt = fee > 0n ? transfers.findIndex((x) => x.token === rc.xlm) : -1;
    if (fee > 0n) {
      if (feeAt < 0) fail(LAUNCH_FEE_AMOUNT);
      if (transfers[feeAt].to !== rc.contract) fail(LAUNCH_FEE_TO);
      if (transfers[feeAt].amount !== fee) fail(LAUNCH_FEE_AMOUNT);
    }
    if (transfers.some((x, i) => i !== feeAt && x.to !== rc.contract)) fail(DESTINATION);
    if (initialBuy > 0n) atLeast(minOut, soleMinimum(rc.intent));
  },
  buy: CALL_RULES.buy,
  sell: CALL_RULES.sell,
  // refund(holder, token, tokens_in): the holder's own tokens are burned, and the intent declares the burn.
  refund: (args, rc) => {
    arity(args, 3);
    actsFor(rc, args[0]);
    const token = anAddress(args[1]);
    const tokens = intOf(args[2]);
    if (tokens === null || tokens <= 0n) fail(ARGUMENTS);
    declares(rc, token, tokens);
  },
  graduate: byAnyone,
  graduate_fallback: byAnyone,
  mark_stuck: byAnyone,
  rescue: byAnyone,
  claim_creator_fees: byAnyone,
  execute_recipient_change: byAnyone,
  // claim_owed(account, asset): anyone may pay an account what recipient changes left it; the app asks for the user's.
  claim_owed: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[0]);
    anAddress(args[1]);
    spendsNothing(rc);
    anyone(rc);
  },
  // transfer_creator_fee_recipient(token, new): the current recipient hands the fees to the address the user confirmed.
  transfer_creator_fee_recipient: (args, rc) => {
    arity(args, 2);
    anAddress(args[0]);
    if (!isConfirmed(args[1], rc.intent)) fail(DESTINATION);
  },
  // cancel_recipient_change(token, caller): the current recipient's veto, as the user.
  cancel_recipient_change: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[1]);
    anAddress(args[0]);
  },
};

/** moments-v2's functions (contracts/moments-v2/src). */
const MOMENTS_V2_RULES: Record<string, CallRule> = {
  // publish(creator, p: PublishParams, expected: MomentsTerms): the graduator, its executor, the locker, the NFT and
  // coin WASM hashes and the durations are this app's pins.
  publish: (args, rc) => {
    arity(args, 3);
    actsFor(rc, args[0]);
    const v2 = rc.v2!;
    const p = structOf(args[1], PUBLISH_PARAMS);
    const t = structOf(args[2], MOMENTS_TERMS_FIELDS);
    if (!p || !t) fail(ARGUMENTS);
    if (!isTicker(p.get("symbol"))) fail(TICKER);
    const pinned = addrOf(t.get("graduator")) === v2.graduator &&
      addrOf(t.get("executor")) === v2.soroswapExecutor &&
      addrOf(t.get("locker")) === v2.locker &&
      hash32(t.get("nft_wasm_hash")) === v2.runtimeWasmHashes.momentNft &&
      hash32(t.get("coin_wasm_hash")) === v2.runtimeWasmHashes.momentCoin &&
      sameDurations(t.get("durations"), MOMENTS_DURATION_KEYS, v2.durations.moments);
    if (!pinned) fail(MOMENT_TERMS);
  },
  // collect(collector, nft, qty, max_total): the collector pays at most max_total, in the one asset the intent spends.
  collect: (args, rc) => {
    arity(args, 4);
    actsFor(rc, args[0]);
    anAddress(args[1]);
    const qty = intOf(args[2]);
    const max = intOf(args[3]);
    const assets = Object.keys(rc.intent.spend);
    if (qty === null || max === null || assets.length !== 1) fail(ARGUMENTS);
    declares(rc, assets[0], max);
  },
  // claim(account, nft) and claim_all(account, nfts): the account's vested coins, minted to it.
  claim: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[0]);
    anAddress(args[1]);
    spendsNothing(rc);
  },
  claim_all: (args, rc) => {
    arity(args, 2);
    actsFor(rc, args[0]);
    const nfts = vecOf(args[1]);
    if (!nfts || nfts.length === 0 || nfts.some((n) => addrOf(n) === null)) fail(ARGUMENTS);
    spendsNothing(rc);
  },
  // withdraw_creator(nft), graduate(nft), expire(nft): anyone may call them; they pay only the Moment's beneficiaries.
  withdraw_creator: byAnyone,
  graduate: byAnyone,
  expire: byAnyone,
};

/** lp-locker's functions (contracts/lp-locker/src/lib.rs): harvest(pool), once per interval, by anyone. */
const LOCKER_RULES: Record<string, CallRule> = {
  harvest: byAnyone,
};

/** The rules a call to `contract` is judged by: v2's singletons have their own, every other contract v1's. */
function rulesFor(contract: string, v2: V2Pins | null): Record<string, CallRule> {
  if (v2 && contract === v2.launchpad) return LAUNCHPAD_V2_RULES;
  if (v2 && contract === v2.moments) return MOMENTS_V2_RULES;
  if (v2 && contract === v2.locker) return LOCKER_RULES;
  return CALL_RULES;
}

/** The fee caps (§4.4): the whole fee, then the resource fee's range and the inclusion bid per operation. */
function checkFees(tx: Transaction, soroban: xdr.SorobanTransactionData | null, policy: FeeCaps) {
  const fee = BigInt(tx.fee);
  const ops = BigInt(tx.operations.length);
  if (fee > policy.maxFee) fail("the network fee is above the limit");
  if (soroban) {
    const resourceFee = BigInt(soroban.resourceFee().toString());
    if (resourceFee < 0n || resourceFee > fee) fail("the resource fee is out of range");
    if (fee - resourceFee > policy.maxInclusionPerOp * ops) fail("the inclusion fee is above the limit");
  } else if (fee > policy.maxInclusionPerOp * ops) {
    fail("the inclusion fee is above the limit");
  }
}

function sorobanDataOf(tx: Transaction): xdr.SorobanTransactionData | null {
  const envelope = tx.toEnvelope();
  if (envelope.switch() !== xdr.EnvelopeType.envelopeTypeTx()) return null;
  const ext = envelope.v1().tx().ext();
  return ext.switch() === 1 ? ext.sorobanData() : null;
}

/** The transaction's memo is the intent's, compared as bytes (text), as a decimal (id) or as hex (hash); a
 *  transaction without a memo matches an intent without one. */
function memoMatches(tx: Transaction, want: Intent["memo"]): boolean {
  const m = tx.memo;
  if (m.type === "none") return !want;
  if (!want || want.type !== m.type || typeof want.value !== "string") return false;
  switch (m.type) {
    case "text":
      return Buffer.from(m.value as string | Buffer).equals(Buffer.from(want.value, "utf8"));
    case "id":
      return m.value === want.value;
    case "hash":
      return (m.value as Buffer).toString("hex") === want.value.toLowerCase();
    default:
      return false;
  }
}

/** A footprint entry a restore may bring back: the data of an allowlisted contract (a launch token or a v2 runtime
 *  contract included), or a pinned WASM (the launch token's, or one v2 creates contracts from). */
function restorable(key: xdr.LedgerKey, allowed: (contract: string) => boolean, code: Set<string>): boolean {
  switch (key.switch()) {
    case xdr.LedgerEntryType.contractData(): {
      const contract = key.contractData().contract();
      if (contract.switch() !== xdr.ScAddressType.scAddressTypeContract()) return false;
      return allowed(Address.fromScAddress(contract).toString());
    }
    case xdr.LedgerEntryType.contractCode():
      return code.has(Buffer.from(key.contractCode().hash()).toString("hex"));
    default:
      return false;
  }
}

/** Adds every token outflow the user authorizes in an invocation tree. Every movement of the user's tokens needs the
 *  user's authorization, so the authorized tree is the complete list of what the transaction can take. A transfer
 *  outside a call that has its own rule (`covered`) must go to the address the user confirmed. */
function walkAuth(inv: xdr.SorobanAuthorizedInvocation, rc: Pick<RuleContext, "user" | "intent">, covered: boolean, add: (id: string, n: bigint) => void) {
  const f = inv.function();
  if (f.switch() !== xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn()) {
    fail("the transaction asks to authorize contract creation");
  }
  const c = f.contractFn();
  const contract = scAddressString(c.contractAddress());
  if (contract === null) fail("the transaction asks to authorize contract creation");
  const fn = c.functionName().toString();
  const args = c.args();
  if (TOKEN_SPEND_FNS.has(fn)) {
    // transfer(from, to, amount) · burn(from, amount) · approve(from, spender, amount, live_until) ·
    // transfer_from(spender, from, to, amount) · burn_from(spender, from, amount). An approval counts in full: the
    // spender may take it later.
    const layout: Record<string, [number, number]> = { transfer: [0, 2], burn: [0, 1], approve: [0, 2], transfer_from: [1, 3], burn_from: [1, 2] };
    const [from, amount] = layout[fn];
    if (args.length > amount && addrOf(args[from]) === rc.user) {
      const n = intOf(args[amount]);
      if (n === null) fail(AMOUNT);
      add(contract, n);
    }
  }
  if (!covered && (fn === "transfer" || fn === "transfer_from")) {
    const [from, to] = fn === "transfer" ? [0, 1] : [1, 2];
    if (args.length > to && addrOf(args[from]) === rc.user && !isConfirmed(args[to], rc.intent)) fail(DESTINATION);
  }
  for (const sub of inv.subInvocations()) walkAuth(sub, rc, covered, add);
}

export function verifyTransaction(tx: Transaction, intent: Intent, ctx: VerifyContext): { outflow: Record<string, string> } {
  const now = ctx.now ?? Math.floor(Date.now() / 1000);
  const policy = ctx.feePolicy ?? env.network.feePolicy;
  if (tx.networkPassphrase !== ctx.passphrase) fail("wrong network");
  const sourceOk = tx.source === ctx.user || (intent.kind === "activate" && tx.source === ctx.sponsor);
  if (!sourceOk) fail("the transaction is not from your account");
  const max = Number(tx.timeBounds?.maxTime ?? 0);
  if (!max || max > now + MAX_VALIDITY_S) fail("the transaction has no short expiry");
  if (tx.operations.length === 0 || tx.operations.length > 8) fail("unexpected number of operations");
  const soroban = sorobanDataOf(tx);
  checkFees(tx, soroban, policy);
  if (!memoMatches(tx, intent.memo)) fail("the memo is not the one you confirmed");

  const outflow = new Map<string, bigint>();
  const add = (id: string, n: bigint) => {
    const sum = (outflow.get(id) ?? 0n) + n;
    if (n < 0n || sum > MAX_I64) fail(AMOUNT);
    outflow.set(id, sum);
  };
  const allowedOps = new Set(intent.ops ?? []);
  const allowedCalls = intent.calls ?? [];
  const v2 = ctx.v2 !== undefined ? ctx.v2 : v2PinsOf(env.network);
  // A contract v2 created at runtime counts only when the WASM it runs is one of the pinned runtime hashes.
  const runtimeHashes = new Set(v2 ? Object.values(v2.runtimeWasmHashes).filter(Boolean) : []);
  const runtime = ctx.runtimeContracts ?? {};
  const allowed = (contract: string) =>
    ctx.allowedContracts.has(contract) || (Object.hasOwn(runtime, contract) && runtimeHashes.has(runtime[contract]));
  const base = {
    user: ctx.user,
    intent,
    allowedContracts: ctx.allowedContracts,
    monadDomain: ctx.monadDomain !== undefined ? ctx.monadDomain : env.network.bridge.monad?.domain ?? null,
    xlm: Asset.native().contractId(ctx.passphrase),
    v2,
  };

  for (const op of tx.operations as any[]) {
    const opSource: string = op.source ?? tx.source;
    if (opSource !== ctx.user && opSource !== ctx.sponsor) fail("an operation runs from a third account");
    if (opSource === ctx.sponsor) {
      // DyorHQ pays only an account's setup (§4.3): anywhere else, the sponsor in a transaction is refused.
      if (intent.kind !== "activate") fail("the sponsor appears outside account activation");
      if (!["beginSponsoringFutureReserves", "createAccount"].includes(op.type)) fail("the sponsor account runs an unexpected operation");
    }
    if (op.type !== "invokeHostFunction" && !allowedOps.has(op.type)) fail(`operation ${op.type} is not part of this action`);
    switch (op.type) {
      case "payment":
        if (op.destination !== intent.to) fail(DESTINATION);
        add(assetId(op.asset, ctx.passphrase), stroops(op.amount));
        break;
      case "pathPaymentStrictSend":
        if (op.destination !== ctx.user) fail("swap output goes to another account");
        add(assetId(op.sendAsset, ctx.passphrase), stroops(op.sendAmount));
        if (intent.receive) {
          const want = minimumFor(intent, assetId(op.destAsset, ctx.passphrase));
          if (want === null || stroops(op.destMin) < want) fail(MINIMUM);
        }
        break;
      case "changeTrust": {
        const line = op.line as Asset;
        const spec = line.isNative() ? "native" : `${line.getCode()}:${line.getIssuer()}`;
        if (!(intent.trust ?? []).includes(spec)) fail(`unexpected trustline ${spec}`);
        // A limit of 0 removes the trustline; a negative one is malformed. Swift refuses both alike (limit > 0).
        if (stroops(op.limit) <= 0n) fail("the transaction removes a trustline");
        break;
      }
      case "beginSponsoringFutureReserves":
        if (op.sponsoredId !== ctx.user || opSource !== ctx.sponsor) fail("unexpected sponsorship");
        break;
      case "endSponsoringFutureReserves":
        if (opSource !== ctx.user) fail("unexpected sponsorship end");
        break;
      case "createAccount":
        if (opSource === ctx.sponsor) {
          // Sponsored activation: only the user's own account, with 0 XLM.
          if (op.destination !== ctx.user || stroops(op.startingBalance) !== 0n) fail("unexpected account creation");
        } else {
          // The user funds a new account (a send of XLM to an address that doesn't exist yet).
          if (op.destination !== intent.to) fail(DESTINATION);
          add(Asset.native().contractId(ctx.passphrase), stroops(op.startingBalance));
        }
        break;
      case "invokeHostFunction": {
        const fn = op.func as xdr.HostFunction;
        if (fn.switch() !== xdr.HostFunctionType.hostFunctionTypeInvokeContract()) fail("only contract calls are allowed");
        const ic = fn.invokeContract();
        if (ic.contractAddress().switch() !== xdr.ScAddressType.scAddressTypeContract()) fail("only contract calls are allowed");
        const contract = Address.fromScAddress(ic.contractAddress()).toString();
        const name = ic.functionName().toString();
        if (!allowed(contract)) fail(`contract ${contract} is not on the allowlist`);
        if (!allowedCalls.some((c) => c.contract === contract && c.fn === name)) fail(`call ${name} is not part of this action`);
        const rules = rulesFor(contract, v2);
        if (!Object.hasOwn(rules, name)) fail(`function ${name} is not on the allowlist`);
        const auth = (op.auth ?? []) as xdr.SorobanAuthorizationEntry[];
        const rc: RuleContext = { ...base, contract, call: ic, auth };
        rules[name](ic.args(), rc);
        const call = ic.toXDR("base64");
        for (const entry of auth) {
          if (entry.credentials().switch() !== xdr.SorobanCredentialsType.sorobanCredentialsSourceAccount()) {
            fail("the transaction needs a signature from another address");
          }
          // The authorization of the call itself is bound by the call's rule; any other root is bound here.
          const root = entry.rootInvocation().function();
          const covered = root.switch() === xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn() &&
            root.contractFn().toXDR("base64") === call;
          walkAuth(entry.rootInvocation(), rc, covered, add);
        }
        break;
      }
      case "restoreFootprint": {
        // Archived entries come back only as their own step, and only the app's own data (§4.9).
        if (intent.kind !== "restore") fail("restoring archived data is only allowed as its own action");
        const footprint = soroban?.resources().footprint();
        const keys = footprint ? [...footprint.readOnly(), ...footprint.readWrite()] : [];
        const wasm = ctx.launchTokenWasmHash ?? env.network.deployment?.launchTokenWasmHash ?? "";
        const code = new Set([...(wasm ? [wasm] : []), ...runtimeHashes]);
        for (const key of keys) {
          if (!restorable(key, allowed, code)) fail("the restore touches data outside the allowlist");
        }
        break;
      }
      default:
        fail(`operation ${op.type} is not allowed`);
    }
  }

  for (const [asset, amount] of outflow) {
    if (!Object.hasOwn(intent.spend, asset)) fail(`the transaction spends an asset this action doesn't declare (${asset})`);
    const cap = units(intent.spend[asset]);
    if (cap === null || amount > cap) fail(`the transaction spends more than this action declares (${asset})`);
  }
  return { outflow: Object.fromEntries([...outflow].map(([k, v]) => [k, v.toString()])) };
}

/** Who pays a step's network fee, as the phone can check it (§4.3): DyorHQ for an activation whose source is the
 *  sponsor ("setup"), or for a step marked as the starter swap whose own fee is within starterInnerFeeMax
 *  ("starter_swap"); the user otherwise. A step the server marks as sponsored never declares more than
 *  starterInnerFeeMax, so a server that claims to pay and doesn't can charge the user at most that. */
export function verifyFeePayer(
  tx: Transaction,
  intent: Intent | undefined,
  step: { feePayer?: string | null; sponsorReason?: string | null },
  ctx: Pick<VerifyContext, "sponsor" | "feePolicy">,
): "user" | "setup" | "starter_swap" {
  if (tx.source === ctx.sponsor && intent?.kind === "activate") return "setup";
  if (step.feePayer !== "sponsor") return "user";
  const policy = ctx.feePolicy ?? env.network.feePolicy;
  if (BigInt(tx.fee) > policy.starterInnerFeeMax) fail("the sponsored step's network fee is above the limit");
  return step.sponsorReason === "starter_swap" ? "starter_swap" : "user";
}
