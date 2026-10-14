import BigInt
import XCTest
@testable import DyorKit

/// "Reading your history" only for what a screen needs (`WalletHistorySnapshot.covers`, `filling`, `progress`): each
/// screen waits for the scans its figures are built from, over its own period, and no more. The store reads newest
/// first, so the last day is held long before the last month, and a period's figure is final as soon as its own window
/// is read.
final class HistoryWindowTests: XCTestCase {
    private let transferTopic = ABI.eventTopic("Transfer(address,address,uint256)")
    private let wallet = Address(literal: "0x7777777777777777777777777777777777777777")
    private var walletWord: Data { wallet.data.leftPadded(to: 32) }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        super.tearDown()
    }

    // MARK: One scan

    /// A scan's window from a block: held once it is read in one piece from the head down to that block, or once the scan
    /// has read its whole window (a window starting below the floor is as read as it will ever be); the share read counts
    /// every block read in it, gaps and all.
    func testAScanHoldsAWindowReadInOnePieceWithTheHead() {
        let entry = HistoryEntry(covered: [100...200, 300...500], head: 500, floor: 50)
        let status = HistoryStatus(entry)
        XCTAssertEqual(status.coveredFrom, 300)
        XCTAssertTrue(status.holds(from: 300))
        XCTAssertTrue(status.holds(from: 450), "a nearer window")
        XCTAssertFalse(status.holds(from: 250), "a gap below")
        XCTAssertFalse(status.holds(from: nil), "the whole window isn't read")
        XCTAssertFalse(status.holds(from: 10), "nor what starts below the floor")

        XCTAssertEqual(status.progress(from: 400), 1, "every block from 400 to the head read")
        XCTAssertEqual(status.progress(from: 250), 201.0 / 251.0, accuracy: 1e-9, "300…500 of 250…500")
        XCTAssertEqual(status.progress(from: 150), (51.0 + 201.0) / 351.0, accuracy: 1e-9, "150…200 and 300…500 of 150…500")
        XCTAssertEqual(status.progress(from: nil), entry.progress, "the whole window")
        XCTAssertEqual(status.progress(from: 50), entry.progress, "from the floor: the whole window")
        XCTAssertEqual(status.progress(from: 10), entry.progress, "below the floor: the whole window")
        XCTAssertEqual(status.unreached().progress(from: 250), status.progress(from: 250), "a stalled scan keeps what it read")

        let complete = HistoryStatus(HistoryEntry(covered: [50...500], head: 500, floor: 50))
        XCTAssertTrue(complete.complete)
        XCTAssertTrue(complete.holds(from: nil))
        XCTAssertTrue(complete.holds(from: 10), "nothing below the floor is ever read")
        XCTAssertTrue(complete.holds(from: 400))
        XCTAssertEqual(complete.progress(from: 400), 1)

        // The head moved on and isn't read: nothing is held in one piece with it.
        let moved = HistoryStatus(HistoryEntry(covered: [100...200, 300...500], head: 600, floor: 50))
        XCTAssertFalse(moved.holds(from: 550))
        XCTAssertEqual(moved.progress(from: 550), 0)
        XCTAssertEqual(moved.progress(from: 450), 51.0 / 151.0, accuracy: 1e-9)

        // A window that starts after the scan's head (a head read before the window began): read once the head is.
        XCTAssertTrue(status.holds(from: 700))
        XCTAssertEqual(status.progress(from: 700), 1)

        XCTAssertFalse(HistoryStatus.none.holds(from: nil))
        XCTAssertFalse(HistoryStatus.none.holds(from: 1))
        XCTAssertEqual(HistoryStatus.none.progress(from: 1), 0)
    }

    /// The store reads down from the head, newest first: after one short refresh the last blocks are held, and a window
    /// over them is final, while the scan's whole window still reads on.
    func testAShortRefreshHoldsTheNewestBlocksFirst() async {
        LogsStub.install(head: 200_000) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let router = LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                                gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 1)
        let store = HistoryStore(router: router, directory: nil)
        let scan = HistoryScan(id: "transfers-in", query: LogsQuery(address: nil, topics: [transferTopic, nil, walletWord]), floor: .blocks(100_000))
        let entry = await store.refresh(scan, wallet: wallet, budget: LogsBudget(requests: 1, seconds: 10))
        XCTAssertEqual(entry.covered, [140_001...200_000], "one request: six 10,000-block ranges down from the head")
        let status = HistoryStatus(entry)
        XCTAssertFalse(status.complete)
        XCTAssertTrue(status.holds(from: 150_000), "the newest 50,000 blocks are held")
        XCTAssertEqual(status.progress(from: 150_000), 1)
        XCTAssertFalse(status.holds(from: 120_000))
        XCTAssertEqual(status.progress(from: 120_000), 60_000.0 / 80_001.0, accuracy: 1e-9)
        XCTAssertEqual(status.progress(from: nil), entry.progress)
    }

    // MARK: A screen's scans and period

    private static let head = BlockHeader(number: 10_000_000, timestamp: 1_800_000_000)
    private static let pace = 0.5
    private static let day: TimeInterval = 86_400
    /// 24 hours at the pace: 172,800 blocks.
    private static let dayBlocks = BlockClock.blocks(in: day, secondsPerBlock: pace)

    /// A scan's state, last refreshed `updated` (the default: a moment ago, so what it holds runs up to now).
    private static func status(coveredFrom: UInt64?, floor: UInt64 = 1_000_000, complete: Bool = false, progress: Double, reachedChain: Bool = true, updated: Date? = Date()) -> HistoryStatus {
        HistoryStatus(complete: complete, progress: progress, reachedChain: reachedChain, updatedAt: updated, floor: floor, head: head.number, coveredFrom: coveredFrom)
    }

    /// The transfer scans have read the last day and a bit, the launchpad scan the last eight days, fee sharing barely
    /// anything, and the Moments scan its whole window; every one of them a moment ago.
    private static func snapshot() -> WalletHistorySnapshot {
        var snapshot = WalletHistorySnapshot.empty
        snapshot.anchor = head
        snapshot.secondsPerBlock = pace
        let twoDays = head.number - 2 * dayBlocks
        snapshot.status = [
            WalletHistoryScans.transfersInId: status(coveredFrom: twoDays, progress: 0.04),
            WalletHistoryScans.transfersOutId: status(coveredFrom: twoDays, progress: 0.04),
            WalletHistoryScans.launchpadId: status(coveredFrom: head.number - 8 * dayBlocks, progress: 0.15),
            WalletHistoryScans.feeSharingId: status(coveredFrom: head.number - 100, progress: 0.01),
            WalletHistoryScans.momentsId: status(coveredFrom: 1_000_000, complete: true, progress: 1),
        ]
        return snapshot
    }

    /// A period's window starts no later than its first record: a record timed at the period's start is in it, whether its
    /// time was estimated at the snapshot's pace or is its block's own (`Log.blockTimestamp`) under a pace that changed a
    /// little — the window starts a hundredth of its length early (`periodMargin`), and a block early rather than late, no
    /// more; before the history read a head there is none.
    func testAPeriodStartsNoLaterThanItsFirstRecord() throws {
        let snapshot = Self.snapshot()
        let since = Date(timeIntervalSince1970: TimeInterval(Self.head.timestamp) - Self.day)
        XCTAssertEqual(WalletHistorySnapshot.periodMargin, 0.01)
        XCTAssertEqual(snapshot.block(since: since), Self.head.number - BlockClock.blocks(in: Self.day * 1.01, secondsPerBlock: Self.pace), "a day and a hundredth of it")
        XCTAssertEqual(snapshot.block(since: .distantPast), 0, "All: from the first block")
        XCTAssertEqual(snapshot.block(since: Date(timeIntervalSince1970: 1_900_000_000)), Self.head.number, "a date past the head: the head")
        XCTAssertNil(WalletHistorySnapshot.empty.block(since: since))
        for (pace, back) in [(0.3023, UInt64(1)), (0.3023, 285_807), (0.37, 1_000_003), (0.5, 12_345)] {
            var paced = snapshot
            paced.secondsPerBlock = pace
            let block = Self.head.number - back
            let time = BlockClock.time(of: block, anchor: Self.head, secondsPerBlock: pace)
            let start = try XCTUnwrap(paced.block(since: time))
            XCTAssertLessThanOrEqual(start, block, "a record at the period's first moment is in it (pace \(pace), \(back) back)")
            XCTAssertGreaterThanOrEqual(start + back / 100 + 2, block, "a hundredth of the window early, and a block, at most")
        }
        // A record whose time is its block's own, the pace over the day faster than the snapshot's by 0.15% (Monad's own
        // variation, measured): its block is still in the window.
        var paced = snapshot
        paced.secondsPerBlock = 0.3023
        let real = 0.3023 / 1.0015
        let first = Self.head.number - BlockClock.blocks(in: Self.day, secondsPerBlock: real)
        let start = try XCTUnwrap(paced.block(since: since))
        XCTAssertLessThanOrEqual(start, first, "the day's first block, by its own time, is in the day's window")
    }

    /// Home's Total Volume (the volume's scans) is final for 24h once those scans have read the last day, and reads on for
    /// 7 days, 30 days and All; the Portfolio, which shows fees received too, also waits for fee sharing; the Moments
    /// proceeds wait for the Moments scan alone; the activity feed's week for the swaps and fills.
    func testEachScreenWaitsForItsOwnScansOverItsOwnPeriod() {
        let snapshot = Self.snapshot()
        let now = Date(timeIntervalSince1970: TimeInterval(Self.head.timestamp))
        let day = now.addingTimeInterval(-Self.day)
        let week = now.addingTimeInterval(-7 * Self.day)
        let month = now.addingTimeInterval(-30 * Self.day)
        XCTAssertFalse(snapshot.complete)
        XCTAssertTrue(snapshot.filling, "every scan together still reads on")

        XCTAssertTrue(snapshot.covers(since: day, scans: WalletHistoryScans.volume))
        XCTAssertFalse(snapshot.filling(since: day, scans: WalletHistoryScans.volume), "no \"Reading your history\" for the last day")
        XCTAssertEqual(snapshot.progress(since: day, scans: WalletHistoryScans.volume), 1)
        XCTAssertFalse(snapshot.covers(since: week, scans: WalletHistoryScans.volume))
        XCTAssertTrue(snapshot.filling(since: week, scans: WalletHistoryScans.volume))
        XCTAssertFalse(snapshot.covers(since: month, scans: WalletHistoryScans.volume))
        XCTAssertFalse(snapshot.covers(since: nil, scans: WalletHistoryScans.volume), "All waits for every window")
        XCTAssertTrue(snapshot.filling(since: nil, scans: WalletHistoryScans.volume))

        // The week's share: the transfer scans read two of its seven days (and the hundredth before it), the launchpad
        // scan all of it, Moments all of it.
        let weekBlocks = Double(Self.head.number - snapshot.block(since: week)! + 1)
        let transfers = Double(2 * Self.dayBlocks + 1) / weekBlocks
        XCTAssertEqual(snapshot.progress(since: week, scans: WalletHistoryScans.volume), (2 * transfers + 1 + 1) / 4, accuracy: 1e-9)
        XCTAssertEqual(snapshot.progress(since: week, scans: WalletHistoryScans.activity), (2 * transfers + 1) / 3, accuracy: 1e-9)
        XCTAssertTrue(snapshot.filling(since: week, scans: WalletHistoryScans.activity), "the feed's week isn't read yet")
        XCTAssertFalse(snapshot.filling(since: day, scans: WalletHistoryScans.activity))
        XCTAssertEqual(snapshot.progress(since: nil, scans: WalletHistoryScans.volume), (0.04 + 0.04 + 0.15 + 1) / 4, accuracy: 1e-9, "All: the scans' own progress")

        // The Portfolio shows fees received: fee sharing has read only the last hundred blocks.
        XCTAssertFalse(snapshot.covers(since: day, scans: WalletHistoryScans.ids))
        XCTAssertTrue(snapshot.filling(since: day, scans: WalletHistoryScans.ids))

        // My Launchpad's fees: launchpad and fee sharing, all time; their progress alone.
        XCTAssertFalse(snapshot.covers(since: nil, scans: WalletHistoryScans.feeIncome))
        XCTAssertTrue(snapshot.filling(since: nil, scans: WalletHistoryScans.feeIncome))
        XCTAssertEqual(snapshot.progress(since: nil, scans: WalletHistoryScans.feeIncome), (0.15 + 0.01) / 2, accuracy: 1e-9)

        // My Moments' proceeds: the Moments scan alone, read in full whatever the others still read.
        XCTAssertTrue(snapshot.covers(since: nil, scans: WalletHistoryScans.proceeds))
        XCTAssertFalse(snapshot.filling(since: nil, scans: WalletHistoryScans.proceeds))
        XCTAssertEqual(snapshot.progress(since: nil, scans: WalletHistoryScans.proceeds), 1)

        // The Send list and My Holdings: transfers in alone.
        XCTAssertTrue(snapshot.filling(since: nil, scans: WalletHistoryScans.holdings))
        XCTAssertEqual(snapshot.progress(since: nil, scans: WalletHistoryScans.holdings), 0.04, accuracy: 1e-9)
    }

    /// Rounds that stopped short: a window not read isn't "Reading your history" any more (the screen says it couldn't be
    /// read, with Retry, from `unreachable`), and a window read stays read.
    func testAStalledWindowIsNotSaidToBeReading() {
        let stalled = Self.snapshot().stalled()
        let now = Date(timeIntervalSince1970: TimeInterval(Self.head.timestamp))
        XCTAssertTrue(stalled.unreachable)
        XCTAssertFalse(stalled.filling(since: now.addingTimeInterval(-7 * Self.day), scans: WalletHistoryScans.volume))
        XCTAssertFalse(stalled.covers(since: now.addingTimeInterval(-7 * Self.day), scans: WalletHistoryScans.volume), "never passed off as read")
        XCTAssertTrue(stalled.covers(since: now.addingTimeInterval(-Self.day), scans: WalletHistoryScans.volume), "the last day was read")
        XCTAssertTrue(stalled.covers(since: nil, scans: WalletHistoryScans.proceeds))
    }

    /// Before any scan read a head nothing is covered, every scan that can reach the chain is reading, and nothing is
    /// read; an empty set of scans waits for nothing.
    func testNothingIsCoveredBeforeAHeadWasRead() {
        let empty = WalletHistorySnapshot.empty
        let now = Date()
        for since in [now.addingTimeInterval(-Self.day), nil] {
            XCTAssertFalse(empty.covers(since: since, scans: WalletHistoryScans.volume))
            XCTAssertTrue(empty.filling(since: since, scans: WalletHistoryScans.volume))
            XCTAssertEqual(empty.progress(since: since, scans: WalletHistoryScans.volume), 0)
        }
        XCTAssertTrue(Self.snapshot().covers(from: 0, scans: []))
        XCTAssertFalse(Self.snapshot().filling(from: 0, scans: []))
        XCTAssertEqual(Self.snapshot().progress(from: 0, scans: []), 1)
    }

    /// Never "100%" while part of a window is unread, however small the part and however lately the scan read: a window
    /// of millions of blocks with its newest few hundred unread — the server's history taken in up to its trust margin,
    /// or the newest 600 left for rpc2 while it rests — read 0.9999, printed "Reading your history… 100%" on Home, the
    /// Portfolio, My Launchpad and My Moments. Read up to now, it is 1.
    func testAWindowWithItsNewestBlocksUnreadIsNeverAHundredPercent() {
        let head: UInt64 = 111_727_140
        let now = Date()
        func snapshot(_ covered: [ClosedRange<UInt64>]) -> WalletHistorySnapshot {
            var snapshot = WalletHistorySnapshot.empty
            for id in WalletHistoryScans.ids { snapshot.status[id] = HistoryStatus(HistoryEntry(covered: covered, head: head, headTimestamp: 1, floor: 0, updatedAt: now)) }
            return snapshot
        }
        let margin = snapshot([0...(head - 1_200)])
        XCTAssertGreaterThan(margin.status(WalletHistoryScans.transfersInId).progress, 0.9999)
        XCTAssertEqual(margin.progress(from: nil, scans: WalletHistoryScans.volume, now: now), WalletHistorySnapshot.readingCap, "All")
        XCTAssertEqual(margin.progress(from: head - 1_000_000, scans: WalletHistoryScans.volume, now: now), WalletHistorySnapshot.readingCap, "a month or so")
        XCTAssertEqual(margin.progress(from: head - 1_000, scans: WalletHistoryScans.volume, now: now), 0, "a window inside the unread blocks")
        XCTAssertFalse(margin.covers(from: head - 1_000_000, scans: WalletHistoryScans.volume, now: now))
        let read = snapshot([0...head])
        XCTAssertEqual(read.progress(from: nil, scans: WalletHistoryScans.volume, now: now), 1)
        XCTAssertEqual(read.progress(from: head - 1_000_000, scans: WalletHistoryScans.volume, now: now), 1)
        XCTAssertEqual(read.progress(from: nil, scans: WalletHistoryScans.volume, now: now.addingTimeInterval(3_600)), WalletHistorySnapshot.readingCap, "read an hour ago: not up to now")
    }

    // MARK: The screens

    /// Each screen says "Reading your history" for its own scans over its own window, with their progress: Home's Total
    /// Volume and the Portfolio per period (Home over the volume's scans, the Portfolio over every scan, as it shows fees
    /// received), the activity feed over its week, My Launchpad's fees over launchpad and fee sharing, My Moments'
    /// proceeds over the Moments scan, and the holdings, the Send list and its wait over transfers in.
    func testEachScreenAsksAboutItsOwnScans() throws {
        let source = DocsLinksTests.appSource
        let home = try source("Home/HomeView.swift")
        XCTAssertTrue(home.contains("if liveVolume, env.history.snapshot.read, env.portfolio.historyFilling(router.period, scans: WalletHistoryScans.volume) {"),
                      "not before the history kept on the phone is read, nor beside a saved figure (said to be saved instead)")
        XCTAssertTrue(home.contains("NumberStyle.percent(env.portfolio.historyProgress(router.period, scans: WalletHistoryScans.volume) * 100"))
        let portfolio = try source("Portfolio/PortfolioView.swift")
        XCTAssertTrue(portfolio.contains("} else if model.historyFilling(router.period, scans: WalletHistoryScans.ids) {"))
        XCTAssertTrue(portfolio.contains("NumberStyle.percent(model.historyProgress(router.period, scans: WalletHistoryScans.ids) * 100"))
        let model = try source("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(model.contains("history.filling(since: historyStart(period), scans: scans)"))
        XCTAssertTrue(model.contains("history.progress(since: historyStart(period), scans: scans)"))
        XCTAssertTrue(model.contains("period.seconds == nil ? nil : period.since()"), "All: every scan's whole window")
        let activity = try source("Profile/RecentActivityView.swift")
        XCTAssertTrue(activity.contains("historyFilling = snapshot.filling(since: since, scans: WalletHistoryScans.activity)"))
        XCTAssertTrue(activity.contains("historyProgress = snapshot.progress(since: since, scans: WalletHistoryScans.activity)"))
        let launchpad = try source("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(launchpad.contains("let filling = snapshot.filling(since: nil, scans: WalletHistoryScans.feeIncome)"))
        XCTAssertTrue(launchpad.contains("incomeProgress = snapshot.progress(since: nil, scans: WalletHistoryScans.feeIncome)"))
        let moments = try source("Moments/MomentsPortfolioView.swift")
        XCTAssertTrue(moments.contains("private var proceedsReading: Bool { env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.proceeds) }"))
        XCTAssertTrue(moments.contains("private var proceedsProgress: Double { env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.proceeds) }"))
        let assets = try source("Portfolio/AssetsModel.swift")
        XCTAssertTrue(assets.contains("historyFilling = !(read?.complete ?? false) && env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.holdings)"))
        XCTAssertTrue(assets.contains("historyProgress = env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.holdings)"))
        let send = try source("Profile/ProfileView.swift")
        XCTAssertTrue(send.contains("} else if !complete, env.history.snapshot.filling(since: nil, scans: WalletHistoryScans.holdings) {"))
        XCTAssertTrue(send.contains("NumberStyle.percent(env.history.snapshot.progress(since: nil, scans: WalletHistoryScans.holdings) * 100"))
        let tokens = try source("Wallet/WalletTokens.swift")
        XCTAssertTrue(tokens.contains("while env.history.wallet == address, env.history.snapshot.readingWindow(scans: WalletHistoryScans.holdings),"),
                      "the token list waits for the transfer scan's window only, never for a round to read the blocks since a head read from the device")
        XCTAssertFalse(tokens.contains("snapshot.filling(since: nil, scans: WalletHistoryScans.holdings)"))
    }

    /// No screen reads the whole history's `filling` or `progress` any more: only the history model's own rounds do, and
    /// the venue scan, which waits for every scan to stop reading before it spends the gate.
    func testNoScreenWaitsForEveryScan() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let whole = try NSRegularExpression(pattern: #"snapshot\.(progress|filling)\b(?!\()|history\.filling\b(?!\()"#)
        var found: [String: Int] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        for file in files {
            let code = String(TradeStringsTests.uncommented(Array(try String(contentsOf: file, encoding: .utf8))))
            let count = whole.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            if count > 0 { found[file.lastPathComponent] = count }
        }
        XCTAssertEqual(found, ["HistoryModel.swift": 1, "RootView.swift": 2])
    }

    // MARK: Up to now

    /// Every window ends now. A history read from the device at launch, last refreshed hours ago, holds none of them —
    /// however far down it was read, and whether or not it was complete — until a round reads it again: its windows are
    /// still being read ("Reading your history…", never 100%), never a figure as final ("$0.00" for a day it never read).
    /// Its head is old, so every period counted back from it starts at it, past what it read; the round that reads the new
    /// blocks makes them final.
    func testAHistoryReadFromTheDeviceIsNotUpToNow() {
        let hoursAgo = Date().addingTimeInterval(-3 * 3_600)
        var onDisk = Self.snapshot()
        for (id, status) in onDisk.status {
            onDisk.status[id] = HistoryStatus(complete: status.complete, progress: status.progress, reachedChain: true, updatedAt: hoursAgo, floor: status.floor, head: status.head,
                                              coveredFrom: status.coveredFrom)
        }
        let now = Date(timeIntervalSince1970: TimeInterval(Self.head.timestamp))
        let day = now.addingTimeInterval(-Self.day)
        // A day after the head: the period starts at the head itself.
        let tomorrow = now.addingTimeInterval(Self.day)
        XCTAssertEqual(onDisk.block(since: tomorrow.addingTimeInterval(-Self.day)), Self.head.number)
        for since in [day, tomorrow.addingTimeInterval(-Self.day), nil] {
            XCTAssertFalse(onDisk.covers(since: since, scans: WalletHistoryScans.volume), "\(String(describing: since))")
            XCTAssertTrue(onDisk.filling(since: since, scans: WalletHistoryScans.volume))
            XCTAssertLessThan(onDisk.progress(since: since, scans: WalletHistoryScans.volume), 1)
        }
        XCTAssertFalse(onDisk.covers(since: nil, scans: WalletHistoryScans.proceeds), "a complete scan, hours old")
        XCTAssertTrue(onDisk.filling(since: nil, scans: WalletHistoryScans.proceeds))
        XCTAssertEqual(onDisk.progress(since: nil, scans: WalletHistoryScans.proceeds), WalletHistorySnapshot.readingCap)
        XCTAssertFalse(onDisk.covers(from: Self.head.number + 100, scans: WalletHistoryScans.proceeds), "a window past the head isn't read")
        XCTAssertLessThan(onDisk.progress(from: Self.head.number + 100, scans: WalletHistoryScans.proceeds), 1)
        // The token list waits for the window alone: a complete transfer scan holds it up no more.
        XCTAssertFalse(Self.snapshot().readingWindow(scans: WalletHistoryScans.proceeds))
        XCTAssertFalse(onDisk.readingWindow(scans: WalletHistoryScans.proceeds))
        XCTAssertTrue(onDisk.readingWindow(scans: WalletHistoryScans.holdings), "transfers in hasn't read its window")

        // Read again a moment ago: what it read is final again.
        XCTAssertTrue(Self.snapshot().covers(since: day, scans: WalletHistoryScans.volume))
        XCTAssertTrue(Self.snapshot().covers(since: nil, scans: WalletHistoryScans.proceeds))
        // Recent means within a top-up and a round, with room to spare; the rounds' own cadence keeps a complete history
        // inside it.
        let edge = Date()
        let justNow = HistoryStatus(complete: true, progress: 1, reachedChain: true, updatedAt: edge.addingTimeInterval(-HistoryCadence.freshFor), floor: 1, head: 2, coveredFrom: 1)
        XCTAssertTrue(justNow.isRecent(at: edge))
        XCTAssertFalse(justNow.isRecent(at: edge.addingTimeInterval(1)))
        XCTAssertGreaterThan(HistoryCadence.freshFor, HistoryCadence.topUpPause + HistoryCadence.roundSeconds)
        XCTAssertFalse(HistoryStatus.none.isCurrent(at: edge), "never read")
        XCTAssertTrue(justNow.isCurrent(through: 2, at: .distantFuture), "through a block: its head, whenever it was read")
        XCTAssertFalse(justNow.isCurrent(through: 3, at: edge))
    }

    /// Rounds that stopped short: a complete scan not read lately is said not to have reached the chain too, so its windows
    /// say they couldn't be read, with Retry, rather than "Reading your history…" while nothing reads.
    func testAStalledHistoryNotReadLatelyCouldntBeRead() {
        var snapshot = Self.snapshot()
        let moments = snapshot.status(WalletHistoryScans.momentsId)
        snapshot.status[WalletHistoryScans.momentsId] = HistoryStatus(complete: true, progress: 1, reachedChain: true, updatedAt: Date().addingTimeInterval(-3_600),
                                                                      floor: moments.floor, head: moments.head, coveredFrom: moments.coveredFrom)
        XCTAssertTrue(snapshot.filling(since: nil, scans: WalletHistoryScans.proceeds))
        let stalled = snapshot.stalled()
        XCTAssertFalse(stalled.status(WalletHistoryScans.momentsId).reachedChain)
        XCTAssertFalse(stalled.filling(since: nil, scans: WalletHistoryScans.proceeds))
        XCTAssertFalse(stalled.covers(since: nil, scans: WalletHistoryScans.proceeds))
        XCTAssertTrue(stalled.unreachable)
        XCTAssertTrue(Self.snapshot().stalled().status(WalletHistoryScans.momentsId).reachedChain, "read lately: kept as it was")
    }

    /// The history keeps the pace its records were timed at, so a period's start block is cut where they are.
    func testTheHistoryKeepsThePaceItsRecordsWereTimedAt() async {
        let head = LaunchpadAddresses.feeHistoryStart + 50_000
        LogsStub.install(head: head) { _ in nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        let router = LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                                gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 4)
        let logsClient = LogsStub.rpc()
        let clock = BlockClock(rpc: logsClient, measured: 0.4)
        let service = WalletHistoryService(store: HistoryStore(router: router, directory: nil), swapHistory: SwapHistoryService(rpc: logsClient, clock: clock), clock: clock,
                                           stacks: { [LaunchpadAddresses.monadMainnet] }, cohorts: [MomentsAddresses.monadMainnet])
        let snapshot = await service.refresh(wallet: wallet, budget: LogsBudget(requests: 200, seconds: 30), curves: [], decimals: [:])
        XCTAssertEqual(snapshot.anchor?.number, head)
        XCTAssertEqual(snapshot.secondsPerBlock, 0.4)
        XCTAssertTrue(snapshot.covers(since: nil, scans: WalletHistoryScans.ids), "every scan read its window: \(snapshot.status)")
        XCTAssertFalse(snapshot.filling(since: nil, scans: WalletHistoryScans.ids))
        XCTAssertEqual(snapshot.progress(since: nil, scans: WalletHistoryScans.ids), 1)
    }
}
