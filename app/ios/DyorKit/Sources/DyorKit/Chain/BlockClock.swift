import Foundation

/// Monad's pace, measured rather than assumed. Monad makes a block about every 0.3023 s (24 hours is about 285,800
/// blocks), not the 0.4 s the app once hard-coded, which made every "24h" about 18 hours. A clock reads the chain's own
/// headers once a session: the latest block and the one `sampleBlocks` before it, and their timestamps give the seconds
/// per block (`secondsPerBlock()`). When those reads fail, it says `fallbackSecondsPerBlock` and tries again a minute
/// later.
///
/// Every time the app shows or claims goes through a clock: the 24h change and its day-ago block (`block(at:)`, which
/// reads the estimated block's timestamp and corrects the estimate once), a chart's span and its labels, the history
/// filters (24H, 7D, 30D) and every time estimated from a block number (`time(of:anchor:secondsPerBlock:)`). Scan windows
/// that are really block budgets keep their block counts, under names that say so
/// (`WalletTokenDiscovery.defaultWindowBlocks`, `TokenActivityService.defaultLookbackBlocks`,
/// `SwapHistoryService.Window.allBlocks`); a coin's holders are read from its launch (`LaunchpadService.launchBlock`).
public actor BlockClock {
    /// The rate used until a measurement answers, and whenever one fails: Monad's average over a million blocks
    /// (measured 2026-09-29).
    public static let fallbackSecondsPerBlock = 0.3023
    /// How far apart the two headers a measurement reads are: 100,000 blocks, about 8.4 hours, so the one-second grain
    /// of a block timestamp moves the rate by about 0.001%.
    public static let sampleBlocks: UInt64 = 100_000
    /// After a measurement fails, how long readers get the fallback before the next one tries again.
    public static let retryAfter: TimeInterval = 60
    /// A rate outside this range is a node answering wrongly, never Monad's pace: the measurement counts as failed.
    static let plausible: ClosedRange<Double> = 0.05...5

    public let rpc: RPCClient
    /// The chain head, read once for every reader that asks within a moment (`HeadClock`): this clock's own reads of it,
    /// and those of every service the session's clock is handed to — prices (the day-ago block, charts) and the wallet's
    /// history rounds.
    public nonisolated let head: HeadClock
    private let sampleBlocks: UInt64
    private let now: @Sendable () -> Date
    private var measured: Double?
    private var failedAt: Date?
    private var measuring: Task<Double?, Never>?

    /// A clock for the chain `rpc` reads. `now` is the device clock, only used to space out retries and to age a head.
    /// `head`: where the latest header comes from (nil: a `HeadClock` of `rpc`).
    public init(rpc: RPCClient, sampleBlocks: UInt64 = BlockClock.sampleBlocks, now: @escaping @Sendable () -> Date = Date.init, head: HeadClock? = nil) {
        self.rpc = rpc
        self.head = head ?? HeadClock(rpc: rpc, now: now)
        self.sampleBlocks = max(1, sampleBlocks)
        self.now = now
    }

    /// A clock that already knows the rate, as a test or a fork rehearsal sets it: it never reads headers for it.
    init(rpc: RPCClient, measured secondsPerBlock: Double) {
        self.rpc = rpc
        head = HeadClock(rpc: rpc)
        sampleBlocks = Self.sampleBlocks
        now = Date.init
        measured = secondsPerBlock
    }

    /// Whether the rate came from the chain this session, rather than the fallback.
    public var isMeasured: Bool { measured != nil }

    /// The rate known now, with no read: the one measured this session, else `fallbackSecondsPerBlock`. Never starts a
    /// measurement — for what must not wait on the network (the wallet's history read from the device at launch, which
    /// is timed again once a measurement answers).
    public var knownSecondsPerBlock: Double { measured ?? Self.fallbackSecondsPerBlock }

    /// Seconds per block: measured once a session from two block headers and kept; the fallback while a measurement
    /// fails, measured again on the first call `retryAfter` seconds later. Callers that arrive while a measurement is
    /// under way wait for it rather than start another.
    public func secondsPerBlock() async -> Double {
        if let measured { return measured }
        if let failedAt, now().timeIntervalSince(failedAt) < Self.retryAfter { return Self.fallbackSecondsPerBlock }
        if let measuring { return await measuring.value ?? Self.fallbackSecondsPerBlock }
        let rpc = rpc, head = head, sampleBlocks = sampleBlocks
        let task = Task { await Self.measure(rpc: rpc, head: head, sampleBlocks: sampleBlocks) }
        measuring = task
        let rate = await task.value
        measuring = nil
        if let rate {
            measured = rate
            failedAt = nil
        } else if measured == nil {
            failedAt = now()
        }
        return measured ?? Self.fallbackSecondsPerBlock
    }

    /// The blocks in `seconds` at the session's rate, rounded up.
    public func blocks(in seconds: TimeInterval) async -> UInt64 {
        Self.blocks(in: seconds, secondsPerBlock: await secondsPerBlock())
    }

    /// The block mined closest to `date`, from `head` (the latest block, from `HeadClock` when not given). The first
    /// estimate counts back from the head at the session's rate; then that block's own timestamp is read and the estimate
    /// moved once by what it is off, so a pace that changed over the day (a slower hour) doesn't show in a 24h change. When
    /// that second read fails the first estimate stands. A date at or after the head's is the head. Throws only when the
    /// head can't be read.
    public func block(at date: Date, head: BlockHeader? = nil) async throws -> UInt64 {
        let anchor: BlockHeader
        if let head { anchor = head } else { anchor = try await self.head.latest() }
        let rate = await secondsPerBlock()
        let target = date.timeIntervalSince1970
        let estimate = Self.estimate(target: target, anchor: anchor, secondsPerBlock: rate)
        guard estimate < anchor.number, let header = try? await rpc.block(.number(estimate)) else { return estimate }
        return Self.corrected(header: header, target: target, secondsPerBlock: rate, head: anchor.number)
    }

    // MARK: Pure

    /// The rate two headers give, newer first; nil when they don't make one (the same block, time running backwards, or
    /// a rate outside `plausible`).
    public static func rate(newer: BlockHeader, older: BlockHeader) -> Double? {
        guard newer.number > older.number, newer.timestamp > older.timestamp else { return nil }
        let rate = Double(newer.timestamp - older.timestamp) / Double(newer.number - older.number)
        return plausible.contains(rate) ? rate : nil
    }

    /// The blocks in `seconds` at `secondsPerBlock`, rounded up; 0 for no time.
    public static func blocks(in seconds: TimeInterval, secondsPerBlock: Double) -> UInt64 {
        guard seconds > 0, secondsPerBlock > 0, seconds.isFinite else { return 0 }
        let blocks = (seconds / secondsPerBlock).rounded(.up)
        return blocks >= Double(UInt64.max) ? UInt64.max : UInt64(blocks)
    }

    /// When `block` was mined, estimated from `anchor` (a later block whose timestamp is known) at `secondsPerBlock`. A
    /// block after the anchor is given the anchor's time.
    public static func time(of block: UInt64, anchor: BlockHeader, secondsPerBlock: Double) -> Date {
        let back = Double(anchor.number > block ? anchor.number - block : 0) * secondsPerBlock
        return Date(timeIntervalSince1970: TimeInterval(anchor.timestamp) - back)
    }

    /// When `log`'s block was mined: the block's own timestamp when the endpoint gave it (`Log.blockTimestamp`), exact;
    /// else estimated from `anchor` at `secondsPerBlock` (`time(of:anchor:secondsPerBlock:)`).
    public static func time(of log: Log, anchor: BlockHeader, secondsPerBlock: Double) -> Date {
        if let timestamp = log.blockTimestamp { return Date(timeIntervalSince1970: TimeInterval(timestamp)) }
        return time(of: log.blockNumber, anchor: anchor, secondsPerBlock: secondsPerBlock)
    }

    /// The first estimate of `block(at:)`: the block `target` seconds (since 1970) falls in, counting back from `anchor`.
    static func estimate(target: TimeInterval, anchor: BlockHeader, secondsPerBlock: Double) -> UInt64 {
        let back = ((Double(anchor.timestamp) - target) / secondsPerBlock).rounded(.toNearestOrAwayFromZero)
        guard back > 0, secondsPerBlock > 0 else { return anchor.number }
        return back >= Double(anchor.number) ? 0 : anchor.number - UInt64(back)
    }

    /// The estimate moved once: `header` is the block first estimated, and the difference between its timestamp and
    /// `target`, in blocks, is added to it, kept between block 0 and `head`.
    static func corrected(header: BlockHeader, target: TimeInterval, secondsPerBlock: Double, head: UInt64) -> UInt64 {
        guard secondsPerBlock > 0 else { return min(header.number, head) }
        let moved = Double(header.number) + ((target - Double(header.timestamp)) / secondsPerBlock).rounded(.toNearestOrAwayFromZero)
        if moved <= 0 { return 0 }
        return moved >= Double(head) ? head : UInt64(moved)
    }

    /// One measurement: the latest header (`HeadClock`) and the one `sampleBlocks` before it (or block 0 on a younger
    /// chain).
    private static func measure(rpc: RPCClient, head clock: HeadClock, sampleBlocks: UInt64) async -> Double? {
        guard let head = try? await clock.latest(), head.number > 0 else { return nil }
        let back = min(sampleBlocks, head.number)
        guard let older = try? await rpc.block(.number(head.number - back)) else { return nil }
        return rate(newer: head, older: older)
    }
}
