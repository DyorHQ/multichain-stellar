import StellarKit
import SwiftUI

/// Today's Stellar screens, public so the app's seams (docs/DESIGN-stellar-parity.md §13.3) can host them until each
/// port lands; they go with the ports (WP-50). Each takes the account's session and draws in `style` (DyorHQ's colours by
/// default). A screen that needs the account's figures shows the paused card (its "Switch to Monad" is `chrome`'s) or a
/// spinner until the session is ready. The tab screens and the pages bring their own navigation; the sheets bring their
/// own Close.
@MainActor
public enum LiteLegacyScreens {
    /// Stellar Home: the balance card with the host's chip, the actions, My Holdings and Activity, under the host's
    /// header. Its own navigation stack.
    public static func home(session: LiteSession, chrome: LiteChrome, style: LiteStyle = .default) -> some View {
        LiteHomeView(session: session)
            .environment(\.liteStyle, style)
            .environment(\.liteChrome, chrome)
    }

    /// Earn: Blend's markets, each with its deposit and withdraw. Its own navigation stack.
    public static func earn(session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteEarnView() }
    }

    /// One Earn market's deposit and withdraw (a sheet, with its Close): the market whose id (`EarnMarket.id`) or asset
    /// is `market`, else Blend's first; Earn's list until the markets are read.
    public static func earnMarket(session: LiteSession, market: String?, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteLegacyEarnMarket(market: market) }
    }

    /// Swap, `sell` for `buy` (registry ids or a coin's contract; XLM for USDC by default). A sheet, with its Close.
    public static func swap(session: LiteSession, sell: String? = nil, buy: String? = nil, style: LiteStyle = .default,
                            chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) {
            SwapSheet(initialSell: sell ?? (buy == "XLM" ? "USDC" : "XLM"), initialBuy: buy ?? (sell == "USDC" ? "XLM" : "USDC"))
        }
    }

    /// The launch list, with Create. Its own navigation stack.
    public static func launchBoard(session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteLaunchView() }
    }

    /// A coin's page: price, trades, the curve ticket. Pushed in the host's navigation.
    public static func launch(token: String, session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LaunchDetailView(token: token) }
    }

    /// The Moments board and the account's collection, with Publish. Its own navigation stack.
    public static func moments(session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteMomentsView() }
    }

    /// A Moment, read by its id, with its collect ticket (it brings its own navigation and Close).
    public static func moment(id: Int, session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteLegacyMomentPage(id: id) }
    }

    /// Deposit: the address and its QR code, and test XLM on testnet. A sheet, with its Close.
    public static func receive(session: LiteSession, style: LiteStyle = .default) -> some View {
        LiteDepositSheet(session: session).environment(\.liteStyle, style)
    }

    /// Withdraw: a send to another Stellar address, of `asset` (XLM by default). A sheet, with its Close.
    public static func send(session: LiteSession, asset: String? = nil, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { SendSheet(asset: asset) }
    }

    /// The bridge between Monad and Stellar, starting `toStellar` or the other way. A sheet, with its Close.
    public static func bridge(session: LiteSession, toStellar: Bool = true, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { BridgeSheet(toStellar: toStellar) }
    }

    /// Add cash (`deposit`) or Cash out through an anchor. A sheet, with its Close.
    public static func cash(session: LiteSession, deposit: Bool, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { CashSheet(deposit: deposit) }
    }

    /// The search over the account's holdings and the launches; `onPick` gets the asset id or the coin's contract. A
    /// sheet, with its Cancel.
    public static func search(session: LiteSession, style: LiteStyle = .default, onPick: @escaping (String) -> Void) -> some View {
        LiteSearchSheet(store: session.home == .ready ? session.store : nil) { pick in
            switch pick {
            case .holding(let asset): onPick(asset)
            case .launch(let token): onPick(token)
            }
        }
        .environment(\.liteStyle, style)
    }

    /// The Stellar account page: the address, Secured by, the secret key, test XLM, Sign out of Stellar. Pushed in the
    /// host's navigation.
    public static func account(session: LiteSession, style: LiteStyle = .default) -> some View {
        LiteAccountView(session: session).environment(\.liteStyle, style)
    }

    /// The account's activity, as Home's card lists it, on a page of its own: the closest to Recent Activity and to
    /// Portfolio's activity. Pushed in the host's navigation.
    public static func activity(session: LiteSession, style: LiteStyle = .default, chrome: LiteChrome = .none) -> some View {
        LiteLegacyHost(session: session, style: style, chrome: chrome) { LiteLegacyActivity() }
    }
}

public extension LiteSession.State {
    /// No such state: nothing on Stellar locks (decision 6). The name stays only so the app's network sheet, which still
    /// names it beside `.idle` and `.ready`, compiles until it is ported (WP-22); it reads as `.idle`.
    @available(*, deprecated, message: "Nothing on Stellar locks (decision 6): there is no locked state.")
    static var locked: Self { .idle }
}

/// A legacy screen that needs the account's figures: itself, with the store, once the session is ready; the paused card
/// or a spinner until then.
struct LiteLegacyHost<Content: View>: View {
    let session: LiteSession
    let style: LiteStyle
    let chrome: LiteChrome
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if session.home == .ready, let store = session.store {
                content().environment(store)
            } else {
                LiteRestingTab(session: session)
            }
        }
        .environment(\.liteStyle, style)
        .environment(\.liteChrome, chrome)
    }
}

/// An Earn market's sheet for a market given by id or asset; Earn's list until the markets are read.
private struct LiteLegacyEarnMarket: View {
    let market: String?
    @Environment(LiteStore.self) private var store

    var body: some View {
        Group {
            if let found = store.earnMarkets.first(where: { $0.id == market || $0.asset == market }) ?? store.earnMarkets.first {
                EarnMarketSheet(market: found)
            } else {
                LiteEarnView()
            }
        }
        .task { if store.earnMarkets.isEmpty { await store.refreshEarn() } }
    }
}

/// A Moment read by its id, then its sheet.
private struct LiteLegacyMomentPage: View {
    let id: Int
    @Environment(LiteStore.self) private var store
    @State private var moment: StellarMoment?
    @State private var error: String?

    var body: some View {
        Group {
            if let moment {
                MomentSheet(moment: moment)
            } else if let error {
                LiteInlineError(message: error).padding(40)
            } else {
                ProgressView()
            }
        }
        .task {
            do { moment = try await store.momentDetail(id).moment } catch { self.error = LiteErrorText.describe(error) }
        }
    }
}

/// The account's activity as a list, read on appear and on pull to refresh.
private struct LiteLegacyActivity: View {
    @Environment(LiteStore.self) private var store

    var body: some View {
        List {
            switch store.status(.activity) {
            case .needsSignIn:
                Text(tr("Sign in on Stellar to continue.")).foregroundStyle(.secondary)
            default:
                if store.activity.isEmpty {
                    if store.failed.contains(.activity) {
                        LiteInlineError(message: store.lastError ?? tr("No connection. Check your network and try again."))
                    } else if store.loaded.contains(.activity) {
                        Text(tr("Nothing yet. Add cash or swap to get started.")).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(store.activity) { LiteActivityRow(item: $0) }
                }
            }
        }
        .navigationTitle(tr("Activity"))
        .task { await store.refreshActivity() }
        .refreshable { await store.refreshActivity() }
    }
}
