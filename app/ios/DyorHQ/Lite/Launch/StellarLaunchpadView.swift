// Stellar's Launch tab (docs/DESIGN-stellar-parity.md §8.10.1, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-37): today's launch list hosts the tab until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The Launch tab: the board of Stellar's launches, with Create. A launch a notification names opens over it. Until the
/// port lands, today's launch list.
struct StellarLaunchpadView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    /// The coin a Stellar destination asked for, its page open over the board.
    @State private var token: String?

    var body: some View {
        Group {
            if let session {
                LiteLegacyScreens.launchBoard(session: session, chrome: chrome)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: Binding(get: { token != nil }, set: { if !$0 { token = nil } })) {
            if let token {
                NavigationStack {
                    StellarLaunchDetailView(token: token)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { self.token = nil } } }
                }
            }
        }
        .onChange(of: router.pendingStellar, initial: true) { _, pending in
            guard case .launch(let next?) = pending else { return }
            router.pendingStellar = nil
            token = next
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
