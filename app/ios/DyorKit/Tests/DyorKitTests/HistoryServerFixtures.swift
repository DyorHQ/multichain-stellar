import BigInt
import Foundation
@testable import DyorKit

/// `history_read` documents in the shape of the contract's example (the server spec's §6, migration 32's
/// `history_read`), built for the app's five scans of one wallet, and a transport that answers them page by page
/// (`HistoryPagesStub`). Not a test file itself.
enum HistoryDocs {
    static let wallet = Address(literal: "0x90f3e7c3b4e32494b06814fd2f4556671f5f4c47")
    static let head: UInt64 = 111_727_140
    static let headTimestamp = 1_791_497_853
    static let token = Address(literal: "0x6666666666666666666666666666666666666666")
    static let counterparty = Address(literal: "0x5555555555555555555555555555555555555555")

    /// The app's five scans of `wallet`, as the release build passes them (the live stacks and cohorts).
    static func scans(_ wallet: Address = wallet) -> [HistoryScan] {
        [WalletHistoryScans.launchpad(wallet: wallet),
         WalletHistoryScans.feeSharing(wallet: wallet, stacks: DyorCoinRegistry.launchpads(live: .monadMainnet)),
         WalletHistoryScans.moments(wallet: wallet, cohorts: DyorCoinRegistry.cohorts(live: .monadMainnet)),
         WalletHistoryScans.transfersOut(wallet: wallet),
         WalletHistoryScans.transfersIn(wallet: wallet)]
    }

    static func scan(_ id: String, _ wallet: Address = wallet) -> HistoryScan { scans(wallet).first { $0.id == id }! }

    /// The floor the server reads each scan from: a global scan's first contract, a wallet scan's genesis.
    static func floor(_ id: String) -> UInt64 {
        switch scan(id).floor {
        case .block(let block): return block
        default: return 0
        }
    }

    /// A query as `history_read` prints it: every list sorted, lowercase, a position that takes anything null.
    static func query(_ query: LogsQuery) -> [String: Any] {
        ["addresses": query.addresses.map(\.hex).sorted(),
         "topics": query.topics.map { position -> Any in position.map { $0.map(\.hexString).sorted() } ?? NSNull() }]
    }

    /// A log `scan`'s filter matches, at `block`: its first event, the wallet where the scan names it, the counterparty
    /// at a position it leaves open, from its first contract (or a token, for a scan of any contract).
    static func log(_ block: UInt64, _ index: Int = 0, scan: HistoryScan, timestamp: Int? = nil) -> Log {
        var topics: [Data] = []
        for position in scan.query.topics { topics.append(position?.first ?? counterparty.data.leftPadded(to: 32)) }
        let hash = BigUInt(block * 1_000 + UInt64(index)).word
        return Log(address: scan.query.addresses.first ?? token, topics: topics, data: BigUInt(block).word, blockNumber: block, transactionHash: hash, logIndex: index,
                   blockTimestamp: timestamp ?? Int(1_700_000_000 + block % 1_000_000))
    }

    /// A log as eth_getLogs and `history_read` print it (hex quantities, `removed` false).
    static func json(_ log: Log) -> [String: Any] {
        var object: [String: Any] = ["address": log.address.hex, "topics": log.topics.map(\.hexString), "data": log.data.hexString,
                                     "blockNumber": BigUInt(log.blockNumber).hexQuantity, "transactionHash": log.transactionHash.hexString,
                                     "logIndex": BigUInt(log.logIndex).hexQuantity, "removed": false]
        if let timestamp = log.blockTimestamp { object["blockTimestamp"] = BigUInt(timestamp).hexQuantity }
        return object
    }

    /// A scan's first-page document.
    static func account(_ id: String, wallet: Address = wallet, defVersion: Int = 1, capFloor: UInt64? = nil, from: UInt64? = nil, to: UInt64 = head,
                        covered: [[UInt64]]? = nil, holes: [[UInt64]] = [], head scanHead: UInt64? = head, complete: Bool? = nil,
                        omitted: [UInt64] = [], omittedTruncated: Bool = false, logs: [Log] = []) -> [String: Any] {
        let scan = scan(id, wallet)
        let from = from ?? max(floor(id), capFloor ?? 0)
        let covered = covered ?? [[from, to]]
        let complete = complete ?? (holes.isEmpty && covered == [[from, to]])
        return ["kind": HistoryServerClient.kinds[id] == .wallet ? "wallet" : "global", "defVersion": defVersion, "query": query(scan.query),
                "fingerprint": scan.query.canonicalFingerprint, "floor": floor(id), "capFloor": capFloor.map { $0 as Any } ?? NSNull(), "from": from, "to": to,
                "covered": covered, "holes": holes, "head": scanHead.map { $0 as Any } ?? NSNull(),
                "headTimestamp": scanHead == nil ? NSNull() as Any : headTimestamp as Any, "complete": complete,
                "omitted": omitted.map { ["blockNumber": BigUInt($0).hexQuantity, "transactionHash": Data(repeating: 0xAA, count: 32).hexString, "logIndex": "0x0",
                                          "address": token.hex] },
                "omittedTruncated": omittedTruncated, "logs": logs.map(json)]
    }

    /// A scan's document on a later page.
    static func later(defVersion: Int = 1, capFloor: UInt64? = nil, logs: [Log] = []) -> [String: Any] {
        ["defVersion": defVersion, "capFloor": capFloor.map { $0 as Any } ?? NSNull(), "logs": logs.map(json)]
    }

    /// A page: `firstTx` only on the first, as `history_read` sends it.
    static func page(wallet: Address = wallet, tracked: Bool = true, firstTx: Any? = nil, scans: [String: [String: Any]], next: String?) -> [String: Any] {
        ["version": 1, "serving": true, "wallet": wallet.hex, "tracked": tracked, "firstTx": firstTx ?? NSNull(), "head": head, "headTimestamp": headTimestamp,
         "scans": scans, "next": next ?? NSNull()]
    }

    static func data(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// Page 1's five `<from>-<to>` pairs, as a cursor carries them.
    static let bounds = "103542521-111727140,103542521-111727140,105347754-111727140,0-111727140,0-111727140"

    // The three-page read of a tracked wallet the tests share: page 1 carries every scan's account, the launchpad's and the
    // Moments' logs, and transfers-out's newest three; page 2 the rest of transfers-out; page 3 transfers-in.
    static var launchpadLogs: [Log] { [log(head - 5_000, 3, scan: scan(WalletHistoryScans.launchpadId)), log(104_000_000, scan: scan(WalletHistoryScans.launchpadId))] }
    static var momentsLogs: [Log] { [log(106_000_000, scan: scan(WalletHistoryScans.momentsId))] }
    static var outFirst: [Log] {
        let out = scan(WalletHistoryScans.transfersOutId)
        return [log(head - 100, scan: out), log(110_000_000, 1, scan: out), log(110_000_000, scan: out), log(109_000_000, scan: out)]
    }
    static var outSecond: [Log] { [log(108_000_000, scan: scan(WalletHistoryScans.transfersOutId)), log(50_000_000, scan: scan(WalletHistoryScans.transfersOutId))] }
    static var inLogs: [Log] { [log(111_000_000, scan: scan(WalletHistoryScans.transfersInId)), log(103_500_000, scan: scan(WalletHistoryScans.transfersInId))] }
    static let inHole: UInt64 = 110_201_300
    static let cursorTwo = "v1:4:109000000:0:\(bounds)"
    static let cursorThree = "v1:5:-:-:\(bounds)"

    /// The three pages, by the cursor that asks each (nil: the first). `capTwo`: the cap floor page 2 reports for
    /// transfers-out; `tracked`/`defVersion`: what page 2 says.
    static func threePages(capTwo: UInt64? = nil, trackedTwo: Bool = true, momentsVersionTwo: Int = 1, firstTx: Any? = ["state": "found", "block": 103_551_773]) -> [String?: Data] {
        let one = page(firstTx: firstTx, scans: [
            WalletHistoryScans.launchpadId: account(WalletHistoryScans.launchpadId, logs: launchpadLogs),
            WalletHistoryScans.feeSharingId: account(WalletHistoryScans.feeSharingId),
            WalletHistoryScans.momentsId: account(WalletHistoryScans.momentsId, logs: momentsLogs),
            WalletHistoryScans.transfersOutId: account(WalletHistoryScans.transfersOutId, logs: outFirst),
            WalletHistoryScans.transfersInId: account(WalletHistoryScans.transfersInId, covered: [[103_140_000, inHole - 1], [inHole + 1, head]], holes: [[inHole, inHole]],
                                                      complete: false),
        ], next: cursorTwo)
        var laterScans: [String: [String: Any]] = [:]
        for id in HistoryServerClient.scanOrder { laterScans[id] = later() }
        var two = laterScans
        two[WalletHistoryScans.transfersOutId] = later(capFloor: capTwo, logs: outSecond)
        two[WalletHistoryScans.momentsId] = later(defVersion: momentsVersionTwo)
        var three = laterScans
        three[WalletHistoryScans.transfersOutId] = later(capFloor: capTwo)
        three[WalletHistoryScans.transfersInId] = later(logs: inLogs)
        return [nil: data(one), cursorTwo: data(page(tracked: trackedTwo, scans: two, next: cursorThree)), cursorThree: data(page(scans: three, next: nil))]
    }
}

extension HistoryDocs {
    /// A REAL document: every page of one full read of `wallet`, as `history_read` answered it on a throwaway PGlite
    /// database with migration 32 applied (the server branch's harness, `supabase/tests/history_pglite_db.ts`), seeded the
    /// way the indexer writes — enrolment by a profile upsert, `history_commit` for every scan, `history_mark_hole` and
    /// `history_set_first_tx` — at head 111,727,140:
    /// - launchpad: three curve buys by the wallet (one 5,000 below the head; one by another wallet, not served);
    /// - fee-sharing: covered, nothing; Moments: one collect;
    /// - transfers-out: 2,100 transfers, one every 4,000 blocks down from 600 below the head, covered from genesis — two
    ///   pages (page 1 stops at 2,000 logs, `next` continuing transfers-out);
    /// - transfers-in: 40 transfers, one every 150,000 blocks down from 900 below the head, a hole at block 110,000,000
    ///   and one log too large to serve at 100,000,000 (`omitted`);
    /// - the first transaction found at 103,551,773.
    /// Kept gzipped (44 KB for 1.1 MB): the leak guard unpacks and scans a gzip like any text. Built by
    /// `supabase/tests/make_history_read_fixture.ts` (beside the harness it imports): when `history_read` changes, run it
    /// again and commit the new fixture with the change; its `--check` says whether this one still matches.
    static func realPages() throws -> [String?: Data] {
        guard let url = Bundle.module.url(forResource: "history-read-pages.json", withExtension: "gz", subdirectory: "Fixtures") else { throw CocoaError(.fileNoSuchFile) }
        let gzip = try Data(contentsOf: url)
        // gzip with no optional fields (Python's gzip.compress): a 10-byte header and an 8-byte trailer around raw deflate.
        guard gzip.count > 18, Array(gzip.prefix(4)) == [0x1F, 0x8B, 0x08, 0x00] else { throw CocoaError(.fileReadCorruptFile) }
        let raw = try (gzip.subdata(in: 10..<(gzip.count - 8)) as NSData).decompressed(using: .zlib) as Data
        guard let document = try JSONSerialization.jsonObject(with: raw) as? [String: Any], let pages = document["pages"] as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var out: [String?: Data] = [:]
        var cursor: String?
        for page in pages {
            out[cursor] = try JSONSerialization.data(withJSONObject: page)
            cursor = page["next"] as? String
        }
        return out
    }
}

/// Answers `history_read` pages by the cursor each request carries (nil: the first), and records every request's body.
/// A page can be held back (`delays`, cancellable) or fail (`failures`); a cursor with no page is an HTTP 400, as the
/// server answers a cursor it never returned.
actor HistoryPagesStub {
    private(set) var bodies: [[String: JSON]] = []
    private var pages: [String?: Data]
    private var delays: [String?: TimeInterval]
    private var failures: [String?: any Error]

    init(pages: [String?: Data], delays: [String?: TimeInterval] = [:], failures: [String?: any Error] = [:]) {
        self.pages = pages
        self.delays = delays
        self.failures = failures
    }

    func answer(_ body: [String: JSON]) async throws -> Data {
        bodies.append(body)
        let cursor = body["p_cursor"]?.string
        if let delay = delays[cursor] { try await Task.sleep(for: .seconds(delay)) }
        if let failure = failures[cursor] { throw failure }
        guard let page = pages[cursor] else { throw SupabaseError.http(400, #"{"code":"22023","message":"p_cursor is not a cursor history_read returned"}"#) }
        return page
    }

    nonisolated func client(_ limits: HistoryServerClient.Limits = .standard) -> HistoryServerClient {
        HistoryServerClient(limits: limits) { body in try await self.answer(body) }
    }
}
