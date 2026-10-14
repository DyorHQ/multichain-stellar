import BigInt
import Foundation

/// An `eth_getLogs` query. Topics are positional: `nil` matches anything at that position, and the array may be
/// shorter than the log's topic list.
public struct LogFilter: Sendable, Equatable {
    public var address: Address?
    public var topics: [Data?]
    public var fromBlock: UInt64
    public var toBlock: UInt64

    public init(address: Address? = nil, topics: [Data?] = [], fromBlock: UInt64, toBlock: UInt64) {
        self.address = address
        self.topics = topics
        self.fromBlock = fromBlock
        self.toBlock = toBlock
    }

    var json: JSON {
        var object: [String: JSON] = [
            "fromBlock": .string(BigUInt(fromBlock).hexQuantity),
            "toBlock": .string(BigUInt(toBlock).hexQuantity),
        ]
        if let address { object["address"] = .string(address.hex) }
        if !topics.isEmpty { object["topics"] = .array(topics.map { topic in topic.map { .string($0.hexString) } ?? .null }) }
        return .object(object)
    }
}

/// What an endpoint answered for one `eth_getLogs` range.
enum LogsAnswer: Sendable {
    case logs([Log])
    /// Refused for its size: its block span, or how many logs it would return, is over the endpoint's cap
    /// (`RPCClient.refusesSize`). A smaller range is answered: `cut`, when the endpoint names one, is the last block of a
    /// range from the same start it can answer (`RPCClient.suggestedEnd`). `dense`: refused for how many logs the range
    /// holds, not for how wide it is (`RPCClient.refusesCount`, or a range suggested from the same start) — a narrower
    /// range is answered, and the endpoint's span is no lesson from it (`LogsRouter`).
    case tooLarge(cut: UInt64?, dense: Bool = false)
    /// Refused for ending past the head of the node that answered (`RPCClient.refusesPastHead`): rpc1's nodes can be a
    /// few blocks apart, the head read from one and the logs from another. Asked again once that node has had time to
    /// catch up (`LogScanLimits.headPause`), while the scan's waits for it last; past them, read in halves as a size
    /// refusal is (`LogScan.divide`), as it was before it was told apart from one, so everything up to that node's head
    /// is read and only the part past it is a gap, for the caller to read later.
    case pastHead
    /// Anything else: an internal error, a throttle that outlasted the client's retries, no answer. A smaller range
    /// may not be answered either.
    case failed
    /// Paced: throttled still after the scan's waits for it (`LogScanLimits.throttleWaits`). Read in halves, once a scan
    /// (`LogScanLimits.throttleSplits`): a range the endpoint throttles every time may be too heavy for it.
    case throttled
}

/// How a scan (`RPCClient.chunkedLogsReport`) meets a range the endpoint doesn't answer for a reason other than its size:
/// an internal error, a throttle that outlasted the client's retries, no answer. In every mode a range refused for its
/// size is read in the parts the endpoint names, or in halves.
public enum LogScanMode: Sendable, Equatable {
    /// Every scan but the wallet's history on Send and the Portfolio and the venue token list, whose callers take what it
    /// read: such a range is read again in halves, each part that fails halved again down to the smallest range, as build
    /// 15 read it, with a pause that grows while nothing is answered, so an outage of a few seconds doesn't cut a history
    /// short. Bounded (`LogScanLimits`): once no range has been answered for 45 s the endpoint is down, and the scan stops
    /// there, incomplete; and it halves failed ranges at most 256 times.
    case patient
    /// The wallet's history on Send and the Portfolio, which say what they couldn't read and offer Retry: such a range is
    /// asked once more, then left as a gap, and two rounds in a row with no range answered end the scan, in about 27
    /// requests.
    case failFast
    /// The venue token list's read in the background (`VenueTokensService`), which shares rpc1 with every other reader:
    /// as patient, except that a throttle — HTTP 429 or 503 once the client's own retries are spent, a rate-limit error,
    /// or a request with no answer after one — is waited out, the same ranges asked again after a pause that doubles
    /// (`LogScanLimits.throttlePause`), not split: a smaller range doesn't ease a throttle or an overloaded endpoint, it
    /// multiplies the requests. A range throttled still after three waits is read in halves, once a scan
    /// (`LogsAnswer.throttled`). A throttle is no answer, so one that lasts past the outage ends the scan there,
    /// incomplete, for a later run. Any other 5xx (a gateway timeout for a heavy range, the same every time) is a failure,
    /// read in halves as patient reads one.
    case paced
}

/// What a scan may spend (`LogScanMode`), so no endpoint can keep one going for hours. Tests make them smaller.
struct LogScanLimits: Sendable, Equatable {
    /// Splits a scan may make in all, whatever refused the range: past them, a part refused again is left as a gap.
    var splits = 4_096
    /// Patient and paced: splits of ranges that failed for a reason other than their size.
    var failedSplits = 256
    /// Patient and paced: the endpoint is down once no range has been answered for this long, in seconds…
    var outage: TimeInterval = 45
    /// …and while nothing is answered, a part waits `pause` seconds for each request in a row that got no answer, at most
    /// `maxPause`.
    var pause: TimeInterval = 0.25
    var maxPause: TimeInterval = 2
    /// Paced: a throttled request is asked again after `throttlePause` seconds, doubling each time in a row, at most
    /// `maxThrottlePause`.
    var throttlePause: TimeInterval = 2
    var maxThrottlePause: TimeInterval = 16
    /// Paced: a range throttled still after `throttleWaits` waits in a row is read in halves (`LogsAnswer.throttled`),
    /// `throttleSplits` times a scan; past them, it is waited out until the outage.
    var throttleWaits = 3
    var throttleSplits = 1
    /// A range refused for ending past the node's head (`LogsAnswer.pastHead`) is asked again after `headPause` seconds,
    /// then twice that: `headRetries` waits a scan in all, not a range, since Monad makes a block every 0.4 s and the
    /// nodes are a few apart. Past them, such a range is read in halves at once.
    var headPause: TimeInterval = 1
    var headRetries = 2
}

/// When the app last came back to the foreground, for every log scan's outage (`LogScan`): iOS suspends an app in the
/// background, and a scan waiting on an answer then hears none, however healthy the endpoint, so a scan that was running
/// would find the endpoint down on the app's return. A scan measures an outage from the later of its last answer and
/// the return, on a clock that stops while the device sleeps (`SuspendingClock`). The app calls `suspended()` when its
/// scene goes to the background and `resumed()` whenever it becomes active: only the first activation after a background
/// is a return. App Lock's Face ID or passcode prompt, a passkey sheet, Control Center and Notification Center make the
/// scene inactive, never background, and the app runs on behind them: an activation after one of them changes nothing,
/// so it can't hide an outage.
public enum LogScanClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: SuspendingClock.Instant?
    nonisolated(unsafe) private static var inBackground = false

    /// The app's scene went to the background, where iOS may suspend it.
    public static func suspended() {
        lock.lock(); defer { lock.unlock() }
        inBackground = true
    }

    /// The app's scene became active. The first time after `suspended()`, a return to the app: the clock restarts, and
    /// true says so, for what else reads on at a return (`VenueTokenList.resume`). Otherwise nothing, and false.
    @discardableResult
    public static func resumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inBackground else { return false }
        inBackground = false
        last = .now
        return true
    }

    static var resumedAt: SuspendingClock.Instant? {
        lock.lock(); defer { lock.unlock() }
        return last
    }
}

/// A scan's running account (`RPCClient.chunkedLogsReport`): what it may still split, and whether the endpoint is
/// answering.
struct LogScan {
    let mode: LogScanMode
    let limits: LogScanLimits
    private(set) var splits: Int
    private(set) var failedSplits: Int
    /// Requests in a row that got no range answered.
    private(set) var failedInARow = 0
    /// Waits spent on ranges past the answering node's head (`LogScanLimits.headRetries`).
    private(set) var headWaits = 0
    /// Paced: how many more ranges throttled still after the waits may be read in halves (`LogScanLimits.throttleSplits`).
    private(set) var throttleSplits: Int
    /// When a range was last answered — with its logs, or a refusal of its size — or the scan started.
    private var answeredAt = SuspendingClock.Instant.now
    /// Patient or paced: no range has been answered for `limits.outage` (since the app's return, when that is later:
    /// `LogScanClock`). The endpoint is down; the scan stops there, incomplete.
    private(set) var down = false

    init(mode: LogScanMode, limits: LogScanLimits) {
        self.mode = mode
        self.limits = limits
        splits = limits.splits
        failedSplits = limits.failedSplits
        throttleSplits = limits.throttleSplits
    }

    /// One request's answers. A range answered with its logs, or refused for its size, is the endpoint answering.
    mutating func record(_ answers: [LogsAnswer]) {
        if answers.contains(where: { switch $0 { case .failed, .throttled: return false; default: return true } }) {
            failedInARow = 0
            answeredAt = .now
            return
        }
        failedInARow += 1
        let since = max(answeredAt, LogScanClock.resumedAt ?? answeredAt)
        if mode != .failFast, SuspendingClock.Instant.now - since >= .seconds(limits.outage) { down = true }
    }

    /// Patient or paced, while the endpoint isn't answering: how long the next part waits. 0 otherwise.
    var pause: TimeInterval {
        mode != .failFast && failedInARow > 0 ? min(limits.pause * Double(failedInARow), limits.maxPause) : 0
    }

    /// Paced: how long to wait before asking again after the `n`th throttle in a row.
    func throttlePause(after n: Int) -> TimeInterval {
        min(limits.throttlePause * pow(2, Double(max(0, n - 1))), limits.maxThrottlePause)
    }

    /// How long to wait before asking again a range past the answering node's head, spending one of the scan's waits;
    /// nil once they are spent (`LogScanLimits.headRetries`).
    mutating func headPause() -> TimeInterval? {
        guard headWaits < limits.headRetries else { return nil }
        headWaits += 1
        return limits.headPause * Double(headWaits)
    }

    /// Whether `part` would be read in halves if it failed for a reason other than its size: patient or paced, while the
    /// scan's splits last, and when it is wider than `floor` blocks.
    func halvesFailures(_ part: LogFilter, floor: UInt64) -> Bool {
        mode != .failFast && splits > 0 && failedSplits > 0 && part.toBlock >= part.fromBlock && part.toBlock - part.fromBlock + 1 > floor
    }

    /// `part` in two after `answer`. Refused for its size: where the refusal says a range the endpoint can answer ends,
    /// while `cuts` lasts, else in halves. Past the answering node's head, its waits spent: in halves. Failed for another
    /// reason: in halves when `halvesFailures`; throttled still after the waits, the same while `throttleSplits` lasts.
    /// Nil — the part is a gap — when it was answered, is no wider than `floor` blocks, or the scan's splits are spent.
    mutating func divide(_ part: LogFilter, after answer: LogsAnswer, cuts: inout Int, floor: UInt64) -> [LogFilter]? {
        guard splits > 0 else { return nil }
        let parts: [LogFilter]?
        switch answer {
        case .logs:
            return nil
        case .tooLarge(let cut, _):
            let named = cuts > 0 ? cut : nil
            if named != nil { cuts -= 1 }
            parts = RPCClient.split(part, at: named, floor: floor)
        case .pastHead:
            parts = RPCClient.split(part, floor: floor)
        case .failed:
            guard halvesFailures(part, floor: floor) else { return nil }
            parts = RPCClient.split(part, floor: floor)
            if parts != nil { failedSplits -= 1 }
        case .throttled:
            guard throttleSplits > 0, halvesFailures(part, floor: floor) else { return nil }
            parts = RPCClient.split(part, floor: floor)
            if parts != nil { failedSplits -= 1; throttleSplits -= 1 }
        }
        if parts != nil { splits -= 1 }
        return parts
    }
}

/// One event emitted by a contract, as `eth_getLogs` and transaction receipts report it.
public struct Log: Sendable, Hashable, Identifiable {
    public let address: Address
    public let topics: [Data]
    public let data: Data
    public let blockNumber: UInt64
    public let transactionHash: Data
    public let logIndex: Int
    /// When the log's block was mined (seconds since 1970), as the endpoint said it: Monad's `eth_getLogs` answers carry
    /// `blockTimestamp` (rpc2, 2026-10-08). Nil where none was given — a receipt, a log kept before the app read it, a
    /// node that leaves it out — and the time is then estimated from a later block (`BlockClock.time(of:anchor:secondsPerBlock:)`).
    public let blockTimestamp: Int?

    /// `txHash-logIndex`, unique across the chain.
    public var id: String { "\(transactionHash.hexString)-\(logIndex)" }

    public init(address: Address, topics: [Data], data: Data, blockNumber: UInt64, transactionHash: Data, logIndex: Int, blockTimestamp: Int? = nil) {
        self.address = address
        self.topics = topics
        self.data = data
        self.blockNumber = blockNumber
        self.transactionHash = transactionHash
        self.logIndex = logIndex
        self.blockTimestamp = blockTimestamp
    }

    /// Parses one log object from a JSON-RPC response. Returns nil when a required field is missing or malformed. The
    /// block's timestamp is optional: one missing or malformed is left out (nil), never a reason to drop the log.
    public init?(json: JSON) {
        guard let addressHex = json["address"].string, let address = Address(addressHex),
              let topicList = json["topics"].array,
              let dataHex = json["data"].string, let data = Data(hex: dataHex),
              let blockHex = json["blockNumber"].string, let block = BigUInt(hexQuantity: blockHex),
              let hashHex = json["transactionHash"].string, let hash = Data(hex: hashHex),
              let indexHex = json["logIndex"].string, let index = BigUInt(hexQuantity: indexHex)
        else { return nil }
        var topics: [Data] = []
        for topic in topicList {
            guard let hex = topic.string, let bytes = Data(hex: hex) else { return nil }
            topics.append(bytes)
        }
        let timestamp = json["blockTimestamp"].string.flatMap { BigUInt(hexQuantity: $0) }.map { Int(clamping: $0) }
        self.init(address: address, topics: topics, data: data, blockNumber: UInt64(clamping: block), transactionHash: hash, logIndex: Int(clamping: index),
                  blockTimestamp: timestamp)
    }

    /// The `index`th indexed parameter as an address (topic 0 is the event signature).
    public func indexedAddress(_ index: Int) -> Address? {
        guard topics.indices.contains(index + 1), topics[index + 1].count == 32 else { return nil }
        return Address(data: topics[index + 1].suffix(20))
    }
}

/// The newest logs of a window (`RPCClient.newestLogs`): every log from `readFrom` to the window's end, read in one piece
/// down from it, and none older — so a figure built from them is of an unbroken run of blocks ending at the head. A gap the
/// router left lower down (a range no endpoint answered) cuts the run there, and what was read below it is left out:
/// counted with it, a wallet's transfers in on one side of the gap and out on the other would read as a balance it doesn't
/// have.
public struct NewestLogs: Sendable, Equatable {
    /// The logs from `readFrom` to the window's end, in block order.
    public let logs: [Log]
    /// The oldest block of the run read in one piece down from the window's end; nil when the end itself wasn't read
    /// (then `logs` is empty, and nothing can be said of the window).
    public let readFrom: UInt64?
    /// Every block of the window was read: `logs` are all of it.
    public let complete: Bool

    public init(logs: [Log], readFrom: UInt64?, complete: Bool) {
        self.logs = logs
        self.readFrom = readFrom
        self.complete = complete
    }

    /// What a router read of `[from, to]` (`LogsRead`) holds of the run down from `to`.
    public init(_ read: LogsRead, from: UInt64, to: UInt64) {
        let down = read.downTo(to)
        self.init(logs: down.map { floor in read.logs.filter { $0.blockNumber >= floor && $0.blockNumber <= to } } ?? [], readFrom: down,
                  complete: read.covers(from, to))
    }
}

/// The two block fields the app needs: the number and the timestamp that anchors event times.
public struct BlockHeader: Sendable, Equatable {
    public let number: UInt64
    public let timestamp: Int

    public init(number: UInt64, timestamp: Int) {
        self.number = number
        self.timestamp = timestamp
    }
}

public extension ABI {
    /// keccak256 of a canonical event signature such as `Transfer(address,address,uint256)`: the first topic
    /// of every log the event emits.
    static func eventTopic(_ signature: String) -> Data { Keccak.hash256(signature) }
}

public extension RPCClient {
    /// keccak256 of a canonical event signature; see `ABI.eventTopic`.
    static func eventTopic(_ signature: String) -> Data { ABI.eventTopic(signature) }

    /// The widest block range each of Monad's public endpoints answers per `eth_getLogs` request, measured read-only on
    /// 2026-09-29: rpc1 has no range cap (it answered 10M blocks in a second; its cap is 10K logs an answer, and it names
    /// a range that fits); rpc3 answers 1,000 blocks, `fromBlock` and `toBlock` both counted, and refuses 1,001 ("Block
    /// range is too large", -32062), counting every range in a request together (`logBatchSpan`); rpc4 is served by
    /// nodes that answer 100,000 and nodes that refuse 1,001 ("limited to a 1,000 range", -32614 in an HTTP 413), so 1,000
    /// is what every one of them answers; rpc.monad.xyz answers 100 and refuses 500. A local fork has no cap; 50,000 keeps
    /// its answers quick. A range sized over the cap is refused and split (`chunkedLogsReport`), one request a split, and
    /// a scan may split only so often (`LogScanLimits`): rpc3 sized at 100,000, as build 16 sized it, needs about 6,350
    /// splits for 5M blocks, so a wide scan spent them all and left the rest as gaps. Every caller here filters by a
    /// specific address or the viewer's own wallet, so a wide range returns a small result set. Matches on the URL text
    /// rather than the host, like the web app's `CHUNK`.
    static func logChunkSize(for url: URL) -> UInt64 {
        let text = url.absoluteString
        if text.contains("127.0.0.1") || text.contains("localhost") { return 50_000 }
        if text.contains("rpc1") { return 100_000 }
        if text.contains("rpc3") || text.contains("rpc4") { return 1_000 }
        return 100
    }

    /// The chunk size for this endpoint; see `logChunkSize(for:)`.
    nonisolated var logChunkSize: UInt64 { Self.logChunkSize(for: url) }

    /// Whether the endpoint answers a range of any span, refusing only one that holds more logs than it returns and naming
    /// the part from the same start that it can (`suggestedEnd`): rpc1 (measured 2026-09-30: a 5M-block range of Uniswap
    /// v4's pool events in one request, 1.6 s, 3,932 logs; the whole history refused with the range to 92,759,889). A
    /// scan with few logs a block can read wide ranges there (`VenueTokensService`).
    static func answersAnyRange(_ url: URL) -> Bool { url.absoluteString.contains("rpc1") }

    /// See `answersAnyRange(_:)`.
    nonisolated var answersAnyRange: Bool { Self.answersAnyRange(url) }

    /// The most blocks one request may ask across all its `eth_getLogs` ranges, where an endpoint counts them together:
    /// rpc3 answers a batch's ranges while they add up to 1,000 blocks and refuses every range past that (-32062), however
    /// small, so there a round trip asks one 1,000-block range (`chunkedLogsReport`). Nil where each range counts on its
    /// own, as on rpc1, rpc4 and rpc.monad.xyz (measured 2026-09-29).
    static func logBatchSpan(for url: URL) -> UInt64? {
        url.absoluteString.contains("rpc3") ? 1_000 : nil
    }

    /// This endpoint's budget for one request; see `logBatchSpan(for:)`.
    nonisolated var logBatchSpan: UInt64? { Self.logBatchSpan(for: url) }

    /// Whether this client's endpoint is a node on this machine (a local fork): `RPCClient.isLocal(_:)`, the one rule for
    /// the log floors and fork-block clamps here and for the read limits and item budget.
    nonisolated var isLocal: Bool { Self.isLocal(url) }

    /// The block a local Anvil fork started from (`anvil_metadata`), cached for the process; nil when the local node
    /// is not Anvil or is not a fork.
    func localForkBlock() async -> UInt64? {
        if let cached = await LocalForkInfo.shared.block(for: url) { return cached }
        let block: UInt64?
        if let json = try? await call("anvil_metadata"), let raw = json["forkedNetwork"]["forkBlockNumber"].number {
            block = UInt64(raw)
        } else {
            block = nil
        }
        await LocalForkInfo.shared.set(block, for: url)
        return block
    }

    /// One `eth_getLogs` request. The range must respect the endpoint's cap; use `chunkedLogs` for wider windows.
    func logs(_ filter: LogFilter) async throws -> [Log] {
        try Self.parseLogs(await call("eth_getLogs", [filter.json]))
    }

    /// Several `eth_getLogs` requests in one HTTP round trip. Each result fails on its own, so one rejected
    /// range never hides the others.
    func logs(_ filters: [LogFilter]) async throws -> [Result<[Log], RPCError>] {
        try await batch(filters.map { ("eth_getLogs", [$0.json]) }).map { result in
            result.flatMap { json in
                do { return .success(try Self.parseLogs(json)) } catch { return .failure(RPCError(code: -1, message: "Malformed log response")) } // not localized: an RPC message, as a node's
            }
        }
    }

    /// Fetches logs over `[fromBlock, toBlock]` by splitting the window into ranges the endpoint accepts and
    /// sending `concurrency` ranges per round trip (fewer where the endpoint counts a request's ranges together,
    /// `logBatchSpan`). A range that fails is read again in smaller parts, as build 15 read it
    /// (`LogScanMode.patient`); what still can't be read leaves a gap rather than failing the whole window, exactly as the
    /// web app's `chunkedLogs` does, and the caller gets everything that could be read, newest ranges first
    /// (`LogsRouter.Order.descending`).
    ///
    /// It says nothing of what it couldn't read, so no screen reads through it: a screen's scan says what it read
    /// (`chunkedLogsReport`, `newestLogs`: the Launch page's trades and holders, a Moment's holders), and the wallet's NFTs
    /// come from its history store. What is left here are readers no screen shows (a wallet's launchpad history over a
    /// given lookback, the swap scan of a window), read newest first since build 23: in build 22 and earlier they read
    /// oldest first, so a window wider than the scan's budget (80 requests, about 4.8M blocks) came back as its OLDEST
    /// slice, nothing of the last weeks, and nobody was told.
    func chunkedLogs(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6) async -> [Log] {
        await chunkedLogsReport(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunkSize, concurrency: concurrency,
                                order: .descending).logs
    }

    /// `chunkedLogs`, saying whether the whole window was read: `complete` is false when a range was left as a gap, or the
    /// scan was cancelled or stopped part-way, so a caller can tell "nothing there" from "couldn't read it". A range the
    /// endpoint refuses for its size is read in smaller parts (`narrowedLogs`). A range refused for any other reason — an
    /// internal error, a throttle that outlasted the client's retries, no answer — is asked once more, then read as `mode`
    /// says (`LogScanMode`): patient, the default, in halves, as build 15 read it, until the endpoint has answered nothing
    /// for 45 s; fail-fast, for the wallet's history on Send and the Portfolio, left as a gap, and two rounds in a row with
    /// no range answered end the scan; paced, for the venue token list, as patient, but a throttle is waited out, never
    /// split. Either way no endpoint can keep a scan going for hours (`LogScanLimits`).
    ///
    /// On the logs router (mainnet), `concurrency` is the most requests in flight at once for this scan, never more than
    /// the router's own (the default leaves it at the router's), and `lane` is where they wait at the app's one gate
    /// (`LogsGate.Lane`): a screen's scan, the default, ahead of the wallet's history rounds and the background. In build
    /// 22 and earlier the router left both out, so the venue list's "one request at a time" ran four at once, first come
    /// first served with the screens.
    ///
    /// `order` is which end of the window is read first, and so which part a scan that stops short holds: ascending, the
    /// default, from `fromBlock` up; descending, from `toBlock` down — the newest blocks, what a screen of recent trades or
    /// a coin's holders needs, read whole before anything older. A window wider than the scan's budget (patient: 80
    /// requests, about 4.8M blocks on rpc2, 80,000 on the 1,000-block endpoints) is always read in part: ascending, it was
    /// the oldest weeks of it in build 22 and earlier, a Moment's holders counted from its first days, the wallet's NFTs from
    /// the chain's first two weeks. Either way the logs come back in block order and `complete` says whether the whole
    /// window was read.
    func chunkedLogsReport(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6,
                           mode: LogScanMode = .patient, lane: LogsGate.Lane = .interactive, order: LogsRouter.Order = .ascending) async -> (logs: [Log], complete: Bool) {
        await chunkedLogsReport(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock, chunkSize: chunkSize, concurrency: concurrency,
                                mode: mode, limits: LogScanLimits(), lane: lane, order: order)
    }

    /// The newest logs of `[fromBlock, toBlock]`, read newest first within `mode`'s budget (`LogsBudget`), as far down as
    /// they were read in one piece (`NewestLogs`): what a figure that is a minimum when the read stops short is built from
    /// — a coin's holders (`LaunchpadService.holders`, `MomentsService.holderStats`) — and a list of the latest events that
    /// says how far back it reaches (`LaunchpadService.trades`). Off the router (a local fork) the scan doesn't say which
    /// blocks it read: a read in part holds nothing, rather than a run it can't vouch for.
    ///
    /// The read stands on its newest range: with `toBlock` unread there is nothing. A head read from these same endpoints
    /// (`block(.latest)` on this client) keeps it within what they serve, and a node a few blocks behind it refusing that
    /// range is asked again after a pause (`LogsRouter.headPause`) rather than three times at once.
    func newestLogs(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, mode: LogScanMode = .patient,
                    lane: LogsGate.Lane = .interactive) async -> NewestLogs {
        guard fromBlock <= toBlock else { return NewestLogs(logs: [], readFrom: toBlock, complete: true) }
        if let logsRouter {
            let read = await logsRouter.read(LogsQuery(address: address, topics: topics), from: fromBlock, to: toBlock, order: .descending, budget: LogsBudget(mode: mode), lane: lane)
            return NewestLogs(read, from: fromBlock, to: toBlock)
        }
        var from = fromBlock
        if isLocal, let forkBlock = await localForkBlock() { from = max(from, forkBlock) }
        let report = await chunkedLogsReport(address: address, topics: topics, fromBlock: from, toBlock: toBlock, mode: mode, lane: lane, order: .descending)
        return report.complete ? NewestLogs(logs: report.logs, readFrom: min(from, toBlock), complete: true) : NewestLogs(logs: [], readFrom: nil, complete: false)
    }

    /// `chunkedLogsReport` within `limits`.
    internal func chunkedLogsReport(address: Address?, topics: [Data?], fromBlock: UInt64, toBlock: UInt64, chunkSize: UInt64? = nil, concurrency: Int = 6,
                                    mode: LogScanMode, limits: LogScanLimits, lane: LogsGate.Lane = .interactive,
                                    order: LogsRouter.Order = .ascending) async -> (logs: [Log], complete: Bool) {
        // A local Anvil fork only holds logs from its fork block on (older ranges are forwarded upstream, where the
        // default RPC caps them at 100 blocks), so a development build scans the fork's own blocks only.
        var fromBlock = fromBlock
        if isLocal, let forkBlock = await localForkBlock() { fromBlock = max(fromBlock, forkBlock) }
        guard fromBlock <= toBlock else { return ([], true) }
        // On mainnet: across the public endpoints, in ranges each answers, within the mode's budget, as many requests at
        // once as the scan asks for and in its lane at the gate (`LogsRouter`).
        if let logsRouter {
            let read = await logsRouter.read(LogsQuery(address: address, topics: topics), from: fromBlock, to: toBlock, order: order, budget: LogsBudget(mode: mode),
                                             concurrency: concurrency, lane: lane)
            return (read.logs, read.covers(fromBlock, toBlock))
        }
        let chunk = max(1, chunkSize ?? logChunkSize)
        let ranges = Self.logRanges(address: address, topics: topics, from: fromBlock, to: toBlock, chunk: chunk, order: order)
        // Newest first, the ranges' answers arrive newest first: the caller gets them in block order, as the router gives them.
        func inOrder(_ read: (logs: [Log], complete: Bool)) -> (logs: [Log], complete: Bool) {
            guard order == .descending else { return read }
            return (read.logs.sorted { a, b in a.blockNumber == b.blockNumber ? a.logIndex < b.logIndex : a.blockNumber < b.blockNumber }, read.complete)
        }
        var scan = LogScan(mode: mode, limits: limits)
        // A wallet-scoped filter (a topic beyond the event signature) is cheap for the wide-range endpoints however
        // far back it reaches: rpc1 answers one wallet's whole transfer history in about a second. Ask for the whole
        // window first, up to three times, and fall back to ranges only when the endpoint refuses it. A refusal for its
        // size is never sent again: the answer would be the same. rpc1 refuses a history of more than 10K logs (an active
        // trader's, or one an airdrop campaign spammed) and names the range from the same start it can answer: the
        // history is then read in such ranges, a request or two for each 10K logs, where 100,000-block ranges took more
        // than a thousand requests, minutes.
        if ranges.count > 1, chunk >= 100_000, topics.dropFirst().contains(where: { $0 != nil }) {
            let whole = LogFilter(address: address, topics: topics, fromBlock: fromBlock, toBlock: toBlock)
            let answer = await logsAnswer(whole, tries: 3, scan: &scan)
            switch answer {
            case .logs(let found): return (found, true)
            case .tooLarge(_?, _): return await narrowedLogs(whole, after: answer, scan: &scan)
            case .tooLarge(nil, _), .failed, .pastHead, .throttled: if Task.isCancelled || scan.down { return ([], false) }
            }
        }
        var out: [Log] = []
        var complete = true
        var next = 0
        var unanswered = 0
        // Ranges a round trip asks: `concurrency`, or as many as fit the endpoint's budget for one request.
        let perTrip = max(1, logBatchSpan.map { min(concurrency, Int(clamping: $0 / chunk)) } ?? concurrency)
        while next < ranges.count, !Task.isCancelled, !scan.down {
            let slice = Array(ranges[next..<min(next + perTrip, ranges.count)])
            next += slice.count
            var answered = false
            let answers = await rangeAnswers(slice, scan: &scan)
            for (filter, answer) in zip(slice, answers) {
                switch answer {
                case .logs(let logs):
                    out.append(contentsOf: logs)
                    answered = true
                case .tooLarge, .pastHead:
                    // Past the node's head: asked again already while the scan's waits lasted (`batchAnswers`).
                    answered = true
                    let narrowed = await narrowedLogs(filter, after: answer, scan: &scan)
                    out.append(contentsOf: narrowed.logs)
                    complete = complete && narrowed.complete
                case .failed where mode != .failFast, .throttled:
                    // As build 15 read it: in halves, which a moment's outage, or a range too heavy for the endpoint to
                    // answer in time, lets through. Throttled still after the waits (paced): the same, once a scan.
                    let narrowed = await narrowedLogs(filter, after: answer, scan: &scan)
                    out.append(contentsOf: narrowed.logs)
                    complete = complete && narrowed.complete
                case .failed:
                    complete = false
                }
            }
            guard mode == .failFast else { continue }
            unanswered = answered ? 0 : unanswered + 1
            if unanswered >= 2 { return inOrder((out, false)) }
        }
        return inOrder((out, complete && next == ranges.count && !scan.down))
    }

    /// `[from, to]` cut into ranges of `chunk` blocks, in the order a scan asks them: ascending, from `from`, the last one
    /// short; descending, from `to` down, each a whole `chunk` but the oldest — so a scan that stops short holds the newest
    /// blocks, read whole.
    internal static func logRanges(address: Address?, topics: [Data?], from: UInt64, to: UInt64, chunk: UInt64, order: LogsRouter.Order) -> [LogFilter] {
        guard from <= to else { return [] }
        let chunk = max(1, chunk)
        var ranges: [LogFilter] = []
        switch order {
        case .ascending:
            var start = from
            while start <= to {
                let end = start + chunk - 1 > to ? to : start + chunk - 1
                ranges.append(LogFilter(address: address, topics: topics, fromBlock: start, toBlock: end))
                if end == UInt64.max { break }
                start = end + 1
            }
        case .descending:
            var end = to
            while true {
                let start = end - from >= chunk ? end - chunk + 1 : from
                ranges.append(LogFilter(address: address, topics: topics, fromBlock: start, toBlock: end))
                if start == from { break }
                end = start - 1
            }
        }
        return ranges
    }

    /// What the endpoint answered each of `filters`, in one round trip: those that failed for a reason other than their
    /// size are asked once more, together, 400 ms later.
    private func rangeAnswers(_ filters: [LogFilter], scan: inout LogScan) async -> [LogsAnswer] {
        var answers = await batchAnswers(filters, scan: &scan)
        let failed = answers.indices.filter { if case .failed = answers[$0] { return true }; return false }
        guard !failed.isEmpty, !Task.isCancelled, !scan.down else { return answers }
        try? await Task.sleep(for: .milliseconds(400))
        let again = await batchAnswers(failed.map { filters[$0] }, scan: &scan)
        for (k, i) in failed.enumerated() { answers[i] = again[k] }
        return answers
    }

    /// One range, asked again while it fails for a reason other than its size: `tries` times in all, 400 ms apart, then
    /// 800 ms.
    private func logsAnswer(_ filter: LogFilter, tries: Int = 2, scan: inout LogScan) async -> LogsAnswer {
        var answer = LogsAnswer.failed
        for attempt in 0..<max(1, tries) {
            if attempt > 0 {
                if Task.isCancelled || scan.down { break }
                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
            answer = await batchAnswers([filter], scan: &scan)[0]
            guard case .failed = answer else { break }
        }
        return answer
    }

    /// Each of `filters` asked once, in one round trip, and recorded in `scan`; every one failed when the request as a
    /// whole got no answer. Paced, those throttled are asked again after a pause while they are throttled, until the
    /// scan finds the endpoint down (`LogScanMode.paced`); a request with no answer at all after a throttle is the
    /// throttle still (a rate limiter drops connections as well as answering 429). Those throttled still after
    /// `LogScanLimits.throttleWaits` waits are `.throttled` — only a range the scan can halve, as many as its
    /// `throttleSplits` — and the rest are waited out until the outage.
    private func batchAnswers(_ filters: [LogFilter], scan: inout LogScan) async -> [LogsAnswer] {
        var (answers, throttled, _) = await ask(filters)
        scan.record(answers)
        var inARow = 0
        var gaveUp = false
        while scan.mode == .paced, !throttled.isEmpty, !scan.down, !Task.isCancelled {
            if !gaveUp, inARow >= scan.limits.throttleWaits, scan.throttleSplits > 0 {
                // A range `LogScan.divide` can't halve (no wider than the floor, or the splits spent) would be a gap.
                let floor: UInt64 = isLocal ? 5_000 : 100
                let halved = Array(throttled.filter { scan.halvesFailures(filters[$0], floor: floor) }.prefix(scan.throttleSplits))
                for i in halved { answers[i] = .throttled }
                throttled.removeAll { halved.contains($0) }
                gaveUp = true
                if throttled.isEmpty { break }
            }
            inARow += 1
            try? await Task.sleep(for: .seconds(scan.throttlePause(after: inARow)))
            if Task.isCancelled { break }
            let again = await ask(throttled.map { filters[$0] })
            scan.record(again.answers)
            for (k, i) in throttled.enumerated() { answers[i] = again.answers[k] }
            if !again.unanswered { throttled = again.throttled.map { throttled[$0] } }
        }
        // Past the head of the node that answered: asked again once it has had time to catch up, while the scan's waits
        // last; past them, read in halves (`LogScan.divide`).
        while !scan.down, !Task.isCancelled {
            let behind = answers.indices.filter { if case .pastHead = answers[$0] { return true }; return false }
            guard !behind.isEmpty, let pause = scan.headPause() else { break }
            try? await Task.sleep(for: .seconds(pause))
            if Task.isCancelled { break }
            let again = await ask(behind.map { filters[$0] })
            scan.record(again.answers)
            for (k, i) in behind.enumerated() { answers[i] = again.answers[k] }
        }
        return answers
    }

    /// Each of `filters` asked once, in one round trip, which of them were throttled, themselves `.failed`, and whether
    /// the request got no answer at all. Throttled, once the client's own retries were spent: the request answered HTTP
    /// 429 or 503 (an endpoint throttling, overloaded or restarting; `RPCClient.isThrottle`), the call a rate-limit error,
    /// or the request got no answer after the endpoint answered it 429 or 503 on the way (`throttles`).
    private func ask(_ filters: [LogFilter]) async -> (answers: [LogsAnswer], throttled: [Int], unanswered: Bool) {
        let throttlesBefore = throttles
        do {
            let results = try await logs(filters)
            guard results.count == filters.count else { return (filters.map { _ in .failed }, [], true) }
            var throttled: [Int] = []
            let answers = zip(filters, results).enumerated().map { i, pair -> LogsAnswer in
                let (filter, result) = pair
                switch result {
                case .success(let logs): return .logs(logs)
                case .failure(let error):
                    if Self.refusesPastHead(error) { return .pastHead }
                    if Self.refusesSize(error) { return .tooLarge(cut: Self.suggestedEnd(error, from: filter.fromBlock, to: filter.toBlock)) }
                    if Self.isRateLimited(error) { throttled.append(i) }
                    return .failed
                }
            }
            return (answers, throttled, false)
        } catch {
            let throttle: Bool
            if case NetworkError.badStatus(let status) = error { throttle = Self.isThrottle(status: status) } else { throttle = (error as? RPCError).map(Self.isRateLimited) ?? false }
            return (filters.map { _ in .failed }, throttle || throttles > throttlesBefore ? Array(filters.indices) : [], true)
        }
    }

    /// Whether an `eth_getLogs` error refuses the range for its size — its block span, or how many logs it would return —
    /// which a smaller range fixes: rpc1's "Log response size exceeded" (-32602, its cap of 10K logs an answer),
    /// rpc.monad.xyz's "eth_getLogs is limited to a 100 range" (-32614), rpc3's "Block range is too large" (-32062), and
    /// the same said in other words. Never a range past the node's head (`refusesPastHead`), a throttle, an internal error
    /// or a node that can't serve the method: a smaller range doesn't reliably fix those, so only a patient scan splits a
    /// range for them (one past the head only once the scan's waits for it are spent), and within its limits
    /// (`LogScanLimits`): splitting every one sends thousands of requests that fail the same way.
    internal static func refusesSize(_ error: RPCError) -> Bool {
        if refusesPastHead(error) { return false }
        let message = error.message.lowercased()
        // not localized: the endpoints' own English, matched as they send it
        let sizes = ["response size", "block range", "too large", "limited to a", "returned more than", "too many logs", "too many results"]
        if sizes.contains(where: message.contains) { return true }
        if isRateLimited(error) { return false }
        return error.code == -32614 || error.code == -32062
    }

    /// Whether an `eth_getLogs` size refusal is about how many logs the range holds — "query returned more than 10000
    /// results", "too many logs", rpc1's "Log response size exceeded" — rather than how wide it is: a narrower range
    /// from the same start is answered, and the refusal says nothing about the endpoint's span (`LogsRouter`, which
    /// reads a span the message names first).
    internal static func refusesCount(_ error: RPCError) -> Bool {
        let message = error.message.lowercased()
        // not localized: the endpoints' own English, matched as they send it
        return ["returned more than", "too many logs", "too many results", "response size"].contains(where: message.contains)
    }

    /// Whether an `eth_getLogs` error refuses the range for ending past the head of the node that answered it — rpc1's
    /// "block range extends beyond current head block" (-32602, probed 2026-09-30), which `refusesSize` would otherwise
    /// take for a size refusal ("block range") and split; rpc2's "block not available: block not found for eth_getLogs,
    /// requested toBlock … is not yet available on the node" (-32014, 2026-10-09), and an upstream's
    /// "ErrUpstreamBlockUnavailable", which read as failures, counted against the range — rather than for its size: a
    /// smaller range from the same start ends there too, and the node reaches it in a moment, so it is asked again first
    /// (`LogsAnswer.pastHead`). rpc2 is the endpoint the newest blocks are read on (`LogsEndpoint.clamps`): its refusal
    /// taken for a failure left them a gap after three asks in a row, a node a few blocks behind the head.
    internal static func refusesPastHead(_ error: RPCError) -> Bool {
        let message = error.message.lowercased()
        // not localized: the endpoint's own English, matched as it sends it
        return message.contains("beyond current head") || message.contains("beyond the current head")
            || message.contains("not yet available on the node") || message.contains("errupstreamblockunavailable")
            || (error.code == -32014 && message.contains("block not available"))
    }

    /// A range refused — for its size, past the node's head, or, patient, for any reason (`answer`) — read in parts down
    /// to 100 blocks (the cap of the default Monad RPC; 5 000 on a local node), each part refused again split again
    /// (`LogScan.divide`): where a size refusal says a range the endpoint can answer ends, else in halves. The endpoint's word is taken up to 200
    /// times a range (about 2M logs on rpc1), then halves only, so no endpoint can keep it splitting off a block at a time.
    /// Patient, a part that would be halved if it failed is asked once, after a pause while the endpoint isn't answering;
    /// every other part is asked twice. A part refused at the smallest size, or once the scan's splits are spent, is left
    /// as a gap, and the range is reported incomplete, as it is when the scan stops part-way.
    private func narrowedLogs(_ filter: LogFilter, after answer: LogsAnswer, scan: inout LogScan) async -> (logs: [Log], complete: Bool) {
        let floor: UInt64 = isLocal ? 5_000 : 100
        var cuts = 200
        guard !scan.down, let parts = scan.divide(filter, after: answer, cuts: &cuts, floor: floor) else { return ([], false) }
        var out: [Log] = []
        var complete = true
        // The parts still to read, the next one last, so the logs come out in block order.
        var pending = Array(parts.reversed())
        while let part = pending.popLast() {
            if Task.isCancelled || scan.down { return (out, false) }
            if scan.pause > 0 {
                try? await Task.sleep(for: .seconds(scan.pause))
                if Task.isCancelled { return (out, false) }
            }
            let reply = await logsAnswer(part, tries: scan.halvesFailures(part, floor: floor) ? 1 : 2, scan: &scan)
            switch reply {
            case .logs(let logs): out.append(contentsOf: logs)
            case .tooLarge, .failed, .pastHead, .throttled:
                if let smaller = scan.divide(part, after: reply, cuts: &cuts, floor: floor) { pending += smaller.reversed() } else { complete = false }
            }
        }
        return (out, complete)
    }

    /// `filter`'s window in two: the first part ending at `cut` when that falls inside the window, else halves. Nil when
    /// the window is no wider than `floor` blocks.
    internal static func split(_ filter: LogFilter, at cut: UInt64? = nil, floor: UInt64) -> [LogFilter]? {
        guard filter.toBlock >= filter.fromBlock, filter.toBlock - filter.fromBlock + 1 > floor else { return nil }
        let half = filter.fromBlock + (filter.toBlock - filter.fromBlock + 1) / 2 - 1
        let end = cut.flatMap { (filter.fromBlock..<filter.toBlock).contains($0) ? $0 : nil } ?? half
        return [LogFilter(address: filter.address, topics: filter.topics, fromBlock: filter.fromBlock, toBlock: end),
                LogFilter(address: filter.address, topics: filter.topics, fromBlock: end + 1, toBlock: filter.toBlock)]
    }

    /// The last block of the range a size refusal says the endpoint can answer, when that range starts at `from` and ends
    /// before `to`: rpc1's refusal ends "this block range should work: [0x6000000, 0x6000b41]". Nil when it names none,
    /// or one that doesn't fit.
    internal static func suggestedEnd(_ error: RPCError, from: UInt64, to: UInt64) -> UInt64? {
        let message = error.message
        guard let open = message.lastIndex(of: "["), let close = message[open...].firstIndex(of: "]") else { return nil }
        let bounds = message[message.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2, bounds.allSatisfy({ $0.count > 2 && $0.lowercased().hasPrefix("0x") }),
              let start = BigUInt(hexQuantity: bounds[0]), let end = BigUInt(hexQuantity: bounds[1]),
              start == BigUInt(from), end >= start, end < BigUInt(to), let cut = UInt64(exactly: end) else { return nil }
        return cut
    }

    /// Block number and timestamp, for anchoring event times without one `eth_getBlockByNumber` per log.
    func block(_ tag: BlockTag = .latest) async throws -> BlockHeader {
        let json = try await call("eth_getBlockByNumber", [tag.json, .bool(false)])
        guard let numberHex = json["number"].string, let number = BigUInt(hexQuantity: numberHex),
              let timestampHex = json["timestamp"].string, let timestamp = BigUInt(hexQuantity: timestampHex)
        else { throw NetworkError.malformedResponse }
        return BlockHeader(number: UInt64(clamping: number), timestamp: Int(clamping: timestamp))
    }

    /// The logs of a mined transaction, or nil while it is pending. Lets callers read events such as
    /// `TokenLaunched` out of their own receipts.
    func transactionLogs(_ hash: Data) async throws -> [Log]? {
        let json = try await call("eth_getTransactionReceipt", [.string(hash.hexString)])
        if json.isNull { return nil }
        return try Self.parseLogs(json["logs"])
    }

    private static func parseLogs(_ json: JSON) throws -> [Log] {
        guard let items = json.array else { throw NetworkError.malformedResponse }
        return try items.map { item in
            guard let log = Log(json: item) else { throw NetworkError.malformedResponse }
            return log
        }
    }
}


/// Process-wide cache of local fork blocks, keyed by endpoint (so every RPC client pointed at the fork shares one lookup).
actor LocalForkInfo {
    static let shared = LocalForkInfo()
    private var blocks: [URL: UInt64?] = [:]
    func block(for url: URL) -> UInt64?? { blocks[url] }
    func set(_ block: UInt64?, for url: URL) { blocks[url] = .some(block) }
}
