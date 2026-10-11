// The transaction verifier. The phone runs the same rules (StellarKit/TxVerifier.swift) before it signs anything,
// and the API runs this copy on every step it builds, so a builder bug is caught before a user ever sees it.
//
// Rules: the right network and source; short time bounds; only the operation types the intent names; contract calls
// only to allowlisted contracts and functions; Soroban auth only through the source account; and the user's total
// outflow per asset (classic payments + every token transfer/burn/approve in the authorized invocation tree) never
// above what the intent declares.
import { Address, Asset, scValToNative, Transaction, xdr } from "@stellar/stellar-sdk";

export interface Intent {
  kind: string;
  /** Plain-language hint. The phone builds its own text from the fields below and never shows this one alone. */
  summary: string;
  /** Max outflow from the user's account per asset contract id, base units. */
  spend: Record<string, string>;
  /** Minimum the user receives per asset contract id (informational; checked where an op encodes it). */
  receive?: Record<string, string>;
  /** Contract calls the transaction may make. */
  calls?: { contract: string; fn: string }[];
  /** Classic operation types the transaction may contain. */
  ops?: string[];
  /** Classic assets ("CODE:ISSUER") that may get a trustline. */
  trust?: string[];
  /** Extra structured facts for display (amounts, tickers, venue). */
  display?: Record<string, string | number | boolean | null>;
}

export interface VerifyContext {
  user: string;
  sponsor: string;
  passphrase: string;
  /** Allowed contract ids for every call the intent names (pinned in the app binary). */
  allowedContracts: Set<string>;
  now?: number;
}

const TOKEN_SPEND_FNS = new Set(["transfer", "transfer_from", "burn", "burn_from", "approve"]);
const MAX_VALIDITY_S = 30 * 60;

export class VerifyError extends Error {}

function fail(msg: string): never {
  throw new VerifyError(msg);
}

function stroops(decimal: string): bigint {
  const [i, f = ""] = decimal.split(".");
  return BigInt(i) * 10_000_000n + BigInt((f + "0000000").slice(0, 7));
}

function assetId(a: Asset, passphrase: string): string {
  return a.contractId(passphrase);
}

function addrString(v: xdr.ScVal): string | null {
  try {
    if (v.switch() !== xdr.ScValType.scvAddress()) return null;
    return Address.fromScVal(v).toString();
  } catch {
    return null;
  }
}

function amountOf(v: xdr.ScVal): bigint {
  const n = scValToNative(v);
  if (typeof n === "bigint") return n;
  if (typeof n === "number") return BigInt(n);
  fail("unexpected amount type");
}

/** What a token call takes from `user`: transfer(from, to, amount) · burn(from, amount) ·
 *  approve(from, spender, amount, live_until) · transfer_from(spender, from, to, amount) · burn_from(spender, from, amount).
 *  An approval counts in full: the spender may take it later. */
function tokenOutflow(fn: string, args: xdr.ScVal[], user: string): bigint {
  const layout: Record<string, [number, number]> = {
    transfer: [0, 2],
    burn: [0, 1],
    approve: [0, 2],
    transfer_from: [1, 3],
    burn_from: [1, 2],
  };
  const l = layout[fn];
  if (!l || args.length <= l[1]) return 0n;
  return addrString(args[l[0]]) === user ? amountOf(args[l[1]]) : 0n;
}

/** Adds every token outflow the user authorizes in an invocation tree. Every movement of the user's tokens needs the
 *  user's authorization, so the authorized tree is the complete list of what the transaction can take. */
function walkAuth(inv: xdr.SorobanAuthorizedInvocation, user: string, out: Map<string, bigint>, calls: { contract: string; fn: string }[]) {
  const f = inv.function();
  if (f.switch() !== xdr.SorobanAuthorizedFunctionType.sorobanAuthorizedFunctionTypeContractFn()) {
    fail("the transaction asks to authorize contract creation");
  }
  const c = f.contractFn();
  const contract = Address.fromScAddress(c.contractAddress()).toString();
  const fn = c.functionName().toString();
  calls.push({ contract, fn });
  if (TOKEN_SPEND_FNS.has(fn)) {
    const n = tokenOutflow(fn, c.args(), user);
    if (n > 0n) out.set(contract, (out.get(contract) ?? 0n) + n);
  }
  for (const sub of inv.subInvocations()) walkAuth(sub, user, out, calls);
}

export function verifyTransaction(tx: Transaction, intent: Intent, ctx: VerifyContext): { outflow: Record<string, string> } {
  const now = ctx.now ?? Math.floor(Date.now() / 1000);
  if (tx.networkPassphrase !== ctx.passphrase) fail("wrong network");
  const sourceOk = tx.source === ctx.user || (intent.kind === "activate" && tx.source === ctx.sponsor);
  if (!sourceOk) fail("the transaction is not from your account");
  const max = Number(tx.timeBounds?.maxTime ?? 0);
  if (!max || max > now + MAX_VALIDITY_S) fail("the transaction has no short expiry");
  if (tx.operations.length === 0 || tx.operations.length > 8) fail("unexpected number of operations");

  const outflow = new Map<string, bigint>();
  const add = (id: string, n: bigint) => outflow.set(id, (outflow.get(id) ?? 0n) + n);
  const allowedOps = new Set(intent.ops ?? []);
  const allowedCalls = intent.calls ?? [];
  const seenCalls: { contract: string; fn: string }[] = [];

  for (const op of tx.operations as any[]) {
    const opSource: string = op.source ?? tx.source;
    if (opSource !== ctx.user && opSource !== ctx.sponsor) fail("an operation runs from a third account");
    if (opSource === ctx.sponsor && !["beginSponsoringFutureReserves", "createAccount"].includes(op.type)) {
      fail("the sponsor account runs an unexpected operation");
    }
    if (op.type !== "invokeHostFunction" && !allowedOps.has(op.type)) fail(`operation ${op.type} is not part of this action`);
    switch (op.type) {
      case "payment":
        if (opSource === ctx.user) add(assetId(op.asset, ctx.passphrase), stroops(op.amount));
        break;
      case "pathPaymentStrictSend":
        if (op.destination !== ctx.user) fail("swap output goes to another account");
        add(assetId(op.sendAsset, ctx.passphrase), stroops(op.sendAmount));
        if (intent.receive) {
          const want = intent.receive[assetId(op.destAsset, ctx.passphrase)];
          if (!want || stroops(op.destMin) < BigInt(want)) fail("the minimum received is lower than quoted");
        }
        break;
      case "changeTrust": {
        const line = op.line as Asset;
        const spec = line.isNative() ? "native" : `${line.getCode()}:${line.getIssuer()}`;
        if (!(intent.trust ?? []).includes(spec)) fail(`unexpected trustline ${spec}`);
        if (stroops(op.limit) === 0n) fail("the transaction removes a trustline");
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
          add(Asset.native().contractId(ctx.passphrase), stroops(op.startingBalance));
        }
        break;
      case "invokeHostFunction": {
        const fn = op.func as xdr.HostFunction;
        if (fn.switch() !== xdr.HostFunctionType.hostFunctionTypeInvokeContract()) fail("only contract calls are allowed");
        const ic = fn.invokeContract();
        const contract = Address.fromScAddress(ic.contractAddress()).toString();
        const name = ic.functionName().toString();
        if (!ctx.allowedContracts.has(contract)) fail(`contract ${contract} is not on the allowlist`);
        if (!allowedCalls.some((c) => c.contract === contract && c.fn === name)) fail(`call ${name} is not part of this action`);
        for (const entry of (op.auth ?? []) as xdr.SorobanAuthorizationEntry[]) {
          if (entry.credentials().switch() !== xdr.SorobanCredentialsType.sorobanCredentialsSourceAccount()) {
            fail("the transaction needs a signature from another address");
          }
          const nested = new Map<string, bigint>();
          walkAuth(entry.rootInvocation(), ctx.user, nested, seenCalls);
          for (const [k, v] of nested) add(k, v);
        }
        break;
      }
      default:
        fail(`operation ${op.type} is not allowed`);
    }
  }

  for (const [asset, amount] of outflow) {
    const cap = intent.spend[asset];
    if (cap === undefined) fail(`the transaction spends an asset this action doesn't declare (${asset})`);
    if (amount > BigInt(cap)) fail(`the transaction spends more than this action declares (${asset})`);
  }
  return { outflow: Object.fromEntries([...outflow].map(([k, v]) => [k, v.toString()])) };
}
