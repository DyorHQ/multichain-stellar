import BigInt
import XCTest
@testable import DyorKit

/// How a window of logs is read in ranges (`RPCClient.chunkedLogsReport`). In both modes a range refused for its size is
/// read in smaller parts, in the ranges the endpoint names when it names them. A range refused for any other reason:
/// - fail-fast (the wallet's history on Send and the Portfolio, which say what they couldn't read, with Retry) asks it once
///   more, then leaves it as a gap and says so, and an endpoint that answers the chain head but no range ends the scan in
///   a few requests. It used to split every failed range down to 100 blocks, one request at a time: about 3.3 million
///   requests for the whole history, hours during which the Send sheet read "Reading your wallet…";
/// - patient (every other scan, whose callers take what it read) reads it in halves, as build 15 did, so an outage of a
///   couple of seconds costs nothing, but stops once the endpoint has answered nothing for a while, and halves failed
///   ranges a bounded number of times, so no endpoint keeps it going for hours.
final class LogScanTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private let token = Address(literal: "0x6666666666666666666666666666666666666666")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    /// A transfer of `token` into the wallet at `block`.
    private func transfer(at block: UInt64) -> Log {
        Log(address: token, topics: [transferTopic, Address(literal: "0x5555555555555555555555555555555555555555").data.leftPadded(to: 32), walletWord],
            data: BigUInt(5).word, blockNumber: block, transactionHash: Data(repeating: UInt8(block % 251), count: 32), logIndex: Int(block % 7))
    }

    /// The finding: rpc1 answers the chain head (108.8M blocks) but fails every getLogs, with an internal error or no
    /// answer at all. The wallet's history, read fail-fast as Send and the Portfolio read it, ends at once, incomplete: the
    /// whole window asked three times, then two rounds of six ranges, each asked twice, and no range split.
    func testAnEndpointThatAnswersNoRangeEndsTheScanInAFewRequests() async {
        for failure in [LogsStub.Failure.error(code: -32603, message: "Internal error"), .noAnswer] {
            LogsStub.install(head: 108_800_000) { _ in failure }
            let discovery = WalletTokenDiscovery(logsRPC: LogsStub.rpc(), multicall: Multicall(rpc: LogsStub.rpc()))
            let started = Date()
            let scan = await discovery.scan(wallet: wallet, wholeHistory: true, logScan: .failFast)
            XCTAssertEqual(scan, WalletTokenDiscovery.Scan(tokens: [], complete: false), "\(failure)")
            let asked = LogsStub.queries()
            XCTAssertEqual(asked.count, 27, "\(failure): 3 for the whole window, then 2 rounds of 6 ranges, each asked twice")
            XCTAssertEqual(asked.prefix(3).map(\.span), [108_800_001, 108_800_001, 108_800_001])
            XCTAssertTrue(asked.dropFirst(3).allSatisfy { $0.span == 100_000 }, "\(failure): no range split for a failure a smaller range wouldn't fix")
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }

    /// A range refused for its size is read in halves, each refused half halved again, and every log comes back in block
    /// order, in either mode.
    func testARangeRefusedForItsSizeIsReadInHalves() async {
        for mode in [LogScanMode.patient, .failFast] {
            let blocks: [UInt64] = [5, 40_000, 99_999, 100_000, 180_000, 250_000]
            LogsStub.install(head: 300_000, logs: blocks.map(transfer)) { range in
                range.span > 30_000 ? .error(code: -32062, message: "Block range is too large") : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 299_999, mode: mode)
            XCTAssertTrue(report.complete, "\(mode)")
            XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "\(mode)")
            XCTAssertTrue(LogsStub.queries().allSatisfy { $0.span >= 25_000 }, "\(mode): halved only until the endpoint answers")
        }
    }

    /// Fail-fast, a range refused for another reason is asked once more, then left as a gap and said, never split; the rest
    /// of the window is read.
    func testARangeRefusedForAnotherReasonIsAskedOnceMoreThenLeftAsAGap() async {
        LogsStub.install(head: 300_000, logs: [5, 150_000, 250_000].map(transfer)) { range in
            range.contains(150_000) ? .error(code: -32603, message: "Internal error") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 260_000, mode: .failFast)
        XCTAssertFalse(report.complete, "a gap is said")
        XCTAssertEqual(report.logs.map(\.blockNumber), [5, 250_000])
        let failing = LogsStub.queries().filter { $0.contains(150_000) }
        XCTAssertEqual(failing, [LogsStub.Range(from: 100_000, to: 199_999), LogsStub.Range(from: 100_000, to: 199_999)])
    }

    /// Patient, a range refused for another reason is read in halves, as build 15 read it, each part that fails halved
    /// again: a range too heavy for the endpoint to answer in one piece comes back whole, where fail-fast leaves it a gap.
    func testAPatientScanReadsAFailedRangeInHalvesAsBuild15Did() async {
        let blocks: [UInt64] = [5, 120_000, 150_000, 199_999, 250_000]
        LogsStub.install(head: 300_000, logs: blocks.map(transfer)) { range in
            range.contains(150_000) && range.span > 30_000 ? .error(code: -32603, message: "Internal error") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 260_000)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), blocks)
        XCTAssertEqual(LogsStub.queries().filter { $0.contains(150_000) }.map(\.span), [100_000, 100_000, 50_000, 25_000],
                       "asked, asked once more, then halved until it is answered")
    }

    /// The finding: every caller but the wallet's history dropped the complete flag, so a two-second hiccup that ended the
    /// fail-fast scan silently cut their history short. Read patiently, as build 15 read it, the same hiccup costs
    /// nothing: every range comes back, and none is split near the smallest size.
    func testAPatientScanRidesOutAMomentsOutage() async {
        let blocks: [UInt64] = [5, 30_000, 99_999, 150_000, 640_000, 1_250_000]
        for mode in [LogScanMode.patient, .paced, .failFast] {
            let until = Date().addingTimeInterval(2)
            LogsStub.install(head: 1_300_000, logs: blocks.map(transfer)) { _ in
                Date() < until ? .error(code: -32603, message: "Internal error") : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 1_299_999, mode: mode)
            switch mode {
            case .patient, .paced:
                XCTAssertTrue(report.complete, "\(mode)")
                XCTAssertEqual(report.logs.map(\.blockNumber), blocks)
                XCTAssertTrue(LogsStub.queries().allSatisfy { $0.span >= 10_000 }, "no range split near the smallest size")
            case .failFast:
                XCTAssertFalse(report.complete, "two rounds with no answer end the scan, and it says so")
                XCTAssertTrue(report.logs.isEmpty)
                XCTAssertEqual(LogsStub.queries().count, 24, "two rounds of six ranges, each asked twice")
            }
        }
    }

    /// Patient is bounded: once the endpoint has answered no range for `LogScanLimits.outage` it is down, and the scan
    /// stops there, incomplete, whether it answers with an error or not at all, the whole history included.
    func testAPatientScanStopsOnceTheEndpointIsDown() async {
        let limits = LogScanLimits(outage: 1, pause: 0.05, maxPause: 0.1)
        // The wallet's whole history (asked whole first), and a contract's events over the same window (in ranges).
        let filters: [(address: Address?, topics: [Data?])] = [(nil, [transferTopic, nil, walletWord]), (token, [transferTopic])]
        for failure in [LogsStub.Failure.error(code: -32603, message: "Internal error"), .noAnswer] {
            for filter in filters {
                LogsStub.install(head: 108_800_000) { _ in failure }
                let started = Date()
                let report = await LogsStub.rpc().chunkedLogsReport(address: filter.address, topics: filter.topics, fromBlock: 0, toBlock: 108_800_000,
                                                                     mode: .patient, limits: limits)
                XCTAssertFalse(report.complete, "\(failure)")
                XCTAssertTrue(report.logs.isEmpty)
                XCTAssertLessThan(Date().timeIntervalSince(started), 5, "\(failure)")
                XCTAssertLessThan(LogsStub.queries().count, 100, "\(failure): a few requests, never the window range by range")
            }
        }
        // The shipped limits: 45 s with no range answered, a pause of 0.25 s more for each failure in a row up to 2 s,
        // 256 splits of failed ranges and 4,096 in all.
        XCTAssertEqual(LogScanLimits(), LogScanLimits(splits: 4_096, failedSplits: 256, outage: 45, pause: 0.25, maxPause: 2))
    }

    /// The finding: the outage was wall-clock time since the last answer, so a scan running when iOS suspended the app
    /// found the endpoint "down" on its return, however healthy it was, and the venue list's refill ended there until a
    /// cold launch. The outage is now measured from the later of the last answer and the app's return (`LogScanClock`).
    func testAScanMeasuresAnOutageFromTheAppsReturn() async throws {
        let limits = LogScanLimits(outage: 0.3)
        var returned = LogScan(mode: .paced, limits: limits)
        var stayed = LogScan(mode: .patient, limits: limits)
        LogScanClock.suspended()
        try await Task.sleep(for: .milliseconds(400)) // the app, suspended
        XCTAssertTrue(LogScanClock.resumed())
        returned.record([.failed])
        XCTAssertFalse(returned.down, "the time away doesn't count")
        try await Task.sleep(for: .milliseconds(400))
        returned.record([.failed])
        XCTAssertTrue(returned.down, "an outage since the return does")
        // A scan that started after the return measures from its start, as before.
        stayed = LogScan(mode: .patient, limits: limits)
        try await Task.sleep(for: .milliseconds(400))
        stayed.record([.failed])
        XCTAssertTrue(stayed.down)
        var failFast = LogScan(mode: .failFast, limits: limits)
        try await Task.sleep(for: .milliseconds(400))
        failFast.record([.failed])
        XCTAssertFalse(failFast.down, "fail-fast counts rounds, not time")
    }

    /// The re-review's finding: the app reset the outage at every activation of its scene, and App Lock's Face ID prompt,
    /// a passkey sheet or Control Center each make one without the app leaving the foreground, so while they kept coming a
    /// scan whose endpoint was down never ended. Only the first activation after the background resets it.
    func testOnlyAReturnFromTheBackgroundResetsTheOutage() async throws {
        let limits = LogScanLimits(outage: 0.3)
        var scan = LogScan(mode: .patient, limits: limits)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(LogScanClock.resumed(), "the scene was only inactive")
        scan.record([.failed])
        XCTAssertTrue(scan.down, "the outage since the scan's start counts")
        LogScanClock.suspended()
        XCTAssertTrue(LogScanClock.resumed(), "a return")
        XCTAssertFalse(LogScanClock.resumed(), "one reset a return")

        // A paced scan throttled throughout ends at its outage, however many activations come meanwhile.
        LogsStub.install(head: 10_000_000, logs: []) { _ in .error(code: -32005, message: "rate limit exceeded") }
        let activations = Task.detached {
            for _ in 0..<16 { LogScanClock.resumed(); try? await Task.sleep(for: .milliseconds(250)) }
        }
        let started = Date()
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 4_999_999, chunkSize: 5_000_000,
                                                             concurrency: 1, mode: .paced, limits: LogScanLimits(outage: 1, throttlePause: 0.05, maxThrottlePause: 0.1))
        let elapsed = Date().timeIntervalSince(started)
        activations.cancel()
        await activations.value
        XCTAssertFalse(report.complete)
        XCTAssertLessThan(elapsed, 3, "it ran on for as long as the activations came (4 s)")
    }

    /// Patient halves failed ranges a bounded number of times: an endpoint that answers only small ranges, failing every
    /// other one, gets the first ranges read in halves, then gaps asked twice, never hours of 100-block requests.
    func testAPatientScanHalvesFailedRangesABoundedNumberOfTimes() async {
        LogsStub.install(head: 3_000_000, logs: [5, 2_500_000].map(transfer)) { range in
            range.span > 1_000 ? .error(code: -32603, message: "Internal error") : nil
        }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 2_999_999,
                                                             mode: .patient, limits: LogScanLimits(pause: 0, maxPause: 0))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [5], "the first ranges are read in halves; later ones are gaps once the halving is spent")
        // Halving all 30 ranges down to 781 blocks would take 7,680 requests.
        XCTAssertLessThan(LogsStub.queries().count, 800, "256 splits of failed ranges, then each range asked twice")
    }

    /// Every split is bounded, whatever refused the range: an endpoint that refuses every range for its size, as none
    /// does, can't keep either mode halving the window down to 100 blocks.
    func testEverySplitIsBounded() async {
        for mode in [LogScanMode.patient, .failFast] {
            LogsStub.install(head: 10_000_000, logs: [5].map(transfer)) { _ in .error(code: -32062, message: "Block range is too large") }
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 9_999_999,
                                                                 mode: mode, limits: LogScanLimits(splits: 64, pause: 0, maxPause: 0))
            XCTAssertFalse(report.complete, "\(mode)")
            XCTAssertLessThan(LogsStub.queries().count, 400, "\(mode): 64 splits, then each range asked once and left")
        }
    }

    /// rpc1 refuses a wallet's whole history when it holds more than 10K logs: that refusal is not sent again, as it used
    /// to be three times over, and the window is read in ranges, in either mode.
    func testAWholeHistoryRefusedForItsSizeIsNotSentAgain() async {
        for mode in [LogScanMode.patient, .failFast] {
            let blocks: [UInt64] = [7, 120_000, 399_999]
            LogsStub.install(head: 400_000, logs: blocks.map(transfer)) { range in
                range.span > 150_000 ? .error(code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 1,000 block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response.") : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 400_000, mode: mode)
            XCTAssertTrue(report.complete, "\(mode)")
            XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "\(mode)")
            XCTAssertEqual(LogsStub.queries().filter { $0.span > 150_000 }.count, 1, "\(mode): the whole window asked once")
        }
    }

    /// rpc1's refusal of a history of more than 10K logs, as it reads live: it names the range from the same start that
    /// fits its cap.
    private func rpc1Refusal(_ range: LogsStub.Range, end: UInt64) -> LogsStub.Failure {
        .error(code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 1,000 block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response. Based on your parameters and the response size limit, this block range should work: [\(BigUInt(range.from).hexQuantity), \(BigUInt(end).hexQuantity)]")
    }

    /// A wallet whose history is over rpc1's cap (here 3 logs an answer, 10K live) is read in the ranges rpc1 names, in
    /// either mode: seven requests for four pages, where 100,000-block ranges over 108.8M blocks took 1,089 requests in 182
    /// rounds, minutes.
    func testAHistoryOverTheCapIsReadInTheRangesTheEndpointNames() async {
        for mode in [LogScanMode.patient, .failFast] {
            let blocks: [UInt64] = [10, 5_000_000, 20_000_000, 40_000_000, 60_000_000, 80_000_000, 90_000_000, 100_000_000, 105_000_000, 108_000_000, 108_500_000, 108_799_999]
            LogsStub.install(head: 108_800_000, logs: blocks.map(transfer)) { [self] range in
                let inside = blocks.filter(range.contains)
                return inside.count > 3 ? rpc1Refusal(range, end: inside[3] - 1) : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 108_800_000, mode: mode)
            XCTAssertTrue(report.complete, "\(mode)")
            XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "\(mode)")
            XCTAssertEqual(LogsStub.queries().count, 7, "\(mode): the whole window once, then each page and what is left after it")
            XCTAssertFalse(LogsStub.queries().contains { $0.span == 100_000 }, "\(mode): never the 100,000-block ranges")
        }
    }

    /// rpc1 sends the same refusal as an HTTP 400 when the request is a single object, not an array (measured
    /// 2026-09-30), and the whole window is asked as one: the refusal, and the range it names, still reach the scan, so
    /// the wallet's history on Send and the Portfolio reads in full, where it came back with a gap.
    func testAHistoryOverTheCapIsReadInFullWhenTheRefusalComesAsHTTP400() async {
        for mode in [LogScanMode.patient, .failFast] {
            let blocks: [UInt64] = [10, 5_000_000, 20_000_000, 40_000_000, 60_000_000, 80_000_000, 90_000_000, 100_000_000, 105_000_000, 108_000_000, 108_500_000, 108_799_999]
            LogsStub.install(head: 108_800_000, logs: blocks.map(transfer), singleErrorStatus: 400) { [self] range in
                let inside = blocks.filter(range.contains)
                return inside.count > 3 ? rpc1Refusal(range, end: inside[3] - 1) : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 108_800_000, mode: mode)
            XCTAssertTrue(report.complete, "\(mode)")
            XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "\(mode)")
            XCTAssertEqual(LogsStub.queries().count, 7, "\(mode): the whole window once, then each page and what is left after it")

            // Ten transfers inside one 100,000-block range: that range, refused in a batch, is read in the parts rpc1 names,
            // each asked on its own, where a refusal as HTTP 400 left it a gap.
            let dense = (0..<10).map { 10_000 + UInt64($0) * 5_000 }
            LogsStub.install(head: 400_000, logs: dense.map(transfer), singleErrorStatus: 400) { [self] range in
                let inside = dense.filter(range.contains)
                return inside.count > 3 ? rpc1Refusal(range, end: inside[3] - 1) : nil
            }
            let spammed = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 299_999, mode: mode)
            XCTAssertTrue(spammed.complete, "\(mode)")
            XCTAssertEqual(spammed.logs.map(\.blockNumber), dense, "\(mode)")
        }
    }

    /// An endpoint that names a tiny range every time is followed 200 times, then the rest is read in halves: it can't keep
    /// the scan splitting off a block at a time, in either mode.
    func testTheRangesAnEndpointNamesAreFollowedABoundedNumberOfTimes() async {
        for mode in [LogScanMode.patient, .failFast] {
            LogsStub.install(head: 300_000, logs: [7, 250_000].map(transfer)) { [self] range in
                range.span > 50_000 ? rpc1Refusal(range, end: range.from) : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 300_000, mode: mode)
            XCTAssertTrue(report.complete, "\(mode)")
            XCTAssertEqual(report.logs.map(\.blockNumber), [7, 250_000], "\(mode)")
            XCTAssertLessThan(LogsStub.queries().count, 450, "\(mode)")
        }
    }

    /// Only the wallet's history on Send and the Portfolio (`WalletTokens.history`) is read fail-fast: every other log
    /// scan — the launchpad's events and holdings, Moments' history, swap history, venue tokens, Home's 30-day discovery —
    /// keeps the patient default, whose callers take what it read (the wallet's NFTs scan nothing since build 23: they come
    /// from the history store).
    func testOnlyTheWalletsHistoryIsReadFailFast() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        let app = ios.appendingPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let kit = ios.appendingPathComponent("DyorKit/Sources/DyorKit")
        var sayFailFast: [String] = []
        for root in [app, kit] {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                if source.contains("failFast") { sayFailFast.append(file.lastPathComponent) }
            }
        }
        // LogsRouter.swift: the budget each mode spends. The wallet's history itself no longer scans: it comes from the
        // history store (`WalletTokens.history`), so nothing in the app reads fail-fast any more.
        XCTAssertEqual(Set(sayFailFast), ["Logs.swift", "LogsRouter.swift", "WalletTokenDiscovery.swift"])
        let tokens = try String(contentsOf: app.appendingPathComponent("Wallet/WalletTokens.swift"), encoding: .utf8)
        XCTAssertEqual(tokens.components(separatedBy: "logScan: .failFast").count - 1, 0, "the history comes from the store")
        XCTAssertTrue(tokens.contains("env.walletDiscovery.held(wallet: address, incoming: snapshot.transfersIn, complete: snapshot.status(WalletHistoryScans.transfersInId).complete, known: known)"))
        let discovery = try String(contentsOf: kit.appendingPathComponent("Services/WalletTokenDiscovery.swift"), encoding: .utf8)
        XCTAssertTrue(discovery.contains("logScan: LogScanMode = .patient"))
        XCTAssertTrue(discovery.contains("fromBlock: from, toBlock: latest, mode: logScan)"))
        // Read with every run of whitespace as one space: the checks pin the code, not its line breaks or indentation.
        let logs = try String(contentsOf: kit.appendingPathComponent("Core/Logs.swift"), encoding: .utf8).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A scan is a screen's at the gate unless it says otherwise (`LogsGate.Lane`), and the router reads it in its lane,
        // as many requests at once as it asks for, from the end it asks for (`LogsRouter.Order`): oldest first unless it
        // says newest first, as every wide scan a screen shows does (`newestLogs`, `NewestFirstScanTests`).
        XCTAssertTrue(logs.contains("mode: LogScanMode = .patient, lane: LogsGate.Lane = .interactive, order: LogsRouter.Order = .ascending) async -> (logs: [Log], complete: Bool)"))
        XCTAssertTrue(logs.contains("from: fromBlock, to: toBlock, order: order, budget: LogsBudget(mode: mode), concurrency: concurrency, lane: lane)"))
        XCTAssertTrue(logs.contains("from: fromBlock, to: toBlock, order: .descending, budget: LogsBudget(mode: mode), lane: lane)"), "newestLogs reads newest first")
    }

    /// The finding (build 17): rpc3 answers 1,000 blocks a request, however many ranges it holds, and refuses the rest,
    /// yet ranges were sized at 100,000 for it, as for rpc1. Each refused range is split, a request a split, and a scan
    /// splits at most 4,096 times: a 5M-block segment of the venue scan needed about 6,350, so part of every segment was
    /// left unread, and never read again. Sized at 1,000, one a request, the same endpoint reads the segment in full, no
    /// range refused.
    func testAnEndpointThatAnswers1000BlocksReadsA5MBlockSegmentWithNoGap() async {
        let blocks: [UInt64] = [100_000_000, 100_000_999, 100_001_000, 101_234_567, 102_500_000, 104_999_999]
        let rule: LogsStub.Rule = { range in range.span > 1_000 ? .error(code: -32062, message: "Block range is too large") : nil }
        LogsStub.install(head: 105_000_000, logs: blocks.map(transfer), batchSpan: 1_000, rule: rule)
        let report = await LogsStub.rpc(url: LogsStub.rpc3).chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 100_000_000, toBlock: 104_999_999)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), blocks)
        XCTAssertEqual(LogsStub.queries().count, 5_000)
        XCTAssertEqual(LogsStub.requests(), 5_000, "one range a request, the default six a round trip notwithstanding")
        XCTAssertTrue(LogsStub.queries().allSatisfy { $0.span == 1_000 }, "every range answered as asked")

        // Build 16's range against the same endpoint: 127 splits and 255 requests for 100,000 blocks, so 6,350 splits for
        // the segment's 50 ranges, past what a scan may make.
        LogsStub.install(head: 105_000_000, logs: blocks.map(transfer), batchSpan: 1_000, rule: rule)
        let build16 = await LogsStub.rpc(url: LogsStub.rpc3).chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 100_000_000, toBlock: 100_099_999,
                                                                              chunkSize: 100_000)
        XCTAssertTrue(build16.complete)
        XCTAssertEqual(LogsStub.queries().count, 255)
        XCTAssertGreaterThan(50 * (LogsStub.queries().count - 1) / 2, LogScanLimits().splits)
    }

    /// rpc3 counts a request's ranges together, so a round trip there asks one 1,000-block range: six in one would have
    /// five refused and split, five splits for every 6,000 blocks, and a 5M-block window past the scan's splits again.
    /// Every other endpoint still asks `concurrency` ranges a round trip.
    func testARequestOnRpc3AsksOneRange() async {
        LogsStub.install(head: 20_000, batchSpan: 1_000) { _ in nil }
        let rpc3 = await LogsStub.rpc(url: LogsStub.rpc3).chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 11_999)
        XCTAssertTrue(rpc3.complete)
        XCTAssertEqual(LogsStub.queries().count, 12, "no range refused, so none split")
        XCTAssertEqual(LogsStub.requests(), 12)

        LogsStub.install(head: 2_000_000) { _ in nil }
        let rpc1 = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 1_199_999)
        XCTAssertTrue(rpc1.complete)
        XCTAssertEqual(LogsStub.queries().count, 12)
        XCTAssertEqual(LogsStub.requests(), 2, "six ranges a round trip, as before")
    }

    /// Ranges are sized to what each endpoint answers, as measured on 2026-09-29 (rpc4: what every node behind it answers),
    /// and only rpc3 counts a request's ranges together. Only rpc1 answers a range of any span, up to its log cap.
    func testRangesAreSizedToWhatEachEndpointAnswers() {
        let sizes: [(String, UInt64, UInt64?)] = [("https://rpc1.monad.xyz", 100_000, nil), ("https://rpc3.monad.xyz", 1_000, 1_000),
                                                  ("https://rpc4.monad.xyz", 1_000, nil), ("https://rpc.monad.xyz", 100, nil),
                                                  ("http://127.0.0.1:8545", 50_000, nil), ("http://localhost:8545", 50_000, nil)]
        for (url, size, batch) in sizes {
            XCTAssertEqual(RPCClient.logChunkSize(for: URL(string: url)!), size, url)
            XCTAssertEqual(RPCClient.logBatchSpan(for: URL(string: url)!), batch, url)
            XCTAssertEqual(RPCClient.answersAnyRange(URL(string: url)!), url.contains("rpc1"), url)
        }
    }

    /// Paced (the venue token list): a throttle — HTTP 429 once the client's own retries are spent, or a rate-limit error
    /// in the answer — is waited out and the same range asked again, never split. The venue list's refill split throttled
    /// ranges, patient: 2,714 requests on rpc1, 1,000 of them answered HTTP 429.
    func testAPacedScanWaitsOutAThrottleAndNeverSplits() async {
        let limits = LogScanLimits(throttlePause: 0.05, maxThrottlePause: 0.1)
        for throttle in [LogsStub.Failure.status(429), .error(code: -32005, message: "rate limit exceeded")] {
            // The client asks five times (its own retries) before the scan sees a throttle: the first ask is throttled
            // in full, the next is answered.
            LogsStub.install(head: 10_000_000, logs: [5, 4_000_000].map(transfer)) { _ in LogsStub.requests() <= 5 ? throttle : nil }
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 4_999_999, chunkSize: 5_000_000,
                                                                 concurrency: 1, mode: .paced, limits: limits)
            XCTAssertTrue(report.complete, "\(throttle)")
            XCTAssertEqual(report.logs.map(\.blockNumber), [5, 4_000_000], "\(throttle)")
            XCTAssertEqual(Set(LogsStub.queries()), [LogsStub.Range(from: 0, to: 4_999_999)], "\(throttle): the same range, never split")
            XCTAssertEqual(LogsStub.requests(), 6, "\(throttle): the client's five, then the scan's one after its pause")
        }
    }

    /// The re-review's finding: paced, only HTTP 429 and rate-limit errors were waited out, so a storm of 503s, or 429s
    /// that ended in a request with no answer, failed the range and the 5M-block range was halved. An endpoint answering
    /// 503 is overloaded or restarting, and one that stops answering after a throttle is throttling still: both are waited
    /// out, the same range asked again, not split (`testAPacedScanReadsARangeThrottledPastItsWaitsInHalvesOnce`).
    func testAPacedScanWaitsOutServerErrorsAndNoAnswerAfterAThrottle() async {
        let limits = LogScanLimits(throttlePause: 0.05, maxThrottlePause: 0.1)
        let scenarios: [(String, LogsStub.Rule)] = [
            // Two of the client's asks, five requests each, then the scan's after its pause.
            ("503s", { _ in LogsStub.requests() <= 10 ? .status(503) : nil }),
            // The client's five asks throttled, then two with no answer, each after the scan's pause.
            ("429s, then no answer", { _ in LogsStub.requests() <= 5 ? .status(429) : LogsStub.requests() <= 7 ? .noAnswer : nil }),
            // A 429, then no answer, within each of two of the client's asks: the scan sees only the connection fail.
            ("a 429, then no answer, in one ask", { _ in LogsStub.requests() <= 4 ? (LogsStub.requests() % 2 == 1 ? .status(429) : .noAnswer) : nil }),
        ]
        for (name, rule) in scenarios {
            LogsStub.install(head: 10_000_000, logs: [5, 4_000_000].map(transfer), rule: rule)
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 4_999_999, chunkSize: 5_000_000,
                                                                 concurrency: 1, mode: .paced, limits: limits)
            XCTAssertTrue(report.complete, name)
            XCTAssertEqual(report.logs.map(\.blockNumber), [5, 4_000_000], name)
            XCTAssertEqual(Set(LogsStub.queries()), [LogsStub.Range(from: 0, to: 4_999_999)], "\(name): the same range, never split")
        }
    }

    /// Paced, a throttle that outlasts the outage ends the scan there, incomplete: nothing split, nothing more asked. The
    /// venue list reads the range on a later run.
    func testAPacedScanStopsWhenAThrottleOutlastsTheOutage() async {
        LogsStub.install(head: 10_000_000, logs: [5].map(transfer)) { _ in .error(code: -32005, message: "rate limit exceeded") }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 9_999_999, chunkSize: 5_000_000,
                                                             concurrency: 1, mode: .paced,
                                                             limits: LogScanLimits(outage: 1, throttlePause: 0.05, maxThrottlePause: 0.1))
        XCTAssertFalse(report.complete)
        XCTAssertEqual(Set(LogsStub.queries()), [LogsStub.Range(from: 0, to: 4_999_999)], "the first range only, never split")
        XCTAssertEqual(LogsStub.requests(), 5, "one ask, the client's own retries")
    }

    /// The V1 final check's finding (P2): paced, every HTTP 5xx was a throttle, so a range the endpoint answers 5xx every
    /// time (a gateway timeout for a heavy range) was waited out, never split, and the venue list stalled on it, run after
    /// run. Only 429 and 503 (and rate-limit errors) are throttles; a 504 is a failure, and a paced scan reads a failed
    /// range in halves, as a patient one does.
    func testAPacedScanReadsARangeAnswered504EveryTimeInHalves() async {
        LogsStub.install(head: 10_000_000, logs: [5, 4_000_000].map(transfer)) { range in range.span > 2_500_000 ? .status(504) : nil }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 4_999_999, chunkSize: 5_000_000,
                                                             concurrency: 1, mode: .paced,
                                                             limits: LogScanLimits(outage: 15, pause: 0, maxPause: 0, throttlePause: 0.05, maxThrottlePause: 0.1))
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [5, 4_000_000])
        XCTAssertEqual(Set(LogsStub.queries()), [LogsStub.Range(from: 0, to: 4_999_999), LogsStub.Range(from: 0, to: 2_499_999), LogsStub.Range(from: 2_500_000, to: 4_999_999)])
        XCTAssertEqual(LogsStub.requests(), 12, "the range asked twice (the client's five each), then its halves")
    }

    /// ...and a range the endpoint throttles every time (a 503 for a range too heavy for it) is waited out, then read in
    /// halves: once a scan, so the requests at most double, and a range throttled after that is waited out until the
    /// outage, never split.
    func testAPacedScanReadsARangeThrottledPastItsWaitsInHalvesOnce() async {
        LogsStub.install(head: 10_000_000, logs: [5, 4_000_000].map(transfer)) { range in range.span > 2_500_000 ? .status(503) : nil }
        let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 4_999_999, chunkSize: 5_000_000,
                                                             concurrency: 1, mode: .paced,
                                                             limits: LogScanLimits(outage: 30, pause: 0, maxPause: 0, throttlePause: 0.05, maxThrottlePause: 0.1,
                                                                                   throttleWaits: 1))
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [5, 4_000_000])
        XCTAssertEqual(Set(LogsStub.queries()), [LogsStub.Range(from: 0, to: 4_999_999), LogsStub.Range(from: 0, to: 2_499_999), LogsStub.Range(from: 2_500_000, to: 4_999_999)])
        XCTAssertEqual(LogsStub.requests(), 12, "asked, waited out once (the client's five each), then its halves")

        // Once a scan: a range throttled past its waits after the first is not split.
        var scan = LogScan(mode: .paced, limits: LogScanLimits())
        var cuts = 200
        let whole = LogFilter(fromBlock: 0, toBlock: 4_999_999)
        XCTAssertEqual(scan.divide(whole, after: .throttled, cuts: &cuts, floor: 100)?.map(\.toBlock), [2_499_999, 4_999_999])
        XCTAssertNil(scan.divide(LogFilter(fromBlock: 0, toBlock: 2_499_999), after: .throttled, cuts: &cuts, floor: 100))
        XCTAssertNotNil(scan.divide(LogFilter(fromBlock: 0, toBlock: 2_499_999), after: .failed, cuts: &cuts, floor: 100), "a failure is still halved")
        XCTAssertEqual(scan.throttleSplits, 0)
        XCTAssertTrue(RPCClient.isThrottle(status: 429) && RPCClient.isThrottle(status: 503))
        XCTAssertFalse([500, 502, 504].contains(where: RPCClient.isThrottle(status:)))
    }

    /// The V1 last check's finding (L1): paced, every range still throttled after the waits was given up to be halved,
    /// even one `LogScan.divide` can't halve (no wider than the floor), which was then a gap, and so was a second range
    /// in the same request once the scan's one split was spent. Only a range that can be halved, as many as the scan's
    /// splits, is given up; the rest are waited out, as the limits say.
    func testAPacedScanWaitsOutAThrottledRangeItCantHalve() async {
        let blocks: [UInt64] = [50, 150, 250, 350, 450, 550, 650, 750, 850, 950]
        let limits = LogScanLimits(outage: 30, pause: 0, maxPause: 0, throttlePause: 0.05, maxThrottlePause: 0.1)
        let scenarios: [(String, UInt64, Int, [UInt64])] = [
            ("a 100-block range (the floor), throttled for 4 asks", 100, 1, [550]),
            ("two 200-block ranges in one request, both throttled for 4 asks", 200, 2, [150, 350]),
        ]
        for (name, chunk, concurrency, throttledBlocks) in scenarios {
            // The client asks five times (its own retries) per ask of the scan: throttled for the scan's first four asks.
            let asked = RangeAsks()
            LogsStub.install(head: 1_000, logs: blocks.map(transfer)) { range in
                guard throttledBlocks.contains(where: range.contains) else { return nil }
                return asked.next(range) <= 20 ? .error(code: -32005, message: "rate limit exceeded") : nil
            }
            let report = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 999, chunkSize: chunk,
                                                                 concurrency: concurrency, mode: .paced, limits: limits)
            XCTAssertTrue(report.complete, name)
            XCTAssertEqual(report.logs.map(\.blockNumber), blocks, "\(name): nothing lost")
        }
    }

    /// The re-review's finding (from before V1): rpc1 refuses a range past the head of the node answering it (its nodes
    /// can be a few blocks apart, the head read from one and the logs from another) with "block range extends beyond
    /// current head block", and `refusesSize` took that for a size refusal: the range was split, 59 requests for a
    /// 1M-block range. It is asked again once the node has had time to catch up, not split; if the node still hasn't, it
    /// is read in halves as before, so everything up to that node's head is read (`testARangeStillPastTheNodesHeadAfterTheWaitsIsReadInHalves`).
    func testARangePastTheNodesHeadIsAskedAgainBeforeItIsSplit() async {
        let limits = LogScanLimits(pause: 0, maxPause: 0, headPause: 0.05)
        let pastHead = LogsStub.Failure.error(code: -32602, message: "block range extends beyond current head block")
        let whole = LogsStub.Range(from: 0, to: 999_999)
        for mode in [LogScanMode.patient, .failFast, .paced] {
            // The node answering catches up by the second ask again.
            LogsStub.install(head: 1_000_000, logs: [5, 999_990].map(transfer)) { range in range.to > 999_000 && LogsStub.requests() <= 2 ? pastHead : nil }
            let caughtUp = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 999_999, chunkSize: 1_000_000,
                                                                  concurrency: 1, mode: mode, limits: limits)
            XCTAssertTrue(caughtUp.complete, "\(mode)")
            XCTAssertEqual(caughtUp.logs.map(\.blockNumber), [5, 999_990], "\(mode)")
            XCTAssertEqual(LogsStub.queries(), [whole, whole, whole], "\(mode): asked again, never split")

            // A node that doesn't catch up: after two more asks, read in halves, each part asked once (the waits are spent).
            LogsStub.install(head: 1_000_000, logs: [5, 600_000].map(transfer)) { range in range.to > 999_000 ? pastHead : nil }
            let behind = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 999_999, chunkSize: 1_000_000,
                                                                concurrency: 1, mode: mode, limits: limits)
            XCTAssertFalse(behind.complete, "\(mode): the blocks past that node's head are a gap")
            XCTAssertEqual(behind.logs.map(\.blockNumber), [5, 600_000], "\(mode): everything up to that node's head is read")
            let asked = LogsStub.queries()
            XCTAssertEqual(Array(asked.prefix(3)), [whole, whole, whole], "\(mode)")
            XCTAssertEqual(Set(asked.dropFirst(3)).count, asked.count - 3, "\(mode): each part once")
            XCTAssertTrue(asked.dropFirst(3).allSatisfy { $0.span < whole.span }, "\(mode)")
        }
        // A size refusal is still split.
        LogsStub.install(head: 1_000_000, logs: [5].map(transfer)) { range in range.span > 500_000 ? .error(code: -32062, message: "Block range is too large") : nil }
        let split = await LogsStub.rpc().chunkedLogsReport(address: token, topics: [transferTopic], fromBlock: 0, toBlock: 999_999, chunkSize: 1_000_000,
                                                           concurrency: 1, mode: .paced, limits: limits)
        XCTAssertTrue(split.complete)
        XCTAssertEqual(Set(LogsStub.queries()), [whole, LogsStub.Range(from: 0, to: 499_999), LogsStub.Range(from: 500_000, to: 999_999)])
    }

    /// The V1 final check's finding (P1): a node that stayed behind the head the caller read for longer than the waits left
    /// the whole last range (up to 100,000 blocks) as a gap, where before, its refusal taken for a size refusal, the range
    /// was halved and everything up to that node's head read — and the callers that take what a scan read (launches,
    /// Moments, swaps, NFTs) lost the newest activity. Once the waits are spent the range is read in halves, as before, in
    /// every mode; the waits are the scan's, two in all, not two for every range it asks.
    func testARangeStillPastTheNodesHeadAfterTheWaitsIsReadInHalves() async {
        let pastHead = LogsStub.Failure.error(code: -32602, message: "block range extends beyond current head block")
        let limits = LogScanLimits(pause: 0, maxPause: 0, headPause: 0.01)
        for mode in [LogScanMode.patient, .failFast, .paced] {
            for walletScoped in [false, true] {
                let name = "\(mode), \(walletScoped ? "wallet-scoped" : "by address")"
                // The node answering is 10 blocks short of the head the caller read, and stays there.
                LogsStub.install(head: 1_000_000, logs: [5, 950_000, 999_950].map(transfer)) { range in range.to > 999_989 ? pastHead : nil }
                let report = await LogsStub.rpc().chunkedLogsReport(address: walletScoped ? nil : token, topics: walletScoped ? [transferTopic, nil, walletWord] : [transferTopic],
                                                                    fromBlock: 0, toBlock: 999_999, mode: mode, limits: limits)
                XCTAssertEqual(report.logs.map(\.blockNumber), [5, 950_000], name)
                XCTAssertFalse(report.complete, "\(name): the last blocks, past that node's head, are a gap the caller reads later")
                let behind = LogsStub.queries().filter { $0.to > 999_989 }
                XCTAssertEqual(behind.count - Set(behind).count, 2, "\(name): two asks again in all, then each part once")
                XCTAssertTrue(behind.contains(LogsStub.Range(from: 999_804, to: 999_999)), "\(name): halved down to the smallest range")
            }
        }
    }

    /// The fallback costs the common case nothing: a node a block or two behind (under a second) costs the wallet's history
    /// on Send and the Portfolio (fail-fast) the one wait of a second it cost before, with the app's limits, and is read
    /// in full; the whole window asked twice.
    func testANodeABlockOrTwoBehindCostsTheWalletsHistoryOneWait() async {
        let pastHead = LogsStub.Failure.error(code: -32602, message: "block range extends beyond current head block")
        let caughtUp = Date().addingTimeInterval(0.8)
        LogsStub.install(head: 1_000_000, logs: [5, 999_990].map(transfer)) { range in range.to > 999_997 && Date() < caughtUp ? pastHead : nil }
        let started = Date()
        let report = await LogsStub.rpc().chunkedLogsReport(address: nil, topics: [transferTopic, nil, walletWord], fromBlock: 0, toBlock: 999_999, mode: .failFast)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.logs.map(\.blockNumber), [5, 999_990])
        XCTAssertEqual(LogsStub.queries(), [LogsStub.Range(from: 0, to: 999_999), LogsStub.Range(from: 0, to: 999_999)])
        XCTAssertGreaterThanOrEqual(elapsed, 0.8)
        XCTAssertLessThan(elapsed, 1.5, "one wait of a second")
    }

    func testTheRangeASizeRefusalNamesIsReadOnlyWhenItFits() {
        let refusal = RPCError(code: -32602, message: "Log response size exceeded. Based on your parameters and the response size limit, this block range should work: [0x6000000, 0x6000b41]")
        XCTAssertEqual(RPCClient.suggestedEnd(refusal, from: 0x6000000, to: 0x6700000), 0x6000b41)
        XCTAssertNil(RPCClient.suggestedEnd(refusal, from: 0x5000000, to: 0x6700000), "another start")
        XCTAssertNil(RPCClient.suggestedEnd(refusal, from: 0x6000000, to: 0x6000b41), "not inside the window")
        XCTAssertNil(RPCClient.suggestedEnd(RPCError(code: -32062, message: "Block range is too large"), from: 0, to: 1_000))
        XCTAssertNil(RPCClient.suggestedEnd(RPCError(code: -32602, message: "should work: [0x, 0x]"), from: 0, to: 1_000))
        let halves = RPCClient.split(LogFilter(fromBlock: 100, toBlock: 1_099), floor: 100)
        XCTAssertEqual(halves?.map(\.fromBlock), [100, 600])
        XCTAssertEqual(halves?.map(\.toBlock), [599, 1_099])
        XCTAssertEqual(RPCClient.split(LogFilter(fromBlock: 100, toBlock: 1_099), at: 150, floor: 100)?.map(\.toBlock), [150, 1_099])
        XCTAssertEqual(RPCClient.split(LogFilter(fromBlock: 100, toBlock: 1_099), at: 1_099, floor: 100)?.map(\.toBlock), [599, 1_099], "a cut outside: halves")
        XCTAssertNil(RPCClient.split(LogFilter(fromBlock: 100, toBlock: 199), floor: 100), "no wider than the floor")
    }

    /// The size refusals of Monad's endpoints, read live on 2026-09-29, and errors a smaller range doesn't fix.
    func testWhichRefusalsASmallerRangeFixes() {
        let size = [
            RPCError(code: -32602, message: "Log response size exceeded. You can make eth_getLogs requests with up to a 1,000 block range and no limit on the response size, or you can request any block range with a cap of 10K logs in the response. Based on your parameters and the response size limit, this block range should work: [0x6000000, 0x6000b41]"),
            RPCError(code: -32614, message: "eth_getLogs is limited to a 100 range"),
            RPCError(code: -32062, message: "Block range is too large"),
            RPCError(code: -32005, message: "query returned more than 10000 results"),
        ]
        for error in size {
            XCTAssertTrue(RPCClient.refusesSize(error), error.message)
            XCTAssertFalse(RPCClient.refusesPastHead(error), error.message)
        }
        // rpc1's refusal of a range past the head of the node answering it (probed live) says "block range" too.
        let pastHead = RPCError(code: -32602, message: "block range extends beyond current head block")
        XCTAssertTrue(RPCClient.refusesPastHead(pastHead))
        XCTAssertFalse(RPCClient.refusesSize(pastHead))
        // rpc2's (2026-10-09), the endpoint the newest blocks are read on, and an upstream's: past the head, never a failure
        // counted against the range, nor a size.
        for refusal in [RPCError(code: -32014, message: "block not available: block not found for eth_getLogs, requested toBlock 111739189 is not yet available on the node"),
                        RPCError(code: -32014, message: "block not available"),
                        RPCError(code: -32603, message: "ErrUpstreamBlockUnavailable: upstream does not have the requested block yet")] {
            XCTAssertTrue(RPCClient.refusesPastHead(refusal), refusal.message)
            XCTAssertFalse(RPCClient.refusesSize(refusal), refusal.message)
        }
        XCTAssertFalse(RPCClient.refusesPastHead(RPCError(code: -32000, message: "block not available")), "-32014's words alone, under another code")
        let other = [
            RPCError(code: -32603, message: "Internal error"),
            RPCError(code: -32000, message: "header not found"),
            RPCError(code: 429, message: "Too Many Requests"),
            RPCError(code: -32005, message: "rate limit exceeded"),
            RPCError(code: -32602, message: "Invalid params"),
            RPCError(code: -1, message: "Malformed log response"),
        ]
        for error in other {
            XCTAssertFalse(RPCClient.refusesSize(error), error.message)
            XCTAssertFalse(RPCClient.refusesPastHead(error), error.message)
        }
    }
}

/// An `eth_getLogs` endpoint answered from memory, named like rpc1 so ranges are 100,000 blocks (`rpc(url: rpc3)` names
/// it like rpc3: 1,000 blocks): the chain head is `head`, every range asked is recorded (`queries()`), every request
/// counted (`requests()`), and `rule` refuses a range (an error, no answer to the whole request, or an HTTP status for it)
/// or lets it be answered from `logs`. With `batchSpan`, a request's ranges share that many blocks, as on rpc3: a range
/// past what the ranges before it in the request used is refused for its size. With `singleErrorStatus`, a single-object
/// request (not an array) whose call is refused gets that HTTP status, the error still its body, as rpc1 sends a size
/// refusal (400). With `answer`, a call other than the logs (a transaction, a receipt, a balance or a nonce at a block) is
/// answered by the test, by the host asked. A log with a block timestamp is answered with it (`blockTimestamp`), as
/// Monad's endpoints answer. With `clampedAt`, a host whose node is behind the chain's head answers its own head, and a
/// range past it CLAMPED, as rpc4, rpc3 and rpc1 answer one (measured 2026-10-08/09): the logs up to its node's head,
/// those past it left out, with no error. With `refusingBatches`, a host answers any JSON array (a batch of any size) with
/// HTTP 403 "Restricted JSON RPC method", as rpc1 does (2026-10-09); every request sent as an array is counted by host
/// (`batchHosts()`).
final class LogsStub: URLProtocol {
    struct Range: Hashable, Sendable {
        let from: UInt64
        let to: UInt64
        var span: UInt64 { to - from + 1 }
        func contains(_ block: UInt64) -> Bool { (from...to).contains(block) }
    }

    enum Failure: Sendable, CustomStringConvertible {
        case error(code: Int, message: String)
        /// No answer to the request that asked it: the connection fails.
        case noAnswer
        /// The request that asked it answered with this HTTP status and no body (429: a throttle).
        case status(Int)
        var description: String {
            switch self {
            case .error(let code, let message): return "\(code) \(message)"
            case .noAnswer: return "no answer"
            case .status(let code): return "HTTP \(code)"
            }
        }
    }

    typealias Rule = @Sendable (Range) -> Failure?
    /// Answers a call that isn't `eth_getLogs`, by host, method and params: nil leaves it to the stub.
    typealias Answer = @Sendable (String, String, JSON) -> JSON?
    /// A rule by host as well (`LogsRouter` tests): consulted before `rule`.
    typealias HostRule = @Sendable (String, Range) -> Failure?

    static let url = URL(string: "https://rpc1.logs-stub.invalid")!
    static let rpc3 = URL(string: "https://rpc3.logs-stub.invalid")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var head: UInt64 = 0
    nonisolated(unsafe) private static var chainLogs: [Log] = []
    nonisolated(unsafe) private static var rule: Rule = { _ in nil }
    nonisolated(unsafe) private static var hostRule: HostRule?
    nonisolated(unsafe) private static var askedHosts: [String] = []
    /// Every head read gets no answer (`HistoryStoreTests`).
    nonisolated(unsafe) static var failHead = false
    nonisolated(unsafe) private static var asked: [Range] = []
    nonisolated(unsafe) private static var batchSpan: UInt64?
    nonisolated(unsafe) private static var singleErrorStatus = 200
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var askedAddresses: [String?] = []
    nonisolated(unsafe) private static var latency: TimeInterval = 0
    nonisolated(unsafe) private static var logCap: Int?
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var mostInFlight = 0
    /// The block the stub wallet sent its first transaction in (`eth_getTransactionCount` answers 1 from it on); nil
    /// says it never did.
    nonisolated(unsafe) private static var firstTransaction: UInt64?
    nonisolated(unsafe) private static var answer: Answer?
    /// Requests asking a range `holding` matches wait, unanswered, until `release()` (or the next `install`), counted in
    /// `held()`: a test holds a scan at a point of its choosing, whatever the machine's pace.
    nonisolated(unsafe) private static var holding: (@Sendable (Range) -> Bool)?
    nonisolated(unsafe) private static var waiting = 0
    private static let released = NSCondition()
    /// By host: the head of the node answering it, behind the chain's (`clampedAt`).
    nonisolated(unsafe) private static var nodeHeads: [String: UInt64] = [:]
    /// Hosts answering any JSON array with HTTP 403 (`refusingBatches`), and the host of every request sent as one.
    nonisolated(unsafe) private static var batchRefusers: Set<String> = []
    nonisolated(unsafe) private static var batched: [String] = []

    /// `latency`: how long each request takes to answer, so requests sent together overlap (`maxInFlight()`). `logCap`: a
    /// range matching more logs is refused as rpc1 refuses one over its 10K, naming the range from its start that fits.
    static func install(head: UInt64, logs: [Log] = [], batchSpan: UInt64? = nil, singleErrorStatus: Int = 200, latency: TimeInterval = 0,
                        logCap: Int? = nil, firstTransaction: UInt64? = nil, hostRule: HostRule? = nil, answer: Answer? = nil,
                        holding: (@Sendable (Range) -> Bool)? = nil, clampedAt: [String: UInt64] = [:], refusingBatches: Set<String> = [], rule: @escaping Rule) {
        released.lock()
        self.holding = holding
        released.broadcast()
        released.unlock()
        lock.lock(); defer { lock.unlock() }
        self.answer = answer
        self.head = head
        chainLogs = logs
        self.batchSpan = batchSpan
        self.singleErrorStatus = singleErrorStatus
        self.latency = latency
        self.logCap = logCap
        self.firstTransaction = firstTransaction
        self.rule = rule
        self.hostRule = hostRule
        nodeHeads = clampedAt
        batchRefusers = refusingBatches
        batched = []
        failHead = false
        asked = []
        askedAddresses = []
        askedHosts = []
        requestCount = 0
        inFlight = 0
        mostInFlight = 0
    }

    /// The host of every request sent as a JSON array (a batch), in order.
    static func batchHosts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return batched
    }

    /// The address each range in `queries()` asked for, in the same order.
    static func addresses() -> [Address?] {
        lock.lock(); let asked = askedAddresses; lock.unlock()
        return asked.map { $0.flatMap(Address.init) }
    }

    /// The host each range in `queries()` was asked of, in the same order.
    static func hosts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return askedHosts
    }

    /// The most requests that were being answered at once.
    static func maxInFlight() -> Int {
        lock.lock(); defer { lock.unlock() }
        return mostInFlight
    }

    /// Lets every request `holding` held through, and holds no more.
    static func release() {
        released.lock()
        holding = nil
        released.broadcast()
        released.unlock()
    }

    /// How many requests `holding` holds now.
    static func held() -> Int {
        released.lock(); defer { released.unlock() }
        return waiting
    }

    /// How many requests were made.
    static func requests() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    /// Every range asked, in order.
    static func queries() -> [Range] {
        lock.lock(); defer { lock.unlock() }
        return asked
    }

    static func rpc(url: URL = LogsStub.url) -> RPCClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return RPCClient(url: url, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let decoded = (try? JSONDecoder().decode(JSON.self, from: Self.body(request))) ?? .null
        let calls = decoded.array ?? [decoded]
        Self.lock.lock()
        Self.requestCount += 1
        Self.inFlight += 1
        Self.mostInFlight = max(Self.mostInFlight, Self.inFlight)
        let latency = Self.latency
        Self.lock.unlock()
        Self.waitWhileHeld(calls)
        if latency > 0 { Thread.sleep(forTimeInterval: latency) }
        defer { Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock() }
        // Every call is recorded, even in a request that is to get no answer.
        var spent: UInt64 = 0
        let host = request.url?.host() ?? ""
        // A batch, of any size, to a host that refuses one (rpc1): HTTP 403, the calls unread.
        if decoded.array != nil {
            Self.lock.lock(); Self.batched.append(host); let refused = Self.batchRefusers.contains(host); Self.lock.unlock()
            if refused {
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                // not localized: rpc1's own English, as it sends it
                let body = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"Restricted JSON RPC method"}}"#
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }
        let answers = calls.map { Self.reply($0, host: host, spent: &spent) }
        let replies = answers.compactMap { $0 }
        guard replies.count == answers.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if let code = replies.lazy.compactMap({ $0["httpStatus"].number }).first {
            let response = HTTPURLResponse(url: request.url!, statusCode: Int(code), httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let body = (try? JSONEncoder().encode(decoded.array == nil ? replies[0] : .array(replies))) ?? Data()
        Self.lock.lock(); let errorStatus = Self.singleErrorStatus; Self.lock.unlock()
        let status = decoded.array == nil && !replies[0]["error"].isNull ? errorStatus : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Waits while `holding` matches a range `calls` ask (`release`).
    private static func waitWhileHeld(_ calls: [JSON]) {
        let ranges = calls.filter { $0["method"].string == "eth_getLogs" }.map { call -> Range in
            let filter = call["params"][0]
            return Range(from: filter["fromBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? 0,
                         to: filter["toBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? 0)
        }
        released.lock(); defer { released.unlock() }
        guard let holding, ranges.contains(where: holding) else { return }
        waiting += 1
        while let holding = self.holding, ranges.contains(where: holding) { released.wait() }
        waiting -= 1
    }

    /// The answer to one call; nil when the request is to get no answer at all. `spent`: the blocks the ranges answered
    /// before it in the same request used (`batchSpan`).
    private static func reply(_ call: JSON, host: String, spent: inout UInt64) -> JSON? {
        let id = call["id"]
        func result(_ value: JSON) -> JSON { .object(["jsonrpc": .string("2.0"), "id": id, "result": value]) }
        func error(_ code: Int, _ message: String) -> JSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
        }
        lock.lock(); let chainHead = self.head; let logs = chainLogs; let rule = self.rule; let hostRule = self.hostRule; let budget = batchSpan; let cap = logCap; let failHead = self.failHead; let answer = self.answer; lock.unlock()
        // A host whose node is behind answers its own head, and the logs up to it only (`clampedAt`).
        lock.lock(); let nodeHead = nodeHeads[host]; lock.unlock()
        let head = nodeHead ?? chainHead
        if let answer, let method = call["method"].string, method != "eth_getLogs", let value = answer(host, method, call["params"]) { return result(value) }
        switch call["method"].string {
        case "eth_getBlockByNumber":
            if failHead { return nil }
            return result(.object(["number": .string(BigUInt(head).hexQuantity), "timestamp": .string(BigUInt(1_790_000_000).hexQuantity)]))
        case "eth_blockNumber":
            if failHead { return nil }
            return result(.string(BigUInt(head).hexQuantity))
        case "eth_getTransactionCount":
            // The nonce at a block: 1 from the first transaction's block on, 0 before it or ever.
            lock.lock(); let first = firstTransaction; lock.unlock()
            let tag = call["params"][1].string ?? "latest"
            let at = tag.hasPrefix("0x") ? BigUInt(hexQuantity: tag).map { UInt64($0) } ?? head : head
            return result(.string(BigUInt(first.map { at >= $0 ? 1 : 0 } ?? 0).hexQuantity))
        case "eth_getLogs":
            let filter = call["params"][0]
            let from = filter["fromBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? 0
            let to = filter["toBlock"].string.flatMap { BigUInt(hexQuantity: $0) }.map { UInt64($0) } ?? head
            let range = Range(from: from, to: to)
            lock.lock(); asked.append(range); askedAddresses.append(filter["address"].string); askedHosts.append(host); lock.unlock()
            if let budget {
                guard spent + range.span <= budget else { return error(-32062, "Block range is too large") }
                spent += range.span
            }
            switch hostRule?(host, range) ?? rule(range) {
            case .error(let code, let message)?: return error(code, message)
            case .noAnswer?: return nil
            case .status(let code)?: return .object(["httpStatus": .number(Double(code))])
            case nil: break
            }
            // An address or a list of them; at each topic position a topic, a list of them, or anything (null).
            let addresses: [Address] = filter["address"].string.flatMap(Address.init).map { [$0] } ?? (filter["address"].array ?? []).compactMap { $0.string.flatMap(Address.init) }
            let topics: [[Data]?] = (filter["topics"].array ?? []).map { position in
                if let one = position.string { return Data(hex: one).map { [$0] } }
                if let list = position.array { return list.compactMap { $0.string.flatMap { Data(hex: $0) } } }
                return nil
            }
            // Clamped: a range past the node's head is answered up to it, the blocks past it left out with no error.
            let matching = logs.filter { log in
                (addresses.isEmpty || addresses.contains(log.address)) && range.contains(log.blockNumber) && (nodeHead.map { log.blockNumber <= $0 } ?? true)
                    && topics.enumerated().allSatisfy { i, topic in topic == nil || (log.topics.indices.contains(i) && topic!.contains(log.topics[i])) }
            }
            if let cap, matching.count > cap {
                let fits = matching.map(\.blockNumber).sorted()[cap] - 1
                return error(-32602, "Log response size exceeded. Based on your parameters and the response size limit, this block range should work: [\(BigUInt(from).hexQuantity), \(BigUInt(fits).hexQuantity)]")
            }
            return result(.array(matching.map(json)))
        default:
            return error(-32601, "Method not found")
        }
    }

    private static func json(_ log: Log) -> JSON {
        var object: [String: JSON] = ["address": .string(log.address.hex), "topics": .array(log.topics.map { .string($0.hexString) }), "data": .string(log.data.hexString),
                                      "blockNumber": .string(BigUInt(log.blockNumber).hexQuantity), "transactionHash": .string(log.transactionHash.hexString),
                                      "logIndex": .string(BigUInt(log.logIndex).hexQuantity)]
        if let timestamp = log.blockTimestamp { object["blockTimestamp"] = .string(BigUInt(timestamp).hexQuantity) }
        return .object(object)
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// How many times each range was asked, for a stub rule (which may run on any thread).
private final class RangeAsks: @unchecked Sendable {
    private let lock = NSLock()
    private var asks: [LogsStub.Range: Int] = [:]

    func next(_ range: LogsStub.Range) -> Int {
        lock.lock(); defer { lock.unlock() }
        asks[range, default: 0] += 1
        return asks[range]!
    }
}
