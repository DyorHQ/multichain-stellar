import XCTest
@testable import DyorKit

/// Layouts that broke in a language QA of build 18 (2026-10-07), read from the app's sources: a Moment's page cut at the
/// left, a launch page's time axis drawn as a strip of a hundred labels, chart labels left in the previous language, and a
/// DyorHQ coin's badge cut before its brand.
final class ScreenLayoutTests: XCTestCase {
    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// A Moment's art fills a box the row sizes. Drawn straight in a flexible frame, a filled image wider than its height
    /// allows widened the whole header past the row, cutting off the name, the badge and the place at the left.
    func testAMomentsArtNeverWidensItsHeader() throws {
        for (file, creator) in [("Moments/MomentDetailView.swift", "info.moment.creator"), ("Moments/RetiredMomentDetailView.swift", "m.creator")] {
            let source = Self.squeezed(try DocsLinksTests.appSource(file))
            XCTAssertTrue(source.contains("Color(.tertiarySystemFill) .frame(height: 240) .overlay { MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: \(creator)) }"), file)
            XCTAssertFalse(source.contains("MomentArtwork(provenance: info.provenance, symbol: info.symbol, creator: \(creator)) .frame(maxWidth: .infinity)"), file)
        }
    }

    /// The price chart's time axis: a few marks the span decides, labelled in hours for a day and in days beyond, in the
    /// app's language read from the environment, so a change of language draws them again; the "no trades" note only while
    /// the curve trades, and only once its last 24 hours were read in full (a read that stopped short or failed isn't "no
    /// trades"), and the 24h volume "—" until they were read, a minimum ("+") while they were read in part.
    func testThePriceChartsTimeAxis() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let chart = try XCTUnwrap(home.range(of: "struct PriceChart: View {")).upperBound
        let end = try XCTUnwrap(home.range(of: "struct HomeHeader: View {", range: chart..<home.endIndex)).lowerBound
        let body = Self.squeezed(String(home[chart..<end]))
        XCTAssertTrue(body.contains("@Environment(\\.locale) private var locale"))
        XCTAssertTrue(body.contains("last.timeIntervalSince(first) > 36 * 3600"))
        XCTAssertTrue(body.contains("return Date.FormatStyle.dateTime.hour().locale(locale)"))
        XCTAssertTrue(body.contains("return Date.FormatStyle.dateTime.month(.abbreviated).day().locale(locale)"))
        XCTAssertTrue(body.contains("AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: timeFormat, centered: true) }"))
        XCTAssertFalse(body.contains(".stride(by: .hour"), "a mark every few hours over weeks is a hundred labels")

        let launch = Self.squeezed(try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift"))
        XCTAssertTrue(launch.contains("if trades.isEmpty, !loadingTrades, tradesRead, tradesComplete, !tradesUnread, launch.phase == .bonding { Paragraph(\"No trades yet"))
        XCTAssertTrue(launch.contains("guard tradesRead else { return \"—\" }"))
        XCTAssertTrue(launch.contains("return tradesComplete && !tradesUnread ? value : value + \"+\""))
        XCTAssertTrue(launch.contains("stat(\"24h Volume\", volume24Text)"))
        XCTAssertTrue(launch.contains("stat(\"Holders\", holdersText)"))
    }

    /// A DyorHQ coin's badge shrinks a little before it truncates: its point is the whole name.
    func testATokensBadgeShrinksBeforeItTruncates() throws {
        let components = try DocsLinksTests.appSource("Design/Components.swift")
        let view = try XCTUnwrap(components.range(of: "struct TokenBadgeView: View {")).upperBound
        let end = try XCTUnwrap(components.range(of: "struct UnverifiedBadge: View {", range: view..<components.endIndex)).lowerBound
        let body = Self.squeezed(String(components[view..<end]))
        XCTAssertTrue(body.contains(".lineLimit(1) .minimumScaleFactor(0.8)"))
    }
}
