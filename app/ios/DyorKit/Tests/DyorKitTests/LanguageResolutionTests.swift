import Foundation
import Observation
import XCTest
@testable import DyorKit

/// The app's language (build 18, L1): English by default, System on request, stored as iOS's per-app language
/// (`LanguageResolution`), and applied at once through `L10n.locale`. The app's wiring is `LanguageWiringTests`.
final class LanguageResolutionTests: XCTestCase {
    /// Every language build 19 plans to ship.
    private let all = ["en", "es", "fr", "zh-Hans", "ko"]

    // MARK: - System

    /// System follows the device's ordered language list as iOS matches it, among the shipped languages only, and falls
    /// back to English.
    func testSystemFollowsTheDeviceAmongTheShippedLanguages() {
        let cases: [([String], AppLanguage)] = [
            (["de", "fr"], .fr), (["de"], .en), (["zh-Hant-TW"], .en), (["zh-CN"], .zhHans),
            (["es-419"], .es), (["fr-CA"], .fr), (["pt-BR"], .en), (["ko-KR"], .ko),
            (["zh-Hans-SG"], .zhHans), (["zh-HK"], .en), (["en-GB", "fr"], .en), ([], .en),
        ]
        for (device, expected) in cases {
            XCTAssertEqual(LanguageResolution.systemLanguage(device: device, shipped: all), expected, "\(device)")
            let launch = LanguageResolution.launch(stored: nil, initialized: true, device: device, shipped: all)
            XCTAssertEqual(launch.choice, .system, "\(device)")
            XCTAssertEqual(launch.resolved, expected, "\(device)")
            XCTAssertNil(launch.write, "System is read, never written at launch")
        }
        // While only English ships, every device gets English, whatever its language.
        for (device, _) in cases {
            for shipped in [["en"], ["Base", "en"], []] {
                XCTAssertEqual(LanguageResolution.systemLanguage(device: device, shipped: shipped), .en, "\(device) \(shipped)")
            }
        }
        // A language counts only once it ships: French without Spanish sends es-419 to English.
        XCTAssertEqual(LanguageResolution.systemLanguage(device: ["es-419", "fr-CA"], shipped: ["en", "fr"]), .fr)
        XCTAssertEqual(LanguageResolution.systemLanguage(device: ["es-419"], shipped: ["en", "fr"]), .en)
    }

    // MARK: - English by default

    /// The table behind owner decision 16.
    func testEnglishIsTheDefault() {
        let device = ["fr-FR", "en"]
        let english = LanguageResolution.Write(appleLanguages: ["en"], markInitialized: true)

        // No marker: a new install, the first launch after the update, or the first after an erase. English, saved with
        // the marker, whatever the device's language and whatever was in the key.
        for stored in [nil, ["fr"], ["ko-KR"]] as [[String]?] {
            let first = LanguageResolution.launch(stored: stored, initialized: false, device: device, shipped: all)
            XCTAssertEqual(first.choice, .language(.en), "\(String(describing: stored))")
            XCTAssertEqual(first.resolved, .en)
            XCTAssertEqual(first.write, english)
        }

        // Marker and no key: System, chosen in the app or as "Default" in iOS Settings.
        let system = LanguageResolution.launch(stored: nil, initialized: true, device: device, shipped: all)
        XCTAssertEqual(system.choice, .system)
        XCTAssertEqual(system.resolved, .fr)
        XCTAssertNil(system.write)
        XCTAssertEqual(LanguageResolution.launch(stored: [], initialized: true, device: device, shipped: all).choice, .system)

        // Marker and a key: that language, as the app saves it or as iOS Settings does (with a region).
        for (stored, expected) in [(["en"], AppLanguage.en), (["ko"], .ko), (["zh-Hans"], .zhHans), (["fr-US"], .fr), (["zh-Hans-US"], .zhHans)] {
            let chosen = LanguageResolution.launch(stored: stored, initialized: true, device: device, shipped: all)
            XCTAssertEqual(chosen.choice, .language(expected), "\(stored)")
            XCTAssertEqual(chosen.resolved, expected, "\(stored)")
            XCTAssertNil(chosen.write, "\(stored)")
        }
        // A saved language this build doesn't ship shows as what the app is actually in (English), and stays saved for
        // the build that ships it.
        let unshipped = LanguageResolution.launch(stored: ["fr"], initialized: true, device: device, shipped: ["en"])
        XCTAssertEqual(unshipped.choice, .language(.en))
        XCTAssertEqual(unshipped.resolved, .en)
        XCTAssertNil(unshipped.write)

        // Choosing System removes the key and keeps the marker; choosing a language saves it alone.
        let toSystem = LanguageResolution.select(.system, device: device, shipped: all)
        XCTAssertEqual(toSystem.choice, .system)
        XCTAssertEqual(toSystem.resolved, .fr)
        XCTAssertEqual(toSystem.write, LanguageResolution.Write(appleLanguages: nil, markInitialized: true))
        for language in AppLanguage.allCases {
            let chosen = LanguageResolution.select(.language(language), device: device, shipped: all)
            XCTAssertEqual(chosen.choice, .language(language))
            XCTAssertEqual(chosen.resolved, language)
            XCTAssertEqual(chosen.write, LanguageResolution.Write(appleLanguages: [language.code], markInitialized: true))
        }

        // An erase: English again.
        let erased = LanguageResolution.erased(device: device, shipped: all)
        XCTAssertEqual(erased.choice, .language(.en))
        XCTAssertEqual(erased.resolved, .en)
        XCTAssertEqual(erased.write, english)
    }

    /// A store in memory, as `UserDefaults` keeps the app's domain apart from the device's global one.
    private final class Store: LanguageDefaults {
        let app = "fun.dyorhq.app"
        var domains: [String: [String: Any]] = [:]
        func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
        func set(_ value: Any?, forKey defaultName: String) { domains[app, default: [:]][defaultName] = value }
        func removeObject(forKey defaultName: String) { domains[app]?[defaultName] = nil }
    }

    /// The whole life of an install, through the store: the first launch saves English, a choice of System is read back
    /// as System, iOS Settings' "Default" and its languages are honoured, and an erase brings English back.
    func testTheStoredChoiceRoundTrips() throws {
        let store = Store()
        store.domains[UserDefaults.globalDomain] = [LanguageResolution.appleLanguagesKey: ["fr-FR"]]
        let device = ["fr-FR"]

        func launch() -> LanguageResolution {
            let stored = LanguageResolution.stored(in: store, domain: store.app)
            let resolution = LanguageResolution.launch(stored: stored.appleLanguages, initialized: stored.initialized, device: device, shipped: all)
            if let write = resolution.write { LanguageResolution.save(write, to: store) }
            return resolution
        }
        func saved() -> [String: Any] { store.domains[store.app] ?? [:] }

        // The device's own list is never read as the app's choice.
        XCTAssertNil(LanguageResolution.stored(in: store, domain: store.app).appleLanguages)
        XCTAssertEqual(launch().choice, .language(.en), "a new install starts in English on a French phone")
        XCTAssertEqual(saved()[LanguageResolution.appleLanguagesKey] as? [String], ["en"])
        XCTAssertEqual(saved()[LanguageResolution.initializedKey] as? Bool, true)
        XCTAssertEqual(store.domains[UserDefaults.globalDomain]?[LanguageResolution.appleLanguagesKey] as? [String], ["fr-FR"], "untouched")
        XCTAssertEqual(launch().choice, .language(.en), "and stays English")
        XCTAssertNil(launch().write)

        LanguageResolution.save(try XCTUnwrap(LanguageResolution.select(.system, device: device, shipped: all).write), to: store)
        XCTAssertNil(saved()[LanguageResolution.appleLanguagesKey])
        XCTAssertEqual(saved()[LanguageResolution.initializedKey] as? Bool, true)
        let system = launch()
        XCTAssertEqual(system.choice, .system, "System is never mistaken for a new install")
        XCTAssertEqual(system.resolved, .fr)

        // iOS Settings › Apps › DyorHQ › Language writes the same key.
        store.set(["ko"], forKey: LanguageResolution.appleLanguagesKey)
        XCTAssertEqual(launch().choice, .language(.ko))
        store.removeObject(forKey: LanguageResolution.appleLanguagesKey)
        XCTAssertEqual(launch().choice, .system, "\"Default\" there is System here")

        LanguageResolution.save(try XCTUnwrap(LanguageResolution.select(.language(.es), device: device, shipped: all).write), to: store)
        XCTAssertEqual(saved()[LanguageResolution.appleLanguagesKey] as? [String], ["es"])
        XCTAssertEqual(launch().choice, .language(.es))

        // Delete Account erases the app's domain; the app's reset then saves English again.
        store.domains[store.app] = nil
        LanguageResolution.save(try XCTUnwrap(LanguageResolution.erased(device: device, shipped: all).write), to: store)
        XCTAssertEqual(saved()[LanguageResolution.appleLanguagesKey] as? [String], ["en"])
        XCTAssertEqual(launch().choice, .language(.en))
        XCTAssertEqual(Set(saved().keys), [LanguageResolution.appleLanguagesKey, LanguageResolution.initializedKey], "nothing else is written")
    }

    // MARK: - Languages and the locale

    func testTheLanguagesAndTheirNames() {
        XCTAssertEqual(AppLanguage.allCases.map(\.code), ["en", "es", "fr", "zh-Hans", "ko"])
        XCTAssertEqual(AppLanguage.allCases.map(\.endonym), ["English", "Español", "Français", "简体中文", "한국어"])
        XCTAssertEqual(AppLanguage.shipped(in: ["en"]), [.en])
        XCTAssertEqual(AppLanguage.shipped(in: ["Base", "en"]), [.en])
        XCTAssertEqual(AppLanguage.shipped(in: []), [.en], "English is the development language: always there")
        XCTAssertEqual(AppLanguage.shipped(in: ["ko", "fr", "en", "de", "zh-Hant"]), [.en, .fr, .ko], "picker order, known languages only")
        XCTAssertEqual(AppLanguage.shipped(in: all), AppLanguage.allCases)
    }

    /// The System row names the device's own language, shipped or not: a French phone reads "Français" while only
    /// English ships, and a German phone "Deutsch", not the English it falls back to.
    func testTheSystemRowNamesTheDeviceLanguage() {
        let cases: [([String], String)] = [
            (["fr-CA"], "Français"), (["fr-FR", "en-US"], "Français"), (["es-419"], "Español"), (["ko-KR"], "한국어"),
            (["zh-CN"], "简体中文"), (["zh-Hans-CN"], "简体中文"), (["en-GB"], "English"), (["en-US", "fr-FR"], "English"),
            (["de-DE"], "Deutsch"), (["de", "fr"], "Deutsch"), (["pt-BR"], "Português"), (["it"], "Italiano"),
            (["zh-Hant-TW"], "繁體中文"), (["zh-HK"], "繁體中文"), (["ja-JP"], "日本語"), (["nb-NO"], "Norsk bokmål"),
            (["sr-Latn-RS"], "Srpski (latinica)"), ([], "English"), (["xx"], "xx"),
        ]
        for (device, expected) in cases {
            XCTAssertEqual(LanguageResolution.deviceLanguageName(device: device), expected, "\(device)")
        }
        // What System then shows is a separate matter: English while only English ships.
        XCTAssertEqual(LanguageResolution.systemLanguage(device: ["fr-CA"], shipped: ["en"]), .en)
    }

    /// The locale keeps the device's region and its format settings; a device already in the language keeps its own
    /// locale untouched, so nothing about dates moves for an English phone in English.
    func testTheLocaleKeepsTheDeviceRegion() {
        let ghana = Locale(identifier: "en_US@rg=ghzzzz")
        XCTAssertEqual(L10n.locale(for: .en, device: ghana), ghana)
        XCTAssertEqual(L10n.locale(for: .en, device: Locale(identifier: "en_GH")), Locale(identifier: "en_GH"))

        let cases: [(AppLanguage, String, String, String)] = [
            (.fr, "es_ES", "fr", "ES"), (.en, "fr_FR", "en", "FR"), (.zhHans, "fr_FR", "zh", "FR"),
            (.ko, "en_US@rg=gbzzzz", "ko", "GB"), (.zhHans, "zh-Hant_TW", "zh", "TW"), (.es, "en_GH", "es", "GH"),
        ]
        for (language, device, code, region) in cases {
            let locale = L10n.locale(for: language, device: Locale(identifier: device))
            XCTAssertEqual(locale.language.languageCode?.identifier, code, "\(language) on \(device)")
            XCTAssertEqual(locale.region?.identifier, region, "\(language) on \(device)")
        }
        XCTAssertEqual(L10n.locale(for: .zhHans, device: Locale(identifier: "zh-Hant_TW")).language.script?.identifier, "Hans")
        XCTAssertEqual(L10n.locale(for: .zhHans, device: Locale(identifier: "fr_FR")).identifier, "zh-Hans_FR")
        XCTAssertEqual(L10n.locale(for: .fr, device: Locale(identifier: "es_ES")).identifier, "fr_ES")

        let arabicDigits = L10n.locale(for: .en, device: Locale(identifier: "de_DE@numbers=arab"))
        XCTAssertEqual(arabicDigits.numberingSystem.identifier, "arab")
        XCTAssertEqual(L10n.locale(for: .es, device: Locale(identifier: "en_US@calendar=japanese")).calendar.identifier, .japanese)
        XCTAssertEqual(L10n.locale(for: .fr, device: Locale(identifier: "en_US@hours=h12")).hourCycle, .oneToTwelve, "a 12-hour clock stays")

        // Prices are the one fixed style in every language: they never read the locale.
        XCTAssertEqual(PriceFormat.usdValue(1234.5), "$1,234.50")
    }

    /// `L10n.locale` reads back what was set, from any thread, and a reader tracking it (a SwiftUI body that called
    /// `tr`) is told when it changes. DyorKit's text comes from its own bundle.
    func testTheCurrentLocaleIsObservedAndLocked() async {
        let original = L10n.locale
        defer { L10n.locale = original }

        let french = L10n.locale(for: .fr, device: Locale(identifier: "fr_FR"))
        let changed = expectation(description: "a reader of the locale is told it changed")
        withObservationTracking { _ = L10n.locale } onChange: { changed.fulfill() }
        L10n.locale = french
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(L10n.locale, french)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask { L10n.locale = i.isMultiple(of: 2) ? french : original; _ = L10n.locale.identifier }
            }
        }
        XCTAssertTrue([french, original].contains(L10n.locale))

        // `swift test` copies the catalog uncompiled, so a lookup returns its English source; the bundle is DyorKit's.
        L10n.locale = french
        XCTAssertEqual(L10n.tr("Approve \("USDC")"), "Approve USDC")
        XCTAssertEqual(L10n.bundle.bundleURL.lastPathComponent, "DyorKit_DyorKit.bundle")
    }
}
