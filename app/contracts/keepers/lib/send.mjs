// Transactions go out ONLY through Foundry's `cast send`, with a keystore, a named Foundry account, or a Ledger.
// This module never sees key material: it refuses raw private keys (flags and environment variables alike) and
// by default (dry run) only prints the exact `cast` command it would run. The RPC URL reaches cast through its
// ETH_RPC_URL environment variable, never argv: a keyed URL would otherwise show in `ps` and in every printed command.
//
// A send is only a success when its receipt says so (build 17, K1): `cast send` exits 0 for a transaction that was
// mined but REVERTED (and Monad bills its whole gas limit), so every send runs with `--json` and its receipt's
// `status` is checked. A send that hangs is killed; one whose outcome cannot be read is reported as unknown, never as
// done.
import { spawnSync } from "node:child_process";

const FORBIDDEN_ENV = ["PRIVATE_KEY", "KEEPER_PRIVATE_KEY", "ETH_PRIVATE_KEY", "DEPLOYER_PRIVATE_KEY"];
/** How long cast waits for a receipt (`cast send --timeout`, seconds), and when the keeper kills cast itself. */
export const CAST_RECEIPT_TIMEOUT_S = 120;
export const CAST_KILL_AFTER_MS = 180_000;
/** What cast needs besides the receipt wait (decrypting the keystore, fees, nonce, the broadcast): the kill timer is the
    receipt wait plus this. A send with less than this plus MIN_RECEIPT_WAIT_S left before the run's deadline is not
    started: a Monad receipt takes about a second, but cast killed after its broadcast is an unknown outcome. */
export const CAST_SEND_OVERHEAD_S = 60;
export const MIN_RECEIPT_WAIT_S = 15;
/** `cast wallet address` only decrypts a keystore (or asks a Ledger): it never needs long. */
export const CAST_ADDRESS_KILL_AFTER_MS = 60_000;

/** A transaction that was mined and REVERTED. It paid for its gas (on Monad: the whole gas limit). */
export class MinedRevert extends Error {
  constructor({ txHash, gasLimit, gasUsed, effectiveGasPrice, spentWei }) {
    super(`mined but REVERTED (tx ${txHash})`);
    this.name = "MinedRevert";
    Object.assign(this, { txHash, gasLimit, gasUsed, effectiveGasPrice, spentWei });
  }
}

/** cast was killed, printed no readable receipt, or failed in a way that may have followed the broadcast: the
    transaction may or may not have been broadcast and mined. */
export class SendStatusUnknown extends Error {
  constructor(message, { gasLimit } = {}) {
    super(message);
    this.name = "SendStatusUnknown";
    this.statusUnknown = true;
    this.gasLimit = gasLimit;
  }
}

/** A send the run refused to start (cast never ran, nothing was broadcast): the run is past its deadline, its RPC is
    stale, or its state cannot be saved. Not a failed send: no backoff, no spend. */
export class SendNotStarted extends Error {
  constructor(message) {
    super(message);
    this.name = "SendNotStarted";
    this.notStarted = true;
  }
}

const HASH = /^0x[0-9a-fA-F]{64}$/;
/** cast errors that come before anything is broadcast: its own arguments and keystore, or the node refusing the
    transaction at submission (it is then not in any pool). With --gas-limit given cast estimates nothing, so "execution
    reverted" only comes from a send that had to estimate. */
export const NOT_BROADCAST = /insufficient funds|nonce too (low|high)|replacement transaction underpriced|transaction underpriced|intrinsic gas too low|exceeds block gas limit|max fee per gas less than block base fee|fee cap less than block base fee|invalid sender|execution reverted|Mac Mismatch|Failed to decrypt|keystore|password|No such file or directory|unexpected argument|invalid value '[^']*' for/i;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;

function quantity(v, field) {
  if (typeof v === "number" && Number.isSafeInteger(v) && v >= 0) return BigInt(v);
  if (typeof v === "string" && /^(0x[0-9a-fA-F]+|[0-9]+)$/.test(v)) return BigInt(v);
  throw new Error(`receipt field ${field} is missing or not a number`);
}

/**
 * The receipt `cast send --json` prints (one JSON object; the last line that parses as one wins, so a stray log line
 * before it does not matter). Anything that is not a complete receipt throws: an unreadable outcome is never a
 * success.
 */
export function parseCastReceipt(stdout) {
  const lines = String(stdout ?? "").split("\n").map((l) => l.trim()).filter((l) => l.startsWith("{"));
  let r;
  for (const line of lines.reverse()) {
    try {
      r = JSON.parse(line);
      break;
    } catch {
      // try the line before
    }
  }
  if (!r || typeof r !== "object" || Array.isArray(r)) throw new Error("cast printed no JSON receipt");
  const status = r.status === "0x1" || r.status === 1 || r.status === "1" ? 1 : r.status === "0x0" || r.status === 0 || r.status === "0" ? 0 : undefined;
  if (status === undefined) throw new Error(`receipt status ${JSON.stringify(r.status)} is neither 0x0 nor 0x1`);
  if (typeof r.transactionHash !== "string" || !HASH.test(r.transactionHash)) throw new Error("receipt has no transaction hash");
  return { status, transactionHash: r.transactionHash, gasUsed: quantity(r.gasUsed, "gasUsed"), effectiveGasPrice: quantity(r.effectiveGasPrice, "effectiveGasPrice") };
}

/** What a mined transaction cost. Monad bills the gas LIMIT, not the gas used, so the limit is what is counted when it
    is known (on a chain that bills the use this over-counts, which only makes the daily cap stricter). */
export function spentWei({ gasLimit, gasUsed, effectiveGasPrice }) {
  const gas = gasLimit !== undefined && gasLimit !== null && BigInt(gasLimit) > gasUsed ? BigInt(gasLimit) : gasUsed;
  return gas * effectiveGasPrice;
}

/**
 * Signer config from CLI options (never from a key):
 *   { keystore: "/path/to/keystore.json", passwordFile?: "/path" }   -> --keystore [--password-file]
 *   { account: "keeper" }                                          -> --account (a ~/.foundry/keystores entry)
 *   { ledger: true, hdPath?: "m/44'/60'/0'/0/0" }                  -> --ledger [--mnemonic-derivation-path]
 *   { unlocked: "0x..." }  (local anvil ONLY; requires allowUnlocked) -> --unlocked --from
 */
export function signerArgs(signer = {}, { allowUnlocked = false } = {}) {
  for (const k of Object.keys(signer)) {
    if (/private/i.test(k) || /mnemonic$/i.test(k)) throw new Error(`refusing signer option "${k}": raw keys are never accepted`);
  }
  if (signer.keystore) return ["--keystore", signer.keystore, ...(signer.passwordFile ? ["--password-file", signer.passwordFile] : [])];
  if (signer.account) return ["--account", signer.account, ...(signer.passwordFile ? ["--password-file", signer.passwordFile] : [])];
  if (signer.ledger) return ["--ledger", ...(signer.hdPath ? ["--mnemonic-derivation-path", signer.hdPath] : [])];
  if (signer.unlocked) {
    if (!allowUnlocked) throw new Error("--unlocked is for a local anvil only; pass --allow-unlocked to confirm");
    return ["--unlocked", "--from", signer.unlocked];
  }
  throw new Error("sending needs a signer: --keystore <file> | --account <name> | --ledger");
}

export function assertNoKeyEnv(env = process.env) {
  const hit = FORBIDDEN_ENV.filter((k) => env[k]);
  if (hit.length) throw new Error(`refusing to run with ${hit.join(", ")} set: unset it; the keepers sign only via keystore/Ledger`);
}

/** The exact `cast send` argv for one call. `args` are already-stringified Solidity arguments. The RPC URL is not in
    it: `castEnv` hands it to cast as ETH_RPC_URL. */
export function castSendArgv({ to, signature, args = [], gasLimit, signer, allowUnlocked, receipt = false, receiptTimeoutS = CAST_RECEIPT_TIMEOUT_S }) {
  const argv = ["send", to, signature, ...args.map(String)];
  if (gasLimit) argv.push("--gas-limit", String(gasLimit));
  // --json: print the receipt, whose status is the only proof of success. --timeout: stop waiting for it.
  if (receipt) argv.push("--json", "--timeout", String(receiptTimeoutS));
  argv.push(...signerArgs(signer, { allowUnlocked }));
  return argv;
}

/**
 * The address a signer sends from, derived with `cast wallet address` from the same keystore / account / Ledger
 * options the sends use (build 17, K1: simulations and the balance check must run as the real sender). The keystore
 * password reaches cast only as a file path.
 */
export function signerAddress(signer = {}, { allowUnlocked = false, castBin = process.env.CAST_BIN || "cast", spawn = spawnSync } = {}) {
  const args = signerArgs(signer, { allowUnlocked });
  if (signer.unlocked) {
    if (!ADDRESS.test(signer.unlocked)) throw new Error("--unlocked needs an address");
    return signer.unlocked;
  }
  const r = spawn(castBin, ["wallet", "address", ...args], { stdio: ["inherit", "pipe", "pipe"], encoding: "utf8", timeout: CAST_ADDRESS_KILL_AFTER_MS, killSignal: "SIGKILL" });
  if (r.error || r.signal) throw new Error(`could not derive the signer address: cast wallet address ${r.error?.code === "ETIMEDOUT" || r.signal ? "timed out" : `could not start (${r.error?.code ?? r.error?.message})`}`);
  const out = String(r.stdout ?? "").trim().split("\n").pop()?.trim() ?? "";
  if (r.status !== 0 || !ADDRESS.test(out)) {
    const why = String(r.stderr ?? "").trim().split("\n")[0] || `exit ${r.status}`;
    throw new Error(`could not derive the signer address: cast wallet address failed (${why})`);
  }
  return out;
}

/** The environment cast runs with: the caller's, plus the RPC URL as ETH_RPC_URL. */
export function castEnv(rpcUrl, env = process.env) {
  return { ...env, ETH_RPC_URL: rpcUrl };
}

function quote(a) {
  return /^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`;
}

/**
 * A sender bound to one run. In dry-run mode (the default) it records and prints the commands; with
 * `send: true` it executes them with cast (inheriting stdin, so a keystore password prompt or Ledger
 * confirmation works interactively).
 *
 * In send mode `call` resolves only when cast exited 0; it then returns the parsed receipt and what the transaction
 * cost (`spentWei`), or `receipt: null` with `receiptError` when cast's output could not be read (the caller must treat
 * that as an unknown outcome: see jobs.mjs `safeSend`). It throws `MinedRevert` for a mined, reverted transaction,
 * `SendStatusUnknown` when cast had to be killed or failed in a way that may have followed the broadcast, and a plain
 * Error only when cast failed before it could broadcast (NOT_BROADCAST).
 */
export function makeSender({ send = false, rpcUrl, signer, allowUnlocked = false, castBin = process.env.CAST_BIN || "cast", log = console.log, spawn = spawnSync, killAfterMs = CAST_KILL_AFTER_MS }) {
  if (send) {
    assertNoKeyEnv();
    signerArgs(signer, { allowUnlocked }); // validate once, up front
  }
  const sent = [];
  return {
    sent,
    live: send,
    async call({ to, signature, args = [], gasLimit, label, timeLeftMs }) {
      // A run's send never outlasts its deadline (--max-runtime): cast's receipt wait and kill timer shrink to the time
      // left, and with too little left the send is not started (the next run sends it). Fly stops a Machine 300 s
      // after a deploy starts; a cast killed after its broadcast would be an unknown outcome.
      let killMs = killAfterMs;
      let receiptS = CAST_RECEIPT_TIMEOUT_S;
      if (send && timeLeftMs !== undefined) {
        killMs = Math.min(killAfterMs, Math.floor(timeLeftMs));
        receiptS = Math.min(CAST_RECEIPT_TIMEOUT_S, Math.floor(killMs / 1000) - CAST_SEND_OVERHEAD_S);
        if (receiptS < MIN_RECEIPT_WAIT_S) {
          throw new SendNotStarted(`only ${Math.max(0, Math.floor(timeLeftMs / 1000))}s left before --max-runtime, too little for a send and its receipt; the next run sends it`);
        }
      }
      const argv = send
        ? castSendArgv({ to, signature, args, gasLimit, signer, allowUnlocked, receipt: true, receiptTimeoutS: receiptS })
        : ["send", to, signature, ...args.map(String), ...(gasLimit ? ["--gas-limit", String(gasLimit)] : []), "<signer>"];
      const printable = `ETH_RPC_URL=<rpc> ${[castBin, ...argv].map(quote).join(" ")}`;
      if (!send) {
        log(`[dry-run] ${label ?? signature}: ${printable}`);
        sent.push({ dryRun: true, argv });
        return { dryRun: true };
      }
      log(`[send] ${label ?? signature}: ${printable}`);
      const r = spawn(castBin, argv, { stdio: ["inherit", "pipe", "pipe"], encoding: "utf8", env: castEnv(rpcUrl), timeout: killMs, killSignal: "SIGKILL" });
      const entry = { dryRun: false, argv, ok: false, stdout: r.stdout, stderr: r.stderr };
      sent.push(entry);
      if (r.error?.code === "ETIMEDOUT" || r.signal) {
        throw new SendStatusUnknown(`cast was killed after ${Math.round(killMs / 1000)}s (${r.signal ?? "timeout"}): the transaction may still be mined`, { gasLimit });
      }
      if (r.error) throw new Error(`cast could not be started (${r.error.code ?? r.error.message})`);
      if (r.status !== 0) {
        const out = `${r.stderr ?? ""}\n${r.stdout ?? ""}`;
        const first = (r.stderr || "").trim().split("\n")[0];
        // cast gives up waiting for a receipt (its --timeout) or loses the RPC after broadcasting with a non-zero exit
        // too: when its output names a transaction hash or a timeout, the transaction may be pending or mined.
        if (/0x[0-9a-fA-F]{64}\b|time[d ]?out|not confirmed|dropped/i.test(out)) {
          throw new SendStatusUnknown(`cast send exited ${r.status} after it may have broadcast: ${first}`, { gasLimit });
        }
        // Only an error that cannot follow a broadcast is a plain failure. Anything else (cast 1.7.1 prints just "error
        // sending request for url (…)" when the RPC goes away while it waits for the receipt) may have sent it.
        if (NOT_BROADCAST.test(r.stderr ?? "")) throw new Error(`cast send failed (${r.status}): ${(r.stderr || "").trim()}`);
        throw new SendStatusUnknown(`cast send exited ${r.status} with an error that does not show it stopped before broadcasting (${first || "no output"}): the transaction may have been sent`, { gasLimit });
      }
      let receipt;
      try {
        receipt = parseCastReceipt(r.stdout);
      } catch (e) {
        return { dryRun: false, stdout: r.stdout, receipt: null, receiptError: e.message };
      }
      const spent = spentWei({ gasLimit, gasUsed: receipt.gasUsed, effectiveGasPrice: receipt.effectiveGasPrice });
      entry.txHash = receipt.transactionHash;
      if (receipt.status !== 1) {
        throw new MinedRevert({ txHash: receipt.transactionHash, gasLimit, gasUsed: receipt.gasUsed, effectiveGasPrice: receipt.effectiveGasPrice, spentWei: spent });
      }
      entry.ok = true;
      return { dryRun: false, stdout: r.stdout, receipt, spentWei: spent };
    },
  };
}
