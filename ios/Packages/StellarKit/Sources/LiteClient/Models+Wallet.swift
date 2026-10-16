import Foundation

// The account's XLM, the network fees and the checks before a send or a bridge (docs/API-lite.md: fees, account,
// recipient, bridge). Stroops are base-unit strings, as everywhere.

/// `GET /v1/fees` (public): what a step of each kind may cost, so a review can price the steps not built yet.
public struct StellarFees: Codable, Equatable, Sendable {
    public struct InclusionFee: Codable, Equatable, Sendable {
        public let classic: String
        public let soroban: String
    }

    public let network: String
    /// The ledger's base reserve (0.5 XLM today).
    public let baseReserve: String
    public let baseFee: String
    /// The inclusion fee the server bids now, per operation.
    public let inclusionFee: InclusionFee
    /// The most a step of each kind is expected to cost, by step kind ("swap_soroswap", "launch_buy", …).
    public let estimates: [String: String]
    /// Where each estimate comes from: "history" (the last 7 days' fees) or "default".
    public let estimateBasis: [String: String]
    public let updatedAt: String?

    /// The estimate for a step kind, in stroops.
    public func estimate(_ stepKind: String) -> Int64? { estimates[stepKind].flatMap { Int64($0) } }
}

/// The account's XLM: its balance and the minimum balance Stellar keeps in it. `spendable` is what can leave.
public struct StellarXLMPosition: Codable, Equatable, Sendable {
    /// The entries the minimum balance counts, in base reserves.
    public struct Reserves: Codable, Equatable, Sendable {
        public let base: Int
        public let subentries: Int
        public let sponsoring: Int
        public let sponsored: Int
    }

    public let balance: String
    public let minBalance: String
    public let sellingLiabilities: String
    public let spendable: String
    public let baseReserve: String
    public let reserves: Reserves
}

/// The add-funds card: whether the account needs XLM before it can pay its fees, and how it can get some.
public struct StellarFirstFunding: Codable, Equatable, Sendable {
    /// Testnet's Friendbot: its grant in XLM, and whether the address has had it. One claim per address, ever: the
    /// account's activation by Friendbot, or the faucet once.
    public struct Faucet: Codable, Equatable, Sendable {
        public let amount: String
        /// Nil in the public view (DyorHQ's records, not the ledger's).
        public let claimed: Bool?
    }

    public let needsXlm: Bool
    /// How much XLM to send, in stroops.
    public let suggestXlm: String
    /// "available", "used" or "unavailable"; nil in the public view (DyorHQ's records, not the ledger's).
    public let starterSwap: String?
    /// Nil off testnet.
    public let faucet: Faucet?
}

/// `GET /v1/recipient/:address?asset=`: whether an address can receive an asset before the user reviews a send.
public struct StellarRecipient: Codable, Equatable, Sendable {
    /// "account" (G…) or "contract" (C…).
    public let kind: String
    public let exists: Bool
    /// Whether the account has enabled the asset; nil where that doesn't apply (XLM, a contract).
    public let trusts: Bool?
}

/// `POST /v1/bridge/quote`: what a bridge transfer delivers, its fee and how long transfers have been taking.
public struct StellarBridgeQuote: Codable, Equatable, Sendable {
    /// "cctp" (testnet) or "oneclick".
    public let route: String
    /// "monad_to_stellar" or "stellar_to_monad".
    public let direction: String
    /// In the sending side's base units (6 decimals on Monad, 7 on Stellar).
    public let amountIn: String
    /// In the receiving side's base units.
    public let amountOut: String
    /// The bridge's own fee, in the sending side's base units.
    public let fee: String?
    /// "circle-iris" when Circle's fee API priced it.
    public let feeSource: String?
    /// The median of recent transfers in this direction, or nil while there are too few to say.
    public let etaSeconds: Int?
    /// How many completed transfers the median is over.
    public let etaBasis: Int?
    public let note: String?
}
