import BigInt
import Foundation

/* The wallet's history as the screens read it: five scans kept on the device (`HistoryStore`), each refreshed
   incrementally, and turned into the records the Portfolio, the activity feeds, My Launchpad, My Moments and the Send
   sheet show — swaps, curve fills, fees received, Moments collects and proceeds, the tokens that ever paid the wallet.
   `cached` builds them from what is held, with no network at all — the scans, each transaction's facts and the pace as
   known, from the device — `completed` with the facts it lacks read, and `refresh` reads on within a budget and builds
   them again. Every record's time is its block's own when the log carries it (`Log.blockTimestamp`), else estimated from
   the head the entry last read, so a cached history keeps its times offline. */

/// The wallet's scans. Every DyorHQ event names the wallet as an indexed topic, so each scan is one filter.
public enum WalletHistoryScans {
    /// How far back the transfer scans read at least: 30 days at Monad's pace — further, to the wallet's first
    /// transaction, once that is known (`WalletHistoryService`), so every swap the wallet ever made counts.
    public static let transferDays: TimeInterval = 30 * 86_400
    static let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    public static var transferBlocks: UInt64 { BlockClock.blocks(in: transferDays, secondsPerBlock: BlockClock.fallbackSecondsPerBlock) }
    public static var transferFloor: HistoryScan.Floor { .blocks(transferBlocks) }

    public static let transfersInId = "transfers-in"
    public static let transfersOutId = "transfers-out"
    public static let launchpadId = "launchpad"
    public static let feeSharingId = "fee-sharing"
    public static let momentsId = "moments"

    /// Every ERC-20 `Transfer` into the wallet: swaps' received legs, and every token that ever paid it.
    public static func transfersIn(wallet: Address, floor: HistoryScan.Floor = transferFloor) -> HistoryScan {
        HistoryScan(id: transfersInId, query: LogsQuery(addresses: [], topics: [[transferTopic], nil, [wallet.data.leftPadded(to: 32)]]), floor: floor)
    }

    /// Every ERC-20 `Transfer` out of the wallet: swaps' spent legs.
    public static func transfersOut(wallet: Address, floor: HistoryScan.Floor = transferFloor) -> HistoryScan {
        HistoryScan(id: transfersOutId, query: LogsQuery(addresses: [], topics: [[transferTopic], [wallet.data.leftPadded(to: 32)]]), floor: floor)
    }

    /// The wallet's curve fills (`CurveBuy` / `CurveSell` index the trader first) and the creator fees an escrow paid it
    /// or it claimed (the escrow indexes the recipient first), on every launchpad stack, from the first escrow's block.
    /// No address filter: a curve is one of hundreds; the records are matched to the stacks' curves and escrows.
    public static func launchpad(wallet: Address) -> HistoryScan {
        let events = LaunchpadABI.Events.self
        return HistoryScan(id: launchpadId,
                           query: LogsQuery(addresses: [], topics: [[events.buyTopic, events.sellTopic, events.escrowPaidTopic, events.escrowPaidTokenTopic, events.escrowClaimedTopic, events.escrowClaimedTokenTopic],
                                                                      [wallet.data.leftPadded(to: 32)]]),
                           floor: .block(LaunchpadAddresses.feeHistoryStart))
    }

    /// Holder rewards the wallet claimed from fee sharing (`Claimed(token, account, amount)` indexes the account second)
    /// on every stack.
    public static func feeSharing(wallet: Address, stacks: [LaunchpadAddresses]) -> HistoryScan {
        HistoryScan(id: feeSharingId, query: LogsQuery(addresses: unique(stacks.map(\.holderFeeSharing)), topics: [[LaunchpadABI.Events.sharingClaimedTopic], nil, [wallet.data.leftPadded(to: 32)]]),
                    floor: .block(LaunchpadAddresses.feeHistoryStart))
    }

    /// Everything the wallet did on Moments, in every cohort: collects, vesting claims, proceeds and pool-fee
    /// withdrawals, publishes. Each event indexes the wallet second; the emitting contract says which cohort.
    public static func moments(wallet: Address, cohorts: [MomentsAddresses]) -> HistoryScan {
        let events = MomentsABI.Events.self
        let deployed = cohorts.filter(\.isDeployed)
        let contracts = unique(deployed.flatMap { [$0.factory, $0.collect, $0.vesting, $0.hook] }.filter { !$0.isZero })
        return HistoryScan(id: momentsId, query: LogsQuery(addresses: contracts, topics: [[events.collectedTopic, events.claimedTopic, events.withdrawnTopic, events.feesWithdrawnTopic, events.publishedTopic], nil,
                                                                                           [wallet.data.leftPadded(to: 32)]]),
                           floor: .block(deployed.map(\.deployBlock).min() ?? 0))
    }

    static func unique(_ list: [Address]) -> [Address] {
        var seen = Set<Address>()
        return list.filter { !$0.isZero && seen.insert($0).inserted }
    }
}

/// How often the app reads the wallet's history on (`HistoryModel`), and so how long what a scan last read counts as up
/// to now: in one place, so the app's rounds and the screens' sense of "up to date" can't drift apart.
public enum HistoryCadence {
    /// Between rounds once the history is complete: the new blocks only (`HistoryModel.topUpPause`).
    public static let topUpPause: TimeInterval = 90
    /// What one round may spend reading, per scan (`HistoryModel.roundBudget`).
    public static let roundSeconds: TimeInterval = 30
    /// How long after a scan last read the chain what it holds still counts as up to now (`HistoryStatus.isRecent`): a
    /// top-up's wait and a round's reading, and half as long again to spare (a round slowed by the gate, a node a little
    /// behind). A scan older than that has stopped — read from the device at launch, the app away, the rounds waiting out
    /// failures — and a trade since may be missing from it.
    public static let freshFor: TimeInterval = (topUpPause + roundSeconds) * 1.5
}

/// How far one scan has got.
public struct HistoryStatus: Sendable, Equatable {
    /// Every block from the floor to the head read.
    public let complete: Bool
    /// How much of them was, 0 to 1.
    public let progress: Double
    /// The last refresh reached the chain (false: it couldn't, and nothing moved).
    public let reachedChain: Bool
    public let updatedAt: Date?
    /// The scan's window at the last refresh: the oldest block it reads, and the head.
    public let floor: UInt64?
    public let head: UInt64?
    /// The oldest block read in one piece with the head (`HistoryEntry.covered`): the store reads newest first, so
    /// everything the scan finds from here to the head is already held, whatever is still to be read below it. Nil when
    /// the head itself wasn't read.
    public let coveredFrom: UInt64?
    /// The blocks read, merged, ascending (`HistoryEntry.covered`): how much of a window is read (`progress(from:)`).
    let covered: [ClosedRange<UInt64>]

    init(_ entry: HistoryEntry) {
        complete = entry.complete
        progress = entry.progress
        reachedChain = entry.reachedChain
        updatedAt = entry.updatedAt
        floor = entry.floor
        head = entry.head
        coveredFrom = entry.head.flatMap { head in entry.covered.first { $0.contains(head) }?.lowerBound }
        covered = entry.covered
    }

    /// A state as given (tests, `unreached`): `covered` nil reads as the blocks from `coveredFrom` to the head alone.
    init(complete: Bool, progress: Double, reachedChain: Bool, updatedAt: Date?, floor: UInt64?, head: UInt64?, coveredFrom: UInt64? = nil, covered: [ClosedRange<UInt64>]? = nil) {
        self.complete = complete
        self.progress = progress
        self.reachedChain = reachedChain
        self.updatedAt = updatedAt
        self.floor = floor
        self.head = head
        self.coveredFrom = coveredFrom
        if let covered {
            self.covered = covered
        } else if let coveredFrom, let head, coveredFrom <= head {
            self.covered = [coveredFrom...head]
        } else {
            self.covered = []
        }
    }

    public static let none = HistoryStatus(.empty)

    /// Whether every block from `block` to the head has been read in one piece (`coveredFrom`), so the scan holds all it
    /// finds from `block` on. False while the head itself is unread.
    public func covers(from block: UInt64) -> Bool {
        guard let coveredFrom else { return false }
        return coveredFrom <= block
    }

    /// Whether the scan holds all it finds in a window from `block` to its head: read in one piece down to `block`
    /// (`covers(from:)`), or its whole window read (`complete`) — the scan never reads below its floor, so a window that
    /// starts below it is as read as it will ever be. `block` nil: the whole window (All), read once the scan is complete.
    public func holds(from block: UInt64?) -> Bool {
        if complete { return true }
        guard let block else { return false }
        return covers(from: block)
    }

    /// How much of a window from `block` to the head has been read, 0 to 1: of the blocks from `block` (or the floor,
    /// when that is later) to the head, the share read, gaps and all. `block` nil, at or below the floor: the whole
    /// window's (`progress`). A window past the head (a head read before the window began) is read as far as the head
    /// goes once the head is; a window that ends now is never all read while the head is old, which the history's own
    /// share caps (`WalletHistorySnapshot.progress(from:scans:now:)`, `isCurrent`).
    public func progress(from block: UInt64?) -> Double {
        guard let block, let floor, block > floor else { return progress }
        guard let head else { return 0 }
        guard head >= block else { return covers(from: block) ? 1 : 0 }
        let read = covered.reduce(UInt64(0)) { total, range in
            let low = max(range.lowerBound, block), high = min(range.upperBound, head)
            return high >= low ? total + (high - low + 1) : total
        }
        return min(1, Double(read) / Double(head - block + 1))
    }

    /// Whether the scan last read the chain recently enough that what it holds runs up to `now` (`HistoryCadence.freshFor`):
    /// false for a scan read from the device at launch until a round reads it again, and for one whose rounds stopped.
    public func isRecent(at now: Date) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= HistoryCadence.freshFor
    }

    /// Whether what the scan holds runs as far as a figure built beside it: its head at or after `block`, the block that
    /// figure was read at (a balance, `LaunchHoldings.block`), so every record behind it is held; with no block, up to now
    /// (`isRecent`). The one gate every window's "final" goes through — a period's figures (`WalletHistorySnapshot.covers`),
    /// a holding's profit and loss and My Launchpad's activity (`fillsCoverage`) — so they can't drift apart. The blocks
    /// below the head are what `holds(from:)` and `covers(from:)` say.
    public func isCurrent(through block: UInt64? = nil, at now: Date) -> Bool {
        guard let block else { return isRecent(at: now) }
        return head.map { $0 >= block } ?? false
    }

    /// The same state, said not to have reached the chain: a scan left behind when rounds of reading stop short.
    func unreached() -> HistoryStatus {
        HistoryStatus(complete: complete, progress: progress, reachedChain: false, updatedAt: updatedAt, floor: floor, head: head, coveredFrom: coveredFrom, covered: covered)
    }
}

/// The wallet's history as the screens read it, from the five scans.
public struct WalletHistorySnapshot: Sendable {
    /// The head the records' times are estimated from; nil before any scan read the chain.
    public var anchor: BlockHeader?
    public var swaps: [SwapRecord]
    public var launch: LaunchpadWalletHistory
    public var feeIncome: LaunchpadFeeIncome
    public var moments: MomentsAccountHistory
    /// Every `Transfer` into the wallet, for what it holds (`WalletTokenDiscovery.held`).
    public var transfersIn: [Log]
    /// Each scan's state, by its id.
    public var status: [String: HistoryStatus]
    /// The curves `launch.fills` were matched to (the launches the screens read, `WalletHistoryService.cached`): a fill on
    /// any other curve isn't among them yet, whatever the scans read.
    public var curves: Set<Address> = []
    /// The pace every record's time was estimated at from `anchor` (`BlockClock.secondsPerBlock`) when its log carried no
    /// timestamp of its own: with it, the block a period starts from (`block(since:)`) is estimated.
    public var secondsPerBlock = BlockClock.fallbackSecondsPerBlock
    /// The blocks of the one-sided transactions in the transfer scans — only received legs, or only sent ones: a swap
    /// whose other leg is native MON, or a plain transfer — whose transaction isn't read yet
    /// (`SwapHistoryService.TransactionFacts`): they are left out of `swaps` until it is. The instant read from the device
    /// reads none (`WalletHistoryService.cached`); a build that reads reads `SwapHistoryService.factsPerBuild` at most, and
    /// one that couldn't leaves them for the next. A screen built from the swaps waits for those in its window (`covers`).
    public var unreadTransactionBlocks: [UInt64] = []
    /// Whether a build that reads would add to `swaps`: transactions left out (`unreadTransactionBlocks`), or sales into
    /// native MON whose MON isn't read yet (shown without an amount meanwhile, as an unknowable one is for good).
    public var swapFactsUnread = false
    /// How many of the transactions' facts it asked for the build of this snapshot read (`SwapHistoryService.Reconstruction`):
    /// nil when it asked for none — the instant read, nothing left out, or the swaps kept from a build before. 0 is an
    /// archive that isn't answering (`swapFactsFailed`).
    public var swapFactsRead: Int?
    /// Set on what the app publishes once rounds of reading stop short (`stalled`) while transactions are still left out:
    /// the swaps' windows aren't "being read" any more, and the screens say part couldn't be read, with Retry.
    public var swapFactsStalled = false

    /// The most a window still waited for shows as read (`progress(from:scans:now:)`): never 100% while part of it waits.
    public static let readingCap = 0.99

    public static let empty = WalletHistorySnapshot(anchor: nil, swaps: [], launch: .empty, feeIncome: LaunchpadFeeIncome(paid: [:], claimed: [:], rewardsClaimed: [:], complete: false),
                                                    moments: .empty, transfersIn: [], status: [:])

    public func status(_ id: String) -> HistoryStatus { status[id] ?? .none }
    /// Whether this snapshot holds what the store or a round read (each scan's state), rather than `empty`, the stand-in
    /// published before the store's instant read lands: a line saying how far the history has got waits for it, so it
    /// never flashes "0%" at launch.
    public var read: Bool { !status.isEmpty }
    /// Whether every scan has read its whole window.
    public var complete: Bool { WalletHistoryScans.ids.allSatisfy { status($0).complete } }
    /// Whether any scan is still behind, with the chain reachable: history is still filling in.
    public var filling: Bool { WalletHistoryScans.ids.contains { let s = status($0); return !s.complete && s.reachedChain } }
    /// How much of every scan's window has been read, 0 to 1.
    public var progress: Double { WalletHistoryScans.ids.reduce(0) { $0 + status($1).progress } / Double(WalletHistoryScans.ids.count) }
    /// Whether the last refresh of some scan couldn't reach the chain, or the rounds stopped short with transactions'
    /// facts still unread (`swapFactsStalled`).
    public var unreachable: Bool { swapFactsStalled || WalletHistoryScans.ids.contains { !status($0).reachedChain } }
    /// The build of this snapshot asked for transactions' facts and read none: a round that read nothing, for the app's
    /// rounds (`HistoryModel`), however complete the scans are.
    public var swapFactsFailed: Bool { swapFactsRead == 0 }

    // MARK: What a screen needs

    /* A screen needs only part of the history: the scans its figures are built from (`WalletHistoryScans.volume`,
       `activity`, `feeIncome`, `holdings`, `proceeds`), over its own period. The store reads newest first, so the
       last day is read in the first round and the last week soon after, long before every scan has read its whole window:
       each screen asks about its own window (`covers`), says "Reading your history" only while that isn't read, with how
       far it has got (`progress`), and takes a period's figure as final once it is. Every window ends now: a scan whose
       head is old (read from the device at launch, or the rounds stopped) holds none of them until a round reads it again
       (`HistoryStatus.isCurrent`), however far down it was read. */

    /// How much earlier than its estimate a period's window is taken to start (`block(since:)`): a record's time is its
    /// block's own when the log carries it (`Log.blockTimestamp`), while the block a period starts at is estimated at
    /// `secondsPerBlock`, which a pace that changed over the period puts a little late. Monad's pace over the last day,
    /// week and month differed by 0.15% at most (measured 2026-10-08); a hundredth of the window is ample.
    public static let periodMargin = 0.01

    /// The oldest block whose records may be timed at `date` or later: `date` counted back from `anchor` at
    /// `secondsPerBlock`, a hundredth of the window further (`periodMargin`) and a block early rather than late — where a
    /// period starting at `date` begins, never after its first record. Block 0 for a date before it; nil before any scan
    /// read a head.
    public func block(since date: Date) -> UInt64? {
        guard let anchor else { return nil }
        let seconds = TimeInterval(anchor.timestamp) - date.timeIntervalSince1970
        let back = BlockClock.blocks(in: seconds * (1 + Self.periodMargin), secondsPerBlock: secondsPerBlock)
        return back >= anchor.number ? 0 : anchor.number - back
    }

    /// Whether `scans` build the swaps (`WalletHistoryScans.swaps`) and the swaps still leave out a transaction from
    /// `block` on (nil: any) whose facts aren't read (`unreadTransactionBlocks`): until it is read, what they give for that
    /// window is a part.
    func swapsWait(from block: UInt64?, scans: [String]) -> Bool {
        guard !unreadTransactionBlocks.isEmpty, WalletHistoryScans.swaps.allSatisfy(scans.contains) else { return false }
        guard let block else { return true }
        return unreadTransactionBlocks.contains { $0 >= block }
    }

    /// Whether scan `id` holds all it finds in the window from `block` up to `now`: read there (`HistoryStatus.holds(from:)`),
    /// and up to now (`HistoryStatus.isCurrent`) — a window that ends now isn't held by a head read minutes ago.
    func holds(_ id: String, from block: UInt64?, now: Date) -> Bool {
        let status = status(id)
        return status.holds(from: block) && status.isCurrent(at: now)
    }

    /// Whether every scan of `scans` covers the window from `block` up to `now`: holds all it finds there, read in one
    /// piece down to `block` or complete, and recently (`holds(_:from:now:)`), and the swaps built from them leave nothing
    /// out there (`swapsWait`), so what they give for that window is final. `block` nil: their whole windows (All),
    /// covered once each is complete.
    public func covers(from block: UInt64?, scans: [String], now: Date = Date()) -> Bool {
        scans.allSatisfy { holds($0, from: block, now: now) } && !swapsWait(from: block, scans: scans)
    }

    /// Whether some scan of `scans` is still behind in the window from `block` (nil: its whole window) up to `now`, or the
    /// swaps built from them still leave out a transaction there (`swapsWait`), with the chain reachable: that window is
    /// still being read. A scan behind that couldn't reach the chain, or stalled, isn't, nor are transactions whose facts
    /// stalled (`swapFactsStalled`): `unreachable` says so instead.
    public func filling(from block: UInt64?, scans: [String], now: Date = Date()) -> Bool {
        if scans.contains(where: { status($0).reachedChain && !holds($0, from: block, now: now) }) { return true }
        return swapsWait(from: block, scans: scans) && !swapFactsStalled && WalletHistoryScans.swaps.allSatisfy { status($0).reachedChain }
    }

    /// How much of the window from `block` (nil: each scan's whole window) `scans` have read, 0 to 1, each counting the
    /// same (`HistoryStatus.progress(from:)`); short of 1 (`readingCap`) for a scan that doesn't hold the window yet
    /// (`holds(_:from:now:)`: part of it unread — however small a part — or its head old, until a round reads it again),
    /// and while the swaps built from them still leave a transaction out there (`swapsWait`). A share capped only for an
    /// old head printed "Reading your history… 100%" over a window of millions of blocks with its newest few hundred
    /// unread: the server's history adopted up to its trust margin, or the newest 600 left for rpc2 while it rests.
    public func progress(from block: UInt64?, scans: [String], now: Date = Date()) -> Double {
        guard !scans.isEmpty else { return 1 }
        let read = scans.reduce(0) { total, id in
            let share = status(id).progress(from: block)
            return total + (holds(id, from: block, now: now) ? share : min(share, Self.readingCap))
        } / Double(scans.count)
        return swapsWait(from: block, scans: scans) ? min(read, Self.readingCap) : read
    }

    /// `covers(from:scans:now:)` for a period starting at `date` (`block(since:)`); nil: All. Nothing is covered before a
    /// head was read.
    public func covers(since date: Date?, scans: [String], now: Date = Date()) -> Bool {
        guard let date else { return covers(from: nil, scans: scans, now: now) }
        guard let block = block(since: date) else { return false }
        return covers(from: block, scans: scans, now: now)
    }

    /// `filling(from:scans:now:)` for a period starting at `date` (`block(since:)`); nil: All.
    public func filling(since date: Date?, scans: [String], now: Date = Date()) -> Bool {
        guard let date else { return filling(from: nil, scans: scans, now: now) }
        guard let block = block(since: date) else { return scans.contains { status($0).reachedChain } }
        return filling(from: block, scans: scans, now: now)
    }

    /// `progress(from:scans:now:)` for a period starting at `date` (`block(since:)`); nil: All. Nothing is read before a
    /// head was.
    public func progress(since date: Date?, scans: [String], now: Date = Date()) -> Double {
        guard let date else { return progress(from: nil, scans: scans, now: now) }
        guard let block = block(since: date) else { return 0 }
        return progress(from: block, scans: scans, now: now)
    }

    /// Whether some scan of `scans` still reads its whole window, with the chain reachable: what a list of all a scan
    /// ever found waits for (the tokens that ever paid the wallet, `WalletTokens`), up to a bound. Unlike a figure up to
    /// now (`filling`), it doesn't wait for a round to read the blocks since a head read from the device: the list's next
    /// read adds what they hold.
    public func readingWindow(scans: [String]) -> Bool {
        scans.contains { let status = status($0); return status.reachedChain && !status.complete }
    }

    /// The same history, every scan still behind — or not read up to `now` (`HistoryStatus.isCurrent`) — said not to
    /// have reached the chain, and the transactions still left out said to have stalled (`swapFactsStalled`): what the
    /// app publishes when rounds of reading stop short (`HistoryModel`), so a screen says the rest couldn't be read, with
    /// Retry, rather than that it is still being read. Scans that read their whole window recently keep their state.
    public func stalled(now: Date = Date()) -> WalletHistorySnapshot {
        var copy = self
        for id in WalletHistoryScans.ids where !(status(id).complete && status(id).isCurrent(at: now)) { copy.status[id] = status(id).unreached() }
        copy.swapFactsStalled = !unreadTransactionBlocks.isEmpty
        return copy
    }
}

public extension WalletHistoryScans {
    static let ids = [transfersInId, transfersOutId, launchpadId, feeSharingId, momentsId]
    /// The scans the swaps are built from (`WalletHistorySnapshot.swaps`): a screen whose scans hold both reads the swaps,
    /// and waits for the transactions they still leave out (`WalletHistorySnapshot.unreadTransactionBlocks`).
    static let swaps = [transfersInId, transfersOutId]

    // The scans each screen's figures are built from: what it waits for, and no more (`WalletHistorySnapshot.covers`).

    /// Total Volume: the swaps (both transfer scans), the curve fills (launchpad) and the Moments collects. The holder
    /// rewards claimed (fee-sharing) count in fees received only, which the Portfolio shows and Home doesn't.
    static let volume = [transfersInId, transfersOutId, launchpadId, momentsId]
    /// The activity feed's backfill: the swaps and the curve fills.
    static let activity = [transfersInId, transfersOutId, launchpadId]
    /// The fees the wallet received on the launchpad (`WalletHistorySnapshot.feeIncome`): what the escrows paid it or it
    /// claimed, and the holder rewards it claimed.
    static let feeIncome = [launchpadId, feeSharingId]
    /// The tokens the wallet holds (My Holdings, the Send list): every transfer into it.
    static let holdings = [transfersInId]
    /// A creator's Moments proceeds (My Moments): the Moments scan alone.
    static let proceeds = [momentsId]
}

/// The reference a wallet's records were last matched with (`HistoryModel.setReference`): the launches' curves, whose
/// fills count, and the tokens' decimals, which weigh a swap's legs. Kept beside the wallet's scans
/// (`WalletHistoryService.keep(reference:wallet:)`), so the first snapshot after launch is right before the Portfolio
/// has read them again.
public struct WalletHistoryReference: Sendable, Equatable, Codable {
    public var curves: Set<Address>
    public var decimals: [Address: Int]

    public init(curves: Set<Address>, decimals: [Address: Int]) {
        self.curves = curves
        self.decimals = decimals
    }

    // Kept as hex text: `{"version":1,"curves":["0x…"],"decimals":{"0x…":6}}`, a curve or token that isn't an address
    // left out.
    private enum CodingKeys: String, CodingKey { case version, curves, decimals }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "another version")
        }
        curves = Set(try container.decode([String].self, forKey: .curves).compactMap(Address.init))
        var decimals: [Address: Int] = [:]
        for (token, places) in try container.decode([String: Int].self, forKey: .decimals) {
            if let token = Address(token) { decimals[token] = places }
        }
        self.decimals = decimals
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(curves.map(\.hex).sorted(), forKey: .curves)
        try container.encode(Dictionary(uniqueKeysWithValues: decimals.map { ($0.key.hex, $0.value) }), forKey: .decimals)
    }
}

/// Builds the wallet's history from the store, and refreshes it.
public actor WalletHistoryService {
    private let store: HistoryStore
    private let swapHistory: SwapHistoryService
    private let clock: BlockClock
    private let stacks: @Sendable () async -> [LaunchpadAddresses]
    private let cohorts: [MomentsAddresses]
    /// Swaps reconstructed from the same transfer logs are kept: the one-sided ones cost transaction reads.
    private var swapCache: [String: (fingerprint: String, swaps: [SwapRecord])] = [:]
    /// What the swap reconstruction looked up per transaction, by wallet (`SwapHistoryService.TransactionFacts`): loaded
    /// with the wallet's scans from beside them (`factsName`) and kept there after every build that read more, for the
    /// transactions the scans still hold.
    private var swapFacts: [String: [Data: SwapHistoryService.TransactionFacts]] = [:]
    /// The block of a wallet's first transaction (`RPCClient.firstTransactionBlock`): nil when it has sent none; throws
    /// when it couldn't be read, to be asked again.
    private let firstActivity: @Sendable (Address) async throws -> UInt64?
    /// What `firstActivity` found before, with no read (the app keeps it on the device): nil when it hasn't.
    private let knownFirstActivity: @Sendable (Address) -> UInt64?
    /// What `firstActivity` answered, by wallet: a block, or none (not kept: a wallet that sends its first
    /// transaction later is asked again). The device's own only: the one the server's history found is the store's
    /// (`HistoryStore.serverFirstTransaction(wallet:)`), dropped with the rest of what the server added.
    private var firstBlocks: [String: UInt64] = [:]
    /// The lookups of a first transaction under way, by wallet: one at a time, beside the rounds (`transferFloor`).
    private var firstLookups: [String: Task<Void, Never>] = [:]

    /// Where the facts are kept beside the scans (`HistoryStore.keep(_:named:wallet:since:)`), and the reference.
    static let factsName = "swap-facts"
    static let referenceName = "reference"

    /// `stacks`: every launchpad stack whose fills and fees count (the live one and the retired ones); `cohorts`: every
    /// Moments cohort, the live one first; `firstActivity`: the wallet's first transaction's block, for the transfer
    /// scans to read back to (nil, the default, keeps them to their window); `knownFirstActivity`: what it found before,
    /// read with no network, so a round never starts above a floor already known.
    public init(store: HistoryStore, swapHistory: SwapHistoryService, clock: BlockClock, stacks: @escaping @Sendable () async -> [LaunchpadAddresses], cohorts: [MomentsAddresses],
                firstActivity: @escaping @Sendable (Address) async throws -> UInt64? = { _ in nil }, knownFirstActivity: @escaping @Sendable (Address) -> UInt64? = { _ in nil }) {
        self.store = store
        self.swapHistory = swapHistory
        self.clock = clock
        self.stacks = stacks
        self.cohorts = cohorts
        self.firstActivity = firstActivity
        self.knownFirstActivity = knownFirstActivity
    }

    public var history: HistoryStore { store }

    /// The scans for `wallet`. `findingFirstTransaction`: whether the wallet's first transaction may be looked up for the
    /// transfer scans' floor (`transferFloor`) — a refresh starts the lookup beside its round and reads with the floor
    /// known now; the instant read of the store never starts one.
    public func scans(wallet: Address, findingFirstTransaction: Bool = true) async -> [HistoryScan] {
        let stacks = await stacks()
        let floor = await transferFloor(wallet, lookup: findingFirstTransaction)
        return [WalletHistoryScans.transfersIn(wallet: wallet, floor: floor), WalletHistoryScans.transfersOut(wallet: wallet, floor: floor), WalletHistoryScans.launchpad(wallet: wallet),
                WalletHistoryScans.feeSharing(wallet: wallet, stacks: stacks), WalletHistoryScans.moments(wallet: wallet, cohorts: cohorts)]
    }

    /// How far back the transfer scans read for `wallet`: to its first transaction when that is older than the usual
    /// window (`WalletHistoryScans.transferDays`), so every swap it ever made counts; the window alone when it never sent
    /// one, or until its first transaction's block is known. Never waits for it: a round reads at once with what is known
    /// (`knownFirstActivity`, or the server's history's, `HistoryStore.serverFirstTransaction(wallet:)`: the earlier of
    /// the two), and a lookup started beside it (`lookup`) when neither is deepens the floor from the next round on — the
    /// launchpad, fee-sharing and Moments scans never needed it, and the newest blocks come first either way. The server's
    /// dropped (an epoch reset, an erase, a spot check's mismatch), the device's own stands, or is looked up.
    private func transferFloor(_ wallet: Address, lookup: Bool) async -> HistoryScan.Floor {
        let key = wallet.hex.lowercased()
        let found = firstBlocks[key] ?? knownFirstActivity(wallet)
        if let found { firstBlocks[key] = found }
        let server = await store.serverFirstTransaction(wallet: wallet)
        if let first = [found, server].compactMap({ $0 }).min() {
            return .earliest(block: first, blocks: WalletHistoryScans.transferBlocks)
        }
        if lookup, firstLookups[key] == nil {
            firstLookups[key] = Task { await self.lookUpFirstTransaction(wallet) }
        }
        return WalletHistoryScans.transferFloor
    }

    /// One lookup of `wallet`'s first transaction (`firstActivity`): a block found is kept for the next round's floor; none,
    /// or a read that failed, is asked again at the next round. A block only ever moves earlier.
    private func lookUpFirstTransaction(_ wallet: Address) async {
        let key = wallet.hex.lowercased()
        if let first = try? await firstActivity(wallet) { firstBlocks[key] = min(first, firstBlocks[key] ?? first) }
        firstLookups[key] = nil
    }

    /// Waits for the lookup of `wallet`'s first transaction under way, if any (tests).
    func firstTransactionLookup(_ wallet: Address) async {
        await firstLookups[wallet.hex.lowercased()]?.value
    }

    /// The history from what is held, with no network at all: instant. The scans and each transaction's facts are read
    /// from the device; records are timed from the head the scans last read, at the pace measured this
    /// session or else `BlockClock.fallbackSecondsPerBlock` (never measured here); the swaps are built from the facts
    /// already known, and the transactions whose facts aren't are left out and said to be
    /// (`WalletHistorySnapshot.unreadTransactionBlocks`, `swapFactsUnread`) — `completed` reads them. `curves`: the curves
    /// whose fills count (every stack's launches); `decimals`: the tokens' decimals, for telling a swap's legs apart.
    public func cached(wallet: Address, curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        await built(wallet: wallet, curves: curves, decimals: decimals, reading: false)
    }

    /// `cached`, with what it leaves unread read now: the pace measured, the facts of the transactions the swaps lack
    /// (`SwapHistoryService.factsPerBuild` at most), the MON of the sales into it — no scan. What the app builds right
    /// after the instant read when that left something out, beside the rounds rather than after one.
    public func completed(wallet: Address, curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        await built(wallet: wallet, curves: curves, decimals: decimals, reading: true)
    }

    private func built(wallet: Address, curves: Set<Address>, decimals: [Address: Int], reading: Bool) async -> WalletHistorySnapshot {
        await snapshot(wallet: wallet, entries: await entries(wallet: wallet), curves: curves, decimals: decimals, reading: reading)
    }

    /// What the store holds of each of `wallet`'s scans, by id, from the device with no network (`HistoryStore.cached`):
    /// what the instant read builds from, and what decides whether the server's history is read (`ServerHistoryPlan`).
    public func entries(wallet: Address) async -> [String: HistoryEntry] {
        var entries: [String: HistoryEntry] = [:]
        for scan in await scans(wallet: wallet, findingFirstTransaction: false) { entries[scan.id] = await store.cached(scan, wallet: wallet) }
        return entries
    }

    /// Monad's pace as known now, with no read (`BlockClock.knownSecondsPerBlock`): how far the chain has moved since an
    /// entry's head, for the server's history (`ServerHistoryPlan.estimatedHead`).
    public var knownSecondsPerBlock: Double {
        get async { await clock.knownSecondsPerBlock }
    }

    /// The reference `wallet`'s records were last matched with, as kept beside its scans; nil when none was.
    public func reference(wallet: Address) async -> WalletHistoryReference? {
        await store.kept(WalletHistoryReference.self, named: Self.referenceName, wallet: wallet)
    }

    /// Keeps the reference `wallet`'s records are matched with now, beside its scans (`reference(wallet:)`) — unless the
    /// wallet was forgotten since `mark` (`erasureMark`), which the caller reads when it starts on the wallet, never when it
    /// writes: a write after an erase of this device's data would leave the wallet's folder behind.
    public func keep(reference: WalletHistoryReference, wallet: Address, since mark: Int) async {
        await store.keep(reference, named: Self.referenceName, wallet: wallet, since: mark)
    }

    /// The store's count of erasures so far (`HistoryStore.erasureMark`), for `keep(reference:wallet:since:)`.
    public var erasureMark: Int {
        get async { await store.erasureMark }
    }

    /// Forgets everything held for `wallet` (an erase of this device's data, or a spot check that found the server's
    /// history wrong): the store's entries and what is kept beside them — the server's first transaction with them
    /// (`HistoryStore.forget`) — and what was built from them here, the first transaction's block held in memory among
    /// it (the device's own, `knownFirstActivity`, is read again).
    public func forget(wallet: Address) async {
        swapCache[wallet.hex] = nil
        swapFacts[wallet.hex] = nil
        firstBlocks[wallet.hex.lowercased()] = nil
        await store.forget(wallet: wallet)
    }

    /// Takes in one read of the server's history of `wallet` (`HistoryServerClient`), made after `erasureToken` was taken
    /// (`HistoryStore.erasureToken()`) and under the owner's history epoch `epoch`: the wallet's first transaction first,
    /// when the server found one earlier than the one known, so the transfer scans keep what the read adds back to it
    /// (`adopt(firstTransaction:wallet:erasureToken:epoch:)`); then every scan the server served (`HistoryStore.adopt`),
    /// all at once, each after its own refresh under way. The
    /// chain's head is read first (`HistoryStore.latest`, one request): a scan whose head is past it speaks for blocks the
    /// device can't prove exist, and none is taken in when the head can't be read — the rounds read the chain as before.
    /// Nothing for another wallet's read, or a read of the metadata alone. The ids of the scans it took in.
    @discardableResult
    public func adopt(_ read: ServerHistoryRead, wallet: Address, erasureToken: Int, epoch: Int) async -> Set<String> {
        guard read.wallet == wallet, !read.metaOnly, let chainHead = await store.latest()?.number else { return [] }
        if case .found(let block) = read.firstTransaction { await adopt(firstTransaction: block, wallet: wallet, erasureToken: erasureToken, epoch: epoch) }
        let scans = await scans(wallet: wallet, findingFirstTransaction: false)
        return await withTaskGroup(of: String?.self) { group in
            for scan in scans {
                guard let server = read.scan(scan) else { continue }
                group.addTask { [store] in
                    await store.adopt(server, scan: scan, wallet: wallet, erasureToken: erasureToken, epoch: epoch, chainHead: chainHead) != nil ? scan.id : nil
                }
            }
            var adopted = Set<String>()
            for await id in group { if let id { adopted.insert(id) } }
            return adopted
        }
    }

    /// The wallet's first transaction as the server's history found it (`ServerFirstTransaction.found`, confirmed there
    /// on a second endpoint), read under the owner's history epoch `epoch`: kept in the store, apart from the device's own
    /// (`HistoryStore.adopt(firstTransaction:wallet:erasureToken:epoch:)`), when it is earlier than the one the device
    /// found, or that isn't known. A block only ever moves earlier, which only ever deepens the transfer scans' floor —
    /// more to read, never less — and it stays the server's: an epoch reset, an erase or a spot check's mismatch drops it,
    /// and the floor is the device's own again. Nothing is kept once this device's data was erased since `erasureToken`.
    func adopt(firstTransaction block: UInt64, wallet: Address, erasureToken: Int, epoch: Int) async {
        if let found = firstBlocks[wallet.hex.lowercased()] ?? knownFirstActivity(wallet), found <= block { return }
        await store.adopt(firstTransaction: block, wallet: wallet, erasureToken: erasureToken, epoch: epoch)
    }

    /// Reads on in every scan, each within `budget`, all at once through the gate in the history's lane (behind the screen
    /// the user is looking at, `LogsGate.Lane.history`), and builds the history again, the facts its swaps lack read. The
    /// chain head is read once for the round and handed to every scan (`HistoryStore.refresh(_:wallet:budget:at:)`): each
    /// reading its own was five identical requests a round to the logs endpoint, outside the gate. When no endpoint
    /// answers it, every scan says the chain wasn't reached, as each did when it asked on its own.
    public func refresh(wallet: Address, budget: LogsBudget, curves: Set<Address>, decimals: [Address: Int]) async -> WalletHistorySnapshot {
        let scans = await scans(wallet: wallet)
        let latest = await roundHead()
        let entries = await withTaskGroup(of: (String, HistoryEntry).self) { group in
            for scan in scans { group.addTask { [store] in (scan.id, await store.refresh(scan, wallet: wallet, budget: budget, at: latest)) } }
            var out: [String: HistoryEntry] = [:]
            for await (id, entry) in group { out[id] = entry }
            return out
        }
        return await snapshot(wallet: wallet, entries: entries, curves: curves, decimals: decimals, reading: true)
    }

    /// The head a round reads to: the session's shared head (`BlockClock.head`, `HeadClock`), on the app's endpoints with a
    /// read raced across them (`RPCClient.isRead`) where the logs endpoints were asked one after another; read anew for
    /// the round (`maxAge` 0), as a round started after a transaction settled must reach its block
    /// (`WalletHistorySnapshot.fillsCoverage`), and handed to the readers that ask in the next second. When the app's
    /// endpoints can't answer it, the logs endpoints' own (`HistoryStore.latest`); nil when neither does. The public
    /// endpoints' heads agree to the block (rpc.monad.xyz, rpc1, rpc2 and rpc3, read side by side 2026-10-10), and a range
    /// a node a few blocks behind refuses is asked again after a pause (`LogsRouter.headPause`).
    private func roundHead() async -> BlockHeader? {
        if let head = try? await clock.head.latest(maxAge: 0) { return head }
        return await store.latest()
    }

    /// The records built from `entries`. `reading`: the pace may be measured and the swaps' facts read; false, nothing is
    /// read (`cached`).
    private func snapshot(wallet: Address, entries: [String: HistoryEntry], curves: Set<Address>, decimals: [Address: Int], reading: Bool) async -> WalletHistorySnapshot {
        let stacks = await stacks()
        let secondsPerBlock = reading ? await clock.secondsPerBlock() : await clock.knownSecondsPerBlock
        // The newest head any scan read anchors every record's time.
        let anchor = entries.values.compactMap(\.anchor).max { $0.number < $1.number }
        var status: [String: HistoryStatus] = [:]
        for (id, entry) in entries { status[id] = HistoryStatus(entry) }
        let transfersIn = entries[WalletHistoryScans.transfersInId]?.logs ?? []
        let transfersOut = entries[WalletHistoryScans.transfersOutId]?.logs ?? []
        let launchpadLogs = entries[WalletHistoryScans.launchpadId]?.logs ?? []
        let sharingLogs = entries[WalletHistoryScans.feeSharingId]?.logs ?? []
        let momentsLogs = entries[WalletHistoryScans.momentsId]?.logs ?? []
        guard let anchor else {
            return WalletHistorySnapshot(anchor: nil, swaps: [], launch: .empty, feeIncome: WalletHistorySnapshot.empty.feeIncome, moments: .empty, transfersIn: transfersIn, status: status, curves: curves,
                                         secondsPerBlock: secondsPerBlock)
        }

        let swaps = await swaps(wallet: wallet, outgoing: transfersOut, incoming: transfersIn, anchor: anchor, secondsPerBlock: secondsPerBlock, decimals: decimals, reading: reading)
        let launch = Self.launch(launchpadLogs, sharing: sharingLogs, stacks: stacks, curves: curves, anchor: anchor, secondsPerBlock: secondsPerBlock)
        let income = Self.feeIncome(launchpadLogs, sharing: sharingLogs, stacks: stacks,
                                    complete: (entries[WalletHistoryScans.launchpadId]?.complete ?? false) && (entries[WalletHistoryScans.feeSharingId]?.complete ?? false))
        let moments = Self.moments(momentsLogs, cohorts: cohorts, anchor: anchor, secondsPerBlock: secondsPerBlock)
        return WalletHistorySnapshot(anchor: anchor, swaps: swaps.records, launch: launch, feeIncome: income, moments: moments, transfersIn: transfersIn, status: status, curves: curves,
                                     secondsPerBlock: secondsPerBlock, unreadTransactionBlocks: swaps.unreadBlocks, swapFactsUnread: swaps.unsettled, swapFactsRead: swaps.factsRead)
    }

    /// The facts `wallet`'s swaps were built with before: in memory, else kept beside its scans (`factsName`).
    private func facts(_ wallet: Address) async -> [Data: SwapHistoryService.TransactionFacts] {
        if let held = swapFacts[wallet.hex] { return held }
        var loaded: [Data: SwapHistoryService.TransactionFacts] = [:]
        if let kept = await store.kept(KeptFacts.self, named: Self.factsName, wallet: wallet), kept.version == KeptFacts.current {
            for (hex, fact) in kept.facts { if let hash = Data(hex: hex), hash.count == 32 { loaded[hash] = fact } }
        }
        // Another build may have loaded them meanwhile, and read more: its are kept.
        if let held = swapFacts[wallet.hex] { return held }
        swapFacts[wallet.hex] = loaded
        return loaded
    }

    /// The facts as kept beside the scans: by transaction hash (`0x…`).
    private struct KeptFacts: Codable, Sendable {
        static let current = 1
        var version = current
        var facts: [String: SwapHistoryService.TransactionFacts]
    }

    /// The swaps from the transfer scans; the blocks of the transactions they leave out for lack of facts; whether a
    /// build that reads would add to them (`WalletHistorySnapshot.swapFactsUnread`); and how many of the facts it asked for
    /// it read (nil: it asked for none, `WalletHistorySnapshot.swapFactsRead`). `reading` false reads nothing.
    private func swaps(wallet: Address, outgoing: [Log], incoming: [Log], anchor: BlockHeader, secondsPerBlock: Double, decimals: [Address: Int],
                       reading: Bool) async -> (records: [SwapRecord], unreadBlocks: [UInt64], unsettled: Bool, factsRead: Int?) {
        let fingerprint = Self.fingerprint(outgoing: outgoing, incoming: incoming, decimals: decimals)
        if let cached = swapCache[wallet.hex], cached.fingerprint == fingerprint {
            return (cached.swaps.map { $0.timed(anchor: anchor, secondsPerBlock: secondsPerBlock) }, [], false, nil)
        }
        // What was looked up per transaction before is kept: a build looks up the new transactions only, and the instant
        // read none.
        let mark = await store.erasureMark
        let known = await facts(wallet)
        let built = await swapHistory.reconstruct(wallet: wallet, outgoing: outgoing, incoming: incoming, anchor: anchor, secondsPerBlock: secondsPerBlock,
                                                  decimals: decimals, limit: 2_000, facts: known, reading: reading)
        let factsRead = built.factsAsked > 0 ? built.factsRead : nil
        // A sale into MON whose MON isn't read yet is read at a build that reads; one found unknowable never is.
        let unsettled = !built.unreadBlocks.isEmpty || built.records.contains { $0.boughtNativeUnknown && built.facts[$0.hash]?.nativeReceived != .unknowable }
        // Forgotten meanwhile (an erase of this device's data): nothing read before it is kept.
        guard await store.erasureMark == mark else { return (built.records, built.unreadBlocks, unsettled, factsRead) }
        // Added to what is kept now — another build may have kept more meanwhile, one that started from newer logs — and
        // pruned to the transactions the store's scans hold now, never to those this build's logs held: a build that
        // started from older logs (the instant read's completion racing a round) never drops what a newer one added. Kept
        // on the device when that changed something.
        let current = await transfers(wallet)
        let held = Set(current.outgoing.map(\.transactionHash)).union(current.incoming.map(\.transactionHash))
        let before = swapFacts[wallet.hex] ?? known
        var facts = before
        for (hash, fact) in built.facts { facts[hash] = facts[hash].map { $0.merged(with: fact) } ?? fact }
        facts = facts.filter { held.contains($0.key) }
        if facts != before {
            swapFacts[wallet.hex] = facts
            let kept = KeptFacts(facts: Dictionary(uniqueKeysWithValues: facts.map { ($0.key.hexString, $0.value) }))
            await store.keep(kept, named: Self.factsName, wallet: wallet, since: mark)
        }
        // The swaps are kept when nothing is left to read — every one-sided transaction's facts known, every sale into MON
        // read or found unknowable — and only when built from the logs the store holds now: an older build's never
        // replaces a newer one's.
        if !unsettled, Self.fingerprint(outgoing: current.outgoing, incoming: current.incoming, decimals: decimals) == fingerprint {
            swapCache[wallet.hex] = (fingerprint, built.records)
        }
        return (built.records, built.unreadBlocks, unsettled, factsRead)
    }

    /// The logs the swaps are built from and the decimals that weigh their legs, not the head: the same give the same
    /// swaps, timed from the newest head.
    private static func fingerprint(outgoing: [Log], incoming: [Log], decimals: [Address: Int]) -> String {
        "\(outgoing.count)-\(incoming.count)-\(outgoing.last?.id ?? "")-\(incoming.last?.id ?? "")-\(decimals.hashValue)"
    }

    /// The transfer scans' logs as the store holds them now, whatever a build started from.
    private func transfers(_ wallet: Address) async -> (outgoing: [Log], incoming: [Log]) {
        let outgoing = await store.cached(WalletHistoryScans.transfersOut(wallet: wallet), wallet: wallet).logs
        let incoming = await store.cached(WalletHistoryScans.transfersIn(wallet: wallet), wallet: wallet).logs
        return (outgoing, incoming)
    }

    /// The launchpad records from the launchpad and fee-sharing scans: fills on the stacks' curves, and fees from their
    /// escrows and fee-sharing contracts only (an unrelated contract may emit an event of the same shape).
    nonisolated static func launch(_ logs: [Log], sharing: [Log], stacks: [LaunchpadAddresses], curves: Set<Address>, anchor: BlockHeader, secondsPerBlock: Double) -> LaunchpadWalletHistory {
        let events = LaunchpadABI.Events.self
        let escrows = Set(stacks.map(\.escrow))
        let sharings = Set(stacks.map(\.holderFeeSharing))
        func those(_ topic: Data, of set: Set<Address>? = nil) -> [Log] { logs.filter { $0.topics.first == topic && (set == nil || set!.contains($0.address)) } }
        return LaunchpadService.walletHistory(buys: those(events.buyTopic), sells: those(events.sellTopic),
                                              escrowNative: those(events.escrowClaimedTopic, of: escrows), escrowToken: those(events.escrowClaimedTokenTopic, of: escrows),
                                              sharing: sharing.filter { sharings.contains($0.address) },
                                              paid: those(events.escrowPaidTopic, of: escrows), paidToken: those(events.escrowPaidTokenTopic, of: escrows),
                                              anchor: anchor, secondsPerBlock: secondsPerBlock, curves: curves)
    }

    /// What the wallet received in launchpad fees, from the same scans (`LaunchpadService.feeIncome`).
    nonisolated static func feeIncome(_ logs: [Log], sharing: [Log], stacks: [LaunchpadAddresses], complete: Bool) -> LaunchpadFeeIncome {
        let escrows = Set(stacks.map(\.escrow))
        let sharings = Set(stacks.map(\.holderFeeSharing))
        let income = LaunchpadService.feeIncome(escrowLogs: logs.filter { escrows.contains($0.address) }, sharingLogs: sharing.filter { sharings.contains($0.address) })
        return LaunchpadFeeIncome(paid: income.paid, claimed: income.claimed, rewardsClaimed: income.rewardsClaimed, complete: complete)
    }

    /// The Moments records from the Moments scan, each cohort's from its own contracts.
    nonisolated static func moments(_ logs: [Log], cohorts: [MomentsAddresses], anchor: BlockHeader, secondsPerBlock: Double) -> MomentsAccountHistory {
        let events = MomentsABI.Events.self
        var histories: [MomentsAccountHistory] = []
        for cohort in cohorts where cohort.isDeployed {
            func those(_ topic: Data, from contract: Address) -> [Log] { logs.filter { $0.address == contract && $0.topics.first == topic } }
            histories.append(MomentsService.history(collected: those(events.collectedTopic, from: cohort.collect), claimed: those(events.claimedTopic, from: cohort.vesting),
                                                    withdrawn: those(events.withdrawnTopic, from: cohort.collect), feesWithdrawn: those(events.feesWithdrawnTopic, from: cohort.hook),
                                                    published: those(events.publishedTopic, from: cohort.factory), anchor: anchor, secondsPerBlock: secondsPerBlock, factory: cohort.factory))
        }
        return MomentsAccountHistory.merged(histories)
    }

    /// The logs of the Moments scan for one cohort, for its creator earnings (`MomentsService.creatorEarnings(account:logs:)`).
    public func momentsLogs(wallet: Address, cohort: MomentsAddresses) async -> (published: [Log], withdrawn: [Log], feesWithdrawn: [Log], complete: Bool) {
        let entry = await store.cached(WalletHistoryScans.moments(wallet: wallet, cohorts: cohorts), wallet: wallet)
        let events = MomentsABI.Events.self
        func those(_ topic: Data, from contract: Address) -> [Log] { entry.logs.filter { $0.address == contract && $0.topics.first == topic } }
        return (those(events.publishedTopic, from: cohort.factory), those(events.withdrawnTopic, from: cohort.collect), those(events.feesWithdrawnTopic, from: cohort.hook), entry.complete)
    }
}
