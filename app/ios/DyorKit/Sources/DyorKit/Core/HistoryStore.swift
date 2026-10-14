import BigInt
import Foundation

/* A wallet's history, kept on the device. Each scan of it (`HistoryScan`: a filter and the oldest block it reads) is
   an entry: the logs read so far and exactly which blocks they cover. A refresh reads the blocks since the newest
   covered one first (from `overlap` below it, what an endpoint that clamps could have left out), then fills the gaps
   back to the floor while its budget lasts, newest first, and saves after every read; the coverage never claims a
   block that wasn't read, so a refresh cut short resumes where it stopped, however many launches later. Screens read
   the entry first — instantly — and refresh it behind.

   The server's cache of the same scans (`HistoryServerClient`) can add to an entry (`adopt`): only the blocks one read
   of it proves covered (`ServerScan.adoptable`), with the logs it served for them, serialised with the refreshes so
   neither loses what the other wrote. What it adds is the server's until the owner's history epoch moves past the one it
   was taken in under (`apply(epoch:)`): then the entry is read again from nothing. The wallet's first transaction as the
   server found it is kept here too, apart from the one the device found, and goes the same way
   (`adopt(firstTransaction:wallet:erasureToken:epoch:)`). */

/// One of a wallet's scans: what it asks for, and the oldest block it ever reads.
public struct HistoryScan: Sendable, Hashable {
    /// The oldest block a scan reads: a block (a contract's deployment), or so many blocks back from the head.
    public enum Floor: Sendable, Hashable {
        case block(UInt64)
        case blocks(UInt64)
        /// The earlier of a block and so many blocks back: a wallet's first transaction, or the usual window when
        /// that is nearer than it.
        case earliest(block: UInt64, blocks: UInt64)

        public func block(head: UInt64) -> UInt64 {
            switch self {
            case .block(let block): return min(block, head)
            case .blocks(let count): return head > count ? head - count : 0
            case .earliest(let block, let count): return min(Floor.block(block).block(head: head), Floor.blocks(count).block(head: head))
            }
        }
    }

    public let id: String
    public let query: LogsQuery
    public let floor: Floor

    public init(id: String, query: LogsQuery, floor: Floor) {
        self.id = id
        self.query = query
        self.floor = floor
    }
}

/// What the store holds of one scan for one wallet.
public struct HistoryEntry: Sendable, Equatable {
    /// Every log read, in block order, each once.
    public var logs: [Log]
    /// The blocks read, merged, ascending.
    public var covered: [ClosedRange<UInt64>]
    /// The chain head, its timestamp and the scan's floor at the last refresh that read the head; nil before the first.
    public var head: UInt64?
    public var headTimestamp: Int?
    public var floor: UInt64?
    /// The oldest block whose logs are kept once the cap dropped older ones (`trim`): the floor never goes below it
    /// again, so the entry can be complete without what was dropped.
    public var capFloor: UInt64?
    /// The floor a complete read of the server's history proved for a transfer scan (`HistoryStore.adopt`): the server
    /// reads them from genesis, and once one read of it served every log from there with nothing left out, the scan's
    /// floor is that (`floor(of:head:)`) — never before, so the device never takes on more blocks than it can prove read.
    /// Nil: the scan's own floor (the wallet's first transaction, or 30 days).
    public var floorOverride: UInt64?
    /// The owner's history epoch the entry took the server's history in under (`HistoryStore.adopt`); nil when it never
    /// did. Lower than the epoch applied, and the entry is read again from nothing (`HistoryStore.apply(epoch:)`).
    public var serverEpoch: Int?
    /// The blocks the server's history added (`HistoryStore.adopt`), merged, ascending, within `covered` (trimmed with it):
    /// where the daily spot check reads the chain again to compare (`ServerHistorySync.spotCheck`), never a block the
    /// device read itself. Empty when it never took any in.
    public var adopted: [ClosedRange<UInt64>]
    public var updatedAt: Date?
    /// Whether the last refresh read the head: false says the chain couldn't be reached, so nothing moved.
    public var reachedChain = true

    public init(logs: [Log] = [], covered: [ClosedRange<UInt64>] = [], head: UInt64? = nil, headTimestamp: Int? = nil, floor: UInt64? = nil, capFloor: UInt64? = nil,
                updatedAt: Date? = nil, floorOverride: UInt64? = nil, serverEpoch: Int? = nil, adopted: [ClosedRange<UInt64>] = []) {
        self.logs = logs
        self.covered = covered
        self.head = head
        self.headTimestamp = headTimestamp
        self.floor = floor
        self.capFloor = capFloor
        self.updatedAt = updatedAt
        self.floorOverride = floorOverride
        self.serverEpoch = serverEpoch
        self.adopted = adopted
    }

    /// The head as a block header, for estimating each log's time; nil before the first refresh.
    public var anchor: BlockHeader? {
        guard let head, let headTimestamp else { return nil }
        return BlockHeader(number: head, timestamp: headTimestamp)
    }

    public static let empty = HistoryEntry()

    /// Whether every block from the floor to the head has been read.
    public var complete: Bool {
        guard let head, let floor else { return false }
        return covered.contains { $0.lowerBound <= floor && $0.upperBound >= head }
    }

    /// The blocks of `[floor, head]` not read yet.
    public var unread: UInt64 {
        guard let head, let floor, head >= floor else { return 0 }
        let read = covered.reduce(UInt64(0)) { total, range in
            let low = max(range.lowerBound, floor), high = min(range.upperBound, head)
            return high >= low ? total + (high - low + 1) : total
        }
        return (head - floor + 1) - min(read, head - floor + 1)
    }

    /// How much of `[floor, head]` has been read, 0 to 1.
    public var progress: Double {
        guard let head, let floor, head >= floor else { return complete ? 1 : 0 }
        return 1 - Double(unread) / Double(head - floor + 1)
    }

    /// The oldest block `scan` reads at `head` for this entry: the scan's own (`HistoryScan.Floor`), or the one a complete
    /// read of the server's history proved when that is older (`floorOverride`), never below the logs the cap kept
    /// (`capFloor`).
    func floor(of scan: HistoryScan, head: UInt64) -> UInt64 {
        max(min(scan.floor.block(head: head), floorOverride ?? .max), capFloor ?? 0)
    }

    /// The newest block read in one piece with the head (nil when the head itself wasn't read).
    public var through: UInt64? {
        guard let head else { return nil }
        return covered.first { $0.contains(head) }?.upperBound
    }

    /// The gaps of `[floor, head]`, newest first.
    func gaps(head: UInt64, floor: UInt64) -> [ClosedRange<UInt64>] {
        guard head >= floor else { return [] }
        var gaps: [ClosedRange<UInt64>] = []
        var cursor = floor
        for range in covered where range.upperBound >= floor && range.lowerBound <= head {
            if range.lowerBound > cursor { gaps.append(cursor...(range.lowerBound - 1)) }
            cursor = max(cursor, range.upperBound == UInt64.max ? range.upperBound : range.upperBound + 1)
            if cursor > head { break }
        }
        if cursor <= head { gaps.append(cursor...head) }
        return gaps.reversed()
    }
}

/// The wallet's history scans, each kept on disk and refreshed incrementally (`HistoryEntry`).
public actor HistoryStore {
    /// Logs kept per entry: past them, the oldest are dropped and the coverage starts where the kept logs do.
    public static let logCap = 20_000
    /// Blocks read again below the newest covered one on every refresh: twice the margin a clamping endpoint is kept
    /// from the head by (`LogsEndpoints.headLag`), 1,200 blocks, about six minutes — the server's history indexer reads
    /// the same again on every run. An endpoint that clamps answers a range ending past its node's head short, with no
    /// error (`LogsEndpoint.clamps`): in build 22 and earlier one could be asked for the newest blocks, and its answer
    /// marked them read with the logs past its node's head missing, which the 20 blocks then read again didn't reach, a
    /// node hundreds of blocks behind. Now none is asked for a block within `headLag` of the head, and every round reads
    /// again what a node of theirs up to 1,200 blocks behind could still have left out below that, and what a round of
    /// build 22 left out. No more requests than the 20 took: the window, these blocks and the few hundred since the last
    /// round, is one range of rpc2's 10,000 — or, while rpc2 rests, a request or two of 1,000 blocks on a clamping
    /// endpoint for the part below the head's 600, which wait for rpc2.
    static let overlap: UInt64 = 2 * LogsEndpoints.headLag

    private let router: LogsRouter
    private let directory: URL?
    private var entries: [String: HistoryEntry] = [:]
    /// The refresh, or the adoption (`adopt`), under way for each entry: a refresh joins it, an adoption waits for it.
    private var refreshing: [String: Task<HistoryEntry, Never>] = [:]
    /// Counts erasures (`forget`): a refresh under way when one happens keeps nothing of what it read.
    private var erasures = 0
    /// The owner's history epoch last applied (`apply(epoch:)`): an entry that took the server's history in under a lower
    /// one is read again from nothing, and no adoption under a lower one is kept.
    private var epoch = 0
    /// How many times each entry was reset (`apply(epoch:)`) or forgotten (`forget`), by key: a refresh or an adoption
    /// under way when one happens keeps nothing of what it read.
    private var resets: [String: Int] = [:]

    /// `directory`: where entries are kept between launches; nil keeps them in memory only (tests). `epoch`: the owner's
    /// history epoch the last read of the flags said (`ServerHistoryDefaults`, kept between launches), applied from the
    /// first entry loaded on: a read of the server's history made before the flags are read again this launch is marked
    /// with it, never with 0 — which would lower an entry's epoch and have the next read of the flags drop it all.
    public init(router: LogsRouter, directory: URL?, epoch: Int = 0) {
        self.router = router
        self.directory = directory
        self.epoch = max(0, epoch)
    }

    /// The owner's history epoch applied now (`apply(epoch:)`): what a read of the server's history is made under, taken
    /// before it with `erasureToken()` and handed to `adopt`.
    public var epochApplied: Int { epoch }

    private static func key(_ scan: HistoryScan, _ wallet: Address) -> String { "\(wallet.hex.lowercased())-\(scan.id)" }

    /// What is held for `scan` and `wallet`, from memory or disk; empty before the first refresh. A file that took the
    /// server's history in under an epoch lower than the one applied is read again from nothing (`apply(epoch:)`).
    public func cached(_ scan: HistoryScan, wallet: Address) -> HistoryEntry {
        let key = Self.key(scan, wallet)
        if let entry = entries[key] { return entry }
        var loaded = load(scan, wallet) ?? .empty
        if Self.adopted(loaded, before: epoch) {
            loaded = .empty
            resets[key, default: 0] += 1
            if let file = file(scan, wallet) { try? FileManager.default.removeItem(at: file) }
        }
        entries[key] = loaded
        return loaded
    }

    /// The chain head, from the first endpoint that answers (`LogsRouter.latest`); nil when none does. A round of every
    /// scan reads the session's shared head once and hands it to each (`refresh(_:wallet:budget:at:)`,
    /// `WalletHistoryService.roundHead`), and this one only when that can't be read.
    public func latest() async -> BlockHeader? {
        await router.latest()
    }

    /// Reads what `scan` is missing for `wallet` — the blocks since the newest read, then the gaps back to the floor,
    /// newest first — within `budget`, and returns the entry as it then stands. A refresh already running for the same
    /// scan and wallet is joined, not doubled. The head is read first (`latest`).
    public func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget) async -> HistoryEntry {
        await refresh(scan, wallet: wallet, budget: budget, head: .read)
    }

    /// `refresh` up to `latest`, the head the caller read for a round of every scan (`WalletHistoryService.refresh`): five
    /// scans each reading it were five identical requests to the logs endpoint, outside the gate, beside the scans' own.
    /// Nil: the head couldn't be read, so the chain wasn't reached and nothing moves, as when the refresh reads it itself.
    public func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget, at latest: BlockHeader?) async -> HistoryEntry {
        await refresh(scan, wallet: wallet, budget: budget, head: .given(latest))
    }

    /// Where a refresh's head comes from: read by the refresh, or given by its caller (nil: it couldn't be read).
    private enum Head: Sendable {
        case read
        case given(BlockHeader?)
    }

    private func refresh(_ scan: HistoryScan, wallet: Address, budget: LogsBudget, head: Head) async -> HistoryEntry {
        let key = Self.key(scan, wallet)
        if let running = refreshing[key] { return await running.value }
        let task = Task { await self.read(scan, wallet: wallet, key: key, budget: budget, head: head) }
        refreshing[key] = task
        let entry = await task.value
        // Its own only: an adoption waiting for it may have cleared it and started meanwhile (`adopt`).
        if refreshing[key] == task { refreshing[key] = nil }
        return entry
    }

    /// Forgets everything held for `wallet` (an erase of this device's data, or a spot check that found the server's
    /// history wrong, `ServerHistorySync.spotCheck`): memory, disk — the server's history taken in with the rest, its floor
    /// (`HistoryEntry.floorOverride`), epoch (`serverEpoch`) and first transaction (`serverFirstTransaction(wallet:)`) — and
    /// whatever a refresh or an adoption under way reads after this. A refresh asked after it never joins one under way
    /// from before (`refreshing` is let go): that one started from entries now gone, and gives back what is held now, never
    /// what it started from (`read`). In the first cut of the server's history a refresh asked after a spot check's
    /// mismatch joined the round under way and was handed the entries the chain had just contradicted, the server's logs
    /// among them, on screen until the next round — up to a top-up's minute and a half.
    public func forget(wallet: Address) {
        erasures += 1
        let prefix = "\(wallet.hex.lowercased())-"
        for key in Set(entries.keys).union(refreshing.keys) where key.hasPrefix(prefix) {
            entries[key] = nil
            refreshing[key] = nil
            resets[key, default: 0] += 1
        }
        serverFirst[wallet.hex.lowercased()] = nil
        serverFirstLoaded.insert(wallet.hex.lowercased())
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(wallet.hex.lowercased())) }
    }

    private func read(_ scan: HistoryScan, wallet: Address, key: String, budget: LogsBudget, head given: Head) async -> HistoryEntry {
        var entry = cached(scan, wallet: wallet)
        let erasure = erasures, generation = resets[key, default: 0]
        // Whether the wallet was forgotten, or the entry reset (`apply(epoch:)`), since the read started: then nothing it
        // read is kept, and a reset entry is never written back with what the server's history had added to it.
        func stale() -> Bool { erasures != erasure || resets[key, default: 0] != generation }
        // Keeps the entry, in memory and on disk, unless it went stale meanwhile.
        func keep(_ entry: HistoryEntry) {
            guard !stale() else { return }
            entries[key] = entry
            save(entry, scan, wallet)
        }
        // What the caller is given: the entry as read — or, gone stale meanwhile (forgotten, reset), what is held now, never
        // what it started from: the entries an erase or a reset dropped, nor a read that wasn't kept.
        func current(_ entry: HistoryEntry) -> HistoryEntry {
            stale() ? cached(scan, wallet: wallet) : entry
        }
        // The head: read now, or the one the round read for every scan.
        let header: BlockHeader?
        switch given {
        case .read: header = await router.latest()
        case .given(let read): header = read
        }
        guard let latest = header else {
            entry.reachedChain = false
            if !stale() { entries[key] = entry }
            return current(entry)
        }
        let head = latest.number
        entry.reachedChain = true
        // The scan's floor (`HistoryEntry.floor(of:head:)`: its own, or the older one a read of the server's history
        // proved; never below the logs the cap kept), never below a local fork's first block either (the fork answers no
        // logs under it, and the endpoint behind it refuses the wide ranges).
        var floor = entry.floor(of: scan, head: head)
        if let fork = await router.localForkBlock() { floor = max(floor, min(fork, head)) }
        let started = ContinuousClock.now
        var requests = 0
        func remaining() -> LogsBudget? {
            let elapsed = (ContinuousClock.now - started).components
            let seconds = budget.seconds - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18
            let left = budget.requests - requests
            return left > 0 && seconds > 0 ? LogsBudget(requests: left, seconds: seconds) : nil
        }
        // Every read is the history's, at the gate (`LogsGate.Lane.history`): behind the screen the user is looking at, ahead
        // of the background. The blocks since the newest read, from `overlap` below it, first — unless what was read lies
        // below the window now (the app unopened for longer than it), when the gaps below read down from the head instead.
        // Every read is given the round's head: the router keeps the blocks within `LogsEndpoints.headLag` of it from the
        // endpoints that clamp (`LogsEndpoint.clamps`), and only those — a gap far below it is theirs to read whole. Those
        // newest blocks wait for an endpoint that refuses past its head (rpc2) while it rests, within the read's seconds:
        // the read of the new blocks has half the round's, so rpc2 throttled or down can't take the gaps' time as well,
        // and the newest blocks it couldn't read aren't waited for twice in a round — the next round reads them anyway.
        var askedToTheHead = false
        if let newest = entry.covered.last, newest.upperBound < head, newest.upperBound >= floor, let budget = remaining() {
            let from = newest.upperBound > Self.overlap ? newest.upperBound - Self.overlap : 0
            let read = await router.read(scan.query, from: max(from, floor), to: head, head: head, order: .ascending,
                                         budget: LogsBudget(requests: budget.requests, seconds: budget.seconds / 2), lane: .history)
            requests += read.requests
            entry.merge(read)
            askedToTheHead = true
        }
        // Then the gaps back to the floor, newest first, each read down from its end.
        entry.head = head
        entry.headTimestamp = latest.timestamp
        entry.floor = floor
        for gap in entry.gaps(head: head, floor: floor) {
            if askedToTheHead, head - gap.lowerBound < LogsEndpoints.headLag { continue }
            guard let budget = remaining(), !Task.isCancelled else { break }
            let read = await router.read(scan.query, from: gap.lowerBound, to: gap.upperBound, head: head, order: .descending, budget: budget, lane: .history)
            requests += read.requests
            entry.merge(read)
            keep(entry)
            // No request went out: no endpoint could take the gap within the budget, and none will take an older one —
            // unless this one lies within `headLag` of the head, kept for an endpoint that refuses past its head (resting
            // now), while those that clamp may still read the gaps below.
            if read.requests == 0, head - gap.lowerBound >= LogsEndpoints.headLag { break }
        }
        entry.trim(floor: floor)
        entry.updatedAt = Date()
        keep(entry)
        return current(entry)
    }

    // MARK: The server's history

    /* What the server's cache of the wallet's history (`HistoryServerClient`) adds to an entry. The data is display-only,
       and only ever adds coverage the read proves (`ServerScan.adoptable`); the device's newest-first rounds read every
       block it doesn't cover — holes, omitted logs' blocks, the margin below the head — as any other gap. */

    /// `erasureMark` under the name the server contract gives it (§16): taken before a read of the server's history and
    /// handed to `adopt`, so that what was read before an erase is never taken in after it. One count, one doc
    /// (`erasureMark`'s), so the two can't drift apart.
    public func erasureToken() -> Int { erasureMark }

    /// Takes in what one read of the server's history (`HistoryServerClient`) holds of `scan` for `wallet`, and returns
    /// the entry as it then stands; nil, with nothing changed, when it refuses. Refused unless the server's filter takes
    /// the scan's (`LogsQuery.isSubset(of:)`: the app may know a cohort the server doesn't yet), the read proves some blocks
    /// (`ServerScan.adoptable`, within the bounds it speaks for; never a read of the metadata alone), no erase of this
    /// device's data came since `erasureToken` (taken before the read), and `epoch` (the owner's history epoch the read
    /// was made under) is no lower than the one applied (`apply(epoch:)`). Serialised with the refreshes (`refreshing`): it
    /// waits for one under way, and one asked for meanwhile joins it, so neither writes the entry over what the other
    /// added. Then:
    /// - the logs the scan matches in the adoptable blocks join the entry, and the blocks its coverage, each log once
    ///   (`merge`): coverage and logs only grow;
    /// - the head is the newer of the entry's and the server's: the next round reads from `overlap` below the newest
    ///   covered block, about 2,400 below the server's head, one request a scan on rpc2;
    /// - the cap floor is the higher of the two when the server's filter is the scan's own (the server's comes from the
    ///   same 20,000-log rule; holes never raise it: they are gaps the device reads). A wider filter's — a cohort or stack
    ///   this build lacks — counts logs the scan never matches, so its cap can sit far above where the device's own would:
    ///   what is adopted stops at it already (`ServerScan.adoptable`), and the device reads below it under its own cap,
    ///   never dropping its own older logs for it (`sameFilter`);
    /// - a transfer scan the read served whole from genesis with nothing left out — a full read (no bounds), finished,
    ///   complete, no hole, no omitted log, and its adoptable blocks one unbroken range from that floor, which the document
    ///   itself proves, whatever its `complete` says — has its floor there from now on (`HistoryEntry.floorOverride`);
    ///   otherwise the scan's own floor stands (the wallet's first transaction, or 30 days) and what lies below it is
    ///   dropped (`trim`), as for the global scans, whose floors are the same on both sides: the device never takes on a
    ///   floor it would have to read down to itself;
    /// - the entry is marked with `epoch` (`HistoryEntry.serverEpoch`), trimmed to the cap, and saved.
    ///
    /// `chainHead`: the chain's head as the device read it (`WalletHistoryService.adopt` reads it); a read whose head is
    /// past it speaks for blocks the device can't prove exist, and is refused. Nil: not checked.
    public func adopt(_ server: ServerScan, scan: HistoryScan, wallet: Address, erasureToken: Int, epoch: Int, chainHead: UInt64? = nil) async -> HistoryEntry? {
        guard Self.takes(server, for: scan, chainHead: chainHead), erasureToken == erasures, epoch >= self.epoch else { return nil }
        let key = Self.key(scan, wallet)
        // A refresh under way finishes first, and this starts from what it kept. One that ended is cleared here as well as
        // by its caller, whichever comes first, so this never waits on it twice.
        while let running = refreshing[key] {
            _ = await running.value
            if refreshing[key] == running { refreshing[key] = nil }
        }
        guard erasureToken == erasures, epoch >= self.epoch else { return nil }
        let work = Task { await self.absorb(server, scan: scan, wallet: wallet, key: key, erasure: erasureToken, epoch: epoch) }
        let slot = Task { await work.value.entry }
        refreshing[key] = slot
        let outcome = await work.value
        if refreshing[key] == slot { refreshing[key] = nil }
        return outcome.adopted ? outcome.entry : nil
    }

    /// The checks of `adopt` that need nothing but the read and the scan: the same scan, logs to take in (not the
    /// metadata alone), the scan's filter within the server's, and adoptable blocks within the bounds the read speaks
    /// for, below a head with its time — one no later than `chainHead`, when given.
    static func takes(_ server: ServerScan, for scan: HistoryScan, chainHead: UInt64? = nil) -> Bool {
        guard let head = server.head, server.headTimestamp != nil, head <= chainHead ?? .max else { return false }
        return server.id == scan.id && !server.metaOnly && !server.adoptable.isEmpty && server.from <= server.to
            && server.adoptable.allSatisfy { $0.lowerBound >= server.from && $0.upperBound <= server.to }
            && scan.query.isSubset(of: server.query)
    }

    /// The floor a read proves for a transfer scan (`HistoryEntry.floorOverride`), or nil: a full read that finished the
    /// scan with nothing left out — no hole, no omitted log — said complete, and whose adoptable blocks are one range
    /// starting at the server's floor (or the cap floor above it, when the server's filter is the scan's own: a wider
    /// one's cap proves nothing of the scan's older logs, `sameFilter`), so every block from there to the trust margin is
    /// in it.
    static func provedFloor(_ server: ServerScan, for scan: HistoryScan) -> UInt64? {
        let floor = max(server.floor, sameFilter(server, scan) ? server.capSeen ?? 0 : 0)
        guard server.kind == .wallet, !server.bounded, !server.metaOnly, server.finished, server.complete, server.holes.isEmpty, server.omittedBlocks.isEmpty,
              server.adoptable.count == 1, server.adoptable[0].lowerBound <= floor else { return nil }
        return floor
    }

    /// Whether the server's filter is the scan's own, in whatever order its lists come (`LogsQuery.canonicalFingerprint`):
    /// only then do the server's cap and the device's count the same logs (`absorb`, `provedFloor`). `isSubset(of:)` takes
    /// a wider one too, on purpose (`takes`).
    static func sameFilter(_ server: ServerScan, _ scan: HistoryScan) -> Bool {
        scan.query.canonicalFingerprint == server.query.canonicalFingerprint
    }

    /// `adopt`'s work, alone on the entry: what the entry holds then, and whether it took the read in.
    private func absorb(_ server: ServerScan, scan: HistoryScan, wallet: Address, key: String, erasure: Int, epoch: Int) async -> (entry: HistoryEntry, adopted: Bool) {
        var entry = cached(scan, wallet: wallet)
        let generation = resets[key, default: 0]
        let blocks = server.adoptable
        let logs = server.logs.filter { scan.query.matches($0) && BlockRanges.contains(blocks, $0.blockNumber) }
        entry.merge(LogsRead(logs: logs, covered: blocks, requests: 0))
        entry.adopted = LogsRead.merge(entry.adopted + blocks)
        if let head = server.head, let timestamp = server.headTimestamp, head > (entry.head ?? 0) {
            entry.head = head
            entry.headTimestamp = timestamp
        }
        if let cap = server.capSeen, Self.sameFilter(server, scan) { entry.capFloor = max(entry.capFloor ?? 0, cap) }
        if let proved = Self.provedFloor(server, for: scan) { entry.floorOverride = proved }
        guard let head = entry.head else { return (cached(scan, wallet: wallet), false) }
        var floor = entry.floor(of: scan, head: head)
        if let fork = await router.localForkBlock() { floor = max(floor, min(fork, head)) }
        // Forgotten, reset, or a later epoch applied meanwhile: nothing of the read is kept.
        guard erasures == erasure, resets[key, default: 0] == generation, epoch >= self.epoch else { return (cached(scan, wallet: wallet), false) }
        entry.floor = floor
        entry.serverEpoch = epoch
        entry.trim(floor: floor)
        entry.updatedAt = Date()
        entries[key] = entry
        save(entry, scan, wallet)
        return (entry, true)
    }

    /// Applies the owner's history epoch (`historyEpoch` in the flags of the app_config row, `RemoteFlags`: at launch and
    /// at each read of the flags, whether or not the server's history is on): every entry that took the server's history in under a lower one is reset — its
    /// logs, coverage, head, floors and cap floor dropped, its file deleted — and read again from nothing by the next
    /// round, nothing a refresh or an adoption under way reads after this kept; one held on disk only is reset when it is
    /// loaded (`cached`). Entries that never took it in are untouched. The wallet's first transaction as the server found
    /// it goes the same way (`serverFirstTransaction(wallet:)`): the transfer scans' floor is then the device's own again,
    /// from their next round. How many entries in memory were reset.
    @discardableResult
    public func apply(epoch: Int) -> Int {
        self.epoch = max(0, epoch)
        var reset = 0
        for (key, entry) in entries where Self.adopted(entry, before: self.epoch) {
            entries[key] = .empty
            resets[key, default: 0] += 1
            if let file = file(forKey: key) { try? FileManager.default.removeItem(at: file) }
            reset += 1
        }
        for (key, held) in serverFirst where held.epoch < self.epoch {
            serverFirst[key] = nil
            if let wallet = Address(key), let file = file(named: Self.serverFirstName, wallet) { try? FileManager.default.removeItem(at: file) }
        }
        return reset
    }

    /// Whether `entry` took the server's history in under an epoch lower than `epoch`.
    private static func adopted(_ entry: HistoryEntry, before epoch: Int) -> Bool {
        entry.serverEpoch.map { $0 < epoch } ?? false
    }

    /// Runs `work` here, unless a wallet was forgotten since `token` (`erasureToken()`): for what is kept outside the
    /// store about the server's history — the spot check's day and the distrust, in UserDefaults
    /// (`ServerHistorySync.spotCheck`) — so that nothing read before an erase of this device's data is written after it.
    /// Whether it ran.
    @discardableResult
    public func unlessErased(since token: Int, _ work: @Sendable () -> Void) -> Bool {
        guard erasures == token else { return false }
        work()
        return true
    }

    // MARK: The wallet's first transaction, as the server found it

    /* The block of the wallet's first transaction a read of the server's history found (`ServerFirstTransaction.found`,
       confirmed there on a second endpoint), kept apart from the one the device found itself (`WalletHistoryService`'s
       `knownFirstActivity`, in UserDefaults). It deepens the transfer scans' floor as that one does, and like what the
       server added to the entries it is the server's: dropped by the owner's history epoch (`apply(epoch:)`), by an erase
       of this device's data and by a spot check that found the server wrong (`forget`). In the first cut of the server's
       history it was written where the device keeps its own, for good: a block wrong-early deepened every transfer scan's
       floor past every switch — at block 1, some 11,000 requests a scan on rpc2, "All" near 0% for as long. Kept beside
       the scans under its own name, with the epoch it was taken in under. */

    private struct ServerFirstBlock: Codable, Sendable {
        var version = 1
        let block: UInt64
        let epoch: Int
    }

    /// Where the server's first transaction is kept beside the scans (`keep(_:named:wallet:since:)`): never a scan's id.
    static let serverFirstName = "server-first-transaction"
    /// What is held of it, by wallet (lowercase hex), and the wallets whose file was looked for already.
    private var serverFirst: [String: ServerFirstBlock] = [:]
    private var serverFirstLoaded: Set<String> = []

    /// The block of `wallet`'s first transaction as the server's history found it, taken in under the epoch applied now
    /// (`adopt(firstTransaction:wallet:erasureToken:epoch:)`); nil when none was, or what was taken in under a lower one,
    /// which is dropped as it loads.
    public func serverFirstTransaction(wallet: Address) -> UInt64? {
        let key = wallet.hex.lowercased()
        if serverFirstLoaded.insert(key).inserted, let stored = kept(ServerFirstBlock.self, named: Self.serverFirstName, wallet: wallet), stored.version == 1 {
            if stored.epoch < epoch {
                if let file = file(named: Self.serverFirstName, wallet) { try? FileManager.default.removeItem(at: file) }
            } else {
                serverFirst[key] = stored
            }
        }
        return serverFirst[key]?.block
    }

    /// Takes in `block`, the wallet's first transaction as a read of the server's history found it, when it is earlier
    /// than the one held from the server (a block only ever moves earlier) — unless an erase of this device's data came
    /// since `erasureToken` (taken before the read) or `epoch` (the one the read was made under) is lower than the one
    /// applied. Whether it was taken in.
    @discardableResult
    public func adopt(firstTransaction block: UInt64, wallet: Address, erasureToken: Int, epoch: Int) -> Bool {
        guard erasureToken == erasures, epoch >= self.epoch else { return false }
        if let held = serverFirstTransaction(wallet: wallet), held <= block { return false }
        let value = ServerFirstBlock(block: block, epoch: epoch)
        serverFirst[wallet.hex.lowercased()] = value
        keep(value, named: Self.serverFirstName, wallet: wallet, since: erasureToken)
        return true
    }

    // MARK: Disk

    /// One log as kept: `s`, its block's timestamp (`Log.blockTimestamp`), is optional — left out when the endpoint gave
    /// none, and absent from every log kept before the app read it — so the files kept before it load as they are, still
    /// version 2, and the next read of their blocks adds it (`HistoryEntry.merge`).
    private struct StoredLog: Codable {
        let a: String, t: [String], d: String, b: UInt64, h: String, i: Int
        let s: Int?
        init(_ log: Log) {
            a = log.address.hex; t = log.topics.map(\.hexString); d = log.data.hexString; b = log.blockNumber; h = log.transactionHash.hexString; i = log.logIndex
            s = log.blockTimestamp
        }
        var log: Log? {
            guard let address = Address(a), let data = Data(hex: d), let hash = Data(hex: h) else { return nil }
            var topics: [Data] = []
            for topic in t { guard let bytes = Data(hex: topic) else { return nil }; topics.append(bytes) }
            return Log(address: address, topics: topics, data: data, blockNumber: b, transactionHash: hash, logIndex: i, blockTimestamp: s)
        }
    }

    private struct Stored: Codable {
        var version = 2
        /// The filter the logs were read with (`LogsQuery.fingerprint`): a file read with another is started over.
        var query: String
        var covered: [[UInt64]]
        var head: UInt64?
        var headTimestamp: Int?
        var floor: UInt64?
        var capFloor: UInt64?
        /// `HistoryEntry.floorOverride` and `serverEpoch`: optional, left out when nil, so the files kept before them load
        /// as they are, still version 2.
        var floorOverride: UInt64?
        var serverEpoch: Int?
        /// `HistoryEntry.adopted`, as `covered` is kept: optional, left out when there is none, still version 2.
        var adopted: [[UInt64]]?
        var updatedAt: Date?
        var logs: [StoredLog]
    }

    private func file(_ scan: HistoryScan, _ wallet: Address) -> URL? {
        file(named: scan.id, wallet)
    }

    /// The file of the entry held under `key` (`key(_:_:)`: the wallet's 42 characters, a dash, the scan's id).
    private func file(forKey key: String) -> URL? {
        guard key.count > 43, let wallet = Address(String(key.prefix(42))) else { return nil }
        return file(named: String(key.dropFirst(43)), wallet)
    }

    private func file(named name: String, _ wallet: Address) -> URL? {
        directory?.appendingPathComponent(wallet.hex.lowercased()).appendingPathComponent("\(name).json")
    }

    private func load(_ scan: HistoryScan, _ wallet: Address) -> HistoryEntry? {
        guard let file = file(scan, wallet), let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == 2, stored.query == scan.query.fingerprint else { return nil }
        var logs: [Log] = []
        for item in stored.logs { guard let log = item.log else { return nil }; logs.append(log) }
        func ranges(_ pairs: [[UInt64]]) -> [ClosedRange<UInt64>] {
            LogsRead.merge(pairs.compactMap { pair -> ClosedRange<UInt64>? in pair.count == 2 && pair[0] <= pair[1] ? pair[0]...pair[1] : nil })
        }
        let covered = ranges(stored.covered)
        // What the server added is never more than what is covered, whatever the file says.
        let adopted = covered.flatMap { BlockRanges.intersect(ranges(stored.adopted ?? []), $0) }
        return HistoryEntry(logs: logs, covered: covered, head: stored.head, headTimestamp: stored.headTimestamp, floor: stored.floor, capFloor: stored.capFloor,
                            updatedAt: stored.updatedAt, floorOverride: stored.floorOverride, serverEpoch: stored.serverEpoch, adopted: adopted)
    }

    private func save(_ entry: HistoryEntry, _ scan: HistoryScan, _ wallet: Address) {
        guard let file = file(scan, wallet) else { return }
        let stored = Stored(query: scan.query.fingerprint, covered: entry.covered.map { [$0.lowerBound, $0.upperBound] }, head: entry.head, headTimestamp: entry.headTimestamp,
                            floor: entry.floor, capFloor: entry.capFloor, floorOverride: entry.floorOverride, serverEpoch: entry.serverEpoch,
                            adopted: entry.adopted.isEmpty ? nil : entry.adopted.map { [$0.lowerBound, $0.upperBound] }, updatedAt: entry.updatedAt,
                            logs: entry.logs.map(StoredLog.init))
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Beside the scans

    /* What is built from a wallet's scans and costs reads to build again — each transaction's facts (`WalletHistoryService`),
       the reference its records were last matched with — is kept in the same folder as the scans, under its own name
       (never a scan's id), so it loads with them, from the device, and `forget` erases it with them. */

    /// Counts the erasures so far (`forget`): what a caller read before one is kept only when none came between — beside
    /// the scans (`keep(_:named:wallet:since:)`), or taken in from the server's history (`adopt`, where the contract calls
    /// it `erasureToken()`).
    public var erasureMark: Int { erasures }

    /// What is kept beside `wallet`'s scans under `name`; nil when nothing is, there is no folder (tests), or it can't be
    /// read as `type`.
    public func kept<T: Decodable & Sendable>(_ type: T.Type, named name: String, wallet: Address) -> T? {
        guard let file = file(named: name, wallet), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Keeps `value` beside `wallet`'s scans under `name` — unless the wallet was forgotten since `mark` (`erasureMark`):
    /// an erase of this device's data keeps nothing read before it.
    public func keep<T: Encodable & Sendable>(_ value: T, named name: String, wallet: Address, since mark: Int) {
        guard erasures == mark, let file = file(named: name, wallet), let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension HistoryEntry {
    /// Adds what a read covered and found, each log once. A log held without its block's timestamp (kept before the app
    /// read it) takes the one a new read of it carries — the overlap of every refresh, a gap read again.
    mutating func merge(_ read: LogsRead) {
        guard !read.covered.isEmpty else { return }
        covered = LogsRead.merge(covered + read.covered)
        var held = Dictionary(logs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for log in read.logs {
            if let index = held[log.id] {
                if logs[index].blockTimestamp == nil, log.blockTimestamp != nil { logs[index] = log }
            } else {
                held[log.id] = logs.count
                logs.append(log)
            }
        }
        logs.sort { a, b in a.blockNumber == b.blockNumber ? a.logIndex < b.logIndex : a.blockNumber < b.blockNumber }
    }

    /// Drops what lies below `floor`, and the oldest logs past the cap with the coverage they came from: from then on
    /// the floor is where the kept logs start (`capFloor`), so the entry can be complete without what was dropped.
    mutating func trim(floor: UInt64) {
        var cut = floor
        if logs.count > HistoryStore.logCap {
            let kept = logs[logs.count - HistoryStore.logCap].blockNumber
            if kept > cut {
                cut = kept
                capFloor = max(capFloor ?? 0, kept)
                self.floor = max(self.floor ?? 0, kept)
            }
        }
        guard cut > 0 else { return }
        logs.removeAll { $0.blockNumber < cut }
        covered = covered.compactMap { range in
            guard range.upperBound >= cut else { return nil }
            return max(range.lowerBound, cut)...range.upperBound
        }
        adopted = BlockRanges.intersect(adopted, cut...UInt64.max)
    }
}
