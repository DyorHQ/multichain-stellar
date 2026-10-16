// The Stellar launch page and Create (docs/DESIGN-stellar-parity.md §8.10.2, §8.10.3; docs/DESIGN-stellar-contracts-v2.md
// §21): the phase each v2 status reads as, the holders' minimum and its footnote, the price chart's points (no stray
// one) and its distinct time labels, a new coin's page waiting for its row, the create screen's name, description, links,
// ticker, XLM shortage, preview (read again for another account or once XLM is added), Advanced's footer and durations,
// Done opening the new coin's page, actions waiting for the coin's row, no phase shown before anything is read, a retired
// launch known from its row, and the source rules the Lite launch screens keep.
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

    /// launchpad-v2's `status` for a launch in `phase`, delayed or not, its graduation open or not.
    private func status(_ phase: String, stuck: Bool = false, graduate: Bool = false) throws -> StellarLaunchStatusV2 {
        try decode(StellarLaunchStatusV2.self, """
            {"token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5", "phase": "\(phase)", "completedAt": null, "stuck": \(stuck),
             "stuckSince": null, "markStuckAt": null, "fallbackAt": null, "rescueAdminAt": null, "rescuePublicAt": null,
             "venue": \(Self.soroswap), "fallback": \(Self.soroswap), "venueLocked": false, "fallbackAllowed": false, "pool": null,
             "graduatedVenue": null, "refund": null, "failure": null,
             "actions": {"buy": false, "sell": false, "graduate": \(graduate), "graduateFallback": false, "markStuck": false, "rescue": false, "refund": false}}
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
        XCTAssertNil(StellarLaunchDetailView.phase(nil, coin: nil), "neither read yet: no phase, ticket or graduation shown as fact")
    }

    /// A launch's board row: on its curve, full, or graduated, on launchpad `generation`.
    private func row(completed: Bool = false, graduated: Bool = false, generation: Int? = 2) throws -> StellarLaunch {
        try decode(StellarLaunch.self, """
            {"token": "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5", "creator": "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
             "quote": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC", "name": "E2E Cat", "symbol": "ECAT", "uri": "",
             "supply": "10000000000000000", "quoteReserve": "0", "tokenReserve": "0", "realQuote": "0", "threshold": "43245553200",
             "progress": 0, "completed": \(completed), "graduated": \(graduated), "volume": "0", "trades": 0, "createdAt": "2026-10-15T10:00:00Z",
             "generation": \(generation.map(String.init) ?? "null")}
            """)
    }

    func testARowReadBeforeTheStateGivesItsPhase() throws {
        XCTAssertEqual(StellarLaunchDetailView.phase(nil, coin: try row()), .bonding)
        XCTAssertEqual(StellarLaunchDetailView.phase(nil, coin: try row(completed: true)), .graduating)
        XCTAssertEqual(StellarLaunchDetailView.phase(nil, coin: try row(completed: true, graduated: true)), .graduated)
        XCTAssertEqual(StellarLaunchDetailView.phase(try status("rescued"), coin: try row(completed: true)), .refund, "the state, once read, says")
    }

    func testARetiredLaunchIsKnownFromItsRowOrOnceTheStateIsRead() throws {
        typealias Page = StellarLaunchDetailView
        XCTAssertTrue(Page.isRetired(generation: 1, stateRead: false, state: nil), "the row's generation says before the state is read")
        XCTAssertFalse(Page.isRetired(generation: 2, stateRead: true, state: nil))
        XCTAssertFalse(Page.isRetired(generation: nil, stateRead: false, state: nil), "unread, or its read failed: not known, so not v1's")
        XCTAssertTrue(Page.isRetired(generation: nil, stateRead: true, state: nil), "launchpad v2 doesn't know it")
    }

    func testGraduateWaitsForLaunchpadV2sState() throws {
        typealias Page = StellarLaunchDetailView
        XCTAssertFalse(Page.offersGraduate(retired: false, status: nil), "the state unread or its read failed: v1 or v2 isn't known")
        XCTAssertFalse(Page.offersGraduate(retired: false, status: try status("completed")), "v2 says its graduation isn't open")
        XCTAssertTrue(Page.offersGraduate(retired: false, status: try status("completed", graduate: true)))
        XCTAssertTrue(Page.offersGraduate(retired: true, status: nil), "a retired launch graduates on v1")
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

    func testNoActionOpensBeforeTheCoinsRowIsRead() {
        XCTAssertFalse(StellarLaunchDetailView.canAct(canSign: true, symbol: ""), "no ticker for the review, the activity or the notification")
        XCTAssertFalse(StellarLaunchDetailView.canAct(canSign: false, symbol: "ECAT"))
        XCTAssertTrue(StellarLaunchDetailView.canAct(canSign: true, symbol: "ECAT"))
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

    /// The line has no stray point: the launch's opening price and the developer buy recorded in the same ledger are one
    /// point (the buy's), a zero or unreadable price is left out, points are drawn oldest first, and the live price is
    /// never placed before a point read. So the line never runs up the edge and its fill is never cut.
    func testThePriceLineHasNoStrayPoints() throws {
        let points = try decode([StellarLaunchDetail.Point].self, """
            [{"t": "2026-10-16T06:05:00Z", "price": "0.000002"}, {"t": "2026-10-16T06:05:00Z", "price": "0.0000021"},
             {"t": "2026-10-16T06:40:00Z", "price": "0"}, {"t": "2026-10-16T07:20:00Z", "price": "0.0000022"},
             {"t": "2026-10-16T06:50:00Z", "price": "0.00000215"}, {"t": "2026-10-16T07:30:00Z", "price": "n/a"}]
            """)
        let now = try XCTUnwrap(StellarFormat.date("2026-10-16T07:50:00Z"))
        let series = StellarLaunchDetailView.priceSeries(points, current: 0.0000022, launchedAt: nil, quoteUSD: 0.18, now: now)
        XCTAssertEqual(series.map(\.time), ["2026-10-16T06:05:00Z", "2026-10-16T06:50:00Z", "2026-10-16T07:20:00Z", "2026-10-16T07:50:00Z"].compactMap(StellarFormat.date))
        XCTAssertEqual(series.first?.usd ?? 0, 0.0000021 * 0.18, accuracy: 1e-15, "the developer buy's price, not the opening's below it")
        XCTAssertTrue(series.allSatisfy { $0.usd > 0 })
        XCTAssertEqual(series.map(\.block), [0, 1, 2, 3])
        XCTAssertTrue(zip(series, series.dropFirst()).allSatisfy { $0.time < $1.time }, "strictly oldest first")
        // A phone clock behind the server's: the live price comes after the newest point, as one point with it.
        let behind = StellarLaunchDetailView.priceSeries(points, current: 0.0000023, launchedAt: nil, quoteUSD: 0.18,
                                                         now: try XCTUnwrap(StellarFormat.date("2026-10-16T07:00:00Z")))
        XCTAssertEqual(behind.last?.time, StellarFormat.date("2026-10-16T07:20:00Z"))
        XCTAssertEqual(behind.last?.usd ?? 0, 0.0000023 * 0.18, accuracy: 1e-15)
        XCTAssertEqual(StellarLaunchDetailView.priceSeries(points, current: 0.0000022, launchedAt: nil, quoteUSD: 0), [], "no dollar price, no line")
        // The fill starts at the plotted range's floor, never at zero.
        let domain = StellarPriceChart.domain(series)
        XCTAssertGreaterThan(domain.lowerBound, 0)
        XCTAssertLessThan(domain.lowerBound, series.map(\.usd).min() ?? 0)
        XCTAssertGreaterThan(domain.upperBound, series.map(\.usd).max() ?? 0)
    }

    /// The time axis's marks fall inside the line's span, at most about four of them, each label read once: a launch two
    /// hours old reads "6:30 AM, 7:00 AM, 7:30 AM", never "6 AM, 6 AM, 7 AM, 7 AM".
    func testTheTimeAxisLabelsAreDistinct() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let start = try XCTUnwrap(StellarFormat.date("2026-10-16T06:05:00Z"))
        // 90 s, 20 min, 1 h 45, 5 h, 11 h, 23 h, 30 h, 3 days, 12 days, 70 days, 800 days.
        let spans: [TimeInterval] = [90, 1_200, 6_300, 18_000, 39_600, 82_800, 108_000, 259_200, 1_036_800, 6_048_000, 69_120_000]
        for span in spans {
            let end = start.addingTimeInterval(span)
            let axis = StellarPriceChart.timeAxis(from: start, to: end, locale: locale, calendar: calendar)
            let labels: [String] = axis.marks.map { $0.formatted(axis.format) }
            XCTAssertEqual(Set(labels).count, labels.count, "\(span): \(labels)")
            XCTAssertLessThanOrEqual(axis.marks.count, 5, "\(span)")
            XCTAssertTrue(axis.marks.allSatisfy { $0 >= start && $0 <= end }, "\(span)")
        }
        let twoHours = StellarPriceChart.timeAxis(from: start, to: start.addingTimeInterval(105 * 60), locale: locale, calendar: calendar)
        XCTAssertEqual(twoHours.marks, ["2026-10-16T06:30:00Z", "2026-10-16T07:00:00Z", "2026-10-16T07:30:00Z"].compactMap(StellarFormat.date))
    }

    /// A coin Create launched seconds ago has no row yet: its page reads it again, up to its limit, and only then says it
    /// couldn't be read. A page opened with its row never waits, nor one a link or a notification opened for a coin the
    /// server doesn't know.
    func testANewCoinsPageWaitsForItsRow() {
        XCTAssertTrue(StellarLaunchDetailView.waitsForRow(justLaunched: true, hasRow: false, waits: 0))
        XCTAssertTrue(StellarLaunchDetailView.waitsForRow(justLaunched: true, hasRow: false, waits: StellarLaunchDetailView.rowWaitLimit - 1))
        XCTAssertFalse(StellarLaunchDetailView.waitsForRow(justLaunched: true, hasRow: false, waits: StellarLaunchDetailView.rowWaitLimit))
        XCTAssertFalse(StellarLaunchDetailView.waitsForRow(justLaunched: true, hasRow: true, waits: 0))
        XCTAssertFalse(StellarLaunchDetailView.waitsForRow(justLaunched: false, hasRow: false, waits: 0), "a link to a coin the server doesn't know")
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

    /// The launch preview of an XLM launch on Soroswap (venue 0) for an account that can spend `spendable` on its first buy.
    private func preview(spendable: String, shortfall: String?, quoteBalance: String = "0") throws -> StellarLaunchPreviewV2 {
        try decode(StellarLaunchPreviewV2.self, """
            {"quote": {"id": "XLM", "code": "XLM", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"}, "venue": \(Self.soroswap),
             "terms": \(Self.terms()), "launchFee": {"asset": "XLM", "amount": "100000000", "booked": true, "to": "CACAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAIBAEAQCAINCW"},
             "xlm": {"balance": "50000000", "minBalance": "10000000", "sellingLiabilities": "0", "launchFee": "100000000", "fees": "4650100",
                     "buffer": "5000000", "spendable": "\(spendable)"},
             "quoteBalance": "\(quoteBalance)", "maxInitialBuy": "\(max(0, Int64(spendable) ?? 0))", "shortfall": \(shortfall.map { "\"\($0)\"" } ?? "null")}
            """)
    }

    func testTheXLMALaunchIsShortOfIsSaidBeforeTheReview() throws {
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

    func testAPreviewReadForAnotherQuoteOrVenueIsNeverUsed() throws {
        let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
        let read = try preview(spendable: "610349900", shortfall: nil)
        XCTAssertEqual(StellarCreateLaunchView.preview(read, quote: xlm, venue: 0), read)
        XCTAssertNil(StellarCreateLaunchView.preview(read, quote: "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", venue: 0),
                     "Paired with just changed: the XLM preview's Max and shortfall aren't USDC's")
        XCTAssertNil(StellarCreateLaunchView.preview(read, quote: xlm, venue: 1), "nor another venue's")
        XCTAssertNil(StellarCreateLaunchView.preview(nil, quote: xlm, venue: 0))
    }

    func testXLMAddedOrAnotherAccountReadsThePreviewAgain() throws {
        func account(xlm: String, exists: Bool = true, address: String = "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR",
                     usdcFirst: Bool = false) throws -> AccountView {
            let xlmRow = #"{"asset": "XLM", "code": "XLM", "name": "Stellar Lumens", "contract": "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC", "decimals": 7, "balance": "\#(xlm)", "enabled": true}"#
            let usdcRow = #"{"asset": "USDC", "code": "USDC", "name": "USD Coin", "contract": "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA", "decimals": 7, "balance": "20000000", "enabled": true}"#
            return try decode(AccountView.self, """
                {"address": "\(address)", "exists": \(exists), "network": "testnet", "activation": "friendbot",
                 "balances": [\(usdcFirst ? "\(usdcRow), \(xlmRow)" : "\(xlmRow), \(usdcRow)")], "sponsor": ""}
                """)
        }
        typealias Create = StellarCreateLaunchView
        let short = Create.accountKey(try account(xlm: "50000000"))
        XCTAssertNotEqual(short, Create.accountKey(try account(xlm: "100000000000")), "Fund with Friendbot changes the key")
        XCTAssertEqual(short, Create.accountKey(try account(xlm: "50000000")), "the same balances read again change nothing")
        XCTAssertEqual(short, Create.accountKey(try account(xlm: "50000000", usdcFirst: true)), "nor the same balances in another order")
        XCTAssertNotEqual(short, Create.accountKey(try account(xlm: "50000000", address: "GDQNY3PBOJOKYZSRMK2S7LHHGWZIUISD4QORETLMXEWXBI7KFZZMKTL3")),
                          "another account with the same balances")
        XCTAssertNotEqual(Create.accountKey(try account(xlm: "0", exists: false)), Create.accountKey(try account(xlm: "0")), "the account activated")
        XCTAssertEqual(Create.accountKey(nil), "")
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

    /// Done after a launch opens the new coin's own page: Create routes it through the router once its sheets have
    /// closed, to the Launch tab, whose board pushes it (`pendingStellar`), and its page waits for the coin's row as a
    /// just-launched coin's. Nothing opens for a launch that returned no coin.
    func testDoneOpensTheNewCoinsPage() async throws {
        let token = "CAKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBIFAUCQKBJRD5"
        StellarLaunchDetailView.justLaunched = []
        defer { StellarLaunchDetailView.justLaunched = [] }
        XCTAssertEqual(StellarCreateLaunchView.destination(afterLaunching: token), .launch(token: token))
        XCTAssertNil(StellarCreateLaunchView.destination(afterLaunching: nil))
        XCTAssertNil(StellarCreateLaunchView.destination(afterLaunching: "GCFIRY65OQE7DFP5KLNS2PF2LVZMUZYJX4OZIEQ36N2IQANUB5XVYOJR"), "only a contract")
        let results = try decode([TxStatus].self, #"[{"hash": "ab", "status": "success", "returnValue": "\#(token)"}]"#)
        XCTAssertEqual(StellarCreateLaunchView.launchedToken(results), token)

        let router = Router()
        router.stellarTab = .home
        StellarCreateLaunchView.openLaunched(token, router: router)
        XCTAssertEqual(StellarLaunchDetailView.justLaunched, [token], "its page waits for its row")
        XCTAssertNil(router.pendingStellar, "not while Create's sheets are still closing")
        for _ in 0..<40 where router.pendingStellar == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(router.pendingStellar, .launch(token: token))
        XCTAssertEqual(router.stellarTab, .launch)

        let untouched = Router()
        StellarCreateLaunchView.openLaunched(nil, router: untouched)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(untouched.pendingStellar)
        XCTAssertEqual(StellarLaunchDetailView.justLaunched, [token])
    }

    /// Advanced's one footer says what launchpad v2 does: the creator tax on curve trades only, and after graduation the
    /// launch's own split of what its locked pool earns, holders taking it all with sharing on.
    func testAdvancedSaysWhatLaunchpadV2Does() throws {
        let terms = try decode(StellarLaunchTermsV2.self, Self.terms())
        let footer = liteTr(StellarCreateLaunchView.feeFooter(terms))
        XCTAssertTrue(footer.contains("curve trades only"), footer)
        XCTAssertTrue(footer.contains("Soroswap"), footer)
        XCTAssertTrue(footer.contains(NumberStyle.basisPoints(5_000)), footer)
        XCTAssertTrue(footer.contains("holders"), footer)
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
