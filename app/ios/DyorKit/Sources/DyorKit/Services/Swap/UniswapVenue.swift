import BigInt
import Foundation

/// Uniswap on Monad: v3 pools through SwapRouter02 and v4 pools (hookless canonical pools plus graduated
/// launchpad pools) through the Universal Router. Quotes come from QuoterV2 and V4Quoter; the better one is offered.
struct UniswapVenue: Sendable {
    let multicall: Multicall
    let v3: V3Router
    /// The launchpad factories (live and retired, all with the 17-field record) whose graduated pools are routable;
    /// empty until one is deployed.
    let launchpadFactories: [Address]
    /// The Moments contracts whose graduated coin ↔ USDC pools are routable; nil when Moments are not live.
    let moments: MomentsAddresses?
    /// Which v4 pools each pair has with liquidity, and which pool each launchpad or Moment coin graduated into, kept a
    /// minute (`SwapRouteCache`): an amount change then costs the one quote read. Without a cache every quote searches.
    let routeCache: SwapRouteCache

    init(multicall: Multicall, v3: V3Router, launchpadFactories: [Address] = [], moments: MomentsAddresses? = nil, cache: ChainCache? = nil) {
        self.multicall = multicall
        self.v3 = v3
        self.launchpadFactories = launchpadFactories.filter { !$0.isZero }
        self.moments = moments
        routeCache = SwapRouteCache(cache: cache)
    }

    static let v3Venue = V3Venue(factory: Uniswap.v3Factory, quoter: Uniswap.quoterV2, tiers: Uniswap.v3FeeTiers)

    private struct V4Candidate: Sendable {
        let hops: [V4Hop]
        let amountOut: BigUInt
        let gas: BigUInt
        /// From a 1/1000 slice quoted in the same read as the trade (`bestV4`); nil when it couldn't be.
        let priceImpactBps: Int?
    }

    private enum Chosen: Sendable {
        case v3(V3Candidate)
        case v4(V4Candidate)
    }

    func quote(_ req: SwapRequest) async throws -> VenueQuote? {
        try SwapEngine.ensureTradable([req.tokenIn.address, req.tokenOut.address])
        let tokenIn = req.tokenIn.wrappedAddress
        let tokenOut = req.tokenOut.wrappedAddress
        guard tokenIn != tokenOut else { return nil }
        let nativeIn = req.tokenIn.isNative
        let nativeOut = req.tokenOut.isNative
        // v4 pools hold native MON directly; WMON legs stay on v3.
        let v4Eligible = req.tokenIn.address != Monad.wmon && req.tokenOut.address != Monad.wmon
        async let v3Search = v3.bestRouteOrNil(on: Self.v3Venue, tokenIn: tokenIn, tokenOut: tokenOut, amountIn: req.amountIn)
        async let v4Search = bestV4OrNil(eligible: v4Eligible, currencyIn: req.tokenIn.address, currencyOut: req.tokenOut.address, amountIn: req.amountIn)
        let (v3Best, v4Best) = await (v3Search, v4Search)

        let chosen: Chosen
        switch (v3Best, v4Best) {
        case (nil, nil): return nil
        case (let v3?, nil): chosen = .v3(v3)
        case (nil, let v4?): chosen = .v4(v4)
        case (let v3?, let v4?): chosen = v4.amountOut >= v3.amountOut ? .v4(v4) : .v3(v3)
        }

        var symbols = [req.tokenIn.symbol]
        if let v3Best, v3Best.route.path.count == 3 { symbols.append(V3Router.hopSymbol(v3Best.route.path[1])) }
        symbols.append(req.tokenOut.symbol)

        let amountOut: BigUInt
        let gas: BigUInt
        let route: String
        let priceImpactBps: Int?
        // Either one's impact was read with its quote, in the same Multicall3 read (`bestV4`, `V3Router.bestRoute`).
        switch chosen {
        case .v4(let v4):
            amountOut = v4.amountOut
            gas = v4.gas
            route = Self.describeV4(v4.hops, symbolIn: req.tokenIn.symbol, symbolOut: req.tokenOut.symbol, momentsHook: moments?.hook)
            priceImpactBps = v4.priceImpactBps
        case .v3(let candidate):
            amountOut = candidate.amountOut
            gas = candidate.gas
            route = "v3 · " + V3Router.describe(candidate.route, symbols: symbols)
            priceImpactBps = candidate.priceImpactBps
        }
        let minOut = SwapMath.minAfterSlippage(amountOut, bps: req.slippageBps)
        let multicall = self.multicall
        let inToken = req.tokenIn
        let outAddress = req.tokenOut.address
        let amountIn = req.amountIn
        let exactApprovals = req.exactApprovals

        return VenueQuote(venue: .uniswap, amountOut: amountOut, minOut: minOut, route: route, gasEstimate: gas, priceImpactBps: priceImpactBps) { account in
            let deadline = BigUInt(SwapMath.nowSeconds + SwapCalldata.deadlineSeconds)
            var steps: [TransactionStep] = []
            switch chosen {
            case .v4(let v4):
                if !nativeIn, exactApprovals {
                    // Exactly the input, to Permit2 and on to the Universal Router, the allowance ending minutes after it's set.
                    steps.append(.approve(token: inToken.address, spender: Uniswap.permit2, amount: amountIn, label: L10n.tr("Approve \(inToken.symbol) for Permit2")))
                    steps.append(.permit2Approve(token: inToken.address, spender: Uniswap.universalRouter, amount: amountIn, lifetime: SwapCalldata.exactPermit2Lifetime,
                                                 label: L10n.tr("Allow the Universal Router to spend \(inToken.symbol)")))
                } else if !nativeIn {
                    steps.append(.approve(token: inToken.address, spender: Uniswap.permit2, amount: SwapCalldata.maxUint160, label: L10n.tr("Approve \(inToken.symbol) for Permit2")))
                    if let permit = try await Self.permit2Step(multicall: multicall, owner: account, token: inToken, amount: amountIn) { steps.append(permit) }
                }
                let request = try SwapCalldata.universalRouterV4(currencyIn: inToken.address, currencyOut: outAddress, hops: v4.hops, amountIn: amountIn, minOut: minOut, deadline: deadline)
                steps.append(.call(request, label: L10n.string(LocalizedStringResource("Swap on Uniswap v4", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The venue's name is never translated."))))
            case .v3(let candidate):
                if !nativeIn { steps.append(.approve(token: inToken.address, spender: Uniswap.swapRouter02, amount: amountIn, label: L10n.tr("Approve \(inToken.symbol) for Uniswap"))) }
                let request = try SwapCalldata.swapRouter02(route: candidate.route, amountIn: amountIn, minOut: minOut, account: account, nativeIn: nativeIn, nativeOut: nativeOut, deadline: deadline)
                steps.append(.call(request, label: L10n.string(LocalizedStringResource("Swap on Uniswap v3", bundle: L10n.kit, comment: "A step of a transaction, named by what it does (a verb), as the list of steps shows it while they are signed and sent. The venue's name is never translated."))))
            }
            return steps
        }
    }

    /// The Permit2 approval for the Universal Router, or nil when the existing one still covers the amount for
    /// more than two minutes. The web app performs this check while running the plan; here it is part of building it.
    static func permit2Step(multicall: Multicall, owner: Address, token: Token, amount: BigUInt) async throws -> TransactionStep? {
        let allowance = try await multicall.readAll([try SwapCalldata.permit2Allowance(owner: owner, token: token.address, spender: Uniswap.universalRouter)])[0]
        let now = SwapMath.nowSeconds
        if allowance[0].uint >= amount, allowance[1].uint > BigUInt(now + 120) { return nil }
        let data = try SwapCalldata.permit2Approve(token: token.address, spender: Uniswap.universalRouter, amount: amount, expiration: BigUInt(now + 30 * 24 * 3600))
        return .call(TransactionRequest(to: Uniswap.permit2, data: data), label: L10n.tr("Allow the Universal Router to spend \(token.symbol)"))
    }

    // MARK: v4 routing

    private func bestV4OrNil(eligible: Bool, currencyIn: Address, currencyOut: Address, amountIn: BigUInt) async -> V4Candidate? {
        guard eligible else { return nil }
        return (try? await bestV4(currencyIn: currencyIn, currencyOut: currencyOut, amountIn: amountIn)) ?? nil
    }

    /// The best v4 route for the amount. Every candidate route is quoted for the amount and for a 1/1000 slice of it in
    /// one read, so the price impact (`V4Candidate.priceImpactBps`) costs no round trip of its own.
    private func bestV4(currencyIn: Address, currencyOut: Address, amountIn: BigUInt) async throws -> V4Candidate? {
        let routes = try await v4Routes(currencyIn: currencyIn, currencyOut: currencyOut)
        if routes.isEmpty { return nil }
        // Layout: [0, n) the amount on each route, then [n, 2n) the slice on each (none when the slice rounds to zero).
        let slice = amountIn / 1000
        var calls = try routes.map { try SwapCalldata.v4Quote(currencyIn: currencyIn, hops: $0, amountIn: amountIn) }
        if slice > 0 { calls += try routes.map { try SwapCalldata.v4Quote(currencyIn: currencyIn, hops: $0, amountIn: slice) } }
        let results = try await multicall.read(calls)
        var best: (index: Int, amountOut: BigUInt, gas: BigUInt)?
        for i in routes.indices {
            guard case .success(let values) = results[i] else { continue }
            let amountOut = values[0].uint
            if best.map({ amountOut > $0.amountOut }) ?? true { best = (i, amountOut, values[1].uint) }
        }
        guard let best else { return nil }
        var impact: Int?
        if slice > 0, case .success(let values) = results[routes.count + best.index] {
            impact = SwapMath.impactBps(amountIn: amountIn, amountOut: best.amountOut, sliceIn: slice, sliceOut: values[0].uint)
        }
        return V4Candidate(hops: routes[best.index], amountOut: best.amountOut, gas: best.gas, priceImpactBps: impact)
    }

    /// Candidate v4 routes: hookless canonical pools (direct and through native MON), graduated launchpad pools,
    /// and graduated Moment pools (coin ↔ USDC, reached directly or through a canonical USDC pool). What they are built
    /// from is kept a minute (`SwapRouteCache`): each pair's live pools, whichever way round (so a flip reads nothing
    /// new), and each coin's graduated pool.
    private func v4Routes(currencyIn cIn: Address, currencyOut cOut: Address) async throws -> [[V4Hop]] {
        let viaNative = !cIn.isZero && !cOut.isZero
        let usdc = moments?.usdc ?? Monad.usdc
        // The pairs probed: direct; in → MON and MON → out unless a side is MON; in → USDC and USDC → out unless that
        // side is USDC.
        var pairs = [TokenPair.unordered(cIn, cOut)]
        if viaNative { pairs += [TokenPair.unordered(cIn, Monad.native), TokenPair.unordered(Monad.native, cOut)] }
        if cIn != usdc { pairs.append(TokenPair.unordered(cIn, usdc)) }
        if cOut != usdc { pairs.append(TokenPair.unordered(usdc, cOut)) }
        async let liveRead = livePools(pairs)
        async let launchRead = launchpadKeys([cIn, cOut])
        async let momentRead = momentsKeys([cIn, cOut])
        let (live, launchKeys, momentKeys) = try await (liveRead, launchRead, momentRead)

        func alive(_ a: Address, _ b: Address) -> [PoolKey] { live[TokenPair.unordered(a, b)]?.keys ?? [] }
        let direct = alive(cIn, cOut)
        let toNative = viaNative ? alive(cIn, Monad.native) : []
        let fromNative = viaNative ? alive(Monad.native, cOut) : []
        let toUSDC = cIn != usdc ? alive(cIn, usdc) : []
        let fromUSDC = cOut != usdc ? alive(usdc, cOut) : []
        func route(_ hops: [V4Hop?]) -> [V4Hop]? {
            let present = hops.compactMap { $0 }
            return present.count == hops.count ? present : nil
        }

        var routes: [[V4Hop]] = direct.compactMap { route([V4Hop(key: $0, from: cIn)]) }
        if viaNative {
            for a in toNative {
                for b in fromNative { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: b, from: Monad.native)]) { routes.append(r) } }
            }
        }
        // Launchpad pools pair a token with its quote asset; reach them directly or through native MON.
        for (token, key) in launchKeys {
            let quote = key.currency0 == token ? key.currency1 : key.currency0
            if cOut == token {
                if cIn == quote {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else if quote.isZero {
                    for a in toNative { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: key, from: Monad.native)]) { routes.append(r) } }
                }
            } else if cIn == token {
                if cOut == quote {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else if quote.isZero {
                    for b in fromNative { if let r = route([V4Hop(key: key, from: cIn), V4Hop(key: b, from: Monad.native)]) { routes.append(r) } }
                }
            }
        }
        // Moment pools pair a coin with USDC; reach them directly or through a canonical USDC pool.
        for (coin, key) in momentKeys {
            if cOut == coin {
                if cIn == usdc {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else {
                    for a in toUSDC { if let r = route([V4Hop(key: a, from: cIn), V4Hop(key: key, from: usdc)]) { routes.append(r) } }
                }
            } else if cIn == coin {
                if cOut == usdc {
                    if let r = route([V4Hop(key: key, from: cIn)]) { routes.append(r) }
                } else {
                    for b in fromUSDC { if let r = route([V4Hop(key: key, from: cIn), V4Hop(key: b, from: usdc)]) { routes.append(r) } }
                }
            }
        }
        return routes
    }

    /// The hookless v4 pools of each pair (`Uniswap.v4Tiers`) holding liquidity, from StateView: the pairs not kept are
    /// read together, in one read. A pool whose liquidity can't be read counts as empty.
    private func livePools(_ pairs: [TokenPair]) async throws -> [TokenPair: V4PairPools] {
        try await routeCache.values(for: pairs, key: { "swap.v4.\($0.a.hex).\($0.b.hex)" }) { missing in
            let slots = missing.flatMap { pair in
                Uniswap.v4Tiers.map { (pair: pair, pool: PoolKey.canonical(pair.a, pair.b, fee: $0.fee, tickSpacing: $0.tickSpacing)) }
            }
            let liquidity = try await multicall.read(try slots.map { try SwapCalldata.stateViewLiquidity(poolId: $0.pool.id) })
            var live: [TokenPair: [PoolKey]] = Dictionary(missing.map { ($0, []) }, uniquingKeysWith: { first, _ in first })
            for (slot, result) in zip(slots, liquidity) {
                guard case .success(let values) = result, values[0].uint > 0 else { continue }
                live[slot.pair, default: []].append(slot.pool)
            }
            return live.mapValues { V4PairPools(keys: $0) }
        }
    }

    /// Pool keys of graduated Moment coins among `tokens`, in input order. Each coin's pool, or that it has none yet, is
    /// kept a minute (`SwapRouteCache`).
    private func momentsKeys(_ tokens: [Address]) async throws -> [(coin: Address, key: PoolKey)] {
        guard let moments, moments.isDeployed else { return [] }
        let candidates = tokens.filter { !$0.isZero && $0 != moments.usdc && $0 != Monad.wmon }
        if candidates.isEmpty { return [] }
        let pools = try await routeCache.values(for: candidates, key: { "swap.momentsPool.\(moments.factory.hex).\($0.hex)" }) { missing in
            try await readMomentPools(missing, moments: moments)
        }
        return candidates.compactMap { coin in pools[coin]?.key.map { (coin: coin, key: $0) } }
    }

    /// Each of `coins`' graduated Moment pool: its Moment id from the factory (one read), then the pool key from the
    /// graduation contract, which reverts while the Moment has no pool (a second). None for an address that is no Moment
    /// coin, or a Moment not graduated yet.
    private func readMomentPools(_ coins: [Address], moments: MomentsAddresses) async throws -> [Address: GraduatedPool] {
        var out = Dictionary(coins.map { ($0, GraduatedPool(key: nil)) }, uniquingKeysWith: { first, _ in first })
        let ids = try await multicall.read(try coins.map { try SwapCalldata.momentIdByCoin(factory: moments.factory, coin: $0) })
        var found: [(coin: Address, id: BigUInt)] = []
        for (coin, result) in zip(coins, ids) {
            guard case .success(let values) = result, values[0].uint > 0 else { continue }
            found.append((coin, values[0].uint))
        }
        if found.isEmpty { return out }
        let keys = try await multicall.read(try found.map { try SwapCalldata.momentsPoolKey(graduation: moments.graduation, momentId: $0.id) })
        for (entry, result) in zip(found, keys) {
            guard case .success(let values) = result else { continue }
            let key = values[0]
            let poolKey = PoolKey(currency0: key[0].address, currency1: key[1].address, fee: Int(clamping: key[2].uint), tickSpacing: Int(clamping: key[3].int), hooks: key[4].address)
            guard !poolKey.hooks.isZero else { continue } // not graduated: no pool yet
            out[entry.coin] = GraduatedPool(key: poolKey)
        }
        return out
    }

    /// Pool keys of launchpad tokens among `tokens` that graduated on Uniswap v4, in input order. Each token's pool, or
    /// that it has none, is kept a minute (`SwapRouteCache`), under this venue's set of factories.
    private func launchpadKeys(_ tokens: [Address]) async throws -> [(token: Address, key: PoolKey)] {
        guard !launchpadFactories.isEmpty else { return [] }
        let candidates = tokens.filter { !$0.isZero && $0 != Monad.wmon }
        if candidates.isEmpty { return [] }
        let factories = launchpadFactories.map(\.hex).joined(separator: ",")
        let pools = try await routeCache.values(for: candidates, key: { "swap.launchpadPool.\(factories).\($0.hex)" }) { missing in
            try await readLaunchpadPools(missing)
        }
        return candidates.compactMap { token in pools[token]?.key.map { (token: token, key: $0) } }
    }

    /// Each of `tokens`' graduated launchpad pool: every factory's record of it (one read), then the pool key from the
    /// first factory that recorded it graduated on Uniswap v4 (a second), since each factory's pools carry its own hook.
    /// None for a token no factory graduated on v4.
    private func readLaunchpadPools(_ tokens: [Address]) async throws -> [Address: GraduatedPool] {
        var out = Dictionary(tokens.map { ($0, GraduatedPool(key: nil)) }, uniquingKeysWith: { first, _ in first })
        let pairs = tokens.flatMap { token in launchpadFactories.map { (token: token, factory: $0) } }
        let records = try await multicall.read(try pairs.map { try SwapCalldata.launchedToken(factory: $0.factory, token: $0.token) })
        var graduated: [(token: Address, factory: Address)] = []
        for (pair, record) in zip(pairs, records) {
            guard case .success(let values) = record, SwapCalldata.graduatedOnV4(values[0]), !graduated.contains(where: { $0.token == pair.token }) else { continue }
            graduated.append(pair)
        }
        if graduated.isEmpty { return out }
        let keys = try await multicall.readAll(try graduated.map { try SwapCalldata.launchpadPoolKey(factory: $0.factory, token: $0.token) })
        for (pair, values) in zip(graduated, keys) {
            let key = values[0]
            out[pair.token] = GraduatedPool(key: PoolKey(currency0: key[0].address, currency1: key[1].address, fee: Int(clamping: key[2].uint),
                                                         tickSpacing: Int(clamping: key[3].int), hooks: key[4].address))
        }
        return out
    }

    /// "v4 · MON → USDC · 0.05%" / "v4 · USDC → MON → TOKEN · 0.05% + launchpad" / "v4 · USDC → COIN · moments 1.5%".
    static func describeV4(_ hops: [V4Hop], symbolIn: String, symbolOut: String, momentsHook: Address? = nil) -> String {
        var names = [symbolIn]
        for (i, hop) in hops.enumerated() {
            let middle = hop.currencyOut.isZero ? "MON" : (hop.currencyOut == Monad.usdc ? "USDC" : "…")
            names.append(i == hops.count - 1 ? symbolOut : middle)
        }
        let fees = hops.map { hop -> String in
            if hop.key.isHookless { return SwapMath.feeLabel(hop.key.fee) }
            if let momentsHook, hop.key.hooks == momentsHook {
                return L10n.string(LocalizedStringResource("moments 1.5%", bundle: L10n.kit, comment: "In a swap's route, the fee of a DyorHQ Moment's pool: “v4 · USDC → COIN · moments 1.5%”."))
            }
            return L10n.string(LocalizedStringResource("launchpad", bundle: L10n.kit, comment: "In a swap's route, the fee of a DyorHQ launchpad pool: “v4 · USDC → MON → TOKEN · 0.05% + launchpad”."))
        }.joined(separator: " + ")
        // not localized: the route's own notation, versions, symbols and fees
        return "v4 · \(names.joined(separator: " → ")) · \(fees)"
    }
}
