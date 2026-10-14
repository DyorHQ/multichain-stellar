// The sign-in messages wallet-auth accepts, and the checks each must pass before the signature is even recovered.
//
// EIP-4361 (Sign-In with Ethereum), bound to DyorHQ's domain and to Monad (security audit 2026-09-26, IOSK-7), exactly:
//
//   dyorhq.fun wants you to sign in with your Ethereum account:
//   <the wallet, EIP-55 checksummed>
//
//   Sign in to DyorHQ.
//
//   URI: https://dyorhq.fun
//   Version: 1
//   Chain ID: 143
//   Nonce: <the server's 64-lowercase-hex nonce>
//   Issued At: <ISO-8601 UTC with milliseconds, e.g. 2026-09-26T12:34:56.789Z>
//   Expiration Time: <Issued At + 10 minutes, same format>
//
// Lines are separated by a single "\n" with no trailing newline. The address line must be the request's address with
// its EIP-55 checksum. Domain, URI, Version and Chain ID are fixed. Issued At must be within 10 minutes of server time;
// Expiration Time must be in the future, after Issued At, and at most 10 minutes after it.
//
// The legacy template ("DyorHQ Sign-In\n\nWallet: <address as sent>\nNonce: <nonce>\nIssued At: <unix ms>") is not
// bound to a domain or chain, so any page that gets a wallet to sign it can sign in as that wallet. It is still
// accepted for the builds that send it, until the owner sets WALLET_AUTH_LEGACY_SIGNIN=off (legacySignIn below) — once
// the first build that signs EIP-4361 has shipped and every older build is expired. No code change or redeploy is
// needed to retire it; then remove it from the code as well.
import { getAddress } from "npm:viem@2";

export const MAX_AGE_MS = 10 * 60 * 1000; // a signed message must be < 10 minutes old
export const SIWE_DOMAIN = "dyorhq.fun";
export const SIWE_URI = "https://dyorhq.fun";
export const SIWE_CHAIN_ID = 143;
export const SIWE_STATEMENT = "Sign in to DyorHQ.";

export type SignIn = { nonce: string; format: "eip4361" | "legacy" };
export type SignInRefusal = { error: string; status: 400 | 401 };

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const ISO_MS = "(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z)";
const SIWE = new RegExp(
  "^dyorhq\\.fun wants you to sign in with your Ethereum account:\\n(0x[0-9a-fA-F]{40})\\n\\n" +
  "Sign in to DyorHQ\\.\\n\\n" +
  "URI: https://dyorhq\\.fun\\nVersion: 1\\nChain ID: 143\\nNonce: ([0-9a-f]{64})\\n" +
  `Issued At: ${ISO_MS}\\nExpiration Time: ${ISO_MS}$`,
);

const unrecognised: SignInRefusal = { error: "sign-in message not recognised — update DyorHQ and try again", status: 400 };
const expired: SignInRefusal = { error: "message expired", status: 401 };

// The EIP-4361 message for these values — the exact text the app signs (used by the tests; documents the contract).
export function siweMessage(address: string, nonce: string, issuedAt: string, expirationTime: string): string {
  return `${SIWE_DOMAIN} wants you to sign in with your Ethereum account:\n${address}\n\n${SIWE_STATEMENT}\n\n` +
    `URI: ${SIWE_URI}\nVersion: 1\nChain ID: ${SIWE_CHAIN_ID}\nNonce: ${nonce}\nIssued At: ${issuedAt}\n` +
    `Expiration Time: ${expirationTime}`;
}

// Whether the legacy template is still accepted: yes unless WALLET_AUTH_LEGACY_SIGNIN is "off" (any case, trimmed).
export function legacySignIn(configured: string | undefined): boolean {
  return (configured ?? "").trim().toLowerCase() !== "off";
}

// Milliseconds for a strict ISO-8601 UTC timestamp with milliseconds (a real date: it must round-trip), else null.
function isoMillis(text: string): number | null {
  const ms = Date.parse(text);
  return Number.isFinite(ms) && new Date(ms).toISOString() === text ? ms : null;
}

// The nonce a sign-in message carries, once its template, address and times check out; or why it was refused.
// `address` is the request's address (0x + 40 hex; any case). `legacy: false` refuses the legacy template.
export function parseSignIn(message: string, address: string, nowMs: number, options: { legacy?: boolean } = {}): SignIn | SignInRefusal {
  if (!ADDRESS.test(address)) return unrecognised;

  const siwe = SIWE.exec(message);
  if (siwe) {
    let checksummed: string;
    try { checksummed = getAddress(address); } catch { return unrecognised; }
    if (siwe[1] !== checksummed) {
      return { error: "the sign-in message must name this wallet with its EIP-55 checksum", status: 400 };
    }
    const issued = isoMillis(siwe[3]);
    const expires = isoMillis(siwe[4]);
    if (issued === null || expires === null) return unrecognised;
    if (Math.abs(nowMs - issued) > MAX_AGE_MS) return expired;
    if (expires <= nowMs || expires <= issued || expires - issued > MAX_AGE_MS) return expired;
    return { nonce: siwe[2], format: "eip4361" };
  }

  if (options.legacy === false) return unrecognised;
  // `address` passed ADDRESS above (0x + 40 hex, no regex metacharacters), and JS `$` without the m flag matches only
  // at the very end, so nothing can be appended.
  const legacy = new RegExp(`^DyorHQ Sign-In\\n\\nWallet: ${address}\\nNonce: ([0-9a-f]{64})\\nIssued At: (\\d{13})$`).exec(message);
  if (legacy) {
    const issued = Number(legacy[2]);
    if (!Number.isFinite(issued) || Math.abs(nowMs - issued) > MAX_AGE_MS) return expired;
    return { nonce: legacy[1], format: "legacy" };
  }
  return unrecognised;
}
