// Where the Stellar section's routes lead: its Earn tab's two sides, its destinations and their references, and the
// router's Stellar half (docs/DESIGN-stellar-parity.md §3.7). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import Foundation
import StellarKit

/// Which side of Stellar's Earn tab is shown, as `TradeMode` picks Monad's Trade tab's: Swap and Earn share the tab,
/// switched by its top switch (`StellarTradeModeSwitcher`). The tab opens on Earn.
enum StellarTradeMode: String, CaseIterable, Identifiable {
    case swap, earn
    var id: String { rawValue }

    /// The side's name on the switch, in the app's language: Monad's Swap, and Stellar's Earn.
    var label: String {
        switch self {
        case .swap: TradeMode.swap.label
        case .earn: MenuItem.earnTitle
        }
    }
}

/// A swap to open: the asset to sell and the one to buy (registry ids, or a coin's contract; nil leaves a side as Swap
/// has it), and whether DyorHQ pays its network fee as the starter swap (§8.6.2).
struct StellarSwapRequest: Hashable {
    var sell: String?
    var buy: String?
    var starter = false
}

/// A place in the Stellar section, and its reference: "stellar:<tab>[/<id>]", what a Stellar notification carries
/// (`StellarActivityRecorder`) and what `Router.open(route:reference:)` follows back. No Monad reference starts with
/// "stellar:".
///
/// | Reference | Destination |
/// |---|---|
/// | `stellar:home` | Home |
/// | `stellar:swap[/<sell>,<buy>]` | Swap, either side may be empty |
/// | `stellar:earn[/<marketId>]` | Earn |
/// | `stellar:launch[/<C…>]` | Launch |
/// | `stellar:moment[/<id>]` | Moment |
/// | `stellar:portfolio` | Portfolio |
/// | `stellar:bridge[/<id>]` | Bridge |
///
/// The starter swap is never in a reference: a notification never offers DyorHQ's fee again.
enum StellarDestination: Hashable {
    case home
    case swap(StellarSwapRequest)
    case earn(market: String?)
    case launch(token: String?)
    case moment(id: Int?)
    case portfolio
    case bridge(id: String?)

    /// What starts every Stellar reference.
    static let scheme = "stellar:"

    /// The destination `reference` names; nil for anything else (a Monad reference, a malformed one).
    init?(reference: String) {
        guard reference.hasPrefix(Self.scheme) else { return nil }
        let path = reference.dropFirst(Self.scheme.count)
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let tab = String(parts[0])
        let id = parts.count > 1 ? String(parts[1]) : nil
        if let id, !Self.isPart(id) { return nil }
        switch tab {
        case "home" where id == nil: self = .home
        case "portfolio" where id == nil: self = .portfolio
        case "swap":
            guard let id else { self = .swap(StellarSwapRequest()); return }
            let sides = id.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard sides.count == 2, sides.contains(where: { !$0.isEmpty }) else { return nil }
            self = .swap(StellarSwapRequest(sell: sides[0].isEmpty ? nil : sides[0], buy: sides[1].isEmpty ? nil : sides[1]))
        case "earn": self = .earn(market: id)
        case "launch":
            if let id, !StrKey.isValid(.contract, id) { return nil }
            self = .launch(token: id)
        case "moment":
            guard let id else { self = .moment(id: nil); return }
            guard id.allSatisfy(\.isASCII), let number = Int(id), number >= 0 else { return nil }
            self = .moment(id: number)
        case "bridge": self = .bridge(id: id)
        default: return nil
        }
    }

    /// The reference that names it; `init?(reference:)` reads it back as this destination (the starter flag aside).
    var reference: String {
        let path: String
        switch self {
        case .home: path = "home"
        case .swap(let request):
            path = request.sell == nil && request.buy == nil ? "swap" : "swap/\(request.sell ?? ""),\(request.buy ?? "")"
        case .earn(let market): path = market.map { "earn/\($0)" } ?? "earn"
        case .launch(let token): path = token.map { "launch/\($0)" } ?? "launch"
        case .moment(let id): path = id.map { "moment/\($0)" } ?? "moment"
        case .portfolio: path = "portfolio"
        case .bridge(let id): path = id.map { "bridge/\($0)" } ?? "bridge"
        }
        return Self.scheme + path
    }

    /// The tab it opens; nil for Portfolio, which opens over the tabs.
    var tab: StellarTab? {
        switch self {
        case .home, .bridge: .home
        case .swap, .earn: .earn
        case .launch: .launch
        case .moment: .moments
        case .portfolio: nil
        }
    }

    /// An id in a reference: 1 to 128 ASCII letters, digits and `:`, `,`, `.`, `_` or `-`, enough for asset ids, contracts,
    /// market ids and transfer ids, and nothing that could read as another part.
    private static func isPart(_ text: String) -> Bool {
        (1...128).contains(text.count)
            && text.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":,._-".unicodeScalars.contains($0)) }
    }
}

extension Router {
    /// To Stellar for a Stellar destination: at once, with no sheet and no prompt, as at a cold launch, where the account
    /// can use Stellar on this iPhone (`stellarAvailable`, which `NetworkRoot` keeps). Otherwise the app stays where it is,
    /// saying why, and this is false.
    func ensureStellar() -> Bool {
        guard stellarAvailable else {
            linkNotice = liteTr(LocalizedStringResource("Stellar isn't available for this account.", table: "StellarShell", comment: "A notice at the bottom of the screen: a Stellar notification or link was tapped, but this account can't use Stellar on this iPhone. Stellar is a network's name, never translated"))
            return false
        }
        network = .stellar
        return true
    }

    /// Opens `destination` on Stellar, which must be on screen: the menu and whatever is presented close, the tab (and the
    /// Earn tab's side) switch, and `pendingStellar` says what the tab's screen opens, which clears it once opened.
    func openStellar(_ destination: StellarDestination) {
        presented = nil
        menuOpen = false
        if let tab = destination.tab { stellarTab = tab }
        switch destination {
        case .swap: stellarTradeMode = .swap
        case .earn: stellarTradeMode = .earn
        case .home, .launch, .moment, .portfolio, .bridge: break
        }
        switch destination {
        case .home, .portfolio, .earn(market: nil), .launch(token: nil), .moment(id: nil):
            pendingStellar = nil
        case .swap, .earn, .launch, .moment, .bridge:
            pendingStellar = destination
        }
        if destination == .portfolio { presented = .portfolio }
    }

    /// Follows a Stellar notification's reference: true when `reference` is Stellar's ("stellar:…"), whether or not it
    /// could open (`ensureStellar`). One a later build wrote that this one can't read opens Stellar Home.
    func openStellar(reference: String?) -> Bool {
        guard let reference, reference.hasPrefix(StellarDestination.scheme) else { return false }
        guard ensureStellar() else { return true }
        openStellar(StellarDestination(reference: reference) ?? .home)
        return true
    }

    /// The one way into a Stellar swap: Home's search, a token page's Swap, a graduated launch's Buy and Sell, the side
    /// menu's Spot and the add-funds card. The Earn tab opens on its Swap side.
    func openStellarSwap(sell: String? = nil, buy: String? = nil, starter: Bool = false) {
        openStellar(.swap(StellarSwapRequest(sell: sell, buy: buy, starter: starter)))
    }

    /// A side menu row on Stellar: Home, Launch and Moments are its tabs, Spot the Earn tab's Swap side, Earn its Earn side,
    /// and Portfolio Stellar's own, over the tabs. False for the rows both networks share (News, Get Help), which Monad's
    /// handling opens as they are.
    func openOnStellar(_ item: MenuItem) -> Bool {
        switch item {
        case .home: openStellar(.home)
        case .spot: openStellarSwap()
        case .earn: openStellar(.earn(market: nil))
        case .launch: openStellar(.launch(token: nil))
        case .moments: openStellar(.moment(id: nil))
        case .portfolio: openStellar(.portfolio)
        case .perps, .news, .help: return false
        }
        return true
    }

    /// Whether `item` is the section on screen on Stellar, for the side menu's "Now": its tab, and on the Earn tab, Spot
    /// for the Swap side and Earn for the Earn side.
    func isCurrentOnStellar(_ item: MenuItem) -> Bool {
        guard let tab = item.stellarTab, tab == stellarTab else { return false }
        switch item {
        case .spot: return stellarTradeMode == .swap
        case .earn: return stellarTradeMode == .earn
        case .home, .perps, .launch, .moments, .news, .portfolio, .help: return true
        }
    }
}
#endif
