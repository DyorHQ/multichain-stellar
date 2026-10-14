import DyorKit
import Foundation

/// Remembers tokens the user has acquired but that aren't in the curated list — anything swapped into or launched —
/// so they still appear in holdings and the swap picker with a price. Persisted per wallet address in UserDefaults;
/// only public token metadata (address/symbol/name/decimals/logo) is stored, never balances or keys.
enum KnownTokenStore {
    private static func key(_ owner: Address) -> String { "knownTokens.\(owner.hex)" }

    static func all(owner: Address?) -> [Token] {
        guard let owner else { return [] }
        migrateUnverified(owner)
        return stored(owner)
    }

    private static func stored(_ owner: Address) -> [Token] {
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([Token].self, from: data)) ?? []
    }

    /// Records a token the wallet now holds. No-ops for native MON and anything already curated or stored.
    static func add(_ token: Token, owner: Address?) {
        guard let owner, !token.isNative, Token.core(token.address) == nil else { return }
        var list = all(owner: owner)
        guard !list.contains(where: { $0.address == token.address }) else { return }
        list.append(token)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key(owner))
    }

    // MARK: Unverified tokens

    /// Tokens found in the wallet's history rather than chosen in the app: anyone can send any token to any wallet
    /// (airdropped spam, a fake "USDC"), so these show as Unverified and stay out of the swap picker's list until the
    /// user searches for them (security audit 2026-09-26, IOST-12).
    private static func unverifiedKey(_ owner: Address) -> String { "knownTokens.unverified.\(owner.hex)" }

    static func unverified(owner: Address?) -> Set<Address> {
        guard let owner else { return [] }
        migrateUnverified(owner)
        return storedUnverified(owner)
    }

    private static func storedUnverified(_ owner: Address) -> Set<Address> {
        guard let list = UserDefaults.standard.stringArray(forKey: unverifiedKey(owner)) else { return [] }
        return Set(list.compactMap { Address($0) })
    }

    private static func migratedKey(_ owner: Address) -> String { "knownTokens.unverified.migrated.v1.\(owner.hex)" }

    /// Once per wallet, before anything reads or changes its tokens: builds before the Unverified mark stored every
    /// token found in the wallet's history as if chosen, and discovery never finds a stored token again, so everything
    /// stored then is marked (`WalletTokenDiscovery.unverifiedAfterUpgrade`). A swap into one clears its mark.
    private static func migrateUnverified(_ owner: Address) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey(owner)) else { return }
        let marked = WalletTokenDiscovery.unverifiedAfterUpgrade(stored: stored(owner), alreadyUnverified: storedUnverified(owner))
        setUnverified(marked, owner: owner)
        defaults.set(true, forKey: migratedKey(owner))
    }

    static func isUnverified(_ token: Address, owner: Address?) -> Bool { unverified(owner: owner).contains(token) }

    /// Records a token discovered in the wallet's transfer history, marked Unverified. A token the wallet already
    /// knows (curated, or acquired in the app) is left as it is.
    static func addDiscovered(_ token: Token, owner: Address?) {
        guard let owner, !token.isNative, Token.core(token.address) == nil,
              !all(owner: owner).contains(where: { $0.address == token.address }) else { return }
        add(token, owner: owner)
        setUnverified(unverified(owner: owner).union([token.address]), owner: owner)
    }

    /// The user acquired `token` in the app (a completed swap into it): it is no longer Unverified.
    static func markChosen(_ token: Address, owner: Address?) {
        guard let owner else { return }
        let current = unverified(owner: owner)
        guard current.contains(token) else { return }
        setUnverified(current.subtracting([token]), owner: owner)
    }

    private static func setUnverified(_ set: Set<Address>, owner: Address) {
        UserDefaults.standard.set(set.map(\.hex).sorted(), forKey: unverifiedKey(owner))
    }

    /// The full token universe for a wallet: the curated list plus everything it has acquired, de-duplicated.
    static func universe(owner: Address?) -> [Token] {
        var seen = Set(Token.core.map(\.address))
        var out = Token.core
        for token in all(owner: owner) where seen.insert(token.address).inserted { out.append(token) }
        return out
    }
}
