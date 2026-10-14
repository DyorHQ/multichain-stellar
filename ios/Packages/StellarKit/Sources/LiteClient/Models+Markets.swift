import Foundation

// Prices, markets, search, swap routes and Earn's rate history (docs/API-lite.md: markets, assets, swap, earn).
// `/v1/markets*` are public: Top Tokens shows while the session is locked.

/// A period, as the app's `VolumePeriod` names them: the `period` and `range` query values.
public enum VolumePeriodKey: String, Codable, CaseIterable, Sendable {
    case day, week, month, all
}

/// How USD values are priced. On testnet assets have no market, so XLM and USDC carry mainnet reference prices.
public struct StellarPricing: Codable, Equatable, Sendable {
    /// "reference" (testnet) or "market".
    public let kind: String
    /// The price provider ("Kraken").
    public let source: String
    /// The network the prices come from.
    public let network: String
    /// What to tell the user about these prices; nil on mainnet.
    public let note: String?
}

/// A Top Tokens row: a registry asset, or a listed DyorHQ launch.
public struct StellarMarketRow: Codable, Equatable, Sendable, Identifiable {
    /// Where `priceUsd` comes from.
    public struct PriceSource: Codable, Equatable, Sendable {
        /// "reference", "curve" or "pool".
        public let kind: String
        /// A reference price's market ("Kraken XLM/USD").
        public let market: String?
        /// A launch's quote asset and its price in it, human units.
        public let quote: String?
        public let quotePrice: String?
        public let at: String?
    }

    /// A launch row's curve.
    public struct LaunchInfo: Codable, Equatable, Sendable {
        /// "curve", "completed" or "graduated".
        public let phase: String
        public let progress: Double
        public let pair: String?
    }

    /// The registry id ("XLM", "USDC") or the launch token's contract.
    public let id: String
    /// "registry" or "launch".
    public let kind: String
    public let contract: String
    public let classic: String?
    public let code: String
    public let name: String
    public let decimals: Int
    /// A bundled logo ("XLM", "USDC"), or nil.
    public let logo: String?
    /// A launch's image on DyorHQ's media storage, or nil.
    public let image: String?
    public let verified: Bool
    /// "launch", …
    public let badges: [String]
    public let note: String?
    public let priceUsd: Double?
    public let change24h: Double?
    /// Created less than 24 hours ago (its change is nil until then).
    public let isNew: Bool
    public let volume24hUsd: Double?
    public let marketCapUsd: Double?
    public let priceSource: PriceSource
    /// The price is older than ten minutes.
    public let stale: Bool
    public let launch: LaunchInfo?
}

/// `GET /v1/markets` (public): Popular order, at most 50 rows. The other tabs are sorted on the phone.
public struct StellarMarkets: Codable, Equatable, Sendable {
    public let asOf: String
    public let pricing: StellarPricing
    public let rows: [StellarMarketRow]
}

/// `GET /v1/markets/:id` (public): the token page's row and its About section.
public struct StellarMarketDetail: Codable, Equatable, Sendable {
    public struct About: Codable, Equatable, Sendable {
        public let contract: String
        public let classic: String?
        public let issuer: String?
        public let decimals: Int
        public let homeDomain: String?
    }

    public let row: StellarMarketRow
    public let about: About
}

/// `GET /v1/markets/:id/history?range=` (public): USD prices over a period, oldest first.
public struct StellarPriceHistory: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let t: String
        public let usd: Double
    }

    public let id: String
    public let range: VolumePeriodKey
    public let intervalS: Int
    /// The provider ("Kraken"), or "curve+pool" for a launch.
    public let source: String
    public let complete: Bool
    public let points: [Point]
}

/// `GET /v1/assets?q=`: a search result.
public struct StellarAssetResult: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    /// "registry", "launch", "classic" or "contract".
    public let kind: String
    public let code: String
    public let name: String?
    public let contract: String
    public let classic: String?
    public let verified: Bool
    /// The user holds it.
    public let held: Bool
}

/// One venue's answer to a swap quote.
public struct StellarQuoteRoute: Codable, Equatable, Sendable {
    /// "sdex", "soroswap" or "aquarius".
    public let venue: String
    public let amountOut: String
    public let minOut: String
    public let priceImpactBps: Int?
    public let path: [String]
    public let best: Bool
}

/// `GET /v1/earn/history?pool=&asset=&range=`: a market's supply rate and utilization over time, oldest first.
public struct StellarEarnHistory: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let t: String
        public let supplyApy: Double
        public let utilization: Double
    }

    public let points: [Point]
}
