import BigInt
import Foundation

/* On-chain history without an indexer: `eth_getLogs` over recent blocks in chunks the endpoint accepts, newest first (see
   `RPCClient.newestLogs`). Windows are deliberately recent (hours, or a coin's life, not months). A port of the web app's
   `launchpad/events.ts`. */

public extension LaunchpadService {
    /// Curve fills for one launch over the last `lookbackBlocks` blocks, or the last 24 hours (`clock`) when nil, oldest
    /// first, and whether the window was read in full (`CurveTrades`). `pair` scales prices to pair units so they line up
    /// with `Launch.pairPrice`; each fill's time is estimated at the session's measured pace. Nil when the head, or the
    /// newest blocks of the buys or of the sells, couldn't be read: no trades at all, never "no trades" — the screen keeps
    /// the last good read and says this one failed.
    ///
    /// The buys and the sells are read newest first (`RPCClient.newestLogs`), and a read that stops short keeps the fills
    /// of the run read in one piece down from the head — of both, down to the later of where each stopped — so what it
    /// gives is every fill from some block to now, never a scatter. In build 22 and earlier both read oldest first and the
    /// result said nothing of what was missing: on the 1,000-block endpoints (the 24 hours are about 290 requests there, the
    /// budget 80) the chart held the day's first hours and the 24h volume was theirs, shown as the whole.
    ///
    /// The head comes from the endpoints the logs are read from (`logsRPC`), as a coin's holders' does: read from the app's
    /// own endpoint (`rpc`), a node of the logs endpoint a few blocks behind it refused the newest range, which the router
    /// asks again only after a pause (`LogsRouter.headPause`). The window ends at the head, not a margin below it as the
    /// venue list's does (`VenueTokensService.headMargin`): a trade made on this page a moment ago is in its newest
    /// blocks, and the page reads its trades again as soon as it is made.
    func trades(curve: Address, pair: PairInfo, lookbackBlocks: UInt64? = nil) async -> CurveTrades? {
        guard let anchor = try? await logsRPC.block(.latest) else { return nil }
        let secondsPerBlock = await clock.secondsPerBlock()
        let lookback = lookbackBlocks ?? BlockClock.blocks(in: 86_400, secondsPerBlock: secondsPerBlock)
        let from = anchor.number > lookback ? anchor.number - lookback : 0
        async let buyRead = logsRPC.newestLogs(address: curve, topics: [LaunchpadABI.Events.buyTopic], fromBlock: from, toBlock: anchor.number)
        async let sellRead = logsRPC.newestLogs(address: curve, topics: [LaunchpadABI.Events.sellTopic], fromBlock: from, toBlock: anchor.number)
        let (buys, sells) = await (buyRead, sellRead)
        return Self.trades(buys: buys, sells: sells, anchor: anchor, pair: pair, secondsPerBlock: secondsPerBlock)
    }

    /// Pure half of `trades(curve:pair:lookbackBlocks:)` for reads that may have stopped short: the fills of both down to
    /// the later of the two `readFrom`s, complete only when both are. Nil when a side's newest block wasn't read: there is
    /// nothing to stand on, and an empty read in its place wiped the page's last good trades and showed a 24h volume of 0.
    nonisolated static func trades(buys: NewestLogs, sells: NewestLogs, anchor: BlockHeader, pair: PairInfo, secondsPerBlock: Double) -> CurveTrades? {
        guard let buysFrom = buys.readFrom, let sellsFrom = sells.readFrom else { return nil }
        let floor = max(buysFrom, sellsFrom)
        let fills = trades(buys: buys.logs.filter { $0.blockNumber >= floor }, sells: sells.logs.filter { $0.blockNumber >= floor }, anchor: anchor, pair: pair,
                           secondsPerBlock: secondsPerBlock)
        return CurveTrades(trades: fills, complete: buys.complete && sells.complete)
    }

    /// How many wallets hold a launch coin (`HolderCount`): the addresses with a positive net balance from the coin's
    /// `Transfer` events since its launch (`launchedAt`, seconds since 1970; its block estimated early, `launchBlock`).
    /// Mints/burns (the zero address) and any `excluding` address (e.g. the bonding curve, which holds the unsold supply)
    /// are left out. Nil when the head, or the newest of the coin's blocks, couldn't be read: no count at all, never 0.
    ///
    /// The transfers are read newest first (`RPCClient.newestLogs`) within the patient budget (80 requests): a coin older
    /// than that reaches back gets a minimum (`HolderCount.complete` false), never a count of balances at some past block.
    /// In build 22 and earlier the window was the last 6,480,000 blocks (about 22.7 days) whatever the coin's age, which
    /// needs 108 requests, read oldest first: it stopped at 80, the newest 1.7M blocks (about six days) unread, so a coin
    /// launched since read 0 holders, and the count was shown as exact.
    func holders(token: Address, excluding: Set<Address> = [], launchedAt: Int) async -> HolderCount? {
        guard let anchor = try? await logsRPC.block(.latest) else { return nil }
        let from = Self.launchBlock(launchedAt: launchedAt, anchor: anchor, secondsPerBlock: await clock.secondsPerBlock())
        let read = await logsRPC.newestLogs(address: token, topics: [ABI.eventTopic("Transfer(address,address,uint256)")], fromBlock: from, toBlock: anchor.number)
        return Self.holders(read, excluding: excluding)
    }

    /// Pure half of `holders(token:excluding:launchedAt:)`: nil when nothing was read down from the head.
    nonisolated static func holders(_ read: NewestLogs, excluding: Set<Address>) -> HolderCount? {
        guard read.readFrom != nil else { return nil }
        return HolderCount(count: holderCount(transfers: read.logs, excluding: excluding), complete: read.complete)
    }

    /// The addresses `transfers` leave with a positive net balance, the zero address and `excluding` left out. Of the
    /// transfers from some block to the head, a minimum of the holders (`HolderCount.complete`); of every transfer since
    /// the coin was minted, their number.
    nonisolated static func holderCount(transfers: [Log], excluding: Set<Address>) -> Int {
        var net: [Address: BigInt] = [:]
        for log in transfers {
            guard let sender = log.indexedAddress(0), let recipient = log.indexedAddress(1) else { continue }
            let amount = BigInt(BigUInt(log.data))
            if !sender.isZero { net[sender, default: 0] -= amount }
            if !recipient.isZero { net[recipient, default: 0] += amount }
        }
        return net.reduce(0) { count, entry in count + (entry.value > 0 && !excluding.contains(entry.key) ? 1 : 0) }
    }

    /// The block a coin launched at `launchedAt` (seconds since 1970) was launched in, estimated early from `anchor`: its
    /// age a quarter longer at `secondsPerBlock`, plus `tradeLookbackMargin`, so a chain a little faster than measured still
    /// puts the launch after it; never before the first launchpad's block (`LaunchpadAddresses.feeHistoryStart`), before
    /// which no DyorHQ curve traded. The one estimate a coin's holders and the wallet's fills on it are read from
    /// (`WalletHistorySnapshot.launchBlock`).
    nonisolated static func launchBlock(launchedAt: Int, anchor: BlockHeader, secondsPerBlock: Double) -> UInt64 {
        let age = max(0, TimeInterval(anchor.timestamp - launchedAt))
        let back = BlockClock.blocks(in: age * 1.25, secondsPerBlock: secondsPerBlock).addingReportingOverflow(tradeLookbackMargin)
        let estimate = back.overflow || back.partialValue >= anchor.number ? 0 : anchor.number - back.partialValue
        return max(estimate, LaunchpadAddresses.feeHistoryStart)
    }

    /// Pure half of `trades(curve:pair:lookbackBlocks:)`, so the parser can be tested on canned logs. Times are estimated
    /// from `anchor` at `secondsPerBlock`.
    nonisolated static func trades(buys: [Log], sells: [Log], anchor: BlockHeader, pair: PairInfo, secondsPerBlock: Double) -> [CurveTrade] {
        var out: [CurveTrade] = []
        for log in buys {
            // Quote that moved the reserves: the input net of fee and tax.
            guard let fill = LaunchpadABI.fill(log) else { continue }
            let fees = fill.fee + fill.tax
            let quote = fees > fill.amountIn ? 0 : fill.amountIn - fees
            out.append(trade(log, anchor: anchor, secondsPerBlock: secondsPerBlock, pair: pair, trader: fill.trader, isBuy: true, quote: quote, tokens: fill.amountOut))
        }
        for log in sells {
            // Gross quote before fees, which is what left the reserves.
            guard let fill = LaunchpadABI.fill(log) else { continue }
            out.append(trade(log, anchor: anchor, secondsPerBlock: secondsPerBlock, pair: pair, trader: fill.trader, isBuy: false, quote: fill.amountOut + fill.fee + fill.tax, tokens: fill.amountIn))
        }
        return out.sorted { a, b in a.block == b.block ? a.logIndex < b.logIndex : a.block < b.block }
    }

    private nonisolated static func trade(_ log: Log, anchor: BlockHeader, secondsPerBlock: Double, pair: PairInfo, trader: Address, isBuy: Bool, quote: BigUInt, tokens: BigUInt) -> CurveTrade {
        CurveTrade(
            id: log.id, block: log.blockNumber, logIndex: log.logIndex, time: time(anchor: anchor, block: log.blockNumber, secondsPerBlock: secondsPerBlock), trader: trader, isBuy: isBuy,
            quoteAmount: quote, tokenAmount: tokens, quoteDecimals: pair.decimals, price: price(quote: quote, tokens: tokens, quoteDecimals: pair.decimals)
        )
    }

    /// Quote per whole token in pair units: raw quote / raw tokens scaled by 10^(18 − quote decimals).
    nonisolated static func price(quote: BigUInt, tokens: BigUInt, quoteDecimals: Int) -> Double {
        guard tokens > 0 else { return 0 }
        return Double(quote) / Double(tokens) * pow(10, Double(18 - quoteDecimals))
    }

    /// Estimated timestamp of `block` (seconds since 1970, rounded) from a later block's and the pace
    /// (`BlockClock.time(of:anchor:secondsPerBlock:)`).
    nonisolated static func time(anchor: BlockHeader, block: UInt64, secondsPerBlock: Double) -> Int {
        Int(BlockClock.time(of: block, anchor: anchor, secondsPerBlock: secondsPerBlock).timeIntervalSince1970.rounded(.toNearestOrAwayFromZero))
    }

    /// OHLC candles from trades in `interval`-second buckets. Empty buckets between trades carry the previous
    /// close forward (capped at 2 000 candles) so the chart has no holes.
    nonisolated static func candles(from trades: [CurveTrade], interval: Int) -> [Candle] {
        guard interval > 0 else { return [] }
        var buckets: [Int: Candle] = [:]
        for trade in trades where trade.price > 0 {
            let bucket = Int((Double(trade.time) / Double(interval)).rounded(.down)) * interval
            let price = trade.price
            let volume = Amount.units(trade.quoteAmount, decimals: trade.quoteDecimals)
            if var candle = buckets[bucket] {
                candle.high = max(candle.high, price)
                candle.low = min(candle.low, price)
                candle.close = price
                candle.volume += volume
                buckets[bucket] = candle
            } else {
                buckets[bucket] = Candle(time: bucket, open: price, high: price, low: price, close: price, volume: volume)
            }
        }
        let sorted = buckets.values.sorted { $0.time < $1.time }
        var filled: [Candle] = []
        for (i, candle) in sorted.enumerated() {
            filled.append(candle)
            guard i + 1 < sorted.count else { break }
            let next = sorted[i + 1]
            var t = candle.time + interval
            while t < next.time, filled.count < 2000 {
                filled.append(Candle(time: t, open: candle.close, high: candle.close, low: candle.close, close: candle.close, volume: 0))
                t += interval
            }
        }
        return filled
    }
}
