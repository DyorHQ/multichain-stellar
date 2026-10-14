import XCTest
@testable import DyorKit

/// Email & Password safety rules from the 2026-09-26 audit: outages told apart from refusals (GE-6), password characters
/// another keyboard may type differently (IOSK-9), and which email bindings may still be legacy (GE-1).
final class AccountSafetyTests: XCTestCase {
    // MARK: Outages (GE-6)

    func testOutagesAreToldApartFromRefusals() {
        XCTAssertTrue(SupabaseError.isOutage(SupabaseError.http(503, "")))
        XCTAssertTrue(SupabaseError.isOutage(SupabaseError.http(500, "")))
        XCTAssertTrue(SupabaseError.isOutage(URLError(.timedOut)))
        XCTAssertTrue(SupabaseError.isOutage(URLError(.notConnectedToInternet)))
        XCTAssertFalse(SupabaseError.isOutage(SupabaseError.http(401, "")))
        XCTAssertFalse(SupabaseError.isOutage(SupabaseError.http(429, "")))
        XCTAssertFalse(SupabaseError.isOutage(SupabaseError.rateLimited(retryAfter: 60)))
        XCTAssertFalse(SupabaseError.isOutage(EmailPepperError.verificationExpired))
        XCTAssertFalse(SupabaseError.isOutage(URLError(.cancelled)))
        XCTAssertEqual(SupabaseError.http(503, "").errorDescription, "DyorHQ's server isn't answering right now (503). Try again in a minute.")
    }

    // MARK: Email & Password inputs (IOSK-9, GE-1)

    func testHardToRetypePasswordCharactersAreFlagged() {
        for plain in ["Correct-Horse-9!", "a b\"c'd--e...f", "~!@#$%^&*()_+{}|:<>?`-=[]\\;',./"] {
            XCTAssertFalse(EmailWallet.hasHardToRetypeCharacters(plain), plain)
        }
        for tricky in ["Correct\u{201C}Horse\u{201D}9", "it\u{2019}s-long-pass9", "dash\u{2014}dash\u{2013}99", "wait\u{2026}Now9",
                       "caf\u{E9}Latte99!", "cafe\u{301}Latte99!", "no\u{A0}break99!", "tab\tinside99!", "emoji\u{1F510}99!"] {
            XCTAssertTrue(EmailWallet.hasHardToRetypeCharacters(tricky), tricky)
        }
    }

    /// Warning about a password never changes what it derives: the seed is of the exact bytes typed.
    func testTheDerivationKeepsTheExactBytes() {
        let curly = EmailWallet.legacySeed(email: "a@b.co", password: "it\u{2019}s-a-long-pass9")
        let straight = EmailWallet.legacySeed(email: "a@b.co", password: "it's-a-long-pass9")
        XCTAssertNotNil(curly)
        XCTAssertNotEqual(curly, straight)
    }

    /// PostgREST's timestamptz, with or without fractional seconds, to the second (the legacy check reads profiles.created_at).
    func testPostgresTimestampsParse() {
        let expected = ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")
        XCTAssertEqual(SupabaseClient.timestamp("2026-09-20T10:00:00.123456+00:00"), expected)
        XCTAssertEqual(SupabaseClient.timestamp("2026-09-20T10:00:00+00:00"), expected)
        XCTAssertEqual(SupabaseClient.timestamp("2026-09-20T10:00:00.5Z"), expected)
        XCTAssertEqual(SupabaseClient.timestamp("2026-09-20T12:00:00.1+02:00"), expected)
        XCTAssertNil(SupabaseClient.timestamp("yesterday"))
        XCTAssertNil(SupabaseClient.timestamp(""))
    }

    func testLegacyBindingsAreJudgedConservatively() {
        let cutoff = EmailWallet.v2Cutoff
        XCTAssertEqual(ISO8601DateFormatter().string(from: cutoff), "2026-09-24T00:00:00Z")
        XCTAssertTrue(EmailWallet.mayBeLegacy(profileCreatedAt: nil), "an unknown profile may be legacy")
        XCTAssertTrue(EmailWallet.mayBeLegacy(profileCreatedAt: cutoff.addingTimeInterval(-1)))
        XCTAssertTrue(EmailWallet.mayBeLegacy(profileCreatedAt: ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z")))
        XCTAssertFalse(EmailWallet.mayBeLegacy(profileCreatedAt: cutoff))
        XCTAssertFalse(EmailWallet.mayBeLegacy(profileCreatedAt: ISO8601DateFormatter().date(from: "2026-09-26T10:00:00Z")))
    }
}
