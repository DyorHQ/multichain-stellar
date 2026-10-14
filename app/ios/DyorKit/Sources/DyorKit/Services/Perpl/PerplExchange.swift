import BigInt
import Foundation

/// Calldata builders, return-data decoders and the number conventions of Perpl's Exchange contract. Function
/// shapes come from the Exchange ABI in the web repository (app/lib/perps/abi.ts, generated from
/// github.com/PerplFoundation/dex-sdk); the tests compare every builder against viem byte for byte.
enum PerplExchange {
    static let address = Perpl.exchange
    /// Perpl's default for new orders (context.order_max_neg_pnl_collat_bps).
    static let maxNegPnlCollatBPS: BigUInt = 300
    /// `getOrder` reads per multicall when walking a market's order index.
    static let orderChunkSize = 250
    /// Custom error the Exchange raises from `getAccountByAddr` for addresses that never deposited.
    static let accountNotFoundSelector = "0x03a0e277" // AccountNotFound(address)

    static let orderDescType = "(uint256,uint256,uint8,uint256,uint256,uint256,uint256,bool,bool,bool,uint256,uint256,uint256,uint256,uint256)"

    enum Signature {
        static let createAccount = "createAccount(uint256)"
        static let depositCollateral = "depositCollateral(uint256)"
        static let withdrawCollateral = "withdrawCollateral(uint256)"
        static let execOrders = "execOrders(\(PerplExchange.orderDescType)[],bool)"
        static let getPerpetualInfo = "getPerpetualInfo(uint256)"
        static let getMarginFractions = "getMarginFractions(uint256,uint256)"
        static let getAccountByAddr = "getAccountByAddr(address)"
        static let getPosition = "getPosition(uint256,uint256)"
        static let getPerpOrderLocks = "getPerpOrderLocks(uint256,uint256)"
        static let getOrderIdIndex = "getOrderIdIndex(uint256)"
        static let getOrder = "getOrder(uint256,uint256)"
    }

    enum Returns {
        // name, symbol, priceDecimals, lotDecimals, linkFeedId, priceTolPer100K, marginTol, marginTolDecimals, refPriceMaxAgeSec,
        // positionBalanceCNS, insuranceBalanceCNS, markPNS, markTimestamp, lastPNS, lastTimestamp, oraclePNS, oracleTimestampSec,
        // longOpenInterestLNS, shortOpenInterestLNS, fundingStartBlock, fundingRatePct100k, absFundingClampPctPer100K, status,
        // basePricePNS, maxBidPriceONS, minBidPriceONS, maxAskPriceONS, minAskPriceONS, numOrders, ignOracle
        static let perpetualInfo = "(string,string,uint256,uint256,bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,int16,uint256,uint8,uint256,uint256,uint256,uint256,uint256,uint256,bool)"
        static let marginFractions = "uint256,uint256,uint256,uint256,uint256,uint256"
        // accountId, balanceCNS, lockedBalanceCNS, frozen, accountAddr, positions(bank1, bank2, bank3, bank4)
        static let account = "(uint256,uint256,uint256,uint8,address,(uint256,uint256,uint256,uint256))"
        // positionInfo(accountId, nextNodeId, prevNodeId, positionType, depositCNS, pricePNS, lotLNS, entryBlock, pnlCNS, deltaPnlCNS, premiumPnlCNS), markPricePNS, markPriceValid
        static let position = "(uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,int256,int256,int256),uint256,bool"
        // orderLockId, nextOrderLockId, prevOrderLockId, orderType, lotLNS, amountCNS
        static let orderLocks = "(uint32,uint32,uint32,uint8,uint40,uint80)[]"
        static let orderIdIndex = "uint256,uint256[],uint256"
        // accountId, orderType, priceONS, lotLNS, recycleFeeRaw, expiryBlock, leverageHdths, orderId, prevOrderId, nextOrderId, maxNegPnlCollatBPS
        static let order = "(uint32,uint8,uint24,uint40,uint16,uint32,uint16,uint16,uint16,uint16,uint16)"
    }

    // MARK: Calls

    /// Signatures and argument shapes are fixed at compile time, so an encoding failure is a programming error
    /// rather than something the app can recover from at run time.
    static func calldata(_ signature: String, _ args: [ABIValue]) -> Data {
        do {
            return try ABI.encodeCall(signature, args)
        } catch {
            preconditionFailure("Perpl calldata for \(signature): \(error)")
        }
    }

    static func read(_ signature: String, _ args: [ABIValue], returns: String) -> ContractCall {
        do {
            return try ContractCall(to: address, signature, args, returns: returns)
        } catch {
            preconditionFailure("Perpl read \(signature): \(error)")
        }
    }

    static func execOrdersCalldata(_ descs: [[ABIValue]], revertOnFail: Bool) -> Data {
        calldata(Signature.execOrders, [.array(descs.map { .tuple($0) }), .bool(revertOnFail)])
    }

    /// Only Perpl's own `AccountNotFound(address)` revert means "no account" (RI-4). A revert with another error, or a
    /// bare "execution reverted" from a node that drops the revert data, is a failed read: taken as "no account", it
    /// would plan a second `createAccount` (and a MON → AUSD swap ahead of it) for an account that exists.
    static func isAccountNotFound(_ error: RPCError) -> Bool {
        guard let data = error.data else { return false }
        return data.lowercased().hasPrefix(accountNotFoundSelector)
    }

    // MARK: Order descriptions

    static func orderDesc(_ input: OrderInput, descId: BigUInt) -> [ABIValue] {
        let perp = input.market
        let type: PerpOrderType
        switch (input.side, input.reduceOnly) {
        case (.long, true): type = .closeShort
        case (.long, false): type = .openLong
        case (.short, true): type = .closeLong
        case (.short, false): type = .openShort
        }
        let slip = Double(input.slippageBps) / 10_000
        let price: Double
        // A zero or NaN limit price falls back to the mark, as the web app's truthiness check does.
        if input.kind == .limit, let limit = input.price, limit != 0, !limit.isNaN {
            price = limit
        } else {
            price = input.side == .long ? perp.mark * (1 + slip) : perp.mark * (1 - slip)
        }
        return [
            .uint(descId),
            .uint(perp.id),
            .uint(type.rawValue),
            .uint(0), // orderId
            .uint(units(price, decimals: perp.priceDecimals)),
            .uint(units(input.size, decimals: perp.lotDecimals)),
            .uint(0), // expiryBlock
            .bool(input.postOnly && input.kind == .limit),
            .bool(false), // fillOrKill
            .bool(input.kind == .market), // immediateOrCancel
            .uint(0), // maxMatches
            .uint(units(input.leverage, decimals: 2)), // leverageHdths
            .uint(0), // lastExecutionBlock
            .uint(0), // amountCNS
            .uint(maxNegPnlCollatBPS),
        ]
    }

    static func cancelDesc(perpId: Int, orderId: Int, descId: BigUInt) -> [ABIValue] {
        [
            .uint(descId), .uint(perpId), .uint(PerpOrderType.cancel.rawValue), .uint(orderId), .uint(0), .uint(0), .uint(0),
            .bool(false), .bool(false), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0),
        ]
    }

    /// Adds `amountCNS` (AUSD, 6 decimals) of collateral to the account's open position on `perpId`. The Exchange
    /// has no dedicated method — `execOrders` carries it as an `IncreasePositionCollateral` desc whose only live
    /// field is `amountCNS` (index 13); everything else stays zero.
    static func addMarginDesc(perpId: Int, amountCNS: BigUInt, descId: BigUInt) -> [ABIValue] {
        [
            .uint(descId), .uint(perpId), .uint(PerpOrderType.increasePositionCollateral.rawValue), .uint(0), .uint(0), .uint(0), .uint(0),
            .bool(false), .bool(false), .bool(false), .uint(0), .uint(0), .uint(0), .uint(amountCNS), .uint(0),
        ]
    }

    // MARK: Decoding

    static func market(id: Int, info p: ABIValue, margins m: [ABIValue]?) -> PerpMarket {
        let priceDecimals = int(p[2].uint)
        let lotDecimals = int(p[3].uint)
        // Margin requirement = notional / (value / 100): MON's 1000 / 2000 mean 10% initial and 5% maintenance.
        let initial = m.map { $0[0].uint }
        let maintenance = m.map { $0[1].uint }
        return PerpMarket(
            id: id,
            symbol: p[1].string,
            name: PerplService.markets.first { $0.id == id }?.name ?? p[0].string,
            priceDecimals: priceDecimals,
            lotDecimals: lotDecimals,
            basePricePNS: p[23].uint,
            mark: scale(p[11].uint, decimals: priceDecimals),
            last: scale(p[13].uint, decimals: priceDecimals),
            oracle: scale(p[15].uint, decimals: priceDecimals),
            markTimestamp: int(p[12].uint),
            longOI: scale(p[17].uint, decimals: lotDecimals),
            shortOI: scale(p[18].uint, decimals: lotDecimals),
            fundingRatePct100k: Int(clamping: p[20].int),
            status: int(p[22].uint),
            // Nil when the read failed or reported no divisor: never a guess. A guessed 5% maintenance would understate
            // the risk on the 10% markets (LIT, VVV, TAO, PUMP), so the liquidation price shows as unknown instead.
            initMarginFraction: initial.flatMap { $0 > 0 ? 100 / Double($0) : nil },
            maintMarginFraction: maintenance.flatMap { $0 > 0 ? 100 / Double($0) : nil },
            numOrders: int(p[28].uint),
            fundingStartBlock: UInt64(clamping: p[19].uint),
            fundingClampPct100k: int(p[21].uint)
        )
    }

    static func account(_ a: ABIValue) -> PerpAccount? {
        let accountId = a[0].uint
        if accountId == 0 { return nil }
        let banks = a[5]
        return PerpAccount(
            accountId: int(accountId),
            balance: a[1].uint,
            locked: a[2].uint,
            frozen: a[3].uint != 0,
            positionPerpIds: perpIds(bank1: banks[0].uint, bank2: banks[1].uint, bank3: banks[2].uint, bank4: banks[3].uint)
        )
    }

    /// Perpetual ids the account's position bitmap marks as open: bank1 holds perps 0–252, the later 256-bit
    /// banks continue from 253, 509 and 765.
    static func perpIds(bank1: BigUInt, bank2: BigUInt, bank3: BigUInt, bank4: BigUInt) -> [Int] {
        let banks: [(offset: Int, bank: BigUInt, bits: Int)] = [(0, bank1, 253), (253, bank2, 256), (509, bank3, 256), (765, bank4, 256)]
        var ids: [Int] = []
        for (offset, bank, bits) in banks where bank != 0 {
            for i in 0..<bits where (bank >> i) & 1 == 1 { ids.append(offset + i) }
        }
        return ids
    }

    /// Order ids from a market's order-id index leaves. Order id 0 is never used, so leaf 0 starts at bit 1.
    static func orderIds(leaves: [BigUInt]) -> [Int] {
        var ids: [Int] = []
        for (leaf, bitmap) in leaves.enumerated() where bitmap != 0 {
            for bit in (leaf == 0 ? 1 : 0)..<256 where (bitmap >> bit) & 1 == 1 { ids.append(leaf * 256 + bit) }
        }
        return ids
    }

    /// Nil when the slot holds no position (zero lot).
    static func position(perp: PerpMarket, values: [ABIValue]) -> PerpPosition? {
        let pos = values[0]
        let markPNS = values[1].uint
        let lotLNS = pos[6].uint
        if lotLNS == 0 { return nil }
        let size = scale(lotLNS, decimals: perp.lotDecimals)
        let entry = scale(pos[5].uint, decimals: perp.priceDecimals)
        let mark = markPNS > 0 ? scale(markPNS, decimals: perp.priceDecimals) : perp.mark
        let side: PositionSide = pos[3].uint == 0 ? .long : .short
        let margin = fromCNS(pos[4].uint)
        let premium = fromCNS(pos[10].int)
        let unrealized = (side == .long ? mark - entry : entry - mark) * size + premium
        let notional = size * mark
        return PerpPosition(
            perpId: perp.id,
            symbol: perp.symbol,
            side: side,
            size: size,
            entry: entry,
            mark: mark,
            margin: margin,
            unrealized: unrealized,
            premium: premium,
            leverage: margin > 0 ? notional / margin : 0,
            liquidation: liquidationPrice(side: side, entry: entry, size: size, margin: margin, premium: premium, maintenanceFraction: perp.maintMarginFraction),
            notional: notional
        )
    }

    /// The order's owner and, when its type is one the app models, the order itself.
    static func order(perp: PerpMarket, orderId: Int, values o: ABIValue) -> (accountId: Int, order: PerpOrder?) {
        let accountId = int(o[0].uint)
        guard let type = PerpOrderType(rawValue: int(o[1].uint)) else { return (accountId, nil) }
        let order = PerpOrder(
            perpId: perp.id,
            orderId: orderId,
            symbol: perp.symbol,
            type: type,
            side: type == .openLong || type == .closeShort ? .buy : .sell,
            price: scale(perp.basePricePNS + o[2].uint, decimals: perp.priceDecimals),
            size: scale(o[3].uint, decimals: perp.lotDecimals),
            leverage: Double(o[6].uint) / 100,
            expiryBlock: int(o[5].uint),
            reduceOnly: type == .closeLong || type == .closeShort
        )
        return (accountId, order)
    }

    static func liquidationPrice(side: PositionSide, entry: Double, size: Double, margin: Double, premium: Double, maintenanceFraction: Double?) -> Double? {
        guard size > 0, let maintenanceFraction, maintenanceFraction > 0 else { return nil }
        let mmr = entry * size * maintenanceFraction
        let sign: Double = side == .long ? 1 : -1
        return max(0, entry + (sign * (mmr - margin - premium)) / size)
    }

    // MARK: Numbers

    static func scale(_ value: BigUInt, decimals: Int) -> Double {
        Double(value) / pow(10, Double(decimals))
    }

    static func fromCNS(_ value: BigUInt) -> Double {
        scale(value, decimals: Perpl.collateralDecimals)
    }

    static func fromCNS(_ value: BigInt) -> Double {
        Double(value) / pow(10, Double(Perpl.collateralDecimals))
    }

    static func toCNS(_ value: Double) -> BigUInt {
        units(value, decimals: Perpl.collateralDecimals)
    }

    /// `BigInt(Math.round(value * 10 ** decimals))` as the web app computes it. Negative or non-finite input
    /// yields zero, which the contract rejects, rather than trapping.
    static func units(_ value: Double, decimals: Int) -> BigUInt {
        BigUInt(exactly: jsRound(value * pow(10, Double(decimals)))) ?? 0
    }

    /// JavaScript `Math.round`: halves round toward positive infinity, unlike Swift's `rounded()`.
    static func jsRound(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let floor = x.rounded(.down)
        return x - floor >= 0.5 ? floor + 1 : floor
    }

    /// `Number(bigint)` for fields that are counts, ids, timestamps and flags.
    static func int(_ value: BigUInt) -> Int {
        Int(clamping: value)
    }
}

/// Strictly increasing `orderDescId`s, seeded from the wall clock in milliseconds like the web app, so two
/// descriptions built in the same millisecond never collide.
final class OrderDescIDs: @unchecked Sendable {
    static let shared = OrderDescIDs()

    private let lock = NSLock()
    private var last: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        last = now > last ? now : last + 1
        return last
    }
}
