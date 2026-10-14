# The Lite API

The Lite API is DyorHQ's Stellar backend: the `lite` Edge Function (`backend/supabase/functions/lite`). The phone
talks to it through StellarKit's `LiteAPI`. This page is the contract both sides build to. It covers every request,
response and error code, including the parity API of `docs/DESIGN-stellar-parity.md` §6.

The same contract exists in three other forms, kept in step with this page:

| Form | Where | Checked by |
|---|---|---|
| TypeScript types | `backend/supabase/functions/_shared/contract.ts` (`Routes` maps every route to its auth, body and answer) | `deno check` |
| Swift models | `ios/Packages/StellarKit/Sources/LiteClient/Models.swift` and `Models+*.swift` | `swift test` |
| Fixtures, one per response | `backend/tests/fixtures/api/*.json` (§17) | both of the above |

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
- **Auth.** Every route needs the Lite session token (`authorization: Bearer <token>`, from §2) **except** `auth/*`,
  `config`, `fees` and `markets*`. Those public routes read only the database and in-isolate caches, answer with
  `Cache-Control: public, max-age=30`, and the phone calls them without the token, so they work while the session is
  locked. Every other answer is `no-store`.
- **Limits.** Per isolate, best effort: 20 requests a minute per IP on `auth/*`, 120 a minute per account, 20 submits
  and 10 upload tickets a minute per account. Over the limit: 429 `rate_limited`. Anything that costs DyorHQ money is
  limited in Postgres, never only in memory.
- **New fields.** A field added to an existing answer is optional for the phone (`decodeIfPresent`), so an older
  server's answer still decodes. A server never removes a field without a new contract.

**Errors.** A refusal has an HTTP status and a body:

```jsonc
{ "error": { "code": "not_enough_xlm_for_fee", "message": "Not enough XLM for the network fee.",
             "detail": { "need": "510000", "spendable": "400000" } } }   // detail: facts, or null
```

`message` is plain English. The phone words known codes itself, in the user's language (§16), and shows `message`
verbatim otherwise. When a contract refused, `code` is `simulation_failed` and `detail.contractCode` names the reason;
`LiteAPI` then reports `LiteAPIError.server(status:code:message:)` with the contract's code (`launch.slippage`, …) as
its `code`.

---

## 1. Routes at a glance

"Public" routes take no token. *Owner* is the package that serves the parity form.

| Route | Auth | Request | Answer (`contract.ts`) | Fixture | Owner |
|---|---|---|---|---|---|
| `POST /v1/auth/challenge` | public | `{address}` | `AuthChallenge` | `auth-challenge` | — |
| `POST /v1/auth/verify` | public | `{address, nonce, signature, inviteCode?}` | `AuthResult` | `auth-verify` | — |
| `GET /v1/config` | public | | `LiteConfig` | `config`, `config.legacy` | WP-02 |
| `GET /v1/fees` *added* | public | | `Fees` | `fees` | WP-10 |
| `GET /v1/account` | JWT | | `AccountView` | `account`, `account.legacy`, `account.missing` | WP-10 |
| `POST /v1/account/activate` | JWT | `{}` | `ActivationResult` | `plan`, `account-activate` | WP-10 |
| `POST /v1/account/trust` | JWT | `{asset}` | `PlanView` | `plan` | WP-10 |
| `POST /v1/account/faucet` | JWT | `{}` | `{hash}` | `account-faucet` | WP-10 |
| `GET /v1/recipient/:address?asset=` *added* | JWT | | `Recipient` | `recipient` | WP-10 |
| `POST /v1/send` | JWT | `SendRequest` | `PlanView` | `plan-send` | WP-10 |
| `POST /v1/plans/:plan/steps/:step/build` | JWT | `{}` | `PlanView` | `plan`, `plan.legacy` | WP-10 |
| `POST /v1/tx/submit` | JWT | `{planId, stepId, signedXdr}` | `Submitted` | `tx-submit` | WP-10 |
| `GET /v1/tx/:hash` | JWT | | `TxStatus` | `tx-status`, `tx-status.legacy` | WP-10 |
| `POST /v1/swap/quote` | JWT | `{sell, buy, amount, slippageBps?}` | `SwapQuote` | `swap-quote`, `swap-quote.legacy` | WP-10 |
| `POST /v1/swap/build` | JWT | `{quoteId, venue?}` | `PlanView` | `plan` | WP-10 |
| `GET /v1/markets` *added* | public | | `Markets` | `markets` | WP-13 |
| `GET /v1/markets/:id` *added* | public | | `MarketDetail` | `market` | WP-13 |
| `GET /v1/markets/:id/history?range=` *added* | public | | `PriceHistory` | `market-history` | WP-13 |
| `GET /v1/prices` | JWT | | `Prices` | `prices` | WP-13 |
| `GET /v1/assets?q=` *added* | JWT | | `AssetSearch` | `assets` | WP-18 |
| `GET /v1/holdings` *added* | JWT | | `Holdings` | `holdings`, `holdings.partial` | WP-18 |
| `GET /v1/portfolio?period=` *added* | JWT | | `Portfolio` | `portfolio` | WP-18 |
| `GET /v1/activity?section=&kind=&period=&market=&limit=` | JWT | | `Activity` | `activity`, `activity.legacy` | WP-18 |
| `GET /v1/launches?section=&sort=&q=&limit=&cursor=` | JWT | | `LaunchBoard` | `launches`, `launches.legacy` | WP-14 |
| `GET /v1/launches/:token?candles=` | JWT | | `LaunchDetail` | `launch`, `launch.legacy` | WP-14 |
| `POST /v1/launches/:token/quote` | JWT | `{side, amount}` | `TradeQuote` | `launch-quote`, `launch-quote.legacy`, `launch-quote-sell.legacy` | WP-14 |
| `POST /v1/launches/metadata` *added* | JWT | `LaunchMetadataRequest` | `{uri}` | `launch-metadata` | WP-14 |
| `POST /v1/launches/build` | JWT | `LaunchBuildRequest` | `PlanView` | `plan` | WP-14 |
| `GET /v1/economics` *added* | JWT | | `Economics` | `economics` | WP-14 |
| `GET /v1/launchpad/me` *added* | JWT | | `MyLaunchpad` | `launchpad-me` | WP-14 |
| `GET /v1/moments?filter=&limit=` | JWT | | `MomentFeed` | `moments`, `moments.legacy` | WP-16 |
| `GET /v1/moments/owned` | JWT | | `OwnedEditions` | `moments-owned`, `moments-owned.legacy` | WP-16 |
| `GET /v1/moments/mine` *added* | JWT | | `MyMoments` | `moments-mine` | WP-16 |
| `GET /v1/moments/:id` | JWT | | `MomentDetail` | `moment`, `moment.legacy` | WP-16 |
| `POST /v1/moments/metadata` | JWT | `MomentMetadataRequest` | `MomentMetadata` | `moment-metadata`, `moment-metadata.legacy` | WP-16 |
| `POST /v1/moments/build` | JWT | `MomentBuildRequest` | `PlanView` | `plan` | WP-16 |
| `POST /v1/media/upload-url` | JWT | `{contentType, bytes}` | `UploadTicket` | `media-upload-url` | WP-16 |
| `GET /v1/earn/markets` | JWT | | `EarnMarkets` | `earn-markets`, `earn-markets.legacy` | WP-15 |
| `GET /v1/earn/positions` | JWT | | `EarnPositions` | `earn-positions`, `earn-positions.legacy` | WP-15 |
| `GET /v1/earn/history?pool=&asset=&range=` *added* | JWT | | `EarnHistory` | `earn-history` | WP-15 |
| `POST /v1/earn/build` | JWT | `{action, pool, asset, amount}` | `PlanView` | `plan` | WP-15 |
| `POST /v1/bridge/quote` | JWT | `{direction, amount}` | `BridgeQuote` | `bridge-quote`, `bridge-quote.legacy` | WP-17 |
| `POST /v1/bridge/start` | JWT | `{direction, amount, monadAddress}` | `BridgeStart` | `bridge-start-in`, `bridge-start-out` | WP-17 |
| `POST /v1/bridge/:id/source` | JWT | `{txHash}` | `{id, status}` | `bridge-source` | WP-17 |
| `POST /v1/bridge/:id/claimed` | JWT | `{txHash}` | `{id, status}` | `bridge-claimed` | WP-17 |
| `GET /v1/bridge/:id` | JWT | | `BridgeStatus` | `bridge-status` | WP-17 |
| `GET /v1/cash/anchors?country=` | JWT | | `CashAnchors` | `cash-anchors` | WP-17 |
| `POST /v1/cash/track` | JWT | `CashTrackRequest` | `{id}` | `cash-track` | WP-17 |

Error bodies: `error`, `error-contract`, `error.legacy`. `/v1/moments/owned` and `/v1/moments/mine` are registered
before `/v1/moments/:id`, so they never reach it.

---

## 2. Auth (public)

**`POST /v1/auth/challenge`** `{address: "G…"}` → `{nonce, message, expiresAt}`. The nonce is single-use and lives 5
minutes. `message` is the exact text the phone signs, one fact per line:

```
DyorHQ Lite sign-in
Network: testnet
Address: G…
Nonce: …
Issued: 2026-10-14T09:41:00.000Z
```

**`POST /v1/auth/verify`** `{address, nonce, signature, inviteCode?}` → `{token, expiresAt, tester: {address, label}}`.
`signature` is the base64 ed25519 signature of the SEP-53 digest of `message`. A first sign-in needs `inviteCode`.
Refusals: 401 `unauthorized` (nonce used or expired, signature wrong), 403 `not_invited`, `bad_invite`,
`access_revoked`.

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
| `anchors[]` | `{domain, name, assets, countries, kinds}` | SEP-24 anchors. |
| `bridge` | `{routes, monad: {chainId, usdc} \| null}` | |
| `flags` | `{enabled, maintenance?}` | From `lite.app_config`. |
| `minBuild` | number | Older builds are asked to update. |
| `deployment` *added* | `{id, launchpad, moments}` | `id` is the deployment's name (`testnet`, `testnet-qa`). |
| `explorer` *added* | string | StellarExpert's base. Informational: the phone builds links from its pinned network. |
| `fees` *added* | `{payer, maxFee, maxInclusionPerOp, starterInnerFeeMax, starterSwap, fundingFloor}` | Stroops. `payer` is `user`; `starterSwap` is true only where DyorHQ sponsors one starter swap (mainnet). Informational: the phone enforces its pinned `feePolicy`. |
| `faucet` *added* | `{amount}` or null | Testnet's faucet, in XLM ("10000"). Null off testnet. |
| `limits` *added* | `{momentMaxEditions, momentWindowSecs: [min, max], collectMax, launchName: [min, max], launchSymbol: [min, max], uriMax, uploadBytes}` | What the server accepts. `launchName` is UTF-8 bytes. |
| `pricing` *added* | `Pricing` | §8. |

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
`starterSwap` is `available | used | unavailable`; `faucet` is `{amount, usedToday}` on testnet, null elsewhere.

**`POST /v1/account/activate`** `{}` → a `PlanView` to run, or `{status: "active", account}` when there is nothing to
do.

| Account | Answer |
|---|---|
| Missing, `friendbot` (testnet) | Friendbot funds it (10,000 test XLM), then a **user-paid** `trust` plan for USDC. |
| Missing, `sponsored` (mainnet; local rehearsal with `LITE_ACTIVATION=sponsored`) | An `activate` plan: DyorHQ creates the account with 0 XLM and sponsors the USDC trustline (`feePayer: sponsor`, `sponsorReason: setup`). |
| Exists, USDC not enabled | A user-paid `trust` plan. Too little XLM: 409 `not_enough_xlm_for_reserve`. |
| Exists, USDC enabled | `{status: "active", account}`. |

**`POST /v1/account/trust`** `{asset}` → a user-paid `trust` plan (`reserveDelta: 1`).

**`POST /v1/account/faucet`** `{}` → `{hash}`. Testnet only (400 `testnet_only`), once a day (429 `faucet_used`).

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
| `routes[]` *added* | Every venue that answered: `{venue, amountOut, minOut, priceImpactBps, path, best}`. `venue` is `sdex`, `soroswap` or `aquarius`; `priceImpactBps` is null where unknown. |
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

**`GET /v1/assets?q=`** (JWT, so `held` can be set, *added*) → `{results: [{id, kind, code, name, contract, classic,
verified, held}]}`. `kind`: `registry | launch | classic | contract`. At most 30, matched on code and name, or exactly on
a C… id or `CODE:G…`. A pasted C… that isn't a launch is read live (`symbol()`, `name()`, `decimals()`) and answered as
`kind: contract, verified: false`.

**`GET /v1/prices`** (JWT) → `{usd: {id: number}, reference, at}`, kept for older clients. Values come from the
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
  costBasisQuote, pnlQuote, isCreator}` (cost basis and P&L null for coins received by transfer), `economics {feeBps,
  protocolShareBps, creatorFeeBps, supply, phantom, threshold}` and `pricePoints [{t, price}]` (at most 300).

**`POST /v1/launches/:token/quote`** `{side: "buy" | "sell", amount}` → buy `{side, used, tokensOut, fees, snipeFee}`,
sell `{side, quoteOut, fees}`; *added* `baseFee`, `creatorFee` and `refund` (the part of a buy a full curve returns).
`fees` is every fee together.

**`POST /v1/launches/metadata`** *added* `{name, symbol, description?, imageUrl?, website?, x?, telegram?}` →
`{uri}`. `imageUrl` must start with `<media base>uploads/<user>/`; `website` is https; `x` is `https://x.com/…` or
`https://twitter.com/…`; `telegram` is `https://t.me/…`; each link at most 200 characters, the description at most 500.

**`POST /v1/launches/build`** `{action: create | buy | sell | graduate | claim, token?, quote?, name?, symbol?, uri?,
creatorFeeBps?, amount?, minOut?}` → `PlanView`. Create: `uri` empty or one this user's metadata call returned, ticker
`^[A-Z0-9]{2,10}$`, name at most 32 UTF-8 bytes, a reserved-looking ticker 400 `look_alike_symbol`, creator fee 0–1000
bps. Buy and sell take `minOut` (the app's fixed 1%).

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
`collectorsSummary {count, largest: {address, editions} | null}`, `you {editions: [token ids still owned], spent}` and
`creatorEarned` (base units of the quote).

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
| `type` | `tx \| bridge \| cash` |
| `id`, `kind`, `status`, `at` | `kind`: an intent kind (§6), a bridge direction, or `deposit`/`withdraw`. |
| `summary` | The server's English words. |
| `amount` | Bridge: base units of the sending side's USDC; cash: the anchor's amount as written. |
| `display` | A transaction's intent display, or a cash transfer's `{asset}`. |
| `section` *added* | `spot \| earn \| launch \| moments \| bridge \| cash \| account` |
| `hash`, `feeCharged`, `feePayer`, `result {amountOut}` *added* | |
| `ref` *added* | `{token}`, `{momentId}` or `{market}`: what the row opens. |
| `symbol`, `name` *added* | The asset, resolved (never "TOKEN"). |
| `title`, `subtitle`, `usd` *added* | English; the phone words known kinds itself. |

---

## 15. Bridge and cash

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

**`GET /v1/cash/anchors?country=`** → `{anchors: [AnchorInfo]}`. **`POST /v1/cash/track`** `{anchor, kind: "deposit" |
"withdraw", asset, amount?, anchorTxId, status?}` → `{id}`: records the anchor transfer so activity can show and resume
it.

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
| 400 `look_alike_symbol` | create with a reserved-looking ticker | That ticker looks like another token's. Choose another. |
| 400 `muxed_unsupported` | an M… recipient | Muxed (M…) addresses aren't supported. Use the G… address and the memo you were given. |
| 409 `recipient_missing` | a non-XLM send to a missing account | This account doesn't exist yet, so it can't receive %@. |
| 409 `recipient_no_trust` | the recipient hasn't enabled the asset | This account hasn't enabled %@, so it can't receive it. |
| 422 `simulation_failed` + `detail.contractCode` | a contract refused: `launch.slippage`, `launch.closed`, `launch.disabled`, `launch.nothing_to_claim`, `moment.closed`, `moment.sold_out`, `moment.price_too_low`, `trust.missing` | The price moved past your 1% limit. Nothing was sent. Review again for a new price. / This curve isn't taking trades now. / New launches are paused. / Nothing to claim yet. / This Moment's collect window has closed. / This Moment is sold out. / The price is below the minimum (%@). / Enable %@ first. |
| 429 `upload_budget` | the daily upload budget | You've uploaded a lot today. Try again tomorrow. |
| 429 `bridge_relay_limit` | the daily relayed-bridge cap | You've bridged in many times today. Try again tomorrow. |
| 422 `tx_rejected` | any other send error (`detail.code` is Stellar's result code) | the server's message, verbatim |

The %@ values come from what the screen already holds (the review's fee, the asset, the account's minimum balance,
the Moments policy). `detail` may repeat them (`need`, `spendable`, `asset`, `minPrice`) for logs.

Other codes, shown as the server's message: 400 `bad_json`, `too_large`, `bad_arg`, `bad_amount`, `bad_address`,
`bad_asset`, `bad_memo`, `too_small`, `bad_xdr`, `unsigned`, `empty_plan`, `same_asset`, `bad_slippage`, `bad_pool`,
`bad_action`, `bad_request_type`, `bad_side`, `bad_quote`, `bad_name`, `bad_symbol`, `bad_fee`, `bad_uri`, `bad_title`,
`bad_media`, `bad_moment`, `bad_quantity`, `bad_editions`, `bad_window`, `bad_type`, `bad_direction`, `bad_hash`,
`bad_spender`, `bad_anchor`, `bad_kind`, `testnet_only`, `no_friendbot`; 401 `unauthorized`; 403 `not_invited`,
`bad_invite`, `access_revoked`; 404 `not_found`, `no_route`; 409 `account_inactive`, `needs_usdc`, `needs_restore`,
`not_ready`, `not_built`, `already_sent`, `stale_step`, `recipient_inactive`, `recipient_cannot_receive`; 410
`plan_expired`, `quote_expired`; 429 `rate_limited`, `faucet_used`; 500 `self_check_failed`, `internal`; 501
`mainnet_route`; 502 `friendbot_failed`, `rpc_unavailable`, `storage_error`, `bridge_quote_failed`; 503
`not_deployed`, `network_busy`, `storage_unavailable`; 504 `friendbot_slow`. Today's 429 `budget_exhausted` goes with
the daily sponsored-fee budget when users start paying their own fees.

---

## 17. Fixtures

`backend/tests/fixtures/api/<name>.json` holds one example of each answer: `<name>.json` in the parity form and
`<name>.legacy.json` for today's form where it differs (`account.missing`, `holdings.partial` and the `error*` bodies
are further cases). They are written for testnet with synthetic addresses.

- **`backend/tests/fixtures/fixtures.test.ts`** type-checks each fixture against its `contract.ts` type and fails when a
  fixture isn't listed:
  `deno test --allow-read --config backend/supabase/functions/deno.json backend/tests/fixtures/`.
- **`backend/tests/fixtures/sync.sh`** copies them to `ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures/`
  (`--check` only compares). Both copies are committed.
- **`LiteClientTests`** decode every fixture with the model the client uses (`testDecodesApiFixtures`), and fail when
  a model drops a field the fixture carries (each model is encoded back and compared), so a misspelt optional can't
  read as nil. `LiteAPIRouteTests` serve them from a stub server to check each `LiteAPI` method's route, its token
  (none on the public routes) and its error codes.
- **Backend packages** add `<area>_fixtures.test.ts`, which produce their answers from seeded data and compare them
  with these files. A deliberate change to an answer changes its fixture, the Swift model and `contract.ts` together.
