import BigInt
import XCTest
@testable import DyorKit

/// Swap's quotes arrive as each venue answers (speed work, 2026-10-10): `SwapEngine.quoteUpdates` publishes the best so
/// far with the venues still asked, and only its last update is final, the one the screen may review; a venue the person
/// picked stays selected until then (`VenueSelection`). The check of the coin bought runs alongside the on-chain venues,
/// nothing they answer is shown until it clears, and Kuru Flow is asked a coin that may be a launchpad's only after it.
/// The route search (each pair's pools, each coin's graduated pool) is kept a minute in the shared reads, so an amount
/// change costs each venue its one quote read, which carries the price-impact slice too. Kuru Flow's token is asked for
/// once as Swap opens, the first quote shares it, and a quote's wait for it ends with the quote. Contract reads are
/// answered by `MomentsChainStub` (which can hold a read, `hold(_:)`); Kuru Flow by `SwapNetStub`, or by
/// `GatedKuruStub`, which holds its answers until a test lets them go.
final class SwapQuoteStreamTests: XCTestCase {
    private let account = Address(literal: "0x1111111111111111111111111111111111111111")
    private let oneMON = BigUInt(10).power(18)

    override func setUp() {
        super.setUp()
        SwapNetStub.reset()
        GatedKuruStub.reset()
        MomentsChainStub.install(MonUsdcChain.answer)
    }

    override func tearDown() {
        GatedKuruStub.release()
        MomentsChainStub.releaseHeld()
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func request(_ tokenIn: Token, _ tokenOut: Token, _ amount: BigUInt) -> SwapRequest {
        SwapRequest(tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amount, slippageBps: 50, account: account)
    }

    private static let getPool = ABI.selector("getPool(address,address,uint24)").hexString
    private static let v3Quote = ABI.selector("quoteExactInputSingle((address,address,uint256,uint24,uint160))").hexString

    // MARK: The tally

    /// A round's answers as they arrive: the quotes so far ranked best first (ties in venue order), each answered
    /// venue's reason for having none, and the venues not heard from yet, in venue order; final once all have answered.
    func testATallyListsWhatHasAnsweredAndWhatIsStillAsked() {
        func quote(_ venue: Venue, _ out: BigUInt) -> VenueQuote {
            VenueQuote(venue: venue, amountOut: out, minOut: out, route: venue.rawValue, gasEstimate: nil, priceImpactBps: nil) { _ in [] }
        }
        var tally = QuoteTally(venues: SwapEngine.quoteVenues)
        XCTAssertEqual(tally.result.pending, [.kuru, .uniswap, .monday])
        XCTAssertFalse(tally.result.isFinal)
        XCTAssertTrue(tally.result.quotes.isEmpty)
        XCTAssertTrue(tally.result.errors.isEmpty)

        tally.record(.uniswap, .success(quote(.uniswap, 100)))
        XCTAssertEqual(tally.result.pending, [.kuru, .monday])
        XCTAssertEqual(tally.result.quotes.map(\.venue), [.uniswap])
        XCTAssertFalse(tally.isComplete)

        tally.record(.monday, .success(nil))
        XCTAssertEqual(tally.result.pending, [.kuru])
        XCTAssertEqual(tally.result.errors[.monday], "No route for this pair.")
        XCTAssertNil(tally.result.errors[.kuru], "a venue still asked has no reason yet")

        var timedOut = tally
        timedOut.record(.kuru, .failure(SwapError.timedOut(.kuru, seconds: 20)))
        XCTAssertTrue(timedOut.isComplete)
        XCTAssertTrue(timedOut.result.isFinal)
        XCTAssertEqual(timedOut.result.pending, [])
        XCTAssertEqual(timedOut.result.quotes.map(\.venue), [.uniswap])
        XCTAssertEqual(timedOut.result.errors[.kuru], SwapError.timedOut(.kuru, seconds: 20).errorDescription)

        tally.record(.kuru, .success(quote(.kuru, 100)))
        XCTAssertTrue(tally.result.isFinal)
        XCTAssertEqual(tally.result.quotes.map(\.venue), [.kuru, .uniswap], "a tie keeps venue order")
        tally.record(.monday, .success(quote(.monday, 101)))
        XCTAssertEqual(tally.result.quotes.map(\.venue), [.monday, .kuru, .uniswap], "best output first")
        XCTAssertNil(tally.result.errors[.monday], "a later answer replaces the reason")
        XCTAssertTrue(QuoteResult().isFinal, "an answer given at once (a wrap, a refusal, nothing to quote) is final")
    }

    // MARK: The venue selected

    /// A venue the person picked stays selected through a round's answers: an answer under way without it — no venue yet,
    /// then only another one — never moves the selection, while the screen shows the best so far; the final answer keeps
    /// it when it quotes it, even below the best, and gives the selection back to the best quote when it doesn't, which
    /// the selection then follows. With no pick, the selection is the best quote, so far or final.
    func testAPickedVenueStaysSelectedUntilTheFinalAnswer() {
        func quote(_ venue: Venue, _ out: BigUInt) -> VenueQuote {
            VenueQuote(venue: venue, amountOut: out, minOut: out, route: venue.rawValue, gasEstimate: nil, priceImpactBps: nil) { _ in [] }
        }
        let picked = VenueSelection(venue: .monday, picked: true)
        let nothingYet = QuoteResult(pending: [.kuru, .uniswap, .monday])
        let first = picked.following(nothingYet)
        XCTAssertEqual(first, picked, "no venue has answered: the pick stands")
        XCTAssertNil(first.shown(in: nothingYet))

        let onlyUniswap = QuoteResult(quotes: [quote(.uniswap, 100)], errors: [.kuru: "No route for this pair."], pending: [.monday])
        let second = first.following(onlyUniswap)
        XCTAssertEqual(second, picked, "another venue's quote never takes the pick's place")
        XCTAssertEqual(second.shown(in: onlyUniswap)?.venue, .uniswap, "the best so far is shown meanwhile")

        let final = QuoteResult(quotes: [quote(.uniswap, 100), quote(.monday, 90)], errors: [.kuru: "No route for this pair."])
        let kept = second.following(final)
        XCTAssertEqual(kept, picked, "the final answer quotes it: kept, though Uniswap's is better")
        XCTAssertEqual(kept.shown(in: final)?.venue, .monday, "and it is what is shown, and reviewed")

        let without = QuoteResult(quotes: [quote(.uniswap, 100)], errors: [.kuru: "No route for this pair.", .monday: "Monday Trade timed out."])
        let given = second.following(without)
        XCTAssertEqual(given, VenueSelection(venue: .uniswap, picked: false), "a final answer without it: the best, followed from now on")
        let later = QuoteResult(quotes: [quote(.kuru, 120), quote(.uniswap, 100)], errors: [.monday: "No route for this pair."])
        XCTAssertEqual(given.following(later), VenueSelection(venue: .kuru, picked: false))

        let none = VenueSelection()
        XCTAssertEqual(none.following(nothingYet), VenueSelection())
        XCTAssertEqual(none.following(onlyUniswap), VenueSelection(venue: .uniswap), "the best so far")
        XCTAssertEqual(none.following(onlyUniswap).following(later), VenueSelection(venue: .kuru), "then the final best")
    }

    // MARK: Quotes as they arrive

    /// Uniswap's quote shows while Kuru Flow is still answering: an update that names Kuru as still asked and is not
    /// final, then the final result with both, ranked. The price impact came in the quote's own read: one read of the
    /// quoter with the amount and the 1/1000 slice, and no other.
    func testEachVenuesQuoteShowsAsItArrivesAndOnlyTheLastIsFinal() async throws {
        GatedKuruStub.reset(holdQuotes: true)
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: GatedKuruStub.session())
        var updates: [QuoteResult] = []
        for await update in engine.quoteUpdates(for: request(.mon, .usdc, oneMON)) {
            updates.append(update)
            // Both contract venues answered while Kuru Flow's answer is held: let it go.
            if update.pending == [.kuru] { GatedKuruStub.release() }
        }
        let final = try XCTUnwrap(updates.last)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(updates.filter(\.isFinal).count, 1, "only the last update is final")
        let early = try XCTUnwrap(updates.first { $0.pending == [.kuru] }, "an update before Kuru Flow answered")
        XCTAssertFalse(early.isFinal)
        XCTAssertEqual(early.quotes.map(\.venue), [.uniswap])
        XCTAssertEqual(early.best?.amountOut, MonUsdcChain.uniswapOut)
        XCTAssertEqual(early.errors[.monday], "No route for this pair.")
        XCTAssertNil(early.errors[.kuru])
        for update in updates.dropLast() { XCTAssertTrue(update.pending.contains(.kuru), "nothing is final before Kuru Flow answers") }

        XCTAssertEqual(final.quotes.map(\.venue), [.kuru, .uniswap])
        XCTAssertEqual(final.best?.amountOut, SwapNetStub.kuruOutput)
        XCTAssertEqual(final.errors.keys.sorted { $0.rawValue < $1.rawValue }, [.monday])

        let uniswap = try XCTUnwrap(final.quotes.first { $0.venue == .uniswap })
        let slice = oneMON / 1000
        XCTAssertEqual(uniswap.priceImpactBps, SwapMath.impactBps(amountIn: oneMON, amountOut: MonUsdcChain.uniswapOut, sliceIn: slice,
                                                                    sliceOut: MonUsdcChain.out(slice)))
        XCTAssertEqual(uniswap.priceImpactBps, 39)
        let quoterReads = MomentsChainStub.batches().filter { $0.contains { $0.to == Uniswap.quoterV2 } }
        XCTAssertEqual(quoterReads.count, 1, "the slice is quoted in the quote's own read")
        XCTAssertEqual(quoterReads.first?.count, 2, "the amount and the slice")

        // `quotes(for:)` is the final result alone.
        GatedKuruStub.reset()
        let whole = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertTrue(whole.isFinal)
        XCTAssertEqual(whole.quotes.map(\.venue), [.kuru, .uniswap])
    }

    /// A buy of a coin still on a retired launchpad's curve is checked alongside the on-chain venues: a venue that has a
    /// pool for it (Monday Trade here) never has its quote shown, in any update, even when it quotes before the check
    /// answers — the check is held here until Monday Trade's quote read has been answered — and the round ends refused
    /// under every venue. Kuru Flow, which would be told the wallet and the coin, is never asked.
    func testABuyRefusedAlongsideTheVenuesShowsNothingTheyAnswered() async throws {
        let stack = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first)
        let chain = RetiredCoinChain(stack: stack, phase: .bonding)
        let pool = Address(literal: "0x00000000000000000000000000000000000c0b01")
        let coin = Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
        MomentsChainStub.install { to, data in
            let args = ABIWords(data.dropFirst(4))
            if data.prefix(4) == ABI.selector("getPool(address,address,uint24)"), to == MondayTrade.factory,
               Set([args.address(0), args.address(1)].compactMap { $0 }) == [Monad.wmon, chain.coin], args.uint(2) == 10_000 {
                return try? ABI.encode([.address(pool)], "address")
            }
            if to == pool, data.prefix(4) == ABI.selector("liquidity()") { return try? ABI.encode([.uint(BigUInt(10).power(21))], "uint128") }
            return chain.answer(to, data)
        }
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad))

        MomentsChainStub.hold(Self.isTheCoinsCheck)
        let updates = Updates()
        let round = Task { for await update in engine.quoteUpdates(for: request(.mon, coin, oneMON)) { updates.append(update) } }
        // Monday Trade quoted the coin while its check is held: what it found reaches the round before the refusal.
        try await waitUntil { MomentsChainStub.calls().contains { $0.to == MondayTrade.quoterV2 } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(MomentsChainStub.heldCount(), 1, "the check is still held")
        XCTAssertTrue(updates.all.isEmpty, "nothing is published before the check answers")
        MomentsChainStub.releaseHeld()
        await round.value
        XCTAssertTrue(updates.all.allSatisfy(\.quotes.isEmpty), "no quote of a refused buy is ever shown: \(updates.all.map { $0.quotes.map(\.venue) })")
        let final = try XCTUnwrap(updates.all.last)
        XCTAssertTrue(final.isFinal)
        for venue in SwapEngine.quoteVenues { XCTAssertEqual(final.errors[venue], RetiredLaunchpad.notice, "\(venue)") }
        XCTAssertEqual(SwapNetStub.recorded(), [], "Kuru Flow was never asked")

        // Selling it is never checked: Monday Trade's pool quotes it.
        let sold = await engine.quotes(for: request(coin, .mon, oneMON))
        XCTAssertEqual(sold.quotes.map(\.venue), [.monday], "\(sold.errors)")
    }

    /// The mirror: a buy whose check clears the coin (one that graduated into a Uniswap v4 pool) publishes nothing while
    /// the check is held, however soon a venue quotes it, and asks Kuru Flow only once it has cleared; then the quotes
    /// show, and the round ends with Uniswap's.
    func testABuyIsShownOnlyOnceItsCheckClearsTheCoin() async throws {
        let stack = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first { !$0.generation.legacyRecord })
        let chain = RetiredCoinChain(stack: stack, phase: .graduated)
        let coin = Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
        MomentsChainStub.install(chain.answer)
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad))

        MomentsChainStub.hold(Self.isTheCoinsCheck)
        let updates = Updates()
        let round = Task { for await update in engine.quoteUpdates(for: request(.mon, coin, oneMON)) { updates.append(update) } }
        try await waitUntil { MomentsChainStub.calls().contains { $0.to == Uniswap.v4Quoter } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(MomentsChainStub.heldCount(), 1, "the check is still held")
        XCTAssertTrue(updates.all.isEmpty, "Uniswap's quote waits for the check")
        XCTAssertEqual(SwapNetStub.recorded(), [], "Kuru Flow waits for the check")
        MomentsChainStub.releaseHeld()
        await round.value
        let final = try XCTUnwrap(updates.all.last)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.quotes.first { $0.venue == .uniswap }?.amountOut, RetiredCoinChain.out, "\(final.errors)")
        XCTAssertFalse(final.errors.values.contains(RetiredLaunchpad.notice))
        XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"), "Kuru Flow asked once the coin cleared")

        // A buy of the app's own tokens needs no check: Kuru Flow is asked at once.
        SwapNetStub.reset()
        MomentsChainStub.install(MonUsdcChain.answer)
        _ = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertFalse(MomentsChainStub.batches().contains(where: Self.isTheCoinsCheck), "USDC is never checked")
        XCTAssertTrue(SwapNetStub.recorded().contains("\(Kuru.api.host ?? "")/api/quote"))
    }

    /// The coin's check (`SwapEngine.buyRefusal`): one aggregate asking every retired factory for the coin's record.
    private static let isTheCoinsCheck: @Sendable ([MomentsChainStub.Call]) -> Bool = { batch in
        batch.map(\.to) == LaunchpadAddresses.retiredFactories && batch.allSatisfy { $0.selector == ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString }
    }

    /// The updates of a round, as its task gets them.
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [QuoteResult] = []
        var all: [QuoteResult] { lock.lock(); defer { lock.unlock() }; return list }
        func append(_ update: QuoteResult) { lock.lock(); list.append(update); lock.unlock() }
    }

    // MARK: The route search, kept a minute

    /// With the shared reads, a second amount for the same pair asks only the quoter (one read, the amount and its
    /// slice); a flip reads no v4 pool again (a v4 pair is one whichever way round); without the shared reads, or once
    /// they are forgotten (`invalidate`), the pools are searched again.
    func testAnAmountChangeCostsOneQuoteRead() async throws {
        let cache = ChainCache()
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), cache: cache)
        let first = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertEqual(first.quotes.first { $0.venue == .uniswap }?.amountOut, MonUsdcChain.uniswapOut)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == Self.getPool }, "the first quote searches")

        MomentsChainStub.install(MonUsdcChain.answer)
        let second = await engine.quotes(for: request(.mon, .usdc, 2 * oneMON))
        XCTAssertEqual(second.quotes.first { $0.venue == .uniswap }?.amountOut, MonUsdcChain.out(2 * oneMON))
        XCTAssertEqual(MomentsChainStub.batches().map { $0.map(\.to) }, [[Uniswap.quoterV2, Uniswap.quoterV2]],
                       "one read: the amount and its slice, every pool kept from the first quote")
        XCTAssertTrue(MomentsChainStub.calls().allSatisfy { $0.selector == Self.v3Quote })

        MomentsChainStub.install(MonUsdcChain.answer)
        let flipped = await engine.quotes(for: request(.usdc, .mon, 2_600_000))
        XCTAssertEqual(flipped.quotes.first { $0.venue == .uniswap }?.amountOut, oneMON, "2.6 USDC buys a MON")
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == Uniswap.stateView }, "the v4 pools of a pair are kept whichever way round")
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.to == Uniswap.v3Factory }, "a v3 factory is asked in the order a route runs")

        cache.invalidate()
        MomentsChainStub.install(MonUsdcChain.answer)
        _ = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.to == Uniswap.stateView }, "forgotten: searched again")
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.to == MondayTrade.factory })

        let uncached = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session())
        _ = await uncached.quotes(for: request(.mon, .usdc, oneMON))
        MomentsChainStub.install(MonUsdcChain.answer)
        _ = await uncached.quotes(for: request(.mon, .usdc, 2 * oneMON))
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.selector == Self.getPool }, "no shared reads: every quote searches")
    }

    /// A coin's graduated launchpad pool is kept per coin: once bought through it, selling it reads neither the
    /// factories' records nor the pool key again (nor the v4 pools, a pair either way round), only the quote.
    func testACoinsGraduatedPoolIsKept() async throws {
        let stack = try XCTUnwrap(LaunchpadAddresses.retiredStacks.first { !$0.generation.legacyRecord })
        let chain = RetiredCoinChain(stack: stack, phase: .graduated)
        let coin = Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
        MomentsChainStub.install(chain.answer)
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(),
                                launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: V2Fixture.launchpad), cache: ChainCache())
        let bought = await engine.quotes(for: request(.mon, coin, oneMON))
        XCTAssertEqual(bought.quotes.first { $0.venue == .uniswap }?.route, "v4 · MON → OLD · launchpad", "\(bought.errors)")

        MomentsChainStub.install(chain.answer)
        let sold = await engine.quotes(for: request(coin, .mon, oneMON))
        XCTAssertEqual(sold.quotes.first { $0.venue == .uniswap }?.route, "v4 · OLD → MON · launchpad", "\(sold.errors)")
        let record = ABI.selector(LaunchpadABI.Factory.getLaunchedToken).hexString
        let poolKey = ABI.selector(LaunchpadABI.Factory.poolKeyOf).hexString
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.selector == record || $0.selector == poolKey }, "the coin's pool was kept")
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == Uniswap.stateView })
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.to == Uniswap.v4Quoter }, "the quote itself is read")
    }

    /// A search whose read fails keeps nothing: the next quote searches that venue's pools again, while what the other
    /// venues read is kept.
    func testAFailedSearchIsNotKept() async {
        let cache = ChainCache()
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: SwapNetStub.session(), cache: cache)
        MomentsChainStub.install(MonUsdcChain.answer, breaking: [Uniswap.v3Factory])
        let broken = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertFalse(broken.quotes.contains { $0.venue == .uniswap }, "Uniswap's v3 pools couldn't be read")

        MomentsChainStub.install(MonUsdcChain.answer)
        let mended = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertEqual(mended.quotes.first { $0.venue == .uniswap }?.amountOut, MonUsdcChain.uniswapOut)
        XCTAssertTrue(MomentsChainStub.calls().contains { $0.to == Uniswap.v3Factory }, "the failed search is made again")
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == MondayTrade.factory }, "Monday Trade's search succeeded and is kept")
        XCTAssertFalse(MomentsChainStub.calls().contains { $0.to == Uniswap.stateView }, "so is the v4 one")
    }

    // MARK: Kuru Flow's token

    /// Swap opening asks for Kuru Flow's token (`prepare`); a quote that needs it while that request is under way waits for
    /// it rather than asking again (Kuru takes one a second), and the next quote reuses it.
    func testSwapOpeningAsksForKurusTokenOnceAndTheFirstQuoteSharesIt() async throws {
        GatedKuruStub.reset(holdTokens: true)
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: GatedKuruStub.session())
        let tokenPath = "\(Kuru.api.host ?? "")/api/generate-token"
        let quotePath = "\(Kuru.api.host ?? "")/api/quote"
        let wallet = account
        let monForUSDC = request(.mon, .usdc, oneMON)
        let prepared = Task { await engine.prepare(for: wallet) }
        try await waitUntil { GatedKuruStub.recorded().contains(tokenPath) }
        let quoting = Task { await engine.quotes(for: monForUSDC) }
        // Time for the quote to reach Kuru Flow, where it waits on the token request under way.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(GatedKuruStub.recorded().filter { $0 == tokenPath }.count, 1, "the quote didn't ask for a token of its own")
        XCTAssertFalse(GatedKuruStub.recorded().contains(quotePath), "the quote waits for the token")
        GatedKuruStub.release()
        await prepared.value
        let result = await quoting.value
        XCTAssertEqual(result.best?.venue, .kuru, "\(result.errors)")
        _ = await engine.quotes(for: request(.mon, .usdc, oneMON))
        XCTAssertEqual(GatedKuruStub.recorded().filter { $0 == tokenPath }.count, 1, "one token for both quotes")
        XCTAssertEqual(GatedKuruStub.recorded().filter { $0 == quotePath }.count, 2)

        // A token already held is not asked for again when Swap opens.
        await engine.prepare(for: account)
        XCTAssertEqual(GatedKuruStub.recorded().filter { $0 == tokenPath }.count, 1)
    }

    /// A quote waiting for Kuru Flow's token stops waiting the moment its task is cancelled (a round refused, or past the
    /// venue's time, `SwapEngine.withTimeout`), while the token request goes on and its token is kept for the next quote:
    /// the wait was the shared request's own, which nothing could cancel, and held a refused round to the request's end.
    func testAQuoteWaitingForKurusTokenStopsWhenCancelled() async throws {
        GatedKuruStub.reset(holdTokens: true)
        let engine = SwapEngine(rpc: MomentsChainStub.rpc(), session: GatedKuruStub.session())
        let tokenPath = "\(Kuru.api.host ?? "")/api/generate-token"
        let monForUSDC = request(.mon, .usdc, oneMON)
        let quoting = Task { await engine.quotes(for: monForUSDC) }
        try await waitUntil { GatedKuruStub.recorded().contains(tokenPath) }
        // Time for the other venues to answer: Kuru Flow alone is left, waiting for its token.
        try await Task.sleep(for: .milliseconds(300))
        // Should the wait not stop, the token is let go after 3 s, so the test fails on the time rather than hanging.
        let backstop = Task { try? await Task.sleep(for: .seconds(3)); GatedKuruStub.release() }
        let started = ContinuousClock.now
        quoting.cancel()
        let cancelled = await quoting.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "never the token request's end")
        XCTAssertNil(cancelled.quotes.first { $0.venue == .kuru })
        backstop.cancel()

        GatedKuruStub.release()
        let next = await engine.quotes(for: monForUSDC)
        XCTAssertEqual(next.best?.venue, .kuru, "\(next.errors)")
        XCTAssertEqual(GatedKuruStub.recorded().filter { $0 == tokenPath }.count, 1, "the request went on, and its token was kept")
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    // MARK: The screen (pinned in the app's source)

    /// Swap shows the best so far and says how many venues are still asked, but Review takes only a final answer for the
    /// inputs on screen, wallet included; a venue the person picked stays selected through a round's answers, and is never
    /// called the best so far unless it is; a refresh keeps the final answer until its own is final; the venues' rows say
    /// which are still asked, and "Best" waits for them; the route search is kept in the app's shared reads; Kuru Flow's
    /// token is asked for as Swap opens.
    func testSwapReviewsOnlyAFinalAnswerForWhatIsOnScreen() throws {
        let swap = Self.squeezed(try DocsLinksTests.appSource("Swap/SwapView.swift"))
        XCTAssertTrue(swap.contains("var selectedQuote: VenueQuote? { guard currentResult?.isFinal == true else { return nil } return shownQuote }"))
        XCTAssertTrue(swap.contains("var currentResult: QuoteResult? { resultKey == quoteKey ? result : nil }"))
        XCTAssertTrue(swap.contains(#"var quoteKey: String { "\(tokenIn.address.hex)-\(tokenOut.address.hex)-\(amountIn)-\(slippageBps)-\(account?.hex ?? "")" }"#),
                      "the wallet is one of the inputs")
        XCTAssertTrue(swap.contains("PrimaryButton(title: model.actionTitle, isBusy: false, isDisabled: model.selectedQuote == nil || model.insufficient) { reviewing = model.review }"))
        XCTAssertTrue(swap.contains("var review: SwapReview? { guard let quote = selectedQuote else { return nil }"))
        XCTAssertTrue(swap.contains(#"if let quote = model.selectedQuote { Paragraph("Minimum received \("#), "the minimum shown is the one Review signs")
        // The amounts shown follow the best so far.
        XCTAssertTrue(swap.contains("if let quote = model.shownQuote { AmountText(amount: quote.amountOut, token: model.tokenOut, font: .title2.weight(.medium))"))
        XCTAssertTrue(swap.contains("guard let quote = shownQuote, let price = prices[tokenOut.address] else { return nil }"))
        // The loop: a first round's updates are shown as they arrive, a refresh's are not, and the final answer after the stream.
        XCTAssertTrue(swap.contains("let refreshing = resultKey == key && result?.isFinal == true"))
        XCTAssertTrue(swap.contains("for await update in env.swap.quoteUpdates(for: request) { last = update"))
        XCTAssertTrue(swap.contains("if update.isFinal || refreshing || Task.isCancelled { continue } result = update resultKey = key error = nil selection = selection.following(update) }"))
        XCTAssertTrue(swap.contains("guard let outcome = last, outcome.isFinal else { quoting = false; return } result = outcome resultKey = key"))
        // The selection: the person's pick is held through a round's answers (`VenueSelection`), and shown once it answered.
        XCTAssertTrue(swap.contains("selection = selection.following(outcome)"))
        XCTAssertTrue(swap.contains("var shownQuote: VenueQuote? { guard let result = currentResult, amountIn > 0 else { return nil } return selection.shown(in: result) }"))
        XCTAssertTrue(swap.contains("Button { Haptics.selection(); model.pick(quote.venue) } label: {"))
        XCTAssertTrue(swap.contains("func pick(_ venue: Venue) { selection = VenueSelection(venue: venue, picked: true) }"))
        XCTAssertFalse(swap.contains("followBest"))
        // What the screen says while venues are still asked: "Best price so far" only of the best so far.
        XCTAssertTrue(swap.contains(#"if let stillAsked = model.venuesStillAsked { Group { if model.showsBestSoFar { Paragraph("Best price so far. Still checking \(stillAsked) more venues.") } else { Paragraph("Still checking \(stillAsked) more venues.") } }"#))
        XCTAssertTrue(swap.contains("guard let result = currentResult, !result.isFinal, shownQuote != nil else { return nil } return result.pending.count"))
        XCTAssertTrue(swap.contains("guard let shown = shownQuote, let best = currentResult?.quotes.first else { return false } return shown.venue == best.venue"))
        XCTAssertTrue(swap.contains("ForEach(result.pending, id: \\.self) { venue in"))
        XCTAssertTrue(swap.contains("if result.isFinal, quote.venue == result.quotes.first?.venue {"), "\"Best\" only of them all")
        XCTAssertTrue(swap.contains(".task(id: model.quoteKey) { await model.quote(env: env, account: model.account) }"))
        XCTAssertTrue(swap.contains("model.account = session.address"))
        XCTAssertTrue(swap.contains("async let prepared: Void = env.swap.prepare(for: SwapModel.quoteAccount(session.address))"))

        let environment = Self.squeezed(try DocsLinksTests.appSource("App/AppEnvironment.swift"))
        XCTAssertTrue(environment.contains("swap = SwapEngine(rpc: rpc, launchpadFactories: LaunchpadAddresses.swapRouteFactories(live: config.launchpad), moments: config.moments, cache: chainCache)"))
        XCTAssertEqual(ChainCache.TTL.swapRoutes, 60)
    }

    private static func squeezed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

/// MON ↔ USDC on chain, answered from memory: Uniswap v3 has one 0.05% WMON/USDC pool (either order), quoted by QuoterV2
/// at 2.6 USDC a MON, less a little on a whole MON (`uniswapOut`), so a 1/1000 slice measures an impact; no other v3 or
/// Monday Trade pool exists, and no v4 pool holds liquidity.
enum MonUsdcChain {
    static let pool = Address(literal: "0x00000000000000000000000000000000000a0500")
    /// What a whole MON (1e18) buys on Uniswap: a little under 2.6 USDC.
    static let uniswapOut = BigUInt(2_590_000)

    /// What `amountIn` buys at 2.6 (a whole MON excepted).
    static func out(_ amountIn: BigUInt) -> BigUInt {
        amountIn == BigUInt(10).power(18) ? uniswapOut : amountIn * 2_600_000 / BigUInt(10).power(18)
    }

    static let answer: MomentsChainStub.Answer = { to, data in
        let selector = data.prefix(4)
        let args = ABIWords(data.dropFirst(4))
        func encode(_ values: [ABIValue], _ types: String) -> Data? { try? ABI.encode(values, types) }
        if selector == StubSelector.of("getPool(address,address,uint24)") {
            let pair = Set([args.address(0), args.address(1)].compactMap { $0 })
            let ours = to == Uniswap.v3Factory && pair == [Monad.wmon, Monad.usdc] && args.uint(2) == 500
            return encode([.address(ours ? pool : .zero)], "address")
        }
        if to == pool, selector == StubSelector.of("liquidity()") { return encode([.uint(BigUInt(10).power(21))], "uint128") }
        if to == Uniswap.stateView, selector == StubSelector.of("getLiquidity(bytes32)") { return encode([.uint(0)], "uint128") }
        if to == Uniswap.quoterV2, selector == StubSelector.of("quoteExactInputSingle((address,address,uint256,uint24,uint160))"),
           args.uint(3) == 500, let amountIn = args.uint(2) {
            let wmonIn = args.address(0) == Monad.wmon
            // USDC → WMON at the same price, the other way round.
            let amountOut = wmonIn ? out(amountIn) : amountIn * BigUInt(10).power(18) / 2_600_000
            return encode([.uint(amountOut), .uint(0), .uint(0), .uint(120_000)], "uint256,uint160,uint32,uint256")
        }
        return nil
    }
}

/// Kuru Flow answered like `SwapNetStub` (a token, then its fixed MON → USDC quote), recording every request as
/// `host/path`, with its token or quote answers held until `release()` when a test asks (`reset(holdTokens:holdQuotes:)`).
/// Any other request fails with HTTP 400.
final class GatedKuruStub: URLProtocol {
    /// One answer, given now or once released.
    private struct Answer: @unchecked Sendable {
        let stub: GatedKuruStub
        let response: HTTPURLResponse
        let body: Data

        func give() {
            stub.client?.urlProtocol(stub, didReceive: response, cacheStoragePolicy: .notAllowed)
            stub.client?.urlProtocol(stub, didLoad: body)
            stub.client?.urlProtocolDidFinishLoading(stub)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var holdTokens = false
    nonisolated(unsafe) private static var holdQuotes = false
    nonisolated(unsafe) private static var held: [Answer] = []

    static func reset(holdTokens tokens: Bool = false, holdQuotes quotes: Bool = false) {
        release()
        lock.lock(); defer { lock.unlock() }
        requests = []
        holdTokens = tokens
        holdQuotes = quotes
    }

    /// Answers every held request, and holds none from now on.
    static func release() {
        lock.lock()
        let answers = held
        held = []
        holdTokens = false
        holdQuotes = false
        lock.unlock()
        for answer in answers { DispatchQueue.global().async { answer.give() } }
    }

    static func recorded() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedKuruStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let token = url.host == Kuru.api.host && url.path.hasSuffix("generate-token")
        let quote = url.host == Kuru.api.host && url.path.hasSuffix("api/quote")
        let status = token || quote ? 200 : 400
        let body: String
        if token {
            body = #"{"token":"stub-token","expires_at":\#(Int(Date().timeIntervalSince1970) + 3600)}"#
        } else if quote {
            body = #"{"status":"success","output":"\#(SwapNetStub.kuruOutput)","transaction":{"to":"\#(Kuru.entrypoint.checksummed)","calldata":"\#(SwapNetStub.kuruSwapCalldata)","value":"1000000000000000000"}}"#
        } else {
            body = #"{"error":"stubbed"}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        let answer = Answer(stub: self, response: response, body: Data(body.utf8))
        Self.lock.lock()
        Self.requests.append("\(url.host ?? "")\(url.path)")
        let hold = (token && Self.holdTokens) || (quote && Self.holdQuotes)
        if hold { Self.held.append(answer) }
        Self.lock.unlock()
        if !hold { answer.give() }
    }
}
