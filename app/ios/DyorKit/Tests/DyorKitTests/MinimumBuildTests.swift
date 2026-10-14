import XCTest
@testable import DyorKit

/// The minimum supported iOS build (security audit 2026-09-26, GP-2): the public `app_config` row 'ios' the app reads
/// with the publishable key, and how it fails open.
final class MinimumBuildTests: XCTestCase {
    private let base = "https://fmnjqrguvopusfufmirs.supabase.co"
    private lazy var backend = SupabaseClient(url: URL(string: base)!, anonKey: "sb_publishable_test", session: WalletAuthCapture.session())

    override func setUp() {
        super.setUp()
        WalletAuthCapture.reset()
    }

    private func parse(_ json: String) -> MinimumBuild? { MinimumBuild.parse(Data(json.utf8)) }

    func testMinimumBuildParsesTheSeededRow() throws {
        let seeded = try XCTUnwrap(parse(#"[{"value":{"min_build":0,"message":"","url":"https://testflight.apple.com"}}]"#))
        XCTAssertEqual(seeded, MinimumBuild(minBuild: 0, message: "", url: URL(string: "https://testflight.apple.com")))
        XCTAssertFalse(seeded.requiresUpdate(bundleVersion: "13"), "the seeded row blocks nothing")
        XCTAssertFalse(seeded.requiresUpdate(bundleVersion: "0"))

        let raised = try XCTUnwrap(parse(#"[{"value":{"min_build":15,"message":"  Update to keep trading.  ","url":"https://apps.apple.com/app/dyorhq"}}]"#))
        XCTAssertEqual(raised.minBuild, 15)
        XCTAssertEqual(raised.message, "Update to keep trading.")
        XCTAssertTrue(raised.requiresUpdate(bundleVersion: "13"))
        XCTAssertTrue(raised.requiresUpdate(bundleVersion: "14"))
        XCTAssertFalse(raised.requiresUpdate(bundleVersion: "15"))
        XCTAssertFalse(raised.requiresUpdate(bundleVersion: "16"))
    }

    /// Anything unexpected fails open: no minimum, or no block for a version that isn't a whole number.
    func testMinimumBuildFailsOpen() throws {
        for bad in ["[]", "{}", "not json", #"[{"value":null}]"#, #"[{"value":{"message":"x"}}]"#,
                    #"[{"value":{"min_build":"15"}}]"#, #"[{"value":{"min_build":-1}}]"#, #"[{"value":{"min_build":15.5}}]"#,
                    #"[{"value":{"min_build":true}}]"#, #"[{"value":{"min_build":1e300}}]"#,
                    #"[{"value":{"min_build":15}},{"value":{"min_build":16}}]"#] {
            XCTAssertNil(parse(bad), bad)
        }
        let row = try XCTUnwrap(parse(#"[{"value":{"min_build":15}}]"#))
        XCTAssertEqual(row.message, "")
        XCTAssertNil(row.url)
        for version in [nil, "", "abc", "13.1", "-20", " "] {
            XCTAssertFalse(row.requiresUpdate(bundleVersion: version), version ?? "nil")
        }
        // Only an https link is ever opened.
        for url in ["http://example.com", "javascript:alert(1)", "itms-services://?action=download", "https://", "not a url"] {
            XCTAssertNil(try XCTUnwrap(parse(#"[{"value":{"min_build":15,"url":"\#(url)"}}]"#)).url, url)
        }
        XCTAssertEqual(try XCTUnwrap(parse(#"[{"value":{"min_build":15,"message":"\#(String(repeating: "a", count: 900))"}}]"#)).message.count, 500)
    }

    /// The owner's message is written in English: the Update screen shows it only while the app is in English, and its own
    /// text, in the app's language, in any other language or when the row has none.
    func testTheOwnersMessageIsShownOnlyInEnglish() throws {
        let row = try XCTUnwrap(parse(#"[{"value":{"min_build":18,"message":"Update to keep trading."}}]"#))
        XCTAssertEqual(row.ownerMessage(in: .en), "Update to keep trading.")
        for language in AppLanguage.allCases where language != .en {
            XCTAssertNil(row.ownerMessage(in: language), language.code)
        }
        XCTAssertEqual(AppLanguage.allCases.filter { row.ownerMessage(in: $0) != nil }, [.en])
        XCTAssertNil(MinimumBuild(minBuild: 18, message: "", url: nil).ownerMessage(in: .en), "no message: the app's own text")
    }

    func testMinimumBuildReadsTheIOSRowWithThePublishableKey() async throws {
        WalletAuthCapture.replies = [(200, #"[{"value":{"min_build":14,"message":"","url":"https://testflight.apple.com"}}]"#)]
        let row = try await backend.minimumBuild()
        XCTAssertEqual(row?.minBuild, 14)
        let request = try XCTUnwrap(WalletAuthCapture.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "\(base)/rest/v1/app_config?key=eq.ios&select=value")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sb_publishable_test")
    }
}
