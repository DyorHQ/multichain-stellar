import Foundation
import XCTest
@testable import DyorKit

/// What the app mirrors to its backend waits on the device until an upload succeeds, within bounds (security audit
/// 2026-09-26, RS-4), and a whole list is mirrored by upsert-then-prune (RS-7).
final class BackendMirrorTests: XCTestCase {
    private struct Row: Codable, Sendable, Equatable { let value: Int }

    func testQueueKeepsTheNewestRowsUpToItsCap() {
        var queue = BackendMirrorQueue<Row>(cap: 3)
        for i in 1...5 { queue.enqueue(id: "\(i)", row: Row(value: i)) }
        XCTAssertEqual(queue.entries.map(\.id), ["3", "4", "5"])
    }

    func testRequeuingAnIdReplacesItsEarlierVersion() {
        var queue = BackendMirrorQueue<Row>(cap: 10)
        queue.enqueue(id: "a", row: Row(value: 1))
        queue.enqueue(id: "b", row: Row(value: 2))
        queue.enqueue(id: "a", row: Row(value: 3))
        XCTAssertEqual(queue.entries.map(\.id), ["b", "a"])
        XCTAssertEqual(queue.entries.last?.row, Row(value: 3))
    }

    func testOnlyTheUploadedVersionLeavesTheQueue() {
        var queue = BackendMirrorQueue<Row>(cap: 10)
        queue.enqueue(id: "a", row: Row(value: 1))
        queue.enqueue(id: "b", row: Row(value: 2))
        let sent = queue.entries
        // Re-recorded while the upload ran: the newer version must still go up.
        queue.enqueue(id: "a", row: Row(value: 9))
        queue.uploaded(sent)
        XCTAssertEqual(queue.entries.map(\.id), ["a"])
        XCTAssertEqual(queue.entries.first?.row, Row(value: 9))
    }

    func testARowTheServerKeepsRefusingIsDroppedAfterItsAttempts() {
        var queue = BackendMirrorQueue<Row>(cap: 10, maxAttempts: 3)
        queue.enqueue(id: "bad", row: Row(value: 1))
        queue.enqueue(id: "good", row: Row(value: 2))
        let bad = queue.entries.filter { $0.id == "bad" }
        queue.refused(bad)
        queue.refused(bad)
        XCTAssertEqual(queue.entries.count, 2)
        queue.refused(bad)
        XCTAssertEqual(queue.entries.map(\.id), ["good"])
    }

    func testQueueSurvivesARoundTripThroughStorage() throws {
        var queue = BackendMirrorQueue<Row>(cap: 5)
        queue.enqueue(id: "a", row: Row(value: 1))
        let decoded = try JSONDecoder().decode(BackendMirrorQueue<Row>.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(decoded.entries.map(\.id), ["a"])
        XCTAssertEqual(decoded.entries.first?.version, queue.entries.first?.version)
        XCTAssertEqual(decoded.cap, 5)
    }

    func testOutagesAreRetriedAndRefusalsCounted() {
        let unavailable: [Error] = [
            URLError(.notConnectedToInternet), URLError(.timedOut), CancellationError(),
            SupabaseError.notSignedIn, SupabaseError.rateLimited(retryAfter: 30),
            SupabaseError.http(401, "JWT expired"), SupabaseError.http(429, ""), SupabaseError.http(503, ""), SupabaseError.http(404, ""),
            // Migration 25 not applied yet: no unique constraint matches on_conflict=wallet,id.
            SupabaseError.http(400, #"{"code":"42P10","message":"there is no unique or exclusion constraint matching the ON CONFLICT specification"}"#),
            // The wallet's profile row isn't there yet (a new wallet's first rows racing its sign-in).
            SupabaseError.http(409, #"{"code":"23503","message":"insert or update on table "activity" violates foreign key constraint"}"#),
        ]
        for error in unavailable { XCTAssertEqual(BackendMirror.outcome(of: error), .unavailable, "\(error)") }
        let refused: [Error] = [
            SupabaseError.http(409, #"{"code":"23505","message":"duplicate key value violates unique constraint \"activity_pkey\""}"#),
            SupabaseError.http(403, #"{"code":"42501","message":"new row violates row-level security policy"}"#),
            SupabaseError.http(400, #"{"code":"22P02","message":"invalid input syntax"}"#),
        ]
        for error in refused { XCTAssertEqual(BackendMirror.outcome(of: error), .refused, "\(error)") }
    }

    func testPruneKeepsTheListedRows() {
        let keep = BackendMirror.pruneQuery(wallet: "0xab", kind: "price", keeping: ["id-1", "id-2"])
        XCTAssertEqual(keep, [URLQueryItem(name: "wallet", value: "eq.0xab"), URLQueryItem(name: "kind", value: "eq.price"),
                              URLQueryItem(name: "client_id", value: "not.in.(id-1,id-2)")])
        // Nothing kept: every row of that kind goes.
        XCTAssertEqual(BackendMirror.pruneQuery(wallet: "0xab", kind: "price", keeping: []),
                       [URLQueryItem(name: "wallet", value: "eq.0xab"), URLQueryItem(name: "kind", value: "eq.price")])
    }
}
