import XCTest
@testable import DyorKit

/// What a token's page and Home's rows say about a DyorHQ coin's price: "vs MON 0.00%" under the price, "New" for a coin
/// younger than 24 hours, "Not trading yet" for a Moment still collecting (no price, no chart), and one line saying where
/// the price comes from. Every other token shows none of these.
final class TokenPagePriceTests: XCTestCase {
    /// "vs MON": a DyorHQ coin's change in its pair asset, 0.00% when only MON's dollar price moved; nothing for any other
    /// token, nor without the day-ago read.
    func testVsPairLine() {
        XCTAssertEqual(PriceInfo(usd: 6.13e-8, change24h: -2.4, source: "DyorHQ curve", pairChange: 0, pairSymbol: "MON").pairChangeText, "vs MON 0.00%")
        XCTAssertEqual(PriceInfo(usd: 6.13e-8, change24h: -2.4, source: "DyorHQ curve", pairChange: 0.004, pairSymbol: "MON").pairChangeText, "vs MON 0.00%")
        XCTAssertEqual(PriceInfo(usd: 1, change24h: 5, source: "Uniswap v4", pairChange: 12.345, pairSymbol: "USDC").pairChangeText, "vs USDC +12.35%")
        XCTAssertEqual(PriceInfo(usd: 1, change24h: -5, source: "Monday Trade", pairChange: -3.2, pairSymbol: "MON").pairChangeText, "vs MON −3.20%")
        XCTAssertNil(PriceInfo(usd: 0.03, change24h: 1, source: "Uniswap v4").pairChangeText, "MON itself")
        XCTAssertNil(PriceInfo(usd: 1, change24h: nil, source: "DyorHQ curve", pairChange: nil, pairSymbol: "MON", isNew: true).pairChangeText, "a new coin")
        XCTAssertNil(PriceInfo(usd: 1, change24h: nil, source: "DyorHQ curve", pairChange: .nan, pairSymbol: "MON").pairChangeText)
    }

    /// One line for where a DyorHQ coin's price comes from, from its venue's label; none for a token priced from the
    /// deepest pool found, whatever that pool's label.
    func testPriceSourceLine() {
        let lines: [(String, String)] = [(DyorListing.curveLabel, "Priced from its DyorHQ curve"), (DyorListing.v4Label, "Priced from its Uniswap v4 pool"),
                                         (DyorListing.mondayLabel, "Priced from its Monday Trade pool"), (DyorListing.momentLabel, "Priced from its Moment pool")]
        for (label, line) in lines {
            XCTAssertEqual(PriceInfo(usd: 1, change24h: 0, source: label, pairChange: 0, pairSymbol: "MON").sourceLine, line, label)
            XCTAssertNil(PriceInfo(usd: 1, change24h: 0, source: label).sourceLine, "\(label): not a DyorHQ venue")
        }
        XCTAssertEqual(lines.map(\.0), ["DyorHQ curve", "Uniswap v4", "Monday Trade", "DyorHQ Moment pool"], "the labels `DyorListing` prices carry")
        XCTAssertNil(PriceInfo(usd: 1, change24h: 0, source: "DyorHQ", pairChange: 0, pairSymbol: "USDC").sourceLine, "no market, no line")
        XCTAssertNil(PriceInfo(usd: 1, change24h: 0, source: "Uniswap v3").sourceLine)
    }

    /// The page and the rows say it: under the price "vs MON" and the source line, "New" in place of the change, and for
    /// a Moment still collecting "Not trading yet" with no price, chart or value; a row with no price shows "—", never
    /// "$0.00", and a token Home didn't price is priced by its page, a Moment Home saw collecting included, whose page's
    /// own read then decides.
    func testThePageAndTheRowsSayIt() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let page = try XCTUnwrap(home.range(of: "struct TokenDetailView: View {")).upperBound
        let pageEnd = try XCTUnwrap(home.range(of: "struct PriceChart: View {")).lowerBound
        let body = String(home[page..<pageEnd])
        for part in ["if info?.isNew == true { NewBadge() } else { ChangeBadge(value: change) }",
                     "if !notTradingYet, let pairChange = info?.pairChangeText {", "if !notTradingYet, let source = info?.sourceLine {",
                     "Text(\"Not trading yet\").font(.system(.title2, design: .rounded).weight(.semibold))",
                     "if !notTradingYet { history = (try? await env.prices.history(for: row.token, points: 48)) ?? [] }",
                     "loaded = (try? await env.prices.prices(for: [row.token]))?[row.token.address]",
                     "loadedNotTrading = await env.prices.notTradingYet([row.token]).contains(row.token.address)",
                     "private var notTradingYet: Bool { loadedNotTrading ?? row.notTradingYet }",
                     "@State private var loadedNotTrading: Bool?"] {
            XCTAssertTrue(body.contains(part), part)
        }
        let reprice = try XCTUnwrap(body.range(of: "            if row.usd == nil {\n                loaded = (try? await env.prices.prices(for: [row.token]))"))
        XCTAssertLessThan(reprice.lowerBound, try XCTUnwrap(body.range(of: "if !notTradingYet { history =")).lowerBound, "the page reads before it decides on a chart")
        XCTAssertFalse(body.contains("!row.notTradingYet"), "a Moment Home saw collecting is read again by its page")
        let chart = try XCTUnwrap(body.range(of: "PriceChart(points: history"))
        let notTrading = try XCTUnwrap(body.range(of: "if notTradingYet {\n                        Paragraph(\"Its Moment hasn't graduated yet"))
        XCTAssertLessThan(notTrading.upperBound, chart.lowerBound, "no chart while it collects")
        // Read with the prices, and only when they were: none without them.
        XCTAssertTrue(home.contains("let map = try await env.prices.prices(for: tokens)\n            return .prices(map, nil, await env.prices.notTradingYet(tokens))"))
        XCTAssertTrue(home.contains("return .prices(nil, error, [])"))
        XCTAssertTrue(home.contains("let info = priceMap[token.address].flatMap { DyorPrice.valid($0.usd) != nil ? $0 : nil }"))
        XCTAssertTrue(home.contains("info: info, notTradingYet: notTrading.contains(token.address))"))
        XCTAssertTrue(home.contains("if row.notTradingYet {\n                // A Moment still collecting"))
    }
}
