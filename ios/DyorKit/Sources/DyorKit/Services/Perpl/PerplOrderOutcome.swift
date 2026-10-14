import BigInt
import Foundation

/* What Perpl actually did with an order the app sent: the authenticated stream's order, fill and position events
   (mt:23/24/25/26/27) parsed in full, and a pure per-request reducer that applies Perpl's own client-side deduplication
   (api-docs websocket.md, "Delivery Semantics & Idempotency"). A gateway ack (mt:3 code 0) only admits an order for
   forwarding; the outcome is the order's status on the stream. Nothing here does I/O: the trading client feeds it and
   waits on it (`PerplTradeClient.awaitOutcome`). */

// MARK: Parsing

/// Perpl's JSON values as the stream sends them: integers as numbers, amounts as decimal strings (or numbers).
enum PerplJSON {
    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// An id where 0 means "none" (`oid`, `scid`, `rq`).
    static func id(_ value: Any?) -> Int? {
        guard let i = int(value), i > 0 else { return nil }
        return i
    }

    static func bool(_ value: Any?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        return nil
    }

    /// An `Amount`: a decimal string, kept as it is; a number becomes its decimal string.
    static func amount(_ value: Any?) -> String? {
        if let s = value as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        if let n = value as? NSNumber { return NSDecimalNumber(decimal: n.decimalValue).stringValue }
        return nil
    }

    /// A transaction hash as lowercase `0x…`.
    static func hash(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let lower = s.lowercased()
        return lower.hasPrefix("0x") ? lower : "0x" + lower
    }
}

/// One `Order` of mt:23/24 or of the order-history REST page (types.md → Order). Every field is optional: an update may
/// carry only what changed, and a pre-chain failure (sr 14, 34) may carry no `oid`.
public struct PerplOrderEvent: Sendable, Equatable {
    public let requestId: Int?, marketId: Int?, accountId: Int?        // rq, mkt, acc
    public let orderId: Int?, contractOrderId: Int?                    // oid, scid (0 → nil)
    public let status: Int?, reason: Int?, failure: Int?               // st, sr, fr
    public let typeRaw: Int?                                           // t, 1-indexed (5 = Cancel)
    public let removed: Bool                                           // r
    public let priceRaw: Int?, originalSizeRaw: Int?, filledSizeRaw: Int?, fillPriceRaw: Int?   // p, os, fs, fp
    public let feeCNS: String?                                         // f (6-dp units; may be negative: a rebate)
    public let flags: Int?, triggerPriceRaw: Int?, linkedPositionId: Int?
    public let block: Int?, txid: String?, logIndex: Int?              // at.b, at.txid (lowercased 0x…), at.l
    public let isSnapshot: Bool                                        // mt:23
    public var isCancelRequest: Bool { typeRaw == 5 }

    /// Nil only when the order has neither a request id nor an order id: nothing could ever join it.
    public init?(json: [String: Any], snapshot: Bool) {
        requestId = PerplJSON.id(json["rq"])
        orderId = PerplJSON.id(json["oid"])
        guard requestId != nil || orderId != nil else { return nil }
        marketId = PerplJSON.int(json["mkt"])
        accountId = PerplJSON.int(json["acc"])
        contractOrderId = PerplJSON.id(json["scid"])
        status = PerplJSON.int(json["st"])
        reason = PerplJSON.int(json["sr"])
        failure = PerplJSON.int(json["fr"])
        typeRaw = PerplJSON.int(json["t"])
        removed = PerplJSON.bool(json["r"]) ?? false
        priceRaw = PerplJSON.int(json["p"])
        originalSizeRaw = PerplJSON.int(json["os"])
        filledSizeRaw = PerplJSON.int(json["fs"])
        fillPriceRaw = PerplJSON.int(json["fp"])
        feeCNS = PerplJSON.amount(json["f"])
        flags = PerplJSON.int(json["fl"])
        triggerPriceRaw = PerplJSON.int(json["tp"])
        linkedPositionId = PerplJSON.id(json["lp"])
        let at = json["at"] as? [String: Any]
        block = PerplJSON.int(at?["b"])
        txid = PerplJSON.hash(at?["txid"])
        logIndex = PerplJSON.int(at?["l"])
        isSnapshot = snapshot
    }
}

/// One `Fill` of mt:25 (types.md → Fill). It carries no `rq`: it is joined to its order by (acc, mkt, oid).
public struct PerplFillEvent: Sendable, Equatable {
    public let marketId: Int, orderId: Int, accountId: Int?, typeRaw: Int?, isMaker: Bool?
    public let priceRaw: Int?, sizeRaw: Int, feeCNS: String?, block: Int?, txid: String?

    /// Nil without a market, an order id or a size.
    public init?(json: [String: Any]) {
        guard let mkt = PerplJSON.int(json["mkt"]), let oid = PerplJSON.id(json["oid"]), let size = PerplJSON.int(json["s"]) else { return nil }
        marketId = mkt
        orderId = oid
        sizeRaw = size
        accountId = PerplJSON.int(json["acc"])
        typeRaw = PerplJSON.int(json["t"])
        isMaker = PerplJSON.int(json["l"]).map { $0 == 1 }  // 1 maker, 2 taker
        priceRaw = PerplJSON.int(json["p"])
        feeCNS = PerplJSON.amount(json["f"])
        let at = json["at"] as? [String: Any]
        block = PerplJSON.int(at?["b"])
        txid = PerplJSON.hash(at?["txid"])
    }

    public init(marketId: Int, orderId: Int, accountId: Int?, typeRaw: Int? = nil, isMaker: Bool? = nil, priceRaw: Int?, sizeRaw: Int,
                feeCNS: String?, block: Int? = nil, txid: String? = nil) {
        self.marketId = marketId; self.orderId = orderId; self.accountId = accountId; self.typeRaw = typeRaw
        self.isMaker = isMaker; self.priceRaw = priceRaw; self.sizeRaw = sizeRaw; self.feeCNS = feeCNS
        self.block = block; self.txid = txid
    }
}

/// One `Position` of mt:26/27 (types.md → Position): the fields the ledger and the census read. Its `rq`/`oid` (the
/// request that last changed it, inferred) are only a hint that the order moved the position, never a size or a price.
public struct PerplPositionEvent: Sendable, Equatable {
    public let pid: Int, marketId: Int?, accountId: Int?, requestId: Int?, orderId: Int?
    public let status: Int?, reason: Int?, isLong: Bool?, sizeRaw: Int?, entryPriceRaw: Int?
    public let collateralCNS: String?, leverageHundredths: Int?

    /// Nil without a position id.
    public init?(json: [String: Any]) {
        guard let pid = PerplJSON.int(json["pid"]) else { return nil }
        self.pid = pid
        marketId = PerplJSON.int(json["mkt"])
        accountId = PerplJSON.int(json["acc"])
        requestId = PerplJSON.id(json["rq"])
        orderId = PerplJSON.id(json["oid"])
        status = PerplJSON.int(json["st"])
        reason = PerplJSON.int(json["sr"])
        isLong = PerplJSON.int(json["sd"]).map { $0 == 1 }
        sizeRaw = PerplJSON.int(json["s"])
        entryPriceRaw = PerplJSON.int(json["ep"])
        collateralCNS = PerplJSON.amount(json["c"])
        leverageHundredths = PerplJSON.int(json["lv"])
    }
}

// MARK: Requests and reasons

/// What was written for a request id: what its first joined event must match (a report of another order under the
/// same id is never read as this one's), and how to read its statuses.
public struct PerplSentRequest: Sendable, Equatable, Codable {
    public let accountId: Int, marketId: Int, wireType: Int, lotLNS: Int
    public let kind: PerplOrderLedger.Kind
    public let writtenAt: Date

    public init(accountId: Int, marketId: Int, wireType: Int, lotLNS: Int, kind: PerplOrderLedger.Kind, writtenAt: Date) {
        self.accountId = accountId; self.marketId = marketId; self.wireType = wireType; self.lotLNS = lotLNS
        self.kind = kind; self.writtenAt = writtenAt
    }
}

/// Why Perpl refused or ended an order: its status, `OrderStatusReason` (`sr`) and, on a post or settlement failure,
/// `OrderFailureReason` (`fr`).
public struct PerplOrderReason: Sendable, Equatable, Hashable, Codable {
    public let status: Int, reason: Int, failure: Int?

    public init(status: Int, reason: Int, failure: Int? = nil) {
        self.status = status; self.reason = reason; self.failure = failure
    }

    /// Request-level refusals and settlement refusals the Exchange evaluated: no later report can turn them into a
    /// success, so they are final the moment they arrive. Every other failure waits for the deadline (Perpl's rule: the
    /// first failure counts only if all received messages are failures).
    public var isFinalAtOnce: Bool { [14, 32, 34, 59].contains(reason) || failure != nil }

    /// Why, as one or two whole sentences in the app's language. `fr` is read first with sr 23, 36 or 44.
    public var message: String {
        if [23, 36, 44].contains(reason), let failure, let text = Self.text(failure: failure) { return text }
        return Self.text(reason: reason)
    }

    static func text(failure: Int) -> String? {
        switch failure {
        case 1: return L10n.string(LocalizedStringResource("There isn't enough available margin on your Perpl account for this order.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 2: return L10n.string(LocalizedStringResource("There isn't enough available margin to add to this position.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 3: return L10n.string(LocalizedStringResource("There isn't enough available margin to turn this position around.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. To turn a position around: to flip it from long to short, or short to long."))
        case 4: return text(reason: 11)
        case 5: return L10n.string(LocalizedStringResource("Settling at this price would leave the market insolvent, so Perpl refused it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 6: return L10n.string(LocalizedStringResource("Closing at this price would leave the position with a negative value, so Perpl refused it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 7: return L10n.string(LocalizedStringResource("Perpl had no fresh price for this market. Try again in a moment.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 8: return L10n.string(LocalizedStringResource("Filling it would carry more unrealized loss than this order allows.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 9: return text(reason: 23)
        default: return nil
        }
    }

    static func text(reason: Int) -> String {
        switch reason {
        case 34: return L10n.string(LocalizedStringResource("Perpl hasn't registered one-click trading for your account yet. Wait a few seconds and try again.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. One-click trading: Perpl's order forwarding."))
        case 32, 59: return L10n.string(LocalizedStringResource("Perpl didn't take this order because it clashed with another one from your account. Nothing was placed. Try again.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 14: return L10n.string(LocalizedStringResource("Perpl couldn't execute it in time, so nothing was placed.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 13: return L10n.string(LocalizedStringResource("It would have filled at once, so Perpl didn't post it as a post-only order.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. A post-only order only rests on the order book (maker); it never fills at once."))
        case 16: return L10n.string(LocalizedStringResource("There wasn't enough on the order book within the slippage limit.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. Slippage limit: the worst price the order accepts."))
        case 28: return L10n.string(LocalizedStringResource("It was cancelled.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 29: return L10n.string(LocalizedStringResource("Perpl cancelled it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 30: return L10n.string(LocalizedStringResource("It was cancelled by a liquidation.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 24: return L10n.string(LocalizedStringResource("Your account has the most open orders Perpl allows. Cancel some first.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 27: return L10n.string(LocalizedStringResource("This market's order book is full. Try again later.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 2, 7, 19: return L10n.string(LocalizedStringResource("Your Perpl account is frozen, so it can't trade right now. Contact Perpl for help.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 12: return L10n.string(LocalizedStringResource("This market isn't trading right now. Try again later.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 10: return L10n.string(LocalizedStringResource("This close is larger than your open position, so Perpl refused it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. A close: an order that reduces or closes a position."))
        case 11: return L10n.string(LocalizedStringResource("There is no position on that side for this order to close.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. That side: long or short."))
        case 17, 39: return L10n.string(LocalizedStringResource("The order is below Perpl's minimum for this market.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 1, 18, 41: return L10n.string(LocalizedStringResource("There isn't enough available balance on your Perpl account.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 40: return L10n.string(LocalizedStringResource("The price is outside what Perpl accepts on this market.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 38, 42: return L10n.string(LocalizedStringResource("The size is outside what Perpl accepts on this market.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 25: return L10n.string(LocalizedStringResource("It reached Perpl's limit of matches for one order. Try a smaller size.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. Matches: the resting orders one order can trade against."))
        case 46: return L10n.string(LocalizedStringResource("It couldn't fill in full, so nothing was filled.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 33: return L10n.string(LocalizedStringResource("The order no longer exists on Perpl.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 45: return L10n.string(LocalizedStringResource("Perpl couldn't cancel it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 50: return L10n.string(LocalizedStringResource("That order belongs to another account.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 57, 58: return L10n.string(LocalizedStringResource("Perpl refused the take-profit or stop-loss (its price, size or position).", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 15: return L10n.string(LocalizedStringResource("Perpl couldn't send it to Monad, so nothing was placed. Try again.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 37, 53: return L10n.string(LocalizedStringResource("Perpl can't settle trades on this market right now.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names."))
        case 5, 20: return L10n.string(LocalizedStringResource("Perpl refused the order's time limit. Try again.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. Time limit: the block by which the order must execute or expire."))
        case 64: return L10n.string(LocalizedStringResource("It triggered, but Perpl couldn't execute it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is a take-profit or stop-loss."))
        case 67: return L10n.string(LocalizedStringResource("It triggered, but expired before it could execute.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is a take-profit or stop-loss."))
        case 36: return L10n.string(LocalizedStringResource("Perpl couldn't post it to the order book.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order."))
        case 23, 44: return L10n.string(LocalizedStringResource("Perpl couldn't settle it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order; to settle: to record the trade on Perpl's exchange."))
        case 0: return L10n.string(LocalizedStringResource("Perpl didn't execute it.", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one or two whole sentences. Shown on its own under a result headline ('Not filled', 'Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines ('Take-profit not placed: %@'). Perpl and Monad are names. 'It' is the order; said when Perpl gave no reason."))
        default: return L10n.string(LocalizedStringResource("Perpl refused it (reason \(String(reason))).", bundle: L10n.kit, comment: "Why Perpl refused or ended a Perps order or request, as one whole sentence, when the app has no sentence for Perpl's reason. Shown under a result headline ('Order failed') and as the last placeholder of the take-profit / stop-loss and cancel result lines. %@ is Perpl's numeric reason code. 'It' is the order."))
        }
    }
}

// MARK: Outcomes

/// What filled: Perpl's own numbers, raw (the market's scaled integers; the decimals live where a `PerpMarket` is).
public struct PerplFillSummary: Sendable, Equatable, Codable {
    public let filledSizeRaw: Int, requestedSizeRaw: Int
    /// `fp`, else the fills' size-weighted average, else nil (never the mark).
    public let priceRaw: Int?
    /// `f`, else the sum of the fills' `f`, else nil.
    public let feeCNS: String?
    public let txid: String?

    public init(filledSizeRaw: Int, requestedSizeRaw: Int, priceRaw: Int?, feeCNS: String?, txid: String?) {
        self.filledSizeRaw = filledSizeRaw; self.requestedSizeRaw = requestedSizeRaw; self.priceRaw = priceRaw
        self.feeCNS = feeCNS; self.txid = txid
    }

    public func size(lotDecimals: Int) -> Double { Double(filledSizeRaw) / pow(10, Double(lotDecimals)) }
    public func price(priceDecimals: Int) -> Double? { priceRaw.map { Double($0) / pow(10, Double(priceDecimals)) } }
    /// The fee in dollars (AUSD has 6 decimals); negative is a rebate.
    public var feeUSD: Double? { feeCNS.flatMap { Double($0) }.map { $0 / 1_000_000 } }
}

public enum PerplOrderOutcome: Sendable, Equatable, Codable {
    public enum Rest: Sendable, Equatable, Codable { case cancelled(PerplOrderReason), resting(orderId: Int?), expired }
    public enum Unconfirmed: Sendable, Equatable, Codable { case timedOut, connectionLost, foreignReport }
    public enum Tone: Sendable, Equatable, Codable { case success, warning, failure, neutral }

    case filled(PerplFillSummary)
    case partlyFilled(PerplFillSummary, rest: Rest)
    case resting(orderId: Int?)
    case notFilled(PerplOrderReason)
    case failed(PerplOrderReason)
    case expired
    /// An entry cancelled before any fill; a take-profit / stop-loss cancelled; a cancel request that went through.
    case cancelled(PerplOrderReason)
    case armed, triggered
    /// Chain evidence only: the position grew, Perpl's own report never came.
    case observed(PerplPositionEvidence.Growth)
    case unconfirmed(Unconfirmed)

    /// success: filled, resting, armed · warning: partlyFilled, expired, observed, unconfirmed, triggered ·
    /// failure: notFilled, failed · neutral: cancelled.
    public var tone: Tone {
        switch self {
        case .filled, .resting, .armed: return .success
        case .partlyFilled, .expired, .observed, .unconfirmed, .triggered: return .warning
        case .notFilled, .failed: return .failure
        case .cancelled: return .neutral
        }
    }

    public var fill: PerplFillSummary? {
        switch self {
        case .filled(let fill), .partlyFilled(let fill, _): return fill
        default: return nil
        }
    }

    /// Perpl provably executed nothing: notFilled, failed, expired, cancelled. (Refund / userCloseVoided only on these.)
    public var executedNothing: Bool {
        switch self {
        case .notFilled, .failed, .expired, .cancelled: return true
        default: return false
        }
    }

    /// Could still change: unconfirmed, observed, resting, partlyFilled(rest: .resting).
    public var canStillChange: Bool {
        switch self {
        case .unconfirmed, .observed, .resting: return true
        case .partlyFilled(_, rest: .resting): return true
        default: return false
        }
    }

    /// `usd` for Activity: filled size × fill price (or attributable chain growth × its implied price); nil whenever
    /// nothing filled or the price is unknown. Never the requested notional, never the mark.
    public func volumeUSD(priceDecimals: Int, lotDecimals: Int) -> Double? {
        switch self {
        case .filled(let fill), .partlyFilled(let fill, _):
            let size = fill.size(lotDecimals: lotDecimals)
            guard size > 0, let price = fill.price(priceDecimals: priceDecimals), price > 0 else { return nil }
            return size * price
        case .observed(let growth):
            guard growth.attributable, growth.size > 0, let price = growth.price, price > 0 else { return nil }
            return growth.size * price
        default:
            return nil
        }
    }
}

// MARK: The ledger

/// The per-request reducer, keyed by (accountId, rq), applying Perpl's client-side deduplication: the first non-failure
/// status is definitive and later failures are ignored; a failure counts only while every message received is one.
public struct PerplOrderLedger: Sendable {
    /// `collateral`: an IncreasePositionCollateral request (add margin), whose reports never touch an order's (I8).
    public enum Kind: Sendable, Equatable, Codable { case entry(ioc: Bool, sizeRaw: Int), trigger, cancel, collateral }
    /// Perpl's "head ≥ lb, no status, no reconnect ⇒ not executed" rule is NOT applied in this build: mt:100 on the
    /// trading socket hasn't been observed to be one heartbeat per block continuing the mt:19 `sn` (census).
    public static let concludesExpiryFromHeartbeat = false
    /// Requests remembered (the least recently updated go first) and for how long.
    public static let capacity = 512, retention: TimeInterval = 86_400
    /// Events and fills that arrive before the event that maps their order to a request: at most this many, this long.
    static let bufferCapacity = 64, bufferWindow: TimeInterval = 30
    static let liveStatuses: Set<Int> = [1, 2, 3, 8, 9]
    static let nonFailureStatuses: Set<Int> = [2, 3, 4, 5, 8, 9, 10]
    /// Filled, Canceled, Expired, Executed: the order is over.
    static let terminalStatuses: Set<Int> = [4, 5, 6, 10]

    struct RequestKey: Hashable, Sendable { let account: Int; let rq: Int }
    struct OrderKey: Hashable, Sendable { let account: Int; let market: Int; let oid: Int }

    /// Everything seen for one request.
    struct Entry: Sendable {
        var first: PerplOrderEvent?
        var firstCarriedRq: Bool?
        var firstFailure: PerplOrderReason?
        var sawNonFailure = false
        var failureThenNonFailure = false
        var failuresCarryingLog = 0
        var status: Int?
        var removed = false
        var filled: Int?
        var fillPrice: Int?
        var fee: String?
        var orderId: Int?
        var marketId: Int?
        var txid: String?
        var reason: Int?
        var failure: Int?
        var originalSize: Int?
        var fills: [PerplFillEvent] = []
        var positionChanged = false
        var isCancel = false
        var terminal = false
        var events = 0
        /// The latest block an event of it carried (`at.b`).
        var lastBlock: Int?
        /// When its first event arrived.
        var firstAt: Date?
        var updatedAt: Date
    }

    struct Buffered<T: Sendable>: Sendable { let item: T; let account: Int; let at: Date }

    /// A request that just ended (its order key no longer maps to it): its late fills and rq-less reports, which Perpl
    /// may send after the terminal one, still belong to it for `bufferWindow`, so they never wait in the buffer for the
    /// next request that reuses the order id.
    struct Ended: Sendable { let rq: Int; let at: Date; let block: Int? }

    private(set) var account: Int?
    private(set) var entries: [RequestKey: Entry] = [:]
    private var keyToRq: [OrderKey: Int] = [:]
    /// Per order key, the requests that ended under it within `bufferWindow`, oldest first.
    private var recentlyEnded: [OrderKey: [Ended]] = [:]
    private var sent: [RequestKey: PerplSentRequest] = [:]
    private var bufferedEvents: [Buffered<PerplOrderEvent>] = []
    private var bufferedFills: [Buffered<PerplFillEvent>] = []

    /// `account`: the account the socket's WalletSnapshot seeded; events without `acc` are attributed to it.
    public init(account: Int?) { self.account = account }

    public mutating func setAccount(_ id: Int?) { account = id }

    /// The client calls this at every write (census timing, the `.cancel` kind for events that omit `t`). `outcome` still
    /// takes the `PerplSentRequest`, because after a reconnect another client's ledger answers for an rq it never wrote.
    public mutating func noteSent(_ sent: PerplSentRequest, rq: Int) {
        self.sent[RequestKey(account: sent.accountId, rq: rq)] = sent
    }

    /// Returns the rqs whose outcome may have changed, and (a cancel request's own event) the order it cancels with the
    /// cancel's status, for the client's removal rule.
    public mutating func apply(_ event: PerplOrderEvent, at now: Date) -> (changed: Set<Int>, cancelTarget: (key: PerplOpenOrder.Key, status: Int)?) {
        guard let account = event.accountId ?? self.account else { return ([], nil) }
        let writtenAsCancel = event.requestId.map { sent[RequestKey(account: account, rq: $0)]?.kind == .cancel } ?? false
        if event.isCancelRequest || writtenAsCancel {
            // Its own report only: it never maps, reads or deletes an order key, so it can't be mistaken for its target.
            var changed: Set<Int> = []
            if let rq = event.requestId {
                attach(event, to: RequestKey(account: account, rq: rq), carriedRq: true, isCancel: true, at: now)
                changed.insert(rq)
            }
            var target: (key: PerplOpenOrder.Key, status: Int)?
            if let market = event.marketId, let oid = event.orderId, let status = event.status {
                target = (PerplOpenOrder.Key(marketId: market, oid: oid), status)
            }
            return (changed, target)
        }
        let writtenAsCollateral = event.requestId.map { sent[RequestKey(account: account, rq: $0)]?.kind == .collateral } ?? false
        if event.typeRaw == 6 || writtenAsCollateral {
            // An IncreasePositionCollateral request's own report: attached to its own request only, never joined, mapped or
            // drained by an order id it may carry, so it can't be read as an order's (I8, as a cancel's). One without a
            // request id names nothing of its own: dropped.
            guard let rq = event.requestId else { return ([], nil) }
            attach(event, to: RequestKey(account: account, rq: rq), carriedRq: true, isCancel: false, keepsOrderId: false, at: now)
            return ([rq], nil)
        }
        if let rq = event.requestId {
            return (join(event, to: RequestKey(account: account, rq: rq), carriedRq: true, account: account, at: now), nil)
        }
        guard let oid = event.orderId else { return ([], nil) }
        // A late report of a request that just ended, from its own block or earlier: it is that request's (never the
        // next one reusing the id). Its result is already decided; only details it lacked are taken.
        if let market = event.marketId, let ended = endedRequest(OrderKey(account: account, market: market, oid: oid), block: event.block, now: now) {
            return (absorbLate(event, into: RequestKey(account: account, rq: ended.rq), at: now), nil)
        }
        switch resolve(account: account, market: event.marketId, oid: oid) {
        case .request(let rq):
            return (join(event, to: RequestKey(account: account, rq: rq), carriedRq: false, account: account, at: now), nil)
        case .ambiguous:
            return ([], nil)
        case .unknown:
            // No live request has the key: a request that just ended still claims a report whose block isn't known.
            if let market = event.marketId,
               let ended = endedRequest(OrderKey(account: account, market: market, oid: oid), block: event.block, now: now, unknownBlockToo: true) {
                return (absorbLate(event, into: RequestKey(account: account, rq: ended.rq), at: now), nil)
            }
            bufferedEvents.append(Buffered(item: event, account: account, at: now))
            trimBuffers(now: now)
            return ([], nil)
        }
    }

    public mutating func apply(_ fill: PerplFillEvent, at now: Date) -> Set<Int> {
        guard let account = fill.accountId ?? self.account else { return [] }
        let orderKey = OrderKey(account: account, market: fill.marketId, oid: fill.orderId)
        // A late fill of a request that just ended, from its own block or earlier: that request's, even when the next
        // one reusing the id is already mapped.
        if let ended = endedRequest(orderKey, block: fill.block, now: now) {
            return attachLateFill(fill, to: RequestKey(account: account, rq: ended.rq), at: now)
        }
        if let rq = keyToRq[orderKey] {
            let key = RequestKey(account: account, rq: rq)
            entries[key]?.fills.append(fill)
            entries[key]?.updatedAt = now
            return [rq]
        }
        // No live request has the key: a request that just ended still claims a fill whose block isn't known.
        if let ended = endedRequest(orderKey, block: fill.block, now: now, unknownBlockToo: true) {
            return attachLateFill(fill, to: RequestKey(account: account, rq: ended.rq), at: now)
        }
        bufferedFills.append(Buffered(item: fill, account: account, at: now))
        trimBuffers(now: now)
        return []
    }

    /// The request that ended under `key` within `bufferWindow` and that an item from `block` belongs to: the earliest
    /// one whose last block is that block or later; with `unknownBlockToo`, the latest one when the item's block (or the
    /// request's) isn't known. An item from a block after every ended request's may be the next request's: never theirs.
    private func endedRequest(_ key: OrderKey, block: Int?, now: Date, unknownBlockToo: Bool = false) -> Ended? {
        let ended = (recentlyEnded[key] ?? []).filter { now.timeIntervalSince($0.at) <= Self.bufferWindow }
        guard !ended.isEmpty else { return nil }
        if let block, let match = ended.first(where: { $0.block.map { block <= $0 } ?? false }) { return match }
        if unknownBlockToo, block == nil || ended.last?.block == nil { return ended.last }
        return nil
    }

    private mutating func attachLateFill(_ fill: PerplFillEvent, to key: RequestKey, at now: Date) -> Set<Int> {
        guard entries[key] != nil else { return [] }
        entries[key]?.fills.append(fill)
        entries[key]?.updatedAt = now
        return [key.rq]
    }

    /// A late report of an ended request: its status, removal and reasons stay as decided; a filled size, fill price,
    /// fee or transaction it didn't carry yet is taken. Returns the request when something was taken.
    private mutating func absorbLate(_ event: PerplOrderEvent, into key: RequestKey, at now: Date) -> Set<Int> {
        guard var entry = entries[key] else { return [] }
        var changed = false
        if let fs = event.filledSizeRaw, fs > (entry.filled ?? 0) { entry.filled = fs; changed = true }
        if entry.fillPrice == nil, let fp = event.fillPriceRaw, fp > 0 { entry.fillPrice = fp; changed = true }
        if entry.fee == nil, let fee = event.feeCNS { entry.fee = fee; changed = true }
        if entry.txid == nil, let txid = event.txid { entry.txid = txid; changed = true }
        entry.updatedAt = now
        entries[key] = entry
        return changed ? [key.rq] : []
    }

    public mutating func apply(_ position: PerplPositionEvent, at now: Date) -> Set<Int> {
        guard let account = position.accountId ?? self.account else { return [] }
        var changed: Set<Int> = []
        if let rq = position.requestId {
            let key = RequestKey(account: account, rq: rq)
            if entries[key] == nil, sent[key] != nil { entries[key] = Entry(updatedAt: now) }
            if entries[key] != nil {
                entries[key]?.positionChanged = true
                entries[key]?.updatedAt = now
                changed.insert(rq)
            }
        }
        if let oid = position.orderId, let market = position.marketId, let rq = keyToRq[OrderKey(account: account, market: market, oid: oid)] {
            let key = RequestKey(account: account, rq: rq)
            entries[key]?.positionChanged = true
            entries[key]?.updatedAt = now
            changed.insert(rq)
        }
        return changed
    }

    /// Perpl's outcome for `rq` as the events seen so far decide it, or nil while undecided. `final`: the deadline passed
    /// and the sending socket stayed signed in with no heartbeat gap since the write (Perpl's "no reconnections" rule):
    /// a provisional failure is then the answer.
    public func outcome(rq: Int, sent: PerplSentRequest, final: Bool) -> PerplOrderOutcome? {
        guard let entry = entries[RequestKey(account: sent.accountId, rq: rq)] else { return nil }
        if Self.isForeign(entry, sent: sent) { return .unconfirmed(.foreignReport) }
        switch sent.kind {
        case .collateral: return nil // never an order's outcome: `collateralOutcome`
        case .cancel: return Self.cancelOutcome(entry)
        case .trigger: return Self.triggerOutcome(entry, final: final)
        case .entry(let ioc, let size): return Self.entryOutcome(entry, ioc: ioc, sizeRaw: size, final: final)
        }
    }

    /// What Perpl did with the IncreasePositionCollateral request `rq` (add margin), from its reports, in this order (p4
    /// spec A.4.3): the position's collateral grown under its own request id (`grown`, from the client's mt:27 reading)
    /// is added, whatever else was said; nothing seen, or a first report of another request, is undecided; a terminal
    /// success (Filled 4, Executed 10) is added; Canceled 5 or Expired 6 — which a request that never matches may also
    /// report for "processed" — or a removal without a failure is undecided, never refused; a failure while nothing else
    /// arrived is refused when it is final at once, or at the evidence wait's end with the socket signed in throughout
    /// (`final`). INFERRED and failing safe: nothing undecided ever reads as added or as refused.
    public func collateralOutcome(rq: Int, sent: PerplSentRequest, final: Bool, grown: BigUInt?) -> PerplCollateralOutcome? {
        if let grown, grown > 0 { return .added(deltaCNS: grown) }
        guard let entry = entries[RequestKey(account: sent.accountId, rq: rq)] else { return nil }
        if Self.isForeign(entry, sent: sent) { return nil }
        if entry.sawNonFailure, entry.status == 4 || entry.status == 10 { return .added(deltaCNS: nil) }
        if entry.status == 5 || entry.status == 6 || (entry.removed && entry.firstFailure == nil) { return nil }
        if !entry.sawNonFailure, let failure = entry.firstFailure, failure.isFinalAtOnce || final { return .refused(failure) }
        return nil
    }

    /// The failure Perpl reported while nothing else has arrived, and which a later report may still replace.
    public func provisionalFailure(rq: Int, accountId: Int) -> PerplOrderReason? {
        guard let entry = entries[RequestKey(account: accountId, rq: rq)], !entry.sawNonFailure, entry.status != 6, !entry.removed,
              let failure = entry.firstFailure, !failure.isFinalAtOnce else { return nil }
        return failure
    }

    /// The request an order key belongs to, while that request is live.
    public func requestId(for key: PerplOpenOrder.Key, accountId: Int) -> Int? {
        keyToRq[OrderKey(account: accountId, market: key.marketId, oid: key.oid)]
    }

    /// A position update named this request (by `rq`, or by its market and order id): a hint to reload, never a size.
    public func sawPositionChange(rq: Int, accountId: Int) -> Bool {
        entries[RequestKey(account: accountId, rq: rq)]?.positionChanged ?? false
    }

    /// Forgets requests older than `retention`, then the least recently updated beyond `capacity`, and buffered events
    /// past their window.
    public mutating func prune(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.updatedAt) < Self.retention }
        if entries.count > Self.capacity {
            let keep = Set(entries.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.capacity).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        keyToRq = keyToRq.filter { entries[RequestKey(account: $0.key.account, rq: $0.value)] != nil }
        sent = sent.filter { now.timeIntervalSince($0.value.writtenAt) < Self.retention }
        if sent.count > Self.capacity {
            let keep = Set(sent.sorted { $0.value.writtenAt > $1.value.writtenAt }.prefix(Self.capacity).map(\.key))
            sent = sent.filter { keep.contains($0.key) }
        }
        trimBuffers(now: now)
    }

    // MARK: Census reads (counts only)

    func entry(rq: Int, accountId: Int) -> Entry? { entries[RequestKey(account: accountId, rq: rq)] }

    func orderKey(rq: Int, accountId: Int) -> PerplOpenOrder.Key? {
        guard let entry = entries[RequestKey(account: accountId, rq: rq)], let market = entry.marketId, let oid = entry.orderId else { return nil }
        return PerplOpenOrder.Key(marketId: market, oid: oid)
    }

    // MARK: Joining

    private enum Resolution { case request(Int), ambiguous, unknown }

    /// The live request an order key maps to. Without a market, the only live key with that id; two → ambiguous.
    private func resolve(account: Int, market: Int?, oid: Int) -> Resolution {
        if let market {
            guard let rq = keyToRq[OrderKey(account: account, market: market, oid: oid)] else { return .unknown }
            return isLiveOrUnknown(RequestKey(account: account, rq: rq)) ? .request(rq) : .unknown
        }
        let candidates = Set(keyToRq.filter { $0.key.account == account && $0.key.oid == oid && isLiveOrUnknown(RequestKey(account: account, rq: $0.value)) }.values)
        if candidates.count > 1 { return .ambiguous }
        return candidates.first.map { .request($0) } ?? .unknown
    }

    private func isLiveOrUnknown(_ key: RequestKey) -> Bool {
        guard let entry = entries[key] else { return true }
        guard !entry.terminal else { return false }
        return entry.status.map { Self.liveStatuses.contains($0) } ?? true
    }

    /// Attaches `event` to its request, maps its order key while the request is live (draining what waited for that
    /// key), and deletes every mapping of a request that this made terminal, so a reused (market, id) can never resolve
    /// to it again.
    private mutating func join(_ event: PerplOrderEvent, to key: RequestKey, carriedRq: Bool, account: Int, at now: Date) -> Set<Int> {
        let wasTerminal = entries[key]?.terminal ?? false
        attach(event, to: key, carriedRq: carriedRq, isCancel: false, at: now)
        if !wasTerminal, let market = event.marketId ?? entries[key]?.marketId, let oid = event.orderId ?? entries[key]?.orderId {
            let orderKey = OrderKey(account: account, market: market, oid: oid)
            keyToRq[orderKey] = key.rq
            drainBuffers(for: orderKey, into: key, at: now)
        }
        if entries[key]?.terminal == true {
            // Its late fills and reports still find it for a while (`endedRequest`), never the next request on the key.
            let block = entries[key]?.lastBlock
            for orderKey in keyToRq.keys where orderKey.account == account && keyToRq[orderKey] == key.rq {
                recentlyEnded[orderKey, default: []].append(Ended(rq: key.rq, at: now, block: block))
            }
            keyToRq = keyToRq.filter { !($0.key.account == account && $0.value == key.rq) }
        }
        return [key.rq]
    }

    /// Hands the reports and fills that waited for `orderKey` to the request it now maps to — only those that arrived
    /// after that request was written (or, written by another socket, after its first report): anything older is another
    /// order's under a reused id, and is dropped.
    private mutating func drainBuffers(for orderKey: OrderKey, into key: RequestKey, at now: Date) {
        let since = sent[key]?.writtenAt ?? entries[key]?.firstAt
        func isTooOld(_ at: Date) -> Bool { since.map { at < $0 } ?? false }
        let mine = { (b: Buffered<PerplOrderEvent>) in b.account == orderKey.account && b.item.orderId == orderKey.oid && (b.item.marketId ?? orderKey.market) == orderKey.market }
        let events = bufferedEvents.filter(mine)
        if !events.isEmpty {
            bufferedEvents.removeAll(where: mine)
            for buffered in events where !isTooOld(buffered.at) { attach(buffered.item, to: key, carriedRq: false, isCancel: false, at: now) }
        }
        let fills = bufferedFills.filter { $0.account == orderKey.account && $0.item.marketId == orderKey.market && $0.item.orderId == orderKey.oid }
        if !fills.isEmpty {
            bufferedFills.removeAll { $0.account == orderKey.account && $0.item.marketId == orderKey.market && $0.item.orderId == orderKey.oid }
            entries[key]?.fills.append(contentsOf: fills.filter { !isTooOld($0.at) }.map(\.item))
        }
    }

    private mutating func trimBuffers(now: Date) {
        recentlyEnded = recentlyEnded.compactMapValues { list in
            let kept = list.filter { now.timeIntervalSince($0.at) <= Self.bufferWindow }
            return kept.isEmpty ? nil : kept
        }
        bufferedEvents.removeAll { now.timeIntervalSince($0.at) > Self.bufferWindow }
        bufferedFills.removeAll { now.timeIntervalSince($0.at) > Self.bufferWindow }
        if bufferedEvents.count > Self.bufferCapacity { bufferedEvents.removeFirst(bufferedEvents.count - Self.bufferCapacity) }
        if bufferedFills.count > Self.bufferCapacity { bufferedFills.removeFirst(bufferedFills.count - Self.bufferCapacity) }
    }

    /// Merges one event into its request under the deduplication rule. `keepsOrderId` false (a margin request's report):
    /// an order id it carries is never taken as its own, so no order key can ever map to it.
    private mutating func attach(_ event: PerplOrderEvent, to key: RequestKey, carriedRq: Bool, isCancel: Bool, keepsOrderId: Bool = true, at now: Date) {
        var entry = entries[key] ?? Entry(updatedAt: now)
        entry.updatedAt = now
        entry.events += 1
        if entry.firstAt == nil { entry.firstAt = now }
        if let block = event.block { entry.lastBlock = max(entry.lastBlock ?? block, block) }
        if isCancel { entry.isCancel = true }
        if entry.first == nil {
            entry.first = event
            entry.firstCarriedRq = carriedRq
        }
        if let market = event.marketId { entry.marketId = market }
        if let oid = event.orderId, !isCancel, keepsOrderId { entry.orderId = oid }
        if let os = event.originalSizeRaw { entry.originalSize = os }
        let status = event.status
        if status == 7 {
            if event.logIndex != nil { entry.failuresCarryingLog += 1 }
            let reason = PerplOrderReason(status: 7, reason: event.reason ?? 0, failure: event.failure)
            if !entry.sawNonFailure, entry.firstFailure == nil { entry.firstFailure = reason }
            // A failure after a non-failure is a late duplicate: only its removal flag still counts. While only failures
            // have arrived, the failure itself decides (final at once, or at the deadline), whatever its `r`.
            if event.removed, entry.sawNonFailure { entry.removed = true; entry.terminal = true }
            // A failure is final when Perpl's rule says so; then the request is over.
            if !entry.sawNonFailure, entry.firstFailure?.isFinalAtOnce == true { entry.terminal = true }
            entries[key] = entry
            return
        }
        let isNonFailure = status.map(Self.nonFailureStatuses.contains) ?? false
        if isNonFailure {
            if entry.firstFailure != nil, !entry.sawNonFailure { entry.failureThenNonFailure = true }
            entry.sawNonFailure = true
        }
        if isNonFailure || status == 6 || event.removed {
            if let status { entry.status = status }
            if event.removed { entry.removed = true }
            if let reason = event.reason { entry.reason = reason }
            if let failure = event.failure { entry.failure = failure }
        } else if status == 1, entry.status == nil {
            entry.status = 1
        }
        if let fs = event.filledSizeRaw { entry.filled = max(entry.filled ?? 0, fs) }
        if let fp = event.fillPriceRaw, fp > 0 { entry.fillPrice = fp }
        if let fee = event.feeCNS { entry.fee = fee }
        if let txid = event.txid { entry.txid = txid }
        if Self.terminalStatuses.contains(entry.status ?? 0) || entry.removed { entry.terminal = true }
        entries[key] = entry
    }

    // MARK: Deciding

    /// The first event joined to the request isn't the order that was written under it (another order reported under
    /// the same request id): nothing it says is read as this order's.
    static func isForeign(_ entry: Entry, sent: PerplSentRequest) -> Bool {
        guard let first = entry.first else { return false }
        if let market = first.marketId, market != sent.marketId { return true }
        if let type = first.typeRaw, type != sent.wireType { return true }
        if let size = first.originalSizeRaw, size != sent.lotLNS { return true }
        return false
    }

    private static func summary(_ entry: Entry, filled: Int, requested: Int) -> PerplFillSummary {
        PerplFillSummary(filledSizeRaw: filled, requestedSizeRaw: requested,
                         priceRaw: entry.fillPrice ?? vwap(entry.fills), feeCNS: entry.fee ?? feeSum(entry.fills),
                         txid: entry.txid ?? entry.fills.last?.txid)
    }

    /// The size-weighted average price of `fills`, or nil when any has no price.
    static func vwap(_ fills: [PerplFillEvent]) -> Int? {
        guard !fills.isEmpty, fills.allSatisfy({ $0.priceRaw != nil }) else { return nil }
        let size = fills.reduce(0.0) { $0 + Double($1.sizeRaw) }
        guard size > 0 else { return nil }
        let notional = fills.reduce(0.0) { $0 + Double($1.sizeRaw) * Double($1.priceRaw ?? 0) }
        return Int(exactly: (notional / size).rounded())
    }

    /// The sum of the fills' fees, or nil when any has none.
    static func feeSum(_ fills: [PerplFillEvent]) -> String? {
        guard !fills.isEmpty else { return nil }
        var total = Decimal(0)
        for fill in fills {
            guard let text = fill.feeCNS, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            total += value
        }
        return NSDecimalNumber(decimal: total).stringValue
    }

    private static func filledSize(_ entry: Entry) -> Int? {
        entry.filled ?? (entry.fills.isEmpty ? nil : entry.fills.reduce(0) { $0 + $1.sizeRaw })
    }

    private static func entryOutcome(_ entry: Entry, ioc: Bool, sizeRaw: Int, final: Bool) -> PerplOrderOutcome? {
        let requested = entry.originalSize ?? sizeRaw
        let fs = filledSize(entry)
        let fallback = ioc ? 16 : 0
        func rest(_ reason: Int) -> PerplOrderReason { PerplOrderReason(status: 5, reason: entry.reason ?? reason, failure: entry.failure) }
        if entry.sawNonFailure || entry.status == 6 || entry.removed {
            switch entry.status {
            case 4:
                let filled = fs ?? requested
                return filled >= requested
                    ? .filled(summary(entry, filled: filled, requested: requested))
                    : .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .cancelled(rest(16)))
            case 5:
                let filled = fs ?? 0
                if filled > 0 { return .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .cancelled(rest(fallback))) }
                return ioc ? .notFilled(rest(16)) : .cancelled(rest(0))
            case 6:
                let filled = fs ?? 0
                return filled > 0 ? .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .expired) : .expired
            default:
                break
            }
            if entry.removed {
                let filled = fs ?? 0
                if filled > 0, filled >= requested { return .filled(summary(entry, filled: filled, requested: requested)) }
                if filled > 0 { return .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .cancelled(rest(fallback))) }
                return ioc ? .notFilled(rest(16)) : .cancelled(rest(0))
            }
            if !ioc {
                switch entry.status {
                case 2:
                    return .resting(orderId: entry.orderId)
                case 3:
                    let filled = fs ?? 0
                    return filled > 0 ? .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .resting(orderId: entry.orderId)) : .resting(orderId: entry.orderId)
                default:
                    break
                }
            }
        }
        if !entry.sawNonFailure, let failure = entry.firstFailure {
            return failure.isFinalAtOnce || final ? .failed(failure) : nil
        }
        // An IOC still reported as resting or partly filled at the deadline: what filled is final, the rest is gone.
        if final, ioc, let filled = fs, filled > 0 {
            return filled >= requested
                ? .filled(summary(entry, filled: filled, requested: requested))
                : .partlyFilled(summary(entry, filled: filled, requested: requested), rest: .cancelled(PerplOrderReason(status: 5, reason: 16)))
        }
        return nil
    }

    private static func triggerOutcome(_ entry: Entry, final: Bool) -> PerplOrderOutcome? {
        if entry.sawNonFailure || entry.status == 6 || entry.removed {
            switch entry.status {
            case 9, 10, 4: return .triggered
            case 5: return .cancelled(PerplOrderReason(status: 5, reason: entry.reason ?? 0, failure: entry.failure))
            case 6: return .expired
            default: break
            }
            if entry.removed { return .cancelled(PerplOrderReason(status: 5, reason: entry.reason ?? 0, failure: entry.failure)) }
            if entry.status == 8 { return .armed }
        }
        if !entry.sawNonFailure, let failure = entry.firstFailure {
            return failure.isFinalAtOnce || final ? .failed(failure) : nil
        }
        return nil
    }

    /// A cancel request's own outcome: its refusal is final at once; a non-failure terminal status means it went through.
    private static func cancelOutcome(_ entry: Entry) -> PerplOrderOutcome? {
        if !entry.sawNonFailure, let failure = entry.firstFailure { return .failed(failure) }
        if [4, 5, 10].contains(entry.status ?? 0) { return .cancelled(PerplOrderReason(status: 5, reason: 28)) }
        return nil
    }
}

// MARK: Waiting

/// Every Perpl wait in one place, so the drain cap provably covers them.
public enum PerplTimeouts {
    public static let ack: TimeInterval = 8                 // PerplTradeClient.send
    public static let removal: TimeInterval = 10            // awaitRemoval / awaitCancelled
    public static let triggerOutcome: TimeInterval = 5      // changeTriggers' one combined st-8 wait
    public static let outcomeWallClock: TimeInterval = 12   // PerplOutcomeDeadline
    public static let drainAcks: TimeInterval = 8, drainOperation: TimeInterval = 20   // PerplTrading.drain
    /// PerplTrading.addMargin's wait for Perpl's evidence after the write (the ack's 8 s plus this stays under the drain).
    public static let marginEvidence: TimeInterval = 10
    /// PerplTrading.cancelAndConfirm's wait, before anything is sent, for a socket that just signed in to send its open
    /// orders (the check of the order the user saw reads them); with the ack's 8 s and the removal's 10 s it fits the drain.
    public static let ordersSnapshot: TimeInterval = 2
}

/// What Perpl did with an IncreasePositionCollateral request (add margin), from its reports: added — by the position's
/// collateral grown under the request (the measured delta), or by the request's own terminal success (nil: not measured)
/// — or refused with Perpl's reason. Nothing else is ever read as either.
public enum PerplCollateralOutcome: Sendable, Equatable {
    case added(deltaCNS: BigUInt?)
    case refused(PerplOrderReason)
}

/// What a position read on the chain, or a growth the stream reported without the request's id, may say of an add-margin
/// request (p4 spec A.4.3, R.1.6, R.1.7). A position's collateral also moves with fills and with every other margin request,
/// so only an unambiguous change is this request's: the same size as before, the collateral grown by the amount (to the
/// cent), and no other margin request on that market that could have moved it. Anything else leaves the request "not
/// confirmed", which is honest; it never credits one deposit to two requests.
public enum PerplMarginEvidence {
    /// How far a chain read may trail Perpl's own report of a change.
    public static let chainLag: TimeInterval = 5
    /// The collateral grown by the amount sent, give or take a cent.
    public static let tolerance = 0.01

    /// The chain's position on `before`'s market and side holds exactly this request: its size unchanged (within half a lot:
    /// a fill moves the collateral too) and its collateral `amount` above `before`'s, to the cent.
    public static func chainShows(_ positions: [PerpPosition], before: PerpPosition, amount: Double, lotDecimals: Int) -> Bool {
        guard let after = positions.first(where: { $0.perpId == before.perpId }), after.side == before.side,
              !sizeMoved(after, before: before, lotDecimals: lotDecimals) else { return false }
        return abs(after.margin - before.margin - amount) <= tolerance + 1e-9
    }

    /// The chain lists the position on `before`'s market with another side or size: an order moved it since `before`, so the
    /// chain can never again tell this request's collateral apart. A read without that market's position says nothing.
    public static func sizeMoved(in positions: [PerpPosition], before: PerpPosition, lotDecimals: Int) -> Bool {
        guard let after = positions.first(where: { $0.perpId == before.perpId }) else { return false }
        return after.side != before.side || sizeMoved(after, before: before, lotDecimals: lotDecimals)
    }

    private static func sizeMoved(_ after: PerpPosition, before: PerpPosition, lotDecimals: Int) -> Bool {
        abs(after.size - before.size) >= pow(10, -Double(lotDecimals)) / 2
    }

    /// One margin request this device made, as far as telling its collateral from another's goes: its market, when it was
    /// tapped, and when its result stopped being able to move the position's collateral (nil while it is being sent,
    /// waited for or re-checked).
    public struct Request: Sendable, Equatable {
        public let marketId: Int
        public let startedAt: Date
        public var settledAt: Date?

        public init(marketId: Int, startedAt: Date, settledAt: Date? = nil) {
            self.marketId = marketId
            self.startedAt = startedAt
            self.settledAt = settledAt
        }
    }

    /// Another margin request on `marketId` than `id` could have moved the collateral since `since` (when this request's
    /// "before" was read, or its write; nil: unknown, so any other one counts): one still being sent, waited for or
    /// re-checked, or one whose result came in after `since` (a chain read trails by up to `chainLag`). In flight or in
    /// either list, written before this one or after: it is the same collateral.
    public static func otherMargin(than id: UUID, on marketId: Int, since: Date?, among requests: [UUID: Request]) -> Bool {
        requests.contains { key, request in
            guard key != id, request.marketId == marketId else { return false }
            guard let settled = request.settledAt, let since else { return true }
            return settled > since.addingTimeInterval(-chainLag)
        }
    }
}

/// When an outcome wait gives up: the first of (ack head + max(ttl, 20) + 5) by the trading heartbeat, or 12 s from the
/// ack (or from the write, for an unacknowledged entry) — always under the drain's 20 s cap and a passkey session's
/// 30 s grace.
public struct PerplOutcomeDeadline: Sendable, Equatable, Codable {
    public static let marginBlocks = 5, defaultTTLBlocks = 20
    public let block: Int?
    public let wallClock: Date

    /// `ttlBlocks` nil or below 20 → 20.
    public init(ackHead: Int?, ttlBlocks: Int?, ackAt: Date, cap: TimeInterval = PerplTimeouts.outcomeWallClock) {
        let ttl = max(ttlBlocks ?? Self.defaultTTLBlocks, Self.defaultTTLBlocks)
        block = ackHead.map { $0 + ttl + Self.marginBlocks }
        wallClock = ackAt.addingTimeInterval(cap)
    }

    public func hasPassed(head: Int?, now: Date) -> Bool {
        if now >= wallClock { return true }
        if let block, let head, head >= block { return true }
        return false
    }
}

/// mt:100 on the trading socket: the head block and the sequence. A gap after an in-order run marks the stream suspect
/// until the next snapshots; it never closes the socket in this build.
public struct PerplHeartbeat: Sendable, Equatable {
    public enum Beat: Sendable, Equatable { case inOrder, unseeded(expected: Int?, got: Int), gap(missed: Int), stale }
    public private(set) var lastSn: Int?
    public private(set) var head: Int?
    public private(set) var gaps = 0
    public private(set) var lastBeatAt: Date?
    public private(set) var inOrderSinceSnapshot = 0
    /// Sequenced beats since the WalletSnapshot (1: the first one).
    public private(set) var beatsSinceSnapshot = 0
    public private(set) var suspect = false
    public private(set) var lastGapAt: Date?
    /// The next beat is the first after a WalletSnapshot: it may re-seed the sequence once.
    private var awaitingFirstBeat = false

    public init() {}

    /// mt:19's header `sn`, which the docs say the heartbeats continue (unverified: the first beat may re-seed it).
    public mutating func snapshot(sn: Int?) {
        lastSn = sn
        awaitingFirstBeat = true
        inOrderSinceSnapshot = 0
        beatsSinceSnapshot = 0
    }

    /// mt:23 and mt:26 of a socket have both arrived: the lists are whole again.
    public mutating func snapshotsArrived() { suspect = false }

    public mutating func beat(sn: Int?, head: Int?, at: Date) -> Beat {
        if let head { self.head = max(self.head ?? head, head) }
        lastBeatAt = at
        guard let sn else { return .inOrder }
        beatsSinceSnapshot += 1
        if awaitingFirstBeat {
            awaitingFirstBeat = false
            if let last = lastSn, sn == last + 1 {
                lastSn = sn
                inOrderSinceSnapshot += 1
                return .inOrder
            }
            let expected = lastSn.map { $0 + 1 }
            lastSn = sn
            return .unseeded(expected: expected, got: sn)
        }
        guard let last = lastSn else {
            lastSn = sn
            return .unseeded(expected: nil, got: sn)
        }
        if sn == last + 1 {
            lastSn = sn
            inOrderSinceSnapshot += 1
            return .inOrder
        }
        if sn > last + 1 {
            gaps += 1
            lastGapAt = at
            if inOrderSinceSnapshot > 0 { suspect = true }
            lastSn = sn
            return .gap(missed: sn - last - 1)
        }
        return .stale
    }
}

/// The highest request id this device wrote per Perpl account, persisted (not a secret), so a NEW client never re-issues
/// an rq the previous socket wrote but Perpl hasn't forwarded yet (`lfr` lags admission): a repeated rq is a retry to
/// Perpl, and the new order would be swallowed as the earlier one.
public struct PerplRequestIdStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static func key(chainId: Int, accountId: Int) -> String { "perpl.rq.highWater.v1.\(chainId).\(accountId)" }

    /// 0 when none was recorded.
    public func highWater(chainId: Int, accountId: Int) -> Int {
        defaults.integer(forKey: Self.key(chainId: chainId, accountId: accountId))
    }

    /// Never lowers the mark.
    public func record(_ rq: Int, chainId: Int, accountId: Int) {
        let key = Self.key(chainId: chainId, accountId: accountId)
        guard rq > defaults.integer(forKey: key) else { return }
        defaults.set(rq, forKey: key)
    }
}

/// What the chain shows an order did, from the position before it was sent and after.
public enum PerplPositionEvidence {
    public struct Growth: Sendable, Equatable, Codable {
        public let side: PositionSide
        public let size: Double
        public let price: Double?
        /// The growth can only have come from this order: Activity may carry `usd`.
        public let attributable: Bool

        public init(side: PositionSide, size: Double, price: Double?, attributable: Bool) {
            self.side = side; self.size = size; self.price = price; self.attributable = attributable
        }
    }

    /// The growth the order can cause on its own side: reduce-only → nil; held opposite of size h: size ≤ h → nil
    /// (it only shrinks that position), else size − h (a flip); otherwise `size`.
    public static func expectedGrowth(orderSide: PositionSide, size: Double, reduceOnly: Bool, held: (side: PositionSide, size: Double)?) -> Double? {
        guard !reduceOnly, size > 0 else { return nil }
        if let held, held.side != orderSide, held.size > 0 {
            return size <= held.size ? nil : size - held.size
        }
        return size
    }

    /// Same-side or new-position growth between `before` and `after`; nil unless it grew by at least half a lot and by no
    /// more than `expected` + half a lot (more means other fills mixed in), or when `before` was on the other side (a
    /// flip is ambiguous). The price is the one the growth implies, nil when not finite or not positive.
    public static func growth(side: PositionSide, before: PerpPosition?, after: PerpPosition?, expected: Double, lot: Double,
                              attributable: Bool) -> Growth? {
        if let before, before.side != side { return nil }
        guard let after, after.side == side else { return nil }
        let startSize = before?.size ?? 0
        let grown = after.size - startSize
        guard grown >= lot / 2, grown <= expected + lot / 2 else { return nil }
        let notional = after.entry * after.size - (before.map { $0.entry * $0.size } ?? 0)
        let price = notional / grown
        return Growth(side: side, size: grown, price: price.isFinite && price > 0 ? price : nil, attributable: attributable)
    }

    /// No other source could have grown that side: `before` read at most 60 s before the send, no other order of this
    /// device sent to that market and side since, and no resting order that can grow that side.
    public static func isAttributable(beforeAge: TimeInterval, otherTrackedOrders: Bool, restingOnSide: Bool) -> Bool {
        beforeAge >= 0 && beforeAge <= 60 && !otherTrackedOrders && !restingOnSide
    }
}

/// What the authenticated stream actually does, counted (no ids, no amounts), so the owner can judge the Perps kill
/// switches on data. Every field answers an open question of the real-time spec.
public struct PerplStreamCensus: Codable, Sendable, Equatable {
    public var requestsWritten = 0
    public var firstEventCarriedRq = 0, firstEventLackedRq = 0, noEventWithin12s = 0
    public var outcomesDecidedByStream = 0, outcomesTimedOut = 0
    public var oidEqualsScid = 0, oidDiffersFromScid = 0, scidMissing = 0
    public var cancelOwnEvents = 0, cancelTargetOwnRemovals = 0, cancelRemovedOnlyByOwnEvent = 0
    public var failureThenNonFailure = 0, failuresCarryingLog = 0
    public var zeroFillIocTriggersCancelled = 0, zeroFillIocTriggersStillListed = 0
    public var removedWithoutStatus = 0, foreignReports = 0, otherAccountUpdates = 0
    public var heartbeatsInOrder = 0, heartbeatGaps = 0, heartbeatUnseeded = 0, heartbeatStale = 0, firstBeatContinuedSnapshot = 0
    /// Add-margin requests (p4 spec A.5): written; their first report by status (4/10, 5/6, 7); an mt:27 that carried
    /// one's request id; and a collateral growth that came without it while one waited.
    public var marginWritten = 0, marginSt4or10 = 0, marginSt5or6 = 0, marginSt7 = 0, marginPositionWithRq = 0, marginGrowthWithoutRq = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case requestsWritten, firstEventCarriedRq, firstEventLackedRq, noEventWithin12s, outcomesDecidedByStream, outcomesTimedOut
        case oidEqualsScid, oidDiffersFromScid, scidMissing, cancelOwnEvents, cancelTargetOwnRemovals, cancelRemovedOnlyByOwnEvent
        case failureThenNonFailure, failuresCarryingLog, zeroFillIocTriggersCancelled, zeroFillIocTriggersStillListed
        case removedWithoutStatus, foreignReports, otherAccountUpdates
        case heartbeatsInOrder, heartbeatGaps, heartbeatUnseeded, heartbeatStale, firstBeatContinuedSnapshot
        case marginWritten, marginSt4or10, marginSt5or6, marginSt7, marginPositionWithRq, marginGrowthWithoutRq
    }

    /// A census stored by an earlier build (without the fields added since) reads with those at 0 and its counts kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        requestsWritten = try count(.requestsWritten)
        firstEventCarriedRq = try count(.firstEventCarriedRq)
        firstEventLackedRq = try count(.firstEventLackedRq)
        noEventWithin12s = try count(.noEventWithin12s)
        outcomesDecidedByStream = try count(.outcomesDecidedByStream)
        outcomesTimedOut = try count(.outcomesTimedOut)
        oidEqualsScid = try count(.oidEqualsScid)
        oidDiffersFromScid = try count(.oidDiffersFromScid)
        scidMissing = try count(.scidMissing)
        cancelOwnEvents = try count(.cancelOwnEvents)
        cancelTargetOwnRemovals = try count(.cancelTargetOwnRemovals)
        cancelRemovedOnlyByOwnEvent = try count(.cancelRemovedOnlyByOwnEvent)
        failureThenNonFailure = try count(.failureThenNonFailure)
        failuresCarryingLog = try count(.failuresCarryingLog)
        zeroFillIocTriggersCancelled = try count(.zeroFillIocTriggersCancelled)
        zeroFillIocTriggersStillListed = try count(.zeroFillIocTriggersStillListed)
        removedWithoutStatus = try count(.removedWithoutStatus)
        foreignReports = try count(.foreignReports)
        otherAccountUpdates = try count(.otherAccountUpdates)
        heartbeatsInOrder = try count(.heartbeatsInOrder)
        heartbeatGaps = try count(.heartbeatGaps)
        heartbeatUnseeded = try count(.heartbeatUnseeded)
        heartbeatStale = try count(.heartbeatStale)
        firstBeatContinuedSnapshot = try count(.firstBeatContinuedSnapshot)
        marginWritten = try count(.marginWritten)
        marginSt4or10 = try count(.marginSt4or10)
        marginSt5or6 = try count(.marginSt5or6)
        marginSt7 = try count(.marginSt7)
        marginPositionWithRq = try count(.marginPositionWithRq)
        marginGrowthWithoutRq = try count(.marginGrowthWithoutRq)
    }

    public mutating func merge(_ other: PerplStreamCensus) {
        requestsWritten += other.requestsWritten
        firstEventCarriedRq += other.firstEventCarriedRq
        firstEventLackedRq += other.firstEventLackedRq
        noEventWithin12s += other.noEventWithin12s
        outcomesDecidedByStream += other.outcomesDecidedByStream
        outcomesTimedOut += other.outcomesTimedOut
        oidEqualsScid += other.oidEqualsScid
        oidDiffersFromScid += other.oidDiffersFromScid
        scidMissing += other.scidMissing
        cancelOwnEvents += other.cancelOwnEvents
        cancelTargetOwnRemovals += other.cancelTargetOwnRemovals
        cancelRemovedOnlyByOwnEvent += other.cancelRemovedOnlyByOwnEvent
        failureThenNonFailure += other.failureThenNonFailure
        failuresCarryingLog += other.failuresCarryingLog
        zeroFillIocTriggersCancelled += other.zeroFillIocTriggersCancelled
        zeroFillIocTriggersStillListed += other.zeroFillIocTriggersStillListed
        removedWithoutStatus += other.removedWithoutStatus
        foreignReports += other.foreignReports
        otherAccountUpdates += other.otherAccountUpdates
        heartbeatsInOrder += other.heartbeatsInOrder
        heartbeatGaps += other.heartbeatGaps
        heartbeatUnseeded += other.heartbeatUnseeded
        heartbeatStale += other.heartbeatStale
        firstBeatContinuedSnapshot += other.firstBeatContinuedSnapshot
        marginWritten += other.marginWritten
        marginSt4or10 += other.marginSt4or10
        marginSt5or6 += other.marginSt5or6
        marginSt7 += other.marginSt7
        marginPositionWithRq += other.marginPositionWithRq
        marginGrowthWithoutRq += other.marginGrowthWithoutRq
    }

    /// One line, counts only, for the device log (Console.app, subsystem fun.dyorhq.app, category perpl). Not shown to
    /// anyone in the app.
    public var summary: String {
        var parts: [String] = []
        parts.append("perpl census written=\(requestsWritten) firstRq=\(firstEventCarriedRq)/\(firstEventLackedRq) none12s=\(noEventWithin12s)") // not localized: a log line
        parts.append("decided=\(outcomesDecidedByStream) timedOut=\(outcomesTimedOut) oid=scid \(oidEqualsScid)/\(oidDiffersFromScid)/\(scidMissing)") // not localized: a log line
        parts.append("cancelOwn=\(cancelOwnEvents) targetOwn=\(cancelTargetOwnRemovals) onlyOwn=\(cancelRemovedOnlyByOwnEvent)") // not localized: a log line
        parts.append("failThenOk=\(failureThenNonFailure) failLog=\(failuresCarryingLog) iocZeroTr=\(zeroFillIocTriggersCancelled)/\(zeroFillIocTriggersStillListed)") // not localized: a log line
        parts.append("rNoSt=\(removedWithoutStatus) foreign=\(foreignReports) otherAcct=\(otherAccountUpdates)") // not localized: a log line
        parts.append("hb=\(heartbeatsInOrder)/\(heartbeatGaps)/\(heartbeatUnseeded)/\(heartbeatStale) cont=\(firstBeatContinuedSnapshot)") // not localized: a log line
        parts.append("margin=\(marginWritten)/\(marginSt4or10)/\(marginSt5or6)/\(marginSt7)/\(marginPositionWithRq)/\(marginGrowthWithoutRq)") // not localized: a log line
        return parts.joined(separator: " ")
    }
}
