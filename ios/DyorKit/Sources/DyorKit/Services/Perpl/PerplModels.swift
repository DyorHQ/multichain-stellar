import BigInt
import Foundation

/* Perpl: the fully on-chain perpetuals order book on Monad (https://docs.perpl.xyz). Positions, orders and
   collateral live in the Exchange contract; everything the user signs goes straight to it. These are the
   app-facing models; `PerplService` fills them from the contract and Perpl's public REST context. */

public enum PositionSide: String, Sendable, Codable {
    case long, short

    public var opposite: PositionSide { self == .long ? .short : .long }
}

public enum OrderSide: String, Sendable {
    case buy, sell
}

public enum OrderKind: String, Sendable {
    case market, limit
}

/// `OrderDesc.orderType` as Perpl's SDK encodes it (`RequestType` as u8).
public enum PerpOrderType: Int, Sendable {
    case openLong = 0
    case openShort = 1
    case closeLong = 2
    case closeShort = 3
    case cancel = 4
    case increasePositionCollateral = 5
    case change = 6
}

/// One perpetual market as the Exchange reports it. Prices and sizes are already scaled by the market's
/// decimals; margin fractions are of notional (0.1 = 10%).
public struct PerpMarket: Identifiable, Hashable, Sendable {
    public let id: Int
    public let symbol: String
    public let name: String
    public let priceDecimals: Int
    public let lotDecimals: Int
    public let basePricePNS: BigUInt
    public let mark: Double
    public let last: Double
    public let oracle: Double
    public let markTimestamp: Int
    public let longOI: Double
    public let shortOI: Double
    public let fundingRatePct100k: Int
    public let status: Int
    /// Initial and maintenance margin as fractions of notional (0.1 = 10%); nil when the Exchange's margin read failed.
    /// Never guessed: a liquidation price computed from a guess could understate the risk.
    public let initMarginFraction: Double?
    public let maintMarginFraction: Double?
    public let numOrders: Int
    /// Block the market's funding schedule started at; funding settles every interval (`MarketContext.fundingIntervalBlocks`,
    /// `PerplFunding.blocksPerInterval` by default) from here.
    public let fundingStartBlock: UInt64
    /// The contract's clamp on |funding| per interval, in parts per 100 000 (0 = not reported).
    public let fundingClampPct100k: Int

    /// The bare asset symbol for display and logo lookup — e.g. "SOL" from a contract symbol like "SOL_v2".
    public var asset: String {
        let letters = String(symbol.prefix { $0.isLetter })
        return letters.isEmpty ? symbol : letters.uppercased()
    }

    /// The funding rate for the current interval as a fraction of notional (`fundingRatePct100k / 100 000`):
    /// positive means long positions pay short positions.
    public var fundingRateHourly: Double { PerplFunding.hourlyRate(pct100k: fundingRatePct100k) }
    /// The venue's maximum leverage for this market (`floor(1 / initial margin fraction)`).
    public var maxLeverage: Double { (initMarginFraction ?? 0) > 0 ? max(1, (1 / initMarginFraction!).rounded(.down)) : 1 }
    /// The smallest tradable size (one lot).
    public var minSize: Double { pow(10, -Double(lotDecimals)) }

    public init(id: Int, symbol: String, name: String, priceDecimals: Int, lotDecimals: Int, basePricePNS: BigUInt, mark: Double, last: Double, oracle: Double, markTimestamp: Int, longOI: Double, shortOI: Double, fundingRatePct100k: Int, status: Int, initMarginFraction: Double?, maintMarginFraction: Double?, numOrders: Int, fundingStartBlock: UInt64 = 0, fundingClampPct100k: Int = 0) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.priceDecimals = priceDecimals
        self.lotDecimals = lotDecimals
        self.basePricePNS = basePricePNS
        self.mark = mark
        self.last = last
        self.oracle = oracle
        self.markTimestamp = markTimestamp
        self.longOI = longOI
        self.shortOI = shortOI
        self.fundingRatePct100k = fundingRatePct100k
        self.status = status
        self.initMarginFraction = initMarginFraction
        self.maintMarginFraction = maintMarginFraction
        self.numOrders = numOrders
        self.fundingStartBlock = fundingStartBlock
        self.fundingClampPct100k = fundingClampPct100k
    }
}

/// A trading account on the Exchange. Balances are in collateral units (AUSD, 6 decimals).
public struct PerpAccount: Hashable, Sendable {
    public let accountId: Int
    public let balance: BigUInt
    public let locked: BigUInt
    public let frozen: Bool
    /// Perpetual ids whose position slot the account's bitmap marks as open.
    public let positionPerpIds: [Int]

    public init(accountId: Int, balance: BigUInt, locked: BigUInt, frozen: Bool, positionPerpIds: [Int]) {
        self.accountId = accountId
        self.balance = balance
        self.locked = locked
        self.frozen = frozen
        self.positionPerpIds = positionPerpIds
    }
}

public struct PerpPosition: Identifiable, Hashable, Sendable, Codable {
    public var id: Int { perpId }
    public let perpId: Int
    public let symbol: String
    public let side: PositionSide
    public let size: Double
    public let entry: Double
    public let mark: Double
    /// Collateral posted, in AUSD.
    public let margin: Double
    /// Mark-to-market profit in AUSD, premium included.
    public let unrealized: Double
    /// Funding and settlement premium carried on the position, in AUSD.
    public let premium: Double
    public let leverage: Double
    public let liquidation: Double?
    public let notional: Double

    public init(perpId: Int, symbol: String, side: PositionSide, size: Double, entry: Double, mark: Double, margin: Double, unrealized: Double, premium: Double, leverage: Double, liquidation: Double?, notional: Double) {
        self.perpId = perpId
        self.symbol = symbol
        self.side = side
        self.size = size
        self.entry = entry
        self.mark = mark
        self.margin = margin
        self.unrealized = unrealized
        self.premium = premium
        self.leverage = leverage
        self.liquidation = liquidation
        self.notional = notional
    }
}

public struct PerpOrder: Identifiable, Hashable, Sendable {
    public var id: String { "\(perpId)-\(orderId)" }
    public let perpId: Int
    public let orderId: Int
    public let symbol: String
    public let type: PerpOrderType
    public let side: OrderSide
    public let price: Double
    public let size: Double
    public let leverage: Double
    public let expiryBlock: Int
    public let reduceOnly: Bool

    public init(perpId: Int, orderId: Int, symbol: String, type: PerpOrderType, side: OrderSide, price: Double, size: Double, leverage: Double, expiryBlock: Int, reduceOnly: Bool) {
        self.perpId = perpId
        self.orderId = orderId
        self.symbol = symbol
        self.type = type
        self.side = side
        self.price = price
        self.size = size
        self.leverage = leverage
        self.expiryBlock = expiryBlock
        self.reduceOnly = reduceOnly
    }
}

/// Perpl's public market context: 24h reference price, volume and funding per market.
public struct MarketContext: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let priceDecimals: Int
    public let sizeDecimals: Int
    public let mark: Double
    public let last: Double
    public let prev24h: Double
    public let volume24h: Double
    public let openInterest: Double
    /// The current interval's funding rate as a fraction of notional per hour (the gateway reports it in parts per
    /// million; the contract's `fundingRatePct100k` is the same number in parts per 100 000). Positive: longs pay shorts.
    public let fundingRate: Double
    public let isOpen: Bool
    /// Perpl's own length of a funding interval: `funding_interval_sec` seconds per `funding_interval_blocks` blocks
    /// (2,580 s per 8,571 blocks on 2026-09-08). 0 when the context didn't report it (`PerplFunding.secondsToNextSettlement`).
    public let fundingIntervalSeconds: Int
    public let fundingIntervalBlocks: Int
    /// Perpl's window for an order to execute, in blocks (`order_ttl_blocks`, 20 on 2026-10-08): an order sent with
    /// `lb: 0` gets this window. Nil when the context didn't report it (`PerplOutcomeDeadline` then counts 20).
    public let orderTTLBlocks: Int?

    public init(id: Int, name: String, priceDecimals: Int, sizeDecimals: Int, mark: Double, last: Double, prev24h: Double, volume24h: Double, openInterest: Double, fundingRate: Double, isOpen: Bool,
                fundingIntervalSeconds: Int = 0, fundingIntervalBlocks: Int = 0, orderTTLBlocks: Int? = nil) {
        self.id = id
        self.name = name
        self.priceDecimals = priceDecimals
        self.sizeDecimals = sizeDecimals
        self.mark = mark
        self.last = last
        self.prev24h = prev24h
        self.volume24h = volume24h
        self.openInterest = openInterest
        self.fundingRate = fundingRate
        self.isOpen = isOpen
        self.fundingIntervalSeconds = fundingIntervalSeconds
        self.fundingIntervalBlocks = fundingIntervalBlocks
        self.orderTTLBlocks = orderTTLBlocks
    }
}

/// What the user asked for. Market orders derive their limit price from the mark and the slippage allowance.
public struct OrderInput: Sendable {
    public var market: PerpMarket
    public var side: PositionSide
    public var kind: OrderKind
    /// Base units (contracts), not collateral.
    public var size: Double
    /// Limit price; ignored for market orders.
    public var price: Double?
    public var leverage: Double
    public var reduceOnly: Bool
    public var slippageBps: Int
    public var postOnly: Bool

    public init(market: PerpMarket, side: PositionSide, kind: OrderKind, size: Double, price: Double? = nil, leverage: Double, reduceOnly: Bool = false, slippageBps: Int = 100, postOnly: Bool = false) {
        self.market = market
        self.side = side
        self.kind = kind
        self.size = size
        self.price = price
        self.leverage = leverage
        self.reduceOnly = reduceOnly
        self.slippageBps = slippageBps
        self.postOnly = postOnly
    }
}

public enum PerplError: Error, LocalizedError, Equatable {
    case contextUnavailable(status: Int)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .contextUnavailable(let status): return L10n.tr("Perpl market data is unavailable (status \(String(status))).")
        case .malformedResponse(let what): return L10n.tr("Perpl sent \(what) the app could not read.")
        }
    }
}


/// One row of Perpl's authenticated account history: deposits, withdrawals, settlements, funding payments,
/// liquidations. `amount` is the signed change in AUSD; `balance` the account balance after it.
public struct PerplAccountEvent: Identifiable, Sendable, Hashable {
    public enum Kind: Int, Sendable, Hashable {
        case deposit = 1, withdrawal = 2, settlement = 4, liquidation = 5, funding = 8
        case other = 0
    }
    public let id: String
    public let time: Date
    public let kind: Kind
    public let rawType: Int
    public let marketId: Int?
    public let amount: Double
    public let balance: Double
    public let fee: Double

    public init(id: String, time: Date, kind: Kind, rawType: Int, marketId: Int?, amount: Double, balance: Double, fee: Double) {
        self.id = id; self.time = time; self.kind = kind; self.rawType = rawType; self.marketId = marketId; self.amount = amount; self.balance = balance; self.fee = fee
    }

    /// Parses one `AccountEvent` row (api-docs rest.md: `at`, `in`, `id`, `et`, `m`, `a`, `b`, `f`).
    init?(event j: [String: Any]) {
        guard let et = (j["et"] as? NSNumber)?.intValue else { return nil }
        let at = j["at"] as? [String: Any]
        let ms = (at?["t"] as? NSNumber)?.doubleValue ?? 0
        let block = (at?["b"] as? NSNumber)?.intValue ?? 0
        let market = (j["m"] as? NSNumber)?.intValue
        self.init(
            id: "\(et)-\(Int(exactly: ms.rounded(.towardZero)) ?? 0)-\(block)-\(market ?? 0)",
            time: Date(timeIntervalSince1970: ms / 1000),
            kind: Kind(rawValue: et) ?? .other,
            rawType: et,
            marketId: market,
            amount: PerplHistory.amount(j["a"]),
            balance: PerplHistory.amount(j["b"]),
            fee: PerplHistory.amount(j["f"])
        )
    }
}
