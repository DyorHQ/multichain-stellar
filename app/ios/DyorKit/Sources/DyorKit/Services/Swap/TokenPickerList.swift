import BigInt
import Foundation

/// What the token picker lists (Swap's, and Home's search, which shares it): the main list, never a token the wallet was
/// sent rather than chose (`KnownTokenStore.unverified`, security audit 2026-09-26, IOST-12), and the received tokens a
/// search matches, in sections of their own: the DyorHQ coins that show their DyorHQ label (`TokenBadge.isDyorHQ`) under
/// "DyorHQ coins in your wallet", every other one under "Unverified". A received DyorHQ coin never enters the main list
/// (owner decision 4): the tokens the wallet holds float to its top, so any coin airdropped to the wallet would come
/// first. The wallet's own coins reach it as chosen ones (`WalletHoldings.ownCoins`, marked chosen by Home, the
/// Portfolio and the Send sheet).
public enum TokenPickerList {
    /// Whether `token`'s symbol or name, as the picker shows it (`displayName`), holds `query`, ignoring case; every token
    /// matches an empty query.
    public static func matches(_ token: Token, query: String) -> Bool {
        query.isEmpty || token.symbol.localizedCaseInsensitiveContains(query) || token.displayName.localizedCaseInsensitiveContains(query)
    }

    /// The main list: the tokens of `universe` that match `query`, none of them received (`unverified`), and, when a swap
    /// side is chosen (`tradableOnly`), none whose trading is closed (`SwapEngine.isTradable`). The tokens the wallet holds
    /// (`balances` above zero) come first, each group in `universe` order.
    public static func main(_ universe: [Token], unverified: Set<Address>, balances: [Address: BigUInt], query: String, tradableOnly: Bool) -> [Token] {
        let listed = universe.filter { token in
            !unverified.contains(token.address) && (!tradableOnly || SwapEngine.isTradable(token)) && matches(token, query: query)
        }
        return listed.enumerated().sorted { a, b in
            let heldA = (balances[a.element.address] ?? 0) > 0
            let heldB = (balances[b.element.address] ?? 0) > 0
            return heldA != heldB ? heldA : a.offset < b.offset
        }.map(\.element)
    }

    /// The received tokens of `universe` a search matches (none without a search), but `excluding`, the one a pasted
    /// address already shows, in `universe` order: those `isDyorHQ` says show their DyorHQ label, then every other one.
    public static func received(_ universe: [Token], unverified: Set<Address>, query: String, excluding: Address?, tradableOnly: Bool,
                                isDyorHQ: (Token) -> Bool) -> (dyorHQ: [Token], unverified: [Token]) {
        guard !query.isEmpty else { return ([], []) }
        let found = universe.filter { token in
            unverified.contains(token.address) && token.address != excluding && (!tradableOnly || SwapEngine.isTradable(token))
                && matches(token, query: query)
        }
        let dyorHQ = found.filter(isDyorHQ)
        let shown = Set(dyorHQ.map(\.address))
        return (dyorHQ, found.filter { !shown.contains($0.address) })
    }
}
