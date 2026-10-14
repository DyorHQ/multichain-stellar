import Foundation
import os

/* When the app reads the server's cache of a wallet's history, and how it keeps checking it (the server contract's §16,
   "When to read" and "Trust"). `HistoryServerClient` reads it and `HistoryStore.adopt` takes it in; this decides when,
   from what the device holds alone (`ServerHistoryPlan`, pure), and the app's history model asks it at its times
   (`HistoryModel`):

   - before the first round of each run of the rounds (a launch, another wallet, a return to the app, an epoch reset), a
     full read while some scan doesn't hold what the server could add, or a top-up of the newest blocks when every one
     does but far behind (`beforeRound`) — so the rounds that follow read only what the server can't vouch for, about
     2,400 blocks a scan (the 1,200-block trust margin below its head plus the rounds' 1,200-block overlap), one rpc2
     request, where a fresh install read the chain for minutes ("Reading your history… 46%");
   - while a scan the device lacks is still being filled in on the server, a poll of the scans' account alone every
     minute, for at most a quarter of an hour a foreground session, and bounded reads of what it newly covers (`poll`);
   - once a day per wallet, one range of what the server added read again from the chain and compared, a mismatch
     distrusting the server for that wallet for a day and reading its history again from the chain alone (`spotCheck`).

   Everything fails open: a read that fails, or doesn't check out, is discarded, and the rounds read the chain as they
   always have. The server is never waited for longer than its own bounded time, and is never needed. */

/// When the app reads the server's history of a wallet, decided from what the device holds and the times alone: the
/// contract's rules (§16), as pure functions.
public enum ServerHistoryPlan {
    /// A read before the rounds (`ServerHistorySync.beforeRound`).
    public enum Read: Sendable, Equatable {
        /// Every page until the last (`HistoryServerClient.read(wallet:)`): some scan isn't complete on the device.
        case full
        /// The blocks from `from` on (`p_from_block`): every scan complete, but its newest block far behind.
        case topUp(from: UInt64)
    }

    /// Blocks a complete scan's newest may lag the head before a top-up is read rather than the chain: 60,000, about five
    /// hours at Monad's pace. Nearer, the rounds read the new blocks themselves, a request or a few a scan.
    public static let topUpLag: UInt64 = 60_000
    /// A top-up reads from this many blocks below the oldest scan's newest one, so what it adds joins what is held.
    public static let topUpOverlap: UInt64 = 20
    /// Seconds between two reads before the rounds of one wallet: returns to the app in a row ask once a minute at most.
    public static let readInterval: TimeInterval = 60
    /// Seconds between two looks at a scan still filling in on the server (a read, then the polls).
    public static let pollInterval: TimeInterval = 60
    /// How long one foreground session polls, from its first look: a quarter of an hour.
    public static let pollWindow: TimeInterval = 15 * 60
    /// The newly covered ranges one poll reads, the newest.
    public static let pollRanges = 3
    /// What the rounds wait for the read before them at most: the client's own seconds (`HistoryServerClient.Limits`), and
    /// five more for the chain's head that adopting reads (`WalletHistoryService.adopt`). Past it they start, and what the
    /// read takes in later waits for the round under way (`HistoryStore.adopt`).
    public static let stepSeconds: TimeInterval = HistoryServerClient.Limits.standard.seconds + 5

    /// The read before the rounds, or nil for none: the whole history while any scan doesn't hold what the server could
    /// add (`holdsTheServers`); a top-up from 20 blocks below the oldest scan's newest block read (`readUpTo`) when every
    /// scan does but one's lies more than `topUpLag` blocks behind the head the server has reached by now
    /// (`estimatedHead`: the server's isn't known before a read, and its indexer follows the chain within minutes); none
    /// within `readInterval` seconds of the last read (`sinceLastRead`, nil: none yet — and a negative one, a clock set
    /// back, as none).
    public static func read(entries: [String: HistoryEntry], estimatedHead: UInt64?, sinceLastRead: TimeInterval?) -> Read? {
        if let since = sinceLastRead, since >= 0, since < readInterval { return nil }
        if entries.isEmpty || entries.values.contains(where: { !holdsTheServers($0) }) { return .full }
        let throughs = entries.values.compactMap(readUpTo)
        guard throughs.count == entries.count, let oldest = throughs.min(), let estimatedHead, estimatedHead > oldest, estimatedHead - oldest > topUpLag else { return nil }
        return .topUp(from: oldest > topUpOverlap ? oldest - topUpOverlap : 0)
    }

    /// The newest block `entry` has read in one piece from its floor; nil when the floor itself is unread. A complete
    /// entry's is its head (`HistoryEntry.through`).
    static func readUpTo(_ entry: HistoryEntry) -> UInt64? {
        guard let floor = entry.floor else { return nil }
        return entry.covered.first { $0.contains(floor) }?.upperBound
    }

    /// Whether `entry` holds everything the server could add to it: every block from its floor to the trust margin below
    /// its head (`HistoryServerClient.trustMargin`) read — complete, or missing only blocks the server never vouches for,
    /// which the rounds read themselves. An entry is that far and no further for as long as rpc2 can't serve the newest
    /// 600 blocks (the endpoints that clamp are never asked for them, `LogsEndpoint.clamps`), at rpc2's few requests a
    /// second often: in the first cut of the server's history, every return to the app a minute after the last read then
    /// paged the whole document again — up to twelve pages, 18 MB for a capped wallet — holding the first round for its 20
    /// seconds while adopting nothing new.
    static func holdsTheServers(_ entry: HistoryEntry) -> Bool {
        guard let head = entry.head, let upTo = readUpTo(entry) else { return false }
        return upTo >= (head > HistoryServerClient.trustMargin ? head - HistoryServerClient.trustMargin : 0)
    }

    /// The head the chain has reached by `now`, from the newest head an entry read and the time since its block at
    /// `secondsPerBlock`; nil when no entry read one.
    public static func estimatedHead(_ entries: some Sequence<HistoryEntry>, now: Date, secondsPerBlock: Double) -> UInt64? {
        entries.compactMap { entry -> UInt64? in
            guard let head = entry.head, let time = entry.headTimestamp else { return nil }
            let elapsed = now.timeIntervalSince1970 - Double(time)
            guard elapsed > 0, secondsPerBlock > 0 else { return head }
            let blocks = min(elapsed / secondsPerBlock, Double(UInt32.max))
            return head + UInt64(blocks)
        }.max()
    }

    /// The blocks `server` proves of `scan` that the device doesn't hold yet (`entry`), at or above the scan's floor at the
    /// server's head (`HistoryEntry.floor(of:head:)`: what lies below it is never kept), merged, ascending. None for a scan
    /// whose filter the server's doesn't take (`LogsQuery.isSubset(of:)`): `HistoryStore.adopt` would refuse it.
    static func beyond(_ server: ServerScan, scan: HistoryScan, entry: HistoryEntry) -> [ClosedRange<UInt64>] {
        guard server.id == scan.id, scan.query.isSubset(of: server.query), let head = server.head ?? entry.head else { return [] }
        let floor = entry.floor(of: scan, head: head)
        return BlockRanges.subtract(BlockRanges.intersect(server.adoptable, floor...UInt64.max), entry.covered)
    }

    /// The scans a poll watches after `read` (a full read, a top-up or a poll's account): each one the device lacks — its
    /// entry not holding what the server could add (`holdsTheServers`) — whose filter the server's takes, and that the
    /// server is still filling in (`complete` false), or that the read stopped before (`finished` false: a wallet with
    /// more logs than the read's twelve pages), or of which the read proves blocks the device doesn't hold yet (a poll
    /// reads its newest ranges only). A scan the server doesn't serve (a wallet it doesn't track: the transfers) is the
    /// device's alone.
    public static func watching(_ read: ServerHistoryRead, scans: [HistoryScan], entries: [String: HistoryEntry]) -> Set<String> {
        var out = Set<String>()
        for scan in scans {
            guard let server = read.scan(scan), let entry = entries[scan.id], !holdsTheServers(entry), scan.query.isSubset(of: server.query) else { continue }
            if !server.complete || !server.finished || !beyond(server, scan: scan, entry: entry).isEmpty { out.insert(scan.id) }
        }
        return out
    }

    /// What one poll reads after the scans' account (`metadata`, `HistoryServerClient.metadata`): the blocks it proves of
    /// the scans watched (`watching`) that the device doesn't hold, merged across them, the newest `pollRanges`, newest
    /// first — each one bounded read (`p_from_block`/`p_to_block`) of every scan.
    public static func newlyCovered(_ metadata: ServerHistoryRead, scans: [HistoryScan], entries: [String: HistoryEntry], watching: Set<String>) -> [ClosedRange<UInt64>] {
        var ranges: [ClosedRange<UInt64>] = []
        for scan in scans where watching.contains(scan.id) {
            guard let server = metadata.scan(scan), let entry = entries[scan.id] else { continue }
            ranges += beyond(server, scan: scan, entry: entry)
        }
        return Array(LogsRead.merge(ranges).reversed().prefix(pollRanges))
    }

    /// Seconds until the next poll, or nil for none: `pollInterval` after the last look (`sinceLastLook`: a read or a
    /// poll; nil, none yet), within the foreground session's window — `pollWindow` from its first look
    /// (`sinceWindowOpened`; nil, not opened yet) — a poll that would fall past it is none. A negative time (a clock set
    /// back) counts as none.
    public static func pollWait(sinceLastLook: TimeInterval?, sinceWindowOpened: TimeInterval?) -> TimeInterval? {
        let look = sinceLastLook.flatMap { $0 >= 0 ? $0 : nil }
        let wait = max(0, pollInterval - (look ?? pollInterval))
        if let opened = sinceWindowOpened, opened >= 0, opened + wait > pollWindow { return nil }
        return wait
    }
}

/// The daily spot check of what the server's history added (the contract's §16 "Trust"): pure decisions.
public enum ServerHistorySpotCheck {
    /// The blocks read again: one range of 10,000, one request on rpc2.
    public static let blocks: UInt64 = 10_000
    /// Once a day per wallet.
    public static let interval: TimeInterval = 86_400
    /// A mismatch distrusts the server for the wallet for a day.
    public static let distrustFor: TimeInterval = 86_400
    /// What the read of the chain may spend: one request, and the seconds of a slow one.
    public static let budget = LogsBudget(requests: 1, seconds: 15)

    /// Whether a check is due: none yet, a day since the last, or a last one in the future (a clock set back).
    public static func due(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let since = now.timeIntervalSince(lastChecked)
        return since < 0 || since >= interval
    }

    /// Whether the server is distrusted for the wallet at `now`: until `until`, never longer than `distrustFor` from now
    /// (a date further off is a clock set back, not a distrust, and has run out).
    public static func distrusted(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        let left = until.timeIntervalSince(now)
        return left > 0 && left <= distrustFor
    }

    /// One range of at most `blocks` within `adopted` (merged, ascending), at random: a range chosen in proportion to its
    /// size, and a start within it that keeps the whole read inside. `random` picks a number in a range (tests pin it).
    public static func range(in adopted: [ClosedRange<UInt64>], random: (ClosedRange<UInt64>) -> UInt64) -> ClosedRange<UInt64>? {
        let ranges = LogsRead.merge(adopted)
        // Each range's size, as a count that can't overflow (a range of every block is 2^64 of them).
        let sizes = ranges.map { range -> UInt64 in range.upperBound - range.lowerBound == .max ? .max : range.upperBound - range.lowerBound + 1 }
        let total = sizes.reduce(UInt64(0)) { $0.addingReportingOverflow($1).overflow ? .max : $0 + $1 }
        guard total > 0 else { return nil }
        var pick = random(0...(total - 1))
        for (range, size) in zip(ranges, sizes) {
            guard pick >= size else {
                let length = min(blocks, size)
                let start = random(range.lowerBound...(range.upperBound - (length - 1)))
                return start...(start + (length - 1))
            }
            pick -= size
        }
        return nil
    }

    /// Whether the chain's logs agree with what is held, in the blocks of `range` the read covered: the same logs by id
    /// (`Log.id`), those `query` matches. Nil when the read covered none of them (no endpoint answered): no verdict.
    public static func agrees(held: [Log], read: LogsRead, query: LogsQuery, within range: ClosedRange<UInt64>) -> Bool? {
        let compared = BlockRanges.intersect(read.covered, range)
        guard !compared.isEmpty else { return nil }
        func ids(_ logs: [Log]) -> Set<String> {
            Set(logs.filter { BlockRanges.contains(compared, $0.blockNumber) && query.matches($0) }.map(\.id))
        }
        return ids(held) == ids(read.logs)
    }
}

/// What the server's history keeps in UserDefaults: the owner's last switches (`RemoteFlags.serverHistory`,
/// `historyEpoch`), for the next launch until the flags are read again — so a launch never reads the server against the
/// owner's switch, nor marks what it takes in with an epoch lower than the one in force — and, per wallet, the day of
/// its last spot check and how long the server is distrusted for it (`ServerHistorySync.spotCheck`). An erase of this
/// device's data removes every key with the rest of UserDefaults (`Session.eraseLocalData`), and a wallet's own
/// before that (`forget(wallet:)`); a wallet's keys are named for it, so nothing of one is read for another. No key
/// starts with a prefix that marks an install as one from before App Lock's default (`Theme.swift`'s `earlierRun`).
/// UserDefaults is thread-safe, hence the unchecked conformance.
public struct ServerHistoryDefaults: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Kept only while the row says the switch is off, or the epoch isn't 0: a launch on a row that says nothing writes
    /// nothing.
    static let offKey = "history.v1.serverHistoryOff"
    static let epochKey = "history.v1.epoch"
    static func distrustKey(_ wallet: Address) -> String { "serverHistory.v1.distrustedUntil.\(wallet.hex.lowercased())" }
    static func checkedKey(_ wallet: Address) -> String { "serverHistory.v1.spotCheckedAt.\(wallet.hex.lowercased())" }

    /// The switches the last read of the flags said (`keep`): on and 0 when none was kept.
    public var kept: (serverHistory: Bool, historyEpoch: Int) {
        let epoch = defaults.integer(forKey: Self.epochKey)
        return (!defaults.bool(forKey: Self.offKey), (0...RemoteFlags.largestEpoch).contains(epoch) ? epoch : 0)
    }

    /// Keeps what `flags` say of the server's history for the next launch.
    public func keep(_ flags: RemoteFlags) {
        if flags.serverHistory { defaults.removeObject(forKey: Self.offKey) } else { defaults.set(true, forKey: Self.offKey) }
        if flags.historyEpoch == 0 { defaults.removeObject(forKey: Self.epochKey) } else { defaults.set(flags.historyEpoch, forKey: Self.epochKey) }
    }

    /// Until when the server is distrusted for `wallet`; nil when it isn't.
    public func distrustedUntil(_ wallet: Address) -> Date? { date(Self.distrustKey(wallet)) }
    /// When `wallet`'s last spot check came to a verdict; nil before the first.
    public func spotCheckedAt(_ wallet: Address) -> Date? { date(Self.checkedKey(wallet)) }

    func distrust(_ wallet: Address, until: Date) { defaults.set(until.timeIntervalSince1970, forKey: Self.distrustKey(wallet)) }
    func spotChecked(_ wallet: Address, at date: Date) { defaults.set(date.timeIntervalSince1970, forKey: Self.checkedKey(wallet)) }

    /// Forgets what is kept of `wallet` (an erase of this device's data).
    public func forget(wallet: Address) {
        defaults.removeObject(forKey: Self.distrustKey(wallet))
        defaults.removeObject(forKey: Self.checkedKey(wallet))
    }

    private func date(_ key: String) -> Date? {
        guard let seconds = defaults.object(forKey: key) as? Double, seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Takes the server's history of a wallet in at the app's times (`HistoryModel`), within the plan (`ServerHistoryPlan`):
/// the read before the rounds (`beforeRound`), the polls of a scan the server is still filling in (`poll`), and the daily
/// spot check (`spotCheck`). One read or poll at a time per wallet (`busy`): the read before the rounds waits for the one
/// under way, a poll lets it be; what this session watched of a wallet is in memory, by wallet.
public actor ServerHistorySync {
    /// What a spot check came to.
    public enum SpotCheck: Sendable, Equatable {
        /// Not due, the wallet distrusted already, or nothing the server added to check.
        case notDue
        /// No endpoint answered the range, or this device's data was erased meanwhile: asked again at the next run.
        case inconclusive
        /// The chain agrees.
        case matched
        /// The chain doesn't: the server is distrusted for the wallet for a day, and the wallet's history on the device
        /// is forgotten, read again from the chain alone.
        case mismatched
    }

    private let client: HistoryServerClient
    private let history: WalletHistoryService
    private let router: LogsRouter
    private let defaults: ServerHistoryDefaults
    private let now: @Sendable () -> Date
    private let random: @Sendable (ClosedRange<UInt64>) -> UInt64
    private static let log = Logger(subsystem: "fun.dyorhq.app", category: "history")

    /// What this session holds of one wallet's reads.
    private struct Watch {
        /// The last read before the rounds (`ServerHistoryPlan.readInterval`).
        var lastRead: Date?
        /// The last look at the server, a read or a poll (`ServerHistoryPlan.pollInterval`).
        var lastLook: Date?
        /// The first look of this foreground session (`ServerHistoryPlan.pollWindow`); nil after a return to the app.
        var windowOpened: Date?
        /// The scans polled (`ServerHistoryPlan.watching`).
        var watching: Set<String> = []
    }

    private var watches: [String: Watch] = [:]
    /// The read or poll under way for each wallet, by its number (`begin`): kept apart from `watches`, which an erase or a
    /// spot check's mismatch drops while one is under way — and the next could then start beside it, and the first one's
    /// end mark the second's done.
    private var busy: [String: Int] = [:]
    private var operations = 0
    /// Reads before the rounds waiting for the one under way to end (`idle`), by wallet, each by its number.
    private var waiting: [String: [Int: CheckedContinuation<Void, Never>]] = [:]
    private var waiters = 0
    /// How many times each wallet's entries were reset (`reset(wallet:)`), by wallet: a read or a poll that began before
    /// one keeps no time and no scans to watch here, and a read before the rounds that began before one reads nothing — it
    /// planned from entries now gone.
    private var resets: [String: Int] = [:]

    /// `history`: the wallet's history the reads are taken into; `router`: where the spot check reads the chain;
    /// `defaults`: the distrust and the spot checks' days. `now` and `random` are the clock and the spot check's dice
    /// (tests pin them).
    public init(client: HistoryServerClient, history: WalletHistoryService, router: LogsRouter, defaults: ServerHistoryDefaults,
                now: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable (ClosedRange<UInt64>) -> UInt64 = { UInt64.random(in: $0) }) {
        self.client = client
        self.history = history
        self.router = router
        self.defaults = defaults
        self.now = now
        self.random = random
    }

    private static func key(_ wallet: Address) -> String { wallet.hex.lowercased() }

    /// Whether the server is distrusted for `wallet` now (a spot check found it wrong within the day): nothing is read
    /// from it for the wallet until then.
    public func distrusted(wallet: Address) -> Bool {
        ServerHistorySpotCheck.distrusted(until: defaults.distrustedUntil(wallet), now: now())
    }

    /// The read before the rounds on `wallet` (`HistoryModel`, before the first round of each run of them), when the plan
    /// calls for one (`ServerHistoryPlan.read`): the whole history while some scan doesn't hold what the server could add,
    /// the new blocks when every one does but far behind, none within a minute of the last (unless the entries were reset
    /// since, `reset(wallet:)`) nor while the wallet is distrusted. A read or a poll of the wallet under way finishes first
    /// (`idle`), and the plan is made from what the device holds after it: in the first cut of the server's history one
    /// under way — a poll, or the read of a run just cancelled — made this one return nothing after the history model had
    /// marked it done, and the run's read was skipped without notice. The erase count and the epoch are taken before the
    /// read (`HistoryStore`), the distrust checked again after them (a spot check's mismatch distrusts the server before it
    /// forgets the wallet, so either this sees the distrust or the adoption sees the erase), and the read is taken in under
    /// them (`WalletHistoryService.adopt`); then the scans to poll are worked out (`ServerHistoryPlan.watching`). Any
    /// failure is logged and nothing is taken: the rounds read the chain. The scans it took in.
    public func beforeRound(wallet: Address) async -> Set<String> {
        let key = Self.key(wallet)
        await idle(key)
        guard !Task.isCancelled, !distrusted(wallet: wallet) else { return [] }
        let operation = begin(key)
        defer { done(key, operation) }
        let resets = self.resets[key, default: 0]
        let entries = await history.entries(wallet: wallet)
        let start = now()
        let head = ServerHistoryPlan.estimatedHead(entries.values, now: start, secondsPerBlock: await history.knownSecondsPerBlock)
        guard let plan = ServerHistoryPlan.read(entries: entries, estimatedHead: head, sinceLastRead: watches[key]?.lastRead.map { start.timeIntervalSince($0) }) else { return [] }
        let store = await history.history
        let token = await store.erasureToken(), epoch = await store.epochApplied
        // Distrusted, or the entries reset, while the plan was made: nothing is read for entries that are gone.
        guard !distrusted(wallet: wallet), self.resets[key, default: 0] == resets else { return [] }
        watches[key, default: Watch()].lastRead = start
        watches[key]?.lastLook = start
        if watches[key]?.windowOpened == nil { watches[key]?.windowOpened = start }
        let read: ServerHistoryRead
        do {
            switch plan {
            case .full: read = try await client.read(wallet: wallet)
            case .topUp(let from): read = try await client.read(wallet: wallet, from: from)
            }
        } catch {
            Self.note(error, wallet: wallet, what: plan == .full ? "full read" : "top-up") // not localized: developer diagnostics
            if self.resets[key, default: 0] == resets { watches[key]?.watching = [] }
            return []
        }
        guard !distrusted(wallet: wallet) else { return [] }
        let adopted = await history.adopt(read, wallet: wallet, erasureToken: token, epoch: epoch)
        await rewatch(after: read, wallet: wallet, token: token, resets: resets)
        return adopted
    }

    /// The wallet's entries were reset and the rounds start over on it (`HistoryModel.restart`: an epoch reset, a spot
    /// check that found the server wrong): the read before the next round is due whatever the time of the last one, and
    /// nothing a read or a poll under way began with is kept here — not its time, not the scans it would watch: it planned
    /// from entries now gone. In the first cut of the server's history the read the cancelled run had just made held the
    /// next one off for a minute, and every entry an epoch reset dropped was read again from the public endpoints alone,
    /// from nothing ("Reading your history… 2%" for minutes on every device at once).
    public func reset(wallet: Address) {
        let key = Self.key(wallet)
        resets[key, default: 0] += 1
        watches[key]?.lastRead = nil
        watches[key]?.watching = []
    }

    /// Seconds until `wallet`'s next poll (`poll`), or nil for none: no scan watched, the foreground session's window
    /// closed (`ServerHistoryPlan.pollWait`), the wallet distrusted. A read or a poll under way: a minute on
    /// (`ServerHistoryPlan.pollInterval`), never at once — `poll` would turn it away without a look, and with the last look
    /// a minute old the poller asked again at once, over and over, for as long as the read lasted.
    public func nextPoll(wallet: Address) -> TimeInterval? {
        let key = Self.key(wallet)
        guard let watch = watches[key], !watch.watching.isEmpty, !distrusted(wallet: wallet) else { return nil }
        let now = now()
        guard let wait = ServerHistoryPlan.pollWait(sinceLastLook: watch.lastLook.map { now.timeIntervalSince($0) }, sinceWindowOpened: watch.windowOpened.map { now.timeIntervalSince($0) })
        else { return nil }
        return busy[key] == nil ? wait : max(wait, ServerHistoryPlan.pollInterval)
    }

    /// One poll of `wallet`'s scans still filling in on the server: their account alone (`HistoryServerClient.metadata`,
    /// one page, no logs), then a bounded read of each of the newest ranges it newly covers that the device doesn't hold
    /// (`ServerHistoryPlan.newlyCovered`, three at most), each taken in (`WalletHistoryService.adopt`); then the scans to
    /// watch again. Nothing while none is watched, the window is closed, the wallet is distrusted or a read of it is under
    /// way (the poller is told to look again a minute on, `nextPoll`). The distrust is checked again once the erase count
    /// is taken and before each read is taken in, as before the rounds (`beforeRound`). A failure that may pass (no
    /// answer, a status, the read's seconds) leaves the scans watched; any other — the owner's switch on the server, a
    /// document that doesn't check out — ends the polls. The scans it took in.
    public func poll(wallet: Address) async -> Set<String> {
        let key = Self.key(wallet)
        guard let watch = watches[key], !watch.watching.isEmpty, busy[key] == nil, !distrusted(wallet: wallet) else { return [] }
        let start = now()
        guard ServerHistoryPlan.pollWait(sinceLastLook: nil, sinceWindowOpened: watch.windowOpened.map { start.timeIntervalSince($0) }) != nil else { return [] }
        let operation = begin(key)
        defer { done(key, operation) }
        let resets = self.resets[key, default: 0]
        watches[key]?.lastLook = start
        if watch.windowOpened == nil { watches[key]?.windowOpened = start }
        let store = await history.history
        let token = await store.erasureToken(), epoch = await store.epochApplied
        guard !distrusted(wallet: wallet) else { return [] }
        let metadata: ServerHistoryRead
        do {
            metadata = try await client.metadata(wallet: wallet)
        } catch {
            Self.note(error, wallet: wallet, what: "poll") // not localized: developer diagnostics
            if !Self.passes(error), self.resets[key, default: 0] == resets { watches[key]?.watching = [] }
            return []
        }
        let scans = await history.scans(wallet: wallet, findingFirstTransaction: false)
        let ranges = ServerHistoryPlan.newlyCovered(metadata, scans: scans, entries: await history.entries(wallet: wallet), watching: watch.watching)
        var adopted = Set<String>()
        for range in ranges {
            guard !Task.isCancelled else { break }
            let read: ServerHistoryRead
            do {
                read = try await client.read(wallet: wallet, from: range.lowerBound, to: range.upperBound)
            } catch {
                Self.note(error, wallet: wallet, what: "bounded read") // not localized: developer diagnostics
                break
            }
            guard !distrusted(wallet: wallet) else { break }
            adopted.formUnion(await history.adopt(read, wallet: wallet, erasureToken: token, epoch: epoch))
        }
        await rewatch(after: metadata, wallet: wallet, token: token, resets: resets)
        return adopted
    }

    /// A return to the app: a new foreground session, whose polls of each wallet get a new window, opened at its first look.
    public func enteredForeground() {
        for key in watches.keys { watches[key]?.windowOpened = nil }
    }

    /// The scans to watch after `read` (`ServerHistoryPlan.watching`), from what the device holds now; nothing kept once
    /// this device's data was erased since `token`, nor once the entries were reset since the read began (`resets`, the
    /// count then: the next read before the rounds works them out again). A scan whose reads keep being refused
    /// (`HistoryStore.adopt`: the device's head behind the server's, say) costs a poll a minute at most, within the
    /// session's quarter of an hour.
    private func rewatch(after read: ServerHistoryRead, wallet: Address, token: Int, resets: Int) async {
        let key = Self.key(wallet)
        let scans = await history.scans(wallet: wallet, findingFirstTransaction: false)
        let entries = await history.entries(wallet: wallet)
        guard await history.history.erasureToken() == token else {
            watches[key] = nil
            return
        }
        guard self.resets[key, default: 0] == resets else { return }
        let watching = ServerHistoryPlan.watching(read, scans: scans, entries: entries)
        watches[key]?.watching = watching
    }

    // MARK: One read or poll at a time

    /// Marks a read or a poll of `key` under way, and returns its number for `done`.
    private func begin(_ key: String) -> Int {
        operations += 1
        busy[key] = operations
        return operations
    }

    /// The read or poll `operation` of `key` ended: the reads before the rounds waiting for it go on (`idle`). Nothing
    /// when another is marked under way since (it can't be, while this one is: `idle`, `poll`).
    private func done(_ key: String, _ operation: Int) {
        guard busy[key] == operation else { return }
        busy[key] = nil
        for waiter in (waiting.removeValue(forKey: key) ?? [:]).values { waiter.resume() }
    }

    /// Waits until no read or poll of `key` is under way (`busy`), or the caller is cancelled (another wallet, a restart:
    /// it leaves at once). Returns with none under way, so the caller can mark its own before anything else starts — no
    /// suspension comes between.
    private func idle(_ key: String) async {
        while busy[key] != nil, !Task.isCancelled {
            waiters += 1
            let id = waiters
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiting[key, default: [:]][id] = continuation
                }
            } onCancel: {
                Task { await self.stopWaiting(id, key) }
            }
        }
    }

    /// A reader whose task was cancelled stops waiting (`idle`); nothing when it was let go already.
    private func stopWaiting(_ id: Int, _ key: String) {
        waiting[key]?.removeValue(forKey: id)?.resume()
    }

    /// The day's spot check of `wallet` (the contract's §16 "Trust"), once a day per wallet while the server isn't
    /// distrusted for it: one range of 10,000 blocks at random within what the server added to the transfers into the
    /// wallet (`HistoryEntry.adopted`), read again from the chain through the router — the history's lane, one request
    /// (`ServerHistorySpotCheck.budget`) — and its logs compared by id with those held (`ServerHistorySpotCheck.agrees`).
    /// A mismatch distrusts the server for the wallet for a day (`ServerHistoryDefaults`), forgets the wallet's history on
    /// the device (`WalletHistoryService.forget`) — the caller reads it again, from the chain alone — and logs it. Nothing
    /// is written once this device's data was erased since the check began.
    public func spotCheck(wallet: Address) async -> SpotCheck {
        let start = now()
        guard !distrusted(wallet: wallet), ServerHistorySpotCheck.due(lastChecked: defaults.spotCheckedAt(wallet), now: start) else { return .notDue }
        let store = await history.history
        let token = await store.erasureToken()
        let scan = WalletHistoryScans.transfersIn(wallet: wallet)
        let entry = await store.cached(scan, wallet: wallet)
        let sampled = entry.covered.flatMap { BlockRanges.intersect(entry.adopted, $0) }
        guard entry.serverEpoch != nil, let head = entry.head, let range = ServerHistorySpotCheck.range(in: sampled, random: random) else { return .notDue }
        let read = await router.read(scan.query, from: range.lowerBound, to: range.upperBound, head: head, order: .descending, budget: ServerHistorySpotCheck.budget,
                                     lane: .history)
        guard let agrees = ServerHistorySpotCheck.agrees(held: entry.logs, read: read, query: scan.query, within: range) else { return .inconclusive }
        let defaults = self.defaults
        if agrees {
            return await store.unlessErased(since: token, { defaults.spotChecked(wallet, at: start) }) ? .matched : .inconclusive
        }
        let until = start.addingTimeInterval(ServerHistorySpotCheck.distrustFor)
        guard await store.unlessErased(since: token, { defaults.distrust(wallet, until: until); defaults.spotChecked(wallet, at: start) }) else { return .inconclusive }
        // not localized: developer diagnostics, never shown
        Self.log.error("server history spot check failed for \(wallet.short, privacy: .public): blocks \(range.lowerBound)-\(range.upperBound), \(read.logs.count) logs on the chain; distrusted for a day, read again from the chain")
        watches[Self.key(wallet)] = nil
        await history.forget(wallet: wallet)
        return .mismatched
    }

    /// Forgets `wallet` here (an erase of this device's data): what this session watched of it, and what the device keeps
    /// of its spot checks and distrust (`ServerHistoryDefaults.forget`).
    public func forget(wallet: Address) {
        watches[Self.key(wallet)] = nil
        defaults.forget(wallet: wallet)
    }

    /// Whether a failed read may pass by itself: no answer, a status, the read's seconds, a cancellation — the scans stay
    /// watched. The owner's switch on the server, another document version, a document that doesn't check out: no.
    static func passes(_ error: Error) -> Bool {
        switch error as? HistoryServerError {
        case .transport, .http, .timedOut, .cancelled: return true
        default: return false
        }
    }

    /// Logs a read that was discarded: developer diagnostics, never shown. A cancellation (another wallet, an erase) is
    /// none.
    private static func note(_ error: Error, wallet: Address, what: String) {
        if case .cancelled? = error as? HistoryServerError { return }
        // not localized: developer diagnostics, never shown
        log.info("server history \(what, privacy: .public) for \(wallet.short, privacy: .public) discarded: \(String(describing: error), privacy: .public)")
    }

    /// `task`'s value when it ends within `seconds`, else nil — the task left to finish on its own (what it takes in still
    /// waits for the round under way, `HistoryStore.adopt`). Cancelling the caller cancels the task, and returns at once.
    public static func value<T: Sendable>(of task: Task<T, Never>, within seconds: TimeInterval) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.begin(continuation, timer: Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    race.end(nil)
                })
                Task { race.end(await task.value) }
            }
        } onCancel: {
            task.cancel()
            race.end(nil)
        }
    }
}

/// The first of a task's value and a deadline (`ServerHistorySync.value(of:within:)`): resumes its caller once, with the
/// first to come, and stops the timer.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var timer: Task<Void, Never>?
    private var ended = false

    func begin(_ continuation: CheckedContinuation<T?, Never>, timer: Task<Void, Never>) {
        lock.lock()
        guard !ended else {
            lock.unlock()
            timer.cancel()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        self.timer = timer
        lock.unlock()
    }

    func end(_ value: T?) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        let continuation = self.continuation, timer = self.timer
        self.continuation = nil
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: value)
    }
}
