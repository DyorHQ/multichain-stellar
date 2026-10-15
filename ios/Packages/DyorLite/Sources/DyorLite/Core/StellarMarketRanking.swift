import Foundation
import StellarKit

/// Top Tokens' tabs, sorted as Monad Home sorts its own (`HomeModel.topTokens`): Popular keeps the server's order (the
/// registry, then listed coins by volume); Hot ranks by the size of the 24h move either way; Gainers and Losers by the
/// move, rising or falling only. A row without a price never shows, and a move not known yet (a coin under a day old)
/// counts as none. Ties keep the Popular order.
public enum StellarMarketRanking {
    /// The tabs, with the raw values of the app's `HomeTokenTab`.
    public enum Tab: String, CaseIterable, Sendable {
        case popular, hot, gainers, losers
    }

    public static func rows(_ rows: [StellarMarketRow], tab: Tab) -> [StellarMarketRow] {
        let priced = rows.filter { $0.priceUsd != nil }
        func move(_ row: StellarMarketRow) -> Double { row.change24h ?? 0 }
        switch tab {
        case .popular: return priced
        case .hot: return stable(priced) { abs(move($0)) > abs(move($1)) }
        case .gainers: return stable(priced.filter { move($0) > 0 }) { move($0) > move($1) }
        case .losers: return stable(priced.filter { move($0) < 0 }) { move($0) < move($1) }
        }
    }

    /// `rows` sorted by `before`, equal rows in their given order.
    private static func stable(_ rows: [StellarMarketRow], by before: (StellarMarketRow, StellarMarketRow) -> Bool) -> [StellarMarketRow] {
        rows.enumerated().sorted { a, b in
            if before(a.element, b.element) { return true }
            if before(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
