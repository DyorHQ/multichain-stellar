import XCTest
@testable import DyorKit

/// Home's totals count every address once (`HomeTotals`): a DyorHQ coin listed in Spot and in the Launch or Moments tab
/// counts in that tab, at Spot's price; one the tab doesn't list counts in Spot; every other token counts in Spot as
/// before. With DyorHQ venues on, a curve, pool or Moment coin has a Spot price, so without this Home would add it twice.
final class HomeTotalsTests: XCTestCase {
    private let qt = Address(literal: "0x00000000000000000000000000000000000c0071")
    private let moment = Address(literal: "0x00000000000000000000000000000000000c0072")
    private let other = Address(literal: "0x00000000000000000000000000000000000c0073")

    private func line(_ address: Address, _ units: Double, _ price: Double?) -> HomeTotals.Line {
        HomeTotals.Line(address: address, units: units, price: price)
    }

    /// QT is held: Spot lists it at its venue price and the Launch tab lists it too. It counts once, under Launch, at
    /// Spot's price (the tab's own decimal price only stands in when Spot has none), and the total is MON plus QT once.
    func testQTInSpotAndLaunchCountsOnce() throws {
        let spotPrice = 6.13e-8, launchPrice = 6.2e-8
        let totals = HomeTotals(spot: [line(Monad.native, 100, 0.03), line(qt, 50_000_000, spotPrice)],
                                launch: [line(qt, 50_000_000, launchPrice)], moments: [])
        XCTAssertEqual(totals.counted[qt], .launch)
        XCTAssertEqual(totals.counted[Monad.native], .spot)
        XCTAssertEqual(totals.prices[qt], spotPrice, "the Launch tab shows the price Spot shows")
        XCTAssertEqual(totals.spot, 3, accuracy: 1e-9, "Spot keeps MON alone")
        XCTAssertEqual(totals.launch, 50_000_000 * spotPrice, accuracy: 1e-12)
        XCTAssertEqual(totals.total, 3 + 50_000_000 * spotPrice, accuracy: 1e-9, "QT once, not twice")
        XCTAssertEqual(try XCTUnwrap(totals.value(of: qt, units: 50_000_000)), 50_000_000 * spotPrice, accuracy: 1e-12)

        // Spot has no price for it (venues off, or its read failed): the Launch tab's own decimal price counts it, once.
        let unpriced = HomeTotals(spot: [line(Monad.native, 100, 0.03), line(qt, 50_000_000, nil)], launch: [line(qt, 50_000_000, launchPrice)], moments: [])
        XCTAssertEqual(unpriced.prices[qt], launchPrice)
        XCTAssertEqual(unpriced.launch, 50_000_000 * launchPrice, accuracy: 1e-12)
        XCTAssertEqual(unpriced.spot, 3, accuracy: 1e-9)
    }

    /// Home's Launch tab lists the newest launches only: a DyorHQ coin it doesn't list still counts, in Spot, at Spot's
    /// price; and a coin with no price anywhere adds nothing (its row shows "—").
    func testADyorHQCoinAbsentFromLaunchStillCountsInSpot() {
        let totals = HomeTotals(spot: [line(Monad.native, 100, 0.03), line(qt, 50_000_000, 6.13e-8), line(other, 5, nil)],
                                launch: [line(moment, 0, 1)], moments: [])
        XCTAssertEqual(totals.counted[qt], .spot)
        XCTAssertEqual(totals.spot, 3 + 50_000_000 * 6.13e-8, accuracy: 1e-9)
        XCTAssertEqual(totals.launch, 0, "a coin created and not held lists at zero")
        XCTAssertNil(totals.prices[other])
        XCTAssertNil(totals.value(of: other, units: 5))
    }

    /// A Moment coin held in the wallet, with more still owed: Spot lists the held coins, the Moments tab the held and the
    /// owed ones. It counts once, under Moments (held and owed), at Spot's price.
    func testAMomentCoinCountsOnce() {
        let totals = HomeTotals(spot: [line(Monad.usdc, 10, 1), line(moment, 10, 0.02)], launch: [], moments: [line(moment, 15, 0.019)])
        XCTAssertEqual(totals.counted[moment], .moments)
        XCTAssertEqual(totals.moments, 15 * 0.02, accuracy: 1e-12)
        XCTAssertEqual(totals.spot, 10, accuracy: 1e-12)
        XCTAssertEqual(totals.total, 10 + 0.3, accuracy: 1e-12)

        // A Moment still collecting has no price: it adds nothing, and its row says "Not trading yet".
        let collecting = HomeTotals(spot: [line(moment, 0, nil)], launch: [], moments: [line(moment, 15, nil)])
        XCTAssertEqual(collecting.total, 0)
    }

    /// Without DyorHQ coins nothing changes: every token counts in Spot at its own price, as `spotValue` summed the rows
    /// before; a token without a price adds nothing.
    func testNonDyorHQCoinsAreUnchanged() {
        let spot = [line(Monad.native, 1_000, 0.03), line(Monad.usdc, 250.5, 1), line(other, 2, 3.5), line(Monad.ausd, 7, nil)]
        let totals = HomeTotals(spot: spot, launch: [], moments: [])
        let before = spot.compactMap { line in line.price.map { line.units * $0 } }.reduce(0, +)
        XCTAssertEqual(totals.spot, before, accuracy: 1e-9)
        XCTAssertEqual(totals.total, before, accuracy: 1e-9)
        XCTAssertEqual(totals.launch, 0)
        XCTAssertEqual(totals.moments, 0)
        XCTAssertTrue(totals.counted.values.allSatisfy { $0 == .spot })
        XCTAssertEqual(HomeTotals.empty.total, 0)
    }

    /// What can't be counted isn't: a price of 0, below 0, NaN or infinite is no price; an address listed twice in one tab
    /// counts at its first line; a Launch or Moments line at address 0 (MON's) never takes MON out of Spot.
    func testPricesThatArentPricesAndRepeatsAndAddressZero() {
        for bad in [0, -1, Double.nan, .infinity] {
            let totals = HomeTotals(spot: [line(other, 3, bad)], launch: [], moments: [])
            XCTAssertNil(totals.prices[other], "\(bad)")
            XCTAssertEqual(totals.spot, 0, "\(bad)")
        }
        let repeated = HomeTotals(spot: [line(other, 3, 2), line(other, 3, 2)], launch: [line(qt, 1, 1), line(qt, 1, 1)], moments: [])
        XCTAssertEqual(repeated.spot, 6)
        XCTAssertEqual(repeated.launch, 1)
        let zero = HomeTotals(spot: [line(Monad.native, 100, 0.03)], launch: [line(.zero, 5, 9)], moments: [line(.zero, 7, 9)])
        XCTAssertEqual(zero.counted[Monad.native], .spot)
        XCTAssertEqual(zero.prices[Monad.native], 0.03)
        XCTAssertEqual(zero.spot, 3, accuracy: 1e-9)
        XCTAssertEqual(zero.launch + zero.moments, 0)
    }

    /// Home's hero, split, allocation ring and tab rows go through `HomeTotals`: no section is summed on its own, a
    /// launch holding carries the Launch tab's price (Spot's first), a Moment is valued at its pool's live price (never
    /// its opening one) when Spot has none, and a Moment still collecting says "Not trading yet". Each section's figure
    /// is the totals' once its part of the wallet is read (`HomeReadState`), and the total is the four sections' sum.
    func testHomeCountsThroughHomeTotals() throws {
        let home = try DocsLinksTests.appSource("Home/HomeView.swift")
        let model = try XCTUnwrap(home.range(of: "final class HomeModel {")).upperBound
        let modelEnd = try XCTUnwrap(home.range(of: "struct TokenDetailView: View {")).lowerBound
        let body = String(home[model..<modelEnd])
        for part in ["var totals: HomeTotals {", "price: $0.usd) }", "price: $0.priceUSD) }", "price: WalletHoldings.momentPrice($0.moment)) })",
                     "var spotValue: Double? { reads.showsValue(of: .spot) ? totals.spot : nil }",
                     "var launchpadValue: Double? { reads.showsValue(of: .launch) ? totals.launch : nil }",
                     "var momentsValue: Double? { reads.showsValue(of: .moments) ? totals.moments : nil }",
                     "return Split(spot: spot, perps: perps, launch: launch, moments: moments)",
                     "var total: Double { spot + perps + launch + moments }", "var totalValue: Double? { split?.total }",
                     "return LaunchHolding(launch: launch, balance: balance, priceUSD: DyorPrice.launch(launch, spot: priceMap[launch.token]?.usd, pairUSD: pairUSD))"] {
            XCTAssertTrue(body.contains(part), part)
        }
        XCTAssertFalse(body.contains("usdcPerCoin"), "a Moment is never valued at its opening price")
        for type in ["Double", "Double?"] {
            XCTAssertFalse(body.contains("Value: \(type) { holdings.") || body.contains("Value: \(type) { launchHoldings.") || body.contains("Value: \(type) { momentRows."),
                           "no section summed on its own")
        }
        XCTAssertTrue(home.contains("LaunchHoldingRow(holding: holding, value: totals.value(of: holding.id, units: holding.units))"))
        XCTAssertTrue(home.contains("MomentHoldingRow(row: row, value: totals.value(of: row.moment.moment.coin, units: HomeModel.coins(row)))"))
        XCTAssertTrue(home.contains("if row.moment.isNotTradingYet {\n                    Text(\"Not trading yet\")"))
    }

    /// A read-only check against mainnet, run with `DYORHQ_LIVE_PRICES=1`: QT's Spot price (its own pool, DyorHQ venues
    /// on) and its launch's decimal price agree, so Home's Launch tab and Spot show one price, around $6e-8; Home counts
    /// it once. Nothing is sent.
    func testLiveQTIsOnePriceAndCountedOnce() async throws {
        guard ProcessInfo.processInfo.environment["DYORHQ_LIVE_PRICES"] == "1" else { throw XCTSkip("Set DYORHQ_LIVE_PRICES=1 to read mainnet") }
        let rpc = RPCClient(urls: Monad.publicRPCs)
        let qt = Token(address: DyorCoinChain.qt, symbol: "QT", name: "Quet", decimals: 18)
        let prices = try await PriceService(rpc: rpc, dyorVenues: true).prices(for: [qt, .mon])
        let spot = try XCTUnwrap(prices[qt.address]?.usd)
        let mon = try XCTUnwrap(prices[Monad.native]?.usd)
        let held = try await LaunchpadService(rpc: rpc, addresses: .monadMainnet).heldLaunches([qt])
        let launch = try XCTUnwrap(held.launches[qt.address])
        let own = try XCTUnwrap(launch.usdPrice(pairUSD: mon))
        print("QT Spot $\(spot) (\(prices[qt.address]?.source ?? "?")), launch $\(own) (\(launch.pairPrice ?? 0) MON at $\(mon)), integer price() \(launch.price)")
        XCTAssertEqual(own, spot, accuracy: spot * 0.01, "one price, read twice a moment apart")
        XCTAssertTrue((1e-8...1e-6).contains(spot), "about $6e-8")
        let totals = HomeTotals(spot: [.init(address: qt.address, units: 1_000_000, price: spot)], launch: [.init(address: qt.address, units: 1_000_000, price: own)], moments: [])
        XCTAssertEqual(totals.total, 1_000_000 * spot, accuracy: 1e-12, "counted once, at Spot's price")
    }

    /// A Moment has no market while it collects or waits to graduate; once it graduated it has one, and an expired one
    /// never will.
    func testAMomentIsNotTradingYetUntilItGraduates() {
        func info(_ state: MomentState, graduated: Bool) -> MomentInfo {
            let record = Moment(id: 1, creator: other, platform: other, treasury: other, coin: moment, nft: other, price: 1, threshold: 1, rateNum: 1, rateDen: 1,
                                creatorBps: 0, platformBps: 0, reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0, deadline: 1)
            return MomentInfo(moment: record, name: "M", symbol: "M", provenance: MomentProvenance(mediaURI: "", mediaHash: Data(count: 32), place: "", date: 0, animationURI: ""),
                              ledger: MomentLedger(state: state, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: 0, platformClaimable: 0,
                                                   treasuryClaimable: 0, totalGross: 0, collects: 0),
                              editions: 0, closed: false, entitlements: 0, graduated: graduated, progressBps: 0, pool: nil)
        }
        XCTAssertTrue(info(.collecting, graduated: false).isNotTradingYet)
        XCTAssertTrue(info(.graduationPending, graduated: false).isNotTradingYet)
        XCTAssertFalse(info(.graduated, graduated: true).isNotTradingYet)
        XCTAssertFalse(info(.expired, graduated: false).isNotTradingYet)
    }
}
