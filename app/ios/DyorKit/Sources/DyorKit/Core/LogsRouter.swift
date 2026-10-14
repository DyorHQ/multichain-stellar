import BigInt
import Foundation

/* Where the app's `eth_getLogs` go, and how a wallet's history is read: the design in full, with `HistoryStore` and the
   app's `HistoryModel`.

   Monad's public endpoints each answer a range of so many blocks per `eth_getLogs`, every one far short of a wallet's
   history (about 111M blocks), measured 2026-10-08 from the owner's network:
   - rpc2.monad.xyz: 10,000 blocks; address lists and topic lists accepted; a batch of 6 ranges in one request; 4
     requests a second sustained without a refusal, about 1 in 5 refused (HTTP 429) at 11 a second. Refuses a range
     that ends past its node's head (-32014 "… is not yet available on the node").
   - rpc4.monad.xyz: 1,000 (some nodes answer any range, most refuse over 1,000); refuses a batch with -32603.
   - rpc3.monad.xyz: 1,000, a request's ranges counted together.
   - rpc1.monad.xyz: 100 (it answered any wallet-scoped range until 2026-10-08); HTTP 429 after a burst; any
     JSON-RPC batch, of any method, answered HTTP 403 "Restricted JSON RPC method" (2026-10-09): one range a request.
   - rpc.monad.xyz: 100; the app's client for everything else.
   Build 21 and earlier asked rpc1 for the whole history on every screen (about 40 scans at once when Home opened),
   split every refusal into smaller ranges and had no time limit, so on today's endpoints every history screen spun
   for minutes and showed 0.

   A range that ends past the answering node's head is refused by rpc2 alone (measured 2026-10-08/09). rpc4, rpc3 and
   rpc1 — and rpc.monad.xyz, taken to, unmeasured — answer it CLAMPED: the logs up to that node's head, those of the
   blocks past it simply missing, with no error, which reads exactly as blocks with no logs; and a node of theirs can be
   hundreds of blocks behind. In build 22 and earlier such an answer marked every block of the range read, and the next
   round read again only the 20 blocks below the newest one read: a transfer in the blocks left out was never seen, on
   any screen, however many rounds later.

   The design:
   1. One logs router, every endpoint (this file). A scan is a window of blocks; the router cuts it into ranges of
      what the endpoint answers (learned from its refusals and remembered for a day), sends them in batches, and
      moves to the next endpoint when one throttles or fails. Every `eth_getLogs` in the app goes through one gate
      (`LogsGate`): a few in flight, a few a second, so the app never throttles itself; a screen's requests go through
      it first, then the history's (or the history's first, once one has waited a moment), then the background's, one
      at a time. A scan has a budget of
      requests and seconds; past it, the caller gets what was read and exactly which blocks it covers (`LogsRead`),
      never a part passed off as the whole. A range refused for how many logs it holds is split, not taken for the
      endpoint's span. For a read whose answer is kept as coverage — the wallet's history and its spot check, which pass
      the round's head — an endpoint that clamps (`LogsEndpoint.clamps`) is asked only for blocks at least 600 below the
      head (`LogsEndpoints.headLag`): the newest blocks go to one that refuses past its head — waited for while the
      scan's deadline lasts, else left unread, a gap like any other — never to one that would answer them short. A
      screen's read may ask any endpoint for any block, as in build 22, and is never kept — but for the newest 600
      blocks' share: a Moment coin's holder count keeps only blocks at least that far below the head
      (`MomentHolderTally.settleBlocks`).
   2. A history store per wallet (`HistoryStore`): five scans (transfers in and out, launchpad, fee sharing,
      Moments), each kept on disk with the blocks it covers. A refresh reads the blocks since the last one first, from
      1,200 below the newest read (`HistoryStore.overlap`) so that what a clamped answer could have left out is read
      again, in at most half its seconds; then the gaps back to the floor while its budget lasts. The cursor never
      moves past a block that wasn't read. The transfer scans read back to the wallet's first transaction (found once
      by bisection over its nonce at past blocks) or 30 days, whichever is earlier; the rest from their contracts'
      deployment.
   3. Screens publish what they have (`WalletHistoryService`, the app's `HistoryModel`): what the app recorded shows
      at once, chain history fills in behind ("Reading your history… 28%"), and a source that couldn't be read says
      so with Retry, never replacing what the last good read showed. Rounds of up to 40 requests per scan, a second
      apart, every 90 s once complete; rounds that read nothing come further apart (20 s doubling to 10 min), and
      from the third in a row the screens say what is left couldn't be read; a return to the app, a pull or a Retry
      starts a round at once. */

/// A public endpoint for `eth_getLogs`: the widest range it answers per request, as measured, how many ranges one
/// request may carry, and whether it answers a range past its node's head short (`clamps`).
public struct LogsEndpoint: Sendable, Hashable {
    public let url: URL
    /// The widest block range (inclusive) one `eth_getLogs` of this endpoint answers.
    public let span: UInt64
    /// Ranges one request carries: 1 where the endpoint counts a request's ranges together (rpc3) or refuses a batch
    /// (rpc4 answers a batch of ranges with an internal error, rpc1 any batch with HTTP 403). One range is then sent as
    /// a single JSON-RPC object, never an array (`RPCClient.batch`).
    public let batch: Int
    /// Whether the endpoint answers state at any past block (a nonce, a balance): rpc1, rpc2 and rpc4 do; rpc3 and
    /// rpc.monad.xyz refuse old blocks ("historical state that is not available", measured 2026-10-08).
    public let archive: Bool
    /// Whether the endpoint may answer a range that ends past its node's head CLAMPED — the logs up to that node's head,
    /// those of the blocks past it simply missing, with no error — rather than refuse it. A clamped answer reads exactly
    /// as blocks with no logs, so such an endpoint is never asked for a block within `LogsEndpoints.headLag` of the head
    /// by a read whose answer is kept (the wallet's history, given the round's head: `LogsRouter.read`). Measured
    /// 2026-10-08/09: rpc2 refuses (`RPCClient.refusesPastHead`); rpc4, rpc3 and rpc1 clamp, a node of theirs hundreds
    /// of blocks behind at times; rpc.monad.xyz is taken to. True unless known
    /// otherwise: an endpoint nobody measured is the kind that can't lose a log. A local fork is one node and the head
    /// the router reads is its own, so it is never behind it: it clamps nothing.
    public let clamps: Bool

    public init(url: URL, span: UInt64, batch: Int = 6, archive: Bool = false, clamps: Bool = true) {
        self.url = url
        self.span = max(1, span)
        self.batch = max(1, batch)
        self.archive = archive
        self.clamps = clamps
    }
}

public enum LogsEndpoints {
    /// Monad mainnet's public endpoints for logs, the widest first, as measured on 2026-10-08 and 09.
    public static let monadMainnet: [LogsEndpoint] = [
        LogsEndpoint(url: URL(string: "https://rpc2.monad.xyz")!, span: 10_000, archive: true, clamps: false),
        LogsEndpoint(url: URL(string: "https://rpc4.monad.xyz")!, span: 1_000, batch: 1, archive: true, clamps: true),
        LogsEndpoint(url: URL(string: "https://rpc3.monad.xyz")!, span: 1_000, batch: 1, clamps: true),
        LogsEndpoint(url: URL(string: "https://rpc1.monad.xyz")!, span: 100, batch: 1, archive: true, clamps: true),
        LogsEndpoint(url: URL(string: "https://rpc.monad.xyz")!, span: 100, clamps: true),
    ]
    /// The endpoints that answer state at past blocks, in order: a client for old nonces and balances fails over
    /// among these only (`RPCClient(urls:)`), never onto one that refuses them.
    public static var archive: [URL] { monadMainnet.filter(\.archive).map(\.url) }
    /// The smallest range any endpoint is asked for: what every one of them answers.
    public static let floorSpan: UInt64 = 100
    /// How far behind the head a clamping endpoint's node is taken to be, at most (`LogsEndpoint.clamps`): the wallet's
    /// history asks such an endpoint only for blocks at least this far below the head, and the newer ones wait for an
    /// endpoint that refuses past its head (`LogsRouter.read`). 600 blocks, about three minutes: the nodes measured behind
    /// were hundreds of blocks so, and the server's history indexer keeps the same margin (`history-indexer/endpoints.ts`,
    /// `lag`). One rpc2 range of 10,000 blocks holds it many times over, so the blocks it keeps from the clamping
    /// endpoints cost rpc2 one range a scan.
    public static let headLag: UInt64 = 600
}

/// An `eth_getLogs` filter with the lists the method allows: any of `addresses` (none: every contract), and at each
/// topic position any of the topics listed there (nil: anything).
public struct LogsQuery: Sendable, Hashable {
    public var addresses: [Address]
    public var topics: [[Data]?]

    public init(addresses: [Address] = [], topics: [[Data]?] = []) {
        self.addresses = addresses
        self.topics = topics
    }

    /// The single-address, single-topic form every older scan uses.
    public init(address: Address?, topics: [Data?]) {
        self.init(addresses: address.map { [$0] } ?? [], topics: topics.map { $0.map { [$0] } })
    }

    /// The filter as text, the same for the same filter: what a stored scan is checked against (`HistoryStore`).
    public var fingerprint: String {
        addresses.map { $0.hex.lowercased() }.joined(separator: ",") + "|"
            + topics.map { $0.map { $0.map(\.hexString).joined(separator: "+") } ?? "*" }.joined(separator: ",")
    }

    func json(from: UInt64, to: UInt64) -> JSON {
        var object: [String: JSON] = ["fromBlock": .string(BigUInt(from).hexQuantity), "toBlock": .string(BigUInt(to).hexQuantity)]
        if addresses.count == 1 { object["address"] = .string(addresses[0].hex) } else if addresses.count > 1 { object["address"] = .array(addresses.map { .string($0.hex) }) }
        if !topics.isEmpty {
            object["topics"] = .array(topics.map { position in
                guard let position else { return .null }
                return position.count == 1 ? .string(position[0].hexString) : .array(position.map { .string($0.hexString) })
            })
        }
        return .object(object)
    }

    /// Whether `log` matches the filter, as the endpoint matches it.
    public func matches(_ log: Log) -> Bool {
        if !addresses.isEmpty, !addresses.contains(log.address) { return false }
        for (i, position) in topics.enumerated() {
            guard let position else { continue }
            guard log.topics.indices.contains(i), position.contains(log.topics[i]) else { return false }
        }
        return true
    }

    /// Whether every log this filter matches, `other` matches too — so a range read whole for `other` holds every log of
    /// this filter in it, and its coverage counts for this one (`HistoryStore.adopt`: the app's scan against the server
    /// history cache's, `history_read`'s `query`). The lists are sets, in any order. `other` takes this filter when it
    /// names no address, or this one names some and every one is among `other`'s; and at every topic position (a
    /// position past the end of a list is nil, anything) when `other` has nil there, or this one lists topics there and
    /// every one is among `other`'s. Not a subset — the app knows a cohort the server doesn't yet — and the scan is read
    /// from the chain, as before.
    public func isSubset(of other: LogsQuery) -> Bool {
        if !other.addresses.isEmpty {
            guard !addresses.isEmpty, Set(addresses).isSubset(of: Set(other.addresses)) else { return false }
        }
        for position in 0..<max(topics.count, other.topics.count) {
            guard position < other.topics.count, let theirs = other.topics[position] else { continue }
            guard position < topics.count, let mine = topics[position], Set(mine).isSubset(of: Set(theirs)) else { return false }
        }
        return true
    }

    /// `fingerprint` with every list sorted: the same text for the same filter, in whatever order its lists were built —
    /// the form the server's history cache prints for its scans (`history_read`'s `fingerprint`, its lists sorted in
    /// Postgres), for logs and diagnostics. What a stored scan is checked against stays `fingerprint`: the files kept
    /// before this keep loading.
    public var canonicalFingerprint: String {
        addresses.map { $0.hex.lowercased() }.sorted().joined(separator: ",") + "|"
            + topics.map { $0.map { $0.map(\.hexString).sorted().joined(separator: "+") } ?? "*" }.joined(separator: ",")
    }
}

/// What a scan may spend: requests across every endpoint, and seconds.
public struct LogsBudget: Sendable, Equatable {
    public var requests: Int
    public var seconds: TimeInterval

    public init(requests: Int, seconds: TimeInterval) {
        self.requests = requests
        self.seconds = seconds
    }

    /// What a `chunkedLogsReport` of each mode spends: fail-fast, the Send sheet's and the Portfolio holdings' read,
    /// which say what they couldn't read; patient, every screen's scan, which takes what was read; paced, the venue
    /// list's background read.
    public init(mode: LogScanMode) {
        switch mode {
        case .failFast: self.init(requests: 12, seconds: 15)
        case .patient: self.init(requests: 80, seconds: 30)
        case .paced: self.init(requests: 400, seconds: 120)
        }
    }
}

/// What a scan read: the logs, in block order, and exactly which blocks of its window were read (`covered`, merged,
/// ascending). A window is complete when one covered range holds it whole.
public struct LogsRead: Sendable, Equatable {
    public var logs: [Log]
    public var covered: [ClosedRange<UInt64>]
    public var requests: Int

    public init(logs: [Log], covered: [ClosedRange<UInt64>], requests: Int) {
        self.logs = logs
        self.covered = covered
        self.requests = requests
    }

    /// Whether every block from `from` to `to` was read.
    public func covers(_ from: UInt64, _ to: UInt64) -> Bool {
        from > to || covered.contains { $0.lowerBound <= from && $0.upperBound >= to }
    }

    /// The last block read in one piece from `from` (nil when `from` itself wasn't read).
    public func through(from: UInt64) -> UInt64? {
        covered.first { $0.contains(from) }?.upperBound
    }

    /// The first block read in one piece down from `to` (nil when `to` itself wasn't read).
    public func downTo(_ to: UInt64) -> UInt64? {
        covered.first { $0.contains(to) }?.lowerBound
    }

    /// `ranges` merged: sorted, and touching or overlapping ones joined.
    public static func merge(_ ranges: [ClosedRange<UInt64>]) -> [ClosedRange<UInt64>] {
        var out: [ClosedRange<UInt64>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, last.upperBound == UInt64.max || range.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}

/// Where a learned cap is kept between launches: an endpoint's refusals lower its span for the day.
public protocol LogsCapabilityStore: Sendable {
    func span(for url: URL) -> UInt64?
    func set(span: UInt64, for url: URL)
}

/// `LogsCapabilityStore` in UserDefaults, each span kept for a day: an endpoint may widen what it answers again.
/// UserDefaults is thread-safe, hence the unchecked conformance.
public struct UserDefaultsLogsCapabilityStore: LogsCapabilityStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let ttl: TimeInterval
    public init(defaults: UserDefaults = .standard, ttl: TimeInterval = 86_400) {
        self.defaults = defaults
        self.ttl = ttl
    }
    private func key(_ url: URL) -> String { "logsRouter.v1.span.\(url.host() ?? url.absoluteString)" }
    public func span(for url: URL) -> UInt64? {
        guard let saved = defaults.dictionary(forKey: key(url)), let span = saved["span"] as? String, let at = saved["at"] as? Double,
              Date().timeIntervalSince1970 - at < ttl else { return nil }
        return UInt64(span)
    }
    public func set(span: UInt64, for url: URL) {
        defaults.set(["span": String(span), "at": Date().timeIntervalSince1970], forKey: key(url))
    }
}

/// One gate for every `eth_getLogs` the app sends, whatever started it: a few requests in flight and a space between
/// their starts, so forty scans opening at once never throttle the app on an endpoint that counts requests a second per
/// client. Four a second: rpc2 answered 260 requests of six ranges at that pace with no refusal (measured 2026-10-08),
/// and refused one in five at eleven a second.
///
/// Requests wait in lanes (`Lane`), and a free slot goes to the request waiting longest in the highest lane: a screen the
/// user is looking at first, then the wallet's history rounds, then the background (the swap picker's venue list, read
/// from genesis), which never holds more than `backgroundSlots` of the slots, however many are free. In build 22 and
/// earlier the gate was first come first served: a screen's scan of five requests queued behind the history's twenty
/// and the venue list's four, 10–25 s, and the venue list's 5,600 requests from genesis took half the gate from a fresh
/// install's history, doubling its first fill. Now a screen's next request is through as soon as a slot frees (a
/// request answers in well under a second), and the venue list reads one request at a time, only while nothing else
/// waits.
///
/// The history's lane ages: once its oldest request has waited `historyWait` (2 s), the next free slot is its, ahead of
/// a screen's. A screen's scan asks four requests at once and queues its next before a slot frees, so with priority alone
/// a long one — an older coin's Launch page, 80 requests and more, about 22 s; a Retry tapped again and again — held
/// every history round back for as long as it read, and a minute and a half of it aged the history past what counts as
/// up to now (`HistoryCadence.freshFor`): screens showing final figures went back to "Reading your history… 99%" until
/// the round got through. A screen's scan now gives up at most one start in eight (one every 2 s, at four a second) while
/// the history waits.
///
/// A request is let through only as it starts — a slot free and the space after the last start passed — so one waiting
/// holds neither. One whose task is cancelled while it waits (its screen closed) leaves the queue at once and takes
/// nothing: no slot, and no start the next request must keep its space from. One cancelled the moment it was let
/// through, before its request went out, gives both back (`enter`). A closed screen costs the scans still reading no
/// time at the gate, where each queued request used to send a request that failed at once, a slot and a quarter of a
/// second each.
public actor LogsGate {
    /// Where a request waits: a slot goes to `interactive` first, then `history`, then `background`.
    public enum Lane: Sendable, Hashable {
        /// A scan a screen the user is looking at waits for: every `chunkedLogsReport`, unless it says otherwise.
        case interactive
        /// The wallet's history rounds (`HistoryStore`, `WalletHistoryService.refresh`): what every history screen fills
        /// in from, behind the screen in front of the user — until one has waited `historyWait`.
        case history
        /// Work nobody is waiting on (`VenueTokensService`'s venue list from genesis): behind everything, and never more
        /// than `backgroundSlots` of the slots at once.
        case background

        /// The lanes in the order a free slot goes to them.
        static let byPriority: [Lane] = [.interactive, .history, .background]
    }

    /// A slot taken (`enter`): handed back with `leave` once the request is answered.
    public struct Slot: Sendable {
        public let lane: Lane
    }

    public static let shared = LogsGate(inFlight: 4, interval: .milliseconds(250), backgroundSlots: 1)

    /// A request waiting: the order it came in, when, and what to tell it.
    private struct Waiter {
        let id: UInt64
        let since: ContinuousClock.Instant
        let continuation: CheckedContinuation<Grant?, Never>
    }

    /// A request let through: when it started, and the start before it — given back if its task was cancelled as it was
    /// let through (`enter`).
    private struct Grant: Sendable {
        let start: ContinuousClock.Instant
        let previous: ContinuousClock.Instant?
    }

    private let maxInFlight: Int
    /// The most of the slots the background lane holds at once.
    let backgroundSlots: Int
    /// How long the history's oldest request waits behind a screen's before the next free slot is its.
    let historyWait: Duration
    private let interval: Duration
    private var inFlight = 0
    /// Slots taken, by lane.
    private var holding: [Lane: Int] = [:]
    private var lastStart: ContinuousClock.Instant?
    /// Requests waiting, by lane, in the order they came.
    private var waiting: [Lane: [Waiter]] = [:]
    private var nextId: UInt64 = 0
    /// When the gate wakes to let the next request through, once the space after the last start is all that holds it.
    private var wakeAt: ContinuousClock.Instant?

    /// `inFlight`: requests in flight at once; `interval`: the space between two starts; `backgroundSlots`: the most of
    /// the slots the background lane holds at once; `historyWait`: how long the history's oldest request waits behind a
    /// screen's before it goes first.
    public init(inFlight: Int, interval: Duration, backgroundSlots: Int = 1, historyWait: Duration = .seconds(2)) {
        maxInFlight = max(1, inFlight)
        self.interval = interval
        self.backgroundSlots = min(maxInFlight, max(1, backgroundSlots))
        self.historyWait = historyWait
    }

    /// Waits in `lane` until the request may start — a slot free for it and the space after the last start passed — and
    /// takes the slot, to hand back with `leave`. Nil when the task was cancelled before it was let through: it left the
    /// queue and took neither the slot nor a start, and its request is not to be sent.
    public func enter(_ lane: Lane = .interactive) async -> Slot? {
        guard !Task.isCancelled else { return nil }
        let id = nextId
        nextId += 1
        let grant = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Grant?, Never>) in
                waiting[lane, default: []].append(Waiter(id: id, since: .now, continuation: continuation))
                letThrough()
            }
        } onCancel: {
            Task { await self.withdraw(id, from: lane) }
        }
        guard let grant else { return nil }
        // Cancelled as it was let through, before its request went out: the slot goes back, and the start with it unless
        // another came after it.
        if Task.isCancelled {
            release(lane)
            if lastStart == grant.start { lastStart = grant.previous }
            letThrough()
            return nil
        }
        return Slot(lane: lane)
    }

    /// Hands back the slot `enter` took, once its request is answered (or failed).
    public func leave(_ slot: Slot) {
        release(slot.lane)
        letThrough()
    }

    private func release(_ lane: Lane) {
        inFlight = max(0, inFlight - 1)
        holding[lane] = max(0, (holding[lane] ?? 0) - 1)
    }

    /// A waiter whose task was cancelled leaves the queue, told it was let through nowhere; nothing when it already was.
    private func withdraw(_ id: UInt64, from lane: Lane) {
        guard let index = waiting[lane]?.firstIndex(where: { $0.id == id }), let waiter = waiting[lane]?.remove(at: index) else { return }
        waiter.continuation.resume(returning: nil)
    }

    /// The highest lane with a request that may take a slot now: the background only below its share
    /// (`backgroundSlots`); the history ahead of a screen once its oldest request has waited `historyWait`.
    private func nextLane() -> Lane? {
        if let oldest = waiting[.history]?.first, ContinuousClock.now - oldest.since >= historyWait { return .history }
        return Lane.byPriority.first { lane in
            guard !(waiting[lane]?.isEmpty ?? true) else { return false }
            return lane != .background || (holding[.background] ?? 0) < backgroundSlots
        }
    }

    /// Lets through every request that may start now, the highest lane first, each in the order it came; when the space
    /// after the last start is all that holds the next one, the gate wakes once it has passed.
    private func letThrough() {
        while inFlight < maxInFlight, let lane = nextLane() {
            let now = ContinuousClock.now
            if let last = lastStart, last + interval > now {
                wake(at: last + interval)
                return
            }
            let waiter = waiting[lane]!.removeFirst()
            inFlight += 1
            holding[lane, default: 0] += 1
            let previous = lastStart
            lastStart = now
            waiter.continuation.resume(returning: Grant(start: now, previous: previous))
        }
    }

    private func wake(at instant: ContinuousClock.Instant) {
        if let wakeAt, wakeAt <= instant { return }
        wakeAt = instant
        // On the gate, as the method that starts it.
        Task {
            try? await Task.sleep(until: instant, clock: .continuous)
            woke(at: instant)
        }
    }

    private func woke(at instant: ContinuousClock.Instant) {
        if wakeAt == instant { wakeAt = nil }
        letThrough()
    }

    /// What the gate holds now (tests): slots taken and requests waiting, by lane, and the last start.
    func state() -> (holding: [Lane: Int], waiting: [Lane: Int], lastStart: ContinuousClock.Instant?) {
        (holding.filter { $0.value > 0 }, waiting.compactMapValues { $0.isEmpty ? nil : $0.count }, lastStart)
    }
}

/// Reads a window of logs across the endpoints (`LogsEndpoint`), in ranges of what each answers, through the gate.
public actor LogsRouter {
    public enum Order: Sendable { case ascending, descending }

    /// What an endpoint has answered this session (diagnostics, and the app's log).
    public struct Stats: Sendable, Equatable {
        public var requests = 0
        public var answered = 0
        public var tooLarge = 0
        public var pastHead = 0
        public var failed = 0
        public var throttled = 0
        public var rests = 0
    }

    /// How long a request may take before it counts as unanswered: the endpoints answer in about a second.
    public static let requestTimeout: TimeInterval = 12
    /// A rest after a throttle, doubling each time in a row, at most `maxThrottleRest`; after a failure, from
    /// `failureRest` to `maxFailureRest`.
    static let throttleRest: TimeInterval = 2, maxThrottleRest: TimeInterval = 16
    static let failureRest: TimeInterval = 1, maxFailureRest: TimeInterval = 8
    /// The widest endpoint is waited for while its rest ends within this long, rather than reading on an endpoint that
    /// answers a fifth of its span or less: a 1,000-block endpoint takes ten requests for one of a 10,000-block one.
    static let waitForWider: TimeInterval = 8
    /// A range refused for ending past the answering node's head (`LogsAnswer.pastHead`) is asked again after
    /// `headPause` seconds, then twice that: `headRetries` waits a scan, not a range, not counted against it — as a scan
    /// off the router waits (`LogScanLimits.headPause`). Monad makes a block every 0.4 s and the nodes behind one URL are
    /// a few blocks apart, the head read from one and the logs from another; three seconds cover seven blocks. Past the
    /// waits a refusal counts as any other, a gap after `maxAttempts`.
    static let headPause: TimeInterval = 1
    static let headRetries = 2

    private let endpoints: [LogsEndpoint]
    private let clients: [URL: RPCClient]
    private let gate: LogsGate
    private let store: (any LogsCapabilityStore)?
    /// Batches in flight at once for one scan, at most: a scan may ask for fewer (`read`'s `concurrency`).
    private let concurrency: Int
    /// What each endpoint answers now: its measured span, lowered by its refusals.
    private var spans: [URL: UInt64] = [:]
    /// Endpoints resting after a throttle or a failure, and how long their last rest was.
    private var restingUntil: [URL: ContinuousClock.Instant] = [:]
    private var lastRest: [URL: TimeInterval] = [:]
    private var batchLimits: [URL: Int] = [:]
    private var statsByURL: [URL: Stats] = [:]

    public init(endpoints: [LogsEndpoint], session: URLSession = .shared, gate: LogsGate = .shared, store: (any LogsCapabilityStore)? = nil, concurrency: Int = 4) {
        precondition(!endpoints.isEmpty, "LogsRouter needs at least one endpoint")
        self.endpoints = endpoints
        var clients: [URL: RPCClient] = [:]
        // A throttle is answered by resting the endpoint and asking the next, not by the client's own retries.
        for endpoint in endpoints where clients[endpoint.url] == nil {
            clients[endpoint.url] = RPCClient(url: endpoint.url, session: session, retries: 0, timeout: Self.requestTimeout)
        }
        self.clients = clients
        self.gate = gate
        self.store = store
        self.concurrency = max(1, concurrency)
        for endpoint in endpoints {
            if let learned = store?.span(for: endpoint.url) { spans[endpoint.url] = min(learned, endpoint.span) }
        }
    }

    /// The endpoints, in order.
    public nonisolated var urls: [URL] { endpoints.map(\.url) }

    /// What `url` answers now (tests).
    func span(of url: URL) -> UInt64 { spans[url] ?? endpoints.first { $0.url == url }?.span ?? LogsEndpoints.floorSpan }

    /// What each endpoint has answered this session, by its host.
    public func stats() -> [String: Stats] {
        var out: [String: Stats] = [:]
        for (url, stats) in statsByURL { out[url.host() ?? url.absoluteString] = stats }
        return out
    }

    /// The latest block's header from the first endpoint that answers.
    public func latest() async -> BlockHeader? {
        for endpoint in endpoints {
            if let header = try? await clients[endpoint.url]?.block(.latest) { return header }
        }
        return nil
    }

    /// The chain head from the first endpoint that answers.
    public func head() async -> UInt64? { await latest()?.number }

    /// The block a local Anvil fork started from, when the first endpoint is one (`RPCClient.localForkBlock`): the
    /// fork answers no logs below it. Nil on mainnet.
    public func localForkBlock() async -> UInt64? {
        guard let endpoint = endpoints.first, let client = clients[endpoint.url], client.isLocal else { return nil }
        return await client.localForkBlock()
    }

    private struct Piece: Hashable, Sendable { let from: UInt64; let to: UInt64 }
    /// One request's outcome: each piece's answer; whether the request was throttled; whether it got no answer at all
    /// (a transport failure, a timeout, an HTTP error), which is the endpoint's fault, not the pieces'; whether it was
    /// sent at all (false: the scan was cancelled while it waited at the gate, `LogsGate.enter`); how long it waited at
    /// the gate for a slot.
    private struct Batch: Sendable {
        let url: URL; let pieces: [Piece]; let answers: [LogsAnswer]; let throttled: Bool; let unanswered: Bool; var sent = true; var waited: Duration = .zero
    }

    /// Reads `query` over `[from, to]`, newest ranges first when `order` is descending, within `budget`. `concurrency`:
    /// the most batches in flight at once for this scan, never more than the router's own (nil: the router's) — the venue
    /// list reads one at a time. `lane`: where its requests wait at the gate (`LogsGate.Lane`): a screen's scan, the
    /// default, goes ahead of the wallet's history rounds, and both ahead of the background.
    ///
    /// A background scan's seconds are the time its requests were out, not the time they waited at the gate: it waits
    /// behind every screen and history round by design, and a user browsing for two minutes timed the venue list's run out
    /// with its endpoints answering, a run that ended short, read again only after a pause on a later return to the app
    /// (`VenueTokenList.resume`). The venue list, the one background scan, reads one request at a time, so its waits never
    /// overlap; its requests stay bounded (`LogsBudget.requests`).
    ///
    /// `head`: the chain head the caller read for this round, given by a read whose answer is kept as coverage for good —
    /// the wallet's history (`HistoryStore`) and its spot check (`ServerHistorySync.spotCheck`). Then an endpoint that
    /// clamps (`LogsEndpoint.clamps`) is asked only for blocks at least `LogsEndpoints.headLag` below it (or below the
    /// window's end, when that is later): one of its nodes, a few hundred blocks behind, answers a range ending past its own
    /// head short, with no error, and the blocks it left out would read as blocks with no logs, covered for good. The
    /// blocks above go to an endpoint that refuses past its head (rpc2), first when one takes them; while one is resting,
    /// the clamping endpoints read on below, and once nothing else is left the scan waits for it, within its deadline. Past
    /// the deadline, or with no such endpoint, they are left unread — a gap the caller sees (`covered`), as any range no
    /// endpoint answered. A gap read far below the head is given the head too, so its newest blocks aren't kept from the
    /// clamping endpoints for nothing.
    ///
    /// Nil — a screen's read (`RPCClient.chunkedLogsReport`, `newestLogs`: a coin's trades and holders, a Moment's), never
    /// kept within `LogsEndpoints.headLag` of the head (a Moment coin's holder count keeps only the blocks below it,
    /// `MomentHolderTally.settleBlocks`) — is routed as in build 22: every endpoint may be asked for every block. Held
    /// back as well, the newest 600 blocks of every such window waited on rpc2 alone, and with rpc2 down, throttled past
    /// the deadline or refusing past its head three times running, those screens showed nothing or "couldn't be read",
    /// where a clamping endpoint would have answered — at worst a few hundred blocks short, until the screen reads again.
    public func read(_ query: LogsQuery, from: UInt64, to: UInt64, head: UInt64? = nil, order: Order = .ascending, budget: LogsBudget, concurrency: Int? = nil,
                     lane: LogsGate.Lane = .interactive) async -> LogsRead {
        guard from <= to else { return LogsRead(logs: [], covered: [], requests: 0) }
        let batchesAtOnce = min(self.concurrency, max(1, concurrency ?? self.concurrency))
        var deadline = ContinuousClock.now + .seconds(budget.seconds)
        var logs: [Log] = []
        var seen = Set<String>()
        var covered: [ClosedRange<UInt64>] = []
        var requests = 0
        // Whether the newest blocks are held back from the clamping endpoints: for a read given the round's head alone,
        // whose answer is kept (above). Then the newest block a clamping endpoint may be asked for (`LogsEndpoint.clamps`)
        // is `headLag` below the head — below the window's end when that is later, a window that reaches past the head the
        // caller read; nil, none at all, the head within `headLag` of the chain's first block.
        let holdsBack = head != nil
        let roundHead = max(head ?? to, to)
        let clampTop: UInt64? = roundHead >= LogsEndpoints.headLag ? roundHead - LogsEndpoints.headLag : nil
        // Blocks still to ask, as ranges from the window's cursor. A range refused is asked again — in parts an endpoint
        // answers, on another endpoint — and one an endpoint refuses on its own account `maxAttempts` times is left as
        // a gap. A request that got no answer at all counts against the endpoint, not its ranges, unless it carried one.
        var cursor: UInt64? = order == .ascending ? from : to
        var retry: [Piece] = []
        var attempts: [Piece: Int] = [:]
        let maxAttempts = 3
        // Ranges refused for ending past the answering node's head, each with when it is asked again (`headPause`), and
        // the scan's waits for them so far. A scan read newest first stands on its newest range (`NewestLogs`): asked
        // again at once, three refusals in a row from a node a few blocks behind left it a gap, and the whole read with
        // it — a coin's holders unread, its trades none.
        var behindHead: [(piece: Piece, at: ContinuousClock.Instant)] = []
        var headWaits = 0

        func requeue(_ piece: Piece, counting: Bool) {
            if counting {
                let n = (attempts[piece] ?? 0) + 1
                attempts[piece] = n
                guard n < maxAttempts else { return }
            }
            retry.append(piece)
        }

        /// `piece` as `endpoint` may be asked for it (`mine`), and what is left for an endpoint that refuses past its head
        /// (`rest`): such an endpoint may be asked for all of it; a clamping one for its blocks up to `clampTop` only,
        /// none when it starts above — unless nothing is held back (`holdsBack`), when every endpoint takes all of it.
        func share(_ piece: Piece, with endpoint: LogsEndpoint) -> (mine: Piece?, rest: Piece?) {
            guard endpoint.clamps, holdsBack else { return (piece, nil) }
            guard let top = clampTop, piece.from <= top else { return (nil, piece) }
            return piece.to <= top ? (piece, nil) : (Piece(from: piece.from, to: top), Piece(from: top + 1, to: piece.to))
        }

        /// Whether everything left to ask — the ranges to ask again, those past a node's head whose pause is over among
        /// them, and the cursor's — lies above `clampTop`: only an endpoint that refuses past its head may be asked for it.
        /// Never, when nothing is held back (`holdsBack`).
        func onlyNearTheHead() -> Bool {
            guard holdsBack else { return false }
            let now = ContinuousClock.now
            var lowest = retry.map(\.from) + behindHead.filter { $0.at <= now }.map(\.piece.from)
            if let at = cursor { lowest.append(order == .ascending ? at : from) }
            guard !lowest.isEmpty else { return false }
            guard let top = clampTop else { return true }
            return lowest.allSatisfy { $0 > top }
        }

        func nextPieces(_ endpoint: LogsEndpoint) -> [Piece] {
            let span = span(of: endpoint.url)
            let limit = batchLimit(endpoint)
            var out: [Piece] = []
            // Ranges past a node's head whose pause is over go first: they are the window's newest.
            let now = ContinuousClock.now
            retry.insert(contentsOf: behindHead.filter { $0.at <= now }.map(\.piece), at: 0)
            behindHead.removeAll { $0.at <= now }
            // Ranges to ask again first, cut to this endpoint's span; what doesn't fit the request waits at the front. A
            // clamping endpoint takes their blocks up to `clampTop` only: those above stay where they were, in order, for
            // an endpoint that refuses past its head.
            var index = 0
            while out.count < limit, index < retry.count {
                let (mine, rest) = share(retry.remove(at: index), with: endpoint)
                if let rest {
                    retry.insert(rest, at: index)
                    index += 1
                }
                guard let piece = mine else { continue }
                var start = piece.from
                while start <= piece.to {
                    let end = min(piece.to, start + span - 1)
                    if out.count < limit {
                        out.append(Piece(from: start, to: end))
                    } else {
                        retry.insert(Piece(from: start, to: piece.to), at: index)
                        break
                    }
                    if end == UInt64.max { break }
                    start = end + 1
                }
            }
            cursorRanges: while out.count < limit, let at = cursor {
                switch order {
                case .ascending:
                    // A clamping endpoint reads up to `clampTop`; the cursor stays at the blocks above, for an endpoint
                    // that refuses past its head.
                    guard let piece = share(Piece(from: at, to: min(to, at + span - 1)), with: endpoint).mine else { break cursorRanges }
                    out.append(piece)
                    cursor = piece.to < to ? piece.to + 1 : nil
                case .descending:
                    if holdsBack, endpoint.clamps, clampTop.map({ at > $0 }) ?? true {
                        // The newest blocks, above `clampTop`, are set aside to ask again — first, by an endpoint that
                        // refuses past its head — and a clamping endpoint reads on below them.
                        let low = clampTop.map { max(from, $0 + 1) } ?? from
                        retry.insert(Piece(from: low, to: at), at: 0)
                        cursor = low > from ? low - 1 : nil
                        continue
                    }
                    let start = at - from >= span ? at - span + 1 : from
                    out.append(Piece(from: start, to: at))
                    cursor = start > from ? start - 1 : nil
                }
            }
            return out
        }

        await withTaskGroup(of: Batch.self) { group in
            var inFlight = 0
            while true {
                // Once all that is left lies within `headLag` of the head, only an endpoint that refuses past its head is
                // asked — waited for, within the deadline, while it rests — never a clamping one (`share`).
                while inFlight < batchesAtOnce, requests < budget.requests, ContinuousClock.now < deadline, !Task.isCancelled,
                      let endpoint = await available(deadline: deadline, refusingOnly: onlyNearTheHead()) {
                    let pieces = nextPieces(endpoint)
                    guard !pieces.isEmpty else { break }
                    requests += 1
                    inFlight += 1
                    let client = clients[endpoint.url]!
                    let url = endpoint.url
                    group.addTask { [gate] in
                        let queued = ContinuousClock.now
                        // Cancelled while it waited at the gate: it left the queue, took no slot, and sends nothing.
                        guard let slot = await gate.enter(lane) else {
                            return Batch(url: url, pieces: pieces, answers: [], throttled: false, unanswered: false, sent: false)
                        }
                        let waited = ContinuousClock.now - queued
                        let answered = await Self.ask(client, query: query, pieces: pieces.map { ($0.from, $0.to) })
                        await gate.leave(slot)
                        return Batch(url: url, pieces: pieces, answers: answered.answers, throttled: answered.throttled, unanswered: answered.unanswered,
                                     waited: waited)
                    }
                }
                guard inFlight > 0, let batch = await group.next() else {
                    // Nothing in flight, and only ranges past a node's head left, waiting their pause: the scan waits for
                    // the first, within its deadline and budget. One whose pause is over and still unsent found no
                    // endpoint within the deadline: the scan ends, and it is a gap.
                    if let wake = behindHead.map(\.at).min(), wake > .now, wake < deadline, requests < budget.requests, !Task.isCancelled {
                        try? await Task.sleep(until: wake, clock: .continuous)
                        continue
                    }
                    break
                }
                inFlight -= 1
                // A batch the gate never let start is no request. The gate turns one away only when its task is cancelled,
                // and its task is cancelled only with the scan's (nothing here cancels one alone): the scan is ending, and
                // its ranges are left unread.
                if !batch.sent {
                    requests -= 1
                    continue
                }
                // The background's seconds leave out its waits at the gate (above).
                if lane == .background { deadline = deadline + batch.waited }
                // Cancelled (the screen closed): what came back is dropped, and no endpoint is blamed for the rest.
                if Task.isCancelled { continue }
                var stats = statsByURL[batch.url] ?? Stats()
                stats.requests += 1
                if batch.unanswered {
                    // The endpoint's fault: it rests, and its next request carries fewer ranges. The ranges are asked again,
                    // counted against them only when one was alone in the request.
                    stats.failed += batch.pieces.count
                    if batch.throttled { stats.throttled += 1 }
                    stats.rests += 1
                    rest(batch.url, throttled: batch.throttled)
                    if !batch.throttled { halveBatch(batch.url) }
                    for piece in batch.pieces { requeue(piece, counting: batch.pieces.count == 1 && !batch.throttled) }
                } else {
                    // Whether a range refused at the floor rested the endpoint: the rest then stands, not cleared below.
                    var rested = false
                    var pastHead: [Piece] = []
                    for (piece, answer) in zip(batch.pieces, batch.answers) {
                        switch answer {
                        case .logs(let found):
                            stats.answered += 1
                            covered.append(piece.from...piece.to)
                            for log in found where seen.insert(log.id).inserted { logs.append(log) }
                        case .tooLarge(let cut, let dense):
                            stats.tooLarge += 1
                            let width = piece.to - piece.from + 1
                            if dense, width > LogsEndpoints.floorSpan {
                                // Too many logs in the range, not too wide a range: asked again in two — at the cut the endpoint
                                // names, else halves — on whichever endpoint is free; the span stays.
                                let split = cut.flatMap { $0 >= piece.from && $0 < piece.to ? $0 : nil } ?? piece.from + width / 2 - 1
                                requeue(Piece(from: piece.from, to: split), counting: false)
                                requeue(Piece(from: split + 1, to: piece.to), counting: false)
                            } else if !dense, lower(batch.url, refused: width, cut: cut.map { $0 - piece.from + 1 }) {
                                // Too wide: the endpoint's span is lowered, remembered, and the range re-cut at it.
                                requeue(piece, counting: false)
                            } else {
                                // Refused at the floor: the endpoint rests so the next one is asked, and the refusal counts
                                // against the range, a gap after `maxAttempts` (every endpoint refusing it).
                                stats.rests += 1
                                rest(batch.url, throttled: false)
                                rested = true
                                requeue(piece, counting: true)
                            }
                        case .pastHead:
                            stats.pastHead += 1
                            pastHead.append(piece)
                        case .failed, .throttled:
                            stats.failed += 1
                            requeue(piece, counting: true)
                        }
                    }
                    // Past the answering node's head: asked again once it has had time to catch up, while the scan's
                    // waits last (`headPause`), uncounted; past them, counted as any refusal.
                    if !pastHead.isEmpty {
                        if headWaits < Self.headRetries {
                            headWaits += 1
                            let at = ContinuousClock.now + .seconds(Self.headPause * Double(headWaits))
                            behindHead += pastHead.map { ($0, at) }
                        } else {
                            for piece in pastHead { requeue(piece, counting: true) }
                        }
                    }
                    if !rested { lastRest[batch.url] = nil }
                    batchLimits[batch.url] = nil
                }
                statsByURL[batch.url] = stats
            }
        }

        return LogsRead(logs: logs.sorted { a, b in a.blockNumber == b.blockNumber ? a.logIndex < b.logIndex : a.blockNumber < b.blockNumber },
                        covered: LogsRead.merge(covered), requests: requests)
    }

    /// The first endpoint not resting — of those that refuse a range past their head only, when `refusingOnly` (all that
    /// is left of a scan lies within `LogsEndpoints.headLag` of the head) — unless a wider one, resting, wakes soon enough
    /// to be worth the wait (`waitForWider`) and hasn't been resting over and over; when every one rests, waits for the
    /// first to wake, within `deadline`. Nil when none wakes within it, or there is none to ask.
    private func available(deadline: ContinuousClock.Instant, refusingOnly: Bool = false) async -> LogsEndpoint? {
        let candidates = refusingOnly ? endpoints.filter { !$0.clamps } : endpoints
        while true {
            let now = ContinuousClock.now
            if let endpoint = candidates.first(where: { (restingUntil[$0.url] ?? now) <= now }) {
                // A wider endpoint resting for a moment is worth more than a narrow one answering now.
                let wider = candidates.prefix { $0.url != endpoint.url }.filter { span(of: $0.url) >= span(of: endpoint.url) * 5 && (lastRest[$0.url] ?? 0) < Self.waitForWider }
                if let wake = wider.compactMap({ restingUntil[$0.url] }).min(), wake - now <= .seconds(Self.waitForWider), wake < deadline, !Task.isCancelled {
                    try? await Task.sleep(until: wake, clock: .continuous)
                    continue
                }
                return endpoint
            }
            guard let wake = candidates.compactMap({ restingUntil[$0.url] }).min(), wake < deadline, !Task.isCancelled else { return nil }
            try? await Task.sleep(until: wake, clock: .continuous)
        }
    }

    /// How many ranges a request of `endpoint` carries now: its batch, halved after each request of it that got no
    /// answer (`halveBatch`), back to its batch once one is answered.
    private func batchLimit(_ endpoint: LogsEndpoint) -> Int { min(endpoint.batch, batchLimits[endpoint.url] ?? endpoint.batch) }

    private func halveBatch(_ url: URL) {
        let current = batchLimits[url] ?? endpoints.first { $0.url == url }?.batch ?? 1
        batchLimits[url] = max(1, current / 2)
    }

    /// `url` rests after a throttle or a failure, longer each time in a row (`throttleRest`, `failureRest`).
    private func rest(_ url: URL, throttled: Bool) {
        let floor = throttled ? Self.throttleRest : Self.failureRest
        let cap = throttled ? Self.maxThrottleRest : Self.maxFailureRest
        let next = min(cap, max(floor, (lastRest[url] ?? 0) * 2))
        lastRest[url] = next
        restingUntil[url] = .now + .seconds(next)
    }

    /// `url` refused a range of `refused` blocks as too wide: it answers less. The span the refusal names (`cut`: rpc4
    /// and rpc.monad.xyz name the number), else half, never under the floor. Remembered for the day. False when there
    /// is nothing left to lower: refused at the floor already.
    private func lower(_ url: URL, refused: UInt64, cut: UInt64?) -> Bool {
        let current = span(of: url)
        var next = cut.map { max(1, $0) } ?? current / 2
        if next >= refused { next = refused / 2 }
        next = max(LogsEndpoints.floorSpan, next)
        guard next < current else { return false }
        spans[url] = next
        store?.set(span: next, for: url)
        return true
    }

    /// `pieces` of `query` asked of `client` in one request: each range's answer, whether the request was throttled, and
    /// whether it got no answer at all.
    private static func ask(_ client: RPCClient, query: LogsQuery, pieces: [(from: UInt64, to: UInt64)]) async -> (answers: [LogsAnswer], throttled: Bool, unanswered: Bool) {
        do {
            let results = try await client.batch(pieces.map { ("eth_getLogs", [query.json(from: $0.from, to: $0.to)]) })
            guard results.count == pieces.count else { return (pieces.map { _ in .failed }, false, true) }
            var throttled = false
            let answers = zip(pieces, results).map { piece, result -> LogsAnswer in
                switch result {
                case .success(let json):
                    guard let items = json.array else { return .failed }
                    var logs: [Log] = []
                    for item in items { guard let log = Log(json: item) else { return .failed }; logs.append(log) }
                    return .logs(logs)
                case .failure(let error):
                    if RPCClient.refusesPastHead(error) { return .pastHead }
                    if RPCClient.refusesSize(error) {
                        // A span the endpoint names is its cap, lowered to; a range it suggests from the same start, or a
                        // count it refuses, is this range's density: split, the span kept.
                        if let named = Self.namedSpan(error) {
                            let (end, overflow) = piece.from.addingReportingOverflow(named - 1)
                            return .tooLarge(cut: overflow || end >= piece.to ? nil : end, dense: false)
                        }
                        if let suggested = RPCClient.suggestedEnd(error, from: piece.from, to: piece.to) { return .tooLarge(cut: suggested, dense: true) }
                        return .tooLarge(cut: nil, dense: RPCClient.refusesCount(error))
                    }
                    if RPCClient.isRateLimited(error) { throttled = true }
                    return .failed
                }
            }
            // Every range refused as a throttle, or a batch refused outright (rpc4 answers a batch of ranges with one
            // internal error): no answer about the ranges themselves.
            let allFailed = answers.allSatisfy { if case .failed = $0 { return true }; return false }
            return (answers, throttled, allFailed && (throttled || pieces.count > 1))
        } catch {
            if case NetworkError.badStatus(let status) = error { return (pieces.map { _ in .failed }, RPCClient.isThrottle(status: status), true) }
            if let error = error as? RPCError { return (pieces.map { _ in .failed }, RPCClient.isRateLimited(error), true) }
            return (pieces.map { _ in .failed }, false, true)
        }
    }

    /// The range a refusal names in words — rpc.monad.xyz's and rpc4's "eth_getLogs is limited to a 1,000 range", rpc1's
    /// "requests with up to a 1,000 block range" — as a span; nil when it names none.
    static func namedSpan(_ error: RPCError) -> UInt64? {
        let message = error.message.lowercased()
        // not localized: the endpoints' own English, matched as they send it
        guard let marker = message.range(of: "limited to a ") ?? message.range(of: "up to a ") else { return nil }
        let digits = message[marker.upperBound...].prefix { $0.isNumber || $0 == "," }.filter(\.isNumber)
        guard let span = UInt64(digits), span > 0 else { return nil }
        return span
    }
}
