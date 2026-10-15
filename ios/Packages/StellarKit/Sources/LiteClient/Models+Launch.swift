import Foundation

// The launchpad (docs/API-lite.md: launches, economics, launchpad/me). Prices in the quote asset are decimal strings
// in human units; amounts are base units.

/// `GET /v1/launches?section=&sort=&q=&cursor=`: one page of a board section.
public struct StellarLaunchBoard: Codable, Equatable, Sendable {
    public struct Counts: Codable, Equatable, Sendable {
        public let explore: Int
        public let graduated: Int
    }

    public let launches: [StellarLaunch]
    /// The next page's cursor; nil on the last page (and from older servers, which send one page).
    public let nextCursor: String?
    public let counts: Counts?
    /// "owner" or "public" (asked without a session). Nil from older servers.
    public let view: String?
}

/// A coin's creator fees, in base units of its quote asset.
public struct StellarCreatorFees: Codable, Equatable, Sendable {
    /// Waiting in the launchpad until the creator claims them.
    public let unclaimed: String
    public let claimed: String
    /// The quote asset's id ("XLM", "USDC").
    public let quote: String
    public let unclaimedUsd: Double?
    public let claimedUsd: Double?
}

extension StellarLaunchDetail {
    /// The coin's figures now.
    public struct Stats: Codable, Equatable, Sendable {
        public let volume24hQuote: String
        public let volume24hUsd: Double?
        public let holders: Int
        public let holdersComplete: Bool
        public let marketCapQuote: String
        public let marketCapUsd: Double?
        public let priceQuote: String
        public let priceUsd: Double?
        public let change24h: Double?
    }

    /// The signed-in user's side of the coin.
    public struct You: Codable, Equatable, Sendable {
        public let balance: String
        /// What the user paid on the curve for what they hold; nil for coins received by transfer.
        public let costBasisQuote: String?
        public let pnlQuote: String?
        public let isCreator: Bool
    }

    /// The launchpad's terms this coin was launched on.
    public struct Economics: Codable, Equatable, Sendable {
        public let feeBps: Int
        public let protocolShareBps: Int
        public let creatorFeeBps: Int
        public let supply: String
        public let phantom: String
        public let threshold: String
    }

    /// A price in the quote asset, human units.
    public struct Point: Codable, Equatable, Sendable {
        public let t: String
        public let price: String
    }
}

/// `GET /v1/economics`: the launchpad's and the Moments contract's terms, read live from the contracts. Nil where
/// the contract isn't deployed.
public struct StellarEconomics: Codable, Equatable, Sendable {
    public struct Launchpad: Codable, Equatable, Sendable {
        public struct Quote: Codable, Equatable, Sendable {
            /// The asset's id ("XLM", "USDC").
            public let asset: String
            public let contract: String
            /// The curve's virtual quote reserve at launch.
            public let phantom: String
            /// The raise at which a curve completes.
            public let threshold: String
            public let enabled: Bool
        }

        public let contract: String
        public let launchesEnabled: Bool
        public let supply: String
        public let feeBps: Int
        public let protocolShareBps: Int
        public let maxCreatorFeeBps: Int
        /// The early-buy tax in bps, by ledger after the launch's own (index 0 is the launch ledger).
        public let snipeSchedule: [Int]
        public let quotes: [Quote]
    }

    public struct Moments: Codable, Equatable, Sendable {
        public struct Quote: Codable, Equatable, Sendable {
            public let asset: String
            /// The lowest price per edition, in base units.
            public let minPrice: String
            public let enabled: Bool
        }

        public let contract: String
        public let platformBps: Int
        public let royaltyBps: Int
        public let publishingEnabled: Bool
        /// Where DyorHQ's share goes; shown in the publish review only.
        public let treasury: String
        public let maxPerCollect: Int
        public let maxEditions: Int
        public let quotes: [Quote]
    }

    public let launchpad: Launchpad?
    public let moments: Moments?
}

/// `GET /v1/launchpad/me`: My Launchpad.
public struct StellarMyLaunchpad: Codable, Equatable, Sendable {
    /// A launch token the user holds.
    public struct Held: Codable, Equatable, Sendable, Identifiable {
        public let token: String
        public let balance: String
        public let valueUsd: Double?
        /// Nil for coins received by transfer.
        public let costBasisQuote: String?
        public let pnlQuote: String?
        public let pnlUsd: Double?
        public let onCurve: Bool
        public let launch: StellarLaunch
        public var id: String { token }
    }

    /// A coin the user launched.
    public struct Created: Codable, Equatable, Sendable, Identifiable {
        public let launch: StellarLaunch
        public let creatorFees: StellarCreatorFees
        public var id: String { launch.token }
    }

    /// Creator fees per quote asset, in base units.
    public struct QuoteFees: Codable, Equatable, Sendable {
        public let quote: String
        public let received: String
        public let claimable: String
        public let receivedUsd: Double?
        public let claimableUsd: Double?
    }

    public struct Fees: Codable, Equatable, Sendable {
        public let byQuote: [QuoteFees]
    }

    public let held: [Held]
    public let created: [Created]
    public let fees: Fees
    /// The launch kinds of the user's activity.
    public let activity: [StellarActivityItem]
}
