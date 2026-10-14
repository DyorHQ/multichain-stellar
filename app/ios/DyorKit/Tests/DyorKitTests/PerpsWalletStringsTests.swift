import Foundation
import XCTest
@testable import DyorKit

/// The Perps and Wallet screens' text (L2, the Perps and Wallet folders), read from the app's sources: text written in
/// the code reaches the screen in the app's language. A `String` the code builds (a model's label, an error, an Activity
/// row, a notification) goes through `tr()`; a word is never chosen inside another string's interpolation (it would
/// never be looked up); text with nothing to translate ("/", "%", "5x") is shown verbatim, never as a key; durations,
/// dates and the chart's dates follow the app's language; and the strings that must stay English (what a server
/// reparses, what is matched against input, identifiers) are left as they are.
final class PerpsWalletStringsTests: XCTestCase {
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

    /// The Swift files of the Perps and Wallet folders, by their path under ios/DyorHQ. The Simulator's stub passkey
    /// provider is left out: it compiles only into DEBUG Simulator builds, and its messages are for developers.
    private static func scopedSources() throws -> [(path: String, text: String)] {
        let app = try ios().appendingPathComponent("DyorHQ")
        var out: [(String, String)] = []
        for folder in ["Perps", "Wallet"] {
            let files = FileManager.default.enumerator(at: app.appendingPathComponent(folder), includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            for file in files where file.pathExtension == "swift" && file.lastPathComponent != "StubPasskeyAuthenticator.swift" {
                out.append((String(file.path.dropFirst(app.path.count + 1)), try String(contentsOf: file, encoding: .utf8)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// One string literal on a line: what it says outside its interpolations, how deep it sits inside other literals'
    /// interpolations (0 for one written in the code), and the code before and after it.
    struct Literal {
        let text: String
        let depth: Int
        let before: String
        let after: String
    }

    /// The literals of one line of Swift, nested ones included. A `//` comment outside a literal ends the line.
    static func literals(in line: String) -> [Literal] {
        let chars = Array(line)
        var found: [Literal] = []
        var i = 0
        func code(depth: Int) {
            var parens = 0
            while i < chars.count {
                let c = chars[i]
                if c == "/", i + 1 < chars.count, chars[i + 1] == "/" { i = chars.count; return }
                if c == "\"" { string(depth: depth); continue }
                if c == "(" { parens += 1 }
                if c == ")" {
                    if parens == 0, depth > 0 { i += 1; return }
                    parens -= 1
                }
                i += 1
            }
        }
        func string(depth: Int) {
            let start = i
            i += 1
            var own = ""
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" { i += 2; code(depth: depth + 1); continue }
                    i += 2
                    continue
                }
                if c == "\"" { i += 1; break }
                own.append(c)
                i += 1
            }
            found.append(Literal(text: own, depth: depth, before: String(chars[..<start]), after: String(chars[min(i, chars.count)...])))
        }
        code(depth: 0)
        return found
    }

    /// Whether a literal's own text reads as words for a person: two words, or one capitalised word ("Unknown"). An
    /// identifier ("perp.triggers.v1.", "faceid") or a symbol ("AUSD", "-PERP") doesn't.
    static func isWords(_ text: String) -> Bool {
        text.range(of: #"[A-Za-z]{2,}\S*\s+\S*[A-Za-z]"#, options: .regularExpression) != nil
            || text.range(of: #"^[A-Z][a-z]+[.…!?]?$"#, options: .regularExpression) != nil
    }

    /// The lines of the scoped sources with their literals; a comment line is left out, and so is a line marked "not
    /// localized", or right under a comment line that marks it. A marker at the end of a line of code covers that line
    /// only: the next line (another case of the same switch, say) is read as any other.
    private static func scannedLines() throws -> [(at: String, line: String, literals: [Literal])] {
        scannedLines(of: try scopedSources())
    }

    static func scannedLines(of files: [(path: String, text: String)]) -> [(at: String, line: String, literals: [Literal])] {
        var out: [(String, String, [Literal])] = []
        for (path, text) in files {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("not localized") || previous.hasPrefix("//") && previous.contains("// not localized") { continue }
                out.append(("\(path):\(index + 1)", line, literals(in: line)))
            }
        }
        return out
    }

    /// A "not localized" marker at the end of a line of code covers that line only; a marker on a line of its own covers
    /// the line under it.
    func testANotLocalizedMarkerCoversItsOwnLine() {
        let cases = """
            case .google: return "Google" // not localized: a company's name
            case .email: return "Email"
            // not localized: Apple's name
            case .apple: return "Apple"
            """
        XCTAssertEqual(Self.scannedLines(of: [("Kind.swift", cases)]).flatMap(\.literals).map(\.text), ["Email"])
    }

    func testTheLiteralReaderSeesNestedLiterals() {
        let line = #"Text("Up \(above ? "above" : "below") \(x)") // "comment""#
        let found = Self.literals(in: line)
        XCTAssertEqual(found.map(\.text), ["above", "below", "Up  "])
        XCTAssertEqual(found.map(\.depth), [1, 1, 0])
        XCTAssertTrue(Self.isWords("Not sent."))
        XCTAssertTrue(Self.isWords("Unknown"))
        XCTAssertFalse(Self.isWords("perp.triggers.v1."))
        XCTAssertFalse(Self.isWords("-PERP"))
        XCTAssertFalse(Self.isWords(" · "))
    }

    /// A word chosen inside another string's interpolation (`"\(isLong ? "long" : "short") …"`) is never looked up:
    /// each choice is a sentence of its own, a key with its words, or a `tr()` of the word.
    func testNoWordIsChosenInsideAnInterpolation() throws {
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth > 0 && Self.isWords(literal.text) || literal.depth > 0 && literal.text.range(of: "^[a-z]{2,}$", options: .regularExpression) != nil {
                found.append("\(at): \"\(literal.text)\"")
            }
        }
        XCTAssertEqual(found, [], "a word inside an interpolation is shown in English in every language")
    }

    /// Text built as a `String` (a returned label, an assigned error, a failure, an Activity row, a notification, a step's
    /// label, a fallback after `??`) goes through `tr()`: a bare literal there is shown in English in every language.
    func testStringTextGoesThroughTr() throws {
        let sink = try NSRegularExpression(pattern: #"(return |(?<![=!<>])= |\+= |\?\? |\.failed\(|\.unavailable\(|\.invalidOrder\(|\.rejected\(|\.unknown\(|\.doneWarning\(|\.append\(|error: |TriggerSheetLine\(text: )$"#)
        let record = try NSRegularExpression(pattern: #"(title: |subtitle: |body: |label: |side: )$"#)
        var found: [String] = []
        for (at, line, literals) in try Self.scannedLines() {
            let recordLine = ["ActivityRecord(", "ProtectionNotice(", "post(kind:", ".call(", "Notifications."].contains { line.contains($0) }
            for literal in literals where literal.depth == 0 && Self.isWords(literal.text) {
                let before = NSRange(literal.before.startIndex..., in: literal.before)
                if sink.firstMatch(in: literal.before, range: before) != nil || (recordLine && record.firstMatch(in: literal.before, range: before) != nil) {
                    found.append("\(at): \"\(literal.text)\"")
                }
            }
        }
        XCTAssertEqual(found, [], "String text written in the code goes through tr()")
    }

    /// Text with nothing to translate ("/", "%", "—", "5x", "0.5") is shown as it is, never looked up as a key.
    func testNoPlaceholderOnlyKey() throws {
        let key = try NSRegularExpression(pattern: #"(Text|Paragraph|Label|Button|TextField|Toggle|\.accessibilityLabel|\.accessibilityValue|\.navigationTitle)\($"#)
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth == 0 && literal.text.range(of: "[A-Za-z]{2,}", options: .regularExpression) == nil {
                let before = NSRange(literal.before.startIndex..., in: literal.before)
                if key.firstMatch(in: literal.before, range: before) != nil, !literal.after.hasPrefix(" as String") {
                    found.append("\(at): \"\(literal.text)\"")
                }
            }
        }
        XCTAssertEqual(found, [], "a key with nothing to translate: show it verbatim")
    }

    /// A tab's or a case's name on screen is a written key, never its raw value (an identifier).
    func testNoRawValueIsShown() throws {
        let shown = try NSRegularExpression(pattern: #"(Text|Paragraph|Label|Button)\([^()]*\.rawValue(\.capitalized)?\)"#)
        for (path, text) in try Self.scopedSources() {
            XCTAssertNil(shown.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(path): a raw value shown as text")
            XCTAssertFalse(text.contains(".capitalized"), path)
        }
        let trade = try Self.source("DyorHQ/Perps/PerpTradeView.swift")
        XCTAssertTrue(trade.contains("ForEach(ChartDataTab.allCases) { $0.title.tag($0) }"))
        // The bottom tabs (Positions / Orders / Assets / Trade History): the shown title and the reserved selected width are
        // both the written key (p4 spec E).
        XCTAssertTrue(trade.contains("tab.title.font(.subheadline.weight(active ? .semibold : .regular))"))
        XCTAssertTrue(trade.contains("tab.title.font(.subheadline.weight(.semibold)).hidden()"))
        XCTAssertTrue(trade.contains("priceType.title.font("))
        XCTAssertTrue(try Self.source("DyorHQ/Perps/PerpsPortfolioView.swift").contains("ForEach(HistoryTab.allCases) { $0.title.tag($0) }"))
    }

    /// Durations are in the app language's own units, and every date written as a `String` is in the app's language
    /// (`L10n.locale`), not the device's.
    func testDurationsAndDatesFollowTheAppLanguage() throws {
        let scope = Self.squeezed(try Self.source("DyorHQ/Wallet/Mera/SessionScopeViews.swift"))
        XCTAssertTrue(scope.contains("Duration.seconds(Int(left.rounded(.up))).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(scope.contains("Duration.seconds(Int((left / 60).rounded(.up)) * 60).formatted(.units(allowed: [.minutes], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(scope.contains("return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))"))
        XCTAssertFalse(scope.contains("? \"1 hour\" :"), "no English-only length")
        XCTAssertFalse(scope.contains(")) minutes\""))
        let phrase = try Self.source("DyorHQ/Wallet/Mera/RecoveryPhraseView.swift")
        XCTAssertTrue(phrase.contains("Duration.seconds(seconds).formatted(.units(allowed: [.seconds], width: .narrow).locale(L10n.locale))"))
        XCTAssertTrue(phrase.contains("Text(\"Hides in \\(Self.seconds("))
        for (path, text) in try Self.scopedSources() {
            for line in text.components(separatedBy: "\n") where line.contains(".formatted(") && !line.contains(".units(") {
                XCTAssertTrue(line.contains("L10n.locale"), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // English is unchanged: these are the strings the code wrote before.
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(Duration.seconds(720).formatted(.units(allowed: [.minutes], width: .narrow).locale(en)), "12m")
        XCTAssertEqual(Duration.seconds(45).formatted(.units(allowed: [.seconds], width: .narrow).locale(en)), "45s")
        XCTAssertEqual(Duration.seconds(0).formatted(.units(allowed: [.seconds], width: .narrow).locale(en)), "0s")
        XCTAssertEqual(Duration.seconds(3600).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)), "1 hour")
        XCTAssertEqual(Duration.seconds(900).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)), "15 minutes")
    }

    /// The Perps chart's dates follow the app's language: the app sends its locale (and the legend's labels) to the page,
    /// which writes its time scale and crosshair dates in it. Prices keep the app's one style.
    func testTheChartDatesFollowTheAppLanguage() throws {
        let chart = Self.squeezed(try Self.source("DyorHQ/Perps/TradingViewChart.swift"))
        XCTAssertTrue(chart.contains("@Environment(\\.locale) private var locale"))
        XCTAssertTrue(chart.contains("language: ChartLanguage(locale)"))
        XCTAssertTrue(chart.contains("self.locale = locale.identifier(.bcp47)"))
        XCTAssertTrue(chart.contains("if pendingScheme != lastScheme || pendingLanguage != lastLanguage {"), "re-sent when the language changes")
        XCTAssertTrue(chart.contains("config[\"locale\"] = language.locale"))
        let page = try Self.source("DyorHQ/Resources/Web/chart.html")
        XCTAssertTrue(page.contains("if (p.locale) chart.applyOptions({ localization: { locale: p.locale, priceFormatter: (v) => formatPrice(v) } });"))
        XCTAssertTrue(page.contains("palette = Object.assign(palette, p.palette || {});"))
        XCTAssertTrue(page.contains("escapeHTML(legendLabels.o)"))
        XCTAssertFalse(page.contains("<span class=\"k\">O</span>"), "the legend's labels come from the app")
        XCTAssertTrue(page.contains("p.toLocaleString('en-US'"), "prices keep the app's one style")
    }

    /// A sign-in method's name inside a sentence is a key per method, written as the side menu shows it (lowercase in
    /// English), and Apple's and Google's names are their titles, never translated nor lowercased.
    func testASignInMethodHasItsOwnNameForASentence() throws {
        let code = try Self.source("DyorHQ/Wallet/Session.swift")
        let session = Self.squeezed(code)
        let start = try XCTUnwrap(code.range(of: "var nameInSentence: String {"))
        let chars = Array(code)
        let open = code.distance(from: code.startIndex, to: start.upperBound) - 1
        let body = Self.squeezed(String(chars[open...(try XCTUnwrap(TradeStringsTests.closing(chars, open)))]))
        XCTAssertTrue(body.contains("case .apple, .google, .watchOnly: return title"))
        for (method, key, english) in [("email", "email", "email"), ("emailPassword", "emailPassword", "email & password"),
                                       ("passkey", "privyPasskey", "passkey (Privy)"), ("meraPasskey", "passkey", "passkey"),
                                       ("imported", "imported", "imported wallet")] {
            XCTAssertTrue(body.contains(#"case .\#(method): return tr(LocalizedStringResource("signInMethod.\#(key)", defaultValue: "\#(english)", comment: "A sign-in method"#), method)
        }
        XCTAssertFalse(body.contains("lowercased("))
        XCTAssertTrue(session.contains(#"case .apple: return "Apple" // not localized: a company's name"#))
        XCTAssertTrue(session.contains(#"case .google: return "Google" // not localized: a company's name"#))
    }

    // MARK: What stays English

    /// What a server reparses, what is matched against what someone types, and the values a page or the store reads
    /// stay English, never translated.
    func testTheEnglishMatchersAreUntouched() throws {
        let session = try Self.source("DyorHQ/Wallet/Session.swift")
        XCTAssertTrue(session.contains("return \"DyorHQ Email Rebind\\n\\nEmail: \\(email)\\nAddress: \\(address.checksummed.lowercased())\\nIssued At: \\(issued)\""))
        XCTAssertTrue(session.contains("trimmed.lowercased().hasSuffix(\"@privaterelay.appleid.com\")"))
        XCTAssertTrue(session.contains("oAuth.login(with: provider, appUrlScheme: \"dyorhq\")"))
        let password = try Self.source("DyorHQ/Wallet/PasswordWallet.swift")
        XCTAssertTrue(password.contains("for weak in [\"password\", \"dyorhq\", \"qwerty\", \"letmein\", \"monad\", \"crypto\", \"wallet\"] where lower.contains(weak) {"))
        let export = try Self.source("DyorHQ/Wallet/WalletExportView.swift")
        XCTAssertTrue(export.contains("if result == \"success\" { dismiss() }"))
        XCTAssertTrue(export.contains("guard message.name == \"exportResult\" else { return }"))
        XCTAssertTrue(export.contains("json[\"status\"] as? String"))
        let log = try Self.source("DyorHQ/Wallet/ActivityLog.swift")
        for status in ["pendingStatus = \"pending\"", "confirmedStatus = \"confirmed\"", "revertedStatus = \"reverted\"", "notFoundStatus = \"notFound\""] {
            XCTAssertTrue(log.contains(status), status)
        }
        XCTAssertTrue(log.contains("case .perp: return \"perps\""))
        XCTAssertTrue(log.contains("case \"moments\": return .moments"))
        // Cancelling is told by type, never by an error's text.
        XCTAssertTrue(session.contains("if case .cancelled? = error as? PasskeyCeremony.Failure { return true }"))
        for (path, text) in try Self.scopedSources() {
            XCTAssertFalse(text.contains("tr(\"pending\")") || text.contains("tr(\"success\")"), path)
            XCTAssertFalse(text.contains("localizedDescription.contains("), "\(path): an error told apart by its (translated) text")
        }
    }

    /// The Perps order's notification names its side in the app's language; Activity rows and notifications are written
    /// in the language in use when they are recorded.
    func testRecordsAndNotificationsAreWrittenInTheAppLanguage() throws {
        let trade = try Self.source("DyorHQ/Perps/PerpTradeView.swift")
        XCTAssertFalse(trade.contains("side: input.side == .long ? \"Long\" : \"Short\""))
        XCTAssertTrue(Self.squeezed(trade).contains("Notifications.perpOrder(PerpOrderNotice(acknowledged: input.kind), side: side, market: \"\\(market.asset)-PERP\", perpId: market.id)"))
        // The live outcome's notice names the side the same way, from the order the tracker follows.
        let tracker = Self.squeezed(try Self.source("DyorHQ/Wallet/PerplOrderTracker.swift"))
        XCTAssertTrue(tracker.contains("Notifications.perpOrder(notice, side: sideName, market: \"\\(asset)-PERP\", perpId: marketId, owner: owner, deliver: deliverBanner)"))
        XCTAssertTrue(tracker.contains(#"let sideName = order.side == .long ? tr(LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]")) : tr(LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]"))"#))
        XCTAssertTrue(tracker.contains(#"let title = order.side == .long ? tr("Long \(perp)") : tr("Short \(perp)")"#), "the Activity row's title, as the sheets write it")
        let notifications = try Self.source("DyorHQ/Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("post(kind: .swap, title: tr(\"Swap complete\"), body: tr(\"Swapped \\(paid) → \\(got)\"), route: .trade)"))
        XCTAssertTrue(notifications.contains("title: tr(\"Bridge complete\")"))
        XCTAssertTrue(notifications.contains("title: tr(\"Price alert: \\(symbol)\")"))
        let run = try Self.source("DyorHQ/Wallet/TransactionRun.swift")
        XCTAssertTrue(run.contains("static var notSent: String { tr(\"Not sent. Nothing left your account.\") }"))
        XCTAssertTrue(run.contains("return tr(\"Up to \\(fee) + \\(unestimated) more steps\")"), "one plural key, not an English-only \"1 more step\"")
    }

    /// One key is one translation, so a word with two meanings is two keys, each with its own comment, and English reads
    /// the same word in both places. "Close" closes a screen or a sheet; the position's Close button and a chart line's
    /// resting close order are keys of their own. "Market" is the order type; the review row naming the market traded is
    /// a key of its own.
    func testAWordWithTwoMeaningsIsTwoKeys() throws {
        let trade = Self.squeezed(try Self.source("DyorHQ/Perps/PerpTradeView.swift"))
        XCTAssertTrue(trade.contains(#"Button(action: onClose) { Text(verbatim: tr(LocalizedStringResource("position.close", defaultValue: "Close", comment: "Closes the open position (a verb), a button on the position. [tight]"))) }"#))
        XCTAssertTrue(trade.contains(#"order.reduceOnly ? tr(LocalizedStringResource("chartLine.close", defaultValue: "Close", comment: "#))
        XCTAssertEqual(trade.components(separatedBy: ##"DetailRow(Text(verbatim: tr(LocalizedStringResource("orderReview.market", defaultValue: "Market", comment: "A review row: the Perps market the order is on, next to its name (BTC-PERP) [tight]"))), Text(verbatim: "##).count - 1, 3)
        XCTAssertFalse(trade.contains(#"DetailRow("Market""#), "the review row names the market with its own key")
        XCTAssertEqual(trade.components(separatedBy: #"Text("Close", comment: "Closes this screen or sheet (a verb)")"#).count - 1, 2)
        XCTAssertEqual(trade.components(separatedBy: #"Text("Market", comment: "Order type: a market order, which fills at once at the market price. [tight]")"#).count - 1, 2)
        XCTAssertFalse(trade.contains("Elsewhere it closes"), "each key's comment names its own meaning")
        XCTAssertFalse(trade.contains("Also names the market traded"))
    }

    /// A key with a count and what its English says for a count of one: the words its singular has (`one`) and the
    /// plural's words it doesn't (`notOne`). A key English says alike for one and many (`sameForOne`) needs its plural
    /// forms only for the other languages.
    struct PluralKey {
        let key: String
        let one: [String]
        let notOne: [String]
        let sameForOne: Bool

        init(_ key: String, one: [String], notOne: [String]) {
            self.key = key
            self.one = one
            self.notOne = notOne
            sameForOne = false
        }

        init(sameForOne key: String) {
            self.key = key
            one = []
            notOne = []
            sameForOne = true
        }
    }

    /// The Perps and Wallet keys with a count (an `Int`, so `%lld`), as the app's catalog spells them, and what each says
    /// for a count of one. Their singular comes from the catalog's plural forms, English included: without them a count
    /// of 1 reads "1 more steps". English says a few alike for one and many: TP/SL is an abbreviation, "percent" has no
    /// plural, and "times" is a multiplier ("1x" reads "1 times leverage").
    static let pluralKeys: [PluralKey] = [
        .init("Up to %@ + %lld more steps", one: ["more step"], notOne: ["steps"]),
        .init("Use at least %lld characters.", one: ["character."], notOne: ["characters"]),
        .init("%lld take-profit/stop-loss orders from an earlier %@ long are still armed on Perpl and would act on this new position. Cancel them from Orders first.",
              one: ["order from", "is still armed", "Cancel it"], notOne: ["orders from", "are still", "them"]),
        .init("%lld take-profit/stop-loss orders from an earlier %@ short are still armed on Perpl and would act on this new position. Cancel them from Orders first.",
              one: ["order from", "is still armed", "Cancel it"], notOne: ["orders from", "are still", "them"]),
        .init("%@ · %lld orders from the closed long", one: ["order from"], notOne: ["orders"]),
        .init("%@ · %lld orders from the closed short", one: ["order from"], notOne: ["orders"]),
        .init("Your recovery phrase hides in %lld seconds. Choose Keep Showing for more time.", one: ["second."], notOne: ["seconds"]),
        .init("%lld %@ candles. Last %@, up %@ over the period. High %@, low %@.", one: ["candle."], notOne: ["candles"]),
        .init("%lld %@ candles. Last %@, down %@ over the period. High %@, low %@.", one: ["candle."], notOne: ["candles"]),
        .init("%lld TP/SL on %@ have no position to close. Left armed, they would fire on your next position here.",
              one: ["has no position", "it would fire"], notOne: ["have no", "they"]),
        .init("This position has %lld TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next long here).",
              one: ["cancel it from", "(it would"], notOne: ["them", "they"]),
        .init("This position has %lld TP/SL on Perpl. Once it is fully closed, cancel them from Orders (they would otherwise stay armed for your next short here).",
              one: ["cancel it from", "(it would"], notOne: ["them", "they"]),
        .init("This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next long here. Check Orders afterwards.",
              one: ["cancels it while", "so it can't fire"], notOne: ["them", "they"]),
        .init("This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels them while Perpl trading is connected, so they can't fire on your next short here. Check Orders afterwards.",
              one: ["cancels it while", "so it can't fire"], notOne: ["them", "they"]),
        .init("The limit price can have at most %lld decimal places on %@.", one: ["decimal place on"], notOne: ["places"]),
        .init("%lld take profits are live. A new one replaces all of them.", one: ["take profit is live"], notOne: ["profits", "them"]),
        .init("%lld stop losses are live. A new one replaces all of them.", one: ["stop loss is live"], notOne: ["losses", "them"]),
        .init("Cancel %lld Triggers", one: ["Trigger"], notOne: ["Triggers"]),
        .init(sameForOne: "Cancelled %lld TP/SL"),
        .init(sameForOne: "Cancelled %lld TP/SL."),
        .init(sameForOne: "Cancelling %lld TP/SL on %@…"),
        .init(sameForOne: "%lld percent"),
        .init(sameForOne: "%lld times"),
        .init(sameForOne: "Maximum leverage, %lld times"),
        .init(sameForOne: "%lld times leverage"),
    ]

    /// Every listed plural key is still written in the Perps or Wallet code, so the list stays the code's.
    func testThePluralKeysAreTheCodes() throws {
        let code = try Self.scopedSources().map(\.text).joined(separator: "\n")
        let value = #"\\\(.+?\)"# // one interpolation, `\(…)`, nested parentheses included
        for key in Self.pluralKeys.map(\.key) {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: "%lld", with: value).replacingOccurrences(of: "%@", with: value)
            XCTAssertNotNil(code.range(of: "\"" + pattern + "\"", options: .regularExpression), "not in the Perps or Wallet code: \(key)")
        }
    }

    /// The app's catalog gives every plural key English forms that read right for a count of one ("Up to %@ + %lld more
    /// step"), not the plural as written ("1 more steps"): `checkEnglishPlurals`.
    func testThePluralKeysHaveEnglishPluralForms() throws {
        let url = try Self.ios().appendingPathComponent("DyorHQ/Resources/Localizable.xcstrings")
        try Self.checkEnglishPlurals(Self.pluralKeys, catalog: Data(contentsOf: url))
    }

    /// Checks the English plural forms the app's catalog gives `keys` (`englishPluralProblem`). The catalog step adds the
    /// keys and their forms once every L2 lane has merged: until then a key the catalog doesn't have is pending, and the
    /// test is skipped, naming the pending keys. A release (`DYORHQ_RELEASE_GATE=1`) refuses a pending key instead: the
    /// app shows its English as written, the plural, for a count of 1.
    static func checkEnglishPlurals(_ keys: [PluralKey], catalog data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any], "a catalog has its strings", file: file, line: line)
        var pending: [String] = []
        var failed = false
        for key in keys {
            guard let entry = strings[key.key] else { pending.append(key.key); continue }
            if let problem = englishPluralProblem(entry, key) {
                XCTFail("\(key.key): \(problem)", file: file, line: line)
                failed = true
            }
        }
        guard !pending.isEmpty else { return }
        if ProcessInfo.processInfo.environment["DYORHQ_RELEASE_GATE"] == "1" {
            for key in pending {
                XCTFail("REFUSING A RELEASE: not in the app's catalog, so a count of 1 reads as the plural (run scripts/dev/strings-sync.sh, then give it its English one and other): \(key)",
                        file: file, line: line)
            }
        } else if !failed {
            throw XCTSkip("catalog step pending: \(pending.count) of \(keys.count) plural keys are not in the app's catalog yet, each to get its English one and other: \(pending)",
                          file: file, line: line)
        }
    }

    /// What a plural key's catalog entry lacks in English, or nil. Its English plural (of the whole string, or of a
    /// substitution) has a "one" and an "other" form, and the "one" differs from the "other" and says the singular: each
    /// of the key's `one` words and none of its `notOne` words. A key English says alike for one and many needs no English
    /// plural; if it has one, its "one" is its "other".
    static func englishPluralProblem(_ entry: Any, _ key: PluralKey) -> String? {
        let english = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any] ?? [:]
        let one = englishPluralForm("one", in: english), other = englishPluralForm("other", in: english)
        if key.sameForOne, one == nil, other == nil { return nil }
        guard let one, let other, !one.isEmpty, !other.isEmpty else {
            return one == nil && other == nil ? "no English plural forms" : "an English plural without its one or other form"
        }
        if key.sameForOne { return one == other ? nil : "English says this alike for one and many, so its one form is its other: \(one)" }
        if one == other { return "the English one form is the other form: \(one)" }
        if let missing = key.one.first(where: { !one.contains($0) }) { return "the English one form doesn't say the singular (no \"\(missing)\"): \(one)" }
        if let plural = key.notOne.first(where: { one.contains($0) }) { return "the English one form says the plural (\"\(plural)\"): \(one)" }
        return nil
    }

    /// The English a catalog localization gives for the plural `form` ("one", "other"): the whole string's plural
    /// variation, or the string with each plural substitution's form in place of its `%#@name@`, the form's `%arg` as the
    /// substitution's specifier. Nil when English has no plural, or not that form.
    static func englishPluralForm(_ form: String, in english: [String: Any]) -> String? {
        func value(_ any: Any?) -> String? { ((any as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String }
        if let forms = (english["variations"] as? [String: Any])?["plural"] as? [String: Any] { return value(forms[form]) }
        guard var sentence = value(english), let substitutions = english["substitutions"] as? [String: Any] else { return nil }
        var varied = false
        for (name, substitution) in substitutions {
            guard let substitution = substitution as? [String: Any],
                  let forms = (substitution["variations"] as? [String: Any])?["plural"] as? [String: Any] else { continue }
            guard let text = value(forms[form]),
                  let placeholder = try? NSRegularExpression(pattern: #"%(\d+\$)?#@"# + NSRegularExpression.escapedPattern(for: name) + "@") else { return nil }
            let filled = text.replacingOccurrences(of: "%arg", with: "%" + (substitution["formatSpecifier"] as? String ?? "lld"))
            sentence = placeholder.stringByReplacingMatches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence),
                                                            withTemplate: NSRegularExpression.escapedTemplate(for: filled))
            varied = true
        }
        return varied ? sentence : nil
    }

    /// The plural check reads both shapes Xcode writes (the whole string varied by plural, or a substitution put back in
    /// its string), and refuses an English "one" that is missing, is the "other" ("1 more steps"), or says the plural; a
    /// key English says alike for one and many may have no English plural.
    func testThePluralCheckReadsTheSingular() {
        func plural(_ forms: [String: String]) -> [String: Any] { ["plural": forms.mapValues { ["stringUnit": ["state": "translated", "value": $0]] }] }
        func entry(_ english: [String: Any]) -> [String: Any] { ["localizations": ["en": english]] }
        let steps = PluralKey("Up to %@ + %lld more steps", one: ["more step"], notOne: ["steps"])
        let whole = entry(["variations": plural(["one": "Up to %@ + %lld more step", "other": "Up to %@ + %lld more steps"])])
        let substitution: [String: Any] = ["stringUnit": ["state": "translated", "value": "Up to %1$@ + %2$#@count@"],
                                           "substitutions": ["count": ["argNum": 2, "formatSpecifier": "lld",
                                                                       "variations": plural(["one": "%arg more step", "other": "%arg more steps"])] as [String: Any]]]
        XCTAssertNil(Self.englishPluralProblem(whole, steps))
        XCTAssertNil(Self.englishPluralProblem(entry(substitution), steps))
        XCTAssertEqual(Self.englishPluralForm("one", in: substitution), "Up to %1$@ + %lld more step")
        XCTAssertEqual(Self.englishPluralForm("other", in: substitution), "Up to %1$@ + %lld more steps")

        XCTAssertEqual(Self.englishPluralProblem([String: Any](), steps), "no English plural forms") // as a sync adds it
        XCTAssertEqual(Self.englishPluralProblem(entry(["stringUnit": ["state": "new", "value": "Up to %@ + %lld more steps"]]), steps), "no English plural forms")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["other": "Up to %@ + %lld more steps"])]), steps),
                       "an English plural without its one or other form")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "Up to %@ + %lld more steps", "other": "Up to %@ + %lld more steps"])]), steps),
                       "the English one form is the other form: Up to %@ + %lld more steps")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "Up to %@ + %lld step", "other": "Up to %@ + %lld more steps"])]), steps),
                       "the English one form doesn't say the singular (no \"more step\"): Up to %@ + %lld step")
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "Up to %@ + one more steps", "other": "Up to %@ + %lld more steps"])]), steps),
                       "the English one form says the plural (\"steps\"): Up to %@ + one more steps")

        let percent = PluralKey(sameForOne: "%lld percent")
        XCTAssertNil(Self.englishPluralProblem(entry(["stringUnit": ["state": "new", "value": "%lld percent"]]), percent))
        XCTAssertNil(Self.englishPluralProblem(entry(["variations": plural(["one": "%lld percent", "other": "%lld percent"])]), percent))
        XCTAssertEqual(Self.englishPluralProblem(entry(["variations": plural(["one": "%lld percents", "other": "%lld percent"])]), percent),
                       "English says this alike for one and many, so its one form is its other: %lld percents")
    }

    /// Each key takes the singular English says for a count of one, and refuses the plural as written ("1 more steps").
    func testEachPluralKeyTakesItsEnglishSingular() {
        let singular = [
            "Up to %@ + %lld more step",
            "Use at least %lld character.",
            "%lld take-profit/stop-loss order from an earlier %@ long is still armed on Perpl and would act on this new position. Cancel it from Orders first.",
            "%lld take-profit/stop-loss order from an earlier %@ short is still armed on Perpl and would act on this new position. Cancel it from Orders first.",
            "%@ · %lld order from the closed long",
            "%@ · %lld order from the closed short",
            "Your recovery phrase hides in %lld second. Choose Keep Showing for more time.",
            "%lld %@ candle. Last %@, up %@ over the period. High %@, low %@.",
            "%lld %@ candle. Last %@, down %@ over the period. High %@, low %@.",
            "%lld TP/SL on %@ has no position to close. Left armed, it would fire on your next position here.",
            "This position has %lld TP/SL on Perpl. Once it is fully closed, cancel it from Orders (it would otherwise stay armed for your next long here).",
            "This position has %lld TP/SL on Perpl. Once it is fully closed, cancel it from Orders (it would otherwise stay armed for your next short here).",
            "This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels it while Perpl trading is connected, so it can't fire on your next long here. Check Orders afterwards.",
            "This position has %lld TP/SL on Perpl. Once it is fully closed, the app cancels it while Perpl trading is connected, so it can't fire on your next short here. Check Orders afterwards.",
            "The limit price can have at most %lld decimal place on %@.",
            "%lld take profit is live. A new one replaces it.",
            "%lld stop loss is live. A new one replaces it.",
            "Cancel %lld Trigger",
        ]
        let counted = Self.pluralKeys.filter { !$0.sameForOne }
        XCTAssertEqual(counted.count, singular.count)
        for (key, one) in zip(counted, singular) {
            XCTAssertNil(Self.englishPluralProblem(Self.englishPlural(one: one, other: key.key), key), key.key)
            XCTAssertNotNil(Self.englishPluralProblem(Self.englishPlural(one: key.key, other: key.key), key), "the plural for one: \(key.key)")
        }
        for key in Self.pluralKeys where key.sameForOne {
            XCTAssertNil(Self.englishPluralProblem(Self.englishPlural(one: key.key, other: key.key), key), key.key)
        }
    }

    /// A catalog entry whose English varies by plural, as the catalog step writes it.
    static func englishPlural(one: String, other: String) -> [String: Any] {
        let forms = ["one": one, "other": other].mapValues { ["stringUnit": ["state": "translated", "value": $0]] }
        return ["localizations": ["en": ["variations": ["plural": forms]]]]
    }
}
