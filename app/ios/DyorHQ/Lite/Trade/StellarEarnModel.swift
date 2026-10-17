// Stellar's Earn: Blend's markets, the account's positions in them, the rate history, and the rules of Earn's ticket
// (docs/DESIGN-stellar-parity.md §8.6.3). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import BigInt
import DyorKit
import DyorLite
import Foundation
import StellarKit

/// A Blend pool's status as Earn shows it, from `EarnMarket.poolStatus`: active; on ice, which pauses borrowing; frozen,
/// which pauses deposits too. Withdrawals go on in all three while the pool has free liquidity. A status this build
/// doesn't know counts as frozen, as the server counts a status Blend doesn't define, so it never invites a deposit; a
/// market from a server that sends none shows no status.
enum StellarPoolStatus: Equatable {
    case active, onIce, frozen

    init?(_ status: String?) {
        guard let status else { return nil }
        switch status {
        case "active": self = .active
        case "on_ice": self = .onIce
        default: self = .frozen
        }
    }

    /// Whether the pool takes deposits: every status but frozen.
    var takesDeposits: Bool { self != .frozen }
}

/// The rate chart's two ranges, the chips 7D and 30D: the past week and the past month of `/v1/earn/history`.
enum StellarRateRange: String, CaseIterable, Identifiable {
    case week, month
    var id: String { rawValue }

    /// The range as the API names it.
    var period: VolumePeriodKey {
        switch self {
        case .week: .week
        case .month: .month
        }
    }
}

/// Earn's reads and rules, as Monad's `PerpsModel` keeps Perps'. Blend's markets are public and the account's positions a
/// viewer read (`/v1/holdings`' Earn part), so Earn fills with or without a session (decision 6): in the public view a
/// position's `earned` is nil, and Earn shows that figure unread, never 0. The figures live in `LiteStore`; this model
/// reads them again every 30 seconds while Earn is on screen, keeps the rate history and the Blend test asset's swap
/// route, and holds the ticket's rules, which the screen and the tests share.
@MainActor
@Observable
final class StellarEarnModel {
    /// How often Earn reads Blend's markets and the account again while it is on screen and the app is active.
    static let pollInterval: Duration = .seconds(30)
    /// The step kind a deposit's network fee is estimated under: what Max keeps back of XLM.
    static let depositStepKind = "blend_submit_deposit"
    /// What the route check prices: one whole unit of the wallet's asset (7 decimals).
    static let routeProbeUnits: Int64 = 10_000_000
    /// The slippage the route check asks its quote at, as Swap's default.
    static let routeProbeSlippageBps = 100

    /// The rate history on screen, with the market and range it is of: never shown under another's name.
    struct RateHistory: Equatable {
        let market: String
        let range: StellarRateRange
        let points: [StellarEarnHistory.Point]
    }

    /// Every position's figures together, for the Assets tab and Portfolio's Earn card: each nil while it can't be told (a
    /// position or a balance not priced, a record DyorHQ doesn't have), never 0.
    struct Totals: Equatable {
        /// What every position is worth now, in dollars.
        let supplied: Double?
        /// What the positions have earned so far, in dollars at the prices their values are counted at: those whose
        /// earnings are known, nil when none's are (the public view).
        let earned: Double?
        /// Whether `earned` counts every position: false when one's earnings aren't known (a deposit DyorHQ has no record
        /// of, a position with no price), so `earned` is a lower bound, shown with "*" as Portfolio's P&L is.
        let earnedComplete: Bool
        /// The supply rate across the positions, weighted by their values, in percent (4.21 for 4.21%).
        let averageApy: Double?
        /// What the wallet holds of the markets' assets, in dollars.
        let wallet: Double?
    }

    /// A read of the markets has answered at least once, or failed: until then Earn shows a spinner, not No Markets.
    private(set) var marketsRead = false
    private(set) var history: RateHistory?
    /// The last history read failed, for this market and range: the chart says so rather than "no history".
    private(set) var failedHistory: RateKey?
    private(set) var historyLoading = false
    /// Whether a swap into a pool's own test asset finds a route, by market id: absent until a quote said.
    private(set) var routes: [String: Bool] = [:]
    private var loads = 0
    @ObservationIgnored private var historyGeneration = 0

    /// A market and a range of the rate chart.
    struct RateKey: Hashable {
        let market: String
        let range: StellarRateRange
    }

    /// A read of Earn's own is under way (the poll, Try Again).
    var loading: Bool { loads > 0 }

    // MARK: Reading

    /// Blend's markets, the account's positions (the holdings' Earn part) and its balances, read again, together.
    func load(store: LiteStore) async {
        loads += 1
        defer {
            loads -= 1
            marketsRead = true
        }
        async let markets: Void = store.refreshEarn()
        async let holdings: Void = store.refreshHoldings()
        async let account: Void = store.refreshAccount()
        _ = await (markets, holdings, account)
    }

    /// Reads Earn again every 30 seconds until the task is cancelled (Earn left the screen, or the app went to the
    /// background).
    func poll(store: LiteStore) async {
        while !Task.isCancelled {
            await load(store: store)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// `market`'s supply rate and utilization over `range`. A read that a later one overtook changes nothing.
    func loadHistory(store: LiteStore, market: EarnMarket, range: StellarRateRange) async {
        historyGeneration &+= 1
        let generation = historyGeneration
        let key = RateKey(market: market.id, range: range)
        historyLoading = true
        defer { if generation == historyGeneration { historyLoading = false } }
        do {
            let read = try await store.earnHistory(pool: market.pool, asset: market.asset, range: range.period)
            guard generation == historyGeneration else { return }
            history = RateHistory(market: market.id, range: range, points: read.points)
            if failedHistory == key { failedHistory = nil }
        } catch {
            guard generation == historyGeneration, !Task.isCancelled else { return }
            failedHistory = key
        }
    }

    /// The rate history of `market` over `range`, only when that is what was read.
    func points(market: EarnMarket, range: StellarRateRange) -> [StellarEarnHistory.Point] {
        guard let history, history.market == market.id, history.range == range else { return [] }
        return history.points
    }

    /// Whether the last history read of `market` over `range` failed.
    func historyFailed(market: EarnMarket, range: StellarRateRange) -> Bool {
        failedHistory == RateKey(market: market.id, range: range)
    }

    /// Asks Swap whether `twin` (the wallet's asset) can be swapped into `own` (a pool's own test asset), once per market:
    /// the ticket offers that swap only when a quote found a route. A quote that couldn't be read leaves it unknown, to
    /// be asked again.
    func checkRoute(store: LiteStore, market: EarnMarket, from twin: AssetInfo, to own: AssetInfo) async {
        guard routes[market.id] == nil else { return }
        do {
            let quote = try await store.swapQuote(sell: twin.id, buy: own.id, amount: Self.routeProbeUnits, slippageBps: Self.routeProbeSlippageBps)
            routes[market.id] = (Int64(quote.best.amountOut) ?? 0) > 0
        } catch let error as LiteAPIError where error.code == "no_route" {
            routes[market.id] = false
        } catch {}
    }

    // MARK: Markets

    /// The market `requested` names (a Stellar destination's `stellar:earn/<id>`), else the account's largest position,
    /// else the pool's USDC market, else the first. A destination names a market by its id (the pool's and the asset's
    /// contracts run together), by `<pool>:<asset>`, by its asset's contract or by its asset's registry id.
    static func defaultMarket(_ markets: [EarnMarket], positions: [EarnPosition], requested: String?, assets: [AssetInfo]) -> EarnMarket? {
        if let requested, let named = markets.first(where: { matches($0, reference: requested, assets: assets) }) { return named }
        var largest: (market: EarnMarket, value: Double)?
        for position in positions where units(position.supplied) > 0 {
            guard let market = markets.first(where: { $0.pool == position.pool && $0.asset == position.asset }) else { continue }
            let value = position.valueUsd ?? 0
            if largest.map({ value > $0.value }) ?? true { largest = (market, value) }
        }
        if let largest { return largest.market }
        return markets.first { $0.code == "USDC" } ?? markets.first
    }

    /// Whether `reference` names `market`.
    static func matches(_ market: EarnMarket, reference: String, assets: [AssetInfo]) -> Bool {
        if reference == market.id || reference == "\(market.pool):\(market.asset)" || reference == market.asset { return true }
        return assets.contains { $0.id == reference && $0.contract == market.asset }
    }

    /// The account's position in `market`, if it has one.
    static func position(in positions: [EarnPosition], for market: EarnMarket) -> EarnPosition? {
        positions.first { $0.pool == market.pool && $0.asset == market.asset && units($0.supplied) > 0 }
    }

    /// The wallet's asset that `market`'s pool lends its own test version of, by its code: the wallet's USDC beside Blend's
    /// test USDC on testnet. Nil for every other market. The pool's own is a registry asset that isn't listed, and the
    /// wallet's is the listed one with its code.
    static func walletTwin(of market: EarnMarket, assets: [AssetInfo]) -> (twin: AssetInfo, own: AssetInfo)? {
        guard let own = assets.first(where: { $0.contract == market.asset }), own.listed == false,
              let twin = assets.first(where: { $0.code == own.code && $0.id != own.id && $0.listed != false }) else { return nil }
        return (twin, own)
    }

    // MARK: The ticket

    /// The ticket's two actions.
    enum Side { case deposit, withdraw }

    /// Whether Deposit can be tapped: a key that signs, and a pool that takes deposits (not frozen).
    static func canDeposit(_ market: EarnMarket, canSign: Bool) -> Bool {
        canSign && (StellarPoolStatus(market.poolStatus)?.takesDeposits ?? true)
    }

    /// Whether Withdraw can be tapped: a key that signs, and a position in the market.
    static func canWithdraw(_ position: EarnPosition?, canSign: Bool) -> Bool {
        canSign && position.map { units($0.supplied) > 0 } == true
    }

    /// What's wrong with `amount` (base units, nil when the field isn't a number) for `side`, in the app's language; nil
    /// when the review may open. A deposit spends at most what's available (`LiteStore.maxAmount`: for XLM, what keeps
    /// the network fee and the minimum balance back), a withdrawal takes back at most what's supplied.
    static func problem(_ side: Side, amount: Int64?, available: Int64, supplied: Int64) -> LocalizedStringResource? {
        guard let amount, amount > 0 else {
            switch side {
            case .deposit: return LocalizedStringResource("Enter an amount to deposit.", table: "StellarEarn", comment: "Stellar Earn, under the ticket: Deposit was tapped with no amount in the field")
            case .withdraw: return LocalizedStringResource("Enter an amount to withdraw.", table: "StellarEarn", comment: "Stellar Earn, under the ticket: Withdraw was tapped with no amount in the field")
            }
        }
        switch side {
        case .deposit:
            return amount > available ? LocalizedStringResource("More than your available balance.") : nil
        case .withdraw:
            return amount > supplied ? LocalizedStringResource("More than you've supplied.", table: "StellarEarn", comment: "Stellar Earn, under the ticket: Withdraw was tapped with more than the account has lent in this market") : nil
        }
    }

    /// The field's amount in `decimals` base units: nil when it isn't a plain positive decimal or doesn't fit.
    static func amount(_ amountText: String, decimals: Int) -> Int64? {
        Amount.parse(amountText, decimals: decimals).flatMap { Int64(exactly: $0) }
    }

    /// `percent` of `available`, in base units, rounded down: what the 25, 50 and 75% buttons write.
    static func share(_ percent: Int, of available: Int64) -> Int64 {
        guard available > 0, percent > 0 else { return 0 }
        return Int64(BigInt(available) * BigInt(min(percent, 100)) / 100)
    }

    /// What `amount` of `market`'s asset would earn in a year at today's supply rate, in dollars; nil without a price.
    static func yearlyInterestUsd(amount: Int64, market: EarnMarket) -> Double? {
        guard amount > 0, let price = market.priceUsd, price.isFinite else { return nil }
        return whole(amount, decimals: market.decimals) * market.supplyApy * price
    }

    /// The same in the asset's base units, for an asset with no price.
    static func yearlyInterestUnits(amount: Int64, market: EarnMarket) -> Int64 {
        guard amount > 0, market.supplyApy.isFinite, market.supplyApy > 0 else { return 0 }
        return Int64((Double(amount) * market.supplyApy).rounded(.down))
    }

    // MARK: Positions

    /// A position's earnings so far in base units, signed: what Blend says it holds now, plus what was withdrawn, less what
    /// was deposited (the server's `earned`). Nil when DyorHQ has no record of it (the public view), and when the record
    /// misses a deposit (`earnedComplete` false: one made elsewhere, or before DyorHQ recorded deposits), where the
    /// figure would count that deposit as earnings.
    static func earned(_ position: EarnPosition) -> Int64? {
        guard position.earnedComplete != false else { return nil }
        return position.earned.flatMap { Int64($0) }
    }

    /// What a position has earned in dollars, at the price its value is counted at; nil without a record or a value.
    static func earnedUsd(_ position: EarnPosition) -> Double? {
        guard let earned = earned(position), let value = position.valueUsd, value.isFinite else { return nil }
        let supplied = units(position.supplied)
        guard supplied > 0 else { return nil }
        return Double(earned) / Double(supplied) * value
    }

    /// Every position together, and what the wallet holds of the markets' assets (`spot`: nil while the holdings aren't
    /// read).
    static func totals(positions: [EarnPosition], markets: [EarnMarket], spot: [StellarHoldings.SpotHolding]?) -> Totals {
        let held = positions.filter { units($0.supplied) > 0 }
        let values = held.map(\.valueUsd)
        let supplied: Double? = values.contains(where: { $0 == nil }) ? nil : values.reduce(0) { $0 + ($1 ?? 0) }
        let earnings = held.map(earnedUsd)
        let known = earnings.compactMap { $0 }
        let earned: Double? = !held.isEmpty && known.isEmpty ? nil : known.reduce(0, +)
        var weighted = 0.0
        var weight = 0.0
        for position in held {
            guard let apy = position.supplyApy, apy.isFinite, let value = position.valueUsd, value > 0 else { continue }
            weighted += apy * value
            weight += value
        }
        let averageApy = weight > 0 ? StellarPercent(weighted / weight).value : nil
        let lent = Set(markets.map(\.asset))
        let wallet: Double? = spot.flatMap { rows in
            let mine = rows.filter { lent.contains($0.contract) && $0.units > 0 }
            return mine.contains(where: { $0.valueUsd == nil }) ? nil : mine.reduce(0) { $0 + ($1.valueUsd ?? 0) }
        }
        return Totals(supplied: supplied, earned: earned, earnedComplete: known.count == held.count, averageApy: averageApy, wallet: wallet)
    }

    /// What the account's positions have earned so far, in dollars, as Earn's Assets tab and Portfolio's Earn card show it:
    /// signed, with "*" when a position's earnings aren't known (a lower bound, as Portfolio's P&L); nil (unread) while
    /// none are known.
    static func earnedText(_ totals: Totals) -> String? {
        totals.earned.map { PriceFormat.usdValue($0, signed: true) + (totals.earnedComplete ? "" : "*") }
    }

    /// The account's deposits into and withdrawals from `market`, from the activity read (`/v1/activity`, which keys an
    /// Earn item by `<pool>:<asset>`).
    static func history(_ items: [StellarActivityItem], market: EarnMarket) -> [StellarActivityItem] {
        let key = "\(market.pool):\(market.asset)"
        return items.filter { $0.section == "earn" && ($0.ref?.market == key || $0.ref?.market == market.id) }
    }

    /// A base-units amount as the API writes it, as a number; 0 for anything else.
    static func units(_ text: String) -> Int64 { Int64(text) ?? 0 }

    /// Base units in whole units of an asset with `decimals`.
    static func whole(_ units: Int64, decimals: Int) -> Double {
        Double(units) / pow(10, Double(max(0, decimals)))
    }
}
#endif
