import BigInt
import Foundation

/// A Uniswap-v3-style venue: a factory, a QuoterV2 and the fee tiers it enables. Shared by Uniswap v3 and Monday Trade.
struct V3Venue: Sendable {
    let factory: Address
    let quoter: Address
    let tiers: [Int]
}

struct V3Candidate: Sendable {
    let route: V3Route
    let amountOut: BigUInt
    let gas: BigUInt
    /// Price impact in basis points versus the route's own marginal price (a 1/1000 slice quoted in the same read as the
    /// trade, `SwapMath.impactBps`); nil when the slice is too small to quote, or its quote failed or came back empty.
    let priceImpactBps: Int?
}

/// Route search over v3-style pools: direct at the three deepest fee tiers, two-hop through `Token.hopTokens` at
/// the deepest tier per leg. Quoter simulations are the expensive part, so only those routes are quoted.
struct V3Router: Sendable {
    let multicall: Multicall
    /// Which pools each pair has and how deep they are, kept a minute (`SwapRouteCache`): an amount change then costs
    /// the one quote read. Without a cache every search reads the pools again.
    let routeCache: SwapRouteCache

    init(multicall: Multicall, cache: ChainCache? = nil) {
        self.multicall = multicall
        routeCache = SwapRouteCache(cache: cache)
    }

    /// The best single- or two-hop route, or nil when the venue has no pool for the pair. Every candidate route is quoted
    /// for the amount and for a 1/1000 slice of it in one read, so the price impact (`V3Candidate.priceImpactBps`) costs
    /// no round trip of its own.
    func bestRoute(on venue: V3Venue, tokenIn: Address, tokenOut: Address, amountIn: BigUInt) async throws -> V3Candidate? {
        let routes = try await candidateRoutes(on: venue, tokenIn: tokenIn, tokenOut: tokenOut)
        if routes.isEmpty { return nil }
        // Layout: [0, n) the amount on each route, then [n, 2n) the slice on each (none when the slice rounds to zero).
        let slice = amountIn / 1000
        var calls = try routes.map { try SwapCalldata.quote(quoter: venue.quoter, route: $0, amountIn: amountIn) }
        if slice > 0 { calls += try routes.map { try SwapCalldata.quote(quoter: venue.quoter, route: $0, amountIn: slice) } }
        let quotes = try await multicall.read(calls)
        var best: (index: Int, amountOut: BigUInt, gas: BigUInt)?
        for i in routes.indices {
            guard case .success(let values) = quotes[i] else { continue }
            let amountOut = values[0].uint
            if best.map({ amountOut > $0.amountOut }) ?? true { best = (i, amountOut, values[3].uint) }
        }
        guard let best else { return nil }
        var impact: Int?
        if slice > 0, best.amountOut > 0, case .success(let values) = quotes[routes.count + best.index] {
            impact = SwapMath.impactBps(amountIn: amountIn, amountOut: best.amountOut, sliceIn: slice, sliceOut: values[0].uint)
        }
        return V3Candidate(route: routes[best.index], amountOut: best.amountOut, gas: best.gas, priceImpactBps: impact)
    }

    /// Like `bestRoute`, but a failed search counts as no route (what Uniswap's quote does).
    func bestRouteOrNil(on venue: V3Venue, tokenIn: Address, tokenOut: Address, amountIn: BigUInt) async -> V3Candidate? {
        (try? await bestRoute(on: venue, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn)) ?? nil
    }

    /// The routes worth quoting, from each leg's pools and their depth (kept a minute, `SwapRouteCache`): direct at the
    /// three deepest fee tiers, and through each hop token at the deepest tier of each leg.
    func candidateRoutes(on venue: V3Venue, tokenIn: Address, tokenOut: Address) async throws -> [V3Route] {
        let hops = Token.hopTokens.filter { $0 != tokenIn && $0 != tokenOut }
        var pairs = [TokenPair(a: tokenIn, b: tokenOut)]
        for hop in hops { pairs += [TokenPair(a: tokenIn, b: hop), TokenPair(a: hop, b: tokenOut)] }
        let depths = try await routeCache.values(for: pairs, key: { "swap.v3.\(venue.factory.hex).\($0.a.hex).\($0.b.hex)" }) { missing in
            try await readDepths(on: venue, pairs: missing)
        }
        // Deepest tiers first; ties keep tier order, as the web app's stable sort does. Written as an explicit
        // loop so the Swift type-checker doesn't choke on a long tuple-returning chain.
        func tiers(_ pair: TokenPair, take: Int) -> [Int] {
            var scored: [(fee: Int, depth: BigUInt, order: Int)] = []
            for (order, fee) in venue.tiers.enumerated() {
                let d = depths[pair]?.byFee[fee] ?? 0
                if d > 0 { scored.append((fee: fee, depth: d, order: order)) }
            }
            scored.sort { $0.depth != $1.depth ? $0.depth > $1.depth : $0.order < $1.order }
            return scored.prefix(take).map(\.fee)
        }
        var routes = tiers(pairs[0], take: 3).map { V3Route(path: [tokenIn, tokenOut], fees: [$0]) }
        for hop in hops {
            for a in tiers(TokenPair(a: tokenIn, b: hop), take: 1) {
                for b in tiers(TokenPair(a: hop, b: tokenOut), take: 1) { routes.append(V3Route(path: [tokenIn, hop, tokenOut], fees: [a, b])) }
            }
        }
        return routes
    }

    /// Each pair's pool at every fee tier (one read), then the liquidity of those that exist (a second, skipped when none
    /// does): the tiers whose pool holds liquidity, per pair. A pool lookup that fails fails the whole read, so nothing
    /// is kept; a pool whose liquidity can't be read counts as empty.
    private func readDepths(on venue: V3Venue, pairs: [TokenPair]) async throws -> [TokenPair: V3PairDepths] {
        let slots = pairs.flatMap { pair in venue.tiers.map { (pair: pair, fee: $0) } }
        let pools = try await multicall.readAll(try slots.map { try SwapCalldata.v3GetPool(factory: venue.factory, $0.pair.a, $0.pair.b, fee: $0.fee) }).map { $0[0].address }
        var depths: [TokenPair: [Int: BigUInt]] = Dictionary(pairs.map { ($0, [:]) }, uniquingKeysWith: { first, _ in first })
        let live = pools.enumerated().filter { !$0.element.isZero }
        if !live.isEmpty {
            let liquidity = try await multicall.read(try live.map { try SwapCalldata.v3Liquidity(pool: $0.element) })
            for (k, entry) in live.enumerated() {
                guard case .success(let values) = liquidity[k], values[0].uint > 0 else { continue }
                let slot = slots[entry.offset]
                depths[slot.pair, default: [:]][slot.fee] = values[0].uint
            }
        }
        return depths.mapValues { V3PairDepths(byFee: $0) }
    }

    /// "MON → USDC · 0.05%" / "USDC → WETH → MON · 0.05% + 0.3%".
    static func describe(_ route: V3Route, symbols: [String]) -> String {
        "\(symbols.joined(separator: " → ")) · \(route.fees.map(SwapMath.feeLabel).joined(separator: " + "))"
    }

    private static let hopSymbols: [Address: String] = [Monad.wmon: "WMON", Monad.usdc: "USDC", Monad.usdt0: "USDT0", Monad.weth: "WETH"]

    static func hopSymbol(_ address: Address) -> String { hopSymbols[address] ?? "…" }
}
