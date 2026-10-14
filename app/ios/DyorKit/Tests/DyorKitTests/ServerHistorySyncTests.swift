import BigInt
import XCTest
@testable import DyorKit

/// When the app reads the server's history of a wallet and how it keeps checking it (the server contract's §16
/// "Switches", "When to read" and "Trust"): the plan from what the device holds alone (`ServerHistoryPlan`), the daily
/// spot check (`ServerHistorySpotCheck`), what is kept in UserDefaults (`ServerHistoryDefaults`), the reads, polls and
/// checks against stubs (`ServerHistorySync`), and the app's wiring of them (`HistoryModel`, `AppEnvironment`, the erase).
final class ServerHistorySyncTests: XCTestCase {
    private let wallet = HistoryDocs.wallet
    private let head = HistoryDocs.head
    private var directory: URL!
    private var suite: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("server-history-tests-\(UUID().uuidString)")
        suite = "server-history-tests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        LogsStub.install(head: 0) { _ in nil }
        try? FileManager.default.removeItem(at: directory)
        userDefaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: When to read

    /// A complete entry from `floor` to `head`, its head's block at `timestamp`.
    private func complete(_ floor: UInt64 = 100, head: UInt64, timestamp: Int = 1_000) -> HistoryEntry {
        HistoryEntry(covered: [floor...head], head: head, headTimestamp: timestamp, floor: floor)
    }

    /// The read before the rounds: the whole history while any of the five scans isn't complete on the device; a top-up
    /// from 20 blocks below the oldest scan's newest block when every one is but one lies more than 60,000 behind the
    /// head the chain has reached; none otherwise, none within a minute of the last read, and none with no head known.
    func testTheReadBeforeTheRounds() {
        func read(_ entries: [String: HistoryEntry], head: UInt64? = nil, since: TimeInterval? = nil) -> ServerHistoryPlan.Read? {
            ServerHistoryPlan.read(entries: entries, estimatedHead: head, sinceLastRead: since)
        }
        XCTAssertEqual(read([:]), .full, "nothing held")
        var entries: [String: HistoryEntry] = [:]
        for id in WalletHistoryScans.ids { entries[id] = .empty }
        XCTAssertEqual(read(entries), .full, "a fresh install")
        for id in WalletHistoryScans.ids { entries[id] = complete(head: 1_000_000) }
        entries[WalletHistoryScans.transfersInId] = HistoryEntry(covered: [500_000...1_000_000], head: 1_000_000, headTimestamp: 1_000, floor: 100)
        XCTAssertEqual(read(entries, head: 1_000_001), .full, "one scan not complete")
        XCTAssertNil(read(entries, since: 59), "within a minute of the last read")
        XCTAssertEqual(read(entries, since: 60), .full)
        XCTAssertEqual(read(entries, since: -30), .full, "a clock set back counts as no read")

        entries[WalletHistoryScans.transfersInId] = complete(head: 1_000_000)
        XCTAssertNil(read(entries, head: 1_000_500), "every scan complete and near the head: the rounds read the new blocks")
        XCTAssertNil(read(entries, head: 1_060_000), "60,000 behind is not more than 60,000")
        XCTAssertEqual(read(entries, head: 1_060_001), .topUp(from: 999_980))
        XCTAssertNil(read(entries, head: nil), "no head known: no top-up")
        XCTAssertNil(read(entries, head: 1_060_001, since: 10))
        entries[WalletHistoryScans.momentsId] = complete(head: 990_000)
        XCTAssertEqual(read(entries, head: 1_060_001), .topUp(from: 989_980), "from the oldest scan's newest block")
        // A complete entry's newest block is the one read with the head (`through`).
        XCTAssertEqual(complete(head: 990_000).through, 990_000)
        XCTAssertEqual(read([WalletHistoryScans.momentsId: complete(0, head: 10)], head: 70_011), .topUp(from: 0), "never below genesis")

        // Missing only blocks within the trust margin below its head — the newest 600 left for rpc2 while it rests, or what
        // a read of the server stops short of — an entry holds all the server could add: no full read again.
        for id in WalletHistoryScans.ids { entries[id] = complete(head: 1_000_000) }
        entries[WalletHistoryScans.transfersInId] = HistoryEntry(covered: [100...999_400], head: 1_000_000, headTimestamp: 1_000, floor: 100)
        XCTAssertTrue(ServerHistoryPlan.holdsTheServers(entries[WalletHistoryScans.transfersInId]!))
        XCTAssertFalse(entries[WalletHistoryScans.transfersInId]!.complete)
        XCTAssertNil(read(entries, head: 1_000_500), "the newest 600 unread: the rounds' to read, not a full read of the server's")
        XCTAssertEqual(read(entries, head: 1_060_000), .topUp(from: 999_380), "far behind: a top-up from 20 below the newest block read from the floor")
        entries[WalletHistoryScans.transfersInId] = HistoryEntry(covered: [100...998_800], head: 1_000_000, headTimestamp: 1_000, floor: 100)
        XCTAssertTrue(ServerHistoryPlan.holdsTheServers(entries[WalletHistoryScans.transfersInId]!), "1,200 below the head: the margin itself")
        entries[WalletHistoryScans.transfersInId] = HistoryEntry(covered: [100...998_799], head: 1_000_000, headTimestamp: 1_000, floor: 100)
        XCTAssertEqual(read(entries, head: 1_000_500), .full, "a block below the margin unread: the server may have it")
        entries[WalletHistoryScans.transfersInId] = HistoryEntry(covered: [100...500_000, 500_002...1_000_000], head: 1_000_000, headTimestamp: 1_000, floor: 100)
        XCTAssertEqual(read(entries, head: 1_000_500), .full, "a gap far below the head")
        XCTAssertNil(ServerHistoryPlan.readUpTo(HistoryEntry(covered: [200...1_000], head: 1_000, headTimestamp: 1, floor: 100)), "the floor unread")
        XCTAssertFalse(ServerHistoryPlan.holdsTheServers(.empty))
        XCTAssertTrue(ServerHistoryPlan.holdsTheServers(HistoryEntry(covered: [0...0], head: 500, headTimestamp: 1, floor: 0)), "a head within the margin of genesis")
    }

    /// The head the chain has reached: the newest head an entry read, moved on by the time since its block at the pace;
    /// the head itself when its block is in the future (a clock behind); nil when no entry read one.
    func testTheChainsHeadIsEstimatedFromTheNewestRead() {
        let older = HistoryEntry(head: 1_000, headTimestamp: 1_000)
        let newer = HistoryEntry(head: 2_000, headTimestamp: 1_100)
        let now = Date(timeIntervalSince1970: 1_130)
        XCTAssertEqual(ServerHistoryPlan.estimatedHead([older, newer], now: now, secondsPerBlock: 0.5), 2_060, "1,260 for the older; 2,060 for the newer")
        XCTAssertEqual(ServerHistoryPlan.estimatedHead([newer], now: Date(timeIntervalSince1970: 900), secondsPerBlock: 0.5), 2_000)
        XCTAssertEqual(ServerHistoryPlan.estimatedHead([newer], now: now, secondsPerBlock: 0), 2_000)
        XCTAssertNil(ServerHistoryPlan.estimatedHead([HistoryEntry.empty, HistoryEntry(head: 5)], now: now, secondsPerBlock: 0.5), "a head without its time")
        XCTAssertNil(ServerHistoryPlan.estimatedHead([HistoryEntry](), now: now, secondsPerBlock: 0.5))
    }

    /// The entries as `read` would leave them taken in: each scan's adoptable blocks, at or above its floor, the server's
    /// head — except `overrides`.
    private func adoptedEntries(_ read: ServerHistoryRead, scans: [HistoryScan], overrides: [String: HistoryEntry] = [:]) -> [String: HistoryEntry] {
        var entries: [String: HistoryEntry] = [:]
        for scan in scans {
            if let entry = overrides[scan.id] { entries[scan.id] = entry; continue }
            guard let server = read.scan(scan), let serverHead = server.head else { entries[scan.id] = .empty; continue }
            let floor = scan.floor.block(head: serverHead)
            entries[scan.id] = HistoryEntry(covered: BlockRanges.intersect(server.adoptable, floor...UInt64.max), head: serverHead, headTimestamp: HistoryDocs.headTimestamp,
                                            floor: floor)
        }
        return entries
    }

    /// What a poll watches: a scan the device lacks that the server is still filling in, or that the read stopped before,
    /// or of which it proves blocks the device doesn't hold; never one the device holds whole, one served whole and taken
    /// in, one the server doesn't serve, nor one whose filter the server's doesn't take.
    func testWhatAPollWatches() async throws {
        let scans = HistoryDocs.scans()
        let full = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client().read(wallet: wallet)
        let taken = adoptedEntries(full, scans: scans)
        XCTAssertFalse(taken[WalletHistoryScans.launchpadId]!.complete, "the margin below the head is the device's to read")
        XCTAssertEqual(ServerHistoryPlan.watching(full, scans: scans, entries: taken), [WalletHistoryScans.transfersInId], "the one the server is still filling in")

        // The device holding it whole: nothing to watch.
        var whole = taken
        whole[WalletHistoryScans.transfersInId] = complete(0, head: head + 300)
        XCTAssertEqual(ServerHistoryPlan.watching(full, scans: scans, entries: whole), [])
        // Nothing held yet: everything the read proves is beyond the device.
        XCTAssertEqual(ServerHistoryPlan.watching(full, scans: scans, entries: [:]), [], "no entry to compare: not watched")
        let none = Dictionary(uniqueKeysWithValues: scans.map { ($0.id, HistoryEntry.empty) })
        XCTAssertEqual(ServerHistoryPlan.watching(full, scans: scans, entries: none), Set(WalletHistoryScans.ids), "nothing taken in yet: every scan")

        // The app's fee-sharing filter on a contract the server doesn't know yet: the server's doesn't take it.
        let wider = scans.map { scan -> HistoryScan in
            scan.id == WalletHistoryScans.feeSharingId
                ? HistoryScan(id: scan.id, query: LogsQuery(addresses: scan.query.addresses + [HistoryDocs.counterparty], topics: scan.query.topics), floor: scan.floor) : scan
        }
        XCTAssertEqual(ServerHistoryPlan.watching(full, scans: wider, entries: none), Set(WalletHistoryScans.ids).subtracting([WalletHistoryScans.feeSharingId]))

        // A read cut short at its first page: the transfer scans it didn't finish are watched though the server has them whole.
        let short = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client(.init(pages: 1, seconds: 15)).read(wallet: wallet)
        XCTAssertFalse(short.scan(HistoryDocs.scan(WalletHistoryScans.transfersOutId))!.finished)
        XCTAssertEqual(ServerHistoryPlan.watching(short, scans: scans, entries: adoptedEntries(short, scans: scans)),
                       [WalletHistoryScans.transfersOutId, WalletHistoryScans.transfersInId])

        // A wallet the server doesn't track: its transfers are the device's alone.
        var globals: [String: [String: Any]] = [:]
        for id in [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId] { globals[id] = HistoryDocs.account(id, complete: false) }
        let untracked = try await HistoryPagesStub(pages: [nil: HistoryDocs.data(HistoryDocs.page(tracked: false, scans: globals, next: nil))]).client().read(wallet: wallet)
        XCTAssertEqual(ServerHistoryPlan.watching(untracked, scans: scans, entries: none), [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId])
    }

    /// The scans' account alone, compared with what the device holds.
    private func metadata(_ accounts: [String: [String: Any]]) async throws -> ServerHistoryRead {
        try await HistoryPagesStub(pages: [nil: HistoryDocs.data(HistoryDocs.page(scans: accounts, next: nil))]).client().metadata(wallet: wallet)
    }

    /// What a poll reads: the blocks the scans' account proves of the scans watched that the device doesn't hold, at or
    /// above each scan's floor, merged across scans, the newest three, newest first — never the margin below the head,
    /// never a hole, never a scan not watched.
    func testWhatAPollReads() async throws {
        let scans = HistoryDocs.scans()
        let incoming = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        let floor = incoming.floor.block(head: head)
        // The hole the full read left is covered now.
        let healed = try await metadata([WalletHistoryScans.transfersInId: HistoryDocs.account(WalletHistoryScans.transfersInId, capFloor: 103_140_000)])
        XCTAssertTrue(try XCTUnwrap(healed.scan(incoming)).complete)
        let held = HistoryEntry(covered: [floor...(HistoryDocs.inHole - 1), (HistoryDocs.inHole + 1)...(head - 1_200)], head: head, headTimestamp: HistoryDocs.headTimestamp, floor: floor)
        let entries = [WalletHistoryScans.transfersInId: held]
        XCTAssertEqual(ServerHistoryPlan.newlyCovered(healed, scans: scans, entries: entries, watching: [WalletHistoryScans.transfersInId]),
                       [HistoryDocs.inHole...HistoryDocs.inHole], "the hole, and nothing below the floor nor in the margin")
        XCTAssertEqual(ServerHistoryPlan.newlyCovered(healed, scans: scans, entries: entries, watching: []), [], "not watched")
        XCTAssertEqual(ServerHistoryPlan.watching(healed, scans: scans, entries: entries), [WalletHistoryScans.transfersInId], "complete now, but the hole not taken in yet")
        var filled = held
        filled.covered = [floor...(head - 1_200)]
        XCTAssertEqual(ServerHistoryPlan.watching(healed, scans: scans, entries: [WalletHistoryScans.transfersInId: filled]), [], "nothing more to take")

        // Four gaps in transfers-in and one in transfers-out joining the newest: three ranges, newest first, merged.
        let gaps: [ClosedRange<UInt64>] = [104_000_000...104_000_009, 105_000_000...105_000_009, 106_000_000...106_000_009, 107_000_000...107_000_009]
        let many = HistoryEntry(covered: BlockRanges.subtract([floor...(head - 1_200)], gaps), head: head, headTimestamp: HistoryDocs.headTimestamp, floor: floor)
        let out = HistoryDocs.scan(WalletHistoryScans.transfersOutId)
        let outFloor = out.floor.block(head: head)
        let outHeld = HistoryEntry(covered: BlockRanges.subtract([outFloor...(head - 1_200)], [107_000_005...107_000_020]), head: head, headTimestamp: HistoryDocs.headTimestamp, floor: outFloor)
        let both = try await metadata([WalletHistoryScans.transfersInId: HistoryDocs.account(WalletHistoryScans.transfersInId),
                                       WalletHistoryScans.transfersOutId: HistoryDocs.account(WalletHistoryScans.transfersOutId)])
        XCTAssertEqual(ServerHistoryPlan.newlyCovered(both, scans: scans, entries: [WalletHistoryScans.transfersInId: many, WalletHistoryScans.transfersOutId: outHeld],
                                                      watching: [WalletHistoryScans.transfersInId, WalletHistoryScans.transfersOutId]),
                       [107_000_000...107_000_020, 106_000_000...106_000_009, 105_000_000...105_000_009])
        XCTAssertEqual(ServerHistoryPlan.pollRanges, 3)
    }

    /// The polls: a minute after the last look, within a quarter of an hour from the session's first (the last at 15:00
    /// itself); a poll that would fall past the window is none; a clock set back is no look.
    func testThePollsCadence() {
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: nil, sinceWindowOpened: nil), 0)
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: 0, sinceWindowOpened: 0), 60)
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: 45, sinceWindowOpened: 45), 15)
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: 300, sinceWindowOpened: 300), 0)
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: 10, sinceWindowOpened: 850), 50, "the last poll at 900 s")
        XCTAssertNil(ServerHistoryPlan.pollWait(sinceLastLook: 10, sinceWindowOpened: 851), "past the quarter of an hour")
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: 120, sinceWindowOpened: 900), 0, "at the quarter of an hour itself")
        XCTAssertNil(ServerHistoryPlan.pollWait(sinceLastLook: 120, sinceWindowOpened: 901))
        XCTAssertEqual(ServerHistoryPlan.pollWait(sinceLastLook: -20, sinceWindowOpened: nil), 0, "a clock set back")
        XCTAssertEqual(ServerHistoryPlan.pollWindow, 900)
        XCTAssertEqual(ServerHistoryPlan.pollInterval, 60)
        XCTAssertEqual(ServerHistoryPlan.stepSeconds, HistoryServerClient.Limits.standard.seconds + 5)
    }

    // MARK: Trust

    /// Once a day per wallet; a distrust lasts a day, and one set further off than that (a clock set back) has run out.
    func testTheSpotChecksDayAndTheDistrust() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ServerHistorySpotCheck.due(lastChecked: nil, now: now))
        XCTAssertFalse(ServerHistorySpotCheck.due(lastChecked: now.addingTimeInterval(-3_600), now: now))
        XCTAssertFalse(ServerHistorySpotCheck.due(lastChecked: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(ServerHistorySpotCheck.due(lastChecked: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(ServerHistorySpotCheck.due(lastChecked: now.addingTimeInterval(60), now: now), "a check in the future: a clock set back")

        XCTAssertFalse(ServerHistorySpotCheck.distrusted(until: nil, now: now))
        XCTAssertTrue(ServerHistorySpotCheck.distrusted(until: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(ServerHistorySpotCheck.distrusted(until: now.addingTimeInterval(86_400), now: now))
        XCTAssertFalse(ServerHistorySpotCheck.distrusted(until: now, now: now), "run out")
        XCTAssertFalse(ServerHistorySpotCheck.distrusted(until: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(ServerHistorySpotCheck.distrusted(until: now.addingTimeInterval(86_401), now: now), "longer than a day: a clock set back")
        XCTAssertEqual(ServerHistorySpotCheck.blocks, 10_000)
        XCTAssertEqual(ServerHistorySpotCheck.budget, LogsBudget(requests: 1, seconds: 15), "one request")
    }

    /// One range of at most 10,000 blocks inside what the server added, the range chosen by size and the start keeping
    /// the read inside it; a smaller range read whole; none when nothing was added.
    func testTheSpotChecksRange() {
        let adopted: [ClosedRange<UInt64>] = [1_000...1_999, 50_000...149_999]
        func pick(_ first: @escaping (ClosedRange<UInt64>) -> UInt64, _ second: @escaping (ClosedRange<UInt64>) -> UInt64) -> ClosedRange<UInt64>? {
            let dice = Dice([first, second])
            return ServerHistorySpotCheck.range(in: adopted, random: dice.roll)
        }
        XCTAssertEqual(pick({ $0.lowerBound }, { $0.lowerBound }), 1_000...1_999, "the small range, whole")
        XCTAssertEqual(pick({ _ in 999 }, { $0.upperBound }), 1_000...1_999)
        XCTAssertEqual(pick({ _ in 1_000 }, { $0.lowerBound }), 50_000...59_999, "the next block is the large range's first")
        XCTAssertEqual(pick({ $0.upperBound }, { $0.upperBound }), 140_000...149_999, "never past its end")
        XCTAssertEqual(pick({ $0.upperBound }, { _ in 77_777 }), 77_777...87_776)
        var ranges: [ClosedRange<UInt64>] = []
        for _ in 0..<200 { if let range = ServerHistorySpotCheck.range(in: adopted, random: { UInt64.random(in: $0) }) { ranges.append(range) } }
        XCTAssertEqual(ranges.count, 200)
        for range in ranges {
            XCTAssertTrue(adopted.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }, "\(range) inside")
            XCTAssertLessThanOrEqual(range.upperBound - range.lowerBound + 1, ServerHistorySpotCheck.blocks)
        }
        XCTAssertNil(ServerHistorySpotCheck.range(in: [], random: { $0.lowerBound }))
        XCTAssertEqual(ServerHistorySpotCheck.range(in: [7...7], random: { $0.upperBound }), 7...7)
        XCTAssertEqual(ServerHistorySpotCheck.range(in: [0...UInt64.max], random: { $0.upperBound }), (UInt64.max - 9_999)...UInt64.max, "no overflow")
    }

    /// The chain and what is held agree when the same logs are in the blocks the read covered, those the filter matches;
    /// no verdict when it covered none.
    func testTheSpotChecksVerdict() {
        let scan = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        let a = HistoryDocs.log(10_100, scan: scan), b = HistoryDocs.log(10_200, 1, scan: scan), c = HistoryDocs.log(12_000, scan: scan)
        let outside = HistoryDocs.log(30_000, scan: scan)
        let other = HistoryDocs.log(10_300, scan: HistoryDocs.scan(WalletHistoryScans.transfersOutId))
        let range: ClosedRange<UInt64> = 10_000...19_999
        func agrees(_ held: [Log], _ chain: [Log], covered: [ClosedRange<UInt64>] = [10_000...19_999]) -> Bool? {
            ServerHistorySpotCheck.agrees(held: held, read: LogsRead(logs: chain, covered: covered, requests: 1), query: scan.query, within: range)
        }
        XCTAssertEqual(agrees([a, b, c], [c, b, a]), true, "in any order")
        XCTAssertEqual(agrees([a, b, c, outside], [a, b, c]), true, "outside the range: not compared")
        XCTAssertEqual(agrees([a, b], [a, b, c]), false, "a log the server left out")
        XCTAssertEqual(agrees([a, b, c], [a, b]), false, "a log the chain doesn't have")
        XCTAssertEqual(agrees([a, b, other], [a, b]), true, "a log the filter doesn't match")
        XCTAssertEqual(agrees([a, b, c], [a, b], covered: [10_000...11_999]), true, "only the blocks read")
        XCTAssertNil(agrees([a], [], covered: []), "nothing read: no verdict")
        XCTAssertNil(agrees([a], [], covered: [20_000...29_999]))
    }

    // MARK: What is kept

    /// The owner's switches kept for the next launch — nothing written for a row that says nothing — and per wallet the
    /// spot check's day and the distrust, under keys named for the wallet, which an erase of the wallet removes; no key
    /// marks an install as one from before App Lock's default (R4).
    func testWhatIsKeptInUserDefaults() throws {
        let kept = ServerHistoryDefaults(defaults: userDefaults)
        XCTAssertTrue(kept.kept == (true, 0))
        kept.keep(.on)
        XCTAssertNil(userDefaults.object(forKey: ServerHistoryDefaults.offKey))
        XCTAssertNil(userDefaults.object(forKey: ServerHistoryDefaults.epochKey))
        kept.keep(RemoteFlags(serverHistory: false, historyEpoch: 4))
        XCTAssertTrue(kept.kept == (false, 4))
        XCTAssertTrue(ServerHistoryDefaults(defaults: userDefaults).kept == (false, 4), "the next launch")
        kept.keep(RemoteFlags(historyEpoch: 5))
        XCTAssertTrue(kept.kept == (true, 5))
        kept.keep(.on)
        XCTAssertTrue(kept.kept == (true, 0))
        userDefaults.set(-3, forKey: ServerHistoryDefaults.epochKey)
        XCTAssertEqual(kept.kept.historyEpoch, 0, "a kept epoch out of range is 0")

        let other = HistoryDocs.counterparty
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        kept.distrust(wallet, until: day)
        kept.spotChecked(wallet, at: day.addingTimeInterval(-60))
        XCTAssertEqual(kept.distrustedUntil(wallet), day)
        XCTAssertEqual(kept.spotCheckedAt(wallet), day.addingTimeInterval(-60))
        XCTAssertNil(kept.distrustedUntil(other), "nothing of one wallet read for another")
        XCTAssertNil(kept.spotCheckedAt(other))
        kept.spotChecked(other, at: day)
        kept.forget(wallet: wallet)
        XCTAssertNil(kept.distrustedUntil(wallet))
        XCTAssertNil(kept.spotCheckedAt(wallet))
        XCTAssertEqual(kept.spotCheckedAt(other), day, "another wallet's stays")
        XCTAssertEqual(ServerHistoryDefaults.distrustKey(wallet), "serverHistory.v1.distrustedUntil.\(wallet.hex.lowercased())")

        let theme = try DocsLinksTests.appSource("Design/Theme.swift")
        let earlierRun = try XCTUnwrap(theme.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = theme[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("settings.") && prefixes.contains("perp."), "\(prefixes)")
        for key in [ServerHistoryDefaults.offKey, ServerHistoryDefaults.epochKey, ServerHistoryDefaults.distrustKey(wallet), ServerHistoryDefaults.checkedKey(wallet)] {
            for prefix in prefixes { XCTAssertFalse(key.hasPrefix(prefix), "\(key) would mark a new install as earlier (\(prefix))") }
        }
    }

    /// The store starts under the epoch kept from the last read of the flags: a read taken in before the flags are read
    /// again is marked with it, one made under a lower epoch is refused, and a file that took the server's history in
    /// under a lower one is read again from nothing when it loads. What the server added is kept with the entry, trimmed
    /// with it, and dropped with it by an epoch reset or an erase.
    func testTheStoreStartsUnderTheKeptEpochAndKeepsWhatTheServerAdded() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let full = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client().read(wallet: wallet)
        let incoming = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        let server = try XCTUnwrap(full.scan(incoming))
        let first = HistoryStore(router: router(), directory: directory)
        let taken = await first.adopt(server, scan: incoming, wallet: wallet, erasureToken: 0, epoch: 2)
        let entry = try XCTUnwrap(taken)
        let floor = incoming.floor.block(head: head)
        XCTAssertEqual(entry.adopted, [floor...(HistoryDocs.inHole - 1), (HistoryDocs.inHole + 1)...(head - 1_200)], "what the server added, at or above the floor")
        XCTAssertEqual(entry.adopted, entry.covered)

        let relaunched = HistoryStore(router: router(), directory: directory, epoch: 2)
        let epochApplied = await relaunched.epochApplied
        XCTAssertEqual(epochApplied, 2)
        let loaded = await relaunched.cached(incoming, wallet: wallet)
        XCTAssertEqual(loaded.adopted, entry.adopted, "kept on disk")
        XCTAssertEqual(loaded.serverEpoch, 2)
        let lower = await relaunched.adopt(server, scan: incoming, wallet: wallet, erasureToken: 0, epoch: 1)
        XCTAssertNil(lower, "a read made under a lower epoch")

        let raised = HistoryStore(router: router(), directory: directory, epoch: 3)
        let reset = await raised.cached(incoming, wallet: wallet)
        XCTAssertEqual(reset, .empty, "taken in under 2, loaded under 3: read again from nothing")
        let negative = await HistoryStore(router: router(), directory: nil, epoch: -4).epochApplied
        XCTAssertEqual(negative, 0)

        // Trimmed with the coverage.
        var trimmed = entry
        trimmed.trim(floor: 110_000_000)
        XCTAssertEqual(trimmed.adopted, [110_000_000...(HistoryDocs.inHole - 1), (HistoryDocs.inHole + 1)...(head - 1_200)])
    }

    // MARK: The reads, the polls and the spot check

    private func router() -> LogsRouter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LogsStub.self]
        return LogsRouter(endpoints: [LogsEndpoint(url: URL(string: "https://wide.logs-stub.invalid")!, span: 10_000, clamps: false)], session: URLSession(configuration: configuration),
                          gate: LogsGate(inFlight: 8, interval: .zero), concurrency: 1)
    }

    /// A store kept in `directory`, the wallet's history on it, and the sync reading `script` and the stub chain.
    private func rig(_ script: ServerScript, clock: MovingClock, dice: Dice = Dice([])) -> (store: HistoryStore, history: WalletHistoryService, sync: ServerHistorySync) {
        let router = router()
        let store = HistoryStore(router: router, directory: directory)
        let client = LogsStub.rpc()
        let blockClock = BlockClock(rpc: client, measured: BlockClock.fallbackSecondsPerBlock)
        let history = WalletHistoryService(store: store, swapHistory: SwapHistoryService(rpc: client, clock: blockClock), clock: blockClock,
                                           stacks: { DyorCoinRegistry.launchpads(live: .monadMainnet) }, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet))
        let sync = ServerHistorySync(client: script.client(), history: history, router: router, defaults: ServerHistoryDefaults(defaults: userDefaults),
                                     now: { clock.now }, random: { dice.roll($0) })
        return (store, history, sync)
    }

    /// The three-page read, page by page.
    private static func threePages(_ body: [String: JSON]) throws -> Data {
        guard let page = HistoryDocs.threePages()[body["p_cursor"]?.string] else { throw SupabaseError.http(400, "no such cursor") }
        return page
    }

    /// Before the rounds: a fresh install's whole history read and taken in, every scan, with no bounds; none again within
    /// the minute; the scan the server is still filling in polled a minute after — its account alone, then a bounded read
    /// of the hole it now covers, taken in — and nothing left to poll once the device holds it all.
    func testAFullReadThenThePollsOfAScanStillFillingIn() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript(Self.threePages)
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let (store, history, sync) = rig(script, clock: clock)

        let adopted = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(adopted, Set(WalletHistoryScans.ids))
        let bodies = await script.bodies
        XCTAssertEqual(bodies.count, 3, "three pages")
        XCTAssertTrue(bodies.allSatisfy { $0["p_from_block"] == nil && $0["p_to_block"] == nil && $0["p_meta_only"] == nil }, "a full read: no bounds")
        XCTAssertEqual(bodies.first?["p_wallet"], .string(wallet.hex))
        let again = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(again, [], "within the minute")
        let afterAgain = await script.bodies.count
        XCTAssertEqual(afterAgain, 3, "no request")

        let wait = await sync.nextPoll(wallet: wallet)
        XCTAssertEqual(wait, 60, "a minute after the read: transfers-in is still filling in on the server")
        clock.advance(61)
        let due = await sync.nextPoll(wallet: wallet)
        XCTAssertEqual(due, 0)

        let incoming = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        let hole = HistoryDocs.inHole
        await script.set { body in
            if body["p_meta_only"] == .bool(true) {
                return HistoryDocs.data(HistoryDocs.page(scans: [WalletHistoryScans.transfersInId: HistoryDocs.account(WalletHistoryScans.transfersInId, capFloor: 103_140_000)], next: nil))
            }
            guard body["p_from_block"] == .number(Double(hole)), body["p_to_block"] == .number(Double(hole)) else { throw SupabaseError.http(400, "unexpected") }
            return HistoryDocs.data(HistoryDocs.page(scans: [WalletHistoryScans.transfersInId: HistoryDocs.account(WalletHistoryScans.transfersInId, from: hole, to: hole, covered: [[hole, hole]],
                                                                                                                   logs: [HistoryDocs.log(hole, 2, scan: incoming)])], next: nil))
        }
        let polled = await sync.poll(wallet: wallet)
        XCTAssertEqual(polled, [WalletHistoryScans.transfersInId])
        let polls = await script.bodies.dropFirst(3)
        XCTAssertEqual(polls.count, 2, "the account, then one bounded read")
        XCTAssertEqual(polls.first?["p_meta_only"], .bool(true))
        let entry = await store.cached(incoming, wallet: wallet)
        XCTAssertTrue(entry.covered.contains { $0.contains(hole) }, "the hole taken in")
        XCTAssertTrue(entry.logs.contains { $0.blockNumber == hole })
        XCTAssertTrue(entry.adopted.contains { $0.contains(hole) })
        let after = await sync.nextPoll(wallet: wallet)
        XCTAssertNil(after, "nothing left to poll: the device reads the margin below the head itself")
        let entries = await history.entries(wallet: wallet)
        XCTAssertFalse(entries.values.contains(where: \.complete), "never complete while the newest blocks are unread")
    }

    /// Every failure is discarded and nothing is taken in: no answer, a status, the owner's switch on the server, another
    /// wallet's document. The rounds read the chain as before; a failure that may pass is asked again after the minute.
    func testEveryFailureFailsOpen() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let failures: [@Sendable ([String: JSON]) throws -> Data] = [
            { _ in throw URLError(.notConnectedToInternet) },
            { _ in throw SupabaseError.http(404, #"{"code":"PGRST202"}"#) },
            { _ in HistoryDocs.data(["version": 1, "serving": false, "wallet": HistoryDocs.wallet.hex, "scans": [String: Any](), "next": NSNull()]) },
            { _ in HistoryDocs.data(HistoryDocs.page(wallet: HistoryDocs.counterparty, scans: [:], next: nil)) },
            { _ in Data("not json".utf8) },
        ]
        for (index, failure) in failures.enumerated() {
            try? FileManager.default.removeItem(at: directory)
            let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
            let script = ServerScript(failure)
            let (store, _, sync) = rig(script, clock: clock)
            let adopted = await sync.beforeRound(wallet: wallet)
            XCTAssertEqual(adopted, [], "\(index)")
            let entry = await store.cached(HistoryDocs.scan(WalletHistoryScans.transfersOutId), wallet: wallet)
            XCTAssertEqual(entry, .empty, "\(index): nothing taken in")
            let poll = await sync.nextPoll(wallet: wallet)
            XCTAssertNil(poll, "\(index): nothing watched")
            clock.advance(60)
            _ = await sync.beforeRound(wallet: wallet)
            let asked = await script.bodies.count
            XCTAssertEqual(asked, 2, "\(index): asked again after the minute")
        }
    }

    /// A wallet the server doesn't track: the global scans it serves are taken in; the transfers are left to the device.
    func testAnUntrackedWalletTakesInTheGlobalScans() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        var globals: [String: [String: Any]] = [:]
        for id in [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId] { globals[id] = HistoryDocs.account(id) }
        let page = HistoryDocs.data(HistoryDocs.page(tracked: false, scans: globals, next: nil))
        let (store, _, sync) = rig(ServerScript { _ in page }, clock: MovingClock(Date(timeIntervalSince1970: 1_791_500_000)))
        let adopted = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(adopted, [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId])
        let transfers = await store.cached(HistoryDocs.scan(WalletHistoryScans.transfersInId), wallet: wallet)
        XCTAssertEqual(transfers, .empty)
        let poll = await sync.nextPoll(wallet: wallet)
        XCTAssertNil(poll, "the transfers aren't the server's to fill in")
    }

    /// Every scan complete on the device but its newest block more than 60,000 behind the head the chain has reached by
    /// now: a top-up from 20 blocks below it, with no upper bound; near the head, nothing.
    func testATopUpWhenEveryScanIsCompleteButFarBehind() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        var accounts: [String: [String: Any]] = [:]
        for id in HistoryServerClient.scanOrder { accounts[id] = HistoryDocs.account(id) }
        let whole = HistoryDocs.data(HistoryDocs.page(scans: accounts, next: nil))
        let script = ServerScript { _ in whole }
        // The stub chain's head block is at 1,790,000,000.
        let clock = MovingClock(Date(timeIntervalSince1970: 1_790_000_010))
        let (_, history, sync) = rig(script, clock: clock)
        let adopted = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(adopted, Set(WalletHistoryScans.ids))
        // A round reads the newest blocks: every scan complete.
        _ = await history.refresh(wallet: wallet, budget: LogsBudget(requests: 20, seconds: 10), curves: [], decimals: [:])
        let completed = await history.entries(wallet: wallet)
        XCTAssertTrue(completed.values.allSatisfy(\.complete), "\(completed.mapValues(\.covered))")
        clock.advance(60)
        let near = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(near, [])
        let none = await script.bodies.count
        XCTAssertEqual(none, 1, "near the head: no read")

        clock.set(Date(timeIntervalSince1970: 1_790_000_000 + 60_100 * BlockClock.fallbackSecondsPerBlock))
        _ = await sync.beforeRound(wallet: wallet)
        let bodies = await script.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.last?["p_from_block"], .number(Double(head + 300 - 20)), "from 20 below the newest block read")
        XCTAssertNil(bodies.last?["p_to_block"])
        XCTAssertNil(bodies.last?["p_meta_only"])
    }

    /// A wallet the server is distrusted for reads nothing from it, polls nothing and checks nothing, until the day is
    /// out; another wallet isn't.
    func testADistrustedWalletReadsNothingFromTheServer() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript(Self.threePages)
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let (_, _, sync) = rig(script, clock: clock)
        ServerHistoryDefaults(defaults: userDefaults).distrust(wallet, until: clock.now.addingTimeInterval(3_600))
        let distrusted = await sync.distrusted(wallet: wallet)
        XCTAssertTrue(distrusted)
        let other = await sync.distrusted(wallet: HistoryDocs.counterparty)
        XCTAssertFalse(other)
        let adopted = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(adopted, [])
        let check = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(check, .notDue)
        let asked = await script.bodies.count
        XCTAssertEqual(asked, 0)
        clock.advance(3_601)
        let later = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(later, Set(WalletHistoryScans.ids), "the distrust ran out")
    }

    /// The day's spot check: one range of 10,000 blocks inside what the server added to the transfers in, read again from
    /// the chain in one request and compared. Agreeing, it is noted and not asked again that day. A log on the chain the
    /// server left out: the server distrusted for the wallet for a day, the wallet's history on the device forgotten, and
    /// nothing read from the server for it. No endpoint answering: no verdict, asked again.
    func testTheSpotCheck() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript(Self.threePages)
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        // The newest range the server added, from block 110,995,000: the transfer at 111,000,000 inside.
        let dice = Dice([{ $0.upperBound }, { _ in 110_995_000 }, { $0.upperBound }, { _ in 110_995_000 }, { $0.upperBound }, { _ in 110_995_000 }])
        let (store, history, sync) = rig(script, clock: clock, dice: dice)
        let nothingYet = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(nothingYet, .notDue, "nothing taken in yet")
        _ = await sync.beforeRound(wallet: wallet)
        let incoming = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        let firstTaken = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertEqual(firstTaken, 103_551_773)

        // The chain unreachable: no verdict, nothing noted.
        LogsStub.install(head: head + 300, logs: HistoryDocs.inLogs) { _ in .noAnswer }
        let unreachable = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(unreachable, .inconclusive)
        XCTAssertNil(ServerHistoryDefaults(defaults: userDefaults).spotCheckedAt(wallet))

        LogsStub.install(head: head + 300, logs: HistoryDocs.inLogs) { _ in nil }
        let matched = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(matched, .matched)
        XCTAssertEqual(LogsStub.queries(), [LogsStub.Range(from: 110_995_000, to: 111_004_999)], "one range of 10,000")
        XCTAssertEqual(LogsStub.requests(), 1, "one request")
        XCTAssertEqual(ServerHistoryDefaults(defaults: userDefaults).spotCheckedAt(wallet), clock.now)
        let sameDay = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(sameDay, .notDue)

        clock.advance(86_400)
        LogsStub.install(head: head + 300, logs: HistoryDocs.inLogs + [HistoryDocs.log(111_000_500, scan: incoming)]) { _ in nil }
        let mismatched = await sync.spotCheck(wallet: wallet)
        XCTAssertEqual(mismatched, .mismatched)
        XCTAssertEqual(ServerHistoryDefaults(defaults: userDefaults).distrustedUntil(wallet), clock.now.addingTimeInterval(86_400))
        let forgotten = await store.cached(incoming, wallet: wallet)
        XCTAssertEqual(forgotten, .empty, "the wallet's history forgotten, to be read from the chain")
        let entries = await history.entries(wallet: wallet)
        XCTAssertTrue(entries.values.allSatisfy { $0 == .empty })
        let firstDropped = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertNil(firstDropped, "the server's first transaction forgotten with the rest")
        let scans = await history.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(scans.first { $0.id == WalletHistoryScans.transfersInId }?.floor, WalletHistoryScans.transferFloor, "the transfer scans' floor the device's own again")
        clock.advance(120)
        let asked = await script.bodies.count
        let adopted = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(adopted, [])
        let askedAfter = await script.bodies.count
        XCTAssertEqual(askedAfter, asked, "nothing read from the server for a day")
    }

    /// A spot check that finds a mismatch after this device's data was erased writes nothing: no distrust, no day, nothing
    /// forgotten twice; and the erase of a wallet removes what is kept of it, not another's.
    func testAnEraseDuringASpotCheckKeepsNothing() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let dice = Dice([{ $0.upperBound }, { _ in 110_995_000 }])
        let (store, _, sync) = rig(ServerScript(Self.threePages), clock: clock, dice: dice)
        _ = await sync.beforeRound(wallet: wallet)
        let incoming = HistoryDocs.scan(WalletHistoryScans.transfersInId)
        LogsStub.install(head: head + 300, logs: HistoryDocs.inLogs + [HistoryDocs.log(111_000_500, scan: incoming)], holding: { _ in true }) { _ in nil }
        let check = Task { await sync.spotCheck(wallet: wallet) }
        for _ in 0..<500 where LogsStub.held() == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(LogsStub.held(), 1)
        await store.forget(wallet: wallet)
        LogsStub.release()
        let outcome = await check.value
        XCTAssertEqual(outcome, .inconclusive)
        let kept = ServerHistoryDefaults(defaults: userDefaults)
        XCTAssertNil(kept.distrustedUntil(wallet))
        XCTAssertNil(kept.spotCheckedAt(wallet))

        let other = HistoryDocs.counterparty
        kept.distrust(wallet, until: clock.now.addingTimeInterval(60))
        kept.spotChecked(other, at: clock.now)
        await sync.forget(wallet: wallet)
        XCTAssertNil(kept.distrustedUntil(wallet))
        XCTAssertEqual(kept.spotCheckedAt(other), clock.now)
        let next = await sync.nextPoll(wallet: wallet)
        XCTAssertNil(next)
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting")
    }

    /// The scans' account of a wallet whose transfers in still have the hole the full read left: a poll of it finds
    /// nothing new to read.
    private static let stillHoled = HistoryDocs.data(HistoryDocs.page(scans: [
        WalletHistoryScans.transfersInId: HistoryDocs.account(WalletHistoryScans.transfersInId, covered: [[103_140_000, HistoryDocs.inHole - 1], [HistoryDocs.inHole + 1, HistoryDocs.head]],
                                                              holes: [[HistoryDocs.inHole, HistoryDocs.inHole]], complete: false),
    ], next: nil))

    /// One read or poll of a wallet at a time, never a busy loop and never a read skipped. A read before the rounds under
    /// way past the minute: the poller is told to look again a minute on — in the first cut it was told 0 and asked at
    /// once, over and over, for as long as the read lasted — and a poll sends nothing. A poll under way: a read before the
    /// rounds asked meanwhile waits for it, then reads — in the first cut it returned nothing, after the history model had
    /// marked the read done, and the run's read was skipped.
    func testAPollAndAReadBeforeTheRoundsNeverOverlap() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript { body in body["p_meta_only"] == .bool(true) ? Self.stillHoled : try Self.threePages(body) }
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let (_, _, sync) = rig(script, clock: clock)
        let first = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(first, Set(WalletHistoryScans.ids))
        let afterFirst = await script.bodies.count
        XCTAssertEqual(afterFirst, 3)

        // A minute on, the transfers in still not holding all the server could add: a full read again, held at the server.
        clock.advance(61)
        let gate = LookupGate()
        await script.hold(gate)
        let reading = Task { await sync.beforeRound(wallet: self.wallet) }
        try await waitUntil { await script.bodies.count == 4 }
        clock.advance(61)
        let wait = await sync.nextPoll(wallet: wallet)
        XCTAssertEqual(wait, ServerHistoryPlan.pollInterval, "a read under way: a minute on, never at once")
        let polled = await sync.poll(wallet: wallet)
        XCTAssertEqual(polled, [])
        let duringRead = await script.bodies.count
        XCTAssertEqual(duringRead, 4, "the poll sent nothing")
        await script.hold(nil)
        await gate.open()
        _ = await reading.value
        let afterSecond = await script.bodies.count
        XCTAssertEqual(afterSecond, 6)

        // A minute on, a poll held at the server, and a read before the rounds asked meanwhile.
        clock.advance(61)
        let due = await sync.nextPoll(wallet: wallet)
        XCTAssertEqual(due, 0)
        let pollGate = LookupGate()
        await script.hold(pollGate)
        let polling = Task { await sync.poll(wallet: self.wallet) }
        try await waitUntil { await script.bodies.count == 7 }
        let lastBody = await script.bodies.last
        XCTAssertEqual(lastBody?["p_meta_only"], .bool(true))
        let waiting = Task { await sync.beforeRound(wallet: self.wallet) }
        try await Task.sleep(for: .milliseconds(200))
        let duringPoll = await script.bodies.count
        XCTAssertEqual(duringPoll, 7, "the read waits for the poll under way")
        await script.hold(nil)
        await pollGate.open()
        let pollTook = await polling.value
        XCTAssertEqual(pollTook, [], "nothing new on the server")
        let read = await waiting.value
        XCTAssertEqual(read, Set(WalletHistoryScans.ids), "then reads: never skipped")
        let afterThird = await script.bodies.count
        XCTAssertEqual(afterThird, 10)
    }

    /// The owner raises the history epoch while a read before the rounds is under way: the store resets what the server
    /// added, and the rounds start over (`HistoryModel.restart`, `reset(wallet:)`). The read after the reset waits for the
    /// one under way, rather than returning nothing, and reads the server again at once — within the minute of the last,
    /// which held it off in the first cut, every reset entry then read again from the public endpoints alone. What the read
    /// from before the reset brought, under the old epoch, is neither taken in nor keeps a time or scans to watch.
    func testAResetReadsTheServerAgainAtOnce() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript(Self.threePages)
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let (store, history, sync) = rig(script, clock: clock)
        let gate = LookupGate()
        await script.hold(gate)
        let before = Task { await sync.beforeRound(wallet: self.wallet) }
        try await waitUntil { await script.bodies.count == 1 }
        let reset = await store.apply(epoch: 1)
        XCTAssertEqual(reset, 0, "nothing taken in yet")
        await sync.reset(wallet: wallet)
        let after = Task { await sync.beforeRound(wallet: self.wallet) }
        try await Task.sleep(for: .milliseconds(200))
        let waiting = await script.bodies.count
        XCTAssertEqual(waiting, 1, "the read after the reset waits for the one under way")
        await script.hold(nil)
        await gate.open()
        let old = await before.value
        XCTAssertEqual(old, [], "read under the old epoch: nothing taken in")
        let new = await after.value
        XCTAssertEqual(new, Set(WalletHistoryScans.ids), "read again at once, within the minute of the last")
        let bodies = await script.bodies.count
        XCTAssertEqual(bodies, 6)
        let entry = await store.cached(HistoryDocs.scan(WalletHistoryScans.transfersOutId), wallet: wallet)
        XCTAssertEqual(entry.serverEpoch, 1)
        let first = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertEqual(first, 103_551_773, "the first transaction under the new epoch too")
        let scans = await history.scans(wallet: wallet, findingFirstTransaction: false)
        XCTAssertEqual(scans.first { $0.id == WalletHistoryScans.transfersInId }?.floor, .earliest(block: 103_551_773, blocks: WalletHistoryScans.transferBlocks))
        clock.advance(10)
        let again = await sync.beforeRound(wallet: wallet)
        XCTAssertEqual(again, [], "and within the minute of that one, nothing")
    }

    /// A spot check's distrust that lands while a read is under way: nothing it read is taken in. The distrust is checked
    /// again once the read is back, as well as after the erase count is taken.
    func testADistrustDuringAReadTakesNothingIn() async throws {
        LogsStub.install(head: head + 300) { _ in nil }
        let script = ServerScript(Self.threePages)
        let clock = MovingClock(Date(timeIntervalSince1970: 1_791_500_000))
        let (store, _, sync) = rig(script, clock: clock)
        let gate = LookupGate()
        await script.hold(gate)
        let reading = Task { await sync.beforeRound(wallet: self.wallet) }
        try await waitUntil { await script.bodies.count == 1 }
        ServerHistoryDefaults(defaults: userDefaults).distrust(wallet, until: clock.now.addingTimeInterval(3_600))
        await script.hold(nil)
        await gate.open()
        let adopted = await reading.value
        XCTAssertEqual(adopted, [])
        for id in WalletHistoryScans.ids {
            let entry = await store.cached(HistoryDocs.scan(id), wallet: wallet)
            XCTAssertEqual(entry, .empty, id)
        }
        let first = await store.serverFirstTransaction(wallet: wallet)
        XCTAssertNil(first)
    }

    /// The rounds wait for the read before them for its own bounded time only: its value when it ends in time; nil when it
    /// doesn't, the read left to finish; and a caller cancelled (another wallet) cancels the read and returns at once. The
    /// gaps are wide — a 50 ms bound against a 30 s read — so a loaded machine can't tip one into the other.
    func testTheReadBeforeTheRoundsIsBounded() async throws {
        let quick = Task { 7 }
        let value = await ServerHistorySync.value(of: quick, within: 5)
        XCTAssertEqual(value, 7)

        let slow = Task { () -> Bool in
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        let started = ContinuousClock.now
        let late = await ServerHistorySync.value(of: slow, within: 0.05)
        XCTAssertNil(late)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "never the read's 30 s")
        XCTAssertFalse(slow.isCancelled, "left to finish")
        slow.cancel()
        _ = await slow.value

        let held = Task { () -> Bool in
            try? await Task.sleep(for: .seconds(30))
            return Task.isCancelled
        }
        let caller = Task { await ServerHistorySync.value(of: held, within: 30) }
        try await Task.sleep(for: .milliseconds(50))
        let before = ContinuousClock.now
        caller.cancel()
        let returned = await caller.value
        XCTAssertNil(returned)
        let cancelled = await held.value
        XCTAssertTrue(cancelled, "the read is cancelled with its caller")
        XCTAssertLessThan(ContinuousClock.now - before, .seconds(5))
    }

    // MARK: The app's wiring

    /// The history model reads the server's history before the first round of each run of the rounds — after the instant
    /// read from the device, which `run` publishes first — when the switch is on and the app has the backend, for its
    /// bounded time; publishes what it took in at once; polls beside the rounds; runs the day's spot check beside them, and
    /// starts the rounds over when it fails; and reads again after a return from the background and an epoch reset.
    func testTheHistoryModelWiresTheServersHistory() throws {
        let model = try DocsLinksTests.appSource("Wallet/HistoryModel.swift")
        XCTAssertTrue(model.contains("""
                    if serverReadDue {
                        serverReadDue = false
                        await readServer(env: env, wallet: wallet)
                        guard !Task.isCancelled, self.wallet == wallet else { return }
                    }
                    let (round, joined) = await round(env: env, wallet: wallet, budget: Self.roundBudget)
        """), "before a round, never beside it")
        XCTAssertEqual(model.components(separatedBy: "await readServer(").count - 1, 1, "only before a round of the rounds")
        XCTAssertTrue(model.contains("        generation += 1\n        let mine = generation\n        serverReadDue = true\n"), "each run of the rounds")
        // The instant read is published before the rounds, and so before the server's history.
        let run = try XCTUnwrap(model.range(of: "    private func run(env: AppEnvironment, wallet: Address, fromStore: Bool, afterReset: Bool = false) {"))
        let instant = try XCTUnwrap(model.range(of: "publish(cached, wallet: wallet, env: env)", range: run.upperBound..<model.endIndex))
        let fill = try XCTUnwrap(model.range(of: "await fill(env: env, wallet: wallet)", range: run.upperBound..<model.endIndex))
        XCTAssertLessThan(instant.lowerBound, fill.lowerBound)
        // After a reset (an epoch's, a spot check's mismatch), the server's history is read again before the first round
        // whatever the time of the last read: the sync is told before anything else of the run.
        XCTAssertTrue(model.contains("""
                filler = Task { [weak self] in
                    if afterReset { await env.serverHistory?.reset(wallet: wallet) }
                    guard let self else { return }
        """))
        for part in ["guard readsServerHistory, let sync = env.serverHistory else { return }",
                     "let step = Task { await sync.beforeRound(wallet: wallet) }\n        let adopted = await ServerHistorySync.value(of: step, within: ServerHistoryPlan.stepSeconds) ?? []",
                     "if !adopted.isEmpty {\n            let taken = await env.walletHistory.cached(wallet: wallet, curves: curves, decimals: decimals)",
                     "publish(taken, wallet: wallet, env: env)",
                     "spotCheck(env: env, wallet: wallet, sync: sync)",
                     "guard poller == nil, readsServerHistory, let sync = env.serverHistory else { return }",
                     "while !Task.isCancelled, let wait = await sync.nextPoll(wallet: wallet) {",
                     "let adopted = await sync.poll(wallet: wallet)",
                     "if !adopted.isEmpty { rebuild(env: env) }",
                     "guard await sync.spotCheck(wallet: wallet) == .mismatched, let self, self.wallet == wallet else { return }\n            restart(env: env)",
                     "if on { serverReadDue = true } else { stopPolling() }",
                     "        if backgrounded {\n            backgrounded = false\n            serverReadDue = true\n            if let sync = env.serverHistory {",
                     "await sync.enteredForeground()",
                     "func epochReset(env: AppEnvironment) {\n        restart(env: env)\n    }",
                     "        filler?.cancel()\n        filler = nil\n        stopPolling()\n        backingOff = false"] {
            XCTAssertTrue(model.contains(part), part)
        }
        // A restart never joins a round that read entries now gone, and reads the server again whatever the last read's time.
        let restart = try XCTUnwrap(model.range(of: "    private func restart(env: AppEnvironment) {"))
        let restartEnd = try XCTUnwrap(model.range(of: "run(env: env, wallet: wallet, fromStore: true, afterReset: true)", range: restart.upperBound..<model.endIndex))
        XCTAssertTrue(model[restart.upperBound..<restartEnd.lowerBound].contains("inFlight = nil"))
        XCTAssertEqual(model.components(separatedBy: "afterReset: true)").count - 1, 1, "only a restart")
        // The facts the instant read left out never roll back a snapshot published meanwhile (the server's history taken
        // in): built again from the store instead.
        XCTAssertTrue(model.contains("let rounds = roundsPublished, published = version"))
        XCTAssertTrue(model.contains("guard let self, self.wallet == wallet, roundsPublished == rounds else { return }\n            guard version == published else { rebuild(env: env); return }\n            publish(completed, wallet: wallet, env: env)"))

        let root = try DocsLinksTests.appSource("App/RootView.swift")
        let background = try XCTUnwrap(root.range(of: "if phase == .background {"))
        let active = try XCTUnwrap(root.range(of: "if phase == .active {", range: background.upperBound..<root.endIndex))
        XCTAssertTrue(root[background.upperBound..<active.lowerBound].contains("env.history.enteredBackground()"))
        XCTAssertTrue(root[active.upperBound...].contains("env.history.resume(env: env)"))
    }

    /// An erase of this device's data — Delete Account and Forget This Device alike — forgets what the server's history
    /// keeps of the wallet with its history, before UserDefaults is wiped whole.
    func testAnEraseForgetsWhatTheServersHistoryKept() throws {
        let deletion = try DocsLinksTests.appSource("Profile/AccountDeletion.swift")
        XCTAssertEqual(deletion.components(separatedBy: "await env.walletHistory.forget(wallet: account.address)\n        await env.serverHistory?.forget(wallet: account.address)\n        await session.eraseLocalData()").count - 1, 1)
        XCTAssertEqual(deletion.components(separatedBy: "await env.walletHistory.forget(wallet: address)\n        await env.serverHistory?.forget(wallet: address)\n        await session.eraseLocalData()").count - 1, 1)
        let session = try DocsLinksTests.appSource("Wallet/Session.swift")
        XCTAssertTrue(session.contains("AppLockStore.erase(UserDefaults.standard, domain: bundle, canAuthenticateOwner: BiometricGate.canAuthenticateOwner)"), "every key with the rest")
        let environment = try DocsLinksTests.appSource("App/AppEnvironment.swift")
        XCTAssertTrue(environment.contains("let serverHistoryDefaults = ServerHistoryDefaults()"), "the standard defaults, which the erase wipes")
    }
}

/// Answers `history_read` as the test says (`set`), and records every request's body as it arrives. While a gate is set
/// (`hold`), a request waits at it, recorded, until the gate opens: a test holds a read at the server at a point of its
/// choosing.
actor ServerScript {
    private(set) var bodies: [[String: JSON]] = []
    private var answer: @Sendable ([String: JSON]) throws -> Data
    private var gate: LookupGate?

    init(_ answer: @escaping @Sendable ([String: JSON]) throws -> Data) {
        self.answer = answer
    }

    func set(_ answer: @escaping @Sendable ([String: JSON]) throws -> Data) {
        self.answer = answer
    }

    /// Requests from now on wait at `gate` (nil: none do).
    func hold(_ gate: LookupGate?) {
        self.gate = gate
    }

    /// Records a request, and says where it waits.
    private func arrive(_ body: [String: JSON]) -> LookupGate? {
        bodies.append(body)
        return gate
    }

    private func respond(_ body: [String: JSON]) throws -> Data {
        try answer(body)
    }

    nonisolated func client() -> HistoryServerClient {
        HistoryServerClient(limits: .standard) { body in
            if let gate = await self.arrive(body) { await gate.wait() }
            return try await self.respond(body)
        }
    }
}

/// A clock the test moves.
final class MovingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock(); current = date; lock.unlock()
    }
}

/// The spot check's dice, loaded: each roll the next pick, kept within the range asked (the range's start once spent).
final class Dice: @unchecked Sendable {
    private let lock = NSLock()
    private var picks: [(ClosedRange<UInt64>) -> UInt64]

    init(_ picks: [(ClosedRange<UInt64>) -> UInt64]) { self.picks = picks }

    func roll(_ range: ClosedRange<UInt64>) -> UInt64 {
        lock.lock()
        let pick = picks.isEmpty ? { $0.lowerBound } : picks.removeFirst()
        lock.unlock()
        return min(max(pick(range), range.lowerBound), range.upperBound)
    }
}
