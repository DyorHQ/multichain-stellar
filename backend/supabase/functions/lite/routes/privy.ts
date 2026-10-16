// Stellar wallets for the accounts that sign in with Privy: Apple, Google, an email code or a Privy passkey (DyorHQ/
// internal ios-app/stellar-v2/privy-stellar-wallets.md §5.1). Privy holds their keys, so their Stellar key is a Privy
// wallet the user owns. Both routes are public: they run before the account has a Lite session, since the sign-in
// challenge itself is signed through the second one.
//
//   POST /v1/privy/wallet {privyToken}  the token's user's Stellar wallet: found, or made once at Privy and kept
//   POST /v1/privy/sign {walletId, hash, expiresAt, authorization}
//                                       relays a raw_sign the phone authorized with the user's own Privy key, then
//                                       checks Privy's signature against the wallet's address
//
// The phone computes every hash it asks for (a transaction it built and checked, or the sign-in challenge's SEP-53
// digest) and verifies the signature itself before using it. This API adds only the app secret: it can't change the
// hash, the wallet or the expiry the phone signed. Off unless LITE_PRIVY_WALLETS=on and PRIVY_APP_SECRET is set.
import { Keypair } from "@stellar/stellar-sdk";
import { hex } from "../../_shared/auth.ts";
import { sql } from "../../_shared/db.ts";
import { env } from "../../_shared/env.ts";
import { ApiError, bad, clientIp, json, notFound, rateLimit, readJson, Router } from "../../_shared/http.ts";
import {
  createStellarWallet,
  PrivyRefused,
  PrivyTokenInvalid,
  PrivyUnavailable,
  privyUserId,
  type PrivyWallet,
  rawSign,
  stellarWallets,
} from "../../_shared/privy.ts";

const HASH = /^0x[0-9a-f]{64}$/;
const WALLET_ID = /^[A-Za-z0-9_-]{1,64}$/;
/** A base64 DER ECDSA P-256 signature is about 96 characters; several (comma-separated) stay well under this. */
const AUTHORIZATION = /^[A-Za-z0-9+/=,]{16,512}$/;
/** The latest expiry a signed request may carry: the phone asks for two minutes. */
const MAX_EXPIRY_MS = 5 * 60_000;

const unavailable = () => new ApiError(503, "privy_unavailable", "Stellar isn't available for this sign-in right now. Try again later.");

function requireEnabled(): void {
  if (!env.privyWallets) throw unavailable();
}

/** Privy's failures as the API says them. */
function privyError(err: unknown, refused: () => ApiError): never {
  if (err instanceof PrivyTokenInvalid) throw new ApiError(401, "privy_token_invalid", "Sign in again.");
  if (err instanceof PrivyRefused) throw refused();
  if (err instanceof PrivyUnavailable) throw unavailable();
  throw err;
}

/** The user's wallet: the row kept for them, else the oldest Stellar wallet Privy lists for them, else a new one. Two
 *  first calls at once make one wallet (Privy's idempotency key) and keep one row. */
async function walletOf(userId: string): Promise<PrivyWallet> {
  const kept = await sql()`select wallet_id, address from lite.privy_wallets where user_id = ${userId}`;
  if (kept.length) return { id: kept[0].wallet_id as string, address: kept[0].address as string };
  const wallet = (await stellarWallets(userId))[0] ?? await createStellarWallet(userId);
  await sql()`insert into lite.privy_wallets (user_id, wallet_id, address)
    values (${userId}, ${wallet.id}, ${wallet.address}) on conflict (user_id) do nothing`;
  const row = await sql()`select wallet_id, address from lite.privy_wallets where user_id = ${userId}`;
  return { id: row[0].wallet_id as string, address: row[0].address as string };
}

export function register(router: Router): void {
  router.on("POST /v1/privy/wallet", async ({ req }) => {
    requireEnabled();
    rateLimit(`privy-wallet:${clientIp(req)}`, 10);
    const body = await readJson<{ privyToken?: unknown }>(req);
    if (typeof body.privyToken !== "string" || body.privyToken === "") throw bad("bad_arg", "privyToken is missing.");
    try {
      const userId = await privyUserId(body.privyToken);
      rateLimit(`privy-user:${userId}`, 5);
      const wallet = await walletOf(userId);
      return json({ walletId: wallet.id, address: wallet.address });
    } catch (err) {
      if (err instanceof ApiError) throw err;
      // The app secret can't make or list wallets: a setup problem on DyorHQ's side, not the user's.
      privyError(err, () => {
        console.error("privy wallet:", String((err as Error).message).slice(0, 120));
        return unavailable();
      });
    }
  });

  router.on("POST /v1/privy/sign", async ({ req }) => {
    requireEnabled();
    rateLimit(`privy-sign:${clientIp(req)}`, 60);
    const body = await readJson<{ walletId?: unknown; hash?: unknown; expiresAt?: unknown; authorization?: unknown }>(req);
    if (typeof body.walletId !== "string" || !WALLET_ID.test(body.walletId)) throw bad("bad_arg", "walletId is missing or malformed.");
    if (typeof body.hash !== "string" || !HASH.test(body.hash)) throw bad("bad_hash", "hash must be 0x and 64 lowercase hex digits.");
    const now = Date.now();
    if (typeof body.expiresAt !== "number" || !Number.isSafeInteger(body.expiresAt) || body.expiresAt <= now ||
      body.expiresAt > now + MAX_EXPIRY_MS) {
      throw bad("bad_arg", "expiresAt must be a time in milliseconds within the next 5 minutes.");
    }
    if (typeof body.authorization !== "string" || !AUTHORIZATION.test(body.authorization)) {
      throw bad("bad_arg", "authorization is missing or malformed.");
    }
    rateLimit(`privy-sign-wallet:${body.walletId}`, 30);
    const rows = await sql()`select address from lite.privy_wallets where wallet_id = ${body.walletId}`;
    if (!rows.length) throw notFound("Wallet");
    const address = rows[0].address as string;
    let signature: Uint8Array;
    try {
      signature = await rawSign(body.walletId, body.hash, body.expiresAt, body.authorization);
    } catch (err) {
      // Privy refused the authorization: not the wallet owner's key, another request than the one signed, or expired.
      privyError(err, () => new ApiError(403, "privy_refused", "Privy didn't sign this. Try again."));
    }
    const digest = Uint8Array.from(body.hash.slice(2).match(/../g)!.map((h) => parseInt(h, 16)));
    if (!Keypair.fromPublicKey(address).verify(digest as any, signature as any)) {
      console.error("privy sign: a signature that doesn't verify for", body.walletId);
      throw new ApiError(502, "privy_bad_signature", "Couldn't sign this. Try again.");
    }
    return json({ signature: `0x${hex(signature)}` });
  });
}
