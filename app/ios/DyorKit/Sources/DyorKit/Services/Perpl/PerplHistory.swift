import Foundation

/* Authenticated Perpl trading history (fills, position history, account events). These endpoints are the only
   source for cumulative volume, realized P&L and a trade log — the on-chain Exchange keeps only live state. Every
   call is Ed25519-signed with the account's API key; see PerplAuth.signedGet and PerplFoundation/api-docs. Prices
   and sizes arrive as integers scaled by the market's decimals, and money amounts as decimal strings in collateral
   units (AUSD, 6 decimals); the parsers here return real display units so the app never re-scales. */

/// One order fill (Perpl "Trade History"). `notional` and `fee` are in AUSD; `price`/`size` are in the market's own
/// units. `orderId` joins the fill to its realized-P&L event in position-history; `direction` is Perpl's own label
/// (Open/Close · Long/Short) and `isClose` marks a reducing fill (the ones that realize P&L).
public struct PerplFill: Identifiable, Sendable, Hashable {
    public let id: String
    public let time: Date
    public let marketId: Int
    public let symbol: String
    public let orderId: Int
    public let side: OrderSide
    public let direction: String
    public let isClose: Bool
    public let isMaker: Bool
    public let price: Double
    public let size: Double
    public let fee: Double
    public var notional: Double { price * size }

    public init(id: String, time: Date, marketId: Int, symbol: String, orderId: Int, side: OrderSide, direction: String, isClose: Bool, isMaker: Bool, price: Double, size: Double, fee: Double) {
        self.id = id; self.time = time; self.marketId = marketId; self.symbol = symbol; self.orderId = orderId
        self.side = side; self.direction = direction; self.isClose = isClose
        self.isMaker = isMaker; self.price = price; self.size = size; self.fee = fee
    }

    /// Parses one `Fill` row (see api-docs types.md). Returns nil for a market not in `markets` (can't scale it).
    init?(fill j: [String: Any], markets: [Int: PerpMarket]) {
        guard let mkt = (j["mkt"] as? NSNumber)?.intValue, let market = markets[mkt] else { return nil }
        let oid = (j["oid"] as? NSNumber)?.intValue ?? 0
        let at = j["at"] as? [String: Any]
        let ms = (at?["t"] as? NSNumber)?.doubleValue ?? 0
        let log = (at?["l"] as? NSNumber)?.intValue ?? 0
        // REST OrderType is 1-indexed (api-docs types.md): 1 OpenLong, 2 OpenShort, 3 CloseLong, 4 CloseShort — NOT
        // the on-chain 0-indexed PerpOrderType. A fill that increases a long or reduces a short is a buy.
        let typeRaw = (j["t"] as? NSNumber)?.intValue ?? 0
        let side: OrderSide = (typeRaw == 1 || typeRaw == 4) ? .buy : .sell
        let direction: String
        switch typeRaw {
        case 1: direction = L10n.string(LocalizedStringResource("Open Long", bundle: L10n.kit, comment: "[tight] A Perps fill: it opened or added to a long position."))
        case 2: direction = L10n.string(LocalizedStringResource("Open Short", bundle: L10n.kit, comment: "[tight] A Perps fill: it opened or added to a short position."))
        case 3: direction = L10n.string(LocalizedStringResource("Close Long", bundle: L10n.kit, comment: "[tight] A Perps fill: it closed or reduced a long position."))
        case 4: direction = L10n.string(LocalizedStringResource("Close Short", bundle: L10n.kit, comment: "[tight] A Perps fill: it closed or reduced a short position."))
        default:
            direction = side == .buy
                ? L10n.string(LocalizedStringResource("Buy", bundle: L10n.kit, comment: "[tight] A Perps fill that bought."))
                : L10n.string(LocalizedStringResource("Sell", bundle: L10n.kit, comment: "[tight] A Perps fill that sold."))
        }
        let priceScaled = (j["p"] as? NSNumber)?.doubleValue ?? 0
        let sizeScaled = (j["s"] as? NSNumber)?.doubleValue ?? 0
        self.init(
            id: "\(mkt)-\(oid)-\(Int(exactly: ms.rounded(.towardZero)) ?? 0)-\(log)",
            time: Date(timeIntervalSince1970: ms / 1000),
            marketId: mkt,
            symbol: market.asset,
            orderId: oid,
            side: side,
            direction: direction,
            isClose: typeRaw == 3 || typeRaw == 4,
            isMaker: (j["l"] as? NSNumber)?.intValue == 1,
            price: priceScaled / pow(10, Double(market.priceDecimals)),
            size: sizeScaled / pow(10, Double(market.lotDecimals)),
            fee: PerplHistory.amount(j["f"])
        )
    }
}

/// One position-history event that realized P&L (a close, a decrease or a liquidation). `realizedPnl` already
/// folds in funding; `ended` marks a fully-closed position (for the trade count and win rate).
public struct PerplPositionRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let time: Date
    public let marketId: Int
    public let symbol: String
    public let orderId: Int
    public let side: PositionSide
    public let entry: Double
    public let exit: Double?
    public let size: Double
    public let realizedPnl: Double
    public let fee: Double
    public let ended: Bool

    /// Position-history rows that realized P&L. Rows with no `dpnl` (a plain open/increase) are skipped so they
    /// don't count as trades or dilute the win rate.
    init?(position j: [String: Any], markets: [Int: PerpMarket]) {
        guard let mkt = (j["mkt"] as? NSNumber)?.intValue, let market = markets[mkt] else { return nil }
        guard j["dpnl"] != nil else { return nil }
        let at = j["at"] as? [String: Any]
        let ms = (at?["t"] as? NSNumber)?.doubleValue ?? 0
        let pid = (j["pid"] as? NSNumber)?.intValue ?? 0
        let status = (j["st"] as? NSNumber)?.intValue ?? 0
        let sdRaw = (j["sd"] as? NSNumber)?.intValue ?? 1
        let dpnl = PerplHistory.amount(j["dpnl"])
        let fnd = PerplHistory.amount(j["fnd"])
        let entryScaled = (j["ep"] as? NSNumber)?.doubleValue ?? 0
        let exitScaled = (j["xp"] as? NSNumber)?.doubleValue
        let sizeScaled = (j["s"] as? NSNumber)?.doubleValue ?? 0
        self.id = "\(mkt)-\(pid)-\(Int(exactly: ms.rounded(.towardZero)) ?? 0)"
        self.time = Date(timeIntervalSince1970: ms / 1000)
        self.marketId = mkt
        self.symbol = market.asset
        self.orderId = (j["oid"] as? NSNumber)?.intValue ?? 0
        self.side = sdRaw == 2 ? .short : .long
        self.entry = entryScaled / pow(10, Double(market.priceDecimals))
        self.exit = exitScaled.map { $0 / pow(10, Double(market.priceDecimals)) }
        self.size = sizeScaled / pow(10, Double(market.lotDecimals))
        self.realizedPnl = dpnl + fnd
        self.fee = PerplHistory.amount(j["fee"])
        self.ended = status == 2 || status == 3 || status == 4 || status == 5 // Closed / Liquidated / Deleveraged / Unwound
    }
}

/// A page of history plus the cursor to fetch the next (nil when there are no more rows).
public struct PerplHistoryPage<T: Sendable>: Sendable {
    public let items: [T]
    public let next: String?
    public init(items: [T], next: String?) { self.items = items; self.next = next }
}

enum PerplHistory {
    /// A collateral `Amount` — a decimal string of the value scaled by 6 — as a display Double in AUSD.
    static func amount(_ value: Any?) -> Double {
        if let s = value as? String { return (Double(s) ?? 0) / 1_000_000 }
        if let n = value as? NSNumber { return n.doubleValue / 1_000_000 }
        return 0
    }
}
