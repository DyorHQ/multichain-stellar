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
// Both verifiers judge the same vectors (backend/tests/vectors/gen-vectors.ts) and give the same reasons: the Swift
// one's are these with a capital letter and a full stop.
import { Address, Asset, scValToNative, Transaction, xdr } from "@stellar/stellar-sdk";
import { env } from "./env.ts";

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

interface RuleContext {
  user: string;
  intent: Intent;
  allowedContracts: Set<string>;
  monadDomain: number | null;
}

/** A call rule: what the call's arguments must say for this action (§5.2). Each was written from the contract's own
 *  signature: contracts/launchpad and contracts/moments (the deployed v1 WASMs), the Soroswap and Aquarius routers'
 *  published ABIs, Blend's pool, Circle's TokenMessengerMinter and SEP-41. A function without a rule is not signed. */
type CallRule = (args: xdr.ScVal[], rc: RuleContext) => void;

function arity(args: xdr.ScVal[], n: number) {
  if (args.length !== n) fail(ARGUMENTS);
}

function actsFor(rc: RuleContext, ...accounts: (xdr.ScVal | undefined)[]) {
  for (const a of accounts) if (addrOf(a) !== rc.user) fail(FOR_ANOTHER);
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
};

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

/** A footprint entry a restore may bring back: an allowlisted contract's or a launch token's data, or the pinned
 *  launch-token WASM. */
function restorable(key: xdr.LedgerKey, allowed: Set<string>, launchTokenWasmHash: string): boolean {
  switch (key.switch()) {
    case xdr.LedgerEntryType.contractData(): {
      const contract = key.contractData().contract();
      if (contract.switch() !== xdr.ScAddressType.scAddressTypeContract()) return false;
      return allowed.has(Address.fromScAddress(contract).toString());
    }
    case xdr.LedgerEntryType.contractCode():
      return launchTokenWasmHash !== "" && key.contractCode().hash().toString("hex") === launchTokenWasmHash;
    default:
      return false;
  }
}

/** Adds every token outflow the user authorizes in an invocation tree. Every movement of the user's tokens needs the
 *  user's authorization, so the authorized tree is the complete list of what the transaction can take. A transfer
 *  outside a call that has its own rule (`covered`) must go to the address the user confirmed. */
function walkAuth(inv: xdr.SorobanAuthorizedInvocation, rc: RuleContext, covered: boolean, add: (id: string, n: bigint) => void) {
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
  const rc: RuleContext = {
    user: ctx.user,
    intent,
    allowedContracts: ctx.allowedContracts,
    monadDomain: ctx.monadDomain !== undefined ? ctx.monadDomain : env.network.bridge.monad?.domain ?? null,
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
        if (!ctx.allowedContracts.has(contract)) fail(`contract ${contract} is not on the allowlist`);
        if (!allowedCalls.some((c) => c.contract === contract && c.fn === name)) fail(`call ${name} is not part of this action`);
        if (!Object.hasOwn(CALL_RULES, name)) fail(`function ${name} is not on the allowlist`);
        CALL_RULES[name](ic.args(), rc);
        const call = ic.toXDR("base64");
        for (const entry of (op.auth ?? []) as xdr.SorobanAuthorizationEntry[]) {
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
        for (const key of keys) {
          if (!restorable(key, ctx.allowedContracts, wasm)) fail("the restore touches data outside the allowlist");
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
