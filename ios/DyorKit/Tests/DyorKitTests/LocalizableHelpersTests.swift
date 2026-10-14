import Foundation
import XCTest
#if canImport(SwiftUI)
import SwiftUI
#endif

/// The shared UI helpers' text (L2a), read from the app's sources. A title, label or message written in the
/// code reaches a helper as a `LocalizedStringKey`, so it is a catalog key (a `LocalizedStringResource` where the text must
/// also become a `String`: the App Lock reason, a UIKit placeholder); text built at run time (an amount, a symbol, an
/// address, a server's message) is shown as it is. A helper's `String` overload is `@_disfavoredOverload`, as `Text`'s own
/// is, so a literal never picks it; and no literal passed to a helper is a key with nothing to translate ("%@ %@",
/// "%@ AUSD"): those go as `verbatim:`.
final class LocalizableHelpersTests: XCTestCase {
    private static func ios() throws -> URL {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        guard FileManager.default.fileExists(atPath: ios.appendingPathComponent("DyorHQ").path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        return ios
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: try ios().appendingPathComponent(path), encoding: .utf8)
    }

    /// Every Swift file of the app, by its path under ios/DyorHQ.
    private static func appSources() throws -> [(path: String, text: String)] {
        let app = try ios().appendingPathComponent("DyorHQ")
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map {
            (String($0.path.dropFirst(app.path.count + 1)), try String(contentsOf: $0, encoding: .utf8))
        }.sorted { $0.path < $1.path }
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The declarations from `struct <name>` to its `var body`: the stored properties and the initializers.
    private static func members(of name: String, in text: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: "struct \(name)"), name).upperBound
        let to = try XCTUnwrap(text.range(of: "var body", range: from..<text.endIndex), name).lowerBound
        return String(text[from..<to])
    }

    /// The shared helpers every screen uses take their text localized, with a `String` path kept for run-time text.
    func testSharedHelpersTakeLocalizedText() throws {
        let components = Self.squeezed(try Self.source("DyorHQ/Design/Components.swift"))
        for signature in [
            "init(title: LocalizedStringKey, text: Binding<String>, token: Token?, onMax: (() -> Void)? = nil)", // AmountField
            "init(title: LocalizedStringKey, address: Address)", // AddressRow
            "init(message: LocalizedStringResource)", // InlineError: a key resolved in the app's language, wrapped by word in Korean
            "init(title: LocalizedStringKey, systemImage: String? = nil, image: String? = nil, isBusy: Bool = false, isDisabled: Bool = false, foreground: Color = .white, action: @escaping () -> Void)", // PrimaryButton
            "init(title: Text, systemImage: String? = nil,", // PrimaryButton, for a caller's own Text
            "init(_ label: LocalizedStringKey, _ value: LocalizedStringKey, tint: Color = .primary, spellsOut: Bool = false)", // DetailRow
            "init<S: StringProtocol>(_ label: LocalizedStringKey, _ value: S, tint: Color = .primary, spellsOut: Bool = false)",
            "init(_ label: LocalizedStringKey, verbatim value: String, tint: Color = .primary, spellsOut: Bool = false)",
            "init(_ label: Text, _ value: Text, tint: Color = .primary, spellsOut: Bool = false)",
        ] {
            XCTAssertTrue(components.contains(signature), signature)
        }
        // InlineError's VoiceOver label keeps its key ("Error: %@"), with the message in the app's language; the message
        // itself is a Paragraph, so Korean wraps between words.
        XCTAssertTrue(components.contains(".accessibilityLabel(Text(\"Error: \\(spoken)\"))"))
        XCTAssertTrue(components.contains("case .localized(let resource): Paragraph(resource)"))
        XCTAssertTrue(components.contains("case .verbatim(let text): Paragraph(verbatim: text)"))

        let profile = try Self.source("DyorHQ/Profile/ProfileView.swift")
        XCTAssertTrue(Self.squeezed(profile).contains("init(_ title: LocalizedStringKey, symbol: String, tint: Color = .accent)"), "SettingsRow")

        // No shared helper keeps its text as a `String`, which `Text` would show without looking it up.
        let shared = [("AmountField: View", components), ("AddressRow: View", components), ("InlineError: View", components),
                      ("PrimaryButton: View", components), ("DetailRow: View", components), ("SettingsRow: View", profile)]
        for (name, text) in shared {
            let members = try Self.members(of: name, in: text)
            for property in ["let title: String", "let label: String", "let value: String", "let message: String"] {
                XCTAssertFalse(members.contains(property), "\(name): \(property)")
            }
        }

        // ConfirmationSheet: both titles are resources, resolved in the app's language for the navigation title, the
        // confirm button and the App Lock reason (a `String` iOS shows itself).
        let sheet = try Self.source("DyorHQ/Wallet/TransactionRun.swift")
        let sheetMembers = try Self.members(of: "ConfirmationSheet<Details: View>: View", in: sheet)
        XCTAssertTrue(sheetMembers.contains("let title: LocalizedStringResource"))
        XCTAssertTrue(sheetMembers.contains("let confirmTitle: LocalizedStringResource"))
        XCTAssertTrue(sheet.contains(".navigationTitle(tr(title))"))
        XCTAssertTrue(sheet.contains("BiometricGate.authenticate(reason: \"Confirm \\(tr(confirmTitle))\")"))
        XCTAssertTrue(sheet.contains("Text(\"Confirm with \\(BiometricGate.promptName)\") : Text(verbatim: tr(confirmTitle))"))

        // A key inside another key's interpolation is shown as its debug description ("LocalizedStringKey(key: …)"), so a
        // helper that puts its key title into a sentence wraps it in Text first; a label made only of other text joins the
        // Texts as they are (HelpRow's title and description: "%@. %@" would be a key with nothing to translate); an
        // amount with its symbol is verbatim.
        let help = try Self.source("DyorHQ/Support/GetHelpView.swift")
        XCTAssertTrue(help.contains(".accessibilityLabel(title + Text(verbatim: \". \") + detail)"), "HelpRow's VoiceOver label")
        XCTAssertTrue(try Self.source("DyorHQ/Perps/PerpTradeView.swift").contains(
            ".accessibilityLabel(Text(\"\\(Text(side)) \\(NumberStyle.number(level.price)), total \\(NumberStyle.number(level.total, compact: true)) \\(symbol)\"))"),
            "the order book row's VoiceOver label")
        XCTAssertTrue(components.contains("Text(verbatim: \"\\(NumberStyle.units(amount, decimals: token.decimals, compact: compact)) \\(token.symbol)\")"), "AmountText")

        // The trigger sheet's title and note are written where the request is made, as resources.
        let trade = try Self.source("DyorHQ/Perps/PerpTradeView.swift")
        XCTAssertTrue(trade.contains("let title: LocalizedStringResource\n    let note: LocalizedStringResource?"), "TriggerCancelRequest")
        let triggers = try Self.source("DyorHQ/Perps/PerpTriggerSheets.swift")
        XCTAssertTrue(triggers.contains(".navigationTitle(tr(title))"))
        XCTAssertTrue(triggers.contains("if let note { Text(verbatim: tr(note)) }"))
    }

    /// A helper's `String` overload is disfavored, so a literal still picks the key, and it shows its text as it is.
    func testEveryStringOverloadIsDisfavoredAndShownAsItIs() throws {
        var overloads = 0
        for (path, text) in try Self.appSources() {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("<S: StringProtocol>(") && (line.contains("init<S") || line.contains("func ")) {
                overloads += 1
                let previous = lines[..<index].last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.trimmingCharacters(in: .whitespaces)
                XCTAssertEqual(previous, "@_disfavoredOverload", "\(path):\(index + 1): a literal would pick this `String` overload and skip the catalog")
                let body = lines[index..<min(lines.count, index + 4)].joined(separator: "\n")
                XCTAssertTrue(body.contains("verbatim"), "\(path):\(index + 1): a run-time `String` is shown as it is, never looked up")
            }
            for (index, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespaces) == "@_disfavoredOverload" {
                let body = lines[(index + 1)..<min(lines.count, index + 5)].joined(separator: "\n")
                XCTAssertTrue(body.contains("verbatim"), "\(path):\(index + 1)")
            }
        }
        // AmountField, AddressRow, InlineError, PrimaryButton, DetailRow, SettingsRow, HelpRow, the Launch board's section,
        // the News and Notifications chips and Send's read notice.
        XCTAssertGreaterThanOrEqual(overloads, 11)
    }

    /// No view helper takes text that is written in the code as a `String`: it would be shown without being looked up.
    /// The few `String` parameters left carry text made at run time, each named here with what it holds.
    func testNoViewHelperTakesWrittenTextAsAString() throws {
        let runTime: Set<String> = [
            "Launchpad/LaunchpadProfileView.swift claimRow caption", // the claimable's own caption, from the model
            "Perps/PerpTradeView.swift stepperField placeholder", // the mark price, a number
            "Perps/PerpTradeView.swift optionRow title", // the size unit's symbol: the market's asset or AUSD
            "Portfolio/AssetsModel.swift tokenRow note", // the run-time overload: a curve route's note from DyorKit
            "Profile/AccountDeletion.swift DeletionNoticeView message", // the deletion's notice, worded by the Session
        ]
        let textName = #"(title|label|subtitle|detail|caption|message|text|placeholder|note|header|side)"#
        let helper = try NSRegularExpression(pattern: #"func (\w+)(<[^>]*>)?\((.*)\) -> some View"#)
        let parameter = try NSRegularExpression(pattern: #"^\s*(?:\w+\s+)?"# + textName + #":\s*String\??\s*(=.*)?$"#)
        let view = try NSRegularExpression(pattern: #"^(?:private |fileprivate )?struct (\w+)(<[^>]*>)?: View[ ,{]"#, options: .anchorsMatchLines)
        let stored = try NSRegularExpression(pattern: #"^    (?:private )?(?:let|var) "# + textName + #": String\??\s*(=.*)?$"#, options: .anchorsMatchLines)
        var found: Set<String> = []
        for (path, text) in try Self.appSources() {
            for line in text.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = helper.firstMatch(in: line, range: range),
                      let name = Range(match.range(at: 1), in: line), let parameters = Range(match.range(at: 3), in: line) else { continue }
                for item in line[parameters].split(separator: ",").map(String.init) {
                    let itemRange = NSRange(item.startIndex..., in: item)
                    if let hit = parameter.firstMatch(in: item, range: itemRange), let label = Range(hit.range(at: 1), in: item) {
                        found.insert("\(path) \(line[name]) \(item[label])")
                    }
                }
            }
            // A view's stored text, at the top level of a top-level `struct …: View` (nested models are the lanes' own).
            let whole = NSRange(text.startIndex..., in: text)
            for match in view.matches(in: text, range: whole) {
                guard let name = Range(match.range(at: 1), in: text), let start = Range(match.range, in: text)?.upperBound else { continue }
                let end = text.range(of: "\n}", range: start..<text.endIndex)?.lowerBound ?? text.endIndex
                let block = String(text[start..<end])
                for hit in stored.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
                    if let label = Range(hit.range(at: 1), in: block) { found.insert("\(path) \(text[name]) \(block[label])") }
                }
            }
        }
        XCTAssertEqual(found.subtracting(runTime).sorted(), [], "a helper's text written in the code must be a LocalizedStringKey")
        XCTAssertEqual(runTime.subtracting(found).sorted(), [], "a run-time parameter named here no longer exists: drop it from the list")
    }

    /// No literal passed to a helper's localized parameter is a key with nothing to translate: an amount with its symbol
    /// ("\(units) \(symbol)" would be the key "%@ %@") goes as `verbatim:` or `Text(verbatim:)`. A literal with words
    /// ("Unlimited approval to \(spender)") is a proper key, its placeholders filled in at run time.
    func testNoPlaceholderOnlyKeyAtAHelperCall() throws {
        // Each helper's localized parameters: by position among the unlabelled arguments ("0", "1", …) or by label.
        let localized: [String: Set<String>] = [
            "DetailRow": ["0", "1"], "PrimaryButton": ["title"], "InlineError": ["message"], "SettingsRow": ["0"], "AddressRow": ["title"],
            "AmountField": ["title"], "ConfirmationSheet": ["title", "confirmTitle"], "TriggerCancelRequest": ["title", "note"],
            "HelpRow": ["title", "detail"], "group": ["0"], "statColumn": ["0"], "splitStat": ["0"], "holdingsEmpty": ["0", "1"],
            "HomeAction": ["title"], "copyButton": ["0"], "header": ["title", "detail"], "claimRow": ["title"], "stat": ["0"],
            "emptyRow": ["0", "1"], "section": ["title", "subtitle"], "sectionHeader": ["0", "subtitle"], "tile": ["0", "2"],
            "chip": ["0"], "summaryRow": ["0"], "metric": ["0"], "small": ["0"], "statTile": ["0"], "miniStat": ["0"], "checkRow": ["0"],
            "sideButton": ["1"], "historyStat": ["0"], "triggerMetricRow": ["0"], "fieldRow": ["0", "placeholder"],
            "optionRow": ["subtitle"], "sheetHeader": ["0"], "MiniStat": ["label"], "readNotice": ["0"], "swatch": ["1"], "row": ["1"],
            "nftTile": ["caption"], "tokenRow": ["note"], "Feature": ["1", "2"], "HeroAuthCard": ["title", "subtitle"],
            "SecondaryAuthRow": ["title", "subtitle"], "SocialButton": ["title"], "LabeledDivider": ["0"], "PasswordField": ["title"],
            "bookRow": ["side"], "holdingsUnreadRow": ["reading"], "holdingsRetryRow": ["0"],
        ]
        var checked = 0
        var verbatim = 0
        var placeholderOnly: [String] = []
        for (path, text) in try Self.appSources() {
            for (name, arguments) in Self.calls(in: Array(text), named: Set(localized.keys)) {
                guard let parameters = localized[name] else { continue }
                var position = 0
                for argument in Self.split(arguments) {
                    let (label, value) = Self.labelled(argument)
                    let key = label ?? String(position)
                    if label == nil { position += 1 }
                    if label == "verbatim" || value.hasPrefix("Text(verbatim:") { verbatim += 1; continue }
                    guard parameters.contains(key) else { continue }
                    for literal in Self.literals(in: Array(value)) {
                        checked += 1
                        if literal.interpolated, literal.words.range(of: "[a-z]{2,}", options: .regularExpression) == nil {
                            placeholderOnly.append("\(path): \(name)(… \(key): \(literal.source) …)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(placeholderOnly, [], "a literal with nothing to translate goes as verbatim:")
        // The scan reads a closure that gives the value its result, and leaves one whose result feeds something else.
        XCTAssertEqual(Self.literals(in: Array(#"pair.map { "\(units) \($0.symbol)" } ?? "—""#)).map { $0.source }, [#""\(units) \($0.symbol)""#, #""—""#])
        XCTAssertEqual(Self.literals(in: Array(#"names.map { "\($0)" }.joined(separator: ", ")"#)).map { $0.source }, [])
        XCTAssertGreaterThan(checked, 400, "the scan reads the helpers' calls")
        XCTAssertGreaterThanOrEqual(verbatim, 40, "amounts with their symbols are shown as they are")
    }

    // MARK: A small reader of Swift call arguments, enough for the app's helper calls (single-line string literals).

    /// Every call of one of `names` in `chars`, with the text between its parentheses: the name right before a "(", not
    /// a member's `x.name(` and not a declaration's `func name(`.
    private static func calls(in chars: [Character], named names: Set<String>) -> [(name: String, arguments: [Character])] {
        func isIdentifier(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }
        var found: [(String, [Character])] = []
        for open in chars.indices where chars[open] == "(" {
            var start = open
            while start > 0, isIdentifier(chars[start - 1]) { start -= 1 }
            guard start < open, !chars[start].isNumber else { continue }
            if start > 0, chars[start - 1] == "." { continue }
            if start >= 5, String(chars[(start - 5)..<start]) == "func " { continue }
            let name = String(chars[start..<open])
            guard names.contains(name) else { continue }
            if let close = closing(chars, open) { found.append((name, Array(chars[(open + 1)..<close]))) }
        }
        return found
    }

    /// The index of the bracket closing the one at `open`, skipping string literals and nested brackets.
    private static func closing(_ chars: [Character], _ open: Int) -> Int? {
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
        let label = argument[match].trimmingCharacters(in: .whitespaces).dropLast() // "title: " → "title"
        return (String(label), String(argument[match.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// The string literals at the top level of a value (a ternary's branches included, in parentheses or not; not those
    /// inside a call or a subscript), each with its text outside the interpolations. A closure whose result is the value
    /// itself, or one side of its `??` or ternary (`pair.map { "\(units) \($0.symbol)" } ?? "—"`), is read too: Swift
    /// infers the closure's literal from the helper's parameter, so at a key parameter it is a key like any other.
    private static func literals(in chars: [Character]) -> [(source: String, words: String, interpolated: Bool)] {
        var found: [(String, String, Bool)] = []
        var depth = 0
        var nesting: [Bool] = [] // for each open bracket: whether it is a call, a subscript or a closure, not a grouping
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"", let end = stringEnd(chars, index) {
                if depth == 0 {
                    var words = ""
                    var interpolated = false
                    var inner = index + 1
                    while inner < end {
                        if chars[inner] == "\\", chars[inner + 1] == "(", let close = closing(chars, inner + 1) {
                            interpolated = true
                            inner = close + 1
                            continue
                        }
                        words.append(chars[inner])
                        inner += 1
                    }
                    found.append((String(chars[index...end]), words, interpolated))
                }
                index = end + 1
                continue
            }
            if "([{".contains(char) {
                let previous = index > 0 ? chars[index - 1] : " "
                let nests = char == "{" ? !isValueClosure(chars, index)
                    : char != "(" || previous.isLetter || previous.isNumber || "_)]>?!".contains(previous)
                nesting.append(nests)
                if nests { depth += 1 }
            } else if ")]}".contains(char), nesting.popLast() == true {
                depth -= 1
            }
            index += 1
        }
        return found
    }

    /// Whether the closure opening at `open` gives the value its result: nothing follows it but the end of the value (or
    /// of its parentheses), a `??` or a ternary's `:`. A closure followed by more (`.joined()`, a call, a subscript, a
    /// ternary's `?`) feeds something else, which decides its literals' type.
    private static func isValueClosure(_ chars: [Character], _ open: Int) -> Bool {
        guard let close = closing(chars, open) else { return false }
        let rest = String(chars[(close + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || rest.hasPrefix("??") || rest.hasPrefix(":") || rest.hasPrefix(")")
    }

    #if canImport(SwiftUI)
    /// The rule the helpers' overloads rely on, as SwiftUI's `Text` does: with its `String` overload disfavored, a literal
    /// (interpolated or not, or a choice of literals) is a key and only a `String` value takes the other path. Without the
    /// attribute, a literal takes the `String` overload, its default type, and never reaches the catalog.
    func testALiteralIsAKeyOnlyWhenTheStringOverloadIsDisfavored() {
        enum Picked: Equatable { case key, string, verbatim }
        struct Helper {
            let label: Picked, value: Picked
            init(_ label: LocalizedStringKey, _ value: LocalizedStringKey) { self.label = .key; self.value = .key }
            @_disfavoredOverload
            init<S: StringProtocol>(_ label: LocalizedStringKey, _ value: S) { self.label = .key; self.value = .string }
            init(_ label: LocalizedStringKey, verbatim value: String) { self.label = .key; self.value = .verbatim }
        }
        struct Undecorated {
            let picked: Picked
            init(_ text: LocalizedStringKey) { picked = .key }
            init<S: StringProtocol>(_ text: S) { picked = .string }
        }
        let symbol = "MON"
        let long = Bool.random()
        XCTAssertEqual(Helper("Liquidity", "Locked forever").value, .key)
        XCTAssertEqual(Helper("Approval", "Unlimited approval to \(symbol)").value, .key)
        XCTAssertEqual(Helper("Side", long ? "Long" : "Short").value, .key)
        XCTAssertEqual(Helper("Venue", symbol).value, .string)
        XCTAssertEqual(Helper("To", Optional<String>.none ?? "—").value, .string)
        XCTAssertEqual(Helper("Graduation", Optional(symbol).map { "100 \($0)" } ?? "—").value, .key, "a closure's literal is inferred from the parameter")
        XCTAssertEqual(Helper("Amount", verbatim: "1 \(symbol)").value, .verbatim)
        XCTAssertEqual(Helper("Venue", symbol).label, .key, "the label stays a key whatever the value")
        XCTAssertEqual(Undecorated("Locked forever").picked, .string, "without the attribute a literal skips the catalog")
    }
    #endif
}
