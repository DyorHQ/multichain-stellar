import Foundation

/// The mark a token carries where it is listed: where it came from, or a warning. It changes only what a row shows:
/// which tokens are Unverified (received, not chosen in the app) stays `HeldToken.unverified` and
/// `KnownTokenStore.unverified`, so a send's default (`WalletHoldings.defaultChoice`), the list order (`precedes`), Top
/// Tokens, "funds arriving" and the Swap picker's main list treat a DyorHQ coin sent to the wallet exactly as before
/// (security audit 2026-09-26, IOST-12).
public enum TokenBadge: Hashable, Sendable {
    /// Nothing to say: MON, a curated token, or a token the user chose that is none of the below.
    case none
    /// A DyorHQ launchpad's coin (`DyorCoinRegistry`), live or retired.
    case dyorLaunch
    /// A DyorHQ Moment's coin, of any cohort.
    case dyorMoment
    /// Sent to the wallet unasked, or with a symbol (or, for a DyorHQ coin, a name) that doesn't show as itself: its
    /// name proves nothing.
    case unverified
    /// It reads as this curated token, or this widely traded one (`WalletHoldings.majorTokens`), without being it.
    case imitates(Token)

    /// The badge `token` shows, `coin` being its DyorHQ registry entry when it has one (an entry for another address is
    /// ignored) and `receivedUnasked` whether it reached the wallet without being chosen in the app. `token` is the one
    /// the screen lists, its text as it shows: a `Launch`'s or `MomentInfo.coinToken`'s (`ChainText.shown`: a right-to-
    /// left name inside an isolate), `DyorCoin.token`, or a held token's. In order:
    /// 1. MON and the curated tokens: none;
    /// 2. a look-alike of a curated or major token (`WalletHoldings.imitated(by:)`), by its own name or symbol or its
    ///    coin's: the imitation warning, whatever made it — a DyorHQ launch called "USDC.e" or "M0N" included;
    /// 3. a DyorHQ coin whose own text, as the chain holds it, doesn't show as itself (`SymbolSafety.isDisplaySafe(_:)`
    ///    of the coin: a symbol that isn't display-safe or is longer than the forms allow, a name with hidden or
    ///    direction-changing characters or a word mixing look-alike alphabets, text that couldn't be read; never a
    ///    name's length alone): Unverified.
    ///    Only the coin's text decides, never the token's, which a screen may have had shown (`ChainText.shown` adds
    ///    isolates and removes direction characters);
    /// 4. a DyorHQ coin: DyorHQ Launch or DyorHQ Moment, received or chosen — a Chinese, Japanese or Korean symbol included;
    /// 5. any other token whose symbol isn't display-safe (`SymbolSafety.isDisplaySafe`), or one received unasked:
    ///    Unverified;
    /// 6. otherwise none.
    /// A coin the registry can't tell yet (a read that failed) has no entry, and shows as it does today.
    public static func of(_ token: Token, coin: DyorCoin?, receivedUnasked: Bool) -> TokenBadge {
        if token.isNative || Token.core(token.address) != nil { return .none }
        let coin = coin.flatMap { $0.address == token.address ? $0 : nil }
        if let imitated = imitation(token, coin: coin) { return .imitates(imitated) }
        if let coin {
            guard SymbolSafety.isDisplaySafe(coin) else { return .unverified }
            return coin.isMoment ? .dyorMoment : .dyorLaunch
        }
        return receivedUnasked || !SymbolSafety.isDisplaySafe(token.symbol) ? .unverified : .none
    }

    /// The curated or major token `token` reads as, by its own symbol and name or, for a DyorHQ coin, by what its contract
    /// says, direction characters and all (`WalletHoldings.imitated(by:)`); nil for MON, the curated tokens and every
    /// other name.
    static func imitation(_ token: Token, coin: DyorCoin?) -> Token? {
        if let curated = WalletHoldings.imitated(by: token) { return curated }
        guard let coin, coin.address == token.address else { return nil }
        return WalletHoldings.imitated(by: Token(address: token.address, symbol: coin.symbol, name: coin.name, decimals: token.decimals))
    }

    /// What the badge reads, in the app's language; nil for none.
    public var title: String? {
        switch self {
        case .none: return nil
        case .dyorLaunch: return L10n.string(LocalizedStringResource("DyorHQ Launch", bundle: L10n.kit, comment: "[tight] A coin's badge: launched on the DyorHQ launchpad. DyorHQ is never translated."))
        case .dyorMoment: return L10n.string(LocalizedStringResource("DyorHQ Moment", bundle: L10n.kit, comment: "[tight] A coin's badge: the coin of a DyorHQ Moment. DyorHQ is never translated."))
        case .unverified: return L10n.string(LocalizedStringResource("Unverified", bundle: L10n.kit, comment: "[tight] A warning badge on a token the app can't vouch for."))
        case .imitates(let listed) where Token.core(listed.address) != nil:
            return L10n.string(LocalizedStringResource("Not the \(listed.symbol) DyorHQ lists", bundle: L10n.kit, comment: "[tight] A warning badge on a look-alike: the value is the symbol of the token DyorHQ lists (USDC)."))
        case .imitates(let major):
            return L10n.string(LocalizedStringResource("Not the real \(major.symbol)", bundle: L10n.kit, comment: "[tight] A warning badge on a look-alike: the value is the symbol of a widely traded token (ETH)."))
        }
    }

    /// A DyorHQ label: DyorHQ Launch or DyorHQ Moment. A DyorHQ coin with a warning is not one.
    public var isDyorHQ: Bool { self == .dyorLaunch || self == .dyorMoment }

    /// A look-alike's warning (`imitates`).
    public var isImitation: Bool {
        if case .imitates = self { return true }
        return false
    }

    /// A warning (Unverified or a look-alike), shown in the attention colour; the DyorHQ labels are facts, not warnings.
    public var isWarning: Bool {
        switch self {
        case .unverified, .imitates: return true
        case .none, .dyorLaunch, .dyorMoment: return false
        }
    }
}

public extension HeldToken {
    /// The badge this held token shows (`TokenBadge.of`), `coin` being its DyorHQ registry entry; `unverified` stays what
    /// the send default and the list order go by.
    func badge(_ coin: DyorCoin?) -> TokenBadge {
        TokenBadge.of(token, coin: coin, receivedUnasked: unverified)
    }
}
