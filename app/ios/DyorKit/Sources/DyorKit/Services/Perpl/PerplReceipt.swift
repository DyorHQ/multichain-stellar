import BigInt
import Foundation

/* What an on-chain Perpl transaction did, read from its receipt's Exchange logs. A successful receipt only says the
   transaction ran: an IOC that matched nothing does not revert (ImmediateOrCancelExecuted(unmatched == total)), so
   "confirmed" is not "filled". Every Exchange event is non-indexed (topic 0 only). The logs of one request are its
   OrderRequestV2 and the events after it, up to the next OrderRequestV2 or OrderBatchCompleted. Only a group whose
   numbers agree with each other yields an outcome; anything else is nil, "couldn't be read", never a guess. */
public enum PerplReceipt {
    /// keccak256 of each event's canonical signature (dex-sdk Exchange.json). `OrderRequestV2` ends in a dynamic `bytes
    /// extension` that is never read.
    public enum Topic {
        public static let orderRequestV2 = ABI.eventTopic("OrderRequestV2(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256,uint256,bytes)")
        public static let orderBatchCompleted = ABI.eventTopic("OrderBatchCompleted(uint256)")
        public static let takerOrderFilledV2 = ABI.eventTopic("TakerOrderFilledV2(uint256,uint256,uint256,uint256,uint256,int256,uint256,uint256,uint256)")
        public static let makerOrderFilledV2 = ABI.eventTopic("MakerOrderFilledV2(uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256,uint256,uint256)")
        public static let immediateOrCancelExecuted = ABI.eventTopic("ImmediateOrCancelExecuted(uint256,uint256)")
        public static let orderPlaced = ABI.eventTopic("OrderPlaced(uint256,uint256,uint256,int256,uint256)")
        public static let orderCancelled = ABI.eventTopic("OrderCancelled(uint256,int256,uint256)")
        public static let positionOpenedV2 = ABI.eventTopic("PositionOpenedV2(uint256,uint256,uint8,uint256,uint256,int256,uint256,uint256,uint256,uint256,uint256)")
        public static let positionIncreasedV2 = ABI.eventTopic("PositionIncreasedV2(uint256,uint256,uint8,uint256,uint256,uint256,int256,int256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)")
        public static let positionDecreased = ABI.eventTopic("PositionDecreased(uint256,uint256,uint8,uint256,uint256,uint256,uint256,int256,int256)")
        public static let positionClosed = ABI.eventTopic("PositionClosed(uint256,uint256,uint8,uint256,int256,int256)")
        public static let positionInverted = ABI.eventTopic("PositionInverted(uint256,uint256,uint8,uint256,uint256,uint256,int256,uint256,uint256,uint256,int256,int256,uint256,uint256)")
        public static let increasePositionCollateral = ABI.eventTopic("IncreasePositionCollateral(uint256,uint256,uint256,uint256,uint256)")

        // The V1 events the ABI still ships: a fill or position change reported by one is invisible to the V2 reading
        // above, so a group holding one is never read.
        public static let orderRequest = ABI.eventTopic("OrderRequest(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256,uint256)")
        public static let takerOrderFilled = ABI.eventTopic("TakerOrderFilled(uint256,uint256,uint256,uint256,uint256,int256,uint256)")
        public static let makerOrderFilled = ABI.eventTopic("MakerOrderFilled(uint256,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256)")
        public static let positionOpened = ABI.eventTopic("PositionOpened(uint256,uint256,uint8,uint256,uint256,int256,uint256,uint256,uint256,uint256)")
        public static let positionIncreased = ABI.eventTopic("PositionIncreased(uint256,uint256,uint8,uint256,uint256,uint256,int256,int256,uint256,uint256,uint256,uint256,uint256,uint256)")
        public static let positionDeleveraged = ABI.eventTopic("PositionDeleveraged(uint256,uint256,bool,uint8,uint256,uint256,uint256,int256,int256,uint256,uint256,uint256,uint256,uint256,uint256)")
        public static let positionUnwound = ABI.eventTopic("PositionUnwound(uint256,uint256,uint256,uint8,uint256,uint256,uint256,int256,uint256,uint256)")

        static let legacy: Set<Data> = [orderRequest, takerOrderFilled, makerOrderFilled, positionOpened, positionIncreased, positionDeleveraged, positionUnwound]

        /// The 32-byte words each known event's static head holds: shorter data can't be read.
        static let headWords: [Data: Int] = [
            orderRequestV2: 18, orderBatchCompleted: 1, takerOrderFilledV2: 9, makerOrderFilledV2: 11, immediateOrCancelExecuted: 2,
            orderPlaced: 5, orderCancelled: 3, positionOpenedV2: 11, positionIncreasedV2: 15, positionDecreased: 9, positionClosed: 6,
            positionInverted: 14, increasePositionCollateral: 5,
        ]
    }

    /// The Exchange's failure events → their `OrderStatusReason` code (types.md's table, matched by name).
    public static let failureReasons: [Data: Int] = [
        ABI.eventTopic("AmountExceedsAvailableBalance(uint256,uint256,uint256)"): 1,
        ABI.eventTopic("AccountFrozen(uint8)"): 2,
        ABI.eventTopic("CantChangeCloseOrder(uint256,uint256,uint256)"): 4,
        ABI.eventTopic("ChangeExpiredOrderNeedsNewExpiry(uint256,uint256,uint256,uint256)"): 5,
        ABI.eventTopic("CloseOrderExceedsPosition(uint256,uint256)"): 10,
        ABI.eventTopic("CloseOrderPositionMismatch(uint8,uint8)"): 11,
        ABI.eventTopic("ContractNotOperational(uint256,uint8)"): 12,
        ABI.eventTopic("CrossesBook(uint256,bool)"): 13,
        ABI.eventTopic("ExceedsLastExecutionBlock(uint256)"): 14,
        ABI.eventTopic("InsuficientFundsForRecycleFee(uint256,uint256,uint256,uint256,uint256)"): 18,
        ABI.eventTopic("InvalidAccountFrozenOrder(uint8,bool)"): 19,
        ABI.eventTopic("InvalidExpiryBlock(uint256,uint256)"): 20,
        ABI.eventTopic("InvalidOrderId(uint256,uint256,uint256)"): 21,
        ABI.eventTopic("MakerOrderSettlementFailed(uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,int256,uint256)"): 23,
        ABI.eventTopic("MaximumAccountOrders(uint256,uint256)"): 24,
        ABI.eventTopic("MaxMatchesReached()"): 25,
        ABI.eventTopic("OrderDescIdTooLow(uint256)"): 32,
        ABI.eventTopic("OrderDoesNotExist(uint256,uint256)"): 33,
        ABI.eventTopic("OrderForwardingNotAllowed()"): 34,
        ABI.eventTopic("OrderPostFailed(uint256)"): 36,
        ABI.eventTopic("OrderSettlementImpliesInsolvent(uint256,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256)"): 37,
        ABI.eventTopic("OrderSizeExceedsAvailableSize(uint256,uint256,uint256)"): 38,
        ABI.eventTopic("PostOrderUnderMinimum(uint256,uint256)"): 39,
        ABI.eventTopic("PriceOutOfRange(uint256,uint256)"): 40,
        ABI.eventTopic("RecycleBalanceInsufficientSevere(uint256,uint256,uint256,uint256,uint256)"): 41,
        ABI.eventTopic("UnableToCancelOrder(uint256,uint256)"): 45,
        ABI.eventTopic("UnspecifiedCollateral()"): 47,
        ABI.eventTopic("WrongAccountForOrder(uint256,uint256,uint256)"): 50,
        ABI.eventTopic("TriggerDescIdTooLow(uint256)"): 59,
        ABI.eventTopic("ValueExceedsMaximum(uint256,uint256)"): 61,
        ABI.eventTopic("PriceSetDuringTriggerExec(uint256)"): 63,
        ABI.eventTopic("OrderExtensionRejected(uint256,uint256)"): 69,
    ]

    public struct TakerFill: Sendable, Equatable {
        public let entryPricePNS: Int
        public let lotLNS: Int
        public let feeCNS: BigUInt

        public init(entryPricePNS: Int, lotLNS: Int, feeCNS: BigUInt) {
            self.entryPricePNS = entryPricePNS; self.lotLNS = lotLNS; self.feeCNS = feeCNS
        }
    }

    /// A change to the requesting account's own position (makers' changes inside the group are other accounts').
    public struct PositionChange: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case opened, increased, decreased, closed, inverted }
        public let kind: Kind
        public let isLong: Bool
        public let pricePNS: Int?
        public let endLotLNS: Int
        public let deltaPnlCNS: BigInt?
    }

    /// One request of the transaction and the events it caused.
    public struct Request: Sendable, Equatable {
        public let perpId: Int, accountId: Int, orderDescId: BigUInt, orderId: Int
        /// On-chain, 0-indexed: 0–3 orders (OpenLong, OpenShort, CloseLong, CloseShort), 4 Cancel,
        /// 5 IncreasePositionCollateral, 6 Change.
        public let orderType: Int
        public let pricePNS: Int, lotLNS: Int, postOnly: Bool, fillOrKill: Bool, immediateOrCancel: Bool, leverageHdths: Int
        public let transactionHash: Data
        public var takerFills: [TakerFill] = []
        public var iocUnmatchedLNS: Int?
        public var iocTotalLNS: Int?
        public var placedOrderId: Int?
        public var placedLotLNS: Int?
        public var cancelled = false
        public var collateralAddedCNS: BigUInt?
        /// This account's own position changes only.
        public var positionChanges: [PositionChange] = []
        /// The failure events inside the group, as `OrderStatusReason` codes.
        public var failureReasons: [Int] = []
        /// V1 fill / position / request events inside the group.
        public var legacyEvents = 0
        /// Known events whose data is shorter than their static head.
        public var unknownEvents = 0

        public var filledLotLNS: Int { takerFills.reduce(0) { $0 + $1.lotLNS } }
        /// Σ(lot × price) / Σ lot, rounded down.
        public var averagePricePNS: Int? {
            let filled = filledLotLNS
            guard filled > 0 else { return nil }
            let notional = takerFills.reduce(BigUInt(0)) { $0 + BigUInt($1.lotLNS) * BigUInt($1.entryPricePNS) }
            return Int(exactly: notional / BigUInt(filled))
        }
        public var feeCNS: BigUInt { takerFills.reduce(BigUInt(0)) { $0 + $1.feeCNS } }

        init(words w: Words, transactionHash: Data) {
            perpId = w.int(0); accountId = w.int(1); orderDescId = w.uint(2); orderId = w.int(3); orderType = w.int(4)
            pricePNS = w.int(5); lotLNS = w.int(6); postOnly = w.bool(8); fillOrKill = w.bool(9); immediateOrCancel = w.bool(10)
            leverageHdths = w.int(12)
            self.transactionHash = transactionHash
        }

        private var fill: PerplFillSummary {
            PerplFillSummary(filledSizeRaw: filledLotLNS, requestedSizeRaw: lotLNS, priceRaw: averagePricePNS,
                             feeCNS: String(feeCNS), txid: transactionHash.hexString)
        }

        /// Only an internally consistent group yields an outcome; everything else is nil ("couldn't be read").
        /// `.failed` is never read from a successful `revertOnFail: true` receipt: a refused request reverts it whole.
        public func outcome(revertOnFail: Bool) -> PerplOrderOutcome? {
            guard legacyEvents == 0, unknownEvents == 0 else { return nil }
            let filled = filledLotLNS
            switch orderType {
            case 0...3:
                if !failureReasons.isEmpty {
                    guard !revertOnFail, filled == 0, placedOrderId == nil, positionChanges.isEmpty else { return nil }
                    return .failed(PerplOrderReason(status: 7, reason: failureReasons[0]))
                }
                // A position changed and no fill could be read.
                if filled == 0, !positionChanges.isEmpty { return nil }
                if let unmatched = iocUnmatchedLNS, let total = iocTotalLNS {
                    guard filled == total - unmatched, placedOrderId == nil else { return nil }
                    if unmatched == total { return .notFilled(PerplOrderReason(status: 5, reason: 16)) }
                    return filled > 0 ? .partlyFilled(fill, rest: .cancelled(PerplOrderReason(status: 5, reason: 16))) : nil
                }
                if let placedOrderId {
                    guard let placedLotLNS, placedLotLNS + filled == lotLNS else { return nil }
                    return filled > 0 ? .partlyFilled(fill, rest: .resting(orderId: placedOrderId)) : .resting(orderId: placedOrderId)
                }
                return filled > 0 && filled == lotLNS ? .filled(fill) : nil
            case 4:
                if cancelled { return .cancelled(PerplOrderReason(status: 5, reason: 28)) }
                guard !revertOnFail, let first = failureReasons.first else { return nil }
                return .failed(PerplOrderReason(status: 7, reason: first))
            default:
                return nil
            }
        }
    }

    /// The Exchange's logs (by address, in log order) grouped per request. Defensive: an event shorter than its static
    /// head is counted in `unknownEvents`, never fatal; values above `Int.max` clamp.
    public static func decode(_ logs: [Log], exchange: Address = Perpl.exchange) -> [Request] {
        var out: [Request] = []
        var current: Request?
        for log in logs.filter({ $0.address == exchange }).sorted(by: { $0.logIndex < $1.logIndex }) {
            guard let topic = log.topics.first else { continue }
            let words = Words(log.data)
            if let head = Topic.headWords[topic], words.count < head {
                if topic == Topic.orderRequestV2 || topic == Topic.orderBatchCompleted {
                    // A request (or a batch's end) that can't be read: the group before it ends, and nothing after it
                    // is credited to that group.
                    if let request = current { out.append(request) }
                    current = nil
                } else {
                    current?.unknownEvents += 1
                }
                continue
            }
            if topic == Topic.orderRequestV2 {
                if let request = current { out.append(request) }
                current = Request(words: words, transactionHash: log.transactionHash)
                continue
            }
            if topic == Topic.orderBatchCompleted {
                if let request = current { out.append(request) }
                current = nil
                continue
            }
            guard var request = current else { continue }
            switch topic {
            case Topic.takerOrderFilledV2:
                request.takerFills.append(TakerFill(entryPricePNS: words.int(0), lotLNS: words.int(3), feeCNS: words.uint(4)))
            case Topic.immediateOrCancelExecuted:
                request.iocUnmatchedLNS = words.int(0)
                request.iocTotalLNS = words.int(1)
            case Topic.orderPlaced:
                request.placedOrderId = words.int(0)
                request.placedLotLNS = words.int(1)
            case Topic.orderCancelled:
                request.cancelled = true
            case Topic.increasePositionCollateral:
                if words.int(1) == request.accountId { request.collateralAddedCNS = words.uint(3) }
            case Topic.positionOpenedV2, Topic.positionIncreasedV2, Topic.positionDecreased, Topic.positionClosed, Topic.positionInverted:
                if words.int(1) == request.accountId, let change = positionChange(topic, words) { request.positionChanges.append(change) }
            default:
                if Topic.legacy.contains(topic) {
                    request.legacyEvents += 1
                } else if let reason = failureReasons[topic] {
                    request.failureReasons.append(reason)
                }
            }
            current = request
        }
        if let request = current { out.append(request) }
        return out
    }

    private static func positionChange(_ topic: Data, _ w: Words) -> PositionChange? {
        let isLong = w.int(2) == 0
        switch topic {
        case Topic.positionOpenedV2:
            return PositionChange(kind: .opened, isLong: isLong, pricePNS: w.int(6), endLotLNS: w.int(7), deltaPnlCNS: nil)
        case Topic.positionIncreasedV2:
            return PositionChange(kind: .increased, isLong: isLong, pricePNS: w.int(9), endLotLNS: w.int(11), deltaPnlCNS: nil)
        case Topic.positionDecreased:
            return PositionChange(kind: .decreased, isLong: isLong, pricePNS: nil, endLotLNS: w.int(6), deltaPnlCNS: w.signed(7))
        case Topic.positionClosed:
            return PositionChange(kind: .closed, isLong: isLong, pricePNS: w.int(3), endLotLNS: 0, deltaPnlCNS: w.signed(4))
        case Topic.positionInverted:
            return PositionChange(kind: .inverted, isLong: isLong, pricePNS: w.int(7), endLotLNS: w.int(9), deltaPnlCNS: w.signed(10))
        default:
            return nil
        }
    }

    /// The group `accountId` made: with `descId`, exactly that request; without, its only one (nil when it made several).
    public static func request(in requests: [Request], accountId: Int, descId: BigUInt?) -> Request? {
        let own = requests.filter { $0.accountId == accountId }
        if let descId { return own.first { $0.orderDescId == descId } }
        return own.count == 1 ? own[0] : nil
    }

    /// `execOrders(desc[], bool)` calldata → its desc ids and `revertOnFail`; nil when it isn't one.
    public static func plan(execOrdersCalldata data: Data) -> (descIds: [BigUInt], revertOnFail: Bool)? {
        guard data.count > 4, Data(data.prefix(4)) == ABI.selector(PerplExchange.Signature.execOrders),
              let values = try? ABI.decode(Data(data.dropFirst(4)), "\(PerplExchange.orderDescType)[],bool"), values.count == 2,
              case .array(let descs) = values[0], case .bool(let revertOnFail) = values[1] else { return nil }
        var ids: [BigUInt] = []
        for desc in descs {
            guard case .tuple(let fields) = desc, let id = fields.first?.uintOrNil else { return nil }
            ids.append(id)
        }
        return (ids, revertOnFail)
    }

    /// The desc id a plan's last step signs (its `execOrders` call's first desc), as `OrderDescIDs` issued it: what finds
    /// the plan's own request in its receipt. Nil when that step isn't an `execOrders` call. Read from the steps that are
    /// signed, never rebuilt: each build of a plan takes a new id.
    public static func descId(ofPlan steps: [TransactionStep]) -> UInt64? {
        guard let data = steps.last?.request?.data, let id = plan(execOrdersCalldata: data)?.descIds.first else { return nil }
        return UInt64(exactly: id)
    }

    /// A mined transaction's requests: up to `attempts` reads `interval` apart while the receipt reads back null or the
    /// read throws (a lagging node behind failover); nil when it never answered.
    public static func requests(ofTransaction hash: Data, rpc: RPCClient, attempts: Int = 3, interval: Duration = .milliseconds(300)) async throws -> [Request]? {
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { try await Task.sleep(for: interval) }
            if let logs = try? await rpc.transactionLogs(hash) { return decode(logs) }
        }
        return nil
    }

    /// What a wallet-signed ORDER (types 0–3) did in its own transaction: its request (the account's, with the desc id the
    /// plan signed; without one, the account's only request) decoded. Nil whenever that can't be said for certain: the
    /// receipt never read back, no such request, another kind of request, or a group that doesn't add up (I3) — "couldn't
    /// be read", never a guess. `revertOnFail` is the plan's (`plan(execOrdersCalldata:)`); the app's own plans are `true`,
    /// so a successful receipt never reads as `.failed` here.
    public static func orderOutcome(_ requests: [Request]?, accountId: Int, descId: BigUInt?, revertOnFail: Bool = true) -> PerplOrderOutcome? {
        guard let requests, let request = request(in: requests, accountId: accountId, descId: descId), (0...3).contains(request.orderType) else { return nil }
        return request.outcome(revertOnFail: revertOnFail)
    }

    /// The collateral a wallet-signed add-margin request (type 5) moved into the position, from its own
    /// `IncreasePositionCollateral` event; nil when the receipt never read back or no such event is the account's.
    public static func marginAdded(_ requests: [Request]?, accountId: Int, descId: BigUInt?) -> BigUInt? {
        guard let requests, let request = request(in: requests, accountId: accountId, descId: descId), request.orderType == 5,
              request.legacyEvents == 0, request.unknownEvents == 0 else { return nil }
        return request.collateralAddedCNS
    }

    /// Every order request (types 0–3) of the transaction matched nothing: there is at least one, each is `notFilled`,
    /// and none of them changed the account's own position.
    public static func allOrdersNotFilled(_ requests: [Request]) -> Bool {
        let orders = requests.filter { (0...3).contains($0.orderType) }
        return !orders.isEmpty && orders.allSatisfy { request in
            guard request.positionChanges.isEmpty, case .notFilled = request.outcome(revertOnFail: true) else { return false }
            return true
        }
    }

    /// An event's data as 32-byte words.
    struct Words {
        let data: Data
        init(_ data: Data) { self.data = Data(data) }
        var count: Int { data.count / 32 }
        func uint(_ index: Int) -> BigUInt {
            guard index >= 0, index < count else { return 0 }
            return BigUInt(data[(index * 32)..<((index + 1) * 32)])
        }
        /// Clamped to `Int.max`.
        func int(_ index: Int) -> Int { Int(exactly: uint(index)) ?? Int.max }
        func bool(_ index: Int) -> Bool { uint(index) != 0 }
        /// Two's complement.
        func signed(_ index: Int) -> BigInt {
            let value = uint(index)
            return value >> 255 != 0 ? BigInt(value) - (BigInt(1) << 256) : BigInt(value)
        }
    }
}
