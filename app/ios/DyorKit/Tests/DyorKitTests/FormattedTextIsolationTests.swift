import XCTest
@testable import DyorKit

/// Display strings and amount fields stay apart: no formatted price or value is ever parsed, written into an amount
/// field or copied (the pasteboard holds addresses only), and every dollar on screen goes through `PriceFormat`.
final class FormattedTextIsolationTests: XCTestCase {
    /// What makes display text: the app's formatters and Foundation's localized ones.
    private static let displayFormatters = ["PriceFormat.", "USDText", "NumberStyle.", "MomentsFormat.", ".formatted(", "String(format:", "NumberFormatter("]
    /// The amount fields' text, as the app names it.
    private static let fieldTexts = ["amountText", "initialBuyText", "priceText", "sizeText", "limitText", "takeProfitText", "stopLossText", "targetText", "amount"]

    static func appSources() throws -> [(path: String, text: String)] {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() }
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        var out: [(String, String)] = []
        let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            out.append((String(url.path.dropFirst(app.path.count + 1)), try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 50)
        return out.sorted { $0.0 < $1.0 }
    }

    private func lines(_ sources: [(path: String, text: String)], matching pattern: String) throws -> [(path: String, line: String)] {
        let regex = try NSRegularExpression(pattern: pattern)
        return sources.flatMap { source in
            source.text.components(separatedBy: "\n").filter { line in
                regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            }.map { (source.path, $0) }
        }
    }

    /// `Amount.parse`, `Amount.fieldNumber` and `PriceAlertTarget.parse` read only a field's own text (a bare name),
    /// never anything built by a display formatter.
    func testNoDisplayStringIsParsed() throws {
        let sources = try Self.appSources()
        let parses = try lines(sources, matching: #"(Amount\.parse|fieldNumber|PriceAlertTarget\.parse)\("#)
        XCTAssertGreaterThanOrEqual(parses.count, 9)
        let argument = try NSRegularExpression(pattern: #"(Amount\.parse|fieldNumber|PriceAlertTarget\.parse)\(([^,)]*)"#)
        for (path, line) in parses {
            for formatter in Self.displayFormatters { XCTAssertFalse(line.contains(formatter), "\(path): \(line)") }
            for match in argument.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                let text = (line as NSString).substring(with: match.range(at: 2))
                XCTAssertNotNil(text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression), "\(path): parses `\(text)`, not a field's text")
            }
        }
    }

    /// Max, the % buttons and quotes write fields with the exact writers (`Amount.exact`, `roundedDown`, the Perps
    /// tickets' POSIX `plainSize` / `plainAmount`), never with a display formatter.
    func testNoDisplayStringIsWrittenIntoAField() throws {
        let sources = try Self.appSources()
        let names = Self.fieldTexts.joined(separator: "|")
        let writes = try lines(sources, matching: #"(?<!let )(?<!var )\b(\#(names)) = [^=]"#).filter { !$0.line.contains("@State") }
        XCTAssertGreaterThanOrEqual(writes.count, 20)
        for (path, line) in writes {
            for formatter in Self.displayFormatters { XCTAssertFalse(line.contains(formatter), "\(path): \(line)") }
        }
        let perps = try XCTUnwrap(sources.first { $0.path == "Perps/PerpTradeView.swift" }).text
        for writer in ["private func plainSize(_ value: Double) -> String {", "private func plainAmount(_ value: Double) -> String {"] {
            let start = try XCTUnwrap(perps.range(of: writer), writer)
            let end = try XCTUnwrap(perps.range(of: "\n    }\n", range: start.upperBound..<perps.endIndex))
            let body = String(perps[start.upperBound..<end.lowerBound])
            for formatter in ["PriceFormat.", "USDText", "NumberStyle.", "MomentsFormat.", ".formatted("] { XCTAssertFalse(body.contains(formatter), writer) }
            XCTAssertTrue(body.contains("en_US_POSIX") || body.contains("String(format: \"%.2f\""), writer)
        }
    }

    /// The pasteboard gets addresses (and one clear, and the export screen's expiring key), never a formatted number.
    func testPasteboardWritesAreAddressesOnly() throws {
        let sources = try Self.appSources()
        let writes = try lines(sources, matching: #"UIPasteboard\.general\.(string = |setItems\()"#)
        var sourcesWritten: [String] = []
        for (path, line) in writes {
            for formatter in Self.displayFormatters { XCTAssertFalse(line.contains(formatter), "\(path): \(line)") }
            if let range = line.range(of: "UIPasteboard.general.string = ") {
                sourcesWritten.append(String(line[range.upperBound...].prefix { $0 != " " && $0 != "}" }))
            } else {
                XCTAssertEqual(path, "Wallet/WalletExportView.swift", line)
                sourcesWritten.append("setItems")
            }
        }
        XCTAssertEqual(Set(sourcesWritten), ["address.checksummed", "account.address.checksummed", "\"\"", "setItems"], "\(sourcesWritten)")
        let export = try XCTUnwrap(sources.first { $0.path == "Wallet/WalletExportView.swift" }).text
        XCTAssertTrue(export.contains("[[UTType.utf8PlainText.identifier: key]]"))
    }

    /// Every dollar on screen is `PriceFormat`'s: no region-styled currency ("US$", "1 234,50 $US") is left.
    func testNoRegionCurrencyFormatting() throws {
        for (path, text) in try Self.appSources() {
            XCTAssertFalse(text.contains(".currency(code:"), path)
            XCTAssertFalse(text.contains("\"US$\""), path)
        }
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        sources.appendPathComponent("Sources")
        let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var read = 0
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(".currency(code:"), url.lastPathComponent)
            read += 1
        }
        XCTAssertGreaterThan(read, 20)
    }

    /// The price lines that can show a dust price give VoiceOver the spoken form, and the price charts label their
    /// axis with `PriceFormat.axis`.
    func testPricesAreSpokenAndChartsLabelled() throws {
        let components = try DocsLinksTests.appSource("Design/Components.swift")
        XCTAssertTrue(components.contains("init(price: Double?, font: Font = .body)"))
        XCTAssertTrue(components.contains("init(value: Double?, font: Font = .body)"))
        XCTAssertTrue(components.contains(".accessibilityLabel(isPrice ? PriceFormat.spoken(dollars) : PriceFormat.usdValue(dollars))"))
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        XCTAssertTrue(home.contains("Text(PriceFormat.axis(price, span: domain.upperBound - domain.lowerBound))"))
        XCTAssertFalse(home.contains("AxisValueLabel() }"), "no default axis label, which reads 0 for every dust tick")
        for price in ["USDText(price: row.usd, font: .subheadline.weight(.medium))", "USDText(price: row.usd, font: .caption2)",
                      "USDText(price: price, font: .system(.largeTitle, design: .rounded).weight(.semibold))"] {
            XCTAssertTrue(home.contains(price), price)
        }
        XCTAssertFalse(home.contains("USDText(value: row.usd"), "a unit price is a price")
        let launch = try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift")
        XCTAssertTrue(launch.contains("Text(PriceFormat.usdPrice(priceUSD)).font(.footnote).foregroundStyle(.secondary).monospacedDigit().accessibilityLabel(PriceFormat.spoken(priceUSD))"))
        let moments = try DocsLinksTests.appSource("Moments/MomentDetailView.swift")
        XCTAssertEqual(moments.components(separatedBy: "MomentsFormat.coinPriceSpoken(").count - 1, 3, "every coin price shown is spoken")
        let format = try DocsLinksTests.appSource("Moments/MomentsUI.swift")
        XCTAssertTrue(format.contains("PriceFormat.usdValue(value, compact: true)"), "Moments' compact dollars: \"$\", never \"US$\"")
    }
}
