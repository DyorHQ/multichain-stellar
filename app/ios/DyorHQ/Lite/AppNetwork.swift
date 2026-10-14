// The network the app shows, Monad or Stellar (docs/DESIGN-network-switch.md). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import Foundation

/// The network on screen: Monad, build 23's screens, or Stellar, DyorLite's. The user picks it with the network chip on
/// Home or in Profile; it is remembered per account (`stored(for:)`), and a new account starts on Monad. Never called a
/// mode on screen: the words are the networks' names.
enum AppNetwork: String, CaseIterable, Identifiable, Hashable {
    /// Listed first: the sheet's rows and the push between the two Homes keep this order (Monad leading, Stellar trailing).
    case monad, stellar

    var id: String { rawValue }

    /// The network's name. Never translated: drawn with `Text(verbatim:)`, and a `%@` that names it isn't translated
    /// either.
    var name: String {
        switch self {
        case .monad: return "Monad" // not localized: a network's name
        case .stellar: return "Stellar" // not localized: a network's name
        }
    }

    /// The bundled image of the network's mark (`NetworkMark`): `logo-MON.png` from TokenLogos, and `logo-XLM.png`,
    /// Stellar's official mark, which only the internal app ships (Internal/Resources, added by Internal/generate.py;
    /// ruling 3).
    var markImage: String {
        switch self {
        case .monad: return "logo-MON"
        case .stellar: return "logo-XLM"
        }
    }

    /// A test network, whose balances have no value: Stellar, whose contracts this build pins to Stellar's testnet
    /// (`LiteGate.isTestnet`). It decides the Testnet badge and every testnet line, so a mainnet build needs no change to
    /// them (open question 7).
    var isTestnet: Bool {
        switch self {
        case .monad: return false
        case .stellar: return LiteGate.isTestnet
        }
    }

    /// The chain, as Profile's Network section names it: "Monad mainnet", "Stellar testnet".
    var chainLabel: String {
        switch self {
        case .monad: return tr("Monad mainnet")
        case .stellar: return isTestnet ? liteTr(LocalizedStringResource("Stellar testnet", table: "Lite", comment: "Profile › Network, the Chain row, when Stellar is the network: Stellar's test network. Stellar is a network's name, never translated")) : name
        }
    }

    /// What DyorHQ does on the network, under its name in the network sheet.
    var summary: String {
        switch self {
        case .monad: return liteTr(LocalizedStringResource("Spot, perps, launches and Moments", table: "Lite", comment: "The network sheet: what DyorHQ does on Monad, under its name. “Moments” is a feature name. At most 2 lines"))
        case .stellar: return liteTr(LocalizedStringResource("Earn, swap, launch and collect", table: "Lite", comment: "The network sheet: what you can do on Stellar in DyorHQ, under its name. At most 2 lines"))
        }
    }
}

/// Stellar's tabs: Home, Earn, Launch, Moments (§3.3), as the router keeps the selection (`Router.stellarTab`) and the
/// side menu's Stellar rows open them; DyorLite's tab bar takes them as `LiteTab`.
enum StellarTab: String, CaseIterable, Identifiable, Hashable {
    case home, earn, launch, moments
    var id: String { rawValue }

    init(_ tab: LiteTab) {
        switch tab {
        case .home: self = .home
        case .earn: self = .earn
        case .launch: self = .launch
        case .moments: self = .moments
        }
    }

    /// DyorLite's tab for it; setting one selects the matching tab (the tab bar's selection, `NetworkRoot`).
    var liteTab: LiteTab {
        get {
            switch self {
            case .home: return .home
            case .earn: return .earn
            case .launch: return .launch
            case .moments: return .moments
            }
        }
        set { self = StellarTab(newValue) }
    }
}

/// Whether the account signed in can switch to Stellar on this iPhone, and if not, why (§2.1). Only asked where the network
/// control exists (`LiteGate.availability`): there, an account that can't use Stellar still sees the control, and the
/// sheet's Stellar row says why instead of being missing.
enum NetworkAvailability: Hashable {
    case offered
    case unavailable(Reason)

    enum Reason: Hashable {
        /// A sign-in method whose wallet has no Stellar key yet: Apple, Google, an email code, a Privy passkey.
        case signInMethod(Session.Method)
        /// A watched address: nothing can be signed.
        case watchOnly
        /// An email & password account whose Stellar key isn't on this iPhone: it signed in before Stellar support.
        case signInAgain
        /// An imported wallet whose Stellar key isn't on this iPhone: it was imported before Stellar support.
        case importAgain

        /// The reason, in the app's language, as the sheet's Stellar row says it.
        var message: String {
            switch self {
            case .signInMethod(let method):
                return liteTr(LocalizedStringResource("Not available for \(method.nameInSentence) sign-in yet.", table: "Lite", comment: "The network sheet's Stellar row, when this account can't use Stellar: %@ is the sign-in method as written in a sentence (Apple, Google, email, passkey (Privy))"))
            case .watchOnly:
                return liteTr(LocalizedStringResource("Not available while watching an address.", table: "Lite", comment: "The network sheet's Stellar row, for a watched address: Stellar can't be used without signing in"))
            case .signInAgain:
                return liteTr(LocalizedStringResource("Sign in again with your email and password to use Stellar on this iPhone.", table: "Lite", comment: "The network sheet's Stellar row, for an email & password account whose Stellar key isn't on this iPhone yet: signing in again creates it"))
            case .importAgain:
                return liteTr(LocalizedStringResource("Import this wallet again on this iPhone to use Stellar.", table: "Lite", comment: "The network sheet's Stellar row, for an imported wallet whose Stellar key isn't on this iPhone yet: importing it again creates it"))
            }
        }
    }

    /// Why Stellar can't be chosen; nil when it can.
    var reason: Reason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: Remembered per account

extension AppNetwork {
    private static func key(_ address: Address) -> String { "network.\(address)" }
    private static func introKey(_ address: Address) -> String { "network.stellarIntroSeen.\(address)" }
    /// The internal build's earlier key, "pro" or "lite" (the drop-in's `AppMode`), moved to `network.<address>` once.
    private static func legacyKey(_ address: Address) -> String { "lite.mode.\(address)" }

    /// The network `address` was last on: Monad for a new account, and with nobody signed in. A value the earlier key
    /// left is moved over the first time, and that key removed.
    static func stored(for address: Address?, defaults: UserDefaults = .standard) -> AppNetwork {
        guard let address else { return .monad }
        if let raw = defaults.string(forKey: key(address)) { return AppNetwork(rawValue: raw) ?? .monad }
        guard let mode = defaults.string(forKey: legacyKey(address)) else { return .monad }
        let network: AppNetwork = mode == "lite" ? .stellar : .monad
        defaults.set(network.rawValue, forKey: key(address))
        defaults.removeObject(forKey: legacyKey(address))
        return network
    }

    static func store(_ network: AppNetwork, for address: Address?, defaults: UserDefaults = .standard) {
        guard let address else { return }
        defaults.set(network.rawValue, forKey: key(address))
        defaults.removeObject(forKey: legacyKey(address))
    }

    /// Whether this account has been through Confirm on this iPhone: the first switch to Stellar explains what changes
    /// (§3.6.2), and later switches don't.
    static func stellarIntroSeen(for address: Address?, defaults: UserDefaults = .standard) -> Bool {
        guard let address else { return false }
        return defaults.bool(forKey: introKey(address))
    }

    /// Marked when Confirm's "Switch to Stellar" is tapped: the Setup run that follows is the consent.
    static func markStellarIntroSeen(for address: Address?, defaults: UserDefaults = .standard) {
        guard let address else { return }
        defaults.set(true, forKey: introKey(address))
    }

    /// Sign-out and erase (`LiteKeyBootstrap.forget`): the network and the intro remembered for `address`, and the earlier
    /// key if it was never moved.
    static func forget(_ address: Address, defaults: UserDefaults = .standard) {
        for key in [key(address), introKey(address), legacyKey(address)] { defaults.removeObject(forKey: key) }
    }
}

extension String {
    /// A Stellar address as Profile shows it: its first and last four characters, `GBQ4…7ZKD`.
    var stellarShort: String { count > 12 ? "\(prefix(4))…\(suffix(4))" : self }
}
#endif
