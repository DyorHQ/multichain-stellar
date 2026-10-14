import BigInt
import Foundation

/// Asks every venue at once and ranks by output, publishing each venue's quote as it arrives (`quoteUpdates`). MON ↔ WMON
/// is a 1:1 wrap and never needs a venue.
public actor SwapEngine {
    public static let quoteVenues: [Venue] = [.kuru, .uniswap, .monday]
    /// Every venue is quoted independently with this budget, so a slow venue never hides the others: their quotes show as
    /// they arrive, and the slow one's is waited for this long at most before the round is final.
    public static let quoteTimeout: TimeInterval = 20

    public let rpc: RPCClient
    private let multicall: Multicall
    private let kuru: KuruFlowClient
    private let uniswap: UniswapVenue
    private let monday: MondayVenue

    /// `launchpadFactories` enables routes through graduated launchpad pools on Uniswap v4 — the live factory plus any
    /// retired one with the current 17-field record; each token's pool key is read from its own factory. `moments`
    /// enables routes through graduated Moment pools (coin ↔ USDC, hooked, 1.5% all-in). `cache`, the app's shared
    /// reads, keeps what the route search finds for a minute (`SwapRouteCache`), so an amount change or a re-quote costs
    /// each venue its one quote read; nil searches every time.
    public init(rpc: RPCClient, session: URLSession = .shared, launchpadFactories: [Address] = [], moments: MomentsAddresses? = nil, cache: ChainCache? = nil) {
        self.rpc = rpc
        let multicall = Multicall(rpc: rpc)
        self.multicall = multicall
        let v3 = V3Router(multicall: multicall, cache: cache)
        kuru = KuruFlowClient(session: session)
        uniswap = UniswapVenue(multicall: multicall, v3: v3, launchpadFactories: launchpadFactories, moments: moments, cache: cache)
        monday = MondayVenue(v3: v3)
    }

    public nonisolated static func isWrap(_ tokenIn: Token, _ tokenOut: Token) -> Bool {
        (tokenIn.isNative && tokenOut.address == Monad.wmon) || (tokenIn.address == Monad.wmon && tokenOut.isNative)
    }

    /// Gets ready to quote for `account` when Swap opens: asks for its Kuru Flow access token now, so the first quote
    /// doesn't wait a round trip for it (`KuruFlowClient.prepare(for:)`). Never fails; a quote that still needs the token
    /// asks for it itself.
    public func prepare(for account: Address) async {
        await kuru.prepare(for: account)
    }

    /// Every venue's answer, best output first, with a readable reason for each venue that gave none: the final result
    /// of `quoteUpdates` (`QuoteResult.isFinal`), for a caller that has no use for the answers as they arrive. A pair
    /// with a retired cohort's Moment coin on either side gets no quote from any venue, and no venue is even asked; nor
    /// does a buy of a coin still on a retired launchpad's curve (`buyRefusal`, asked alongside the on-chain venues, and
    /// before Kuru Flow).
    public func quotes(for request: SwapRequest) async -> QuoteResult {
        await round(request) { _ in }
    }

    /// One round of quotes for `request`, as it fills in: an update each time a venue answers, its quote ranked among
    /// those so far, its reason, or its timeout (`quoteTimeout`), with the venues still asked in `pending`; the last
    /// update is the final result (`QuoteResult.isFinal`), and the stream ends after it. An update before the last is
    /// only the best so far, which a slower venue may still beat: a screen may show it, but must review and sign only
    /// the final one. Cancelling the consumer's task ends the round and the stream without a final result.
    ///
    /// The check of the coin bought (`buyRefusal`) runs alongside the on-chain venues instead of before them: no update is
    /// published until it has cleared the coin, and a refusal ends the round at once with its reason under every venue
    /// and no quote, whatever a venue answered. Kuru Flow, a third party's API that is told the wallet and the pair, is
    /// asked a coin that may be a launchpad's only once the check has cleared it, so a refused buy never reaches it
    /// (`RetiredLaunchpads.swift`). A pair with a retired cohort's Moment coin on either side, an amount of zero and a
    /// wrap are answered at once, final, with no venue asked.
    public nonisolated func quoteUpdates(for request: SwapRequest) -> AsyncStream<QuoteResult> {
        // Only the newest update matters to a screen that falls behind; the final one is always the newest.
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let final = await self.round(request) { continuation.yield($0) }
                if !Task.isCancelled { continuation.yield(final) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What a round's tasks answer: the coin check's refusal (nil: the coin may be bought), or one venue's outcome.
    private enum RoundAnswer: Sendable {
        case checked(SwapError?)
        case answered(Venue, Result<VenueQuote?, Error>)
    }

    /// One round (`quoteUpdates`): `publish` gets each update before the last, and the final result is returned.
    private func round(_ request: SwapRequest, publish: @escaping @Sendable (QuoteResult) -> Void) async -> QuoteResult {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) {
            return Self.refusedEverywhere(closed)
        }
        guard Self.isQuotable(request) else { return QuoteResult() }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return QuoteResult(quotes: [Self.wrapQuote(request)]) }
        // The venues asked only once the coin bought is cleared: Kuru Flow, for a coin that may be a launchpad's. The
        // on-chain venues read their pools alongside the check, telling no one the wallet, and show nothing before it.
        let afterCheck: Set<Venue> = Self.mayBeLaunchCoin(request.tokenOut) ? [.kuru] : []
        return await withTaskGroup(of: RoundAnswer.self) { group in
            func askVenue(_ venue: Venue) {
                group.addTask {
                    do { return .answered(venue, .success(try await self.ask(venue, for: request))) } catch { return .answered(venue, .failure(error)) }
                }
            }
            group.addTask { .checked(await self.buyRefusal(request.tokenOut)) }
            for venue in Self.quoteVenues where !afterCheck.contains(venue) { askVenue(venue) }
            var tally = QuoteTally(venues: Self.quoteVenues)
            var cleared = false
            for await answer in group {
                switch answer {
                case .checked(let refused?):
                    // Nothing a venue answered for a coin that may not be bought is shown: the venues still asked are
                    // stopped, and the quotes so far dropped.
                    group.cancelAll()
                    return Self.refusedEverywhere(refused)
                case .checked(nil):
                    cleared = true
                    for venue in Self.quoteVenues where afterCheck.contains(venue) { askVenue(venue) }
                case .answered(let venue, let outcome):
                    tally.record(venue, outcome)
                }
                if cleared, !tally.isComplete { publish(tally.result) }
            }
            return tally.result
        }
    }

    /// One venue's quote, or nil when it has no route. Throws with a readable message on failure or timeout, and —
    /// before any venue is asked — `SwapError.tradingClosed` when a retired cohort's Moment coin is on either side, and
    /// `buyRefusal`'s answer when the coin bought is still on a retired launchpad's curve. One venue alone (no screen
    /// shows it as it arrives) checks the coin first, so a refused buy asks no venue.
    public func quote(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
        if let closed = Self.tradingClosed(request.tokenIn, request.tokenOut) { throw closed }
        guard Self.isQuotable(request) else { return nil }
        if Self.isWrap(request.tokenIn, request.tokenOut) { return venue == .wrap ? Self.wrapQuote(request) : nil }
        if venue == .wrap { return nil }
        if let refused = await buyRefusal(request.tokenOut) { throw refused }
        return try await ask(venue, for: request)
    }

    /// One venue's quote, within `quoteTimeout`: asked once the pair's checks passed, alongside the coin's in a round
    /// (`round`; Kuru Flow after it for a coin that may be a launchpad's), after it for one venue alone (`quote(_:for:)`).
    private func ask(_ venue: Venue, for request: SwapRequest) async throws -> VenueQuote? {
        try await Self.withTimeout(Self.quoteTimeout, venue: venue) {
            switch venue {
            case .kuru: return try await self.kuru.quote(request)
            case .uniswap: return try await self.uniswap.quote(request)
            case .monday: return try await self.monday.quote(request)
            case .wrap: return nil
            }
        }
    }

    // MARK: Past-cohort Moment coins

    /// The retired Moments cohorts' pool hooks. The app trades no past cohort's pool (on cohorts 1 and 2 a route through
    /// one also pays the retired platform wallet).
    static let retiredHooks = Set(MomentsAddresses.retiredMainnet.map(\.hook))

    /// Whether `token` may be traded in the app at all: false for a retired cohort's Moment coin, on every venue.
    public nonisolated static func isTradable(_ token: Token) -> Bool {
        !MomentsAddresses.isRetiredCoin(token.address)
    }

    /// `SwapError.tradingClosed` for a pair with a retired cohort's Moment coin on either side, or nil when it may trade.
    public nonisolated static func tradingClosed(_ tokenIn: Token, _ tokenOut: Token) -> SwapError? {
        [tokenIn, tokenOut].first { !isTradable($0) }.map { .tradingClosed($0.address) }
    }

    /// Whether Swap may open on this pair: every side that is set is tradable (an unset side keeps what Swap shows).
    /// `Router.openSwap` and Swap's hand-off both ask this, so a retired coin never becomes a side.
    public nonisolated static func isTradablePair(_ tokenIn: Token?, _ tokenOut: Token?) -> Bool {
        [tokenIn, tokenOut].allSatisfy { $0.map(isTradable) ?? true }
    }

    /// The last line under every venue: throws `tradingClosed` when any of `addresses` (a trade's sides, a route's path,
    /// a v4 pool's currencies or hook) is a retired cohort's coin or pool hook. The venues check before quoting and the
    /// router calldata builders check again before encoding.
    static func ensureTradable(_ addresses: [Address]) throws {
        if let closed = addresses.first(where: { MomentsAddresses.isRetiredCoin($0) || retiredHooks.contains($0) }) {
            throw SwapError.tradingClosed(closed)
        }
    }

    /// Every retired cohort's coin and pool hook, in a fixed order, for `ensureNoRetired(in:)`.
    static let retiredAddresses: [Address] = MomentsAddresses.retiredMainnetCoins.keys.sorted { $0.hex < $1.hex }
        + MomentsAddresses.retiredMainnet.map(\.hook)

    /// For calldata the app did not encode (Kuru Flow's is ready-made, so its route cannot be read): throws
    /// `tradingClosed` when a retired cohort's coin or hook appears anywhere in it. An address the calldata touches sits
    /// in it as 20 contiguous bytes (an ABI word's low 20 bytes, or a raw address in a packed path), so a route that
    /// hops through a retired pool is caught even for an ordinary pair. Best effort: a route that names a pool only by
    /// its id (a v4 PoolId hash) would not show the hook, which is why the sides are also checked before asking.
    static func ensureNoRetired(in calldata: Data) throws {
        if let hit = retiredAddresses.first(where: { calldata.range(of: $0.data) != nil }) {
            throw SwapError.tradingClosed(hit)
        }
    }

    // MARK: Retired launchpads' coins

    /// Why `token` may not be bought, or nil when it may. A coin still on a retired launchpad's curve (bonding, migrating
    /// or refund mode) is sell-only (owner decision 2026-09-28): its holders sell, nobody buys, so a buy of it gets
    /// `SwapError.retiredLaunchpad` under every venue and no quote. A round of quotes asks this alongside the on-chain
    /// venues, shows nothing they answer until it clears the coin, and asks Kuru Flow only then (`quoteUpdates`); one
    /// venue alone asks it first (`quote(_:for:)`). Read on-chain from every retired factory's record (`RetiredLaunchpad.sellOnlyCoins`); a coin
    /// that graduated into a pool trades both ways, and selling one is never checked. The app's own tokens (`Token.core`)
    /// and MON are no launchpad coin and need no read. A read that fails refuses too (`SwapError.launchpadUnchecked`):
    /// nothing could rule the coin out.
    public func buyRefusal(_ token: Token) async -> SwapError? {
        guard Self.mayBeLaunchCoin(token) else { return nil }
        do {
            return try await RetiredLaunchpad.sellOnlyCoins([token.address], multicall: multicall).contains(token.address) ? .retiredLaunchpad(token.address) : nil
        } catch {
            return .launchpadUnchecked
        }
    }

    /// Whether `token` could be a launchpad coin at all: not MON, and none of the app's own tokens.
    nonisolated static func mayBeLaunchCoin(_ token: Token) -> Bool {
        !token.isNative && Token.core(token.address) == nil
    }

    // MARK: Helpers

    /// No quote, with `error`'s reason under every venue.
    private static func refusedEverywhere(_ error: SwapError) -> QuoteResult {
        let reason = SwapMath.describe(error)
        return QuoteResult(errors: Dictionary(uniqueKeysWithValues: quoteVenues.map { ($0, reason) }))
    }

    private static func isQuotable(_ request: SwapRequest) -> Bool {
        request.tokenIn.address != request.tokenOut.address && request.amountIn > 0
    }

    /// Best output first; ties keep venue order.
    static func rank(_ quotes: [VenueQuote]) -> [VenueQuote] {
        quotes.enumerated()
            .sorted { a, b in a.element.amountOut != b.element.amountOut ? a.element.amountOut > b.element.amountOut : a.offset < b.offset }
            .map(\.element)
    }

    static func wrapQuote(_ request: SwapRequest) -> VenueQuote {
        let wrapping = request.tokenIn.isNative
        let amount = request.amountIn
        return VenueQuote(venue: .wrap, amountOut: amount, minOut: amount, route: wrapping ? L10n.tr("Wrap MON → WMON, 1:1") : L10n.tr("Unwrap WMON → MON, 1:1"), gasEstimate: 50_000, priceImpactBps: 0) { _ in
            let request = wrapping
                ? TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonDeposit(), value: amount)
                : TransactionRequest(to: Monad.wmon, data: try SwapCalldata.wmonWithdraw(amount: amount))
            return [.call(request, label: wrapping ? L10n.tr("Wrap MON") : L10n.tr("Unwrap WMON"))]
        }
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, venue: Venue, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SwapError.timedOut(venue, seconds: Int(seconds.rounded()))
            }
            guard let first = try await group.next() else { throw SwapError.timedOut(venue, seconds: Int(seconds.rounded())) }
            group.cancelAll()
            return first
        }
    }
}

/// One round's answers as they arrive (`SwapEngine.quoteUpdates`): each venue's quote, or the reason it has none, and the
/// venues not heard from yet.
struct QuoteTally: Sendable {
    /// The venues asked, in the order ties are ranked and pending venues listed.
    let venues: [Venue]
    private var quotes: [Venue: VenueQuote] = [:]
    private var errors: [Venue: String] = [:]
    private var answered: Set<Venue> = []

    init(venues: [Venue]) {
        self.venues = venues
    }

    /// `venue`'s answer: its quote, no route (nil), or the failure or timeout that stopped it.
    mutating func record(_ venue: Venue, _ outcome: Result<VenueQuote?, Error>) {
        answered.insert(venue)
        switch outcome {
        case .success(let quote?):
            quotes[venue] = quote
            errors[venue] = nil
        case .success(nil):
            quotes[venue] = nil
            errors[venue] = L10n.tr("No route for this pair.")
        case .failure(let error):
            quotes[venue] = nil
            errors[venue] = SwapMath.describe(error)
        }
    }

    /// Every venue has answered.
    var isComplete: Bool { venues.allSatisfy(answered.contains) }

    /// The quotes so far, best output first (ties in venue order), every answered venue's reason for having none, and the
    /// venues still asked, in venue order: final (`QuoteResult.isFinal`) once every venue has answered.
    var result: QuoteResult {
        QuoteResult(quotes: SwapEngine.rank(venues.compactMap { quotes[$0] }), errors: errors, pending: venues.filter { !answered.contains($0) })
    }
}
