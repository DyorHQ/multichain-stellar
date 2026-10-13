# Verification

What was proven, how, and what is still open. Last full run: **2026-10-13** on Stellar testnet (protocol 29).

## Automated suites

| Suite | Command | Result |
|---|---|---|
| Contracts | `cd contracts && ./build.sh && cargo test` (Rust 1.91+) | 31 passed (launch-token 6, launchpad 18, moments 7) |
| Backend unit | `deno test -A --config backend/supabase/functions/deno.json backend/tests/unit/` | 18 passed |
| Schema | migrations + `backend/tests/sql/lite_schema_test.sql` on Postgres 16 | 15 tables closed to anon/authenticated; budget and candles OK |
| Type check | `deno check` on both functions and every script | 0 errors |
| StellarKit | `cd ios/Packages/StellarKit && swift test` (Swift 6.3.3, Linux and macOS) | 11 passed, including the live journey below (Linux). On macOS 10 passed and the journey skipped without `LITE_API` |
| DyorLite | `xcodebuild -scheme DyorLite` build, then test on an iPhone 17 simulator (Xcode 26.6, iOS 26.5) | 0 errors, 0 warnings; 4 tests passed |
| LiteHarness | `xcodegen generate`, then `xcodebuild -scheme LiteHarness` for the iOS Simulator (Xcode 26.6) | 0 errors, 0 warnings |

## Testnet journey (`backend/tests/e2e/lite_e2e.ts`)

Each run uses a fresh key and plays the phone's role:

1. The API builds a transaction.
2. The phone verifies it with the same rules as `TxVerifier`, signs it and submits it.
3. The sponsor fee-bumps it.
4. The test waits for the ledger.

The first 2026-10-13 run passed all 9 phases against the build session's deployment (launchpad `CC4EJ5O6…`); its
transactions are in the table below. Later that day the contracts were redeployed with keys the owner holds
(ARCHITECTURE §4.4), the deploy script's smoke test passed on them, and the journey ran again against the redeployed
contracts through the local stack (`backend/scripts/local-stack.sh`, RUNBOOK §8): all 9 phases passed, 15 sponsored
transactions, all successful on-chain, for example the
[launch](https://stellar.expert/explorer/testnet/tx/38dbf5eab57efa558e1d70654f3dea0d980c7f8f5713db44c08fc161c513372c)
that graduated to Soroswap and the
[burn](https://stellar.expert/explorer/testnet/tx/40abd9152c5813dbf1cf61b49e9805e8d956792c011498523b1daaba1066a74e)
toward Monad (attested by Circle within 33 seconds).

| Phase | What happened | Example transaction |
|---|---|---|
| auth | The invite gate held: 403 without an invite, 401 when a nonce was replayed. Friendbot activated the account; a sponsored USDC trustline was added | [trust](https://stellar.expert/explorer/testnet/tx/f2a22ee3f8cf5ecfa7a97ff75d59e02682a6760f77ff7cae0aeed03248b9602e) |
| swap | Three venues were quoted (Aquarius, SDEX, Soroswap); the best route executed | [swap](https://stellar.expert/explorer/testnet/tx/0064b1bd8893444712aac5927f579db327e4bd342ae9b642031cb06ef926ab98) |
| earn | Deposited 100 XLM to Blend v2 and withdrew 40; position 60 | [deposit](https://stellar.expert/explorer/testnet/tx/b536c9f141fb45bf5a2e56a20ac8997fd16af6dfffc6fddff5e4e8a407490d28) · [withdraw](https://stellar.expert/explorer/testnet/tx/a986da47cb2d435ecf62fa94c24160d8a716a6ab614280d083d0cf381771d32e) |
| launch | Launched with an initial buy, sold, bought to the clamped threshold, graduated to Soroswap by the keeper, bought through the aggregator, claimed creator fees | [launch](https://stellar.expert/explorer/testnet/tx/1088670464c5afd018610b442ee925704ff5f370f81705962dde21226c2c5e37) · [buy](https://stellar.expert/explorer/testnet/tx/92ef1570d423b23c4769969f81b1b38751feb80d83bac696c0783415cef51622) · [claim](https://stellar.expert/explorer/testnet/tx/3b5cfd71142c6343a4c48e005bd5f02476502ed868494c30c743a0b0b5f7bc50) · pair `CCNP7HXB…FDB6UD` |
| moments | Published a Moment and collected 2; the account owns 2 | [publish](https://stellar.expert/explorer/testnet/tx/98c23497857d935d6b4fda6ddb7adc5a2aa4c7f85168260b23142dd6ce337c27) · [collect](https://stellar.expert/explorer/testnet/tx/43dc15eb94fabe4132f179a50a4b2d809788c9b2c5ed87834234fbfb574a75c8) |
| send | Created an account with 5 XLM and sent 1 more. USDC to an account without a trustline was refused before signing | [payment](https://stellar.expert/explorer/testnet/tx/b81bc5433c69dbd615c1095552ccc822f36783148e5fdca002b809aee602f019) |
| bridge | Approve + CCTP `deposit_for_burn` to Monad testnet | [burn](https://stellar.expert/explorer/testnet/tx/5d5b521293bb209091cb3d86c7a267d75a1070d04b6665a9b1c13a721154d6b3) |
| anchor | SEP-10 sign-in with testanchor.stellar.org (challenge validated), then a SEP-24 interactive deposit, tracked | — |
| prices | XLM reference price from the mainnet book | — |

Totals since 2026-10-11: 48 sponsored transactions from 10 test accounts; 47 succeeded. The one failure was a Blend
withdraw that hit the resource limit on-chain. It led to the simulation headroom fix (DECISIONS #11) and has passed in
every run since.

## Bridge, beyond the journey

- **Stellar → Monad.**
  - The burn above was attested by Circle Iris, and the indexer moved the transfer to "ready to claim".
  - The generated claim, `receiveMessage(message, attestation)`, was run with `eth_call` against Monad testnet's
    MessageTransmitterV2. It returned `true`, so the calldata is valid.
  - Not done: an actual send, which needs a funded Monad testnet key.
- **Monad → Stellar.**
  - The generated `depositForBurnWithHook` (amount, domain 27, CctpForwarder as recipient and caller, hook data with
    the G-address) was run with `eth_call` against Monad testnet's TokenMessengerV2, with balance and allowance
    overridden. It didn't revert.
  - Not done: a real burn followed by the `mint_and_forward` relay, which needs Monad testnet USDC.
- **Registration.** CCTP has Monad testnet (domain 15) and Stellar testnet (27) registered with each other on both
  chains.

## Swift ↔ server agreement

`backend/tests/vectors/gen-vectors.ts` writes 39 vectors: real transactions the API built on testnet, plus synthetic
attacks (over-spend, unpinned contract, other signer, long expiry, SetOptions, sponsor paying out, unexpected
trustline, path payment to someone else). For every vector, the Swift `TxVerifier` matches the TypeScript verifier
on all of these:

- the decoded fields;
- a byte-exact re-encode;
- the verdict;
- the outflow;
- the reason.

The live Swift journey (`LiteJourneyTests`) does six things:

1. Derives a SEP-5 key.
2. Is refused without an invite, then signs in with one.
3. Activates the account.
4. Has an over-limit swap refused by `PlanRunner` before anything is signed.
5. Runs the swap at the confirmed limit.
6. Completes SEP-10 and SEP-24 with testanchor.

## The network switch in the app (2026-10-13)

IOS-app branch `lite/network-switch` (build 24 on build 23, see INTEGRATION-ios.md) ran in the internal project on an
iPhone 17 simulator (iOS 26, Xcode 26.6), against the local stack on Stellar testnet:

- **First switch, new wallet:**
  - the account starts on Monad;
  - chip → Stellar → Next → Confirm → Switch to Stellar runs the Setup checklist: one Face ID prompt to unlock, the
    invite, sign-in, and account setup;
  - it lands on Stellar Home with 10,000 test XLM and USDC enabled.
- **Background drop:** sending the app to the background in the middle of Setup dropped the signer. The checklist then
  said "Unlock again to continue", and Join asked for Face ID again.
- **Switching back:** Stellar → Monad is instant, with no prompt. A cold launch on Stellar doesn't prompt either.
- **A swap on testnet:** 10 XLM → USDC through Aquarius, with one Face ID prompt. Activity said "Swap 10 XLM for
  USDC · Done", and the balances followed within one refresh.
- **Sign-out** removed the account's network, Stellar activation and keys, and the next account started on Monad.
- **Screens:**
  - English and Spanish, light and dark;
  - the screens checked were Earn, Launch, Moments, Deposit, Withdraw, Add cash, Profile's Network section and the
    Stellar account page.
- **App Store target unchanged:**
  - every changed app file, with its `STELLAR_LITE` branches removed, is byte-identical to `d387a64`;
  - every `Lite/` file compiles to nothing without the flag.

## Not yet verified

- **The app against the hosted API.** Everything above ran against the local stack (INTEGRATION-ios.md §7). The
  Supabase deployment is staged, not applied.
- **On a device**, and in TestFlight. The internal project has no Xcode Cloud workflow yet.
- **A passkey (Mera) or email account through the switch.** The run used imported phrase wallets.
- **The Supabase-hosted runtime.** Everything ran on Deno 2.9 with Postgres 16 locally. Storage uploads, `pg_cron` and
  `pg_net` run only in the real project.
- **Mainnet anything.** The values are described and typed but not enabled. The Aquarius mainnet router id must be
  checked before mainnet.
- **An independent audit of the contracts.** Required before real money (same rule as Moments on Monad).
