import BigInt
import Foundation

/// The facts Swap's route search reads before it can quote a pair (speed work, 2026-10-10), kept for a minute in the app's
/// shared reads (`ChainCache`, `ChainCache.TTL.swapRoutes`): which Uniswap v3 and Monday Trade pools a pair has at each
/// fee tier and how deep each is (`V3Router`), which hookless Uniswap v4 pools of a pair hold liquidity, and which pool a
/// launchpad coin or a Moment coin graduated into (`UniswapVenue`). Without them every amount typed and every 15 s
/// re-quote searched again, 4–5 round trips before the quote itself; with them an amount change costs the one quote read.
///
/// Only what a read that succeeded brought back is kept: a read that fails throws, keeps nothing, and the next quote
/// searches again. A transaction of the user's that settled, a pull to refresh and an erase of this device's data forget
/// it all (`ChainCache.invalidate`). These are public chain facts, the same for every wallet. Nothing here decides what
/// may be traded: a retired cohort's coin or pool hook is refused by every venue before it searches and by the router
/// calldata builders after (`SwapEngine.ensureTradable`), whatever a search found or kept.
struct SwapRouteCache: Sendable {
    /// The shared reads the facts are kept in; nil keeps nothing, and every search reads it all, as before.
    let cache: ChainCache?

    init(cache: ChainCache?) {
        self.cache = cache
    }

    /// The fact for each of `items`: each kept less than `ChainCache.TTL.swapRoutes` ago as kept, the others read
    /// together, in one call of `read` (which answers every item it is given), and kept. An item `read` leaves out is
    /// neither kept nor answered.
    func values<Item: Hashable & Sendable, Value: Sendable>(for items: [Item], key: (Item) -> String,
                                                            read: ([Item]) async throws -> [Item: Value]) async throws -> [Item: Value] {
        var found: [Item: Value] = [:]
        var missing: [Item] = []
        for item in items where found[item] == nil && !missing.contains(item) {
            if let kept: Value = cache?.fresh(key(item), ttl: ChainCache.TTL.swapRoutes) { found[item] = kept } else { missing.append(item) }
        }
        guard !missing.isEmpty else { return found }
        // Noted before the read: what it brings back is not kept if the cache was invalidated meanwhile.
        let generation = cache?.generation ?? 0
        let answers = try await read(missing)
        for item in missing {
            guard let value = answers[item] else { continue }
            found[item] = value
            cache?.keep(value, for: key(item), readSince: generation)
        }
        return found
    }
}

/// Two tokens of a route search: in the order a v3 factory is asked for their pool (`TokenPair(a:b:)`), or sorted as a v4
/// pool key sorts its currencies (`unordered`), so a pair and its flip are one.
struct TokenPair: Hashable, Sendable {
    let a: Address
    let b: Address

    /// The pair sorted numerically, as `PoolKey.canonical` sorts a v4 pool's currencies.
    static func unordered(_ x: Address, _ y: Address) -> TokenPair {
        BigUInt(x.data) < BigUInt(y.data) ? TokenPair(a: x, b: y) : TokenPair(a: y, b: x)
    }
}

/// The fee tiers at which a v3-style pair has a pool holding liquidity, each with that liquidity; none for a pair with no
/// such pool.
struct V3PairDepths: Sendable {
    let byFee: [Int: BigUInt]
}

/// The hookless v4 pools of a pair (`Uniswap.v4Tiers`) that hold liquidity, in tier order.
struct V4PairPools: Sendable {
    let keys: [PoolKey]
}

/// The pool a coin graduated into, or nil when it has none: never launched there, or not graduated yet.
struct GraduatedPool: Sendable {
    let key: PoolKey?
}
