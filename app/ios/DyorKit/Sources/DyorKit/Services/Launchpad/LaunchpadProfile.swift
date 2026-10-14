import BigInt
import Foundation

/* What My Launchpad reads for the coins a wallet holds, without a scan of its own: every launch coin's balance and every
   fee-sharing coin's holder rewards in one read (`LaunchpadService.holdings`), at a block it names, and each coin's profit
   and loss from the wallet's own curve fills, which its history already holds (`WalletHistorySnapshot.launch`), shown only
   once the history has read them all, from before the coin's launch up to the block the balance was read at
   (`WalletHistorySnapshot.fillsCoverage`). Nothing here is ever 0 for want of an answer: a balance or a reward that
   couldn't be read has none. */

/// What a wallet holds of each launch coin, and the holder rewards waiting for it on each coin that shares its fees, as
/// one read gave them (`LaunchpadService.holdings`) or a screen keeps them (`keeping`). Amounts are raw: a coin's balance
/// in its 18-decimal units, a reward in its coin's pair asset.
public struct LaunchHoldings: Sendable, Hashable, Codable {
    /// Each coin's balance, zero included; a coin whose balance couldn't be read, and that no earlier read kept, has none.
    public var balances: [Address: BigUInt]
    /// Each fee-sharing coin's pending holder rewards; a coin whose rewards couldn't be read, and that no earlier read
    /// kept, has none. A coin that doesn't share its fees has none either.
    public var rewards: [Address: BigUInt]
    /// The coins whose balance the latest read didn't answer: their balance, when they have one, is an earlier read's.
    public var balancesUnread: Set<Address>
    /// The fee-sharing coins whose rewards the latest read didn't answer: likewise kept from an earlier read, if any.
    public var rewardsUnread: Set<Address>
    /// The block the latest read that answered was read at (Multicall3's `getBlockNumber` in the same aggregate): every
    /// balance here is as of it or earlier, so a history whose head has reached it holds every fill behind them
    /// (`WalletHistorySnapshot.fillsCoverage`). Nil when no read named one.
    public var block: UInt64?

    public init(balances: [Address: BigUInt], rewards: [Address: BigUInt], balancesUnread: Set<Address> = [], rewardsUnread: Set<Address> = [], block: UInt64? = nil) {
        self.balances = balances
        self.rewards = rewards
        self.balancesUnread = balancesUnread
        self.rewardsUnread = rewardsUnread
        self.block = block
    }

    /// A read that got no answer at all, for `coins` and the fee-sharing `sharing` among them: every one unread.
    public static func unread(coins: [Address], sharing: [Address]) -> LaunchHoldings {
        LaunchHoldings(balances: [:], rewards: [:], balancesUnread: Set(coins), rewardsUnread: Set(sharing))
    }

    /// Every balance and every reward was read in the latest read.
    public var complete: Bool { balancesUnread.isEmpty && rewardsUnread.isEmpty }
    /// Some coin's balance was never read, now or before: what the wallet holds can't be counted or totalled in full.
    public var balancesMissing: Bool { balancesUnread.contains { balances[$0] == nil } }
    /// Some fee-sharing coin's rewards were never read, now or before.
    public var rewardsMissing: Bool { rewardsUnread.contains { rewards[$0] == nil } }

    /// `read` as a screen shows it: what it answered as read, and each balance or reward it didn't answer as `previous`
    /// had it (still unread, never zero, when `previous` had none). `previous` is the screen's last `keeping` for the SAME
    /// wallet: a caller passes nil once the wallet changed, so no wallet ever sees another's coins. The block is the read's,
    /// else `previous`'s (every balance kept is as of it or earlier).
    public static func keeping(_ read: LaunchHoldings, previous: LaunchHoldings?) -> LaunchHoldings {
        var kept = read
        guard let previous else { return kept }
        for coin in read.balancesUnread where kept.balances[coin] == nil { kept.balances[coin] = previous.balances[coin] }
        for coin in read.rewardsUnread where kept.rewards[coin] == nil { kept.rewards[coin] = previous.rewards[coin] }
        if kept.block == nil { kept.block = previous.block }
        return kept
    }

    /// The same holdings once the rewards of `coins` were claimed: none wait any more, so a later read that fails can't
    /// bring the claimed amount back as kept (`keeping`).
    public func claimed(_ coins: [Address]) -> LaunchHoldings {
        var after = self
        for coin in coins where after.rewards[coin] != nil { after.rewards[coin] = 0 }
        return after
    }
}

public extension LaunchpadService {
    /// What `account` holds of each of `launches`, and the holder rewards waiting for it on each that shares its fees
    /// (`pendingRewards` on the launch's own stack), in one read: a single aggregate of every balance and every reward,
    /// and the block it ran at (`Multicall.blockNumber`, `LaunchHoldings.block`). Throws when the aggregate itself gets no
    /// answer; a call in it that fails leaves its coin unread (`LaunchHoldings.balancesUnread`, `rewardsUnread`), never 0.
    func holdings(of launches: [Launch], account: Address) async throws -> LaunchHoldings {
        var seen = Set<Address>()
        let coins = launches.filter { seen.insert($0.token).inserted }
        let sharing = coins.compactMap { launch -> (coin: Address, contract: Address)? in
            let contract = stack(for: launch).holderFeeSharing
            return launch.holderFeeSharing && !contract.isZero ? (launch.token, contract) : nil
        }
        let calls = coins.map { LaunchpadABI.call($0.token, LaunchpadABI.Token.balanceOf, [.address(account)], returns: "uint256") }
            + sharing.map { LaunchpadABI.call($0.contract, LaunchpadABI.Sharing.pendingRewards, [.address($0.coin), .address(account)], returns: "uint256") }
        let results = try await multicall.read(calls + [Multicall.blockNumber])
        var held = Self.holdings(coins: coins.map(\.token), sharing: sharing.map(\.coin), results: Array(results.dropLast()))
        held.block = results.last.flatMap(Multicall.block)
        return held
    }

    /// Pure half of `holdings(of:account:)`: `results` answer each of `coins`' balance, then each of `sharing`'s rewards,
    /// in that order. A failed or malformed answer leaves its coin unread; a result list of the wrong length answers none.
    nonisolated static func holdings(coins: [Address], sharing: [Address], results: [Result<[ABIValue], Error>]) -> LaunchHoldings {
        guard results.count == coins.count + sharing.count else { return .unread(coins: coins, sharing: sharing) }
        var held = LaunchHoldings(balances: [:], rewards: [:])
        func amount(_ result: Result<[ABIValue], Error>) -> BigUInt? {
            guard case .success(let values) = result, case .uint(let value)? = values.first else { return nil }
            return value
        }
        for (coin, result) in zip(coins, results) {
            if let value = amount(result) { held.balances[coin] = value } else { held.balancesUnread.insert(coin) }
        }
        for (coin, result) in zip(sharing, results.dropFirst(coins.count)) {
            if let value = amount(result) { held.rewards[coin] = value } else { held.rewardsUnread.insert(coin) }
        }
        return held
    }
}

/// A held launch coin's profit and loss, in dollars, from the wallet's own fills on its curve
/// (`LaunchpadWalletHistory.pnl`).
public struct LaunchPositionPnL: Sendable, Hashable {
    public let usd: Double
    /// Against what the wallet put in on the curve; nil when it took out as much as it put in.
    public let percent: Double?

    public init(usd: Double, percent: Double?) {
        self.usd = usd
        self.percent = percent
    }
}

public extension LaunchpadWalletHistory {
    /// The wallet's profit and loss on the coin of `curve`: the holding's value now (`valueUSD`, as every screen values a
    /// launch coin, `DyorPrice.launch`) less what the wallet put in on the curve and didn't take out — every buy's gross
    /// quote paid less every sell's net quote received, in the pair asset (`pairDecimals`), at its dollar price today
    /// (`pairUSD`), realized and unrealized together. Nil without a fill on the curve (a coin bought on Swap or sent to
    /// the wallet has no curve cost), without a value, or without the pair's price: never a figure made up from part of
    /// it. Only as complete as the fills are: a caller shows it once they all are (`WalletHistorySnapshot.fillsCoverage`).
    func pnl(curve: Address, pairDecimals: Int, valueUSD: Double?, pairUSD: Double?) -> LaunchPositionPnL? {
        let mine = fills.filter { $0.curve == curve }
        guard !mine.isEmpty, let valueUSD, valueUSD.isFinite, let pairUSD = DyorPrice.valid(pairUSD) else { return nil }
        var paid = 0.0, received = 0.0
        for fill in mine {
            let quote = Amount.units(fill.quoteAmount, decimals: pairDecimals)
            if fill.isBuy { paid += quote } else { received += quote }
        }
        let cost = (paid - received) * pairUSD
        let usd = valueUSD - cost
        guard usd.isFinite else { return nil }
        return LaunchPositionPnL(usd: usd, percent: cost > 0 ? usd / cost * 100 : nil)
    }
}

/// How much of what a screen needs a wallet's history holds (`WalletHistorySnapshot.fillsCoverage`).
public enum HistoryCoverage: Sendable, Equatable {
    /// All of it: what the screen builds from it is final.
    case complete
    /// Still being read (or matched): what is held so far is part of it, shown as such or not at all.
    case reading
    /// It couldn't be read (the chain unreachable, the rounds stalled, or older logs dropped past the store's cap): the
    /// screen says so, with Retry.
    case unread
}

public extension WalletHistorySnapshot {
    /// Whether the launchpad scan holds every fill the wallet made on `curve`, a coin launched at `launchedAt` (seconds
    /// since 1970), up to the block its balance was read at (`through`, `LaunchHoldings.block`; nil: up to `now`). Complete
    /// once the curve is among those the fills were matched to (`curves`), the scan's head has reached that block
    /// (`HistoryStatus.isCurrent(through:at:)`) — a trade since the history last read would otherwise be in the balance
    /// and not in the cost, its whole value shown as profit — and the scan has read every block from before the coin's
    /// launch to its head in one piece (`HistoryStatus.covers(from:)`): the store reads newest first, so a young coin's
    /// fills are all held long before the scan reaches its floor. Reading while the scan reads on, or the curve waits to
    /// be matched; unread when the chain couldn't be reached or the rounds stalled. The launch's block is estimated early
    /// (`launchBlock`).
    func fillsCoverage(curve: Address, launchedAt: Int, secondsPerBlock: Double, through block: UInt64?, now: Date = Date()) -> HistoryCoverage {
        let status = status(WalletHistoryScans.launchpadId)
        let current = status.isCurrent(through: block, at: now)
        let covered = launchBlock(launchedAt: launchedAt, secondsPerBlock: secondsPerBlock).map { status.covers(from: $0) } ?? false
        return coverage(curves: [curve], covered: covered && current, current: current)
    }

    /// Whether the launchpad scan holds every fill the wallet made on `curves` over its whole window, up to the block the
    /// screen's balances were read at (`through`; nil: up to `now`), through the same gate as a holding's profit and loss
    /// (`HistoryStatus.isCurrent(through:at:)`), and its last refresh reached the chain: a feed of the wallet's own trades,
    /// shown as far as it is read, which says so until then — never "no activity" from a head read before the wallet's
    /// first trade.
    func fillsCoverage(curves: Set<Address>, through block: UInt64?, now: Date = Date()) -> HistoryCoverage {
        let status = status(WalletHistoryScans.launchpadId)
        let current = status.isCurrent(through: block, at: now)
        return coverage(curves: curves, covered: status.complete && current && status.reachedChain, current: current)
    }

    /// How far the launchpad scan has read what a coin's profit and loss waits for (`fillsCoverage(curve:…)`), 0 to 1: the
    /// blocks from the coin's launch to the head (`HistoryStatus.progress(from:)`), short of 1 (`readingCap`) until the
    /// head reaches `through` (or, with none, while it isn't recent): never "100%" beside a figure still waited for.
    func fillsProgress(launchedAt: Int, secondsPerBlock: Double, through block: UInt64?, now: Date = Date()) -> Double {
        let status = status(WalletHistoryScans.launchpadId)
        let read = launchBlock(launchedAt: launchedAt, secondsPerBlock: secondsPerBlock).map { status.progress(from: $0) } ?? 0
        return status.isCurrent(through: block, at: now) ? read : min(read, Self.readingCap)
    }

    /// How far the launchpad scan has read what the activity feed waits for (`fillsCoverage(curves:…)`): its whole window,
    /// short of 1 (`readingCap`) until the head reaches `through` (or, with none, while it isn't recent).
    func fillsProgress(through block: UInt64?, now: Date = Date()) -> Double {
        let status = status(WalletHistoryScans.launchpadId)
        return status.isCurrent(through: block, at: now) ? status.progress : min(status.progress, Self.readingCap)
    }

    /// The block a coin launched at `launchedAt` (seconds since 1970) was launched in, estimated early from the head the
    /// history last read (`anchor`): its age a quarter longer at `secondsPerBlock`, plus
    /// `LaunchpadService.tradeLookbackMargin`, so a chain a little faster than measured still puts the launch after it;
    /// never before the first launchpad's block (`LaunchpadAddresses.feeHistoryStart`), before which no DyorHQ curve
    /// traded (`LaunchpadService.launchBlock`, which the coin's holder count reads from too). Nil before the history read
    /// any head.
    func launchBlock(launchedAt: Int, secondsPerBlock: Double) -> UInt64? {
        guard let anchor else { return nil }
        return LaunchpadService.launchBlock(launchedAt: launchedAt, anchor: anchor, secondsPerBlock: secondsPerBlock)
    }

    private func coverage(curves: Set<Address>, covered: Bool, current: Bool) -> HistoryCoverage {
        // A curve the fills weren't matched to is matched when the history is built again with it (`HistoryModel`).
        guard curves.isSubset(of: self.curves) else { return .reading }
        if covered { return .complete }
        let status = status(WalletHistoryScans.launchpadId)
        return status.reachedChain && (!status.complete || !current) ? .reading : .unread
    }
}
