import DyorKit
import Foundation
import Observation
import SwiftUI

/// A review sheet counts itself in `Router.linkHolds` while it is on screen, so a Moment link waits until it is gone.
private struct HoldsMomentLinks: ViewModifier {
    @Environment(Router.self) private var router
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onAppear { if !counted { counted = true; router.linkHolds += 1 } }
            .onDisappear { if counted { counted = false; router.linkHolds = max(0, router.linkHolds - 1) } }
    }
}

extension View {
    /// Holds Moment links while this view is on screen (every review sheet that can lead to a signature).
    func holdsMomentLinks() -> some View { modifier(HoldsMomentLinks()) }
}

/// Which trading interface the Trade tab shows. Swap and Perps share one tab, switched by a top toggle.
enum TradeMode: String, CaseIterable, Identifiable {
    case swap, perps
    var id: String { rawValue }
    /// The mode's name on the Trade tab's switch, in the app's language. The swap side has a key of its own, "Swap" in
    /// English: the key "Swap" is the swap review's button, a verb, and one key is one translation.
    var label: String {
        switch self {
        case .swap: tr(LocalizedStringResource("tradeMode.swap", defaultValue: "Swap", comment: "The Trade tab's switch to its spot-swap screen: the screen's name, a noun [tight]"))
        case .perps: tr(LocalizedStringResource("Perps", comment: "Perpetual futures [tight]"))
        }
    }
}

/// Screens that live outside the tab bar: opened from the side menu (or the home header) as full-screen covers with
/// their own navigation stack and a Close control.
enum PresentedScreen: String, Identifiable {
    case portfolio, news, help, profile, notifications
    var id: String { rawValue }
}

/// Cross-tab navigation requests, e.g. "swap this token" from a market row.
@Observable
@MainActor
final class Router {
    /// The app's one router. Shared so the notification delegate can hand it a tapped banner (`receive`), which at a cold
    /// start arrives before any view is on screen.
    static let shared = Router()

    var tab: AppTab = .home
    /// The side menu (the three-line button on Home) is open.
    var menuOpen = false
    /// A full-screen section opened from the menu or the home header.
    var presented: PresentedScreen?
    /// The reporting period every volume figure in the app uses (Home's Total Volume and the Portfolio).
    var period: VolumePeriod = .all
    /// Which side of the Trade tab is shown (Swap vs Perps).
    var tradeMode: TradeMode = .swap
    var pendingSwap: (tokenIn: Token?, tokenOut: Token?)?
    var pendingPerpMarket: Int?
    /// A launch to open on the Launch tab's detail page, set from another tab or the post-launch "View" action.
    var pendingLaunch: Launch?
    /// A launch to open by reference on the Launch tab, when the screen that sent it couldn't read the launch itself
    /// (`CurveRoute.launchUnread`): the tab pushes `LaunchReferenceView`, which reads it.
    var pendingLaunchReference: LaunchReference?
    /// A Moment to open on the Moments tab's detail page.
    var pendingMoment: MomentInfo?
    /// A Moment link that arrived (a universal link or `dyorhq://`) and hasn't been opened yet. It waits here, on the
    /// App-level router that outlives sign-in, until RootView's gate (`MomentLinkGate`) says the app may navigate.
    var pendingLink: MomentLink?
    /// A Moment link to open on the Moments tab: MomentsView pushes `MomentLinkView`, which resolves and loads it.
    var pendingMomentLink: MomentLink?
    /// A tapped banner's screen, waiting like `pendingLink` until RootView's gate (`NotificationRouteGate`) says the app
    /// may navigate. Only the latest tap waits: a banner tapped while another's screen waits replaces it, so the app
    /// navigates once.
    var pendingNotificationRoute: NotificationTap?
    /// Whether the waiting banner's route arrived after the waiting Moment link: when both may open at once, only the
    /// one that arrived last does.
    private(set) var notificationRouteArrivedLast = false
    /// A short notice about the last link handed to the app (not a Moment), shown once by RootView.
    var linkNotice: String?
    /// What holds a Moment link back right now: every review sheet on screen (`holdsMomentLinks()` — ConfirmationSheet,
    /// the Perps order / close / margin / TP/SL reviews, Bridge) and every approved send or deletion no sheet covers
    /// (`holdingLinks`). RootView's gate waits until it is 0, so a link never tears one down.
    var linkHolds = 0

    /// Every URL handed to the app. This parses and stores; nothing navigates until the gate delivers. A URL on our
    /// hosts that isn't a Moment link gets a notice; anything else (Privy's OAuth callback on the `dyorhq` scheme, say)
    /// is not ours to comment on.
    func handle(_ url: URL) {
        if let link = MomentLink(url: url) {
            pendingLink = link
            notificationRouteArrivedLast = false
        } else if MomentLink.isOurs(url) {
            linkNotice = tr("That link isn't a Moment.")
        }
    }

    /// A tapped banner (`Notifications.tapped`). Nothing navigates until the gate delivers it. A banner that names no
    /// screen opens the app as it was, and drops a screen still waiting from an earlier tap: the latest tap wins.
    func receive(_ tap: NotificationTap) {
        pendingNotificationRoute = tap.route == .none ? nil : tap
        notificationRouteArrivedLast = true
    }

    /// Opens the waiting banner's screen: the menu and whatever is presented close, as for a Moment link. A Perps alert
    /// opens its market, named by its record in the center (`NotificationHub.item`), which the gate has checked is the
    /// account signed in.
    func deliverPendingNotificationRoute() {
        guard let tap = pendingNotificationRoute else { return }
        pendingNotificationRoute = nil
        menuOpen = false
        open(route: tap.route, reference: tap.item.flatMap { NotificationHub.shared.item($0)?.reference })
    }

    /// Runs `work` — an approved send or a deletion that no review sheet covers — holding Moment links until it ends.
    /// The task takes the count, not the view that started it, because the task outlives that view.
    func holdingLinks<T>(_ work: () async throws -> T) async rethrows -> T {
        linkHolds += 1
        defer { linkHolds = max(0, linkHolds - 1) }
        return try await work()
    }

    /// Opens the pending link's Moment: the menu and whatever is presented close, and the Moments tab pushes it.
    func deliverPendingLink() {
        guard let link = pendingLink else { return }
        pendingLink = nil
        menuOpen = false
        presented = nil
        pendingMomentLink = link
        tab = .moments
    }

    /// Opens Swap on a pair. A retired cohort's Moment coin on either side opens nothing: past cohorts are claim-only,
    /// so trading their coins is closed everywhere in the app (cohorts 1 and 2's pools also pay the retired platform
    /// wallet), and the engine refuses it too.
    func openSwap(tokenIn: Token? = nil, tokenOut: Token? = nil) {
        guard SwapEngine.isTradablePair(tokenIn, tokenOut) else { return }
        pendingSwap = (tokenIn, tokenOut)
        tradeMode = .swap
        tab = .trade
    }

    func openPerp(id: Int) {
        pendingPerpMarket = id
        tradeMode = .perps
        tab = .trade
    }

    /// Opens `launch`'s page on the Launch tab. The last request wins: a reference still waiting is dropped.
    func openLaunch(_ launch: Launch) {
        pendingLaunchReference = nil
        pendingLaunch = launch
        tab = .launch
    }

    /// Opens a launch's page by reference, for a coin whose launch couldn't be read: the page reads it. The last request
    /// wins: a launch still waiting is dropped.
    func openLaunch(_ reference: LaunchReference) {
        pendingLaunch = nil
        pendingLaunchReference = reference
        tab = .launch
    }

    /// Opens the Launch page of a coin on a launchpad's curve, where it trades: from its launch, or by reference when its
    /// launch couldn't be read. Never the board, which doesn't list a retired launchpad's sell-only coin.
    func openLaunchPage(for route: CurveRoute) {
        switch route {
        case .launchPage(let launch): openLaunch(launch)
        case .launchUnread(let reference, _, _): openLaunch(reference)
        case .swap, .unchecked: openLaunchTab()
        }
    }

    /// Opens the Launch tab's board: Swap's way on when its curve check failed (`CurveRoute.unchecked`). The board lists
    /// the live launchpad's coins, and a retired one's holder finds theirs under "Your Sell-Only Coins".
    func openLaunchTab() {
        tab = .launch
    }

    func openMoment(_ moment: MomentInfo) {
        pendingMoment = moment
        tab = .moments
    }

    /// Opens a Moment by its link on the Moments tab, whose page reads it first (`MomentLinkView`): for a screen showing a
    /// Moment as it saved it when last read, which its page mustn't show as current.
    func openMoment(_ link: MomentLink) {
        pendingMomentLink = link
        tab = .moments
    }

    /// Follows a tapped row of the notification center to its screen.
    func open(_ notification: AppNotification) {
        open(route: notification.route, reference: notification.reference)
    }

    /// Follows a tapped notification, a row of the center or a banner, to its screen. `.none` opens nothing. A Perps
    /// alert's `reference` names its market (`PerpAlertText.reference`), which then opens; any other reference opens
    /// Perps as it was.
    func open(route: NotificationRoute, reference: String? = nil) {
        guard route != .none else { return }
        presented = nil
        switch route {
        case .none: break
        case .home: tab = .home
        case .trade: tradeMode = .swap; tab = .trade
        case .perps:
            if let market = PerpAlertText.market(reference: reference) { pendingPerpMarket = market }
            tradeMode = .perps; tab = .trade
        case .launch: tab = .launch
        case .moments: tab = .moments
        case .portfolio: presented = .portfolio
        }
    }

    /// Opens a section from the side menu: tabs switch (and the Trade tab picks its mode), the rest present.
    func open(_ item: MenuItem) {
        menuOpen = false
        switch item {
        case .home: tab = .home
        case .spot: tradeMode = .swap; tab = .trade
        case .perps: tradeMode = .perps; tab = .trade
        case .launch: tab = .launch
        case .moments: tab = .moments
        case .portfolio: presented = .portfolio
        case .news: presented = .news
        case .help: presented = .help
        }
    }
}

/// Reporting periods for volume, fees and P&L: the last day, week, month, or everything.
enum VolumePeriod: String, CaseIterable, Identifiable {
    case day, week, month, all
    var id: String { rawValue }
    /// The period's name in the app's language.
    var label: String {
        switch self {
        case .day: return tr(LocalizedStringResource("24h", comment: "A reporting period: the last 24 hours [tight]"))
        case .week: return tr(LocalizedStringResource("7 days", comment: "A reporting period: the last 7 days [tight]"))
        case .month: return tr(LocalizedStringResource("30 days", comment: "A reporting period: the last 30 days [tight]"))
        case .all: return tr(LocalizedStringResource("volumePeriod.all", defaultValue: "All", comment: "A reporting period: all time [tight]"))
        }
    }
    /// The period's short name, for a chip, in the app's language.
    var shortLabel: String {
        switch self {
        case .day: return tr(LocalizedStringResource("24h", comment: "A reporting period: the last 24 hours [tight]"))
        case .week: return tr(LocalizedStringResource("7D", comment: "A reporting period on a chip: the last 7 days [tight]"))
        case .month: return tr(LocalizedStringResource("30D", comment: "A reporting period on a chip: the last 30 days [tight]"))
        case .all: return tr(LocalizedStringResource("volumePeriod.all", defaultValue: "All", comment: "A reporting period: all time [tight]"))
        }
    }
    /// Wall-clock length; nil for "All".
    var seconds: TimeInterval? {
        switch self {
        case .day: return 86_400
        case .week: return 86_400 * 7
        case .month: return 86_400 * 30
        case .all: return nil
        }
    }
    /// The matching swap-history window (on-chain scans are bounded, so "All" is the scan's own cap).
    var swapWindow: SwapHistoryService.Window {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .all: return .all
        }
    }
    /// Blocks to scan for on-chain history (~0.4 s blocks); "All" covers the swap scan's 90-day cap.
    var blocks: UInt64 { swapWindow.blocks }
    /// The earliest timestamp inside the period (0 for "All").
    func since(now: Date = Date()) -> Date { seconds.map { now.addingTimeInterval(-$0) } ?? .distantPast }
}

/// The sections listed in the side menu, in display order.
enum MenuItem: String, CaseIterable, Identifiable {
    case home, spot, perps, launch, moments, news, portfolio, help
    var id: String { rawValue }

    /// The section's name in the menu, in the app's language.
    var title: String {
        switch self {
        case .home: return tr(LocalizedStringResource("Home", comment: "The Home tab's name, a noun"))
        case .spot: return tr(LocalizedStringResource("Spot", comment: "Spot, as against perpetual futures (Perps): the wallet's own tokens, and trading them by swaps [tight]"))
        case .perps: return tr(LocalizedStringResource("Perps", comment: "Perpetual futures [tight]"))
        case .launch: return tr(LocalizedStringResource("Launch", comment: "A noun: the Launch tab, the launchpad's coins [tight]"))
        case .moments: return tr(LocalizedStringResource("Moments", comment: "The Moments feature's name [tight]"))
        case .news: return tr("News")
        case .portfolio: return tr("Portfolio")
        case .help: return tr("Get Help")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .spot: return "arrow.left.arrow.right"
        case .perps: return "chart.line.uptrend.xyaxis"
        case .launch: return "flame"
        case .moments: return "camera.aperture"
        case .news: return "newspaper"
        case .portfolio: return "chart.pie"
        case .help: return "questionmark.circle"
        }
    }

    /// What the section holds, under its name in the menu, in the app's language.
    var subtitle: String {
        switch self {
        case .home: return tr("Balances and markets")
        case .spot: return tr("Swap across every Monad venue")
        case .perps: return tr("Perpetuals on Perpl")
        case .launch: return tr("Launch and trade new coins")
        case .moments: return tr("Collect moments, graduate coins")
        case .news: return tr("Crypto headlines")
        case .portfolio: return tr("Volume, fees and P&L across DyorHQ")
        case .help: return tr("Support and community")
        }
    }
}
