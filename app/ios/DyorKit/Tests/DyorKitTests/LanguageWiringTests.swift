import Foundation
import XCTest
@testable import DyorKit

/// The app's wiring of its language (build 18, L1), read from the app's sources and project: the store writes only
/// `LanguageResolution`'s keys (R4), the locale reaches every screen without rebuilding RootView, Delete Account brings
/// English back, the screens read the store, and the catalogs agree with the project.
final class LanguageWiringTests: XCTestCase {
    private static func ios() throws -> URL {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return ios
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: try ios().appendingPathComponent(path), encoding: .utf8)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    private static func between(_ text: String, _ start: String, _ end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start).upperBound
        let to = try XCTUnwrap(text.range(of: end, range: from..<text.endIndex), end).lowerBound
        return String(text[from..<to])
    }

    /// R4: the language's two keys don't start with a prefix that marks an install as one from before App Lock's default
    /// (`Theme.swift`'s `earlierRun`), so writing them on the first launch leaves App Lock ON for a new install. The
    /// app's store writes no key of its own.
    func testNoLanguageKeyMarksAnEarlierInstall() throws {
        let theme = try Self.source("DyorHQ/Design/Theme.swift")
        let earlierRun = try XCTUnwrap(theme.range(of: "let earlierRun = [")).upperBound
        let quotesAndSpace = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))
        let prefixes = theme[earlierRun...].prefix { $0 != "]" }.split(separator: ",").map { $0.trimmingCharacters(in: quotesAndSpace) }
        XCTAssertTrue(prefixes.contains("settings.") && prefixes.contains("perp."), "\(prefixes)")
        XCTAssertEqual(LanguageResolution.appleLanguagesKey, "AppleLanguages")
        XCTAssertEqual(LanguageResolution.initializedKey, "language.initialized")
        for key in [LanguageResolution.appleLanguagesKey, LanguageResolution.initializedKey] {
            for prefix in prefixes { XCTAssertFalse(key.hasPrefix(prefix), "\(key) would mark a new install as earlier (\(prefix))") }
        }

        let store = try Self.source("DyorHQ/App/LanguageStore.swift")
        XCTAssertFalse(store.contains("forKey: \""), "no key literal: LanguageResolution's two keys only")
        XCTAssertFalse(store.contains(".set("), "every write goes through LanguageResolution.save")
        XCTAssertFalse(store.contains("removeObject"))
        XCTAssertTrue(Self.squeezed(store).contains("if let write = launch.write { LanguageResolution.save(write, to: defaults) }"))
        XCTAssertTrue(Self.squeezed(store).contains("if let write = resolution.write { LanguageResolution.save(write, to: defaults) }"))
        for prefix in prefixes { XCTAssertFalse(store.contains("\"\(prefix)"), prefix) }
    }

    /// The language reaches every screen through the environment's locale, set on RootView, which is never rebuilt with an
    /// `.id`: its `.task(id:)` jobs (the backend sign-in, the restore, the per-account binding) must not restart.
    func testTheLocaleReachesEveryScreenWithoutRebuildingRootView() throws {
        let root = try Self.source("DyorHQ/App/RootView.swift")
        let rootView = try Self.between(root, "struct RootView: View {", "extension RootView {")
        XCTAssertFalse(rootView.contains(".id("), "never an .id on RootView")
        XCTAssertTrue(rootView.contains(".environment(\\.locale, env.language.locale)"))
        let app = try Self.source("DyorHQ/App/DyorHQApp.swift")
        XCTAssertFalse(app.contains(".id("))
        XCTAssertTrue(app.contains(".environment(environment.language)"))
        let environment = Self.squeezed(try Self.source("DyorHQ/App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains("let language = LanguageStore()"))
        XCTAssertEqual(environment.components(separatedBy: "LanguageStore(").count - 1, 1, "one store")

        // The store sets both locales from one value.
        let store = Self.squeezed(try Self.source("DyorHQ/App/LanguageStore.swift"))
        XCTAssertEqual(store.components(separatedBy: "L10n.locale = locale").count - 1, 2, "at launch and on every change")
        XCTAssertTrue(store.contains("func tr(_ resource: LocalizedStringResource) -> String { L10n.string(resource) }"))
    }

    /// A navigation title and a search prompt, which UIKit draws, are `String`s from `tr()`. A key's title is resolved once,
    /// when its screen is shown, so a screen open during a change of language kept its old title (Profile read "Profil" in
    /// Spanish); `tr()` reads `L10n.locale`, which is observable, so the title is drawn again in the new language.
    func testTitlesAndSearchPromptsFollowTheLanguage() throws {
        var titles = 0
        var found: [String] = []
        for (path, text) in try FormattedTextIsolationTests.appSources() {
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if line.contains(".navigationTitle(") { titles += 1 }
                if line.range(of: #"\.navigationTitle\([^)]*"[^"]*[A-Za-z][^"]*""#, options: .regularExpression) != nil,
                   line.range(of: #"\.navigationTitle\((Text\(verbatim:|tr\(|[^"]*\? tr\()"#, options: .regularExpression) == nil {
                    found.append("\(path):\(number + 1): \(code)")
                }
                if line.range(of: #"\.searchable\(.*prompt: ""#, options: .regularExpression) != nil {
                    found.append("\(path):\(number + 1): \(code)")
                }
            }
        }
        XCTAssertEqual(found, [], "a key's title or prompt stays in the language it was first shown in: write it in tr()")
        XCTAssertGreaterThan(titles, 50, "the scan reads the app's titles")
    }

    /// Delete Account and Forget This Device erase the app's defaults, the saved language with them; the erase then sets
    /// the language back to English, saved and on screen, before the sign-out.
    func testTheEraseSetsTheLanguageBackToEnglish() throws {
        let session = try Self.source("DyorHQ/Wallet/Session.swift")
        let erase = try Self.between(session, "func eraseLocalData() async {", "private var relyingParty")
        let wipe = try XCTUnwrap(erase.range(of: "AppLockStore.erase(UserDefaults.standard"))
        let reset = try XCTUnwrap(erase.range(of: "language?.reset()"))
        let signedOut = try XCTUnwrap(erase.range(of: "state = .signedOut"))
        XCTAssertLessThan(wipe.upperBound, reset.lowerBound, "after the defaults are erased")
        XCTAssertLessThan(reset.upperBound, signedOut.lowerBound, "before the sign-out")
        XCTAssertTrue(session.contains("@ObservationIgnored weak var language: LanguageStore?"))
        XCTAssertTrue(try Self.source("DyorHQ/App/AppEnvironment.swift").contains("session.language = language"))
        let store = Self.squeezed(try Self.source("DyorHQ/App/LanguageStore.swift"))
        XCTAssertTrue(store.contains("func reset() { apply(LanguageResolution.erased(device: Self.deviceLanguages(defaults), shipped: shipped)) }"))
    }

    /// The Language screen offers System and the languages the bundle ships, in their own names; Profile shows the
    /// language in use; the onboarding menu uses the same store and appears once a second language ships.
    func testTheScreensReadTheStore() throws {
        let settings = try Self.source("DyorHQ/Profile/Settings.swift")
        let screen = Self.squeezed(try Self.between(settings, "struct LanguageView: View {", "struct LanguageMenu: View {"))
        XCTAssertTrue(screen.contains("ForEach(language.available) { option in row(.language(option)) { Text(verbatim: option.endonym) } }"))
        XCTAssertTrue(screen.contains("Text(\"Uses your device language (\\(language.deviceLanguageName))\")"))
        XCTAssertTrue(screen.contains("if language.available.count < 2 { Text(\"More languages are coming in the next update.\") }"))
        XCTAssertTrue(screen.contains("Button { language.select(choice) }"))
        let store = Self.squeezed(try Self.source("DyorHQ/App/LanguageStore.swift"))
        XCTAssertTrue(store.contains("available = AppLanguage.shipped(in: shipped)"))
        XCTAssertTrue(store.contains("shipped = bundle.localizations"))
        XCTAssertTrue(store.contains("var deviceLanguageName: String { LanguageResolution.deviceLanguageName(device: Self.deviceLanguages(defaults)) }"),
                      "the System row names the device's language, not the one System falls back to")
        // The device's list is the global domain's own: the app's AppleLanguages shadows it in the standard search and in
        // Locale.preferredLanguages, and persistentDomain(forName:) of the global domain comes back without it in an iOS
        // app, which named the app's language as the device's and made System keep it.
        let devices = try Self.between(store, "private static func deviceLanguages(_ defaults: UserDefaults) -> [String] {", "func tr(")
        let global = try XCTUnwrap(devices.range(of: "CFPreferencesCopyAppValue(LanguageResolution.appleLanguagesKey as CFString, kCFPreferencesAnyApplication)"))
        let fallback = try XCTUnwrap(devices.range(of: "return Locale.preferredLanguages"))
        XCTAssertLessThan(global.upperBound, fallback.lowerBound, "the global domain first, iOS's list last")

        let profile = try Self.source("DyorHQ/Profile/ProfileView.swift")
        XCTAssertTrue(profile.contains("SettingsRow(\"Language\", symbol: \"globe\", tint: .accent); Spacer(); Text(language.resolved.endonym)"))

        let onboarding = Self.squeezed(try Self.source("DyorHQ/Onboarding/OnboardingView.swift"))
        XCTAssertTrue(onboarding.contains("if language.available.count > 1 { ToolbarItem(placement: .topBarTrailing) { LanguageMenu() } }"))
        let menu = Self.squeezed(try Self.between(settings, "struct LanguageMenu: View {", "struct AppearanceSheet: View {"))
        XCTAssertTrue(menu.contains("set: { language.select($0) }"))
    }

    /// The catalogs and the project: English is the development language everywhere, the bundle lists only the languages
    /// that ship (and no catalog carries another), the permission strings in the InfoPlist catalog are the Info.plist's
    /// own, and the app's name is never translated.
    func testTheCatalogsAndTheProjectAgree() throws {
        let ios = try Self.ios()
        let project = try Self.source("project.yml")
        XCTAssertTrue(project.contains("\n  developmentLanguage: en\n"))
        XCTAssertTrue(project.contains("\n    LOCALIZATION_PREFERS_STRING_CATALOGS: YES\n"))
        XCTAssertTrue(project.contains("\n    SWIFT_EMIT_LOC_STRINGS: YES\n"))
        let package = Self.squeezed(try Self.source("DyorKit/Package.swift"))
        XCTAssertTrue(package.contains("defaultLocalization: \"en\","))
        XCTAssertTrue(package.contains("], resources: [.process(\"Resources\")]),"))

        let info = try XCTUnwrap(NSDictionary(contentsOf: ios.appendingPathComponent("DyorHQ/Info.plist")) as? [String: Any])
        let shipped = try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
        XCTAssertEqual(shipped, ["en", "es", "fr", "zh-Hans", "ko"], "English and the four complete translations")
        XCTAssertTrue(project.contains("        CFBundleLocalizations: [\(shipped.joined(separator: ", "))]\n"), "Info.plist regenerated from project.yml")

        func catalog(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: ios.appendingPathComponent(path))
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], path)
            XCTAssertEqual(json["sourceLanguage"] as? String, "en", path)
            return try XCTUnwrap(json["strings"] as? [String: Any], path)
        }
        let catalogs = ["DyorHQ/Resources/Localizable.xcstrings", "DyorHQ/Resources/InfoPlist.xcstrings",
                        "DyorKit/Sources/DyorKit/Resources/Localizable.xcstrings"]
        for path in catalogs {
            for (key, entry) in try catalog(path) {
                let languages = ((entry as? [String: Any])?["localizations"] as? [String: Any])?.keys.map { $0 } ?? []
                for language in languages { XCTAssertTrue(shipped.contains(language), "\(path): \(key) has \(language), which doesn't ship") }
            }
        }

        let plist = try catalog("DyorHQ/Resources/InfoPlist.xcstrings")
        for key in ["NSFaceIDUsageDescription", "NSPhotoLibraryUsageDescription", "CFBundleDisplayName", "CFBundleName"] {
            let entry = try XCTUnwrap(plist[key] as? [String: Any], key)
            let english = (((entry["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertEqual(english, info[key] as? String, "\(key): the catalog's English is the Info.plist's, byte for byte")
        }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            XCTAssertEqual((plist[key] as? [String: Any])?["shouldTranslate"] as? Bool, false, "\(key): DyorHQ is never translated")
        }
    }

    /// `String(localized:…, locale:)` never selects a language (its locale only formats the arguments), so no source uses
    /// it: text goes through `tr()` or `L10n.tr`.
    func testNoSourceResolvesTextWithALocaleArgument() throws {
        let ios = try Self.ios()
        var checked = 0
        for folder in ["DyorHQ", "DyorKit/Sources"] {
            let files = FileManager.default.enumerator(at: ios.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" {
                checked += 1
                for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n") where line.contains("String(localized:") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    XCTAssertFalse(line.contains("locale:"), "\(file.lastPathComponent): \(line)")
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
    }
}
