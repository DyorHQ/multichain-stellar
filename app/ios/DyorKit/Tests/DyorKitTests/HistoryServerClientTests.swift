import BigInt
import XCTest
@testable import DyorKit

/// The server's history cache, the client side (`HistoryServerClient`, the server spec's §6 and §16): the filter
/// matching (`LogsQuery.isSubset(of:)`), the exact adoptable rule (`ServerScan.adoptable`), paging with the bounds on
/// every page, the checks across pages, and failing open on everything else — the device then reads the chain as before.
final class HistoryServerClientTests: XCTestCase {
    private let t0 = ABI.eventTopic("Zero()"), t1 = ABI.eventTopic("One()"), t2 = ABI.eventTopic("Two()")
    private let a = Address(literal: "0x1111111111111111111111111111111111111111")
    private let b = Address(literal: "0x2222222222222222222222222222222222222222")
    private let c = Address(literal: "0x3333333333333333333333333333333333333333")
    private let w = HistoryDocs.wallet.data.leftPadded(to: 32)
    private let x = Data(repeating: 9, count: 32)
    private let wallet = HistoryDocs.wallet
    private let head = HistoryDocs.head

    // MARK: Matching

    /// Q can take S's coverage when every log Q matches, S matches: S names no address or Q names some, all S's; and at
    /// every topic position (past the end of a list: anything) S takes anything, or Q lists topics, all S's. In any order.
    func testIsSubsetTable() {
        let rows: [(LogsQuery, LogsQuery, Bool, String)] = [
            (LogsQuery(addresses: [a], topics: [[t0]]), LogsQuery(addresses: [a], topics: [[t0]]), true, "the same filter"),
            (LogsQuery(addresses: [b, a], topics: [[t1, t0]]), LogsQuery(addresses: [a, b], topics: [[t0, t1]]), true, "in another order"),
            (LogsQuery(addresses: [], topics: [[t0]]), LogsQuery(addresses: [], topics: [[t0, t1]]), true, "fewer events"),
            (LogsQuery(addresses: [a], topics: [[t0]]), LogsQuery(addresses: [], topics: [[t0]]), true, "the server names no contract"),
            (LogsQuery(addresses: [], topics: [[t0]]), LogsQuery(addresses: [a], topics: [[t0]]), false, "any contract, the server's some"),
            (LogsQuery(addresses: [a], topics: [[t0]]), LogsQuery(addresses: [a, b], topics: [[t0]]), true, "fewer contracts"),
            (LogsQuery(addresses: [a, c], topics: [[t0]]), LogsQuery(addresses: [a, b], topics: [[t0]]), false, "a contract the server doesn't read (a new cohort)"),
            (LogsQuery(addresses: [], topics: [[t2]]), LogsQuery(addresses: [], topics: [[t0, t1]]), false, "an event the server doesn't read"),
            (LogsQuery(addresses: [], topics: [nil]), LogsQuery(addresses: [], topics: [[t0]]), false, "any event, the server's some"),
            (LogsQuery(addresses: [], topics: [[t0], [x], [w]]), LogsQuery(addresses: [], topics: [[t0], nil, [w]]), true, "the server takes anything at 1"),
            (LogsQuery(addresses: [], topics: [[t0]]), LogsQuery(addresses: [], topics: [[t0], [w]]), false, "a position left out is anything; the server's is the wallet"),
            (LogsQuery(addresses: [], topics: [[t0], [w]]), LogsQuery(addresses: [], topics: [[t0]]), true, "the server's list shorter: anything there"),
            (LogsQuery(addresses: [], topics: [[t0], nil, [w]]), LogsQuery(addresses: [], topics: [[t0], nil]), true, "the server's shorter, by a nil"),
            (LogsQuery(addresses: [], topics: [[t0], nil]), LogsQuery(addresses: [], topics: [[t0], nil, [w]]), false, "the wallet at 2 on the server's only"),
            (LogsQuery(addresses: [], topics: [[t0], []]), LogsQuery(addresses: [], topics: [[t0], [w]]), true, "an empty list matches nothing"),
            (LogsQuery(addresses: [], topics: [[t0], [w]]), LogsQuery(addresses: [], topics: [[t0], [x]]), false, "another wallet"),
            (LogsQuery(), LogsQuery(), true, "two filters of everything"),
            (LogsQuery(), LogsQuery(addresses: [], topics: [[t0]]), false, "everything, the server's one event"),
        ]
        for (q, s, expected, why) in rows { XCTAssertEqual(q.isSubset(of: s), expected, why) }
    }

    /// The canonical fingerprint sorts every list, in the format of `fingerprint`, which a stored scan is still checked
    /// against unsorted (the files kept before it keep loading).
    func testTheCanonicalFingerprintSortsTheLists() {
        let query = LogsQuery(addresses: [b, a], topics: [[t1, t0], nil, [w]])
        let topics = [t0, t1].map(\.hexString).sorted().joined(separator: "+")
        XCTAssertEqual(query.canonicalFingerprint, "\(a.hex),\(b.hex)|\(topics),*,\(w.hexString)")
        XCTAssertEqual(LogsQuery(addresses: [a, b], topics: [[t0, t1], nil, [w]]).canonicalFingerprint, query.canonicalFingerprint)
        XCTAssertEqual(query.fingerprint, "\(b.hex),\(a.hex)|\(t1.hexString)+\(t0.hexString),*,\(w.hexString)", "unchanged")
        XCTAssertEqual(LogsQuery().canonicalFingerprint, "|")
    }

    /// The server reads exactly the app's scans: each one's query as `history_read` builds it from
    /// `supabase/functions/_shared/history-scans.json` (addresses and events sorted, null at 1 when the wallet is topic 2,
    /// the wallet's word last) takes the app's and the app's takes it, and the fingerprint it prints is the app's
    /// canonical one. A cohort the app knows and the server doesn't fails the match: that scan is read from the chain.
    func testTheAppScansMatchTheServers() throws {
        struct Spec: Decodable {
            struct Event: Decodable { let topic: String }
            struct Scan: Decodable { let id: String; let walletTopic: Int; let addresses: [String]; let events: [Event] }
            let scans: [Scan]
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: root.appendingPathComponent("supabase/functions/_shared/history-scans.json")))
        let app = Dictionary(uniqueKeysWithValues: HistoryDocs.scans().map { ($0.id, $0) })
        XCTAssertEqual(Set(spec.scans.map(\.id)), Set(HistoryServerClient.scanOrder))
        for scan in spec.scans {
            let mine = try XCTUnwrap(app[scan.id])
            let topic0s = scan.events.map(\.topic).sorted()
            var topics: [[Data]?] = [topic0s.compactMap { Data(hex: $0) }]
            if scan.walletTopic == 2 { topics.append(nil) }
            topics.append([w])
            let server = LogsQuery(addresses: scan.addresses.sorted().compactMap(Address.init), topics: topics)
            XCTAssertTrue(mine.query.isSubset(of: server), scan.id)
            XCTAssertTrue(server.isSubset(of: mine.query), scan.id)
            let printed = scan.addresses.sorted().joined(separator: ",") + "|" + topic0s.joined(separator: "+") + (scan.walletTopic == 2 ? ",*" : "") + ",\(w.hexString)"
            XCTAssertEqual(mine.query.canonicalFingerprint, printed, scan.id)
            XCTAssertEqual(HistoryServerClient.kinds[scan.id], scan.id.hasPrefix("transfers") ? .wallet : .global)
        }
        let moments = try XCTUnwrap(app[WalletHistoryScans.momentsId])
        let ahead = LogsQuery(addresses: moments.query.addresses + [c], topics: moments.query.topics)
        XCTAssertFalse(ahead.isSubset(of: moments.query), "a cohort the server doesn't read yet")
    }

    // MARK: The adoptable rule

    /// A = covered(page 1) ∩ [max(from, capSeen), min(to, head − 1,200)] − holes − omitted blocks; a read cut short
    /// above its last log of the scan only, nothing when it served none; nothing at all when omitted is truncated or
    /// there is no head.
    func testTheAdoptableRule() {
        let top: UInt64 = 10_000_000, trusted = top - 1_200
        func rule(covered: [ClosedRange<UInt64>] = [0...10_000_000], from: UInt64 = 0, to: UInt64 = 10_000_000, cap: UInt64? = nil, head: UInt64? = 10_000_000,
                  holes: [ClosedRange<UInt64>] = [], omitted: [UInt64] = [], truncated: Bool = false, finished: Bool = true, lowest: UInt64? = nil) -> [ClosedRange<UInt64>] {
            ServerScan.adoptable(covered: covered, from: from, to: to, capSeen: cap, head: head, holes: holes, omittedBlocks: omitted, omittedTruncated: truncated,
                                 finished: finished, lowestServedBlock: lowest)
        }
        XCTAssertEqual(HistoryServerClient.trustMargin, 1_200)
        XCTAssertEqual(rule(), [0...trusted], "covered to the head: up to 1,200 below it, the rest the device reads")
        XCTAssertEqual(rule(cap: 5_000_000), [5_000_000...trusted], "never below the cap")
        XCTAssertEqual(rule(from: 3_000_000, cap: 2_000_000), [3_000_000...trusted], "the higher of from and the cap")
        XCTAssertEqual(rule(to: 9_000_000), [0...9_000_000], "a bound below the margin")
        XCTAssertEqual(rule(covered: [0...500, 700...top]), [0...500, 700...trusted], "only what is covered")
        XCTAssertEqual(rule(covered: [0...20_000_000], from: 150, to: 180), [150...180], "within the bounds, whatever covered says")
        XCTAssertEqual(rule(holes: [2_000...2_999, 5_000...5_000]), [0...1_999, 3_000...4_999, 5_001...trusted], "never a hole")
        XCTAssertEqual(rule(holes: [0...0]), [1...trusted])
        XCTAssertEqual(rule(omitted: [7_000, 7_000, top - 10]), [0...6_999, 7_001...trusted], "never an omitted log's block")
        XCTAssertEqual(rule(truncated: true), [], "omitted truncated: nothing")
        XCTAssertEqual(rule(head: nil), [], "no head: nothing")
        XCTAssertEqual(rule(to: 1_199, head: 1_199), [], "a head within the margin of genesis")
        XCTAssertEqual(rule(to: 1_200, head: 1_200), [0...0])
        XCTAssertEqual(rule(finished: false, lowest: 6_000_000), [6_000_001...trusted], "cut short: above the last log served, its block perhaps only partly")
        XCTAssertEqual(rule(finished: false, lowest: nil), [], "cut short before any log of it")
        XCTAssertEqual(rule(finished: false, lowest: top), [], "its last log served within the margin")
        XCTAssertEqual(rule(covered: [], from: 1, to: 0), [], "nothing to serve")
        XCTAssertEqual(rule(covered: [0...top], from: 1, to: 0), [], "nothing to serve, whatever covered says")

        // What a poll reads next (`ServerHistoryPlan.beyond`, the newest first across scans in `newlyCovered`): the adoptable
        // blocks the device doesn't hold, at or above the scan's floor, of the same scan only.
        let scan = ServerScan(id: "s", kind: .wallet, defVersion: 1, query: LogsQuery(), fingerprint: "|", floor: 0, capSeen: nil, from: 0, to: top, covered: [0...top], holes: [],
                              head: top, headTimestamp: 1, complete: true, omittedBlocks: [], omittedTruncated: false, finished: true, lowestServedBlock: nil, bounded: false,
                              metaOnly: true, logs: [], adoptable: [0...trusted])
        let mine = HistoryScan(id: "s", query: LogsQuery(), floor: .block(0))
        func beyond(_ covered: [ClosedRange<UInt64>], scan app: HistoryScan = mine) -> [ClosedRange<UInt64>] {
            ServerHistoryPlan.beyond(scan, scan: app, entry: HistoryEntry(covered: covered, head: top, headTimestamp: 1, floor: 0))
        }
        XCTAssertEqual(beyond([100...200, 5_000...trusted]), [0...99, 201...4_999])
        XCTAssertEqual(beyond([0...top]), [])
        XCTAssertEqual(beyond([], scan: HistoryScan(id: "s", query: LogsQuery(), floor: .block(1_000))), [1_000...trusted], "never below the scan's floor")
        XCTAssertEqual(beyond([], scan: HistoryScan(id: "t", query: LogsQuery(), floor: .block(0))), [], "another scan's")
    }

    /// Sets of blocks: within a range, without others, at the ends of UInt64 too.
    func testBlockRanges() {
        XCTAssertEqual(BlockRanges.subtract([0...UInt64.max], [0...0, UInt64.max...UInt64.max]), [1...(UInt64.max - 1)])
        XCTAssertEqual(BlockRanges.subtract([5...10, 20...30], [0...6, 9...21, 30...40]), [7...8, 22...29])
        XCTAssertEqual(BlockRanges.subtract([5...10], [5...10]), [])
        XCTAssertEqual(BlockRanges.intersect([0...10, 20...30], 5...25), [5...10, 20...25])
        XCTAssertEqual(BlockRanges.intersect([0...10], 11...UInt64.max), [])
        XCTAssertTrue(BlockRanges.contains([5...10], 10))
        XCTAssertFalse(BlockRanges.contains([5...10], 11))
    }

    // MARK: Paging

    /// A full read asks page after page with the cursor each returned until `next` is null, and assembles each scan's
    /// logs across pages, its adoptable blocks worked out; the server's queries are the app's.
    func testAFullReadPagesToTheEnd() async throws {
        let stub = HistoryPagesStub(pages: HistoryDocs.threePages())
        let read = try await stub.client().read(wallet: wallet)
        XCTAssertTrue(read.finished)
        XCTAssertEqual(read.pages, 3)
        XCTAssertTrue(read.tracked)
        XCTAssertFalse(read.bounded)
        XCTAssertFalse(read.metaOnly)
        XCTAssertEqual(read.firstTransaction, .found(103_551_773))
        XCTAssertEqual(read.head, head)
        let bodies = await stub.bodies
        let first: [String: JSON] = ["p_wallet": .string(wallet.hex)]
        XCTAssertEqual(bodies, [first, first.merging(["p_cursor": .string(HistoryDocs.cursorTwo)]) { $1 }, first.merging(["p_cursor": .string(HistoryDocs.cursorThree)]) { $1 }])
        XCTAssertEqual(Set(read.scans.keys), Set(WalletHistoryScans.ids))

        let launchpad = try XCTUnwrap(read.scans[WalletHistoryScans.launchpadId])
        XCTAssertEqual(launchpad.adoptable, [103_542_521...(head - 1_200)])
        XCTAssertEqual(launchpad.logs, HistoryDocs.launchpadLogs)
        XCTAssertEqual(launchpad.kind, .global)
        XCTAssertTrue(launchpad.finished && launchpad.complete)
        let out = try XCTUnwrap(read.scans[WalletHistoryScans.transfersOutId])
        XCTAssertEqual(out.logs, HistoryDocs.outFirst + HistoryDocs.outSecond, "across pages, newest first")
        XCTAssertEqual(out.adoptable, [0...(head - 1_200)])
        XCTAssertEqual(out.lowestServedBlock, 50_000_000)
        XCTAssertEqual(out.kind, .wallet)
        let incoming = try XCTUnwrap(read.scans[WalletHistoryScans.transfersInId])
        XCTAssertEqual(incoming.logs, HistoryDocs.inLogs)
        XCTAssertEqual(incoming.adoptable, [103_140_000...(HistoryDocs.inHole - 1), (HistoryDocs.inHole + 1)...(head - 1_200)], "the hole left out")
        XCTAssertFalse(incoming.complete)
        XCTAssertEqual(read.scans[WalletHistoryScans.feeSharingId]?.logs, [])
        for scan in HistoryDocs.scans() {
            let server = try XCTUnwrap(read.scan(scan))
            XCTAssertTrue(scan.query.isSubset(of: server.query) && server.query.isSubset(of: scan.query), scan.id)
            XCTAssertEqual(server.fingerprint, scan.query.canonicalFingerprint)
            XCTAssertEqual(server.head, head)
            XCTAssertEqual(server.headTimestamp, HistoryDocs.headTimestamp)
        }
    }

    /// The bounds go on every page; the read and its scans say they were bounded.
    func testBoundsGoOnEveryPage() async throws {
        let stub = HistoryPagesStub(pages: HistoryDocs.threePages())
        let read = try await stub.client().read(wallet: wallet, from: 103_000_000, to: 111_000_000)
        XCTAssertTrue(read.bounded)
        XCTAssertTrue(read.scans.values.allSatisfy(\.bounded))
        let bodies = await stub.bodies
        XCTAssertEqual(bodies.count, 3)
        for body in bodies {
            XCTAssertEqual(body["p_from_block"], .number(103_000_000))
            XCTAssertEqual(body["p_to_block"], .number(111_000_000))
            XCTAssertNil(body["p_meta_only"])
        }
        let topUp = HistoryPagesStub(pages: HistoryDocs.threePages())
        _ = try await topUp.client().read(wallet: wallet, from: 111_000_000)
        let topUpBodies = await topUp.bodies
        XCTAssertTrue(topUpBodies.allSatisfy { $0["p_from_block"] == .number(111_000_000) && $0["p_to_block"] == nil }, "a top-up: from alone")
        do {
            _ = try await topUp.client().read(wallet: wallet, from: 9, to: 5)
            XCTFail("from past to")
        } catch let error as HistoryServerError { XCTAssertEqual(error, .badBounds) }
        let asked = await topUp.bodies.count
        XCTAssertEqual(asked, 3, "refused before asking")
    }

    /// The metadata is one page, asked with `p_meta_only` and no cursor: every scan's account, no logs; a metadata page
    /// with logs or a next page is no metadata page.
    func testTheMetadataIsOnePageWithoutLogs() async throws {
        var scans: [String: [String: Any]] = [:]
        for id in HistoryServerClient.scanOrder { scans[id] = HistoryDocs.account(id) }
        let stub = HistoryPagesStub(pages: [nil: HistoryDocs.data(HistoryDocs.page(scans: scans, next: nil))])
        let meta = try await stub.client().metadata(wallet: wallet)
        XCTAssertTrue(meta.metaOnly)
        XCTAssertTrue(meta.finished)
        XCTAssertTrue(meta.scans.values.allSatisfy { $0.metaOnly && $0.logs.isEmpty && $0.adoptable == [$0.from...(head - 1_200)] })
        let bodies = await stub.bodies
        XCTAssertEqual(bodies, [["p_wallet": .string(wallet.hex), "p_meta_only": .bool(true)]])

        var withLogs = scans
        withLogs[WalletHistoryScans.launchpadId] = HistoryDocs.account(WalletHistoryScans.launchpadId, logs: HistoryDocs.launchpadLogs)
        await XCTAssertThrowsHistory(.malformed("launchpad: logs in the metadata")) {
            try await HistoryPagesStub(pages: [nil: HistoryDocs.data(HistoryDocs.page(scans: withLogs, next: nil))]).client().metadata(wallet: self.wallet)
        }
        await XCTAssertThrowsHistory(.malformed("a next page after the metadata")) {
            try await HistoryPagesStub(pages: [nil: HistoryDocs.data(HistoryDocs.page(scans: scans, next: HistoryDocs.cursorTwo))]).client().metadata(wallet: self.wallet)
        }
    }

    /// A cap raised while the read goes on clips the scan at the highest cap floor any page reported; a lower one never
    /// widens it.
    func testACapRaisedMidReadClips() async throws {
        let raised = try await HistoryPagesStub(pages: HistoryDocs.threePages(capTwo: 50_000_000)).client().read(wallet: wallet)
        let out = try XCTUnwrap(raised.scans[WalletHistoryScans.transfersOutId])
        XCTAssertEqual(out.capSeen, 50_000_000)
        XCTAssertEqual(out.adoptable, [50_000_000...(head - 1_200)])
        XCTAssertNil(raised.scans[WalletHistoryScans.transfersInId]?.capSeen, "each scan its own")

        var pages = HistoryDocs.threePages()
        var one = try XCTUnwrap(JSONSerialization.jsonObject(with: pages[String?.none]!) as? [String: Any])
        var scans = one["scans"] as! [String: Any]
        scans[WalletHistoryScans.transfersOutId] = HistoryDocs.account(WalletHistoryScans.transfersOutId, capFloor: 40_000_000, logs: HistoryDocs.outFirst)
        one["scans"] = scans
        pages[String?.none] = HistoryDocs.data(one)
        let lowered = try await HistoryPagesStub(pages: pages).client().read(wallet: wallet)
        XCTAssertEqual(lowered.scans[WalletHistoryScans.transfersOutId]?.capSeen, 40_000_000, "pages 2 and 3 say none: the first page's stands")
        XCTAssertEqual(lowered.scans[WalletHistoryScans.transfersOutId]?.adoptable, [40_000_000...(head - 1_200)])
    }

    /// A read stopped at its pages keeps what arrived: every scan before the cursor's whole, the cursor's above its last
    /// log served, the rest nothing.
    func testAReadCutShortKeepsWhatArrived() async throws {
        let one = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client(.init(pages: 1, seconds: 15)).read(wallet: wallet)
        XCTAssertFalse(one.finished)
        XCTAssertEqual(one.pages, 1)
        for id in [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId] {
            XCTAssertTrue(one.scans[id]?.finished == true, id)
            XCTAssertEqual(one.scans[id]?.adoptable, [HistoryDocs.floor(id)...(head - 1_200)], id)
        }
        let out = try XCTUnwrap(one.scans[WalletHistoryScans.transfersOutId])
        XCTAssertFalse(out.finished)
        XCTAssertEqual(out.lowestServedBlock, 109_000_000)
        XCTAssertEqual(out.adoptable, [109_000_001...(head - 1_200)], "above the last log served, whose block may be only partly served")
        XCTAssertEqual(one.scans[WalletHistoryScans.transfersInId]?.adoptable, [], "not reached: nothing")

        let two = try await HistoryPagesStub(pages: HistoryDocs.threePages()).client(.init(pages: 2, seconds: 15)).read(wallet: wallet)
        XCTAssertTrue(two.scans[WalletHistoryScans.transfersOutId]?.finished == true)
        XCTAssertEqual(two.scans[WalletHistoryScans.transfersOutId]?.adoptable, [0...(head - 1_200)])
        XCTAssertEqual(two.scans[WalletHistoryScans.transfersInId]?.adoptable, [], "listed, no log served: nothing")
    }

    /// A page that doesn't come back within the read's seconds ends the read with what arrived; no page at all is an
    /// error; a cancelled read is discarded, at once. The seconds are generous and the pages held far longer, so a loaded
    /// machine's slow first page can't turn the partial read into none.
    func testTheReadsSecondsAndCancellation() async throws {
        let started = ContinuousClock.now
        let slow = HistoryPagesStub(pages: HistoryDocs.threePages(), delays: [HistoryDocs.cursorTwo: 30])
        let partial = try await slow.client(.init(pages: 12, seconds: 3)).read(wallet: wallet)
        XCTAssertEqual(partial.pages, 1)
        XCTAssertFalse(partial.finished)
        XCTAssertEqual(partial.scans[WalletHistoryScans.transfersOutId]?.adoptable, [109_000_001...(head - 1_200)])
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(20), "the held page never waited out")

        await XCTAssertThrowsHistory(.timedOut) {
            try await HistoryPagesStub(pages: HistoryDocs.threePages(), delays: [nil: 30]).client(.init(pages: 12, seconds: 0.3)).read(wallet: self.wallet)
        }

        let held = HistoryPagesStub(pages: HistoryDocs.threePages(), delays: [nil: 30])
        let reading = Task { try await held.client().read(wallet: self.wallet) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = ContinuousClock.now
        reading.cancel()
        do {
            _ = try await reading.value
            XCTFail("a cancelled read")
        } catch let error as HistoryServerError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .seconds(3))
    }

    /// `tracked` or a scan's definition changing between pages, or the scans served, aborts the whole read.
    func testAReadAbortsWhenTrackedOrADefinitionChanges() async {
        await XCTAssertThrowsHistory(.changedBetweenPages("tracked")) {
            try await HistoryPagesStub(pages: HistoryDocs.threePages(trackedTwo: false)).client().read(wallet: self.wallet)
        }
        await XCTAssertThrowsHistory(.changedBetweenPages("moments: defVersion")) {
            try await HistoryPagesStub(pages: HistoryDocs.threePages(momentsVersionTwo: 2)).client().read(wallet: self.wallet)
        }
        var pages = HistoryDocs.threePages()
        var two = try! JSONSerialization.jsonObject(with: pages[HistoryDocs.cursorTwo]!) as! [String: Any]
        var scans = two["scans"] as! [String: Any]
        scans[WalletHistoryScans.transfersInId] = nil
        two["scans"] = scans
        pages[HistoryDocs.cursorTwo] = HistoryDocs.data(two)
        await XCTAssertThrowsHistory(.changedBetweenPages("the scans served")) {
            try await HistoryPagesStub(pages: pages).client().read(wallet: self.wallet)
        }
    }

    /// Everything else is discarded, the whole read, and the device reads the chain: an error, a status other than 2xx
    /// (on any page), another version, `serving` false, another wallet, anything that doesn't parse or breaks the rules.
    func testEverythingElseFailsOpen() async throws {
        let pages = HistoryDocs.threePages()
        await XCTAssertThrowsHistory(.http(500)) {
            try await HistoryPagesStub(pages: pages, failures: [nil: SupabaseError.http(500, "")]).client().read(wallet: self.wallet)
        }
        await XCTAssertThrowsHistory(.http(400)) {
            try await HistoryPagesStub(pages: pages, failures: [HistoryDocs.cursorThree: SupabaseError.http(400, "")]).client().read(wallet: self.wallet)
        }
        await XCTAssertThrowsHistory(.transport("URLError \(URLError.notConnectedToInternet.rawValue)")) {
            try await HistoryPagesStub(pages: pages, failures: [nil: URLError(.notConnectedToInternet)]).client().read(wallet: self.wallet)
        }

        // The first page, changed one way at a time.
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: pages[String?.none]!) as? [String: Any])
        func page(_ change: (inout [String: Any]) -> Void) -> Data {
            var copy = first
            change(&copy)
            return HistoryDocs.data(copy)
        }
        func scan(_ id: String, _ change: @escaping (inout [String: Any]) -> Void) -> Data {
            page { page in
                var scans = page["scans"] as! [String: Any]
                var scan = scans[id] as! [String: Any]
                change(&scan)
                scans[id] = scan
                page["scans"] = scans
            }
        }
        let out = WalletHistoryScans.transfersOutId
        var outLogs = HistoryDocs.outFirst.map(HistoryDocs.json)
        let cases: [(Data, HistoryServerError)] = [
            (Data(), .malformed("not a JSON object")),
            (Data("not json".utf8), .malformed("not a JSON object")),
            (Data("[]".utf8), .malformed("not a JSON object")),
            (page { $0["version"] = 2 }, .version(2)),
            (page { $0["version"] = nil }, .version(nil)),
            (page { $0["version"] = "1" }, .version(nil)),
            (Data(#"{"version":1,"serving":false,"wallet":"\#(wallet.hex)","scans":{},"next":null}"#.utf8), .notServing),
            (page { $0["serving"] = "true" }, .malformed("serving")),
            (page { $0["wallet"] = HistoryDocs.counterparty.hex }, .otherWallet),
            (page { $0["wallet"] = nil }, .otherWallet),
            (page { $0["tracked"] = nil }, .malformed("tracked")),
            (page { $0["scans"] = [] as [Any] }, .malformed("scans")),
            (page { $0["next"] = "v2:1:-:-:\(HistoryDocs.bounds)" }, .malformed("next")),
            (page { $0["next"] = "v1:9:-:-:\(HistoryDocs.bounds)" }, .malformed("next")),
            (page { $0["next"] = 4 }, .malformed("next")),
            (page { $0["head"] = -1 }, .malformed("head")),
            (page { $0["firstTx"] = ["state": "found", "block": NSNull()] }, .malformed("firstTx.block")),
            (page { $0["firstTx"] = ["state": "lost"] }, .malformed("firstTx.state")),
            (page { page in
                page["tracked"] = false
                var scans = page["scans"] as! [String: Any]
                scans[WalletHistoryScans.transfersInId] = nil
                page["scans"] = scans
            }, .malformed("transfers-out: a wallet scan of an untracked wallet")),
            (scan(WalletHistoryScans.launchpadId) { $0["kind"] = "wallet" }, .malformed("launchpad: kind")),
            (scan(out) { $0["defVersion"] = 1.5 }, .malformed("transfers-out: defVersion")),
            (scan(out) { $0["from"] = "0" }, .malformed("transfers-out: from")),
            (scan(out) { $0["covered"] = [[5, 4]] }, .malformed("transfers-out: covered")),
            (scan(out) { $0["holes"] = [[1]] }, .malformed("transfers-out: holes")),
            (scan(out) { $0["complete"] = nil }, .malformed("transfers-out: complete")),
            (scan(out) { $0["omitted"] = [["blockNumber": "0xzz"]] }, .malformed("transfers-out: an omitted log")),
            (scan(out) { $0["query"] = ["addresses": ["0x12"], "topics": []] }, .malformed("transfers-out: query")),
            (scan(out) { $0["query"] = ["addresses": [], "topics": [["0x1234"]]] }, .malformed("transfers-out: query")),
            (scan(out) { $0["headTimestamp"] = NSNull() }, .malformed("transfers-out: head without its time")),
            (scan(out) { $0["capFloor"] = "x" }, .malformed("transfers-out: capFloor")),
            (scan(out) { $0["logs"] = nil }, .malformed("transfers-out: logs")),
            (scan(out) { $0["logs"] = Array(outLogs.reversed()) }, .malformed("transfers-out: logs not newest first")),
            (scan(out) { $0["logs"] = [outLogs[1], outLogs[1]] }, .malformed("transfers-out: logs not newest first")),
            (scan(out) { $0["to"] = 109_500_000 }, .malformed("transfers-out: a log outside the bounds")),
            (scan(out) { $0["from"] = 1; $0["to"] = 0 }, .malformed("transfers-out: a log outside the bounds")),
        ]
        outLogs[0]["removed"] = true
        let withRemoved = scan(out) { $0["logs"] = outLogs }
        outLogs[0]["removed"] = false
        outLogs[0]["blockNumber"] = "0xg"
        let unparsable = scan(out) { $0["logs"] = outLogs }
        for (body, expected) in cases + [(withRemoved, .malformed("transfers-out: a log")), (unparsable, .malformed("transfers-out: a log"))] {
            await XCTAssertThrowsHistory(expected) {
                try await HistoryPagesStub(pages: [nil: body]).client().read(wallet: self.wallet)
            }
        }

        // Later pages: logs of a scan the cursor moved past, a cursor that doesn't move on.
        var two = try XCTUnwrap(JSONSerialization.jsonObject(with: pages[HistoryDocs.cursorTwo]!) as? [String: Any])
        var twoScans = two["scans"] as! [String: Any]
        twoScans[WalletHistoryScans.launchpadId] = HistoryDocs.later(logs: [HistoryDocs.log(103_600_000, scan: HistoryDocs.scan(WalletHistoryScans.launchpadId))])
        two["scans"] = twoScans
        var behind = pages
        behind[HistoryDocs.cursorTwo] = HistoryDocs.data(two)
        await XCTAssertThrowsHistory(.malformed("launchpad: logs after the cursor moved past it")) {
            try await HistoryPagesStub(pages: behind).client().read(wallet: self.wallet)
        }
        var stuck = pages
        stuck[HistoryDocs.cursorTwo] = HistoryDocs.data(HistoryDocs.page(scans: Dictionary(uniqueKeysWithValues: HistoryServerClient.scanOrder.map { ($0, HistoryDocs.later()) }),
                                                                         next: HistoryDocs.cursorTwo))
        await XCTAssertThrowsHistory(.malformed("a cursor that doesn't move on")) {
            try await HistoryPagesStub(pages: stuck).client().read(wallet: self.wallet)
        }
        var back = pages
        back[HistoryDocs.cursorTwo] = HistoryDocs.data(HistoryDocs.page(scans: Dictionary(uniqueKeysWithValues: HistoryServerClient.scanOrder.map { ($0, HistoryDocs.later()) }),
                                                                        next: "v1:3:-:-:\(HistoryDocs.bounds)"))
        await XCTAssertThrowsHistory(.malformed("a cursor that doesn't move on")) {
            try await HistoryPagesStub(pages: back).client().read(wallet: self.wallet)
        }

        // A scan the app doesn't know is left alone; an untracked wallet's three global scans are a read.
        let unknown = page { page in
            var scans = page["scans"] as! [String: Any]
            scans["airdrops"] = ["kind": "global", "whatever": true]
            page["scans"] = scans
            page["next"] = NSNull()
        }
        let read = try await HistoryPagesStub(pages: [nil: unknown]).client().read(wallet: wallet)
        XCTAssertEqual(Set(read.scans.keys), Set(WalletHistoryScans.ids))
        let untracked = page { page in
            var scans = page["scans"] as! [String: Any]
            scans[WalletHistoryScans.transfersInId] = nil
            scans[WalletHistoryScans.transfersOutId] = nil
            page["scans"] = scans
            page["tracked"] = false
            page["firstTx"] = NSNull()
            page["next"] = NSNull()
        }
        let globals = try await HistoryPagesStub(pages: [nil: untracked]).client().read(wallet: wallet)
        XCTAssertFalse(globals.tracked)
        XCTAssertNil(globals.firstTransaction)
        XCTAssertEqual(Set(globals.scans.keys), [WalletHistoryScans.launchpadId, WalletHistoryScans.feeSharingId, WalletHistoryScans.momentsId])
    }

    /// Fuzz: every field of the first page, of a scan's account and of a log, removed or replaced by a value of every JSON
    /// type, and the page cut at random points. Nothing crashes; a document that still reads keeps every rule — the
    /// adoptable blocks within what is covered and the bounds, never in a hole, an omitted log's block or the margin, every
    /// log within the bounds; a required field removed (or null) or made a string where it isn't one, and a cut page,
    /// never read.
    func testFuzzedDocumentsNeverCrashNorClaimMore() async throws {
        var one = try XCTUnwrap(JSONSerialization.jsonObject(with: HistoryDocs.threePages()[String?.none]!) as? [String: Any])
        one["next"] = NSNull()
        var scans = one["scans"] as! [String: Any]
        scans[WalletHistoryScans.transfersOutId] = HistoryDocs.account(WalletHistoryScans.transfersOutId, holes: [[90_000_000, 90_000_100]], omitted: [80_000_000],
                                                                       logs: HistoryDocs.outFirst)
        one["scans"] = scans
        let values: [Any?] = [nil, NSNull(), "x", -1, 1.5, [] as [Any], [:] as [String: Any], true, 7]
        func mutate(_ path: [String], in object: [String: Any], with value: Any?) -> [String: Any] {
            var copy = object
            if path.count == 1 { copy[path[0]] = value } else { copy[path[0]] = mutate(Array(path.dropFirst()), in: copy[path[0]] as! [String: Any], with: value) }
            return copy
        }
        // What must never read: a field the reader needs, removed or null (`removal`), or a string where it takes none
        // (`typed`). Anything else may read, or not, as long as what reads keeps the rules.
        func mustFail(_ key: String, _ value: Any?, removal: Set<String>, typed: Set<String>) -> Bool {
            (removal.contains(key) && (value == nil || value is NSNull)) || (typed.contains(key) && value is String)
        }
        var documents: [(data: Data, mustFail: Bool, what: String)] = []
        let topRemoval: Set = ["version", "serving", "wallet", "tracked", "scans"]
        for key in one.keys {
            for value in values {
                documents.append((HistoryDocs.data(mutate([key], in: one, with: value)),
                                  mustFail(key, value, removal: topRemoval, typed: topRemoval.union(["next", "head", "headTimestamp", "firstTx"])), key))
            }
        }
        let account = scans[WalletHistoryScans.transfersOutId] as! [String: Any]
        let accountRemoval: Set = ["kind", "defVersion", "query", "floor", "from", "to", "covered", "holes", "complete", "omitted", "omittedTruncated", "logs"]
        for key in account.keys {
            for value in values {
                documents.append((HistoryDocs.data(mutate(["scans", WalletHistoryScans.transfersOutId, key], in: one, with: value)),
                                  mustFail(key, value, removal: accountRemoval, typed: accountRemoval.union(["capFloor", "head", "headTimestamp"])), "transfers-out." + key))
            }
        }
        let logRemoval: Set = ["address", "topics", "data", "blockNumber", "transactionHash", "logIndex"]
        for key in HistoryDocs.json(HistoryDocs.outFirst[1]).keys {
            for value in values {
                var logs = HistoryDocs.outFirst.map(HistoryDocs.json)
                logs[1][key] = value
                documents.append((HistoryDocs.data(mutate(["scans", WalletHistoryScans.transfersOutId, "logs"], in: one, with: logs)),
                                  mustFail(key, value, removal: logRemoval, typed: logRemoval.union(["removed"])), "log." + key))
            }
        }
        let whole = HistoryDocs.data(one)
        var generator = SeededGenerator(seed: 0xD1A0)
        for _ in 0..<40 { documents.append((whole.prefix(Int.random(in: 1..<(whole.count - 1), using: &generator)), true, "cut")) }

        var read = 0, failed = 0
        for (document, mustFail, what) in documents {
            do {
                let result = try await HistoryPagesStub(pages: [String?.none: document]).client().read(wallet: wallet)
                read += 1
                XCTAssertFalse(mustFail, "\(what) read")
                for scan in result.scans.values {
                    let low = max(scan.from, scan.capSeen ?? 0)
                    for range in scan.adoptable {
                        XCTAssertTrue(range.lowerBound >= low && range.upperBound <= scan.to && range.upperBound + HistoryServerClient.trustMargin <= (scan.head ?? 0), what)
                        XCTAssertTrue(scan.covered.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }, what)
                        XCTAssertFalse(scan.holes.contains { $0.overlaps(range) }, what)
                        XCTAssertFalse(scan.omittedBlocks.contains { range.contains($0) }, what)
                    }
                    XCTAssertTrue(scan.logs.allSatisfy { $0.blockNumber >= scan.from && $0.blockNumber <= scan.to }, what)
                    if scan.omittedTruncated { XCTAssertEqual(scan.adoptable, [], what) }
                }
            } catch is HistoryServerError {
                failed += 1
            } catch {
                XCTFail("\(what): \(error)")
            }
        }
        XCTAssertGreaterThan(read, 20)
        XCTAssertGreaterThan(failed, 100)
    }

    /// A real document (`HistoryDocs.realPages`: migration 32's `history_read` on PGlite): two pages, read to the end with
    /// the cursor the first returned; the server's queries and fingerprints are the app's own (Postgres sorts the lists
    /// as the app does); every scan's adoptable blocks as the rule gives them — transfers-out whole from genesis,
    /// transfers-in without its hole and its omitted log's block — and every log once, newest first. Cut after the first
    /// page, transfers-out keeps the blocks above its last log served, and transfers-in, listed with no log, nothing.
    func testARealDocumentFromMigration32() async throws {
        let pages = try HistoryDocs.realPages()
        XCTAssertEqual(pages.count, 2)
        let stub = HistoryPagesStub(pages: pages)
        let read = try await stub.client().read(wallet: wallet)
        XCTAssertTrue(read.finished)
        XCTAssertEqual(read.pages, 2)
        XCTAssertTrue(read.tracked)
        XCTAssertEqual(read.firstTransaction, .found(103_551_773))
        XCTAssertEqual(read.head, head)
        let bodies = await stub.bodies
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.last?["p_cursor"]?.string?.hasPrefix("v1:4:103746540:0:"), true, "page 1 stopped inside transfers-out")
        for scan in HistoryDocs.scans() {
            let server = try XCTUnwrap(read.scan(scan), scan.id)
            XCTAssertTrue(scan.query.isSubset(of: server.query) && server.query.isSubset(of: scan.query), scan.id)
            XCTAssertEqual(server.fingerprint, scan.query.canonicalFingerprint, scan.id)
            XCTAssertEqual(server.head, head)
            XCTAssertTrue(server.finished, scan.id)
            XCTAssertEqual(Set(server.logs.map(\.id)).count, server.logs.count, "each log once: \(scan.id)")
        }
        let trusted = head - 1_200
        let launchpad = try XCTUnwrap(read.scans[WalletHistoryScans.launchpadId])
        XCTAssertEqual(launchpad.logs.map(\.blockNumber), [head - 5_000, 104_000_000, 104_000_000], "the wallet's three, not another wallet's")
        XCTAssertEqual(launchpad.adoptable, [103_542_521...trusted])
        XCTAssertEqual(read.scans[WalletHistoryScans.momentsId]?.logs.map(\.blockNumber), [106_000_000])
        XCTAssertEqual(read.scans[WalletHistoryScans.momentsId]?.adoptable, [105_347_754...trusted])
        XCTAssertEqual(read.scans[WalletHistoryScans.feeSharingId]?.logs, [])
        let out = try XCTUnwrap(read.scans[WalletHistoryScans.transfersOutId])
        XCTAssertEqual(out.logs.count, 2_100)
        XCTAssertEqual(out.logs.first?.blockNumber, head - 600)
        XCTAssertEqual(out.lowestServedBlock, head - 600 - 4_000 * 2_099)
        XCTAssertTrue(out.complete)
        XCTAssertEqual(out.adoptable, [0...trusted])
        let incoming = try XCTUnwrap(read.scans[WalletHistoryScans.transfersInId])
        XCTAssertEqual(incoming.logs.count, 40)
        XCTAssertEqual(incoming.holes, [110_000_000...110_000_000])
        XCTAssertEqual(incoming.omittedBlocks, [100_000_000])
        XCTAssertFalse(incoming.omittedTruncated)
        XCTAssertFalse(incoming.complete)
        XCTAssertEqual(incoming.adoptable, [0...99_999_999, 100_000_001...109_999_999, 110_000_001...trusted])

        let short = try await HistoryPagesStub(pages: pages).client(.init(pages: 1, seconds: 15)).read(wallet: wallet)
        XCTAssertEqual(short.scans[WalletHistoryScans.transfersOutId]?.adoptable, [103_746_541...trusted])
        XCTAssertEqual(short.scans[WalletHistoryScans.transfersInId]?.adoptable, [])
        XCTAssertEqual(short.scans[WalletHistoryScans.launchpadId]?.adoptable, launchpad.adoptable)
    }

    // MARK: The request

    /// `rpcJSON` posts the arguments as JSON — a block number as digits, never "1.0", a flag as a boolean, a null — with the
    /// publishable key, as `rpc` does, and surfaces a status other than 2xx with its body; the client sends the wallet
    /// lowercase and reads through it, a status other than 2xx failing the read open.
    func testTheRequestGoesAsJSONToTheRPC() async throws {
        let base = "https://fmnjqrguvopusfufmirs.supabase.co"
        let backend = SupabaseClient(url: URL(string: base)!, anonKey: "sb_publishable_test", session: WalletAuthCapture.session())
        WalletAuthCapture.reset()
        WalletAuthCapture.replies = [(200, #"{"ok":true}"#), (400, #"{"code":"22023","message":"p_cursor is not a cursor history_read returned"}"#)]
        let answer = try await backend.rpcJSON(name: "history_read", body: ["p_wallet": .string(wallet.hex), "p_from_block": .number(103_542_521), "p_meta_only": .bool(true),
                                                                            "p_cursor": .null])
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), #"{"ok":true}"#)
        let request = try XCTUnwrap(WalletAuthCapture.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "\(base)/rest/v1/rpc/history_read")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let sent = String(decoding: WalletAuthCapture.body(request), as: UTF8.self)
        for part in [#""p_from_block":103542521"#, #""p_meta_only":true"#, #""p_cursor":null"#, #""p_wallet":"\#(wallet.hex)""#] { XCTAssertTrue(sent.contains(part), sent) }
        XCTAssertFalse(sent.contains("103542521.0"))
        do {
            _ = try await backend.rpcJSON(name: "history_read", body: ["p_wallet": .string(wallet.hex), "p_cursor": .string("v1:9")])
            XCTFail("a 400")
        } catch SupabaseError.http(let status, let body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("22023"))
        }

        WalletAuthCapture.reset()
        WalletAuthCapture.replies = [(200, String(decoding: HistoryDocs.threePages()[String?.none]!, as: UTF8.self)), (503, "")]
        let client = HistoryServerClient(supabase: backend)
        await XCTAssertThrowsHistory(.http(503)) { try await client.read(wallet: Address(literal: self.wallet.checksummed)) }
        let asked = WalletAuthCapture.requests.map { String(decoding: WalletAuthCapture.body($0), as: UTF8.self) }
        XCTAssertEqual(asked.count, 2)
        XCTAssertTrue(asked[0].contains(#""p_wallet":"\#(wallet.hex)""#), "lowercase")
        XCTAssertTrue(asked[1].contains(#""p_cursor":"\#(HistoryDocs.cursorTwo)""#))
    }
}

/// Asserts `body` throws exactly `expected` (`HistoryServerError`).
func XCTAssertThrowsHistory<T>(_ expected: HistoryServerError, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("no error; expected \(expected)", file: file, line: line)
    } catch let error as HistoryServerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("\(error); expected \(expected)", file: file, line: line)
    }
}

/// A repeatable random sequence (SplitMix64), so a fuzz run is the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
