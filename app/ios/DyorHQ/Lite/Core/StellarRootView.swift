// The Stellar section's tab bar (docs/DESIGN-stellar-parity.md §3.6). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The Stellar section: Monad's tab bar on another network, Home · Launch · Earn · Moments, Earn in Trade's slot. The
/// router keeps the selection (`Router.stellarTab`), so the side menu and a notification open a tab as on Monad.
/// `NetworkRoot` shows it in place of `MainTabView` while the account is on Stellar, and presents the covers above both.
///
/// Home shows at once. The other tabs need the account's figures: until the session is ready they rest
/// (`StellarRestingTab`). Nothing on Stellar locks (decision 6): an account set up on this iPhone is ready at once, with
/// or without a session. Each time it appears it looks again, without a prompt, at a session that isn't ready or mid-run
/// (`resumeAtLaunch()`), and a ready one reads its figures again.
struct StellarRootView: View {
    let session: LiteSession
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.stellarTab) {
            Tab("Home", systemImage: "house", value: StellarTab.home) { StellarHomeView() }
            Tab("Launch", systemImage: "flame", value: StellarTab.launch) { resting { StellarLaunchpadView() } }
            Tab(MenuItem.earnTitle, systemImage: "leaf", value: StellarTab.earn) { resting { StellarTradeView() } }
            Tab("Moments", systemImage: "camera.aperture", value: StellarTab.moments) { resting { StellarMomentsView() } }
        }
        .sensoryFeedback(.selection, trigger: router.stellarTab)
        .task {
            await session.resumeAtLaunch()
            if session.home == .ready { await session.store?.refreshAll() }
        }
    }

    /// A tab that needs the account's figures: itself once the session is ready, else what it rests on.
    @ViewBuilder
    private func resting<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if session.home == .ready, session.store != nil {
            content()
        } else {
            StellarRestingTab(session: session)
        }
    }
}

/// Launch, Earn or Moments while the session is paused or still opening: why it is paused, with Switch to Monad, or a
/// spinner. There is no locked state (decision 6).
struct StellarRestingTab: View {
    let session: LiteSession
    @Environment(\.stellarActions) private var actions

    var body: some View {
        switch session.home {
        case .paused(let failure):
            ContentUnavailableView {
                Label {
                    Text(verbatim: LiteErrorText.describe(failure))
                } icon: {
                    Image(systemName: "pause.circle")
                }
            } actions: {
                PrimaryButton(title: Text("Switch to \(AppNetwork.monad.name)", tableName: "StellarShell", comment: "A button on a Stellar tab while DyorHQ on Stellar is paused: go back to the Monad network. %@ is the network's name (Monad), never translated")) {
                    actions.switchToMonad()
                }
                .fixedSize()
            }
        case .loading, .ready:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
