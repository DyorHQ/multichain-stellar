// Stellar's Earn (docs/DESIGN-stellar-parity.md §8.6.3; decision 6): the pool status chip and a frozen pool's Deposit,
// the default market, the ticket's rules (Max, the percent buttons, what a deposit and a withdrawal may take, a
// withdrawal of everything), the pool's name, the estimated interest, the earned figure unread in the public view and
// priced at its market's price, the Assets totals, the History tab's rows and their read (which leaves the account's
// activity as other screens read it), Portfolio's "Earned so far", Blend's test USDC and its swap, the rate chart's points
// and range, the market picker's search, Earn's destinations, and the source rules Earn keeps.
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

        // The whole position typed (or Withdraw on the Position card) asks for everything: the supplied figure read is the
        // least that arrives, and the interest earned since comes too, so no dust stays in the pool.
        XCTAssertTrue(StellarEarnModel.takesEverything(.withdraw, amount: 1_000_000_526, supplied: 1_000_000_526))
        XCTAssertFalse(StellarEarnModel.takesEverything(.withdraw, amount: 1_000_000_525, supplied: 1_000_000_526), "part of it: that amount")
        XCTAssertFalse(StellarEarnModel.takesEverything(.deposit, amount: 50, supplied: 50), "a deposit is of its amount")
        XCTAssertFalse(StellarEarnModel.takesEverything(.withdraw, amount: 50, supplied: 0), "no position")

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

    /// The pool's server name already says Blend ("Blend TestnetV2"): the chip, the review and VoiceOver say it once.
    func testThePoolIsNamedWithBlendOnce() throws {
        XCTAssertEqual(StellarEarnModel.poolLabel(try market().poolName), "Blend · TestnetV2", "§8.6.3's chip")
        XCTAssertEqual(StellarEarnModel.poolShortName("Blend TestnetV2"), "TestnetV2", "VoiceOver: Lends through Blend, pool TestnetV2")
        XCTAssertEqual(StellarEarnModel.poolLabel("Fixed XLM-USDC"), "Blend · Fixed XLM-USDC", "a name without Blend keeps all of it")
        XCTAssertEqual(StellarEarnModel.poolLabel("blend  YieldBlox "), "Blend · YieldBlox")
        XCTAssertEqual(StellarEarnModel.poolLabel("Blend"), "Blend")
        XCTAssertEqual(StellarEarnModel.poolShortName("Blendex"), "Blendex", "only the word Blend")
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
        let xlm = try market(priceUsd: 0.1901)
        XCTAssertEqual(StellarEarnModel.earned(owner), 10_000_000)
        XCTAssertEqual(try XCTUnwrap(StellarEarnModel.earnedUsd(owner, market: xlm)), 0.1901, accuracy: 1e-12, "1 XLM earned, at XLM's $0.1901")
        let publicView = try position(earned: nil)
        XCTAssertNil(StellarEarnModel.earned(publicView), "the public view has no record")
        XCTAssertNil(StellarEarnModel.earnedUsd(publicView, market: xlm))
        let onlyPublic = StellarEarnModel.totals(positions: [publicView], markets: [xlm], spot: nil)
        XCTAssertNil(onlyPublic.earned, "nothing known: unread, never $0")
        XCTAssertNil(StellarEarnModel.earnedText(onlyPublic))
        // Short of one, the total is what is known, said to be a lower bound as Portfolio's P&L is.
        let mixed = StellarEarnModel.totals(positions: [owner, publicView], markets: [xlm], spot: nil)
        XCTAssertEqual(try XCTUnwrap(mixed.earned), 0.1901, accuracy: 1e-12)
        XCTAssertFalse(mixed.earnedComplete)
        XCTAssertEqual(StellarEarnModel.earnedText(mixed), "+$0.19*")
        XCTAssertEqual(StellarEarnPositionCard.signed(10_000_000, code: "XLM", decimals: 7), "+1 XLM")
        XCTAssertEqual(StellarEarnPositionCard.signed(-5_000_000, code: "XLM", decimals: 7), "−0.5 XLM")
        XCTAssertEqual(StellarEarnPositionCard.signed(0, code: "XLM", decimals: 7), "0 XLM")
    }

    /// A position whose deposit DyorHQ has no record of (made elsewhere, or before deposits were recorded): the server's
    /// `earned` is then the whole position, which isn't earnings, so Earn and Home show it unknown.
    func testAPositionWithNoRecordedDepositShowsNoEarnings() throws {
        let xlm = try market(priceUsd: 0.1901)
        let elsewhere = try position(earned: "1000000000", complete: false)
        XCTAssertNil(StellarEarnModel.earned(elsewhere), "100 XLM supplied isn't 100 XLM earned")
        XCTAssertNil(StellarEarnModel.earnedUsd(elsewhere, market: xlm))
        XCTAssertNil(StellarEarnPositionRow.earnedUsd(elsewhere, markets: [xlm]), "Home's Earn row shows Earn's figure")
        let totals = StellarEarnModel.totals(positions: [elsewhere, try position(valueUsd: 19.01)], markets: [xlm], spot: nil)
        XCTAssertEqual(try XCTUnwrap(totals.earned), 0.1901, accuracy: 1e-12, "only the recorded one counts")
        XCTAssertFalse(totals.earnedComplete)
        XCTAssertEqual(StellarEarnPositionRow.earnedUsd(try position(), markets: [xlm]) ?? 0, 0.1901, accuracy: 1e-12)
    }

    /// Earnings in dollars are the earnings at the market's price, as Portfolio's P&L counts them, never a share of the
    /// position's value, which the server rounds to the cent: small and emptied positions were priced wrong that way.
    func testEarningsArePricedAtTheirMarketsPriceNotThePositionsRoundedValue() throws {
        let xlm = try market(priceUsd: 0.18)
        // 0.03 XLM supplied ($0.0054, which the server writes $0.01) that earned 0.0331 XLM: $0.005958, not the $0.011 its
        // rounded value would make of it.
        let small = try position(supplied: "300000", earned: "331000", valueUsd: 0.01)
        XCTAssertEqual(try XCTUnwrap(StellarEarnModel.earnedUsd(small, market: xlm)), 0.0331 * 0.18, accuracy: 1e-12)
        // Dust a withdrawal left behind (936 stroops, valued $0.00) after earning 2,632 stroops: still priced.
        let dust = try position(supplied: "936", earned: "2632", valueUsd: 0)
        XCTAssertEqual(try XCTUnwrap(StellarEarnModel.earnedUsd(dust, market: xlm)), 0.0002632 * 0.18, accuracy: 1e-15)
        XCTAssertEqual(StellarEarnModel.totals(positions: [small, dust], markets: [xlm], spot: nil).earned ?? 0, (0.0331 + 0.0002632) * 0.18, accuracy: 1e-12)
        // The pool's market, else another pool's market of the asset; without one, or without a price, unknown, never $0.
        let otherPool = try decode(EarnMarket.self, """
            {"pool": "CBOTHERPOOL", "poolName": "Blend Fixed", "asset": "\(Self.xlm)", "code": "XLM", "decimals": 7, "supplyApy": 0.02, "borrowApy": 0.04,
             "utilization": 0.5, "totalSupplied": 10, "note": null, "totalSuppliedUsd": 1.8, "freeLiquidityUsd": 0.9, "priceUsd": 0.18, "poolStatus": "active"}
            """)
        XCTAssertEqual(StellarEarnModel.market(of: small, in: [otherPool, xlm])?.pool, Self.pool, "its own pool's market first")
        XCTAssertEqual(StellarEarnModel.market(of: small, in: [otherPool])?.pool, "CBOTHERPOOL", "the asset is priced the same in any pool")
        XCTAssertNil(StellarEarnModel.market(of: small, in: [try market(Self.blendUSDC, code: "USDC")]))
        XCTAssertNil(StellarEarnModel.earnedUsd(small, market: nil), "the markets not read")
        XCTAssertNil(StellarEarnModel.earnedUsd(small, market: try market(priceUsd: nil)), "no price")
        XCTAssertNil(StellarEarnModel.totals(positions: [small], markets: [], spot: nil).earned)
    }

    /// The figures a testnet account had on a local stack (WP-35, 2026-10-17): 100 XLM supplied to Blend TestnetV2 and 40
    /// withdrawn 20 seconds later (Horizon's balance changes: exactly 100 and 40 XLM), as `/v1/holdings` answered at once.
    /// Blend's own position for the account then, read on chain, was 253,794,932 b-tokens × get_reserve's b_rate
    /// 2.364119164290 = 60.0001462 XLM at the reserve's last accrual: the API's 60.0001603 is it plus the seconds of
    /// interest since, which Blend's SDK accrues to the time of the read. XLM's reference price then: $0.181059.
    func testEarnedSoFarIsTheValueNowPlusWithdrawalsLessDeposits() throws {
        let row = try decode(EarnPosition.self, """
            {"pool": "\(Self.pool)", "asset": "\(Self.xlm)", "code": "XLM", "supplied": "600001603", "poolName": "Blend TestnetV2",
             "deposited": "1000000000", "withdrawn": "400000000", "earned": "1603", "earnedComplete": true,
             "supplyApy": 5.135860714113084, "valueUsd": 10.81}
            """)
        let earned = try XCTUnwrap(StellarEarnModel.earned(row))
        XCTAssertEqual(earned, StellarEarnModel.units(row.supplied) + 400_000_000 - 1_000_000_000)
        XCTAssertEqual(StellarEarnPositionCard.signed(earned, code: "XLM", decimals: 7), "+0.00016 XLM", "in the asset, in the app's number style")
        let xlm = try market(priceUsd: 0.181059)
        let usd = try XCTUnwrap(StellarEarnModel.earnedUsd(row, market: xlm))
        XCTAssertEqual(usd, 0.0001603 * 0.181059, accuracy: 1e-15, "in dollars, at the market's price")
        XCTAssertEqual(PriceFormat.usdValue(usd, signed: true), "+<$0.01")
        let totals = StellarEarnModel.totals(positions: [row], markets: [xlm], spot: nil)
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
        let markets = [try market(priceUsd: 0.19), try market(Self.blendUSDC, code: "USDC", priceUsd: 0.9999)]
        let totals = StellarEarnModel.totals(positions: [xlm, busdc], markets: markets, spot: spot)
        XCTAssertEqual(try XCTUnwrap(totals.supplied), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.averageApy), 3.75, accuracy: 1e-9, "3% on $30 and 6% on $10")
        XCTAssertEqual(try XCTUnwrap(totals.earned), 1 * 0.19 + 0.1 * 0.9999, accuracy: 1e-9, "1 XLM and 0.1 USDC earned, at their markets' prices")
        XCTAssertTrue(totals.earnedComplete)
        XCTAssertEqual(StellarEarnModel.earnedText(totals), "+$0.29", "Earn's Assets tab")
        XCTAssertEqual(try XCTUnwrap(totals.wallet), 12.3, accuracy: 1e-9, "the wallet's XLM; its USDC isn't an asset Earn lends here")
        XCTAssertNil(StellarEarnModel.totals(positions: [xlm], markets: markets, spot: nil).wallet, "the holdings not read: unread")
        let none = StellarEarnModel.totals(positions: [], markets: markets, spot: [])
        XCTAssertEqual(none.supplied, 0)
        XCTAssertEqual(none.earned, 0)
        XCTAssertTrue(none.earnedComplete)
        // A loss (a pool that lost value) is signed as one.
        let loss = StellarEarnModel.totals(positions: [try position(earned: "-10000000", valueUsd: 20)], markets: markets, spot: [])
        XCTAssertEqual(StellarEarnModel.earnedText(loss), "−$0.19")
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
        // Nothing shown under another market's name, and unread until its own read answers.
        let model = StellarEarnModel()
        XCTAssertEqual(model.activity(for: try market()), .init(market: try market().id, items: [], status: .unread))
    }

    /// The History tab reads its market's deposits and withdrawals on its own (`section=earn&market=<pool>:<asset>`): the
    /// account's activity, which Portfolio and Recent Activity word their rows from, keeps every section's items, and its
    /// read status stays its own.
    func testTheHistoryTabsReadLeavesTheAccountsActivityAsItWas() async throws {
        let server = EarnServer()
        let store = try await resumedStore(server, seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        await store.refreshActivity()
        let all = store.activity.map(\.id)
        XCTAssertEqual(all, ["swap-1", "launch-1", "earn-xlm"], "the account's activity, every section")
        XCTAssertEqual(store.status(.activity), .read)

        let xlm = try market()
        let model = StellarEarnModel()
        await model.loadActivity(store: store, market: xlm)
        XCTAssertEqual(model.activity(for: xlm).items.map(\.id), ["earn-xlm"])
        XCTAssertEqual(model.activity(for: xlm).status, .read)
        XCTAssertEqual(model.activity(for: try market(Self.blendUSDC, code: "USDC")).status, .unread, "another market's isn't this one's")
        XCTAssertEqual(store.activity.map(\.id), all, "the account's activity is as it was: Earn's read never replaces it")
        XCTAssertEqual(store.status(.activity), .read)
        let read = try XCTUnwrap(server.requests.last { $0.path == "/v1/activity" })
        XCTAssertEqual(read.query, ["section": "earn", "market": "\(Self.pool):\(Self.xlm)"])

        // A read that fails keeps the rows shown, and says so.
        server.failActivity = true
        await model.loadActivity(store: store, market: xlm)
        XCTAssertEqual(model.activity(for: xlm).items.map(\.id), ["earn-xlm"])
        XCTAssertEqual(model.activity(for: xlm).status, .failed)
        XCTAssertEqual(store.status(.activity), .read, "Earn's failure isn't the account's activity's")
    }

    /// A passkey account in the public view: the History tab waits for the sign-in, nothing is asked, and the account's
    /// activity status is untouched.
    func testTheHistoryTabWaitsForTheSignInWithoutAsking() async throws {
        let server = EarnServer()
        let store = try await resumedStore(server, seed: nil)
        let before = store.status(.activity)
        let model = StellarEarnModel()
        await model.loadActivity(store: store, market: try market())
        XCTAssertEqual(model.activity(for: try market()).status, .needsSignIn)
        XCTAssertEqual(store.status(.activity), before, "Earn's read leaves the account's activity's status as it was")
        XCTAssertFalse(server.requests.contains { $0.path == "/v1/activity" || $0.path.hasPrefix("/v1/auth") }, "nothing asked")
    }

    // MARK: - Portfolio's Earn card

    /// "Earned so far" is the all-time Earn P&L, whatever the period shown: every market with a recorded deposit, open or
    /// withdrawn in full, at today's prices, as the P&L reads with All chosen. Portfolio reads it beside the period's.
    func testPortfoliosEarnedSoFarIsTheAllTimeEarnPnL() async throws {
        let server = EarnServer()
        let store = try await resumedStore(server, seed: (0..<32).map { _ in UInt8.random(in: 0...255) })
        let folder = FileManager.default.temporaryDirectory.appending(path: "stellar-earn-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let model = StellarPortfolioModel(saved: StellarSaved(screens: SavedScreens(directory: folder, build: "test")))
        await model.load(store, period: .week, force: false)
        XCTAssertEqual(Set(server.requests.filter { $0.path == "/v1/portfolio" }.map { $0.query["period"] }), ["week", "all"])
        let lifetime = try XCTUnwrap(model.shown(.all, live: store.portfolio[.all], status: store.status(.portfolio))?.figures.stats(.earn))
        XCTAssertEqual(StellarEarnModel.earnedSoFarText(lifetime), "+$1.25*", "the all-time Earn P&L, a lower bound when a market's isn't known")
        XCTAssertEqual(store.portfolio[.week]?.sections.earn.pnl, 0.0023, "the week's own P&L beside it")

        // Read once; again with a pull; never twice when All is the period shown.
        let lifetimeReads = { server.requests.filter { $0.path == "/v1/portfolio" && $0.query["period"] == "all" }.count }
        await model.load(store, period: .month, force: false)
        XCTAssertEqual(lifetimeReads(), 1)
        await model.load(store, period: .month, force: true)
        XCTAssertEqual(lifetimeReads(), 2)
        await model.load(store, period: .all, force: true)
        XCTAssertEqual(lifetimeReads(), 3)
        XCTAssertEqual(StellarEarnModel.earnedSoFarText(StellarPortfolioModel.Stats()), "$0.00", "nothing earned yet")
    }

    // MARK: - Reads against a Lite server

    /// The store of a session resumed as an account set up on this iPhone, against `server`: a seed account with its key
    /// here, which signs in silently, or (`seed` nil) an account with no key and no session here, as a passkey account in
    /// the public view, which nothing may prompt.
    private func resumedStore(_ server: EarnServer, seed: [UInt8]?) async throws -> LiteStore {
        let address = try StellarSigner(seed: seed ?? (0..<32).map { _ in UInt8.random(in: 0...255) }).address
        UserDefaults.standard.set(true, forKey: LiteSession.activatedKey(address))
        addTeardownBlock {
            server.stop()
            StellarKeychain.erase(account: address)
            UserDefaults.standard.removeObject(forKey: LiteSession.activatedKey(address))
        }
        let keys = seed.map { seed in
            GatedSeedKeyProvider(address: address, methodLabel: "Email & Password", network: "testnet", appLockApplies: { false }, seed: { seed })
        }
        let session = LiteSession(env: server.environment, stellarAddress: address, monad: nil, keys: keys)
        // The store holds its session weakly: the test holds it until it ends.
        addTeardownBlock { withExtendedLifetime(session) {} }
        await session.resumeAtLaunch()
        return try XCTUnwrap(session.store)
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
            // Earn's history is its own read: the account's activity, which other screens word their rows from, is never
            // replaced by Earn's.
            XCTAssertFalse(text.contains("refreshActivity("), name)
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

/// A Lite server for one test, on a host of its own under `.stellar-earn.test`: the config, the fees, a seed account's
/// sign-in and, only with the session it issued, the account's activity (`section` and `market` filter it, as the API's
/// do) and the portfolio of any period, the all-time one's Earn P&L $1.25 and short of a market's. It keeps every request.
final class EarnServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        /// Below the API's base: "/v1/activity".
        let path: String
        let query: [String: String]
        let authorization: String?
        let body: Data?
    }

    static let pool = "CCEBVDYM32YNYCVNRXQKDFFPISJJCV557CDZEIRBEE4NCV4KHPQ44HGF"
    static let xlm = "CDLZFC3SYJYDZT7K67VZ75HPJVIEUVNIXF47ZG2FB2RMQQVU2HHGCYSC"

    let host = "lite-\(UUID().uuidString.lowercased()).stellar-earn.test"
    private let lock = NSLock()
    private var seen: [Request] = []
    private var issued: String?
    private var failing = false

    init() {
        URLProtocol.registerClass(EarnStub.self)
        EarnStub.serve(host: host) { [self] in answer($0) }
    }

    var environment: LiteEnvironment { LiteEnvironment(apiURL: URL(string: "https://\(host)/lite")!, pinned: .testnet, buildNumber: 1000) }

    /// Every request, in order.
    var requests: [Request] { lock.withLock { seen } }

    /// The activity's reads fail, as the API's do when it can't read the history.
    var failActivity: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func stop() { EarnStub.serve(host: host, nil) }

    /// The account's activity: a swap, a launch trade and a deposit to Blend's XLM market, with the market each is of.
    private static let activity: [(section: String, market: String?, json: String)] = [
        ("spot", nil, #"{"type": "tx", "id": "swap-1", "kind": "swap", "summary": "Swapped", "status": "success", "at": "2026-10-17T10:00:00Z", "section": "spot", "hash": "aa", "ref": null}"#),
        ("launch", nil, #"{"type": "tx", "id": "launch-1", "kind": "launch_buy", "summary": "Bought", "status": "success", "at": "2026-10-17T09:00:00Z", "section": "launch", "hash": "bb", "ref": null}"#),
        ("earn", "\(pool):\(xlm)", #"{"type": "tx", "id": "earn-xlm", "kind": "earn_deposit", "summary": "Supplied XLM", "status": "success", "at": "2026-10-17T08:00:00Z", "section": "earn", "hash": "cc", "ref": {"market": "\#(pool):\#(xlm)"}}"#),
    ]

    private func answer(_ request: Request) -> (status: Int, body: Data) {
        let (session, failing) = lock.withLock {
            seen.append(request)
            return (issued.map { request.authorization == "Bearer \($0)" } ?? false, self.failing)
        }
        switch (request.method, request.path) {
        case ("GET", "/v1/config"): return (200, Data(Self.config.utf8))
        case ("GET", "/v1/fees"): return (200, Data(Self.fees.utf8))
        case ("POST", "/v1/auth/challenge"):
            let address = request.body.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?["address"] ?? ""
            let nonce = "earn-nonce-0123456789"
            let message = ["DyorHQ Lite sign-in", "Network: testnet", "Address: \(address)", "Nonce: \(nonce)", "Issued: \(Self.time(0))"].joined(separator: "\n")
            return (200, try! JSONSerialization.data(withJSONObject: ["nonce": nonce, "message": message, "expiresAt": Self.time(300)]))
        case ("POST", "/v1/auth/verify"):
            let token = "jwt-\(UUID().uuidString)"
            lock.withLock { issued = token }
            let body: [String: Any] = ["token": token, "expiresAt": Self.time(3600), "refreshToken": "lrt_earn", "refreshExpiresAt": Self.time(30 * 86_400),
                                       "tester": ["address": "G", "label": NSNull()]]
            return (200, try! JSONSerialization.data(withJSONObject: body))
        case ("GET", "/v1/activity"):
            guard session else { return (401, Self.error("not_signed_in", "Sign in again.")) }
            if failing { return (503, Self.error("rpc_unavailable", "The history couldn't be read just now.")) }
            let items = Self.activity.filter { item in
                (request.query["section"].map { $0 == item.section } ?? true) && (request.query["market"].map { $0 == item.market } ?? true)
            }
            return (200, Data(#"{"items": [\#(items.map(\.json).joined(separator: ", "))]}"#.utf8))
        case ("GET", "/v1/portfolio"):
            guard session else { return (401, Self.error("not_signed_in", "Sign in again.")) }
            return (200, Self.portfolio(period: request.query["period"] ?? "week"))
        default:
            return (404, Self.error("not_found", "No such route."))
        }
    }

    /// StellarKit's `portfolio.json` over `period`; the all-time one's Earn P&L $1.25, short of a market whose isn't known.
    private static func portfolio(period: String) -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() } // StellarEarnTests.swift → Tests → Internal → ios → app → S
        let url = root.appending(path: "ios/Packages/StellarKit/Tests/LiteClientTests/Fixtures/portfolio.json")
        guard var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              var sections = json["sections"] as? [String: Any], var earn = sections["earn"] as? [String: Any] else { return Data() }
        json["period"] = period
        if period == "all" {
            earn["pnl"] = 1.25
            earn["pnlComplete"] = false
            sections["earn"] = earn
            json["sections"] = sections
        }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private static let config = """
        {"network":"testnet","passphrase":"Test SDF Network ; September 2015","rpcUrl":"http://127.0.0.1:9/rpc",
         "horizonUrl":"http://127.0.0.1:9/horizon","activation":"friendbot","sponsor":"\(PinnedContracts.testnet.sponsor)",
         "assets":[{"id":"XLM","code":"XLM","name":"Stellar Lumens","decimals":7,"contract":"\(xlm)","classic":"native","note":null}],
         "contracts":{"launchpad":null,"moments":null,"soroswapRouter":"C","blendPools":[{"id":"\(pool)","name":"Blend TestnetV2"}]},"allowlist":{},
         "bridge":{"routes":[],"monad":null},"flags":{"enabled":true},"minBuild":1,"inviteRequired":false,"faucet":{"amount":"10000"}}
        """

    private static let fees = """
        {"network":"testnet","baseReserve":"5000000","baseFee":"100","inclusionFee":{"classic":"100","soroban":"150"},
         "estimates":{"blend_submit_withdraw":"500000"},"estimateBasis":{},"updatedAt":null}
        """

    private static func error(_ code: String, _ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": code, "message": message]])
    }

    /// `seconds` from now, as the API writes times.
    private static func time(_ seconds: TimeInterval) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds)) }
}

/// Answers the requests to `.stellar-earn.test` hosts (`URLSession.shared`, which `LiteAPI` uses, asks the registered
/// protocols), each with its host's server; every other request goes out as usual.
final class EarnStub: URLProtocol {
    typealias Handler = @Sendable (EarnServer.Request) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func serve(host: String, _ handler: Handler?) { lock.withLock { handlers[host] = handler } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".stellar-earn.test") ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        let seen = EarnServer.Request(method: request.httpMethod ?? "GET", path: String(url.path.dropFirst("/lite".count)), query: query,
                                      authorization: request.value(forHTTPHeaderField: "authorization"), body: Self.body(of: request))
        guard let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, body) = handler(seen)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
