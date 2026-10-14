import Foundation

/// The one dollar price a DyorHQ launch coin is valued at, on every screen that values one (Home's Launch tab, the
/// Portfolio, the Launch board and page, My Launchpad): the price Spot shows for it (`PriceService`, which with DyorHQ
/// venues on reads the coin's own curve or pool) when Spot has one; otherwise the launch's own decimal price in its pair
/// asset (`Launch.pairPrice`, read from the same curve or pool) times that asset's dollar price. Never the integer
/// `Launch.price`, whose whole units of a 6-decimal pair move in steps of $0.000001.
public enum DyorPrice {
    /// `launch`'s dollars per whole coin: `spot` (Spot's price for the coin) when it is a positive finite number, else
    /// `launch.usdPrice(pairUSD:)`; nil when neither is known.
    public static func launch(_ launch: Launch, spot: Double?, pairUSD: Double?) -> Double? {
        if let spot = valid(spot) { return spot }
        return launch.usdPrice(pairUSD: pairUSD)
    }

    /// `price` when it is a positive finite number: a price of 0, below 0, NaN or infinite is no price.
    public static func valid(_ price: Double?) -> Double? {
        guard let price, price.isFinite, price > 0 else { return nil }
        return price
    }
}
