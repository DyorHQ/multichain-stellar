import BigInt
import Foundation
import Observation
import os

/* The authenticated Perpl trading WebSocket (wss://app.perpl.xyz/ws/v1/trading): sign in with the Ed25519 key,
   then place market / limit / stop / take-profit orders as mt:22 frames. Stop and take-profit are keeper-managed
   trigger orders — the only way to get real TP/SL, since the on-chain Exchange has no trigger primitive. Order
   placement/cancel/modify all flow through here; positions and open orders are still read from the contract. */

/// One order to send as an `mt:22` frame. Prices/sizes are scaled to the market's decimals here.
public struct PerplOrderFrame: Sendable {
    public enum TriggerCondition: Int, Sendable { case gteLast = 1, lteLast = 2, gteMark = 3, lteMark = 4 }

    public var type: PerpOrderType        // 0-indexed enum; mapped to the WS 1-indexed `t`
    public var marketId: Int
    public var accountId: Int
    public var pricePNS: Int              // scaled; 0 = market
    public var lotLNS: Int                // scaled size
    public var leverageHdths: Int         // leverage × 100 (0 for cancels / triggers)
    public var slippageBps: Int?          // `ms`, market orders
    public var ioc: Bool                  // fl: 4 IOC vs 0 GTC
    public var lastExecutionBlock: Int    // `lb`; 0 for triggers
    public var triggerPricePNS: Int?      // `tp`
    public var triggerCondition: TriggerCondition?
    public var linkedPositionId: Int?     // `lp`
    public var linkedRequestId: Int?      // `tr` — activate when this request trades (attach a trigger to an entry)
    public var orderId: Int?              // `oid`, for cancel/change
    /// A reserved request id (`PerplTradeClient.reserveRequestId`), so the triggers of a bracket can link to their entry
    /// via `tr`. Every other frame gets its id as it is written.
    public var requestId: Int?
    /// Post-only (`fl: 1`): a limit that must rest on the book as a maker, never fill at once as a taker.
    public var postOnly: Bool
    /// `a`: the collateral an IncreasePositionCollateral request adds, a whole number of 6-decimal units (CNS), written as
    /// a decimal string (types.md `OrderSpec.a`). Nil on every other frame.
    public var amountCNS: BigUInt?

    public init(type: PerpOrderType, marketId: Int, accountId: Int, pricePNS: Int, lotLNS: Int, leverageHdths: Int,
                slippageBps: Int? = nil, ioc: Bool, lastExecutionBlock: Int, triggerPricePNS: Int? = nil,
                triggerCondition: TriggerCondition? = nil, linkedPositionId: Int? = nil, linkedRequestId: Int? = nil,
                orderId: Int? = nil, requestId: Int? = nil, postOnly: Bool = false, amountCNS: BigUInt? = nil) {
        self.type = type; self.marketId = marketId; self.accountId = accountId; self.pricePNS = pricePNS
        self.lotLNS = lotLNS; self.leverageHdths = leverageHdths; self.slippageBps = slippageBps; self.ioc = ioc
        self.lastExecutionBlock = lastExecutionBlock; self.triggerPricePNS = triggerPricePNS
        self.triggerCondition = triggerCondition; self.linkedPositionId = linkedPositionId
        self.linkedRequestId = linkedRequestId; self.orderId = orderId; self.requestId = requestId; self.postOnly = postOnly
        self.amountCNS = amountCNS
    }

    /// The wire type `t` (1-indexed on the WS API; the enum is 0-indexed).
    public var wireType: Int { type.rawValue + 1 }

    /// The `mt:22` JSON object, given the request id `rq` and correlation `sn`.
    public func json(rq: Int, sn: Int) -> [String: Any] {
        var frame: [String: Any] = [
            "mt": 22, "sn": sn, "rq": rq, "mkt": marketId, "acc": accountId,
            "t": wireType, "p": pricePNS, "s": lotLNS, "fl": ioc ? 4 : (postOnly ? 1 : 0), "lv": leverageHdths, "lb": lastExecutionBlock,
        ]
        if let slippageBps { frame["ms"] = slippageBps }
        if let triggerPricePNS { frame["tp"] = triggerPricePNS }
        if let triggerCondition { frame["tpc"] = triggerCondition.rawValue }
        if let linkedPositionId { frame["lp"] = linkedPositionId }
        if let linkedRequestId { frame["tr"] = linkedRequestId }
        if let orderId { frame["oid"] = orderId }
        if let amountCNS { frame["a"] = String(amountCNS) }
        return frame
    }
}

/// Builds the order frames for a ticket: the entry order, plus optional take-profit and stop-loss triggers.
public enum PerplOrders {
    // `Int(exactly:)`, not `Int(_:)`: a non-finite or out-of-range value (a pasted "1e300") becomes 0 — an order Perpl
    // refuses — instead of trapping.
    private static func scalePrice(_ price: Double, _ market: PerpMarket) -> Int { Int(exactly: (price * pow(10, Double(market.priceDecimals))).rounded()) ?? 0 }
    private static func scaleSize(_ size: Double, _ market: PerpMarket) -> Int { Int(exactly: (size * pow(10, Double(market.lotDecimals))).rounded()) ?? 0 }

    /// The entry order. A market order is a marketable-limit IOC at the slippage bound (`p:0`, `ms`, `fl:4`); a
    /// post-only limit carries `fl:1` (post-only applies to limits only).
    ///
    /// `lb` (last-execution block) is sent as `0`: Perpl then substitutes the market's OWN maximum window
    /// (`order_ttl_blocks`). Computing `head + ttlBlocks` ourselves — from the RPC block, which runs ahead of Perpl's
    /// heartbeat head — overshot that ceiling and every entry was rejected with `last exec block too high` (which is
    /// why authenticated market/limit orders and TP/SL brackets all failed once one-click was on). The
    /// `head`/`ttlBlocks` parameters are kept for source compatibility but no longer bound the entry.
    public static func entry(_ input: OrderInput, accountId: Int, head: Int, ttlBlocks: Int = 100) -> PerplOrderFrame {
        let type: PerpOrderType = input.reduceOnly
            ? (input.side == .long ? .closeShort : .closeLong)     // reduce-only market close
            : (input.side == .long ? .openLong : .openShort)
        let market = input.kind == .market
        return PerplOrderFrame(
            type: type, marketId: input.market.id, accountId: accountId,
            pricePNS: market ? 0 : scalePrice(input.price ?? input.market.mark, input.market),
            lotLNS: scaleSize(input.size, input.market),
            leverageHdths: Int((input.leverage * 100).rounded()),
            slippageBps: market ? input.slippageBps : nil,
            ioc: market,
            lastExecutionBlock: 0,
            postOnly: !market && input.postOnly
        )
    }

    /// A take-profit trigger that closes `size` of a `side` position at `price`. Long TP fires when price rises
    /// (GTE Last); short TP fires when price falls (LTE Last). Market on trigger (`p:0`, IOC, `lb:0`).
    public static func takeProfit(side: PositionSide, price: Double, size: Double, market: PerpMarket, accountId: Int, linkedPositionId: Int?) -> PerplOrderFrame {
        PerplOrderFrame(
            type: side == .long ? .closeLong : .closeShort, marketId: market.id, accountId: accountId,
            pricePNS: 0, lotLNS: scaleSize(size, market), leverageHdths: 0, ioc: true, lastExecutionBlock: 0,
            triggerPricePNS: scalePrice(price, market),
            triggerCondition: side == .long ? .gteLast : .lteLast, linkedPositionId: linkedPositionId
        )
    }

    /// A stop-loss trigger. Long SL fires when the mark falls (LTE Mark); short SL when the mark rises (GTE Mark).
    public static func stopLoss(side: PositionSide, price: Double, size: Double, market: PerpMarket, accountId: Int, linkedPositionId: Int?) -> PerplOrderFrame {
        PerplOrderFrame(
            type: side == .long ? .closeLong : .closeShort, marketId: market.id, accountId: accountId,
            pricePNS: 0, lotLNS: scaleSize(size, market), leverageHdths: 0, ioc: true, lastExecutionBlock: 0,
            triggerPricePNS: scalePrice(price, market),
            triggerCondition: side == .long ? .lteMark : .gteMark, linkedPositionId: linkedPositionId
        )
    }

    public static func cancel(perpId: Int, orderId: Int, accountId: Int, head: Int) -> PerplOrderFrame {
        // `lb: 0` for the same reason as `entry` — a computed `head + 100` can exceed the market's ceiling and be
        // rejected with `last exec block too high`.
        PerplOrderFrame(type: .cancel, marketId: perpId, accountId: accountId, pricePNS: 0, lotLNS: 0, leverageHdths: 0, ioc: false, lastExecutionBlock: 0, orderId: orderId)
    }

    /// Adds `amountCNS` (AUSD, 6-decimal units) of collateral to the account's open position on `perpId`: an
    /// IncreasePositionCollateral request (`t: 6`), which never matches (websocket.md: `mnp` ignored), with `a` the amount
    /// as a decimal string and `lb: 0` like every frame.
    public static func addMargin(perpId: Int, amountCNS: BigUInt, accountId: Int) -> PerplOrderFrame {
        PerplOrderFrame(type: .increasePositionCollateral, marketId: perpId, accountId: accountId, pricePNS: 0, lotLNS: 0, leverageHdths: 0,
                        ioc: false, lastExecutionBlock: 0, amountCNS: amountCNS)
    }

    /// Why `frame` must not be sent, or nil. The scaling above turns a price below one tick into 0, and on Perpl a
    /// 0 means something else: a trigger with `tp: 0` is a plain reduce-only market close that executes the moment it
    /// is admitted (a take-profit or stop-loss typed as "0" would close the position at once), and a resting order
    /// with `p: 0` is a market order. Checked for every frame before any is sent, so a bracket is refused whole.
    public static func problem(_ frame: PerplOrderFrame) -> String? {
        switch frame.type {
        case .cancel, .change:
            return nil
        case .increasePositionCollateral:
            guard let amount = frame.amountCNS, amount > 0 else {
                return L10n.string(LocalizedStringResource("The margin amount rounds to zero.", bundle: L10n.kit, comment: "Add Margin's error: the amount entered is below the smallest unit of AUSD, so nothing was sent."))
            }
            return nil
        case .openLong, .openShort, .closeLong, .closeShort:
            if frame.lotLNS <= 0 { return L10n.tr("The order size rounds to zero on this market.") }
            if frame.triggerCondition != nil || frame.triggerPricePNS != nil {
                guard frame.type == .closeLong || frame.type == .closeShort else { return L10n.tr("A take-profit or stop-loss can only close a position.") }
                guard (frame.triggerPricePNS ?? 0) > 0, frame.triggerCondition != nil else { return L10n.tr("The take-profit or stop-loss price rounds to zero on this market.") }
                return nil
            }
            if !frame.ioc, frame.pricePNS <= 0 { return L10n.tr("The limit price rounds to zero on this market.") }
            return nil
        }
    }
}

/// The result of an order request: the gateway ack (`mt:3`). `code == 0` means accepted for forwarding.
public struct PerplOrderAck: Sendable {
    public let code: Int
    public let error: String?
    /// The frame went out but no status came back (the ack timed out, or the socket closed while waiting): Perpl may
    /// have placed it, so it is neither accepted nor rejected — the caller says so and never resends it blindly.
    public let outcomeUnknown: Bool
    public var accepted: Bool { code == 0 && !outcomeUnknown }
    /// The request id the frame was written with: nil only when nothing was written.
    public let requestId: Int?
    /// The trading heartbeat's head block when the ack arrived (the outcome deadline counts from it).
    public let head: Int?
    public let receivedAt: Date

    public init(code: Int, error: String?, outcomeUnknown: Bool = false, requestId: Int? = nil, head: Int? = nil, receivedAt: Date = Date()) {
        self.code = code
        self.error = error
        self.outcomeUnknown = outcomeUnknown
        self.requestId = requestId
        self.head = head
        self.receivedAt = receivedAt
    }
}

public enum PerplTradeError: LocalizedError {
    case notSignedIn, noAccount, forwardingDisabled, timeout, closed(String)
    /// The trading socket is not connected, so nothing was sent (the message says why).
    case unavailable(String)
    /// Refused on the device before anything was sent: the frame would not do what the ticket says (a zero trigger
    /// price is a market close that fires at once, a zero-price limit is a market order).
    case invalidOrder(String)
    /// The order frame was already sent when this happened (no acknowledgement, or the socket closed while waiting),
    /// so Perpl may have placed it: the caller must not offer an immediate resend.
    public var outcomeUnknown: Bool {
        switch self {
        case .timeout, .closed: return true
        case .notSignedIn, .noAccount, .forwardingDisabled, .unavailable, .invalidOrder: return false
        }
    }
    public var errorDescription: String? {
        switch self {
        case .notSignedIn: return L10n.tr("Not connected to Perpl trading.")
        case .noAccount: return L10n.tr("No Perpl trading account. Deposit AUSD first.")
        case .forwardingDisabled: return L10n.tr("Enable one-click trading (order forwarding) on your Perpl account first.")
        case .timeout: return L10n.tr("Perpl did not acknowledge the order in time.")
        case .closed(let why): return why // already a full sentence from PerplClose.message
        case .unavailable(let why): return why
        case .invalidOrder(let why): return why
        }
    }
}

/// Why the trading socket closed, as the server reported it: the RFC 6455 close code plus Perpl's reason string
/// (api-docs README → "WebSocket Close Codes"). URLSession surfaces every server-initiated close as the same generic
/// "Socket is not connected" — the code and reason on the task are the only way to tell an idle timeout from a
/// rejected key from the per-wallet connection cap, so they are kept and turned into a specific message here.
public struct PerplClose: Sendable, Equatable {
    public let code: Int
    public let reason: String

    /// 3401 — the API key was rejected. Retrying with the same key can never succeed; the user must re-enroll.
    public var isAuthFailure: Bool { code == 3401 }
    /// 1008 "too many connections" — Perpl allows 4 trading sockets per WALLET (shared with app.perpl.xyz tabs).
    // not localized: Perpl's own English close reasons, matched as it sends them
    public var isConnectionCap: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many connections") }
    public var isRateLimit: Bool { code == 1008 && reason.localizedCaseInsensitiveContains("too many requests") }

    public var message: String {
        switch code {
        case 3401:
            return L10n.tr("Perpl rejected this trading key. Remove the API key below and connect again to enroll a fresh one.")
        case 1008 where isConnectionCap:
            return L10n.tr("Too many Perpl trading connections for this wallet — Perpl allows 4, shared with the Perpl web app. Close other Perpl sessions (or wait a minute) and try again.")
        case 1008 where isRateLimit:
            return L10n.tr("Perpl's trading rate limit was hit. Wait a moment and try again.")
        case 1008:
            return L10n.tr("Perpl closed the idle trading connection (\(reason)). It reconnects on your next order.")
        case 1011:
            return L10n.tr("Perpl couldn't process a trading frame (\(reason)). Reconnect and try again.")
        case 1013:
            return L10n.tr("Perpl dropped the trading connection because the app fell behind reading it. Try again.")
        case 1001:
            return L10n.tr("Perpl's trading server is restarting. Try again in a moment.")
        case 0:
            return reason.isEmpty ? L10n.tr("Perpl trading connection was lost.") : L10n.tr("Perpl trading connection was lost: \(reason).")
        default:
            return reason.isEmpty ? L10n.tr("Perpl trading connection closed (code \(String(code))).") : L10n.tr("Perpl trading connection closed (\(String(code)): \(reason)).")
        }
    }
}

/// One open order from the authenticated trading stream (mt:23/24) — a resting limit order or a pending keeper trigger
/// (TP/SL). Prices and sizes are the market's scaled integers (the market's decimals live in the app layer, so scaling
/// happens where a `PerpMarket` is in hand). `OrderType` here is Perpl's 1-indexed API enum, NOT the 0-indexed on-chain
/// `PerpOrderType`.
public struct PerplOpenOrder: Identifiable, Sendable, Hashable {
    /// An order is known by its market AND its id: Perpl's order ids are per market (on-chain `getOrder(perpId,
    /// orderId)`), so the same id on two markets is two orders.
    public struct Key: Hashable, Sendable {
        public let marketId: Int
        public let oid: Int
        public init(marketId: Int, oid: Int) { self.marketId = marketId; self.oid = oid }
    }

    public let oid: Int
    public let marketId: Int
    public let typeRaw: Int              // 1 OpenLong, 2 OpenShort, 3 CloseLong, 4 CloseShort
    public let statusRaw: Int            // 2 Open, 3 PartiallyFilled, 8 Untriggered, 9 Triggered
    public let priceRaw: Int             // limit price (0 = market)
    public let sizeRaw: Int              // original size
    public let filledRaw: Int
    public let triggerPriceRaw: Int?     // `tp`
    public let triggerConditionRaw: Int? // `tpc`: 1/2 last-based (take-profit), 3/4 mark-based (stop-loss)
    public let linkedPositionId: Int?
    public let leverageHundredths: Int
    /// Perpl's "Smart contract order ID" (`scid`, types.md `Order`): the id the Exchange contract knows the order by, so
    /// the on-chain order a card shows can be matched to the stream's (`streamOrder`). Nil when Perpl didn't send one.
    public let contractOrderId: Int?
    public var key: Key { Key(marketId: marketId, oid: oid) }
    public var id: Key { key }

    public init(oid: Int, marketId: Int, typeRaw: Int, statusRaw: Int, priceRaw: Int, sizeRaw: Int, filledRaw: Int,
                triggerPriceRaw: Int?, triggerConditionRaw: Int?, linkedPositionId: Int?, leverageHundredths: Int, contractOrderId: Int? = nil) {
        self.oid = oid; self.marketId = marketId; self.typeRaw = typeRaw; self.statusRaw = statusRaw
        self.priceRaw = priceRaw; self.sizeRaw = sizeRaw; self.filledRaw = filledRaw
        self.triggerPriceRaw = triggerPriceRaw; self.triggerConditionRaw = triggerConditionRaw
        self.linkedPositionId = linkedPositionId; self.leverageHundredths = leverageHundredths
        self.contractOrderId = contractOrderId
    }

    /// A keeper trigger (take-profit / stop-loss) rather than a plain resting order.
    public var isTrigger: Bool { (triggerPriceRaw ?? 0) != 0 }
    public var isReduceOnly: Bool { typeRaw == 3 || typeRaw == 4 }
    /// The side of the position a reduce-only trigger protects: CloseLong (3) protects a long.
    public var protectsLong: Bool { typeRaw == 3 }
    /// The trigger fires when price rises through it (GTE conditions 1/3) vs falls through it (LTE 2/4).
    private var firesOnRise: Bool { triggerConditionRaw == 1 || triggerConditionRaw == 3 }
    /// Take-profit vs stop-loss is defined by the close side and direction — a long is stopped out when price falls
    /// and takes profit when it rises (the reverse for a short) — NOT by whether last or mark is watched. This
    /// classifies triggers placed anywhere (including the Perpl web app), not only this app's own last/mark convention.
    public var isStopLoss: Bool { protectsLong ? !firesOnRise : firesOnRise }
    /// A resting order that can still open or grow a position (OpenLong / OpenShort, not a trigger). A trigger attached
    /// to such an entry (`tr`) waits for it to fill, so the triggers closing that side of its market are never treated
    /// as orphaned.
    public var isRestingEntry: Bool { !isTrigger && (typeRaw == 1 || typeRaw == 2) }
    /// The side of the market this order acts on: the position a trigger closes, or the one an entry opens.
    public var side: PerplMarketSide { PerplMarketSide(marketId: marketId, isLong: isReduceOnly ? protectsLong : typeRaw == 1) }
}

extension PerplOpenOrder {
    /// The stream's order for an on-chain resting order (`PerpOrder`), found only by Perpl's own "Smart contract order ID"
    /// (`scid`): the same market, `scid` equal to the chain's order id, not a trigger, the same type (the stream's `t` is
    /// the chain's 0-indexed type + 1) and the same price at the market's precision. Exactly one match, else nil — no
    /// `scid`, or any term that differs, means the app can't name the order Perpl would cancel, so its cancel stays a
    /// wallet transaction. Never matched by `oid`: whether `oid` equals `scid` is the census's open question.
    public static func streamOrder(for chain: PerpOrder, in orders: [PerplOpenOrder], priceDecimals: Int) -> PerplOpenOrder? {
        guard let price = Int(exactly: (chain.price * pow(10, Double(priceDecimals))).rounded()) else { return nil }
        let matches = orders.filter { order in
            order.marketId == chain.perpId && order.contractOrderId == chain.orderId && !order.isTrigger
                && order.typeRaw == chain.type.rawValue + 1 && order.priceRaw == price
        }
        return matches.count == 1 ? matches.first : nil
    }
}

/// One side of one market: a position there, or the entries and triggers that act on it.
public struct PerplMarketSide: Hashable, Sendable {
    public let marketId: Int
    public let isLong: Bool
    public init(marketId: Int, isLong: Bool) { self.marketId = marketId; self.isLong = isLong }
}

/// One position from the authenticated stream (mt:26 snapshot, mt:27 updates). `pid` is the id a trigger links to
/// (`lp`): Perpl cancels a position-linked trigger itself when that position closes or inverts. Size is the market's
/// scaled integer, like `PerplOpenOrder`.
public struct PerplLivePosition: Sendable, Hashable {
    public let pid: Int
    public let marketId: Int
    public let isLong: Bool
    public let sizeRaw: Int
    /// 1 Open, 2 Closed, 3 Liquidated, 4 Deleveraged, 5 Unwound, 6 Failed.
    public let statusRaw: Int
    /// What the stream adds (mt:26/27), read by nothing on screen in this build: the chain stays the source of the
    /// position cards. `ep`, `c` (6-dp collateral units), `lv` (hundredths), and the request / order that last changed it.
    public let entryPriceRaw: Int?
    public let collateralCNS: String?
    public let leverageHundredths: Int?
    public let requestId: Int?
    public let orderId: Int?
    public let statusReason: Int?

    public init(pid: Int, marketId: Int, isLong: Bool, sizeRaw: Int, statusRaw: Int, entryPriceRaw: Int? = nil, collateralCNS: String? = nil,
                leverageHundredths: Int? = nil, requestId: Int? = nil, orderId: Int? = nil, statusReason: Int? = nil) {
        self.pid = pid; self.marketId = marketId; self.isLong = isLong; self.sizeRaw = sizeRaw; self.statusRaw = statusRaw
        self.entryPriceRaw = entryPriceRaw; self.collateralCNS = collateralCNS; self.leverageHundredths = leverageHundredths
        self.requestId = requestId; self.orderId = orderId; self.statusReason = statusReason
    }

    public var isOpen: Bool { statusRaw == 1 && sizeRaw > 0 }
    public var wasLiquidated: Bool { statusRaw == 3 }
    /// Closed by the protocol rather than by an order: liquidated, deleveraged or unwound.
    public var endedByProtocol: Bool { statusRaw == 3 || statusRaw == 4 || statusRaw == 5 }
}

/// A keeper trigger (take-profit / stop-loss) changing state on the authenticated stream: it fired (Perpl is closing
/// the position), or it failed — refused after the gateway admitted it, or it fired and could not execute, which
/// leaves the position open without that protection — or it expired without firing.
public struct PerplTriggerEvent: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case triggered
        /// `reason` is Perpl's `sr` (OrderStatusReason), e.g. 64 TriggeredExecutionAttemptsExhausted, 67
        /// TriggeredOrderExpired.
        case failed(reason: Int)
        /// It reached its time-in-force without firing (Expired, 6): it no longer protects anything.
        case expired
    }
    public let order: PerplOpenOrder
    public let outcome: Outcome

    public init(order: PerplOpenOrder, outcome: Outcome) {
        self.order = order
        self.outcome = outcome
    }
}

/// What became of an order a cancel was sent for, as the live list of the socket that sent the cancel shows it (an
/// accepted cancel is only admitted: it lands, or not, on the stream).
public enum PerplCancelResult: Sendable, Equatable {
    /// It left the live list cancelled: Perpl's own report for it, or the cancel's report that it went through.
    case cancelled
    /// It triggered (or filled) before the cancel landed.
    case firedFirst
    /// It had expired before the cancel landed.
    case expiredFirst
    /// It was gone before the cancel landed: not on the list when the cancel went out, or it failed on its own.
    case alreadyGone
    /// Perpl refused the cancel and the order is still on the list: Perpl's reason, as a whole sentence.
    case refused(String)
    /// Still on the list when the wait ended, or the socket stopped being live: it may still be live.
    case notConfirmed

    /// How an order that left the live list left it, from the status it left with (`lastTerminalStatus`): 5 (or the
    /// cancel's own report, recorded as 5) cancelled; 4, 9, 10 fired; 6 expired; 7 failed on its own, so already gone; a
    /// live status (an `r: true` that kept the status it had) cancelled.
    public static func left(withStatus status: Int) -> PerplCancelResult {
        switch status {
        case 4, 9, 10: return .firedFirst
        case 6: return .expiredFirst
        case 7: return .alreadyGone
        default: return .cancelled
        }
    }

    /// The order is no longer on Perpl's live list.
    public var isGone: Bool {
        switch self {
        case .cancelled, .firedFirst, .expiredFirst, .alreadyGone: return true
        case .refused, .notConfirmed: return false
        }
    }
}

/// Live authenticated connection: signs in, tracks the account (id, forwarding, request-id seed) and places orders.
@Observable
@MainActor
public final class PerplTradeClient {
    public private(set) var signedIn = false
    public private(set) var accountId: Int?
    public private(set) var forwardingEnabled = false
    public private(set) var error: String?
    /// The account's live open orders — resting limit orders AND pending keeper triggers (TP/SL) — as the authenticated
    /// stream reports them (mt:23 snapshot on connect, mt:24 updates after). This is the ONLY authoritative source for
    /// pending triggers, since they never touch the on-chain order book. Empty until the first snapshot arrives.
    public private(set) var openOrders: [PerplOpenOrder] = []
    private var ordersByKey: [PerplOpenOrder.Key: PerplOpenOrder] = [:]
    /// Orders Perpl has reported with a status other than Failed on this socket. Per Perpl's client-side deduplication
    /// rule (api-docs websocket.md) that first non-failure status is definitive, so a later failure only a resent
    /// request can get (`duplicateRequestFailures`) is a stale echo, not the order's end.
    private var admitted: Set<PerplOpenOrder.Key> = []
    /// The mt:23 snapshot has arrived on this socket, so `openOrders` is the whole set rather than whatever updates
    /// came in first. Until then (and on a socket that dropped) the list proves nothing about what is live.
    public private(set) var hasOrdersSnapshot = false
    /// The account's open positions as the authenticated stream reports them (mt:26 snapshot, mt:27 updates) — the
    /// source of the position id a trigger links to (`lp`).
    public private(set) var positions: [PerplLivePosition] = []
    private var positionsByPid: [Int: PerplLivePosition] = [:]
    public private(set) var hasPositionsSnapshot = false
    /// Fired on the main actor whenever `openOrders` changes, so the owner can republish it.
    public var onOrdersUpdate: (@MainActor () -> Void)?
    /// Fired on the main actor when a trigger fires or fails (from mt:24 updates only — a snapshot is state, not a
    /// transition). Each trigger reports each outcome once.
    public var onTriggerEvent: (@MainActor (PerplTriggerEvent) -> Void)?
    /// Fired on the main actor when an update (mt:27) reports a position that is no longer open — closed by an order,
    /// or liquidated, deleveraged or unwound — after `positions` already reflects it.
    public var onPositionEnded: (@MainActor (PerplLivePosition) -> Void)?
    private var announcedTriggers: Set<String> = []
    private var endedPositions: Set<Int> = []
    /// Order requests between their first frame and their last ack (`place`, `placeAll`, `sendEach`).
    private var requestsInFlight = 0
    /// Fired on the main actor whenever account state (id / forwardingEnabled / lfr) changes — from the initial
    /// snapshot or a later AccountUpdate — so the owner can re-derive its status the moment forwarding turns on.
    public var onAccountUpdate: (@MainActor () -> Void)?
    /// Fired on the main actor when the socket drops, so the owner can flip status off `.connected` and reconnect on
    /// next use (the socket has no reconnect of its own).
    public var onDisconnect: (@MainActor () -> Void)?
    /// How the last socket ended, from the server's close frame — read it in `onDisconnect` to decide whether a
    /// retry can help (idle timeout: yes; 3401 rejected key: never; connection cap: only after backing off).
    public private(set) var lastClose: PerplClose?
    private var keepAlive: Task<Void, Never>?

    /// The account's balance and locked balance (AUSD, 6-dp units) from the WalletSnapshot and its AccountUpdates. Nil
    /// until one arrives, or when Perpl sent a value that isn't a whole number (never a guess).
    public private(set) var balanceCNS: BigUInt?
    public private(set) var lockedBalanceCNS: BigUInt?
    /// The trading heartbeat (mt:100): head block, sequence, gaps. Log-only: a gap never closes the socket.
    @ObservationIgnored public private(set) var heartbeat = PerplHeartbeat()
    /// A heartbeat gap after an in-order run: updates may have been missed since the snapshots, so the live lists may be
    /// out of date. The automatic TP/SL clean-up doesn't act on a suspect stream.
    public private(set) var streamSuspect = false
    /// When this socket's WalletSnapshot arrived (signed in).
    @ObservationIgnored public private(set) var signedInAt: Date?
    /// What the stream did on this socket, counted (no ids, no amounts). `drainCensus` hands it over.
    @ObservationIgnored public private(set) var census = PerplStreamCensus()
    /// Perpl's reports per request (mt:23/24/25/26/27), deduplicated as Perpl's docs say.
    @ObservationIgnored private var ledger = PerplOrderLedger(account: nil)
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
    /// The terminal status (and reason) each order last left the live list with (≤ 128, newest kept).
    @ObservationIgnored private var lastTerminal: [PerplOpenOrder.Key: (status: Int, reason: Int)] = [:]
    @ObservationIgnored private var lastTerminalOrder: [PerplOpenOrder.Key] = []
    /// The same, by Perpl's smart contract order id (`scid`) for the orders that carried one (≤ 128, newest kept), with
    /// when it was seen: how an on-chain order the stream knew left its list (`lastTerminalStatus(marketId:contractOrderId:)`).
    /// The Exchange gives an id again, so a record speaks only of the order that held the id then.
    @ObservationIgnored private var lastTerminalByScid: [PerplOpenOrder.Key: (status: Int, reason: Int, at: Date)] = [:]
    @ObservationIgnored private var lastTerminalScidOrder: [PerplOpenOrder.Key] = []
    /// The collateral a position gained in an mt:27 that carried the request id of an IncreasePositionCollateral request
    /// this socket wrote, by that request id (6-decimal units, ≤ 64).
    @ObservationIgnored private var collateralGrowth: [Int: BigUInt] = [:]
    /// The collateral positions gained in mt:27 updates that carried no such request id, and whether their size stayed
    /// the same (≤ 16, kept 60 s): `collateralGrowthWithoutRequest`.
    @ObservationIgnored private var growthWithoutRequest: [(pid: Int, delta: BigUInt, sizeUnchanged: Bool, at: Date)] = []
    /// Request ids an mt:27 named in the position's own `rq` while reporting it closed (`st 2`), ≤ 64: what says a close
    /// sent from here ended the position (`positionClosed(byRequest:)`).
    @ObservationIgnored private var closedByRequest: Set<Int> = []
    @ObservationIgnored private var closedByRequestOrder: [Int] = []
    /// What was written per request id on this socket (≤ 256, newest kept).
    @ObservationIgnored private var sentRequests: [Int: PerplSentRequest] = [:]
    /// The highest request id written on this socket: a reserved id must be above it, so ids rise in write order.
    @ObservationIgnored private var lastWrittenRq = 0
    /// The request id written with each frame awaiting its ack (by `sn`), so the ack can report it.
    @ObservationIgnored private var pendingRq: [Int: Int] = [:]
    @ObservationIgnored private var snapshotsReported = false
    /// Census bookkeeping: a bracket entry's `tr`-linked triggers, the order each cancel was written for, and which
    /// one-time counts each request already gave.
    @ObservationIgnored private var children: [Int: [Int]] = [:]
    @ObservationIgnored private var cancelTargets: [PerplOpenOrder.Key: Int] = [:]
    @ObservationIgnored private var counted: [Int: CensusMarks] = [:]
    /// Each cancel this socket wrote, by its request id: the order it cancels, and whether that order was on this socket's
    /// live list when the cancel went out (nil: the list wasn't in yet). Kept as long as `sentRequests` keeps the id.
    @ObservationIgnored private var cancelsWritten: [Int: (key: PerplOpenOrder.Key, listed: Bool?)] = [:]
    /// Test seam: when set, frames are written here instead of the socket (and stand in for it in the guards).
    @ObservationIgnored var transport: ((String) -> Void)?
    #if DEBUG
    /// DEBUG builds only: this client is the scripted Perps demo's (`debugScripted()`), which never connects. Set once, by
    /// `debugScripted()`; false for every client built with `init(key:)`.
    @ObservationIgnored public private(set) var isDebugScripted = false
    #endif

    /// Fired on the main actor after the existing state is updated: each mt:24's orders, mt:25's fills, mt:27's
    /// positions; any own-account 21/24/25/27; a heartbeat that isn't in order; each request id as it is written (for the
    /// device's high-water mark); and once per socket when both snapshots (mt:23 and mt:26) have arrived.
    @ObservationIgnored public var onOrderEvents: (@MainActor ([PerplOrderEvent]) -> Void)?
    @ObservationIgnored public var onFills: (@MainActor ([PerplFillEvent]) -> Void)?
    @ObservationIgnored public var onPositionEvents: (@MainActor ([PerplPositionEvent]) -> Void)?
    @ObservationIgnored public var onAccountActivity: (@MainActor () -> Void)?
    @ObservationIgnored public var onHeartbeat: (@MainActor (PerplHeartbeat.Beat) -> Void)?
    @ObservationIgnored public var onRequestIdIssued: (@MainActor (Int) -> Void)?
    @ObservationIgnored public var onSnapshotsComplete: (@MainActor () -> Void)?

    private struct Waiter {
        let rq: Int
        let sent: PerplSentRequest
        let deadline: PerplOutcomeDeadline
        let continuation: CheckedContinuation<PerplOrderOutcome, Never>
    }

    private struct CensusMarks: OptionSet {
        let rawValue: UInt8
        static let firstEvent = CensusMarks(rawValue: 1 << 0)
        static let scid = CensusMarks(rawValue: 1 << 1)
        static let cancelOwn = CensusMarks(rawValue: 1 << 2)
        static let failThenOk = CensusMarks(rawValue: 1 << 3)
        static let foreign = CensusMarks(rawValue: 1 << 4)
        static let zeroFillChecked = CensusMarks(rawValue: 1 << 5)
        static let margin = CensusMarks(rawValue: 1 << 6)
        static let marginPosition = CensusMarks(rawValue: 1 << 7)
    }

    private let chainId: Int
    private let wsURL: URL
    private let key: PerplApiKey
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var lastForwardedRq = 0
    private var snCounter = 0
    private var pending: [Int: CheckedContinuation<PerplOrderAck, Error>] = [:]
    private var connectContinuation: CheckedContinuation<Void, Error>?

    public init(key: PerplApiKey, chainId: Int = 143, wsURL: URL = URL(string: "wss://app.perpl.xyz/ws/v1/trading")!, session: URLSession = .shared) {
        self.chainId = chainId
        self.key = key
        self.wsURL = wsURL
        self.session = session
    }

    /// Something sent on this socket is still waiting for Perpl: an order request mid-way through its frames, a frame
    /// whose ack hasn't come back, or an outcome being waited for. Closing the socket now would leave it unknown.
    public var hasRequestsInFlight: Bool { requestsInFlight > 0 || !pending.isEmpty || !waiters.isEmpty }

    /// Connects and signs in, resolving once the WalletSnapshot has seeded the account and request-id counter.
    public func connect(timeout: TimeInterval = 10) async throws {
        #if DEBUG
        precondition(!isDebugScripted, "a scripted demo client never connects")
        #endif
        if self.task != nil { disconnect() } // one socket per client, ever
        lastClose = nil
        hasOrdersSnapshot = false
        hasPositionsSnapshot = false
        snapshotsReported = false
        let socket = session.webSocketTask(with: wsURL)
        self.task = socket
        socket.resume()
        // Sign in as the very first frame: Perpl closes the socket (1008 idle timeout) if it doesn't arrive promptly.
        try signIn()
        receive(on: socket)
        // Keep the socket alive with Perpl's APPLICATION ping (`mt:1`, api-docs websocket.md → Keep-Alive). A
        // WebSocket protocol ping is answered at the edge and never reaches Perpl as activity, so the server's idle
        // timeout would still close the socket between orders. 30s = 2 requests/min of the 120/min budget.
        keepAlive?.cancel()
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                self?.send(["mt": 1, "t": Int(Date().timeIntervalSince1970 * 1000)])
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            // Scoped to THIS socket: a stale attempt's timer must never fail a later connect's continuation.
            Task { try? await Task.sleep(for: .seconds(timeout)); if self.task === socket { self.failConnect(PerplTradeError.timeout) } }
        }
    }

    /// Tears the socket down and fails anything still waiting on it (an in-flight connect, unacknowledged orders),
    /// so no caller can hang on a socket that no longer exists.
    public func disconnect() {
        keepAlive?.cancel()
        keepAlive = nil
        let open = task
        task = nil
        signedIn = false
        hasOrdersSnapshot = false
        hasPositionsSnapshot = false
        snapshotsReported = false
        open?.cancel(with: .goingAway, reason: nil)
        let closed = PerplTradeError.closed(L10n.tr("Trading connection was closed."))
        failConnect(closed)
        for (_, c) in pending { c.resume(throwing: closed) }
        pending.removeAll()
        pendingRq.removeAll()
        releaseWaiters()
    }

    /// Places the frames in order (entry first, then triggers), returning the entry's ack. Triggers are sent
    /// best-effort after the entry is accepted.
    public func place(_ frames: [PerplOrderFrame]) async throws -> PerplOrderAck {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var firstAck: PerplOrderAck?
        for frame in frames {
            let ack = try await send(frame)
            if firstAck == nil { firstAck = ack }
            if !ack.accepted { break }
        }
        return firstAck ?? PerplOrderAck(code: -1, error: "No frames") // not localized: an ack's error, as Perpl's own are
    }

    /// Places the frames in order and returns EVERY frame's ack (stopping after the first rejection). Lets a caller
    /// verify that a linked take-profit / stop-loss actually landed, not just the entry — critical for a bracket that
    /// must never leave a position unprotected.
    public func placeAll(_ frames: [PerplOrderFrame]) async throws -> [PerplOrderAck] {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var acks: [PerplOrderAck] = []
        for (index, frame) in frames.enumerated() {
            let ack: PerplOrderAck
            let (rq, result) = await sendTracked(frame)
            switch result {
            case .success(let answered):
                ack = answered
            case .failure(let error) where index > 0:
                // The entry was already acknowledged: this trigger isn't accepted, so the caller warns that the position
                // may be unprotected, instead of failing the whole bracket, which the order sheet would show as a failed
                // order — inviting a second entry. Sent and unanswered is "unknown" (it may be live); never sent is not.
                acks.append(Self.unanswered(error, fallback: L10n.tr("Perpl did not confirm this trigger."), requestId: rq))
                continue
            case .failure(let error):
                // The entry itself: the caller's catch (GL-1). It knows the entry's id from its reservation.
                throw error
            }
            acks.append(ack)
            // Only a rejected ENTRY ends the bracket. A rejected take-profit must not keep the stop-loss from being sent
            // — the position would open with no stop at all.
            if !ack.accepted, index == 0 { break }
        }
        return acks
    }

    /// Sends each frame in turn and returns every frame's ack, whatever the others did — for independent requests such
    /// as cancelling several triggers. Throws only when nothing could be sent.
    public func sendEach(_ frames: [PerplOrderFrame]) async throws -> [PerplOrderAck] {
        try admit(frames)
        requestsInFlight += 1
        defer { requestsInFlight -= 1 }
        var acks: [PerplOrderAck] = []
        for frame in frames {
            let (rq, result) = await sendTracked(frame)
            switch result {
            case .success(let ack): acks.append(ack)
            case .failure(let error): acks.append(Self.unanswered(error, fallback: L10n.tr("Perpl did not confirm this request."), requestId: rq))
            }
        }
        return acks
    }

    /// Checks a request before its first frame goes out: signed in, forwarding on, and every frame sendable.
    private func admit(_ frames: [PerplOrderFrame]) throws {
        guard signedIn, task != nil || transport != nil, accountId != nil else { throw PerplTradeError.notSignedIn }
        guard forwardingEnabled else { throw PerplTradeError.forwardingDisabled }
        if let problem = frames.lazy.compactMap(PerplOrders.problem).first { throw PerplTradeError.invalidOrder(problem) }
    }

    /// The ack to report for a frame whose send threw: unknown if it went out (Perpl may have it), rejected if not.
    private static func unanswered(_ error: Error, fallback: String, requestId: Int?) -> PerplOrderAck {
        let unknown = (error as? PerplTradeError)?.outcomeUnknown ?? true
        return PerplOrderAck(code: -1, error: (error as? LocalizedError)?.errorDescription ?? fallback, outcomeUnknown: unknown, requestId: requestId)
    }

    /// Reserves the next request id. Only for a request whose first frame must carry its own id (a bracket's entry,
    /// which its triggers link to with `tr`). Call it in the same synchronous run as that frame's write — no `await` in
    /// between: a frame written meanwhile takes a higher id, and the reserved one is then refused, never written.
    public func reserveRequestId() -> Int { lastForwardedRq += 1; return lastForwardedRq }

    /// Raises the id counter to at least `floor`: the highest id this device ever wrote for the account (persisted), so
    /// a new socket never re-issues an id the last one wrote but Perpl hasn't forwarded yet (`lfr` lags admission).
    public func seedRequestIds(atLeast floor: Int) { lastForwardedRq = max(lastForwardedRq, floor) }

    // MARK: Outcomes

    /// Perpl's outcome for `rq` on THIS socket (a drained passkey socket still answers, GL-1). Returns when decided
    /// (never on a provisional failure); at the deadline returns `outcome(final: continuityHeld(since: sent.writtenAt))`,
    /// else `.unconfirmed(.timedOut)`; when the socket closes, `.unconfirmed(.connectionLost)`. Counted in
    /// `hasRequestsInFlight` while it waits. Never throws, never resends.
    public func awaitOutcome(rq: Int, sent: PerplSentRequest, deadline: PerplOutcomeDeadline) async -> PerplOrderOutcome {
        if let decided = ledger.outcome(rq: rq, sent: sent, final: false) {
            census.outcomesDecidedByStream += 1
            return decided
        }
        guard signedIn else { return .unconfirmed(.connectionLost) }
        if deadline.hasPassed(head: heartbeat.head, now: Date()) { return finalOutcome(rq: rq, sent: sent) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(rq: rq, sent: sent, deadline: deadline, continuation: continuation)
            let wait = max(0, deadline.wallClock.timeIntervalSinceNow)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.expireWaiter(id)
            }
        }
    }

    /// Several at once under one wall-clock cap.
    public func awaitOutcomes(_ requests: [Int: PerplSentRequest], cap: TimeInterval) async -> [Int: PerplOrderOutcome] {
        let deadline = PerplOutcomeDeadline(ackHead: nil, ttlBlocks: nil, ackAt: Date(), cap: cap)
        var out: [Int: PerplOrderOutcome] = [:]
        for (rq, sent) in requests.sorted(by: { $0.key < $1.key }) {
            out[rq] = await awaitOutcome(rq: rq, sent: sent, deadline: deadline)
        }
        return out
    }

    public func outcome(rq: Int, sent: PerplSentRequest, final: Bool) -> PerplOrderOutcome? {
        ledger.outcome(rq: rq, sent: sent, final: final)
    }

    public func provisionalFailure(rq: Int, accountId: Int) -> PerplOrderReason? {
        ledger.provisionalFailure(rq: rq, accountId: accountId)
    }

    /// Signed in without a break, and no heartbeat gap, since `date` (Perpl's "no reconnections" condition).
    public func continuityHeld(since date: Date) -> Bool {
        guard signedIn, let signedInAt, signedInAt <= date else { return false }
        return (heartbeat.lastGapAt ?? .distantPast) < date
    }

    public func sentRequest(rq: Int) -> PerplSentRequest? { sentRequests[rq] }

    /// The live request an order on the list belongs to.
    public func requestId(for key: PerplOpenOrder.Key) -> Int? {
        guard let accountId else { return nil }
        return ledger.requestId(for: key, accountId: accountId)
    }

    /// The status (and reason) `key` left the live list with on this socket: 5 cancelled (a cancel request's own
    /// removal reads 5/28), 4/9/10 fired or filled, 6 expired, 7 failed.
    public func lastTerminalStatus(of key: PerplOpenOrder.Key) -> (status: Int, reason: Int)? { lastTerminal[key] }

    /// The status (and reason) the order with Perpl's smart contract order id `contractOrderId` on `marketId` left this
    /// socket's live list with, when it carried that id (`scid`), and when: how an on-chain resting order ended, as the
    /// stream saw it. The Exchange reuses ids, so the caller weighs `at` (a later order may hold the id now).
    public func lastTerminalStatus(marketId: Int, contractOrderId: Int) -> (status: Int, reason: Int, at: Date)? {
        lastTerminalByScid[PerplOpenOrder.Key(marketId: marketId, oid: contractOrderId)]
    }

    // MARK: Margin and close evidence

    /// The collateral (6-decimal units) a position gained in an mt:27 that carried `rq`, an IncreasePositionCollateral
    /// request this socket wrote: Perpl's own word that the margin went in. Nil when none was seen.
    public func collateralAdded(rq: Int) -> BigUInt? { collateralGrowth[rq] }

    /// An mt:27 for position `pid` without a margin request's id raised its collateral by exactly `amountCNS` with its
    /// size unchanged, after `since`: the margin went in, reported without its request id (the caller makes sure no other
    /// margin request and no order of its own is in flight on that market).
    public func collateralGrowthWithoutRequest(pid: Int, amountCNS: BigUInt, since: Date) -> Bool {
        growthWithoutRequest.contains { $0.pid == pid && $0.delta == amountCNS && $0.sizeUnchanged && $0.at >= since }
    }

    /// What Perpl did with the IncreasePositionCollateral request `rq` this socket wrote, as far as its reports say:
    /// added (its own success, or the position's collateral grown under it), refused (a final failure; `final`: the
    /// evidence wait ended with the socket signed in throughout), or nil while undecided (`PerplOrderLedger.collateralOutcome`).
    public func collateralOutcome(rq: Int, final: Bool) -> PerplCollateralOutcome? {
        guard let sent = sentRequests[rq], sent.kind == .collateral else { return nil }
        return ledger.collateralOutcome(rq: rq, sent: sent, final: final, grown: collateralAdded(rq: rq))
    }

    /// An mt:27 reported a position closed (`st 2`) carrying `rq` in that report itself — never inferred from a
    /// position's earlier request id.
    public func positionClosed(byRequest rq: Int) -> Bool { closedByRequest.contains(rq) }

    /// An mt:27 named request `rq` (by its own `rq`, or by its order's market and id): a hint that it moved the position.
    public func sawPositionChange(rq: Int) -> Bool {
        guard let sent = sentRequests[rq] else { return false }
        return ledger.sawPositionChange(rq: rq, accountId: sent.accountId)
    }

    /// What became of `key`, whose cancel THIS socket wrote as `cancelRq`, as this socket's live list shows it now; nil
    /// while that can't be said yet (still listed and not refused, or gone with no report of how). Nil too when this
    /// socket didn't write that cancel for that order, or isn't signed in with its orders snapshot: a list emptied by a
    /// closed socket, or another socket's list, proves nothing about this cancel.
    public func cancelResult(of key: PerplOpenOrder.Key, cancelRq: Int) -> PerplCancelResult? {
        guard signedIn, hasOrdersSnapshot, let written = cancelsWritten[cancelRq], written.key == key else { return nil }
        let own = sentRequests[cancelRq].flatMap { ledger.outcome(rq: cancelRq, sent: $0, final: false) }
        if ordersByKey[key] != nil {
            // Still listed: only the cancel's own refusal (final at once) decides it.
            if case .failed(let reason)? = own { return .refused(reason.message) }
            return nil
        }
        if let terminal = lastTerminal[key] { return .left(withStatus: terminal.status) }
        switch own {
        case .cancelled(_)?: return .cancelled
        case .failed(_)?: return .alreadyGone
        default: break
        }
        // Gone with no report of how: it wasn't on the list when the cancel went out (already gone), or the list was
        // replaced since (a later snapshot without it) after it was listed at the write.
        switch written.listed {
        case false?: return .alreadyGone
        case true?: return .cancelled
        case nil: return nil
        }
    }

    /// The census counted on this socket since the last call, handed over and reset.
    public func drainCensus() -> PerplStreamCensus {
        defer { census = PerplStreamCensus() }
        return census
    }

    private func finalOutcome(rq: Int, sent: PerplSentRequest) -> PerplOrderOutcome {
        census.outcomesTimedOut += 1
        return ledger.outcome(rq: rq, sent: sent, final: continuityHeld(since: sent.writtenAt)) ?? .unconfirmed(.timedOut)
    }

    /// Removed from the map before it resumes: exactly once.
    private func expireWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: finalOutcome(rq: waiter.rq, sent: waiter.sent))
    }

    private func resolveWaiters(_ changed: Set<Int>) {
        guard !waiters.isEmpty, !changed.isEmpty else { return }
        for (id, waiter) in waiters where changed.contains(waiter.rq) {
            guard let outcome = ledger.outcome(rq: waiter.rq, sent: waiter.sent, final: false) else { continue }
            waiters[id] = nil
            census.outcomesDecidedByStream += 1
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func checkBlockDeadlines() {
        guard !waiters.isEmpty else { return }
        let now = Date()
        for (id, waiter) in waiters where waiter.deadline.hasPassed(head: heartbeat.head, now: now) { expireWaiter(id) }
    }

    /// The socket is gone: every wait ends as "connection lost" (the caller reconciles; nothing is resent).
    private func releaseWaiters() {
        let all = waiters
        waiters.removeAll()
        for (_, waiter) in all { waiter.continuation.resume(returning: .unconfirmed(.connectionLost)) }
    }

    // MARK: WS internals

    private func signIn() throws {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = PerplAuth.base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let canonical = PerplAuth.wsSigninCanonical(chainId: chainId, timestamp: timestamp, nonce: nonce)
        let signature = try PerplAuth.sign(Data(canonical.utf8), secret: key.secret)
        send(["mt": 29, "chain_id": chainId, "api_key": key.token, "timestamp": timestamp, "nonce": nonce, "signature": signature])
    }

    /// `send`, reporting the request id the frame was written with even when no ack comes back (nil: nothing written).
    private func sendTracked(_ frame: PerplOrderFrame) async -> (rq: Int?, result: Result<PerplOrderAck, Error>) {
        var written: Int?
        do {
            let ack = try await send(frame) { written = $0 }
            return (written, .success(ack))
        } catch {
            return (written, .failure(error))
        }
    }

    /// Writes one frame and waits for its ack. Its request id is assigned here, as it is written, so ids rise strictly in
    /// write order (Perpl refuses an id below the last one it accepted): a reserved id is used only while it is still
    /// above every id written; otherwise nothing is written and the frame is refused (never sent: the caller refunds).
    private func send(_ frame: PerplOrderFrame, written: (Int) -> Void = { _ in }) async throws -> PerplOrderAck {
        // The socket closed between frames: this one never leaves the device (rather than waiting 8 s on a socket that
        // no longer exists and reporting an outcome that isn't in doubt).
        guard signedIn, task != nil || transport != nil else { throw PerplTradeError.notSignedIn }
        let rq: Int
        if let reserved = frame.requestId {
            guard reserved > lastWrittenRq else {
                throw PerplTradeError.unavailable(L10n.string(LocalizedStringResource("Another request went out first, so this one wasn't sent. Nothing was placed. Try again.", bundle: L10n.kit, comment: "An order sheet's error: the app refused to send an order because another Perps request had just gone out with a later request number; nothing left the device.")))
            }
            rq = reserved
        } else {
            lastForwardedRq += 1
            rq = lastForwardedRq
        }
        lastWrittenRq = rq
        lastForwardedRq = max(lastForwardedRq, rq)
        noteWrite(frame, rq: rq)
        written(rq)
        snCounter += 1
        let sn = snCounter
        return try await withCheckedThrowingContinuation { continuation in
            pending[sn] = continuation
            pendingRq[sn] = rq
            send(frame.json(rq: rq, sn: sn))
            Task {
                try? await Task.sleep(for: .seconds(PerplTimeouts.ack))
                if let c = self.pending.removeValue(forKey: sn) {
                    self.pendingRq[sn] = nil
                    c.resume(throwing: PerplTradeError.timeout)
                }
            }
        }
    }

    /// Records what was written under `rq` (what its first event must match, census timing) and reports the id.
    private func noteWrite(_ frame: PerplOrderFrame, rq: Int) {
        let kind: PerplOrderLedger.Kind = frame.type == .cancel ? .cancel
            : frame.type == .increasePositionCollateral ? .collateral
            : (frame.triggerPricePNS != nil ? .trigger : .entry(ioc: frame.ioc, sizeRaw: frame.lotLNS))
        let sent = PerplSentRequest(accountId: frame.accountId, marketId: frame.marketId, wireType: frame.wireType, lotLNS: frame.lotLNS,
                                    kind: kind, writtenAt: Date())
        sentRequests[rq] = sent
        if sentRequests.count > 256, let oldest = sentRequests.keys.min() {
            sentRequests[oldest] = nil
            counted[oldest] = nil
            children[oldest] = nil
            cancelsWritten[oldest] = nil
        }
        ledger.noteSent(sent, rq: rq)
        if let entry = frame.linkedRequestId { children[entry, default: []].append(rq) }
        if frame.type == .cancel, let oid = frame.orderId {
            let target = PerplOpenOrder.Key(marketId: frame.marketId, oid: oid)
            if cancelTargets.count > 128 { cancelTargets.removeAll() }
            cancelTargets[target] = rq
            cancelsWritten[rq] = (target, hasOrdersSnapshot ? ordersByKey[target] != nil : nil)
        }
        census.requestsWritten += 1
        if kind == .collateral { census.marginWritten += 1 }
        onRequestIdIssued?(rq)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            self?.countSilence(rq)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        if let transport { transport(text); return }
        task?.send(.string(text)) { _ in }
    }

    /// Reads frames from `socket` until it fails. The socket is captured (not re-read from `self.task`) so a close
    /// that lands after `disconnect()` swapped the task still reports the right close code, and a stale socket's
    /// failure can never be mistaken for the current one's.
    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message, let data = text.data(using: .utf8) { self.handle(data) }
                    self.receive(on: socket)
                case .failure(let failure):
                    // A deliberate disconnect() already tore down and reported; ignore the cancelled socket's echo.
                    guard socket === self.task else { return }
                    self.socketFailed(Self.closeInfo(socket, fallback: failure))
                }
            }
        }
    }

    /// The socket ended on its own (`close`, from the server's close frame or the transport): everything waiting on it
    /// fails as "outcome unknown", every outcome wait ends as "connection lost", and the owner hears of it (`onDisconnect`).
    private func socketFailed(_ close: PerplClose) {
        lastClose = close
        task = nil
        signedIn = false
        self.error = close.message
        let closed = PerplTradeError.closed(close.message)
        failConnect(closed)
        for (_, c) in pending { c.resume(throwing: closed) }
        pending.removeAll()
        pendingRq.removeAll()
        releaseWaiters()
        keepAlive?.cancel()
        onDisconnect?()
    }

    /// The server's close code + reason when it sent a close frame; otherwise a code-0 close carrying the transport's
    /// own description (a dropped network, a TLS failure, the app being suspended).
    private static func closeInfo(_ socket: URLSessionWebSocketTask, fallback: Error) -> PerplClose {
        let code = socket.closeCode
        guard code != .invalid else { return PerplClose(code: 0, reason: fallback.localizedDescription) }
        let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return PerplClose(code: code.rawValue, reason: reason)
    }

    /// Internal (not private) so tests can replay recorded frames.
    func handle(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let mt = obj["mt"] as? Int else { return }
        let now = Date()
        switch mt {
        case 19: // WalletSnapshot — the accounts array is under `as` (Perpl `Wallet.as: Account[]`); the previous
                 // `accounts`/`acc` guesses never matched, so account id + forwarding flag never seeded on connect.
            heartbeat.snapshot(sn: Self.intValue(obj["sn"]))
            signedInAt = now
            signedIn = true
            applyAccounts(obj["as"] as? [[String: Any]] ?? obj["accounts"] as? [[String: Any]] ?? obj["acc"] as? [[String: Any]])
            ledger.setAccount(accountId)
            ledger.prune(now: now)
            resolveConnect()
        case 21: // AccountUpdate — fw / lfr / balance change. Only the seeded account's: another account of the wallet
                 // must never overwrite its id, its request-id seed or its forwarding flag.
            if let id = Self.intValue(obj["id"]), let current = accountId, id != current {
                census.otherAccountUpdates += 1
                return
            }
            applyAccount(obj)
            onAccountActivity?()
        case 23: // OrdersSnapshot — the full open-order set replaces what we hold
            let raws = (obj["d"] as? [[String: Any]]) ?? []
            var changed: Set<Int> = []
            for raw in raws {
                guard let event = PerplOrderEvent(json: raw, snapshot: true) else { continue }
                changed.formUnion(ledger.apply(event, at: now).changed)
            }
            ordersByKey.removeAll()
            for raw in raws { applyOrder(raw, announce: false) }
            hasOrdersSnapshot = true
            publishOrders()
            ledger.prune(now: now)
            resolveWaiters(changed)
            snapshotsMaybeComplete()
        case 24: // OrdersUpdate — upsert live orders, drop removed / terminal ones
            let raws = (obj["d"] as? [[String: Any]]) ?? []
            let events = raws.compactMap { PerplOrderEvent(json: $0, snapshot: false) }
            var changed: Set<Int> = []
            var targets: [(key: PerplOpenOrder.Key, status: Int)] = []
            for event in events {
                let applied = ledger.apply(event, at: now)
                changed.formUnion(applied.changed)
                if let target = applied.cancelTarget { targets.append(target) }
            }
            for raw in raws { applyOrder(raw, announce: true) }
            // A cancel request's own report that it went through removes its target, as cancelled — never as fired.
            // Its refusal (st 7) or a live status never touches the target.
            for target in targets where [4, 5, 10].contains(target.status) && ordersByKey[target.key] != nil {
                let scid = ordersByKey[target.key]?.contractOrderId
                ordersByKey[target.key] = nil
                noteTerminal(target.key, status: 5, reason: 28, scid: scid)
                if cancelTargets.removeValue(forKey: target.key) != nil { census.cancelRemovedOnlyByOwnEvent += 1 }
            }
            publishOrders()
            resolveWaiters(changed)
            countOrderEvents(events, changed: changed)
            #if DEBUG
            Self.debugLog(mt: mt, raws)
            #endif
            if !events.isEmpty { onOrderEvents?(events) }
            if events.contains(where: { $0.accountId == nil || $0.accountId == accountId }) { onAccountActivity?() }
        case 25: // FillsUpdate — joined to their orders by (account, market, order id)
            let raws = (obj["d"] as? [[String: Any]]) ?? []
            let fills = raws.compactMap(PerplFillEvent.init(json:))
            var changed: Set<Int> = []
            for fill in fills { changed.formUnion(ledger.apply(fill, at: now)) }
            resolveWaiters(changed)
            #if DEBUG
            Self.debugLog(mt: mt, raws)
            #endif
            if !fills.isEmpty { onFills?(fills) }
            if fills.contains(where: { $0.accountId == nil || $0.accountId == accountId }) { onAccountActivity?() }
        case 26: // PositionsSnapshot — the full open-position set
            let raws = (obj["d"] as? [[String: Any]]) ?? []
            positionsByPid.removeAll()
            for raw in raws { _ = applyPosition(raw) }
            for event in raws.compactMap(PerplPositionEvent.init(json:)) { _ = ledger.apply(event, at: now) }
            hasPositionsSnapshot = true
            publishPositions()
            ledger.prune(now: now)
            snapshotsMaybeComplete()
        case 27: // PositionsUpdate — upsert open positions, drop ended ones, and report each ending once
            let raws = (obj["d"] as? [[String: Any]]) ?? []
            // Read against each position's collateral before `applyPosition` replaces it.
            notePositionEvidence(raws, at: now)
            let ended = raws.compactMap(applyPosition)
            publishPositions()
            let events = raws.compactMap(PerplPositionEvent.init(json:))
            var changed: Set<Int> = []
            for event in events { changed.formUnion(ledger.apply(event, at: now)) }
            resolveWaiters(changed)
            for position in ended where endedPositions.insert(position.pid).inserted { onPositionEnded?(position) }
            #if DEBUG
            Self.debugLog(mt: mt, raws)
            #endif
            if !events.isEmpty { onPositionEvents?(events) }
            if events.contains(where: { $0.accountId == nil || $0.accountId == accountId }) { onAccountActivity?() }
        case 100: // Heartbeat — head block and sequence (log-only: a gap marks the stream suspect, never reconnects)
            let beat = heartbeat.beat(sn: Self.intValue(obj["sn"]), head: Self.intValue(obj["h"]), at: now)
            countBeat(beat)
            if streamSuspect != heartbeat.suspect { streamSuspect = heartbeat.suspect }
            checkBlockDeadlines()
            if beat != .inOrder { onHeartbeat?(beat) }
        case 3: // command status ack
            if let cid = obj["cid"] as? Int, let continuation = pending.removeValue(forKey: cid) {
                let status = obj["status"] as? [String: Any]
                continuation.resume(returning: PerplOrderAck(code: status?["code"] as? Int ?? -1, error: status?["error"] as? String,
                                                             requestId: pendingRq.removeValue(forKey: cid), head: heartbeat.head, receivedAt: now))
            }
        default: break
        }
    }

    /// Both snapshots of this socket are in: the lists are whole again (once per socket).
    private func snapshotsMaybeComplete() {
        guard hasOrdersSnapshot, hasPositionsSnapshot, !snapshotsReported else { return }
        snapshotsReported = true
        heartbeat.snapshotsArrived()
        if streamSuspect != heartbeat.suspect { streamSuspect = heartbeat.suspect }
        onSnapshotsComplete?()
    }

    private func applyAccounts(_ accounts: [[String: Any]]?) {
        guard let first = accounts?.first else { return }
        applyAccount(first)
    }

    private func applyAccount(_ account: [String: Any]) {
        // `id` is the AccountID (`in` is the InstanceID — never use it as the account id).
        if let id = (account["id"] as? Int) ?? (account["id"] as? NSNumber)?.intValue { accountId = id }
        if let lfr = (account["lfr"] as? Int) ?? (account["lfr"] as? NSNumber)?.intValue { lastForwardedRq = max(lastForwardedRq, lfr) }
        if let fw = Self.boolValue(account["fw"]) { forwardingEnabled = fw }
        // Balances are decimal strings (`Amount`); anything but a whole number reads as unknown.
        if account.keys.contains("b") { balanceCNS = Self.wholeAmount(account["b"]) }
        if account.keys.contains("lb") { lockedBalanceCNS = Self.wholeAmount(account["lb"]) }
        onAccountUpdate?()
    }

    private static func wholeAmount(_ value: Any?) -> BigUInt? {
        guard let text = PerplJSON.amount(value) else { return nil }
        return BigUInt(text, radix: 10)
    }

    private func noteTerminal(_ key: PerplOpenOrder.Key, status: Int, reason: Int, scid: Int? = nil) {
        if lastTerminal[key] == nil { lastTerminalOrder.append(key) }
        lastTerminal[key] = (status, reason)
        if lastTerminalOrder.count > 128 { lastTerminal[lastTerminalOrder.removeFirst()] = nil }
        guard let scid else { return }
        let byScid = PerplOpenOrder.Key(marketId: key.marketId, oid: scid)
        if lastTerminalByScid[byScid] == nil { lastTerminalScidOrder.append(byScid) }
        lastTerminalByScid[byScid] = (status, reason, Date())
        if lastTerminalScidOrder.count > 128 { lastTerminalByScid[lastTerminalScidOrder.removeFirst()] = nil }
    }

    /// What an mt:27 says before `applyPosition` replaces each position (this account's only): the collateral a position
    /// gained under an IncreasePositionCollateral request this socket wrote, named by the position's own `rq` (never an
    /// earlier one it kept); the collateral one gained under no such request, and whether its size stayed the same; and
    /// the requests named by a report of a position closed (`st 2`).
    private func notePositionEvidence(_ raws: [[String: Any]], at now: Date) {
        growthWithoutRequest.removeAll { now.timeIntervalSince($0.at) > 60 }
        for raw in raws {
            if let acc = Self.intValue(raw["acc"]), let accountId, acc != accountId { continue }
            let rq = PerplJSON.id(raw["rq"])
            let marginRq = rq.flatMap { sentRequests[$0]?.kind == .collateral ? $0 : nil }
            if let marginRq, mark(marginRq, .marginPosition) { census.marginPositionWithRq += 1 }
            if let rq, Self.intValue(raw["st"]) == 2, closedByRequest.insert(rq).inserted {
                closedByRequestOrder.append(rq)
                if closedByRequestOrder.count > 64 { closedByRequest.remove(closedByRequestOrder.removeFirst()) }
            }
            // The collateral it had and has now, both whole numbers of 6-decimal units.
            guard let pid = Self.intValue(raw["pid"]), let previous = positionsByPid[pid],
                  let before = previous.collateralCNS.flatMap({ BigUInt($0, radix: 10) }),
                  let after = PerplJSON.amount(raw["c"]).flatMap({ BigUInt($0, radix: 10) }), after > before else { continue }
            let delta = after - before
            if let marginRq {
                collateralGrowth[marginRq] = delta
                if collateralGrowth.count > 64, let oldest = collateralGrowth.keys.min() { collateralGrowth[oldest] = nil }
                continue
            }
            // An update that leaves out its size kept it.
            let unchanged = Self.intValue(raw["s"]).map { $0 == previous.sizeRaw } ?? true
            growthWithoutRequest.append((pid, delta, unchanged, now))
            if growthWithoutRequest.count > 16 { growthWithoutRequest.removeFirst(growthWithoutRequest.count - 16) }
            // Census: a margin request this socket wrote in the last minute whose growth came without its request id.
            let waiting = sentRequests.contains { $0.value.kind == .collateral && now.timeIntervalSince($0.value.writtenAt) <= 60 && collateralGrowth[$0.key] == nil }
            if unchanged, waiting { census.marginGrowthWithoutRq += 1 }
        }
    }

    // MARK: Census (counts only)

    private func countBeat(_ beat: PerplHeartbeat.Beat) {
        switch beat {
        case .inOrder:
            census.heartbeatsInOrder += 1
            if heartbeat.beatsSinceSnapshot == 1 { census.firstBeatContinuedSnapshot += 1 }
        case .gap: census.heartbeatGaps += 1
        case .unseeded: census.heartbeatUnseeded += 1
        case .stale: census.heartbeatStale += 1
        }
    }

    /// One-time counts per request this socket wrote: how its first event joined, oid vs scid, a cancel's own report,
    /// a failure later replaced, a foreign report; and the shape of every update (`r` without `st`).
    private func countOrderEvents(_ events: [PerplOrderEvent], changed: Set<Int>) {
        for event in events {
            if event.removed, event.status == nil { census.removedWithoutStatus += 1 }
            guard let rq = event.requestId, let sent = sentRequests[rq], event.accountId == nil || event.accountId == sent.accountId else { continue }
            if event.status == 7, event.logIndex != nil { census.failuresCarryingLog += 1 }
            // A margin request's reports answer the margin questions only (never an order's: it may name an order id).
            if sent.kind == .collateral || event.typeRaw == 6 {
                if mark(rq, .margin) {
                    switch event.status {
                    case 4?, 10?: census.marginSt4or10 += 1
                    case 5?, 6?: census.marginSt5or6 += 1
                    case 7?: census.marginSt7 += 1
                    default: break
                    }
                }
                continue
            }
            if event.orderId != nil, mark(rq, .scid) {
                if event.contractOrderId == nil { census.scidMissing += 1 }
                else if event.contractOrderId == event.orderId { census.oidEqualsScid += 1 }
                else { census.oidDiffersFromScid += 1 }
            }
            if sent.kind == .cancel || event.isCancelRequest, mark(rq, .cancelOwn) { census.cancelOwnEvents += 1 }
        }
        for rq in changed {
            guard let sent = sentRequests[rq], sent.kind != .collateral, let entry = ledger.entry(rq: rq, accountId: sent.accountId) else { continue }
            if let carried = entry.firstCarriedRq, mark(rq, .firstEvent) {
                if carried { census.firstEventCarriedRq += 1 } else { census.firstEventLackedRq += 1 }
            }
            if entry.failureThenNonFailure, mark(rq, .failThenOk) { census.failureThenNonFailure += 1 }
            if PerplOrderLedger.isForeign(entry, sent: sent), mark(rq, .foreign) { census.foreignReports += 1 }
            // A market entry that filled nothing: are its `tr`-linked TP/SL cancelled with it, or left armed?
            if case .entry(ioc: true, _) = sent.kind, case .notFilled? = ledger.outcome(rq: rq, sent: sent, final: false),
               let linked = children[rq], !linked.isEmpty, mark(rq, .zeroFillChecked) {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.countLeftTriggers(linked)
                }
            }
        }
        for event in events where !event.isCancelRequest && event.typeRaw != 6 && event.requestId.flatMap({ sentRequests[$0]?.kind }) != .collateral {
            // The target of one of this socket's cancels left on its own report.
            guard let market = event.marketId, let oid = event.orderId, event.removed || [4, 5, 6, 7, 10].contains(event.status ?? 0) else { continue }
            if cancelTargets.removeValue(forKey: PerplOpenOrder.Key(marketId: market, oid: oid)) != nil { census.cancelTargetOwnRemovals += 1 }
        }
    }

    private func countLeftTriggers(_ linked: [Int]) {
        let stillListed = linked.contains { rq in
            guard let sent = sentRequests[rq], let key = ledger.orderKey(rq: rq, accountId: sent.accountId) else { return false }
            return ordersByKey[key] != nil
        }
        if stillListed { census.zeroFillIocTriggersStillListed += 1 } else { census.zeroFillIocTriggersCancelled += 1 }
    }

    /// Nothing at all came back for `rq` within 12 s of its write.
    private func countSilence(_ rq: Int) {
        guard let sent = sentRequests[rq] else { return }
        if (ledger.entry(rq: rq, accountId: sent.accountId)?.events ?? 0) == 0 { census.noEventWithin12s += 1 }
    }

    /// True the first time `rq` gets `marks`.
    private func mark(_ rq: Int, _ marks: CensusMarks) -> Bool {
        var current = counted[rq] ?? []
        guard !current.contains(marks) else { return false }
        current.insert(marks)
        counted[rq] = current
        return true
    }

    #if DEBUG
    /// DEBUG builds only: which fields each inbound order / fill / position update carried, and its status codes. Ids are
    /// private; nothing outbound (the sign-in frame carries a signature) is ever logged.
    private static func debugLog(mt: Int, _ items: [[String: Any]]) {
        let logger = Logger(subsystem: "fun.dyorhq.app", category: "perpl") // not localized: a log category
        for item in items {
            let fields = item.keys.sorted().joined(separator: ",")
            let st = intValue(item["st"]).map(String.init) ?? "-", sr = intValue(item["sr"]).map(String.init) ?? "-"
            let fr = intValue(item["fr"]).map(String.init) ?? "-", t = intValue(item["t"]).map(String.init) ?? "-"
            let rq = intValue(item["rq"]).map(String.init) ?? "-", oid = intValue(item["oid"]).map(String.init) ?? "-"
            logger.debug("mt\(mt, privacy: .public) fields=\(fields, privacy: .public) st=\(st, privacy: .public) sr=\(sr, privacy: .public) fr=\(fr, privacy: .public) t=\(t, privacy: .public) rq=\(rq, privacy: .private) oid=\(oid, privacy: .private)") // not localized: a log line
        }
    }
    #endif

    /// Reads a JSON bool that may arrive as a real boolean or as 0/1.
    private static func boolValue(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// Upserts one `Order` from mt:23/24, or drops it when Perpl flags it removed (`r`) or it reaches a terminal
    /// status. Live statuses kept: Pending(1), Open(2), PartiallyFilled(3), Untriggered(8), Triggered(9).
    /// `announce` (updates only): report a trigger that fired, failed or expired (`onTriggerEvent`).
    ///
    /// A cancel request's own report (`t` 5, or a request this socket wrote as a cancel — a partial update may omit `t`)
    /// carries its TARGET's id: merged here it would rewrite the target's type to Cancel, so the trigger would silently
    /// drop out of the TP/SL rows and the orphan checks. It never touches the list here; `handle` applies its one rule.
    ///
    /// An IncreasePositionCollateral request's report (`t` 6, or a request this socket wrote as one) is never an order on
    /// the list either, for the same reason: it may name an order id it doesn't own.
    private func applyOrder(_ raw: [String: Any], announce: Bool) {
        if Self.intValue(raw["t"]) == 5 || Self.intValue(raw["t"]) == 6 { return }
        if let rq = PerplJSON.id(raw["rq"]), sentRequests[rq]?.kind == .cancel || sentRequests[rq]?.kind == .collateral { return }
        guard let oid = Self.intValue(raw["oid"]) else { return }
        // Order ids are per market: an update is merged into the order with its market AND id. One that leaves out
        // its market belongs to the only order with that id, if there is exactly one; otherwise it can't be placed.
        let marketId: Int
        if let mkt = Self.intValue(raw["mkt"]) {
            marketId = mkt
        } else {
            let known = ordersByKey.keys.filter { $0.oid == oid }
            guard known.count <= 1 else { return }
            marketId = known.first?.marketId ?? 0
        }
        let key = PerplOpenOrder.Key(marketId: marketId, oid: oid)
        let previous = ordersByKey[key]
        // An update without a status keeps the one it had, rather than reading as terminal and dropping a live order.
        let status = Self.intValue(raw["st"]) ?? previous?.statusRaw ?? 0
        let reason = Self.intValue(raw["sr"]) ?? 0
        let removed = Self.boolValue(raw["r"]) ?? false
        // A failure only a resent request can get, for an order already admitted: the late echo of a duplicate. The
        // order stays as it is (dropping it would hide a live stop-loss the app could then no longer cancel).
        if status == 7, admitted.contains(key), Self.duplicateRequestFailures.contains(reason) { return }
        if Self.admittedStatuses.contains(status) { admitted.insert(key) }
        // An update may carry only what changed; the order's own terms (type, size, trigger) never do.
        let order = PerplOpenOrder(
            oid: oid,
            marketId: marketId,
            typeRaw: Self.intValue(raw["t"]) ?? previous?.typeRaw ?? 0,
            statusRaw: status,
            priceRaw: Self.intValue(raw["p"]) ?? previous?.priceRaw ?? 0,
            sizeRaw: Self.intValue(raw["os"]) ?? previous?.sizeRaw ?? 0,
            filledRaw: Self.intValue(raw["fs"]) ?? previous?.filledRaw ?? 0,
            triggerPriceRaw: Self.intValue(raw["tp"]) ?? previous?.triggerPriceRaw,
            triggerConditionRaw: Self.intValue(raw["tpc"]) ?? previous?.triggerConditionRaw,
            linkedPositionId: Self.intValue(raw["lp"]) ?? previous?.linkedPositionId,
            leverageHundredths: Self.intValue(raw["lv"]) ?? previous?.leverageHundredths ?? 0,
            contractOrderId: PerplJSON.id(raw["scid"]) ?? previous?.contractOrderId
        )
        if announce, order.isTrigger, let outcome = Self.triggerOutcome(status: status, reason: reason),
           announcedTriggers.insert("\(marketId)-\(oid)-\(Self.eventName(outcome))").inserted {
            onTriggerEvent?(PerplTriggerEvent(order: order, outcome: outcome))
        }
        guard !removed, [1, 2, 3, 8, 9].contains(status) else {
            // How it left (an `r: true` without `st` keeps the status it had), for a cancel's confirmation.
            noteTerminal(key, status: status, reason: reason, scid: order.contractOrderId)
            ordersByKey[key] = nil
            return
        }
        ordersByKey[key] = order
    }

    /// The statuses that admit an order (api-docs websocket.md, "Client-side deduplication"): Open, PartiallyFilled,
    /// Filled, Canceled, Untriggered, Triggered, Executed.
    static let admittedStatuses: Set<Int> = [2, 3, 4, 5, 8, 9, 10]
    /// Failures that answer a request, never an order already on Perpl: its request id was already used
    /// (OrderDescIdTooLow 32, TriggerDescIdTooLow 59), or forwarding was off when it was sent
    /// (OrderForwardingNotAllowed 34 — revoking forwarding leaves admitted orders alone).
    static let duplicateRequestFailures: Set<Int> = [32, 34, 59]

    /// What a trigger's status says happened to it, if anything worth reporting. The reason is read first: a trigger
    /// that fired and then couldn't be carried out — attempts exhausted (64) or the triggered order expired (67) — has
    /// failed whatever status comes with it (an expiry arrives as Expired, 6). Then Failed (7): refused, or could not
    /// execute. Expired (6) after firing is a failure too; before firing, the trigger simply expired. Triggered (9) /
    /// Executed (10) / Filled (4) or a firing reason (54, 65, 66) means it fired — including a recoverable failure (68)
    /// the keeper is still retrying under Triggered. Untriggered, open and cancelled triggers report nothing.
    static func triggerOutcome(status: Int, reason: Int) -> PerplTriggerEvent.Outcome? {
        if [64, 67].contains(reason) { return .failed(reason: reason) }
        if status == 7 { return .failed(reason: reason) }
        if status == 6 { return [54, 65, 66, 68].contains(reason) ? .failed(reason: 67) : .expired }
        if [4, 9, 10].contains(status) || [54, 65, 66].contains(reason) { return .triggered }
        return nil
    }

    // not localized: an identifier, the key that keeps an event from being announced twice
    private static func eventName(_ outcome: PerplTriggerEvent.Outcome) -> String {
        switch outcome {
        case .triggered: return "fired"
        case .failed: return "failed"
        case .expired: return "expired"
        }
    }

    private func publishOrders() {
        // A stable order, so rows don't reshuffle between updates.
        openOrders = ordersByKey.values.sorted { ($0.oid, $0.marketId) < ($1.oid, $1.marketId) }
        onOrdersUpdate?()
    }

    /// Upserts one `Position` from mt:26/27, dropping it once it is no longer open. Returns the position when this
    /// frame ended it (closed, liquidated, deleveraged, unwound), for `onPositionEnded`.
    private func applyPosition(_ raw: [String: Any]) -> PerplLivePosition? {
        guard let pid = Self.intValue(raw["pid"]) else { return nil }
        let previous = positionsByPid[pid]
        // The side is never guessed: a position whose side isn't known can't be matched to the triggers that close it.
        guard let isLong = Self.intValue(raw["sd"]).map({ $0 == 1 }) ?? previous?.isLong else { return nil }
        let position = PerplLivePosition(
            pid: pid,
            marketId: Self.intValue(raw["mkt"]) ?? previous?.marketId ?? 0,
            isLong: isLong,
            sizeRaw: Self.intValue(raw["s"]) ?? previous?.sizeRaw ?? 0,
            statusRaw: Self.intValue(raw["st"]) ?? previous?.statusRaw ?? 0,
            entryPriceRaw: Self.intValue(raw["ep"]) ?? previous?.entryPriceRaw,
            collateralCNS: PerplJSON.amount(raw["c"]) ?? previous?.collateralCNS,
            leverageHundredths: Self.intValue(raw["lv"]) ?? previous?.leverageHundredths,
            requestId: PerplJSON.id(raw["rq"]) ?? previous?.requestId,
            orderId: PerplJSON.id(raw["oid"]) ?? previous?.orderId,
            statusReason: Self.intValue(raw["sr"]) ?? previous?.statusReason
        )
        if position.isOpen {
            positionsByPid[pid] = position
            return nil
        }
        positionsByPid[pid] = nil
        // Closed (2) or ended by the protocol (3–5): an ending worth reporting. Failed (6) never opened.
        return (2...5).contains(position.statusRaw) ? position : nil
    }

    private func publishPositions() {
        positions = positionsByPid.values.sorted { $0.pid < $1.pid }
    }

    private func resolveConnect() {
        connectContinuation?.resume()
        connectContinuation = nil
    }

    private func failConnect(_ error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }
}

#if DEBUG
/// DEBUG builds only (the app's scripted Perps demo and its tests; never in a Release binary).
extension PerplTradeClient {
    /// A client that is never connected — no socket, no sign-in — whose URL can't route (`wss://perps-demo.invalid`) and
    /// whose key is an all-zero placeholder nothing reads; `connect()` refuses to run on it (precondition). Frames go to
    /// `debugAttach`'s `write`; `debugReceive` hands it a frame as if Perpl had sent it; `debugDrop` ends it as a dropped
    /// socket would (`socketFailed`).
    public static func debugScripted() -> PerplTradeClient {
        // not localized: a placeholder key nothing signs with, and a host that can't resolve
        let placeholder = PerplApiKey(token: "", secret: Data(repeating: 0, count: 32), address: "0x0000000000000000000000000000000000000000", scopeMask: 0)
        let client = PerplTradeClient(key: placeholder, wsURL: URL(string: "wss://perps-demo.invalid")!, session: .shared)
        client.isDebugScripted = true
        return client
    }

    /// Every frame this client writes goes to `write` (as the socket would carry it), never to a network.
    public func debugAttach(write: @escaping (String) -> Void) {
        precondition(isDebugScripted && task == nil, "only a scripted demo client, which never has a socket")
        transport = write
    }

    /// A frame as if Perpl had sent it on the socket.
    public func debugReceive(_ text: String) {
        precondition(isDebugScripted, "only a scripted demo client")
        handle(Data(text.utf8))
    }

    /// Ends the scripted connection as a dropped socket would: Perpl's "server restarting" close (1001).
    public func debugDrop() {
        precondition(isDebugScripted, "only a scripted demo client")
        socketFailed(PerplClose(code: 1001, reason: ""))
    }
}
#endif
