import BigInt
import Foundation

/// A Uniswap-v3-style route: `path[i]` → `path[i + 1]` through fee tier `fees[i]`.
public struct V3Route: Hashable, Sendable {
    public let path: [Address]
    public let fees: [Int]

    public init(path: [Address], fees: [Int]) {
        self.path = path
        self.fees = fees
    }

    public var isSingleHop: Bool { fees.count == 1 }

    /// The packed `address (uint24 address)*` path QuoterV2 and the routers consume.
    public var packed: Data {
        var out = Data()
        for (i, token) in path.enumerated() {
            out.append(token.data)
            if i < fees.count { out.append(BigUInt(fees[i]).serialize().leftPadded(to: 3)) }
        }
        return out
    }
}

/// A Uniswap v4 pool key. `id` is what StateView and the quoter address pools by.
public struct PoolKey: Hashable, Sendable, Codable {
    public let currency0: Address
    public let currency1: Address
    public let fee: Int
    public let tickSpacing: Int
    public let hooks: Address

    public init(currency0: Address, currency1: Address, fee: Int, tickSpacing: Int, hooks: Address = .zero) {
        self.currency0 = currency0
        self.currency1 = currency1
        self.fee = fee
        self.tickSpacing = tickSpacing
        self.hooks = hooks
    }

    /// The hookless pool for an unordered pair; currencies are sorted numerically as the PoolManager requires.
    public static func canonical(_ a: Address, _ b: Address, fee: Int, tickSpacing: Int) -> PoolKey {
        let (c0, c1) = BigUInt(a.data) < BigUInt(b.data) ? (a, b) : (b, a)
        return PoolKey(currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: .zero)
    }

    public var isHookless: Bool { hooks.isZero }

    /// keccak256 of the ABI-encoded key.
    public var id: Data {
        var words = Data()
        words.append(currency0.data.leftPadded(to: 32))
        words.append(currency1.data.leftPadded(to: 32))
        words.append(BigUInt(fee).word)
        words.append(tickSpacing >= 0 ? BigUInt(tickSpacing).word : ((BigUInt(1) << 256) - BigUInt(-tickSpacing)).word)
        words.append(hooks.data.leftPadded(to: 32))
        return Keccak.hash256(words)
    }

    static let abiType: ABIType = .tuple([.address, .address, .uint(24), .int(24), .address])
    var abiValue: ABIValue { .tuple([.address(currency0), .address(currency1), .uint(fee), .int(tickSpacing), .address(hooks)]) }
}

/// One leg of a v4 route: the pool and the direction through it.
public struct V4Hop: Hashable, Sendable {
    public let key: PoolKey
    public let zeroForOne: Bool

    public init(key: PoolKey, zeroForOne: Bool) {
        self.key = key
        self.zeroForOne = zeroForOne
    }

    /// nil when `from` is on neither side of the pool.
    public init?(key: PoolKey, from: Address) {
        if key.currency0 == from { self.init(key: key, zeroForOne: true) } else if key.currency1 == from { self.init(key: key, zeroForOne: false) } else { return nil }
    }

    public var currencyIn: Address { zeroForOne ? key.currency0 : key.currency1 }
    public var currencyOut: Address { zeroForOne ? key.currency1 : key.currency0 }

    static let pathKeyType: ABIType = .tuple([.address, .uint(24), .int(24), .address, .bytes])
    /// `PathKey { intermediateCurrency, fee, tickSpacing, hooks, hookData }` with empty hook data.
    var pathKey: ABIValue { .tuple([.address(currencyOut), .uint(key.fee), .int(key.tickSpacing), .address(key.hooks), .bytes(Data())]) }
}

/// Calldata for every venue contract, byte-for-byte what the web app's viem builders produce (see SwapTests).
public enum SwapCalldata {
    public static let deadlineSeconds = 10 * 60
    public static let maxUint160 = (BigUInt(1) << 160) - 1
    /// How long an exact Permit2 allowance lives (`SwapRequest.exactApprovals`): set when its step is sent, and the
    /// swap is the very next transaction, so two minutes is ample — and a passkey session signs one only while the
    /// allowance ends before the session does.
    public static let exactPermit2Lifetime = 2 * 60
    /// SwapRouter02's `ADDRESS_THIS` recipient sentinel, used before `unwrapWETH9`.
    static let routerThis = Address(literal: "0x0000000000000000000000000000000000000002")

    enum V4 {
        static let swapCommand: UInt8 = 0x10
        static let swapExactInSingle: UInt8 = 0x06
        static let swapExactIn: UInt8 = 0x07
        static let settleAll: UInt8 = 0x0c
        static let takeAll: UInt8 = 0x0f
    }

    // MARK: Reads

    public static func v3GetPool(factory: Address, _ a: Address, _ b: Address, fee: Int) throws -> ContractCall {
        try ContractCall(to: factory, "getPool(address,address,uint24)", [.address(a), .address(b), .uint(fee)], returns: "address")
    }

    public static func v3Liquidity(pool: Address) throws -> ContractCall {
        try ContractCall(to: pool, "liquidity()", returns: "uint128")
    }

    public static func v3Slot0(pool: Address) throws -> ContractCall {
        try ContractCall(to: pool, "slot0()", returns: "uint160,int24,uint16,uint16,uint16,uint8,bool")
    }

    public static func v3Token0(pool: Address) throws -> ContractCall {
        try ContractCall(to: pool, "token0()", returns: "address")
    }

    // Uniswap v2-style reads (Nad.fun's DEX, where graduated Nad.fun memecoins keep their liquidity).
    public static func v2GetPair(factory: Address, _ a: Address, _ b: Address) throws -> ContractCall {
        try ContractCall(to: factory, "getPair(address,address)", [.address(a), .address(b)], returns: "address")
    }

    public static func v2GetReserves(pool: Address) throws -> ContractCall {
        try ContractCall(to: pool, "getReserves()", returns: "uint112,uint112,uint32")
    }

    /// QuoterV2 `quoteExactInputSingle` → (amountOut, sqrtPriceX96After, initializedTicksCrossed, gasEstimate).
    public static func quoteExactInputSingle(quoter: Address, tokenIn: Address, tokenOut: Address, amountIn: BigUInt, fee: Int) throws -> ContractCall {
        try ContractCall(to: quoter, "quoteExactInputSingle((address,address,uint256,uint24,uint160))",
                         [.tuple([.address(tokenIn), .address(tokenOut), .uint(amountIn), .uint(fee), .uint(0)])],
                         returns: "uint256,uint160,uint32,uint256")
    }

    /// QuoterV2 `quoteExactInput` → (amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate).
    public static func quoteExactInput(quoter: Address, route: V3Route, amountIn: BigUInt) throws -> ContractCall {
        try ContractCall(to: quoter, "quoteExactInput(bytes,uint256)", [.bytes(route.packed), .uint(amountIn)], returns: "uint256,uint160[],uint32[],uint256")
    }

    /// Whichever QuoterV2 function the route needs; `amountOut` is element 0 and `gasEstimate` element 3 either way.
    public static func quote(quoter: Address, route: V3Route, amountIn: BigUInt) throws -> ContractCall {
        guard route.path.count == route.fees.count + 1, !route.fees.isEmpty else { throw SwapError.malformedRoute }
        return route.isSingleHop
            ? try quoteExactInputSingle(quoter: quoter, tokenIn: route.path[0], tokenOut: route.path[1], amountIn: amountIn, fee: route.fees[0])
            : try quoteExactInput(quoter: quoter, route: route, amountIn: amountIn)
    }

    /// V4Quoter `quoteExactInputSingle` → (amountOut, gasEstimate).
    public static func v4QuoteExactInputSingle(hop: V4Hop, amountIn: BigUInt) throws -> ContractCall {
        try ContractCall(to: Uniswap.v4Quoter, "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
                         [.tuple([hop.key.abiValue, .bool(hop.zeroForOne), .uint(amountIn), .bytes(Data())])],
                         returns: "uint256,uint256")
    }

    /// V4Quoter `quoteExactInput` → (amountOut, gasEstimate).
    public static func v4QuoteExactInput(currencyIn: Address, hops: [V4Hop], amountIn: BigUInt) throws -> ContractCall {
        try ContractCall(to: Uniswap.v4Quoter, "quoteExactInput((address,(address,uint24,int24,address,bytes)[],uint128))",
                         [.tuple([.address(currencyIn), .array(hops.map(\.pathKey)), .uint(amountIn)])],
                         returns: "uint256,uint256")
    }

    public static func v4Quote(currencyIn: Address, hops: [V4Hop], amountIn: BigUInt) throws -> ContractCall {
        guard let first = hops.first else { throw SwapError.malformedRoute }
        return hops.count == 1 ? try v4QuoteExactInputSingle(hop: first, amountIn: amountIn) : try v4QuoteExactInput(currencyIn: currencyIn, hops: hops, amountIn: amountIn)
    }

    /// StateView `getSlot0` → (sqrtPriceX96, tick, protocolFee, lpFee).
    public static func stateViewSlot0(poolId: Data) throws -> ContractCall {
        try ContractCall(to: Uniswap.stateView, "getSlot0(bytes32)", [.bytes(poolId)], returns: "uint160,int24,uint24,uint24")
    }

    public static func stateViewLiquidity(poolId: Data) throws -> ContractCall {
        try ContractCall(to: Uniswap.stateView, "getLiquidity(bytes32)", [.bytes(poolId)], returns: "uint128")
    }

    /// Permit2 `allowance(owner, token, spender)` → (amount, expiration, nonce).
    public static func permit2Allowance(owner: Address, token: Address, spender: Address) throws -> ContractCall {
        try ContractCall(to: Uniswap.permit2, "allowance(address,address,address)", [.address(owner), .address(token), .address(spender)], returns: "uint160,uint48,uint48")
    }

    /// Launchpad factory `getLaunchedToken(token)`: the 17-field `Types.LaunchedToken` (`graduationVenue` is field 10,
    /// `phase` field 11, `exists` field 16). Only for factories with the current record, never the legacy 16-field one.
    public static func launchedToken(factory: Address, token: Address) throws -> ContractCall {
        try ContractCall(to: factory, "getLaunchedToken(address)", [.address(token)], returns: LaunchpadABI.launchedTokenTuple)
    }

    /// Whether a decoded `launchedToken` record is a launch whose pool sits on Uniswap v4: it exists, its phase is
    /// PoolCreated (2) and its graduation venue is UniswapV4 (0).
    static func graduatedOnV4(_ record: ABIValue) -> Bool {
        record[16].bool && record[11].uint == 2 && record[10].uint == 0
    }

    public static func launchpadPoolKey(factory: Address, token: Address) throws -> ContractCall {
        try ContractCall(to: factory, "poolKeyOf(address)", [.address(token)], returns: "(address,address,uint24,int24,address)")
    }
    /// Moments: the Moment id of a coin (0 when the address is not a Moment coin).
    public static func momentIdByCoin(factory: Address, coin: Address) throws -> ContractCall {
        try ContractCall(to: factory, "momentIdByCoin(address)", [.address(coin)], returns: "uint256")
    }
    /// Moments: the graduated pool key of a Moment (reverts while it has no pool).
    public static func momentsPoolKey(graduation: Address, momentId: BigUInt) throws -> ContractCall {
        try ContractCall(to: graduation, "poolKeyOf(uint256)", [.uint(momentId)], returns: "(address,address,uint24,int24,address)")
    }

    // MARK: Uniswap SwapRouter02 (no deadline in the params; `multicall(deadline, data)` instead)

    public static func swapRouter02ExactInputSingle(route: V3Route, amountIn: BigUInt, minOut: BigUInt, recipient: Address) throws -> Data {
        guard route.path.count >= 2, let fee = route.fees.first else { throw SwapError.malformedRoute }
        try SwapEngine.ensureTradable(route.path)
        return try ABI.encodeCall("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
                                  [.tuple([.address(route.path[0]), .address(route.path[1]), .uint(fee), .address(recipient), .uint(amountIn), .uint(minOut), .uint(0)])])
    }

    public static func swapRouter02ExactInput(route: V3Route, amountIn: BigUInt, minOut: BigUInt, recipient: Address) throws -> Data {
        try SwapEngine.ensureTradable(route.path)
        return try ABI.encodeCall("exactInput((bytes,address,uint256,uint256))", [.tuple([.bytes(route.packed), .address(recipient), .uint(amountIn), .uint(minOut)])])
    }

    /// The full SwapRouter02 transaction: native MON in rides on `value` (with `refundETH`), native out goes
    /// through `unwrapWETH9` with the router itself as the swap recipient.
    public static func swapRouter02(route: V3Route, amountIn: BigUInt, minOut: BigUInt, account: Address, nativeIn: Bool, nativeOut: Bool, deadline: BigUInt) throws -> TransactionRequest {
        let recipient = nativeOut ? routerThis : account
        var calls: [Data] = [route.isSingleHop
            ? try swapRouter02ExactInputSingle(route: route, amountIn: amountIn, minOut: minOut, recipient: recipient)
            : try swapRouter02ExactInput(route: route, amountIn: amountIn, minOut: minOut, recipient: recipient)]
        if nativeOut { calls.append(try ABI.encodeCall("unwrapWETH9(uint256,address)", [.uint(minOut), .address(account)])) }
        if nativeIn { calls.append(try ABI.encodeCall("refundETH()")) }
        let data = try ABI.encodeCall("multicall(uint256,bytes[])", [.uint(deadline), .array(calls.map { .bytes($0) })])
        return TransactionRequest(to: Uniswap.swapRouter02, data: data, value: nativeIn ? amountIn : 0)
    }

    // MARK: Monday Trade SwapRouter (Uniswap v3 SwapRouter v1 layout: deadline inside the params)

    public static func mondayExactInputSingle(route: V3Route, amountIn: BigUInt, minOut: BigUInt, recipient: Address, deadline: BigUInt) throws -> Data {
        guard route.path.count >= 2, let fee = route.fees.first else { throw SwapError.malformedRoute }
        try SwapEngine.ensureTradable(route.path)
        return try ABI.encodeCall("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
                                  [.tuple([.address(route.path[0]), .address(route.path[1]), .uint(fee), .address(recipient), .uint(deadline), .uint(amountIn), .uint(minOut), .uint(0)])])
    }

    public static func mondayExactInput(route: V3Route, amountIn: BigUInt, minOut: BigUInt, recipient: Address, deadline: BigUInt) throws -> Data {
        try SwapEngine.ensureTradable(route.path)
        return try ABI.encodeCall("exactInput((bytes,address,uint256,uint256,uint256))", [.tuple([.bytes(route.packed), .address(recipient), .uint(deadline), .uint(amountIn), .uint(minOut)])])
    }

    /// The v1 router treats recipient address(0) as itself, which is what `unwrapWETH9` needs afterwards.
    public static func mondaySwap(route: V3Route, amountIn: BigUInt, minOut: BigUInt, account: Address, nativeIn: Bool, nativeOut: Bool, deadline: BigUInt) throws -> TransactionRequest {
        let recipient = nativeOut ? Address.zero : account
        var calls: [Data] = [route.isSingleHop
            ? try mondayExactInputSingle(route: route, amountIn: amountIn, minOut: minOut, recipient: recipient, deadline: deadline)
            : try mondayExactInput(route: route, amountIn: amountIn, minOut: minOut, recipient: recipient, deadline: deadline)]
        if nativeOut { calls.append(try ABI.encodeCall("unwrapWETH9(uint256,address)", [.uint(minOut), .address(account)])) }
        if nativeIn { calls.append(try ABI.encodeCall("refundETH()")) }
        let data = try ABI.encodeCall("multicall(bytes[])", [.array(calls.map { .bytes($0) })])
        return TransactionRequest(to: MondayTrade.swapRouter, data: data, value: nativeIn ? amountIn : 0)
    }

    // MARK: Uniswap v4 through the Universal Router

    /// `execute(V4_SWAP)` with actions `SWAP_EXACT_IN(_SINGLE)`, `SETTLE_ALL`, `TAKE_ALL`. Native MON in rides on
    /// `value`; ERC-20 input is pulled through Permit2.
    public static func universalRouterV4(currencyIn: Address, currencyOut: Address, hops: [V4Hop], amountIn: BigUInt, minOut: BigUInt, deadline: BigUInt) throws -> TransactionRequest {
        guard let first = hops.first else { throw SwapError.malformedRoute }
        guard amountIn.bitWidth <= 128, minOut.bitWidth <= 128 else { throw SwapError.amountTooLarge }
        // Never encode a swap through a retired Moments cohort's coin or pool, whatever route was chosen.
        try SwapEngine.ensureTradable([currencyIn, currencyOut] + hops.flatMap { [$0.key.currency0, $0.key.currency1, $0.key.hooks] })
        let swap: Data
        if hops.count == 1 {
            swap = try ABI.encode([.tuple([first.key.abiValue, .bool(first.zeroForOne), .uint(amountIn), .uint(minOut), .bytes(Data())])],
                                  [.tuple([PoolKey.abiType, .bool, .uint(128), .uint(128), .bytes])])
        } else {
            swap = try ABI.encode([.tuple([.address(currencyIn), .array(hops.map(\.pathKey)), .uint(amountIn), .uint(minOut)])],
                                  [.tuple([.address, .array(V4Hop.pathKeyType), .uint(128), .uint(128)])])
        }
        let actions = Data([hops.count == 1 ? V4.swapExactInSingle : V4.swapExactIn, V4.settleAll, V4.takeAll])
        let params: [Data] = [
            swap,
            try ABI.encode([.address(currencyIn), .uint(amountIn)], "address,uint256"),
            try ABI.encode([.address(currencyOut), .uint(minOut)], "address,uint256"),
        ]
        let input = try ABI.encode([.bytes(actions), .array(params.map { .bytes($0) })], "bytes,bytes[]")
        let data = try ABI.encodeCall("execute(bytes,bytes[],uint256)", [.bytes(Data([V4.swapCommand])), .array([.bytes(input)]), .uint(deadline)])
        return TransactionRequest(to: Uniswap.universalRouter, data: data, value: currencyIn.isZero ? amountIn : 0)
    }

    // MARK: Permit2 and WMON

    public static func permit2Approve(token: Address, spender: Address, amount: BigUInt, expiration: BigUInt) throws -> Data {
        guard amount.bitWidth <= 160 else { throw SwapError.amountTooLarge }
        return try ABI.encodeCall("approve(address,address,uint160,uint48)", [.address(token), .address(spender), .uint(amount), .uint(expiration)])
    }

    public static func wmonDeposit() throws -> Data { try ABI.encodeCall("deposit()") }

    public static func wmonWithdraw(amount: BigUInt) throws -> Data { try ABI.encodeCall("withdraw(uint256)", [.uint(amount)]) }
}
