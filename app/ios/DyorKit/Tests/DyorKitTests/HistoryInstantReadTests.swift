import BigInt
import XCTest
@testable import DyorKit

/// The wallet's history read from the device at launch needs no network (`WalletHistoryService.cached`): the scans, each
/// transaction's facts (`SwapHistoryService.TransactionFacts`, kept beside the scans) and the pace as known; what it lacks
/// is read right after (`completed`), on the archive endpoints only. Every record's time is its block's own when the log
/// carries it (`Log.blockTimestamp`), kept with the logs, and the files kept before it still load.
final class HistoryInstantReadTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private let other = Address(literal: "0x5555555555555555555555555555555555555555")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-instant-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: Facts

    /// A transaction's facts are kept as hex text, with what a sale into MON paid in one of three states — not read yet,
    /// read, or unknowable (kept so, never read again) — and come back as they were.
    func testTheFactsRoundTripWithTheirThreeStates() throws {
        typealias Facts = SwapHistoryService.TransactionFacts
        let facts: [String: Facts] = [
            "a": Facts(from: wallet, to: Uniswap.universalRouter, value: BigUInt(10).power(18)),
            "b": Facts(from: wallet, to: Kuru.entrypoint, value: 0, nativeReceived: .read(BigUInt(2_000_021) * BigUInt(10).power(12))),
            "c": Facts(from: wallet, to: MondayTrade.swapRouter, value: 0, nativeReceived: .unknowable),
            "d": Facts(from: nil, to: nil, value: 0, nativeReceived: .unknowable),
        ]
        let data = try JSONEncoder().encode(facts)
        XCTAssertEqual(try JSONDecoder().decode([String: Facts].self, from: data), facts)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""native":"unknowable""#))
        XCTAssertTrue(text.contains(#""native":"unread""#))
        XCTAssertTrue(text.contains(#""native":"0x1bc18080c0525000""#), "a read amount, as a quantity")
        XCTAssertTrue(text.contains(#""value":"0xde0b6b3a7640000""#))
        XCTAssertFalse(text.contains("\"from\":null"), "an unknown sender is left out")

        // The format as kept: a fact with no state reads as not read yet; an amount that isn't one is refused.
        let plain = try JSONDecoder().decode(Facts.self, from: Data(#"{"value":"0x5"}"#.utf8))
        XCTAssertEqual(plain, Facts(from: nil, to: nil, value: 5, nativeReceived: .unread))
        XCTAssertThrowsError(try JSONDecoder().decode(Facts.self, from: Data(#"{"value":"0x5","native":"0xzz"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Facts.self, from: Data(#"{"value":"0x5","native":"lots"}"#.utf8)))

        // Two builds' facts of one transaction: the more known kept.
        let record = Facts(from: wallet, to: Kuru.entrypoint, value: 0)
        let settled = Facts(from: nil, to: nil, value: 0, nativeReceived: .unknowable)
        XCTAssertEqual(record.merged(with: settled), Facts(from: wallet, to: Kuru.entrypoint, value: 0, nativeReceived: .unknowable))
        XCTAssertEqual(settled.merged(with: record), Facts(from: wallet, to: Kuru.entrypoint, value: 0, nativeReceived: .unknowable))
        XCTAssertEqual(record.merged(with: record), record)
    }

    /// What is kept beside a wallet's scans loads from the device, and an erase of this device's data keeps nothing read
    /// before it.
    func testWhatIsKeptBesideTheScansFollowsAnErase() async {
        let store = HistoryStore(router: router(), directory: directory)
        let reference = WalletHistoryReference(curves: [token, other], decimals: [Monad.usdc: 6, token: 18])
        let mark = await store.erasureMark
        await store.keep(reference, named: "reference", wallet: wallet, since: mark)
        let kept = await store.kept(WalletHistoryReference.self, named: "reference", wallet: wallet)
        XCTAssertEqual(kept, reference)
        await store.forget(wallet: wallet)
        let erased = await store.kept(WalletHistoryReference.self, named: "reference", wallet: wallet)
        XCTAssertNil(erased)
        await store.keep(reference, named: "reference", wallet: wallet, since: mark)
        let late = await store.kept(WalletHistoryReference.self, named: "reference", wallet: wallet)
        XCTAssertNil(late, "read before the erase: not kept after it")
        let memoryOnly = HistoryStore(router: router(), directory: nil)
        let none = await memoryOnly.kept(WalletHistoryReference.self, named: "reference", wallet: wallet)
        XCTAssertNil(none)
    }

    /// The reference the records were last matched with (the launches' curves, the tokens' decimals) is kept per wallet,
    /// so the first snapshot after launch counts launch fills and weighs swap legs before the Portfolio has read them.
    func testTheReferenceIsKeptPerWallet() async throws {
        let service = WalletHistoryService(store: HistoryStore(router: router(), directory: directory), swapHistory: SwapHistoryService(rpc: LogsStub.rpc()),
                                           clock: BlockClock(rpc: LogsStub.rpc()), stacks: { [] }, cohorts: [])
        let reference = WalletHistoryReference(curves: [token], decimals: [Monad.usdc: 6])
        let mark = await service.erasureMark
        await service.keep(reference: reference, wallet: wallet, since: mark)
        let kept = await service.reference(wallet: wallet)
        XCTAssertEqual(kept, reference)
        let elsewhere = await service.reference(wallet: other)
        XCTAssertNil(elsewhere, "another wallet's is its own")
        let file = try String(contentsOf: directory.appendingPathComponent(wallet.hex).appendingPathComponent("reference.json"), encoding: .utf8)
        XCTAssertTrue(file.contains(#""version":1"#))
        XCTAssertTrue(file.contains(token.hex))
        await service.forget(wallet: wallet)
        let forgotten = await service.reference(wallet: wallet)
        XCTAssertNil(forgotten)
        // A write after the erase with the mark read before it (a Portfolio load in flight) leaves nothing behind.
        await service.keep(reference: reference, wallet: wallet, since: mark)
        let late = await service.reference(wallet: wallet)
        XCTAssertNil(late, "never kept after an erase")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(wallet.hex).path), "no folder named for the wallet")

        let source = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(source.contains("Task { await env.walletHistory.keep(reference: reference, wallet: wallet, since: erasureMark) }"), "setReference keeps it")
        XCTAssertTrue(source.contains("""
                        let mark = await env.walletHistory.erasureMark
                        guard !Task.isCancelled, self.wallet == wallet else { return }
                        erasureMark = mark
                        await restoreReference(env: env, wallet: wallet)
        """), "the mark is read when the rounds start on the wallet, before the first snapshot is matched with the reference")
        XCTAssertFalse(source.contains("since: await"), "never a mark read when it writes")
        // A curve is a launch's for good: the reference only grows, on the device too.
        XCTAssertTrue(source.contains("let changed = !curves.isSubset(of: self.curves) || decimals != self.decimals\n        self.curves.formUnion(curves)"))
        XCTAssertTrue(source.contains("let reference = WalletHistoryReference(curves: self.curves, decimals: decimals)"))
        XCTAssertFalse(source.contains("self.curves = curves"), "never replaced")
        // An erase stops the rounds first, in both of its paths.
        let deletion = try DocsLinksTests.appSource("Profile/AccountDeletion.swift")
        XCTAssertEqual(deletion.components(separatedBy: "env.history.start(env: env, wallet: nil)\n        await env.walletHistory.forget(wallet: ").count - 1, 2)
        XCTAssertTrue(source.contains("curves.formUnion(kept.curves)"))
        XCTAssertTrue(source.contains("decimals.merge(kept.decimals) { now, _ in now }"), "what this launch read wins")
    }

    // MARK: Block timestamps

    /// Monad's `eth_getLogs` answers carry the block's timestamp: parsed when it is there, left out (never the log) when it
    /// isn't or can't be read.
    func testTheBlockTimestampIsParsedWhenGiven() throws {
        func log(_ extra: [String: JSON]) -> Log? {
            var object: [String: JSON] = ["address": .string(token.hex), "topics": .array([.string(transferTopic.hexString)]), "data": .string("0x"),
                                          "blockNumber": .string("0x6a913cc"), "transactionHash": .string(Data(repeating: 1, count: 32).hexString), "logIndex": .string("0x11")]
            object.merge(extra) { _, new in new }
            return Log(json: .object(object))
        }
        // As rpc2 answered on 2026-10-08.
        XCTAssertEqual(try XCTUnwrap(log(["blockTimestamp": .string("0x6ac82a5a")])).blockTimestamp, 1_791_502_938)
        XCTAssertNil(try XCTUnwrap(log([:])).blockTimestamp)
        XCTAssertNil(try XCTUnwrap(log(["blockTimestamp": .string("soon")])).blockTimestamp, "unreadable: left out, the log kept")
        XCTAssertNil(try XCTUnwrap(log(["blockTimestamp": .number(1)])).blockTimestamp)

        let anchor = BlockHeader(number: 1_000, timestamp: 1_800_000_000)
        let timed = Log(address: token, topics: [], data: Data(), blockNumber: 900, transactionHash: Data(), logIndex: 0, blockTimestamp: 1_799_999_000)
        XCTAssertEqual(BlockClock.time(of: timed, anchor: anchor, secondsPerBlock: 0.3).timeIntervalSince1970, 1_799_999_000, "its own")
        let untimed = Log(address: token, topics: [], data: Data(), blockNumber: 900, transactionHash: Data(), logIndex: 0)
        XCTAssertEqual(BlockClock.time(of: untimed, anchor: anchor, secondsPerBlock: 0.3), BlockClock.time(of: 900, anchor: anchor, secondsPerBlock: 0.3), "estimated")
    }

    /// A log kept without its block's timestamp takes the one a new read of it carries.
    func testALogKeptWithoutItsTimestampTakesTheOneReadAgain() {
        let untimed = transfer(at: 150, hash: 1, from: other, to: wallet)
        let timed = transfer(at: 150, hash: 1, from: other, to: wallet, timestamp: 1_790_000_000)
        var entry = HistoryEntry(logs: [untimed], covered: [100...200], head: 200, headTimestamp: 1, floor: 100)
        entry.merge(LogsRead(logs: [timed], covered: [140...200], requests: 1))
        XCTAssertEqual(entry.logs.count, 1)
        XCTAssertEqual(entry.logs.first?.blockTimestamp, 1_790_000_000)
        entry.merge(LogsRead(logs: [untimed], covered: [140...200], requests: 1))
        XCTAssertEqual(entry.logs.first?.blockTimestamp, 1_790_000_000, "never loses it")
    }

    /// A scan file kept before the app read block timestamps (version 2, no `s` per log) loads as it is; a refresh keeps
    /// the timestamps it reads, and the file it writes loads with them.
    func testTheFilesKeptBeforeStillLoad() async throws {
        let scan = HistoryScan(id: "transfers-in", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .blocks(100_000))
        let folder = directory.appendingPathComponent(wallet.hex.lowercased())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hash = Data(repeating: 0x42, count: 32).hexString
        let old = """
        {"version":2,"query":"\(scan.query.fingerprint)","covered":[[100000,200000]],"head":200000,"headTimestamp":1790000000,"floor":100000,\
        "logs":[{"a":"\(token.hex)","t":["\(transferTopic.hexString)","\(other.data.leftPadded(to: 32).hexString)","\(walletWord.hexString)"],\
        "d":"\(BigUInt(5).word.hexString)","b":150000,"h":"\(hash)","i":3}]}
        """
        try Data(old.utf8).write(to: folder.appendingPathComponent("transfers-in.json"))

        let store = HistoryStore(router: router(), directory: directory)
        let entry = await store.cached(scan, wallet: wallet)
        XCTAssertEqual(entry.logs.count, 1, "the old file loads")
        XCTAssertEqual(entry.logs.first?.blockNumber, 150_000)
        XCTAssertEqual(entry.logs.first?.logIndex, 3)
        XCTAssertNil(entry.logs.first?.blockTimestamp)
        XCTAssertEqual(entry.covered, [100_000...200_000])
        XCTAssertEqual(entry.anchor, BlockHeader(number: 200_000, timestamp: 1_790_000_000))

        // The chain moves on: the new blocks are read with their timestamps, and kept with them.
        LogsStub.install(head: 203_000, logs: [transfer(at: 202_000, hash: 9, from: other, to: wallet, timestamp: 1_790_000_900)]) { _ in nil }
        let refreshed = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 5, seconds: 10))
        XCTAssertEqual(refreshed.logs.map(\.blockNumber), [150_000, 202_000])
        let reloaded = await HistoryStore(router: router(), directory: directory).cached(scan, wallet: wallet)
        XCTAssertEqual(reloaded.logs.map(\.blockTimestamp), [nil, 1_790_000_900], "the old log as it was, the new with its time")
        let written = try String(contentsOf: folder.appendingPathComponent("transfers-in.json"), encoding: .utf8)
        XCTAssertTrue(written.contains(#""version":2"#), "the same format, one optional field more")
    }

    // MARK: The instant read

    /// The swaps' facts are read on the archive endpoints only, kept beside the scans, and the instant read of the device
    /// makes no request at all: the scans, the facts and the pace as known. A sale into MON whose MON the balance change
    /// can't say is kept as unknowable — never read again, and the swaps built with it are kept as they are. Records take
    /// their blocks' own times.
    func testTheInstantReadMakesNoRequest() async throws {
        let chain = Chain(wallet: wallet, token: token, other: other)
        let calls = Calls()
        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        let first = service(clock: BlockClock(rpc: LogsStub.rpc(), measured: BlockClock.fallbackSecondsPerBlock))
        let read = await first.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        XCTAssertTrue(read.complete, "\(read.status)")
        chain.check(read)
        XCTAssertEqual(read.unreadTransactionBlocks, [])
        XCTAssertFalse(read.swapFactsUnread)
        XCTAssertEqual(Set(calls.hosts()), [Chain.archiveHost], "every fact read on the archive endpoints")
        XCTAssertEqual(calls.count("eth_getTransactionReceipt"), 2, "the two sales into MON")
        let kept = directory.appendingPathComponent(wallet.hex).appendingPathComponent("swap-facts.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "kept beside the scans")
        XCTAssertTrue(try String(contentsOf: kept, encoding: .utf8).contains(#""native":"unknowable""#))

        // Only an unknowable sale left: the swaps are kept, and the next build reads nothing.
        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        calls.reset()
        let again = await first.completed(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        XCTAssertEqual(LogsStub.requests(), 0)
        XCTAssertEqual(again.swaps, read.swaps)

        // A new launch: the instant read makes no request — the pace isn't measured, the facts come from the device.
        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        let clock = BlockClock(rpc: LogsStub.rpc())
        let instant = await service(clock: clock).cached(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        XCTAssertEqual(LogsStub.requests(), 0, "no request at all")
        let measured = await clock.isMeasured
        XCTAssertFalse(measured, "the pace isn't measured")
        XCTAssertEqual(instant.secondsPerBlock, BlockClock.fallbackSecondsPerBlock)
        XCTAssertEqual(instant.anchor, read.anchor, "timed from the head the scans last read")
        chain.check(instant)
        XCTAssertFalse(instant.swapFactsUnread)
        XCTAssertTrue(instant.covers(since: nil, scans: WalletHistoryScans.volume))

        // The unknowable sale is never read again, even by a build that reads.
        let fresh = service(clock: BlockClock(rpc: LogsStub.rpc(), measured: BlockClock.fallbackSecondsPerBlock))
        _ = await fresh.completed(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        XCTAssertEqual(calls.count("eth_getTransactionReceipt"), 0, "unknowable: kept so")
        XCTAssertEqual(calls.count("eth_getTransactionByHash"), 0)
    }

    /// With no facts kept (the first launch with this build), the instant read still makes no request: the one-sided
    /// transactions are left out and said to be, so a screen built from the swaps says it is still reading rather than
    /// show a part as the whole; the build right after reads them, on the archive endpoints.
    func testTheInstantReadLeavesOutWhatItHasNoFactsFor() async throws {
        let chain = Chain(wallet: wallet, token: token, other: other)
        let calls = Calls()
        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        _ = await service(clock: BlockClock(rpc: LogsStub.rpc(), measured: BlockClock.fallbackSecondsPerBlock))
            .refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        try FileManager.default.removeItem(at: directory.appendingPathComponent(wallet.hex).appendingPathComponent("swap-facts.json"))

        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        calls.reset()
        let later = service(clock: BlockClock(rpc: LogsStub.rpc()))
        let instant = await later.cached(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        XCTAssertEqual(LogsStub.requests(), 0)
        XCTAssertEqual(instant.swaps.map(\.hash), [chain.swap], "the two-sided swap alone")
        XCTAssertEqual(instant.unreadTransactionBlocks.sorted(), chain.oneSidedBlocks)
        XCTAssertTrue(instant.swapFactsUnread)
        XCTAssertFalse(instant.covers(since: nil, scans: WalletHistoryScans.volume), "never a part passed off as the whole")
        XCTAssertTrue(instant.filling(since: nil, scans: WalletHistoryScans.volume))
        XCTAssertLessThan(instant.progress(since: nil, scans: WalletHistoryScans.volume), 1)
        XCTAssertTrue(instant.covers(since: nil, scans: WalletHistoryScans.holdings), "the holdings need no facts")
        XCTAssertTrue(instant.covers(since: nil, scans: WalletHistoryScans.feeIncome))

        let completed = await later.completed(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        chain.check(completed)
        XCTAssertEqual(completed.unreadTransactionBlocks, [])
        XCTAssertFalse(completed.swapFactsUnread)
        XCTAssertTrue(completed.covers(since: nil, scans: WalletHistoryScans.volume))
        XCTAssertEqual(Set(calls.hosts()), [Chain.archiveHost])
        XCTAssertGreaterThan(calls.count("eth_getTransactionByHash"), 0)
    }

    /// A screen waits only for the unread transactions in its own window.
    func testAScreenWaitsForTheUnreadTransactionsInItsWindow() {
        var snapshot = WalletHistorySnapshot.empty
        snapshot.anchor = BlockHeader(number: 1_000, timestamp: 1_800_000_000)
        let read = HistoryStatus(complete: true, progress: 1, reachedChain: true, updatedAt: Date(), floor: 0, head: 1_000, coveredFrom: 0)
        for id in WalletHistoryScans.ids { snapshot.status[id] = read }
        snapshot.unreadTransactionBlocks = [400]
        XCTAssertTrue(snapshot.covers(from: 500, scans: WalletHistoryScans.volume), "after it: final")
        XCTAssertFalse(snapshot.filling(from: 500, scans: WalletHistoryScans.volume))
        XCTAssertEqual(snapshot.progress(from: 500, scans: WalletHistoryScans.volume), 1)
        XCTAssertFalse(snapshot.covers(from: 300, scans: WalletHistoryScans.volume))
        XCTAssertTrue(snapshot.filling(from: 300, scans: WalletHistoryScans.volume))
        XCTAssertEqual(snapshot.progress(from: 300, scans: WalletHistoryScans.volume), 0.99)
        XCTAssertFalse(snapshot.covers(from: nil, scans: WalletHistoryScans.activity))
        XCTAssertTrue(snapshot.covers(from: nil, scans: WalletHistoryScans.holdings))
        XCTAssertTrue(snapshot.covers(from: nil, scans: WalletHistoryScans.proceeds))
        // Couldn't reach the chain: not "reading" any more, and still never final.
        var unreached = snapshot
        for id in WalletHistoryScans.ids { unreached.status[id] = read.unreached() }
        XCTAssertFalse(unreached.filling(from: nil, scans: WalletHistoryScans.volume))
        XCTAssertFalse(unreached.covers(from: nil, scans: WalletHistoryScans.volume))
    }

    /// The archive endpoints refuse every transaction's record while the log endpoints answer the scans: a build that asks
    /// and reads none says so (`swapFactsFailed`), the windows that need those transactions wait ("Reading your history",
    /// never final), and once the rounds stop short over it (`stalled`) the screens stop saying "reading" and say part of
    /// the history couldn't be read, with Retry, never final either. The app counts it as a round that read nothing.
    func testTransactionFactsThatKeepFailingSayTheyCouldntBeRead() async throws {
        let chain = Chain(wallet: wallet, token: token, other: other)
        let calls = Calls()
        let answer = chain.answer(recording: calls)
        let refusing: LogsStub.Answer = { host, method, params in
            guard method == "eth_getTransactionByHash" else { return answer(host, method, params) }
            calls.add(host, method)
            return .null
        }
        LogsStub.install(head: chain.head, logs: chain.logs, answer: refusing) { _ in nil }
        let history = service(clock: BlockClock(rpc: LogsStub.rpc(), measured: BlockClock.fallbackSecondsPerBlock))
        let round = await history.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        XCTAssertTrue(round.complete, "every scan read its window: \(round.status)")
        XCTAssertFalse(round.unreachable)
        XCTAssertEqual(round.unreadTransactionBlocks.sorted(), chain.oneSidedBlocks)
        XCTAssertEqual(round.swapFactsRead, 0, "asked, and none read")
        XCTAssertTrue(round.swapFactsFailed)
        XCTAssertGreaterThan(calls.count("eth_getTransactionByHash"), 0)
        XCTAssertFalse(round.covers(since: nil, scans: WalletHistoryScans.volume))
        XCTAssertTrue(round.filling(since: nil, scans: WalletHistoryScans.volume))
        XCTAssertEqual(round.progress(since: nil, scans: WalletHistoryScans.volume), WalletHistorySnapshot.readingCap)
        XCTAssertTrue(round.covers(since: nil, scans: WalletHistoryScans.holdings), "the holdings need no facts")

        let stalled = round.stalled()
        XCTAssertTrue(stalled.swapFactsStalled)
        XCTAssertTrue(stalled.unreachable, "the screens' notice, with Retry")
        XCTAssertFalse(stalled.filling(since: nil, scans: WalletHistoryScans.volume), "no longer said to be reading")
        XCTAssertFalse(stalled.covers(since: nil, scans: WalletHistoryScans.volume), "never final")
        XCTAssertTrue(stalled.covers(since: nil, scans: WalletHistoryScans.holdings))
        XCTAssertFalse(stalled.filling(since: nil, scans: WalletHistoryScans.holdings))

        // The archive answers again: the next build reads them, and says it read some.
        LogsStub.install(head: chain.head, logs: chain.logs, answer: answer) { _ in nil }
        let next = await history.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        XCTAssertEqual(next.unreadTransactionBlocks, [])
        XCTAssertEqual(next.swapFactsRead, chain.oneSidedBlocks.count)
        XCTAssertFalse(next.swapFactsFailed)
        XCTAssertTrue(next.covers(since: nil, scans: WalletHistoryScans.volume))
        // Nothing left out: the build after asks for nothing.
        let settled = await history.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        XCTAssertNil(settled.swapFactsRead)
        XCTAssertFalse(settled.unreachable)

        // The app's rounds: a complete round whose facts failed is a round that read nothing (a stall, and the backoff, and
        // after `HistoryModel.stalls` of them the stalled snapshot); one that read some goes on at once, not after a top-up.
        let model = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(model.contains("""
                if round.complete, !round.swapFactsFailed {
                    stalls = 0
                    lastProgress = 1
                } else if round.complete || round.unreachable || (!widened && round.progress <= lastProgress) {
        """))
        XCTAssertTrue(model.contains("if round.complete, !round.unreadTransactionBlocks.isEmpty, (round.swapFactsRead ?? 0) > 0 { return .seconds(1) }"))
        XCTAssertTrue(model.contains("self.snapshot = stalls >= Self.stalls ? snapshot.stalled() : snapshot"))
    }

    /// A build that started from older logs never drops the facts a newer build added, nor replaces its swaps: what it
    /// read is added to what is kept, pruned to the transactions the store holds now, and its swaps are kept only when
    /// built from those same logs.
    func testAnOlderBuildNeverDropsANewerBuildsFacts() async throws {
        let chain = Chain(wallet: wallet, token: token, other: other)
        let calls = Calls()
        LogsStub.install(head: chain.head, logs: chain.logs, answer: chain.answer(recording: calls)) { _ in nil }
        let history = service(clock: BlockClock(rpc: LogsStub.rpc(), measured: BlockClock.fallbackSecondsPerBlock))
        _ = await history.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [Monad.usdc: 6])
        let kept = directory.appendingPathComponent(wallet.hex).appendingPathComponent("swap-facts.json")
        let before = try String(contentsOf: kept, encoding: .utf8)
        for hash in [chain.buy, chain.sale, chain.gift] { XCTAssertTrue(before.contains(hash.hexString), "kept: \(hash.hexString)") }
        // Another build of the store as it is keeps them all.
        _ = await history.completed(wallet: wallet, curves: [], decimals: [Monad.usdc: 6])
        let after = try String(contentsOf: kept, encoding: .utf8)
        for hash in [chain.buy, chain.sale, chain.gift] { XCTAssertTrue(after.contains(hash.hexString), "still kept: \(hash.hexString)") }

        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit
        let source = try String(contentsOf: root.appendingPathComponent("Sources/DyorKit/Services/WalletHistory.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("let current = await transfers(wallet)"))
        XCTAssertTrue(source.contains("let held = Set(current.outgoing.map(\\.transactionHash)).union(current.incoming.map(\\.transactionHash))"))
        XCTAssertTrue(source.contains("var facts = before\n        for (hash, fact) in built.facts { facts[hash] = facts[hash].map { $0.merged(with: fact) } ?? fact }\n        facts = facts.filter { held.contains($0.key) }"))
        XCTAssertFalse(source.contains("Set(outgoing.map(\\.transactionHash))"), "never pruned to the build's own logs")
        XCTAssertTrue(source.contains("if !unsettled, Self.fingerprint(outgoing: current.outgoing, incoming: current.incoming, decimals: decimals) == fingerprint {"))
    }

    /// The app reads the facts on the archive client, knows a first transaction found before at once, and publishes the
    /// instant read before reading what it left out.
    func testTheAppWiresTheInstantRead() throws {
        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertTrue(environment.contains("swapHistory = SwapHistoryService(rpc: logsClient, clock: clock, archive: archiveClient)"))
        XCTAssertTrue(environment.contains("let archiveClient = isFork ? RPCClient(url: config.rpcURL) : RPCClient(urls: LogsEndpoints.archive)"))
        XCTAssertTrue(environment.contains("knownFirstActivity: keptFirstBlock)"))
        // The device's own first transaction alone is kept in UserDefaults, by its own lookup: the server's history's is
        // kept apart, in the history store, and dropped with the rest of what the server added (`HistoryStore.forget`,
        // `apply(epoch:)`) — never written where it would deepen the transfer scans' floor past every switch.
        XCTAssertTrue(environment.contains(#"if let first { UserDefaults.standard.set(String(first), forKey: "history.v1.firstBlock.\(wallet.hex.lowercased())") }"#))
        XCTAssertEqual(environment.components(separatedBy: "history.v1.firstBlock.").count - 1, 2, "read once, written once")
        XCTAssertFalse(environment.contains("keepFirstActivity"))
        let model = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(model.contains("""
                        let cached = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)
                        guard !Task.isCancelled, self.wallet == wallet else { return }
                        publish(cached, wallet: wallet, env: env)
                        if cached.swapFactsUnread { completeFacts(env: env, wallet: wallet) }
        """))
        XCTAssertTrue(model.contains("guard let self, self.wallet == wallet, roundsPublished == rounds else { return }"), "never over a round")
    }

    // MARK: Fixtures

    private func router() -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                          gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 4)
    }

    /// A service on a store kept in `directory`: its logs on the router, the swaps' other reads on rpc3 (which refuses old
    /// state) and their facts on the archive client.
    private func service(clock: BlockClock) -> WalletHistoryService {
        let swaps = SwapHistoryService(rpc: LogsStub.rpc(url: LogsStub.rpc3), clock: clock, archive: LogsStub.rpc(url: URL(string: "https://\(Chain.archiveHost)")!))
        return WalletHistoryService(store: HistoryStore(router: router(), directory: directory), swapHistory: swaps, clock: clock,
                                    stacks: { [LaunchpadAddresses.monadMainnet] }, cohorts: [MomentsAddresses.monadMainnet])
    }

    private func transfer(at block: UInt64, hash: UInt8, from: Address, to: Address, token: Address? = nil, amount: BigUInt = 5, index: Int = 0, timestamp: Int? = nil) -> Log {
        Log(address: token ?? self.token, topics: [transferTopic, from.data.leftPadded(to: 32), to.data.leftPadded(to: 32)], data: amount.word, blockNumber: block,
            transactionHash: Data(repeating: hash, count: 32), logIndex: index, blockTimestamp: timestamp)
    }

    /// The calls answered beside the logs, with the host each was asked of.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(host: String, method: String)] = []
        func add(_ host: String, _ method: String) { lock.lock(); calls.append((host, method)); lock.unlock() }
        func reset() { lock.lock(); calls = []; lock.unlock() }
        func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return calls.filter { $0.method == method }.count }
        func hosts() -> [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.host) }
    }

    /// A wallet's chain: a swap of USDC for a token (both legs logged, each with its block's time); a buy paid in MON (the
    /// token received only); a sale into MON whose MON the balance change says; one it can't (the wallet sent another
    /// transaction in that block); a plain transfer in from someone else; and an escrow payment with its block's time.
    private struct Chain {
        static let archiveHost = "archive.logs-stub.invalid"
        let wallet: Address, token: Address, other: Address
        let head = LaunchpadAddresses.feeHistoryStart + 50_000
        let swap = Data(repeating: 0xA1, count: 32)
        let buy = Data(repeating: 0xB2, count: 32)
        let sale = Data(repeating: 0xC3, count: 32)
        let unknowable = Data(repeating: 0xD4, count: 32)
        let gift = Data(repeating: 0xE5, count: 32)
        let swapTime = 1_789_999_650
        let paidTime = 1_789_999_900
        var oneSidedBlocks: [UInt64] { [head - 900, head - 800, head - 700, head - 600] }
        static let received = BigUInt(2) * BigUInt(10).power(18) + BigUInt(21_000) * BigUInt(1_000_000_000)

        var logs: [Log] {
            let transfer = ABI.eventTopic("Transfer(address,address,uint256)")
            func log(_ token: Address, _ from: Address, _ to: Address, _ amount: BigUInt, _ block: UInt64, _ hash: Data, _ index: Int, _ time: Int? = nil) -> Log {
                Log(address: token, topics: [transfer, from.data.leftPadded(to: 32), to.data.leftPadded(to: 32)], data: amount.word, blockNumber: block, transactionHash: hash,
                    logIndex: index, blockTimestamp: time)
            }
            let router = Uniswap.universalRouter
            return [log(Monad.usdc, wallet, router, 2_000_000, head - 1_000, swap, 0, swapTime), log(token, router, wallet, BigUInt(10).power(18), head - 1_000, swap, 1, swapTime),
                    log(token, router, wallet, BigUInt(3).power(18), head - 900, buy, 0),
                    log(token, wallet, router, BigUInt(4).power(18), head - 800, sale, 0),
                    log(token, wallet, router, BigUInt(5).power(18), head - 700, unknowable, 0),
                    log(token, other, wallet, 77, head - 600, gift, 0),
                    Log(address: LaunchpadAddresses.monadMainnet.escrow, topics: [LaunchpadABI.Events.escrowPaidTopic, wallet.data.leftPadded(to: 32)], data: BigUInt(7).power(18).word,
                        blockNumber: head - 500, transactionHash: Data(repeating: 0xF6, count: 32), logIndex: 0, blockTimestamp: paidTime)]
        }

        /// The transactions, receipts, balances and nonces at a block, as an archive endpoint answers them.
        func answer(recording calls: Calls) -> LogsStub.Answer {
            let (wallet, other, token, head) = (wallet, other, token, head)
            let (buy, sale, unknowable, gift) = (buy, sale, unknowable, gift)
            return { host, method, params in
                func block(_ index: Int) -> UInt64? { params[index].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } }
                func quantity(_ value: BigUInt) -> JSON { .string(value.hexQuantity) }
                switch method {
                case "eth_getTransactionByHash":
                    calls.add(host, method)
                    guard let hash = params[0].string.flatMap({ Data(hex: $0) }) else { return .null }
                    let router = JSON.string(Uniswap.universalRouter.hex)
                    switch hash {
                    case buy: return .object(["from": .string(wallet.hex), "to": router, "value": quantity(BigUInt(10).power(18))])
                    case sale, unknowable: return .object(["from": .string(wallet.hex), "to": router, "value": .string("0x0")])
                    case gift: return .object(["from": .string(other.hex), "to": .string(token.hex), "value": .string("0x0")])
                    default: return .null
                    }
                case "eth_getTransactionReceipt":
                    calls.add(host, method)
                    let hash = params[0].string.flatMap { Data(hex: $0) }
                    let at: UInt64 = hash == sale ? head - 800 : head - 700
                    return .object(["status": .string("0x1"), "blockNumber": quantity(BigUInt(at)), "gasUsed": quantity(21_000), "effectiveGasPrice": quantity(1_000_000_000)])
                case "eth_getBalance":
                    calls.add(host, method)
                    let balances: [UInt64: BigUInt] = [head - 801: BigUInt(10).power(19), head - 800: BigUInt(12) * BigUInt(10).power(18),
                                                       head - 701: BigUInt(12) * BigUInt(10).power(18), head - 700: BigUInt(13) * BigUInt(10).power(18)]
                    return block(1).flatMap { balances[$0] }.map(quantity)
                case "eth_getTransactionCount":
                    calls.add(host, method)
                    // The unknowable sale's block holds another transaction of the wallet's: its nonce moved by two.
                    let nonces: [UInt64: BigUInt] = [head - 801: 5, head - 800: 6, head - 701: 6, head - 700: 8]
                    return block(1).flatMap { nonces[$0] }.map(quantity)
                default:
                    return nil
                }
            }
        }

        /// What the snapshot holds of this chain, built with every fact read.
        func check(_ snapshot: WalletHistorySnapshot, file: StaticString = #filePath, line: UInt = #line) {
            let swaps = Dictionary(uniqueKeysWithValues: snapshot.swaps.map { ($0.hash, $0) })
            XCTAssertEqual(Set(swaps.keys), [swap, buy, sale, unknowable], "the gift isn't a swap", file: file, line: line)
            XCTAssertEqual(swaps[swap]?.time, Date(timeIntervalSince1970: TimeInterval(swapTime)), "its block's own time", file: file, line: line)
            XCTAssertEqual(swaps[swap]?.blockTimestamp, swapTime, file: file, line: line)
            XCTAssertEqual(swaps[buy]?.soldToken, Monad.native, file: file, line: line)
            XCTAssertEqual(swaps[buy]?.soldAmount, BigUInt(10).power(18), file: file, line: line)
            XCTAssertNil(swaps[buy]?.blockTimestamp, "no time given: estimated", file: file, line: line)
            XCTAssertEqual(swaps[sale]?.boughtAmount, Self.received, "the balance change plus the gas", file: file, line: line)
            XCTAssertEqual(swaps[unknowable]?.boughtNativeUnknown, true, "unknown, never 0", file: file, line: line)
            XCTAssertEqual(snapshot.launch.payments.map(\.time), [Date(timeIntervalSince1970: TimeInterval(paidTime))], file: file, line: line)
        }
    }
}
