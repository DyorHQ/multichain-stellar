import BigInt
import XCTest
@testable import DyorKit

/// The session scope in MERA-PLAN §3: a table of plans the live session signs on its own (each app flow's real calldata
/// shape) and a table of plans that must ask — every always-ask class and every violation of the wallet's own check or
/// the caps. Plus the network-fee bound, the Kuru Flow decoder, the wallet-auth message template, the run-time Permit2
/// step, and the on-chain curve lookup.
final class MeraPolicyTests: XCTestCase {
    typealias Policy = Mera.SigningPolicy
    typealias Intent = Mera.Intent

    let account = Address(literal: "0x1111111111111111111111111111111111111111")
    let stranger = Address(literal: "0x2222222222222222222222222222222222222222")
    let launchToken = Address(literal: "0x3333333333333333333333333333333333333333")
    let curve = Address(literal: "0x4444444444444444444444444444444444444444")
    let erc20Pair = Address(literal: "0x5555555555555555555555555555555555555555")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var expiresAt: Date { now.addingTimeInterval(15 * 60) }
    var unix: Int { Int(now.timeIntervalSince1970) }
    /// The live (v2) Moments cohort. `MomentsAddresses.monadMainnet` is all zero until the owner deploys v2, so the
    /// session context here is built on a v2 fixture (`testMainnetContractsWhileV2IsPending` covers the pending table).
    let moments = V2Fixture.moments
    let cohort3 = MomentsAddresses.retiredMainnet[0]
    let usdcIn = BigUInt(50_000_000) // 50 USDC
    let monIn = BigUInt(10).power(18) * 10 // 10 MON

    private var context: Policy.Context {
        Policy.Context(account: account, expiresAt: expiresAt, contracts: Policy.Contracts(moments: moments), verifiedCurves: [launchToken: curve])
    }

    // MARK: Builders

    private func call(_ to: Address, _ data: Data, value: BigUInt = 0, from: Address? = nil, chainId: Int = 143) -> Policy.Call {
        Policy.Call(from: from ?? account, to: to, data: data, value: value, chainId: chainId)
    }

    private func encode(_ signature: String, _ args: [ABIValue] = []) -> Data { try! ABI.encodeCall(signature, args) }

    private func approve(_ token: Address, _ spender: Address, _ amount: BigUInt, value: BigUInt = 0) -> Policy.Call {
        call(token, encode("approve(address,uint256)", [.address(spender), .uint(amount)]), value: value)
    }

    private func permit2(_ token: Address, _ amount: BigUInt, spender: Address = Uniswap.universalRouter, expiration: Int) -> Policy.Call {
        call(Uniswap.permit2, try! SwapCalldata.permit2Approve(token: token, spender: spender, amount: amount, expiration: BigUInt(expiration)))
    }

    /// Universal Router calldata as the app builds it (`SwapCalldata.universalRouterV4`): `amountIn` of `tokenIn` for at
    /// least `minOut` of `tokenOut`, through one canonical v4 pool, or `via` a second one.
    private func urSwap(_ tokenIn: Address, _ amountIn: BigUInt, _ tokenOut: Address, minOut: BigUInt = 990_000, via: Address? = nil) -> Data {
        var hops = [V4Hop(key: PoolKey.canonical(tokenIn, via ?? tokenOut, fee: 500, tickSpacing: 10), from: tokenIn)!]
        if let via { hops.append(V4Hop(key: PoolKey.canonical(via, tokenOut, fee: 3000, tickSpacing: 60), from: via)!) }
        return try! SwapCalldata.universalRouterV4(currencyIn: tokenIn, currencyOut: tokenOut, hops: hops, amountIn: amountIn, minOut: minOut, deadline: BigUInt(unix + 600)).data
    }

    /// USDC → MON, matching `swapIntent(.uniswap, pay: usdc, usdcIn)` (1,000,000 out, so a 99% minimum of 990,000).
    private var universalRouterSwap: Data { urSwap(usdc, usdcIn, Monad.native) }
    /// MON on `value` → USDC, matching `swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)`.
    private var monSwap: Data { urSwap(Monad.native, monIn, usdc) }

    /// A v3 route through SwapRouter02 (`SwapCalldata.swapRouter02`), or through Monday Trade's router.
    private func v3Swap(_ path: [Address], _ amountIn: BigUInt, minOut: BigUInt = 990_000, nativeIn: Bool = false, nativeOut: Bool = false, monday: Bool = false) -> TransactionRequest {
        let route = V3Route(path: path, fees: Array(repeating: 500, count: path.count - 1))
        return monday
            ? try! SwapCalldata.mondaySwap(route: route, amountIn: amountIn, minOut: minOut, account: account, nativeIn: nativeIn, nativeOut: nativeOut, deadline: BigUInt(unix + 600))
            : try! SwapCalldata.swapRouter02(route: route, amountIn: amountIn, minOut: minOut, account: account, nativeIn: nativeIn, nativeOut: nativeOut, deadline: BigUInt(unix + 600))
    }

    private func call(_ request: TransactionRequest) -> Policy.Call { call(request.to, request.data, value: request.value) }

    /// KuruFlowEntrypoint calldata in the layout read from its bytecode; `recipient` picks the explicit-recipient variant.
    private func kuru(tokenIn: Address, amountIn: BigUInt, tokenOut: Address, minOut: BigUInt, recipient: Address? = nil,
                      fee: [ABIValue]? = nil) -> Data {
        var args: [ABIValue] = [.address(tokenOut), .uint(minOut), .address(tokenIn), .uint(amountIn),
                                .tuple(fee ?? [.address(stranger), .uint(0), .address(.zero), .uint(0), .bool(true)]), .bytes(Data([0x02, 0x01, 0xff]))]
        var types = "address,uint256,address,uint256,(address,uint256,address,uint256,bool),bytes"
        if let recipient { args.append(.address(recipient)); types += ",address" }
        let selector = recipient == nil ? KuruFlowSwap.payCaller : KuruFlowSwap.payRecipient
        return selector + (try! ABI.encode(args, types))
    }

    private func curveCall(_ signature: String, _ amount: BigUInt, recipient: Address? = nil, value: BigUInt = 0, to: Address? = nil) -> Policy.Call {
        call(to ?? curve, encode(signature, [.uint(amount), .uint(1), .address(recipient ?? account)]), value: value)
    }

    /// An `execOrders` desc of `type` (0 OpenLong, 1 OpenShort, 2/3 Close, 4 Cancel, 5 IncreasePositionCollateral) on
    /// market 16, 10 lots at 5×, with the app's defaults; `change` edits one field (by index) first.
    private func perplOrders(_ types: [Int], change: (Int, ABIValue)? = nil) -> Policy.Call {
        let descs: [[ABIValue]] = types.enumerated().map { i, type in
            var desc: [ABIValue] = [.uint(i + 1), .uint(16), .uint(type), .uint(0), .uint(100), .uint(10), .uint(0), .bool(false), .bool(false), .bool(true), .uint(0), .uint(500), .uint(0), .uint(0), .uint(300)]
            if let change { desc[change.0] = change.1 }
            return desc
        }
        return call(Perpl.exchange, PerplExchange.execOrdersCalldata(descs, revertOnFail: true))
    }

    /// The order `perplOrders` builds, as a sheet declares it.
    private func perplIntent(_ type: Int = 0, lots: BigUInt = 10, leverage: BigUInt = 500, price: BigUInt = 100, usd: Double? = 80) -> Intent {
        .perplOrder(usd: usd, order: .init(perpId: 16, orderType: BigUInt(type), lotLNS: lots, leverageHdths: leverage, price: price, postOnly: false, immediateOrCancel: true))
    }

    private var usdc: Address { Monad.usdc }
    private func swapIntent(_ venue: Venue, pay: Address, _ amount: BigUInt, receive: Address = Monad.native, out: BigUInt = 1_000_000, usd: Double? = 50) -> Intent {
        .swap(venue: venue, pay: .init(token: pay, amount: amount), receive: .init(token: receive, amount: out), usd: usd)
    }

    private func review(_ calls: [Policy.Call], _ intent: Intent, caps: Mera.SpendingCaps = Mera.SpendingCaps(), context: Policy.Context? = nil) -> Policy.Verdict {
        Policy.review(calls, intent: intent, context: context ?? self.context, caps: caps)
    }

    // MARK: Prompt-free

    func testSessionScopedPlansAreSilent() {
        let kuruOut = BigUInt(40) * BigUInt(10).power(18)
        let cases: [(String, [Policy.Call], Intent)] = [
            ("Uniswap v4, USDC → MON with exact approvals and a short Permit2 allowance",
             [approve(usdc, Uniswap.permit2, usdcIn), permit2(usdc, usdcIn, expiration: unix + SwapCalldata.exactPermit2Lifetime), call(Uniswap.universalRouter, universalRouterSwap)],
             swapIntent(.uniswap, pay: usdc, usdcIn)),
            ("Uniswap v4, MON in on value", [call(Uniswap.universalRouter, monSwap, value: monIn)], swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)),
            ("Uniswap v4, two hops", [call(Uniswap.universalRouter, urSwap(Monad.native, monIn, erc20Pair, via: usdc), value: monIn)],
             swapIntent(.uniswap, pay: Monad.native, monIn, receive: erc20Pair)),
            ("Uniswap v3 through SwapRouter02, USDC → MON", [approve(usdc, Uniswap.swapRouter02, usdcIn), call(v3Swap([usdc, Monad.wmon], usdcIn, nativeOut: true))],
             swapIntent(.uniswap, pay: usdc, usdcIn)),
            ("Uniswap v3 through SwapRouter02, MON → token over two hops", [call(v3Swap([Monad.wmon, usdc, erc20Pair], monIn, nativeIn: true))],
             swapIntent(.uniswap, pay: Monad.native, monIn, receive: erc20Pair)),
            ("Uniswap v3, WMON the token", [approve(Monad.wmon, Uniswap.swapRouter02, monIn), call(v3Swap([Monad.wmon, usdc], monIn))],
             swapIntent(.uniswap, pay: Monad.wmon, monIn, receive: usdc)),
            ("Monday Trade, USDC → MON", [approve(usdc, MondayTrade.swapRouter, usdcIn), call(v3Swap([usdc, Monad.wmon], usdcIn, nativeOut: true, monday: true))],
             swapIntent(.monday, pay: usdc, usdcIn)),
            ("Monday Trade, MON → USDC", [call(v3Swap([Monad.wmon, usdc], monIn, nativeIn: true, monday: true))], swapIntent(.monday, pay: Monad.native, monIn, receive: usdc)),
            ("Kuru Flow, output to the caller, 0.5% slippage",
             [approve(usdc, Kuru.entrypoint, usdcIn), call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut * 995 / 1000))],
             swapIntent(.kuru, pay: usdc, usdcIn, out: kuruOut)),
            ("Kuru Flow, MON in, explicit recipient = the account",
             [call(Kuru.entrypoint, kuru(tokenIn: .zero, amountIn: monIn, tokenOut: usdc, minOut: 990, recipient: account), value: monIn)],
             swapIntent(.kuru, pay: Monad.native, monIn, receive: usdc, out: 1000)),
            ("Wrap MON", [call(Monad.wmon, encode("deposit()"), value: monIn)], swapIntent(.wrap, pay: Monad.native, monIn, receive: Monad.wmon, out: monIn)),
            ("Unwrap WMON", [call(Monad.wmon, encode("withdraw(uint256)", [.uint(monIn)]))], swapIntent(.wrap, pay: Monad.wmon, monIn, receive: Monad.native, out: monIn)),
            ("Launchpad buy, MON pair", [curveCall(LaunchpadABI.Curve.buy, monIn, value: monIn)], .launchpadBuy(token: launchToken, pay: .init(token: Monad.native, amount: monIn), usd: 30)),
            ("Launchpad buy, ERC-20 pair", [approve(erc20Pair, curve, usdcIn), curveCall(LaunchpadABI.Curve.buy, usdcIn)],
             .launchpadBuy(token: launchToken, pay: .init(token: erc20Pair, amount: usdcIn), usd: 50)),
            ("Launchpad sell", [approve(launchToken, curve, monIn), curveCall(LaunchpadABI.Curve.sell, monIn)], .launchpadSell(token: launchToken, amount: monIn, usd: 20)),
            ("Moments collect, exact approval", [approve(moments.usdc, moments.collect, usdcIn), call(moments.collect, encode(MomentsABI.Collect.collect, [.uint(7), .uint(2)]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50)),
            ("Moments claim", [call(moments.vesting, encode(MomentsABI.Vesting.claim, [.uint(7)]))], .momentsClaim),
            ("Moments claim all", [call(moments.vesting, encode(MomentsABI.Vesting.claimAll, [.array([.uint(7), .uint(8)])]))], .momentsClaim),
            ("Past-cohort claim", [call(MomentsAddresses.retiredMainnet[0].vesting, encode(MomentsABI.Vesting.claim, [.uint(3)]))], .momentsClaim),
            ("Cohort 3 claim", [call(cohort3.vesting, encode(MomentsABI.Vesting.claim, [.uint(1)]))], .momentsClaim),
            ("Cohort 1 claim all", [call(MomentsAddresses.retiredMainnet[2].vesting, encode(MomentsABI.Vesting.claimAll, [.array([.uint(2)])]))], .momentsClaim),
            ("Cohort 3 creator proceeds", [call(cohort3.collect, encode(MomentsABI.Collect.withdrawCreator, [.uint(1)]))], .momentsWithdraw),
            ("Cohort 3 creator pool fees", [call(cohort3.hook, encode(MomentsABI.Hook.withdrawCreator, [.uint(1)]))], .momentsWithdraw),
            ("Creator proceeds", [call(moments.collect, encode(MomentsABI.Collect.withdrawCreator, [.uint(7)]))], .momentsWithdraw),
            ("Creator pool fees", [call(moments.hook, encode(MomentsABI.Hook.withdrawCreator, [.uint(7)]))], .momentsWithdraw),
            ("Perpl deposit", [approve(Perpl.collateral, Perpl.exchange, usdcIn), call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(usdcIn)]))],
             .perplDeposit(amount: usdcIn)),
            ("Perpl account opening", [approve(Perpl.collateral, Perpl.exchange, usdcIn), call(Perpl.exchange, encode(PerplExchange.Signature.createAccount, [.uint(usdcIn)]))],
             .perplDeposit(amount: usdcIn)),
            ("Perpl withdraw to self", [call(Perpl.exchange, encode(PerplExchange.Signature.withdrawCollateral, [.uint(usdcIn)]))], .perplWithdraw),
            ("Perpl opening a long", [perplOrders([0])], perplIntent()),
            ("Perpl opening a short", [perplOrders([1])], perplIntent(1)),
            ("Swap MON → AUSD, then deposit it",
             [call(Kuru.entrypoint, kuru(tokenIn: .zero, amountIn: monIn, tokenOut: Monad.ausd, minOut: 995), value: monIn),
              approve(Perpl.collateral, Perpl.exchange, 1000), call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(1000)]))],
             .combining([swapIntent(.kuru, pay: Monad.native, monIn, receive: Monad.ausd, out: 1000, usd: nil), .perplDeposit(amount: 1000)], usd: 60)),
            ("Nothing to sign", [], .momentsClaim),
        ]
        for (name, calls, intent) in cases {
            XCTAssertEqual(review(calls, intent), .allowed, name)
        }
    }

    // MARK: Asks

    func testEveryAlwaysAskClassAsks() {
        let transfer = call(usdc, encode("transfer(address,uint256)", [.address(stranger), .uint(usdcIn)]))
        for what in Mera.AlwaysAsk.allCases {
            XCTAssertEqual(review([transfer], .alwaysAsks(what)), .ask(.alwaysAsks(what)), what.rawValue)
            XCTAssertFalse(what.summary.isEmpty)
        }
        // An untagged sheet fails closed, even for a call a swap would allow.
        XCTAssertEqual(review([call(Uniswap.universalRouter, universalRouterSwap)], .ask), .ask(.alwaysAsks(.unlisted)))
        // A combination with an always-ask part asks as a whole.
        XCTAssertEqual(Intent.combining([swapIntent(.uniswap, pay: usdc, usdcIn), .alwaysAsks(.send)], usd: 1), .alwaysAsks(.send))
    }

    func testViolationsAsk() {
        let uni = swapIntent(.uniswap, pay: usdc, usdcIn)
        let kuruOut = BigUInt(1_000_000)
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: kuruOut)
        let sell = Intent.launchpadSell(token: launchToken, amount: monIn, usd: 20)
        let cases: [(String, [Policy.Call], Intent, Policy.Reason)] = [
            // Chain, sender and allowlist.
            ("another chain", [call(Uniswap.universalRouter, universalRouterSwap, chainId: 1)], uni, .wrongChain),
            ("another sender", [call(Uniswap.universalRouter, universalRouterSwap, from: stranger)], uni, .wrongSender),
            ("an unknown contract", [call(stranger, universalRouterSwap)], uni, .notAllowlisted),
            ("a plain MON transfer inside a swap", [call(stranger, Data(), value: 1)], swapIntent(.uniswap, pay: Monad.native, monIn), .notAllowlisted),
            ("a token transfer inside a swap", [call(usdc, encode("transfer(address,uint256)", [.address(stranger), .uint(1)]))], uni, .notAllowlisted),
            ("a Uniswap call declared as Monday", [call(Uniswap.universalRouter, universalRouterSwap)], swapIntent(.monday, pay: usdc, usdcIn), .notAllowlisted),
            // ERC-20 approvals.
            ("the old standing max approval to Permit2", [approve(usdc, Uniswap.permit2, SwapCalldata.maxUint160)], uni, .approval(.amount)),
            ("an approval above the input", [approve(usdc, Uniswap.swapRouter02, usdcIn + 1)], uni, .approval(.amount)),
            ("an approval to a stranger", [approve(usdc, stranger, usdcIn)], uni, .approval(.spender)),
            ("an approval of another token", [approve(Monad.wmon, Uniswap.permit2, usdcIn)], uni, .approval(.token)),
            ("an approval carrying MON", [approve(usdc, Uniswap.permit2, usdcIn, value: 1)], uni, .approval(.value)),
            ("an approval when the input is MON", [approve(usdc, Uniswap.permit2, 1)], swapIntent(.uniswap, pay: Monad.native, monIn), .approval(.token)),
            // Permit2.
            ("the old 30-day Permit2 allowance", [permit2(usdc, usdcIn, expiration: unix + 30 * 24 * 3600)], uni, .approval(.expiration)),
            ("a Permit2 allowance one second past the session", [permit2(usdc, usdcIn, expiration: Int(expiresAt.timeIntervalSince1970) + 1)], uni, .approval(.expiration)),
            ("a Permit2 allowance above the input", [permit2(usdc, usdcIn + 1, expiration: unix + 60)], uni, .approval(.amount)),
            ("a Permit2 allowance for a stranger", [permit2(usdc, usdcIn, spender: stranger, expiration: unix + 60)], uni, .approval(.spender)),
            ("a Permit2 allowance outside a Uniswap swap", [permit2(usdc, usdcIn, expiration: unix + 60)], swapIntent(.monday, pay: usdc, usdcIn), .notAllowlisted),
            // MON.
            // A Universal Router swap carries exactly its input in MON when MON pays it, and none otherwise (IOSK-10).
            ("more MON than declared", [call(Uniswap.universalRouter, monSwap, value: monIn + 1)], swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc), .notAllowlisted),
            ("MON with an ERC-20 input", [call(Uniswap.universalRouter, universalRouterSwap, value: 1)], uni, .notAllowlisted),
            ("MON beyond what a v4 swap settles", [call(Uniswap.universalRouter, urSwap(Monad.native, monIn - 1, usdc), value: monIn)], swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc), .notAllowlisted),
            ("less MON than a v4 swap settles", [call(Uniswap.universalRouter, monSwap, value: monIn - 1)], swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc), .notAllowlisted),
            ("unwrapping more than declared", [call(Monad.wmon, encode("withdraw(uint256)", [.uint(monIn + 1)]))], swapIntent(.wrap, pay: Monad.wmon, monIn), .amountOverDeclared),
            // Kuru Flow.
            ("Kuru output to another address", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut, recipient: stranger))], kuruIntent, .recipient),
            ("Kuru minimum below 99% of the quote", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut * 98 / 100))], kuruIntent, .minimumOut),
            ("Kuru selling another token", [call(Kuru.entrypoint, kuru(tokenIn: Monad.wmon, amountIn: usdcIn, tokenOut: Monad.native, minOut: kuruOut))], kuruIntent, .differentToken),
            ("Kuru buying another token", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.wmon, minOut: kuruOut))], kuruIntent, .differentToken),
            ("Kuru selling more than declared", [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn + 1, tokenOut: Monad.native, minOut: kuruOut))], kuruIntent, .amountOverDeclared),
            ("an unknown Kuru function", [call(Kuru.entrypoint, encode("transferOwnership(address)", [.address(stranger)]))], kuruIntent, .notAllowlisted),
            // Launchpad.
            ("a curve no known factory recorded", [curveCall(LaunchpadABI.Curve.sell, monIn, to: stranger)], sell, .unverifiedCurve),
            ("an approval to an unverified curve", [approve(launchToken, curve, monIn)], sell, .unverifiedCurve),
            ("curve proceeds to another address", [curveCall(LaunchpadABI.Curve.sell, monIn, recipient: stranger)], sell, .recipient),
            ("selling more than declared", [curveCall(LaunchpadABI.Curve.sell, monIn + 1)], sell, .amountOverDeclared),
            ("a buy declared as a sell", [curveCall(LaunchpadABI.Curve.buy, monIn)], sell, .notAllowlisted),
            // Moments.
            ("collecting on a retired cohort", [call(MomentsAddresses.retiredMainnet[1].collect, encode(MomentsABI.Collect.collect, [.uint(1), .uint(1)]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50), .notAllowlisted),
            ("collecting on cohort 3", [call(cohort3.collect, encode(MomentsABI.Collect.collect, [.uint(1), .uint(1)]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50), .notAllowlisted),
            ("an approval of cohort 3's collect", [approve(moments.usdc, cohort3.collect, usdcIn)],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50), .approval(.spender)),
            ("a Permit2 collect", [call(moments.collect, encode(MomentsABI.Collect.collectWithPermit2, [.uint(7), .uint(1), MomentsABI.permit(token: moments.usdc, amount: usdcIn, nonce: 1, deadline: 1), .bytes(Data(count: 65))]))],
             .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50), .notAllowlisted),
            ("expiring a Moment as a withdrawal", [call(moments.collect, encode(MomentsABI.Collect.expire, [.uint(7)]))], .momentsWithdraw, .notAllowlisted),
            ("expiring cohort 3's Moment as a withdrawal", [call(cohort3.collect, encode(MomentsABI.Collect.expire, [.uint(1)]))], .momentsWithdraw, .notAllowlisted),
            ("a buyback as a claim", [call(moments.buyback, encode(MomentsABI.Buyback.execute, [.uint(7), .uint(0)]))], .momentsClaim, .notAllowlisted),
            ("a graduation as a claim", [call(moments.graduation, encode(MomentsABI.Graduation.graduate, [.uint(7)]))], .momentsClaim, .notAllowlisted),
            ("a treasury withdrawal as withdraw-to-self", [call(cohort3.collect, encode(MomentsABI.Collect.withdrawTreasury, [.uint(1)]))], .momentsWithdraw, .notAllowlisted),
            ("a platform withdrawal as withdraw-to-self", [call(moments.collect, encode(MomentsABI.Collect.withdrawPlatform, [.uint(7)]))], .momentsWithdraw, .notAllowlisted),
            ("a claim on a stranger contract", [call(stranger, encode(MomentsABI.Vesting.claim, [.uint(7)]))], .momentsClaim, .notAllowlisted),
            // Perpl.
            ("depositing more than declared", [call(Perpl.exchange, encode(PerplExchange.Signature.depositCollateral, [.uint(usdcIn + 1)]))], .perplDeposit(amount: usdcIn), .amountOverDeclared),
            ("a cancel inside an order", [perplOrders([0, 4])], perplIntent(), .notAllowlisted),
            ("a reduce-only close", [perplOrders([2])], perplIntent(), .notAllowlisted),
            ("a margin move", [perplOrders([5])], perplIntent(), .notAllowlisted),
        ]
        for (name, calls, intent, reason) in cases {
            XCTAssertEqual(review(calls, intent, context: name.contains("unverified") ? Policy.Context(account: account, expiresAt: expiresAt) : nil), .ask(reason), name)
        }
    }

    /// Router and Perpl payloads are read in full (IOSK-10): exactly the shape the app builds is prompt-free, and a
    /// payload that does anything more — or that the decoder can't read in full — asks.
    func testRouterAndOrderPayloadsAreReadInFull() {
        typealias V4 = SwapCalldata.V4
        let uni = swapIntent(.uniswap, pay: usdc, usdcIn)
        let monUni = swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)
        func single(_ tokenIn: Address, _ tokenOut: Address, amountIn: BigUInt, minOut: BigUInt, hookData: Data = Data()) -> Data {
            let hop = V4Hop(key: PoolKey.canonical(tokenIn, tokenOut, fee: 500, tickSpacing: 10), from: tokenIn)!
            return try! ABI.encode([.tuple([hop.key.abiValue, .bool(hop.zeroForOne), .uint(amountIn), .uint(minOut), .bytes(hookData)])],
                                   "((address,address,uint24,int24,address),bool,uint128,uint128,bytes)")
        }
        func pair(_ currency: Address, _ amount: BigUInt) -> Data { try! ABI.encode([.address(currency), .uint(amount)], "address,uint256") }
        func execute(commands: Data = Data([V4.swapCommand]), actions: Data = Data([V4.swapExactInSingle, V4.settleAll, V4.takeAll]),
                     params: [Data], extraInputs: [Data] = []) -> Data {
            let input = try! ABI.encode([.bytes(actions), .array(params.map { .bytes($0) })], "bytes,bytes[]")
            return encode("execute(bytes,bytes[],uint256)", [.bytes(commands), .array(([input] + extraInputs).map { .bytes($0) }), .uint(unix + 600)])
        }
        let swapParams = [single(usdc, Monad.native, amountIn: usdcIn, minOut: 990_000), pair(usdc, usdcIn), pair(Monad.native, 990_000)]
        XCTAssertEqual(execute(params: swapParams), universalRouterSwap, "the test encoder matches the app's builder")
        var trailing = universalRouterSwap
        trailing.append(0)
        var dirty = universalRouterSwap
        dirty[4 + 3 * 32 + 1] = 0x01 // inside the padding after the one-byte command
        let v3Inner = try! SwapCalldata.swapRouter02ExactInputSingle(route: V3Route(path: [usdc, Monad.wmon], fees: [500]), amountIn: usdcIn, minOut: 990_000, recipient: account)
        XCTAssertEqual(review([call(Uniswap.swapRouter02, encode("multicall(uint256,bytes[])", [.uint(unix), .array([.bytes(v3Inner)])]))], swapIntent(.uniswap, pay: usdc, usdcIn, receive: Monad.wmon)),
                       .allowed, "the same swap alone is prompt-free")

        let asks: [(String, Policy.Call, Intent, Policy.Reason)] = [
            ("a second command (a sweep)", call(Uniswap.universalRouter, execute(commands: Data([V4.swapCommand, 0x04]), params: swapParams, extraInputs: [pair(usdc, 0)])), uni, .notAllowlisted),
            ("a TAKE to someone instead of TAKE_ALL", call(Uniswap.universalRouter, execute(actions: Data([V4.swapExactInSingle, V4.settleAll, 0x0e]), params: swapParams)), uni, .notAllowlisted),
            ("an extra action", call(Uniswap.universalRouter, execute(actions: Data([V4.swapExactInSingle, V4.settleAll, V4.takeAll, V4.takeAll]), params: swapParams + [pair(usdc, 0)])), uni, .notAllowlisted),
            ("hook data", call(Uniswap.universalRouter, execute(params: [single(usdc, Monad.native, amountIn: usdcIn, minOut: 990_000, hookData: Data([1])), pair(usdc, usdcIn), pair(Monad.native, 990_000)])), uni, .notAllowlisted),
            ("settling more than the swap's input", call(Uniswap.universalRouter, execute(params: [swapParams[0], pair(usdc, usdcIn + 1), swapParams[2]])), uni, .notAllowlisted),
            ("taking less than the swap's minimum", call(Uniswap.universalRouter, execute(params: [swapParams[0], swapParams[1], pair(Monad.native, 1)])), uni, .notAllowlisted),
            ("settling another currency", call(Uniswap.universalRouter, execute(params: [swapParams[0], pair(Monad.wmon, usdcIn), swapParams[2]])), uni, .notAllowlisted),
            ("a trailing byte", call(Uniswap.universalRouter, trailing), uni, .notAllowlisted),
            ("a dirty padding byte", call(Uniswap.universalRouter, dirty), uni, .notAllowlisted),
            ("the old placeholder payload", call(Uniswap.universalRouter, encode("execute(bytes,bytes[],uint256)", [.bytes(Data([0x10])), .array([.bytes(Data([1, 2, 3]))]), .uint(unix + 600)])), uni, .notAllowlisted),
            ("a v4 swap of another token", call(Uniswap.universalRouter, urSwap(Monad.wmon, usdcIn, Monad.native)), uni, .differentToken),
            ("a v4 swap for another token", call(Uniswap.universalRouter, urSwap(usdc, usdcIn, erc20Pair)), uni, .differentToken),
            ("a v4 swap of more than declared", call(Uniswap.universalRouter, urSwap(usdc, usdcIn + 1, Monad.native)), uni, .amountOverDeclared),
            ("a v4 minimum below 99% of the quote", call(Uniswap.universalRouter, urSwap(usdc, usdcIn, Monad.native, minOut: 989_999)), uni, .minimumOut),
            // SwapRouter02.
            ("a v3 swap paying someone else", call(try! SwapCalldata.swapRouter02(route: V3Route(path: [usdc, Monad.wmon], fees: [500]), amountIn: usdcIn, minOut: 990_000, account: stranger, nativeIn: false, nativeOut: false, deadline: BigUInt(unix))),
             swapIntent(.uniswap, pay: usdc, usdcIn, receive: Monad.wmon), .notAllowlisted),
            ("a v3 unwrap to someone else", call(try! SwapCalldata.swapRouter02(route: V3Route(path: [usdc, Monad.wmon], fees: [500]), amountIn: usdcIn, minOut: 990_000, account: stranger, nativeIn: false, nativeOut: true, deadline: BigUInt(unix))), uni, .notAllowlisted),
            ("a v3 call after the swap", call(Uniswap.swapRouter02, encode("multicall(uint256,bytes[])", [.uint(unix), .array([.bytes(v3Inner), .bytes(encode("sweepToken(address,uint256,address)", [.address(usdc), .uint(0), .address(stranger)]))])])),
             swapIntent(.uniswap, pay: usdc, usdcIn, receive: Monad.wmon), .notAllowlisted),
            ("MON on value with no refund", call(Uniswap.swapRouter02, v3Swap([Monad.wmon, usdc], monIn).data, value: monIn), monUni, .notAllowlisted),
            ("a refund with no MON on value", call(Uniswap.swapRouter02, v3Swap([Monad.wmon, usdc], monIn, nativeIn: true).data), monUni, .notAllowlisted),
            ("a v3 price limit", call(Uniswap.swapRouter02, encode("multicall(uint256,bytes[])", [.uint(unix), .array([.bytes(encode("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
                                     [.tuple([.address(usdc), .address(Monad.wmon), .uint(500), .address(account), .uint(usdcIn), .uint(990_000), .uint(1)])]))])])),
             swapIntent(.uniswap, pay: usdc, usdcIn, receive: Monad.wmon), .notAllowlisted),
            ("a v3 minimum below 99% of the quote", call(v3Swap([usdc, Monad.wmon], usdcIn, minOut: 989_999, nativeOut: true)), uni, .minimumOut),
            // Monday Trade.
            ("a Monday swap paying someone else", call(try! SwapCalldata.mondaySwap(route: V3Route(path: [usdc, Monad.wmon], fees: [500]), amountIn: usdcIn, minOut: 990_000, account: stranger, nativeIn: false, nativeOut: false, deadline: BigUInt(unix))),
             swapIntent(.monday, pay: usdc, usdcIn, receive: Monad.wmon), .notAllowlisted),
            ("a Monday swap of more than declared", call(v3Swap([usdc, Monad.wmon], usdcIn + 1, nativeOut: true, monday: true)), swapIntent(.monday, pay: usdc, usdcIn), .amountOverDeclared),
            ("a SwapRouter02 payload sent to Monday", call(MondayTrade.swapRouter, v3Swap([usdc, Monad.wmon], usdcIn, nativeOut: true).data), swapIntent(.monday, pay: usdc, usdcIn), .notAllowlisted),
            // Perpl.
            ("two orders in one call", perplOrders([0, 0]), perplIntent(), .notAllowlisted),
            ("an order with an expiry", perplOrders([0], change: (6, .uint(1))), perplIntent(), .notAllowlisted),
            ("an order moving collateral", perplOrders([0], change: (13, .uint(1))), perplIntent(), .notAllowlisted),
            ("a fill-or-kill order", perplOrders([0], change: (8, .bool(true))), perplIntent(), .notAllowlisted),
            ("a looser negative-PnL bound", perplOrders([0], change: (14, .uint(1_000))), perplIntent(), .notAllowlisted),
            ("an order on another market", perplOrders([0], change: (1, .uint(17))), perplIntent(), .amountOverDeclared),
            ("a short declared as a long", perplOrders([1]), perplIntent(0), .amountOverDeclared),
            ("more than 2% over the size", perplOrders([0], change: (5, .uint(11))), perplIntent(), .amountOverDeclared),
            ("higher leverage than shown", perplOrders([0], change: (11, .uint(501))), perplIntent(), .amountOverDeclared),
            ("a long more than 2% above the price shown", perplOrders([0], change: (4, .uint(103))), perplIntent(), .amountOverDeclared),
            ("a short more than 2% below the price shown", perplOrders([1], change: (4, .uint(97))), perplIntent(1), .amountOverDeclared),
            ("a resting order shown as immediate-or-cancel", perplOrders([0], change: (9, .bool(false))), perplIntent(), .amountOverDeclared),
            ("a post-only order not shown as one", perplOrders([0], change: (7, .bool(true))), perplIntent(), .amountOverDeclared),
            ("an order with nothing declared", perplOrders([0]), Intent(parts: [.init(kind: .perplOrder)], usd: 10), .notAllowlisted),
        ]
        for (name, call, intent, reason) in asks {
            XCTAssertEqual(review([call], intent), .ask(reason), name)
        }
        // Within 2% of the declared size (an order sized in dollars, converted at a mark that moved) is still the order.
        XCTAssertEqual(review([perplOrders([0], change: (5, .uint(102)))], perplIntent(lots: 100)), .allowed)
        // So is a price within 2% of the one shown, or better: lower for a long, higher for a short.
        XCTAssertEqual(review([perplOrders([0], change: (4, .uint(102)))], perplIntent()), .allowed)
        XCTAssertEqual(review([perplOrders([0], change: (4, .uint(50)))], perplIntent()), .allowed)
        XCTAssertEqual(review([perplOrders([1], change: (4, .uint(98)))], perplIntent(1)), .allowed)
        XCTAssertEqual(review([perplOrders([1], change: (4, .uint(150)))], perplIntent(1)), .allowed)
        // The terms a sheet declares are those the app's own builder encodes.
        let market = PerpMarket(id: 16, symbol: "BTC", name: "Bitcoin", priceDecimals: 1, lotDecimals: 5, basePricePNS: 0,
                                mark: 100, last: 100, oracle: 100, markTimestamp: 0, longOI: 0, shortOI: 0,
                                fundingRatePct100k: 0, status: 0, initMarginFraction: 0.1, maintMarginFraction: 0.05, numOrders: 0)
        for input in [OrderInput(market: market, side: .long, kind: .market, size: 0.5, leverage: 20), OrderInput(market: market, side: .short, kind: .limit, size: 2, price: 90, leverage: 3)] {
            let plan = PerplService.buildOrderDesc(input)
            let data = PerplExchange.execOrdersCalldata([plan], revertOnFail: true)
            XCTAssertEqual(review([call(Perpl.exchange, data)], .perplOrder(usd: 50, order: .init(input))), .allowed, "\(input.side)")
        }
    }

    func testCapsAndPricing() {
        let swap = [call(Uniswap.universalRouter, monSwap, value: monIn)]
        func intent(_ usd: Double?) -> Intent { swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc, usd: usd) }
        XCTAssertEqual(review(swap, intent(100)), .allowed, "exactly the per-action cap")
        XCTAssertEqual(review(swap, intent(nil)), .ask(.unpriced))
        XCTAssertEqual(review(swap, intent(.nan)), .ask(.unpriced))
        XCTAssertEqual(review(swap, intent(100.01)), .ask(.overActionCap))
        var spent = Mera.SpendingCaps()
        spent.charge(100); spent.charge(100)
        XCTAssertEqual(review(swap, intent(50), caps: spent), .allowed, "exactly the session cap")
        XCTAssertEqual(review(swap, intent(50.01), caps: spent), .ask(.overSessionCap))
        // A violation is reported before the caps, whatever the price.
        XCTAssertEqual(review([call(stranger, Data())], intent(nil)), .ask(.notAllowlisted))
        // Reasons read as "Face ID required: <reason>".
        XCTAssertEqual(Policy.Reason.overActionCap.summary, "over the $100 limit per action")
        XCTAssertEqual(Policy.Reason.locked.summary, "your session is locked")
    }

    // MARK: Network fee

    func testNetworkFeeIsBoundedWhateverTheApproval() {
        let gwei = BigUInt(10).power(9)
        let intent = swapIntent(.uniswap, pay: Monad.native, monIn, receive: usdc)
        func prepared(to: Address = Uniswap.universalRouter, data: Data? = nil, value: BigUInt? = nil, gasLimit: BigUInt, maxFee: BigUInt, tip: BigUInt = 2 * gwei, chainId: Int = Monad.chainId) -> Policy.Call {
            Policy.Call(PreparedTransaction(from: account, to: to, data: data ?? monSwap, value: value ?? monIn, nonce: 7,
                                            gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, chainId: chainId))
        }
        func refusal(_ call: Policy.Call, _ intent: Intent) -> Policy.Reason? { Policy.refusal(call, intent: intent, account: account) }
        // A normal swap: ~300k gas estimated plus 20%, at twice a 100 gwei base fee plus a 2 gwei tip — about 0.07 MON.
        let normal = prepared(gasLimit: 360_000, maxFee: 202 * gwei)
        XCTAssertEqual(normal.gasLimit, 360_000, "the prepared transaction's fee is kept")
        XCTAssertEqual(normal.maxFeePerGas, 202 * gwei)
        XCTAssertEqual(normal.maxPriorityFeePerGas, 2 * gwei)
        XCTAssertNil(refusal(normal, intent))
        XCTAssertEqual(review([normal], intent), .allowed, "the fee is no reason to ask")
        XCTAssertNil(refusal(prepared(gasLimit: 10_000_000, maxFee: 500 * gwei), intent), "exactly 5 MON")
        XCTAssertNil(refusal(prepared(gasLimit: Policy.maxGasLimit, maxFee: 202 * gwei), intent), "exactly the gas limit ceiling")
        // The largest the app sends: a launch with its first buy (~6.2M gas limit), approved by a step-up.
        XCTAssertNil(refusal(prepared(to: stranger, gasLimit: 6_200_000, maxFee: 202 * gwei), .alwaysAsks(.launch)))
        // A graduating Moment collect reserves 3M gas for the graduation: prompt-free still, since its fee is ordinary.
        XCTAssertNil(refusal(prepared(gasLimit: 4_000_000, maxFee: 202 * gwei), intent))
        // A Kuru swap with an exact approval: each step is bounded on its own.
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: 1000)
        let kuruApprove = prepared(to: usdc, data: encode("approve(address,uint256)", [.address(Kuru.entrypoint), .uint(usdcIn)]), value: 0, gasLimit: 60_000, maxFee: 202 * gwei)
        func kuruSwap(_ gasLimit: BigUInt, _ maxFee: BigUInt) -> Policy.Call {
            prepared(to: Kuru.entrypoint, data: kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995), value: 0, gasLimit: gasLimit, maxFee: maxFee)
        }
        XCTAssertNil(refusal(kuruApprove, kuruIntent))
        XCTAssertNil(refusal(kuruSwap(400_000, 202 * gwei), kuruIntent))
        XCTAssertEqual(review([kuruApprove, kuruSwap(400_000, 202 * gwei)], kuruIntent), .allowed)
        XCTAssertEqual(refusal(kuruSwap(400_000, 100_000 * gwei), kuruIntent), .networkFee, "a huge max fee on the swap step")

        let refused: [(String, Policy.Call)] = [
            ("a huge gas limit", prepared(gasLimit: 50_000_000, maxFee: 202 * gwei)),
            ("a gas limit over 15M, even at a tiny fee", prepared(gasLimit: Policy.maxGasLimit + 1, maxFee: 1, tip: 1)),
            ("a huge max fee", prepared(gasLimit: 360_000, maxFee: 1_000_000 * gwei)),
            ("one wei per gas over 5 MON", prepared(gasLimit: 10_000_000, maxFee: 500 * gwei + 1)),
            ("a tip above the max fee", prepared(gasLimit: 360_000, maxFee: 202 * gwei, tip: 202 * gwei + 1)),
            ("a fee given in part", Policy.Call(from: account, to: Uniswap.universalRouter, data: universalRouterSwap, value: monIn, gasLimit: 360_000)),
        ]
        for (name, call) in refused {
            // Refused for a session-OK swap and for an action a step-up approves alike: no Face ID vouches for the fee.
            XCTAssertEqual(refusal(call, intent), .networkFee, name)
            XCTAssertEqual(refusal(call, .ask), .networkFee, "\(name), approved")
            XCTAssertEqual(refusal(call, .alwaysAsks(.send)), .networkFee, "\(name), a send")
        }
        // Only Monad's fee is bounded here: a bridge's source transaction on another chain has that chain's fee market.
        XCTAssertNil(refusal(prepared(gasLimit: 50_000_000, maxFee: 202 * gwei, chainId: 42_161), .alwaysAsks(.bridge)))
        // A preview has no fee yet, so the fee decides nothing before it is prepared.
        let preview = Policy.Call(step: .call(TransactionRequest(to: Uniswap.universalRouter, data: universalRouterSwap, value: monIn), label: "Swap"), from: account)
        XCTAssertNil(preview?.gasLimit)
        XCTAssertNil(preview.flatMap { refusal($0, intent) })
        XCTAssertEqual(Policy.Reason.networkFee.summary, "an unusually high network fee")
    }

    /// Kuru's minimum at the 1% slippage preset is floor(out × 99 / 100), as Kuru and `SwapMath` round it: prompt-free
    /// whatever the quote's last digits, and one unit less asks.
    func testKuruOnePercentMinimumIsPromptFreeWhateverTheRounding() {
        for out in [BigUInt(2_587_123), BigUInt(1_000_001), BigUInt(99), BigUInt(40) * BigUInt(10).power(18) + 7] {
            let intent = swapIntent(.kuru, pay: usdc, usdcIn, out: out)
            let minimum = SwapMath.minAfterSlippage(out, bps: 100)
            func swap(_ minOut: BigUInt) -> [Policy.Call] { [call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: minOut))] }
            XCTAssertEqual(review(swap(minimum), intent), .allowed, "1% of \(out)")
            if minimum > 0 { XCTAssertEqual(review(swap(minimum - 1), intent), .ask(.minimumOut), "just under 1% of \(out)") }
        }
    }

    func testForeignRecipientOrTokenIsRefusedWhateverTheApproval() {
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: 1000)
        func refusal(_ call: Policy.Call, _ intent: Intent) -> Policy.Reason? { Policy.refusal(call, intent: intent, account: account) }
        let own = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995))
        let ownExplicit = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995, recipient: account))
        let paysStranger = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995, recipient: stranger))
        let otherToken = call(Kuru.entrypoint, kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: erc20Pair, minOut: 995))
        XCTAssertNil(refusal(own, kuruIntent))
        XCTAssertNil(refusal(ownExplicit, kuruIntent))
        // The output to someone else: refused for the sheet that declared the swap, and for any approved action too.
        XCTAssertEqual(refusal(paysStranger, kuruIntent), .recipient)
        XCTAssertEqual(refusal(paysStranger, .ask), .recipient)
        XCTAssertEqual(refusal(paysStranger, .alwaysAsks(.send)), .recipient)
        // A token other than the ones shown, when the sheet declared a Kuru swap.
        XCTAssertEqual(refusal(otherToken, kuruIntent), .differentToken)
        XCTAssertEqual(refusal(otherToken, .combining([swapIntent(.kuru, pay: usdc, usdcIn, receive: erc20Pair), kuruIntent], usd: 50)), nil, "any declared Kuru part may match")
        // The session check still names them first for a live session (it would ask); the refusal stops the approval.
        XCTAssertEqual(Policy.check(paysStranger, intent: kuruIntent, context: context), .ask(.recipient))
        // A launchpad trade the sheet declared must pay this account.
        let buy = Intent.launchpadBuy(token: launchToken, pay: .init(token: Monad.native, amount: monIn), usd: 30)
        let sell = Intent.launchpadSell(token: launchToken, amount: 1000, usd: 30)
        XCTAssertNil(refusal(curveCall(LaunchpadABI.Curve.buy, monIn, value: monIn), buy))
        XCTAssertEqual(refusal(curveCall(LaunchpadABI.Curve.buy, monIn, recipient: stranger, value: monIn), buy), .recipient)
        XCTAssertNil(refusal(curveCall(LaunchpadABI.Curve.sell, 1000), sell))
        XCTAssertEqual(refusal(curveCall(LaunchpadABI.Curve.sell, 1000, recipient: stranger), sell), .recipient)
        // Nothing else is second-guessed here: other calls fall to the session check (which asks) and the step-up.
        XCTAssertNil(refusal(call(stranger, Data([1, 2, 3, 4])), .alwaysAsks(.send)))
    }

    // MARK: Moments v2

    /// v2 `publish(PublishParams, bytes32)` (0xa270dccc) to the v2 factory always asks: no intent admits it, whatever the
    /// sheet declares, and the create sheet declares `AlwaysAsk.launch`. So do the policy and guardian calls.
    func testV2PublishAndGovernanceCallsAlwaysAsk() {
        let input = MomentPublishInput(name: "Nature", symbol: "NATURE", mediaURI: "ipfs://bafy", mediaHash: Data(count: 32), place: "Accra", date: unix,
                                       price: 1_000_000, creatorAllocBps: 1_000, collectWindow: 86_400)
        let publish = call(moments.factory, MomentsABI.calldata(MomentsABI.Factory.publish, [MomentsABI.publishParams(input, salt: Data(count: 32)), .bytes(V2Fixture.termsHash)]))
        XCTAssertEqual(publish.data.prefix(4).hexString, "0xa270dccc")
        let intents: [(String, Intent)] = [
            ("collect", .momentsCollect(pay: .init(token: moments.usdc, amount: usdcIn), usd: 50)), ("claim", .momentsClaim), ("withdraw", .momentsWithdraw),
            ("swap", swapIntent(.uniswap, pay: usdc, usdcIn)), ("launchpad buy", .launchpadBuy(token: launchToken, pay: .init(token: Monad.native, amount: monIn), usd: 30)),
            ("Perpl withdraw", .perplWithdraw),
        ]
        let governance: [(String, Data)] = [
            ("applyPolicy", encode("applyPolicy()")), ("cancelPolicy", encode("cancelPolicy()")), ("setGuardianPaused", encode("setGuardianPaused(bool)", [.bool(true)])),
            ("setGuardian", encode("setGuardian(address)", [.address(stranger)])), ("setExternalBaseURI", encode("setExternalBaseURI(string)", [.string("https://evil.example/")])),
            ("setPublishingPaused", encode("setPublishingPaused(bool)", [.bool(false)])),
        ]
        for (name, intent) in intents {
            // A launchpad sheet names the first thing it checks: the call isn't to the verified curve.
            let reason: Policy.Reason = name == "launchpad buy" ? .unverifiedCurve : .notAllowlisted
            XCTAssertEqual(review([publish], intent), .ask(reason), "publish under \(name)")
            for (what, data) in governance {
                XCTAssertEqual(review([call(moments.factory, data)], intent), .ask(reason), "\(what) under \(name)")
            }
        }
        XCTAssertEqual(review([publish], .alwaysAsks(.launch)), .ask(.alwaysAsks(.launch)))
        XCTAssertEqual(review([publish], .ask), .ask(.alwaysAsks(.unlisted)))
    }

    /// While v2 is pending the shipped contracts table is all zero for the live cohort: collecting asks (nothing points at
    /// address 0), and claims and creator withdrawals still work on every retired cohort, newest first.
    func testMainnetContractsWhileV2IsPending() {
        let mainnet = Policy.Contracts.monadMainnet
        XCTAssertEqual(mainnet.moments, MomentsAddresses.monadMainnet)
        guard !MomentsAddresses.monadMainnet.isDeployed else {
            // Wired: the live cohort leads, then cohorts 3, 2, 1.
            XCTAssertEqual(mainnet.momentsCohorts, [MomentsAddresses.monadMainnet] + MomentsAddresses.retiredMainnet)
            return
        }
        XCTAssertEqual(mainnet.momentsCohorts, MomentsAddresses.retiredMainnet, "cohorts 3, 2, 1; nothing at address 0")
        XCTAssertEqual(Policy.Contracts(moments: V2Fixture.moments).momentsCohorts, [V2Fixture.moments] + MomentsAddresses.retiredMainnet)
        let pending = Policy.Context(account: account, expiresAt: expiresAt, contracts: mainnet)
        let collect = Intent.momentsCollect(pay: .init(token: usdc, amount: usdcIn), usd: 50)
        XCTAssertEqual(review([approve(usdc, .zero, usdcIn)], collect, context: pending), .ask(.approval(.spender)))
        XCTAssertEqual(review([call(.zero, encode(MomentsABI.Collect.collect, [.uint(1), .uint(1)]))], collect, context: pending), .ask(.notAllowlisted))
        XCTAssertEqual(review([call(.zero, encode(MomentsABI.Vesting.claim, [.uint(1)]))], .momentsClaim, context: pending), .ask(.notAllowlisted))
        XCTAssertEqual(review([call(.zero, encode(MomentsABI.Collect.withdrawCreator, [.uint(1)]))], .momentsWithdraw, context: pending), .ask(.notAllowlisted))
        for cohort in MomentsAddresses.retiredMainnet {
            XCTAssertEqual(review([call(cohort.vesting, encode(MomentsABI.Vesting.claim, [.uint(1)]))], .momentsClaim, context: pending), .allowed)
            XCTAssertEqual(review([call(cohort.collect, encode(MomentsABI.Collect.withdrawCreator, [.uint(1)]))], .momentsWithdraw, context: pending), .allowed)
            XCTAssertEqual(review([call(cohort.hook, encode(MomentsABI.Hook.withdrawCreator, [.uint(1)]))], .momentsWithdraw, context: pending), .allowed)
            XCTAssertEqual(review([call(cohort.collect, encode(MomentsABI.Collect.collect, [.uint(1), .uint(1)]))], collect, context: pending), .ask(.notAllowlisted))
        }
    }

    /// The v2 launchpad's `graduateFallback` needs at least 22,062,500 gas: over the 15M ceiling, so it is refused on the
    /// fee bound whatever the sheet or a step-up says. The app never sends it; the keepers do.
    func testGraduateFallbackIsRefusedAtTheGasItNeeds() {
        let gwei = BigUInt(10).power(9)
        let fallback = Policy.Call(PreparedTransaction(from: account, to: V2Fixture.launchpad.factory,
                                                       data: encode(LaunchpadABI.Factory.graduateFallback, [.address(launchToken)]), value: 0, nonce: 3,
                                                       gasLimit: 22_100_000, maxFeePerGas: 110 * gwei, maxPriorityFeePerGas: 2 * gwei, chainId: Monad.chainId))
        for intent in [Intent.ask, .alwaysAsks(.unlisted), .alwaysAsks(.launch), .momentsClaim] {
            XCTAssertEqual(Policy.refusal(fallback, intent: intent, account: account), .networkFee)
        }
        XCTAssertEqual(review([fallback], .momentsClaim), .ask(.notAllowlisted), "and it is on no list")
        XCTAssertLessThan(Policy.maxGasLimit, 22_062_500)
        XCTAssertEqual(Policy.maxGasLimit, NetworkFeeLimits.monad.maxGasLimit, "the caps are unchanged")
    }

    // MARK: Messages

    func testOnlyTheWalletAuthTemplateIsPromptFree() {
        let nonce = String(repeating: "ab", count: 32)
        let millis = unix * 1000 + 123
        func signIn(_ address: String, _ nonce: String, _ issued: Int) -> Data { Data(SupabaseClient.signInMessage(address: address, nonce: nonce, issuedAt: issued).utf8) }
        func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
        XCTAssertEqual(Policy.check(message: signIn(account.checksummed, nonce, millis), account: account, now: now), .allowed)
        // The address line must carry the EIP-55 checksum (an all-digit address like `account` has no letters to case).
        let lettered = Address(literal: "0x52908400098527886E0F7030069857D2E4169EE7")
        XCTAssertEqual(Policy.check(message: signIn(lettered.checksummed, nonce, millis), account: lettered, now: now), .allowed)
        XCTAssertEqual(Policy.check(message: signIn(lettered.hex, nonce, millis), account: lettered, now: now), .ask(.alwaysAsks(.message)))
        let good = text(signIn(account.checksummed, nonce, millis))
        let asks: [(String, Data)] = [
            ("another wallet", signIn(stranger.checksummed, nonce, millis)),
            ("issued six minutes ago", signIn(account.checksummed, nonce, millis - 6 * 60 * 1000)),
            ("issued in the future", signIn(account.checksummed, nonce, millis + 6 * 60 * 1000)),
            ("an uppercase nonce", signIn(account.checksummed, nonce.uppercased(), millis)),
            ("a short nonce", signIn(account.checksummed, "abcd", millis)),
            ("a trailing newline", signIn(account.checksummed, nonce, millis) + Data("\n".utf8)),
            ("a carriage return", Data(good.replacingOccurrences(of: "\n", with: "\r\n").utf8)),
            ("another domain", Data(good.replacingOccurrences(of: "dyorhq.fun wants", with: "evil.fun wants").utf8)),
            ("another URI", Data(good.replacingOccurrences(of: "URI: https://dyorhq.fun", with: "URI: https://dyorhq.fun.evil.com").utf8)),
            ("another chain", Data(good.replacingOccurrences(of: "Chain ID: 143", with: "Chain ID: 1").utf8)),
            ("a longer validity", Data(good.replacingOccurrences(of: "Expiration Time: \(SupabaseClient.iso8601(millis: millis + 600_000))",
                                                              with: "Expiration Time: \(SupabaseClient.iso8601(millis: millis + 3_600_000))").utf8)),
            ("an appended resource", Data((good + "\nResources:\n- https://evil.example").utf8)),
            ("the retired DyorHQ Sign-In template", Data("DyorHQ Sign-In\n\nWallet: \(account.checksummed)\nNonce: \(nonce)\nIssued At: \(millis)".utf8)),
            ("an arbitrary message", Data("Transfer all funds".utf8)),
            ("the email rebind message", Data("DyorHQ Email Rebind\n\nEmail: a@b.c\nAddress: \(account.hex)\nIssued At: \(millis)".utf8)),
            ("not UTF-8", Data([0xff, 0xfe, 0x00])),
        ]
        for (name, message) in asks {
            XCTAssertEqual(Policy.check(message: message, account: account, now: now), .ask(.alwaysAsks(.message)), name)
        }
    }

    // MARK: Kuru Flow calldata

    func testKuruFlowSwapDecoding() throws {
        let caller = try XCTUnwrap(KuruFlowSwap(calldata: kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5)))
        XCTAssertEqual(caller.tokenIn, usdc)
        XCTAssertEqual(caller.amountIn, 7)
        XCTAssertEqual(caller.tokenOut, .zero)
        XCTAssertEqual(caller.minAmountOut, 5)
        XCTAssertNil(caller.recipient, "ce1e7030 pays msg.sender")
        let explicit = try XCTUnwrap(KuruFlowSwap(calldata: kuru(tokenIn: .zero, amountIn: 7, tokenOut: usdc, minOut: 5, recipient: stranger)))
        XCTAssertEqual(explicit.recipient, stranger)
        // Another selector, a truncated head, or an address word with dirty high bytes decodes to nothing.
        XCTAssertNil(KuruFlowSwap(calldata: Data([0xde, 0xad, 0xbe, 0xef]) + Data(count: 320)))
        XCTAssertNil(KuruFlowSwap(calldata: KuruFlowSwap.payCaller + Data(count: 64)))
        var dirty = kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5)
        dirty[4] = 0x01
        XCTAssertNil(KuruFlowSwap(calldata: dirty))
        XCTAssertNil(KuruFlowSwap(calldata: KuruFlowSwap.payRecipient + Data(count: 320)), "the recipient variant needs its eleventh head word")
        // Whatever sits in the eleventh word is the recipient the contract pays, so it is what the check compares.
        let reread = try XCTUnwrap(KuruFlowSwap(calldata: KuruFlowSwap.payRecipient + Data(kuru(tokenIn: usdc, amountIn: 7, tokenOut: .zero, minOut: 5).dropFirst(4))))
        XCTAssertNotEqual(reread.recipient, account)
    }

    /// The fee tuple (IOST-7), decoded as the web's `decodeKuruFlowSwap` and judged as its `kuruFeeAllowed`: only zero
    /// basis points on both sides is a swap the wallet signs; the recipient and referrer are not pinned (at 0 bps they
    /// receive nothing); a dirty address word or a fee flag that isn't a clean bool decodes to nothing.
    func testKuruFeeTuple() throws {
        func swap(_ fee: [ABIValue]) -> Data { kuru(tokenIn: usdc, amountIn: usdcIn, tokenOut: Monad.native, minOut: 995, fee: fee) }
        let clean = try XCTUnwrap(KuruFlowSwap(calldata: swap([.address(stranger), .uint(7), .address(account), .uint(3), .bool(false)])))
        XCTAssertEqual(clean.fee, KuruFlowSwap.Fee(recipient: stranger, bps: 7, referrer: account, referrerBps: 3, onOutput: false))
        XCTAssertFalse(clean.takesNoFee)
        XCTAssertTrue(try XCTUnwrap(KuruFlowSwap(calldata: swap([.address(stranger), .uint(0), .address(.zero), .uint(0), .bool(true)]))).takesNoFee)
        XCTAssertTrue(try XCTUnwrap(KuruFlowSwap(calldata: swap([.address(.zero), .uint(0), .address(stranger), .uint(0), .bool(false)]))).takesNoFee)
        for fee: [ABIValue] in [
            [.address(stranger), .uint(1), .address(.zero), .uint(0), .bool(true)],
            [.address(.zero), .uint(0), .address(stranger), .uint(1), .bool(true)],
            [.address(.zero), .uint(BigUInt(1) << 255), .address(.zero), .uint(0), .bool(false)],
        ] {
            XCTAssertFalse(try XCTUnwrap(KuruFlowSwap(calldata: swap(fee))).takesNoFee, "\(fee)")
        }
        // Word 4 (fee recipient) or 6 (referrer) with dirty high bytes; word 8 (feeOnOutput) that isn't 0 or 1.
        for (index, byte) in [(4 * 32, UInt8(1)), (6 * 32, 1), (8 * 32 + 31, 2)] {
            var bad = swap([.address(stranger), .uint(0), .address(.zero), .uint(0), .bool(true)])
            bad[4 + index] = byte
            XCTAssertNil(KuruFlowSwap(calldata: bad), "word \(index / 32)")
        }
        // The wallet refuses a fee-taking swap whatever the session (the quote client already blocks it).
        let taking = call(Kuru.entrypoint, swap([.address(stranger), .uint(30), .address(.zero), .uint(0), .bool(true)]))
        let kuruIntent = swapIntent(.kuru, pay: usdc, usdcIn, out: 1_000)
        XCTAssertEqual(Policy.refusal(taking, intent: kuruIntent, account: account), .fee)
        XCTAssertEqual(Policy.refusal(taking, intent: .ask, account: account), .fee)
        XCTAssertEqual(Policy.check(taking, intent: kuruIntent, context: context), .ask(.fee))
        XCTAssertEqual(Policy.Reason.fee.summary, "a swap that pays a fee to someone else")
    }

    // MARK: Builders

    func testRuntimePermit2StepExpiresShortlyAfterItIsSent() throws {
        let step = TransactionStep.permit2Approve(token: usdc, spender: Uniswap.universalRouter, amount: usdcIn, lifetime: SwapCalldata.exactPermit2Lifetime, label: "Permit")
        let request = try XCTUnwrap(try step.request(at: now))
        XCTAssertEqual(request.to, Uniswap.permit2)
        XCTAssertEqual(request.data, try SwapCalldata.permit2Approve(token: usdc, spender: Uniswap.universalRouter, amount: usdcIn, expiration: BigUInt(unix + 120)))
        XCTAssertEqual(review([Policy.Call(step: step, from: account, now: now)!], swapIntent(.uniswap, pay: usdc, usdcIn)), .allowed)
        // In the session's last two minutes the same step would outlast it, so it asks.
        let late = Policy.Context(account: account, expiresAt: now.addingTimeInterval(90))
        XCTAssertEqual(review([Policy.Call(step: step, from: account, now: now)!], swapIntent(.uniswap, pay: usdc, usdcIn), context: late), .ask(.approval(.expiration)))
        // An approval step previews as its `approve` call.
        let approval = TransactionStep.approve(token: usdc, spender: Uniswap.permit2, amount: usdcIn, label: "Approve")
        XCTAssertEqual(Policy.Call(step: approval, from: account)?.data, try ERC20.approveCalldata(spender: Uniswap.permit2, amount: usdcIn))
        XCTAssertFalse(SwapRequest(tokenIn: .usdc, tokenOut: .mon, amountIn: 1, slippageBps: 50, account: account).exactApprovals, "standing approvals stay the default")
    }

    func testKnownCurveComesFromAKnownFactoryRecord() {
        func record(curve: Address, exists: Bool, legacy: Bool) -> ABIValue {
            // 17 fields (16 for the first deployment): token, curve, …, exists last.
            var fields: [ABIValue] = [.address(launchToken), .address(curve), .address(stranger), .address(stranger), .address(.zero), .uint(0),
                                      .uint(0), .uint(0), .int(0), .bool(false), .uint(0), .uint(0), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
            if legacy { fields.remove(at: 10) }
            return .tuple(fields)
        }
        // The v2 stack (a fixture while the mainnet table is pending), then the four retired ones: 0x6B1C, 0x10F3, 0x2F02
        // and the legacy 0xad3d.
        let stacks = [V2Fixture.launchpad] + LaunchpadAddresses.retiredStacks
        XCTAssertEqual(stacks.count, 5)
        struct Failed: Error {}
        let found = LaunchpadService.knownCurve(stacks: stacks, records: [
            .failure(Failed()),
            .success([record(curve: .zero, exists: false, legacy: false)]),
            .success([record(curve: stranger, exists: false, legacy: false)]),
            .success([record(curve: stranger, exists: false, legacy: false)]),
            .success([record(curve: curve, exists: true, legacy: true)]),
        ])
        XCTAssertEqual(found, curve, "the first stack that recorded the launch, legacy layout included")
        XCTAssertNil(LaunchpadService.knownCurve(stacks: stacks, records: stacks.map { .success([record(curve: curve, exists: false, legacy: $0.generation.legacyRecord)]) }))
    }
}
