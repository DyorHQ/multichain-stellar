import BigInt
import XCTest
@testable import DyorKit

/// How a window of logs is read across the public endpoints (`LogsRouter`): in ranges of what each answers, learning a
/// lower cap from a refusal, resting an endpoint that throttles and moving to the next, within a budget, and saying
/// exactly which blocks were read.
final class LogsRouterTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }

    private static let wide = URL(string: "https://wide.logs-stub.invalid")!
    private static let narrow = URL(string: "https://narrow.logs-stub.invalid")!
    private static let last = URL(string: "https://last.logs-stub.invalid")!

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    /// A transfer of `token` into the wallet at `block`.
    private func transfer(at block: UInt64) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: Int(block % 7))
    }

    private var query: LogsQuery { LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]) }

    /// A router over three stub endpoints: one answering 10,000 blocks in batches of 6, one 1,000 one range a request,
    /// one 100 — each refusing a range past its head, so every one may read up to it (an endpoint that clamps has tests
    /// of its own, below).
    private func router(gate: LogsGate = LogsGate(inFlight: 8, interval: .zero), concurrency: Int = 4, store: (any LogsCapabilityStore)? = nil) -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: Self.wide, span: 10_000, clamps: false), LogsEndpoint(url: Self.narrow, span: 1_000, batch: 1, clamps: false),
                                      LogsEndpoint(url: Self.last, span: 100, clamps: false)],
                          session: URLSession(configuration: configuration), gate: gate, store: store, concurrency: concurrency)
    }

    /// A 60,000-block window is read in six 10,000-block ranges, one request, every block covered, the logs in block order.
    func testAWindowIsReadInTheRangesTheEndpointAnswers() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 45_000), transfer(at: 41_000), transfer(at: 99_000)]) { _ in nil }
        let read = await router().read(query, from: 40_001, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertEqual(read.covered, [40_001...100_000])
        XCTAssertTrue(read.covers(40_001, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [41_000, 45_000, 99_000])
        XCTAssertEqual(read.requests, 1)
        XCTAssertEqual(LogsStub.queries().count, 6)
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"])
    }

    /// A range refused for its size, naming what the endpoint answers ("limited to a 1,000 range"), lowers that endpoint's
    /// span for the rest of the scan and is read again in ranges of that size; the span is remembered.
    func testARefusalNamingTheCapLowersTheSpanAndTheRangeIsReadAgain() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.span > 1_000 ? .error(code: -32614, message: "eth_getLogs is limited to a 1,000 range") : nil
        }) { _ in nil }
        let store = MemoryCapabilityStore()
        let router = router(store: store)
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 1_000)
        XCTAssertEqual(store.span(for: Self.wide), 1_000)
        XCTAssertTrue(LogsStub.queries().dropFirst().allSatisfy { $0.span <= 1_000 }, "every range after the refusal fits the cap")
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"], "the same endpoint reads on, smaller")
    }

    /// A refusal that names nothing halves the span, down to the floor; one at the floor rests the endpoint, and the next
    /// endpoint reads the range.
    func testARefusalAtTheFloorMovesToTheNextEndpoint() async {
        LogsStub.install(head: 2_000, logs: [transfer(at: 1_500)], hostRule: { host, _ in
            host == "wide.logs-stub.invalid" ? .error(code: -32602, message: "block range too large") : nil
        }) { _ in nil }
        let read = await router().read(query, from: 1_001, to: 2_000, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertTrue(read.covers(1_001, 2_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [1_500])
        XCTAssertTrue(LogsStub.hosts().contains("narrow.logs-stub.invalid"), "the narrow endpoint read it")
    }

    /// A range refused for how many logs it holds ("query returned more than 10000 results") is a dense range, not a
    /// narrow endpoint: it is read again in halves on the same endpoint, whose span is neither lowered nor remembered
    /// lower.
    func testARefusalForTooManyLogsSplitsTheRangeAndKeepsTheSpan() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500), transfer(at: 12_000)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.contains(19_500) && range.span > 2_000 ? .error(code: -32005, message: "query returned more than 10000 results") : nil
        }) { _ in nil }
        let store = MemoryCapabilityStore()
        let router = router(store: store)
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [12_000, 19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 10_000, "a dense range is no lesson about the endpoint")
        XCTAssertNil(store.span(for: Self.wide))
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"], "the same endpoint reads the halves")
    }

    /// A refusal naming an absurd span (a hostile endpoint) names no cut: the range is halved, never an overflow.
    func testARefusalNamingAnAbsurdSpanIsHalved() async {
        LogsStub.install(head: 20_000, logs: [transfer(at: 19_500)], hostRule: { host, range in
            host == "wide.logs-stub.invalid" && range.span > 5_000 ? .error(code: -32614, message: "eth_getLogs is limited to a 18446744073709551615 range") : nil
        }) { _ in nil }
        let router = router()
        let read = await router.read(query, from: 10_001, to: 20_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(10_001, 20_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [19_500])
        let spanNow = await router.span(of: Self.wide)
        XCTAssertEqual(spanNow, 5_000)
    }

    /// A scan cancelled (its screen closed) blames no endpoint for the requests cut short: nothing rests, and the next
    /// scan reads on the same endpoint at once.
    func testACancelledScanRestsNoEndpoint() async {
        LogsStub.install(head: 100_000, latency: 0.3) { _ in nil }
        let router = router()
        let cancelled = Task { await router.read(query, from: 1, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10)) }
        try? await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        _ = await cancelled.value
        let stats = await router.stats()
        XCTAssertEqual(stats["wide.logs-stub.invalid"]?.rests ?? 0, 0)
        XCTAssertEqual(stats["wide.logs-stub.invalid"]?.failed ?? 0, 0)
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000)]) { _ in nil }
        let read = await router.read(query, from: 1, to: 100_000, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertTrue(read.covers(1, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [50_000])
        XCTAssertEqual(Set(LogsStub.hosts()), ["wide.logs-stub.invalid"])
    }

    /// An endpoint that throttles (HTTP 429) rests, and the next endpoint reads the window; nothing is left unread.
    func testAThrottledEndpointRestsAndTheNextOneReads() async {
        LogsStub.install(head: 5_000, logs: [transfer(at: 4_500), transfer(at: 1_200)], hostRule: { host, _ in
            host == "wide.logs-stub.invalid" ? .status(429) : nil
        }) { _ in nil }
        let read = await router().read(query, from: 1_001, to: 5_000, budget: LogsBudget(requests: 40, seconds: 30))
        XCTAssertTrue(read.covers(1_001, 5_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [1_200, 4_500])
        let hosts = LogsStub.hosts()
        XCTAssertTrue(hosts.contains("narrow.logs-stub.invalid"))
        XCTAssertLessThanOrEqual(hosts.filter { $0 == "wide.logs-stub.invalid" }.count, 3, "the throttled endpoint is waited for while its rests are short, then left to rest")
    }

    /// Past its budget of requests a scan stops and says exactly what it read: ascending, the blocks from the start;
    /// descending, the blocks down from the end.
    func testTheBudgetBoundsTheScanAndCoverageSaysWhatWasRead() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 10_500), transfer(at: 195_000)]) { _ in nil }
        let up = await router(concurrency: 1).read(query, from: 1, to: 200_000, budget: LogsBudget(requests: 2, seconds: 10))
        XCTAssertEqual(up.requests, 2)
        XCTAssertEqual(up.covered, [1...120_000], "two requests of six 10,000-block ranges")
        XCTAssertEqual(up.through(from: 1), 120_000)
        XCTAssertFalse(up.covers(1, 200_000))
        XCTAssertEqual(up.logs.map(\.blockNumber), [10_500])

        LogsStub.install(head: 200_000, logs: [transfer(at: 10_500), transfer(at: 195_000)]) { _ in nil }
        let down = await router(concurrency: 1).read(query, from: 1, to: 200_000, order: .descending, budget: LogsBudget(requests: 2, seconds: 10))
        XCTAssertEqual(down.covered, [80_001...200_000])
        XCTAssertEqual(down.downTo(200_000), 80_001)
        XCTAssertNil(down.through(from: 1))
        XCTAssertEqual(down.logs.map(\.blockNumber), [195_000])
    }

    /// Batches run in parallel, but never more than the gate allows in flight.
    func testTheGateBoundsRequestsInFlight() async {
        LogsStub.install(head: 600_000, latency: 0.05) { _ in nil }
        let gate = LogsGate(inFlight: 2, interval: .zero)
        let read = await router(gate: gate, concurrency: 4).read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30))
        XCTAssertTrue(read.covers(1, 600_000))
        XCTAssertEqual(read.requests, 10)
        XCTAssertLessThanOrEqual(LogsStub.maxInFlight(), 2)
    }

    /// A range that every endpoint fails is left as a gap after its attempts, and the window is reported as not covered.
    func testARangeNoEndpointAnswersIsAGap() async {
        LogsStub.install(head: 30_000, logs: [transfer(at: 5_000)], hostRule: { _, range in range.contains(15_000) ? .noAnswer : nil }) { _ in nil }
        let read = await router().read(query, from: 1, to: 30_000, budget: LogsBudget(requests: 60, seconds: 30))
        XCTAssertFalse(read.covers(1, 30_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [5_000])
        XCTAssertTrue(read.covered.contains { $0.lowerBound == 1 }, "what was answered is covered")
    }

    /// A client built on the router reads its scans through it, and `complete` is whether the window was covered.
    func testAClientOnTheRouterScansThroughIt() async {
        LogsStub.install(head: 25_000, logs: [transfer(at: 24_000)]) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let client = RPCClient(logsRouter: router(), session: URLSession(configuration: configuration))
        let report = await client.chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 1, toBlock: 25_000, mode: .patient)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [24_000])
        let head = try? await client.blockNumber()
        XCTAssertEqual(head, 25_000, "head reads go to the router's endpoints")
    }

    /// A query's lists: several addresses and several topics at a position go out as the method's arrays, and match as
    /// the endpoint matches them.
    func testAQueryWithListsIsSentAndMatchedAsLists() async throws {
        let other = Address(literal: "0x8888888888888888888888888888888888888888")
        let outgoing = Log(address: other, topics: [transferTopic, walletWord, Data(repeating: 1, count: 32)], data: BigUInt(1).word, blockNumber: 50, transactionHash: Data(repeating: 9, count: 32), logIndex: 0)
        LogsStub.install(head: 100, logs: [transfer(at: 40), outgoing, Log(address: Address(literal: "0x9999999999999999999999999999999999999999"), topics: [transferTopic, walletWord], data: Data(), blockNumber: 60, transactionHash: Data(repeating: 8, count: 32), logIndex: 0)]) { _ in nil }
        let query = LogsQuery(addresses: [token, other], topics: [[transferTopic], [walletWord, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32)]])
        let read = await router().read(query, from: 1, to: 100, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertEqual(read.logs.map(\.blockNumber), [40, 50], "both addresses, either topic; the third log's address isn't listed")
        let json = query.json(from: 1, to: 100)
        XCTAssertEqual(json["address"].array?.count, 2)
        XCTAssertEqual(json["topics"][1].array?.count, 2)
        XCTAssertEqual(json["topics"][0].string, transferTopic.hexString, "a single topic goes out as one, not a list")
        XCTAssertTrue(query.matches(outgoing))
        XCTAssertFalse(query.matches(transfer(at: 1).replacing(address: Address(literal: "0x9999999999999999999999999999999999999999"))))
    }

    func testCoverageMergesTouchingRanges() {
        XCTAssertEqual(LogsRead.merge([50...60, 1...10, 11...20, 30...40, 35...55]), [1...20, 30...60])
        XCTAssertEqual(LogsRead.merge([]), [])
        let read = LogsRead(logs: [], covered: [1...20, 30...60], requests: 0)
        XCTAssertTrue(read.covers(5, 20)); XCTAssertFalse(read.covers(5, 30)); XCTAssertTrue(read.covers(30, 60))
        XCTAssertEqual(read.through(from: 1), 20); XCTAssertNil(read.through(from: 25)); XCTAssertEqual(read.downTo(60), 30)
        XCTAssertEqual(LogsRouter.namedSpan(RPCError(code: -32614, message: "eth_getLogs is limited to a 1,000 range")), 1_000)
        XCTAssertEqual(LogsRouter.namedSpan(RPCError(code: -32614, message: "eth_getLogs is limited to a 100 range")), 100)
        XCTAssertNil(LogsRouter.namedSpan(RPCError(code: -32602, message: "block range too large")))
    }

    // MARK: Endpoints that clamp

    private static let refusing = URL(string: "https://refusing.logs-stub.invalid")!
    private static let clamping = URL(string: "https://clamping.logs-stub.invalid")!

    /// A router over an endpoint that refuses a range past its head (rpc2) and one that answers it clamped (rpc4, rpc3,
    /// rpc1), both 10,000 blocks in batches of 6, so neither is waited for as the wider (`LogsRouter.waitForWider`): the
    /// one that refuses first, as on mainnet, unless `clampingFirst`. `refusing: false` leaves it out.
    private func clampRouter(refusing: Bool = true, clampingFirst: Bool = false) -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let refuser = LogsEndpoint(url: Self.refusing, span: 10_000, clamps: false)
        let clamper = LogsEndpoint(url: Self.clamping, span: 10_000, clamps: true)
        let endpoints = !refusing ? [clamper] : clampingFirst ? [clamper, refuser] : [refuser, clamper]
        return LogsRouter(endpoints: endpoints, session: URLSession(configuration: configuration), gate: LogsGate(inFlight: 8, interval: .zero))
    }

    /// The ranges each host was asked for.
    private func asked(_ url: URL) -> [LogsStub.Range] {
        zip(LogsStub.queries(), LogsStub.hosts()).filter { $0.1 == url.host() }.map(\.0)
    }

    /// Mainnet's endpoints as measured on 2026-10-08/09: rpc2 alone refuses a range past its node's head; rpc4, rpc3 and
    /// rpc1 answer it clamped, and rpc.monad.xyz is taken to. rpc1 answers any batch with HTTP 403: one range a request.
    /// An endpoint nobody measured is taken to clamp.
    func testMainnetsEndpointsSayWhichClampAndRpc1TakesOneRangeARequest() throws {
        let byHost = Dictionary(uniqueKeysWithValues: LogsEndpoints.monadMainnet.map { ($0.url.host() ?? "", $0) })
        XCTAssertEqual(byHost.filter { !$0.value.clamps }.keys.sorted(), ["rpc2.monad.xyz"], "only rpc2 refuses a range past its head")
        XCTAssertEqual(byHost.filter(\.value.clamps).keys.sorted(), ["rpc.monad.xyz", "rpc1.monad.xyz", "rpc3.monad.xyz", "rpc4.monad.xyz"])
        XCTAssertEqual(try XCTUnwrap(byHost["rpc1.monad.xyz"]).batch, 1, "rpc1 answers any JSON-RPC batch with HTTP 403")
        XCTAssertEqual(LogsEndpoints.monadMainnet.first?.url.host(), "rpc2.monad.xyz", "the endpoint the newest blocks are read on comes first")
        XCTAssertEqual(LogsEndpoints.headLag, 600)
        XCTAssertTrue(LogsEndpoint(url: Self.wide, span: 1_000).clamps, "unmeasured: the kind that can't lose a log")
    }

    /// rpc1's batch, as `LogsEndpoints.monadMainnet` gives it, never sends rpc1 a batch: every range goes as a single
    /// JSON-RPC object, and nothing comes back HTTP 403. With the 6 ranges a request of build 22, every request rpc1 was
    /// sent was refused.
    func testRpc1IsNeverSentABatch() async throws {
        let rpc1 = try XCTUnwrap(LogsEndpoints.monadMainnet.first { $0.url.host() == "rpc1.monad.xyz" })
        let stub = URL(string: "https://rpc1.batch-stub.invalid")!
        LogsStub.install(head: 100_000, logs: [transfer(at: 450), transfer(at: 999)], refusingBatches: [stub.host()!]) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let router = LogsRouter(endpoints: [LogsEndpoint(url: stub, span: rpc1.span, batch: rpc1.batch, archive: rpc1.archive, clamps: rpc1.clamps)],
                                session: URLSession(configuration: configuration), gate: LogsGate(inFlight: 8, interval: .zero))
        let read = await router.read(query, from: 1, to: 1_000, head: 100_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(read.covers(1, 1_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [450, 999])
        XCTAssertEqual(read.requests, 10, "ten 100-block ranges, one a request")
        XCTAssertEqual(LogsStub.batchHosts(), [], "no batch, so no HTTP 403")
        XCTAssertEqual(LogsStub.requests(), 10)
    }

    /// The bug in build 22: a node of a clamping endpoint 300 blocks behind answered the newest range up to its own head,
    /// with no error, and the router marked the whole range read — the transfer past that node's head never seen. Now, for
    /// a read given the round's head (the wallet's history, whose answer is kept), a clamping endpoint is asked only for
    /// blocks at least 600 below the head: while the endpoint that refuses past its head rests (throttled), the clamping
    /// one reads every older block, and the newest wait for the other, within the scan's deadline, which reads them — the
    /// transfer found, every block read.
    func testTheNewestBlocksWaitForTheEndpointThatRefusesPastItsHead() async {
        let throttled = RangeCount()
        let answered = RangeLog()
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000), transfer(at: 99_300), transfer(at: 99_900)], hostRule: { host, range in
            // The first request to the endpoint that refuses, six ranges, is throttled; it rests, then answers.
            guard host == Self.refusing.host() else { return nil }
            if throttled.next() <= 6 { return .status(429) }
            answered.add(range)
            return nil
        }, clampedAt: [Self.clamping.host()!: 99_700]) { _ in nil }
        let started = ContinuousClock.now
        let read = await clampRouter().read(query, from: 1, to: 100_000, head: 100_000, order: .descending, budget: LogsBudget(requests: 40, seconds: 20))
        XCTAssertTrue(read.covers(1, 100_000), "every block read")
        XCTAssertEqual(read.logs.map(\.blockNumber), [50_000, 99_300, 99_900], "the transfer past the clamping node's head too")
        let clamped = asked(Self.clamping)
        XCTAssertFalse(clamped.isEmpty, "the clamping endpoint read the older blocks while the other rested")
        XCTAssertTrue(clamped.allSatisfy { $0.to <= 99_400 }, "never a block within 600 of the head: \(clamped.filter { $0.to > 99_400 })")
        XCTAssertTrue(answered.ranges.contains { $0.to == 100_000 }, "the newest blocks answered — not throttled — on the endpoint that refuses past its head: \(answered.ranges)")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(LogsRouter.throttleRest), "they waited out its rest")
    }

    /// Asked first, a clamping endpoint sets the newest blocks aside, reads on below them, and the endpoint that refuses
    /// past its head reads them: read newest first and oldest first alike.
    func testAClampingEndpointAskedFirstLeavesTheNewestToTheOther() async {
        for order in [LogsRouter.Order.descending, .ascending] {
            LogsStub.install(head: 100_000, logs: [transfer(at: 20_000), transfer(at: 99_950)], clampedAt: [Self.clamping.host()!: 99_800]) { _ in nil }
            let read = await clampRouter(clampingFirst: true).read(query, from: 1, to: 100_000, head: 100_000, order: order, budget: LogsBudget(requests: 40, seconds: 10))
            XCTAssertTrue(read.covers(1, 100_000), "\(order)")
            XCTAssertEqual(read.logs.map(\.blockNumber), [20_000, 99_950], "\(order)")
            XCTAssertTrue(asked(Self.clamping).allSatisfy { $0.to <= 99_400 }, "\(order): \(asked(Self.clamping))")
            XCTAssertTrue(asked(Self.refusing).allSatisfy { $0.from >= 99_401 }, "\(order): only the newest blocks were the other's")
        }
    }

    /// The wallet's history (a read given the round's head) with no endpoint that refuses past its head to read the newest
    /// blocks — none, or one that never answers before the deadline: the newest 600 are left unread, a gap the coverage
    /// says, never a clamped answer passed off as read and kept for good.
    func testWithNoEndpointThatRefusesPastItsHeadTheNewestBlocksAreAGap() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000), transfer(at: 99_900)], clampedAt: [Self.clamping.host()!: 99_700]) { _ in nil }
        let alone = await clampRouter(refusing: false).read(query, from: 1, to: 100_000, head: 100_000, order: .descending, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertEqual(alone.covered, [1...99_400])
        XCTAssertFalse(alone.covers(1, 100_000))
        XCTAssertEqual(alone.logs.map(\.blockNumber), [50_000])

        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000), transfer(at: 99_900)], hostRule: { host, _ in host == Self.refusing.host() ? .noAnswer : nil },
                         clampedAt: [Self.clamping.host()!: 99_700]) { _ in nil }
        let started = ContinuousClock.now
        let down = await clampRouter().read(query, from: 1, to: 100_000, head: 100_000, budget: LogsBudget(requests: 40, seconds: 3))
        XCTAssertEqual(down.covered, [1...99_400], "the endpoint that refuses never answered: its blocks are a gap")
        XCTAssertEqual(down.logs.map(\.blockNumber), [50_000])
        XCTAssertTrue(asked(Self.clamping).allSatisfy { $0.to <= 99_400 })
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(8), "waited for it within the deadline, no longer")
    }

    /// The head the caller read keeps from the clamping endpoints only the blocks within 600 of it: a window far below it
    /// is theirs to read whole, and one reaching past the head is held back from the window's end. With no head given — a
    /// screen's read, never kept — nothing is held back, as in build 22.
    func testOnlyTheBlocksNearTheHeadAreKeptFromAClampingEndpoint() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 49_990)]) { _ in nil }
        let given = await clampRouter(refusing: false).read(query, from: 1, to: 50_000, head: 100_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(given.covers(1, 50_000))
        XCTAssertEqual(given.logs.map(\.blockNumber), [49_990])
        LogsStub.install(head: 100_000, logs: [transfer(at: 49_990)]) { _ in nil }
        let past = await clampRouter(refusing: false).read(query, from: 1, to: 50_000, head: 40_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertEqual(past.covered, [1...49_400], "a window past the head given: held back from its end")
        LogsStub.install(head: 100_000, logs: []) { _ in nil }
        let early = await clampRouter(refusing: false).read(query, from: 1, to: 500, head: 500, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertEqual(early.covered, [], "a head within 600 of the first block: nothing is a clamping endpoint's")
        XCTAssertEqual(early.requests, 0)
        LogsStub.install(head: 100_000, logs: [transfer(at: 49_990)]) { _ in nil }
        let screen = await clampRouter(refusing: false).read(query, from: 1, to: 50_000, budget: LogsBudget(requests: 20, seconds: 10))
        XCTAssertTrue(screen.covers(1, 50_000), "no head given: nothing held back")
        XCTAssertEqual(screen.logs.map(\.blockNumber), [49_990])
    }

    /// A screen's read — no head given, never kept: a coin's trades and holders, a Moment's (`RPCClient.newestLogs`) — is
    /// routed as in build 22. With the endpoint that refuses past its head down, its newest blocks still come from a
    /// clamping one and the screen has its newest run to stand on (`NewestLogs`): at worst a few hundred blocks short (the
    /// transfer past the clamping node's own head isn't there) until it reads again. Held back as for the history, every
    /// such screen showed nothing while rpc2 was down, throttled past the deadline or refusing past its head.
    func testAScreensReadWithNoHeadAsksAnyEndpointForTheNewestBlocks() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000), transfer(at: 99_650), transfer(at: 99_900)],
                         hostRule: { host, _ in host == Self.refusing.host() ? .noAnswer : nil }, clampedAt: [Self.clamping.host()!: 99_700]) { _ in nil }
        let started = ContinuousClock.now
        let read = await clampRouter().read(query, from: 1, to: 100_000, order: .descending, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertTrue(read.covers(1, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [50_000, 99_650], "the clamping node's answer, short of its own head")
        XCTAssertTrue(asked(Self.clamping).contains { $0.to == 100_000 }, "the newest range asked of the clamping endpoint")
        let newest = NewestLogs(read, from: 1, to: 100_000)
        XCTAssertEqual(newest.readFrom, 1)
        XCTAssertEqual(newest.logs.map(\.blockNumber), [50_000, 99_650], "something to stand on")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(8), "never waited for the endpoint that is down")
    }

    /// rpc2's refusal of a range past its node's head (-32014, measured 2026-10-09) is that, not a failure: the range is
    /// asked again of rpc2 after a pause, uncounted — never handed to a clamping endpoint — and three refusals in a row
    /// from a node a few blocks behind don't leave the newest blocks a gap.
    func testRpc2sRefusalPastItsHeadIsAskedAgainAfterAPause() async {
        let refusals = RangeCount()
        let pastHead = LogsStub.Failure.error(code: -32014, message: "block not available: block not found for eth_getLogs, requested toBlock 100000 is not yet available on the node")
        LogsStub.install(head: 100_000, logs: [transfer(at: 99_999)], hostRule: { host, range in
            host == Self.refusing.host() && range.to == 100_000 && refusals.next() <= 3 ? pastHead : nil
        }, clampedAt: [Self.clamping.host()!: 99_990]) { _ in nil }
        let started = ContinuousClock.now
        let read = await clampRouter().read(query, from: 90_001, to: 100_000, head: 100_000, order: .descending, budget: LogsBudget(requests: 40, seconds: 20))
        XCTAssertTrue(read.covers(90_001, 100_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [99_999])
        XCTAssertEqual(refusals.count, 4, "refused three times, answered the fourth")
        XCTAssertEqual(asked(Self.clamping).count, 0, "never handed to the clamping endpoint: rpc2 itself, asked again")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .seconds(3), "asked again after 1 s, then after 2 s")
    }
}

/// A count across a test's stub rules, which run on the URL loading system's threads.
private final class RangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    /// The next count: 1 the first time.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// The ranges a test's stub rule let through, from the URL loading system's threads.
private final class RangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [LogsStub.Range] = []
    var ranges: [LogsStub.Range] { lock.lock(); defer { lock.unlock() }; return held }
    func add(_ range: LogsStub.Range) { lock.lock(); held.append(range); lock.unlock() }
}

/// A capability store in memory.
final class MemoryCapabilityStore: LogsCapabilityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [URL: UInt64] = [:]
    func span(for url: URL) -> UInt64? { lock.lock(); defer { lock.unlock() }; return spans[url] }
    func set(span: UInt64, for url: URL) { lock.lock(); spans[url] = span; lock.unlock() }
}

private extension Log {
    func replacing(address: Address) -> Log {
        Log(address: address, topics: topics, data: data, blockNumber: blockNumber, transactionHash: transactionHash, logIndex: logIndex)
    }
}
