import Foundation
import StellarCore

// Mirrors of the Lite API's JSON (backend/supabase/functions/lite; the contract is docs/API-lite.md and
// _shared/contract.ts). Amounts are base-unit strings, USD values numbers (nil when unknown), changes and rates
// fractions (0.0123 = +1.23%), times ISO 8601 strings. A field added after build 23's API is optional, so today's
// payloads still decode; the fixtures in Tests/LiteClientTests/Fixtures hold both forms.

public struct AssetInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let code: String
    public let name: String
    public let decimals: Int
    public let contract: String
    public let classic: String?
    public let note: String?
    /// The reference price this asset is valued at: "XLM" or "USDC" (Blend's test USDC is valued as USDC).
    public let priceRef: String?
    /// A logo bundled with the app ("XLM", "USDC"), or nil.
    public let logo: String?
    /// False for an asset that never shows in Top Tokens (Blend's test USDC).
    public let listed: Bool?
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

    /// The contracts this API serves. The app's pins win wherever they overlap.
    public struct Deployment: Codable, Equatable, Sendable {
        public let id: String
        public let launchpad: String?
        public let moments: String?
    }

    /// The network fee policy, in stroops. Informational: the caps the phone enforces are pinned in the app.
    public struct Fees: Codable, Equatable, Sendable {
        /// "user": users pay their own network fees in XLM.
        public let payer: String
        public let maxFee: String
        public let maxInclusionPerOp: String
        public let starterInnerFeeMax: String
        /// Whether DyorHQ offers the one sponsored starter swap into XLM on this network (mainnet only).
        public let starterSwap: Bool
        /// The add-funds card shows while spendable XLM is below this.
        public let fundingFloor: String
    }

    /// Testnet's faucet: how much test XLM one tap brings, in XLM.
    public struct Faucet: Codable, Equatable, Sendable {
        public let amount: String
    }

    /// What the server accepts, so a form can say so before it asks.
    public struct Limits: Codable, Equatable, Sendable {
        public let momentMaxEditions: Int
        /// The shortest and the longest collect window, in seconds.
        public let momentWindowSecs: [Int]
        public let collectMax: Int
        /// A launch name's least and most UTF-8 bytes.
        public let launchName: [Int]
        /// A ticker's least and most characters.
        public let launchSymbol: [Int]
        public let uriMax: Int
        public let uploadBytes: Int
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
    public let deployment: Deployment?
    /// StellarExpert's base for this network. Informational: the app builds its links from the pinned network.
    public let explorer: String?
    public let fees: Fees?
    /// Nil off testnet.
    public let faucet: Faucet?
    public let limits: Limits?
    public let pricing: StellarPricing?
    /// Whether a first sign-in needs an invite code: false on testnet, true on mainnet. Nil from older servers, which
    /// always ask for one.
    public let inviteRequired: Bool?

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
    /// "native", "classic", "sac" or "launch".
    public let kind: String?
    public let verified: Bool?
    public let logo: String?
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
    /// The account's XLM and what it must keep; nil while the account doesn't exist.
    public let xlm: StellarXLMPosition?
    public let firstFunding: StellarFirstFunding?
    /// "owner" (the session's own account) or "public" (the viewer's account, without a session: on-chain facts only).
    /// Nil from older servers.
    public let view: String?

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
    /// What the step does, as fees are estimated: "swap_soroswap", "launch_buy", "trust", …
    public let stepKind: String?
    /// The most the step may cost in stroops: a built step's `tx.fee`, an unbuilt step's ceiling. The server's figure,
    /// for display; a built transaction's own fee is the one that counts.
    public let maxFee: String?
    /// "user" or "sponsor": the server's word, for display.
    public let feePayer: String?
    /// "setup" or "starter_swap", when `feePayer` is "sponsor".
    public let sponsorReason: String?
    /// New base reserves the step holds back (a trustline is 1).
    public let reserveDelta: Int?
}

public struct PlanView: Codable, Equatable, Sendable {
    /// The plan's fees as the server prices them, in stroops.
    public struct Fees: Codable, Equatable, Sendable {
        public let userMax: String
        public let sponsored: Bool
        public let newReserves: Int
    }

    public let planId: String
    public let kind: String
    public let expiresAt: String
    public let steps: [PlanStep]
    public let fees: Fees?
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
    /// What a settled transaction delivered, read from its result.
    public struct Outcome: Codable, Equatable, Sendable {
        /// Base units received (a swap's output, a curve buy's tokens, a sell's quote).
        public let amountOut: String?
    }

    public let hash: String
    public let status: String
    public let ledger: Int?
    public let error: String?
    public let returnValue: AnyJSON?
    /// The network fee charged, in stroops, once settled.
    public let feeCharged: String?
    /// "user" or "sponsor".
    public let feePayer: String?
    public let result: Outcome?
}

public struct SwapRoute: Codable, Equatable, Sendable {
    public let venue: String
    public let amountOut: String
    public let path: [String]
    public let minOut: String?
}

public struct SwapQuote: Codable, Equatable, Sendable {
    /// Whether DyorHQ would pay this swap's network fee (mainnet's one starter swap into XLM), and why not.
    public struct StarterSwap: Codable, Equatable, Sendable {
        public let eligible: Bool
        public let reason: String?
    }

    public let quoteId: String
    public let sell: String
    public let buy: String
    public let amountIn: String
    public let slippageBps: Int
    public let best: SwapRoute
    public let alternatives: [SwapRoute]
    public let expiresAt: String
    /// Every venue that answered, the best one marked.
    public let routes: [StellarQuoteRoute]?
    /// Asset ids the user must enable before receiving the output.
    public let needsEnable: [String]?
    public let starterSwap: StarterSwap?
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
    public let totalSuppliedUsd: Double?
    /// Supplied less borrowed, in USD: what can be withdrawn at once.
    public let freeLiquidityUsd: Double?
    public let priceUsd: Double?
    /// "active", "on_ice" or "frozen" (Blend's pool status).
    public let poolStatus: String?
    public var id: String { pool + asset }
}

/// A Blend position: `/v1/earn/positions` rows and the `earn` rows of `/v1/holdings`.
public struct EarnPosition: Codable, Equatable, Sendable, Identifiable {
    public let pool: String
    public let asset: String
    public let code: String
    public let supplied: String
    /// Only in older servers' positions.
    public let bTokens: String?
    public let poolName: String?
    public let deposited: String?
    public let withdrawn: String?
    public let earned: String?
    /// False when deposits made before the server recorded them are missing from `earned`.
    public let earnedComplete: Bool?
    public let supplyApy: Double?
    public let valueUsd: Double?
    public var id: String { pool + asset }
}

public struct StellarLaunch: Codable, Equatable, Sendable, Identifiable {
    public struct Links: Codable, Equatable, Sendable {
        public let website: String?
        public let x: String?
        public let telegram: String?
    }

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
    public let quoteCode: String?
    /// The coin's image on DyorHQ's media storage, or nil.
    public let image: String?
    public let description: String?
    public let links: Links?
    public let burned: String?
    public let circulating: String?
    /// "curve", "completed" or "graduated".
    public let phase: String?
    /// Price in the quote asset, human units ("0.0000021").
    public let priceQuote: String?
    public let priceUsd: Double?
    public let change24h: Double?
    public let isNew: Bool?
    public let marketCapQuote: String?
    public let marketCapUsd: Double?
    public let volume24hQuote: String?
    public let volume24hUsd: Double?
    public let holders: Int?
    /// False when some of the coin's transfers couldn't be read, so `holders` may be short.
    public let holdersComplete: Bool?
    public let feeBps: Int?
    public let protocolShareBps: Int?
    public let creatorFeeBps: Int?
    /// The Soroswap pool's fee after graduation.
    public let poolFeeBps: Int?
    public let lookAlike: Bool?
    public let graduatedAt: String?
    public let lastTradeAt: String?
    public var id: String { token }
}

public struct StellarLaunchTrade: Codable, Equatable, Sendable {
    public let trader: String
    public let side: String
    public let quoteAmount: String
    public let tokenAmount: String
    public let price: String
    public let txHash: String?
    public let ts: String
    /// "curve" or "soroswap".
    public let venue: String?
}

public struct StellarCandle: Codable, Equatable, Sendable {
    public let t: String
    public let o: String
    public let h: String
    public let l: String
    public let c: String
    public let v: String
}

public struct StellarLaunchDetail: Codable, Equatable, Sendable {
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

    public let launch: StellarLaunch
    public let curve: Curve?
    public let trades: [StellarLaunchTrade]
    public let candles: [StellarCandle]
    public let stats: Stats?
    public let creatorFees: StellarCreatorFees?
    public let you: You?
    public let economics: Economics?
    /// At most 300 prices in the quote asset, oldest first.
    public let pricePoints: [Point]?
    /// "owner" or "public" (no session: `you` has no cost basis or P&L, and is nil without a viewer).
    public let view: String?
}

public struct TradeQuote: Codable, Equatable, Sendable {
    public let side: String
    public let used: String?
    public let tokensOut: String?
    public let quoteOut: String?
    public let fees: String
    public let snipeFee: String?
    public let baseFee: String?
    public let creatorFee: String?
    /// The part of a buy a full curve gives back.
    public let refund: String?
}

public struct StellarMoment: Codable, Equatable, Sendable, Identifiable {
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
    public let description: String?
    public let place: String?
    /// The day it was taken, "2026-10-14".
    public let takenOn: String?
    /// "image" or "video".
    public let mediaType: String?
    /// A still for the media (a video's poster, or the photo).
    public let posterUrl: String?
    public let quoteCode: String?
    public let priceUsd: Double?
    public let collects: Int?
    public let collectors: Int?
    /// "collecting", "sold_out" or "closed".
    public let state: String?
    public let platformBps: Int?
    public let royaltyBps: Int?
    public let publishedAt: String?
}

public struct StellarMomentDetail: Codable, Equatable, Sendable {
    public struct Collector: Codable, Equatable, Sendable { public let collector: String; public let quantity: Int; public let firstTokenId: Int; public let ts: String }
    public let moment: StellarMoment
    public let collectors: [Collector]
    public let collectorsSummary: CollectorsSummary?
    public let you: You?
    /// What the creator has been paid, in base units of the Moment's quote asset.
    public let creatorEarned: String?
    /// "owner" or "public" (no session: `you.spent` is nil, and `you` is nil without a viewer).
    public let view: String?
}

/// A Moment edition (an NFT) in the user's account.
public struct StellarEdition: Codable, Equatable, Sendable, Identifiable {
    public let tokenId: Int
    public let momentId: Int
    public let title: String?
    public let mediaUrl: String?
    public let posterUrl: String?
    public let mediaType: String?
    /// The Moments contract that minted it.
    public let contract: String?
    public var id: Int { tokenId }
}

public struct StellarActivityItem: Codable, Equatable, Sendable, Identifiable {
    /// What an item points at: a launch, a Moment or an Earn market.
    public struct Ref: Codable, Equatable, Sendable {
        public let token: String?
        public let momentId: Int?
        public let market: String?
    }

    public let type: String
    public let id: String
    public let kind: String
    /// The server's own words, in English: what the app shows when it can't word the item itself.
    public let summary: String
    public let status: String
    public let at: String
    public let amount: String?
    /// A transaction's intent display fields, or a cash transfer's asset: what the app words the item from. Absent from
    /// older servers' payloads.
    public let display: [String: StellarJSON]?
    /// "spot", "earn", "launch", "moments", "bridge", "cash" or "account".
    public let section: String?
    public let hash: String?
    /// The network fee charged, in stroops.
    public let feeCharged: String?
    public let feePayer: String?
    public let result: TxStatus.Outcome?
    public let ref: Ref?
    /// The asset's symbol and name, resolved by the server.
    public let symbol: String?
    public let name: String?
    /// The server's English title and subtitle (the app words known kinds itself).
    public let title: String?
    public let subtitle: String?
    public let usd: Double?
}

extension StellarActivityItem {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        summary = try c.decode(String.self, forKey: .summary)
        status = try c.decode(String.self, forKey: .status)
        at = try c.decode(String.self, forKey: .at)
        amount = try c.decodeIfPresent(String.self, forKey: .amount)
        // Words, not money: a display the app can't read only costs it its own wording, never the whole list.
        display = (try? c.decodeIfPresent([String: StellarJSON].self, forKey: .display)) ?? nil
        section = try c.decodeIfPresent(String.self, forKey: .section)
        hash = try c.decodeIfPresent(String.self, forKey: .hash)
        feeCharged = try c.decodeIfPresent(String.self, forKey: .feeCharged)
        feePayer = try c.decodeIfPresent(String.self, forKey: .feePayer)
        result = try c.decodeIfPresent(TxStatus.Outcome.self, forKey: .result)
        ref = try c.decodeIfPresent(Ref.self, forKey: .ref)
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? nil
        usd = try c.decodeIfPresent(Double.self, forKey: .usd)
    }
}

/// `GET /v1/prices`: USD per asset id or token contract. Kept for older clients; markets carry the prices now.
public struct StellarPrices: Codable, Equatable, Sendable {
    public let usd: [String: Double]
    public let reference: String
    public let at: String?
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

/// `auth/verify` and `auth/refresh`: a session.
public struct AuthResult: Codable, Equatable, Sendable {
    public struct Tester: Codable, Equatable, Sendable { public let address: String; public let label: String? }
    /// The access token (an hour), sent as `authorization: Bearer …`.
    public let token: String
    public let expiresAt: String
    public let tester: Tester
    /// Renews the session once (`LiteAPI.refresh`); each use hands out its successor. Lapses 30 days after it was
    /// issued. Nil from older servers.
    public let refreshToken: String?
    public let refreshExpiresAt: String?
}

/// A session as the phone keeps it between launches (`StellarKeychain.saveSession`): the access token and the refresh
/// token that renews it, each with when it ends. The item is one JSON object of strings, times in ISO 8601 to the
/// second, so an item saved before refresh tokens (`token` and `expiresAt` alone) still reads, an older build still
/// finds those two in a newer item, and a refresh token is kept even when its answer gave no expiry.
public struct LiteSavedSession: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date
    public let refreshToken: String?
    public let refreshExpiresAt: Date?

    public init(token: String, expiresAt: Date, refreshToken: String? = nil, refreshExpiresAt: Date? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }

    /// An item read back; nil when it isn't a session.
    public init?(data: Data) {
        let time = ISO8601DateFormatter()
        guard let fields = try? JSONDecoder().decode([String: String].self, from: data),
              let token = fields["token"], let expiresAt = fields["expiresAt"].flatMap(time.date(from:)) else { return nil }
        self.init(token: token, expiresAt: expiresAt, refreshToken: fields["refreshToken"], refreshExpiresAt: fields["refreshExpiresAt"].flatMap(time.date(from:)))
    }

    /// The item's bytes.
    public func data() throws -> Data {
        let time = ISO8601DateFormatter()
        var fields = ["token": token, "expiresAt": time.string(from: expiresAt)]
        fields["refreshToken"] = refreshToken
        fields["refreshExpiresAt"] = refreshExpiresAt.map(time.string(from:))
        return try JSONEncoder().encode(fields)
    }
}
