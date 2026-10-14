import Foundation
import XCTest
@testable import DyorKit

/// DyorKit's own text (L2, ios/DyorKit/Sources): every sentence DyorKit writes for a person (a transaction step's label,
/// an error, a revert reason, a badge, a passkey prompt's reason, an alert, a price's source line) goes through
/// `L10n.tr` or a `LocalizedStringResource` from DyorKit's own catalog, so it is in the app's language when it is
/// written. Text kept as a `static let` would keep the language of its first read, so such text is a computed property.
/// A word is never chosen inside another string's interpolation; a count that needs a plural is the key's own `Int`.
/// What must stay English stays as it is: the nodes', Perpl's, Kuru's, Aurora's and DyorHQ's servers' own English, which
/// the code matches; identifiers; and names (tokens, chains, venues, markets, languages).
final class DyorKitStringsTests: XCTestCase {
    // MARK: Reading the sources

    /// ios/DyorKit/Sources/DyorKit.
    private static func root() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() } // DyorKitStringsTests.swift → DyorKitTests → Tests → DyorKit
        return root.appendingPathComponent("Sources/DyorKit")
    }

    /// Every Swift file of DyorKit's sources, by its path under Sources/DyorKit; a new file is read too. The BIP-39 word
    /// list is left out: its words are the standard's, never shown as text of the app's.
    private static func sources() throws -> [(path: String, text: String)] {
        let root = root()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let swift = files.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "BIP39Wordlist.swift" }
        XCTAssertGreaterThan(swift.count, 100)
        return try swift.map { (String($0.path.dropFirst(root.path.count + 1)), try String(contentsOf: $0, encoding: .utf8)) }.sorted { $0.0 < $1.0 }
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(path), encoding: .utf8)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The code lines of the sources with their literals; a doc or line comment is left out, and so is a line marked
    /// "not localized", or right under a comment line that marks it. A marker at the end of a line of code covers that
    /// line only: the next line (another case of the same switch, say) is read as any other.
    private static func scannedLines() throws -> [(at: String, line: String, literals: [PerpsWalletStringsTests.Literal])] {
        scannedLines(of: try sources())
    }

    private static func scannedLines(of files: [(path: String, text: String)]) -> [(at: String, line: String, literals: [PerpsWalletStringsTests.Literal])] {
        var out: [(String, String, [PerpsWalletStringsTests.Literal])] = []
        for (path, text) in files {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                if line.contains("not localized") || previous.hasPrefix("//") && previous.contains("// not localized") { continue }
                out.append(("\(path):\(index + 1)", line, PerpsWalletStringsTests.literals(in: line)))
            }
        }
        return out
    }

    /// Names that are never translated, which the code returns as they are: venues, price sources, the app's own name.
    private static let names: Set<String> = ["Kuru Flow", "Uniswap", "Monday Trade", "Uniswap v4", "Uniswap v3", "Nad.fun", "DyorHQ",
                                             "DyorHQ curve", "DyorHQ Moment pool"]

    // MARK: Written text goes through DyorKit's catalog

    /// DyorKit's text is looked up in DyorKit's own resource bundle (its `Bundle.module`, DyorKit_DyorKit.bundle, both in
    /// the app and under `swift test`; here in the tests `Bundle.module` is the tests' own bundle), which holds its
    /// catalog: raw under `swift test`, compiled into the app's copy of the bundle. A resource names that bundle
    /// (`L10n.kit`), so it is never looked up in the app's catalog. With no entry for a key, the key is the English, its
    /// values filled in.
    func testTheCatalogIsDyorKitsOwn() throws {
        XCTAssertEqual(L10n.bundle.bundleURL.lastPathComponent, "DyorKit_DyorKit.bundle")
        XCTAssertNotEqual(L10n.bundle.bundleURL, Bundle.module.bundleURL, "the tests' bundle holds fixtures, not DyorKit's catalog")
        let raw = L10n.bundle.url(forResource: "Localizable", withExtension: "xcstrings")
        let compiled = L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
            ?? L10n.bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: "en")
        XCTAssertTrue(raw != nil || compiled != nil, "DyorKit's catalog is in its resource bundle")
        let l10n = Self.squeezed(try Self.source("Core/L10n.swift"))
        XCTAssertTrue(l10n.contains("static var bundle: Bundle { .module }"), "DyorKit's own bundle, in the app and under swift test")
        XCTAssertTrue(l10n.contains("static var kit: LocalizedStringResource.BundleDescription { .atURL(bundle.bundleURL) }"))
        XCTAssertTrue(l10n.contains("public static func tr(_ value: String.LocalizationValue) -> String { string(LocalizedStringResource(value, bundle: kit)) }"))

        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")
        XCTAssertEqual(L10n.tr("Approve \("USDC") for Permit2"), "Approve USDC for Permit2")
        XCTAssertEqual(L10n.string(LocalizedStringResource("Graduate", bundle: L10n.kit, comment: "a test")), L10n.tr("Graduate"))
        XCTAssertEqual(L10n.tr("Liquidation risk: \("BTC-PERP long")"), "Liquidation risk: BTC-PERP long")
        XCTAssertEqual(L10n.tr("Perpl liquidates at 100%. Mark \("$1.00")"), "Perpl liquidates at 100%. Mark $1.00", "a percent sign stays one")
    }

    /// Text built as a `String` (a returned label or error, an assigned value, either branch of a choice, a switch case's
    /// or a computed property's own result, a fallback after `??`, a step's label, a quote's route, a refusal) goes
    /// through `L10n.tr` or a resource: a bare literal there is shown in English in every language.
    func testStringTextGoesThroughTheCatalog() throws {
        let sink = try NSRegularExpression(pattern: Self.sinkPattern)
        var found: [String] = []
        for (at, line, _) in try Self.scannedLines() {
            for text in Self.bareText(on: line, sink: sink) { found.append("\(at): \"\(text)\"") }
        }
        XCTAssertEqual(found, [], "String text written in DyorKit goes through L10n")

        // The reader sees what it should: each of these is bare English a person reads…
        for line in [#"case .x: return "Not enough MON to pay for gas.""#,
                     #"return launch.curveSellsOpen ? L10n.tr("Sell on its Launch page") : "Graduation pending · Launch page""#,
                     #"return launch.curveSellsOpen ? "Sell on its Launch page" : L10n.tr("Graduation pending · Launch page")"#,
                     #"case .bonding, .graduated: retired ? L10n.tr("Sell on its Launch page") : "Trade on its Launch page""#,
                     #"    : "Graduation pending · Launch page""#, // a choice's second branch on a line of its own
                     #"case .migrating: "Migrating · Launch page""#,
                     #"default: "Trade on its Launch page""#,
                     #"public static var notice: String { "This coin's launchpad is retired: you can sell, but not buy." }"#,
                     #"VenueQuote(venue: .kuru, amountOut: out, minOut: min, route: "Aggregated across Kuru order books and Monad pools", gasEstimate: nil)"#,
                     #"throw PerplTradeError.unavailable("Perpl trading isn't available right now.")"#] {
            XCTAssertEqual(Self.bareText(on: line, sink: sink).count, 1, line)
        }
        // …and none of these is: the same text looked up, a name, a debug description (for developers).
        for line in [#"case .x: return L10n.tr("Not enough MON to pay for gas.")"#,
                     #"return launch.curveSellsOpen ? L10n.tr("Sell on its Launch page") : L10n.tr("Graduation pending · Launch page")"#,
                     #"case .migrating: L10n.tr("Migrating · Launch page")"#,
                     #"VenueQuote(venue: .kuru, amountOut: out, minOut: min, route: L10n.tr("Aggregated across Kuru order books and Monad pools"), gasEstimate: nil)"#,
                     #"case .kuru: return "Kuru Flow""#,
                     #"public var description: String { "RawDigest32(32 bytes)" }"#] {
            XCTAssertEqual(Self.bareText(on: line, sink: sink), [], line)
        }
        // A "not localized" marker at the end of a line covers that line only; a marker on a line of its own covers the
        // line under it.
        let cases = """
            case .opticID: "Optic ID" // not localized: Apple's name
            case .passcode: "Passcode"
            // not localized: Apple's name
            case .faceID: "Face ID"
            """
        XCTAssertEqual(Self.scannedLines(of: [("Kind.swift", cases)]).flatMap { Self.bareText(on: $0.line, sink: sink) }, ["Passcode"])
    }

    /// Where a bare literal is String text a person reads: after `return` or `=`, either branch of a choice (`? ` and
    /// ` : `), a fallback after `??`, a switch case's own result (`case .x: "…"`, `default: "…"`), a computed property's
    /// or a closure's implicit result (`{ "…" }`; not a `description`'s, which is for developers), a step's `label:`, a
    /// quote's `route:`, an error's text, and the properties that hold a sentence.
    private static let sinkPattern = #"(return |(?<![=!<>])= |\?\? |\? | : |\bcase [^:"]*: |\bdefault: |(?<!description: String )\{ |label: |route: |errorDescription: String\? \{ |\.rejected\(|\.venue\(|\.transport\(|\.notCollecting\(|\.malformedResponse\(|\.decoding\(|\.unexpectedResponse\(|\.invalidOrder\(|\.unavailable\(|\.closed\(|fallback: |direction = |act = |title = |stepsHeading = |recentlyDeleted = )$"#

    /// The literals of `line` that are String text written bare: words (not a listed name) written in the code itself,
    /// right after a place whose text a person reads (`sinkPattern`).
    private static func bareText(on line: String, sink: NSRegularExpression) -> [String] {
        PerpsWalletStringsTests.literals(in: line).filter { literal in
            literal.depth == 0 && PerpsWalletStringsTests.isWords(literal.text) && !names.contains(literal.text)
                && sink.firstMatch(in: literal.before, range: NSRange(literal.before.startIndex..., in: literal.before)) != nil
        }.map(\.text)
    }

    /// A word chosen inside another string's interpolation (`"\(isLong ? "long" : "short") …"`) is never looked up: each
    /// choice is a sentence of its own.
    func testNoWordIsChosenInsideAnInterpolation() throws {
        var found: [String] = []
        for (at, _, literals) in try Self.scannedLines() {
            for literal in literals where literal.depth > 0 && (PerpsWalletStringsTests.isWords(literal.text) || literal.text.range(of: "^[a-z]{2,}$", options: .regularExpression) != nil) {
                found.append("\(at): \"\(literal.text)\"")
            }
        }
        XCTAssertEqual(found, [], "a word inside an interpolation stays English in every language")
    }

    /// Every resource DyorKit writes is looked up in DyorKit's catalog; nothing uses `String(localized:)` (its locale
    /// formats values but never picks the language) or `NSLocalizedString`; and a one-word key, whose meaning is
    /// ambiguous out of context ("Graduate", "Long", "All"), carries a translator comment.
    func testEveryKeyIsLookedUpInDyorKitsCatalog() throws {
        let oneWord = try NSRegularExpression(pattern: #"L10n\.tr\("[A-Za-z]+"\)"#)
        var resources = 0
        for (path, text) in try Self.sources() where path != "Core/L10n.swift" {
            let range = NSRange(text.startIndex..., in: text)
            resources += Self.resourceCalls(in: text).count
            XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: text), [], "\(path): a resource outside DyorKit's catalog")
            XCTAssertFalse(text.contains("String(localized:"), path)
            XCTAssertFalse(text.contains("NSLocalizedString"), path)
            XCTAssertNil(oneWord.firstMatch(in: text, range: range), "\(path): a one-word key without a translator comment")
        }
        XCTAssertGreaterThan(resources, 60)

        // The reader sees what it should: a resource is judged by its own arguments alone, read to its own closing
        // parenthesis, never by a neighbour's (a resource with none above another that names DyorKit's catalog, as a
        // table of them is written), a nested one's, or the words of its comment.
        let neighbours = """
            case .quickstart: return L10n.string(LocalizedStringResource("getting started", comment: "The topic of a docs page."))
            case .bridge: return L10n.string(LocalizedStringResource("bridging", bundle: L10n.kit, comment: "The topic of a docs page."))
            """
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: neighbours).count, 1)
        XCTAssertTrue(Self.resourcesOutsideTheCatalog(in: neighbours).first?.contains("getting started") ?? false)
        let nested = #"L10n.string(LocalizedStringResource("Pay \(L10n.string(LocalizedStringResource("fees", bundle: L10n.kit))) now", comment: "A (verb)."))"#
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: nested).count, 1, "the nested resource's catalog isn't its own")
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: #"LocalizedStringResource("Graduate", comment: "not bundle: L10n.kit")"#).count, 1)
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: #"LocalizedStringResource("Open", comment: "A verb."); let kit = "bundle: L10n.kit""#).count, 1)
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: #"LocalizedStringResource("Never closes", bundle: L10n.kit"#).count, 1, "a call that never closes")
        let wrapped = """
            L10n.string(LocalizedStringResource("Long \\(symbol) (\\(String(size)))", // a side and its size
                                                bundle: L10n.kit,
                                                comment: "An order's step (verb): “Long BTC (2)”."))
            """
        XCTAssertEqual(Self.resourceCalls(in: wrapped).count, 1)
        XCTAssertEqual(Self.resourcesOutsideTheCatalog(in: wrapped), [], "a call over several lines, with a comment and nested parentheses")
    }

    /// Where each `LocalizedStringResource(` call in `text` opens: the index just after its `(`. A mention on a comment
    /// line isn't a call.
    private static func resourceCalls(in text: String) -> [Int] {
        let chars = Array(text)
        let call = Array("LocalizedStringResource(")
        var opens: [Int] = []
        var lineStart = 0
        var i = 0
        while i < chars.count {
            if chars[i] == "\n" { lineStart = i + 1 }
            if chars[i] == "L", i + call.count <= chars.count, Array(chars[i ..< i + call.count]) == call,
               i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_"),
               !String(chars[lineStart ..< i]).trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                opens.append(i + call.count)
            }
            i += 1
        }
        return opens
    }

    /// The `LocalizedStringResource(…)` calls in `text` that don't pass `bundle: L10n.kit` among their own arguments,
    /// each as the first 80 characters of the call.
    static func resourcesOutsideTheCatalog(in text: String) -> [String] {
        let chars = Array(text)
        let start = "LocalizedStringResource(".count
        return resourceCalls(in: text).compactMap { open in
            let own = ownArguments(chars, from: open)
            if let own, squeezed(own).contains("bundle: L10n.kit") { return nil }
            return String(chars[(open - start) ..< min(open - start + 80, chars.count)])
        }
    }

    /// A call's own arguments, read from `start`, just after its `(`, to the `)` that closes it: each string literal
    /// stands as `""`, and what a nested bracket or a comment holds is left out. Nil when the call never closes.
    static func ownArguments(_ chars: [Character], from start: Int) -> String? {
        var own = ""
        var depth = 0
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "\"" {
                guard let end = endOfLiteral(chars, from: i) else { return nil }
                if depth == 0 { own += "\"\"" }
                i = end
                continue
            }
            if "([{".contains(c) {
                depth += 1
            } else if ")]}".contains(c) {
                if depth == 0 { return own }
                depth -= 1
            } else if depth == 0 {
                own.append(c)
            }
            i += 1
        }
        return nil
    }

    /// The index just past the string literal whose opening quote is at `start`. A `\(…)` interpolation is read as
    /// code, so a literal inside it ends where it should; a `"""` literal runs to its closing `"""`.
    static func endOfLiteral(_ chars: [Character], from start: Int) -> Int? {
        let multiline = start + 2 < chars.count && chars[start + 1] == "\"" && chars[start + 2] == "\""
        var i = start + (multiline ? 3 : 1)
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    guard let end = endOfInterpolation(chars, from: i + 2) else { return nil }
                    i = end
                } else {
                    i += 2
                }
                continue
            }
            if c == "\"" {
                if !multiline { return i + 1 }
                if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" { return i + 3 }
            }
            if c == "\n", !multiline { return nil }
            i += 1
        }
        return nil
    }

    /// The index just past the `)` that closes an interpolation whose code starts at `start`.
    static func endOfInterpolation(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                guard let end = endOfLiteral(chars, from: i) else { return nil }
                i = end
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                if depth == 0 { return i + 1 }
                depth -= 1
            }
            i += 1
        }
        return nil
    }

    /// A step's label or a notification's title whose first word reads as a noun out of context ("Claim", "Swap",
    /// "Launch", "Collect", "Deposit", "Buy", "Sell", "Open", "Close", "Long", "Short", "Order … filled") carries a
    /// translator comment, so it is translated as the instruction or the event it is.
    func testAmbiguousLabelsCarryATranslatorComment() throws {
        let bare = try NSRegularExpression(pattern: #"(label: |let label = )L10n\.tr\("(Buy|Sell|Launch|Claim|Collect|Swap|Deposit|Open|Close|Long|Short)\b|L10n\.tr\("(Order (submitted|placed|filled)|Close order filled)"\)"#)
        for (path, text) in try Self.sources() {
            XCTAssertNil(bare.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(path): an ambiguous label without a translator comment")
        }
        let code = Self.squeezed(try Self.sources().map(\.text).joined(separator: "\n"))
        for key in [#""Claim fees""#, #""Swap on Kuru Flow""#, #""Launch $\(input.symbol)""#, #""Collect \(quantity) editions of \(symbol)""#,
                    #""Claim \(momentIds.count) Moments""#, #""Open Perpl account""#, #""Order filled""#, #""Close order filled""#, #""Graduate""#,
                    #""Close \(symbol)""#, #""Long \(symbol)""#, #""All""#] {
            XCTAssertTrue(code.contains("LocalizedStringResource(\(key), bundle: L10n.kit, comment: \""), key)
        }
    }

    /// A step a person follows names iOS's screens as iOS names them: the Passwords app's list of deleted passkeys is
    /// "Deleted" (iOS 18 and later; "Recently Deleted" is the Photos album), and its translators are told to use iOS's
    /// own names for the app and the list.
    func testThePasswordsAppsListIsNamedAsIOSNamesIt() throws {
        let deletion = Self.squeezed(try Self.source("Services/Mera/MeraAccountDeletion.swift"))
        XCTAssertTrue(deletion.contains(#"recentlyDeleted = L10n.string(LocalizedStringResource("If your passkey is in iCloud Keychain, Passwords may keep it in Deleted for up to 30 days.", bundle: L10n.kit, comment: "Passwords is iOS's Passwords app and Deleted its list of deleted passwords and passkeys (iOS 18 and later): use iOS's own names for them in this language."))"#))
        XCTAssertFalse(deletion.contains("Recently Deleted for up to 30 days"), "iOS 18's Passwords app has no Recently Deleted")
    }

    /// Written text that a `static let` would keep in the language of its first read is a computed property, read again
    /// each time it is shown.
    func testNoTextIsFrozenInAStaticLet() throws {
        let frozen = try NSRegularExpression(pattern: #"static let \w+[^=\n]*= *\[?\s*L10n\."#)
        for (path, text) in try Self.sources() {
            XCTAssertNil(frozen.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(path): text kept in a static let")
        }
        let curves = try Self.source("Services/Launchpad/LaunchpadCurves.swift")
        XCTAssertTrue(curves.contains("public static var tradeOnLaunchPage: String { L10n.tr("))
        let retired = try Self.source("Services/Launchpad/RetiredLaunchpads.swift")
        XCTAssertTrue(retired.contains("public static var notice: String { L10n.tr(\"This coin's launchpad is retired: you can sell, but not buy.\") }"))
        XCTAssertTrue(try Self.source("Core/RPCClient.swift").contains("public static var unconfirmed: String { L10n.tr("))
        XCTAssertTrue(try Self.source("Chain/Transactions.swift").contains("static var fundsArriving: String { L10n.tr("))
        XCTAssertTrue(try Self.source("Services/Perpl/PerplTriggers.swift").contains("public static var liquidationUnknownMessage: String {"))
        XCTAssertTrue(try Self.source("Services/Mera/MeraAccountDeletion.swift").contains("public static var manualSteps: [String] {"))
        // The revert map writes each sentence when it is shown; only the selectors are worked out once.
        let transactions = Self.squeezed(try Self.source("Chain/Transactions.swift"))
        XCTAssertTrue(transactions.contains("static var knownErrors: [String: String] { knownErrorSentences.mapValues { $0() } }"))
        XCTAssertTrue(transactions.contains("if let named = knownErrorSentences[selector] { return named() }"))
        XCTAssertTrue(transactions.contains(#"("NothingToClaim", { L10n.tr("There is nothing to claim yet.") }),"#))
    }

    /// The parts that must stay English do: what a server parses (the sign-in message), what the code compares (Perpl's
    /// key-request statement, the Simulator stub's title), identifiers (a price's source, a fill's dedup key, a link's
    /// slug) and names.
    func testIdentifiersAndNamesStayAsTheyAre() throws {
        let supabase = try Self.source("Services/Supabase/SupabaseClient.swift")
        for line in [#""\(signInDomain) wants you to sign in with your Ethereum account:","#, #""Sign in to DyorHQ.","#, #""Nonce: \(nonce)","#,
                     #""Issued At: \(iso8601(millis: issuedAt))","#] {
            XCTAssertTrue(supabase.contains(line), line)
        }
        XCTAssertTrue(try Self.source("Services/Perpl/PerplEnrollment.swift")
            .contains(#"public static let statement = "I authorize the creation of Perpl API key with the specified scope and parameters""#))
        let venue = try Self.source("Services/Prices/DyorVenue.swift")
        XCTAssertTrue(venue.contains(#"static let curveLabel = "DyorHQ curve""#))
        XCTAssertEqual(PriceInfo(usd: 1, change24h: nil, source: DyorListing.curveLabel, pairSymbol: "MON").sourceLine, "Priced from its DyorHQ curve")
        XCTAssertEqual(PriceInfo(usd: 1, change24h: nil, source: DyorListing.momentLabel, pairSymbol: "USDC").sourceLine, "Priced from its Moment pool")
        XCTAssertEqual(Venue.kuru.displayName, "Kuru Flow")
        XCTAssertEqual(Venue.wrap.displayName, "Wrap")
        XCTAssertEqual(AppLanguage.en.endonym, "English")
        XCTAssertEqual(DocsLinks.home.topic, "DyorHQ")
        XCTAssertEqual(DocsLinks.quickstart.topic, "getting started")
        // A name or symbol that couldn't be read stands as U+FFFD, a symbol, not a word.
        XCTAssertEqual(ChainText.unreadable, "\u{FFFD}")
    }

    // MARK: English as before

    /// The text reads exactly as before in English: whole sentences replaced words put into them.
    func testEnglishReadsAsBefore() throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")

        XCTAssertEqual(ChainListUnread(.launch).errorDescription, "A launch couldn't be read from the chain just now. Try again.")
        XCTAssertEqual(ChainListUnread(.momentName).errorDescription, "A Moment's name couldn't be read from the chain just now. Try again.")
        XCTAssertEqual(ChainListUnread(.dyorCoin).errorDescription, "A DyorHQ coin couldn't be read from the chain just now. Try again.")
        XCTAssertEqual(Address.inputProblem("0x12g4"), "“g” can't be part of an address: it uses only 0–9 and a–f.")
        XCTAssertEqual(SwapError.timedOut(.kuru, seconds: 8).errorDescription, "Kuru Flow did not answer within 8s.")
        XCTAssertEqual(TokenBadge.unverified.title, "Unverified")
        XCTAssertEqual(PerpOrderNotice.submitted.title, "Order submitted")
        XCTAssertEqual(WalletHoldings.symbolList([]), "")
        XCTAssertEqual(PerplFunding.Direction.longsPayShorts.summary, "Longs pay shorts")
        XCTAssertEqual(SwapHistoryService.Window.all.label, "All")
        XCTAssertEqual(Mera.SigningPolicy.Reason.overActionCap.summary, "over the $100 limit per action")
        XCTAssertEqual(Mera.SigningPolicy.Reason.overSessionCap.summary, "over this session’s $250 limit")
        XCTAssertEqual(Mera.AlwaysAsk.send.summary, "sending to another address")
        XCTAssertEqual(PerplEnrollmentError.wrongChain.errorDescription,
                       "DyorHQ refused to sign Perpl's trading-key request because it is for a different network. Nothing was signed. Try again later.")
        XCTAssertEqual(PerplEnrollmentError.wrongDomain("salt").errorDescription,
                       "DyorHQ refused to sign Perpl's trading-key request because its signing domain is not Perpl's (salt). Nothing was signed. Try again later.")

        // A revert's custom error keeps its selector and, when the payload has words, says them.
        XCTAssertEqual(RevertReason.describe(RPCError(code: 3, message: "execution reverted: custom error 0xdeadbeef", data: "0xdeadbeef")),
                       "The contract rejected the transaction (custom error 0xdeadbeef).")
        let word = String(repeating: "0", count: 63) + "7"
        XCTAssertEqual(RevertReason.describe(RPCError(code: 3, message: "execution reverted: custom error 0xdeadbeef", data: "0xdeadbeef" + word)),
                       "The contract rejected the transaction (custom error 0xdeadbeef with 7).")

        // A retired Moment's coin and its pool are each a sentence of their own.
        let pool = Address(literal: "0x000000000000000000000000000000000000dEaD")
        XCTAssertEqual(SwapError.tradingClosed(pool).errorDescription,
                       "Past cohort · trading closed. \(pool.short) is a retired Moment pool, so DyorHQ never trades it.")

        // Perps orders: the verb for each side and for a close.
        let service = PerplService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!))
        let market = PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                                mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                                fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        func label(_ side: PositionSide, reduceOnly: Bool) -> String? {
            service.orderPlan(OrderInput(market: market, side: side, kind: .market, size: 1, price: nil, leverage: 2, reduceOnly: reduceOnly, slippageBps: 50, postOnly: false)).first?.label
        }
        XCTAssertEqual(label(.long, reduceOnly: false), "Long BTC")
        XCTAssertEqual(label(.short, reduceOnly: false), "Short BTC")
        XCTAssertEqual(label(.short, reduceOnly: true), "Close BTC")
    }

    /// A number that isn't a count a plural depends on (a status or close code, a market's number, a length, a limit, a
    /// wait in minutes) goes into its sentence as plain digits, a `String`: an `Int` would be formatted in the app's
    /// language ("4,001", "4 001"), while the app writes every number in one style. Only the plural keys keep an `Int`.
    func testANumberThatIsntACountIsPlainDigits() throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        for locale in ["en_US", "fr_FR", "de_DE"] {
            L10n.locale = Locale(identifier: locale)
            XCTAssertEqual(PerplClose(code: 4001, reason: "").message, "Perpl trading connection closed (code 4001).", locale)
            XCTAssertEqual(PerplClose(code: 4002, reason: "bye").message, "Perpl trading connection closed (4002: bye).", locale)
            XCTAssertEqual(SupabaseError.rateLimited(retryAfter: 86_400).errorDescription, "Too many attempts. Try again in 1440 min.", locale)
            XCTAssertEqual(Address.inputProblem("0x" + String(repeating: "a", count: 1234)),
                           "An address has 40 characters after 0x; this one has 1234.", locale)
            XCTAssertEqual(NetworkError.badStatus(503).errorDescription, "The server answered with status 503.", locale)
            XCTAssertEqual(PerplError.contextUnavailable(status: 502).errorDescription, "Perpl market data is unavailable (status 502).", locale)
            XCTAssertEqual(SupabaseError.http(503, "").errorDescription, "DyorHQ's server isn't answering right now (503). Try again in a minute.", locale)
            XCTAssertEqual(Mera.SigningPolicy.Reason.overActionCap.summary, "over the $100 limit per action", locale)
        }
        // At the call sites: each such number is converted to its digits before it goes into the key.
        let code = try Self.sources().map(\.text).joined(separator: "\n")
        for site in [#"(code \(String(code)))."#, #"(\(String(code)): \(reason))."#, #"Try again in \(String(max(1, (seconds + 59) / 60))) min."#,
                     #"this one has \(String(body.count))."#, #"status \(String(code))."#, #"(status \(String(status)))."#, #"position \(String(perpId))"#,
                     #"Kuru Flow returned \(String(status))."#, #"at most \(String(LaunchpadService.maxExemptions))."#, #"(\(String(http.statusCode)))."#] {
            XCTAssertTrue(code.contains(site), site)
        }
    }

    /// Perps alerts: each side and level is a sentence of its own, and all of the margin in use reads as before. That
    /// "All" is a key of its own, apart from the swap history's window "All": one key is one translation, and French and
    /// Spanish say all of the margin with another form than all time.
    func testPerpAlertsReadAsBefore() throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")
        XCTAssertEqual(PerpAlertText.positionName(asset: "ETH", side: .short), "ETH-PERP short")
        XCTAssertEqual(PerpAlertText.usageText(10), "All")
        XCTAssertTrue(PerpAlertText.usageIsAll(.nan) && PerpAlertText.usageIsAll(10) && !PerpAlertText.usageIsAll(9.99))
        let alerts = try Self.source("Services/Perpl/PerpRisk.swift")
        XCTAssertFalse(alerts.contains(#"side == .long ? "long" : "short""#), "no side chosen inside a sentence")
        XCTAssertTrue(alerts.contains(#"LocalizedStringResource("marginUsage.all", defaultValue: "All", bundle: L10n.kit, comment: "#))
        XCTAssertTrue(try Self.source("Services/SwapHistory.swift")
            .contains(#"LocalizedStringResource("All", bundle: L10n.kit, comment: "[tight] A history window: every swap, as far back as the app reads.")"#))
    }

    /// No key carries two comments in DyorKit: Xcode would join them for the one translation the key gets, and a word with
    /// two meanings is two keys instead. Read from every `LocalizedStringResource("…", bundle: L10n.kit, comment:)`, an
    /// interpolated value standing for any value.
    func testNoKeyHasTwoComments() throws {
        let site = try NSRegularExpression(pattern: #"LocalizedStringResource\("((?:[^"\\]|\\.)*)"(?:, defaultValue: "(?:[^"\\]|\\.)*")?, bundle: L10n\.kit, comment: "((?:[^"\\]|\\.)*)""#)
        let value = try NSRegularExpression(pattern: #"\\\([^)]*\)"#)
        var comments: [String: Set<String>] = [:]
        for (_, text) in try Self.sources() {
            let code = Self.squeezed(text)
            for match in site.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let key = Range(match.range(at: 1), in: code), let comment = Range(match.range(at: 2), in: code) else { continue }
                let written = String(code[key])
                let normalized = value.stringByReplacingMatches(in: written, range: NSRange(written.startIndex..., in: written), withTemplate: "%")
                comments[normalized, default: []].insert(String(code[comment]))
            }
        }
        XCTAssertGreaterThan(comments.count, 100, "the scan reads DyorKit's comments")
        let twice = comments.filter { $0.value.count > 1 }.map { entry in "\(entry.key): \(entry.value.sorted())" }.sorted()
        XCTAssertEqual(twice, [], "a key with two comments")
    }

    // MARK: What stays English

    /// The nodes', Perpl's, Kuru's, Aurora's and DyorHQ's servers' own English, which the code matches, is never
    /// translated: each matcher reads as written, and still recognises the server's text while the app is in French.
    func testTheEnglishMatchersAreUntouched() throws {
        let transactions = try Self.source("Chain/Transactions.swift")
        XCTAssertTrue(transactions.contains(#"static func isNonceUsed(_ error: RPCError) -> Bool { error.message.lowercased().contains("nonce too low") }"#))
        XCTAssertTrue(transactions.contains(#""insufficient funds", "insufficient balance", "intrinsic gas too low", "exceeds block gas limit", "underpriced","#))
        XCTAssertTrue(transactions.contains(#""nonce too low", "invalid sender", "invalid chain id", "transaction type not supported", "oversized data","#))
        XCTAssertTrue(transactions.contains(#"error.message.localizedCaseInsensitiveContains("insufficient balance")"#))
        XCTAssertTrue(transactions.contains(#"if message.localizedCaseInsensitiveContains("insufficient funds") { return L10n.tr("Not enough MON to pay for gas.") }"#))
        XCTAssertTrue(transactions.contains(##"message.range(of: #"custom error (0x[0-9a-fA-F]{8})"#, options: .regularExpression)"##))
        let rpc = try Self.source("Core/RPCClient.swift")
        XCTAssertTrue(rpc.contains(#"return message.contains("request limit") || message.contains("rate limit") || message.contains("too many requests")"#))
        XCTAssertTrue(rpc.contains(#"|| message.contains("per second") || message.contains("throughput")"#))
        XCTAssertTrue(rpc.contains(#"if message.contains("already known") || message.contains("known transaction") || message.contains("already imported") { return hash }"#))
        XCTAssertTrue(rpc.contains(#"if message.contains("nonce too low"), let known = try? await call("eth_getTransactionByHash""#))
        XCTAssertTrue(rpc.contains(#"message: "Missing response""#))
        XCTAssertTrue(try Self.source("Core/Multicall.swift").contains(#"message: "Call reverted""#))
        XCTAssertTrue(try Self.source("Chain/ERC20.swift").contains(#"return error.code == 3 || message.contains("revert") || message.contains("out of gas") || message.contains("gas required exceeds")"#))
        XCTAssertTrue(try Self.source("Chain/TokenTransfer.swift").contains(#"|| error.message.localizedCaseInsensitiveContains("insufficient funds")"#))
        let logs = try Self.source("Core/Logs.swift")
        XCTAssertTrue(logs.contains(#"let sizes = ["response size", "block range", "too large", "limited to a", "returned more than", "too many logs", "too many results"]"#))
        XCTAssertTrue(logs.contains(#"return message.contains("beyond current head") || message.contains("beyond the current head")"#))
        XCTAssertTrue(logs.contains(#"|| message.contains("not yet available on the node") || message.contains("errupstreamblockunavailable")"#))
        XCTAssertTrue(logs.contains(#"|| (error.code == -32014 && message.contains("block not available"))"#))
        let perpl = try Self.source("Services/Perpl/PerplTradeClient.swift")
        XCTAssertTrue(perpl.contains(#"public var isConnectionCap: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many connections") }"#))
        XCTAssertTrue(perpl.contains(#"public var isRateLimit: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many requests") }"#))
        let supabase = try Self.source("Services/Supabase/SupabaseClient.swift")
        XCTAssertTrue(supabase.contains(#"if reason.contains("nonce") { return L10n.tr("That sign-in expired or was already used. Please try again.") }"#))
        XCTAssertTrue(supabase.contains(#"return reason == "the verified email does not match" || reason == "no verified email on this Privy account""#))
        XCTAssertTrue(supabase.contains(#"(object["error"] as? String) == "Duplicate""#))
        XCTAssertTrue(try Self.source("Services/Swap/SwapTypes.swift").contains(#"message.range(of: "user rejected|user denied", options: [.regularExpression, .caseInsensitive])"#))
        XCTAssertTrue(try Self.source("Services/Aurora/AuroraIntents.swift").contains("body?.message ?? body?.error ??"), "Aurora's own message, as it sends it")
        XCTAssertTrue(try Self.source("Services/Swap/KuruFlowClient.swift").contains(#"Self.text(json["message"]) ?? Self.text(json["error"]) ??"#), "Kuru's own message")

        // The servers' English, as they send it, is still recognised with the app in French.
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "fr_FR")
        XCTAssertTrue(TransactionSender.isNonceUsed(RPCError(code: -32000, message: "Nonce too low: next nonce 5, tx nonce 4")))
        XCTAssertTrue(TransactionSender.isFundingInFlight(RPCError(code: -32003, message: "Signer had insufficient balance")))
        for message in ["insufficient funds for gas * price + value", "transaction underpriced", "max fee per gas less than block base fee",
                        "invalid chain id for signer", "oversized data"] {
            XCTAssertTrue(TransactionSender.isRefusal(RPCError(code: -32000, message: message)), message)
        }
        XCTAssertFalse(TransactionSender.isRefusal(RPCError(code: -32000, message: "upstream request timeout")))
        XCTAssertEqual(RevertReason.describe(RPCError(code: -32000, message: "insufficient funds for gas * price + value")), L10n.tr("Not enough MON to pay for gas."))
        XCTAssertTrue(RevertReason.describe(RPCError(code: 3, message: "execution reverted: custom error 0x12345678")).contains("0x12345678"))
        XCTAssertTrue(RPCClient.isRateLimited(RPCError(code: -32007, message: "50/second request limit reached")))
        XCTAssertTrue(RPCClient.refusesSize(RPCError(code: -32000, message: "query returned more than 10000 results")))
        XCTAssertTrue(RPCClient.refusesPastHead(RPCError(code: -32602, message: "block range extends beyond current head block")))
        XCTAssertTrue(RPCClient.refusesPastHead(RPCError(code: -32014, message: "block not available: block not found for eth_getLogs, requested toBlock 111739189 is not yet available on the node")))
        XCTAssertTrue(ERC20.isCallError(RPCError(code: -32000, message: "execution reverted")))
        XCTAssertTrue(ERC20.isCallError(RPCError(code: -32000, message: "Call reverted")), "Multicall's own failure reads as a node's")
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: -32000, message: "insufficient funds for transfer")))
        XCTAssertTrue(PerplClose(code: 1008, reason: "Too many connections").isConnectionCap)
        XCTAssertTrue(PerplClose(code: 1008, reason: "too many requests").isRateLimit)
        XCTAssertEqual(SupabaseError.signInRejected("invalid or expired nonce").errorDescription, L10n.tr("That sign-in expired or was already used. Please try again."))
        XCTAssertTrue(SupabaseClient.isDuplicateUpload(SupabaseError.http(400, #"{"statusCode":"409","error":"Duplicate"}"#)))
        XCTAssertEqual(SwapMath.describe(NSError(domain: "wallet", code: 4001, userInfo: [NSLocalizedDescriptionKey: "User rejected the request."])),
                       L10n.tr("Request cancelled in your wallet."))
    }

    // MARK: Plurals

    /// DyorKit's keys with a count that needs a plural (an `Int`, so `%lld`), as its catalog spells them. Each was a
    /// hand-built English plural or a counted noun; the catalog step adds every language's plural forms, English "one"
    /// included: without them a count of 1 reads "Collect 1 editions".
    static let pluralKeys = [
        "Collect %lld editions of %@", // a Moments collect's step (was `quantity == 1 ? "edition" : "editions"`)
        "Claim %lld Moments", // Claim All's step (was `count == 1 ? "Moment" : "Moments"`)
        "Take-profit can have at most %lld decimal places on %@.", // a trigger off the tick grid (was `decimal place\(… "s")`)
        "Stop-loss can have at most %lld decimal places on %@.",
        "Choose between 1 and %lld editions.", // a collect's quantity refused (the revert map's and `collectReason`'s)
        "A symbol can be at most %lld characters.", // the create forms
        "A name can be at most %lld characters.",
    ]

    /// Every listed plural key is still written in DyorKit's code, so the list stays the code's.
    func testThePluralKeysAreTheCodes() throws {
        let code = try Self.sources().map(\.text).joined(separator: "\n")
        let value = #"\\\(.+?\)"# // one interpolation, `\(…)`, nested parentheses included
        for key in Self.pluralKeys {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                .replacingOccurrences(of: "%lld", with: value).replacingOccurrences(of: "%@", with: value)
            XCTAssertNotNil(code.range(of: "\"" + pattern + "\"", options: .regularExpression), "not in DyorKit's code: \(key)")
        }
        XCTAssertFalse(code.contains(#"== 1 ? "edition""#))
        XCTAssertFalse(code.contains(#"== 1 ? "Moment""#))
        XCTAssertFalse(code.contains(#"decimal place\("#))
        XCTAssertFalse(code.contains("Choose between 1 and 20 editions."), "one key for the collect refusal, the revert map's too")
    }

    /// A count is the key's own argument, so one key covers 1 and many: what a count of 1 reads is the catalog's (here,
    /// under `swift test`, the key itself, since the command line copies the catalog uncompiled).
    func testACountIsTheKeysArgument() async throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")
        let btc = PerpMarket(id: 1, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                                mark: 95000, last: 95000, oracle: 95000, markTimestamp: 0, longOI: 0, shortOI: 0,
                                fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.stopLoss, decimals: 2).message(market: btc), "Stop-loss can have at most 2 decimal places on BTC.")
        XCTAssertEqual(PerplTriggerRules.Problem.offTick(.takeProfit, decimals: 1).message(market: btc), L10n.tr("Take-profit can have at most \(1) decimal places on \("BTC")."))

        let moments = MomentsService(rpc: RPCClient(url: URL(string: "http://127.0.0.1:1")!), addresses: .monadMainnet)
        let three = await moments.collectWithApprovalPlan(momentId: 1, quantity: 3, gross: 3, symbol: "SNAP")
        XCTAssertEqual(three.map(\.label), ["Approve USDC", "Collect 3 editions of SNAP"])
        let one = await moments.collectWithApprovalPlan(momentId: 1, quantity: 1, gross: 1, symbol: "SNAP")
        XCTAssertEqual(one.last?.label, L10n.tr("Collect \(1) editions of \("SNAP")"))
        let claims = await moments.claimAllPlan(momentIds: [1, 2])
        XCTAssertEqual(claims.first?.label, "Claim 2 Moments")
    }

    /// A plural key DyorKit's catalog carries has English "one" and "other" forms that differ. The catalogs are filled
    /// once, after every L2 lane merges: while DyorKit's is still empty this is skipped, except under the release gate
    /// (`DYORHQ_RELEASE_GATE=1`), where an empty catalog refuses the release.
    func testThePluralKeysHaveEnglishPluralForms() throws {
        let url = Self.root().appendingPathComponent("Resources/Localizable.xcstrings")
        let catalog = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = catalog["strings"] as? [String: Any] ?? [:]
        if strings.isEmpty {
            guard ProcessInfo.processInfo.environment["DYORHQ_RELEASE_GATE"] == "1" else {
                throw XCTSkip("DyorKit's catalog is not synced yet: the catalog step gives its \(Self.pluralKeys.count) plural keys their English one and other")
            }
            return XCTFail("REFUSING A RELEASE: DyorKit's catalog is empty, so English reads \"Collect 1 editions of …\"")
        }
        for key in Self.pluralKeys {
            guard let entry = strings[key] as? [String: Any] else { XCTFail("not in DyorKit's catalog: \(key)"); continue }
            let english = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any] ?? [:]
            let substitutions = (english["substitutions"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
            let plurals = ([english] + substitutions).compactMap { ($0["variations"] as? [String: Any])?["plural"] as? [String: Any] }
            func value(_ forms: [String: Any], _ form: String) -> String {
                (((forms[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
            }
            let complete = plurals.contains { !value($0, "one").isEmpty && !value($0, "other").isEmpty && value($0, "one") != value($0, "other") }
            XCTAssertTrue(complete, "no English one and other plural forms in DyorKit's catalog: \(key)")
        }
    }

    /// A close the app sent that Perpl took but didn't report in time is said of the close (p4 spec #26): check the
    /// positions before closing again — never the order's "before placing it again". The order keeps its own sentences.
    func testAnUnconfirmedCloseIsSaidOfTheClose() {
        let c = PerplOutcomeText.Context(asset: "BTC", priceDecimals: 1, lotDecimals: 5, requestedSize: 0.002, limitPrice: nil, isMarket: true,
                                         reducesPosition: true, slippageBps: 100, acknowledged: true)
        let expected: [(PerplOrderOutcome.Unconfirmed, String)] = [
            (.timedOut, "Perpl accepted the close for forwarding but hasn't reported what happened to it yet. Your positions are reloading: check them before closing again."),
            (.connectionLost, "The connection to Perpl dropped before it reported the close's result. Your positions are reloading: check them before closing again."),
            (.foreignReport, "Perpl reported a different order under this close's request number, so its result can't be shown. Check Positions before closing again."),
        ]
        for (why, sentence) in expected {
            let close = PerplOutcomeText.close(.unconfirmed(why), c)
            XCTAssertEqual(close.detail, sentence)
            XCTAssertFalse(close.detail?.contains("placing it again") ?? true)
            XCTAssertTrue(PerplOutcomeText.order(.unconfirmed(why), c).detail?.contains("placing it again") ?? false, "the order keeps its own")
        }
        XCTAssertEqual(PerplOutcomeText.notClosedHeadline, "Not closed")
    }
}
