// Monad ↔ Stellar USDC (docs/DESIGN-stellar-parity.md §5.7, §6.10).
// Testnet: Circle CCTP v2 (Monad testnet domain 15 ↔ Stellar testnet domain 27; both directions are registered on
// both chains, checked 2026-10-11). Monad → Stellar mints to Circle's CctpForwarder, which forwards to the user's
// G-address in the same call; DyorHQ's keeper relays `mint_and_forward` once Iris attests (protocol upkeep, §4.1): at
// most 10 transfers a user starts in a UTC day, and only a burn that is the transfer's own (its amount, at least 1
// USDC, through the forwarder to the user's address), once. Stellar → Monad burns on Stellar and returns a "claim on
// Monad" step (receiveMessage) for the Pro wallet to sign. A quote's fee is Circle's own, from Iris's fee API, and its
// time is how long the last transfers that way took.
// Mainnet: NEAR Intents 1Click (live Monad ↔ Stellar USDC routes; no testnet).
import { keccak_256 } from "@noble/hashes/sha3";
import { StrKey } from "@stellar/stellar-sdk";
import type postgres from "postgres";
import type { BridgeDirection, BridgeQuote, BridgeStart, BridgeStatus, BridgeTransfer, EvmStep } from "./contract.ts";
import { sql, tableExists } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById } from "./networks.ts";
import { Builder, createPlan, registerBuilder, StepSpec } from "./plans.ts";
import {
  classicBalances,
  Contract,
  fromStroops,
  invoke,
  keeper,
  Keypair,
  loadAccount,
  newTx,
  prepare,
  requireAccount,
  rpcServer,
  sendSigned,
  sv,
} from "./stellar.ts";

/** The finality every transfer here waits for: Circle's standard transfer (1000 would be a fast one). The burns ask
 *  for it, and quotes price it. */
const STANDARD_FINALITY = 2000;

/** The least a transfer from Monad moves, in Monad USDC's base units (6 decimals): 1 USDC. The keeper pays its relay. */
export const MIN_INBOUND = 1_000_000n;

/** The most transfers from Monad one user starts, and so the keeper relays, in a UTC day. */
export const RELAYS_PER_DAY = 10;

// ------------------------------------------------------------------------------------------------ EVM encoding

// Call data is written in lowercase hex, checksummed addresses included.
const hexOf = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const selector = (sig: string) => hexOf(keccak_256(new TextEncoder().encode(sig)).subarray(0, 4));
const word = (hex: string) => hex.replace(/^0x/, "").toLowerCase().padStart(64, "0");
const uint = (n: bigint | number) => word(BigInt(n).toString(16));
/** A Stellar contract (C…) as CCTP's bytes32: its 32-byte id. */
const contractWord = (c: string) => hexOf(StrKey.decodeContract(c));

const APPROVE = selector("approve(address,uint256)");
const DEPOSIT_FOR_BURN_WITH_HOOK = selector("depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)");

function bytesTail(data: Uint8Array): string {
  const len = uint(data.length);
  const padded = hexOf(data).padEnd(Math.ceil(data.length / 32) * 64, "0");
  return len + padded;
}

export function isEvmAddress(a: string): boolean {
  return /^0x[0-9a-fA-F]{40}$/.test(a);
}

export function evmToBytes32(a: string): Uint8Array {
  if (!isEvmAddress(a)) throw bad("bad_address", "That isn't a Monad address (0x…).");
  const out = new Uint8Array(32);
  out.set(Uint8Array.from(a.slice(2).match(/../g)!.map((h) => parseInt(h, 16))), 12);
  return out;
}

/** CctpForwarder hook data: 24 zero bytes · uint32 version 0 · uint32 length · strkey bytes
 *  (developers.circle.com/cctp/references/stellar, "Hook format"). */
export function forwarderHookData(recipient: string): Uint8Array {
  const r = new TextEncoder().encode(recipient);
  const out = new Uint8Array(32 + r.length);
  new DataView(out.buffer).setUint32(24, 0);
  new DataView(out.buffer).setUint32(28, r.length);
  out.set(r, 32);
  return out;
}

export function encodeApprove(spender: string, amount: bigint): string {
  return "0x" + APPROVE + word(spender.slice(2)) + uint(amount);
}

export function encodeDepositForBurnWithHook(p: {
  amount: bigint;
  destinationDomain: number;
  mintRecipient: Uint8Array;
  burnToken: string;
  destinationCaller: Uint8Array;
  maxFee: bigint;
  minFinalityThreshold: number;
  hookData: Uint8Array;
}): string {
  const head = [
    uint(p.amount),
    uint(p.destinationDomain),
    hexOf(p.mintRecipient),
    word(p.burnToken.slice(2)),
    hexOf(p.destinationCaller),
    uint(p.maxFee),
    uint(p.minFinalityThreshold),
    uint(8 * 32), // offset of hookData
  ].join("");
  return "0x" + DEPOSIT_FOR_BURN_WITH_HOOK + head + bytesTail(p.hookData);
}

export function encodeReceiveMessage(message: Uint8Array, attestation: Uint8Array): string {
  const mTail = bytesTail(message);
  const offsetA = 64 + mTail.length / 2;
  return "0x" + selector("receiveMessage(bytes,bytes)") + uint(64) + uint(offsetA) + mTail + bytesTail(attestation);
}

/** The pinned contracts a transfer to Stellar goes through: Monad's USDC and TokenMessengerV2, then Stellar's
 *  TokenMessengerMinter, which mints, and CctpForwarder, which pays out. */
export interface InboundPins {
  chainId: number;
  usdc: string;
  tokenMessenger: string;
  /** Monad's CCTP domain. */
  monadDomain: number;
  /** Stellar's CCTP domain. */
  domain: number;
  /** C… */
  tokenMessengerMinter: string;
  /** C… */
  forwarder: string;
}

function inboundPins(): InboundPins {
  const monad = env.network.bridge.monad!;
  const cctp = env.network.contracts.cctp!;
  return {
    chainId: monad.chainId,
    usdc: monad.usdc,
    tokenMessenger: monad.tokenMessenger,
    monadDomain: monad.domain,
    domain: cctp.domain,
    tokenMessengerMinter: cctp.tokenMessengerMinter,
    forwarder: cctp.forwarder,
  };
}

/** What the Monad wallet signs for a transfer to Stellar: USDC's approve of TokenMessengerV2, then
 *  depositForBurnWithHook to Stellar's domain, minted to and called by the CctpForwarder, with the user's G-address as
 *  the hook data, so the forwarder pays it out to them. */
export function inboundSteps(user: string, amount: bigint, pins: InboundPins): EvmStep[] {
  const forwarder = StrKey.decodeContract(pins.forwarder);
  return [
    { kind: "evm", chainId: pins.chainId, label: "Allow USDC", to: pins.usdc, data: encodeApprove(pins.tokenMessenger, amount), value: "0" },
    {
      kind: "evm",
      chainId: pins.chainId,
      label: "Send to Stellar",
      to: pins.tokenMessenger,
      value: "0",
      data: encodeDepositForBurnWithHook({
        amount,
        destinationDomain: pins.domain,
        mintRecipient: forwarder,
        burnToken: pins.usdc,
        destinationCaller: forwarder,
        maxFee: 0n,
        minFinalityThreshold: STANDARD_FINALITY,
        hookData: forwarderHookData(user),
      }),
    },
  ];
}

/** The rules the phone checks a transfer's Monad steps by before it signs them (§5.7, StellarEvmStepCheck), checked
 *  here first: a step goes to the pinned USDC or TokenMessengerV2 only, on the pinned chain, with no value; the
 *  approve is TokenMessengerV2's, for at most the amount; the burn moves exactly the amount, of USDC, to Stellar's
 *  domain, minted to and called by the CctpForwarder, with the user's address as the hook. The reason a step breaks
 *  one, or null. */
export function inboundStepsRefusal(steps: EvmStep[], user: string, amount: bigint, pins: InboundPins): string | null {
  const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();
  const addressWord = (w: string) => /^0{24}/.test(w) ? `0x${w.slice(24)}` : null;
  if (steps.length !== 2) return "a transfer to Stellar is an approve, then a burn";
  for (const s of steps) {
    if (s.kind !== "evm" || s.chainId !== pins.chainId || s.value !== "0") return "a step leaves the pinned Monad chain or sends MON";
    if (!(same(s.to, pins.usdc) || same(s.to, pins.tokenMessenger))) return "a step calls a contract other than USDC and TokenMessengerV2";
    if (!/^0x[0-9a-f]{8}(?:[0-9a-f]{64})*$/i.test(s.data)) return "a step's call data is malformed";
  }
  const [approve, burn] = steps;
  const a = callWords(approve.data, APPROVE);
  if (!same(approve.to, pins.usdc) || a?.length !== 2) return "the first step isn't USDC's approve";
  const spender = addressWord(a[0]);
  if (spender === null || !same(spender, pins.tokenMessenger)) return "the approve is for another spender";
  if (BigInt(`0x${a[1]}`) > amount) return "the approve is for more than the amount";
  const b = callWords(burn.data, DEPOSIT_FOR_BURN_WITH_HOOK);
  if (!same(burn.to, pins.tokenMessenger) || !b || b.length < 9) return "the second step isn't TokenMessengerV2's depositForBurnWithHook";
  const forwarder = contractWord(pins.forwarder);
  const burnToken = addressWord(b[3]);
  if (BigInt(`0x${b[0]}`) !== amount) return "the burn isn't for the amount";
  if (BigInt(`0x${b[1]}`) !== BigInt(pins.domain)) return "the burn sends to another network";
  if (b[2] !== forwarder || b[4] !== forwarder) return "the burn isn't minted to and called by the CctpForwarder";
  if (burnToken === null || !same(burnToken, pins.usdc)) return "the burn isn't of USDC";
  // The hook data: its offset (just after the eight head words), its length, then its bytes, zero-padded to a word.
  const hook = hexOf(forwarderHookData(user));
  const padded = hook.padEnd(Math.ceil(hook.length / 64) * 64, "0");
  if (BigInt(`0x${b[7]}`) !== 256n || BigInt(`0x${b[8]}`) !== BigInt(hook.length / 2) || b.slice(9).join("") !== padded) {
    return "the hook data isn't the user's address";
  }
  return null;
}

/** The 32-byte words of `data` after the selector `fn`, as hex; null for another function. */
function callWords(data: string, fn: string): string[] | null {
  if (data.slice(2, 10).toLowerCase() !== fn) return null;
  return data.slice(10).toLowerCase().match(/.{64}/g) ?? [];
}

// ------------------------------------------------------------------------------------------------ burn messages

/** The fields of a CCTP v2 burn message the keeper's relay checks: MessageV2's header, then BurnMessageV2's body
 *  (Circle's evm-cctp-contracts, src/messages/v2), as Iris returns it. Every bytes32 is lowercase hex: an EVM address
 *  is left-padded with zeros, a Stellar contract is its 32-byte id. */
export interface BurnMessage {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  /** The sending TokenMessenger. */
  sender: string;
  /** The receiving TokenMessenger. */
  recipient: string;
  destinationCaller: string;
  bodyVersion: number;
  burnToken: string;
  mintRecipient: string;
  amount: bigint;
  hookData: string;
}

/** MessageV2's header is 148 bytes; BurnMessageV2's body is 228 bytes before its hook data. */
const MESSAGE_HEADER = 148;
const BURN_BODY = 228;

/** `message`'s fields, or null when it is too short to be a burn. */
export function decodeBurnMessage(message: Uint8Array): BurnMessage | null {
  if (message.length < MESSAGE_HEADER + BURN_BODY) return null;
  const view = new DataView(message.buffer, message.byteOffset, message.byteLength);
  const bytes32 = (at: number) => hexOf(message.subarray(at, at + 32));
  const body = MESSAGE_HEADER;
  return {
    version: view.getUint32(0),
    sourceDomain: view.getUint32(4),
    destinationDomain: view.getUint32(8),
    sender: bytes32(44),
    recipient: bytes32(76),
    destinationCaller: bytes32(108),
    bodyVersion: view.getUint32(body),
    burnToken: bytes32(body + 4),
    mintRecipient: bytes32(body + 36),
    amount: BigInt(`0x${bytes32(body + 68)}`),
    hookData: hexOf(message.subarray(body + BURN_BODY)),
  };
}

/** Why the keeper doesn't relay `message` for a transfer from Monad, or null when it does. The keeper pays for each
 *  relay, so it relays only the burn its Monad steps describe (inboundSteps): a CCTP v2 burn of Monad's USDC from
 *  Monad's TokenMessengerV2 to Stellar's TokenMessengerMinter, minted to and called by the CctpForwarder, of exactly
 *  the transfer's amount (at least 1 USDC), with the transfer's address as the hook, so the forwarder pays it out to
 *  them. A burn the user signed otherwise (smaller, or for someone else) isn't relayed. */
export function inboundMessageRefusal(message: Uint8Array, transfer: { address: string; amount: bigint }, pins: InboundPins): string | null {
  const m = decodeBurnMessage(message);
  if (!m || m.version !== 1 || m.bodyVersion !== 1) return "it isn't a CCTP v2 burn";
  if (m.sourceDomain !== pins.monadDomain || m.destinationDomain !== pins.domain) return "it isn't a burn from Monad to Stellar";
  if (m.sender !== word(pins.tokenMessenger) || m.recipient !== contractWord(pins.tokenMessengerMinter)) {
    return "it isn't between the pinned TokenMessengerV2 and TokenMessengerMinter";
  }
  const forwarder = contractWord(pins.forwarder);
  if (m.mintRecipient !== forwarder || m.destinationCaller !== forwarder) return "it isn't minted to and called by the CctpForwarder";
  if (m.burnToken !== word(pins.usdc)) return "it isn't a burn of USDC";
  if (m.amount !== transfer.amount || m.amount < MIN_INBOUND) return "it isn't for the transfer's amount";
  if (m.hookData !== hexOf(forwarderHookData(transfer.address))) return "its hook data isn't the transfer's address";
  return null;
}

// ------------------------------------------------------------------------------------------------ quotes

/** A fee in basis points, exactly: num / den (Iris writes decimals such as 1.4). */
export interface Bps {
  num: bigint;
  den: bigint;
}

/** Iris's fee in basis points as it writes it, a JSON number (0, 1, 1.4), exactly; null for anything else, a
 *  negative fee or one above 100%. */
export function parseBps(v: unknown): Bps | null {
  if (typeof v !== "number" || !Number.isFinite(v) || v < 0 || v > 10_000) return null;
  const m = /^(\d+)(?:\.(\d+))?$/.exec(String(v));
  if (!m) return null;
  const frac = m[2] ?? "";
  return { num: BigInt(m[1] + frac), den: 10n ** BigInt(frac.length) };
}

/** The bridge's fee on `amount` at `bps`: ceil(amount × bps / 10⁴), in the amount's own base units (§6.10). */
export function bridgeFee(amount: bigint, bps: Bps): bigint {
  const d = bps.den * 10_000n;
  return (amount * bps.num + d - 1n) / d;
}

/** How long Iris's fee for a route is kept. */
const IRIS_FEE_TTL_MS = 10 * 60_000;
const irisFees = new Map<string, { bps: Bps; at: number }>();

/** Forgets the Iris fees kept so far (tests). */
export function forgetIrisFees(): void {
  irisFees.clear();
}

/** Circle's fee for a standard transfer from CCTP domain `src` to `dst`: the finalityThreshold 2000 row of Iris's
 *  GET /v2/burn/USDC/fees/{src}/{dst}, in basis points, kept 10 minutes per route. 502 bridge_quote_failed when Iris
 *  doesn't answer with one. */
export async function irisStandardFee(src: number, dst: number, now = Date.now()): Promise<Bps> {
  const key = `${src}/${dst}`;
  const kept = irisFees.get(key);
  if (kept && now - kept.at < IRIS_FEE_TTL_MS) return kept.bps;
  let rows: unknown = null;
  try {
    const res = await fetch(`${env.network.apis.iris}/v2/burn/USDC/fees/${src}/${dst}`, { signal: AbortSignal.timeout(8_000) });
    if (res.ok) rows = await res.json();
  } catch {
    // unreachable: no fee
  }
  const row = Array.isArray(rows) ? rows.find((r) => r?.finalityThreshold === STANDARD_FINALITY) : undefined;
  const bps = parseBps(row?.minimumFee);
  if (!bps) throw new ApiError(502, "bridge_quote_failed", "The bridge fee isn't available right now. Try again in a minute.");
  irisFees.set(key, { bps, at: now });
  return bps;
}

/** A quote's time is the median of this many completed transfers that way, newest first... */
const ETA_SAMPLE = 20;
/** ...and none with fewer than this many. */
const ETA_MIN = 3;

/** The median of these durations in whole seconds, or null with fewer than ETA_MIN; etaBasis is how many it is over. */
export function etaOf(seconds: number[]): { etaSeconds: number | null; etaBasis: number } {
  const n = seconds.length;
  if (n < ETA_MIN) return { etaSeconds: null, etaBasis: n };
  const s = [...seconds].sort((a, b) => a - b);
  const mid = Math.floor(n / 2);
  return { etaSeconds: Math.round(n % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2), etaBasis: n };
}

/** How long the last ETA_SAMPLE completed CCTP transfers this way took, start to finish, in seconds. */
async function recentDurations(direction: BridgeDirection): Promise<number[]> {
  const rows = await sql()`
    select extract(epoch from updated_at - created_at)::float8 as seconds from lite.bridge_transfers
     where direction = ${direction} and route = 'cctp' and status = 'completed' order by updated_at desc limit ${ETA_SAMPLE}`;
  return rows.map((r) => Number(r.seconds));
}

function directionArg(v: unknown): BridgeDirection {
  if (v !== "monad_to_stellar" && v !== "stellar_to_monad") throw bad("bad_direction", "direction is monad_to_stellar or stellar_to_monad.");
  return v;
}

/** The CCTP domains a transfer goes from and to. */
function domains(direction: string): { src: number; dst: number } {
  const monad = env.network.bridge.monad!.domain;
  const stellar = env.network.contracts.cctp!.domain;
  return direction === "monad_to_stellar" ? { src: monad, dst: stellar } : { src: stellar, dst: monad };
}

/** `amount` of the sending side's USDC in the receiving side's base units: 7 decimals on Stellar, 6 on Monad and in
 *  every CCTP message, so a burn on Stellar moves whole micro-USDC only. */
function received(direction: BridgeDirection, amount: bigint): bigint {
  return direction === "monad_to_stellar" ? amount * 10n : amount / 10n;
}

// ------------------------------------------------------------------------------------------------ API

/** What a transfer of `amount` (the sending side's base units) delivers, Circle's fee for it and how long the last
 *  transfers that way took. */
export async function bridgeQuote(input: { direction: string; amount: bigint }): Promise<BridgeQuote> {
  const direction = directionArg(input.direction);
  if (env.network.name !== "testnet") return await oneClickQuote(direction, input.amount, true, "", "");
  const { src, dst } = domains(direction);
  const fee = bridgeFee(input.amount, await irisStandardFee(src, dst));
  return {
    route: "cctp",
    direction,
    amountIn: input.amount.toString(),
    amountOut: received(direction, input.amount - fee).toString(),
    fee: fee.toString(),
    feeSource: "circle-iris",
    ...etaOf(await recentDurations(direction)),
    note: "Testnet CCTP: Monad testnet USDC ↔ Circle test USDC on Stellar.",
  };
}

// The relay cap (§6.10). A transfer from Monad holds one of its user's RELAYS_PER_DAY relays for a UTC day
// (relay_day, migration 11) from the moment its Monad steps are handed out, reported or not, so the 11th start of a
// day is refused however many of the 10 were reported. One started on an earlier day takes one of today's when its
// burn is reported. Both run under the user's relay lock, so requests sent together can't pass the cap together.

const relayLimit = () => new ApiError(429, "bridge_relay_limit", "You've bridged in many times today. Try again tomorrow.");

/** How many of `user`'s transfers from Monad hold one of today's relays. */
async function relaysToday(q: postgres.Sql, user: string): Promise<number> {
  const rows = await q`
    select count(*)::int as relays from lite.bridge_transfers where address = ${user} and relay_day = (now() at time zone 'utc')::date`;
  return Number(rows[0]?.relays ?? 0);
}

/** Runs `fn` in one transaction that holds `user`'s relay lock, with the relays their day already holds: what `fn`
 *  decides from that count still holds when it commits. */
async function withRelays<T>(user: string, fn: (tx: postgres.Sql, relays: number) => Promise<T>): Promise<T> {
  return await sql().begin(async (tx) => {
    await tx`select pg_advisory_xact_lock(hashtextextended(${`lite.bridge_relays:${user}`}, 0))`;
    return await fn(tx, await relaysToday(tx, user));
  }) as T;
}

/** Records a transfer from Monad `user` started, awaiting its burn: it takes one of today's relays, or 429
 *  bridge_relay_limit when they are all taken. */
async function newInboundTransfer(user: string, amount: bigint): Promise<BridgeTransfer> {
  return await withRelays(user, async (tx, relays) => {
    if (relays >= RELAYS_PER_DAY) throw relayLimit();
    const rows = await tx`
      insert into lite.bridge_transfers (address, direction, route, amount, recipient, relay_day)
      values (${user}, 'monad_to_stellar', 'cctp', ${amount.toString()}, ${user}, (now() at time zone 'utc')::date)
      returning id, status`;
    return { id: rows[0].id as string, status: rows[0].status as string, direction: "monad_to_stellar" };
  });
}

/** Records a transfer to Monad `user` started, awaiting its burn. */
export async function newOutboundTransfer(user: string, amount: bigint, monadAddress: string): Promise<BridgeTransfer> {
  const rows = await sql()`
    insert into lite.bridge_transfers (address, direction, route, amount, recipient)
    values (${user}, 'stellar_to_monad', 'cctp', ${amount.toString()}, ${monadAddress})
    returning id, status`;
  return { id: rows[0].id as string, status: rows[0].status as string, direction: "stellar_to_monad" };
}

/** The labels and steps of a transfer to Monad: Circle's TokenMessengerMinter pulls with transfer_from, so the burn
 *  needs an allowance first (two steps: a Soroban transaction holds one contract call). */
export function outboundSteps(amount: bigint, monadAddress: string): { label: string; spec: StepSpec }[] {
  const cctp = env.network.contracts.cctp!;
  const usdc = assetById(env.network, "USDC")!;
  return [
    { label: "Allow the USDC transfer", spec: { kind: "token_approve", token: usdc.contract, spender: cctp.tokenMessengerMinter, amount: amount.toString() } },
    { label: "Send USDC to Monad", spec: { kind: "cctp_burn", amount: amount.toString(), recipient: monadAddress, usdc: usdc.contract } },
  ];
}

/** Starts a transfer (`amount` in the sending side's base units): to Stellar, the Monad steps for the Pro wallet; to
 *  Monad, the plan the phone signs. */
export async function startBridge(user: string, input: { direction: string; amount: bigint; monadAddress: string }): Promise<BridgeStart> {
  if (env.network.name !== "testnet") throw new ApiError(501, "mainnet_route", "Mainnet bridging uses NEAR Intents; enable it with the mainnet launch.");
  const direction = directionArg(input.direction);
  if (!isEvmAddress(input.monadAddress)) throw bad("bad_address", "Your Monad address is required.");

  if (direction === "monad_to_stellar") {
    const amount6 = input.amount; // Monad USDC has 6 decimals
    if (amount6 < MIN_INBOUND) throw bad("too_small", "Bridge at least 1 USDC from Monad.");
    // Refused before Horizon is asked; recording the transfer checks again, under the lock.
    if ((await relaysToday(sql(), user)) >= RELAYS_PER_DAY) throw relayLimit();
    // The forwarder pays out to the account's USDC trustline: without one, the mint on Stellar would fail.
    const classic = await classicBalances(user);
    if (!classic) throw new ApiError(409, "account_inactive", "Activate your Stellar account first.");
    const usdc = assetById(env.network, "USDC")!;
    if (!classic.balances.some((b) => b.asset === usdc.classic)) throw new ApiError(409, "needs_usdc", "Enable USDC on Stellar first, so the bridge can deliver it.");
    const pins = inboundPins();
    const evmSteps = inboundSteps(user, amount6, pins);
    const refusal = inboundStepsRefusal(evmSteps, user, amount6, pins);
    if (refusal) {
      // Steps the phone would refuse: never hand them out.
      throw new ApiError(500, "self_check_failed", "We built a transaction that didn't pass our own checks. Nothing was sent.", { reason: refusal });
    }
    return { transfer: await newInboundTransfer(user, amount6), evmSteps };
  }

  const amount7 = input.amount;
  if (amount7 <= 0n || amount7 % 10n !== 0n) throw bad("bad_amount", "Stellar → Monad moves whole micro-USDC (6 decimals).");
  // The plan first: a transfer is recorded only once its first step is built.
  const plan = await createPlan(user, "bridge_out", outboundSteps(amount7, input.monadAddress));
  return { transfer: await newOutboundTransfer(user, amount7, input.monadAddress), plan };
}

const TRANSFER_ID = /^[0-9a-f-]{36}$/;

/** The burn's transaction hash, from the phone; the indexer follows it from now on. A transfer from Monad started on
 *  an earlier UTC day takes one of today's relays now (429 bridge_relay_limit while they are all taken: it can be
 *  reported again tomorrow), so the keeper relays at most RELAYS_PER_DAY of a user's transfers for any one day. */
export async function setSourceTx(user: string, id: string, txHash: string): Promise<{ id: string; status: string }> {
  if (!/^(0x[0-9a-fA-F]{64}|[0-9a-f]{64})$/.test(txHash)) throw bad("bad_hash", "That isn't a transaction hash.");
  if (!TRANSFER_ID.test(id)) throw notFound("Transfer");
  return await withRelays(user, async (tx, relays) => {
    const rows = await tx`
      select relay_day < (now() at time zone 'utc')::date as late from lite.bridge_transfers
       where id = ${id} and address = ${user} and status = 'awaiting_source'`;
    if (rows.length === 0) throw notFound("Transfer");
    if (rows[0].late && relays >= RELAYS_PER_DAY) throw relayLimit();
    const reported = await tx`
      update lite.bridge_transfers set source_tx = ${txHash}, status = 'attesting', updated_at = now(),
             relay_day = case when relay_day is not null then (now() at time zone 'utc')::date end
       where id = ${id} returning id, status`;
    return { id: reported[0].id as string, status: reported[0].status as string };
  });
}

export async function transferStatus(user: string, id: string): Promise<BridgeStatus> {
  if (!TRANSFER_ID.test(id)) throw notFound("Transfer");
  const rows = await sql()`select * from lite.bridge_transfers where id = ${id} and address = ${user}`;
  if (rows.length === 0) throw notFound("Transfer");
  const t = rows[0];
  const out: BridgeStatus = {
    id: t.id, direction: t.direction, route: t.route, amount: String(t.amount), recipient: t.recipient, status: t.status, sourceTx: t.source_tx, destTx: t.dest_tx, error: t.error,
  };
  if (t.direction === "stellar_to_monad" && t.status === "relaying" && t.message && t.attestation) {
    const monad = env.network.bridge.monad!;
    out.claim = {
      kind: "evm",
      chainId: monad.chainId,
      label: "Claim on Monad",
      to: monad.messageTransmitter,
      value: "0",
      data: encodeReceiveMessage(hexToBytes(t.message as string), hexToBytes(t.attestation as string)),
    };
  }
  return out;
}

export async function markClaimed(user: string, id: string, txHash: string): Promise<{ id: string; status: "completed" }> {
  if (!TRANSFER_ID.test(id)) throw notFound("Transfer");
  const rows = await sql()`update lite.bridge_transfers set dest_tx = ${txHash}, status = 'completed', updated_at = now()
                            where id = ${id} and address = ${user} and status = 'relaying' returning id`;
  if (rows.length === 0) throw notFound("Transfer");
  return { id, status: "completed" };
}

function hexToBytes(h: string): Uint8Array {
  const s = h.replace(/^0x/, "");
  return Uint8Array.from(s.match(/../g) ?? [], (x) => parseInt(x, 16));
}

/** One of Iris's messages for a burn (GET /v2/messages/{domain}?transactionHash=). */
interface IrisMessage {
  status?: unknown;
  message?: unknown;
  attestation?: unknown;
}

/** Complete, with its message and Circle's attestation. */
function attested(m: IrisMessage): m is IrisMessage & { message: string; attestation: string } {
  return m?.status === "complete" && typeof m.message === "string" && typeof m.attestation === "string" && m.attestation !== "PENDING";
}

/** Indexer step: polls Iris for every transfer waiting on an attestation and finishes what can be finished: the keeper
 *  relays a transfer to Stellar whose burn checks out (relayInbound), and a transfer to Monad waits for its claim
 *  there. */
export async function advanceBridges(): Promise<number> {
  if (!env.network.apis.iris || !env.network.contracts.cctp || !env.network.bridge.monad) return 0;
  const open = await sql()`select * from lite.bridge_transfers where status = 'attesting' and source_tx is not null and updated_at > now() - interval '2 days' order by updated_at limit 20`;
  let advanced = 0;
  for (const t of open) {
    const { src } = domains(t.direction as string);
    // Iris indexes an EVM burn by its 0x hash and a Stellar burn by the hash Horizon/RPC report for the
    // transaction (for a fee-bump, the outer hash), without 0x.
    const raw = String(t.source_tx);
    const hash = t.direction === "monad_to_stellar" ? (raw.startsWith("0x") ? raw : `0x${raw}`) : raw.replace(/^0x/, "");
    const res = await fetch(`${env.network.apis.iris}/v2/messages/${src}?transactionHash=${hash}`, { signal: AbortSignal.timeout(8_000) });
    if (!res.ok) continue;
    const body = await res.json();
    const messages: IrisMessage[] = Array.isArray(body?.messages) ? body.messages : [];
    if (t.direction === "monad_to_stellar") {
      if (await relayInbound(t, messages)) advanced++;
      continue;
    }
    const m = messages[0];
    if (!m || !attested(m)) continue;
    await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, status = 'relaying', updated_at = now() where id = ${t.id}`;
    advanced++;
  }
  return advanced;
}

/** A transfer from Monad once Circle has attested every message of its burn's transaction: the keeper relays the one
 *  that is this transfer's (inboundMessageRefusal), unless it was relayed for another transfer already (the same burn
 *  reported twice), and the transfer completes. Otherwise the transfer fails, and nothing is relayed. True when the
 *  keeper relayed it. */
async function relayInbound(t: postgres.Row, messages: IrisMessage[]): Promise<boolean> {
  const ready = messages.filter(attested);
  if (ready.length === 0 || ready.length < messages.length) return false;
  const transfer = { address: String(t.address), amount: BigInt(String(t.amount)) };
  const refusals = ready.map((m) => inboundMessageRefusal(hexToBytes(m.message), transfer, inboundPins()));
  const m = ready.find((_, i) => refusals[i] === null);
  if (!m) {
    await sql()`update lite.bridge_transfers set message = ${ready[0].message}, error = ${`Not relayed: ${refusals[0]}.`}, status = 'failed', updated_at = now() where id = ${t.id}`;
    return false;
  }
  const done = await sql()`
    select 1 from lite.bridge_transfers where message = ${m.message} and direction = 'monad_to_stellar' and status = 'completed' and id <> ${t.id}`;
  if (done.length > 0) {
    await sql()`update lite.bridge_transfers set error = 'Not relayed: its burn was relayed for another transfer.', status = 'failed', updated_at = now() where id = ${t.id}`;
    return false;
  }
  try {
    const destTx = await relayMintAndForward(t.id as string, hexToBytes(m.message), hexToBytes(m.attestation));
    await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, dest_tx = ${destTx}, status = 'completed', updated_at = now() where id = ${t.id}`;
  } catch (err) {
    await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, error = ${String((err as Error).message).slice(0, 300)}, updated_at = now() where id = ${t.id}`;
    return false;
  }
  return true;
}

/** Calls CctpForwarder.mint_and_forward for transfer `id` from the keeper's account (permissionless; the keeper pays
 *  the fee, §4.7) and records the transaction in lite.keeper_log. Only for a message relayInbound checked. */
export async function relayMintAndForward(id: string, message: Uint8Array, attestation: Uint8Array): Promise<string> {
  const cctp = env.network.contracts.cctp!;
  const k = keeper();
  const acct = await loadAccount(k.publicKey());
  if (!acct) throw new Error("the keeper's account doesn't exist");
  const tx = await prepare(newTx(acct, 120).addOperation(new Contract(cctp.forwarder).call("mint_and_forward", sv.bytes(message), sv.bytes(attestation))).build());
  tx.sign(k);
  const hash = await sendSigned(tx);
  await logRelay(hash, k.publicKey(), tx.fee, id);
  return hash;
}

/** One row in lite.keeper_log for a relay, once migration 05 has created it. A row that can't be written is logged;
 *  the relay stands. */
async function logRelay(hash: string, keeperAddress: string, maxFee: string, transfer: string): Promise<void> {
  try {
    if (!(await tableExists("lite.keeper_log"))) return;
    await sql()`insert into lite.keeper_log (hash, job, keeper, max_fee, detail)
                values (${hash}, 'relay', ${keeperAddress}, ${maxFee}, ${sql().json({ transfer })}) on conflict (hash) do nothing`;
  } catch (err) {
    console.warn("keeper_log: relay not recorded", hash, String((err as Error).message ?? err).slice(0, 120));
  }
}

/** An allowance for a pinned spender (the CCTP TokenMessengerMinter), valid for about 3 hours. */
export const approveForBridge: Builder = async (user, spec) => {
  const cctp = env.network.contracts.cctp!;
  const spender = String(spec.spender);
  if (spender !== cctp.tokenMessengerMinter) throw bad("bad_spender", "Unexpected spender.");
  const token = String(spec.token);
  const amount = String(spec.amount);
  const acct = await requireAccount(user);
  const latest = (await rpcServer().getLatestLedger()).sequence;
  const tx = await invoke(acct, token, "approve", [sv.addr(user), sv.addr(spender), sv.i128(amount), sv.u32(latest + 2_000)]);
  const code = assetById(env.network, token)?.code ?? "token";
  return {
    tx,
    intent: {
      kind: "approve",
      summary: `Allow Circle's bridge to move ${fromStroops(amount)} ${code}`,
      spend: { [token]: amount },
      calls: [{ contract: token, fn: "approve" }],
      display: { amount, spender: "Circle CCTP" },
    },
  };
};
registerBuilder("token_approve", approveForBridge);

/** TokenMessengerMinter.deposit_for_burn(from, amount, destination_domain, mint_recipient, burn_token,
 *  destination_caller, max_fee, min_finality_threshold): the user's USDC to their Monad address, which the intent
 *  binds (`to`): both verifiers hold mint_recipient to it and the domain to Monad's (§5.2). */
export const burnToMonad: Builder = async (user, spec) => {
  const cctp = env.network.contracts.cctp!;
  const monad = env.network.bridge.monad!;
  const acct = await requireAccount(user);
  const amount = String(spec.amount);
  const recipient = String(spec.recipient);
  const tx = await invoke(acct, cctp.tokenMessengerMinter, "deposit_for_burn", [
    sv.addr(user),
    sv.i128(amount),
    sv.u32(monad.domain),
    sv.bytes(evmToBytes32(recipient)),
    sv.addr(String(spec.usdc)),
    sv.bytes(new Uint8Array(32)),
    sv.i128(0),
    sv.u32(STANDARD_FINALITY),
  ]);
  return {
    tx,
    intent: {
      kind: "bridge_out",
      summary: `Send ${fromStroops(amount)} USDC to Monad ${recipient.slice(0, 6)}…${recipient.slice(-4)}`,
      spend: { [String(spec.usdc)]: amount },
      calls: [{ contract: cctp.tokenMessengerMinter, fn: "deposit_for_burn" }],
      display: { amount, to: recipient },
      to: recipient,
    },
  };
};
registerBuilder("cctp_burn", burnToMonad);

// ------------------------------------------------------------------------------------------------ 1Click (mainnet)

const ONECLICK_ASSETS = {
  monadUSDC: "nep245:v2_1.omni.hot.tg:143_2dmLwYWkCQKyTjeUPAsGJuiVLbFx",
  stellarUSDC: "nep245:v2_1.omni.hot.tg:1100_111bzQBB65GxAPAVoxqmMcgYo5oS3txhqs1Uh1cgahKQUeTUq1TJu",
};

export async function oneClickQuote(direction: BridgeDirection, amount: bigint, dry: boolean, recipient: string, refundTo: string): Promise<BridgeQuote> {
  const api = env.network.apis.oneClick ?? "https://1click.chaindefuser.com";
  const toStellar = direction === "monad_to_stellar";
  const body = {
    dry,
    swapType: "EXACT_INPUT",
    slippageTolerance: 100,
    originAsset: toStellar ? ONECLICK_ASSETS.monadUSDC : ONECLICK_ASSETS.stellarUSDC,
    depositType: "ORIGIN_CHAIN",
    destinationAsset: toStellar ? ONECLICK_ASSETS.stellarUSDC : ONECLICK_ASSETS.monadUSDC,
    amount: amount.toString(),
    refundTo: refundTo || (toStellar ? "0x0000000000000000000000000000000000000000" : Keypair.random().publicKey()),
    refundType: "ORIGIN_CHAIN",
    recipient: recipient || (toStellar ? Keypair.random().publicKey() : "0x0000000000000000000000000000000000000000"),
    recipientType: "DESTINATION_CHAIN",
    deadline: new Date(Date.now() + 30 * 60_000).toISOString(),
    referral: "dyorhq",
    quoteWaitingTimeMs: 3_000,
  };
  const res = await fetch(`${api}/v0/quote`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) });
  const json = await res.json();
  if (!res.ok) throw new ApiError(502, "bridge_quote_failed", "The bridge didn't return a quote.", json);
  const q = json.quote ?? {};
  return { route: "oneclick", direction, amountIn: String(q.amountIn ?? amount), amountOut: String(q.amountOut ?? "0"), etaSeconds: q.timeEstimate ?? null, depositAddress: q.depositAddress ?? null, depositMemo: q.depositMemo ?? null };
}
