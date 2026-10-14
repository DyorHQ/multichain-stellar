import Foundation

/// The chain head, read once for every reader that asks within a moment (speed work, 2026-10-10): the price reads (the
/// day-ago block and every chart, `PriceService`), the block clock (`BlockClock`) and the wallet's history rounds
/// (`WalletHistoryService.refresh`) each read the latest header on their own, often in the same second, each read a
/// round trip on the critical path of the screen that made it. One clock per chain, the session's `BlockClock.head`.
///
/// - A reader takes a head read at most `maxAge` seconds before it asked — `HeadClock.maxAge`, a second (about three
///   blocks), unless it says otherwise — or the answer of the read under way, when that began within the same time;
///   otherwise a read starts, which readers asking meanwhile share. The read runs in a task of its own, so a reader that
///   leaves (a screen closed) doesn't cancel it for the others.
/// - A head's age is counted from when its read began, never from when it answered: a header read since a moment is at
///   least as new as the chain was then. A reader that must see every block mined before it asked — a history round
///   started after a transaction settled reads to its block (`WalletHistorySnapshot.fillsCoverage`) — asks with
///   `maxAge` 0, which a read begun before it never answers.
/// - A failed read is shared with the readers waiting for it and never kept: the next reader reads again.
/// - `forget()` (a transaction of the user's settled, a pull to refresh: `AppEnvironment.invalidateChainReads`, with the
///   shared reads) takes effect at once: no head read before it is taken after it, no read under way since before it is
///   joined, and nothing such a read brings back is kept.
/// - Public chain data only, nothing about a wallet: nothing to erase.
public actor HeadClock {
    /// How old a head a reader takes unless it says otherwise: a second, about three of Monad's blocks. A 24h change's
    /// day-ago block and a chart's samples are found from it, and a head that much older moves them by three blocks.
    public static let maxAge: TimeInterval = 1

    private let read: @Sendable () async throws -> BlockHeader
    private let now: @Sendable () -> Date
    /// Counts the `forget()`s, under a lock so one takes effect at once from any thread, with no suspension: what was read,
    /// or began to be read, before one is never taken after it.
    private nonisolated let forgets = Forgets()
    /// The newest head read, when its read began, and the `forgets` count then.
    private var last: (header: BlockHeader, readAt: Date, epoch: Int)?
    /// The read under way, when it began, and the `forgets` count then.
    private var reading: (id: UUID, at: Date, epoch: Int, task: Task<BlockHeader, Error>)?

    /// The head of the chain `rpc` reads (`eth_getBlockByNumber` of the latest block, a read raced across its endpoints,
    /// `RPCClient.isRead`). `now` is the device clock, which only measures how old a head is.
    public init(rpc: RPCClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(now: now) { try await rpc.block(.latest) }
    }

    /// A clock whose heads come from `read` (tests).
    init(now: @escaping @Sendable () -> Date = { Date() }, read: @escaping @Sendable () async throws -> BlockHeader) {
        self.read = read
        self.now = now
    }

    /// The newest head read so far, with no read; nil before the first answered, and after a `forget()` until the next.
    public var known: BlockHeader? {
        guard let last, last.epoch == forgets.value else { return nil }
        return last.header
    }

    /// Forgets the head kept, and lets no new reader join a read under way (`AppEnvironment.invalidateChainReads`): the
    /// next reader reads the head anew, as the shared reads' next read goes to the chain (`ChainCache.invalidate`). A read
    /// under way still answers those already waiting for it, and nothing it brings back is kept.
    public nonisolated func forget() {
        forgets.advance()
    }

    /// The latest header: one read at most `maxAge` seconds before this call, the read under way when it began within
    /// that time, or a new read — none from before the last `forget()`. Throws when the read fails.
    public func latest(maxAge: TimeInterval = HeadClock.maxAge) async throws -> BlockHeader {
        let asked = now()
        let epoch = forgets.value
        if let last, last.epoch == epoch, Self.isWithin(last.readAt, of: asked, maxAge: maxAge) { return last.header }
        if let reading, reading.epoch == epoch, Self.isWithin(reading.at, of: asked, maxAge: maxAge) { return try await reading.task.value }
        let id = UUID()
        let read = read
        let task = Task { try await read() }
        reading = (id, asked, epoch, task)
        let result = await task.result
        if reading?.id == id { reading = nil }
        let header = try result.get()
        // Two reads can overlap (a reader asking with `maxAge` 0 while another is under way): the one begun last is kept,
        // and none begun before a `forget()`.
        if epoch == forgets.value, last.map({ $0.epoch != epoch || $0.readAt <= asked }) ?? true { last = (header, asked, epoch) }
        return header
    }

    /// The latest block number (`latest(maxAge:)`).
    public func number(maxAge: TimeInterval = HeadClock.maxAge) async throws -> UInt64 {
        try await latest(maxAge: maxAge).number
    }

    /// Whether something read from `began` is at most `maxAge` seconds old at `asked`. A device clock set back makes a
    /// read seem younger than it is, or from the future: never taken for that.
    static func isWithin(_ began: Date, of asked: Date, maxAge: TimeInterval) -> Bool {
        let age = asked.timeIntervalSince(began)
        return age >= 0 && age < maxAge
    }
}

/// `HeadClock`'s count of `forget()`s, read and moved on from any thread under a lock.
private final class Forgets: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func advance() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
