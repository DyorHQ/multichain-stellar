import BigInt
import XCTest
@testable import DyorKit

/// Swap never buys a coin still on a retired launchpad's curve (owner decision 2026-09-28): for a coin on each of the four
/// retired stacks, in each phase before graduation, every venue is refused with the same notice — paying with MON or
/// USDC — and no quote is ever shown: a round checks the coin alongside the on-chain venues and shows nothing they answer
/// until the check clears it, Kuru Flow is never asked, and one venue alone is never asked. Selling it is never checked.
/// A coin that graduated from a retired stack routes both ways: through its Uniswap v4 pool (0x6B1C, 0x10F3, 0x2F02) or
/// its Monday Trade pool (the legacy 0xad3d). Contract reads are answered by `MomentsChainStub`; Kuru Flow by
/// `SwapNetStub` (its fixed MON → USDC quote, which it blocks for any other pair).
final class SwapRetiredLaunchpadTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let amount = BigUInt(10).power(18)

    override func setUp() {
        super.setUp()
        SwapNetStub.reset()
        MomentsChainStub.install { _, _ in nil }
    }

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    /// The engine as the app builds it: Uniswap v4 routes through the graduated pools of the live stack (the v2 fixture
    /// here) and of the retired stacks with the current record. Its reads go to `host` when given
    /// (`MomentsChainStub.rpc(host:)`), so a check counts them alone, never a read of an earlier engine's round that was
    /// still on its way when that round returned.
    private func engine(host: String? = nil) -> SwapEngine {
        SwapEngine(rpc: host.map { MomentsChainStub.rpc(host: $0) } ?? MomentsChainStub.rpc(), session: SwapNetStub.session(),
                   launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad))
    }

    private func coin(_ chain: RetiredCoinChain) -> Token {
        Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: 50, account: account, exactApprovals: true)
    }

    /// The only reads a refused buy of one venue makes, sent to `host`: one aggregate asking each retired factory for the
    /// coin's record. Kuru Flow was never asked.
    private func assertOnlyTheRecordsWereRead(over host: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let selector = ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString
        let batches = MomentsChainStub.batches(host: host)
        XCTAssertEqual(batches.map { $0.map(\.to) }, [LaunchpadAddresses.retiredFactories], label, file: file, line: line)
        XCTAssertTrue(batches.joined().allSatisfy { $0.selector == selector }, label, file: file, line: line)
        XCTAssertEqual(SwapNetStub.recorded(), [], "\(label): Kuru Flow was never asked", file: file, line: line)
    }

    /// A round's refused buy, sent to `host`: the coin's record was read from each retired factory, in one aggregate of
    /// those records alone (the on-chain venues, asked alongside, read in reads of their own, Uniswap's launchpad pools
    /// among them), no update of the round ever carried a quote, and Kuru Flow was never asked.
    private func assertRefusedWithoutAQuote(_ updates: [QuoteResult], over host: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let selector = ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString
        let check = MomentsChainStub.batches(host: host).filter { $0.map(\.to) == LaunchpadAddresses.retiredFactories && $0.allSatisfy { $0.selector == selector } }
        XCTAssertEqual(check.count, 1, "\(label): the coin's check", file: file, line: line)
        XCTAssertTrue(updates.allSatisfy(\.quotes.isEmpty), "\(label): a quote was shown", file: file, line: line)
        XCTAssertEqual(updates.filter(\.isFinal).count, 1, label, file: file, line: line)
        XCTAssertTrue(updates.last?.isFinal ?? false, label, file: file, line: line)
        XCTAssertEqual(SwapNetStub.recorded(), [], "\(label): Kuru Flow was never asked", file: file, line: line)
    }

    // MARK: Sell-only coins

    func testNoVenueQuotesABuyOfACoinOnARetiredCurve() async throws {
        // Each engine reads over a host of its own, so each check counts its own reads alone.
        var engines = 0
        func host() -> String { engines += 1; return "rpc-\(engines).moments-stub.invalid" }
        for stack in LaunchpadAddresses.retiredStacks {
            for phase in [LaunchPhase.bonding, .migrating, .refund] {
                let chain = RetiredCoinChain(stack: stack, phase: phase)
                let coin = coin(chain)
                for pay in [Token.mon, Token.usdc] {
                    let label = "\(stack.factory.short) \(phase.title) \(pay.symbol) → coin"
                    MomentsChainStub.install(chain.answer)
                    SwapNetStub.reset()
                    let streamed = host()
                    var updates: [QuoteResult] = []
                    for await update in engine(host: streamed).quoteUpdates(for: request(pay, coin)) { updates.append(update) }
                    let result = updates.last ?? QuoteResult(pending: SwapEngine.quoteVenues)
                    XCTAssertTrue(result.quotes.isEmpty, label)
                    XCTAssertEqual(Set(result.errors.keys), Set(SwapEngine.quoteVenues), label)
                    for venue in SwapEngine.quoteVenues { XCTAssertEqual(result.errors[venue], RetiredLaunchpad.notice, "\(label) \(venue)") }
                    assertRefusedWithoutAQuote(updates, over: streamed, label)
                    let whole = await engine(host: host()).quotes(for: request(pay, coin))
                    XCTAssertTrue(whole.quotes.isEmpty, label)
                    for venue in SwapEngine.quoteVenues { XCTAssertEqual(whole.errors[venue], RetiredLaunchpad.notice, "\(label) \(venue)") }
                    XCTAssertEqual(SwapNetStub.recorded(), [], "\(label): Kuru Flow was never asked")

                    for venue in SwapEngine.quoteVenues {
                        let alone = host()
                        do {
                            let quote = try await engine(host: alone).quote(venue, for: request(pay, coin))
                            XCTFail("\(label): \(venue) quoted \(String(describing: quote?.route))")
                        } catch {
                            XCTAssertEqual(error as? SwapError, .retiredLaunchpad(chain.coin), "\(label) \(venue)")
                        }
                        assertOnlyTheRecordsWereRead(over: alone, "\(label) \(venue)")
                    }
                    let refusal = await engine().buyRefusal(coin)
                    XCTAssertEqual(refusal, .retiredLaunchpad(chain.coin), label)
                }
            }
        }
        XCTAssertEqual(SwapError.retiredLaunchpad(.zero).errorDescription, "This coin's launchpad is retired: you can sell, but not buy.")
    }

    /// Selling it is never checked: the coin as the pay side reaches the venues (none has a pool for it, since it never
    /// graduated), and no venue answers with the retired-launchpad notice.
    func testSellingACoinOnARetiredCurveIsNotRefused() async {
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            let chain = RetiredCoinChain(stack: stack, phase: .bonding)
            MomentsChainStub.install(chain.answer)
            for receive in [Token.mon, Token.usdc] {
                let result = await engine.quotes(for: request(coin(chain), receive))
                XCTAssertEqual(Set(result.errors.keys), Set(SwapEngine.quoteVenues))
                XCTAssertFalse(result.errors.values.contains(RetiredLaunchpad.notice), "\(stack.factory.short) → \(receive.symbol): \(result.errors)")
            }
            XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"), "the venues were asked")
        }
    }

    // MARK: Graduated coins

    /// A coin that graduated from each retired stack is an ordinary pool token: bought and sold against MON through its
    /// pool — Uniswap v4 on the stack's hook, or Monday Trade for the legacy stack's coins.
    func testAGraduatedRetiredCoinRoutesBothWays() async throws {
        let engine = engine()
        for stack in LaunchpadAddresses.retiredStacks {
            let chain = RetiredCoinChain(stack: stack, phase: .graduated)
            let coin = coin(chain)
            MomentsChainStub.install(chain.answer)
            let refusal = await engine.buyRefusal(coin)
            XCTAssertNil(refusal, stack.factory.short)
            let venue: Venue = chain.venue == .monday ? .monday : .uniswap
            for (tokenIn, tokenOut) in [(Token.mon, coin), (coin, Token.mon)] {
                let label = "\(stack.factory.short) \(tokenIn.symbol) → \(tokenOut.symbol)"
                let result = await engine.quotes(for: request(tokenIn, tokenOut))
                let quote = try XCTUnwrap(result.quotes.first { $0.venue == venue }, "\(label): \(result.errors)")
                XCTAssertEqual(quote.amountOut, RetiredCoinChain.out, label)
                XCTAssertFalse(result.errors.values.contains(RetiredLaunchpad.notice), label)
                if venue == .uniswap {
                    XCTAssertEqual(quote.route, "v4 · \(tokenIn.symbol) → \(tokenOut.symbol) · launchpad", label)
                } else {
                    XCTAssertTrue(quote.route.hasSuffix("· 1%"), "\(label): \(quote.route)")
                }
                let steps = try await quote.build(account)
                XCTAssertEqual(steps.last?.request?.to, venue == .uniswap ? Uniswap.universalRouter : MondayTrade.swapRouter, label)
            }
        }
    }

    // MARK: Reads

    /// A read that fails refuses the buy (nothing could rule the coin out); the app's own tokens are never read.
    func testAFailedReadRefusesAndTheAppsOwnTokensAreNeverRead() async {
        let engine = engine()
        let unknown = Token(address: Address(literal: "0x00000000000000000000000000000000000c0100"), symbol: "NEW", name: "New coin", decimals: 18)
        let refusal = await engine.buyRefusal(unknown)
        XCTAssertEqual(refusal, .launchpadUnchecked)
        let result = await engine.quotes(for: request(.mon, unknown))
        XCTAssertTrue(result.quotes.isEmpty)
        XCTAssertEqual(result.errors[.kuru], SwapError.launchpadUnchecked.errorDescription)

        MomentsChainStub.install { _, _ in nil }
        for token in Token.core + [Token.mon] {
            let none = await engine.buyRefusal(token)
            XCTAssertNil(none, token.symbol)
        }
        XCTAssertTrue(MomentsChainStub.calls().isEmpty, "MON, WMON, the stablecoins and pair assets are no launchpad coin")
        XCTAssertFalse(SwapEngine.mayBeLaunchCoin(.usdc))
        XCTAssertTrue(SwapEngine.mayBeLaunchCoin(unknown))
    }

    /// The record check Swap's buy refusal runs (`RetiredLaunchpad.sellOnlyCoins`, through the launchpads' curve check
    /// `LaunchpadCurve.curveRecords(queries:results:)`), per layout: a record that exists and has no pool is on the curve,
    /// a graduated or missing one is not, and a failed answer, or an answer missing or extra, throws.
    func testSellOnlyRecords() throws {
        let coin = Address(literal: "0x00000000000000000000000000000000000c0100")
        struct Down: Error {}
        for stack in LaunchpadAddresses.retiredStacks {
            let label = stack.factory.short
            for phase in LaunchPhase.allCases {
                let found = try LaunchpadCurve.curveRecords(queries: [(coin, stack)], results: [Self.record(coin, on: stack, phase)])
                XCTAssertEqual(Set(found.keys), phase == .graduated ? [] : [coin], "\(label) \(phase.title)")
                if let hit = found[coin] {
                    XCTAssertEqual(hit.stack, stack, "\(label) \(phase.title)")
                    XCTAssertEqual(hit.record.phase, phase, "\(label) \(phase.title): read in the stack's own layout")
                }
            }
            XCTAssertTrue(try LaunchpadCurve.curveRecords(queries: [(coin, stack)], results: [Self.record(coin, on: stack, .bonding, exists: false)]).isEmpty, label)
            XCTAssertThrowsError(try LaunchpadCurve.curveRecords(queries: [(coin, stack)], results: [.failure(Down())]), label)
            XCTAssertThrowsError(try LaunchpadCurve.curveRecords(queries: [(coin, stack)], results: []), label)
            XCTAssertThrowsError(try LaunchpadCurve.curveRecords(queries: [(coin, stack)], results: [Self.record(coin, on: stack, .bonding), Self.record(coin, on: stack, .bonding)]), label)
        }
    }

    /// The same check over several stacks, as `sellOnlyCoins` asks every retired factory for each coin: a coin is kept
    /// once, with the first stack that has it on its curve (a graduated record ahead of it is passed over), a coin no
    /// stack has on its curve is left out, and one factory's answer missing throws for all of them.
    func testSellOnlyRecordsAcrossTheRetiredStacks() throws {
        let coin = Address(literal: "0x00000000000000000000000000000000000c0100")
        let other = Address(literal: "0x00000000000000000000000000000000000c0200")
        let stacks = LaunchpadAddresses.retiredStacks
        XCTAssertGreaterThanOrEqual(stacks.count, 4)
        struct Down: Error {}
        // Coin-major, as the aggregate asks: `coin` graduated on the first stack, in refund mode on the second, on the
        // third's curve too, unknown to the fourth; `other` unknown to all of them.
        let queries = [coin, other].flatMap { token in stacks.map { (token: token, stack: $0) } }
        let coinRecords = [Self.record(coin, on: stacks[0], .graduated), Self.record(coin, on: stacks[1], .refund), Self.record(coin, on: stacks[2], .bonding),
                           Self.record(coin, on: stacks[3], .bonding, exists: false)] + stacks.dropFirst(4).map { Self.record(coin, on: $0, .bonding, exists: false) }
        let otherRecords = stacks.map { Self.record(other, on: $0, .bonding, exists: false) }
        let found = try LaunchpadCurve.curveRecords(queries: queries, results: coinRecords + otherRecords)
        XCTAssertEqual(Set(found.keys), [coin], "each coin once; the unknown one left out")
        XCTAssertEqual(found[coin]?.stack, stacks[1], "the first stack that has it on its curve")
        XCTAssertEqual(found[coin]?.record.phase, .refund)

        // The same coin asked twice of one stack (a list holding it twice): kept once.
        let twice = try LaunchpadCurve.curveRecords(queries: [(coin, stacks[2]), (coin, stacks[2])], results: [Self.record(coin, on: stacks[2], .bonding), Self.record(coin, on: stacks[2], .migrating)])
        XCTAssertEqual(Set(twice.keys), [coin])
        XCTAssertEqual(twice[coin]?.record.phase, .bonding, "the first answer")

        // One factory's answer failing, after another already had the coin on its curve: no coin can be ruled in or out.
        var failing = coinRecords + otherRecords
        failing[stacks.count + 1] = .failure(Down())
        XCTAssertThrowsError(try LaunchpadCurve.curveRecords(queries: queries, results: failing))
        XCTAssertThrowsError(try LaunchpadCurve.curveRecords(queries: queries, results: Array((coinRecords + otherRecords).dropLast())))
    }

    /// `token`'s `getLaunchedToken` answer from `stack`'s factory, in that stack's record layout.
    private static func record(_ token: Address, on stack: LaunchpadAddresses, _ phase: LaunchPhase, exists: Bool = true) -> Result<[ABIValue], Error> {
        let legacy = stack.generation.legacyRecord
        return .success([RetiredCoinChain.record(token: token, curve: token, phase: phase, venue: legacy ? .monday : .uniswapV4, exists: exists, legacy: legacy)])
    }
}

/// One coin launched on one retired stack, in `phase`, answered from memory: every retired factory's `getLaunchedToken`
/// (an empty record, in its own layout, from the others), and once graduated its pool — a Uniswap v4 pool on the stack's
/// hook, quoted by the V4Quoter, or for the legacy stack a 1% Monday Trade pool against WMON, quoted by Monday's QuoterV2.
/// Every other pool lookup answers "none"; every other call reverts.
struct RetiredCoinChain: Sendable {
    let stack: LaunchpadAddresses
    let phase: LaunchPhase
    let coin = Address(literal: "0x00000000000000000000000000000000000c01d0")
    let curve = Address(literal: "0x00000000000000000000000000000000000c01c0")
    let mondayPool = Address(literal: "0x00000000000000000000000000000000000c0b00")
    static let out = BigUInt(777_000)

    var venue: GraduationVenue { stack.generation.legacyRecord ? .monday : .uniswapV4 }

    static func record(token: Address, curve: Address, phase: LaunchPhase, venue: GraduationVenue, exists: Bool, legacy: Bool) -> ABIValue {
        var fields: [ABIValue] = [.address(token), .address(curve), .address(token), .address(token), .address(.zero), .uint(1_000), .uint(0), .uint(100), .int(60), .bool(false),
                                  .uint(BigUInt(venue.rawValue)), .uint(BigUInt(phase.rawValue)), .uint(0), .uint(0), .uint(0), .bytes(Data(count: 32)), .bool(exists)]
        if legacy { fields.remove(at: 10) }
        return .tuple(fields)
    }

    func answer(_ to: Address, _ data: Data) -> Data? {
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func is_(_ signature: String) -> Bool { selector == ABI.selector(signature) }
        func encode(_ values: [ABIValue], _ types: String) -> Data { try! ABI.encode(values, types) }
        let graduated = phase == .graduated
        if is_(LaunchpadABI.Factory.getLaunchedToken), let retired = LaunchpadAddresses.retiredStack(for: to) {
            let legacy = retired.generation.legacyRecord
            let ours = to == stack.factory && args.address(0) == coin
            return encode([Self.record(token: ours ? coin : .zero, curve: ours ? curve : .zero, phase: ours ? phase : .bonding, venue: venue, exists: ours, legacy: legacy)],
                          LaunchpadABI.launchedTokenReturns(legacy: legacy))
        }
        if is_(LaunchpadABI.Factory.poolKeyOf), to == stack.factory, graduated, venue == .uniswapV4, args.address(0) == coin {
            return encode([.tuple([.address(.zero), .address(coin), .uint(0), .int(60), .address(stack.hook)])], LaunchpadABI.poolKeyTuple)
        }
        if to == Uniswap.v4Quoter, is_("quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))"), graduated, venue == .uniswapV4 {
            return encode([.uint(Self.out), .uint(150_000)], "uint256,uint256")
        }
        if is_("getPool(address,address,uint24)"), to == Uniswap.v3Factory || to == MondayTrade.factory {
            let pair = Set([args.address(0), args.address(1)].compactMap { $0 })
            let ours = to == MondayTrade.factory && graduated && venue == .monday && pair == [Monad.wmon, coin] && args.uint(2) == 10_000
            return encode([.address(ours ? mondayPool : .zero)], "address")
        }
        if to == mondayPool, is_("liquidity()") { return encode([.uint(BigUInt(10).power(21))], "uint128") }
        if to == MondayTrade.quoterV2, is_("quoteExactInputSingle((address,address,uint256,uint24,uint160))") {
            return encode([.uint(Self.out), .uint(0), .uint(0), .uint(150_000)], "uint256,uint160,uint32,uint256")
        }
        return nil
    }
}
