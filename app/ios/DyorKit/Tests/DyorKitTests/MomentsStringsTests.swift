import Foundation
import XCTest

/// The Moments screens' text (L2), read from the app's sources (ios/DyorHQ/Moments). A sentence written in the code
/// reaches the screen through the catalog: as a `Text`, `Label` or `Button` key, or through `tr()` where it must be a
/// `String` first (a row's value, a field's error, a badge, an Activity record). What has nothing to translate (an amount
/// with its symbol, a count, a percentage) is shown as it is; a count that needs a plural is the key's own `Int`, never
/// "x == 1 ? …"; dates and countdowns follow the app's language. The English literals that are identifiers (URL schemes,
/// the Activity section, upload types) stay as they are, and the folder has no English server or RPC matcher. English
/// reads a plural key from the catalog too, so once the app's catalog is synced every one has its English "one" form.
final class MomentsStringsTests: XCTestCase {
    // MARK: The checks

    /// No `String` sink is given English words: a row's value (`LabeledContent(…, value:)`, shown as it is), an Activity
    /// record's title and subtitle (also the banner's text), a `verbatim:` text, an assignment (a field's error) or a
    /// `String` returned by a property (a badge). Those go through `tr()`; a function that returns a key may return words.
    func testWordsGivenAsAStringGoThroughTheCatalog() throws {
        var unlocalized: [String] = []
        var records = 0
        for (name, text) in try Self.sources() {
            let chars = Self.code(text)
            for call in Self.calls("LabeledContent", in: chars) {
                for argument in call where argument.label == "value" {
                    unlocalized += Self.literals(in: argument.value).filter { Self.hasWords($0.words) }.map { "\(name): LabeledContent(… value: \($0.source))" }
                }
            }
            for call in Self.calls("ActivityRecord", in: chars) {
                records += 1
                for argument in call where argument.label == "title" || argument.label == "subtitle" {
                    unlocalized += Self.literals(in: argument.value).filter { Self.hasWords($0.words) }.map { "\(name): ActivityRecord(… \(argument.label!): \($0.source))" }
                }
                let title = call.first { $0.label == "title" }.map { String($0.value) } ?? ""
                XCTAssertTrue(title.hasPrefix("tr("), "\(name): an Activity record's title is in the app's language: \(title)")
            }
            for callee in ["Text", "Paragraph", "DetailRow"] {
                for call in Self.calls(callee, in: chars) {
                    for argument in call where argument.label == "verbatim" {
                        unlocalized += Self.literals(in: argument.value).filter { Self.hasWords($0.words) }.map { "\(name): \(callee)(verbatim: \($0.source))" }
                    }
                }
            }
            let lines = String(chars).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                for pattern in [#"(?<![=!<>+\-*/])=\s*""#, #"\breturn\s*\(?\s*""#] {
                    guard let hit = line.range(of: pattern, options: .regularExpression) else { continue }
                    let rest = Array(line[line.index(before: hit.upperBound)...])
                    guard let end = Self.literalEnd(rest, 0) else { continue }
                    let literal = Self.literal(rest, 0, end)
                    guard Self.hasWords(literal.words) else { continue }
                    if pattern.contains("return"), let declaration = Self.declaration(lines, enclosing: number),
                       ["LocalizedStringKey", "Text"].contains(declaration.type) || declaration.name == "symbol" { // `symbol`: SF Symbol names
                        continue
                    }
                    unlocalized.append("\(name):\(number + 1): \(literal.source)")
                }
            }
        }
        XCTAssertEqual(unlocalized, [], "English words given as a String are shown untranslated: tr() them")
        // Publish; collect, claim, two creator withdrawals, three beneficiary ones, retry, expire, buyback; the past
        // cohort's claim and two withdrawals; Claim All.
        XCTAssertEqual(records, 15)
    }

    /// No key is only placeholders and symbols ("$%@", "%lld", "%@ $%@"): an amount, a count or a ticker is shown as it
    /// is. No plural is made by hand or a label from a raw value: the catalog gives each language its own forms.
    func testNoPlaceholderOnlyKeyAndNoHandMadePlural() throws {
        var placeholderOnly: [String] = []
        var checked = 0
        for (name, text) in try Self.sources() {
            XCTAssertFalse(text.contains("== 1 ?"), "\(name): a plural made by hand reads wrong in other languages")
            XCTAssertFalse(text.contains(".capitalized"), "\(name): a label from a raw value is never translated")
            let chars = Self.code(text)
            for callee in ["Text", "Paragraph", "Label", "Button", "Section", "LabeledContent"] {
                for call in Self.calls(callee, in: chars) {
                    guard let first = call.first, first.label == nil else { continue }
                    for literal in Self.literals(in: first.value) {
                        checked += 1
                        if literal.interpolated, !Self.hasWords(literal.words) { placeholderOnly.append("\(name): \(callee)(\(literal.source))") }
                    }
                }
            }
        }
        XCTAssertEqual(placeholderOnly, [], "nothing to translate: Text(verbatim:)")
        XCTAssertGreaterThan(checked, 150, "the scan reads the folder's keys")

        // A field's placeholder with nothing to translate (a number) is passed as a `String`, shown as it is.
        var placeholders: [String] = []
        for (name, text) in try Self.sources() {
            for call in Self.calls("TextField", in: Self.code(text)) {
                guard let first = call.first, first.label == nil, !String(first.value).hasSuffix(" as String") else { continue }
                placeholders += Self.literals(in: first.value).filter { !Self.hasWords($0.words) }.map { "\(name): TextField(\($0.source))" }
            }
        }
        XCTAssertEqual(placeholders, [], "a number as a placeholder: \"1\" as String")
        let create = try XCTUnwrap(try Self.sources().first { $0.name == "CreateMomentView.swift" }?.text)
        XCTAssertTrue(create.contains(#"TextField("1" as String, text: $priceText)"#))
        XCTAssertTrue(create.contains(#"TextField("10" as String, text: $allocPercentText)"#))
    }

    /// One key is one translation, so the filter's "All" (every Moment) is a key of its own, apart from the app's other
    /// "All"s (all time, every news source, every kind of notification): gender and number differ in Spanish and French.
    /// English reads "All".
    func testTheFiltersAllIsAKeyOfItsOwn() throws {
        let board = try XCTUnwrap(try Self.sources().first { $0.name == "MomentsView.swift" }?.text)
        XCTAssertTrue(board.contains(#"case .all: return Text(verbatim: tr(LocalizedStringResource("momentFilter.all", defaultValue: "All", comment: "[tight] Moments filter: every Moment")))"#))
        XCTAssertFalse(board.contains(#"Text("All""#))
    }

    /// The filter's "Graduated" (every graduated Moment, a plural beside "All" and "Collecting" in Spanish and French) is
    /// a key of its own, apart from the status badge's "Graduated", which the Launch board and a date row share. English
    /// reads "Graduated".
    func testTheFiltersGraduatedIsAKeyOfItsOwn() throws {
        let sources = Dictionary(uniqueKeysWithValues: try Self.sources().map { ($0.name, $0.text) })
        let board = try XCTUnwrap(sources["MomentsView.swift"])
        XCTAssertTrue(board.contains(#"case .graduated: return Text(verbatim: tr(LocalizedStringResource("momentFilter.graduated", defaultValue: "Graduated", comment: "[tight] Moments filter: the Moments whose coin has graduated")))"#))
        XCTAssertFalse(board.contains(#"Text("Graduated""#))
        // The badge's key keeps one comment, which no longer names the filter.
        let badge = "[tight] A status: the coin graduated into its pool. A badge on Moments, a section of the Launch board and a date row: use a form that fits each"
        for name in ["MomentsUI.swift", "RetiredMomentDetailView.swift"] {
            XCTAssertTrue(try XCTUnwrap(sources[name]).contains(#"LocalizedStringResource("Graduated", comment: "\#(badge)")"#), name)
        }
    }

    /// The five interpolations the compiler said would show a debug description (a `BigUInt` in a key) are written as
    /// what they mean: a token id as a `String`, a count as an `Int`.
    func testNoBigNumberIsInterpolatedIntoAKey() throws {
        let sources = Dictionary(uniqueKeysWithValues: try Self.sources().map { ($0.name, $0.text) })
        let detail = try XCTUnwrap(sources["MomentDetailView.swift"]), retired = try XCTUnwrap(sources["RetiredMomentDetailView.swift"])
        let create = try XCTUnwrap(sources["CreateMomentView.swift"])
        for (name, text) in [("MomentDetailView", detail), ("RetiredMomentDetailView", retired)] {
            XCTAssertFalse(text.contains(#"View #\(id) on OpenSea"#), name)
            XCTAssertTrue(text.contains(#"Label("View #\(String(id)) on OpenSea", systemImage: "sailboat")"#), name)
        }
        XCTAssertFalse(detail.contains(#"\(quote.editions)"#))
        XCTAssertTrue(detail.contains("let editions = Int(clamping: quote.editions)"))
        XCTAssertTrue(create.contains("let collects = Int(clamping: reservePerCollect > 0 ?"))
        XCTAssertTrue(create.contains(#"Paragraph("Fingerprint \(String(mediaHash.hexString.prefix(12)))… goes on-chain.")"#))
    }

    /// Every count that needs a plural is the key's `Int` ("%lld editions"), so the catalog gives "1 edition" and each
    /// language its own forms.
    func testPluralsAreKeysWithTheirCount() throws {
        let all = try Self.sources().map(\.text).joined(separator: "\n")
        for plural in [
            #"Text("\(windowDays) days")"#, // Publish: the collect window
            #"Text("\(days) days")"#, // Publish's review: Window
            #"About \(collects) collects at this price"#, // Publish: the pricing footer
            #"value: tr("\(MomentsFormat.usdcCents(info.reserveRemaining)) · about \(info.collectsToGraduate) collects"))"#,
            #"Paragraph("\(editions) editions · \(MomentsFormat.coins(quote.entitlement)) $\(info.symbol)")"#, // You get
            #"(\(MomentsFormat.usdc(quote.gross)) for \(editions) editions)"#, // the terminal collect
            #""Collect \(quantity) Editions""#, // the Collect button
            #"value: tr("\(top.short) · \(count) editions"))"#, // Largest holder
            #"value: tr("\(MomentsFormat.coins(detail.supply.entitlements)) · \(detail.supply.collects) collects"))"#,
            #"subtitle: tr("\(quantity) editions · "#, // the collect's Activity record
            #"subtitle: tr("across \(portfolio?.claimableIds.count ?? 0) Moments")"#, // Claim All's Activity record
            #"Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held) · creator")"#,
            #"Text("\(row.nftBalance) editions · promised \(promised) · claimed \(claimed) · in wallet \(held)")"#,
        ] {
            XCTAssertTrue(all.contains(plural), plural)
        }
    }

    /// Dates and countdowns are in the app's language (`L10n.locale`), never the launch locale; the countdown uses the
    /// system's narrow units, and in English it reads exactly as build 16's hand-made one ("2d 3h left").
    func testDatesAndCountdownsFollowTheAppLanguage() throws {
        let sources = try Self.sources()
        for (name, text) in sources {
            for line in text.components(separatedBy: "\n") where line.contains(".formatted(") {
                XCTAssertEqual(name, "MomentsUI.swift", "\(name): a date or a duration goes through MomentsFormat: \(line)")
                XCTAssertTrue(line.contains(".locale(L10n.locale)") || line.contains(".formatted(remaining(units))"), line)
            }
        }
        let ui = try XCTUnwrap(sources.first { $0.name == "MomentsUI.swift" }?.text)
        XCTAssertTrue(ui.contains("let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 3_600 ? [.minutes] : seconds < 86_400 ? [.hours, .minutes] : [.days, .hours]"))
        XCTAssertTrue(ui.contains("let time = Duration.seconds(max(60, seconds)).formatted(remaining(units))"))
        XCTAssertTrue(ui.contains("Duration.UnitsFormatStyle(allowedUnits: units, width: .narrow, zeroValueUnits: .show(length: 1), fractionalPart: .hide(rounded: .down)).locale(L10n.locale)"))

        // The same style, in English and French.
        func countdown(_ seconds: Int, _ locale: Locale) -> String {
            let units: Set<Duration.UnitsFormatStyle.Unit> = seconds < 3_600 ? [.minutes] : seconds < 86_400 ? [.hours, .minutes] : [.days, .hours]
            return Duration.seconds(max(60, seconds)).formatted(Duration.UnitsFormatStyle(allowedUnits: units, width: .narrow, zeroValueUnits: .show(length: 1),
                                                                                          fractionalPart: .hide(rounded: .down)).locale(locale))
        }
        // Build 16's countdown, without its " left".
        func handMade(_ seconds: Int) -> String {
            if seconds < 3_600 { return "\(max(1, seconds / 60))m" }
            if seconds < 86_400 { return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
            return "\(seconds / 86_400)d \((seconds % 86_400) / 3_600)h"
        }
        let english = Locale(identifier: "en_US")
        for seconds in [1, 59, 60, 61, 119, 3_599, 3_600, 3_659, 3_660, 7_199, 86_399, 86_400, 89_999, 90_000, 2 * 86_400 + 3 * 3_600 + 3_599, 30 * 86_400] {
            XCTAssertEqual(countdown(seconds, english), handMade(seconds), "\(seconds) s")
        }
        XCTAssertEqual(countdown(2 * 86_400 + 3 * 3_600, Locale(identifier: "fr_FR")), "2j 3h")
        XCTAssertTrue(ui.contains(#"tr(LocalizedStringResource("\(time) left""#))
        XCTAssertTrue(ui.contains(#"tr(LocalizedStringResource("Collecting · \(left)""#))
    }

    /// The folder's only text matchers are the media link's URL schemes; the Activity section and the upload types are
    /// identifiers. None of them is translated.
    func testIdentifiersAndMatchersStayAsTheyAre() throws {
        var matchers: Set<String> = []
        var sections = 0
        for (name, text) in try Self.sources() {
            let code = String(Self.code(text))
            for pattern in [#"\.(hasPrefix|hasSuffix|contains|starts)\((with: )?"[^"]*"\)"#, #"[!=]= "[^"]*""#] {
                var from = code.startIndex
                while let hit = code.range(of: pattern, options: .regularExpression, range: from..<code.endIndex) {
                    matchers.insert(String(code[hit]))
                    from = hit.upperBound
                }
            }
            sections += code.components(separatedBy: #"section: "moments""#).count - 1
            for identifier in [#"section: tr("#, #"tr("ipfs"#, #"tr("https"#, #"tr("image/"#, #"tr("video/"#] {
                XCTAssertFalse(code.contains(identifier), "\(name): \(identifier)")
            }
        }
        XCTAssertEqual(matchers, [#".hasPrefix("ipfs://")"#, #".hasPrefix("https://")"#])
        XCTAssertEqual(sections, 15, "every Activity record's section")
        let create = try XCTUnwrap(try Self.sources().first { $0.name == "CreateMomentView.swift" }?.text)
        XCTAssertTrue(create.contains(#"contentType: isMP4 ? "video/mp4" : "video/quicktime""#))
    }

    // MARK: The catalog's English plurals

    /// The folder's plural keys as the compiler extracts them (an `Int` is %lld, a `String` %@, a written "%" in an
    /// interpolated key %%), from the sites `testPluralsAreKeysWithTheirCount` pins. The code's English is the "other"
    /// form: until the catalog gives a key its "one", a count of 1 reads "1 days" or "Collect 1 Editions".
    private static let pluralKeys = [
        "%lld days", // Publish: the collect window, and the review's Window row
        "Minimum %@. About %lld collects at this price reach the %@ reserve, and the coin graduates at a %@ FDV. Up to %@ of the %@ coins is yours, vesting 20%% at graduation then 16%% a month; anything you leave deepens the pool. Collecting ends at graduation or when the window closes (1 to 30 days).",
        "%@ · about %lld collects", // Still needed
        "%lld editions · %@ $%@", // You get
        "This collect completes the Moment: it takes only what the reserve still needs (%@ for %lld editions) and graduates the coin in the same transaction.",
        "Collect %lld Editions", // the Collect button, 1 edition by default
        "%@ · %lld editions", // Largest holder
        "%@ · %lld collects", // Owed to collectors
        "%lld editions · %@", // the collect's Activity record
        "across %lld Moments", // Claim All's Activity record
        "%lld editions · promised %@ · claimed %@ · in wallet %@ · creator", // My Moments, a row
        "%lld editions · promised %@ · claimed %@ · in wallet %@",
    ]

    /// Every plural key is in the app's catalog with an English "one" and "other" that differ. The catalogs are filled
    /// once, after every L2 lane merges: while the app's is still empty this is skipped, except under the release gate
    /// (`DYORHQ_RELEASE_GATE=1`), where an empty catalog refuses the release. A synced catalog without the English
    /// plurals fails, so the catalog step cannot leave "Collect 1 Editions" in English.
    func testEveryPluralKeyHasItsEnglishOneAndOther() throws {
        let strings = try Self.appCatalog()
        if strings.isEmpty {
            guard ProcessInfo.processInfo.environment["DYORHQ_RELEASE_GATE"] == "1" else {
                throw XCTSkip("the app's catalog is not synced yet: the catalog step gives the \(Self.pluralKeys.count) Moments plural keys their English one and other")
            }
            return XCTFail("REFUSING A RELEASE: the app's catalog is empty, so English reads \"Collect 1 Editions\" and \"1 days\"")
        }
        for key in Self.pluralKeys {
            if let problem = Self.englishPluralProblem(strings[key]) { XCTFail("\(key): \(problem)") }
        }
    }

    /// The plural check reads both shapes Xcode writes (the whole string varied by plural, or a substitution) and refuses
    /// a key that is missing, has no English plural, or has an English "one" that is missing or the same as "other".
    func testThePluralCheckReadsTheCatalogShapes() throws {
        func plural(_ forms: [String: String]) -> [String: Any] {
            ["plural": forms.mapValues { ["stringUnit": ["state": "translated", "value": $0]] }]
        }
        func entry(_ localization: [String: Any], in language: String = "en") -> [String: Any] { ["localizations": [language: localization]] }
        let whole = entry(["variations": plural(["one": "%lld day", "other": "%lld days"])])
        let substitution = entry(["stringUnit": ["state": "translated", "value": "Collect %#@count@"],
                                  "substitutions": ["count": ["argNum": 1, "formatSpecifier": "lld",
                                                              "variations": plural(["one": "%arg Edition", "other": "%arg Editions"])] as [String: Any]]])
        XCTAssertNil(Self.englishPluralProblem(whole))
        XCTAssertNil(Self.englishPluralProblem(substitution))

        XCTAssertEqual(Self.englishPluralProblem(nil), "not in the app's catalog")
        XCTAssertEqual(Self.englishPluralProblem([String: Any]()), "no English plural") // as a sync adds it
        XCTAssertEqual(Self.englishPluralProblem(entry(["stringUnit": ["state": "translated", "value": "%lld days"]])), "no English plural")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "%lld jour", "other": "%lld jours"])], in: "fr")), "no English plural")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["other": "%lld days"])])), "an English plural without its one or other form")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "%lld days", "other": "%lld days"])])), "the English one form is the other form")
    }

    // MARK: Reading the sources

    /// Every Swift file of ios/DyorHQ/Moments, by name; a new file is read too.
    private static func sources() throws -> [(name: String, text: String)] {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { folder.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        folder = folder.appendingPathComponent("DyorHQ/Moments")
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 7)
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }.sorted { $0.name < $1.name }
    }

    /// The app's catalog (ios/DyorHQ/Resources/Localizable.xcstrings), its entries by key.
    private static func appCatalog() throws -> [String: Any] {
        var file = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { file.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        file = file.appendingPathComponent("DyorHQ/Resources/Localizable.xcstrings")
        guard FileManager.default.fileExists(atPath: file.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        return try XCTUnwrap(catalog["strings"] as? [String: Any], "a catalog has its strings")
    }

    /// What a plural key's catalog entry lacks in English, or nil: it needs a plural variation (of the whole string or
    /// of a substitution) whose "one" and "other" forms are both written and differ.
    private static func englishPluralProblem(_ entry: Any?) -> String? {
        guard let entry = entry as? [String: Any] else { return "not in the app's catalog" }
        let forms = plurals(in: (entry["localizations"] as? [String: Any])?["en"] ?? [String: Any]())
        guard !forms.isEmpty else { return "no English plural" }
        for form in forms {
            guard let one = form["one"], let other = form["other"], !one.isEmpty, !other.isEmpty else { return "an English plural without its one or other form" }
            if one == other { return "the English one form is the other form" }
        }
        return nil
    }

    /// Every plural variation inside a catalog localization, as its forms' values by plural category.
    private static func plurals(in json: Any) -> [[String: String]] {
        guard let object = json as? [String: Any] else { return [] }
        var found: [[String: String]] = []
        for (key, value) in object {
            if key == "plural", let forms = value as? [String: Any] {
                found.append(forms.compactMapValues { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String })
            } else {
                found += plurals(in: value)
            }
        }
        return found
    }

    private static func hasWords(_ words: String) -> Bool { words.range(of: "[a-z]{2,}", options: .regularExpression) != nil }

    /// `text` without its `//` comments (a quote or a bracket in a comment is not code); the lines are kept.
    private static func code(_ text: String) -> [Character] {
        var out: [Character] = []
        for line in text.components(separatedBy: "\n") {
            let chars = Array(line)
            var index = 0
            while index < chars.count {
                if chars[index] == "\"", let end = literalEnd(chars, index) {
                    out += chars[index...end]
                    index = end + 1
                    continue
                }
                if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" { break }
                out.append(chars[index])
                index += 1
            }
            out.append("\n")
        }
        return out
    }

    /// The index of the quote closing the single-line literal that opens at `start`; its interpolations may hold literals.
    private static func literalEnd(_ chars: [Character], _ start: Int) -> Int? {
        var index = start + 1
        while index < chars.count {
            if chars[index] == "\\" {
                if index + 1 < chars.count, chars[index + 1] == "(" {
                    guard let close = closing(chars, index + 1) else { return nil }
                    index = close + 1
                } else {
                    index += 2
                }
                continue
            }
            if chars[index] == "\"" { return index }
            if chars[index] == "\n" { return nil }
            index += 1
        }
        return nil
    }

    /// The index of the bracket closing the one at `open`, skipping literals.
    private static func closing(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                guard let end = literalEnd(chars, index) else { return nil }
                index = end + 1
                continue
            }
            if "([{".contains(char) {
                depth += 1
            } else if ")]}".contains(char) {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The literal from `start` to `end`: its source and its text outside the interpolations.
    private static func literal(_ chars: [Character], _ start: Int, _ end: Int) -> (source: String, words: String, interpolated: Bool) {
        var words = ""
        var interpolated = false
        var index = start + 1
        while index < end {
            if chars[index] == "\\", chars[index + 1] == "(", let close = closing(chars, index + 1) {
                interpolated = true
                index = close + 1
                continue
            }
            words.append(chars[index])
            index += 1
        }
        return (String(chars[start...end]), words, interpolated)
    }

    /// Every call of `name` (not a member's `x.name(`) with its top-level arguments, each with its label.
    private static func calls(_ name: String, in chars: [Character]) -> [[(label: String?, value: [Character])]] {
        let target = Array(name + "(")
        var found: [[(label: String?, value: [Character])]] = []
        var index = 0
        while index + target.count <= chars.count {
            if chars[index] == "\"", let end = literalEnd(chars, index) {
                index = end + 1
                continue
            }
            let previous = index > 0 ? chars[index - 1] : " "
            if Array(chars[index..<(index + target.count)]) == target, !(previous.isLetter || previous.isNumber || previous == "_" || previous == "."),
               let close = closing(chars, index + target.count - 1) {
                found.append(arguments(Array(chars[(index + target.count)..<close])))
            }
            index += 1
        }
        return found
    }

    /// An argument list's top-level arguments.
    private static func arguments(_ chars: [Character]) -> [(label: String?, value: [Character])] {
        var parts: [[Character]] = []
        var current: [Character] = []
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"", let end = literalEnd(chars, index) {
                current += chars[index...end]
                index = end + 1
                continue
            }
            if "([{".contains(char) { depth += 1 } else if ")]}".contains(char) { depth -= 1 }
            if char == ",", depth == 0 { parts.append(current); current = [] } else { current.append(char) }
            index += 1
        }
        parts.append(current)
        return parts.compactMap { part in
            let text = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard let label = text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*:\s"#, options: .regularExpression) else { return (nil, Array(text)) }
            return (String(text[label].trimmingCharacters(in: .whitespaces).dropLast()), Array(text[label.upperBound...]))
        }
    }

    /// The string literals at the top level of an argument's value, a ternary's and a `??`'s included (in grouping
    /// parentheses or not); not those inside a call, a subscript or a closure, whose type is decided there.
    private static func literals(in value: [Character]) -> [(source: String, words: String, interpolated: Bool)] {
        var found: [(source: String, words: String, interpolated: Bool)] = []
        var nesting: [Bool] = [] // for each open bracket: whether it nests (a call, a subscript, a closure)
        var index = 0
        while index < value.count {
            let char = value[index]
            if char == "\"", let end = literalEnd(value, index) {
                if !nesting.contains(true) { found.append(literal(value, index, end)) }
                index = end + 1
                continue
            }
            if "([{".contains(char) {
                let previous = index > 0 ? value[index - 1] : " "
                nesting.append(char != "(" || previous.isLetter || previous.isNumber || "_)]>?!".contains(previous))
            } else if ")]}".contains(char) {
                _ = nesting.popLast()
            }
            index += 1
        }
        return found
    }

    /// The `func` or computed `var` around line `number`: its name and the type it returns.
    private static func declaration(_ lines: [String], enclosing number: Int) -> (name: String, type: String)? {
        let function = #"func (\w+)[^{]*->\s*([\w.]+)"#, property = #"var (\w+):\s*([\w.]+)\??\s*\{"#
        for line in lines[...number].reversed() {
            for pattern in [function, property] {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let name = Range(match.range(at: 1), in: line), let type = Range(match.range(at: 2), in: line) else { continue }
                return (String(line[name]), String(line[type]))
            }
        }
        return nil
    }
}
