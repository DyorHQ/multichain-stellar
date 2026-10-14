import Foundation
import XCTest
@testable import DyorKit

/// The ages on the coin cards and in the trade and activity rows, and the bridge's time estimate (`RelativeTime`): in
/// English exactly as the app always wrote them ("45s", "3m", "2h", "5d", "600s"), and in each other language with its
/// own narrow units; the number is always plain digits.
final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let english = Locale(identifier: "en_US")

    private func age(_ seconds: Int, _ locale: Locale? = nil) -> String {
        RelativeTime.short(1_800_000_000 - seconds, now: now, locale: locale ?? english)
    }

    func testEnglishReadsAsBefore() {
        XCTAssertEqual(RelativeTime.short(0, now: now, locale: english), "", "no time")
        XCTAssertEqual(age(0), "0s")
        XCTAssertEqual(age(59), "59s")
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(3599), "59m", "rounded down")
        XCTAssertEqual(age(3600), "1h")
        XCTAssertEqual(age(86_399), "23h")
        XCTAssertEqual(age(86_400), "1d")
        XCTAssertEqual(age(40 * 86_400 + 5), "40d", "days, never weeks")
        XCTAssertEqual(age(-30), "0s", "a time ahead of the clock")
        XCTAssertEqual(age(2 * 86_400, Locale(identifier: "en_GB")), "2d")
        XCTAssertEqual(RelativeTime.seconds(600, locale: english), "600s", "the bridge's estimate stays in seconds")
        XCTAssertEqual(RelativeTime.seconds(30, locale: english), "30s")
    }

    func testOtherLanguagesUseTheirOwnUnits() {
        XCTAssertEqual(age(5 * 86_400, Locale(identifier: "fr_FR")), "5j")
        XCTAssertEqual(age(180, Locale(identifier: "es_ES")), "3 min")
        XCTAssertEqual(age(2 * 3600, Locale(identifier: "zh-Hans_CN")), "2小时")
        XCTAssertEqual(age(5 * 86_400, Locale(identifier: "ko_KR")), "5일")
    }

    /// The number is plain digits whatever the device's region or numbering: only the unit is the language's. A long
    /// bridge estimate reads "1200s" as before, never "1,200s", "1.200s", "1 200s" or "1’200s", and a device set to
    /// Devanagari or Arabic digits still reads "45s" and "3m" in English, as the prices beside them do.
    func testNumbersArePlainDigits() {
        for region in ["en_US", "de_DE", "fr_FR", "de_CH", "en_IN"] {
            XCTAssertEqual(RelativeTime.seconds(1200, locale: Locale(identifier: region)), "1200s", region)
        }
        XCTAssertEqual(age(1234 * 86_400), "1234d")
        XCTAssertEqual(age(1234 * 86_400, Locale(identifier: "fr_FR")), "1234j")
        XCTAssertEqual(RelativeTime.seconds(1200, locale: Locale(identifier: "es_ES")), "1200 s")
        for device in ["hi_IN@numbers=deva", "ar_EG", "en_US@numbers=arab"] {
            let english = L10n.locale(for: .en, device: Locale(identifier: device))
            XCTAssertEqual(age(45, english), "45s", device)
            XCTAssertEqual(age(180, english), "3m", device)
            XCTAssertEqual(RelativeTime.seconds(1200, locale: english), "1200s", device)
        }
    }

    /// Without a locale it follows the app's language (`L10n.locale`), not the device's.
    func testDefaultsToTheAppLanguage() {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(RelativeTime.short(Int(Date().timeIntervalSince1970) - 3 * 86_400 - 10), "3j")
        L10n.locale = english
        XCTAssertEqual(RelativeTime.short(Int(Date().timeIntervalSince1970) - 3 * 86_400 - 10), "3d")
    }
}
