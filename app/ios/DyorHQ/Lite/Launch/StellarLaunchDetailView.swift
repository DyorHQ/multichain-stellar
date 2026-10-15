// A Stellar launch's page (docs/DESIGN-stellar-parity.md §8.10.2, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-36): today's launch page hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The page of the coin `token` (its contract, C…), pushed: its price, trades and curve ticket. Until the port lands,
/// today's launch page.
struct StellarLaunchDetailView: View {
    let token: String
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(token: String) {
        self.token = token
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.launch(token: token, session: session, chrome: chrome)
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
