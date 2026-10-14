# DyorHQ Swap — spot trading across Monad venues

The Swap side of the Trade tab (`ios/DyorHQ/Trade/TradeView.swift`, `ios/DyorHQ/Swap/SwapView.swift`) quotes three
venues at once, ranks them by output, and executes the chosen one from the user's own wallet. No DyorHQ contract sits
in the path; every transaction targets the venue's own router. The engine is `SwapEngine` in
`ios/DyorKit/Sources/DyorKit/Services/Swap/`; addresses live in `ios/DyorKit/Sources/DyorKit/Chain/Monad.swift`.

## Venues

| Venue | What is quoted | How it executes | Source of the addresses |
| --- | --- | --- | --- |
| **Kuru Flow** | `POST https://ws.kuru.io/api/quote` with a per-address JWT from `POST /api/generate-token` (1 request/second per address, cached per wallet). Returns `output` and a ready transaction `{to, calldata, value}` against `KuruFlowEntrypoint 0xb3e6778480b2E488385E8205eA05E20060B813cb`. The app accepts it only if `to` is the entrypoint, `value` is exactly the input for native MON and zero otherwise, and the decoded calldata (`KuruFlowSwap`, selectors `0xce1e7030` / `0x31343b21`) trades the requested tokens and amount, pays this wallet, enforces at least the slippage minimum and carries no fee. | ERC-20 input: `approve(entrypoint, amount)` then the returned transaction. Native MON is address zero and rides on `value`. | https://docs.kuru.io/kuru-flow/flow-overview, https://docs.kuru.io/contracts/Contract-addresses |
| **Uniswap** | v3: `QuoterV2 0x661e93cca42afacb172121ef892830ca3b70f08d` over pools from `UniswapV3Factory 0x204faca1764b154221e35c0d20abb3c525710498` at fee tiers 100 / 500 / 3000 / 10000 (direct at the three deepest tiers, two-hop through WMON, USDC, USDT0 or WETH at the deepest tier per leg). v4: `V4Quoter 0xa222dd357a9076d1091ed6aa2e16c9742dd26891` over hookless canonical pools (fee / tick spacing 100/1, 500/10, 3000/60, 10000/200) whose liquidity is read through `StateView 0x77395f3b2e73ae90843717371294fa97cc419d64`, direct or through native MON, plus graduated DyorHQ launchpad pools (hooked; the pool key read from the factory that recorded the coin) and graduated Moment pools (coin ↔ USDC, hooked), reached directly or through a canonical pool. The better of v3 and v4 is offered; v4 is skipped when either side is WMON. | v3: `SwapRouter02 0xfe31f71c1b106eac32f1a19239c9a9a72ddfb900` `multicall(deadline, [exactInput(Single), unwrapWETH9?, refundETH?])`; native MON in via `value`, native out via `unwrapWETH9`. v4: `Universal Router 0x0d97dc33264bfc1c226207428a79b26757fb9dc3` `execute(V4_SWAP)` with actions `SWAP_EXACT_IN(_SINGLE)`, `SETTLE_ALL`, `TAKE_ALL`; ERC-20 input goes through `Permit2 0x000000000022D473030F116dDEE9F6B43aC78BA3`: `approve(token → Permit2, amount)`, then `Permit2.approve(token, router, amount)` with a two-minute allowance; native MON in via `value`. | https://developers.uniswap.org/docs/protocols/v4/deployments (Monad), https://developers.uniswap.org/docs/protocols/v3/deployments/v3-monad-deployments |
| **Monday Trade** | Spot pools (concentrated liquidity with an embedded order book) through `QuoterV2 0xB97eCD41Aef0F842E773C8F9905919cDE49880C9` over pools from `Factory 0xC1e98D0A2a58fB8aBd10ccc30a58efff4080Aa21` at fee tiers 100, 300, 500, 3000 and 10000. Same route search as Uniswap v3 (`V3Router`). | `SwapRouter 0xFE951b693A2FE54BE5148614B109E316B567632F`, which has the Uniswap v3 SwapRouter v1 layout (deadline inside the params, `multicall(bytes[])`, `unwrapWETH9`, `refundETH`; recipient `address(0)` means the router, for the unwrap). | https://docs.monday.trade/spot-trading/spot-contract-pair-specifications |
| **Wrap** | MON ↔ WMON is 1:1 through `WMON 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A` `deposit` / `withdraw` and never goes to a venue. | | Monad token list |

Every address in `Monad.swift` was checked for bytecode on Monad mainnet on 2026-09-08. Quotes and route lookups are
contract reads bundled through Multicall3; the calldata builders (`SwapCalldata.swift`) are pinned byte for byte by
`ios/DyorKit/Tests/DyorKitTests/SwapTests.swift`. Transaction deadlines are 10 minutes.

## Token list

`Token.core` (`Chain/Monad.swift`) carries a curated set from Monad's official list (`monad-crypto/token-list`, mainnet
v2.48): MON, WMON, USDC, USDT0, WETH, WBTC, cbBTC, gMON, sMON, aprMON, shMON, AUSD, aBIL, USDe, USD1, mUSD, LBTC,
ezETH, rETH. The picker adds, in sections (`TokenPickerList.swift`): the tokens this wallet acquired in the app
(`ios/DyorHQ/Wallet/KnownTokenStore.swift`), every token with a pool on Uniswap v3, Uniswap v4 or Monday Trade
(pool-creation logs scanned from genesis, `VenueTokensService.swift` / `VenueTokenList.swift`, logos from Kuru), Kuru's
token directory for a typed search (`GET api.kuru.io/api/v1/tokens/search`, `KuruTokenListClient.swift`), and any
ERC-20 by pasted address (symbol, name and decimals read on-chain). A token the wallet was only sent is listed as
Unverified; a retired Moments cohort's coin is never listed or quoted; a coin still on a retired launchpad's curve is
sell-only, so a buy of it gets no quote (`SwapEngine.buyRefusal`).

## Behaviour

* Every venue is quoted independently with a 20-second budget, so a slow venue never hides the others. Quotes start
  400 ms after the last edit and refresh every 15 seconds while an amount is entered; a venue that gave no quote shows
  its reason in the list.
* Each venue's quote shows as it arrives (`SwapEngine.quoteUpdates`): the best so far, with "Best price so far. Still
  checking N more venues." and a "Checking…" row per venue still asked. Review opens only on the final answer, once
  every venue has answered or run out of time, for the pair, amount, slippage and wallet on screen
  (`SwapModel.selectedQuote`); the "Best" badge waits for it too. A refresh keeps the final answer on screen until its
  own is final. The sell-only check of the coin bought (`buyRefusal`) runs alongside the on-chain venues, and nothing
  they answer is shown until it clears the coin; Kuru Flow, a third party's API that is told the wallet and the pair,
  is asked a coin that may be a launchpad's only once the check has cleared it, so a refused buy never reaches it.
* The route search is kept a minute in the app's shared reads (`SwapRouteCache`, `ChainCache.TTL.swapRoutes`): each
  pair's Uniswap v3 and Monday Trade pools and their depth, each pair's live v4 pools (either way round), and each
  launchpad or Moment coin's graduated pool. An amount change or a refresh then costs each venue one quote read, which
  quotes the 1/1000 price-impact slice too. A settled transaction or a pull to refresh forgets it. Kuru Flow's access
  token is asked for as Swap opens, and a quote that needs it meanwhile waits for that request; a quote that ends
  (cancelled, refused or out of time) stops waiting at once, and the request goes on for the next one.
* The best output is preselected; the user can pick another venue. A venue the user picked stays selected through a
  round's answers as they arrive — while it hasn't answered, the best so far is shown, and the note under the amount
  says "Best price so far" only of the best so far — until the final answer: one that quotes it keeps it, one that
  doesn't gives the selection back to the best quote (`VenueSelection`). Minimum received follows the slippage setting
  (presets 0.1%, 0.5%, 1%, 3%, or a custom value up to 50%; the default is 0.5%). Price impact is measured against
  the venue's own marginal price (a 1/1000 slice quote) and is highlighted above 1%.
* Review freezes the quote: the sheet builds its plan once from that quote, so what it shows is what is signed, even
  though the list keeps refreshing behind it.
* Execution runs the plan through `TransactionSender` (`Chain/Transactions.swift`): approvals the allowance already
  covers are skipped, every approval is for exactly the input (an unlimited allowance left by an earlier build or
  another app is replaced rather than reused), each transaction is simulated with `eth_call` before it is signed, and
  hashes are shown as they are sent. Native MON never needs an approval. Max keeps back the network fee.
* A passkey (Mera) account's session signs a swap without a prompt only when the calldata decodes to the reviewed
  pair, amount and minimum (`Services/Mera/MeraCalldata.swift`).
* Other tabs open Swap on a pair through `Router.openSwap` (a token row on Home, a graduated coin on Launch or
  Moments). The app handles no swap URL: its only links are Moment links (`ios/DyorHQ/App/Router.swift`).

## Files

`ios/DyorHQ/Swap/SwapView.swift` (the screen, the slippage sheet, the token picker and the history list),
`ios/DyorHQ/Trade/TradeView.swift` (the Swap | Perps switch), and under `ios/DyorKit/Sources/DyorKit/Services/Swap/`:
`SwapEngine.swift` (per-venue quoting as the answers arrive, ranking, the trading-closed and sell-only rules),
`SwapTypes.swift` (request, quote, errors, slippage and impact math), `UniswapVenue.swift`, `MondayVenue.swift`,
`V3Router.swift` (the shared v3-style route search), `SwapRouteCache.swift` (what the route search keeps for a minute),
`KuruFlowClient.swift` (the Flow API and the calldata decoder), `SwapCalldata.swift` (every
contract call and router transaction), `TokenPickerList.swift`, `KuruTokenListClient.swift`. Swap history is
`Services/SwapHistory.swift`. `scripts/dev/pool-inventory.mjs` is a read-only mainnet inventory of pools per venue and
tier.

## Not built

* Exact-output swaps (every quote is exact-input).
* Limit orders on Kuru or Monday order books; the swap uses their market execution only.
* Monday Trade's RWA (tokenised stock) markets, which run through a separate authenticated API rather than the spot
  pools.
* A Kuru Flow integrator or referrer fee: the quote request carries no referrer fields, and a returned transaction
  with any fee basis points is refused (`KuruFlowSwap.takesNoFee`).
