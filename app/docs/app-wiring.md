# App wiring — what every screen of the iPhone app reads and writes

DyorHQ is a SwiftUI iPhone app (`ios/DyorHQ`) over a Swift package (`ios/DyorKit`). It talks to Monad mainnet
(chain id 143) directly: plain JSON-RPC over HTTPS to the keyless public endpoints, `rpc.monad.xyz` first and
`rpc1.monad.xyz` as failover (`Monad.publicRPCs` in `ios/DyorKit/Sources/DyorKit/Chain/Monad.swift`; the client in
`Core/RPCClient.swift` batches up to 40 calls per request and fails over on 429/5xx and 403 — rpc1 refuses every batch
with a 403, so batches stay on `rpc.monad.xyz`; a read, never a broadcast, a receipt or anything a transaction is signed
with, must start answering within 8 s on an endpoint (its body then read whole as long as it keeps coming) and is asked
of the other endpoint as well when the first's answer hasn't started in 1.3 s; the chain head is read once for every
reader within a second, `Chain/HeadClock.swift`). Contract reads are bundled into
one `eth_call` through Multicall3 `aggregate3` at `0xcA11bde05977b3631167028862bE2a173976CA11` (`Core/Multicall.swift`);
event history is `eth_getLogs` on `rpc1.monad.xyz` (`LaunchpadService.defaultLogsRPC`). Every write is a plan of
`TransactionStep`s that a `ConfirmationSheet` (`ios/DyorHQ/Wallet/TransactionRun.swift`) hands to `TransactionSender`
(`Chain/Transactions.swift`): each step is simulated with `eth_call`, gas-estimated (+20%), priced EIP-1559, signed on
the phone by the session's wallet, broadcast with `eth_sendRawTransaction` and polled for its receipt. The signer is one
of `PrivyWallet` (Privy's embedded wallet: email code, Apple, Google), `LocalWallet` (an imported key or the email +
password key, in the iPhone Keychain) or a Mera passkey session (`Wallet/Mera/`, key derived from the passkey's PRF
output, never stored). No DyorHQ server signs or relays transactions. The only backend is Supabase
(`Services/Supabase/SupabaseClient.swift`): PostgREST reads with the publishable key, writes under a wallet session
minted by the `wallet-auth` Edge Function from a `personal_sign` over a single-use nonce, row-level security by wallet.

Tabs: Home, Launch, Trade (Swap | Perps), Moments (`ios/DyorHQ/App/RootView.swift`). The side menu adds Portfolio,
News and Get Help; Home's header opens Profile and Notifications (`App/Router.swift`). Paths below are relative to
`ios/DyorHQ/` for screens and `ios/DyorKit/Sources/DyorKit/` for services.

## Home

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Home | Balances of MON, of the curated list and of every held token, read with `ERC20.balances` through Multicall3; held tokens found from the wallet's incoming `Transfer` logs (6,480,000-block window). Prices from `PriceService`: Uniswap v4 `StateView` / v3 `slot0`, Nad.fun v2 reserves, and for DyorHQ coins their own curve or pool (`DyorVenue`); the 24h change re-reads at the day-ago block (`BlockClock`). Perpl account and positions (`getAccountByAddr`, `getPosition`). Newest launches (`launchListing`), the wallet's Moments (`MomentsService.portfolio`), Total Volume from `PortfolioModel`, logos from `GET api.kuru.io/api/v1/markets`. Polls every 30 s. | None of its own. Sheets: Receive (QR); Send (native or ERC-20 `transfer`); Transfer (Spot ↔ Perps: approve AUSD → `createAccount` / `depositCollateral`, buying the missing AUSD with MON first when short; `withdrawCollateral` the other way); Bridge (below). | `Home/HomeView.swift`, `Home/TransferSheet.swift`, `Home/AddFundsCard.swift`, `Services/Prices/`, `Services/WalletTokenDiscovery.swift` |
| Token page | Price and 24h change, a 24-hour history (48 Multicall3 reads at past blocks, Swift Charts), the wallet's balance, and the coin's launch or Moment when it is a DyorHQ coin (`DyorCoinRegistry`, read from the factories themselves). | None; Buy / Sell open Swap on the pair, or the Launch page when the coin still trades on a curve. | `Home/HomeView.swift`, `Services/DyorCoins/DyorCoinRegistry.swift` |
| Bridge | Aurora Intents Swap API through the `aurora-proxy` Edge Function (wallet session; the Aurora key stays server-side): `tokens`, `quote`, `status`. Balances on the source chains from public RPCs (`eth_getBalance`, Multicall3 `balanceOf`; `EVMChain.supported`). `BridgeTracker` polls the status and the destination balance until the funds land. | The source-chain deposit, signed on the phone with a `TransactionSender` bound to that chain's id and RPC (one side is always Monad); `submitDeposit` to Aurora through the proxy. | `Bridge/*.swift`, `Services/Aurora/`, `Chain/EVMChain.swift`, `supabase/functions/aurora-proxy/` |

## Launch

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Board and coin page | Factory and curve state through Multicall3 on the live v2 stack (factory `0x3B1f5f562f5F61B980aBfDDbebD6cdF9a73b0b5b`) and the four retired stacks: `getLaunches`, `getLaunchedToken`, curve `price` / `getReserves` / `quoteBuy` / `quoteSell`, `HolderFeeSharing` and `FeeEscrow` balances. Per coin: curve fills from `CurveBuy` / `CurveSell` logs over the last 24 h (candles in Swift Charts) and the holder count from the token's `Transfer` logs (6,480,000 blocks). Pair-token prices from `PriceService`. Coin pictures at list sizes from Storage's resized copy of the `launch-media` object (`/storage/v1/render/image/public/…?width=<bucket>&resize=contain&quality=70`, `ImageSourcePolicy.renderURL`), the original after it; the board warms its next rows (`BoardPrefetch`). | Buy (approve the pair token if ERC-20, curve `buy`); Sell (approve, curve `sell`); Launch (factory `launchToken` with the launch fee in MON, or router `launchAndBuy` with a developer buy; the fee and economics hash shown are re-checked before signing); Retry graduation (`graduate`); Claim rewards (`HolderFeeSharing.claim`); Claim creator fees (`FeeEscrow`). Coin image: upload to the Supabase bucket `launch-media` under the wallet session, stored `Cache-Control: public, max-age=604800` (write-once; a week, as the app rechecks it, so a takedown reaches other caches too). Retired stacks are sell-only. | `Launchpad/LaunchpadView.swift`, `Services/Launchpad/LaunchpadService.swift`, `LaunchpadContracts.swift`, `LaunchpadEvents.swift`, `RetiredLaunchpads.swift`, `contracts/src/` |
| Launch profile | The wallet's curve positions and PnL (own fills, up to 30 days), the coins it launched, claimable creator fees per stack escrow and holder rewards per coin, its launchpad activity (1,512,000-block window). | Claim one asset, one coin's rewards, or everything (`claimEscrowPlan`, `claimRewardsPlan`). | `Launchpad/LaunchpadProfileView.swift`, `Services/Launchpad/LaunchpadPortfolio.swift` |

## Trade

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Swap | Quotes from every venue at once (`SwapEngine`): Kuru Flow (`POST ws.kuru.io/api/quote`, JWT from `/api/generate-token`), Uniswap v3 `QuoterV2` and v4 `V4Quoter` / `StateView`, Monday Trade `QuoterV2` — the contract quotes via Multicall3, 20 s budget per venue, refreshed every 15 s. Each venue's quote shows as it arrives (`SwapEngine.quoteUpdates`) and Review takes only the final answer; the route search is kept a minute in the shared reads (`SwapRouteCache`), so an amount change costs each venue one quote read (the price-impact slice included); Kuru's token is asked for as Swap opens. Balances and prices. Token picker: tokens the wallet acquired (`KnownTokenStore`), every token with a pool on Uniswap v3/v4 or Monday (pool-creation logs from genesis, `VenueTokenList`), Kuru's token directory (`GET api.kuru.io/api/v1/tokens/search`), or a pasted address (`ERC20.metadata`). Logos for tokens found on chain from Kuru's markets (`GET api.kuru.io/api/v1/markets`, kept in Caches for a day, SVGs left out; `KuruTokenListClient.logos`). History: the local activity log merged with the wallet's `Transfer` logs (`SwapHistoryService`, 24H / 7D / 30D). | The chosen venue's plan: approvals, then the venue router call (`docs/swap-spec.md`); MON ↔ WMON `deposit` / `withdraw`. | `Swap/SwapView.swift`, `Trade/TradeView.swift`, `Services/Swap/`, `Services/SwapHistory.swift`, `Services/VenueTokensService.swift` |
| Perps · on chain | Perpl's Exchange contract via Multicall3: `getPerpetualInfo`, `getMarginFractions`, `getAccountByAddr`, `getPosition`, `getPerpOrderLocks` / `getOrderIdIndex` / `getOrder`; the wallet's AUSD balance and allowance. | `createAccount` / `depositCollateral` after an AUSD approval, `withdrawCollateral`, `execOrders` for market and limit orders, reduce-only closes, cancels and added margin, `allowOrderForwarding(true)` for one-click trading. | `Perps/PerpsView.swift`, `Perps/PerpTradeView.swift`, `Services/Perpl/PerplService.swift`, `PerplExchange.swift` |
| Perps · Perpl API | REST, no auth: `GET app.perpl.xyz/api/v1/pub/context` (24h, volume, OI, funding) and `…/v1/market-data/{id}/candles/{res}/{from}-{to}`. Market-data WebSocket `wss://app.perpl.xyz/ws/v1/market-data` (heartbeat, market state, order book, trades). With an enrolled trading key: the trading WebSocket `wss://app.perpl.xyz/ws/v1/trading` (open orders, keeper triggers, positions) and Ed25519-signed history (`/v1/trading/fills`, `/v1/trading/position-history`, `/v1/trading/account-history`). Chart: TradingView Lightweight Charts bundled in `Resources/Web/`, fed by Perpl's candles. | Through the trading socket, once a key is enrolled: market / limit orders and take-profit / stop-loss as `mt:22` frames (keeper-managed triggers; the contract has none). Enrollment: `POST …/v1/api-key/payload` → the wallet signs the validated EIP-712 digest → the Ed25519 key is kept in the Keychain (a passkey account derives it per session). | `Perps/PerpsPortfolioView.swift`, `Perps/TradingViewChart.swift`, `Wallet/PerplTrading.swift`, `Services/Perpl/PerplFeed.swift`, `PerplTradeClient.swift`, `PerplAuth.swift`, `PerplHistory.swift` |

## Moments

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Board, Moment page, portfolio | The v2 contracts (factory `0x95eb7F5A88B10D9dF32aC54F48C767927fa80840`) through Multicall3: `policy` / `termsHash`, `momentCount`, `getMoment`, Collect `ledger` / `state` / `quote`, Vesting `claimable` / `entitlement`, the graduation record and the pool's `slot0` via `PoolManager.extsload`; NFT holders (`ownerOf`). The wallet's history from `Collected` / `Claimed` / `Withdrawn` / `FeesWithdrawn` / `Published` logs since the deploy block. Media from IPFS gateways or the Supabase mirror, size-capped (`RemoteMedia`), decoded at the size bucket each view shows and kept in Caches between launches (`Core/ImagePipeline.swift`, `Core/ImageDiskCache.swift`: write-once `launch-media` objects and IPFS CIDs rechecked weekly, other pictures hourly, both shown at once meanwhile; erased with the account). A hash-checked photo is always read whole, in download slots of its own (`RemoteMedia.largeFetches`); the board warms its next rows' art (`BoardPrefetch`; the latest rows only, and no whole photo on Low Data Mode or cellular, `NetworkCost`). Share links `dyorhq.fun/moments/<name>` (universal links) resolve through `MomentDirectory`. | Publish (factory `publish(params, expectedTermsHash)`); Collect (approve USDC → Collect `collect`); Claim / Claim all (Vesting `claim` / `claimAll`); creator proceeds and pool-fee withdrawals; platform / treasury withdrawals; retry graduation; expire; buyback. Media: a photo encoded at most 2048 px at JPEG 0.85 (`MomentsMath.photoMaxPixels`), upload to the `launch-media` bucket (stored with a week's `Cache-Control`), then the `pin-media` Edge Function pins it to IPFS; the on-chain URI is `ipfs://<cid>` and the file's keccak-256 is recorded. | `Moments/*.swift`, `Services/Moments/`, `contracts/src/moments/`, `supabase/functions/pin-media/` |
| Past cohorts | Cohorts 1–3 (claim-only) read from their own contracts: vested coins, creator proceeds and pool fees still owed. | `claim`, `withdrawCreator`, the hook's creator-fee withdrawal — nothing else. | `Moments/RetiredMomentDetailView.swift`, `Portfolio/PastCohortsCard.swift`, `Services/Moments/RetiredMoments.swift` |

## Portfolio, Profile and the rest

| Screen | Reads | Writes | Source |
| --- | --- | --- | --- |
| Portfolio (menu) | Volume, fees and P&L per section: Spot from the wallet's `Transfer` logs (up to 90 days), Perps from Perpl's signed fills and position history, Launch from own curve fills and claims, Moments from the Moments logs (live and retired cohorts), Bridge from the local `BridgeStore`. Assets: every held ERC-20 (Multicall3 balances, discovery from `Transfer` logs) and ERC-721 (the four-topic `Transfer` logs among the transfers into the wallet its history store holds, then `ownerOf`, `tokenURI`; no scan of their own). | None; rows navigate to their section. | `Portfolio/PortfolioModel.swift`, `Portfolio/AssetsModel.swift`, `Services/WalletNFTDiscovery.swift` |
| Profile (header) | The wallet's `profiles` row (PostgREST), Recent Activity (local log merged with launchpad activity and 7-day swap scans), Perpl trading status, price-alert count, the RPC host. | Send (native transfer or ERC-20 `transfer`; the recipient is checked with `eth_getCode`). DyorHQ Social: sign in (`wallet-auth`), upsert `profiles` (handle, display name, bio), avatar to the `avatars` bucket (read back from its original by its `?v=` link; this phone draws the bytes it uploaded, `ImagePipeline.seed`). Settings mirrored to `user_settings`. Perpl: enroll or remove the trading key, enable one-click trading. Export: the Keychain key behind Face ID, Privy's export page in a `WKWebView`, or a passkey account's recovery phrase. Delete account: the `delete-account` Edge Function (a Privy token, or the wallet session for an email + password account), the `email_accounts` row, then everything on the device. Sign-out closes the `sessions` row. | `Profile/ProfileView.swift`, `Profile/Settings.swift`, `Profile/RecentActivityView.swift`, `Profile/AccountDeletion.swift`, `Social/SocialSession.swift`, `Social/SocialProfileView.swift`, `Wallet/WalletExportView.swift` |
| Notifications (bell) | The in-app center (`NotificationHub`, on device). While the app is open, `AlertCenter` checks price alerts every 30 s against `PriceService` and open Perpl positions for margin warnings (`PerpRisk`), fills and closes. There is no push server: local notifications only. | Local `UNUserNotificationCenter` posts; the center and price alerts are mirrored to the `notifications` and `alerts` tables. | `Notifications/*.swift`, `Wallet/Notifications.swift`, `Wallet/PriceAlerts.swift`, `Services/Notifications/` |
| News (menu) | The public RSS feeds of CoinDesk, Cointelegraph, Decrypt, The Defiant and The Block, fetched directly; articles open on the publisher's site. | None. | `News/NewsView.swift`, `Services/News/NewsService.swift` |
| Onboarding | Sign-in: Privy (email code, Apple, Google; Privy passkeys when enabled); a Mera passkey (WebAuthn PRF, rpId `accounts.dyorhq.fun`, when `PasskeysEnabled`); email + password (PBKDF2 1,000,000 rounds, the `email-pepper` Edge Function's HMAC, HKDF → secp256k1 key in the Keychain, bound to the wallet through `email-rebind`); an imported phrase or private key (derived on device, Keychain); or watch-only. | Nothing on chain. After sign-in: the backend session (`wallet-auth`), a `profiles` row, a `sessions` row. | `Onboarding/OnboardingView.swift`, `Onboarding/ImportWalletView.swift`, `Wallet/Session.swift`, `Wallet/Mera/`, `Chain/EmailWallet.swift`, `Services/Mera/` |
| Get Help, side menu | Links to the docs (`dyorhq.gitbook.io/docs`), dyorhq.fun and X. | None. | `Support/GetHelpView.swift`, `Menu/SideMenuView.swift`, `Core/DocsLinks.swift` |

## Charts

* Perps: TradingView's Lightweight Charts engine, bundled in `Resources/Web/chart.html` and
  `lightweight-charts.standalone.production.js` and rendered in a `WKWebView` with no network access of its own
  (`Perps/TradingViewChart.swift`); every candle comes from Perpl's REST candles above.
* Launch coin pages (candles built from `CurveBuy` / `CurveSell` fills) and Home token pages (the 24-hour price history)
  use Swift Charts.

## Build configuration

`Config/AppConfig.swift` reads build-time values from `Secrets.xcconfig` through `Info.plist`: the Privy app and client
ids, the social-login and passkey switches, the Perpl builder id, the Supabase URL and publishable key (with working
defaults), the wallet-export page and the bridge fee recipient. Contract addresses are baked into DyorKit
(`LaunchpadAddresses.monadMainnet`, `MomentsAddresses.monadMainnet`); a Debug build may point the RPC and the stacks at
a local fork, a Release build never reads those overrides. No provider API key ships in the app.

## Backend sync and remote switches

`Backend/BackendSync.swift` mirrors the device's activity log, notification center, price alerts and settings to the
wallet's own rows (`activity`, `notifications`, `alerts`, `user_settings`) under the wallet session, queued on the
device until an upload succeeds, and restores them after a sign-in on a new device (`Services/Supabase/BackendRestore.swift`
checks every restored value). `App/UpdateGate.swift` reads the public `app_config` row `ios` with the publishable key at
launch and at most every ten minutes: `min_build` retires old builds (balances and export stay reachable, nothing
signs) and `flags` are the owner's switches (`RemoteFlags`). Tables and functions: `supabase/migrations/`,
`supabase/functions/`, `supabase/README.md`.

## Perps on Perpl

Perpl is the on-chain perpetuals order book on Monad. The app talks to its Exchange contract
`0x34B6552d57a35a1D042CcAe1951BD1C370112a6F` (`Chain/Monad.swift`, `Services/Perpl/PerplExchange.swift`) directly:

* `getAccountByAddr` → account id, balance, locked balance, frozen flag, position bitmap. An address that never
  deposited reverts with `AccountNotFound(address)` (selector `0x03a0e277`); only that revert means "no account".
  `getPosition` per market → size, entry, margin, premium and the mark; the liquidation price is
  entry ± (entry × size × maintenance fraction − margin − premium) / size.
* Open orders: `getPerpOrderLocks` shows which markets hold locks, `getOrderIdIndex` gives the order ids, `getOrder`
  returns each order (book prices are `basePricePNS + priceONS`).
* Writes: `createAccount(amount)` / `depositCollateral(amount)` (AUSD, 6 decimals, minimum 10 AUSD to open),
  `withdrawCollateral`, `execOrders([OrderDesc], revertOnFail)` with order types OpenLong 0, OpenShort 1, CloseLong 2,
  CloseShort 3, Cancel 4, IncreasePositionCollateral 5 (added margin), Change 6. A market order is an
  immediate-or-cancel limit at the mark ± slippage. `allowOrderForwarding(true)` turns on one-click trading.
* Margin: the initial and maintenance fractions are `100 / value` of `getMarginFractions` (MON: 1000 and 2000, so 10%
  and 5%); a market whose read fails shows an unknown liquidation price rather than a guessed one.
* Take-profit and stop-loss exist only as Perpl keeper triggers: they go through the authenticated trading WebSocket
  with an enrolled Ed25519 key (`PerplTradeClient.swift`, `PerplAuth.swift`, `Wallet/PerplTrading.swift`), never
  through the contract.
* The market-data WebSocket and the public REST endpoints are called directly from the phone, with no proxy and no
  `Origin` header (`PerplFeed.swift`). Perps run only on Perpl; Monday Trade is a spot venue in this app.

## History without an indexer

Every history view is `eth_getLogs` over a bounded window, split into ranges the endpoint accepts
(`RPCClient.chunkedLogsReport` in `Core/Logs.swift`; a range that is refused is halved, and what still cannot be read is
left as a gap rather than failing the whole read). Range sizes per endpoint (`RPCClient.logChunkSize`, measured
2026-09-29): `rpc.monad.xyz` 100 blocks; `rpc1.monad.xyz` 100,000-block ranges (it answers a range of any span up to
10,000 logs per answer); `rpc3` / `rpc4` 1,000 blocks; a local fork 50,000. Every scan therefore goes to `rpc1`
(`LaunchpadService.defaultLogsRPC`), filtered by a contract or by the wallet's own address as a topic. Windows in the
code: curve trades 24 hours (`BlockClock` turns it into blocks), launchpad activity 1,512,000 blocks (about 5.3 days),
a launch coin's holders from its launch and a Moment coin's from its publish, wallet token discovery 6,480,000 blocks
(about 22.7 days), swap history up to 90 days, Moments history from each cohort's deploy block, and the venue token list
from genesis (in 5,000,000-block segments, checkpointed). The wallet's NFTs come from its history store's transfers in,
with no scan of their own. A screen's scan wider than its budget reads newest first (`RPCClient.newestLogs`,
`chunkedLogsReport(order: .descending)`) and says when it stopped short: a holder count is then a minimum ("12+", with a
plain note rather than an error, since no read can do better for a coin older than the budget reaches), and the 24h
volume of the trades read too. A range refused for ending past the answering node's head is asked again after a pause
(`LogsRouter.headPause`), and the head of those windows is read from the logs endpoints themselves. Only `rpc2` refuses
such a range: `rpc4`, `rpc3` and `rpc1` (and, unmeasured, `rpc.monad.xyz`) answer it clamped to their node's head, with
no error and the later blocks' logs missing, a node hundreds of blocks behind at times. So for the wallet's history,
whose reads are kept as coverage (a read given the round's head: the head clock read anew on the app's endpoints, else
the logs endpoints' own, `WalletHistoryService.roundHead`), the router asks an endpoint that clamps only for blocks
at least 600 below the head (`LogsEndpoint.clamps`, `LogsEndpoints.headLag`): the newest blocks wait for `rpc2` while
the scan's deadline lasts, and are otherwise left unread, a gap like any other. A screen's own read (no head given) may
ask any endpoint for any block, as before: with `rpc2` down it is at worst a few hundred blocks short until it reads
again, rather than empty. None of its newest 600 blocks is kept: a Moment coin's holder count, the one screen read kept
on the device, keeps only blocks at least that far below the head (`MomentHolderTally.settleBlocks`). Every history
round reads again the 1,200 blocks below the newest it read (`HistoryStore.overlap`), and `rpc1`, which answers any
JSON-RPC batch with HTTP 403, is sent one range a request. The
NFTs list says how far back the transfers into the wallet reach ("Only NFTs received since …") and counts what it lists
as a minimum. Monad's pace is measured from block headers rather than assumed (`Chain/BlockClock.swift`).

The wallet's history can also come from the backend's cache of the same five scans (supabase migration 32,
`history_read`, filled by the `history-indexer` Edge Function from the same public endpoints). `HistoryModel` publishes
the instant read from the device first, then, before the first round of each run of the rounds (a launch, another
wallet, a return to the app, an epoch reset), asks `ServerHistorySync.beforeRound`: a full read while any scan doesn't
hold what the server could add (every block from its floor to 1,200 below its head), a top-up from 20 blocks below the
oldest scan's newest block read when every scan does but is more than 60,000 blocks behind, else nothing
(`ServerHistoryPlan`); after an epoch reset or a spot check's mismatch the read is due at once, whatever the time of the
last, and one read or poll of a wallet runs at a time (the read waits for the one under way). It waits at most 20
seconds for it (the client's 15 and the chain head's read); what it takes in (`HistoryStore.adopt`, only the blocks the
document proves, never the newest 1,200) is published at once, and the rounds then read only what is left, about 2,400
blocks a scan (the 1,200-block margin plus the 1,200-block overlap), one `rpc2` request. A scan the server is
still filling in is polled beside the rounds — its account alone every minute, for at most 15 minutes a foreground
session, then bounded reads of the three newest ranges it newly covers. Once a day per wallet a random 10,000-block range
of what the server added to the transfers in is read again from the chain (one request) and compared by log id: a
mismatch distrusts the server for that wallet for a day, forgets the wallet's history on the device and reads it again
from the chain. Every failure is discarded and the device reads the chain as before. The owner's switches are
`serverHistory` (on unless the `app_config` row says `false`) and `historyEpoch` (raising it resets every entry that took
the server's history in under a lower one, whether the switch is on or off); both are kept in UserDefaults for the next
launch (`ServerHistoryDefaults`), and the server has its own instant switch (`serving`). The wallet's first transaction
as the server found it is kept in the history store, apart from the one the device found, and goes with the rest of what
the server added (an epoch reset, an erase, a spot check's mismatch). Nothing is read from the server on a local fork.

## Shared chain reads

Several screens read the same chain state at about the same time — Home, the Portfolio, the Launch and Moments boards,
My Launchpad, My Moments, Recent Activity and the alert checks — so those reads are made once and shared
(`Core/ChainCache.swift`, one `ChainCache` in `AppEnvironment`):

* The launch list is read once at 200 launches per factory, every factory's `launchCount()` in one Multicall3 aggregate,
  and each screen takes its own newest (`LaunchpadService.launchListing`, `LaunchListing.prefix(perFactory:)`); a factory
  the shared read couldn't read is read again with a screen's own limit, so Home's 30 and the board's 60 never wait on the
  Portfolio's 200, and a list read on a node behind (a page shorter than the count, a coin with no record) is that
  factory unread, never a shorter list. The live
  and retired Moments lists likewise (`MomentsService.moments(limit:)`, `RetiredMoments.list`). Shared for 15 s; a
  screen asking while the read is under way waits for it. A list that couldn't be read in full, and any failure, is never
  kept, so Retry reads again.
* Prices (`PriceService.prices(for:)`): identical reads at once are one read, a token's price is kept 10 s, and the block
  mined 24 hours ago a minute, so a warm read is one round trip. A token's pools are looked up by one lookup at a time:
  a read waits only for the lookups of its own tokens under way, so two screens never look the same token up twice, and a
  read whose tokens were all looked up lately waits for none.
* The Moments terms (`MomentsService.policy`) are shared for a minute (`ChainCache.TTL.terms`): their values change only
  through a proposal queued for 48 hours, and a publish stays bound to the terms its review showed (`termsHash`, MO-4).
* A transaction that settles in a `ConfirmationSheet` and every pull to refresh forget all of it
  (`AppEnvironment.invalidateChainReads`): the next read goes to the chain, and no read begun before is joined or kept.

What never changes once settled (ten minutes after it was made) is kept between launches in Application Support
(`ChainStore`, `chain-reads-143/`; a fork keeps no launch or Moment, in memory either, since a fork restarted can reuse an
index or an address, and its pools for the session only): each launch's token at its index, curve, pair asset,
text, supply and launch time (`launches.json`), each Moment's record and text, a retired cohort's included
(`moments-<factory>.json`), and the Uniswap and Nad.fun pools found with the time each lookup was made, so their time
limits still apply (`pools.json`; a DyorHQ coin's venue is read from its factory every session). A refresh then reads only
what moves: a launch's record, curve values and pool price, a Moment's ledger, editions, entitlements and graduation.
Text is kept as the chain holds it and made safe to show on every read. A kept launch whose record no longer matches
forgets that factory's launches and reads them in full. A graduated Moment coin's transfers counted so far are kept too
(`moment-holders-<coin>.json`: each address's net transfers over one run of blocks read in one piece), so its page reads
only the blocks since and, while the count doesn't reach the publish, the blocks before it, newest first; the newest 600
blocks are read every time and never kept, since an endpoint that clamps may have answered them short. Delete Account
and Forget This Device remove the folder, and no read begun before the erase writes to it after
(`Session.eraseLocalData`).

The Moments screens read in as few round trips as the data allows (speed work, build 23):

* A list's `momentCount()` is read with the state of every Moment the device keeps that the last count put in range, in
  one aggregate, so a board of settled Moments, a past cohort, or a kept Moment's page (`info(id:)`) is one read; a count
  that moved reads the new Moments in full.
* A Moment's page reads the Moment, its supply (`MomentsService.detail(for:)`) and the account's stake (one aggregate, its
  edition ids included) side by side and shows each as it lands, then its edition holders (every edition, 400 to a read,
  a minimum said past 10,000) and its coin's holders (kept from the last opening, said to be saved until read again). The
  Share button looks the Moment's name up only after the page's reads.
* The board polls every 20 s only while it is on screen with the app in front, and back within 20 s of its last read it
  waits out the rest; a poll that read nothing new sets nothing, and a countdown is drawn again alone when its text
  changes (`MomentCountdown`), a screen only when what it shows of the time changes (`MomentBoardTimes`,
  `MomentPageTimes`).
* My Moments checks the list the screens share (the newest 200), reads each cohort's list once for its positions and its
  proceeds (what a Moment still holds for its creator comes from the list), and reads its proceeds once on opening, then
  whenever the wallet's Moments scan moves.

## Saved screens

Home, the Portfolio, the Launch and Moments boards and My Launchpad each keep what they last showed for a wallet on the
device (`Core/SavedScreens.swift`, one `SavedScreens` in `AppEnvironment`, `saved-screens-143/` in Application Support,
out of backups; a fork saves none), so a screen opened paints it at once and reads everything again behind it:

* One file per screen and wallet (`home-<wallet>.json`, …; the boards signed out use `signed-out`). A file is shown only
  to the wallet it names, by the build that wrote it, and while it is under a day old and not dated ahead of the clock.
* A screen takes its saved file in before its first frame (`showSaved`, from its `onAppear`; the files are a few KB), so a
  warm launch opens Home, the boards and My Launchpad on what they last showed, never on placeholders or a spinner under
  it; Home takes in the Portfolio's for Total Volume too. With nothing saved, a board shows its spinner until its first
  read answers, never "No Moments yet" or "No Launches Yet".
* Whatever shows from a save says when it was read ("Updated 3 min ago", `SavedLine`), with a spinner while the read
  runs, until the screen's own reads replace it. Nothing is animated by the line: an animation keyed to it animated
  whatever changed with it (the first layout, `Paragraph`'s Korean words, the cards) and garbled the Moments board.
  The Moments board says it in its eyebrow's row, and Home under the balance beside Total Volume's column (the taller
  while Total Volume says its own saved time), so neither moves when the line goes; the Launch board's line is a row. A part whose read then fails keeps its saved figures, still said to be
  saved, beside its error and Retry. A saved launch opens its page by reference (`LaunchReference`), a saved Moment by its
  link (`MomentLinkView`), and a saved token row opens its page with the token alone, so the page reads it now: a page
  shows what it is given as current.
* Home saves each part it has figures of with when that part was read (Spot rows with prices and balances, the launch
  holdings, the Moments stakes, and the Perps equity — never the positions, which its tab reads every time) and publishes
  each part as its own read lands (`HomeReadState.showSaved`, `isSaved`, `hasFigures`); a launch part kept from the saved
  launches stays saved until every launchpad is read in this session. The Portfolio saves a period's figures per section
  only once they are final (its load read everything, and the history read the period's whole window with the chain
  reachable), dated by the load whose prices and Perpl fills they are valued with, and shows them until a load lands
  whole (`PortfolioModel.showsLive`); Home's Total Volume says its own saved time under it. The boards save only a full
  read, and the Launch board's "Your Sell-Only Coins" stays saved until the wallet's balances are read again; Publish
  stays off until the Moments terms are read.
  My Launchpad saves its launches, balances and rewards, escrows and prices; saved escrow balances show "As last read"
  and saved rewards aren't current, so Claim All never claims what was saved. Fees received, profit and loss and the
  Activity tab come from the history, which the device keeps on its own.
* Delete Account and Forget This Device remove every saved screen of every wallet, and no save asked for by a read that
  began before the erase lands after it (`Session.eraseLocalData`, `SavedScreens.epoch`). The models the environment
  keeps follow the wallet signed in (`LaunchpadProfileModel.follow`, `PortfolioModel.follow`): a sign-out clears what
  they hold of it in memory.
