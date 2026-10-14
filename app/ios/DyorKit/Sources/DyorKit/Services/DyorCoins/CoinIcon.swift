import Foundation

/// The picture a token shows, decided by its address, never its symbol: a token called "USDC" is not USDC. The screens
/// look it up when they draw (`TokenLogo(token:size:)`), so a stored token snapshot with no logo, or a stale one, shows
/// the right picture as soon as its coin is known, with nothing stored rewritten.
public enum CoinIcon: Hashable, Sendable {
    /// A curated token's bundled logo, named by the curated entry's own symbol (the app's asset `logo-<symbol>`).
    case bundled(symbol: String)
    /// Remote images, tried in order: the first one decoded within the caps wins. `fill`: DyorHQ launch or Moment
    /// artwork, cropped to fill the circle; otherwise a list logo, fitted whole.
    case remote([RemoteImageSource], fill: Bool)
    /// The token's letters on its colour.
    case letters

    /// What `token` shows, `coin` being its DyorHQ registry entry when it has one (`DyorCoinRegistry.coin(_:)`; an entry
    /// for another address is ignored). In order:
    /// 1. a curated token, by address: its bundled logo, or its letters when none ships (aBIL, which has no logo on
    ///    purpose);
    /// 2. a token whose badge is a warning whatever else is known of it (`TokenBadge.of` as for a token the user chose): a
    ///    look-alike of a curated or major token, by its own name or its coin's, DyorHQ's coins included, or a symbol or
    ///    DyorHQ coin's text that doesn't show as itself ("USDϹ" with a Greek lunate sigma): its letters, never a picture
    ///    that could pass for the real one;
    /// 3. a DyorHQ launch: its on-chain logo through `ImageSourcePolicy`, filled;
    /// 4. a DyorHQ Moment: its artwork as the Moments screens load it (`ImageSourcePolicy.momentSources`), filled;
    /// 5. a logo a token list gave it (`ImageSourcePolicy.listSources`), fitted;
    /// 6. otherwise its letters — also when rule 3, 4 or 5 finds nothing it may load.
    public static func resolve(_ token: Token, coin: DyorCoin?, policy: ImageSourcePolicy) -> CoinIcon {
        if let curated = Token.core(token.address) { return curated.logoURL == nil ? .letters : .bundled(symbol: curated.symbol) }
        let coin = coin.flatMap { $0.address == token.address ? $0 : nil }
        if TokenBadge.of(token, coin: coin, receivedUnasked: false).isWarning { return .letters }
        if let coin {
            let sources = coin.isMoment
                ? policy.momentSources(mediaURI: coin.logo, mediaHash: coin.mediaHash, isVideo: coin.mediaIsVideo, creator: coin.creator)
                : policy.creatorSources(coin.logo).map { RemoteImageSource(url: $0) }
            return sources.isEmpty ? .letters : .remote(sources, fill: true)
        }
        let listed = policy.listSources(for: token).map { RemoteImageSource(url: $0) }
        return listed.isEmpty ? .letters : .remote(listed, fill: false)
    }
}
