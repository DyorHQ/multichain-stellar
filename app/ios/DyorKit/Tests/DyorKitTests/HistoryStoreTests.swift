import BigInt
import XCTest
@testable import DyorKit

/// A wallet's history kept on the device (`HistoryStore`): refreshed from the newest block read, filled back to the
/// floor newest first within a budget, saved as it goes, never claiming a block it didn't read; and the records the
/// screens read built from it (`WalletHistoryService`).
final class HistoryStoreTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func transfer(at block: UInt64, index: Int = 0) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: index)
    }

    private func router(concurrency: Int = 1) -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                          gate: LogsGate(inFlight: 8, interval: .zero), concurrency: concurrency)
    }

    private var scan: HistoryScan { HistoryScan(id: "transfers-in", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .blocks(100_000)) }

    /// The first refresh reads down from the head, newest blocks first, as far as its budget goes; the entry says what
    /// it covers and how far it got, and keeps the head's time for the records' times.
    func testTheFirstRefreshReadsDownFromTheHeadWithinItsBudget() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 199_500), transfer(at: 150_000), transfer(at: 101_000)]) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let entry = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 10))
        XCTAssertEqual(entry.head, 200_000)
        XCTAssertEqual(entry.headTimestamp, 1_790_000_000)
        XCTAssertEqual(entry.floor, 100_000)
        XCTAssertEqual(entry.covered, [140_001...200_000], "one request: six 10,000-block ranges down from the head")
        XCTAssertEqual(entry.logs.map(\.blockNumber), [150_000, 199_500], "block order")
        XCTAssertFalse(entry.complete)
        XCTAssertEqual(entry.unread, 40_001)
        XCTAssertEqual(entry.progress, 1 - 40_001.0 / 100_001.0, accuracy: 0.0001)
        XCTAssertEqual(entry.through, 200_000)
        XCTAssertTrue(entry.reachedChain)
    }

    /// The next refresh reads the new blocks first, then goes on filling down to the floor; past the floor it is
    /// complete, and the entry survives a new store (it is on disk).
    func testTheNextRefreshReadsNewBlocksThenFillsTheGap() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 199_500), transfer(at: 150_000), transfer(at: 101_000)]) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        _ = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 10))

        LogsStub.install(head: 203_000, logs: [transfer(at: 199_500), transfer(at: 150_000), transfer(at: 101_000), transfer(at: 202_000)]) { _ in nil }
        let again = HistoryStore(router: router(), directory: directory)
        let cached = await again.cached(scan, wallet: wallet)
        XCTAssertEqual(cached.covered, [140_001...200_000], "loaded from disk")
        let entry = await again.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 3, seconds: 10))
        XCTAssertEqual(entry.head, 203_000)
        XCTAssertEqual(entry.floor, 103_000)
        XCTAssertTrue(entry.complete, "the new blocks, then the gap down to the floor")
        XCTAssertEqual(entry.logs.map(\.blockNumber), [150_000, 199_500, 202_000], "the log below the floor is dropped, the new one added")
        XCTAssertEqual(entry.unread, 0)
        let queries = LogsStub.queries()
        XCTAssertEqual(queries.first?.from, 198_800, "the new blocks first, from 1,200 below the newest read")
        XCTAssertEqual(queries.first?.to, 203_000)
        XCTAssertEqual(HistoryStore.overlap, 2 * LogsEndpoints.headLag)
    }

    /// The bug in build 22: a round's newest range answered by a node of a clamping endpoint hundreds of blocks behind
    /// was marked read with the transfers past that node's head missing, and the next round read again only the 20
    /// blocks below the newest read. Every round now reads again the 1,200 below it: a transfer such an answer left out
    /// is found by the next round, at no request more.
    func testTheNextRefreshReadsAgainWhatAClampedAnswerLeftOut() async {
        // Round 1 read every block to the head, but its newest answer was short: the transfer at 199,500 is missing.
        LogsStub.install(head: 200_000, logs: [transfer(at: 150_000)]) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let first = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertTrue(first.complete)
        XCTAssertEqual(first.logs.map(\.blockNumber), [150_000])

        LogsStub.install(head: 200_300, logs: [transfer(at: 150_000), transfer(at: 199_500), transfer(at: 200_250)]) { _ in nil }
        let entry = await HistoryStore(router: router(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertTrue(entry.complete)
        XCTAssertEqual(entry.logs.map(\.blockNumber), [150_000, 199_500, 200_250], "found 500 blocks below the newest read")
        XCTAssertEqual(LogsStub.queries(), [LogsStub.Range(from: 198_800, to: 200_300)], "one range, one request")
        XCTAssertEqual(LogsStub.requests(), 2, "the head, and that request")
    }

    /// A router over an endpoint that refuses a range past its head (rpc2) and one that answers it clamped (rpc4): both
    /// 10,000 blocks in batches of 6, so neither is waited for as the wider.
    private func clampRouter() -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://refusing.logs-stub.invalid")!, span: 10_000, clamps: false),
                                      LogsEndpoint(url: URL(string: "https://clamping.logs-stub.invalid")!, span: 10_000, clamps: true)],
                          session: URLSession(configuration: configuration), gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 4)
    }

    /// With the endpoint that refuses past its head down, a round reads every block on the clamping one but those within
    /// 600 of the head, which it leaves unread — the history not complete, never a clamped answer taken for them — and,
    /// the new blocks' read given half the round, a gap far below the head is read whole there (the round's head is the
    /// router's, not the gap's end). Once the other answers again, the next round reads them, the transfer the clamping
    /// node didn't have found.
    func testWithTheEndpointThatRefusesPastItsHeadDownTheNewestBlocksStayUnread() async {
        let logs = [transfer(at: 120_000), transfer(at: 199_000), transfer(at: 200_200)]
        let refusingHost = "refusing.logs-stub.invalid", clampingHost = "clamping.logs-stub.invalid"
        // Round 1, every endpoint up: one request, the newest 60,000 blocks.
        LogsStub.install(head: 200_000, logs: logs) { _ in nil }
        let one = await HistoryStore(router: clampRouter(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 10))
        XCTAssertEqual(one.covered, [140_001...200_000])

        // Round 2, the endpoint that refuses past its head down, the head 500 blocks on, the clamping node at the old head.
        LogsStub.install(head: 200_500, logs: logs, hostRule: { host, _ in host == refusingHost ? .noAnswer : nil }, clampedAt: [clampingHost: 200_000]) { _ in nil }
        let two = await HistoryStore(router: clampRouter(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 3))
        XCTAssertFalse(two.complete)
        XCTAssertEqual(two.covered, [100_500...200_000], "the gap below read whole; past round 1's head, nothing")
        XCTAssertEqual(two.unread, 500)
        XCTAssertEqual(two.logs.map(\.blockNumber), [120_000, 199_000])
        let clamped = zip(LogsStub.queries(), LogsStub.hosts()).filter { $0.1 == clampingHost }.map(\.0)
        XCTAssertTrue(clamped.contains { $0.to == 140_000 }, "the gap's own newest blocks, far below the head, read by the clamping endpoint")
        XCTAssertTrue(clamped.allSatisfy { $0.to <= 199_900 }, "nothing within 600 of the head: \(clamped.filter { $0.to > 199_900 })")

        // Round 3, every endpoint up again.
        LogsStub.install(head: 200_500, logs: logs) { _ in nil }
        let three = await HistoryStore(router: clampRouter(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertTrue(three.complete)
        XCTAssertEqual(three.logs.map(\.blockNumber), [120_000, 199_000, 200_200])
    }

    /// The new blocks' read has half the round's seconds: with the endpoint that refuses past its head throttled, it stops
    /// waiting for it at half the budget, and the gap far below the head is read in the half left. Given the round's whole
    /// seconds it would have waited out one more rest (2 s, then 4, then 8: asked at 0, 2 and 6 s), the third ask within a
    /// 10-second budget but not within 5 — so the endpoint is asked twice, never three times.
    func testTheNewBlocksReadHasHalfTheRoundsSeconds() async {
        let logs = [transfer(at: 120_000), transfer(at: 199_000)]
        let refusingHost = "refusing.logs-stub.invalid"
        LogsStub.install(head: 200_000, logs: logs) { _ in nil }
        let one = await HistoryStore(router: clampRouter(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 10))
        XCTAssertEqual(one.covered, [140_001...200_000])

        // The endpoint that refuses past its head throttled every time; the head 500 blocks on.
        LogsStub.install(head: 200_500, logs: logs, hostRule: { host, _ in host == refusingHost ? .status(429) : nil }) { _ in nil }
        let two = await HistoryStore(router: clampRouter(), directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertEqual(two.covered, [100_500...200_000], "the gap below read whole in the half left; past round 1's head, nothing")
        XCTAssertEqual(two.unread, 500)
        XCTAssertEqual(two.logs.map(\.blockNumber), [120_000, 199_000])
        let refused = zip(LogsStub.queries(), LogsStub.hosts()).filter { $0.1 == refusingHost }.map(\.0)
        XCTAssertEqual(refused.count, 2, "asked at 0 and 2 s: the third ask, at 6 s, past half the round's 10: \(refused)")
    }

    /// A gap within 600 of the head, read first when the new blocks' read didn't run (the entry read to the head already,
    /// a hole near it), that no endpoint could take — only one that refuses past its head may, and there is none to ask —
    /// never ends the round: the clamping endpoints still read the older gaps.
    func testANearHeadGapNoEndpointCouldTakeNeverStopsTheOlderGaps() async throws {
        // Read to the head, with a hole 300 to 550 below it and the older blocks unread.
        let folder = directory.appendingPathComponent(wallet.hex.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stored = #"{"version":2,"query":"\#(scan.query.fingerprint)","covered":[[140001,199949],[200200,200500]],"head":200500,"headTimestamp":1,"floor":100500,"logs":[]}"#
        try Data(stored.utf8).write(to: folder.appendingPathComponent("\(scan.id).json"))
        LogsStub.install(head: 200_500, logs: [transfer(at: 120_000)]) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let clampingOnly = LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://clamping.logs-stub.invalid")!, span: 10_000, clamps: true)],
                                      session: URLSession(configuration: configuration), gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 4)
        let entry = await HistoryStore(router: clampingOnly, directory: directory).refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertEqual(entry.covered, [100_500...199_949, 200_200...200_500], "the older gap read; the hole near the head left for an endpoint that refuses past it")
        XCTAssertEqual(entry.logs.map(\.blockNumber), [120_000])
        XCTAssertTrue(LogsStub.queries().allSatisfy { $0.to <= 199_900 }, "never a block within 600 of the head on the clamping endpoint")
    }

    /// A refresh asked after the wallet was forgotten never joins one from before: that one started from entries now gone
    /// — a spot check that found the server's history wrong forgets the wallet and restarts the rounds at once — and gives
    /// back what is held now, never what it started from. In the first cut a refresh asked after the erase joined it, and
    /// was handed the forgotten logs.
    func testARefreshAfterAnEraseNeverJoinsOneFromBefore() async throws {
        let scan = HistoryScan(id: "s", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .block(40_000))
        LogsStub.install(head: 50_000, logs: [transfer(at: 45_000)]) { _ in nil }
        let store = HistoryStore(router: router(), directory: directory)
        let held = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertEqual(held.logs.map(\.blockNumber), [45_000])

        // The next refresh waits on its new blocks; the wallet is forgotten meanwhile, and a refresh asked after it.
        LogsStub.install(head: 50_300, logs: [transfer(at: 45_000), transfer(at: 50_200)], holding: { $0.contains(50_200) }) { _ in nil }
        let before = Task { await store.refresh(scan, wallet: self.wallet, budget: LogsBudget(requests: 10, seconds: 10)) }
        for _ in 0..<500 where LogsStub.held() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(LogsStub.held(), 1)
        await store.forget(wallet: wallet)
        // The chain out of reach for it: what it gives back is what is held, and only that.
        let after = Task { await store.refresh(scan, wallet: self.wallet, budget: LogsBudget(requests: 10, seconds: 10), at: nil) }
        try await Task.sleep(for: .milliseconds(200))
        LogsStub.release()
        let fresh = await after.value
        XCTAssertEqual(fresh.logs, [], "not the forgotten logs")
        XCTAssertEqual(fresh.covered, [])
        XCTAssertFalse(fresh.reachedChain, "its own read, not the one from before")
        let old = await before.value
        XCTAssertEqual(old.logs, [], "what is held now, never what it started from")
        let kept = await store.cached(scan, wallet: wallet)
        XCTAssertEqual(kept.logs, [])
        XCTAssertEqual(kept.covered, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex.lowercased()).path))
    }

    /// A chain that can't be reached moves nothing and says so; what was held stays.
    func testAnUnreachableChainMovesNothing() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 199_500)]) { _ in nil }
        let store = HistoryStore(router: router(), directory: nil)
        let first = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertTrue(first.complete)
        LogsStub.install(head: 200_000, logs: []) { _ in nil }
        LogsStub.installHeadFailure()
        let entry = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertFalse(entry.reachedChain)
        XCTAssertEqual(entry.logs.map(\.blockNumber), [199_500])
        XCTAssertEqual(entry.covered, first.covered)
    }

    /// A gap the endpoint won't answer stays a gap: the coverage never claims it, and the next refresh asks again.
    func testAGapIsNeverClaimed() async {
        LogsStub.install(head: 200_000, logs: [transfer(at: 199_500), transfer(at: 150_000)],
                         hostRule: { _, range in range.contains(160_000) ? .error(code: -32603, message: "internal error") : nil }) { _ in nil }
        let store = HistoryStore(router: router(), directory: nil)
        let entry = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertFalse(entry.complete)
        XCTAssertFalse(entry.covered.contains { $0.contains(160_000) })
        XCTAssertEqual(entry.logs.map(\.blockNumber), [150_000, 199_500])
        XCTAssertTrue(entry.unread > 0 && entry.unread <= 10_000)
        LogsStub.install(head: 200_000, logs: [transfer(at: 199_500), transfer(at: 150_000), transfer(at: 160_000)]) { _ in nil }
        let filled = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 40, seconds: 10))
        XCTAssertTrue(filled.complete)
        XCTAssertEqual(filled.logs.map(\.blockNumber), [150_000, 160_000, 199_500])
    }

    /// Two refreshes of the same scan at once share one read.
    func testARefreshAlreadyRunningIsJoined() async {
        LogsStub.install(head: 100_000, logs: [transfer(at: 50_000)], latency: 0.05) { _ in nil }
        let store = HistoryStore(router: router(), directory: nil)
        async let a = store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 10, seconds: 10))
        async let b = store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 10, seconds: 10))
        let (first, second) = await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(LogsStub.requests(), 3, "the head and one read, not two reads")
    }

    /// The wallet's scans: every DyorHQ event names the wallet as an indexed topic, so each is one filter; the launchpad
    /// scan carries no address (a curve is one of hundreds) and starts at the first escrow's block; the Moments scan
    /// lists every cohort's contracts and starts at the oldest cohort.
    func testTheWalletsScans() {
        let scans = [WalletHistoryScans.transfersIn(wallet: wallet), WalletHistoryScans.transfersOut(wallet: wallet), WalletHistoryScans.launchpad(wallet: wallet),
                     WalletHistoryScans.feeSharing(wallet: wallet, stacks: [.monadMainnet] + LaunchpadAddresses.retiredStacks),
                     WalletHistoryScans.moments(wallet: wallet, cohorts: [.monadMainnet] + MomentsAddresses.retiredMainnet)]
        XCTAssertEqual(scans.map(\.id), WalletHistoryScans.ids)
        XCTAssertEqual(scans[0].query.topics, [[transferTopic], nil, [walletWord]])
        XCTAssertEqual(scans[1].query.topics, [[transferTopic], [walletWord]])
        XCTAssertEqual(scans[0].floor.block(head: 111_000_000), 111_000_000 - BlockClock.blocks(in: WalletHistoryScans.transferDays, secondsPerBlock: BlockClock.fallbackSecondsPerBlock))
        XCTAssertTrue(scans[2].query.addresses.isEmpty)
        XCTAssertEqual(scans[2].query.topics[0]?.count, 6)
        XCTAssertEqual(scans[2].query.topics[1], [walletWord])
        XCTAssertEqual(scans[2].floor, .block(LaunchpadAddresses.feeHistoryStart))
        XCTAssertEqual(scans[3].query.addresses.count, 5)
        XCTAssertEqual(scans[3].query.topics[2], [walletWord])
        XCTAssertEqual(scans[4].query.addresses.count, 16, "four contracts of each of four cohorts")
        XCTAssertEqual(scans[4].floor, .block(105_347_754))
        XCTAssertEqual(HistoryScan.Floor.blocks(10).block(head: 5), 0)
    }

    /// Rounds that stop short: the scans still behind are said not to have reached the chain, so a screen shows its
    /// error with Retry instead of "Reading your history…" for ever; a scan that read its whole window lately keeps its
    /// state, and one that read it long ago (`HistoryStatus.isCurrent`) is behind too.
    /// The stand-in published before the store's instant read lands is not a read history: Home's "Reading your
    /// history… N%" waits for one, so it never flashes "0%" at launch; any scan's state makes it one.
    func testTheStandInBeforeTheStoresReadIsNotARead() {
        XCTAssertFalse(WalletHistorySnapshot.empty.read)
        XCTAssertTrue(WalletHistorySnapshot.empty.filling, "still filling, as before: the read state is a separate question")
        var snapshot = WalletHistorySnapshot.empty
        snapshot.status = [WalletHistoryScans.transfersInId: HistoryStatus(complete: false, progress: 0, reachedChain: true, updatedAt: nil, floor: nil, head: nil)]
        XCTAssertTrue(snapshot.read)
        let home = try? DocsLinksTests.appSource("Home/HomeView.swift")
        // Beside the live figure only: a saved one says when it was read instead (`SavedLine`).
        XCTAssertEqual(home?.contains("if liveVolume, env.history.snapshot.read, env.portfolio.historyFilling(router.period, scans: WalletHistoryScans.volume) {"), true)
    }

    func testAStalledHistorySaysTheRestCouldntBeRead() {
        let read = HistoryStatus(complete: true, progress: 1, reachedChain: true, updatedAt: Date(), floor: 10, head: 20)
        let behind = HistoryStatus(complete: false, progress: 0.4, reachedChain: true, updatedAt: nil, floor: 10, head: 20)
        var snapshot = WalletHistorySnapshot.empty
        snapshot.status = [WalletHistoryScans.transfersInId: read, WalletHistoryScans.launchpadId: behind]
        XCTAssertTrue(snapshot.filling)
        XCTAssertFalse(snapshot.unreachable)
        let stalled = snapshot.stalled()
        XCTAssertFalse(stalled.filling)
        XCTAssertTrue(stalled.unreachable)
        XCTAssertEqual(stalled.status(WalletHistoryScans.transfersInId), read, "read to the head: unchanged")
        XCTAssertEqual(stalled.status(WalletHistoryScans.launchpadId).progress, 0.4, "how far it got stays")
        XCTAssertFalse(stalled.status(WalletHistoryScans.launchpadId).reachedChain)
        XCTAssertFalse(stalled.status(WalletHistoryScans.momentsId).reachedChain, "a scan never read is behind too")
        XCTAssertEqual(stalled.progress, snapshot.progress)
        var old = snapshot
        old.status[WalletHistoryScans.transfersInId] = HistoryStatus(complete: true, progress: 1, reachedChain: true, updatedAt: Date().addingTimeInterval(-3_600), floor: 10, head: 20)
        XCTAssertFalse(old.stalled().status(WalletHistoryScans.transfersInId).reachedChain, "read in full an hour ago: not up to now")
        XCTAssertFalse(old.stalled().swapFactsStalled, "no transaction left out")
    }

    /// The transfer scans read back to the wallet's first transaction when that is older than their window, and to the
    /// window alone when it is nearer, or the wallet never sent one, or it couldn't be read. The first transaction's
    /// block is found by bisection over the nonce at past blocks, asked once, and never waited for: the first round reads
    /// with the window's floor while the lookup runs beside it, and the next round reads back to the block it found — or
    /// at once to a block found before (`knownFirstActivity`).
    func testTheTransferScansReadBackToTheWalletsFirstTransaction() async throws {
        XCTAssertEqual(HistoryScan.Floor.earliest(block: 5_000, blocks: 1_000).block(head: 10_000), 5_000, "the first transaction, older than the window")
        XCTAssertEqual(HistoryScan.Floor.earliest(block: 9_500, blocks: 1_000).block(head: 10_000), 9_000, "the window, when the first transaction is nearer")
        XCTAssertEqual(HistoryScan.Floor.earliest(block: 5_000, blocks: 20_000).block(head: 10_000), 0)

        LogsStub.install(head: 100_000, firstTransaction: 61_337) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let client = RPCClient(url: URL(string: "https://wide.logs-stub.invalid")!, session: URLSession(configuration: configuration))
        let first = try await client.firstTransactionBlock(of: wallet, head: 100_000)
        XCTAssertEqual(first, 61_337)
        LogsStub.install(head: 100_000) { _ in nil }
        let none = try await client.firstTransactionBlock(of: wallet, head: 100_000)
        XCTAssertNil(none)

        XCTAssertEqual(LogsEndpoints.archive.map(\.host), ["rpc2.monad.xyz", "rpc4.monad.xyz", "rpc1.monad.xyz"], "the endpoints that answer a nonce at any block")

        let asked = Counter()
        let service = WalletHistoryService(store: HistoryStore(router: router(), directory: nil), swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client),
                                           stacks: { [] }, cohorts: [], firstActivity: { _ in await asked.bump(); return 61_337 })
        // The instant read of the store never waits for the lookup: the window's floor until a refresh has looked.
        let instant = await service.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(instant[0].floor, WalletHistoryScans.transferFloor)
        let unasked = await asked.count
        XCTAssertEqual(unasked, 0)
        // The first round: the window's floor, the lookup started beside it rather than waited for.
        let roundOne = await service.scans(wallet: wallet)
        XCTAssertEqual(roundOne[0].floor, WalletHistoryScans.transferFloor, "round 1 never waits for the lookup")
        XCTAssertEqual(roundOne[2].floor, .block(LaunchpadAddresses.feeHistoryStart))
        await service.firstTransactionLookup(wallet)
        // The next round reads back to it.
        let scans = await service.scans(wallet: wallet)
        XCTAssertEqual(scans[0].floor, .earliest(block: 61_337, blocks: WalletHistoryScans.transferBlocks))
        XCTAssertEqual(scans[1].floor, scans[0].floor)
        XCTAssertEqual(scans[2].floor, .block(LaunchpadAddresses.feeHistoryStart), "the other scans keep their floors")
        _ = await service.scans(wallet: wallet)
        let count = await asked.count
        XCTAssertEqual(count, 1, "asked once per wallet")

        let failing = WalletHistoryService(store: HistoryStore(router: router(), directory: nil), swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client),
                                           stacks: { [] }, cohorts: [], firstActivity: { _ in throw URLError(.notConnectedToInternet) })
        _ = await failing.scans(wallet: wallet)
        await failing.firstTransactionLookup(wallet)
        let fallback = await failing.scans(wallet: wallet)
        XCTAssertEqual(fallback[0].floor, WalletHistoryScans.transferFloor, "the window alone until it can be read")

        // Found before (kept on the device): the first round reads back to it at once, the instant read too, with no lookup.
        let lookups = Counter()
        let known = WalletHistoryService(store: HistoryStore(router: router(), directory: nil), swapHistory: SwapHistoryService(rpc: client), clock: BlockClock(rpc: client),
                                         stacks: { [] }, cohorts: [], firstActivity: { _ in await lookups.bump(); return nil }, knownFirstActivity: { _ in 61_337 })
        let instantKnown = await known.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(instantKnown[0].floor, .earliest(block: 61_337, blocks: WalletHistoryScans.transferBlocks))
        let roundKnown = await known.scans(wallet: wallet)
        XCTAssertEqual(roundKnown[0].floor, .earliest(block: 61_337, blocks: WalletHistoryScans.transferBlocks), "a round never starts above a floor already known")
        await known.firstTransactionLookup(wallet)
        let looked = await lookups.count
        XCTAssertEqual(looked, 0)
    }

    private actor Counter {
        var count = 0
        func bump() { count += 1 }
    }

    /// Past the cap, the oldest logs are dropped and the floor moves up to the kept ones: the entry is complete without
    /// them, and no refresh reads them again.
    func testTheCapMovesTheFloorUpToTheKeptLogs() {
        var entry = HistoryEntry(logs: (1...(HistoryStore.logCap + 5)).map { transfer(at: UInt64($0)) }, covered: [1...30_000], head: 30_000, headTimestamp: 1, floor: 1)
        XCTAssertTrue(entry.complete)
        entry.trim(floor: 1)
        XCTAssertEqual(entry.logs.count, HistoryStore.logCap)
        XCTAssertEqual(entry.capFloor, 6)
        XCTAssertEqual(entry.floor, 6)
        XCTAssertEqual(entry.covered, [6...30_000])
        XCTAssertTrue(entry.complete, "complete without what was dropped")
        XCTAssertEqual(entry.gaps(head: 30_000, floor: 6), [])
        XCTAssertEqual(entry.progress, 1)
    }

    /// A stored scan read with another filter (a contract added to the scan under the same id) is started over, never
    /// trusted for blocks it never asked about.
    func testAStoredScanReadWithAnotherFilterIsStartedOver() async {
        LogsStub.install(head: 50_000, logs: [transfer(at: 45_000)]) { _ in nil }
        let scan = HistoryScan(id: "s", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .block(40_000))
        let store = HistoryStore(router: router(), directory: directory)
        let read = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 10, seconds: 10))
        XCTAssertTrue(read.complete)
        let same = HistoryStore(router: router(), directory: directory)
        let kept = await same.cached(scan, wallet: wallet)
        XCTAssertEqual(kept.logs.map(\.blockNumber), [45_000], "the same filter: read from disk")
        XCTAssertTrue(kept.complete)
        let other = HistoryScan(id: "s", query: LogsQuery(addresses: [token], topics: scan.query.topics), floor: .block(40_000))
        let fresh = HistoryStore(router: router(), directory: directory)
        let started = await fresh.cached(other, wallet: wallet)
        XCTAssertEqual(started, .empty)
    }

    /// Forgetting a wallet drops its entries from memory and disk, and a refresh under way keeps nothing after it.
    func testAForgottenWalletKeepsNothing() async {
        // The head answers after a second: the erase lands while the refresh waits for it.
        LogsStub.install(head: 50_000, logs: [transfer(at: 45_000)], latency: 1) { _ in nil }
        let scan = HistoryScan(id: "s", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .block(40_000))
        let store = HistoryStore(router: router(), directory: directory)
        let refresh = Task { await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 10, seconds: 10)) }
        try? await Task.sleep(for: .milliseconds(300))
        await store.forget(wallet: wallet)
        _ = await refresh.value
        let after = await store.cached(scan, wallet: wallet)
        XCTAssertEqual(after, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex.lowercased()).path))
    }

    /// The records built from the store: a swap from a spent and a received transfer in one transaction, an escrow
    /// payment from the launchpad scan (an unrelated contract's event of the same shape left out), each timed from the
    /// head the entries read; and every scan's status.
    func testTheHistoryIsBuiltFromTheStore() async {
        let usdc = Monad.usdc
        let escrow = LaunchpadAddresses.monadMainnet.escrow
        let stranger = Address(literal: "0x4444444444444444444444444444444444444444")
        let tx = Data(repeating: 0xAB, count: 32)
        // A head just past the first escrow's block: the launchpad scans read back to it in one request each; the transfer
        // scans read their 30 days.
        let head: UInt64 = LaunchpadAddresses.feeHistoryStart + 50_000
        let spent = Log(address: usdc, topics: [transferTopic, walletWord, Data(repeating: 1, count: 32)], data: BigUInt(2_000_000).word, blockNumber: head - 1_000, transactionHash: tx, logIndex: 0)
        let received = Log(address: token, topics: [transferTopic, Data(repeating: 1, count: 32), walletWord], data: BigUInt(10).power(18).word, blockNumber: head - 1_000, transactionHash: tx, logIndex: 1)
        let paid = Log(address: escrow, topics: [LaunchpadABI.Events.escrowPaidTopic, walletWord], data: BigUInt(7).power(18).word, blockNumber: head - 900, transactionHash: Data(repeating: 0xCD, count: 32), logIndex: 0)
        let lookalike = Log(address: stranger, topics: [LaunchpadABI.Events.escrowPaidTopic, walletWord], data: BigUInt(99).power(18).word, blockNumber: head - 800, transactionHash: Data(repeating: 0xEF, count: 32), logIndex: 0)
        LogsStub.install(head: head, logs: [spent, received, paid, lookalike]) { _ in nil }
        let store = HistoryStore(router: router(concurrency: 4), directory: nil)
        let logsClient = LogsStub.rpc()
        let clock = BlockClock(rpc: logsClient, measured: BlockClock.fallbackSecondsPerBlock)
        let service = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: logsClient, clock: clock), clock: clock,
                                           stacks: { [LaunchpadAddresses.monadMainnet] }, cohorts: [MomentsAddresses.monadMainnet])
        let before = await service.cached(wallet: wallet, curves: [], decimals: [usdc: 6])
        XCTAssertNil(before.anchor)
        XCTAssertTrue(before.swaps.isEmpty)
        XCTAssertFalse(before.complete)

        let snapshot = await service.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [usdc: 6])
        XCTAssertEqual(snapshot.anchor?.number, head)
        XCTAssertEqual(snapshot.swaps.count, 1)
        XCTAssertEqual(snapshot.swaps.first?.soldToken, usdc)
        XCTAssertEqual(snapshot.swaps.first?.boughtToken, token)
        XCTAssertEqual(snapshot.swaps.first?.time, BlockClock.time(of: head - 1_000, anchor: snapshot.anchor!, secondsPerBlock: BlockClock.fallbackSecondsPerBlock))
        XCTAssertEqual(snapshot.launch.payments.map(\.amount), [BigUInt(7).power(18)], "the escrow's payment, not the look-alike's")
        XCTAssertEqual(snapshot.feeIncome.paid[.zero], BigUInt(7).power(18))
        XCTAssertTrue(snapshot.feeIncome.complete)
        XCTAssertEqual(snapshot.transfersIn.map(\.blockNumber), [head - 1_000])
        XCTAssertEqual(Set(snapshot.status.keys), Set(WalletHistoryScans.ids))
        XCTAssertTrue(snapshot.complete, "every scan read its window: \(snapshot.status)")
        XCTAssertFalse(snapshot.filling)
        XCTAssertEqual(snapshot.progress, 1)

        let cached = await service.cached(wallet: wallet, curves: [], decimals: [usdc: 6])
        XCTAssertEqual(cached.swaps, snapshot.swaps, "built from what is held, no scan")
        XCTAssertEqual(cached.anchor, snapshot.anchor)
    }
}

extension LogsStub {
    /// Fails every head read, so a refresh can't reach the chain.
    static func installHeadFailure() {
        install(head: 0, logs: [], hostRule: { _, _ in .noAnswer }) { _ in nil }
        failHead = true
    }
}
