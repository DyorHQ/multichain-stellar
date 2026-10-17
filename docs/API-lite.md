# The Lite API

The Lite API is DyorHQ's Stellar backend: the `lite` Edge Function (`backend/supabase/functions/lite`). The phone
talks to it through StellarKit's `LiteAPI`. This page is the contract both sides build to. It covers every request,
response and error code, including the parity API of `docs/DESIGN-stellar-parity.md` §6.

The same contract exists in three other forms, kept in step with this page:

| Form | Where | Checked by |
|---|---|---|
| TypeScript types | `backend/supabase/functions/_shared/contract.ts` (`Routes` maps every route to its auth, body and answer) | `deno check` of `contract.ts` |
| Swift models | `ios/Packages/StellarKit/Sources/LiteClient/Models.swift` and `Models+*.swift` | `swift test` in StellarKit |
| Fixtures, one per response | `backend/tests/fixtures/api/*.json` (§17) | `deno test` of `backend/tests/fixtures/`, `sync.sh --check` and `swift test` (§17) |

**Status.** Routes and fields marked *added* are part of the contract now; the package named in §1 makes the server
answer them. Until it lands, the server sends today's payload, and the phone decodes that too: every added field is
optional in Swift.

---

## 0. Conventions

- **Base.** `https://<project>.supabase.co/functions/v1/lite/v1/…` hosted; `http://127.0.0.1:8000/lite/v1/…` on the
  local stack. Paths below start at `/v1`. Requests and answers are JSON (`content-type: application/json`), and a
  request body is at most 64 KB.
- **Amounts** in base units are decimal-integer **strings**: "12500000" is 1.25 of a 7-decimal asset. XLM amounts in
  stroops (1 XLM = 10,000,000) are the same thing. Stellar assets have 7 decimals and Monad's USDC 6.
- **USD** values are JSON numbers. Unknown is `null`, never `0`.
- **Prices in a quote asset** are decimal strings in human units: "0.0000021".
- **Changes and rates** are **fractions**: 0.0123 is +1.23%. The phone turns them into percent in one place (DyorLite's
  `…Percent` accessors).
- **Times** are ISO 8601 in UTC with milliseconds: "2026-10-14T09:41:00.000Z". A calendar day is "2026-10-14".
- **Periods** use the app's `VolumePeriod` raw values: `day | week | month | all` (`VolumePeriodKey` in Swift).
- **Assets** are named by id: a registry id (`XLM`, `USDC`, `BUSDC`), a token's contract id (C…), or for a trustline
  outside the registry `CODE:G…`. `spend` and `receive` maps in intents are keyed by contract id.
- **Auth: three route classes** (the `auth` of each route in `contract.ts`). Viewing never needs a session; DyorHQ's
  own history and every write do.
  - **public**: no token, and nothing about any account: `auth/*`, `config`, `fees`, `markets*`, `prices`,
    `economics`, `earn/markets`, `earn/history` and the local media stand-in's reads. They read only the database,
    the in-isolate caches and cached contract views, and answer with `Cache-Control: public, max-age=30`. They
    ignore an `Authorization` header, never refuse it. The phone sends them no token, except `prices`, `economics`,
    `earn/markets` and `earn/history` while it holds one: until WP-13, WP-14 and WP-15 serve those without a session,
    today's server still asks for it there.
  - **viewer**: a session is optional: `GET /v1/account`, `/v1/holdings`, `/v1/earn/positions`, `/v1/moments/owned`,
    `/v1/launches`, `/v1/launches/:token`, `/v1/moments`, `/v1/moments/:id` and `/v1/assets`. With a valid
    `authorization: Bearer <token>` (§2): the **owner view** of the token's account, `"view": "owner"`. With no
    `Authorization` header: the **public view** for `?address=G…`, `"view": "public"`: on-chain facts only, every
    field from DyorHQ's own history `null` (§2, "Public views"), `Cache-Control: public, max-age=15`. A route about an
    account (`account`, `holdings`, `earn/positions`, `moments/owned`) answers 400 `address_required` with neither
    (the phone doesn't ask it then: `LiteAPIError.notSignedIn`); the boards, a launch and a Moment answer without
    `?address=`, with no `you`. A token that is present but invalid or expired gets 401, never the public view, so the
    phone renews instead of silently getting less. The public view never checks the tester list and answers every
    valid G… alike.
  - **session**: the token is required: DyorHQ's history (`portfolio`, `activity`, `launchpad/me`, `moments/mine`,
    `tx/:hash`) and every write, quote or plan (`account/activate|trust|faucet`, `recipient`, `send`, `plans/*`,
    `tx/submit`, `swap/*`, `earn/build`, the `launches/*` writes and quotes, the `moments/*` writes, `media/*`,
    `bridge/*`). Without it: 401 `unauthorized`.

  Answers other than the public ones and the public views are `no-store`. The local media stand-in (§12, local stack
  only) takes no session token either: its upload carries a signed token of its own, and its reads are the Debug
  build's media base.
- **Limits.** Per isolate, best effort: 300 requests a minute per IP across the public routes, and within that 20 on
  `auth/challenge`, `auth/verify` and `auth/signout` and 30 on `auth/refresh`; 120 a minute per IP for public views;
  120 a minute per account, 20 submits and 10 upload tickets a minute per account. Over the limit: 429
  `rate_limited`. Anything that costs DyorHQ money is limited in Postgres, never only in memory.
- **New fields.** A field added to an existing answer is optional for the phone (`decodeIfPresent`), so an older
  server's answer still decodes. A server never removes a field without a new contract.

**Errors.** A refusal has an HTTP status and a body:

```jsonc
{ "error": { "code": "not_enough_xlm_for_fee", "message": "Not enough XLM for the network fee.",
             "detail": { "need": "510000", "spendable": "400000" } } }   // detail: facts, or null
```

`message` is plain English. The phone words known codes itself, in the user's language (§16), and shows `message`
verbatim otherwise. `detail` holds every value a code's copy shows (§16). When a contract refused, `code` is
`simulation_failed` and `detail.contractCode` names the reason; `LiteAPI` then reports
`LiteAPIError.server(status:code:message:detail:)` with the contract's code (`launch.slippage`, …) as its `code`. Every
refusal's `detail` reaches the app in that `detail`, as text. A contract's code is always `<area>.<reason>` and the
API's codes never hold a dot, so the two can't be confused.

---

## 1. Routes at a glance

*Auth* is the route's class (§0): **public** routes take no token, **viewer** routes answer the public view without
one, **session** routes need one. *Owner* is the package that serves the parity form.

| Route | Auth | Request | Answer (`contract.ts`) | Fixture | Owner |
|---|---|---|---|---|---|
| `POST /v1/auth/challenge` | public | `{address}` | `AuthChallenge` | `auth-challenge` | — |
| `POST /v1/auth/verify` | public | `{address, nonce, signature, inviteCode?}` | `AuthResult` | `auth-verify`, `auth-verify.legacy` | WP-02b |
| `POST /v1/auth/refresh` *added* | public | `{address, refreshToken}` | `AuthResult` | `auth-refresh`, `error-refresh-reused` | WP-02b |
| `POST /v1/auth/signout` *added* | public | `{refreshToken}` | 204, no body | — | WP-02b |
| `GET /v1/config` | public | | `LiteConfig` | `config`, `config.legacy` | WP-02 |
| `GET /v1/fees` *added* | public | | `Fees` | `fees` | WP-10 |
| `GET /v1/account[?address=]` | viewer | | `AccountView` | `account`, `account.legacy`, `account.missing`, `account.public` | WP-10 |
| `POST /v1/account/activate` | session | `{}` | `ActivationResult` | `plan`, `account-activate` | WP-10 |
| `POST /v1/account/trust` | session | `{asset}` | `PlanView` | `plan` | WP-10 |
| `POST /v1/account/faucet` | session | `{}` | `{hash}` | `account-faucet` | WP-10 |
| `GET /v1/recipient/:address?asset=` *added* | session | | `Recipient` | `recipient` | WP-10 |
| `POST /v1/send` | session | `SendRequest` | `PlanView` | `plan-send` | WP-10 |
| `POST /v1/plans/:plan/steps/:step/build` | session | `{}` | `PlanView` | `plan`, `plan.legacy` | WP-10 |
| `POST /v1/tx/submit` | session | `{planId, stepId, signedXdr}` | `Submitted` | `tx-submit` | WP-10 |
| `GET /v1/tx/:hash` | session | | `TxStatus` | `tx-status`, `tx-status.legacy` | WP-10 |
| `POST /v1/swap/quote` | session | `{sell, buy, amount, slippageBps?}` | `SwapQuote` | `swap-quote`, `swap-quote.legacy` | WP-10 |
| `POST /v1/swap/build` | session | `{quoteId, venue?}` | `PlanView` | `plan` | WP-10 |
| `GET /v1/markets` *added* | public | | `Markets` | `markets` | WP-13 |
| `GET /v1/markets/:id` *added* | public | | `MarketDetail` | `market` | WP-13 |
| `GET /v1/markets/:id/history?range=` *added* | public | | `PriceHistory` | `market-history` | WP-13 |
| `GET /v1/prices` | public | | `Prices` | `prices` | WP-13 |
| `GET /v1/assets?q=[&address=]` *added* | viewer | | `AssetSearch` | `assets` | WP-18 |
| `GET /v1/holdings[?address=]` *added* | viewer | | `Holdings` | `holdings`, `holdings.partial`, `holdings.public` | WP-18 |
| `GET /v1/portfolio?period=` *added* | session | | `Portfolio` | `portfolio` | WP-18 |
| `GET /v1/activity?section=&kind=&period=&market=&limit=` | session | | `Activity` | `activity`, `activity.legacy` | WP-18 |
| `GET /v1/launches?section=&sort=&q=&limit=&cursor=[&address=]` | viewer | | `LaunchBoard` | `launches`, `launches.legacy` | WP-14 |
| `GET /v1/launches/:token?candles=[&address=]` | viewer | | `LaunchDetail` | `launch`, `launch.legacy`, `launch.public` | WP-14 |
| `POST /v1/launches/:token/quote` | session | `{side, amount}` | `TradeQuote` | `launch-quote`, `launch-quote.legacy`, `launch-quote-sell.legacy` | WP-14 |
| `POST /v1/launches/metadata` *added* | session | `LaunchMetadataRequest` | `{uri}` | `launch-metadata` | WP-14 |
| `POST /v1/launches/build` | session | `LaunchBuildRequest` | `PlanView` | `plan` | WP-14 |
| `GET /v1/economics` *added* | public | | `Economics` | `economics` | WP-14 |
| `GET /v1/launchpad/me` *added* | session | | `MyLaunchpad` | `launchpad-me` | WP-14 |
| `GET /v1/moments?filter=&limit=[&address=]` | viewer | | `MomentFeed` | `moments`, `moments.legacy` | WP-16 |
| `GET /v1/moments/owned[?address=]` | viewer | | `OwnedEditions` | `moments-owned`, `moments-owned.legacy`, `moments-owned.public` | WP-16 |
| `GET /v1/moments/mine` *added* | session | | `MyMoments` | `moments-mine` | WP-16 |
| `GET /v1/moments/:id[?address=]` | viewer | | `MomentDetail` | `moment`, `moment.legacy`, `moment.public` | WP-16 |
| `POST /v1/moments/metadata` | session | `MomentMetadataRequest` | `MomentMetadata` | `moment-metadata`, `moment-metadata.legacy` | WP-16 |
| `POST /v1/moments/build` | session | `MomentBuildRequest` | `PlanView` | `plan` | WP-16 |
| `POST /v1/media/upload-url` | session | `{contentType, bytes}` | `UploadTicket` | `media-upload-url` | WP-16 |
| `PUT /v1/local-media/upload/:token` *added*, local stack | signed token | the file's bytes | 204, no body | — (not JSON) | WP-16 |
| `GET /v1/local-media/lite-media/<path>` *added*, local stack | public | | the file's bytes (`MediaBytes`) | — (not JSON) | WP-16 |
| `GET /v1/earn/markets` | public | | `EarnMarkets` | `earn-markets`, `earn-markets.legacy` | WP-15 |
| `GET /v1/earn/positions[?address=]` | viewer | | `EarnPositions` | `earn-positions`, `earn-positions.legacy`, `earn-positions.public` | WP-15 |
| `GET /v1/earn/history?pool=&asset=&range=` *added* | public | | `EarnHistory` | `earn-history` | WP-15 |
| `POST /v1/earn/build` | session | `{action, pool, asset, amount}` | `PlanView` | `plan` | WP-15 |
| `POST /v1/bridge/quote` | session | `{direction, amount}` | `BridgeQuote` | `bridge-quote`, `bridge-quote.legacy` | WP-17 |
| `POST /v1/bridge/start` | session | `{direction, amount, monadAddress}` | `BridgeStart` | `bridge-start-in`, `bridge-start-out` | WP-17 |
| `POST /v1/bridge/:id/source` | session | `{txHash}` | `{id, status}` | `bridge-source` | WP-17 |
| `POST /v1/bridge/:id/claimed` | session | `{txHash}` | `{id, status}` | `bridge-claimed` | WP-17 |
| `GET /v1/bridge/:id` | session | | `BridgeStatus` | `bridge-status` | WP-17 |

Error bodies: `error`, `error-contract`, `error.legacy`, `error-refresh-reused`, `error-address-required`.
`/v1/moments/owned` and `/v1/moments/mine` are registered before `/v1/moments/:id`, so they never reach it.

---

## 2. Auth (public)

**`POST /v1/auth/challenge`** `{address: "G…"}` → `{nonce, message, expiresAt}`. The nonce is single use, lives 5
minutes and is 16 to 64 of `A–Z a–z 0–9 _ -`. `message` is the exact text the phone signs: at most 512 bytes, five
lines joined by `\n`, nothing before, after or between them:

```
DyorHQ Lite sign-in
Network: testnet
Address: G…
Nonce: …
Issued: 2026-10-14T09:41:00.000Z
```

A seed account signs it without a prompt, so the phone signs only this shape (DESIGN-stellar-parity §5.8): the network
it has pinned, its own address, the answer's own `nonce` and an ISO 8601 time, which isn't compared with the phone's
clock. Anything else (another network, address or nonce, a line more or less, `\r\n`) is refused before any key is
read: `LiteAPIError.decoding("the sign-in challenge")`. The phone then checks its own signature as SEP-53 over that
message with the account's key, and sends nothing signed any other way. These five lines are part of the contract: a
server that changes them breaks sign-in on every phone.

**`POST /v1/auth/verify`** `{address, nonce, signature, inviteCode?}` → `AuthResult` `{token, expiresAt, tester:
{address, label}, refreshToken, refreshExpiresAt}` (the last two *added*). `signature` is the base64 ed25519 signature
of the SEP-53 digest of `message`: sha256 of `"Stellar Signed Message:\n" + message`. `token` is the access token, a
JWT valid for **1 hour** (it was 12 hours before refresh tokens). A first sign-in needs `inviteCode` where
`config.inviteRequired` is true (mainnet); testnet needs none. An existing tester's `inviteCode` is ignored, not
consumed, so the phone may send one whenever it has one. Refusals: 401 `unauthorized` (nonce used or expired, signature
wrong), 403 `not_invited`, `bad_invite`, `access_revoked`.

**Refresh tokens** *added*. `refreshToken` is `lrt_` and 32 random bytes in base64url; the server keeps only its
SHA-256. Each sign-in starts a **family**. A refresh token:

- lives 30 days from issue, and each refresh issues a successor with 30 days of its own (a sliding lifetime);
- is **single use**: a refresh rotates it;
- presented a second time revokes its whole family, since a copy is in use somewhere else: 401 `refresh_reused`;
- is kept on the phone with the access token, in a Keychain item for this device only (never synced or backed up).

**`POST /v1/auth/refresh`** *added* `{address, refreshToken}` → `AuthResult`, as verify answers: a new access token and
the refresh token's successor, in the same family. Refusals: 401 `refresh_invalid` (unknown, expired or revoked), 401
`refresh_reused` (already used: the family is revoked), 403 `access_revoked` (the tester was turned off: the family is
revoked too).

**`POST /v1/auth/signout`** *added* `{refreshToken}` → 204, no body. Revokes the token's family. An unknown token gets
204 too, so the answer says nothing about which tokens exist. The phone calls it, best effort within 3 seconds, when the
user signs out of Stellar or of the app, or erases this iPhone.

**What the phone does.** It renews the session before the access token ends (10 minutes before `expiresAt` while the
app is active). On a 401 to a request that carried the token, `LiteAPI` runs one renewal, shared by every request
refused meanwhile, and tries each of them once more. A renewal is `auth/refresh` with the stored refresh token, then,
for a seed account, the silent sign-in above. The phone never presents a refresh token twice (that would revoke its
own family): refreshes of one token at the same time share one request, and a token it already rotated is replaced by
its successor. When neither works, a viewer request is answered with the public view and a session request reports
that the user needs to sign in. None of this asks for Face ID, the passcode or a passkey.

**Public views** (viewer routes without a token, §0): the owner view's shape with `"view": "public"`. On-chain facts
stay; DyorHQ's own history is `null`:

| Route | `null` in the public view | Notes |
|---|---|---|
| `GET /v1/account?address=` | `firstFunding.starterSwap`, `firstFunding.faucet.claimed` | `needsXlm` and `suggestXlm` stay: they follow from the ledger. Launch balances are the indexed ones. |
| `GET /v1/holdings?address=` | `earn[].deposited`, `withdrawn` and `earned` (with `earnedComplete: false`); `launch[].costBasisUsd` and `pnlUsd` | Balances, Earn `supplied`, editions, prices, totals and `change24h` stay. Launch balances are the indexed ones, with no live `balance()` read (`stale: false`). Cached 15 s per address. |
| `GET /v1/earn/positions?address=` | `deposited`, `withdrawn` and `earned` (with `earnedComplete: false`) | |
| `GET /v1/moments/owned?address=` | — | The address's editions. |
| `GET /v1/launches/:token[?address=]` | `you.costBasisQuote`, `you.pnlQuote` | `you` is `{balance, costBasisQuote, pnlQuote, isCreator}` for `?address=` (the indexed balance), `null` without it. |
| `GET /v1/moments/:id[?address=]` | `you.spent` | `you` is `{editions, spent}` for `?address=`, `null` without it. |
| `GET /v1/launches`, `GET /v1/moments` | — | The same boards. |
| `GET /v1/assets?q=[&address=]` | — | `held` is about `?address=`, and false without it. |

Fixtures: `account.public`, `holdings.public`, `earn-positions.public`, `moments-owned.public`, `launch.public`,
`moment.public`.

---

## 3. `GET /v1/config` (public)

The network, its assets and contracts. The phone's pins win wherever they overlap (contract ids, the fee caps, the
media base, the RPC and explorer links).

| Field | Type | Notes |
|---|---|---|
| `network` | `testnet \| mainnet` | |
| `passphrase`, `rpcUrl`, `horizonUrl` | string | The phone never uses `rpcUrl` for checks (its RPC is pinned). |
| `activation` | `friendbot \| sponsored` | Testnet activates with Friendbot; mainnet with DyorHQ's sponsored account setup. |
| `sponsor` | G… | Checked against the pinned sponsor. |
| `assets[]` | `AssetInfo` | `{id, code, name, decimals, contract, classic, note?}`, plus *added* `priceRef` (`XLM`/`USDC`; BUSDC is valued as USDC), `logo` (a bundled logo key or null) and `listed` (false for BUSDC). |
| `contracts` | object | `launchpad`, `moments` (null when not deployed), `soroswapRouter`, `soroswapFactory`, `aquariusRouter`, `blendPools[] {id, name}`, `cctp {tokenMessengerMinter, messageTransmitter, forwarder, domain}` or null. |
| `allowlist` | `{role: [C…]}` | The roles the phone pins. |
| `bridge` | `{routes, monad: {chainId, usdc} \| null}` | |
| `flags` | `{enabled, maintenance?}` | From `lite.app_config`. |
| `minBuild` | number | Older builds are asked to update. |
| `deployment` *added* | `{id, launchpad, moments}` | `id` is the deployment's name (`testnet`, `testnet-qa`). |
| `explorer` *added* | string | StellarExpert's base. Informational: the phone builds links from its pinned network. |
| `fees` *added* | `{payer, maxFee, maxInclusionPerOp, starterInnerFeeMax, starterSwap, fundingFloor}` | Stroops. `payer` is `user`; `starterSwap` is true only where DyorHQ sponsors one starter swap (mainnet). Informational: the phone enforces its pinned `feePolicy`. |
| `faucet` *added* | `{amount}` or null | Friendbot's grant on testnet, in XLM ("10000"): one claim per address, ever. Null off testnet. |
| `limits` *added* | `{momentMaxEditions, momentWindowSecs: [min, max], collectMax, launchName: [min, max], launchSymbol: [min, max], uriMax, uploadBytes}` | What the server accepts. `launchName` is UTF-8 bytes. |
| `pricing` *added* | `Pricing` | §8. |
| `inviteRequired` *added* | boolean | Whether a first sign-in needs an invite code (§2): false on testnet, true on mainnet. Older servers send none and always ask for one. |

---

## 4. `GET /v1/fees` (public, *added*)

```jsonc
{ "network": "testnet", "baseReserve": "5000000", "baseFee": "100",
  "inclusionFee": { "classic": "100", "soroban": "150" },        // the bid now, per operation
  "estimates": { "payment": "10000", "swap_soroswap": "500000", "launch_create": "10000000", … },
  "estimateBasis": { "swap_soroswap": "history", "launch_create": "default" }, "updatedAt": "…" }
```

- **Estimates** are, per step kind, the p90 over 7 days of the declared `maxFee`, × 5/4. Without history, the defaults
  apply (`basis: default`, shipped in Swift too). An estimate is never above the policy's `maxFee`.
- **Step kinds:** `payment`, `payment_token`, `trust`, `activate`, `restore`, `swap_sdex`, `swap_soroswap`,
  `swap_aquarius`, `blend_submit_deposit`, `blend_submit_withdraw`, `launch_create`, `launch_buy`, `launch_sell`,
  `launch_graduate`, `launch_claim`, `moment_publish`, `moment_collect`, `token_approve`, `cctp_burn`.

---

## 5. Account

**`GET /v1/account`** → `AccountView`:

| Field | Notes |
|---|---|
| `address`, `exists`, `network`, `activation`, `sponsor` | |
| `balances[]` | `BalanceRow`: `{asset, code, name, contract, classic, decimals, balance, enabled, note?}`. Every registry asset, every other Horizon trustline (no pool shares) and held launch tokens. *Added:* `kind` (`native \| classic \| sac \| launch`), `verified`, `logo`. Real codes only: a launch token carries its own symbol. |
| `reserves` | `{subentries, sponsoredByDyorHQ}`, or null without an account. |
| `xlm` *added* | `{balance, minBalance, sellingLiabilities, spendable, baseReserve, reserves: {base, subentries, sponsoring, sponsored}}`, stroops; null without an account. |
| `firstFunding` *added* | `{needsXlm, suggestXlm, starterSwap, faucet}`: the add-funds card. |

```
minBalance = max(0, 2 + subentries + sponsoring − sponsored) × baseReserve     (baseReserve from the ledger header)
spendable  = max(0, balance − minBalance − sellingLiabilities)
```

The phone recomputes `spendable` from these parts. `firstFunding`: `needsXlm` when spendable < `fees.fundingFloor`
(0.1 XLM); `suggestXlm` is 2 XLM for a missing account, otherwise 1 XLM plus any reserve the account lacks;
`starterSwap` is `available | used | unavailable`; `faucet` is `{amount, claimed}` on testnet, null elsewhere:
`claimed` once the address has had Friendbot's test XLM, by its activation or the faucet (a faucet row in
`lite.tx_log`). The public view (§2) leaves `starterSwap` and `claimed` null.

**`POST /v1/account/activate`** `{}` → a `PlanView` to run, or `{status: "active", account}` when there is nothing to
do.

| Account | Answer |
|---|---|
| Missing, `friendbot` (testnet) | Friendbot funds it (10,000 test XLM): the address's one claim, logged as its faucet row with Friendbot's transaction. Then a **user-paid** `trust` plan for USDC. 502 `friendbot_failed` when Friendbot doesn't answer; 504 `friendbot_slow` when the account, or the transaction that funded it, doesn't show in time. |
| Missing, `sponsored` (mainnet; local rehearsal with `LITE_ACTIVATION=sponsored`) | An `activate` plan: DyorHQ creates the account with 0 XLM and sponsors the USDC trustline (`feePayer: sponsor`, `sponsorReason: setup`). |
| Exists, USDC not enabled | A user-paid `trust` plan. Too little XLM: 409 `not_enough_xlm_for_reserve`. |
| Exists, USDC enabled | `{status: "active", account}`. |

**`POST /v1/account/trust`** `{asset}` → a user-paid `trust` plan (`reserveDelta: 1`).

**`POST /v1/account/faucet`** `{}` → `{hash}`. Testnet only (400 `testnet_only`): Friendbot's 10,000 test XLM for an
account that already existed (an imported wallet), merged in from a Friendbot-funded temporary account that pays the
fee (`feePayer: external`). Once per address, ever: 429 `faucet_used` "You already claimed your test XLM." once the
address has claimed, by this route or by Friendbot's activation. Two claims at once claim once; a merge the network
refused leaves the claim to make.

**`GET /v1/recipient/:address?asset=`** *added* → `{kind: "account" | "contract", exists, trusts}`. `trusts` is null
where it doesn't apply (XLM, a contract). An M… address: 400 `muxed_unsupported`.

**`POST /v1/send`** `{asset, to, amount, memo?, memoType?}` → `PlanView`. `memoType` is `text` (default, at most 28
bytes), `id` or `hash` (hex or base64). The intent carries `to` and `memo` (§6). Refusals: 409 `recipient_missing`
(a non-XLM send to a missing account), 409 `recipient_no_trust`; today's servers answer 409 `recipient_inactive` and
`recipient_cannot_receive` instead. A new account needs at least 1 XLM (400 `too_small`).

---

## 6. Plans, steps and transactions

An action is a **plan** of one or more steps. The server builds the first step at once and each later one when the
step before it has confirmed, so sequence numbers and simulations are fresh. The phone verifies every built step
against its intent and the amounts the user confirmed, signs it and submits it.

**`PlanView`** `{planId, kind, expiresAt, steps[], fees}`:

| `PlanStep` field | Notes |
|---|---|
| `id` | `s1`, `s2`, … |
| `label` | English; the phone titles steps itself. |
| `status` | `pending \| built \| submitted \| done \| failed` |
| `intent` | When built (below). |
| `xdr`, `hash` | When built: the unsigned envelope (base64) and its hash (hex). |
| `txHash`, `error`, `builtAt` | |
| `stepKind` *added* | §4's step kinds. |
| `maxFee` *added* | Stroops: a built step's `tx.fee`; an unbuilt step's ceiling for its kind. |
| `feePayer` *added* | `user` or `sponsor`. |
| `sponsorReason` *added* | `setup` or `starter_swap`, only when `feePayer` is `sponsor`; otherwise null. |
| `reserveDelta` *added* | New base reserves the step holds back (a trustline is 1). |

`fees` *added*: `{userMax, sponsored, newReserves}` across the plan. **The phone recomputes** `maxFee` and the payer from
the transaction itself and believes "DyorHQ pays" only where it can check it (WP-11); the server's values are for
display before a step is built.

**`Intent`** (the server's self-check and the phone's verifier read the same object):

| Field | Notes |
|---|---|
| `kind` | `payment`, `trust`, `activate`, `swap`, `earn_deposit`, `earn_withdraw`, `launch_create`, `launch_buy`, `launch_sell`, `launch_graduate`, `launch_claim`, `moment_publish`, `moment_collect`, `approve`, `bridge_out`, `restore`. |
| `summary` | A plain-language hint; never shown alone. |
| `spend` | The most the user's account may send, per asset contract, base units. |
| `receive` | The least the user receives, per asset contract. |
| `calls[]` | `{contract, fn}` the transaction may call. |
| `ops[]`, `trust[]` | Classic operation types and the `CODE:ISSUER` trustlines it may contain. |
| `display` | Facts the phone words the review from (amounts, tickers, venue, policy). Scalars only. |
| `to` *added* | The destination the user confirmed: G… or C…, or for `bridge_out` the Monad address as 0x-hex. |
| `memo` *added* | `{type: "text" \| "id" \| "hash", value}`, when the transaction carries one. |

**`POST /v1/plans/:plan/steps/:step/build`** `{}` → `PlanView`. 409 `not_ready` before the previous step is done,
`already_sent` after submit; 410 `plan_expired`.

**`POST /v1/tx/submit`** `{planId, stepId, signedXdr}` → `{hash, status: "pending"}`. The hash must match the built
step (409 `stale_step`) and carry the user's signature (400 `unsigned`); the server verifies it again. A built fee
above the policy's `maxFee`: 422 `fee_too_high`.

**`GET /v1/tx/:hash`** → `TxStatus` `{hash, status: "pending" | "success" | "failed", ledger?, error?, returnValue?}`,
plus *added* `feeCharged` (stroops), `feePayer` (`user | sponsor | external`) and `result: {amountOut}`. `returnValue`
is the contract's answer (a new token or Moment id); `amountOut` is what the step delivered: an SDEX path payment's
last amount, Soroswap's last `Vec<i128>` element, Aquarius's `u128`, a curve buy's `tokens_out` or a sell's
`quote_out`.

---

## 7. Swap

**`POST /v1/swap/quote`** `{sell, buy, amount, slippageBps?}` (`slippageBps` 1–1000, default 100) → `SwapQuote`:

| Field | Notes |
|---|---|
| `quoteId`, `sell`, `buy`, `amountIn`, `slippageBps`, `expiresAt` | |
| `best` | `{venue, amountOut, path, minOut}`, kept for older clients. |
| `alternatives[]` | `{venue, amountOut, path}`, kept for older clients. |
| `routes[]` *added* | Every venue that answered: `{venue, amountOut, minOut, priceImpactBps, path, best}`. `venue` is `sdex` or `soroswap`; `aquarius` is off for now (decision O7). `priceImpactBps` compares the rate with the same path's rate for a thousandth of the amount, and is null where unknown, or where the venue answers that size along another path. |
| `needsEnable` *added* | Asset ids to enable before receiving (the build adds a user-paid `trust` step). |
| `starterSwap` *added* | `{eligible, reason}`. `reason` when not eligible: `activation` (the network doesn't sponsor), `buy_not_xlm`, `sell_not_registry`, `has_xlm` (spendable ≥ 0.05 XLM), `too_small` (min out < 1 XLM), `used`. |

No route: 404 `no_route`. Same asset twice: 400 `same_asset`.

**`POST /v1/swap/build`** `{quoteId, venue?}` → `PlanView`. `venue` picks one of `routes`; the best when absent. An
expired quote: 410 `quote_expired`.

---

## 8. Markets and assets

**`Pricing`** (in config, markets, holdings and portfolio): `{kind: "reference" | "market", source, network, note}`.
On testnet, assets have no market: XLM and USDC are valued at mainnet reference prices (`kind: reference`, `source:
"Kraken"`, `network: mainnet`, `note` says so). On mainnet `kind` is `market` and `note` is null.

**`GET /v1/markets`** (public, *added*) → `{asOf, pricing, rows: [MarketRow]}`, Popular order: registry rows with
`listed: true` in registry order, then listed and priced launch tokens by 24h USD volume and then newest; at most 50.
Unlisted, smoke and look-alike launches are left out. The phone derives Hot (|change| descending) and Gainers/Losers,
dropping unpriced rows.

| `MarketRow` field | Notes |
|---|---|
| `id` | Registry id, or the launch token's contract. |
| `kind` | `registry \| launch` |
| `contract`, `classic`, `code`, `name`, `decimals` | `classic` is null for a launch. |
| `logo` | A bundled logo key (`XLM`, `USDC`) or null. |
| `image` | A launch's image on DyorHQ's media storage, or null. |
| `verified`, `badges` | Badges: `launch`, `unverified`, `lookAlike` (never listed), `testAsset`. |
| `note` | e.g. "Test XLM". |
| `priceUsd`, `change24h`, `volume24hUsd`, `marketCapUsd` | `marketCapUsd` = `priceUsd × circulating` for a launch, null for registry assets. |
| `isNew` | Created less than 24 hours ago; `change24h` is null then. |
| `priceSource` | `{kind: "reference", market: "Kraken XLM/USD", at}` or `{kind: "curve" \| "pool", quote: "XLM", quotePrice: "0.0000021", at}`. |
| `stale` | The price is older than 10 minutes. Older than 24 hours, it is null. |
| `launch` | `{phase: "curve" \| "completed" \| "graduated", progress, pair}`, or null. |

**`GET /v1/markets/:id`** (public, *added*) → `{row: MarketRow, about: {contract, classic, issuer, decimals,
homeDomain}}`. Balances come from `/v1/account`.

**`GET /v1/markets/:id/history?range=day|week|month|all`** (public, *added*) → `{id, range, intervalS, source,
complete, points: [{t, usd}]}`, oldest first. Registry assets: reference candles, `day` in 900 s buckets, `week` and
`month` 3600 s, `all` 86,400 s. Launch tokens: curve and pool candles × the quote's USD price, forward-filled from
creation, `source: "curve+pool"`.

**`GET /v1/assets?q=`** (viewer, so `held` can be set, *added*) → `{results: [{id, kind, code, name, contract, classic,
verified, held}]}`. `kind`: `registry | launch | classic | contract`. At most 30, matched on code and name, or exactly on
a C… id or `CODE:G…`. A pasted C… that isn't a launch is read live (`symbol()`, `name()`, `decimals()`) and answered as
`kind: contract, verified: false`.

**`GET /v1/prices`** (public) → `{usd: {id: number}, reference, at}`, kept for older clients. Values come from the
reference cache (BUSDC as USDC); an unknown price is left out, never 1.

---

## 9. `GET /v1/holdings` (*added*)

Home's balance card, My Holdings, the allocation ring and Portfolio's assets.

| Field | Notes |
|---|---|
| `address`, `exists`, `asOf`, `pricing` | |
| `xlm` | §5's `xlm`. |
| `spot[]` | `{id, kind: "registry" \| "classic", contract, classic, code, name, decimals, balance, enabled, verified, badges, note, logo, priceUsd, valueUsd, change24h}`. A classic row outside the registry is unverified, with an `unverified` badge; its name comes from the asset's home domain (or null), its logo is null. |
| `earn[]` | Blend positions: `{pool, poolName, asset, code, supplied, deposited, withdrawn, earned, earnedComplete, supplyApy, valueUsd}`. `earnedComplete` is false when deposits from before the server recorded them are missing. |
| `launch[]` | `{token, symbol, name, image, balance, priceUsd, valueUsd, change24h, phase, progress, costBasisUsd, pnlUsd, stale}`. Launch tokens are listed here only, and counted once. `stale`: the live balance couldn't be read, so this is the indexed one. |
| `moments` | `{count, editions: [Edition]}` (§12). |
| `totals` | `{spot, earn, launch, moments, total, complete}`, USD. A part that failed is null, `total` is null and `complete` false. Moments are worth 0 (editions have no market). |
| `change24h` | `{usd, pct, complete}`: `usd = Σ value × c / (1 + c)` over priced holdings. |
| `parts` | `{spot, earn, launch, moments}`, each `ok` or `failed`. |

---

## 10. `GET /v1/portfolio?period=day|week|month|all` (*added*)

```jsonc
{ "period": "week", "since": "…" /* null for all */, "asOf": "…", "pricing": { … },
  "totals": Stats, "sections": { "spot": Stats, "earn": Stats, "launch": Stats, "moments": Stats, "bridge": Stats },
  "activity": [ { "id", "section", "kind", "title", "subtitle", "at", "usd", "hash" } ],
  "coverage": { "from": "<first recorded action>", "note": "…" } }
// Stats = { volume, fees, pnl, claimedFees, trades, pnlComplete, networkFeesXlm, networkFeesUsd }
```

Everything is valued at **today's prices**, as Monad's Portfolio is. `networkFeesXlm` (stroops) is the network fees the
user paid in the section, never part of `fees`. `pnlComplete` is false when an outcome is missing.

| Section | Volume | Fees | P&L | Other |
|---|---|---|---|---|
| spot | DyorHQ swaps not touching a launch: amount in × p(sell), or out × p(buy) when sell is unpriced | 0 | Σ(out × p(buy) − in × p(sell)) | |
| launch | curve and pool trades by the user: quote amount × p(quote) | curve fees × p | received − spent + Σ Δtokens × p(token) | `claimedFees`: creator fees claimed |
| earn | deposits and withdrawals × p | 0 | (supplied now + withdrawn − deposited) × p | |
| moments | paid × p | paid × platform bps × p | 0 | `claimedFees`: the creator's proceeds |
| bridge | completed transfers × p(USDC) | Circle's fee | 0 | `trades` = count |

A launch buy made through DyorHQ counts once, from the trade, and its transaction adds only its network fee.

---

## 11. Launches

**`LaunchRow`** (board, detail, My Launchpad). Today's fields: `token, creator, quote (C…), name, symbol, uri, supply,
quoteReserve, tokenReserve, realQuote, threshold` (base units), `progress` (fraction), `completed, graduated, pair,
lastPrice` (quote price), `volume` (all-time curve volume, base units), `trades, createdAt`. *Added:*

| Field | Notes |
|---|---|
| `quoteCode` | `XLM`, `USDC` |
| `image`, `description`, `links {website, x, telegram}` | From the coin's metadata; the image only from DyorHQ's storage. |
| `burned`, `circulating` | `circulating = supply − burned`. |
| `phase` | `curve \| completed \| graduated` |
| `priceQuote`, `priceUsd` | `quoteReserve / tokenReserve` on the curve; the pool's price after graduation. |
| `change24h`, `isNew` | In USD. |
| `marketCapQuote`, `marketCapUsd` | `priceQuote × circulating`. |
| `volume24hQuote`, `volume24hUsd` | |
| `holders`, `holdersComplete` | From indexed transfers, mints and burns, excluding the launchpad and the pair. `holdersComplete` is false when part of the coin's events couldn't be read: show "n+". |
| `feeBps`, `protocolShareBps`, `creatorFeeBps` | The launch's terms. |
| `poolFeeBps` | The Soroswap pool's fee after graduation; null before. |
| `lookAlike` | The ticker imitates another (never listed). |
| `graduatedAt`, `lastTradeAt` | |

**`GET /v1/launches?section=explore|graduated&sort=newest|market_cap|near_graduation&q=&limit=50&cursor=`** →
`{launches: [LaunchRow], nextCursor, counts: {explore, graduated}}` (`nextCursor` and `counts` *added*). Explore holds
every coin that hasn't graduated, completed curves included. `sort=new|hot|graduated` without `section` stays for older
clients and answers `{launches}`.

**`GET /v1/launches/:token?candles=1m|5m|1h|1d`** → `{launch, curve, trades, candles}`:

- `curve`: `{quoteReserve, tokenReserve, realQuote, threshold, creatorFees, completed, graduated, pair}`, read live;
  null when the RPC didn't answer.
- `trades[]`: `{trader, side, quoteAmount, tokenAmount, price, txHash, ts}`, newest 50, plus *added* `venue: "curve" |
  "soroswap"` (curve and pool trades merged).
- `candles[]`: `{t, o, h, l, c, v}`, prices in the quote asset, at most 300.
- *Added:* `stats {volume24hQuote, volume24hUsd, holders, holdersComplete, marketCapQuote, marketCapUsd, priceQuote,
  priceUsd, change24h}`, `creatorFees {unclaimed, claimed, quote, unclaimedUsd, claimedUsd}`, `you {balance,
  costBasisQuote, pnlQuote, isCreator}` (cost basis and P&L null for coins received by transfer, and in the public
  view), `economics {feeBps, protocolShareBps, creatorFeeBps, supply, phantom, threshold}` and `pricePoints [{t,
  price}]` (at most 300).

**`POST /v1/launches/:token/quote`** `{side: "buy" | "sell", amount}` → buy `{side, used, tokensOut, fees, snipeFee}`,
sell `{side, quoteOut, fees}`; *added* `baseFee`, `creatorFee` and `refund` (the part of a buy a full curve returns).
`fees` is every fee together.

**`POST /v1/launches/metadata`** *added* `{name, symbol, description?, imageUrl?, website?, x?, telegram?}` →
`{uri}`. `imageUrl` must start with `<media base>uploads/<user>/`; `website` is https; `x` is `https://x.com/…` or
`https://twitter.com/…`; `telegram` is `https://t.me/…`; each link at most 200 characters, the description at most 500.

**`POST /v1/launches/build`** `{action: create | buy | sell | graduate | claim, token?, quote?, name?, symbol?, uri?,
creatorFeeBps?, amount?, minOut?}` → `PlanView`. Create: `uri` empty or one this user's metadata call returned, ticker
of 2 to 10 ASCII letters or digits as sent (else 422 `bad_symbol`, before any other check: Soroswap reads a token's
symbol as UTF-8), upper-cased; name at most 32 UTF-8 bytes, a reserved-looking ticker 400 `look_alike_symbol`, creator
fee 0–1000 bps. Buy and sell take `minOut` (the app's fixed 1%).

**`GET /v1/economics`** *added* → `{launchpad, moments}`, read live from the contracts (cached 5 minutes); each null
when not deployed. The admin is never exposed.

```jsonc
{ "launchpad": { "contract", "launchesEnabled", "supply", "feeBps", "protocolShareBps", "maxCreatorFeeBps",
                 "snipeSchedule": [9800, 2500, 300, 30],   // early-buy tax bps by ledger offset from the launch
                 "quotes": [ { "asset": "XLM", "contract", "phantom", "threshold", "enabled" } ] },
  "moments": { "contract", "platformBps", "royaltyBps", "publishingEnabled", "treasury", "maxPerCollect",
               "maxEditions", "quotes": [ { "asset": "XLM", "minPrice", "enabled" } ] } }
```

`treasury` is shown only in the publish review.

**`GET /v1/launchpad/me`** *added* → My Launchpad:

```jsonc
{ "held": [ { "token", "balance", "valueUsd", "costBasisQuote", "pnlQuote", "pnlUsd", "onCurve", "launch": LaunchRow } ],
  "created": [ { "launch": LaunchRow, "creatorFees": { "unclaimed", "claimed", "quote", "unclaimedUsd", "claimedUsd" } } ],
  "fees": { "byQuote": [ { "quote": "XLM", "received", "claimable", "receivedUsd", "claimableUsd" } ] },
  "activity": [ ActivityItem ] }        // the launch kinds
```

`unclaimed` is the curve's `creator_fees`, read live and cached 30 s.

---

## 12. Moments and media

Stellar Moments are SEP-50 editions: no coin and no graduation.

**`MomentRow`**. Today's fields: `id, creator, uri, title, mediaUrl, price` (base units), `quote` (C…), `maxEditions`
(0 is an open edition), `minted, deadline, open, createdAt`. *Added:* `description, place, takenOn` ("2026-10-14"),
`mediaType` (`image | video`), `posterUrl` (the photo, or the video's poster), `quoteCode, priceUsd, collects,
collectors, state` (`collecting | sold_out | closed`), `platformBps, royaltyBps, publishedAt`.

**`GET /v1/moments?filter=all|collecting|closed&limit=`** → `{moments: [MomentRow]}`: listed Moments only. `closed`
covers sold out and window closed.

**`GET /v1/moments/:id`** → `{moment, collectors: [{collector, quantity, firstTokenId, ts}]}`, plus *added*
`collectorsSummary {count, largest: {address, editions} | null}`, `you {editions: [token ids still owned], spent}`
(`spent` null in the public view) and `creatorEarned` (base units of the quote).

**`GET /v1/moments/owned`** → `{editions: [Edition]}`. **`Edition`**: `{tokenId, momentId, title, mediaUrl}`, plus
*added* `posterUrl, mediaType, contract`. Read from indexed ownership.

**`GET /v1/moments/mine`** *added* →

```jsonc
{ "created": [ MomentRow & { "proceeds": "…", "proceedsUsd": 0.54 } ],     // one object
  "collected": [ { "tokenId", "momentId", "contract", "moment": MomentRow } ],
  "totals": { "editions", "moments", "spentByQuote": { "XLM": "…" }, "earnedByQuote": { "XLM": "…" } } }
```

**`POST /v1/moments/metadata`** `{title, description?, mediaUrl, mediaType, posterUrl?, place?, takenOn?}` →
`{uri, posterUrl}` (`posterUrl` *added*, as are the request's last three fields). A video needs `posterUrl` (a frame
the phone uploaded); a photo is its own poster. The JSON written follows SEP-50: `name`, `description`, `image`,
`animation_url` (videos), `attributes` (Creator, Network, Place, Date).

**`POST /v1/moments/build`** `{action: "publish", uri, price, quote, maxEditions, windowSecs}` or `{action: "collect",
momentId, quantity}` → `PlanView`. Publish returns the policy it used (`platformBps`, `royaltyBps`, `minPrice`) in the
intent's `display`, and adds a user-paid `trust` step when the price is in USDC and the creator lacks the trustline.

**`POST /v1/media/upload-url`** `{contentType, bytes}` → `{uploadUrl, publicUrl, path}`: a one-time signed URL; PUT the
file there. `uploads/<user>/<uuid>.<ext>`, write-once. Images are jpeg, png, webp or gif; videos mp4 or quicktime; at
most `limits.uploadBytes` (25 MB). A daily budget of 50 uploads and 200 MB per user: 429 `upload_budget`.

**Local media stand-in** *added* (WP-16). The local stack has no Supabase Storage, so the API stores media itself. It
answers only on testnet with `LITE_LOCAL_STORAGE_DIR` set (it and `LITE_PUBLIC_BASE` are refused on mainnet);
anywhere else both routes answer 404 `not_found`. `POST /v1/media/upload-url` then hands out these URLs, built from `LITE_PUBLIC_BASE`:
`uploadUrl` on the first route, `publicUrl` on the second, which is the Debug build's pinned media base
(`http://127.0.0.1:8000/lite/v1/local-media/lite-media/` on the default ports). The metadata calls store their JSON the
same way.

- **`PUT /v1/local-media/upload/:token`**, no session token. The body is the file's bytes, `content-type` the ticket's
  type. `:token` is the object's path and expiry, signed with HMAC-SHA256 under `LITE_JWT_SECRET`, valid 10 minutes →
  204, no body. Write-once: a path takes one upload (409 `already_uploaded`). A token that is wrong or expired: 401
  `unauthorized`; a content type that isn't the path's: 400 `bad_type`; more bytes than the type allows: 400
  `too_large`.
- **`GET /v1/local-media/lite-media/<path>`**, public. `<path>` is `<folder>/<owner>/<file>`: `uploads/G…/<uuid>.<ext>`,
  or `launches/G…/<uuid>.json` and `moments/G…/<uuid>.json` for metadata → the stored bytes, with the content type they
  were stored with. Nothing stored there, or a path that would leave the storage directory: 404 `not_found`.

---

## 13. Earn (Blend)

**`GET /v1/earn/markets`** → `{markets: [EarnMarket], note}`. `EarnMarket`: `{pool, poolName, asset, code, decimals,
supplyApy, borrowApy, utilization` (fractions), `totalSupplied` (human units, a number), `note}`, plus *added*
`totalSuppliedUsd`, `freeLiquidityUsd` (supplied − borrowed), `priceUsd` and `poolStatus` (`active | on_ice | frozen`:
Blend status 0–1 active, 2–3 on ice, 4–5 and setup frozen). `note` is set on testnet.

**`GET /v1/earn/positions`** → `{positions: [EarnPosition]}`. Today: `{pool, asset, code, supplied, bTokens}`; the
parity rows are §9's `earn` rows (`bTokens` dropped).

**`GET /v1/earn/history?pool=&asset=&range=week|month`** *added* → `{points: [{t, supplyApy, utilization}]}`, from
snapshots every 10 minutes.

**`POST /v1/earn/build`** `{action: "deposit" | "withdraw", pool, asset, amount}` → `PlanView` (a `trust` step first
when the asset isn't enabled).

---

## 14. Activity

**`GET /v1/activity?section=&kind=&period=&market=&limit=`** → `{items: [ActivityItem]}`, newest first. Every filter is
*added* and optional; `market` is a market row id or an Earn market as `<pool>:<asset>`.

| Field | Notes |
|---|---|
| `type` | `tx \| bridge \| cash`. `cash`: only transfers from before cash was removed until mainnet, titled "Transaction". |
| `id`, `kind`, `status`, `at` | `kind`: an intent kind (§6), a bridge direction, or `deposit`/`withdraw`. |
| `summary` | The server's English words. |
| `amount` | Bridge: base units of the sending side's USDC; cash: the amount as its provider wrote it. |
| `display` | A transaction's intent display, or a cash transfer's `{asset}`. |
| `section` *added* | `spot \| earn \| launch \| moments \| bridge \| cash \| account` |
| `hash`, `feeCharged`, `feePayer`, `result {amountOut}` *added* | |
| `ref` *added* | `{token}`, `{momentId}` or `{market}`: what the row opens. |
| `symbol`, `name` *added* | The asset, resolved (never "TOKEN"). |
| `title`, `subtitle`, `usd` *added* | English; the phone words known kinds itself. |

---

## 15. Bridge

**`POST /v1/bridge/quote`** `{direction: "monad_to_stellar" | "stellar_to_monad", amount}` (the sending side's base
units) → `{route, direction, amountIn, amountOut, fee, etaSeconds, note}`, plus *added* `feeSource: "circle-iris"`
(the fee from Circle's Iris fee API, cached 10 minutes) and `etaBasis`. `etaSeconds` is the median of the last 20
completed transfers that way, or null with fewer than 3; `etaBasis` is how many the median is over. Mainnet's 1Click
quotes also carry `depositAddress` and `depositMemo`.

**`POST /v1/bridge/start`** `{direction, amount, monadAddress}` → `{transfer: {id, status, direction}, plan?, evmSteps?}`:

- Monad → Stellar: `evmSteps` for the Monad wallet (`{kind: "evm", chainId, label, to, data, value}`: approve, then
  `depositForBurnWithHook`). USDC must be enabled on Stellar (409 `needs_usdc`). At least 1 USDC, and at most 10
  relayed transfers a day (429 `bridge_relay_limit`).
- Stellar → Monad: a plan (approve, then `deposit_for_burn`), whose burn intent carries `to` = the Monad address.
- Mainnet: 501 `mainnet_route` until the mainnet program.

**`POST /v1/bridge/:id/source`** `{txHash}` → `{id, status: "attesting"}`. **`POST /v1/bridge/:id/claimed`** `{txHash}` →
`{id, status: "completed"}`.

**`GET /v1/bridge/:id`** → `{id, direction, route, amount, recipient, status, sourceTx, destTx, error, claim?}`. `claim`
is the Monad step that completes a Stellar → Monad transfer once it is attested.

Adding cash and cashing out are removed until mainnet (DESIGN-stellar-parity §1.1, decision 7): there are no cash
routes.

---

## 16. Errors

The codes the phone words, and the HTTP status each comes with. Copy is in the Stellar string tables (5 languages).

| Status, code | When | App copy |
|---|---|---|
| 409 `not_enough_xlm_for_fee` | the fee is above spendable XLM; also `tx_insufficient_balance` / `tx_insufficient_fee` at submit | Not enough XLM for the network fee. |
| 409 `not_enough_xlm_for_reserve` | a new trustline's 0.5 XLM doesn't fit; `op_low_reserve`, `CHANGE_TRUST_LOW_RESERVE` | Not enough XLM for Stellar's minimum balance. |
| 409 `not_enough_xlm` | amount + fee + reserve > spendable; `op_underfunded` (native) | Not enough XLM. %@ XLM stays in your account. |
| 422 `fee_too_high` | a built `tx.fee` above the policy's `maxFee` (`detail: {fee, max}`) | Not signed: the network fee is unusually high right now (%@ XLM). Nothing was sent. Try again in a minute. |
| 429 `sponsor_limit` | a daily, IP or attempt cap on DyorHQ's sponsorship | DyorHQ's free setup is busy today. Try again tomorrow. |
| 409 `already_set_up` | activation or the starter swap already used | Your account is already set up. |
| 400 `unsupported_asset` | not a registry id, a launch, a valid `CODE:ISSUER` or a C… token | DyorHQ doesn't support that token on Stellar. |
| 422 `bad_symbol` | create with a ticker that isn't 2 to 10 ASCII letters or digits | Use 2 to 10 letters or digits for the symbol. |
| 400 `look_alike_symbol` | create with a reserved-looking ticker | That ticker looks like another token's. Choose another. |
| 429 `faucet_used` | a second claim of Friendbot's test XLM | You already claimed your test XLM. |
| 400 `muxed_unsupported` | an M… recipient | Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given. |
| 409 `recipient_missing` | a non-XLM send to a missing account | This account doesn't exist yet, so it can't receive %@. |
| 409 `recipient_no_trust` | the recipient hasn't enabled the asset | This account hasn't enabled %@, so it can't receive it. |
| 422 `simulation_failed` + `detail.contractCode` | a contract refused: `launch.slippage`, `launch.closed`, `launch.disabled`, `launch.nothing_to_claim`, `moment.closed`, `moment.sold_out`, `moment.price_too_low`, `trust.missing` | The price moved past your 1% limit. Nothing was sent. Review again for a new price. / This curve isn't taking trades now. / New launches are paused. / Nothing to claim yet. / This Moment's collect window has closed. / This Moment is sold out. / The price is below the minimum (%@). / Enable %@ first. |
| 429 `upload_budget` | the daily upload budget | You've uploaded a lot today. Try again tomorrow. |
| 429 `bridge_relay_limit` | the daily relayed-bridge cap | You've bridged in many times today. Try again tomorrow. |
| 422 `tx_rejected` | any other send error (`detail.code` is Stellar's result code) | the server's message, verbatim |
| 401 `unauthorized` | a Bearer token that is invalid or expired | none: the phone renews and retries once (§2) |
| 401 `refresh_invalid` / `refresh_reused` | a refresh token that is unknown, expired or revoked / already used (its family is revoked) | none: a silent sign-in (seed accounts) or the public view (passkey accounts) |
| 400 `address_required` | a viewer route about an account, with neither a token nor `?address=` | none (a phone bug) |

Every %@ is in the error's `detail`, so a refusal can be worded from the error alone:

| Code | `detail` |
|---|---|
| `not_enough_xlm` | `minBalance`: what stays in the account (stroops); also `need`, `spendable` |
| `not_enough_xlm_for_fee`, `not_enough_xlm_for_reserve` | `need`, `spendable` (stroops) |
| `fee_too_high` | `fee`: the built fee (stroops); also `max` |
| `recipient_missing`, `recipient_no_trust`, `trust.missing` | `assetCode`; also `asset` (its id) |
| `moment.price_too_low` | `minPrice` (base units of the quote) and `quoteCode` |

The phone reads them from the error: `LiteAPIError.server(status:code:message:detail:)` carries `detail` as text
(strings as sent, numbers and booleans written out, nested values left out), so `LiteErrorText.describe(_:)` can fill
a copy's %@ from the error alone.

Other codes, shown as the server's message: 400 `bad_json`, `too_large`, `bad_arg`, `bad_amount`, `bad_address`,
`bad_asset`, `bad_memo`, `too_small`, `bad_xdr`, `unsigned`, `empty_plan`, `same_asset`, `bad_slippage`, `bad_pool`,
`bad_action`, `bad_request_type`, `bad_side`, `bad_quote`, `bad_name`, `bad_symbol`, `bad_fee`, `bad_uri`, `bad_title`,
`bad_media`, `bad_moment`, `bad_quantity`, `bad_editions`, `bad_window`, `bad_type`, `bad_direction`, `bad_hash`,
`bad_spender`, `testnet_only`, `no_friendbot`; 403 `not_invited`, `bad_invite`,
`access_revoked`; 404 `not_found`, `no_route`; 409 `account_inactive`, `needs_usdc`, `needs_restore`, `not_ready`,
`not_built`, `already_sent`, `stale_step`, `recipient_inactive`, `recipient_cannot_receive`, `already_uploaded`; 410
`plan_expired`, `quote_expired`; 429 `rate_limited`; 500 `self_check_failed`,
`internal`; 501 `mainnet_route`; 502 `friendbot_failed`, `rpc_unavailable`, `storage_error`, `bridge_quote_failed`;
503 `not_deployed`, `network_busy`, `storage_unavailable`; 504 `friendbot_slow`. Today's 429 `budget_exhausted` goes
with the daily sponsored-fee budget when users start paying their own fees.

---

## 17. Fixtures

`backend/tests/fixtures/api/<name>.json` holds one example of each answer: `<name>.json` in the parity form and
`<name>.legacy.json` for today's form where it differs (`auth-verify.legacy` is a sign-in answer without a refresh
token). `<name>.public.json` is a viewer route's public view (§2); `account.missing`, `holdings.partial` and the
`error*` bodies are further cases. They are written for testnet with synthetic addresses.

- **`backend/tests/fixtures/fixtures.test.ts`** type-checks each fixture exactly as its `contract.ts` type: it writes
  every fixture into one module as a literal and runs `deno run --check` on it, so a field `contract.ts` lacks, a
  missing required field or a value outside a literal union fails and names the fixture. (Importing the JSON instead
  would let unknown fields and wrong union values through.) It also fails when a fixture isn't listed:
  `deno test --allow-read --allow-run --config backend/supabase/functions/deno.json backend/tests/fixtures/`.
- **`backend/tests/fixtures/sync.sh`** copies them to `ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures/`
  (`--check` only compares). Both copies are committed.
- **`LiteClientTests`** decode every fixture with the model the client uses (`testDecodesApiFixtures`), and fail when
  a model drops a field the fixture carries (each model is encoded back and compared), so a misspelt optional can't
  read as nil. `LiteAPIRouteTests` serve them from a stub server to check each `LiteAPI` method's route, its token
  (none on the public routes but the four still guarded; `?address=` on the viewer routes without one, and no request
  about an account without a viewer) and its error codes and details. `LiteSessionAPITests` check the sign-in (a
  challenge of any other shape is never signed, a signature that isn't SEP-53 is never sent), the refresh (one request
  for refreshes of one token at once, never a rotated token again) and the renewal (one for concurrent 401s, then one
  retry, then the public view or `notSignedIn`). `SavedSessionTests` check the Keychain item's format.
- **Backend packages** add `<area>_fixtures.test.ts`, which produce their answers from seeded data and compare them
  with these files. A deliberate change to an answer changes its fixture, the Swift model and `contract.ts` together:
  a fixture field missing from `contract.ts` fails `fixtures.test.ts`, one the Swift model drops fails
  `LiteClientTests`, and a phone copy left behind fails `sync.sh --check`.
