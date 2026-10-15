@testable import DyorLite
import Foundation
import XCTest

/// The package's catalog (Sources/DyorLite/Resources/Localizable.xcstrings) and `LiteL10n`: every entry has a note
/// for its translator and the four languages the app ships, with the same values to fill in as its key, and network
/// and product names as they are; `tr` follows `LiteL10n.locale`, as the app's `L10n` does.
final class LiteL10nTests: XCTestCase {
    private static let languages = ["es", "fr", "ko", "zh-Hans"]
    /// Names that are never translated.
    private static let names = ["Monad", "Stellar", "DyorHQ", "Blend", "Soroswap", "Circle", "USDC", "XLM", "Moment", "Freighter", "LOBSTR", "xBull"]

    private static func catalog() throws -> [String: [String: Any]] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() } // LiteL10nTests.swift → DyorLiteTests → Tests → DyorLite
        url.appendPathComponent("Sources/DyorLite/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("the package's sources aren't readable from here") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceLanguage"] as? String, "en")
        return try XCTUnwrap(json["strings"] as? [String: [String: Any]])
    }

    /// The values a string takes (%@, %lld, …), positions dropped, in order of position when they are numbered.
    private static func specifiers(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(@|lld|ld|d|lf|f)"#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let found = matches.enumerated().map { index, match -> (Int, String) in
            let position = Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) } ?? index + 1
            return (position, String(text[Range(match.range(at: 2), in: text)!]))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// A localization's values: one string, or each plural form.
    private static func values(_ localization: [String: Any]) -> [String] {
        if let unit = localization["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
        let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] ?? [:]
        return plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
    }

    func testEveryEntryHasANoteAndTheFourLanguages() throws {
        let strings = try Self.catalog()
        XCTAssertGreaterThan(strings.count, 150)
        for (key, entry) in strings {
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, "no note for the translator: \(key)")
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            // A key that isn't its own English ("activity.done") carries its English.
            let english = localizations["en"].map(Self.values) ?? [key]
            XCTAssertFalse(english.isEmpty, key)
            let expected = Self.specifiers(english.first ?? key)
            for language in Self.languages {
                let values = localizations[language].map(Self.values) ?? []
                XCTAssertFalse(values.isEmpty, "\(language) is missing: \(key)")
                for value in values {
                    XCTAssertFalse(value.isEmpty, "\(language) is empty: \(key)")
                    XCTAssertEqual(Self.specifiers(value), expected, "\(language) takes other values than its key: \(key) → \(value)")
                    for name in Self.names where key.contains(name) {
                        XCTAssertTrue(value.contains(name), "\(language) translates or drops the name \(name): \(key) → \(value)")
                    }
                }
            }
        }
    }

    func testTheCatalogIsThePackagesOwn() {
        XCTAssertEqual(LiteL10n.bundle.bundleURL.lastPathComponent, "DyorLite_DyorLite.bundle")
        let raw = LiteL10n.bundle.url(forResource: "Localizable", withExtension: "xcstrings")
        let compiled = LiteL10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
        XCTAssertTrue(raw != nil || compiled != nil, "the catalog is in the package's resource bundle")
    }

    /// `tr` resolves in `LiteL10n.locale`, whatever the device's language: words, values and plurals.
    func testTextFollowsTheLocaleTheHostSets() throws {
        guard LiteL10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "fr") != nil else {
            throw XCTSkip("the catalog is compiled into the bundle by Xcode's build (xcodebuild), not by swift build")
        }
        let saved = LiteL10n.locale
        defer { LiteL10n.locale = saved }

        LiteL10n.locale = Locale(identifier: "en_US")
        XCTAssertEqual(tr("Testnet"), "Testnet")
        XCTAssertEqual(tr("\(1) trades"), "1 trade")
        XCTAssertEqual(tr("\(12) trades"), "12 trades")
        XCTAssertEqual(tr("Sign in to \("Anchor")"), "Sign in to Anchor")
        XCTAssertEqual(tr("95% goes to the creator. Your edition carries a 5% creator royalty for future sales."),
                       "95% goes to the creator. Your edition carries a 5% creator royalty for future sales.", "a percent sign stays one")
        XCTAssertEqual(tr("\(42)% to graduation"), "42% to graduation")
        XCTAssertEqual(LiteL10n.string(LocalizedStringResource("activity.done", defaultValue: "Done", bundle: LiteL10n.lite)), "Done")

        LiteL10n.locale = Locale(identifier: "fr_FR")
        XCTAssertEqual(tr("Sign in to \("Anchor")"), "Se connecter à Anchor")
        XCTAssertEqual(LiteSession.Failure.cancelled.errorDescription, "Pas terminé. Réessayez.")
        XCTAssertEqual(tr("\(1) trades"), "1 transaction")
        XCTAssertEqual(tr("\(3) trades"), "3 transactions")
        XCTAssertEqual(tr("\(42)% to graduation"), "42% vers la graduation")
        XCTAssertEqual(LiteL10n.string(LocalizedStringResource("activity.done", defaultValue: "Done", bundle: LiteL10n.lite)), "Terminé")
        XCTAssertEqual(LiteSession.Failure.offline.errorDescription, "Pas de connexion. Vérifiez votre réseau et réessayez.")

        LiteL10n.locale = Locale(identifier: "ko_KR")
        XCTAssertEqual(tr("Testnet"), "테스트넷")
        XCTAssertEqual(tr("\(2) of \(100)"), "100개 중 2개", "values reordered by position")

        LiteL10n.locale = Locale(identifier: "zh-Hans_CN")
        XCTAssertEqual(tr("Switch to Monad"), "切换到 Monad")

        LiteL10n.locale = Locale(identifier: "es_ES")
        XCTAssertEqual(tr("Get \("10.000") test XLM"), "Obtener 10.000 XLM de prueba")
    }

    func testDollarsReadTheSameInEveryLanguage() {
        XCTAssertEqual(usd(0), "$0.00")
        XCTAssertEqual(usd(10_512.4), "$10,512.40")
        XCTAssertEqual(usd(1_234_567.891), "$1,234,567.89")
        XCTAssertEqual(usd(0.004), "<$0.01")
        XCTAssertEqual(usd(-5), "−$5.00")
    }

    func testKoreanParagraphsBreakBetweenWords() {
        XCTAssertTrue(LiteWordWrap.keepsWordsWhole(Locale(identifier: "ko_KR").language))
        XCTAssertFalse(LiteWordWrap.keepsWordsWhole(Locale(identifier: "en_US").language))
        XCTAssertEqual(LiteWordWrap.lines(of: "잠금 해제하면  Stellar 잔액을\n볼 수 있어요."), [["잠금", "해제하면", "Stellar", "잔액을"], ["볼", "수", "있어요."]])
        XCTAssertEqual(LiteWordWrap.lines(of: "Confirm with Face ID"), [["Confirm", "with", "Face ID"]], "Apple's names stay whole")
    }
}
