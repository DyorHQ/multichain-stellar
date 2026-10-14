import Foundation
import XCTest
@testable import DyorKit

/// Korean paragraphs wrap between words (`WordWrap`, the app's `Paragraph`), read from the app's sources and catalog: a
/// section footer long enough to wrap in Korean is a `Paragraph`, never a `Text`, and `Paragraph` is the `Text` it always
/// was in every other language.
final class KoreanParagraphsTests: XCTestCase {
    /// The app's catalog: each key's Korean.
    private static func korean() throws -> [String: String] {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { ios.deleteLastPathComponent() }
        let url = ios.appendingPathComponent("DyorHQ/Resources/Localizable.xcstrings")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        var out: [String: String] = [:]
        for (key, entry) in strings {
            guard let ko = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["ko"] as? [String: Any] else { continue }
            if let value = (ko["stringUnit"] as? [String: Any])?["value"] as? String {
                out[key] = value
            } else if let plural = (ko["variations"] as? [String: Any])?["plural"] as? [String: Any] {
                out[key] = plural.values.compactMap { (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }.max { $0.count < $1.count }
            }
        }
        return out
    }

    /// The bodies of every `footer: { … }` closure in `source`.
    static func footers(in source: String) -> [Substring] {
        var bodies: [Substring] = []
        var search = source.startIndex
        while let marker = source.range(of: "footer: {", range: search..<source.endIndex) {
            var depth = 1
            var index = marker.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "{" { depth += 1 } else if source[index] == "}" { depth -= 1 }
                index = source.index(after: index)
            }
            bodies.append(source[marker.upperBound..<source.index(before: index)])
            search = index
        }
        return bodies
    }

    /// The catalog key a written literal names: its text, each interpolation a specifier.
    static func key(of literal: String, in keys: [String]) -> String? {
        let parts = literal.components(separatedBy: #"\("#)
        guard parts.count > 1 else { return literal.replacingOccurrences(of: #"\""#, with: "\"") }
        // Each interpolation ends at its balancing parenthesis; the text after it is the next static part.
        var statics = [parts[0]]
        for part in parts.dropFirst() {
            var depth = 1
            var index = part.startIndex
            while index < part.endIndex, depth > 0 {
                if part[index] == "(" { depth += 1 } else if part[index] == ")" { depth -= 1 }
                index = part.index(after: index)
            }
            statics.append(String(part[index...]))
        }
        let pattern = "^" + statics.map { NSRegularExpression.escapedPattern(for: $0.replacingOccurrences(of: #"\""#, with: "\"")) }
            .joined(separator: #"%(?:\d+\$)?(?:@|lld|ld|d|lf|f|\.\d+f)"#) + "$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let found = keys.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        return found.count == 1 ? found[0] : nil
    }

    /// A footer whose Korean runs past one line (30 characters) is a `Paragraph`: as a `Text` it would break between two
    /// syllables of a word.
    func testLongFootersWrapByWord() throws {
        let korean = try Self.korean()
        let keys = Array(korean.keys)
        let literal = try NSRegularExpression(pattern: #"(?<![\w.])Text\("((?:[^"\\]|\\.)*)"\)"#)
        var checked = 0
        var plain: [String] = []
        var paragraphs = 0
        for (path, text) in try FormattedTextIsolationTests.appSources() {
            for footer in Self.footers(in: text) {
                let body = String(footer)
                paragraphs += body.components(separatedBy: "Paragraph(").count - 1
                for match in literal.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                    guard let range = Range(match.range(at: 1), in: body), let key = Self.key(of: String(body[range]), in: keys),
                          let ko = korean[key] else { continue }
                    checked += 1
                    // Joined to another Text ("A" + "B") it can't be a Paragraph; none of the footers does that today.
                    if ko.count > 30 { plain.append("\(path): Text(\"\(body[range].prefix(60))…\")") }
                }
            }
        }
        XCTAssertEqual(plain, [], "a footer long enough to wrap in Korean is a Paragraph")
        XCTAssertGreaterThan(paragraphs, 90, "the footers are Paragraphs")
        XCTAssertGreaterThan(checked, 10, "the scan reads the footers' short Texts")
    }

    /// The reader finds a literal's key, interpolations and all.
    func testTheReaderFindsALiteralsKey() {
        let keys = ["Held by %@ on Monad. This version can't send, trade or sign anything.", "%lld words. Words are separated by spaces.", "Plain"]
        XCTAssertEqual(Self.key(of: #"Held by \(address.short) on Monad. This version can't send, trade or sign anything."#, in: keys), keys[0])
        XCTAssertEqual(Self.key(of: #"\(count) words. Words are separated by spaces."#, in: keys), keys[1])
        XCTAssertEqual(Self.key(of: "Plain", in: keys), "Plain")
        XCTAssertEqual(Self.footers(in: "Section { A } footer: { Text(\"x\") { y } }"), [" Text(\"x\") { y } "])
    }

    /// An order's result wraps by word in Korean (real-time spec I28): the outcome views' every line is a `Paragraph` in
    /// a label made for one (`ParagraphLabel`), never a label with a `String` or `Text` title, and the order sheet's
    /// warnings are paragraphs too.
    func testTheOrderResultWrapsByWord() throws {
        let outcome = try DocsLinksTests.appSource("Perps/PerpOrderOutcomeView.swift")
        XCTAssertNil(outcome.range(of: #"(?<![\w.])Label\(\s*(Text\(|"|[a-z]\w*\s*,)"#, options: .regularExpression), "no label with a String or Text title")
        XCTAssertGreaterThanOrEqual(outcome.components(separatedBy: "Paragraph(verbatim:").count - 1, 6)
        XCTAssertGreaterThanOrEqual(outcome.components(separatedBy: ".modifier(ParagraphLabel())").count - 1, 2)
        // A line limit or a scale factor turns a Paragraph back into plain Text (Korean breaks inside words, I28) and can
        // cut off what to check: none anywhere in the order's result views (the status bar, the receipt bar, the row).
        XCTAssertFalse(outcome.contains(".lineLimit("), "no line limit on an order result")
        XCTAssertFalse(outcome.contains(".minimumScaleFactor("), "no scale factor on an order result")
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        let sheet = String(trade[try XCTUnwrap(trade.range(of: "struct AuthedOrderSheet: View {")).lowerBound...])
        XCTAssertFalse(sheet.contains("Label(message, systemImage:"), "the sheet's warnings are paragraphs")
        XCTAssertTrue(sheet.contains("Label { Paragraph(verbatim: message) } icon: { Image(systemName: \"exclamationmark.triangle.fill\") }"))
    }

    /// Close Position, Add Margin and Cancel Order sent over the trading connection wrap by word in Korean too (p4 spec §9.3,
    /// I28): their failure, sending and waiting lines are paragraphs, their results go through the outcome views, and no line
    /// is a label with a `String` or `Text` title, or held to a line limit or a scale factor.
    func testTheAPIActionSheetsWrapByWord() throws {
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        func slice(_ text: String, from start: String, to end: String) throws -> String {
            let from = try XCTUnwrap(text.range(of: start), start)
            let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
            return String(text[from.lowerBound..<to.lowerBound])
        }
        let stringTitle = #"(?<![\w.])Label\(\s*(Text\(|"|[a-z]\w*\s*,)"#
        let close = try slice(trade, from: "struct ClosePositionSheet: View {", to: "struct AddMarginSheet: View {")
        let margin = try slice(trade, from: "struct AddMarginSheet: View {", to: "struct AuthedOrderSheet: View {")
        for (name, sheet) in [("ClosePositionSheet", close), ("AddMarginSheet", margin)] {
            XCTAssertTrue(sheet.contains("Paragraph(verbatim: failureLine)"), name)
            XCTAssertTrue(sheet.contains("Paragraph(verbatim: PerpOrderCopy.sending)"), name)
            XCTAssertTrue(sheet.contains("PerpOrderStatusBar("), name)
            XCTAssertTrue(sheet.contains("PerpOrderOutcomeSection("), name)
            XCTAssertNil(sheet.range(of: stringTitle, options: .regularExpression), "\(name): no label with a String or Text title")
            XCTAssertFalse(sheet.contains("Label(message, systemImage:"), name)
            XCTAssertFalse(sheet.contains("Text(failureLine") || sheet.contains("Text(verbatim: failureLine"), name)
            XCTAssertFalse(sheet.contains(".lineLimit("), "\(name): no line limit")
            XCTAssertFalse(sheet.contains(".minimumScaleFactor("), "\(name): no scale factor")
        }
        XCTAssertTrue(margin.contains("Paragraph(verbatim: PerpActionCopy.marginCanClose)"))
        XCTAssertTrue(close.contains("Paragraph(verbatim: perplTrading.nothingSentLine(for: route))"), "the wallet's line after a refusal for forwarding")

        let sheets = try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift")
        let cancel = try slice(sheets, from: "struct CancelOrderSheet: View {", to: "private struct CancelTriggerRow: View {")
        XCTAssertTrue(cancel.contains("Paragraph(verbatim: failureLine)"))
        XCTAssertTrue(cancel.contains("Label { Paragraph(verbatim: line.text) }"))
        XCTAssertNil(cancel.range(of: stringTitle, options: .regularExpression), "no label with a String or Text title")
        XCTAssertFalse(cancel.contains("Text(failureLine") || cancel.contains("Text(verbatim: failureLine") || cancel.contains("Text(verbatim: line.text"))
        XCTAssertFalse(cancel.contains(".lineLimit(") || cancel.contains(".minimumScaleFactor("))
    }

    /// The TP/SL sheets' outcome and progress lines, and the Orders tab's TP/SL warnings, wrap by word in Korean (real-time
    /// spec I28): a paragraph in a label made for one, never a label with a `String` title.
    func testTheTPSLLinesWrapByWord() throws {
        let sheets = try DocsLinksTests.appSource("Perps/PerpTriggerSheets.swift")
        XCTAssertFalse(sheets.contains("Label(line.text"), "an outcome line is a paragraph")
        XCTAssertTrue(sheets.contains("Label { Paragraph(verbatim: line.text) } icon: {"))
        XCTAssertTrue(sheets.contains("Label { Paragraph(verbatim: PerpTriggerCopy.step(kind, step)) } icon: { ProgressView().controlSize(.mini) }"))
        let trade = try DocsLinksTests.appSource("Perps/PerpTradeView.swift")
        XCTAssertFalse(trade.contains(#"Label("\(orphans.count) TP/SL on"#), "the leftover banner is a paragraph")
        XCTAssertTrue(trade.contains(#"Paragraph("\(orphans.count) TP/SL on \(market.asset) have no position to close."#))
        XCTAssertFalse(trade.contains(#"Label("TP/SL can't be verified right now"#))
        XCTAssertTrue(trade.contains(#"freshnessNote(Paragraph("TP/SL can't be verified right now"#))
    }

    /// `Paragraph` lays out word by word only in Korean, with no line limit or minimum scale, and only up to its limit;
    /// otherwise it is the `Text` it always was. A key's markdown is drawn as `Text` draws it.
    func testParagraphIsTextOutsideKorean() throws {
        let paragraph = try DocsLinksTests.appSource("Design/Paragraph.swift")
        let squeezed = paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(squeezed.contains("if WordWrap.keepsWordsWhole(locale.language), lineLimit == nil, minimumScaleFactor >= 1, text.characters.count <= Self.wordByWordLimit {"))
        XCTAssertTrue(squeezed.contains("} else { Text(text) }"))
        XCTAssertTrue(squeezed.contains("AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))"))
        XCTAssertTrue(squeezed.contains(".accessibilityElement(children: .ignore) .accessibilityLabel(Text(text))"), "VoiceOver reads the paragraph once, whole")
    }
}
