// Stellar's Earn (docs/DESIGN-stellar-parity.md §8.6.3; decision 6): the pool status chip and a frozen pool's Deposit,
// the default market, the ticket's rules (Max, the percent buttons, what a deposit and a withdrawal may take), the
// estimated interest, the earned figure unread in the public view, the Assets totals, the History tab's rows, Blend's test
// USDC and its swap, the rate chart's points and range, the market picker's search, Earn's destinations, and the source
// rules Earn keeps.
@testable import DyorHQ
import DyorKit
import DyorLite
import StellarKit
import SwiftUI
import XCTest

@MainActor
final class StellarEarnTests: XCTestCase {
    private static let pool = "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF"
    private static let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"
    private static let usdc = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
    private static let blendUSDC = "CAQCFVLOBK5GIULPNZRGATJJMIZL5BSP7X5YJVMGCPTUEPFM4AVSRCJU"

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func number(_ value: Double?) -> String { value.map { "\($0)" } ?? "null" }
    private func string(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

    /// A market as `/v1/earn/markets` answers it.
    private func market(_ asset: String = StellarEarnTests.xlm, code: String = "XLM", status: String? = "active", supplyApy: Double = 0.0421,
                        utilization: Double = 0.623, priceUsd: Double? = 0.19) throws -> EarnMarket {
        try decode(EarnMarket.self, """
            {"pool": "\(Self.pool)", "poolName": "Blend TestnetV2", "asset": "\(asset)", "code": "\(code)", "decimals": 7,
             "supplyApy": \(supplyApy), "borrowApy": 0.068, "utilization": \(utilization), "totalSupplied": 1200000, "note": null,
             "totalSuppliedUsd": 228000, "freeLiquidityUsd": 85000, "priceUsd": \(number(priceUsd)), "poolStatus": \(string(status))}
            """)
    }

    /// A position as `/v1/holdings`' Earn part answers it; `earned` nil is the public view's. `complete` false is an owner's
    /// position whose deposit DyorHQ has no record of.
    private func position(_ asset: String = StellarEarnTests.xlm, code: String = "XLM", supplied: String = "1000000000", earned: String? = "10000000",
                          complete: Bool? = nil, supplyApy: Double? = 0.031, valueUsd: Double? = 19.01) throws -> EarnPosition {
        try decode(EarnPosition.self, """
            {"pool": "\(Self.pool)", "poolName": "Blend TestnetV2", "asset": "\(asset)", "code": "\(code)", "supplied": "\(supplied)",
             "deposited": \(earned == nil ? "null" : "\"1000000000\""), "withdrawn": \(earned == nil ? "null" : "\"0\""), "earned": \(string(earned)),
             "earnedComplete": \(complete ?? (earned != nil)), "supplyApy": \(number(supplyApy)), "valueUsd": \(number(valueUsd))}
            """)
    }

    /// The testnet registry: XLM and Circle's USDC listed, Blend's test USDC (code USDC) not.
    private func assets() throws -> [AssetInfo] {
        try decode([AssetInfo].self, """
            [{"id": "XLM", "code": "XLM", "name": "Stellar Lumens", "decimals": 7, "contract": "\(Self.xlm)", "classic": "native",
              "note": "Test XLM", "priceRef": "XLM", "logo": "XLM", "listed": true},
             {"id": "USDC", "code": "USDC", "name": "USD Coin", "decimals": 7, "contract": "\(Self.usdc)",
              "classic": "USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5", "note": null, "priceRef": "USDC", "logo": "USDC", "listed": true},
             {"id": "BUSDC", "code": "USDC", "name": "Blend test USDC", "decimals": 7, "contract": "\(Self.blendUSDC)",
              "classic": "USDC:GATALTGTWIOT6BUDBCZM3Q4OQ4BO2COLOAZ7IYSKPLC2PMSOPPGF5V56", "note": null, "priceRef": "USDC", "logo": null, "listed": false}]
            """)
    }

    // MARK: - The pool's status

    func testThePoolStatusChipAndAFrozenPoolsDeposit() throws {
        let active = try market(status: "active")
        let onIce = try market(status: "on_ice")
        let frozen = try market(status: "frozen")
        let older = try market(status: nil)
        let unknown = try market(status: "paused_forever")

        XCTAssertEqual(StellarPoolStatus(active.poolStatus), .active)
        XCTAssertEqual(StellarPoolStatus(onIce.poolStatus), .onIce)
        XCTAssertEqual(StellarPoolStatus(frozen.poolStatus), .frozen)
        XCTAssertNil(StellarPoolStatus(older.poolStatus), "an older server's market shows no status")
        XCTAssertEqual(StellarPoolStatus(unknown.poolStatus), .frozen, "a status this build doesn't know never invites a deposit")

        // The chip: words in the status's colour, never the colour alone.
        XCTAssertEqual(StellarPoolStatusChip(status: .active).tint, .positive)
        XCTAssertEqual(StellarPoolStatusChip(status: .onIce).tint, .attention)
        XCTAssertEqual(StellarPoolStatusChip(status: .frozen).tint, .negative)
        XCTAssertEqual(StellarPoolStatusChip(status: .active).label.key, "Active")
        XCTAssertEqual(StellarPoolStatusChip(status: .onIce).label.key, "Borrowing paused")
        XCTAssertEqual(StellarPoolStatusChip(status: .frozen).label.key, "Deposits paused")
        for status in [StellarPoolStatus.active, .onIce, .frozen] {
            XCTAssertEqual(StellarPoolStatusChip(status: status).label.table, "StellarEarn")
        }

        // Deposit: off for a frozen pool (and anything it doesn't know), on for an active or on-ice one; never without a key.
        XCTAssertTrue(StellarEarnModel.canDeposit(active, canSign: true))
        XCTAssertTrue(StellarEarnModel.canDeposit(onIce, canSign: true), "on ice pauses borrowing, not deposits")
        XCTAssertFalse(StellarEarnModel.canDeposit(frozen, canSign: true))
        XCTAssertFalse(StellarEarnModel.canDeposit(unknown, canSign: true))
        XCTAssertTrue(StellarEarnModel.canDeposit(older, canSign: true))
        XCTAssertFalse(StellarEarnModel.canDeposit(active, canSign: false), "a watch-only account signs nothing")

        // Withdraw: on with a position, whatever the pool's status (a frozen pool still pays out what it can).
        let held = try position()
        XCTAssertTrue(StellarEarnModel.canWithdraw(held, canSign: true))
        XCTAssertFalse(StellarEarnModel.canWithdraw(nil, canSign: true), "no position, no Withdraw")
        XCTAssertFalse(StellarEarnModel.canWithdraw(try position(supplied: "0"), canSign: true))
        XCTAssertFalse(StellarEarnModel.canWithdraw(held, canSign: false))
    }

    // MARK: - The market on screen

    func testTheDefaultMarketIsTheOneNamedThenTheLargestPositionThenUSDCThenTheFirst() throws {
        let xlm = try market()
        let busdc = try market(Self.blendUSDC, code: "USDC")
        let markets = [xlm, busdc]
        let registry = try assets()

        XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [], requested: nil, assets: registry)?.id, busdc.id, "the pool's USDC market")
        XCTAssertEqual(StellarEarnModel.defaultMarket([xlm], positions: [], requested: nil, assets: registry)?.id, xlm.id, "else the first")
        XCTAssertNil(StellarEarnModel.defaultMarket([], positions: [], requested: nil, assets: registry))

        let small = try position(Self.blendUSDC, code: "USDC", supplied: "50000000", valueUsd: 5)
        let large = try position(valueUsd: 19.01)
        XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [small, large], requested: nil, assets: registry)?.id, xlm.id,
                       "the account's largest position, by value")
        XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [try position(supplied: "0")], requested: nil, assets: registry)?.id, busdc.id,
                       "an emptied position isn't one")

        // A destination's market wins, however it names it.
        for reference in [busdc.id, "\(Self.pool):\(Self.blendUSDC)", Self.blendUSDC, "BUSDC"] {
            XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [large], requested: reference, assets: registry)?.id, busdc.id, reference)
        }
        XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [large], requested: "USDC", assets: registry)?.id, xlm.id,
                       "the wallet's USDC isn't Blend's test USDC: the default applies")
        XCTAssertEqual(StellarEarnModel.defaultMarket(markets, positions: [large], requested: "CNOSUCHMARKET", assets: registry)?.id, xlm.id)
    }

    func testAnEarnDestinationNamesTheMarketAndOpensTheEarnSide() throws {
        let busdc = try market(Self.blendUSDC, code: "USDC")
        let destination = try XCTUnwrap(StellarDestination(reference: "stellar:earn/\(busdc.id)"))
        XCTAssertEqual(destination, .earn(market: busdc.id))
        XCTAssertEqual(destination.tab, .earn)
        XCTAssertEqual(destination.reference, "stellar:earn/\(busdc.id)", "what LiteStore.earnPlan puts in its notification reads back")
        XCTAssertEqual(StellarDestination(reference: "stellar:earn"), .earn(market: nil))
    }

    // MARK: - The ticket

    func testTheTicketsRulesForADepositAndAWithdrawal() throws {
        XCTAssertEqual(StellarEarnModel.problem(.deposit, amount: nil, available: 100, supplied: 0)?.key, "Enter an amount to deposit.")
        XCTAssertEqual(StellarEarnModel.problem(.deposit, amount: 0, available: 100, supplied: 0)?.key, "Enter an amount to deposit.")
        XCTAssertEqual(StellarEarnModel.problem(.withdraw, amount: nil, available: 100, supplied: 50)?.key, "Enter an amount to withdraw.")
        XCTAssertEqual(StellarEarnModel.problem(.deposit, amount: 101, available: 100, supplied: 0)?.key, "More than your available balance.")
        XCTAssertNil(StellarEarnModel.problem(.deposit, amount: 100, available: 100, supplied: 0), "all that's available")
        XCTAssertEqual(StellarEarnModel.problem(.withdraw, amount: 51, available: 1_000, supplied: 50)?.key, "More than you've supplied.")
        XCTAssertNil(StellarEarnModel.problem(.withdraw, amount: 50, available: 0, supplied: 50), "the whole position, with nothing in the wallet")
        XCTAssertEqual(StellarEarnModel.problem(.withdraw, amount: 51, available: 1_000, supplied: 50)?.table, "StellarEarn")

        // The field: a plain decimal in the asset's decimals, a decimal comma read as a point, nothing else.
        XCTAssertEqual(StellarEarnModel.amount("12.5", decimals: 7), 125_000_000)
        XCTAssertEqual(StellarEarnModel.amount("0,5", decimals: 7), 5_000_000)
        XCTAssertEqual(StellarEarnModel.amount("1,250.5", decimals: 7), 12_505_000_000, "grouping read as Amount.parse reads it")
        XCTAssertNil(StellarEarnModel.amount("1.2.3", decimals: 7), "an ambiguous amount is none")
        XCTAssertNil(StellarEarnModel.amount("abc", decimals: 7))
        XCTAssertNil(StellarEarnModel.amount("99999999999999", decimals: 7), "more than fits is no amount")

        // 25 / 50 / 75%, rounded down; 100% is Max, all that's available.
        XCTAssertEqual(StellarEarnModel.share(25, of: 1_000_000_003), 250_000_000)
        XCTAssertEqual(StellarEarnModel.share(75, of: 3), 2)
        XCTAssertEqual(StellarEarnModel.share(100, of: 1_000_000_003), 1_000_000_003)
        XCTAssertEqual(StellarEarnModel.share(50, of: 0), 0)
        XCTAssertEqual(StellarFormat.plain(units: StellarEarnModel.share(50, of: 125_000_001)), "6.25", "the field reads back as written")
    }

    func testTheEstimatedYearlyInterestIsTheAmountAtTodaysRate() throws {
        let xlm = try market(supplyApy: 0.0421, priceUsd: 0.2)
        let usd = try XCTUnwrap(StellarEarnModel.yearlyInterestUsd(amount: 1_000_000_000, market: xlm))
        XCTAssertEqual(usd, 100 * 0.0421 * 0.2, accuracy: 1e-12, "100 XLM at 4.21% and $0.20")
        XCTAssertNil(StellarEarnModel.yearlyInterestUsd(amount: 0, market: xlm))
        let unpriced = try market(priceUsd: nil)
        XCTAssertNil(StellarEarnModel.yearlyInterestUsd(amount: 1_000_000_000, market: unpriced), "no price, no dollars")
        XCTAssertEqual(StellarEarnModel.yearlyInterestUnits(amount: 1_000_000_000, market: unpriced), 42_100_000, "4.21 XLM instead")
    }

    func testTheRatesStackAboveTheTicketAtAccessibilitySizes() {
        for size in [DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5] {
            XCTAssertTrue(StellarEarnMarketView.stacksRates(size), "\(size)")
        }
        for size in [DynamicTypeSize.xSmall, .large, .xLarge, .xxLarge, .xxxLarge] {
            XCTAssertFalse(StellarEarnMarketView.stacksRates(size), "\(size): beside the ticket, as Perps' book")
        }
    }

    // MARK: - Positions and totals

    func testTheEarnedFigureIsUnreadInThePublicViewNeverZero() throws {
        let owner = try position(earned: "10000000")
        XCTAssertEqual(StellarEarnModel.earned(owner), 10_000_000)
        XCTAssertEqual(try XCTUnwrap(StellarEarnModel.earnedUsd(owner)), 0.1901, accuracy: 1e-12, "1 XLM earned of 100 supplied worth $19.01")
        let publicView = try position(earned: nil)
        XCTAssertNil(StellarEarnModel.earned(publicView), "the public view has no record")
        XCTAssertNil(StellarEarnModel.earnedUsd(publicView))
        let onlyPublic = StellarEarnModel.totals(positions: [publicView], markets: [], spot: nil)
        XCTAssertNil(onlyPublic.earned, "nothing known: unread, never $0")
        XCTAssertNil(StellarEarnModel.earnedText(onlyPublic))
        // Short of one, the total is what is known, said to be a lower bound as Portfolio's P&L is.
        let mixed = StellarEarnModel.totals(positions: [owner, publicView], markets: [], spot: nil)
        XCTAssertEqual(try XCTUnwrap(mixed.earned), 0.1901, accuracy: 1e-12)
        XCTAssertFalse(mixed.earnedComplete)
        XCTAssertEqual(StellarEarnModel.earnedText(mixed), "+$0.19*")
        XCTAssertEqual(StellarEarnPositionCard.signed(10_000_000, code: "XLM", decimals: 7), "+1 XLM")
        XCTAssertEqual(StellarEarnPositionCard.signed(-5_000_000, code: "XLM", decimals: 7), "−0.5 XLM")
        XCTAssertEqual(StellarEarnPositionCard.signed(0, code: "XLM", decimals: 7), "0 XLM")
    }

    /// A position whose deposit DyorHQ has no record of (made elsewhere, or before deposits were recorded): the server's
    /// `earned` is then the whole position, which isn't earnings, so Earn, Home and Portfolio show it unknown.
    func testAPositionWithNoRecordedDepositShowsNoEarnings() throws {
        let elsewhere = try position(earned: "1000000000", complete: false)
        XCTAssertNil(StellarEarnModel.earned(elsewhere), "100 XLM supplied isn't 100 XLM earned")
        XCTAssertNil(StellarEarnModel.earnedUsd(elsewhere))
        XCTAssertNil(StellarEarnPositionRow.earnedUsd(elsewhere), "Home's Earn row shows Earn's figure")
        let totals = StellarEarnModel.totals(positions: [elsewhere, try position(valueUsd: 19.01)], markets: [], spot: nil)
        XCTAssertEqual(try XCTUnwrap(totals.earned), 0.1901, accuracy: 1e-12, "only the recorded one counts")
        XCTAssertFalse(totals.earnedComplete)
        XCTAssertEqual(StellarEarnPositionRow.earnedUsd(try position()) ?? 0, 0.1901, accuracy: 1e-12)
    }

    /// The figures a testnet account had on a local stack (WP-35, 2026-10-17): 100 XLM supplied to Blend TestnetV2 and 40
    /// withdrawn 20 seconds later (Horizon's balance changes: exactly 100 and 40 XLM), as `/v1/holdings` answered at once.
    /// Blend's own position for the account then, read on chain, was 253,794,932 b-tokens × get_reserve's b_rate
    /// 2.364119164290 = 60.0001462 XLM at the reserve's last accrual: the API's 60.0001603 is it plus the seconds of
    /// interest since, which Blend's SDK accrues to the time of the read.
    func testEarnedSoFarIsTheValueNowPlusWithdrawalsLessDeposits() throws {
        let row = try decode(EarnPosition.self, """
            {"pool": "\(Self.pool)", "asset": "\(Self.xlm)", "code": "XLM", "supplied": "600001603", "poolName": "Blend TestnetV2",
             "deposited": "1000000000", "withdrawn": "400000000", "earned": "1603", "earnedComplete": true,
             "supplyApy": 5.135860714113084, "valueUsd": 10.81}
            """)
        let earned = try XCTUnwrap(StellarEarnModel.earned(row))
        XCTAssertEqual(earned, StellarEarnModel.units(row.supplied) + 400_000_000 - 1_000_000_000)
        XCTAssertEqual(StellarEarnPositionCard.signed(earned, code: "XLM", decimals: 7), "+0.00016 XLM", "in the asset, in the app's number style")
        let usd = try XCTUnwrap(StellarEarnModel.earnedUsd(row))
        XCTAssertEqual(usd, 0.0001603 * 10.81 / 60.0001603, accuracy: 1e-12, "in dollars, at the price its value is counted at")
        XCTAssertEqual(PriceFormat.usdValue(usd, signed: true), "+<$0.01")
        let totals = StellarEarnModel.totals(positions: [row], markets: [], spot: nil)
        XCTAssertEqual(try XCTUnwrap(totals.earned), usd, accuracy: 1e-15, "the Earn total is the positions'")
        XCTAssertTrue(totals.earnedComplete)
    }

    func testTheAssetsTabTotalsEveryMarket() throws {
        let xlm = try position(supplyApy: 0.03, valueUsd: 30)
        let busdc = try position(Self.blendUSDC, code: "USDC", supplied: "100000000", earned: "1000000", supplyApy: 0.06, valueUsd: 10)
        let spot = try decode([StellarHoldings.SpotHolding].self, """
            [{"id": "XLM", "kind": "registry", "contract": "\(Self.xlm)", "classic": "native", "code": "XLM", "name": "Stellar Lumens", "decimals": 7,
              "balance": "647000000", "enabled": true, "verified": true, "badges": [], "note": null, "logo": "XLM", "priceUsd": 0.19, "valueUsd": 12.3, "change24h": 0},
             {"id": "USDC", "kind": "registry", "contract": "\(Self.usdc)", "classic": null, "code": "USDC", "name": "USD Coin", "decimals": 7,
              "balance": "20000000", "enabled": true, "verified": true, "badges": [], "note": null, "logo": "USDC", "priceUsd": 1, "valueUsd": 2, "change24h": 0}]
            """)
        let markets = [try market(), try market(Self.blendUSDC, code: "USDC")]
        let totals = StellarEarnModel.totals(positions: [xlm, busdc], markets: markets, spot: spot)
        XCTAssertEqual(try XCTUnwrap(totals.supplied), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.averageApy), 3.75, accuracy: 1e-9, "3% on $30 and 6% on $10")
        XCTAssertEqual(try XCTUnwrap(totals.earned), 0.3 + 0.1, accuracy: 1e-9)
        XCTAssertTrue(totals.earnedComplete)
        XCTAssertEqual(StellarEarnModel.earnedText(totals), "+$0.40", "Earn's Assets tab and Portfolio's Earn card")
        XCTAssertEqual(try XCTUnwrap(totals.wallet), 12.3, accuracy: 1e-9, "the wallet's XLM; its USDC isn't an asset Earn lends here")
        XCTAssertNil(StellarEarnModel.totals(positions: [xlm], markets: markets, spot: nil).wallet, "the holdings not read: unread")
        let none = StellarEarnModel.totals(positions: [], markets: markets, spot: [])
        XCTAssertEqual(none.supplied, 0)
        XCTAssertEqual(none.earned, 0)
        XCTAssertTrue(none.earnedComplete)
        // A loss (a pool that lost value) is signed as one.
        let loss = StellarEarnModel.totals(positions: [try position(earned: "-5000000", valueUsd: 20)], markets: markets, spot: [])
        XCTAssertEqual(StellarEarnModel.earnedText(loss), "−$0.10")
        XCTAssertNil(none.averageApy, "no position, no rate")
        XCTAssertNil(StellarEarnModel.totals(positions: [try position(valueUsd: nil)], markets: markets, spot: []).supplied, "an unpriced position")
    }

    func testTheHistoryTabListsThisMarketsDepositsAndWithdrawals() throws {
        let items = try decode([StellarActivityItem].self, """
            [{"type": "tx", "id": "a", "kind": "earn_deposit", "summary": "Supplied XLM", "status": "success", "at": "2026-10-15T10:00:00Z",
              "section": "earn", "hash": "aa", "ref": {"market": "\(Self.pool):\(Self.xlm)"}},
             {"type": "tx", "id": "b", "kind": "earn_withdraw", "summary": "Withdrew USDC", "status": "success", "at": "2026-10-15T11:00:00Z",
              "section": "earn", "hash": "bb", "ref": {"market": "\(Self.pool):\(Self.blendUSDC)"}},
             {"type": "tx", "id": "c", "kind": "swap", "summary": "Swapped", "status": "success", "at": "2026-10-15T12:00:00Z",
              "section": "spot", "hash": "cc", "ref": null},
             {"type": "tx", "id": "d", "kind": "trust", "summary": "Enabled USDC", "status": "success", "at": "2026-10-15T12:30:00Z",
              "section": "earn", "hash": "dd", "ref": null}]
            """)
        XCTAssertEqual(StellarEarnModel.history(items, market: try market()).map(\.id), ["a"])
        XCTAssertEqual(StellarEarnModel.history(items, market: try market(Self.blendUSDC, code: "USDC")).map(\.id), ["b"])
    }

    // MARK: - Blend's test USDC

    func testBlendsTestUSDCSaysSoAndOffersItsSwapOnlyWithARoute() throws {
        let registry = try assets()
        let busdc = try market(Self.blendUSDC, code: "USDC")
        let pair = try XCTUnwrap(StellarEarnModel.walletTwin(of: busdc, assets: registry))
        XCTAssertEqual(pair.twin.id, "USDC", "swap from the wallet's USDC")
        XCTAssertEqual(pair.own.id, "BUSDC", "into the pool's own")
        XCTAssertNil(StellarEarnModel.walletTwin(of: try market(), assets: registry), "XLM is XLM")
        XCTAssertNil(StellarEarnModel.walletTwin(of: try market(Self.usdc, code: "USDC"), assets: registry), "a market of the wallet's own USDC")

        // The route check: unknown until a quote says, and asked once a market knows.
        let model = StellarEarnModel()
        XCTAssertNil(model.routes[busdc.id], "no swap offered before a quote found a route")
    }

    // MARK: - The rate chart

    func testTheRateChartPlotsPercentsInTimeOrderAndNeedsTwoPoints() throws {
        let history = try decode(StellarEarnHistory.self, """
            {"points": [{"t": "2026-10-15T10:10:00.000Z", "supplyApy": 0.0425, "utilization": 0.64},
                        {"t": "2026-10-15T10:00:00Z", "supplyApy": 0.0421, "utilization": 0.623},
                        {"t": "not a time", "supplyApy": 0.05, "utilization": 0.7}]}
            """)
        let samples = StellarRateChart.samples(history.points)
        XCTAssertEqual(samples.map(\.apy), [4.21, 4.25], "oldest first, in percent, a point with no time left out")
        XCTAssertEqual(samples.map(\.utilization), [62.3, 64])
        let domain = StellarRateChart.domain(samples)
        XCTAssertLessThan(domain.lowerBound, 4.21)
        XCTAssertGreaterThan(domain.upperBound, 4.25)
        XCTAssertGreaterThanOrEqual(StellarRateChart.domain([.init(time: .now, apy: 0, utilization: 0)]).lowerBound, 0, "never below 0%")
        XCTAssertEqual(StellarRateChart.axis(4.2, span: 0.3), "4.20%")
        XCTAssertEqual(StellarRateChart.axis(4.2, span: 2), "4.2%")
        XCTAssertEqual(StellarRateChart.chip(.week), Text("7D"))
        XCTAssertEqual(StellarRateChart.chip(.month), Text("30D"))
        XCTAssertEqual(StellarRateRange.week.period, .week)
        XCTAssertEqual(StellarRateRange.month.period, .month)

        // The history on screen is only ever the market's and range's own.
        let model = StellarEarnModel()
        XCTAssertEqual(model.points(market: try market(), range: .week), [])
        XCTAssertFalse(model.historyFailed(market: try market(), range: .week))
    }

    // MARK: - The market picker

    func testTheMarketPickerSearchesCodePoolAndNameAndHidesNoMarket() throws {
        let registry = try assets()
        let markets = [try market(), try market(Self.blendUSDC, code: "USDC")]
        let asset: (EarnMarket) -> AssetInfo? = { market in registry.first { $0.contract == market.asset } }
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "", asset: asset).count, 2, "every market is listed")
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "usdc", asset: asset).map(\.code), ["USDC"])
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "test usdc", asset: asset).map(\.code), ["USDC"], "by the asset's name")
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "blend test", asset: asset).count, 2, "the pool's name, Blend TestnetV2, matches both")
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "testnetv2", asset: asset).count, 2, "by the pool")
        XCTAssertEqual(StellarSelectMarketSheet.filtered(markets, query: "lumens", asset: asset).map(\.code), ["XLM"])
    }

    // MARK: - Source rules

    /// Earn's sources (ios/DyorHQ/Lite/Trade) and its strings table, read from this checkout.
    private func earnSources() throws -> [(name: String, text: String)] {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { ios.deleteLastPathComponent() } // StellarEarnTests.swift → Tests → Internal → ios
        let trade = ios.appendingPathComponent("DyorHQ/Lite/Trade")
        let names = ["StellarEarnView.swift", "StellarEarnModel.swift", "StellarSelectMarketSheet.swift", "StellarRateChart.swift"]
        return try names.map { ($0, try String(contentsOf: trade.appendingPathComponent($0), encoding: .utf8)) }
    }

    func testEarnIsNoLongerASeamAndKeepsNoneOfTheOldScreensStyling() throws {
        for (name, text) in try earnSources() {
            XCTAssertFalse(text.contains("SEAM("), name)
            for gone in ["LiteLegacyScreens", "LiteChrome", "LiteStyle", "LiteParagraph", "LitePrimaryButton", "LiteInlineError", "liteFormSheet",
                         "EarnMarketSheet", "AssetBadge", "unlock", "Unlock", "env.history", "AsyncImage"] {
                XCTAssertFalse(text.contains(gone), "\(name): \(gone)")
            }
            for line in text.components(separatedBy: "\n") where line.contains("UIPasteboard") {
                XCTAssertTrue(line.contains("UIPasteboard.general.string = address.checksummed"), "\(name): \(line)")
            }
        }
    }

    func testEarnsTextNeverSaysLiteOrPro() throws {
        var ios = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { ios.deleteLastPathComponent() } // StellarEarnTests.swift → Tests → Internal
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf: ios.appendingPathComponent("Resources/StellarEarn.xcstrings"))) as? [String: Any]
        let strings = try XCTUnwrap(table?["strings"] as? [String: Any])
        XCTAssertGreaterThan(strings.count, 20, "the table is read")
        let word = try NSRegularExpression(pattern: #"\b(Lite|Pro)\b"#)
        func check(_ text: String, _ at: String) {
            XCTAssertNil(word.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), "\(at): \(text)")
        }
        for (key, entry) in strings {
            check(key, "key")
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            for (language, localization) in localizations {
                let unit = (localization as? [String: Any])?["stringUnit"] as? [String: Any]
                check(unit?["value"] as? String ?? "", "\(key) [\(language)]")
            }
        }
    }
}
