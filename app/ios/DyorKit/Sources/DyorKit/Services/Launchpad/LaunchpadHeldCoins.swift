import BigInt
import Foundation

/// The DyorHQ launch coins among a wallet's tokens (`LaunchpadService.heldLaunches`), as their factories record them, with
/// what the wallet's lists value each one at.
public struct HeldLaunches: Sendable, Hashable {
    /// Each coin a known launchpad recorded, in any phase, with the factory that recorded it: the live one or a retired one.
    public let factories: [Address: Address]
    /// Each recorded coin's phase, from its record.
    public let phases: [Address: LaunchPhase]
    /// Each recorded coin's deployer, from its record: the factory's caller, or the launch router's, never an argument.
    public let deployers: [Address: Address]
    /// Each recorded coin's pair asset, from its record: native MON as address 0.
    public let pairAssets: [Address: Address]
    /// Their launches, by coin. A coin whose launch, or whose factory's launches, couldn't be read has none.
    public let launches: [Address: Launch]
    /// Each coin's live price in whole pair-asset units per whole coin, to a Double's precision (its launch's `pairPrice`):
    /// its curve's reserves while it is on the curve, its pool's sqrt price once graduated. `Launch.price` can't stand in
    /// for it: it counts whole units of the pair's smallest unit, so on a 6-decimal pair (USDC, AUSD) it moves in steps of
    /// $0.000001, which is most of a small launch's price, and it is 0 below that. A coin whose launch or live price
    /// couldn't be read has none: never its curve's last price once graduated, nor any other stale one.
    public let pairPerCoin: [Address: Double]

    public static let none = HeldLaunches(factories: [:], phases: [:], deployers: [:], pairAssets: [:], launches: [:], pairPerCoin: [:])

    public init(factories: [Address: Address], phases: [Address: LaunchPhase], deployers: [Address: Address], pairAssets: [Address: Address],
                launches: [Address: Launch], pairPerCoin: [Address: Double]) {
        self.factories = factories
        self.phases = phases
        self.deployers = deployers
        self.pairAssets = pairAssets
        self.launches = launches
        self.pairPerCoin = pairPerCoin
    }

    /// Every recorded coin was read in full: its launch and its live price.
    public var complete: Bool { factories.keys.allSatisfy { launches[$0] != nil && pairPerCoin[$0] != nil } }

    /// The coins still on a launchpad's curve, as `LaunchpadService.curveHoldings` reads them, from this same read: a list
    /// of holdings routes them to their Launch page without asking the factories again.
    public var curve: CurveHoldings {
        let onCurve = factories.filter { phases[$0.key] != .graduated }
        return CurveHoldings(factories: onCurve, phases: phases.filter { onCurve[$0.key] != nil }, launches: launches.filter { onCurve[$0.key] != nil })
    }
}

public extension LaunchpadService {
    /// The launches of those of `tokens` a known launchpad recorded — the live one once deployed, then each retired one
    /// (`stacks`) — in any phase, by coin, each from the first factory whose record names a curve (`firstRecord`, as
    /// `knownCurve` reads it), with each coin's live price (`HeldLaunches.pairPerCoin`). MON and the curated tokens are
    /// never asked. One aggregate asks every factory for every coin's record; then each factory's coins are read as
    /// launches (`hydrate`, in chunks), and every coin's live price in one more read. Throws when the aggregate fails or
    /// any answer in it is missing: a coin could then be missed, so nothing is ruled in or out. A factory whose launches
    /// can't be read leaves every one of its coins without a launch or price, still recorded (`HeldLaunches.complete` is
    /// false): that includes a factory one of whose coins has a protocol value (price, reserve, state, supply) that can't
    /// be read, since `hydrate` then throws for the whole read. A coin whose text can't be read keeps its launch.
    func heldLaunches(_ tokens: [Token]) async throws -> HeldLaunches {
        var seen = Set<Address>()
        let coins = tokens.filter { SwapEngine.mayBeLaunchCoin($0) && seen.insert($0.address).inserted }.map(\.address)
        let stacks = stacks.filter(\.isDeployed)
        guard !coins.isEmpty, !stacks.isEmpty else { return .none }
        let calls = coins.flatMap { coin in
            stacks.map { LaunchpadABI.call($0.factory, LaunchpadABI.Factory.getLaunchedToken, [.address(coin)], returns: LaunchpadABI.launchedTokenReturns(legacy: $0.generation.legacyRecord)) }
        }
        let results = try await multicall.read(calls)
        guard results.count == calls.count else { throw LaunchpadError.unexpectedResponse(L10n.string(LocalizedStringResource("launchpad records", bundle: L10n.kit, comment: "What the app could not read, completing “The launchpad returned something the app could not read (<this>).”"))) }
        var hits: [Address: (stack: LaunchpadAddresses, record: LaunchpadABI.LaunchRecord)] = [:]
        for (i, coin) in coins.enumerated() {
            let answers = Array(results[i * stacks.count ..< (i + 1) * stacks.count])
            // A factory answers a coin it never launched with an empty record: a missing answer is a failed read.
            for answer in answers { if case .failure = answer { throw LaunchpadError.unexpectedResponse(L10n.string(LocalizedStringResource("a launchpad record", bundle: L10n.kit, comment: "What the app could not read, completing “The launchpad returned something the app could not read (<this>).”"))) } }
            if let hit = Self.firstRecord(stacks: stacks, records: answers), hit.record.token == coin { hits[coin] = hit }
        }
        guard !hits.isEmpty else { return .none }
        var byFactory: [Address: [LaunchpadABI.LaunchRecord]] = [:]
        for coin in coins { if let hit = hits[coin] { byFactory[hit.stack.factory, default: []].append(hit.record) } }
        var launches: [Address: Launch] = [:]
        await withTaskGroup(of: [Launch].self) { group in
            for (factory, records) in byFactory {
                group.addTask { (try? await self.hydrate(records, factory: factory)) ?? [] }
            }
            for await list in group { for launch in list { launches[launch.token] = launch } }
        }
        // Each launch carries its live price, read with it (`Launch.pairPrice`): one source for every screen.
        let prices = launches.compactMapValues(\.pairPrice)
        return HeldLaunches(factories: hits.mapValues(\.stack.factory), phases: hits.mapValues(\.record.phase), deployers: hits.mapValues(\.record.deployer),
                            pairAssets: hits.mapValues(\.record.pairToken), launches: launches, pairPerCoin: prices)
    }

    /// A launch's live price (`Launch.pairPrice`): whole pair units per whole coin (18 decimals) from a curve's
    /// `getReserves` (quote reserve, token reserve) or, `graduated`, a pool's slot0 word, whose pair side is `pairSide`
    /// (WMON for a Monday Trade pool of a MON launch). Nil for an empty reserve, an uninitialised pool, or a price that
    /// isn't a positive finite number.
    nonisolated static func pairPerCoin(_ values: [ABIValue], graduated: Bool, token: Address, pairSide: Address, pairDecimals: Int) -> Double? {
        let price: Double
        if graduated {
            guard case .bytes(let word)? = values.first else { return nil }
            let sqrtPriceX96 = BigUInt(word) & ((BigUInt(1) << 160) - 1)
            guard sqrtPriceX96 > 0 else { return nil }
            let token0 = BigUInt(token.data) < BigUInt(pairSide.data) ? token : pairSide
            price = PriceService.price(sqrtPriceX96: sqrtPriceX96, token: token, token0: token0, tokenDecimals: 18, quoteDecimals: pairDecimals)
        } else {
            guard values.count >= 2, case .uint(let quoteReserve) = values[0], case .uint(let tokenReserve) = values[1], tokenReserve > 0 else { return nil }
            price = Double(quoteReserve) / Double(tokenReserve) * pow(10, Double(18 - pairDecimals))
        }
        return price.isFinite && price > 0 ? price : nil
    }
}
