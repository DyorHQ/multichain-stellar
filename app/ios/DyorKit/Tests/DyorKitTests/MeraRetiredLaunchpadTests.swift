import BigInt
import XCTest
@testable import DyorKit

/// A passkey account refuses a buy on a retired launchpad (owner decision 2026-09-28) whatever the sheet declared or a
/// Face ID approved, even when a screen built one: a curve `buy` into a curve each retired factory recorded (looked up on
/// chain through `curveToToken`), the pair approval that would feed it, and `launchAndBuy` on (or an approval to) each
/// retired router. Selling into the same curve stays open, a v2 curve buy is unaffected, and a curve buy whose curve
/// couldn't be looked up is refused as unverified.
final class MeraRetiredLaunchpadTests: XCTestCase {
    typealias Policy = Mera.SigningPolicy
    typealias Intent = Mera.Intent

    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let monIn = BigUInt(10).power(18)
    private let usdcIn = BigUInt(5_000_000)
    /// A v2 launch: its curve is recorded by no retired factory.
    private let v2Coin = Address(literal: "0x00000000000000000000000000000000000c2c01")
    private let v2Curve = Address(literal: "0x00000000000000000000000000000000000c2cc0")

    override func setUp() {
        super.setUp()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    /// One launch on each retired stack: its curve and its coin, distinct per stack.
    private func launch(on stack: LaunchpadAddresses) -> (curve: Address, coin: Address) {
        let tag = stack.factory.data.prefix(2)
        return (Address(data: Data(count: 16) + tag + Data([0xcc, 0x01]))!, Address(data: Data(count: 16) + tag + Data([0xc0, 0x1d]))!)
    }

    /// Every retired factory's `curveToToken`: its own launch's curve maps to its coin, anything else to address 0.
    private func install() {
        let launches = Dictionary(uniqueKeysWithValues: LaunchpadAddresses.retiredStacks.map { ($0.factory, launch(on: $0)) })
        MomentsChainStub.install { to, data in
            guard data.prefix(4) == ABI.selector(LaunchpadABI.Factory.curveToToken), let own = launches[to] else { return nil }
            let asked = ABIWords(data.dropFirst(4)).address(0)
            return try! ABI.encode([.address(asked == own.curve ? own.coin : .zero)], "address")
        }
    }

    private func lookup(_ calls: [Policy.Call]) async -> Policy.RetiredCurves {
        await RetiredLaunchpad.curves(among: Policy.curveCandidates(calls), multicall: Multicall(rpc: MomentsChainStub.rpc()))
    }

    private func call(_ to: Address, _ data: Data, value: BigUInt = 0) -> Policy.Call {
        Policy.Call(from: account, to: to, data: data, value: value)
    }

    private func buy(_ curve: Address, _ amount: BigUInt, value: BigUInt = 0) -> Policy.Call {
        call(curve, LaunchpadABI.calldata(LaunchpadABI.Curve.buy, [.uint(amount), .uint(1), .address(account)]), value: value)
    }

    private func sell(_ curve: Address, _ amount: BigUInt) -> Policy.Call {
        call(curve, LaunchpadABI.calldata(LaunchpadABI.Curve.sell, [.uint(amount), .uint(1), .address(account)]))
    }

    private func approve(_ token: Address, _ spender: Address, _ amount: BigUInt) -> Policy.Call {
        call(token, try! ERC20.approveCalldata(spender: spender, amount: amount))
    }

    /// Every intent a sheet could declare around a curve buy, the session-scoped ones and those that always ask.
    private func intents(coin: Address) -> [Intent] {
        [.launchpadBuy(token: coin, pay: .init(token: Monad.native, amount: monIn), usd: 20),
         .launchpadBuy(token: coin, pay: .init(token: Monad.usdc, amount: usdcIn), usd: 5),
         .launchpadSell(token: coin, amount: monIn, usd: 5), .ask, .alwaysAsks(.unlisted), .alwaysAsks(.launch)]
    }

    // MARK: Buys refused

    func testABuyOnEachRetiredCurveIsRefusedWhateverTheSheetSays() async {
        install()
        for stack in LaunchpadAddresses.retiredStacks {
            let (curve, coin) = launch(on: stack)
            let native = buy(curve, monIn, value: monIn)
            let pairApproval = approve(Monad.usdc, curve, usdcIn)
            let erc20 = buy(curve, usdcIn)
            let retired = await lookup([pairApproval, erc20, native])
            XCTAssertEqual(retired, .known([curve: coin]), stack.factory.short)
            for intent in intents(coin: coin) {
                for (name, step) in [("native buy", native), ("pair approval", pairApproval), ("ERC-20 buy", erc20)] {
                    XCTAssertEqual(Policy.refusal(step, intent: intent, account: account, retiredCurves: retired), .retiredLaunchpad, "\(stack.factory.short) \(name)")
                }
            }
            // Each transaction signed on its own is looked up on its own, and refused the same way.
            for step in [native, pairApproval, erc20] {
                let alone = await lookup([step])
                XCTAssertEqual(Policy.refusal(step, intent: .ask, account: account, retiredCurves: alone), .retiredLaunchpad)
            }
        }
        XCTAssertEqual(Policy.Reason.retiredLaunchpad.summary, "a buy on a retired launchpad, which only takes sells")
    }

    /// The lookup asks each candidate of every retired factory, in one aggregate, and nothing else.
    func testTheLookupAsksEveryRetiredFactoryOnce() async {
        install()
        let curves = LaunchpadAddresses.retiredStacks.map { launch(on: $0).curve }
        let retired = await lookup(curves.map { buy($0, monIn, value: monIn) })
        XCTAssertEqual(retired, .known(Dictionary(uniqueKeysWithValues: LaunchpadAddresses.retiredStacks.map { (launch(on: $0).curve, launch(on: $0).coin) })))
        let batches = MomentsChainStub.batches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, curves.count * LaunchpadAddresses.retiredFactories.count)
        XCTAssertEqual(Set(batches.first?.map(\.to) ?? []), Set(LaunchpadAddresses.retiredFactories))
        XCTAssertTrue(MomentsChainStub.calls().allSatisfy { $0.selector == ABI.selector(LaunchpadABI.Factory.curveToToken).hexString })
        // A plan that pays into no curve looks nothing up.
        let swap = [approve(Monad.usdc, Uniswap.permit2, usdcIn), call(Uniswap.universalRouter, Data([0x35, 0x93, 0x56, 0x4c]))]
        XCTAssertEqual(Policy.curveCandidates(swap), [])
        let none = await lookup(swap)
        XCTAssertEqual(none, .none)
        XCTAssertEqual(MomentsChainStub.batches().count, 1, "no second read")
    }

    /// A developer buy through each retired router — `launchAndBuy`, or the pair approval for it — is refused without any
    /// lookup; the v2 router's is not (a launch always asks for Face ID instead).
    func testLaunchAndBuyOnEachRetiredRouterIsRefused() async throws {
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.launchpad)
        let input = LaunchInput(name: "Old", symbol: "OLD", pairToken: .zero, initialBuy: monIn, minTokensOut: 1)
        let plan = try await service.launchPlan(input, launchFee: 0, from: account)
        let data = try XCTUnwrap(plan.last?.request?.data)
        XCTAssertEqual(data.prefix(4), ABI.selector(LaunchpadABI.Router.launchAndBuy))
        for router in LaunchpadAddresses.retiredRouters {
            for intent in [Intent.alwaysAsks(.launch), .ask] {
                XCTAssertEqual(Policy.refusal(call(router, data, value: monIn), intent: intent, account: account), .retiredLaunchpad, router.short)
                XCTAssertEqual(Policy.refusal(approve(Monad.usdc, router, usdcIn), intent: intent, account: account), .retiredLaunchpad, router.short)
            }
        }
        XCTAssertNil(Policy.refusal(call(V2Fixture.launchpad.router, data, value: monIn), intent: .alwaysAsks(.launch), account: account))
        XCTAssertNil(Policy.refusal(approve(Monad.usdc, V2Fixture.launchpad.router, usdcIn), intent: .alwaysAsks(.launch), account: account))
    }

    // MARK: What stays open

    /// Holders sell into each retired curve: approving the coin for its own curve and the `sell` are never refused, and
    /// a live session signs them within the caps as before.
    func testASellOnEachRetiredCurveStaysOpen() async {
        install()
        for stack in LaunchpadAddresses.retiredStacks {
            let (curve, coin) = launch(on: stack)
            let steps = [approve(coin, curve, 5_000), sell(curve, 5_000)]
            let retired = await lookup(steps)
            XCTAssertEqual(retired, .known([curve: coin]))
            let intent = Intent.launchpadSell(token: coin, amount: 5_000, usd: 5)
            for step in steps { XCTAssertNil(Policy.refusal(step, intent: intent, account: account, retiredCurves: retired), stack.factory.short) }
            let context = Policy.Context(account: account, expiresAt: now.addingTimeInterval(900), verifiedCurves: [coin: curve])
            XCTAssertEqual(Policy.review(steps, intent: intent, context: context, caps: Mera.SpendingCaps()), .allowed, stack.factory.short)
        }
    }

    /// A v2 curve is recorded by no retired factory: its buys are neither refused nor asked more than before.
    func testAV2CurveBuyIsUnaffected() async {
        install()
        let native = buy(v2Curve, monIn, value: monIn)
        let pairApproval = approve(Monad.usdc, v2Curve, usdcIn)
        let retired = await lookup([pairApproval, buy(v2Curve, usdcIn), native])
        XCTAssertEqual(retired, .none)
        let intent = Intent.launchpadBuy(token: v2Coin, pay: .init(token: Monad.native, amount: monIn), usd: 20)
        XCTAssertNil(Policy.refusal(native, intent: intent, account: account, retiredCurves: retired))
        XCTAssertNil(Policy.refusal(pairApproval, intent: .ask, account: account, retiredCurves: retired))
        let context = Policy.Context(account: account, expiresAt: now.addingTimeInterval(900), verifiedCurves: [v2Coin: v2Curve])
        XCTAssertEqual(Policy.review([native], intent: intent, context: context, caps: Mera.SpendingCaps()), .allowed)
    }

    /// When the lookup fails no curve can be ruled out: every curve `buy` is refused as unverified, while approvals and
    /// sells (which can't buy by themselves) stay open.
    func testAFailedLookupRefusesCurveBuysOnly() async {
        MomentsChainStub.install { _, _ in nil } // every read reverts
        let native = buy(v2Curve, monIn, value: monIn)
        let failed = await lookup([native])
        XCTAssertEqual(failed, .unknown)
        XCTAssertEqual(Policy.refusal(native, intent: .launchpadBuy(token: v2Coin, pay: .init(token: Monad.native, amount: monIn), usd: 20), account: account, retiredCurves: failed), .unverifiedCurve)
        XCTAssertNil(Policy.refusal(approve(v2Coin, v2Curve, 5_000), intent: .ask, account: account, retiredCurves: failed))
        XCTAssertNil(Policy.refusal(sell(v2Curve, 5_000), intent: .launchpadSell(token: v2Coin, amount: 5_000, usd: 5), account: account, retiredCurves: failed))
        // The pure half: a missing or failed answer, or answers that don't line up, is unknown.
        struct Down: Error {}
        let factories = LaunchpadAddresses.retiredFactories
        XCTAssertEqual(RetiredLaunchpad.curves(candidates: [v2Curve], factories: factories, results: []), .unknown)
        XCTAssertEqual(RetiredLaunchpad.curves(candidates: [v2Curve], factories: factories, results: factories.map { _ in .failure(Down()) }), .unknown)
        XCTAssertEqual(RetiredLaunchpad.curves(candidates: [v2Curve], factories: factories, results: factories.map { _ in .success([.address(.zero)]) }), .none)
    }

    /// What the wallet looks up before `refusal`: every curve `buy` target and every approval spender, except the swap
    /// routers, Permit2 and Perpl.
    func testCurveCandidates() {
        let curve = launch(on: LaunchpadAddresses.retiredStacks[0]).curve
        let calls = [approve(Monad.usdc, Uniswap.permit2, 1), approve(Monad.usdc, Uniswap.swapRouter02, 1), approve(Monad.usdc, MondayTrade.swapRouter, 1),
                     approve(Monad.usdc, Kuru.entrypoint, 1), approve(Perpl.collateral, Perpl.exchange, 1),
                     approve(Monad.usdc, v2Curve, 1), buy(curve, 1), sell(v2Coin, 1), call(curve, Data([1, 2]))]
        XCTAssertEqual(Policy.curveCandidates(calls), [v2Curve, curve])
    }
}
