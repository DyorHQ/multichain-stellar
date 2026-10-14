import Foundation
import XCTest

/// Every language the app ships is complete in every String Catalog, read from the catalogs' JSON: each key a catalog
/// asks to translate (not marked never to translate, not stale) has the language's localization, translated and not
/// empty in every form (each plural category, "other" always among them), with the English's format specifiers (the
/// same positions and types, positional when there are two or more). CFBundleLocalizations (Info.plist, from
/// project.yml) lists English and exactly the languages the three catalogs complete, so the Language screen never
/// offers a language that would show English in places. scripts/dev/merge-translations.py writes the translations and
/// refuses the same mistakes.
final class ShippedLanguagesTests: XCTestCase {
    private static let catalogs = ["DyorHQ/Resources/Localizable.xcstrings", "DyorHQ/Resources/InfoPlist.xcstrings",
                                   "DyorKit/Sources/DyorKit/Resources/Localizable.xcstrings"]

    private static func ios() throws -> URL {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return ios
    }

    /// One catalog's entries, by key.
    private static func strings(_ path: String) throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: try ios().appendingPathComponent(path))
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], path)
        XCTAssertEqual(catalog["sourceLanguage"] as? String, "en", path)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any], path)
        return strings.compactMapValues { $0 as? [String: Any] }
    }

    /// The languages the app ships, as Info.plist lists them.
    private static func shipped() throws -> [String] {
        let info = try XCTUnwrap(NSDictionary(contentsOf: try ios().appendingPathComponent("DyorHQ/Info.plist")) as? [String: Any])
        return try XCTUnwrap(info["CFBundleLocalizations"] as? [String])
    }

    // MARK: The checks

    /// Every shipped language other than English has every key of every catalog translated, with the English's
    /// specifiers in every form.
    func testEveryShippedLanguageTranslatesEveryKey() throws {
        let shipped = try Self.shipped()
        XCTAssertEqual(shipped.first, "en", "English, the development language, first")
        XCTAssertGreaterThan(shipped.count, 1, "a language besides English ships")
        var checked = 0
        var problems: [String] = []
        for path in Self.catalogs {
            for (key, entry) in try Self.strings(path) where Self.needsTranslation(entry) {
                for language in shipped where language != "en" {
                    checked += 1
                    if let problem = Self.problem(key: key, entry: entry, language: language) { problems.append("\(path): \(key) [\(language)]: \(problem)") }
                }
            }
        }
        XCTAssertEqual(Array(problems.sorted().prefix(40)), [], "\(problems.count) keys are not translated as they must be in a shipped language")
        XCTAssertGreaterThanOrEqual(checked, 2_000 * (shipped.count - 1), "the check reads every catalog's keys")
    }

    /// CFBundleLocalizations is English and the languages the catalogs complete, no more and no fewer: a language the
    /// catalogs carry is either complete in all three and shipped, or not there at all.
    func testTheBundleShipsExactlyTheLanguagesTheCatalogsComplete() throws {
        let catalogs = try Self.catalogs.map { try Self.strings($0) }
        var carried: Set<String> = []
        for strings in catalogs {
            for entry in strings.values { carried.formUnion(Self.localizations(entry).keys) }
        }
        carried.remove("en")
        var incomplete: Set<String> = []
        for language in carried {
            let missing = catalogs.contains { strings in
                strings.contains { key, entry in Self.needsTranslation(entry) && Self.problem(key: key, entry: entry, language: language) != nil }
            }
            if missing { incomplete.insert(language) }
        }
        let complete = carried.subtracting(incomplete)
        XCTAssertEqual(Set(try Self.shipped()), complete.union(["en"]), "CFBundleLocalizations lists English and every language the catalogs complete")
        XCTAssertEqual(incomplete, [], "a catalog carries a language that is not complete in all three catalogs")
    }

    /// The reader: specifiers by position and type, %% and a percent sign before a space left out; and the problems it
    /// finds in a language's entry.
    func testTheReaderFindsWhatALanguageLacks() {
        func read(_ text: String) -> [String]? {
            Self.specifiers(text).map { $0.found.map { "\($0.position)\($0.type)" } }
        }
        XCTAssertEqual(read("%@ %@ for %@ %@"), ["1@", "2@", "3@", "4@"])
        XCTAssertEqual(read("%2$@ pour %1$lld"), ["2@", "1lld"])
        XCTAssertEqual(read("1% slippage at 100%% of %@"), ["1@"])
        XCTAssertNil(read("%@ et %2$@"), "positional and unpositioned mixed")
        XCTAssertEqual(Self.specifiers("%1$@ %2$@")?.positional, true)

        func unit(_ value: String, state: String = "translated") -> [String: Any] { ["stringUnit": ["state": state, "value": value]] }
        let entry: [String: Any] = ["localizations": [
            "en": unit("%1$@ holds %2$lld editions"),
            "es": unit("%1$@ tiene %2$lld ediciones"),
            "fr": unit("%@ détient %lld éditions"),
            "ko": unit("%1$@: %2$@"),
            "zh-Hans": unit("", state: "new"),
            "de": ["variations": ["plural": ["one": unit("%1$@ hat %2$lld Edition")]]],
        ]]
        XCTAssertNil(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "es"))
        XCTAssertEqual(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "fr"), "two or more specifiers need positions")
        XCTAssertEqual(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "ko"),
                       "specifiers [1@, 2@] are not the English's [1@, 2lld]")
        XCTAssertEqual(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "zh-Hans"), "state is new, not translated")
        XCTAssertEqual(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "de"), "a plural without its other form")
        XCTAssertEqual(Self.problem(key: "%@ holds %lld editions", entry: entry, language: "it"), "not translated")
        XCTAssertFalse(Self.needsTranslation(["shouldTranslate": false]))
        XCTAssertFalse(Self.needsTranslation(["extractionState": "stale"]))
        XCTAssertTrue(Self.needsTranslation(["extractionState": "extracted_with_value"]))
    }

    // MARK: Reading the catalogs

    private static func localizations(_ entry: [String: Any]) -> [String: Any] { entry["localizations"] as? [String: Any] ?? [:] }

    /// Whether a language must translate the entry: not marked never to translate, and still in the code.
    static func needsTranslation(_ entry: [String: Any]) -> Bool {
        entry["shouldTranslate"] as? Bool != false && entry["extractionState"] as? String != "stale"
    }

    /// The English of an entry (its "other" form when it varies by plural); the key itself when the catalog keeps no
    /// English of its own.
    private static func english(key: String, entry: [String: Any]) -> String? {
        guard let english = localizations(entry)["en"] as? [String: Any] else { return key }
        if let unit = english["stringUnit"] as? [String: Any] { return unit["value"] as? String }
        let plural = (english["variations"] as? [String: Any])?["plural"] as? [String: Any]
        return ((plural?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    /// Every form of one language's localization, labelled: its own text, and each variation's (plural categories,
    /// devices), however deep.
    private static func forms(_ localization: [String: Any], label: String = "") -> [(label: String, unit: [String: Any])] {
        var out: [(label: String, unit: [String: Any])] = []
        if let unit = localization["stringUnit"] as? [String: Any] { out.append((label, unit)) }
        for (axis, cases) in localization["variations"] as? [String: Any] ?? [:] {
            for (name, value) in cases as? [String: Any] ?? [:] {
                if let value = value as? [String: Any] { out += forms(value, label: "\(label)[\(axis)=\(name)] ") }
            }
        }
        return out
    }

    /// What `language`'s localization of one entry lacks, or nil when it is complete.
    static func problem(key: String, entry: [String: Any], language: String) -> String? {
        guard let english = english(key: key, entry: entry), let expected = specifiers(english) else { return "the English can't be read" }
        guard let localization = localizations(entry)[language] as? [String: Any] else { return "not translated" }
        if localization["substitutions"] != nil { return "substitutions, which this check doesn't read" }
        let found = forms(localization)
        guard !found.isEmpty else { return "not translated" }
        if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any], plural["other"] == nil {
            return "a plural without its other form"
        }
        func names(_ specifiers: [Specifier]) -> String { "[" + Set(specifiers).sorted().map { "\($0.position)\($0.type)" }.joined(separator: ", ") + "]" }
        for (label, unit) in found {
            guard unit["state"] as? String == "translated" else { return "\(label)state is \(unit["state"] as? String ?? "missing"), not translated" }
            guard let value = unit["value"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "\(label)empty" }
            guard let specifiers = specifiers(value) else { return "\(label)mixes positional and unpositioned specifiers" }
            if Set(specifiers.found) != Set(expected.found) {
                return "\(label)specifiers \(names(specifiers.found)) are not the English's \(names(expected.found))"
            }
            if specifiers.found.count >= 2, !specifiers.positional { return "\(label)two or more specifiers need positions" }
        }
        return nil
    }

    /// One format specifier: its position (counted in order when none is written) and its type ("@", "lld").
    struct Specifier: Hashable, Comparable {
        let position: Int
        let type: String
        static func < (a: Specifier, b: Specifier) -> Bool { (a.position, a.type) < (b.position, b.type) }
    }

    /// As scripts/dev/check-strings.py reads them: %% is a percent sign, and so is one before a space ("1% slippage").
    private static let specifier = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])"#)

    /// The format specifiers of `text`, and whether their positions are written; nil when it mixes written positions and
    /// unpositioned specifiers.
    static func specifiers(_ text: String) -> (found: [Specifier], positional: Bool)? {
        let text = text.replacingOccurrences(of: "%%", with: "")
        let read: [(position: Int?, type: String)] = specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
            return (Int(group(1)), group(2) + group(3))
        }
        if read.allSatisfy({ $0.position == nil }) {
            return (read.enumerated().map { Specifier(position: $0.offset + 1, type: $0.element.type) }, false)
        }
        if read.contains(where: { $0.position == nil }) { return nil }
        return (read.map { Specifier(position: $0.position ?? 0, type: $0.type) }, true)
    }
}
