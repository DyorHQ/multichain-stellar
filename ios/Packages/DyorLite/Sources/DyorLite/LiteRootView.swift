import StellarKit
import SwiftUI

/// The Stellar screens: Home · Earn · Launch · Moments, in DyorHQ's own look (the host's tokens, header and chip).
/// The host shows it in place of Monad's tabs while the account is on Stellar, and keeps the selection.
///
/// It follows the session: ready → the four tabs with the account's figures; unavailable → Home with the paused card;
/// still opening → a spinner. Nothing on Stellar locks (decision 6). Each time it appears it looks again, without a
/// prompt, at a session that isn't ready or mid-run (`resumeAtLaunch()`), and a ready one shows its last figures at once
/// and reads them again (spec §2.6 rule 6).
@MainActor
public struct LiteRootView: View {
    private let session: LiteSession
    @Binding private var selection: LiteTab
    private let style: LiteStyle
    private let chrome: LiteChrome

    public init(session: LiteSession, selection: Binding<LiteTab>, style: LiteStyle, chrome: LiteChrome) {
        self.session = session
        _selection = selection
        self.style = style
        self.chrome = chrome
    }

    public var body: some View {
        TabView(selection: $selection) {
            LiteHomeView(session: session)
                .tabItem { Label(tr("Home"), systemImage: "house") }
                .tag(LiteTab.home)
            tab { LiteEarnView() }
                .tabItem { Label(tr("Earn"), systemImage: "leaf") }
                .tag(LiteTab.earn)
            tab { LiteLaunchView() }
                .tabItem { Label(tr("Launch"), systemImage: "flame") }
                .tag(LiteTab.launch)
            tab { LiteMomentsView() }
                .tabItem { Label(tr("Moments"), systemImage: "camera.aperture") }
                .tag(LiteTab.moments)
        }
        .sensoryFeedback(.selection, trigger: selection)
        .environment(\.liteStyle, style)
        .environment(\.liteChrome, chrome)
        .task {
            await session.resumeAtLaunch()
            if session.state == .ready { await session.store?.refreshAll() }
        }
    }

    /// A tab that needs the account's figures: itself once the session is ready, else what Home's card says.
    @ViewBuilder
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if session.home == .ready, let store = session.store {
            content().environment(store)
        } else {
            LiteRestingTab(session: session)
        }
    }
}

/// Earn, Launch or Moments while the session is paused or still opening: what Home's card says, with its button.
struct LiteRestingTab: View {
    let session: LiteSession
    @Environment(\.liteChrome) private var chrome

    var body: some View {
        switch session.home {
        case .paused(let failure):
            ContentUnavailableView {
                Label(failure.errorDescription ?? "", systemImage: "pause.circle")
            } actions: {
                LitePrimaryButton(title: tr("Switch to Monad"), action: chrome.switchToMonad)
                    .fixedSize()
            }
        case .loading, .ready:
            ProgressView()
        }
    }
}
