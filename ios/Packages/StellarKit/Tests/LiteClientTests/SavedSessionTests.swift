import Foundation
@testable import LiteClient
import XCTest

/// The session item `StellarKeychain` keeps (`LiteSavedSession`): the refresh token is kept with the access token, an
/// item saved before refresh tokens still loads, and an older build still reads a newer item.
final class SavedSessionTests: XCTestCase {
    private let expiresAt = Date(timeIntervalSince1970: 1_791_970_860) // 2026-10-14T09:41:00Z
    private let refreshExpiresAt = Date(timeIntervalSince1970: 1_794_562_860) // 2026-11-13T09:41:00Z

    func testKeepsTheRefreshToken() throws {
        let saved = LiteSavedSession(token: "access", expiresAt: expiresAt, refreshToken: "lrt_next", refreshExpiresAt: refreshExpiresAt)
        XCTAssertEqual(LiteSavedSession(data: try saved.data()), saved)
        let fields = try JSONDecoder().decode([String: String].self, from: try saved.data())
        XCTAssertEqual(fields, ["token": "access", "expiresAt": "2026-10-14T09:41:00Z", "refreshToken": "lrt_next", "refreshExpiresAt": "2026-11-13T09:41:00Z"])
    }

    func testASessionWithoutARefreshToken() throws {
        let saved = LiteSavedSession(token: "access", expiresAt: expiresAt)
        let read = try XCTUnwrap(LiteSavedSession(data: try saved.data()))
        XCTAssertEqual(read, saved)
        XCTAssertNil(read.refreshToken)
        XCTAssertNil(read.refreshExpiresAt)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: try saved.data()).keys.sorted(), ["expiresAt", "token"])
    }

    /// An answer that gave a refresh token without its expiry: the token is still kept.
    func testARefreshTokenWithoutItsExpiryIsKept() throws {
        let saved = LiteSavedSession(token: "access", expiresAt: expiresAt, refreshToken: "lrt_next")
        let read = try XCTUnwrap(LiteSavedSession(data: try saved.data()))
        XCTAssertEqual(read.refreshToken, "lrt_next")
        XCTAssertNil(read.refreshExpiresAt)
    }

    /// The item as StellarKeychain wrote it before refresh tokens.
    func testAnOlderItemLoads() throws {
        let read = try XCTUnwrap(LiteSavedSession(data: Data(#"{"token":"access","expiresAt":"2026-10-14T09:41:00Z"}"#.utf8)))
        XCTAssertEqual(read, LiteSavedSession(token: "access", expiresAt: expiresAt))
    }

    /// What a build before refresh tokens reads from a newer item: the access token and its expiry, as it always did.
    func testAnOlderBuildReadsANewerItem() throws {
        let data = try LiteSavedSession(token: "access", expiresAt: expiresAt, refreshToken: "lrt_next", refreshExpiresAt: refreshExpiresAt).data()
        let fields = try JSONDecoder().decode([String: String].self, from: data)
        XCTAssertEqual(fields["token"], "access")
        XCTAssertEqual(fields["expiresAt"].flatMap(ISO8601DateFormatter().date(from:)), expiresAt)
    }

    func testAnythingElseIsNoSession() {
        for item in [#"{"token":"access"}"#, #"{"expiresAt":"2026-10-14T09:41:00Z"}"#, #"{"token":"access","expiresAt":"tomorrow"}"#,
                     #"{"token":"access","expiresAt":1791970860}"#, "[]", "not json", ""] {
            XCTAssertNil(LiteSavedSession(data: Data(item.utf8)), item)
        }
    }
}
