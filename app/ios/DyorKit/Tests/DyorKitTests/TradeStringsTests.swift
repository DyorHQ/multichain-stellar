import Foundation
import XCTest
@testable import DyorKit

/// The text of Launchpad, Home, Portfolio, Swap and Bridge is localizable (L2), read from the app's sources. Text written
/// in a view is a catalog key with words in it; an amount, a symbol or a count on its own is shown as it is
/// (`Text(verbatim:)`), never a key such as "%@ %@" or "$%@". Text a model builds as a `String` (a tab's label, an error,
/// an Activity title) goes through `tr()`. A literal next to a `String` in a ternary or a `??` is a `String` too, so a
/// view never mixes them. The English matchers for server errors stay English.
final class TradeStringsTests: XCTestCase {
    private static let folders = ["Launchpad/", "Home/", "Portfolio/", "Swap/", "Bridge/"]

    /// Every Swift file of the five folders, without its comments.
    private static func sources() throws -> [(path: String, code: [Character])] {
        let all = try FormattedTextIsolationTests.appSources().filter { source in folders.contains { source.path.hasPrefix($0) } }
        XCTAssertEqual(all.count, 16, "the five folders' files")
        return all.map { ($0.path, uncommented(Array($0.text))) }
    }

    // MARK: Keys

    /// SwiftUI's views and modifiers whose first, unlabelled argument is a key when it is a literal.
    private static let views: Set<String> = ["Text", "Paragraph", "Button", "Label", "Section", "LabeledContent", "Link", "TextField", "ProgressView",
                                             "Toggle", "Stepper", "Picker", "ContentUnavailableView", "Menu"]
    private static let modifiers: Set<String> = ["accessibilityLabel", "accessibilityHint", "navigationTitle"]

    /// No key has nothing to translate: an amount with its symbol, a count, a percentage, "$" with a ticker or "—" is
    /// shown with `Text(verbatim:)` (or as a `String`) built from parts already localized.
    func testNoPlaceholderOnlyKey() throws {
        var checked = 0
        var found: [String] = []
        for (path, code) in try Self.sources() {
            XCTAssertFalse(String(code).contains(#"AmountField(title: "0","#), "\(path): the amount field's \"0\" is a number, shown as it is")
            for call in Self.calls(in: code, views: Self.views, modifiers: Self.modifiers) {
                guard let first = Self.split(call.arguments).first else { continue }
                let (label, value) = Self.labelled(first)
                // A number placeholder passed `as String` takes the view's run-time path, shown as it is.
                if label != nil || value.hasPrefix("Text(verbatim:") || value.hasSuffix(" as String") { continue }
                for literal in Self.literals(in: Array(value)) {
                    checked += 1
                    if literal.words.range(of: "[A-Za-z]{2,}", options: .regularExpression) == nil {
                        found.append("\(path):\(Self.line(of: call.start, in: code)): \(call.name)(\(literal.source))")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "a key with nothing to translate: show it with Text(verbatim:)")
        XCTAssertGreaterThan(checked, 280, "the scan reads the views' keys")
    }

    /// A literal beside a `String` in a ternary or a `??` (`name.isEmpty ? "Your coin" : name`) is a `String`, which a
    /// view shows without looking it up: each side is a key, or each side is shown as it is.
    func testNoLiteralBesideAStringInAKey() throws {
        // Both sides are keys here: the other side is a `LocalizedStringKey` itself.
        let keys: Set<String> = ["Home/AddFundsCard.swift: copied ? \"Copied\" : title"]
        var found: [String] = []
        for (path, code) in try Self.sources() {
            for call in Self.calls(in: code, views: Self.views, modifiers: Self.modifiers) {
                guard let first = Self.split(call.arguments).first else { continue }
                let (label, value) = Self.labelled(first)
                guard label == nil else { continue }
                let sides = Self.branches(value)
                guard sides.count > 1 else { continue }
                let written = sides.filter { Self.isLiteral($0) && Self.hasWords($0) }
                let builtAtRunTime = sides.filter { !Self.isLiteral($0) }
                if !written.isEmpty, !builtAtRunTime.isEmpty, !keys.contains("\(path): \(value)") {
                    found.append("\(path):\(Self.line(of: call.start, in: code)): \(call.name)(\(value))")
                }
            }
        }
        XCTAssertEqual(found, [], "a literal beside a String is never looked up")
        // The reader finds the sides of a nested ternary and of a `??`.
        XCTAssertEqual(Self.branches("a ? \"A\" : b ? \"B\" : c"), ["\"A\"", "\"B\"", "c"])
        XCTAssertEqual(Self.branches("error.map { $0 } ?? \"Fallback\""), ["error.map { $0 }", "\"Fallback\""])
        XCTAssertEqual(Self.branches("x?.name ?? y"), ["x?.name", "y"])
        XCTAssertEqual(Self.branches("a ? (b ? \"B\" : \"C\") : \"D\""), ["\"B\"", "\"C\"", "\"D\""])
    }

    /// `LabeledContent`'s `value:` is shown as it is: written text there goes through `tr()`.
    func testLabeledContentValueIsNeverAWrittenLiteral() throws {
        var values = 0
        var found: [String] = []
        for (path, code) in try Self.sources() {
            for call in Self.calls(in: code, views: ["LabeledContent"], modifiers: []) {
                for argument in Self.split(call.arguments) {
                    let (label, value) = Self.labelled(argument)
                    guard label == "value" else { continue }
                    values += 1
                    if Self.literals(in: Array(value)).contains(where: { $0.words.range(of: "[a-z]{2,}", options: .regularExpression) != nil }) {
                        found.append("\(path):\(Self.line(of: call.start, in: code)): value: \(value)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "LabeledContent's value is shown without being looked up")
        XCTAssertGreaterThanOrEqual(values, 10)
    }

    // MARK: Model text

    /// Text a model or a helper builds as a `String` (an error, a status, an Activity title, a label returned by a
    /// property) is written inside `tr()`: a bare literal there is never looked up.
    func testModelTextGoesThroughTr() throws {
        // Where a `String` is made from a literal: returned, the result of a switch arm, the fallback of a `??`, assigned,
        // or handed to a status or to iOS (an announcement, the Face ID reason).
        let sink = try NSRegularExpression(pattern: #"(?:\breturn|\?\?|[^=!<>]=|\bdefault:|\bcase [^\n"]*:|\.(?:failed|settling|unverified|refunded)\(|Announcement\(|reason:|\.append\()\s*("(?:[^"\\\n]|\\.)*")"#)
        var found: [String] = []
        for (path, code) in try Self.sources() {
            let text = String(code)
            for match in sink.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let literal = String(text[range])
                if Self.isWriting(literal) { found.append("\(path):\(text[..<range.lowerBound].filter { $0 == "\n" }.count + 1): \(literal)") }
            }
            // An Activity row's title and detail, as recorded or corrected.
            for call in Self.calls(in: code, views: ["ActivityRecord", "FeedItem", "Activity", "correct"], modifiers: []) {
                for argument in Self.split(call.arguments) {
                    let (label, value) = Self.labelled(argument)
                    guard ["title", "subtitle", "detail"].contains(label ?? "") else { continue }
                    for literal in Self.literals(in: Array(value)) where Self.isWriting(literal.source) {
                        found.append("\(path):\(Self.line(of: call.start, in: code)): \(call.name) \(label ?? ""): \(literal.source)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "text built as a String goes through tr()")
        XCTAssertTrue(Self.isWriting(#""Not enough \(symbol): you have \(amount).""#))
        XCTAssertTrue(Self.isWriting(#""Spot""#))
        XCTAssertFalse(Self.isWriting(#""\(units) AUSD""#), "an amount and its symbol")
        XCTAssertFalse(Self.isWriting(#""arrow.left.arrow.right""#), "an SF Symbol")
        XCTAssertFalse(Self.isWriting(#""creator-\(id)""#), "an identifier")
    }

    /// The labels the models used to write in English (or derive from a raw value) are each a `tr()` per case.
    func testModelLabelsAreLocalizedPerCase() throws {
        let labels: [(file: String, declaration: String, cases: Int)] = [
            ("Home/HomeView.swift", "enum HomeTokenTab", 4),
            ("Home/HomeView.swift", "enum HoldingCategory", 4),
            ("Home/TransferSheet.swift", "enum Direction", 2),
            ("Launchpad/LaunchpadView.swift", "enum LaunchSort", 3),
            ("Launchpad/LaunchpadProfileView.swift", "private enum Tab", 3),
            ("Portfolio/AssetsModel.swift", "private enum Kind", 2),
            ("Portfolio/PortfolioModel.swift", "var title: String", 5),
            ("Swap/SwapView.swift", "var actionTitle: String", 5),
            ("Swap/SwapView.swift", "private func hint(_ bps: Int) -> String", 4),
            ("Bridge/BridgeView.swift", "private var progressText: String", 2),
            ("Bridge/BridgeView.swift", "private var primaryTitle: String", 6),
            ("Bridge/BridgeModel.swift", "extension AuroraSwapStatus", 6),
        ]
        for (file, declaration, cases) in labels {
            let code = String(Self.uncommented(Array(try DocsLinksTests.appSource(file))))
            let start = try XCTUnwrap(code.range(of: declaration), "\(file): \(declaration)")
            let open = try XCTUnwrap(code[start.upperBound...].firstIndex(of: "{"))
            let chars = Array(code)
            let openIndex = code.distance(from: code.startIndex, to: open)
            let close = try XCTUnwrap(Self.closing(chars, openIndex))
            let body = String(chars[openIndex...close])
            XCTAssertFalse(body.contains("capitalized"), "\(file): \(declaration)")
            XCTAssertEqual(body.components(separatedBy: "tr(").count - 1, cases, "\(file): \(declaration): one tr() per label")
            let bare = Self.literals(in: Array(body), nestedToo: true).filter { Self.isWriting($0.source) }
            XCTAssertEqual(bare.map(\.source), [], "\(file): \(declaration)")
        }
    }

    /// A count with a noun is one key with the count as its argument, which the catalog gives its plural forms; English
    /// is never chosen by hand (`count == 1 ? "edition" : "editions"`). No label is derived from a raw value.
    func testPluralsAndLabelsAreNotBuiltByHand() throws {
        for (path, code) in try Self.sources() {
            let text = String(code)
            XCTAssertNil(text.range(of: #"== 1 \? ""#, options: .regularExpression), "\(path): a plural chosen by hand")
            XCTAssertFalse(text.contains("rawValue.capitalized"), "\(path): a label derived from a raw value")
        }
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        XCTAssertTrue(home.contains(#"tr("\(row.nftBalance) editions")"#))
        let portfolio = try DocsLinksTests.appSource("Portfolio/PortfolioView.swift")
        XCTAssertTrue(portfolio.contains(#"Text("\(stats.trades) trades in the period")"#))
        let past = try DocsLinksTests.appSource("Portfolio/PastCohortsCard.swift")
        XCTAssertTrue(past.contains(#"tr("\(position.row.nftBalance) editions")"#))
        let history = try DocsLinksTests.appSource("Portfolio/PortfolioModel.swift")
        XCTAssertTrue(history.contains(#"tr("\(c.editions) editions · \("#))
        let profile = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains(#"tr("\(model.claimAllCount) claims · fees and rewards")"#))
    }

    /// The keys above read "1 editions", "1 trades in the period" or "1 claims" until the app's catalog gives them their
    /// English plural forms (the catalog step, after every lane merges; the build before this one chose the noun by
    /// hand). While the catalog is still empty this is skipped, naming the keys; once it holds strings, each key needs a
    /// "one" form with the singular noun and an "other" form with the plural, directly or through a substitution.
    func testPluralKeysHaveEnglishOneAndOtherForms() throws {
        let plurals = [("%lld editions", "edition"), ("%lld editions · %@ %@", "edition"),
                       ("%lld trades in the period", "trade"), ("%lld claims · fees and rewards", "claim"),
                       ("Best price so far. Still checking %lld more venues.", "venue")]
        // The reader finds a direct plural and one inside a substitution.
        let direct: [String: Any] = ["variations": ["plural": ["one": ["stringUnit": ["value": "%lld edition"]],
                                                               "other": ["stringUnit": ["value": "%lld editions"]]]]]
        let substituted: [String: Any] = ["stringUnit": ["value": "%#@arg1@ · %2$@ %3$@"],
                                          "substitutions": ["arg1": ["variations": ["plural": ["one": ["stringUnit": ["value": "%arg claim"]]]]]]]
        XCTAssertEqual(Self.pluralForms(in: [direct]).one, ["%lld edition"])
        XCTAssertEqual(Self.pluralForms(in: [direct]).other, ["%lld editions"])
        XCTAssertEqual(Self.pluralForms(in: [substituted]).one, ["%arg claim"])
        let data = Data(try DocsLinksTests.appSource("Resources/Localizable.xcstrings").utf8)
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        try XCTSkipIf(strings.isEmpty, "catalog step pending: give \(plurals.map(\.0)) English one and other forms")
        for (name, noun) in plurals {
            let english = (((strings[name] as? [String: Any])?["localizations"] as? [String: Any])?["en"]).map { [$0] } ?? []
            let forms = Self.pluralForms(in: english)
            XCTAssertTrue(forms.one.contains { $0.contains(noun) && !$0.contains(noun + "s") }, "\(name): no English \"one\" form with \"\(noun)\"")
            XCTAssertTrue(forms.other.contains { $0.contains(noun + "s") }, "\(name): no English \"other\" form with \"\(noun)s\"")
        }
    }

    /// The text of every "one" and "other" case under a catalog entry's plural variations, however deep (a substitution
    /// keeps its own).
    private static func pluralForms(in values: [Any]) -> (one: [String], other: [String]) {
        var one: [String] = [], other: [String] = []
        for case let value as [String: Any] in values {
            if let plural = (value["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                func text(_ form: String) -> String? { ((plural[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
                if let text = text("one") { one.append(text) }
                if let text = text("other") { other.append(text) }
            }
            let nested = pluralForms(in: Array(value.values))
            one += nested.one
            other += nested.other
        }
        return (one, other)
    }

    /// One key is one translation, so a word with two meanings is two keys, and English reads the same word in both
    /// places: a past cohort Moment's "Closed" (collecting is closed) is not the Perps tab of closed positions, and My
    /// Launchpad's "View" (the name of its switch, a noun) is not the explorer link's verb.
    func testAWordWithTwoMeaningsIsTwoKeys() throws {
        let past = try DocsLinksTests.appSource("Portfolio/PastCohortsCard.swift")
        XCTAssertTrue(past.contains(#"Text(verbatim: tr(LocalizedStringResource("pastCohort.closed", defaultValue: "Closed", comment: "#))
        XCTAssertTrue(past.contains(#"(info.graduated ? Text("Graduated") : info.state == .expired ? Text("Expired")"#), "each status is a key")
        XCTAssertFalse(past.contains(#""Closed")"#))
        let profile = try DocsLinksTests.appSource("Launchpad/LaunchpadProfileView.swift")
        XCTAssertTrue(profile.contains(#"Picker(tr(LocalizedStringResource("myLaunchpad.view", defaultValue: "View", comment: "#))
        XCTAssertFalse(profile.contains(#"Picker("View""#))
    }

    /// Home's four categories, My Holdings' switch and the balance card's split, are keys of their own, apart from the
    /// tabs' and the menu's names: four share the card's width, so a language whose Launch tab is a long word keeps the
    /// switch short. The split names each category as the switch does. English reads Spot, Perps, Launch and Moments.
    func testHomesCategoriesAreKeysOfTheirOwn() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        for (key, english) in [("spot", "Spot"), ("perps", "Perps"), ("launch", "Launch"), ("moments", "Moments")] {
            XCTAssertTrue(home.contains(#"tr(LocalizedStringResource("homeCategory.\#(key)", defaultValue: "\#(english)", comment: "[tight] Home, one of four categories sharing the card's width: a segment of My Holdings' switch and a label over the balance card's split."#), key)
        }
        for (category, value) in [("spot", "spotValue"), ("perps", "perpsValue"), ("launchpad", "launchpadValue"), ("moments", "momentsValue")] {
            XCTAssertTrue(home.contains("splitStat(.\(category), model.\(value), "), "the split names \(category) as the switch does")
        }
        XCTAssertTrue(home.contains("Text(verbatim: category.label).font(.caption)"))
        XCTAssertTrue(home.contains("ForEach(HoldingCategory.allCases) { Text($0.label).tag($0) }"))
        XCTAssertFalse(home.contains(#"splitStat("Launch""#), "the split's labels are the categories'")
        XCTAssertFalse(home.contains(#"LocalizedStringResource("Launch", comment:"#), "Home's switch no longer borrows the Launch tab's key")
    }

    // MARK: What stays English

    /// Aurora's errors are matched on its own English text, whatever the app's language; the amounts in them are then
    /// written in the token's units.
    func testServerMatchersStayEnglish() throws {
        let bridge = try DocsLinksTests.appSource("Bridge/BridgeModel.swift")
        XCTAssertTrue(bridge.contains(#"message.lowercased().contains("at least") || message.lowercased().contains("too low"),"#))
        XCTAssertTrue(bridge.contains("// not localized: Aurora's own English error text"))
    }

    // MARK: Times

    /// Every age on screen says "ago" through the key "%@ ago" around `RelativeTime` (DyorKit, in the app's language), and
    /// the coin card shows the age on its own. The app keeps no English copy of it.
    func testAgesSayAgoThroughAKey() throws {
        var agos = 0
        for (path, code) in try Self.sources() {
            let text = String(code)
            agos += text.components(separatedBy: #"Text("\(RelativeTime.short("#).count - 1
            for line in text.components(separatedBy: "\n") where line.contains("RelativeTime.short(") {
                XCTAssertTrue(line.contains(") ago\")") || line.contains("Text(verbatim: RelativeTime.short("), "\(path): \(line)")
            }
        }
        XCTAssertEqual(agos, 3, "Launch trades, My Launchpad activity and Swap history")
        XCTAssertNil(try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift").range(of: "enum RelativeTime"), "one RelativeTime, DyorKit's")
    }

    // MARK: A small reader of Swift source (single-line string literals), enough for these files

    /// `chars` without its `//` and `/* */` comments; string literals are kept whole.
    static func uncommented(_ chars: [Character]) -> [Character] {
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "\"", let end = stringEnd(chars, index) {
                out += chars[index...end]
                index = end + 1
                continue
            }
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    private static func line(of index: Int, in chars: [Character]) -> Int { chars[..<index].filter { $0 == "\n" }.count + 1 }

    /// Each call of a view in `views` (not a member, not a declaration) or of a modifier in `modifiers` (a member), with
    /// the text between its parentheses.
    private static func calls(in chars: [Character], views: Set<String>, modifiers: Set<String>) -> [(name: String, start: Int, arguments: [Character])] {
        func isIdentifier(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }
        var found: [(String, Int, [Character])] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "\"", let end = stringEnd(chars, index) { index = end + 1; continue }
            if chars[index] == "(" {
                var start = index
                while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
                let name = String(chars[start..<index])
                let member = start > 0 && chars[start - 1] == "."
                let declared = start >= 5 && String(chars[(start - 5)..<start]) == "func "
                if !name.isEmpty, !declared, member ? modifiers.contains(name) : views.contains(name), let close = closing(chars, index) {
                    found.append((name, start, Array(chars[(index + 1)..<close])))
                }
            }
            index += 1
        }
        return found
    }

    /// The index of the bracket closing the one at `open`, skipping string literals and nested brackets.
    static func closing(_ chars: [Character], _ open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                guard let end = stringEnd(chars, index) else { return nil }
                index = end + 1
                continue
            }
            if "([{".contains(char) { depth += 1 } else if ")]}".contains(char) {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// The index of the quote closing the literal that opens at `start`; its interpolations may hold literals of their own.
    private static func stringEnd(_ chars: [Character], _ start: Int) -> Int? {
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

    /// The top-level arguments of an argument list.
    private static func split(_ chars: [Character]) -> [String] {
        var arguments: [String] = []
        var current: [Character] = []
        var depth = 0
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"", let end = stringEnd(chars, index) {
                current += chars[index...end]
                index = end + 1
                continue
            }
            if "([{".contains(char) { depth += 1 } else if ")]}".contains(char) { depth -= 1 }
            if char == ",", depth == 0 {
                arguments.append(String(current))
                current = []
            } else {
                current.append(char)
            }
            index += 1
        }
        arguments.append(String(current))
        return arguments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// An argument's label, if it has one, and its value.
    private static func labelled(_ argument: String) -> (label: String?, value: String) {
        guard let match = argument.range(of: #"^[A-Za-z_][A-Za-z0-9_]*:\s"#, options: .regularExpression) else { return (nil, argument) }
        let label = argument[match].trimmingCharacters(in: .whitespaces).dropLast()
        return (String(label), String(argument[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// The string literals of a value, each with its text outside the interpolations: those at its top level (a ternary's
    /// sides, a `??`, a closure whose result is the value), not those inside a call or a subscript, which are another
    /// call's own; with `nestedToo`, those inside calls as well, except inside `tr(`.
    private static func literals(in chars: [Character], nestedToo: Bool = false) -> [(source: String, words: String)] {
        var found: [(String, String)] = []
        var nesting: [(nests: Bool, name: String)] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"", let end = stringEnd(chars, index) {
                let depth = nesting.filter(\.nests).count
                let inTr = nesting.contains { $0.name == "tr" }
                if nestedToo ? !inTr : depth == 0 {
                    var words = ""
                    var inner = index + 1
                    while inner < end {
                        if chars[inner] == "\\", chars[inner + 1] == "(", let close = closing(chars, inner + 1) {
                            inner = close + 1
                            continue
                        }
                        words.append(chars[inner])
                        inner += 1
                    }
                    found.append((String(chars[index...end]), words))
                }
                index = end + 1
                continue
            }
            if "([{".contains(char) {
                let previous = index > 0 ? chars[index - 1] : " "
                var start = index
                while start > 0, chars[start - 1].isLetter || chars[start - 1].isNumber || chars[start - 1] == "_" { start -= 1 }
                let nests = char == "{" ? !isValueClosure(chars, index)
                    : char != "(" || previous.isLetter || previous.isNumber || "_)]>?!".contains(previous)
                nesting.append((nests, char == "(" ? String(chars[start..<index]) : ""))
            } else if ")]}".contains(char) {
                _ = nesting.popLast()
            }
            index += 1
        }
        return found
    }

    /// Whether the closure opening at `open` gives the value its result: nothing follows it but the end of the value, a
    /// `??` or a ternary's `:`.
    private static func isValueClosure(_ chars: [Character], _ open: Int) -> Bool {
        guard var next = closing(chars, open).map({ $0 + 1 }) else { return false }
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        guard next < chars.count else { return true }
        return chars[next] == ":" || chars[next] == ")" || (chars[next] == "?" && next + 1 < chars.count && chars[next + 1] == "?")
    }

    /// The sides of a value's top-level ternaries and `??`s (the conditions left out), those of a side in parentheses
    /// included, or the value itself.
    static func branches(_ value: String) -> [String] {
        let chars = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        if chars.first == "(", closing(chars, 0) == chars.count - 1 { return branches(String(chars[1..<(chars.count - 1)])) }
        var depth = 0
        var index = 0
        var marks: [(Int, String)] = [] // top-level " ?? ", " ? " and " : ", by position
        while index < chars.count {
            let char = chars[index]
            if char == "\"", let end = stringEnd(chars, index) { index = end + 1; continue }
            if "([{".contains(char) { depth += 1 } else if ")]}".contains(char) { depth -= 1 }
            if depth == 0, index > 0, chars[index - 1].isWhitespace {
                if char == "?", index + 2 < chars.count, chars[index + 1] == "?", chars[index + 2].isWhitespace { marks.append((index, "??")); index += 2; continue }
                if char == "?", index + 1 < chars.count, chars[index + 1].isWhitespace { marks.append((index, "?")) }
                if char == ":", index + 1 < chars.count, chars[index + 1].isWhitespace { marks.append((index, ":")) }
            }
            index += 1
        }
        guard !marks.isEmpty else { return [String(chars)] }
        var sides: [String] = []
        var from = 0
        for (position, mark) in marks {
            let part = String(chars[from..<position]).trimmingCharacters(in: .whitespacesAndNewlines)
            if mark != "?" { sides += branches(part) } // the part before a "?" is a condition
            from = position + (mark == "??" ? 2 : 1)
        }
        sides += branches(String(chars[from...]))
        return sides
    }

    private static func isLiteral(_ side: String) -> Bool {
        let chars = Array(side.trimmingCharacters(in: CharacterSet(charactersIn: "()").union(.whitespacesAndNewlines)))
        guard chars.first == "\"", let end = stringEnd(chars, 0) else { return false }
        return end == chars.count - 1
    }

    private static func hasWords(_ literal: String) -> Bool {
        Self.literals(in: Array(literal)).contains { $0.words.range(of: "[A-Za-z]{2,}", options: .regularExpression) != nil }
    }

    /// Whether a literal holds writing for a person to read: a lowercase word, and a space or a capital letter starting a
    /// word ("Not enough MON", "Spot"). Not an amount with its symbol, an identifier ("creator-…") or an SF Symbol.
    static func isWriting(_ literal: String) -> Bool {
        guard let words = literals(in: Array(literal)).first?.words else { return false }
        guard words.range(of: "[a-z]{2,}", options: .regularExpression) != nil else { return false }
        if words.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil { return false }
        return words.contains(" ") || words.range(of: "[A-Z][a-z]", options: .regularExpression) != nil
    }
}
