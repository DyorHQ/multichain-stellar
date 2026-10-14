import BigInt
import Foundation

/* DyorHQ coins: every coin a DyorHQ launchpad (the live one and each retired one) or Moments cohort (c1–c4) recorded,
   proven on chain and nothing else. An address is one only because a known factory's own record says so — the
   launchpad's `getLaunchedToken(coin)` naming it, or a cohort's `momentIdByCoin(coin)` and `getMoment(id).coin` agreeing —
   never because of anything the token says about itself: a look-alike can answer `factory()` or copy a name. Launching
   and publishing are open to anyone (5 MON), so being one says where a coin was made, not that DyorHQ vouches for it:
   the label is "DyorHQ Launch" or "DyorHQ Moment", never "Verified" (`TokenBadge`), and a look-alike of a curated token
   or a symbol that isn't display-safe (`SymbolSafety`) keeps its warning whatever made it.

   `DyorCoinRegistry` holds them (read from the factories, kept in `DyorCoinStore`); `TokenBadge` and `CoinIcon` decide
   what a screen shows for a token from its entry. Nothing here changes which tokens are Unverified (IOST-12): a DyorHQ
   coin sent to a wallet unasked stays out of a send's default, Top Tokens, "funds arriving" and the picker's list. */

/// One DyorHQ coin as its factory recorded it. Every field is fixed on chain once the coin exists (a launch token has
/// no setter for its logo; a Moment's provenance is fixed at publish), so an entry never goes stale.
public struct DyorCoin: Hashable, Sendable, Identifiable, Codable {
    /// Which factory recorded the coin, and whether the app has retired that factory.
    public enum Origin: Hashable, Sendable {
        /// A launchpad's coin: its factory, that stack's contract generation, and whether the stack is a retired one.
        case launch(factory: Address, generation: LaunchpadAddresses.Generation, retired: Bool)
        /// A Moment's coin: its cohort's factory, the Moment's id there (ids restart at 1 on every factory), and whether
        /// the cohort is a retired one.
        case moment(factory: Address, id: BigUInt, retired: Bool)
    }

    /// The coin's contract.
    public let address: Address
    public let origin: Origin
    /// The coin's own `symbol()` and `name()` as the chain holds them — bytes that aren't text as U+FFFD, a read that
    /// failed as `ChainText.unreadable`, direction characters and all — cut to `maxStoredSymbol` and `maxStoredName`:
    /// what it calls itself, never trusted. Every check reads these (`TokenBadge`, `SymbolSafety`,
    /// `WalletHoldings.imitated(by:)`); a screen shows `displaySymbol` and `displayName` (and `token` carries them).
    public let symbol: String
    public let name: String
    /// Who made it, from the factory's record: a launch's deployer (the factory's caller, or the launch router's, never an
    /// argument), a Moment's creator.
    public let creator: Address
    /// Where its picture is, as written on chain by whoever made it: a launch token's `getTokenInfo().logo`, a Moment's
    /// `provenance.mediaURI` (for a video Moment, its poster frame). Loaded only through `ImageSourcePolicy`.
    public let logo: String
    /// A Moment's `provenance.mediaHash`: the keccak-256 of its photo (so the DyorHQ mirror of it can be found and
    /// checked), or of its video. Nil for a launch.
    public let mediaHash: Data?
    /// A Moment whose media is a video (`provenance.animationURI` set): `logo` is its poster frame, and the mirror holds a
    /// poster no on-chain hash can check.
    public let mediaIsVideo: Bool
    /// What the coin trades against, from its record: a launch's pair asset (native MON as address 0), a Moment's USDC.
    public let pair: Address

    public var id: Address { address }

    /// An entry, its creator's strings cut to what is kept (`maxStoredSymbol`, `maxStoredName`; a logo over
    /// `ImageSourcePolicy.maxURLBytes` is dropped), so the registry's file stays small whatever a creator writes.
    public init(address: Address, origin: Origin, symbol: String, name: String, creator: Address, logo: String, mediaHash: Data? = nil, mediaIsVideo: Bool = false, pair: Address) {
        self.address = address
        self.origin = origin
        self.symbol = Self.capped(symbol, Self.maxStoredSymbol)
        self.name = Self.capped(name, Self.maxStoredName, wholeCharacters: true)
        self.creator = creator
        self.logo = logo.utf8.count <= ImageSourcePolicy.maxURLBytes ? logo : ""
        self.mediaHash = mediaHash.map { Data($0.prefix(32)) }
        self.mediaIsVideo = mediaIsVideo
        self.pair = pair
    }

    private enum CodingKeys: String, CodingKey { case address, origin, symbol, name, creator, logo, mediaHash, mediaIsVideo, pair }

    /// An entry from the registry's file, cut as `init` cuts one: a file written by a build that kept longer strings
    /// reads as this build keeps them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(address: try container.decode(Address.self, forKey: .address), origin: try container.decode(Origin.self, forKey: .origin),
                  symbol: try container.decode(String.self, forKey: .symbol), name: try container.decode(String.self, forKey: .name),
                  creator: try container.decode(Address.self, forKey: .creator), logo: try container.decode(String.self, forKey: .logo),
                  mediaHash: try container.decodeIfPresent(Data.self, forKey: .mediaHash), mediaIsVideo: try container.decode(Bool.self, forKey: .mediaIsVideo),
                  pair: try container.decode(Address.self, forKey: .pair))
    }

    /// The most kept of a symbol: characters, then UTF-8 bytes. Longer than any form allows
    /// (`SymbolSafety.maxSymbolLength`), so what is cut still reads as too long and keeps its warning.
    public static let maxStoredSymbol = (characters: 32, bytes: 128)
    /// The most kept of a name, as `maxStoredSymbol`: more than a screen shows. A name's length never makes a warning
    /// (`SymbolSafety.isDisplaySafe(_:)`), so this only keeps the file small.
    public static let maxStoredName = (characters: 64, bytes: 256)

    /// `text` cut to `cap.characters` characters, then, if still over `cap.bytes` UTF-8 bytes, to that many bytes. A
    /// symbol is cut at a scalar's end: a cut symbol is then at least `cap.bytes` - 3 bytes long, never short enough
    /// to pass as fitting a form. A name (`wholeCharacters`) is cut at a character's end, whole characters dropped
    /// from its end until it fits, so no emoji is left cut inside its sequence: a family emoji ending in its joiner,
    /// or a keycap "1️⃣" without its keycap mark, reads as a hidden character (`SymbolSafety.hasHiddenCharacters`),
    /// and a coin whose whole name has none would show a warning for what was cut. Only a character longer than all
    /// of `cap.bytes` is cut inside, at a scalar's end, so a name of one such character keeps what fits of it.
    static func capped(_ text: String, _ cap: (characters: Int, bytes: Int), wholeCharacters: Bool = false) -> String {
        guard text.utf8.count > cap.characters else { return text } // no more characters than bytes
        let out = String(text.prefix(cap.characters))
        guard out.utf8.count > cap.bytes else { return out }
        var kept = String.UnicodeScalarView()
        var used = 0
        // Keeps the scalars of `scalars` that fit, up to the first that doesn't.
        func keep<Scalars: Sequence<Unicode.Scalar>>(_ scalars: Scalars) {
            for scalar in scalars {
                let size = String(scalar).utf8.count
                guard used + size <= cap.bytes else { return }
                kept.append(scalar)
                used += size
            }
        }
        guard wholeCharacters else {
            keep(out.unicodeScalars)
            return String(kept)
        }
        for character in out {
            let size = character.utf8.count
            guard used + size <= cap.bytes else {
                if size > cap.bytes { keep(character.unicodeScalars) }
                break
            }
            kept.append(contentsOf: character.unicodeScalars)
            used += size
        }
        return String(kept)
    }

    /// The symbol as a screen shows it (`ChainText.shown`: direction characters and invisible padding removed, right-to-
    /// left text isolated). For showing only: never compare or check it.
    public var displaySymbol: String { ChainText.shown(symbol) }
    /// The name as a screen shows it, as `displaySymbol`.
    public var displayName: String { ChainText.shown(name) }

    /// The factory that recorded it: a launchpad's or a cohort's.
    public var factory: Address {
        switch origin {
        case .launch(let factory, _, _), .moment(let factory, _, _): return factory
        }
    }

    /// Its factory is one the app has retired: a launchpad whose curves take sells only, or a claim-only cohort.
    public var retired: Bool {
        switch origin {
        case .launch(_, _, let retired), .moment(_, _, let retired): return retired
        }
    }

    public var isLaunch: Bool { if case .launch = origin { return true } else { return false } }
    public var isMoment: Bool { if case .moment = origin { return true } else { return false } }

    /// (factory, id) for a Moment's coin; nil for a launch.
    public var momentKey: MomentKey? {
        if case .moment(let factory, let id, _) = origin { return MomentKey(factory: factory, id: id) }
        return nil
    }

    /// The coin as a token the app can list: 18 decimals, as every launch token and Moment coin has, and its symbol and
    /// name as they show (`displaySymbol`, `displayName`), as a `Launch`'s and `MomentInfo.coinToken`'s are, so no
    /// screen ever draws the chain's direction characters. The checks read the entry itself, never this token's text
    /// (`TokenBadge.of`, `CoinIcon.resolve`). No logo URL: a screen resolves the picture from this entry (`CoinIcon`),
    /// never from a stored one.
    public var token: Token {
        Token(address: address, symbol: displaySymbol, name: displayName, decimals: MomentsConstants.coinDecimals, isLaunchpad: isLaunch)
    }
}

extension DyorCoin.Origin: Codable {
    private enum CodingKeys: String, CodingKey { case kind, factory, generation, id, retired }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let factory = try container.decode(Address.self, forKey: .factory)
        let retired = try container.decode(Bool.self, forKey: .retired)
        switch try container.decode(String.self, forKey: .kind) {
        case "launch":
            let name = try container.decode(String.self, forKey: .generation)
            guard let generation = LaunchpadAddresses.Generation.allCases.first(where: { $0.description == name }) else {
                throw DecodingError.dataCorruptedError(forKey: .generation, in: container, debugDescription: "Unknown launchpad generation \(name)")
            }
            self = .launch(factory: factory, generation: generation, retired: retired)
        case "moment":
            let text = try container.decode(String.self, forKey: .id)
            guard let id = BigUInt(text, radix: 10), id > 0 else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Invalid Moment id \(text)")
            }
            self = .moment(factory: factory, id: id, retired: retired)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown coin origin \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launch(let factory, let generation, let retired):
            try container.encode("launch", forKey: .kind)
            try container.encode(factory, forKey: .factory)
            try container.encode(generation.description, forKey: .generation)
            try container.encode(retired, forKey: .retired)
        case .moment(let factory, let id, let retired):
            try container.encode("moment", forKey: .kind)
            try container.encode(factory, forKey: .factory)
            try container.encode(String(id), forKey: .id)
            try container.encode(retired, forKey: .retired)
        }
    }
}
