import Foundation

/// Chain reads several screens make at about the same time, made once and shared (speed work, 2026-10-09): the launch
/// list, the Moments lists and terms, and prices. Home, the Portfolio, the Launch board, My Launchpad, Recent Activity, the Moments
/// screens and the alert checks each read them on their own, often within the same second at launch and every 20–30 s
/// after, which cost about a hundred requests in the first seconds (rpc.monad.xyz answers about 25 a second).
///
/// - Callers that ask for the same key while its read is under way wait for that read rather than start another, and
///   share its answer, its failure included (`value`).
/// - An answer is kept for a short time (`TTL`): long enough to serve the screens that ask in the same burst, shorter
///   than any screen's poll, so no screen shows an older figure than its own read would have. Nothing is kept that a
///   reader shouldn't reuse (`keep`): a failure or a list that couldn't be read in full is never kept, so a Retry reads
///   again at once.
/// - `invalidate()` forgets everything at once (a transaction of the user's that settled, a pull to refresh, an erase):
///   the next read of every key goes to the chain, a read under way still answers those already waiting for it, and
///   nothing it brings back is kept.
///
/// What never changes once read (a launch's text, a Moment's record) lives in `ChainStore`, not here.
public final class ChainCache: @unchecked Sendable {
    /// How long each kind of read is shared.
    public enum TTL {
        /// The launch list and the Moments lists: the Launch and Moments boards poll every 20 s and Home every 30 s.
        public static let listing: TimeInterval = 15
        /// A Moments cohort's terms (`MomentsService.policy`): set by governance, their values changed only through a
        /// proposal queued for 48 hours (the board says one is queued), so the board's 20 s poll reads them every third time.
        /// A publish is bound to the terms its review showed (`termsHash`, MO-4) and the factory refuses it if they changed,
        /// so terms a minute old never publish under other terms; a pause or a new link base shows within the minute.
        public static let terms: TimeInterval = 60
        /// One token's price and 24h change.
        public static let price: TimeInterval = 10
        /// The block mined 24 hours before the latest, which every 24h change is measured from: a minute later the change
        /// is measured over 24 hours and a minute, which no figure on screen can show.
        public static let dayAgoBlock: TimeInterval = 60
        /// What Swap's route search learns before it can quote a pair (`SwapRouteCache`): which Uniswap v3, v4 and Monday
        /// Trade pools the pair trades through and how deep each v3 one is, and which pool a launchpad or Moment coin
        /// graduated into. Pools are created and drained rarely, and each amount typed and each 15 s re-quote then costs
        /// the one quote read instead of the search's 4–5 reads before it. No quote is kept: every amount is quoted on
        /// chain. A pool drained within the minute fails its quote and is passed over; one created, or a coin graduated,
        /// within it is found by the first search after the minute, or at once after a transaction of the user's settles.
        public static let swapRoutes: TimeInterval = 60
    }

    private struct Entry {
        let value: any Sendable
        let at: Date
        let generation: Int
    }

    private struct Read {
        let id: UUID
        let generation: Int
        let task: Task<Result<any Sendable, Error>, Never>
    }

    private enum Claim {
        case fresh(any Sendable)
        case join(Task<Result<any Sendable, Error>, Never>)
        case lead(Read)
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var currentGeneration = 0
    private var entries: [String: Entry] = [:]
    private var reads: [String: Read] = [:]

    /// `now` is the device clock, which only measures how long an answer is kept.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Counts the `invalidate()`s: what a reader read before one is never kept after it (`keep(_:for:readSince:)`).
    public var generation: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentGeneration
    }

    /// The answer kept for `key`, read less than `ttl` seconds ago and since the last `invalidate()`; else the answer of
    /// the read of `key` under way, waited for; else `read`'s, which callers asking meanwhile share. The answer is kept
    /// when `keep` says so (and nothing was invalidated while it was read). `read` runs in a task of its own, so a caller
    /// that leaves (a screen closed) doesn't cancel it for the others, and what it reads is still kept for the next.
    public func value<T: Sendable>(_ key: String, ttl: TimeInterval, keep: @escaping @Sendable (T) -> Bool = { _ in true },
                                   read: @escaping @Sendable () async throws -> T) async throws -> T {
        switch claim(key, ttl: ttl, read: read) {
        case .fresh(let value):
            if let value = value as? T { return value }
            return try await read()
        case .join(let task):
            let value = try await task.value.get()
            if let value = value as? T { return value }
            return try await read()
        case .lead(let leading):
            let result = await leading.task.value
            settle(key, leading, result: result, keep: { ($0 as? T).map(keep) ?? false })
            let value = try result.get()
            if let value = value as? T { return value }
            return try await read()
        }
    }

    /// What `key` holds, kept less than `ttl` seconds ago and since the last `invalidate()`; nil otherwise. For a reader
    /// that keeps the parts of its reads one by one (a price per token), with `keep(_:for:readSince:)`.
    public func fresh<T: Sendable>(_ key: String, ttl: TimeInterval) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], entry.generation == currentGeneration, isFresh(entry, ttl: ttl) else { return nil }
        return entry.value as? T
    }

    /// Keeps `value` under `key`, unless `invalidate()` was called since `generation` (what `generation` said when the
    /// read that brought it began).
    public func keep<T: Sendable>(_ value: T, for key: String, readSince generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == currentGeneration else { return }
        entries[key] = Entry(value: value, at: now(), generation: generation)
    }

    /// Forgets every answer kept, and lets no new caller join a read under way: a transaction of the user's settled, a
    /// pull to refresh asked for what is on chain now, or this device's data was erased.
    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        currentGeneration += 1
        entries = [:]
    }

    // MARK: Bookkeeping

    private func isFresh(_ entry: Entry, ttl: TimeInterval) -> Bool {
        let age = now().timeIntervalSince(entry.at)
        // A clock set back makes an answer seem younger than it is: never kept longer than its time for that.
        return age >= 0 && age < ttl
    }

    private func claim<T: Sendable>(_ key: String, ttl: TimeInterval, read: @escaping @Sendable () async throws -> T) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key], entry.generation == currentGeneration, isFresh(entry, ttl: ttl) { return .fresh(entry.value) }
        if let running = reads[key], running.generation == currentGeneration { return .join(running.task) }
        let task = Task<Result<any Sendable, Error>, Never> {
            do { return .success(try await read() as any Sendable) } catch { return .failure(error) }
        }
        let leading = Read(id: UUID(), generation: currentGeneration, task: task)
        reads[key] = leading
        return .lead(leading)
    }

    private func settle(_ key: String, _ read: Read, result: Result<any Sendable, Error>, keep: (any Sendable) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        if reads[key]?.id == read.id { reads[key] = nil }
        guard read.generation == currentGeneration, case .success(let value) = result, keep(value) else { return }
        entries[key] = Entry(value: value, at: now(), generation: read.generation)
    }
}

/// Facts read from the chain that don't change once settled — a launch's token, curve and creator text, a Moment's record
/// and text — and where tokens are priced (with each lookup's own time limit), kept as small JSON files between launches
/// (speed work, 2026-10-09). Public chain data only, nothing about a wallet, shared by every account on the device, in
/// Application Support and out of backups. A fork keeps none of it (`directory` nil, `keepsFacts` false): a fork restarted
/// while the app runs can reuse an address for something else, so the launchpad and the Moments keep no settled launch or
/// Moment of it, not even in memory, and read each in full every time; its pools are kept for the session only, each
/// for its lookup's own time. Erasing this device's data removes them (`erase`), and a write that was read before an
/// erase is dropped (`save(_:to:epoch:)`), so nothing read for the erased account comes back.
///
/// The reader that keeps a file trusts it as it trusts the registry's (`DyorCoinStore`): it is the app's own sandbox.
/// Text is kept as the chain holds it and made safe to show on every read (`ChainText.shown`), so a later rule applies to
/// it too, and a picture's link goes through `ImageSourcePolicy` like any other.
public final class ChainStore: @unchecked Sendable {
    /// Where the files are; nil keeps everything in memory only.
    public let directory: URL?
    private let lock = NSLock()
    private var currentEpoch = 0

    public init(directory: URL?) {
        self.directory = directory
    }

    /// Whether the facts of a settled launch or Moment are kept at all (`directory` set). A fork's aren't, in memory
    /// either: a fork restarted can give an address to something else, and what was kept of it would be shown.
    public var keepsFacts: Bool { directory != nil }

    /// `chain-reads-<chain>` in the app's Application Support folder, or memory only when there is none.
    public static func applicationSupport(chainId: Int = Monad.chainId) -> ChainStore {
        let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ChainStore(directory: folder?.appending(path: "chain-reads-\(chainId)"))
    }

    /// Counts the erases: a reader notes it when it starts, and what it read is saved only if none happened since.
    public var epoch: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentEpoch
    }

    /// The file `name` as `T`; nil when there is none, or it can't be read as one.
    public func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let url = directory?.appending(path: name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Replaces the file `name` with `value` in one atomic write, out of backups, unless this device's data was erased
    /// since `epoch`. Nothing to do in memory only.
    public func save<T: Encodable>(_ value: T, to name: String, epoch: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == currentEpoch, let directory else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Removes every file (an erase of this device's data). Readers drop what they hold in memory at their next read
    /// (`epoch` moved), and no save of anything read before this lands after it.
    public func erase() {
        lock.lock()
        defer { lock.unlock() }
        currentEpoch += 1
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

/// One entry of a list in a `ChainStore` file, nil when it can't be read: an entry a later build added a field to, or a
/// damaged one, is left out, never the whole file.
struct ChainStoreEntry<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// How long after a launch or a Moment is made its fixed facts are kept on the device (`ChainStore`): by then no block
/// that recorded it can be replaced (Monad finalizes in about a second), so its index, record and text are the chain's
/// for good. Anything younger is read in full every time.
enum ChainSettled {
    static let age: TimeInterval = 600
    /// The most creator text (UTF-8 bytes, every field together) kept of one launch or Moment. A creator can write tens of
    /// kilobytes (`Multicall.textChunk`); one who does is read in full every time, as before, and keeps the files small.
    static let maxKeptText = 4_096

    /// Whether `texts` together are short enough to keep.
    static func isKeepable(_ texts: [String]) -> Bool {
        texts.reduce(0) { $0 + $1.utf8.count } <= maxKeptText
    }

    /// Whether something made at `timestamp` (unix seconds) is settled at `now`.
    static func isSettled(_ timestamp: Int, now: Date) -> Bool {
        timestamp > 0 && now.timeIntervalSince1970 - TimeInterval(timestamp) >= age
    }
}
