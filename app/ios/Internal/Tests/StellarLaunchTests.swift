// The Stellar launch page and Create (docs/DESIGN-stellar-parity.md §8.10.2, §8.10.3; docs/DESIGN-stellar-contracts-v2.md
// §21): the phase each v2 status reads as, the holders' minimum and its footnote, the price chart's points, the create
// screen's name, description, links, ticker, XLM shortage and durations, and the source rules the Lite launch screens keep.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import XCTest

@MainActor
final class StellarLaunchTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static let soroswap = #"{"id": 0, "kind": "Soroswap", "name": "Soroswap", "executor": "CAAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQC526", "enabled": true, "feeFraction": 0}"#

    /// launchpad-v2's `status` for a launch in `phase`, delayed or not.
    private func status(_ phase: String, stuck: Bool = false) throws -> StellarLaunchStatusV2 {
        try decode(StellarLaunchStatusV2.self, """
            {"token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5", "phase": "\(phase)", "completedAt": null, "stuck": \(stuck),
             "stuckSince": null, "markStuckAt": null, "fallbackAt": null, "rescueAdminAt": null, "rescuePublicAt": null,
             "venue": \(Self.soroswap), "fallback": \(Self.soroswap), "venueLocked": false, "fallbackAllowed": false, "pool": null,
             "graduatedVenue": null, "refund": null, "failure": null,
             "actions": {"buy": false, "sell": false, "graduate": false, "graduateFallback": false, "markStuck": false, "rescue": false, "refund": false}}
            """)
    }

    /// launchpad-v2's terms for an XLM launch on Soroswap, venue-locked or not.
    private static func terms(venueLocked: Bool = false, fallbackDelay: Int = 3600, lockedFallback: Int = 86400) -> String {
        """
        {"supply": "10000000000000000", "feeBps": 100, "protocolShareBps": 5000, "maxCreatorFeeBps": 1000, "snipeSchedule": [9800],
         "snipeStepSecs": 5, "launchFee": "100000000", "feeAsset": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC",
         "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC", "phantom": "20000000000", "threshold": "43245553200",
         "venue": \(soroswap), "fallback": \(soroswap), "venueLocked": \(venueLocked),
         "locker": "CABAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAFNSZ", "tokenWasmHash": "02",
         "durations": {"grace": 3600, "fallbackDelay": \(fallbackDelay), "rescueAdmin": 604800, "rescuePublic": 2592000, "lockedFallback": \(lockedFallback),
                       "takeoverDelay": 259200, "takeoverWindow": 259200, "timelock": 172800, "timelockWindow": 604800, "harvestInterval": 3600}}
        """
    }

    // MARK: - The launch page

    func testEachV2PhaseReadsAsMonadsSections() throws {
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("curve"), coin: nil), .bonding)
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("completed"), coin: nil), .graduating)
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("completed", stuck: true), coin: nil), .delayed)
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("graduated"), coin: nil), .graduated)
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("rescued"), coin: nil), .refund, "a rescued launch is in refund mode")
        XCTAssertEqual(StellarLaunchDetailView.phase(nil, coin: nil), .bonding, "a retired launch with no row yet")
    }

    func testHoldersShowAMinimumWithItsFootnoteWhenIncomplete() {
        let incomplete = StellarLaunchDetailView.holders(5, complete: false)
        XCTAssertEqual(incomplete.text, "5+")
        XCTAssertTrue(incomplete.incomplete, "the footnote says there may be more holders")
        let complete = StellarLaunchDetailView.holders(5, complete: true)
        XCTAssertEqual(complete.text, "5")
        XCTAssertFalse(complete.incomplete)
        let unread = StellarLaunchDetailView.holders(nil, complete: false)
        XCTAssertEqual(unread.text, "—", "unread, never 0")
        XCTAssertFalse(unread.incomplete)
    }

    func testThePriceChartIsInDollarsAndEndsOnTheLivePrice() throws {
        let points = try decode([StellarLaunchDetail.Point].self, #"[{"t": "2026-10-15T10:00:00.000Z", "price": "0.000002"}, {"t": "2026-10-15T11:00:00Z", "price": "0.000004"}]"#)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let series = StellarLaunchDetailView.priceSeries(points, current: 0.000005, launchedAt: nil, quoteUSD: 0.25, now: now)
        XCTAssertEqual(series.map(\.usd), [0.0000005, 0.000001, 0.00000125], "each point × the quote's dollar price")
        XCTAssertEqual(series.last?.time, now)
        XCTAssertEqual(Set(series.map(\.block)).count, 3)
        // No trades: a flat line from the launch to now.
        let launched = Date(timeIntervalSince1970: 1_700_000_000)
        let flat = StellarLaunchDetailView.priceSeries([], current: 0.000005, launchedAt: launched, quoteUSD: 0.25, now: now)
        XCTAssertEqual(flat.map(\.time), [launched, now])
        XCTAssertEqual(flat.map(\.usd), [0.00000125, 0.00000125])
        XCTAssertEqual(StellarLaunchDetailView.priceSeries([], current: nil, launchedAt: launched, quoteUSD: 0.25), [], "no price, no line")
    }

    // MARK: - Create

    func testANameIsCutToThirtyTwoBytesOnWholeCharacters() {
        XCTAssertEqual(StellarCreateLaunchView.fitted(String(repeating: "a", count: 40), bytes: 32).utf8.count, 32)
        let korean = StellarCreateLaunchView.fitted(String(repeating: "가", count: 20), bytes: 32)
        XCTAssertEqual(korean, String(repeating: "가", count: 10), "three bytes each: ten fit, never half of one")
        XCTAssertEqual(StellarCreateLaunchView.fitted("E2E Cat", bytes: 32), "E2E Cat")
    }

    func testADescriptionIsCutToFiveHundredScalarsAsTheServerCounts() {
        let thumbs = "👍🏽" // one character, two scalars
        XCTAssertEqual(StellarCreateLaunchView.fitted(String(repeating: thumbs, count: 251), scalars: 500), String(repeating: thumbs, count: 250))
        let accented = "e\u{301}" // é as a letter and its accent: two scalars
        XCTAssertEqual(StellarCreateLaunchView.fitted(String(repeating: accented, count: 3), scalars: 5), String(repeating: accented, count: 2),
                       "never half of a character")
        XCTAssertEqual(StellarCreateLaunchView.fitted(String(repeating: "a", count: 500), scalars: 500).count, 500)
    }

    func testLinksAreRefusedOnTheFormAsTheServerRefusesThem() {
        typealias Create = StellarCreateLaunchView
        XCTAssertTrue(Create.linkAccepted("", .x), "a link is optional")
        XCTAssertTrue(Create.linkAccepted(" https://dyorhq.fun ", .website))
        XCTAssertFalse(Create.linkAccepted("http://dyorhq.fun", .website), "https only")
        XCTAssertFalse(Create.linkAccepted("dyorhq.fun", .website))
        XCTAssertFalse(Create.linkAccepted("https://user:secret@dyorhq.fun", .website))
        XCTAssertFalse(Create.linkAccepted("https://dyorhq.fun/" + String(repeating: "a", count: 200), .website), "at most 200 characters")
        XCTAssertTrue(Create.linkAccepted("https://x.com/dyorhq", .x))
        XCTAssertTrue(Create.linkAccepted("HTTPS://Twitter.com/dyorhq", .x))
        XCTAssertFalse(Create.linkAccepted("@dyorhq", .x))
        XCTAssertFalse(Create.linkAccepted("https://x.com/", .x), "a profile, not the site")
        XCTAssertFalse(Create.linkAccepted("https://example.com/x.com", .x))
        XCTAssertTrue(Create.linkAccepted("https://t.me/dyorhq", .telegram))
        XCTAssertFalse(Create.linkAccepted("https://telegram.me/dyorhq", .telegram))
    }

    func testTickersAreTwoToTenASCIILettersOrDigits() {
        XCTAssertEqual(StellarTickerV2.normalized("ecat"), "ECAT")
        XCTAssertNil(StellarTickerV2.normalized("É"))
        XCTAssertNil(StellarTickerV2.normalized("ÉCAT"), "refused on the phone before any review")
        XCTAssertNil(StellarTickerV2.normalized("A"))
        XCTAssertNil(StellarTickerV2.normalized("ABCDEFGHIJK"))
    }

    func testTheXLMALaunchIsShortOfIsSaidBeforeTheReview() throws {
        func preview(spendable: String, shortfall: String?, quoteBalance: String = "0") throws -> StellarLaunchPreviewV2 {
            try decode(StellarLaunchPreviewV2.self, """
                {"quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"}, "venue": \(Self.soroswap),
                 "terms": \(Self.terms()), "launchFee": {"asset": "XLM", "amount": "100000000", "booked": true, "to": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW"},
                 "xlm": {"balance": "50000000", "minBalance": "10000000", "sellingLiabilities": "0", "launchFee": "100000000", "fees": "4650100",
                         "buffer": "5000000", "spendable": "\(spendable)"},
                 "quoteBalance": "\(quoteBalance)", "maxInitialBuy": "\(max(0, Int64(spendable) ?? 0))", "shortfall": \(shortfall.map { "\"\($0)\"" } ?? "null")}
                """)
        }
        // 5 XLM: short of the fee before any buy; an XLM developer buy adds to what is missing.
        let short = try preview(spendable: "-69650100", shortfall: "69650100")
        XCTAssertEqual(StellarCreateLaunchView.shortage(short, initialBuy: 0, quoteIsXLM: true), .xlm(69_650_100))
        XCTAssertEqual(StellarCreateLaunchView.shortage(short, initialBuy: 10_000_000, quoteIsXLM: true), .xlm(79_650_100))
        // Enough for the launch, not for the whole buy: only the part above Max is missing.
        let fits = try preview(spendable: "610349900", shortfall: nil)
        XCTAssertNil(StellarCreateLaunchView.shortage(fits, initialBuy: 610_349_900, quoteIsXLM: true))
        XCTAssertEqual(StellarCreateLaunchView.shortage(fits, initialBuy: 700_000_000, quoteIsXLM: true), .xlm(89_650_100))
        // A USDC buy is held to the USDC balance.
        let usdc = try preview(spendable: "610349900", shortfall: nil, quoteBalance: "20000000")
        XCTAssertEqual(StellarCreateLaunchView.shortage(usdc, initialBuy: 30_000_000, quoteIsXLM: false), .quote(balance: 20_000_000))
        XCTAssertNil(StellarCreateLaunchView.shortage(usdc, initialBuy: 20_000_000, quoteIsXLM: false))
    }

    func testTheReviewsFallbackWaitsForAVenueLockedLaunchsLockedFallback() throws {
        let open = try decode(StellarLaunchTermsV2.self, Self.terms())
        XCTAssertEqual(StellarCreateLaunchView.fallbackDelay(open), 3600)
        let locked = try decode(StellarLaunchTermsV2.self, Self.terms(venueLocked: true))
        XCTAssertEqual(StellarCreateLaunchView.fallbackDelay(locked), 86400, "no sooner than lockedFallback")
        let lockedLater = try decode(StellarLaunchTermsV2.self, Self.terms(venueLocked: true, fallbackDelay: 172_800))
        XCTAssertEqual(StellarCreateLaunchView.fallbackDelay(lockedLater), 172_800, "and never before fallbackDelay")
    }

    func testTheReviewWritesDurationsInWords() {
        let saved = L10n.locale
        L10n.locale = Locale(identifier: "en")
        defer { L10n.locale = saved }
        XCTAssertEqual(StellarCreateLaunchView.duration(3600), "1 hour")
        XCTAssertEqual(StellarCreateLaunchView.duration(2_592_000), "30 days")
        XCTAssertEqual(StellarCreateLaunchView.duration(129_600), "1 day, 12 hours")
    }

    // MARK: - Source rules

    /// The Launch screens' sources (ios/DyorHQ/Lite/Launch), read from this checkout.
    private func launchSources() throws -> [(name: String, text: String)] {
        var folder = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { folder.deleteLastPathComponent() } // StellarLaunchTests.swift → Tests → Internal → ios
        folder.appendPathComponent("DyorHQ/Lite/Launch")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertTrue(names.contains("StellarLaunchDetailView.swift") && names.contains("StellarCreateLaunchView.swift"))
        return try names.map { ($0, try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8)) }
    }

    /// DyorKit's AppCoinValueTests rule: a coin's value is never read from `launch.price` or `launch.marketCap`.
    func testNoCoinIsValuedThroughLaunchPriceOrMarketCap() throws {
        let rule = try NSRegularExpression(pattern: #"priceNumber|LaunchpadMath\.marketCap\(|\b(launch|\$0|\$1)\.(price|marketCap)\b"#)
        for (name, text) in try launchSources() {
            XCTAssertNil(rule.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), name)
        }
    }

    func testThePageAndCreateAreNoLongerSeams() throws {
        for (name, text) in try launchSources() where ["StellarLaunchDetailView.swift", "StellarCreateLaunchView.swift"].contains(name) {
            XCTAssertFalse(text.contains("SEAM("), name)
            XCTAssertFalse(text.contains("LiteLegacyScreens"), name)
        }
    }
}
