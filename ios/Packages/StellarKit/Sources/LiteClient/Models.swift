import Foundation
import StellarCore

// Mirrors of the Lite API's JSON (backend/supabase/functions/lite). Amounts are base-unit strings.

public struct AssetInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let name: String
    public let decimals: Int
    public let contract: String
    public let classic: String?
    public let note: String?
}

public struct AnchorInfo: Codable, Equatable, Sendable, Identifiable {
    public let domain: String
    public let name: String
    public let assets: [String]
    public let countries: [String]
    public let kinds: [String]
    public var id: String { domain }
}

public struct LiteConfig: Codable, Equatable, Sendable {
    public struct Contracts: Codable, Equatable, Sendable {
        public struct Pool: Codable, Equatable, Sendable { public let id: String; public let name: String }
        public let launchpad: String?
        public let moments: String?
        public let soroswapRouter: String
        public let blendPools: [Pool]
    }

    public struct Flags: Codable, Equatable, Sendable {
        public let enabled: Bool
        public let maintenance: Bool?
    }

    public struct Bridge: Codable, Equatable, Sendable {
        public struct Monad: Codable, Equatable, Sendable { public let chainId: Int; public let usdc: String }
        public let routes: [String]
        public let monad: Monad?
    }

    public let network: String
    public let passphrase: String
    public let rpcUrl: String
    public let horizonUrl: String
    public let activation: String
    public let sponsor: String
    public let assets: [AssetInfo]
    public let contracts: Contracts
    public let allowlist: [String: [String]]
    public let anchors: [AnchorInfo]
    public let bridge: Bridge
    public let flags: Flags
    public let minBuild: Int

    public func asset(_ id: String) -> AssetInfo? { assets.first { $0.id == id || $0.contract == id } }
}

public struct BalanceRow: Codable, Equatable, Sendable, Identifiable {
    public let asset: String
    public let code: String
    public let name: String
    public let contract: String
    public let classic: String?
    public let decimals: Int
    public let balance: String
    public let enabled: Bool
    public let note: String?
    public var id: String { asset }
    public var units: Int64 { Int64(balance) ?? 0 }
}

public struct AccountView: Codable, Equatable, Sendable {
    public struct Reserves: Codable, Equatable, Sendable { public let subentries: Int; public let sponsoredByDyorHQ: Int }
    public let address: String
    public let exists: Bool
    public let network: String
    public let activation: String
    public let balances: [BalanceRow]
    public let reserves: Reserves?
    public let sponsor: String

    public func balance(_ asset: String) -> Int64 { balances.first { $0.asset == asset }?.units ?? 0 }
}

/// A transaction status or a contract's return value: any JSON.
public indirect enum AnyJSON: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AnyJSON])
    case object([String: AnyJSON])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) { self = .number(n) } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([AnyJSON].self) { self = .array(a) } else { self = .object(try c.decode([String: AnyJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var text: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        default: return nil
        }
    }
}

public struct PlanStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let status: String
    public let intent: Intent?
    public let xdr: String?
    public let hash: String?
    public let txHash: String?
    public let error: String?
}

public struct PlanView: Codable, Equatable, Sendable {
    public let planId: String
    public let kind: String
    public let expiresAt: String
    public let steps: [PlanStep]
}

/// /account/activate answers with a plan, or with the active account.
public struct ActivationResult: Decodable, Sendable {
    public let plan: PlanView?
    public let account: AccountView?

    public init(from decoder: Decoder) throws {
        if let p = try? PlanView(from: decoder) {
            plan = p
            account = nil
        } else {
            plan = nil
            account = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(AccountView.self, forKey: .account)
        }
    }

    enum CodingKeys: String, CodingKey { case account }
}

public struct TxStatus: Codable, Equatable, Sendable {
    public let hash: String
    public let status: String
    public let ledger: Int?
    public let error: String?
    public let returnValue: AnyJSON?
}

public struct SwapRoute: Codable, Equatable, Sendable {
    public let venue: String
    public let amountOut: String
    public let path: [String]
    public let minOut: String?
}

public struct SwapQuote: Codable, Equatable, Sendable {
    public let quoteId: String
    public let sell: String
    public let buy: String
    public let amountIn: String
    public let slippageBps: Int
    public let best: SwapRoute
    public let alternatives: [SwapRoute]
    public let expiresAt: String
}

public struct EarnMarket: Codable, Equatable, Sendable, Identifiable {
    public let pool: String
    public let poolName: String
    public let asset: String
    public let code: String
    public let decimals: Int
    public let supplyApy: Double
    public let borrowApy: Double
    public let utilization: Double
    public let totalSupplied: Double
    public let note: String?
    public var id: String { pool + asset }
}

public struct EarnPosition: Codable, Equatable, Sendable, Identifiable {
    public let pool: String
    public let asset: String
    public let code: String
    public let supplied: String
    public let bTokens: String
    public var id: String { pool + asset }
}

public struct Launch: Codable, Equatable, Sendable, Identifiable {
    public let token: String
    public let creator: String
    public let quote: String
    public let name: String
    public let symbol: String
    public let uri: String
    public let supply: String
    public let quoteReserve: String
    public let tokenReserve: String
    public let realQuote: String
    public let threshold: String
    public let progress: Double
    public let completed: Bool
    public let graduated: Bool
    public let pair: String?
    public let lastPrice: String?
    public let volume: String
    public let trades: Int
    public let createdAt: String
    public var id: String { token }
}

public struct LaunchTrade: Codable, Equatable, Sendable {
    public let trader: String
    public let side: String
    public let quoteAmount: String
    public let tokenAmount: String
    public let price: String
    public let txHash: String?
    public let ts: String
}

public struct Candle: Codable, Equatable, Sendable {
    public let t: String
    public let o: String
    public let h: String
    public let l: String
    public let c: String
    public let v: String
}

public struct LaunchDetail: Codable, Equatable, Sendable {
    public struct Curve: Codable, Equatable, Sendable {
        public let quoteReserve: String
        public let tokenReserve: String
        public let realQuote: String
        public let threshold: String
        public let creatorFees: String
        public let completed: Bool
        public let graduated: Bool
        public let pair: String?
    }

    public let launch: Launch
    public let curve: Curve?
    public let trades: [LaunchTrade]
    public let candles: [Candle]
}

public struct TradeQuote: Codable, Equatable, Sendable {
    public let side: String
    public let used: String?
    public let tokensOut: String?
    public let quoteOut: String?
    public let fees: String
    public let snipeFee: String?
}

public struct Moment: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let creator: String
    public let uri: String
    public let title: String?
    public let mediaUrl: String?
    public let price: String
    public let quote: String
    public let maxEditions: Int
    public let minted: Int
    public let deadline: String
    public let open: Bool
    public let createdAt: String
}

public struct MomentDetail: Codable, Equatable, Sendable {
    public struct Collector: Codable, Equatable, Sendable { public let collector: String; public let quantity: Int; public let firstTokenId: Int; public let ts: String }
    public let moment: Moment
    public let collectors: [Collector]
}

public struct OwnedEdition: Codable, Equatable, Sendable, Identifiable {
    public let tokenId: Int
    public let momentId: Int
    public let title: String?
    public let mediaUrl: String?
    public var id: Int { tokenId }
}

public struct ActivityItem: Codable, Equatable, Sendable, Identifiable {
    public let type: String
    public let id: String
    public let kind: String
    public let summary: String
    public let status: String
    public let at: String
    public let amount: String?
}

public struct Prices: Codable, Equatable, Sendable {
    public let usd: [String: Double]
    public let reference: String
}

public struct EvmStep: Codable, Equatable, Sendable {
    public let kind: String
    public let chainId: Int
    public let label: String
    public let to: String
    public let data: String
    public let value: String
}

public struct BridgeTransfer: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let direction: String
}

public struct BridgeStart: Codable, Equatable, Sendable {
    public let transfer: BridgeTransfer
    public let plan: PlanView?
    public let evmSteps: [EvmStep]?
}

public struct BridgeStatus: Codable, Equatable, Sendable {
    public let id: String
    public let direction: String
    public let status: String
    public let amount: String
    public let recipient: String
    public let sourceTx: String?
    public let destTx: String?
    public let error: String?
    public let claim: EvmStep?
}

public struct UploadTicket: Codable, Equatable, Sendable {
    public let uploadUrl: String
    public let publicUrl: String
    public let path: String
}

public struct AuthChallenge: Codable, Equatable, Sendable {
    public let nonce: String
    public let message: String
    public let expiresAt: String
}

public struct AuthResult: Codable, Equatable, Sendable {
    public struct Tester: Codable, Equatable, Sendable { public let address: String; public let label: String? }
    public let token: String
    public let expiresAt: String
    public let tester: Tester
}
