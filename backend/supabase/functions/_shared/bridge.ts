// Monad ↔ Stellar USDC.
// Testnet: Circle CCTP v2 (Monad testnet domain 15 ↔ Stellar testnet domain 27; both directions are registered on
// both chains, checked 2026-10-11). Monad → Stellar mints to Circle's CctpForwarder, which forwards to the user's
// G-address in the same call; the API relays `mint_and_forward` once Iris attests. Stellar → Monad burns on Stellar
// and returns a "claim on Monad" step (receiveMessage) for the Pro wallet to sign.
// Mainnet: NEAR Intents 1Click (live Monad ↔ Stellar USDC routes; no testnet).
import { keccak_256 } from "@noble/hashes/sha3";
import { StrKey } from "@stellar/stellar-sdk";
import { accountView, needsTrustline } from "./account.ts";
import { sql } from "./db.ts";
import { env } from "./env.ts";
import { ApiError, bad, notFound } from "./http.ts";
import { assetById } from "./networks.ts";
import { createPlan, PlanView, registerBuilder } from "./plans.ts";
import { Contract, fromStroops, invoke, Keypair, loadAccount, newTx, prepare, requireAccount, sendSigned, sponsor, sv } from "./stellar.ts";

// ------------------------------------------------------------------------------------------------ EVM encoding

const hexOf = (b: Uint8Array) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const selector = (sig: string) => hexOf(keccak_256(new TextEncoder().encode(sig)).subarray(0, 4));
const word = (hex: string) => hex.replace(/^0x/, "").padStart(64, "0");
const uint = (n: bigint | number) => word(BigInt(n).toString(16));

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

/** CctpForwarder hook data: 24 zero bytes · uint32 version 0 · uint32 length · strkey bytes. */
export function forwarderHookData(recipient: string): Uint8Array {
  const r = new TextEncoder().encode(recipient);
  const out = new Uint8Array(32 + r.length);
  new DataView(out.buffer).setUint32(24, 0);
  new DataView(out.buffer).setUint32(28, r.length);
  out.set(r, 32);
  return out;
}

export function encodeApprove(spender: string, amount: bigint): string {
  return "0x" + selector("approve(address,uint256)") + word(spender.slice(2)) + uint(amount);
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
  return "0x" + selector("depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)") + head + bytesTail(p.hookData);
}

export function encodeReceiveMessage(message: Uint8Array, attestation: Uint8Array): string {
  const mTail = bytesTail(message);
  const offsetA = 64 + mTail.length / 2;
  return "0x" + selector("receiveMessage(bytes,bytes)") + uint(64) + uint(offsetA) + mTail + bytesTail(attestation);
}

// ------------------------------------------------------------------------------------------------ API

export async function bridgeQuote(input: { direction: string; amount: string }) {
  const amount = BigInt(input.amount);
  if (env.network.name === "testnet") {
    return {
      route: "cctp",
      direction: input.direction,
      amountIn: amount.toString(),
      amountOut: input.direction === "monad_to_stellar" ? (amount * 10n).toString() : (amount / 10n).toString(), // 6 ↔ 7 decimals
      fee: "0",
      etaSeconds: input.direction === "monad_to_stellar" ? 60 : 120,
      note: "Testnet CCTP: Monad testnet USDC ↔ Circle test USDC on Stellar.",
    };
  }
  return await oneClickQuote(input.direction, amount, true, "", "");
}

export async function startBridge(user: string, input: { direction: string; amount: string; monadAddress: string }): Promise<{ transfer: Record<string, unknown>; plan?: PlanView; evmSteps?: unknown[] }> {
  if (env.network.name !== "testnet") throw new ApiError(501, "mainnet_route", "Mainnet bridging uses NEAR Intents; enable it with the mainnet launch.");
  const cctp = env.network.contracts.cctp!;
  const monad = env.network.bridge.monad!;
  if (!isEvmAddress(input.monadAddress)) throw bad("bad_address", "Your Monad address is required.");
  const usdc = assetById(env.network, "USDC")!;

  if (input.direction === "monad_to_stellar") {
    const amount6 = BigInt(input.amount); // Monad USDC has 6 decimals
    if (amount6 <= 0n) throw bad("bad_amount", "Amount must be positive.");
    const acct = await accountView(user);
    if (!acct.exists) throw new ApiError(409, "account_inactive", "Activate your Stellar account first.");
    const trust = needsTrustline(acct.balances, "USDC");
    if (trust) throw new ApiError(409, "needs_usdc", "Enable USDC on Stellar first, so the bridge can deliver it.");
    const forwarder = StrKey.decodeContract(cctp.forwarder);
    const rows = await sql()`
      insert into lite.bridge_transfers (address, direction, route, amount, recipient) values (${user}, 'monad_to_stellar', 'cctp', ${amount6.toString()}, ${user})
      returning id, status, created_at`;
    const evmSteps = [
      { kind: "evm", chainId: monad.chainId, label: "Allow USDC", to: monad.usdc, data: encodeApprove(monad.tokenMessenger, amount6), value: "0" },
      {
        kind: "evm",
        chainId: monad.chainId,
        label: "Send to Stellar",
        to: monad.tokenMessenger,
        value: "0",
        data: encodeDepositForBurnWithHook({
          amount: amount6,
          destinationDomain: cctp.domain,
          mintRecipient: forwarder,
          burnToken: monad.usdc,
          destinationCaller: forwarder,
          maxFee: 0n,
          minFinalityThreshold: 2000,
          hookData: forwarderHookData(user),
        }),
      },
    ];
    return { transfer: { id: rows[0].id, status: rows[0].status, direction: "monad_to_stellar" }, evmSteps };
  }

  if (input.direction === "stellar_to_monad") {
    const amount7 = BigInt(input.amount);
    if (amount7 <= 0n || amount7 % 10n !== 0n) throw bad("bad_amount", "Stellar → Monad moves whole micro-USDC (6 decimals).");
    const rows = await sql()`
      insert into lite.bridge_transfers (address, direction, route, amount, recipient) values (${user}, 'stellar_to_monad', 'cctp', ${amount7.toString()}, ${input.monadAddress})
      returning id, status`;
    const plan = await createPlan(user, "bridge_out", [{
      label: "Send USDC to Monad",
      spec: { kind: "cctp_burn", amount: amount7.toString(), recipient: input.monadAddress, usdc: usdc.contract },
    }]);
    return { transfer: { id: rows[0].id, status: rows[0].status, direction: "stellar_to_monad" }, plan };
  }
  throw bad("bad_direction", "direction is monad_to_stellar or stellar_to_monad.");
}

export async function setSourceTx(user: string, id: string, txHash: string) {
  if (!/^(0x[0-9a-fA-F]{64}|[0-9a-f]{64})$/.test(txHash)) throw bad("bad_hash", "That isn't a transaction hash.");
  const rows = await sql()`update lite.bridge_transfers set source_tx = ${txHash}, status = 'attesting', updated_at = now()
                            where id = ${id} and address = ${user} and status = 'awaiting_source' returning id, status`;
  if (rows.length === 0) throw notFound("Transfer");
  return rows[0];
}

export async function transferStatus(user: string, id: string) {
  if (!/^[0-9a-f-]{36}$/.test(id)) throw notFound("Transfer");
  const rows = await sql()`select * from lite.bridge_transfers where id = ${id} and address = ${user}`;
  if (rows.length === 0) throw notFound("Transfer");
  const t = rows[0];
  const out: Record<string, unknown> = {
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

export async function markClaimed(user: string, id: string, txHash: string) {
  const rows = await sql()`update lite.bridge_transfers set dest_tx = ${txHash}, status = 'completed', updated_at = now()
                            where id = ${id} and address = ${user} and status = 'relaying' returning id`;
  if (rows.length === 0) throw notFound("Transfer");
  return { id, status: "completed" };
}

function hexToBytes(h: string): Uint8Array {
  const s = h.replace(/^0x/, "");
  return Uint8Array.from(s.match(/../g) ?? [], (x) => parseInt(x, 16));
}

/** Indexer step: poll Iris for every transfer waiting on an attestation and finish what can be finished. */
export async function advanceBridges(): Promise<number> {
  if (!env.network.apis.iris || !env.network.contracts.cctp) return 0;
  const open = await sql()`select * from lite.bridge_transfers where status = 'attesting' and source_tx is not null and updated_at > now() - interval '2 days' limit 20`;
  let advanced = 0;
  for (const t of open) {
    const srcDomain = t.direction === "monad_to_stellar" ? env.network.bridge.monad!.domain : env.network.contracts.cctp.domain;
    const hash = String(t.source_tx).startsWith("0x") || t.direction === "monad_to_stellar" ? String(t.source_tx) : `0x${t.source_tx}`;
    const res = await fetch(`${env.network.apis.iris}/v2/messages/${srcDomain}?transactionHash=${hash}`, { signal: AbortSignal.timeout(8_000) });
    if (!res.ok) continue;
    const body = await res.json();
    const m = body?.messages?.[0];
    if (!m || m.status !== "complete" || !m.attestation || m.attestation === "PENDING") continue;
    if (t.direction === "monad_to_stellar") {
      try {
        const destTx = await relayMintAndForward(hexToBytes(m.message), hexToBytes(m.attestation));
        await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, dest_tx = ${destTx}, status = 'completed', updated_at = now() where id = ${t.id}`;
      } catch (err) {
        await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, error = ${String((err as Error).message).slice(0, 300)}, updated_at = now() where id = ${t.id}`;
        continue;
      }
    } else {
      await sql()`update lite.bridge_transfers set message = ${m.message}, attestation = ${m.attestation}, status = 'relaying', updated_at = now() where id = ${t.id}`;
    }
    advanced++;
  }
  return advanced;
}

/** Calls CctpForwarder.mint_and_forward from the sponsor account (permissionless; the sponsor pays the fee). */
export async function relayMintAndForward(message: Uint8Array, attestation: Uint8Array): Promise<string> {
  const cctp = env.network.contracts.cctp!;
  const sp = sponsor();
  const acct = (await loadAccount(sp.publicKey()))!;
  const tx = await prepare(newTx(acct, 120).addOperation(new Contract(cctp.forwarder).call("mint_and_forward", sv.bytes(message), sv.bytes(attestation))).build());
  tx.sign(sp);
  return await sendSigned(tx);
}

registerBuilder("cctp_burn", async (user, spec) => {
  const cctp = env.network.contracts.cctp!;
  const monad = env.network.bridge.monad!;
  const acct = await requireAccount(user);
  const amount = String(spec.amount);
  const tx = await invoke(acct, cctp.tokenMessengerMinter, "deposit_for_burn", [
    sv.addr(user),
    sv.i128(amount),
    sv.u32(monad.domain),
    sv.bytes(evmToBytes32(String(spec.recipient))),
    sv.addr(String(spec.usdc)),
    sv.bytes(new Uint8Array(32)),
    sv.i128(0),
    sv.u32(2000),
  ]);
  return {
    tx,
    intent: {
      kind: "bridge_out",
      summary: `Send ${fromStroops(amount)} USDC to Monad ${String(spec.recipient).slice(0, 6)}…${String(spec.recipient).slice(-4)}`,
      spend: { [String(spec.usdc)]: amount },
      calls: [{ contract: cctp.tokenMessengerMinter, fn: "deposit_for_burn" }],
      display: { amount, to: String(spec.recipient) },
    },
  };
});

// ------------------------------------------------------------------------------------------------ 1Click (mainnet)

const ONECLICK_ASSETS = {
  monadUSDC: "nep245:v2_1.omni.hot.tg:143_2dmLwYWkCQKyTjeUPAsGJuiVLbFx",
  stellarUSDC: "nep245:v2_1.omni.hot.tg:1100_111bzQBB65GxAPAVoxqmMcgYo5oS3txhqs1Uh1cgahKQUeTUq1TJu",
};

export async function oneClickQuote(direction: string, amount: bigint, dry: boolean, recipient: string, refundTo: string) {
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
