// Stellar's Moments tab (docs/DESIGN-stellar-parity.md §8.11.1, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-39): today's Moments hosts the tab until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The Moments tab: Stellar's editions and the account's collection, with Publish. A Moment a notification names opens
/// over it. Until the port lands, today's Moments.
struct StellarMomentsView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    /// The Moment a Stellar destination asked for, open over the board.
    @State private var moment: Int?

    var body: some View {
        Group {
            if let session {
                LiteLegacyScreens.moments(session: session, chrome: chrome)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: Binding(get: { moment != nil }, set: { if !$0 { moment = nil } })) {
            // Today's Moment page brings its own navigation and Close.
            if let moment { StellarMomentDetailView(id: moment) }
        }
        .onChange(of: router.pendingStellar, initial: true) { _, pending in
            guard case .moment(let id?) = pending else { return }
            router.pendingStellar = nil
            moment = id
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
