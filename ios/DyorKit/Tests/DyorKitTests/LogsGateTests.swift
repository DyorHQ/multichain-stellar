import BigInt
import XCTest
@testable import DyorKit

/// The one gate every `eth_getLogs` goes through (`LogsGate`): a free slot goes to a screen's request first, then the
/// history's, then the background's, each lane first come first served; the background never holds more than its one
/// slot; a request cancelled while it waits leaves the queue and takes neither a slot nor a start. And what reaches it
/// from a scan (`LogsRouter.read`, `RPCClient.chunkedLogsReport`, `HistoryStore`): the lane and the requests at once the
/// scan asks for, the history's head read once a round.
final class LogsGateTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }
    private var query: LogsQuery { LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]) }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    // MARK: The gate

    /// With every slot taken, the requests waiting go through as slots free: a screen's first, in the order they came,
    /// then the history's, then the background's — whatever order they came in.
    func testAFreeSlotGoesToTheScreenThenTheHistoryThenTheBackground() async throws {
        let gate = LogsGate(inFlight: 1, interval: .zero)
        let held = try unwrapped(await gate.enter(.history))
        let order = Recorder()
        var waiters: [Task<Void, Never>] = []
        let arrivals: [(LogsGate.Lane, String)] = [(.background, "background"), (.history, "history 1"), (.interactive, "screen 1"), (.history, "history 2"),
                                                   (.interactive, "screen 2"), (.background, "background 2")]
        for (lane, name) in arrivals {
            waiters.append(Task {
                guard let slot = await gate.enter(lane) else { return }
                await order.add(name)
                await gate.leave(slot)
            })
            // Each queued before the next comes, so "the order they came" is this order.
            let queued = waiters.count
            try await waitUntil { await gate.state().waiting.values.reduce(0, +) == queued }
        }
        await gate.leave(held)
        for waiter in waiters { await waiter.value }
        let names = await order.names
        XCTAssertEqual(names, ["screen 1", "screen 2", "history 1", "history 2", "background", "background 2"])
        let state = await gate.state()
        XCTAssertEqual(state.holding, [:])
        XCTAssertEqual(state.waiting, [:])
    }

    /// The background holds one slot at most: a second background request waits with three slots free, while a screen's
    /// and the history's go straight through; it goes once the first is handed back. The app's gate is so.
    func testTheBackgroundNeverHoldsMoreThanOneSlot() async throws {
        let gate = LogsGate(inFlight: 4, interval: .zero, backgroundSlots: 1)
        let first = try unwrapped(await gate.enter(.background))
        let second = Task { await gate.enter(.background) }
        try await waitUntil { await gate.state().waiting[.background] == 1 }
        let screen = try unwrapped(await gate.enter(.interactive))
        let history = try unwrapped(await gate.enter(.history))
        var state = await gate.state()
        XCTAssertEqual(state.holding, [.background: 1, .interactive: 1, .history: 1])
        XCTAssertEqual(state.waiting, [.background: 1], "a slot free, yet the background's second request waits")
        await gate.leave(first)
        let next = await second.value
        XCTAssertEqual(next?.lane, .background)
        state = await gate.state()
        XCTAssertEqual(state.holding, [.background: 1, .interactive: 1, .history: 1])
        XCTAssertEqual(state.waiting, [:])
        for slot in [next, screen, history].compactMap({ $0 }) { await gate.leave(slot) }
        let shared = await LogsGate.shared.backgroundSlots
        XCTAssertEqual(shared, 1, "the app's gate: the background one request at a time")
    }

    /// A request cancelled while it waits (its screen closed) is told so at once, leaves the queue, and takes neither a
    /// slot nor a start: the next request keeps its space from the last real start only.
    func testACancelledWaiterLeavesTheQueueAndTakesNothing() async throws {
        let gate = LogsGate(inFlight: 1, interval: .milliseconds(200))
        let held = try unwrapped(await gate.enter(.history))
        let before = await gate.state().lastStart
        XCTAssertNotNil(before)
        let waiter = Task { await gate.enter(.interactive) }
        try await waitUntil { await gate.state().waiting[.interactive] == 1 }
        waiter.cancel()
        let slot = await waiter.value
        XCTAssertNil(slot)
        var state = await gate.state()
        XCTAssertEqual(state.waiting, [:], "it left the queue")
        XCTAssertEqual(state.holding, [.history: 1], "it took no slot")
        XCTAssertEqual(state.lastStart, before, "nor a start")
        await gate.leave(held)
        state = await gate.state()
        XCTAssertEqual(state.holding, [:])
        XCTAssertEqual(state.lastStart, before)

        // A task already cancelled never queues.
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.enter(.interactive)
        }
        let none = await cancelled.value
        XCTAssertNil(none)
        state = await gate.state()
        XCTAssertEqual(state.holding, [:])
        XCTAssertEqual(state.waiting, [:])
    }

    /// A request cancelled as the slot it waits for frees — let through, or withdrawn first, whichever comes — ends with
    /// nothing taken: the slot and the start go back.
    func testACancelledRequestLetThroughGivesTheSlotAndTheStartBack() async throws {
        for _ in 0..<20 {
            let gate = LogsGate(inFlight: 1, interval: .zero)
            let held = try unwrapped(await gate.enter(.history))
            let before = await gate.state().lastStart
            let waiter = Task { await gate.enter(.interactive) }
            try await waitUntil { await gate.state().waiting[.interactive] == 1 }
            waiter.cancel()
            await gate.leave(held)
            let slot = await waiter.value
            XCTAssertNil(slot)
            try await waitUntil { await gate.state().waiting.isEmpty }
            let state = await gate.state()
            XCTAssertEqual(state.holding, [:], "no slot kept")
            XCTAssertEqual(state.lastStart, before, "no start kept")
        }
    }

    /// The speed review's finding (2026-10-09): with priority alone, a screen's long scan (four requests at once, its next
    /// queued before a slot frees) held every history round back for as long as it read, and the history aged past what
    /// counts as up to now. Once the history's oldest request has waited `historyWait`, the next free slot is its, ahead of
    /// a screen's that came later; before that, the screen's goes first.
    func testAHistoryRequestThatWaitedItsShareGoesBeforeAScreens() async throws {
        for (wait, expected) in [(Duration.milliseconds(100), ["history", "screen"]), (.seconds(30), ["screen", "history"])] {
            let gate = LogsGate(inFlight: 1, interval: .zero, historyWait: wait)
            let held = try unwrapped(await gate.enter(.interactive))
            let order = Recorder()
            let history = Task {
                guard let slot = await gate.enter(.history) else { return }
                await order.add("history")
                await gate.leave(slot)
            }
            try await waitUntil { await gate.state().waiting[.history] == 1 }
            let screen = Task {
                guard let slot = await gate.enter(.interactive) else { return }
                await order.add("screen")
                await gate.leave(slot)
            }
            try await waitUntil { await gate.state().waiting[.interactive] == 1 }
            try await Task.sleep(for: .milliseconds(150))
            await gate.leave(held)
            await history.value
            await screen.value
            let names = await order.names
            XCTAssertEqual(names, expected, "history waits \(wait)")
        }
        let shared = await LogsGate.shared.historyWait
        XCTAssertEqual(shared, .seconds(2), "the app's gate: one start in eight for the history while a screen reads")
    }

    /// The space between starts holds: three requests on a free gate start a space apart.
    func testStartsKeepTheirSpace() async throws {
        let gate = LogsGate(inFlight: 3, interval: .milliseconds(100))
        let started = ContinuousClock.now
        var slots: [LogsGate.Slot] = []
        for _ in 0..<3 { slots.append(try unwrapped(await gate.enter(.interactive))) }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(200))
        for slot in slots { await gate.leave(slot) }
    }

    // MARK: What reaches it

    private func router(gate: LogsGate, concurrency: Int = 4) -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                          gate: gate, concurrency: concurrency)
    }

    /// A scan asks for fewer requests at once than the router's own and gets them: the finding (build 22) was the venue
    /// list's "one at a time" read four at once on the router, which left the argument out. More than the router's own
    /// stays the router's.
    func testAScanGetsTheRequestsAtOnceItAsksFor() async {
        LogsStub.install(head: 600_000, latency: 0.05) { _ in nil }
        let one = await router(gate: LogsGate(inFlight: 8, interval: .zero)).read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30), concurrency: 1)
        XCTAssertTrue(one.covers(1, 600_000))
        XCTAssertEqual(one.requests, 10)
        XCTAssertEqual(LogsStub.maxInFlight(), 1)

        LogsStub.install(head: 600_000, latency: 0.05) { _ in nil }
        let capped = await router(gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 2).read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30),
                                                                                                    concurrency: 6)
        XCTAssertTrue(capped.covers(1, 600_000))
        XCTAssertLessThanOrEqual(LogsStub.maxInFlight(), 2, "never more than the router's own")

        // Through the client every reader scans with: the venue list's call, one at a time in the background lane.
        LogsStub.install(head: 600_000, logs: [transfer(at: 300_000)], latency: 0.05) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let client = RPCClient(logsRouter: router(gate: LogsGate(inFlight: 8, interval: .zero)), session: URLSession(configuration: configuration))
        let venue = await client.chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 1, toBlock: 600_000, concurrency: 1, mode: .paced,
                                                   lane: .background)
        XCTAssertTrue(venue.complete)
        XCTAssertEqual(venue.logs.map(\.blockNumber), [300_000])
        XCTAssertEqual(LogsStub.maxInFlight(), 1, "one request at a time")
    }

    /// A scan's lane reaches the gate: a background scan waits while the background's one slot is held, with slots
    /// free, and reads once it is handed back — one request at a time whatever the router allows.
    func testABackgroundScanWaitsInTheBackgroundLane() async throws {
        LogsStub.install(head: 600_000, logs: [transfer(at: 450_000)], latency: 0.02) { _ in nil }
        let gate = LogsGate(inFlight: 4, interval: .zero)
        let held = try unwrapped(await gate.enter(.background))
        let router = router(gate: gate)
        let scan = Task { await router.read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30), lane: .background) }
        // The router's four batches wait, three slots free.
        try await waitUntil { await gate.state().waiting[.background] == 4 }
        XCTAssertEqual(LogsStub.requests(), 0, "nothing sent while the background's slot is held")
        await gate.leave(held)
        let read = await scan.value
        XCTAssertTrue(read.covers(1, 600_000))
        XCTAssertEqual(read.logs.map(\.blockNumber), [450_000])
        XCTAssertEqual(LogsStub.maxInFlight(), 1)
    }

    /// The speed review's finding (2026-10-09): a background scan's seconds counted its waits at the gate, behind every
    /// screen and history round by design, so a user browsing timed the venue list's run out with its endpoints answering.
    /// They count the time its requests were out: held at the gate past its seconds, it reads on once let through. A
    /// screen's scan, which waits behind nobody but another screen, keeps its seconds as they are.
    func testABackgroundScansSecondsLeaveOutItsWaitsAtTheGate() async throws {
        // Twelve ranges of 10,000 blocks: two requests of six, one at a time.
        for (lane, whole) in [(LogsGate.Lane.background, true), (.interactive, false)] {
            LogsStub.install(head: 120_000, logs: [transfer(at: 5_000), transfer(at: 115_000)]) { _ in nil }
            let gate = LogsGate(inFlight: 1, interval: .zero)
            let held = try unwrapped(await gate.enter(lane))
            let router = router(gate: gate)
            let scan = Task { await router.read(query, from: 1, to: 120_000, order: .descending, budget: LogsBudget(requests: 20, seconds: 0.3), concurrency: 1, lane: lane) }
            try await waitUntil { await gate.state().waiting[lane] == 1 }
            try await Task.sleep(for: .milliseconds(500))
            await gate.leave(held)
            let read = await scan.value
            XCTAssertEqual(read.covers(1, 120_000), whole, "\(lane)")
            XCTAssertEqual(read.requests, whole ? 2 : 1, "\(lane)")
            XCTAssertEqual(read.logs.map(\.blockNumber), whole ? [5_000, 115_000] : [115_000], "\(lane): the newest first")
        }
    }

    /// A scan cancelled while its requests wait at the gate (its screen closed) sends none of them, counts none, leaves
    /// the queue, and the gate is as it was.
    func testACancelledScanLeavesTheGateAsItWas() async throws {
        LogsStub.install(head: 600_000) { _ in nil }
        let gate = LogsGate(inFlight: 1, interval: .milliseconds(50))
        let held = try unwrapped(await gate.enter(.history))
        let before = await gate.state().lastStart
        let router = router(gate: gate)
        let scan = Task { await router.read(query, from: 1, to: 600_000, budget: LogsBudget(requests: 20, seconds: 30)) }
        try await waitUntil { await gate.state().waiting[.interactive] == 4 }
        scan.cancel()
        let read = await scan.value
        XCTAssertEqual(read.requests, 0, "no request was sent")
        XCTAssertEqual(read.covered, [])
        XCTAssertEqual(LogsStub.requests(), 0)
        let state = await gate.state()
        XCTAssertEqual(state.waiting, [:])
        XCTAssertEqual(state.holding, [.history: 1])
        XCTAssertEqual(state.lastStart, before)
        let stats = await router.stats()
        XCTAssertNil(stats["wide.logs-stub.invalid"], "no endpoint blamed")
        await gate.leave(held)
    }

    /// The wallet's history reads in the history lane: behind a screen's request, ahead of the background's.
    func testTheHistoryReadsInTheHistoryLane() async throws {
        LogsStub.install(head: 200_000) { _ in nil }
        let gate = LogsGate(inFlight: 1, interval: .zero)
        let held = try unwrapped(await gate.enter(.interactive))
        let store = HistoryStore(router: router(gate: gate, concurrency: 1), directory: nil)
        let scan = HistoryScan(id: "transfers-in", query: query, floor: .blocks(100_000))
        let refresh = Task { await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10), at: BlockHeader(number: 200_000, timestamp: 1_790_000_000)) }
        try await waitUntil { await gate.state().waiting[.history] == 1 }
        await gate.leave(held)
        let entry = await refresh.value
        XCTAssertTrue(entry.complete)
    }

    /// A round reads the chain head once for every scan, not once a scan: one `eth_getBlockByNumber` of the latest block
    /// for five scans, from the session's shared head (`BlockClock.head`, `WalletHistoryService.roundHead`) and, only when
    /// that can't be read, from the logs endpoints. Given a head, a scan reads to it and reads none itself; given none (the
    /// round couldn't read it), it says the chain wasn't reached and asks nothing.
    func testARoundReadsTheHeadOnceForEveryScan() async {
        let heads = HeadReads()
        let head = LaunchpadAddresses.feeHistoryStart + 50_000
        LogsStub.install(head: head, answer: { host, method, params in
            if method == "eth_getBlockByNumber", params[0].string == "latest" { heads.add(host) }
            return nil
        }) { _ in nil }
        let store = HistoryStore(router: router(gate: LogsGate(inFlight: 8, interval: .zero)), directory: nil)
        let logsClient = LogsStub.rpc()
        let clock = BlockClock(rpc: logsClient, measured: BlockClock.fallbackSecondsPerBlock)
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: logsClient, clock: clock), clock: clock,
                                           stacks: { [LaunchpadAddresses.monadMainnet] }, cohorts: [MomentsAddresses.monadMainnet])
        let snapshot = await service.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [:])
        XCTAssertEqual(snapshot.anchor?.number, head)
        XCTAssertEqual(Set(snapshot.status.keys), Set(WalletHistoryScans.ids))
        XCTAssertTrue(snapshot.complete, "\(snapshot.status)")
        XCTAssertEqual(heads.hosts, [LogsStub.url.host()!], "one head read for the five scans, the session's shared one")
        let shared = await clock.head.known
        XCTAssertEqual(shared?.number, head, "and kept for the readers after it")

        // A scan given the head reads to it, and reads no head itself.
        let scan = HistoryScan(id: "given", query: query, floor: .blocks(10_000))
        let given = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10), at: BlockHeader(number: head - 1_000, timestamp: 1_790_000_000))
        XCTAssertEqual(given.head, head - 1_000)
        XCTAssertTrue(given.complete)
        XCTAssertEqual(heads.count, 1)

        // Given none: the chain wasn't reached, nothing moved, nothing asked.
        let requests = LogsStub.requests()
        let unread = HistoryScan(id: "unread", query: query, floor: .blocks(10_000))
        let unreached = await store.refresh(unread, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10), at: nil)
        XCTAssertFalse(unreached.reachedChain)
        XCTAssertNil(unreached.head)
        XCTAssertEqual(LogsStub.requests(), requests)

        // The shared head unread (its endpoint answers no header): the round reads the logs endpoints' own, once.
        let fallbackHeads = HeadReads()
        LogsStub.install(head: head + 10, answer: { host, method, params in
            guard method == "eth_getBlockByNumber", params[0].string == "latest" else { return nil }
            fallbackHeads.add(host)
            return host == LogsStub.url.host() ? .object([:]) : nil
        }) { _ in nil }
        let next = await service.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [:])
        XCTAssertEqual(next.anchor?.number, head + 10)
        XCTAssertTrue(next.complete, "\(next.status)")
        XCTAssertEqual(fallbackHeads.hosts, [LogsStub.url.host()!, "wide.logs-stub.invalid"])
    }

    // MARK: Helpers

    private func transfer(at block: UInt64) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: 0)
    }

    /// Waits until `condition` holds, for at most five seconds.
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `value`, failing the test when it is nil: `XCTUnwrap` takes no `await` in its argument.
    private func unwrapped<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// Names in the order they were added.
private actor Recorder {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

/// Head reads counted, from any thread.
private final class HeadReads: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    /// The host of each head read, in order.
    var hosts: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    func add(_ host: String) { lock.lock(); asked.append(host); lock.unlock() }
}
