import Foundation
import XCTest
@testable import DyorKit

/// The text of the app's remaining folders (L2: Onboarding, Profile, Notifications, Support, News, App, Menu, Design,
/// Social, Backend, Config, Trade), read from the app's sources. Text written in the code reaches the screen in the app's
/// language: a `String` the code builds (a label returned by a model, an error, a notice, an Activity row, a step's
/// label) goes through `tr()`; a word is never chosen inside another string's interpolation; text with nothing to
/// translate ("·", "@", a count) is shown verbatim, never as a key; a count with a noun is one key with the count as its
/// argument, whose English plural forms a release needs in the catalog; a label is never derived from a raw value; an
/// ambiguous or tight label carries a translator comment; dates and durations follow the app's language; errors are told
/// apart by type, never by text. What must stay English is left as it is: the server's own words the app matches, the
/// word typed to delete an account, and the subjects and device details of a mail to support.
final class AppStringsTests: XCTestCase {
    private static let folders = ["App", "Backend", "Config", "Design", "Menu", "News", "Notifications", "Onboarding", "Profile",
                                  "Social", "Support", "Trade"]

    /// The Swift files of the folders, by their path under ios/DyorHQ.
    private static func sources() throws -> [(path: String, text: String)] {
        let all = try FormattedTextIsolationTests.appSources().filter { source in folders.contains { source.path.hasPrefix($0 + "/") } }
        XCTAssertEqual(all.count, 30, "the folders' files")
        return all
    }

    private static func source(_ path: String) throws -> String { try DocsLinksTests.appSource(path) }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The lines of the folders with their literals; a comment line is left out, and so is a line marked "not localized",
    /// or right under a comment line that marks it (`PerpsWalletStringsTests.scannedLines(of:)`: a marker at the end of a
    /// line of code covers that line only).
    private static func scannedLines() throws -> [(at: String, line: String, literals: [PerpsWalletStringsTests.Literal])] {
        PerpsWalletStringsTests.scannedLines(of: try sources())
    }

    /// The body of the first `{ … }` after `declaration` (itself after `after`, when given), its comments removed.
    private static func body(of declaration: String, after: String? = nil, in file: String) throws -> String {
        let code = String(TradeStringsTests.uncommented(Array(try source(file))))
        let from = try after.map { try XCTUnwrap(code.range(of: $0), "\(file): \($0)").upperBound } ?? code.startIndex
        let start = try XCTUnwrap(code.range(of: declaration, range: from..<code.endIndex), "\(file): \(declaration)")
        let open = try XCTUnwrap(code[start.upperBound...].firstIndex(of: "{"))
        let chars = Array(code)
        let openIndex = code.distance(from: code.startIndex, to: open)
        let close = try XCTUnwrap(TradeStringsTests.closing(chars, openIndex))
        return String(chars[openIndex...close])
    }

    // MARK: Text built as a String

    /// A word chosen inside another string's interpolation (`"\(n == 1 ? "it" : "them")"`, `?? "this token"`) is never
    /// looked up: each choice is a sentence of its own, or a `tr()`.
    func testNoWordIsChosenInsideAnInterpolation() throws {
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth > 0
                && (PerpsWalletStringsTests.isWords(literal.text) || literal.text.range(of: "^[a-z]{2,}$", options: .regularExpression) != nil) {
                found.append("\(at): \"\(literal.text)\"")
            }
        }
        XCTAssertEqual(found, [], "a word inside an interpolation is shown in English in every language")
    }

    /// Text built as a `String` (a returned label, an assigned error or notice, a fallback after `??`, a thrown failure's
    /// reason, an Activity row, a feed row, a step's label, or a branch of a ternary that is one of these) goes through
    /// `tr()`: a bare literal there is shown in English in every language.
    func testStringTextGoesThroughTr() throws {
        var found: [String] = []
        var checked = 0
        for (at, line, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth == 0 && PerpsWalletStringsTests.isWords(literal.text) {
                checked += 1
                if Self.isStringText(literal, on: line) { found.append("\(at): \"\(literal.text)\"") }
            }
        }
        XCTAssertEqual(found, [], "String text written in the code goes through tr()")
        XCTAssertGreaterThan(checked, 400, "the scan reads the folders' text")
    }

    /// The scan's reader: a literal is String text right after a sink, in a record's field on a record line, or as a
    /// branch of a ternary that is returned, assigned or a record's field; a key (`Text(…)`'s, a `tr()`'s) is not, nor a
    /// ternary inside a call.
    func testTheScanSeesStringTextInATernary() {
        func flagged(_ line: String) -> [String] {
            PerpsWalletStringsTests.literals(in: line)
                .filter { $0.depth == 0 && PerpsWalletStringsTests.isWords($0.text) && Self.isStringText($0, on: line) }.map(\.text)
        }
        XCTAssertEqual(flagged(#"incomplete = unread ? "Some activity couldn't be read just now." : nil"#), ["Some activity couldn't be read just now."])
        XCTAssertEqual(flagged(#"return isLong ? "Opens a long." : "Opens a short.""#), ["Opens a long.", "Opens a short."])
        XCTAssertEqual(flagged(#"notice = failed ? nil : "Saved just now.""#), ["Saved just now."])
        XCTAssertEqual(flagged(#"guard ok else { return (a ?? b).isEmpty ? "Nothing to show." : "Not read." }"#), ["Nothing to show.", "Not read."])
        XCTAssertEqual(flagged(#"Notifications.perpOrder(.filled, side: position.side == .long ? "Long" : "Short","#), ["Long", "Short"])
        XCTAssertEqual(flagged(#"error = message ?? "Something went wrong.""#), ["Something went wrong."])

        XCTAssertEqual(flagged(#"incomplete = unread ? tr("Some activity couldn't be read just now.") : nil"#), [])
        XCTAssertEqual(flagged(#"let label = Text(isLong ? "Opens a long." : "Opens a short.")"#), [], "keys")
        XCTAssertEqual(flagged(#"Label(isPhrase ? "Not a valid phrase yet." : "Not a valid key.", systemImage: "x")"#), [], "keys")
        XCTAssertEqual(flagged(#"shown = name == "Some words" ? first : second"#), [], "a comparison, not a value")
        XCTAssertEqual(flagged(#"row = Row(title: isLong ? "Opens a long." : "Opens a short.")"#), [], "not a record line")
    }

    /// Where String text is written in code: the end of the code before a literal (`return `, an assignment, `?? `, a
    /// failure's or notice's argument), and on a record line a record's field.
    private static let sink = try! NSRegularExpression(pattern: #"(return |(?<![=!<>])= |\?\? |\.unavailable\(|\.backendSignInNeeded\(|\.emailSignInNotDeleted\(|\.bindFailed\(|\.append\(|error: )$"#)
    private static let record = try! NSRegularExpression(pattern: #"(title: |subtitle: |body: |label: |side: )$"#)
    /// Where a ternary whose branches are String text starts: a `return`, an assignment, or a record's field.
    private static let ternaryHead = try! NSRegularExpression(pattern: #"(\breturn |(?<![=!<>])= )"#)
    private static let recordTernaryHead = try! NSRegularExpression(pattern: #"\b(title|subtitle|body|label|side): "#)

    /// Whether `literal` on `line` is String text the code builds, which must go through `tr()`.
    static func isStringText(_ literal: PerpsWalletStringsTests.Literal, on line: String) -> Bool {
        let recordLine = ["ActivityRecord(", "FeedItem(", "post(kind:", ".call(", "Notifications.", "AppNotification("].contains { line.contains($0) }
        let range = NSRange(literal.before.startIndex..., in: literal.before)
        if sink.firstMatch(in: literal.before, range: range) != nil { return true }
        if recordLine, record.firstMatch(in: literal.before, range: range) != nil { return true }
        return isTernaryBranch(literal.before, head: ternaryHead) || (recordLine && isTernaryBranch(literal.before, head: recordTernaryHead))
    }

    /// Whether the code before a literal makes it a branch of a ternary that `head` starts, at that expression's top level:
    /// `incomplete = unread ? "…" : nil`, `return isLong ? "…" : "…"`; not `x = Text(isLong ? "…" : "…")`, whose
    /// literals are keys.
    static func isTernaryBranch(_ before: String, head: NSRegularExpression) -> Bool {
        let code = withoutLiterals(before)
        guard code.hasSuffix("? ") || code.hasSuffix(": ") else { return false }
        for match in head.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let start = Range(match.range, in: code) else { continue }
            let rest = Array(code[start.upperBound...])
            var depth = 0
            var ternary = false
            for (index, c) in rest.enumerated() {
                if "([{".contains(c) { depth += 1 } else if ")]}".contains(c) { depth -= 1 }
                if depth < 0 { break }
                if c == "?", depth == 0, index > 0, rest[index - 1] == " ", index + 1 < rest.count, rest[index + 1] == " " { ternary = true }
            }
            if depth == 0, ternary { return true }
        }
        return false
    }

    /// `code` with every string literal emptied (`"…"` becomes `""`), interpolations included, so only code is read.
    static func withoutLiterals(_ code: String) -> String {
        let chars = Array(code)
        var out = ""
        var index = 0
        func skipLiteral() { // from an opening quote to past its closing one
            index += 1
            while index < chars.count {
                if chars[index] == "\\", index + 1 < chars.count {
                    if chars[index + 1] == "(" { index += 2; skipInterpolation(); continue }
                    index += 2
                    continue
                }
                if chars[index] == "\"" { index += 1; return }
                index += 1
            }
        }
        func skipInterpolation() { // to past the parenthesis that closes `\(`
            var depth = 0
            while index < chars.count {
                let c = chars[index]
                if c == "\"" { skipLiteral(); continue }
                if c == "(" { depth += 1 } else if c == ")" {
                    if depth == 0 { index += 1; return }
                    depth -= 1
                }
                index += 1
            }
        }
        while index < chars.count {
            if chars[index] == "\"" {
                skipLiteral()
                out += "\"\""
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    /// The `String`s these folders build are written inside `tr()`, one sentence per case: the notices a deletion leaves
    /// (`DeletionNoticeView`), the Send sheet's problems, the log-in messages, the feed's rows.
    func testBuiltTextIsWrittenInTr() throws {
        let deletion = Self.squeezed(try Self.source("Profile/AccountDeletion.swift"))
        for assignment in deletion.components(separatedBy: "notice = ").dropFirst() {
            XCTAssertTrue(assignment.hasPrefix("tr(") || assignment.hasPrefix("Failure.privyNotConfigured.localizedDescription")
                          || assignment.hasPrefix("try await deleteEmailSignIn("), "a deletion notice: \(assignment.prefix(60))")
        }
        XCTAssertEqual(try Self.body(of: "var errorDescription: String?", in: "Profile/AccountDeletion.swift").components(separatedBy: "return tr(").count - 1, 3)
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        let acknowledgement = try Self.body(of: "private func replaceAcknowledgement(", in: "Onboarding/OnboardingView.swift")
        XCTAssertEqual(acknowledgement.components(separatedBy: "return tr(\"I understand").count - 1, 4, "one whole sentence per case")
        XCTAssertFalse(onboarding.contains("let beyond"), "no sentence glued from pieces")
        XCTAssertFalse(onboarding.contains("let retry ="))
        XCTAssertTrue(onboarding.contains(#"return tr("\(message) If you made this password with it shown"#))
        // A wallet that holds nothing is a sentence of its own, never a fragment dropped into "%@ holds %@."
        XCTAssertTrue(onboarding.contains(#"Label("\(conflict.current.short) holds no MON or tokens.", systemImage: "circle.dashed")"#))
        XCTAssertFalse(onboarding.contains(#"tr("no MON or tokens")"#))
        // An HTTP status is no count: it goes in as text, never as a plural argument.
        XCTAssertTrue(try Self.source("Profile/AccountDeletion.swift").contains(#"tr("error \(String(code))")"#))
        let send = try Self.body(of: "private var problem: String?", in: "Profile/ProfileView.swift")
        XCTAssertEqual(send.components(separatedBy: "return tr(").count - 1, 3)
        let feed = try Self.source("Profile/RecentActivityView.swift")
        for title in [#"title: tr("Swapped")"#, #"title: tr("Launched $\(symbol)")"#, #"title: isBuy ? tr("Bought \(symbol)") : tr("Sold \(symbol)")"#,
                      #"title: tr("\(symbol) graduated")"#] {
            XCTAssertTrue(feed.contains(title), title)
        }
        let profile = try Self.source("Profile/ProfileView.swift")
        XCTAssertTrue(profile.contains(#"return [.call(request, label: tr("Send \(review.token.symbol)"))]"#), "the step's label")
        XCTAssertTrue(profile.contains(#"title: tr("Sent \(review.token.symbol)")"#), "the Activity row")
        // A token sent to the wallet unasked: a sentence of its own, a DyorHQ coin's label as its %@, with what it means.
        let received = Self.squeezed(try Self.body(of: "var receivedNote: String", in: "Profile/ProfileView.swift"))
        XCTAssertTrue(received.contains(#"return tr(LocalizedStringResource("\(title): sent to you, not chosen here", comment: "Send review: a token someone sent to this wallet, not one chosen in the app. %@ is its DyorHQ label, DyorHQ Launch or DyorHQ Moment"))"#))
        XCTAssertTrue(received.contains(#"return tr(LocalizedStringResource("Unverified: sent to you, not chosen here", comment: "#))
    }

    /// Text with nothing to translate ("·", "@", "—", a count, "0x…") is shown as it is, never looked up as a key.
    func testNoPlaceholderOnlyKey() throws {
        let key = try NSRegularExpression(pattern: #"(Text|Paragraph|Label|Button|TextField|SecureField|Toggle|Section|LabeledContent|Link|ProgressView|\.accessibilityLabel|\.accessibilityValue|\.navigationTitle)\($"#)
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
        // A key placed inside another's interpolation would be a key with nothing to translate ("%@. %@").
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains(#"Text("\(Text("#), "\(path): a key made only of other text")
        }
        let help = try Self.source("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains(#".accessibilityLabel(title + Text(verbatim: ". ") + detail)"#))
        XCTAssertTrue(help.contains(#"HelpRow(symbol: "at", title: Text(verbatim: "X"), detail: Text(verbatim: SupportLinks.xHandle))"#), "a name")
        XCTAssertTrue(help.contains(#"title: Text(verbatim: "dyorhq.fun")"#), "an address")
        XCTAssertTrue(help.contains(#"detail: Text(verbatim: "dyorhq.fun/terms")"#))
        XCTAssertTrue(help.contains(#"detail: Text(verbatim: "dyorhq.fun/privacy")"#))
        XCTAssertTrue(try Self.source("Menu/SideMenuView.swift").contains("Text(verbatim: SupportLinks.name)"), "the app's name")
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains(#".accessibilityLabel(Text(verbatim: "\(SupportLinks.name). \(SupportLinks.tagline)."))"#))
    }

    // MARK: Labels

    /// A label that used to be written in English per case, or derived from a raw value, is a `tr()` per case (the app's
    /// name, DyorHQ, excepted), and a picker shows a case's title, never its raw value.
    func testLabelsAreLocalizedPerCase() throws {
        let labels: [(file: String, after: String?, declaration: String, cases: Int)] = [
            ("Design/Theme.swift", "enum AppearanceMode", "var label: String", 3),
            ("App/Router.swift", "enum TradeMode", "var label: String", 2),
            ("App/Router.swift", "enum VolumePeriod", "var label: String", 4),
            ("App/Router.swift", "enum VolumePeriod", "var shortLabel: String", 4),
            ("App/Router.swift", "enum MenuItem", "var title: String", 8),
            ("App/Router.swift", "enum MenuItem", "var subtitle: String", 8),
            ("Notifications/NotificationHub.swift", "enum Kind", "var title: String", 5),
            ("Onboarding/OnboardingView.swift", "struct StrengthMeter", "private var label: String", 4),
        ]
        for (file, after, declaration, cases) in labels {
            let body = try Self.body(of: declaration, after: after, in: file)
            XCTAssertFalse(body.contains("capitalized"), "\(file): \(declaration)")
            XCTAssertEqual(body.components(separatedBy: "tr(").count - 1, cases, "\(file): \(declaration): one tr() per label")
            for line in body.components(separatedBy: "\n") where !line.contains("tr(") {
                let bare = PerpsWalletStringsTests.literals(in: line).filter { PerpsWalletStringsTests.isWords($0.text) }
                XCTAssertEqual(bare.map(\.text), [], "\(file): \(declaration): words outside tr()")
            }
        }
        XCTAssertTrue(try Self.body(of: "var title: String", after: "enum Kind", in: "Notifications/NotificationHub.swift")
            .contains(#"case .system: return "DyorHQ""#), "the app's name is never translated")
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains(".capitalized"), "\(path): a label derived from a raw value")
            XCTAssertNil(text.range(of: #"Text\(\$0\.rawValue\)"#, options: .regularExpression), "\(path): a raw value shown as text")
        }
        // A segmented switch shows each case's title, a key with its [tight] comment, never the case's raw value.
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains("ForEach(Mode.allCases) { $0.title.tag($0) }"))
        XCTAssertTrue(onboarding.contains("case signUp, logIn\n"), "raw values are identifiers, never shown")
        let importer = try Self.source("Onboarding/ImportWalletView.swift")
        XCTAssertTrue(importer.contains("ForEach(Kind.allCases) { $0.title.tag($0) }"))
        XCTAssertTrue(importer.contains("case phrase, key\n"))
        for (file, declaration, cases) in [("Onboarding/OnboardingView.swift", "var title: Text", 2), ("Onboarding/ImportWalletView.swift", "var title: Text", 2)] {
            let titles = try Self.body(of: declaration, in: file)
            XCTAssertEqual(titles.components(separatedBy: "[tight]\")").count - 1, cases, "\(file): each side is tight")
        }
        // English is as before.
        XCTAssertEqual(AppLanguage.en.endonym, "English", "the language names stay in their own language")
    }

    /// The side menu says how the wallet is signed in with the method's own words for a sentence
    /// (`Session.Method.nameInSentence`), never its title lowercased in code, which wrote "apple", "google" and "privy" in
    /// every language. English reads "Signed in with Apple" and, as before, "Signed in with email & password".
    func testTheSideMenuNamesTheSignInMethodAsWritten() throws {
        let menu = try Self.source("Menu/SideMenuView.swift")
        XCTAssertTrue(menu.contains(#"if displayName == account.address.short { return tr("Signed in with \(account.method.nameInSentence)") }"#))
        XCTAssertFalse(menu.contains("lowercased("), "no name is lowercased in code")
    }

    // MARK: Plurals

    /// The keys with a count (an `Int`, so `%lld`) in these folders, as the app's catalog spells them, and what each says
    /// for a count of one. Their singular comes from the catalog's plural forms, English included: without them a count of
    /// 1 reads "1 words", "1 transactions" or "1 take-profit/stop-loss orders … them".
    static let pluralKeys: [PerpsWalletStringsTests.PluralKey] = [
        .init("%lld words. Words are separated by spaces.", one: ["word."], notOne: ["words."]),
        .init("It has sent %lld transactions, so it may also hold positions, collateral or coins not shown here.",
              one: ["transaction,"], notOne: ["transactions"]),
        .init("You have %lld take-profit/stop-loss orders live on Perpl. Removing the key doesn't cancel them: they stay armed, and this device can't show or cancel them until you connect again.",
              one: ["order live", "cancel it"], notOne: ["orders", "them", "they"]),
    ]

    /// A count with a noun is one key with the count as its argument, which the catalog gives its plural forms (and the
    /// pronouns that follow it, "it" or "them"); English is never chosen by hand (`count == 1 ? "" : "s"`). Every listed key
    /// is still written in the code, so the list stays the code's.
    func testPluralsAreKeysWithTheirCount() throws {
        for (path, text) in try Self.sources() {
            XCTAssertNil(text.range(of: #"== 1 \? ""#, options: .regularExpression), "\(path): a plural chosen by hand")
        }
        let code = try Self.sources().map(\.text).joined(separator: "\n")
        let value = #"\\\(.+?\)"# // one interpolation, `\(…)`, nested parentheses included
        for key in Self.pluralKeys.map(\.key) {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: "%lld", with: value).replacingOccurrences(of: "%@", with: value)
            XCTAssertNotNil(code.range(of: "\"" + pattern + "\"", options: .regularExpression), "not in the code: \(key)")
        }
        // The count is an Int: the wallet's transaction count, a UInt64, would make the key "%llu".
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains(#"It has sent \(Int(clamping: holdings.transactions)) transactions"#))
    }

    /// The app's catalog gives each plural key English forms whose "one" differs from the "other" and says the singular
    /// ("%lld word.", "%lld transaction,", "order … it"), as the catalog step writes them with every language's
    /// (`PerpsWalletStringsTests.checkEnglishPlurals`). Until then the test is skipped, naming the keys still pending; a
    /// release (`DYORHQ_RELEASE_GATE=1`) refuses a key the catalog doesn't have, since it reads "1 words".
    func testThePluralKeysHaveEnglishPluralForms() throws {
        try PerpsWalletStringsTests.checkEnglishPlurals(Self.pluralKeys, catalog: Data(try Self.source("Resources/Localizable.xcstrings").utf8))
    }

    /// Each key takes the singular English says for a count of one, and refuses the plural as written ("1 words").
    func testEachPluralKeyTakesItsEnglishSingular() {
        let singular = [
            "%lld word. Words are separated by spaces.",
            "It has sent %lld transaction, so it may also hold positions, collateral or coins not shown here.",
            "You have %lld take-profit/stop-loss order live on Perpl. Removing the key doesn't cancel it: it stays armed, and this device can't show or cancel it until you connect again.",
        ]
        XCTAssertEqual(Self.pluralKeys.count, singular.count)
        for (key, one) in zip(Self.pluralKeys, singular) {
            XCTAssertNil(PerpsWalletStringsTests.englishPluralProblem(PerpsWalletStringsTests.englishPlural(one: one, other: key.key), key), key.key)
            XCTAssertNotNil(PerpsWalletStringsTests.englishPluralProblem(PerpsWalletStringsTests.englishPlural(one: key.key, other: key.key), key),
                            "the plural for one: \(key.key)")
        }
    }

    // MARK: Translator comments

    /// A short key whose meaning depends on where it stands carries a translator comment there: "All" sources, all
    /// notifications or all time (a key each), "Close" a screen or a sheet, "Watch" an address, "To" an address, a status
    /// ("Locked", "Enrolled", "Ready", "Error", "Now"), "System" and the import's "Type"; a label in a tight place (the
    /// menu, the switches, the chips, the statuses) says "[tight]". English is unchanged: a comment is only for the
    /// translator.
    func testAmbiguousKeysCarryTheirComments() throws {
        let bare = [#"chip("All""#, #"Text("All")"#, #".accessibilityLabel("Close")"#, #"Button("Watch")"#, #"Text("To")"#,
                    #"LabeledContent("Session")"#, #"LabeledContent("Sign-in""#, #"Text("Locked")"#, #"Text("Enrolled")"#,
                    #"Text("Now")"#, #"Text("Ready")"#, #"Text("Error")"#, #"Text("System")"#, #"LocalizedStringResource("System")"#,
                    #"Picker("Type""#]
        var tight = 0
        for (path, text) in try Self.sources() {
            for occurrence in bare { XCTAssertFalse(text.contains(occurrence), "\(path): \(occurrence) without its comment") }
            tight += text.components(separatedBy: "[tight]").count - 1
        }
        XCTAssertGreaterThanOrEqual(tight, 40, "the tight labels say so")
        // A position's side reads as the Perps screens' own key and comment, which also name the order button.
        let alerts = try Self.source("Notifications/AlertCenter.swift")
        let trade = try Self.source("Perps/PerpTradeView.swift")
        for side in [#"LocalizedStringResource("Long", comment: "Opens a long position: a bet that the price rises. Also a position's side. [tight]")"#,
                     #"LocalizedStringResource("Short", comment: "Opens a short position: a bet that the price falls. Also a position's side. [tight]")"#] {
            XCTAssertTrue(alerts.contains(side), side)
            XCTAssertTrue(trade.contains(side), "the Perps screen's own: \(side)")
        }
        // One key is one translation: the Trade switch's "Swap" (the screen's name, a noun) is a key of its own, and the
        // key "Swap" is the swap review's button, a verb. English reads "Swap" for both.
        let mode = Self.squeezed(try Self.body(of: "var label: String", after: "enum TradeMode", in: "App/Router.swift"))
        XCTAssertTrue(mode.contains(#"case .swap: tr(LocalizedStringResource("tradeMode.swap", defaultValue: "Swap", comment: "The Trade tab's switch to its spot-swap screen: the screen's name, a noun [tight]"))"#))
        XCTAssertTrue(try DocsLinksTests.appSource("Swap/SwapView.swift")
            .contains(#"confirmTitle: LocalizedStringResource("Swap", comment: "Button: make the swap the review shows (a verb)")"#), "the review's button")
        // "All" is a key per meaning, since gender and number differ in Spanish and French: a reporting period (all time),
        // every news source, every kind of notification (and, in the Moments lane, every Moment). English reads "All".
        let router = Self.squeezed(try Self.source("App/Router.swift"))
        XCTAssertEqual(router.components(separatedBy: #"tr(LocalizedStringResource("volumePeriod.all", defaultValue: "All", comment: "A reporting period: all time [tight]"))"#).count - 1, 2,
                       "the period's label and its chip")
        XCTAssertTrue(try Self.source("News/NewsView.swift")
            .contains(#"chip(Text(verbatim: tr(LocalizedStringResource("newsSource.all", defaultValue: "All", comment: "News filter: headlines from every source [tight]"))), selected: source == nil)"#))
        XCTAssertTrue(try Self.source("Notifications/NotificationCenterView.swift")
            .contains(#"chip(Text(verbatim: tr(LocalizedStringResource("notificationFilter.all", defaultValue: "All", comment: "Notification center filter: every kind of notification [tight]"))), selected: filter == nil)"#))
    }

    /// A key is one translation wherever it stands, so a key used in several places carries one comment, the same at
    /// every place that writes one, and it names each use; a use with another meaning gets a key of its own.
    func testASharedKeyHasOneCommentForEveryUse() throws {
        let shared: [(key: String, names: [String])] = [
            ("Swap", ["(a verb)"]),
            ("System", ["Appearance", "light or dark", "Language", "its language"]), // Appearance, the Language screen and menu
            ("Now", ["side menu", "TP/SL sheet"]), // the menu's badge; Perps' row of the trigger set now
            ("Type", ["Import Wallet", "order's type"]), // Import Wallet's switch; Perps' order type
            ("Cancelled.", ["a request", "passkey prompt"]), // describe(_:); a passkey ceremony's failure
        ]
        let app = try FormattedTextIsolationTests.appSources().map(\.text).joined(separator: "\n")
        for (key, names) in shared {
            let site = try NSRegularExpression(pattern: #"(?:LocalizedStringResource|Text)\(""# + NSRegularExpression.escapedPattern(for: key) + #"", comment: "((?:[^"\\]|\\.)*)""#)
            let comments = Set(site.matches(in: app, range: NSRange(app.startIndex..., in: app)).compactMap { Range($0.range(at: 1), in: app).map { String(app[$0]) } })
            XCTAssertEqual(comments.count, 1, "\(key): one comment for every use: \(comments.sorted())")
            for comment in comments {
                for name in names { XCTAssertTrue(comment.contains(name), "\(key): the comment names \(name): \(comment)") }
            }
        }
    }

    /// No key carries two comments anywhere in the app: Xcode would join them for the one translation the key gets, and
    /// a word with two meanings ("All", "Close", "Market") is two keys instead. Read from every `Text("…", comment:)` and
    /// `LocalizedStringResource("…", comment:)` of the app, an interpolated value standing for any value.
    func testNoKeyHasTwoComments() throws {
        let site = try NSRegularExpression(pattern: #"(?:\bText|LocalizedStringResource)\("((?:[^"\\]|\\.)*)"(?:, defaultValue: "(?:[^"\\]|\\.)*")?, comment: "((?:[^"\\]|\\.)*)""#)
        let value = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var comments: [String: Set<String>] = [:]
        for (_, text) in try FormattedTextIsolationTests.appSources() {
            let code = Self.squeezed(text)
            for match in site.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let key = Range(match.range(at: 1), in: code), let comment = Range(match.range(at: 2), in: code) else { continue }
                let written = String(code[key])
                let normalized = value.stringByReplacingMatches(in: written, range: NSRange(written.startIndex..., in: written), withTemplate: "%")
                comments[normalized, default: []].insert(String(code[comment]))
            }
        }
        XCTAssertGreaterThan(comments.count, 100, "the scan reads the app's comments")
        let twice = comments.filter { $0.value.count > 1 }.map { entry in "\(entry.key): \(entry.value.sorted())" }.sorted()
        XCTAssertEqual(twice, [], "a key with two comments")
        XCTAssertEqual(comments["Close"], ["Closes this screen or sheet (a verb)"])
    }

    // MARK: Dates and durations

    /// Every date and duration written as a `String` is in the app's language (`L10n.locale`), in the system's own units;
    /// English reads as before.
    func testDatesAndDurationsFollowTheAppLanguage() throws {
        for (path, text) in try Self.sources() {
            for line in text.components(separatedBy: "\n") where line.contains(".formatted(") {
                XCTAssertTrue(line.contains("L10n.locale"), "\(path): \(line.trimmingCharacters(in: .whitespaces))")
            }
            for line in text.components(separatedBy: "\n") where line.contains("String(format:") {
                XCTAssertFalse(PerpsWalletStringsTests.literals(in: line).contains { PerpsWalletStringsTests.isWords($0.text) },
                               "\(path): words in a format string: \(line.trimmingCharacters(in: .whitespaces))")
            }
            XCTAssertFalse(text.contains("ListFormatter.localizedString("), "\(path): a list in the device's language")
        }
        let center = try Self.source("Notifications/NotificationCenterView.swift")
        XCTAssertTrue(center.contains(#"tr("Today")"#) && center.contains(#"tr("Yesterday")"#))
        XCTAssertTrue(center.contains("day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(L10n.locale))"))
        let settings = try Self.source("Profile/Settings.swift")
        XCTAssertTrue(settings.contains("Duration.seconds(Int(length)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(L10n.locale))"))
        XCTAssertTrue(settings.contains(#"Text("Unlocked · \(clock) left")"#))
        XCTAssertFalse(String(TradeStringsTests.uncommented(Array(settings))).contains(#""1 hour""#), "no English-only length")
        XCTAssertTrue(try Self.source("Onboarding/OnboardingView.swift").contains("list.locale = L10n.locale"))

        // English is unchanged: the session lengths read as the code wrote them before.
        let en = Locale(identifier: "en_US")
        let lengths = Mera.SessionLength.choices.map { Duration.seconds(Int($0)).formatted(.units(allowed: [.hours, .minutes], width: .wide).locale(en)) }
        XCTAssertEqual(lengths, ["5 minutes", "15 minutes", "1 hour"])
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!).locale(en)), "Sep 21, 2026")
        let list = ListFormatter()
        list.locale = en
        XCTAssertEqual(list.string(from: ["1 MON", "2 USDC", "3 AUSD"]), "1 MON, 2 USDC, and 3 AUSD")
    }

    // MARK: Errors

    /// `describe(_:)` tells a cancelled request and a lost connection by the error's type and code (`FailureKind`), never
    /// by matching its English text, and says them in the app's language, each key with a translator comment.
    func testDescribeKnowsFailuresByType() throws {
        let describe = Self.squeezed(try Self.body(of: "func describe(_ error: Error) -> String", in: "Design/Components.swift"))
        XCTAssertTrue(describe.contains("switch FailureKind.of(error) {"))
        XCTAssertTrue(describe.contains(#"case .cancelled: return tr(LocalizedStringResource("Cancelled.", comment: "An error message: what was under way was cancelled"#))
        XCTAssertTrue(describe.contains(#"case .offline: return tr(LocalizedStringResource("No connection. Check your network and try again.", comment: "An error message: the device is offline"#))
        XCTAssertTrue(describe.contains("case .other: return error.localizedDescription"))
        // An error's own description comes first, as before: English reads as it did (an RPC call's lost connection still
        // says iOS's own sentence, through `NetworkError`), and only an error without one is told by its type and code.
        let own = try XCTUnwrap(describe.range(of: "(error as? LocalizedError)?.errorDescription"))
        let kind = try XCTUnwrap(describe.range(of: "switch FailureKind.of(error)"))
        XCTAssertLessThan(own.lowerBound, kind.lowerBound)
        for (path, text) in try Self.sources() {
            XCTAssertFalse(text.contains("localizedCaseInsensitiveContains(\"cancel"), path)
            XCTAssertFalse(text.contains("localizedCaseInsensitiveContains(\"network"), path)
            XCTAssertFalse(text.contains("localizedDescription.contains("), "\(path): an error matched by its text")
        }
    }

    /// The server's own English words the app matches stay English, whatever the app's language, and each is still what
    /// the function sends: the email binding's code and its word for a stale token, delete-account's answers. The word
    /// typed to delete an account is DELETE in every language.
    func testServerMatchersStayEnglish() throws {
        let onboarding = try Self.source("Onboarding/OnboardingView.swift")
        XCTAssertTrue(onboarding.contains(#"guard Self.serverField(text, "error") == "email_already_bound", "#))
        XCTAssertTrue(onboarding.contains(#"catch SupabaseError.http(401, let text) where Self.serverField(text, "error")?.contains("expired") == true { throw EmailAuthError.verificationExpired }"#))
        XCTAssertTrue(onboarding.contains("// not localized: the function's own English word for a stale token"))
        let deletion = try Self.source("Profile/AccountDeletion.swift")
        XCTAssertTrue(deletion.contains(#"catch SupabaseError.http(401, let body) where body.contains("invalid Privy access token") { // not localized"#))
        XCTAssertTrue(deletion.contains(#"catch SupabaseError.http(409, let body) where serverError(body) == "no email binding" { // not localized"#))
        XCTAssertEqual(deletion.components(separatedBy: #"body.contains("PRIVY_APP_SECRET") { // not localized"#).count - 1, 2)
        XCTAssertTrue(deletion.contains(#"confirmation.trimmingCharacters(in: .whitespaces).uppercased() == "DELETE" } // not localized"#))
        XCTAssertTrue(deletion.contains(#"comment: "Keep DELETE in English and in capitals: it is the word the user must type""#))
        // A refusal the function sends reaches the screen through EdgeFunctionError: a known one in the app's language,
        // email-rebind's as a sentence of its own and delete-account's inside one; nothing else reads the server's text.
        let message = Self.squeezed(try Self.body(of: "private static func serverMessage(_ text: String) -> String", in: "Onboarding/OnboardingView.swift"))
        XCTAssertTrue(message.contains("return EdgeFunctionError.emailRebind(msg)"))
        XCTAssertFalse(message.contains("uppercased()"), "EdgeFunctionError writes the sentence")
        XCTAssertEqual(onboarding.components(separatedBy: "throw EmailAuthError.bindFailed(Self.serverMessage(text))").count - 1, 2)
        XCTAssertTrue(deletion.contains(#"throw Failure.emailSignInNotDeleted(serverError(body).map(EdgeFunctionError.deleteAccount) ?? tr("error \(String(code))"))"#))
        XCTAssertEqual(deletion.components(separatedBy: "serverError(body)").count - 1, 2, "the matcher and the mapped reason")

        let rebind = try EdgeFunctionErrorTests.function("email-rebind")
        XCTAssertTrue(rebind.contains(#"error: "email_already_bound""#))
        XCTAssertTrue(rebind.contains(#"{ error: "this verification expired — request a new code" }, 401"#))
        let delete = try EdgeFunctionErrorTests.function("delete-account")
        XCTAssertTrue(delete.contains(#"error: "no email binding""#))
        XCTAssertTrue(delete.contains(#"{ error: "invalid Privy access token" }, 401"#))
        XCTAssertTrue(delete.contains(#""PRIVY_APP_SECRET is not configured""#))

        // A mail to support: its subject and the device details are for the support team; the body is the user's.
        let help = try Self.source("Support/GetHelpView.swift")
        XCTAssertTrue(help.contains(#"mail(subject: "DyorHQ support")"#))
        XCTAssertTrue(help.contains(#"mail(subject: "DyorHQ bug report", body: tr("What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n"))"#))
    }

    // MARK: Update screen and the Google button

    /// The owner's update message is written in English: the Update screen shows it only while the app is in English, and
    /// the app's own text otherwise.
    func testTheUpdateScreenShowsTheServerMessageOnlyInEnglish() throws {
        let gate = Self.squeezed(try Self.source("App/UpdateGate.swift"))
        XCTAssertTrue(gate.contains("if let message = minimum.ownerMessage(in: language.resolved) { Text(verbatim: message) } else { Paragraph(\"This version of DyorHQ is no longer supported."))
        XCTAssertFalse(gate.contains("minimum.message"), "the row's text is shown only through ownerMessage(in:) (MinimumBuildTests)")
        XCTAssertTrue(gate.contains("@Environment(LanguageStore.self) private var language"))
    }

    /// "Continue with Google" is drawn in the bundled Google Sans subset only when the subset has every letter of the label
    /// in the app's language (`GoogleButtonFont`); the label is resolved once and drawn as it is.
    func testTheGoogleButtonFallsBackToTheSystemFont() throws {
        let button = Self.squeezed(try Self.source("Onboarding/OnboardingView.swift"))
        XCTAssertTrue(button.contains(#"let label = tr(LocalizedStringResource("Continue with Google", comment: "#))
        XCTAssertTrue(button.contains(#"Text(verbatim: label) .font(GoogleButtonFont.usesGoogleSans(label, language: language.resolved) ? Font.custom("GoogleSans-Medium", size: 17, relativeTo: .body) : Font.body.weight(.medium))"#))
        XCTAssertEqual(button.components(separatedBy: ".custom(\"GoogleSans-Medium\"").count - 1, 1, "Google Sans only behind the check")
    }
}
