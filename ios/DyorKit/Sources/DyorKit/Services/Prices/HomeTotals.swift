import Foundation

/// Home's section totals (Spot, Launch, Moments), with every address counted exactly once. A DyorHQ coin the wallet holds
/// is listed in Spot like any token (with DyorHQ venues on it has a Spot price there), and also in the Launch or the
/// Moments tab when that tab lists it; adding the tabs up would count it twice. So a coin is counted under Launch, or
/// else under Moments, only when that tab actually lists it, and otherwise under Spot, where it stays listed either way.
/// Home's Launch tab covers only the newest launches of each launchpad, so a DyorHQ coin it doesn't list still counts,
/// in Spot. Every other token counts in Spot, as before.
///
/// Each address has one price (`prices`): Spot's when Spot has one, so the Launch and Moments tabs show the price Spot
/// shows; otherwise the tab's own (a launch's decimal price, `DyorPrice.launch`; a Moment pool's live price). A price
/// that isn't a positive finite number is none (`DyorPrice.valid`), and a line without a price adds nothing. A Launch or
/// Moments line at address 0 (MON's) names no coin and is left out, so it can never take MON out of Spot.
public struct HomeTotals: Equatable, Sendable {
    /// Where an address is counted.
    public enum Tab: Hashable, Sendable {
        case spot, launch, moments
    }

    /// One holding as a tab lists it.
    public struct Line: Equatable, Sendable {
        public let address: Address
        /// Whole coins: the wallet's balance; for a Moment coin, its coins still owed to the wallet too.
        public let units: Double
        /// The tab's own price, dollars per whole coin; nil when it has none.
        public let price: Double?

        public init(address: Address, units: Double, price: Double?) {
            self.address = address
            self.units = units
            self.price = price
        }
    }

    /// The Spot tab's total: the tokens no other tab counts.
    public let spot: Double
    /// The Launch tab's total: every launch coin it lists.
    public let launch: Double
    /// The Moments tab's total: every Moment coin it lists, held and still owed.
    public let moments: Double
    /// The one price of each address, as counted: Spot's first, then the Launch tab's, then the Moments tab's.
    public let prices: [Address: Double]
    /// The tab each listed address is counted in.
    public let counted: [Address: Tab]

    public static let empty = HomeTotals(spot: [], launch: [], moments: [])

    /// The totals of the lines each tab lists. An address listed twice in one tab is counted at its first line.
    public init(spot: [Line], launch: [Line], moments: [Line]) {
        let launch = launch.filter { !$0.address.isZero }
        let moments = moments.filter { !$0.address.isZero }
        var prices: [Address: Double] = [:]
        for line in spot + launch + moments where prices[line.address] == nil {
            if let price = DyorPrice.valid(line.price) { prices[line.address] = price }
        }
        var counted: [Address: Tab] = [:]
        var totals: [Tab: Double] = [:]
        for (tab, lines) in [(Tab.launch, launch), (.moments, moments), (.spot, spot)] {
            for line in lines where counted[line.address] == nil {
                counted[line.address] = tab
                guard let price = prices[line.address], line.units.isFinite, line.units > 0 else { continue }
                totals[tab, default: 0] += line.units * price
            }
        }
        self.spot = totals[.spot] ?? 0
        self.launch = totals[.launch] ?? 0
        self.moments = totals[.moments] ?? 0
        self.prices = prices
        self.counted = counted
    }

    /// Spot, Launch and Moments together.
    public var total: Double { spot + launch + moments }

    /// `units` of `address` at its one price; nil when it has none.
    public func value(of address: Address, units: Double) -> Double? {
        prices[address].map { units * $0 }
    }
}
