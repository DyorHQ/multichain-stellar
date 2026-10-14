import BigInt
import Foundation

public struct RPCError: Error, LocalizedError, Equatable, Sendable {
    public let code: Int
    public let message: String
    /// Revert data (`0x…`) when the node includes it, so callers can decode custom errors.
    public let data: String?

    public init(code: Int, message: String, data: String? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var errorDescription: String? { message }
}

public enum NetworkError: Error, LocalizedError {
    case badStatus(Int)
    case malformedResponse
    case transport(Error)

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return L10n.tr("The server answered with status \(String(code)).")
        case .malformedResponse: return L10n.tr("The server sent a response the app could not read.")
        case .transport(let error): return error.localizedDescription
        }
    }
}

/// Ethereum JSON-RPC over HTTPS with request batching and endpoint failover. `urls` are tried in order when an
/// endpoint fails at the transport level or answers HTTP 429 / 5xx, and calls an endpoint throttles inside an HTTP 200
/// are re-sent to the next endpoint, so one throttled or down public endpoint never takes the app offline. After a
/// failover the answering endpoint is preferred for 30 s, then the primary is tried again. Batches are split into
/// requests of at most `maxBatch` calls. An endpoint that refuses a request outright (HTTP 403: rpc1 refuses every
/// batch) is passed over for the next at once, and sent no batch again (`isRefusal`).
///
/// A read waits less than anything else (speed work, 2026-10-10). A read (`isRead`: the head, a balance, code, a block
/// header, a contract read, a nonce at a past block) is answered the same however many times and wherever it is asked,
/// so asking it twice can never do anything twice:
/// - one endpoint's answer must start within 8 s (`readTimeout`, 6 s without a byte, and a third more however its
///   connection trickles), where every request was given 30 s and a stalled connection held a screen for up to a minute
///   on the app's two endpoints; once it has started, its body is read as long as it keeps coming, no gap longer than
///   6 s, so a large answer on a slow link is read whole (`readDeadline`);
/// - when that endpoint's answer hasn't started within `hedgeDelay` (1.3 s), the next is asked the same — never while an
///   answer is coming in; the first good answer is taken and the other request cancelled (`race`);
/// - a read split into several requests sends them at once, spread over the endpoints within `itemsPerSecond`, where
///   they went one after another (`batch`).
///
/// Everything else — a broadcast, a receipt or a transaction by hash, the nonce, gas and fees a transaction is signed
/// with, a transaction rehearsed before it is signed, a log scan — is sent exactly as before: one endpoint at a time,
/// each given `timeout` (30 s), never two at once, so nothing a user signs is sent or followed twice by this client.
public actor RPCClient {
    /// The primary endpoint — shown in Settings and handed to Privy's embedded wallet.
    public let url: URL
    public let urls: [URL]
    private let session: URLSession
    private let maxBatch: Int
    /// The calls one endpoint is sent of a split read within a second (`batch`, `schedule`): rpc.monad.xyz fails what is
    /// over 50 a second inside an HTTP 200. Nil: no budget is known, or every endpoint is a local node (a fork has none),
    /// and a split read's requests all start at once on the preferred endpoint.
    private let itemsPerSecond: Int?
    private var nextId = 1
    /// The endpoints that refused a batch this session (`isRefusal`): a request of several calls goes to the others.
    private var refusesBatches: Set<Int> = []
    private var preferred = 0
    private var preferredSince = Date.distantPast
    private static let stickiness: TimeInterval = 30
    /// Answers of HTTP 429 or 503 this client has had (`post`, `isThrottle`): a request that then fails with no answer was
    /// throttled on its way (`chunkedLogsReport`, paced).
    private(set) var throttles = 0
    /// Where this client's `chunkedLogsReport` reads: across every public endpoint, in ranges each answers, through the
    /// app's one gate (`LogsRouter`). Nil: this client's own endpoint, in ranges sized by its URL (a local fork, tests).
    public let logsRouter: LogsRouter?
    /// Rounds a throttled request (HTTP 429 or 5xx, or a rate-limit error in an answer) is sent again: `throttleRetries`
    /// for a client on its own; 0 for a router's client, whose router rests the endpoint and asks the next instead.
    private let retries: Int
    /// How long one request may take: anything that isn't a read (`isRead`), and a read of a local node.
    private let timeout: TimeInterval
    /// How long a read may wait on one endpoint without a byte of its answer (`isRead`, `readDeadline`), never more than
    /// `timeout`.
    private let readTimeout: TimeInterval
    /// How long a read waits for its endpoint before the next is asked as well (`race`).
    private let hedgeDelay: TimeInterval

    public init(url: URL, session: URLSession = .shared, maxBatch: Int = 100, retries: Int = RPCClient.throttleRetries, timeout: TimeInterval = 30,
                readTimeout: TimeInterval = RPCClient.readTimeout) {
        self.url = url
        self.urls = [url]
        self.session = session
        self.maxBatch = max(1, maxBatch)
        self.retries = max(0, retries)
        self.timeout = timeout
        self.readTimeout = min(timeout, readTimeout)
        hedgeDelay = Self.hedgeDelay
        itemsPerSecond = nil
        logsRouter = nil
    }

    /// Several interchangeable endpoints for the same chain, in preference order. `itemsPerSecond`: what one of them is
    /// sent of a split read within a second (`batch`).
    public init(urls: [URL], session: URLSession = .shared, maxBatch: Int = 100, itemsPerSecond: Int? = nil,
                readTimeout: TimeInterval = RPCClient.readTimeout, hedgeDelay: TimeInterval = RPCClient.hedgeDelay) {
        precondition(!urls.isEmpty, "RPCClient needs at least one endpoint")
        self.url = urls[0]
        self.urls = urls
        self.session = session
        self.maxBatch = max(1, maxBatch)
        self.itemsPerSecond = urls.allSatisfy(Self.isLocal) ? nil : itemsPerSecond.map { max(1, $0) }
        retries = Self.throttleRetries
        timeout = 30
        self.readTimeout = min(timeout, readTimeout)
        self.hedgeDelay = hedgeDelay
        logsRouter = nil
    }

    /// A client for history reads: head reads fail over across the router's endpoints, and every log scan goes through
    /// the router.
    public init(logsRouter: LogsRouter, session: URLSession = .shared, maxBatch: Int = 100) {
        let urls = logsRouter.urls
        self.url = urls[0]
        self.urls = urls
        self.session = session
        self.maxBatch = max(1, maxBatch)
        retries = Self.throttleRetries
        timeout = 30
        readTimeout = Self.readTimeout
        hedgeDelay = Self.hedgeDelay
        itemsPerSecond = nil
        self.logsRouter = logsRouter
    }

    /// How long a read may wait on one endpoint (`isRead`) without a byte of its answer before it counts as unanswered:
    /// 6 s, thirty times a healthy answer (0.15–0.2 s on an open connection, 0.4–1.1 s on a new one, measured 2026-10-08);
    /// and its answer must start within a third more (8 s), however its connection trickles (`readDeadline`). A
    /// connection that stalled — common on a phone after a network change — held every request 30 s on each endpoint
    /// before.
    public static let readTimeout: TimeInterval = 6

    /// How long a read's answer may take to start on one endpoint (its status and headers in), for a wait of `idle`
    /// seconds without a byte: a third more. Its body is then read as long as it keeps coming, each gap within `idle`,
    /// with no limit in all: a page of creator text (up to about 1.8 MB of hex, `Multicall.readItems`) on a slow link takes
    /// longer than any such limit, and was cut off part way, its board failing on every retry
    /// (`data(for:session:answerWithin:onResponse:)`).
    static func readDeadline(idle: TimeInterval) -> TimeInterval { idle * 4 / 3 }

    /// How long a read waits for its endpoint's answer to start before the next is asked the same (`race`): above a
    /// healthy answer even on a new connection, so a burst of reads is not sent twice, and far below the 30 s a stalled
    /// endpoint cost before.
    public static let hedgeDelay: TimeInterval = 1.3

    /// Whether a call only reads the chain — answered the same however many times and wherever it is asked, and no part
    /// of a transaction being made — so it may be asked of two endpoints at once and given `readTimeout`: the head, a
    /// balance, code, a block header, the chain id, an `eth_call` with neither a sender nor a value (a contract read; one
    /// with either rehearses a transaction before it is signed, `TransactionSender.prepare`, `TokenTransfer`), and a
    /// nonce at a past block (the first-transaction search, a swap's facts; a transaction is signed with the `pending`
    /// one). Everything else — a broadcast, a receipt or a transaction by hash, gas, fees, the pending nonce, logs — is
    /// never asked twice at once. The base fee a transaction is signed with is a header read, asked as one that isn't
    /// (`latestBaseFee`).
    static func isRead(_ method: String, _ params: [JSON]) -> Bool {
        switch method {
        case "eth_blockNumber", "eth_chainId", "eth_getBalance", "eth_getCode", "eth_getBlockByNumber": return true
        case "eth_call":
            guard let request = params.first?.object else { return false }
            return request["from"] == nil && request["value"] == nil
        case "eth_getTransactionCount":
            return params.count > 1 && params[1].string?.hasPrefix("0x") == true
        default: return false
        }
    }

    /// Whether every call of a request is a read (`isRead`): a request with one call that isn't is sent as that call is.
    static func isRead(_ calls: [(method: String, params: [JSON])]) -> Bool {
        !calls.isEmpty && calls.allSatisfy { isRead($0.method, $0.params) }
    }

    // MARK: Raw calls

    public func call(_ method: String, _ params: [JSON] = []) async throws -> JSON {
        let results = try await batch([(method, params)])
        return try results[0].get()
    }

    /// Sends several requests, `maxBatch` per HTTP round trip. Results keep the request order. A read (`isRead`) split into
    /// several requests sends them all at once, each starting on the endpoint and in the second `schedule` gives it, so no
    /// endpoint is sent more of it in a second than `itemsPerSecond`: a chart's 96 calls were three requests one after
    /// another, the second and third mostly refused by rpc.monad.xyz's 50 a second and asked again on rpc1, which refuses
    /// every batch (`isRefusal`). Anything else is sent one request after the other, as before.
    public func batch(_ calls: [(method: String, params: [JSON])]) async throws -> [Result<JSON, RPCError>] {
        guard !calls.isEmpty else { return [] }
        let read = Self.isRead(calls)
        guard calls.count > maxBatch else { return try await batchChunk(calls, from: nil, read: read) }
        let chunks = stride(from: 0, to: calls.count, by: maxBatch).map { Array(calls[$0..<min($0 + maxBatch, calls.count)]) }
        guard read else {
            var results: [Result<JSON, RPCError>] = []
            results.reserveCapacity(calls.count)
            for chunk in chunks { results += try await batchChunk(chunk, from: nil, read: false) }
            return results
        }
        resetStalePreference()
        let endpoints = order(from: preferred, calls: maxBatch)
        let plan = itemsPerSecond.map { Self.schedule(chunks.map(\.count), order: endpoints, budget: $0) }
            ?? chunks.map { _ in (endpoint: endpoints[0], after: TimeInterval(0)) }
        return try await withThrowingTaskGroup(of: (Int, [Result<JSON, RPCError>]).self) { group in
            for (i, chunk) in chunks.enumerated() {
                let start = plan[i]
                group.addTask {
                    if start.after > 0 { try await Task.sleep(for: .seconds(start.after)) }
                    return (i, try await self.batchChunk(chunk, from: start.endpoint, read: true))
                }
            }
            var parts = [[Result<JSON, RPCError>]](repeating: [], count: chunks.count)
            for try await (i, part) in group { parts[i] = part }
            return parts.flatMap { $0 }
        }
    }

    /// Where and when each request of a split read starts (`batch`): the requests of `sizes` calls in order, each in the
    /// earliest second of the read where an endpoint of `order` (indices, the preferred first) leaves room for it under
    /// `budget` calls — of those, the one sent least that second, the earlier in `order` when they tie, so the read is
    /// spread over the endpoints and leaves each the most room for the app's other reads. A request larger than the budget
    /// goes alone. With rpc.monad.xyz's 50 a second and requests of 40, on two endpoints that take batches: 49 calls are 40
    /// and 9 at once, 96 are 40 and 40 at once and 16 a second later — never more than an endpoint answers in a second.
    static func schedule(_ sizes: [Int], order: [Int], budget: Int) -> [(endpoint: Int, after: TimeInterval)] {
        let order = order.isEmpty ? [0] : order
        var used: [[Int: Int]] = []
        return sizes.map { size in
            var second = 0
            while true {
                if used.count <= second { used.append([:]) }
                let sent = used[second]
                let room = order.filter { (sent[$0] ?? 0) == 0 || (sent[$0] ?? 0) + size <= budget }
                if let endpoint = room.min(by: { (sent[$0] ?? 0) < (sent[$1] ?? 0) }) {
                    used[second][endpoint, default: 0] += size
                    return (endpoint, TimeInterval(second))
                }
                second += 1
            }
        }
    }

    /// Whether an HTTP status means "this endpoint, not this request" — worth retrying on the next endpoint.
    static func shouldFailOver(status: Int) -> Bool { status == 429 || (500...599).contains(status) }

    /// Whether an HTTP status is the endpoint throttling or overloaded (429, 503), which waiting eases, rather than this
    /// request failing: another 5xx, such as a gateway timeout for a heavy range, is answered the same every time.
    static func isThrottle(status: Int) -> Bool { status == 429 || status == 503 }

    /// Whether an HTTP status is the endpoint refusing to serve a request of this kind at all (403), rather than an answer
    /// about its calls: rpc1.monad.xyz answers every JSON-RPC batch, even one of a single call, with 403 "Restricted JSON
    /// RPC method", and serves the same calls sent one by one (measured 2026-10-10). Nothing was run: the next endpoint is
    /// asked at once, without a backoff (the endpoint isn't throttling), and one that refused a batch is sent none again
    /// this session (`refusesBatches`).
    static func isRefusal(status: Int) -> Bool { status == 403 }

    /// The endpoints a request of `calls` calls is asked of, in order from `first`: every one, but for a batch none that
    /// refused one this session (`isRefusal`) — unless every endpoint has.
    private func order(from first: Int, calls: Int) -> [Int] {
        let all = (0..<urls.count).map { (first + $0) % urls.count }
        guard calls > 1, !refusesBatches.isEmpty else { return all }
        let taking = all.filter { !refusesBatches.contains($0) }
        return taking.isEmpty ? all : taking
    }

    /// After a failover the answering endpoint is preferred for `stickiness` seconds, then the primary again.
    private func resetStalePreference() {
        if preferred != 0, Date().timeIntervalSince(preferredSince) > Self.stickiness { preferred = 0 }
    }

    /// One JSON-RPC POST of `body` to `url`, waiting up to `timeout` between two packets.
    private static func request(_ url: URL, body: Data, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        request.timeoutInterval = timeout
        return request
    }

    /// POSTs `body`, a request of `calls` calls, to the endpoint `start` (nil: the preferred one), failing over to the next
    /// on a transport error, a 429 / 5xx answer or a refusal (403, `isRefusal`; a batch never to an endpoint that refused
    /// one). When every endpoint is throttling at once (a burst, measured on the live public endpoints) it backs off and
    /// tries again in bounded rounds; when every endpoint is simply unreachable (offline) or refused it, it fails at once
    /// instead. Any other status is the answer about this request: no other endpoint is asked, and its body is returned
    /// with it (`exchange`). One endpoint at a time, each given `timeout`: how everything but a read is sent (`isRead`).
    private func post(_ body: Data, calls: Int, from start: Int?) async throws -> (data: Data, status: Int, endpoint: Int) {
        resetStalePreference()
        let first = start ?? preferred
        var failure: Error = NetworkError.malformedResponse
        for round in 0...retries {
            if round > 0 { try await Task.sleep(for: .milliseconds(400 * round)) }
            var throttled = false
            for index in order(from: first, calls: calls) {
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: Self.request(urls[index], body: body, timeout: timeout))
                } catch {
                    // A cancelled task must stop here, not go on to hit the next endpoint.
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw NetworkError.transport(error) }
                    failure = NetworkError.transport(error)
                    continue
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    failure = NetworkError.badStatus(http.statusCode)
                    if Self.isThrottle(status: http.statusCode) { throttles += 1 }
                    if Self.shouldFailOver(status: http.statusCode) { throttled = true; continue }
                    if Self.isRefusal(status: http.statusCode) {
                        if calls > 1 { refusesBatches.insert(index) }
                        continue
                    }
                    return (data, http.statusCode, index)
                }
                if index != first { preferred = index; preferredSince = Date() }
                return (data, 200, index)
            }
            if !throttled { break } // nothing answered at all (offline / unreachable): waiting won't help
        }
        throw failure
    }

    /// One request's end on one endpoint, in a race (`raceRound`).
    private enum Attempt: Sendable {
        /// `hedgeDelay` passed: the next endpoint may be asked as well.
        case hedge
        /// Every call's answer, in request order.
        case answered(position: Int, results: [Result<JSON, RPCError>])
        /// An answer about the request itself (a status other than 403, 429 and 5xx, a body that can't be read): asked of
        /// one endpoint, the request's end.
        case requestError(position: Int, error: Error)
        /// No answer: a transport error, `readTimeout` passed, HTTP 429 / 5xx, or a refusal (403, `isRefusal`) (`status`).
        case failed(position: Int, error: Error, status: Int?)
    }

    /// How one round of a race ended.
    private enum RoundEnd: Sendable {
        case answered([Result<JSON, RPCError>], endpoint: Int)
        case requestError(Error)
        case failed(Error, throttled: Bool)
        case cancelled(Error)

        var isAnswer: Bool {
            if case .answered = self { return true }
            return false
        }
    }

    /// `post` for a read (`isRead`): from the endpoint `start` (nil: the preferred one), in rounds that end as `post`'s do
    /// — an answer, an answer about the request, or no answer from any endpoint, the throttled ones asked again after the
    /// same backoff. An endpoint that answered after the one asked first is preferred from then on, as after a failover.
    private func race(_ body: Data, ids: Range<Int>, from start: Int?) async throws -> (results: [Result<JSON, RPCError>], endpoint: Int) {
        resetStalePreference()
        let first = start ?? preferred
        var failure: Error = NetworkError.malformedResponse
        for round in 0...retries {
            if round > 0 { try await Task.sleep(for: .milliseconds(400 * round)) }
            let (end, throttleAnswers, refusedBatch) = await raceRound(body, ids: ids, from: first)
            throttles += throttleAnswers
            refusesBatches.formUnion(refusedBatch)
            switch end {
            case .answered(let results, let endpoint):
                if endpoint != first { preferred = endpoint; preferredSince = Date() }
                return (results, endpoint)
            case .requestError(let error):
                throw error
            case .cancelled(let error):
                throw NetworkError.transport(error)
            case .failed(let error, let throttled):
                failure = error
                if !throttled { throw failure } // nothing answered at all (offline / unreachable): waiting won't help
            }
        }
        throw failure
    }

    /// One round of a read: the endpoints in order from `first`, each given its read limits (`readLimit`). The next is
    /// asked at once when one fails (as `post` fails over), and also when the answer of the one asked hasn't started within
    /// `hedgeDelay` — once a round, so at most two are asked at a time. An answer that has started (its status and headers
    /// in, its body coming) is not raced: a large answer on a slow link would only be asked twice over the same link, each
    /// copy slowing the other. The first answer in which every call succeeded is taken at once and the other request
    /// cancelled. An answer with a failed call (a revert, a call throttled, a block the endpoint doesn't hold) is kept
    /// while the other request may still bring one without: a failed call from a faster endpoint never beats a good answer
    /// from the one asked first. When every request has ended without a clean answer, the round ends as one endpoint at a
    /// time would have: an answer before an answer about the request, then the endpoint asked first. Also returns how many
    /// endpoints answered HTTP 429 or 503 (`throttles`), and those that refused the request as a batch (`isRefusal`,
    /// `refusesBatches`).
    private func raceRound(_ body: Data, ids: Range<Int>, from first: Int) async -> (end: RoundEnd, throttled: Int, refusedBatch: Set<Int>) {
        let order = order(from: first, calls: ids.count)
        let targets = order.map { (url: urls[$0], limit: readLimit(for: urls[$0])) }
        let session = session, hedgeDelay = hedgeDelay
        // The requests whose answer has started, by position: told from their own tasks as each answer starts.
        let answering = AnswersStarted()
        return await withTaskGroup(of: Attempt.self) { group in
            var launched = 0, inFlight = 0, hedged = false, throttleAnswers = 0
            var running: Set<Int> = []
            var refusedBatch: Set<Int> = []
            var kept: [(position: Int, end: RoundEnd)] = []
            var failure: Error = NetworkError.malformedResponse
            var throttled = false
            func launch() {
                let position = launched
                let target = targets[position]
                launched += 1
                inFlight += 1
                running.insert(position)
                group.addTask {
                    await Self.attempt(body, to: target.url, session: session, limit: target.limit, ids: ids, position: position) { answering.insert(position) }
                }
            }
            launch()
            if targets.count > 1 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(hedgeDelay))
                    return .hedge
                }
            }
            while inFlight > 0, let attempt = await group.next() {
                switch attempt {
                case .hedge:
                    // Only a request whose answer hasn't started is raced.
                    if !hedged, launched < targets.count, !Task.isCancelled, !running.allSatisfy(answering.contains) { hedged = true; launch() }
                case .answered(let position, let results):
                    inFlight -= 1
                    running.remove(position)
                    if results.allSatisfy({ if case .success = $0 { return true }; return false }) {
                        group.cancelAll()
                        return (.answered(results, endpoint: order[position]), throttleAnswers, refusedBatch)
                    }
                    kept.append((position, .answered(results, endpoint: order[position])))
                case .requestError(let position, let error):
                    inFlight -= 1
                    running.remove(position)
                    kept.append((position, .requestError(error)))
                case .failed(let position, let error, let status):
                    inFlight -= 1
                    running.remove(position)
                    if Task.isCancelled { group.cancelAll(); return (.cancelled(CancellationError()), throttleAnswers, refusedBatch) }
                    failure = error
                    if let status {
                        if Self.shouldFailOver(status: status) { throttled = true }
                        if Self.isThrottle(status: status) { throttleAnswers += 1 }
                        if Self.isRefusal(status: status), ids.count > 1 { refusedBatch.insert(order[position]) }
                    }
                    if inFlight == 0, kept.isEmpty, launched < targets.count { launch() }
                }
            }
            group.cancelAll()
            if Task.isCancelled { return (.cancelled(CancellationError()), throttleAnswers, refusedBatch) }
            let best = kept.min { a, b in
                let rankA = a.end.isAnswer ? 0 : 1, rankB = b.end.isAnswer ? 0 : 1
                return rankA != rankB ? rankA < rankB : a.position < b.position
            }
            return (best?.end ?? .failed(failure, throttled: throttled), throttleAnswers, refusedBatch)
        }
    }

    /// How long a read may wait on `url` without a byte of its answer: `readTimeout`, or `timeout` on a local node — a fork
    /// reads state it hasn't held before from its upstream first, which can take longer. Its answer must start within a
    /// third more (`readDeadline`).
    private func readLimit(for url: URL) -> TimeInterval {
        Self.isLocal(url) ? timeout : readTimeout
    }

    /// Whether `url` is a node on this machine (a local fork), which has no public endpoint's limits: the one rule for the
    /// read limits and the item budget here, and for the log floors and fork-block clamps (`Logs.swift`, `isLocal`).
    static func isLocal(_ url: URL) -> Bool {
        let host = url.host() ?? ""
        return host == "127.0.0.1" || host == "localhost"
    }

    /// One request of a read to one endpoint (`raceRound`): its answer given `limit` seconds without a byte and a third
    /// more to start (`readDeadline`), then read whole as long as it keeps coming. `onResponse` is called as the answer
    /// starts.
    private static func attempt(_ body: Data, to url: URL, session: URLSession, limit: TimeInterval, ids: Range<Int>, position: Int,
                                onResponse: @escaping @Sendable () -> Void) async -> Attempt {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.data(for: request(url, body: body, timeout: limit), session: session, answerWithin: readDeadline(idle: limit),
                                                   onResponse: onResponse)
        } catch {
            return .failed(position: position, error: NetworkError.transport(error), status: nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if !(200..<300).contains(status), shouldFailOver(status: status) || isRefusal(status: status) {
            return .failed(position: position, error: NetworkError.badStatus(status), status: status)
        }
        do {
            return .answered(position: position, results: try decode(data, status: status, ids: ids))
        } catch {
            return .requestError(position: position, error: error)
        }
    }

    /// `session.data(for:)` for a read, its answer given `limit` seconds to start whatever the connection does
    /// (`URLError.timedOut`): `URLRequest.timeoutInterval` only bounds the wait between two packets, so a connection that
    /// trickles without answering would hold it. Once the answer has started — its status and headers in — its body is
    /// read for as long as it keeps coming, each gap within the request's `timeoutInterval`, with no limit in all: a large
    /// answer on a slow link is never cut off part way (`readDeadline`). The body arrives in the chunks the network
    /// delivers (a task delegate, `ReadLoad`). `onResponse` is called once, as the answer starts (`raceRound`, which then
    /// asks no other endpoint). A cancelled task cancels the request at once.
    static func data(for request: URLRequest, session: URLSession, answerWithin limit: TimeInterval,
                     onResponse: (@Sendable () -> Void)? = nil) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        let load = ReadLoad(onResponse: onResponse)
        task.delegate = load
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in load.start(task, answerWithin: limit, continuation) }
        } onCancel: {
            task.cancel()
        }
    }

    /// `session.data(for:)`, given up after `limit` seconds in all whatever the connection does (`URLError.timedOut`),
    /// its body included: for a small answer that must never hold its caller long, such as Kuru Flow's access token
    /// (`KuruFlowClient`). `URLRequest.timeoutInterval` only bounds the wait between two packets.
    static func data(for request: URLRequest, session: URLSession, limit: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(limit))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else { throw URLError(.timedOut) }
            return answer
        }
    }

    /// Opens a connection to each of the first `count` endpoints (all of them when nil) before a read needs it: an
    /// `eth_chainId`, which every node answers from memory, its answer unread. A new connection costs 0.4–1.1 s of
    /// handshakes (measured 2026-10-08), paid by the first screen that reads otherwise. Changes nothing this client keeps:
    /// no preference, no throttle count.
    public func warm(first count: Int? = nil) async {
        let call = JSON.object(["jsonrpc": .string("2.0"), "id": .number(0), "method": .string("eth_chainId"), "params": .array([])])
        guard let body = try? JSONEncoder().encode(call) else { return }
        let targets = Array(urls.prefix(count ?? urls.count)).map { (url: $0, limit: readLimit(for: $0)) }
        let session = session
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask {
                    _ = try? await Self.data(for: Self.request(target.url, body: body, timeout: target.limit), session: session,
                                             answerWithin: Self.readDeadline(idle: target.limit))
                }
            }
        }
    }

    /// Whether a per-call error is the endpoint throttling us rather than an answer about the call itself. Public
    /// endpoints report throttling inside an HTTP 200: QuickNode's rpc.monad.xyz counts batch items (≤ 50/s) and fails
    /// the overflow items with "50/second request limit reached"; others use code -32005 / 429 or "rate limit" text.
    /// Deliberately narrow: execution reverts, gas and nonce errors never match.
    static func isRateLimited(_ error: RPCError) -> Bool {
        if error.code == 429 || error.code == -32005 { return true }
        let message = error.message.lowercased()
        // not localized: the endpoints' own English, matched as they send it
        return message.contains("request limit") || message.contains("rate limit") || message.contains("too many requests")
            || message.contains("per second") || message.contains("throughput")
    }

    /// One batch, plus bounded retries of just the calls the endpoint throttled: each retry goes to the endpoint after the
    /// one that answered (the public endpoints limit differently — items vs. requests — so the other one usually has
    /// room), with a short backoff from the second retry on, and the one that throttled is passed over for a while unless
    /// a request beside this one already moved off it. A throttled call is never executed, so re-sending it is always
    /// safe. `start`: the endpoint asked first (nil: the preferred one); `read`: sent as a read (`isRead`).
    private func batchChunk(_ calls: [(method: String, params: [JSON])], from start: Int?, read: Bool) async throws -> [Result<JSON, RPCError>] {
        var (results, endpoint) = try await exchange(calls, from: start, read: read)
        var throttled = results.indices.filter { if case .failure(let e) = results[$0] { return Self.isRateLimited(e) }; return false }
        var round = 0
        while !throttled.isEmpty, round < retries {
            round += 1
            if urls.count > 1 {
                let next = (endpoint + 1) % urls.count
                if preferred == endpoint { preferred = next; preferredSince = Date() }
                endpoint = next
            }
            if round > 1 { try await Task.sleep(for: .milliseconds(350 * (round - 1))) }
            let retried = try await exchange(throttled.map { calls[$0] }, from: endpoint, read: read)
            endpoint = retried.endpoint
            for (k, i) in throttled.enumerated() { results[i] = retried.results[k] }
            throttled = throttled.filter { if case .failure(let e) = results[$0] { return Self.isRateLimited(e) }; return false }
        }
        return results
    }

    /// Rounds a throttled request is sent again by a client on its own (`retries`).
    public static let throttleRetries = 4

    /// Whether `body` answers every call of a request with ids `ids` with a JSON-RPC error: one error object for a single
    /// call, an array of them for a batch.
    static func isErrorAnswer(_ body: JSON, ids: Range<Int>, single: Bool) -> Bool {
        let responses = single ? [body] : (body.array ?? [])
        guard responses.count == ids.count else { return false }
        let answered = responses.compactMap { response -> Int? in
            guard response["error"]["code"].number != nil || response["error"]["message"].string != nil else { return nil }
            return response["id"].number.flatMap { Int(exactly: $0) }
        }
        return Set(answered) == Set(ids) && answered.count == ids.count
    }

    /// Sends `calls` as one JSON-RPC request — a read raced across the endpoints (`race`), anything else one endpoint at a
    /// time (`post`) — from the endpoint `start` (nil: the preferred one), and maps the answers back to request order.
    /// Also returns the endpoint that answered.
    private func exchange(_ calls: [(method: String, params: [JSON])], from start: Int?, read: Bool) async throws -> (results: [Result<JSON, RPCError>], endpoint: Int) {
        var payload: [JSON] = []
        let firstId = nextId
        for (i, call) in calls.enumerated() {
            payload.append(.object(["jsonrpc": .string("2.0"), "id": .number(Double(firstId + i)), "method": .string(call.method), "params": .array(call.params)]))
        }
        nextId += calls.count
        let body = try JSONEncoder().encode(calls.count == 1 ? payload[0] : .array(payload))
        let ids = firstId..<(firstId + calls.count)
        if read { return try await race(body, ids: ids, from: start) }
        let (data, status, endpoint) = try await post(body, calls: calls.count, from: start)
        return (try Self.decode(data, status: status, ids: ids), endpoint)
    }

    /// The answers to the calls numbered `ids` in `data`, an endpoint's reply with HTTP `status`, in request order. A
    /// call the reply leaves out is a failure of its own ("Missing response").
    static func decode(_ data: Data, status: Int, ids: Range<Int>) throws -> [Result<JSON, RPCError>] {
        let single = ids.count == 1
        let decoded: JSON
        if (200..<300).contains(status) {
            decoded = try JSONDecoder().decode(JSON.self, from: data)
        } else {
            // A request error whose body is the JSON-RPC error of every call in it is that error, as an HTTP 200 would carry
            // it: rpc1 refuses a single-object `eth_getLogs` over its log cap as HTTP 400 (the same call in a one-item
            // array: HTTP 200), and rpc.monad.xyz and rpc4 a range over theirs as HTTP 413, each naming what it can answer
            // in the error (`RPCClient.refusesSize`). Any other body is the status.
            guard (400..<500).contains(status), let body = try? JSONDecoder().decode(JSON.self, from: data),
                  isErrorAnswer(body, ids: ids, single: single)
            else { throw NetworkError.badStatus(status) }
            decoded = body
        }
        let responses = single ? [decoded] : (decoded.array ?? [])
        guard responses.count == ids.count else { throw NetworkError.malformedResponse }

        var byId: [Int: JSON] = [:]
        // `Int(exactly:)`: a hostile or broken RPC can send any JSON number as an id; a non-integer one matches nothing.
        for r in responses { if let id = r["id"].number, let key = Int(exactly: id) { byId[key] = r } }
        return ids.map { id in
            // not localized: RPC messages, read and matched like a node's own
            guard let r = byId[id] else { return .failure(RPCError(code: -1, message: "Missing response")) }
            let error = r["error"]
            if !error.isNull {
                // not localized: the node's own message, or a stand-in for one
                return .failure(RPCError(code: error["code"].number.flatMap { Int(exactly: $0) } ?? -1, message: error["message"].string ?? "RPC error", data: error["data"].string))
            }
            return .success(r["result"])
        }
    }

    // MARK: Typed helpers

    // Quantities from the RPC are converted with `init(exactly:)`: an out-of-range answer is a malformed response, not a
    // crash.
    public func chainId() async throws -> Int {
        let raw = try quantity(await call("eth_chainId"))
        guard let id = Int(exactly: raw) else { throw NetworkError.malformedResponse }
        return id
    }

    public func blockNumber() async throws -> UInt64 {
        let raw = try quantity(await call("eth_blockNumber"))
        guard let number = UInt64(exactly: raw) else { throw NetworkError.malformedResponse }
        return number
    }

    public func balance(of address: Address, block: BlockTag = .latest) async throws -> BigUInt {
        try quantity(await call("eth_getBalance", [.string(address.hex), block.json]))
    }

    public func code(at address: Address) async throws -> Data {
        try bytes(await call("eth_getCode", [.string(address.hex), BlockTag.latest.json]))
    }

    /// The block of `address`'s first transaction — the first block its nonce is 1 at — found by bisection over its
    /// nonce at past blocks (about 27 reads; the public endpoints answer a nonce at any block, measured 2026-10-08).
    /// Nil when it has sent none by `head`.
    public func firstTransactionBlock(of address: Address, head: UInt64) async throws -> UInt64? {
        guard try await transactionCount(of: address, block: .number(head)) > 0 else { return nil }
        var low: UInt64 = 0
        var high = head
        while low < high {
            let mid = low + (high - low) / 2
            if try await transactionCount(of: address, block: .number(mid)) > 0 { high = mid } else { low = mid + 1 }
        }
        return high
    }

    public func transactionCount(of address: Address, block: BlockTag = .pending) async throws -> UInt64 {
        let raw = try quantity(await call("eth_getTransactionCount", [.string(address.hex), block.json]))
        guard let count = UInt64(exactly: raw) else { throw NetworkError.malformedResponse }
        return count
    }

    public func gasPrice() async throws -> BigUInt {
        try quantity(await call("eth_gasPrice"))
    }

    /// The node's suggested EIP-1559 tip.
    public func maxPriorityFeePerGas() async throws -> BigUInt {
        try quantity(await call("eth_maxPriorityFeePerGas"))
    }

    /// The latest block's base fee, or nil on a chain without EIP-1559.
    public func latestBaseFee() async throws -> BigUInt? {
        // The base fee a transaction is signed with: asked as anything but a read is, never of two endpoints at once
        // (`isRead`).
        let json = try await batchChunk([("eth_getBlockByNumber", [BlockTag.latest.json, .bool(false)])], from: nil, read: false)[0].get()
        guard let hex = json["baseFeePerGas"].string else { return nil }
        return BigUInt(hexQuantity: hex)
    }

    public func ethCall(_ tx: CallRequest, block: BlockTag = .latest) async throws -> Data {
        try bytes(await call("eth_call", [tx.json, block.json]))
    }

    /// Several `eth_call`s in one HTTP request, each with its own block tag (multicall cannot span blocks).
    public func ethCalls(_ calls: [(CallRequest, BlockTag)]) async throws -> [Result<Data, RPCError>] {
        try await batch(calls.map { ("eth_call", [$0.0.json, $0.1.json]) }).map { result in
            result.flatMap { json in
                if let data = try? bytes(json) { return .success(data) }
                return .failure(RPCError(code: -1, message: "Malformed call result")) // not localized: an RPC message, as a node's
            }
        }
    }

    public func estimateGas(_ tx: CallRequest) async throws -> BigUInt {
        try quantity(await call("eth_estimateGas", [tx.json]))
    }

    /// Submits a signed transaction and returns its hash. The hash is keccak-256 of the signed bytes, computed here
    /// rather than taken from the node's answer, so what the app follows is always the transaction it signed. When the
    /// network says it already has this exact transaction — a failover resend after the first endpoint accepted it but
    /// its answer was lost — that is success, not an error. "Nonce too low" is success only if this very transaction is
    /// known; otherwise another transaction used the nonce and the error stands.
    public func sendRawTransaction(_ signed: Data) async throws -> Data {
        let hash = Keccak.hash256(signed)
        do {
            guard try bytes(await call("eth_sendRawTransaction", [.string(signed.hexString)])).count == 32 else { throw NetworkError.malformedResponse }
            return hash
        } catch let error as RPCError {
            let message = error.message.lowercased()
            // not localized: the nodes' own English, matched as they send it
            if message.contains("already known") || message.contains("known transaction") || message.contains("already imported") { return hash }
            if message.contains("nonce too low"), let known = try? await call("eth_getTransactionByHash", [.string(hash.hexString)]), !known.isNull { return hash }
            throw error
        }
    }

    /// Whether the network has this transaction: mined (a receipt) or waiting (`eth_getTransactionByHash`). Nil when
    /// neither read got an answer, which says nothing either way.
    public func knowsTransaction(_ hash: Data) async -> Bool? {
        var answered = false
        do {
            if try await transactionReceipt(hash) != nil { return true }
            answered = true
        } catch {}
        do {
            let pending = try await call("eth_getTransactionByHash", [.string(hash.hexString)])
            if !pending.isNull { return true }
            answered = true
        } catch {}
        return answered ? false : nil
    }

    public func transactionReceipt(_ hash: Data) async throws -> TransactionReceipt? {
        let json = try await call("eth_getTransactionReceipt", [.string(hash.hexString)])
        if json.isNull { return nil }
        guard let status = json["status"].string, let block = json["blockNumber"].string, let gasUsed = json["gasUsed"].string else { throw NetworkError.malformedResponse }
        return TransactionReceipt(hash: hash, success: status == "0x1", blockNumber: UInt64(exactly: BigUInt(hexQuantity: block) ?? 0) ?? 0, gasUsed: BigUInt(hexQuantity: gasUsed) ?? 0)
    }

    /// Polls until the transaction is mined. Monad blocks every ~0.4 s, so the interval is short. The budget is a number
    /// of polls (180 × 500 ms, about 90 s of running), not a wall-clock deadline: a run the system suspended (the phone
    /// locked mid-plan) resumes with the polls it had left instead of finding its deadline gone and reporting a mined
    /// transaction as unconfirmed. One last read always follows the final wait.
    ///
    /// `fastPolls` reads come first, `fastInterval` apart (Monad's receipts appear about 300 ms after inclusion, so a
    /// short first phase shows a result sooner); they are polls like the others, added before the `polls` budget.
    public func waitForReceipt(_ hash: Data, polls: Int = 180, interval: Duration = .milliseconds(500),
                               fastPolls: Int = 0, fastInterval: Duration = .milliseconds(150)) async throws -> TransactionReceipt {
        for _ in 0..<max(0, fastPolls) {
            if let receipt = try await pollReceipt(hash) { return receipt }
            try await Task.sleep(for: fastInterval)
        }
        for _ in 0..<max(1, polls) {
            if let receipt = try await pollReceipt(hash) { return receipt }
            try await Task.sleep(for: interval)
        }
        if let receipt = try await pollReceipt(hash) { return receipt }
        throw TransactionError.timedOut(hash)
    }

    /// One receipt read, nil while the transaction is pending. A failed read (a dropped connection on resume, every
    /// endpoint throttled, a malformed answer) says nothing about a transaction that is already broadcast, so it is
    /// also nil — never a failure the user would answer by sending it again. Only cancellation throws.
    private func pollReceipt(_ hash: Data) async throws -> TransactionReceipt? {
        do {
            return try await transactionReceipt(hash)
        } catch let error as CancellationError {
            throw error
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    // MARK: Parsing

    private func quantity(_ json: JSON) throws -> BigUInt {
        guard let s = json.string, let value = BigUInt(hexQuantity: s) else { throw NetworkError.malformedResponse }
        return value
    }

    private func bytes(_ json: JSON) throws -> Data {
        guard let s = json.string, let data = Data(hex: s) else { throw NetworkError.malformedResponse }
        return data
    }
}

/// The requests of a read's round whose answer has started (`RPCClient.raceRound`), by position: told from each request's
/// own task as its answer starts, read by the round when its hedge delay passes.
private final class AnswersStarted: @unchecked Sendable {
    private let lock = NSLock()
    private var positions: Set<Int> = []

    func insert(_ position: Int) {
        lock.lock()
        positions.insert(position)
        lock.unlock()
    }

    func contains(_ position: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return positions.contains(position)
    }
}

/// One read's request (`RPCClient.data(for:session:answerWithin:onResponse:)`): its answer must start within its limit,
/// then its body is appended in the chunks the network delivers, as long as it keeps coming, and it answers once. Its
/// callbacks run on the session's serial delegate queue, the limit's on a global one, and `start` on the caller's; the
/// continuation and what decides the answer are handed between them under a lock, so it is resumed exactly once,
/// whichever comes first — the task's completion, or a cancellation that got in before the task was resumed.
private final class ReadLoad: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onResponse: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    /// The answer didn't start within the limit: the request was cancelled for that, and fails as timed out.
    private var expired = false

    init(onResponse: (@Sendable () -> Void)?) {
        self.onResponse = onResponse
    }

    func start(_ task: URLSessionDataTask, answerWithin limit: TimeInterval, _ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        // Only a task never resumed can be started. One already cancelled (canceling, or completed if its completion
        // came first) may never report back, so it is answered here; one cancelled from now on reports its completion,
        // which finds the continuation stored.
        lock.lock()
        let startable = task.state == .suspended
        if startable { self.continuation = continuation }
        lock.unlock()
        guard startable else { continuation.resume(throwing: CancellationError()); return }
        task.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self, weak task] in
            guard let self, let task else { return }
            self.expire(task)
        }
    }

    /// The limit passed: a request whose answer hasn't started is cancelled, and fails as timed out.
    private func expire(_ task: URLSessionDataTask) {
        lock.lock()
        let waiting = response == nil && continuation != nil
        if waiting { expired = true }
        lock.unlock()
        if waiting { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let late = expired
        if !late {
            self.response = response
            data.reserveCapacity(Int(min(max(response.expectedContentLength, 0), 16 << 20)))
        }
        lock.unlock()
        guard !late else { completionHandler(.cancel); return }
        completionHandler(.allow)
        onResponse?()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let expired = expired, response = response, data = data
        lock.unlock()
        guard let continuation else { return }
        if expired { continuation.resume(throwing: URLError(.timedOut)) }
        else if let error { continuation.resume(throwing: error) }
        else if let response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: URLError(.badServerResponse)) }
    }
}

public enum BlockTag: Sendable, Equatable {
    case latest
    case pending
    case number(UInt64)

    var json: JSON {
        switch self {
        case .latest: return .string("latest")
        case .pending: return .string("pending")
        case .number(let n): return .string(BigUInt(n).hexQuantity)
        }
    }
}

/// The parameters of `eth_call` / `eth_estimateGas` / a transaction to sign.
public struct CallRequest: Sendable, Equatable {
    public var from: Address?
    public var to: Address
    public var data: Data
    public var value: BigUInt

    public init(from: Address? = nil, to: Address, data: Data = Data(), value: BigUInt = 0) {
        self.from = from
        self.to = to
        self.data = data
        self.value = value
    }

    var json: JSON {
        var o: [String: JSON] = ["to": .string(to.hex), "data": .string(data.hexString)]
        if let from { o["from"] = .string(from.hex) }
        if value > 0 { o["value"] = .string(value.hexQuantity) }
        return .object(o)
    }
}

public struct TransactionReceipt: Sendable, Equatable {
    public let hash: Data
    public let success: Bool
    public let blockNumber: UInt64
    public let gasUsed: BigUInt
}

public enum TransactionError: Error, LocalizedError {
    case timedOut(Data)
    case reverted(Data)
    case rejected(String)
    /// Signed and handed to the network, but no endpoint's answer arrived to say it was taken: it may be live. Follow
    /// this hash; never sign a replacement for it.
    case possiblySent(Data)

    /// Sent — or possibly sent — with no confirmation seen, in the app's language.
    public static var unconfirmed: String { L10n.tr("Sent — confirmation not seen yet. Check it before trying again.") }

    public var errorDescription: String? {
        switch self {
        case .timedOut, .possiblySent: return Self.unconfirmed
        case .reverted: return L10n.tr("The transaction was mined but reverted.")
        case .rejected(let reason): return reason
        }
    }

    /// The transaction this error is about, when it has one.
    public var hash: Data? {
        switch self {
        case .timedOut(let hash), .reverted(let hash), .possiblySent(let hash): return hash
        case .rejected: return nil
        }
    }
}
