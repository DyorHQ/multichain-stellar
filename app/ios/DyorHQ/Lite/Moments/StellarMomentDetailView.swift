// A Stellar Moment's page (docs/DESIGN-stellar-parity.md §8.11.2, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-38): today's Moment page hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The page of the Moment `id`, with its collect ticket. Until the port lands, today's Moment page, read by its id, which
/// brings its own navigation and Close.
struct StellarMomentDetailView: View {
    let id: Int
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(id: Int) {
        self.id = id
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.moment(id: id, session: session, chrome: chrome)
        } else {
            ProgressView()
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
