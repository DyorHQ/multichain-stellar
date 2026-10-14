import BigInt
import Foundation

/* The payloads a passkey session signs without a prompt, read in full (security audit 2026-09-26, IOSK-10). A router
   call was prompt-free on its (to, selector) alone, so whatever its payload did — pay someone else, trade another token,
   run a sweep — went unread. Each decoder here accepts exactly the shape the app builds (`SwapCalldata`,
   `PerplExchange.orderDesc`) in its one canonical ABI encoding, and returns nil for anything else, which asks for Face
   ID: an extra command or action, another recipient, a stray offset, a dirty word, a trailing byte. */
extension Mera.SigningPolicy {
    /// A swap as its calldata runs it. Native MON is the zero address on either side; the output always goes to the
    /// account that signs the call (each decoder checks how).
    struct SwapTerms: Sendable, Equatable {
        let tokenIn: Address
        let tokenOut: Address
        let amountIn: BigUInt
        let minOut: BigUInt
    }

    /// `data` decoded as `types`, only when encoding the values again gives the same bytes.
    static func strictDecode(_ data: Data, _ types: String) -> [ABIValue]? {
        let data = Data(data)
        guard let values = try? ABI.decode(data, types), let again = try? ABI.encode(values, types), again == data else { return nil }
        return values
    }

    // MARK: Uniswap v4 (Universal Router)

    /// `execute(commands, inputs, deadline)` as `SwapCalldata.universalRouterV4` builds it: the single V4_SWAP command,
    /// whose actions are SWAP_EXACT_IN_SINGLE or SWAP_EXACT_IN with no hook data, then SETTLE_ALL of exactly the input
    /// (paid by the caller) and TAKE_ALL of the output with the swap's own minimum (paid to the caller). `value` is
    /// exactly the input when MON pays it, and zero otherwise: MON sent beyond what SETTLE_ALL takes would stay in the
    /// router, where anyone can sweep it.
    static func universalRouterSwap(_ data: Data, value: BigUInt) -> SwapTerms? {
        typealias V4 = SwapCalldata.V4
        guard data.prefix(4) == Selector.universalRouterExecute,
              let args = strictDecode(data.dropFirst(4), "bytes,bytes[],uint256"),
              args[0].bytes == Data([V4.swapCommand]), args[1].elements.count == 1,
              let input = strictDecode(args[1].elements[0].bytes, "bytes,bytes[]"), input[1].elements.count == 3 else { return nil }
        let params = input[1].elements.map(\.bytes)
        let terms: SwapTerms
        switch input[0].bytes {
        case Data([V4.swapExactInSingle, V4.settleAll, V4.takeAll]):
            guard let swap = strictDecode(params[0], "((address,address,uint24,int24,address),bool,uint128,uint128,bytes)")?.first,
                  swap[4].bytes.isEmpty else { return nil }
            let key = swap[0]
            let zeroForOne = swap[1].bool
            terms = SwapTerms(tokenIn: zeroForOne ? key[0].address : key[1].address, tokenOut: zeroForOne ? key[1].address : key[0].address,
                              amountIn: swap[2].uint, minOut: swap[3].uint)
        case Data([V4.swapExactIn, V4.settleAll, V4.takeAll]):
            guard let swap = strictDecode(params[0], "(address,(address,uint24,int24,address,bytes)[],uint128,uint128)")?.first,
                  let last = swap[1].elements.last, swap[1].elements.allSatisfy({ $0[4].bytes.isEmpty }) else { return nil }
            terms = SwapTerms(tokenIn: swap[0].address, tokenOut: last[0].address, amountIn: swap[2].uint, minOut: swap[3].uint)
        default:
            return nil
        }
        guard let settle = strictDecode(params[1], "address,uint256"), settle[0].address == terms.tokenIn, settle[1].uint == terms.amountIn,
              let take = strictDecode(params[2], "address,uint256"), take[0].address == terms.tokenOut, take[1].uint == terms.minOut,
              value == (terms.tokenIn.isZero ? terms.amountIn : 0) else { return nil }
        return terms
    }

    // MARK: Uniswap v3 (SwapRouter02) and Monday Trade

    /// `multicall(deadline, calls)` as `SwapCalldata.swapRouter02` builds it.
    static func swapRouter02Swap(_ data: Data, account: Address, value: BigUInt) -> SwapTerms? {
        guard data.prefix(4) == Selector.swapRouter02Multicall, let args = strictDecode(data.dropFirst(4), "uint256,bytes[]") else { return nil }
        return v3Swap(args[1].elements.map(\.bytes), monday: false, account: account, value: value)
    }

    /// `multicall(calls)` as `SwapCalldata.mondaySwap` builds it (the v1 router layout: the deadline inside the params).
    static func mondaySwap(_ data: Data, account: Address, value: BigUInt) -> SwapTerms? {
        guard data.prefix(4) == Selector.mondayMulticall, let args = strictDecode(data.dropFirst(4), "bytes[]") else { return nil }
        return v3Swap(args[0].elements.map(\.bytes), monday: true, account: account, value: value)
    }

    /// The v3 router calls, in the order the app builds them: one exact-input swap (single pool, or a packed path, with no
    /// price limit), then `unwrapWETH9(minOut, account)` when the output is MON — the swap paying the router itself —
    /// otherwise the swap paying the account; then `refundETH()` exactly when MON pays the input on `value`, which must
    /// be the whole input. Nothing else.
    private static func v3Swap(_ calls: [Data], monday: Bool, account: Address, value: BigUInt) -> SwapTerms? {
        guard let swap = calls.first else { return nil }
        let args = swap.dropFirst(4)
        var path: [Address]
        let recipient: Address, amountIn: BigUInt, minOut: BigUInt
        switch (monday, swap.prefix(4)) {
        case (false, Selector.swapRouter02ExactInputSingle):
            guard let p = strictDecode(args, "(address,address,uint24,address,uint256,uint256,uint160)")?.first, p[6].uint == 0 else { return nil }
            (path, recipient, amountIn, minOut) = ([p[0].address, p[1].address], p[3].address, p[4].uint, p[5].uint)
        case (false, Selector.swapRouter02ExactInput):
            guard let p = strictDecode(args, "(bytes,address,uint256,uint256)")?.first, let packed = packedPath(p[0].bytes) else { return nil }
            (path, recipient, amountIn, minOut) = (packed, p[1].address, p[2].uint, p[3].uint)
        case (true, Selector.mondayExactInputSingle):
            guard let p = strictDecode(args, "(address,address,uint24,address,uint256,uint256,uint256,uint160)")?.first, p[7].uint == 0 else { return nil }
            (path, recipient, amountIn, minOut) = ([p[0].address, p[1].address], p[3].address, p[5].uint, p[6].uint)
        case (true, Selector.mondayExactInput):
            guard let p = strictDecode(args, "(bytes,address,uint256,uint256,uint256)")?.first, let packed = packedPath(p[0].bytes) else { return nil }
            (path, recipient, amountIn, minOut) = (packed, p[1].address, p[3].uint, p[4].uint)
        default:
            return nil
        }
        var rest = calls.dropFirst()
        if let unwrap = rest.first, unwrap.prefix(4) == Selector.unwrapWETH9 {
            // SwapRouter02 names itself with ADDRESS_THIS; the v1 router reads address(0) as itself.
            guard recipient == (monday ? Address.zero : SwapCalldata.routerThis), path.last == Monad.wmon,
                  let u = strictDecode(unwrap.dropFirst(4), "uint256,address"), u[0].uint == minOut, u[1].address == account else { return nil }
            path[path.count - 1] = Monad.native
            rest = rest.dropFirst()
        } else if recipient != account {
            return nil
        }
        if rest.first == Selector.refundETH {
            guard value == amountIn, path.first == Monad.wmon else { return nil }
            path[0] = Monad.native
            rest = rest.dropFirst()
        } else if value != 0 {
            return nil
        }
        guard rest.isEmpty, let tokenIn = path.first, let tokenOut = path.last else { return nil }
        return SwapTerms(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, minOut: minOut)
    }

    /// The tokens of a packed v3 path, `address (uint24 address)+`, or nil when the bytes aren't that shape.
    static func packedPath(_ data: Data) -> [Address]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 43, (bytes.count - 20) % 23 == 0 else { return nil }
        return stride(from: 0, to: bytes.count, by: 23).compactMap { Address(data: Data(bytes[$0..<$0 + 20])) }
    }

    // MARK: Perpl

    /// `execOrders(descs, revertOnFail)` carrying exactly one desc that opens a position (OpenLong / OpenShort) with
    /// every field the app never sets at its default — no order id, expiry, fill-or-kill, match cap, execution block or
    /// collateral amount, and Perpl's default negative-PnL bound — as `PerplExchange.orderDesc` builds it. Returns that
    /// desc's terms; cancels, closes, margin moves and anything else are nil.
    static func perplOpenOrder(_ data: Data) -> Mera.Intent.OrderTerms? {
        guard data.prefix(4) == Selector.perplExecOrders,
              let args = strictDecode(data.dropFirst(4), "\(PerplExchange.orderDescType)[],bool"),
              args[0].elements.count == 1 else { return nil }
        let d = args[0].elements[0]
        let type = d[2].uint
        guard type == BigUInt(PerpOrderType.openLong.rawValue) || type == BigUInt(PerpOrderType.openShort.rawValue),
              d[3].uint == 0, d[6].uint == 0, !d[8].bool, d[10].uint == 0, d[12].uint == 0, d[13].uint == 0,
              d[14].uint == PerplExchange.maxNegPnlCollatBPS, d[4].uint > 0, d[5].uint > 0, d[11].uint > 0 else { return nil }
        return Mera.Intent.OrderTerms(perpId: d[1].uint, orderType: type, lotLNS: d[5].uint, leverageHdths: d[11].uint,
                                      price: d[4].uint, postOnly: d[7].bool, immediateOrCancel: d[9].bool)
    }
}
