import Foundation

// What the account holds and how it did (docs/API-lite.md: holdings, portfolio). USD values are at today's prices,
// nil when unknown; a part that couldn't be read says so in `parts` and leaves the totals incomplete.

/// `GET /v1/holdings`: Home's balance card, My Holdings, the allocation and Portfolio's assets.
public struct StellarHoldings: Codable, Equatable, Sendable {
    /// A classic or registry asset in the account.
    public struct SpotHolding: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        /// "registry", or "classic" for any other trustline (unverified).
        public let kind: String
        public let contract: String
        public let classic: String?
        public let code: String
        public let name: String?
        public let decimals: Int
        public let balance: String
        public let enabled: Bool
        public let verified: Bool
        public let badges: [String]
        public let note: String?
        public let logo: String?
        public let priceUsd: Double?
        public let valueUsd: Double?
        public let change24h: Double?
        public var units: Int64 { Int64(balance) ?? 0 }
    }

    /// A DyorHQ launch token in the account. Counted here only, never in `spot`.
    public struct LaunchHolding: Codable, Equatable, Sendable, Identifiable {
        public let token: String
        public let symbol: String
        public let name: String
        public let image: String?
        public let balance: String
        public let priceUsd: Double?
        public let valueUsd: Double?
        public let change24h: Double?
        /// "curve", "completed" or "graduated".
        public let phase: String
        public let progress: Double
        public let costBasisUsd: Double?
        public let pnlUsd: Double?
        /// The live balance couldn't be read; this is the indexed one.
        public let stale: Bool
        public var id: String { token }
    }

    public struct Moments: Codable, Equatable, Sendable {
        public let count: Int
        public let editions: [StellarEdition]
    }

    /// USD per part. A part is nil, and `complete` false, when it couldn't be read. Moments count as 0 (editions
    /// have no market).
    public struct Totals: Codable, Equatable, Sendable {
        public let spot: Double?
        public let earn: Double?
        public let launch: Double?
        public let moments: Double?
        public let total: Double?
        public let complete: Bool
    }

    /// The change over 24 hours across priced holdings.
    public struct Change: Codable, Equatable, Sendable {
        public let usd: Double?
        public let pct: Double?
        public let complete: Bool
    }

    public let address: String
    public let exists: Bool
    public let asOf: String
    public let pricing: StellarPricing
    public let xlm: StellarXLMPosition?
    public let spot: [SpotHolding]
    public let earn: [EarnPosition]
    public let launch: [LaunchHolding]
    public let moments: Moments
    public let totals: Totals
    public let change24h: Change
    /// "ok" or "failed", by part: "spot", "earn", "launch", "moments".
    public let parts: [String: String]
    /// "owner" (the session's own account) or "public" (the viewer's account, without a session: on-chain facts only,
    /// DyorHQ's history nil). Nil from older servers.
    public let view: String?
}

/// A section's figures over a period, in USD at today's prices. Network fees are counted apart, never in `fees`.
public struct StellarStats: Codable, Equatable, Sendable {
    public let volume: Double
    public let fees: Double
    public let pnl: Double
    public let claimedFees: Double
    public let trades: Int
    /// False when some trades' outcome is missing from `pnl`.
    public let pnlComplete: Bool
    /// In stroops.
    public let networkFeesXlm: String
    public let networkFeesUsd: Double?
}

/// `GET /v1/portfolio?period=`.
public struct StellarPortfolio: Codable, Equatable, Sendable {
    public struct Sections: Codable, Equatable, Sendable {
        public let spot: StellarStats
        public let earn: StellarStats
        public let launch: StellarStats
        public let moments: StellarStats
        public let bridge: StellarStats
    }

    /// One action in the period.
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        /// The transaction hash, or a transfer's id.
        public let id: String
        public let section: String
        public let kind: String
        public let title: String
        public let subtitle: String?
        public let at: String
        public let usd: Double?
        public let hash: String?
    }

    /// What the figures cover.
    public struct Coverage: Codable, Equatable, Sendable {
        /// The first action DyorHQ recorded for this account.
        public let from: String?
        public let note: String?
    }

    public let period: VolumePeriodKey
    /// The period's start; nil for all time.
    public let since: String?
    public let asOf: String
    public let pricing: StellarPricing
    public let totals: StellarStats
    public let sections: Sections
    public let activity: [Item]
    public let coverage: Coverage
}
