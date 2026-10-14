import Foundation

// Moments (docs/API-lite.md: moments). Stellar Moments are SEP-50 editions: no coin, no graduation. Prices and
// proceeds are base units of the Moment's quote asset.

extension StellarMomentDetail {
    public struct CollectorsSummary: Codable, Equatable, Sendable {
        public struct Largest: Codable, Equatable, Sendable {
            public let address: String
            public let editions: Int
        }

        public let count: Int
        /// Nil before the first collect.
        public let largest: Largest?
    }

    /// The signed-in user's side of the Moment.
    public struct You: Codable, Equatable, Sendable {
        /// Token ids of the editions the user still owns.
        public let editions: [Int]
        public let spent: String
    }
}

/// `GET /v1/moments/mine`: My Moments.
public struct StellarMomentsMine: Codable, Equatable, Sendable {
    /// A Moment the user published, with what it has paid them. On the wire, the Moment's fields and these two sit
    /// side by side in one object.
    public struct Created: Codable, Equatable, Sendable, Identifiable {
        public let moment: StellarMoment
        public let proceeds: String
        public let proceedsUsd: Double?
        public var id: Int { moment.id }

        enum CodingKeys: String, CodingKey { case proceeds, proceedsUsd }

        public init(from decoder: Decoder) throws {
            moment = try StellarMoment(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            proceeds = try c.decode(String.self, forKey: .proceeds)
            proceedsUsd = try c.decodeIfPresent(Double.self, forKey: .proceedsUsd)
        }

        public func encode(to encoder: Encoder) throws {
            try moment.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(proceeds, forKey: .proceeds)
            try c.encodeIfPresent(proceedsUsd, forKey: .proceedsUsd)
        }
    }

    /// An edition the user collected and still owns.
    public struct Collected: Codable, Equatable, Sendable, Identifiable {
        public let tokenId: Int
        public let momentId: Int
        public let contract: String
        public let moment: StellarMoment
        public var id: Int { tokenId }
    }

    public struct Totals: Codable, Equatable, Sendable {
        public let editions: Int
        public let moments: Int
        /// Base units, by quote asset id ("XLM", "USDC").
        public let spentByQuote: [String: String]
        public let earnedByQuote: [String: String]
    }

    public let created: [Created]
    public let collected: [Collected]
    public let totals: Totals
}
