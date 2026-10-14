import BigInt
import Foundation

public struct PriceInfo: Hashable, Sendable, Codable {
    public let usd: Double
    /// Percent change over the last 24 hours, measured from the block mined 24 hours before the latest (`BlockClock`);
    /// nil when the historical read was not available, or for a coin that didn't exist then (`isNew`).
    public let change24h: Double?
    /// "Uniswap v4", "Uniswap v3", "Nad.fun" or "USDC"; for a DyorHQ coin its own venue: "DyorHQ curve", "Monday Trade",
    /// "Uniswap v4" or "DyorHQ Moment pool". An identifier, never shown: `sourceLine` says it in the app's language.
    public let source: String
    /// A DyorHQ coin's change over the same 24 hours in its pair asset (`pairSymbol`), as "vs MON" shows it: 0 when only
    /// the pair asset's dollar price moved. Nil for every other token, or when the historical read was not available.
    public let pairChange: Double?
    /// The asset a DyorHQ coin trades against ("MON", "USDC", "AUSD" or "aBIL"); nil for every other token.
    public let pairSymbol: String?
    /// A DyorHQ coin its factory hadn't recorded 24 hours ago: it has no 24h change, and shows "New".
    public let isNew: Bool

    public init(usd: Double, change24h: Double?, source: String, pairChange: Double? = nil, pairSymbol: String? = nil, isNew: Bool = false) {
        self.usd = usd
        self.change24h = change24h
        self.source = source
        self.pairChange = pairChange
        self.pairSymbol = pairSymbol
        self.isNew = isNew
    }
}

public extension PriceInfo {
    /// Whether it is a DyorHQ coin's price, from its own curve or pool (`DyorListing`): only those carry a pair asset.
    var isDyorVenue: Bool { pairSymbol != nil }

    /// A DyorHQ coin's 24h change in its pair asset, in the app's language, as its token page shows it under the price: "vs MON 0.00%" when only
    /// MON's dollar price moved. A change under half a hundredth of a percent reads 0.00%. Nil for every other token,
    /// and without the day-ago read (a coin that is "New" included).
    var pairChangeText: String? {
        guard let pairSymbol, let pairChange, pairChange.isFinite else { return nil }
        let change = NumberStyle.percent(abs(pairChange) < 0.005 ? 0 : pairChange)
        return L10n.string(LocalizedStringResource("vs \(pairSymbol) \(change)", bundle: L10n.kit, comment: "A coin's 24h change measured in the asset it trades against: “vs MON 1.20%”. The values are the asset's symbol and the change."))
    }

    /// Where a DyorHQ coin's price comes from, in one line for its token page: "Priced from its DyorHQ curve", "…its
    /// Uniswap v4 pool", "…its Monday Trade pool" or "…its Moment pool", in the app's language. Nil for every other token.
    var sourceLine: String? {
        guard isDyorVenue else { return nil }
        switch source {
        case DyorListing.curveLabel: return L10n.tr("Priced from its DyorHQ curve")
        case DyorListing.v4Label: return L10n.tr("Priced from its Uniswap v4 pool")
        case DyorListing.mondayLabel: return L10n.tr("Priced from its Monday Trade pool")
        case DyorListing.momentLabel: return L10n.tr("Priced from its Moment pool")
        default: return nil
        }
    }
}

public struct PricePoint: Hashable, Sendable, Identifiable {
    public var id: UInt64 { block }
    public let block: UInt64
    public let time: Date
    public let usd: Double

    public init(block: UInt64, time: Date, usd: Double) {
        self.block = block
        self.time = time
        self.usd = usd
    }
}

/// Spot prices straight from on-chain pools, quoted in USDC, plus the same read 24 hours earlier (Monad's public RPCs
/// serve historical state) for the 24h change. Nothing here depends on an indexer.
///
/// With DyorHQ venues on (`setUsesDyorVenues`), a DyorHQ coin — one the registry knows, or one a DyorHQ factory's own
/// record names — is priced only on the venue its factory's record names (`DyorListing`), re-read every 30 minutes, and
/// every minute while it is on its curve or its Moment collects (`DyorListing.isSettled`): never from any other pool, so
/// a thin pool anyone plants beside it is ignored. Every other token, and every token with them
/// off, is priced from the deepest pool found for it. Times come from the
/// session's measured block pace (`BlockClock`): the day-ago block is the one mined 24 hours before the latest, and a
/// chart's span and labels are true times.
public actor PriceService {
    enum Source: Hashable, Sendable {
        case v4(poolId: Data)
        case v3(pool: Address, token: Address, quote: Address, token0: Address)
        /// A Uniswap v2-style pair (Nad.fun's DEX): priced from reserves, not a sqrt price.
        case v2(pool: Address, token: Address, quote: Address, token0: Address)
        /// A DyorHQ coin's own venue, from its factory's record.
        case dyor(DyorListing)

        // not localized: identifiers (`PriceInfo.source`), never shown
        var label: String {
            switch self {
            case .v4: return "Uniswap v4"
            case .v3: return "Uniswap v3"
            case .v2: return "Nad.fun"
            case .dyor(let listing): return listing.label
            }
        }

        /// The read that returns this source's price inputs: slot0's `sqrtPriceX96` for v3/v4, `getReserves` for v2, a
        /// DyorHQ venue's own read (`DyorListing.priceCall`); nil for a DyorHQ coin with nothing to read.
        var priceCall: ContractCall? {
            get throws {
                switch self {
                case .v4(let poolId): return try SwapCalldata.stateViewSlot0(poolId: poolId)
                case .v3(let pool, _, _, _): return try SwapCalldata.v3Slot0(pool: pool)
                case .v2(let pool, _, _, _): return try SwapCalldata.v2GetReserves(pool: pool)
                case .dyor(let listing): return listing.priceCall()
                }
            }
        }

        var isWMONQuoted: Bool {
            switch self {
            case .v3(_, _, let quote, _), .v2(_, _, let quote, _): return quote == Monad.wmon
            case .v4, .dyor: return false
            }
        }

        /// The DyorHQ listing, for a DyorHQ coin.
        var listing: DyorListing? {
            if case .dyor(let listing) = self { return listing }
            return nil
        }
    }

    public let rpc: RPCClient
    /// Turns 24 hours into the day-ago block, and a chart's blocks into times.
    public let clock: BlockClock
    private let multicall: Multicall
    /// Each token's pool as last looked up, and the tokens without one — both for a while only (`PoolLookupCache`). A
    /// DyorHQ coin's entry is its venue, from its factory's record, looked up again after the same 30 minutes, or after a
    /// minute while it can still graduate.
    private var pools = PoolLookupCache<Source>()
    private let now: @Sendable () -> Date
    /// What says, without a read, that an address is or isn't a DyorHQ coin and which factory recorded it. Without it,
    /// every token the app doesn't curate has its records read on every factory.
    private let registry: DyorCoinRegistry?
    /// The launchpad stacks and Moments cohorts whose records name DyorHQ coins.
    nonisolated let launchpads: [LaunchpadAddresses]
    nonisolated let cohorts: [MomentsAddresses]
    /// Off, DyorHQ coins are priced like any token, as build 16 did (`setUsesDyorVenues`).
    private var usesDyorVenues: Bool
    /// Counts the changes to `usesDyorVenues`: a discovery that began before one drops what it found, since it belongs
    /// to the other setting.
    private var venueGeneration = 0
    /// The reads the app's screens share (`ChainCache`): identical price reads at once are one read, each token's price
    /// is kept `ChainCache.TTL.price` seconds, and the day-ago block `ChainCache.TTL.dayAgoBlock`. Nil reads every time, as a
    /// test does.
    private let cache: ChainCache?
    /// Where the pools found are kept between launches (`ChainStore`, `pools.json`), each with the time it was found, so
    /// a relaunch doesn't look every token up again and every lookup's time limit still runs from when it was made
    /// (RS-12). Nil keeps them for the session only.
    private let store: ChainStore?
    /// `store`'s epoch when its pools were last read into `pools`; nil before.
    private var poolsEpoch: Int?
    /// The lookups under way, by token, each with its own id (`discover`): a discovery due a token one of them is looking
    /// up waits for that lookup rather than start its own, so two screens pricing the same tokens at once look them up
    /// once, and a discovery waits for no lookup of tokens it doesn't need.
    private var lookingUp: [Address: (id: UUID, task: Task<Void, Error>)] = [:]

    /// `registry` (DyorHQ's coins) reads the launchpads and cohorts it was made with; without one, `launchpads` and
    /// `cohorts`. `dyorVenues` prices DyorHQ coins on their own venues from the start, and is off unless asked for: on,
    /// a curve, Uniswap v4 or Moment coin the wallet holds has a spot price, so a screen that also values it as a
    /// launch or Moment holding must count each coin once before turning it on. `cache` shares price reads between the
    /// screens (`ChainCache`), and `store` keeps the pools found between launches.
    public init(rpc: RPCClient, registry: DyorCoinRegistry? = nil, clock: BlockClock? = nil,
                launchpads: [LaunchpadAddresses] = DyorCoinRegistry.launchpads(live: .monadMainnet),
                cohorts: [MomentsAddresses] = DyorCoinRegistry.cohorts(live: .monadMainnet),
                dyorVenues: Bool = false,
                now: @escaping @Sendable () -> Date = { Date() },
                cache: ChainCache? = nil, store: ChainStore? = nil) {
        self.rpc = rpc
        self.clock = clock ?? BlockClock(rpc: rpc)
        multicall = Multicall(rpc: rpc)
        self.registry = registry
        self.launchpads = registry?.launchpads ?? launchpads
        self.cohorts = registry?.cohorts ?? cohorts
        usesDyorVenues = dyorVenues
        self.now = now
        self.cache = cache
        self.store = store
    }

    /// Whether DyorHQ coins are priced on their own venues or like any other token, as before (the default, `init`'s
    /// `dyorVenues`). A change forgets every pool and venue found, so the next read looks them up the new way, and every
    /// price kept (`cache`): those were read the other way.
    public func setUsesDyorVenues(_ on: Bool) {
        guard on != usesDyorVenues else { return }
        usesDyorVenues = on
        venueGeneration += 1
        pools = PoolLookupCache<Source>()
        savePools()
    }

    // MARK: Public

    /// USD price and 24h change for every token that has a discoverable pool or, for a DyorHQ coin, a priced venue. USDC
    /// is 1 by definition. The 24h change compares with the block mined 24 hours before the latest one; a DyorHQ coin's
    /// venue is read again at that block, so a coin that graduated since is compared with its curve price then, and a
    /// coin its factory hadn't recorded then is "New" (`PriceInfo.isNew`).
    ///
    /// With the app's shared reads (`cache`): a read of the same tokens while one is under way waits for it and shares
    /// its answer, a token priced in the last `ChainCache.TTL.price` seconds keeps that price, and only the others are
    /// read. A token with no price (no pool, or a read that failed) is never kept: it is asked again every time.
    public func prices(for tokens: [Token]) async throws -> [Address: PriceInfo] {
        guard let cache else { return try await readPrices(for: tokens) }
        let venues = venueGeneration
        let key = "prices.\(venues)." + Set(tokens.map { "\($0.address.hex):\($0.decimals)" }).sorted().joined(separator: ",")
        return try await cache.value(key, ttl: 0, keep: { (_: [Address: PriceInfo]) in false }) {
            try await self.pricesKeeping(tokens, venues: venues, cache: cache)
        }
    }

    /// `prices(for:)` with the shared reads: each token priced within `ChainCache.TTL.price` as kept, the others read, and
    /// what they read kept, under the venue setting it was read with (`venues`), unless the cache was invalidated since.
    private func pricesKeeping(_ tokens: [Token], venues: Int, cache: ChainCache) async throws -> [Address: PriceInfo] {
        let since = cache.generation
        func key(_ token: Token) -> String { "price.\(venues).\(token.address.hex).\(token.decimals)" }
        var map: [Address: PriceInfo] = [:]
        var unread: [Token] = []
        for token in tokens where map[token.address] == nil && !unread.contains(where: { $0.address == token.address }) {
            if let kept: PriceInfo = cache.fresh(key(token), ttl: ChainCache.TTL.price) { map[token.address] = kept } else { unread.append(token) }
        }
        guard !unread.isEmpty else { return map }
        let read = try await readPrices(for: unread)
        for token in unread {
            guard let info = read[token.address] else { continue }
            map[token.address] = info
            cache.keep(info, for: key(token), readSince: since)
        }
        return map
    }

    /// `prices(for:)` read now.
    private func readPrices(for tokens: [Token]) async throws -> [Address: PriceInfo] {
        try await discover(tokens)
        let sources = await withConversions(resolve(tokens))
        let dayAgo = try await dayAgoBlock()
        async let nowRead = Self.readPrices(multicall: multicall, sources, block: .latest)
        async let beforeRead = before(sources, block: dayAgo)
        let (now, before) = try await (nowRead, beforeRead)
        // Each token's source as read, not as the cache holds it after the reads (a switch change empties it).
        let sourceOf = Dictionary(sources.map { ($0.token.address, $0.source) }, uniquingKeysWith: { first, _ in first })
        var map: [Address: PriceInfo] = [:]
        for token in tokens {
            if Self.isUSD(token) {
                map[token.address] = PriceInfo(usd: 1, change24h: 0, source: "USDC")
                continue
            }
            guard let usd = now.usd[token.address] else { continue }
            let source = sourceOf[token.address]
            func change(_ now: Double?, _ then: Double?) -> Double? {
                guard let now, let then, then != 0 else { return nil }
                return (now - then) / then * 100
            }
            if let listing = source?.listing {
                let isNew = before.new.contains(token.address)
                map[token.address] = PriceInfo(usd: usd, change24h: isNew ? nil : change(usd, before.prices.usd[token.address]), source: listing.label,
                                               pairChange: isNew ? nil : change(now.pair[token.address], before.prices.pair[token.address]),
                                               pairSymbol: DyorListing.pairAsset(listing.pair)?.symbol, isNew: isNew)
            } else {
                map[token.address] = PriceInfo(usd: usd, change24h: change(usd, before.prices.usd[token.address]), source: source?.label ?? "Uniswap v3")
            }
        }
        return map
    }

    /// The block mined 24 hours before the latest, which every 24h change is measured from (`BlockClock.block(at:head:)`),
    /// nil when the latest is less than a day after 1970 (a test chain). Throws only when the latest block can't be read.
    /// With the shared reads (`cache`), one read serves every price read for `ChainCache.TTL.dayAgoBlock` seconds, so a
    /// warm price read is one round trip. The latest block is the session's shared head (`HeadClock`), read once for every
    /// reader within a second.
    private func dayAgoBlock() async throws -> UInt64? {
        let clock = clock
        let read: @Sendable () async throws -> UInt64? = {
            let head = try await clock.head.latest()
            return head.timestamp > 86_400 ? try? await clock.block(at: Date(timeIntervalSince1970: TimeInterval(head.timestamp - 86_400)), head: head) : nil
        }
        guard let cache else { return try await read() }
        return try await cache.value("prices.dayAgoBlock", ttl: ChainCache.TTL.dayAgoBlock, keep: { (block: UInt64?) in block != nil }, read: read)
    }

    /// Which of `tokens` have no pool the price finder looks for: its last lookup of each that read every pool it asks
    /// about found none with liquidity (`PoolLookupCache.hasNoPool`), or a DyorHQ coin's venue has no price (a Moment
    /// still collecting or expired). Such a token simply has no price. A token `prices(for:)` gave no price that isn't
    /// among them had a read fail — its lookup, or its price — so its price is unknown, not absent.
    public func withoutPool(_ tokens: [Token]) -> Set<Address> {
        Set(tokens.map(\.address).filter { pools.hasNoPool($0) || pools.source($0)?.listing.map { !$0.isPriced } == true })
    }

    /// Which of `tokens` are DyorHQ Moments still collecting (or waiting to graduate), as their records last read said:
    /// no pool yet, so no price, and a screen says "Not trading yet".
    public func notTradingYet(_ tokens: [Token]) -> Set<Address> {
        Set(tokens.map(\.address).filter { pools.source($0)?.listing?.venue == .collecting })
    }

    /// The prices `prices(for:)` gives without reading the chain: USDC and AUSD at $1, by definition. What a list can
    /// still show when the price read fails, exactly as a read that worked would show it.
    public static func definedPrices(for tokens: [Token]) -> [Address: PriceInfo] {
        var map: [Address: PriceInfo] = [:]
        for token in tokens where isUSD(token) { map[token.address] = PriceInfo(usd: 1, change24h: 0, source: "USDC") }
        return map
    }

    /// Samples the token's pool at `points` evenly spaced blocks over `span` seconds (blocks from the session's measured
    /// pace), ending at the latest block (the session's shared head, `HeadClock`), in one batched JSON-RPC request; each
    /// sample's time is estimated from the latest block's own timestamp. A DyorHQ coin is sampled on its own venue: a
    /// launch that graduated inside the span on its curve before then, a Moment from when it graduated. Samples the node
    /// cannot serve are dropped, so fewer than `points` may come back.
    public func history(for token: Token, points: Int = 48, span: TimeInterval = 86_400) async throws -> [PricePoint] {
        guard points > 0 else { return [] }
        let head = try await clock.head.latest()
        let latest = head.number
        let secondsPerBlock = await clock.secondsPerBlock()
        let spanBlocks = BlockClock.blocks(in: max(0, span), secondsPerBlock: secondsPerBlock)
        let step = points > 1 ? spanBlocks / UInt64(points - 1) : 0
        var blocks: [UInt64] = []
        for i in 0..<points {
            let back = step * UInt64(points - 1 - i)
            let block = latest > back ? latest - back : 0
            if blocks.last != block { blocks.append(block) }
        }
        func time(_ block: UInt64) -> Date { BlockClock.time(of: block, anchor: head, secondsPerBlock: secondsPerBlock) }
        if Self.isUSD(token) { return blocks.map { PricePoint(block: $0, time: time($0), usd: 1) } }

        try await discover([token])
        guard let source = pools.source(token.address) else { return [] }
        if let listing = source.listing { return try await dyorHistory(token, listing, blocks: blocks, time: time) }
        // WMON-quoted pools need MON's own price at every sample to become USD.
        var monSource: Source?
        if source.isWMONQuoted {
            try await discover([Token.mon])
            guard let mon = pools.source(Monad.native) else { return [] }
            monSource = mon
        }
        guard let call = try source.priceCall else { return [] }
        let monCall = try monSource?.priceCall
        var requests: [(CallRequest, BlockTag)] = []
        for block in blocks {
            requests.append((CallRequest(to: call.to, data: call.data), .number(block)))
            if let monCall { requests.append((CallRequest(to: monCall.to, data: monCall.data), .number(block))) }
        }
        let results = try await rpc.ethCalls(requests)
        guard results.count == requests.count else { throw NetworkError.malformedResponse }
        let stride = monCall == nil ? 1 : 2
        var out: [PricePoint] = []
        for (i, block) in blocks.enumerated() {
            guard case .success(let data) = results[i * stride], let base = Self.priceFromData(data, source: source, tokenDecimals: token.decimals) else { continue }
            var usd = base
            if let monSource {
                guard case .success(let monData) = results[i * stride + 1], let monSqrt = Self.sqrtPrice(monData) else { continue }
                usd *= Self.usd(sqrtPriceX96: monSqrt, source: monSource, tokenDecimals: 18)
            }
            out.append(PricePoint(block: block, time: time(block), usd: usd))
        }
        return out
    }

    /// `history` for a DyorHQ coin: at each sample its venue's read (`DyorListing.priceCall(at:)`) and its pair asset's
    /// own reads, as one Multicall3 read at that block, all samples in one batched request.
    private func dyorHistory(_ token: Token, _ listing: DyorListing, blocks: [UInt64], time: (UInt64) -> Date) async throws -> [PricePoint] {
        let helpers = await withConversions([(token, .dyor(listing))]).filter { $0.token.address != token.address }
        var requests: [(calls: [ContractCall], block: UInt64)] = []
        var samples: [(block: UInt64, at: Int)] = []
        let helperCalls = try helpers.compactMap { try $0.source.priceCall }
        guard helperCalls.count == helpers.count else { return [] }
        for block in blocks {
            let at = Int(time(block).timeIntervalSince1970)
            guard let call = listing.priceCall(at: at) else { continue }
            samples.append((block, at))
            requests.append(([call] + helperCalls, block))
        }
        let answers = try await multicall.read(requests)
        var out: [PricePoint] = []
        for (sample, answer) in zip(samples, answers) {
            guard case .success(let results) = answer, results.count == 1 + helpers.count, case .success(let values) = results[0],
                  let pairPrice = listing.pairPrice(values, at: sample.at) else { continue }
            let helperPrices = Self.combine(helpers, Array(results.dropFirst()))
            let mon = helperPrices.usd[Monad.native] ?? helperPrices.usd[Monad.wmon]
            guard let pairUSD = DyorListing.pairUSD(listing.pair, mon: mon, abil: helperPrices.usd[Token.abil.address]) else { continue }
            out.append(PricePoint(block: sample.block, time: time(sample.block), usd: pairPrice * pairUSD))
        }
        return out
    }

    /// Value of a raw token amount at a USD price; nil when the price is unknown.
    public static func usdValue(_ amount: BigUInt, decimals: Int, price: Double?) -> Double? {
        price.map { Amount.units(amount, decimals: decimals) * $0 }
    }

    // MARK: Discovery

    /// Finds where each token not looked up lately trades. A DyorHQ coin first: its venue from its factory's record
    /// (`listings`), and a token whose records couldn't be read is left for the next read, never priced from another
    /// pool meanwhile. Then the deepest pool for each other token: for MON/WMON the v4 native/USDC pool (falling back to
    /// v3), for everything else the v3 pool against USDC, or against WMON when no USDC pool has liquidity. When the
    /// switch changes while it reads, what it found belongs to the other setting: it is dropped and looked up again.
    ///
    /// One lookup of a token at a time (`lookingUp`): a discovery waits only for the lookups under way of the tokens it is
    /// due, and starts one of its own for the rest, so two screens pricing the same tokens at once (Home and the Portfolio
    /// at launch) never run the pool lookups twice, and a read whose tokens were all looked up lately waits for nothing.
    /// (The first speed pass chained every discovery behind the one before it, so a price read that needed no lookup
    /// waited for an unrelated one, its RPC timeouts included.) A lookup that fails fails every discovery waiting for it,
    /// as a read they share; the tokens it was due stay due, and the next discovery looks them up again. A lookup runs in
    /// a task of its own, so one a closed screen started still finishes for the next. The pools found are kept on the
    /// device (`store`), each with the time it was found.
    private func discover(_ tokens: [Token]) async throws {
        loadPools()
        let time = now()
        var due: [Token] = []
        var waits: [UUID: Task<Void, Error>] = [:]
        for token in tokens where pools.needsLookup(token.address, now: time) && !Self.isUSD(token) && !due.contains(where: { $0.address == token.address }) {
            if let running = lookingUp[token.address] { waits[running.id] = running.task } else { due.append(token) }
        }
        if !due.isEmpty {
            let id = UUID()
            let lookup = Task {
                let result = await ERC20.captured { try await self.lookUp(due) }
                self.finishLookup(id, of: due)
                try result.get()
            }
            for token in due { lookingUp[token.address] = (id, lookup) }
            waits[id] = lookup
        }
        for lookup in waits.values { try await lookup.value }
    }

    /// Lookup `id` of `tokens` is done (`discover`): whatever it found is in `pools`, and a token still due is looked up
    /// by the next discovery that asks for it.
    private func finishLookup(_ id: UUID, of tokens: [Token]) {
        for token in tokens where lookingUp[token.address]?.id == id { lookingUp[token.address] = nil }
    }

    /// `discover`'s lookup of `tokens`, each of them by one lookup at a time (`lookingUp`).
    private func lookUp(_ tokens: [Token]) async throws {
        let time = now()
        let generation = venueGeneration
        let epoch = store?.epoch
        var todo: [Token] = []
        for token in tokens where self.pools.needsLookup(token.address, now: time) && !Self.isUSD(token) && !todo.contains(where: { $0.address == token.address }) {
            todo.append(token)
        }
        guard !todo.isEmpty else { return }
        defer { if epoch == store?.epoch { savePools() } }
        if usesDyorVenues {
            let (listed, unsettled) = await listings(todo.map(\.address))
            guard generation == venueGeneration else { return try await lookUp(tokens) }
            for (coin, listing) in listed { pools.found(coin, .dyor(listing), now: time, settled: listing.isSettled) }
            todo.removeAll { listed[$0.address] != nil || unsettled.contains($0.address) }
            guard !todo.isEmpty else { return }
        }
        let v4Ids = Uniswap.v4Tiers.map { PoolKey.canonical(Monad.native, Monad.usdc, fee: $0.fee, tickSpacing: $0.tickSpacing).id }
        // Discover on both the Uniswap v3 factory and Monday Trade's (a v3-style factory). RWAs like aBIL only have
        // liquidity on Monday, so without it they'd never get a price.
        var pairs: [(token: Address, quote: Address, fee: Int, factory: Address)] = []
        for token in todo {
            let base = token.isNative ? Monad.wmon : token.address
            // Quote against USDC, AUSD (both dollar stables) and WMON. AUSD covers RWAs and launch assets whose only
            // deep pool is against Perpl's AUSD collateral rather than USDC.
            for quote in [Monad.usdc, Monad.ausd, Monad.wmon] where base != quote {
                for fee in Uniswap.v3FeeTiers { pairs.append((base, quote, fee, Uniswap.v3Factory)) }
                for fee in MondayTrade.feeTiers { pairs.append((base, quote, fee, MondayTrade.factory)) }
            }
        }
        let v4Calls = try v4Ids.map { try SwapCalldata.stateViewLiquidity(poolId: $0) }
        let poolCalls = try pairs.map { try SwapCalldata.v3GetPool(factory: $0.factory, $0.token, $0.quote, fee: $0.fee) }
        async let v4Read = multicall.read(v4Calls)
        async let poolRead = multicall.readAll(poolCalls)
        let (v4Liquidity, pools) = try await (v4Read, poolRead)

        let existing = pools.enumerated().compactMap { entry -> (index: Int, pool: Address)? in
            let pool = entry.element[0].address
            return pool.isZero ? nil : (entry.offset, pool)
        }
        let liquidityCalls = try existing.map { try SwapCalldata.v3Liquidity(pool: $0.pool) }
        let token0Calls = try existing.map { try SwapCalldata.v3Token0(pool: $0.pool) }
        async let liquidityRead = multicall.read(liquidityCalls)
        async let token0Read = multicall.read(token0Calls)
        let (liquidities, token0s) = try await (liquidityRead, token0Read)

        // Tokens with a read that failed: "no pool" for them may be an outage, so it isn't remembered.
        var incomplete: Set<Address> = []
        var bestV3: [Address: (weight: BigUInt, source: Source)] = [:]
        for (k, entry) in existing.enumerated() {
            let pair = pairs[entry.index]
            guard case .success(let liquidity) = liquidities[k], case .success(let token0) = token0s[k] else { incomplete.insert(pair.token); continue }
            guard liquidity[0].uint > 0 else { continue }
            // Prefer dollar-quoted pools: USDC first, then AUSD, then a WMON pool only when no stable pool has depth.
            let weight: BigUInt = pair.quote == Monad.usdc ? liquidity[0].uint * 1_000_000
                : (pair.quote == Monad.ausd ? liquidity[0].uint * 1_000 : liquidity[0].uint)
            if let previous = bestV3[pair.token], weight <= previous.weight { continue }
            bestV3[pair.token] = (weight, .v3(pool: entry.pool, token: pair.token, quote: pair.quote, token0: token0[0].address))
        }
        var v4Best: (liquidity: BigUInt, id: Data)?
        for (i, result) in v4Liquidity.enumerated() {
            guard case .success(let values) = result else { incomplete.insert(Monad.wmon); continue }
            let liquidity = values[0].uint
            if liquidity > 0, v4Best.map({ liquidity > $0.liquidity }) ?? true { v4Best = (liquidity, v4Ids[i]) }
        }

        // Fallback: tokens with no v3/v4 pool may be graduated Nad.fun coins on its v2 DEX (paired vs WMON).
        let needV2 = todo.filter { !($0.isNative || $0.address == Monad.wmon) && bestV3[$0.address] == nil }
        var v2Best: [Address: Source] = [:]
        if !needV2.isEmpty {
            let pairCalls = try needV2.map { try SwapCalldata.v2GetPair(factory: NadFun.factory, $0.address, Monad.wmon) }
            let pairResults = try await multicall.readAll(pairCalls)
            let v2Pairs = pairResults.enumerated().compactMap { entry -> (token: Address, pool: Address)? in
                let pool = entry.element[0].address
                return pool.isZero ? nil : (needV2[entry.offset].address, pool)
            }
            if !v2Pairs.isEmpty {
                async let reserveRead = multicall.read(try v2Pairs.map { try SwapCalldata.v2GetReserves(pool: $0.pool) })
                async let token0Read = multicall.read(try v2Pairs.map { try SwapCalldata.v3Token0(pool: $0.pool) })
                let (reserves, token0s) = try await (reserveRead, token0Read)
                for (k, pair) in v2Pairs.enumerated() {
                    guard case .success(let r) = reserves[k], case .success(let t0) = token0s[k] else { incomplete.insert(pair.token); continue }
                    guard r.count >= 2, r[0].uint > 0, r[1].uint > 0 else { continue }
                    v2Best[pair.token] = .v2(pool: pair.pool, token: pair.token, quote: Monad.wmon, token0: t0[0].address)
                }
            }
        }

        guard generation == venueGeneration else { return try await lookUp(tokens) }
        for token in todo {
            let source: Source?
            let base = token.isNative ? Monad.wmon : token.address
            if token.isNative || token.address == Monad.wmon {
                source = v4Best.map { .v4(poolId: $0.id) } ?? bestV3[Monad.wmon]?.source
            } else {
                source = bestV3[token.address]?.source ?? v2Best[token.address]
            }
            if let source { self.pools.found(token.address, source, now: time) }
            else if !incomplete.contains(base) { self.pools.noPool(token.address, now: time) }
        }
    }

    // MARK: Kept on the device

    /// The file `store` keeps the pools found in.
    static let poolsFile = "pools.json"

    /// What `pools.json` holds: the Uniswap v4, v3 and Nad.fun pools found and the tokens found with none, each with when
    /// its lookup was made, under the venue setting they were found with. A DyorHQ coin's venue is never kept: it is read
    /// from its factory's record again each session (`listings`).
    struct SavedPools: Codable {
        static let currentVersion = 1

        let version: Int
        /// `usesDyorVenues` when they were found: a file of the other setting is never used.
        let dyorVenues: Bool
        let pools: [SavedPool]
        let misses: [SavedMiss]

        private enum CodingKeys: String, CodingKey { case version, dyorVenues, pools, misses }

        init(dyorVenues: Bool, pools: [SavedPool], misses: [SavedMiss]) {
            version = Self.currentVersion
            self.dyorVenues = dyorVenues
            self.pools = pools
            self.misses = misses
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            dyorVenues = try container.decode(Bool.self, forKey: .dyorVenues)
            pools = try container.decode([ChainStoreEntry<SavedPool>].self, forKey: .pools).compactMap(\.value)
            misses = try container.decode([ChainStoreEntry<SavedMiss>].self, forKey: .misses).compactMap(\.value)
        }
    }

    /// One pool found for `token`: its kind and what pricing it reads (`Source`).
    struct SavedPool: Codable, Hashable {
        let token: Address
        /// "v4", "v3" or "v2".
        let kind: String
        /// A v4 pool's id, `0x` hex.
        let poolId: String?
        /// A v3 or v2 pool, the token it prices (WMON for MON), its quote asset and its token0.
        let pool: Address?
        let priced: Address?
        let quote: Address?
        let token0: Address?
        let at: Date
        let settled: Bool

        /// Nil for a DyorHQ coin's venue, which is never kept.
        init?(token: Address, source: Source, at: Date, settled: Bool) {
            let kind: String, poolId: String?, pool: Address?, priced: Address?, quote: Address?, token0: Address?
            switch source {
            case .v4(let id):
                (kind, poolId, pool, priced, quote, token0) = ("v4", id.hexString, nil, nil, nil, nil)
            case .v3(let address, let token, let quoted, let first):
                (kind, poolId, pool, priced, quote, token0) = ("v3", nil, address, token, quoted, first)
            case .v2(let address, let token, let quoted, let first):
                (kind, poolId, pool, priced, quote, token0) = ("v2", nil, address, token, quoted, first)
            case .dyor:
                return nil
            }
            self.token = token
            self.kind = kind
            self.poolId = poolId
            self.pool = pool
            self.priced = priced
            self.quote = quote
            self.token0 = token0
            self.at = at
            self.settled = settled
        }

        /// The source it names; nil when the entry is incomplete or of a kind this build doesn't know.
        var source: Source? {
            switch kind {
            case "v4":
                guard let poolId, let id = Data(hex: poolId), id.count == 32 else { return nil }
                return .v4(poolId: id)
            case "v3":
                guard let pool, let priced, let quote, let token0 else { return nil }
                return .v3(pool: pool, token: priced, quote: quote, token0: token0)
            case "v2":
                guard let pool, let priced, let quote, let token0 else { return nil }
                return .v2(pool: pool, token: priced, quote: quote, token0: token0)
            default:
                return nil
            }
        }
    }

    /// A token found with no pool, and when.
    struct SavedMiss: Codable, Hashable {
        let token: Address
        let at: Date
    }

    /// Reads the pools kept on the device into `pools`, once, and again after an erase (the store's epoch moved), when what
    /// this session found goes too. A file of the other venue setting is left unread.
    private func loadPools() {
        guard let store else { return }
        let epoch = store.epoch
        guard poolsEpoch != epoch else { return }
        if poolsEpoch != nil { pools = PoolLookupCache<Source>() }
        poolsEpoch = epoch
        guard let saved = store.load(SavedPools.self, from: Self.poolsFile), saved.version == SavedPools.currentVersion,
              saved.dyorVenues == usesDyorVenues else { return }
        pools.restore(hits: saved.pools.compactMap { entry in entry.source.map { (entry.token, $0, entry.at, entry.settled) } },
                      misses: saved.misses.map { ($0.token, $0.at) })
    }

    /// Saves the pools found (not the DyorHQ venues), unless this device's data was erased since they were read.
    private func savePools() {
        guard let store, let epoch = poolsEpoch, epoch == store.epoch else { return }
        let entries = pools.entries
        let saved = SavedPools(dyorVenues: usesDyorVenues,
                               pools: entries.hits.compactMap { SavedPool(token: $0.token, source: $0.source, at: $0.at, settled: $0.settled) }.sorted { $0.token.hex < $1.token.hex },
                               misses: entries.misses.map { SavedMiss(token: $0.token, at: $0.at) }.sorted { $0.token.hex < $1.token.hex })
        store.save(saved, to: Self.poolsFile, epoch: epoch)
    }

    private func resolve(_ tokens: [Token]) -> [(token: Token, source: Source)] {
        var seen: Set<Address> = []
        return tokens.compactMap { token in
            guard seen.insert(token.address).inserted, let source = pools.source(token.address) else { return nil }
            return (token, source)
        }
    }

    /// `sources` and what turns them into dollars at the same block: MON's own source for a WMON-quoted pool or a DyorHQ
    /// coin paired with MON, aBIL's for one paired with aBIL (and MON's again when aBIL's own pool is WMON-quoted). A
    /// conversion whose pool can't be found leaves those prices out; the others are still read.
    private func withConversions(_ sources: [(token: Token, source: Source)]) async -> [(token: Token, source: Source)] {
        var out = sources
        func has(_ address: Address) -> Bool { out.contains { $0.token.address == address } }
        func add(_ token: Token) async {
            guard !has(token.address) else { return }
            try? await discover([token])
            if let source = pools.source(token.address) { out.append((token, source)) }
        }
        if out.contains(where: { $0.source.listing?.pair == Token.abil.address }) { await add(Token.abil) }
        let needsMON = out.contains { entry in
            entry.source.isWMONQuoted || entry.source.listing.map { $0.pair.isZero || $0.pair == Monad.wmon } == true
        }
        if needsMON, !has(Monad.native), !has(Monad.wmon) { await add(Token.mon) }
        return out
    }

    // MARK: DyorHQ venues

    /// What the factories' records say of `coins` now: each DyorHQ coin's market (`listed`), and the coins whose records
    /// couldn't be read (`unsettled`), which aren't priced from any pool until a read answers. The rest are not DyorHQ
    /// coins: MON and the curated tokens, what the registry says isn't one, and every address each factory answered for
    /// without naming it. A coin the registry knows is asked of its own factory only.
    private func listings(_ coins: [Address]) async -> (listed: [Address: DyorListing], unsettled: Set<Address>) {
        var origins: [Address: DyorListing.Origin] = [:]
        var unknown: [Address] = []
        for coin in coins where !coin.isZero && Token.core(coin) == nil {
            switch await registry?.membership(coin) {
            case .dyor(let known)?:
                if let origin = origin(of: known) { origins[coin] = origin } else { unknown.append(coin) }
            case .notDyor?:
                continue
            case .unknown?, nil:
                unknown.append(coin)
            }
        }
        var listed: [Address: DyorListing] = [:]
        var unsettled: Set<Address> = []
        // 1. Who recorded each coin not known: every launchpad's record, every cohort's Moment id. A launch's record
        //    decides it at once; a Moment's is read next.
        if !unknown.isEmpty {
            let perCoin = launchpads.count + cohorts.count
            let answers = await Self.readChunked(multicall, unknown.flatMap { DyorListing.originCalls($0, launchpads: launchpads, cohorts: cohorts) }, block: .latest)
            for (i, coin) in unknown.enumerated() {
                switch DyorListing.origins(coin, launchpads: launchpads, cohorts: cohorts, answers: Array(answers[i * perCoin ..< (i + 1) * perCoin])) {
                case .moment(let cohort, let id): origins[coin] = .moment(cohort, id: id)
                case .record(.listed(let listing)): listed[coin] = listing
                case .record(.notDyor): break
                case .record(.notYet), .record(.unread): unsettled.insert(coin)
                }
            }
        }
        // 2. Each coin's record in its own factory: a factory's own coin it has no record of now is a node behind, and a
        //    coin the registry proved is never taken for another's, whatever a record says.
        let known = Set(origins.keys).subtracting(unknown)
        for (coin, record) in await records(origins, block: .latest) {
            switch record {
            case .listed(let listing): listed[coin] = listing
            case .notDyor where !known.contains(coin): break
            case .notDyor, .notYet, .unread: unsettled.insert(coin)
            }
        }
        return (listed, unsettled)
    }

    /// The launchpad stack or cohort, of those this reads, that recorded `coin`.
    private func origin(of coin: DyorCoin) -> DyorListing.Origin? {
        switch coin.origin {
        case .launch(let factory, _, _):
            return launchpads.first { $0.factory == factory }.map { .launch($0) }
        case .moment(let factory, let id, _):
            return cohorts.first { $0.factory == factory }.map { .moment($0, id: id) }
        }
    }

    /// Each coin's record (`DyorListing.record`) in its own factory at `block`, in one read.
    private func records(_ origins: [Address: DyorListing.Origin], block: BlockTag) async -> [Address: DyorListing.Record] {
        guard !origins.isEmpty else { return [:] }
        let entries = origins.sorted { $0.key.hex < $1.key.hex }
        let layouts = entries.map { entry in DyorListing.recordCalls(entry.key, origin: entry.value) }
        let answers = await Self.readChunked(multicall, layouts.flatMap { $0 }, block: block)
        var out: [Address: DyorListing.Record] = [:]
        var at = 0
        for (entry, layout) in zip(entries, layouts) {
            out[entry.key] = DyorListing.record(entry.key, origin: entry.value, answers: Array(answers[at ..< at + layout.count]))
            at += layout.count
        }
        return out
    }

    /// `calls` at `block` in Multicall3 reads of at most `Multicall.recordChunk`, `Multicall.readsInFlight` at a time, their
    /// answers in `calls` order; every call of a read that failed as a whole comes back as a failure.
    static func readChunked(_ multicall: Multicall, _ calls: [ContractCall], block: BlockTag) async -> [Result<[ABIValue], Error>] {
        let chunks = stride(from: 0, to: calls.count, by: Multicall.recordChunk).map { Array(calls[$0 ..< min(calls.count, $0 + Multicall.recordChunk)]) }
        var answers = [[Result<[ABIValue], Error>]](repeating: [], count: chunks.count)
        await withTaskGroup(of: (Int, [Result<[ABIValue], Error>]).self) { group in
            var next = 0
            func send() {
                guard next < chunks.count else { return }
                let index = next
                next += 1
                let chunk = chunks[index]
                group.addTask {
                    do {
                        let results = try await multicall.read(chunk, block: block)
                        return (index, results.count == chunk.count ? results : chunk.map { _ in .failure(NetworkError.malformedResponse) })
                    } catch {
                        return (index, chunk.map { _ in .failure(error) })
                    }
                }
            }
            for _ in 0 ..< Multicall.readsInFlight { send() }
            while let (index, results) = await group.next() {
                answers[index] = results
                send()
            }
        }
        return answers.flatMap { $0 }
    }

    // MARK: Reads

    /// Prices read at one block: dollars per whole token, and for a DyorHQ coin also its price in its pair asset.
    struct PriceRead: Sendable {
        var usd: [Address: Double] = [:]
        var pair: [Address: Double] = [:]
    }

    /// The day-ago read: every DyorHQ coin's venue read again at `block` (its record then), then every price at that
    /// block. A coin its factory hadn't recorded then is `new`; one whose record then couldn't be read has no change.
    private func before(_ sources: [(token: Token, source: Source)], block: UInt64?) async -> (prices: PriceRead, new: Set<Address>) {
        guard let block else { return (PriceRead(), []) }
        var origins: [Address: DyorListing.Origin] = [:]
        for (token, source) in sources { if let listing = source.listing { origins[token.address] = listing.origin } }
        let then = await records(origins, block: .number(block))
        var sourcesThen: [(token: Token, source: Source)] = []
        var new: Set<Address> = []
        for (token, source) in sources {
            guard source.listing != nil else { sourcesThen.append((token, source)); continue }
            switch then[token.address] {
            case .listed(let listing)?: sourcesThen.append((token, .dyor(listing)))
            case .notYet?: new.insert(token.address)
            default: break
            }
        }
        let prices = (try? await Self.readPrices(multicall: multicall, sourcesThen, block: .number(block))) ?? PriceRead()
        return (prices, new)
    }

    /// Prices of `sources` at `block`, in one Multicall3 read (`combine`).
    private static func readPrices(multicall: Multicall, _ sources: [(token: Token, source: Source)], block: BlockTag) async throws -> PriceRead {
        var priced: [(token: Token, source: Source)] = []
        var calls: [ContractCall] = []
        for entry in sources {
            guard let call = try entry.source.priceCall else { continue }
            priced.append(entry)
            calls.append(call)
        }
        guard !calls.isEmpty else { return PriceRead() }
        return combine(priced, try await multicall.read(calls, block: block))
    }

    /// Pure: dollars per whole token from each source's answer (`results`, one per source, all from one block). A
    /// WMON-quoted pool's price becomes dollars through MON's; a DyorHQ coin's price in its pair asset
    /// (`DyorListing.pairPrice`) through its pair asset's (`DyorListing.pairUSD`): MON's, $1, or aBIL's.
    static func combine(_ sources: [(token: Token, source: Source)], _ results: [Result<[ABIValue], Error>]) -> PriceRead {
        var read = PriceRead()
        for ((token, source), result) in zip(sources, results) {
            guard case .success(let values) = result else { continue }
            if let listing = source.listing {
                read.pair[token.address] = listing.pairPrice(values)
            } else {
                read.usd[token.address] = priceFromValues(values, source: source, tokenDecimals: token.decimals)
            }
        }
        let mon = read.usd[Monad.native] ?? read.usd[Monad.wmon]
        for (token, source) in sources where source.isWMONQuoted {
            if let mon, let value = read.usd[token.address] { read.usd[token.address] = value * mon } else { read.usd[token.address] = nil }
        }
        let monUSD = read.usd[Monad.native] ?? read.usd[Monad.wmon]
        for (token, source) in sources {
            guard let listing = source.listing, let pairPrice = read.pair[token.address],
                  let pairUSD = DyorListing.pairUSD(listing.pair, mon: monUSD, abil: read.usd[Token.abil.address]) else { continue }
            read.usd[token.address] = pairPrice * pairUSD
        }
        return read
    }

    // MARK: Math

    /// Price of `token` in `quote` units per whole token, from the sqrtPriceX96 of a pool whose token0 is known.
    public static func price(sqrtPriceX96: BigUInt, token: Address, token0: Address, tokenDecimals: Int, quoteDecimals: Int) -> Double {
        let ratio = Double(sqrtPriceX96) / pow(2, 96) // sqrt(token1 per token0 in raw units)
        let price1per0 = ratio * ratio
        let raw = token == token0 ? price1per0 : 1 / price1per0 // quote-raw per token-raw
        return raw * pow(10, Double(tokenDecimals - quoteDecimals))
    }

    static func usd(sqrtPriceX96: BigUInt, source: Source, tokenDecimals: Int) -> Double {
        switch source {
        case .v4:
            return price(sqrtPriceX96: sqrtPriceX96, token: Monad.native, token0: Monad.native, tokenDecimals: 18, quoteDecimals: 6)
        case .v3(_, let token, let quote, let token0):
            // USDC and AUSD are 6-decimal dollar stables; a WMON quote is 18-decimal and converted to USD via MON.
            let quoteDecimals = (quote == Monad.usdc || quote == Monad.ausd) ? 6 : 18
            return price(sqrtPriceX96: sqrtPriceX96, token: token, token0: token0, tokenDecimals: tokenDecimals, quoteDecimals: quoteDecimals)
        case .v2, .dyor:
            return 0 // v2 is priced from reserves, a DyorHQ venue by `DyorListing.pairPrice`: never from here.
        }
    }

    private static func quoteDecimals(_ quote: Address) -> Int { (quote == Monad.usdc || quote == Monad.ausd) ? 6 : 18 }

    /// Quote units per whole token from a v2 pair's reserves; the WMON→USD step happens in the caller (isWMONQuoted).
    static func priceFromReserves(reserve0: BigUInt, reserve1: BigUInt, token: Address, quote: Address, token0: Address, tokenDecimals: Int) -> Double? {
        let (reserveToken, reserveQuote) = token == token0 ? (reserve0, reserve1) : (reserve1, reserve0)
        guard reserveToken > 0 else { return nil }
        return Double(reserveQuote) / Double(reserveToken) * pow(10, Double(tokenDecimals - quoteDecimals(quote)))
    }

    /// Price from a source's decoded read values (sqrtPriceX96 for v3/v4, reserve0/reserve1 for v2).
    static func priceFromValues(_ values: [ABIValue], source: Source, tokenDecimals: Int) -> Double? {
        switch source {
        case .v4, .v3:
            guard let sqrt = values.first?.uintOrNil else { return nil }
            return usd(sqrtPriceX96: sqrt, source: source, tokenDecimals: tokenDecimals)
        case .v2(_, let token, let quote, let token0):
            guard let r0 = values.first?.uintOrNil, values.count >= 2, let r1 = values[1].uintOrNil else { return nil }
            return priceFromReserves(reserve0: r0, reserve1: r1, token: token, quote: quote, token0: token0, tokenDecimals: tokenDecimals)
        case .dyor:
            return nil
        }
    }

    /// Price from a source's raw return data (used by history, which reads raw bytes per block).
    static func priceFromData(_ data: Data, source: Source, tokenDecimals: Int) -> Double? {
        switch source {
        case .v4, .v3:
            guard let sqrt = sqrtPrice(data) else { return nil }
            return usd(sqrtPriceX96: sqrt, source: source, tokenDecimals: tokenDecimals)
        case .v2(_, let token, let quote, let token0):
            guard let decoded = try? ABI.decode(data, "uint112,uint112,uint32"), decoded.count >= 2,
                  let r0 = decoded[0].uintOrNil, let r1 = decoded[1].uintOrNil else { return nil }
            return priceFromReserves(reserve0: r0, reserve1: r1, token: token, quote: quote, token0: token0, tokenDecimals: tokenDecimals)
        case .dyor:
            return nil
        }
    }

    static func sqrtPrice(_ slot0: Data) -> BigUInt? {
        guard let value = try? ABI.decode(slot0, "uint160").first, case .uint(let sqrt) = value else { return nil }
        return sqrt
    }

    static func isUSD(_ token: Token) -> Bool { token.address == Monad.usdc || token.address == Monad.ausd }
}

/// Which tokens' pools are known, and for how long (security audit 2026-09-26, RS-12). A chosen pool is looked up again
/// after `hitTTL` — liquidity moves, and a deeper pool can appear — and a token with no pool after `missTTL`, rather than
/// either lasting as long as the app runs. A market that is about to move elsewhere is looked up again after
/// `unsettledTTL`. The pool last found keeps pricing its token until a new lookup says otherwise, and a lookup whose
/// reads failed records nothing, so an outage is never remembered as "no pool".
struct PoolLookupCache<Source: Sendable>: Sendable {
    var hitTTL: TimeInterval = 30 * 60
    var missTTL: TimeInterval = 5 * 60
    /// How soon a market found `settled: false` is looked up again: a DyorHQ launch on its curve, which graduates into a
    /// pool, and a Moment still collecting, which graduates or expires (`DyorListing.isSettled`). Within a minute of a
    /// graduation the coin is priced from its pool, and no screen keeps saying "Not trading yet" for a coin that trades.
    var unsettledTTL: TimeInterval = 60
    private var hits: [Address: (source: Source, at: Date, settled: Bool)] = [:]
    private var misses: [Address: Date] = [:]

    /// Whether `token` is due a lookup: never looked up, its pool is older than `hitTTL` (`unsettledTTL` for a market
    /// that is about to move), or its miss older than `missTTL`. A lookup dated after `now` (the device clock was set
    /// back since, or a kept one is from another clock) is due at once: no lookup outlasts its time limit that way.
    func needsLookup(_ token: Address, now: Date) -> Bool {
        if let hit = hits[token] {
            let age = now.timeIntervalSince(hit.at)
            return age < 0 || age >= (hit.settled ? hitTTL : unsettledTTL)
        }
        if let missed = misses[token] {
            let age = now.timeIntervalSince(missed)
            return age < 0 || age >= missTTL
        }
        return true
    }

    /// Every pool kept and every token found with none, each with when its lookup was made: what `PriceService` keeps on
    /// the device between launches.
    var entries: (hits: [(token: Address, source: Source, at: Date, settled: Bool)], misses: [(token: Address, at: Date)]) {
        (hits.map { ($0.key, $0.value.source, $0.value.at, $0.value.settled) }, misses.map { ($0.key, $0.value) })
    }

    /// Adds what an earlier session found (`entries`), each with the time its lookup was made, so its time limit runs on
    /// from then (RS-12 holds across launches). A token this session already looked up keeps this session's answer.
    mutating func restore(hits restored: [(token: Address, source: Source, at: Date, settled: Bool)], misses restoredMisses: [(token: Address, at: Date)]) {
        for hit in restored where hits[hit.token] == nil && misses[hit.token] == nil {
            hits[hit.token] = (hit.source, hit.at, hit.settled)
        }
        for miss in restoredMisses where hits[miss.token] == nil && misses[miss.token] == nil {
            misses[miss.token] = miss.at
        }
    }

    /// The pool last found for `token`, however old.
    func source(_ token: Address) -> Source? { hits[token]?.source }

    /// Whether the last lookup of `token` that completed found no pool, however old: false for a token never looked up,
    /// or only by lookups whose reads failed.
    func hasNoPool(_ token: Address) -> Bool { hits[token] == nil && misses[token] != nil }

    /// `source` prices `token`; `settled: false` for a market that is about to move elsewhere (`unsettledTTL`).
    mutating func found(_ token: Address, _ source: Source, now: Date, settled: Bool = true) {
        hits[token] = (source, now, settled)
        misses[token] = nil
    }

    /// A complete lookup found no pool with liquidity (a pool that was drained included).
    mutating func noPool(_ token: Address, now: Date) {
        hits[token] = nil
        misses[token] = now
    }
}
