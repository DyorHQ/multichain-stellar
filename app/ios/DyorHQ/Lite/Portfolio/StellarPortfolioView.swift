// Stellar's Portfolio (docs/DESIGN-stellar-parity.md §8.12.1, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-40): today's activity list hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Portfolio while Stellar is on screen, opened from the side menu as a full-screen cover with its own navigation and
/// Close, as Monad's is (`AppCovers`). Until the port lands, the account's Stellar activity, the closest of today's
/// screens.
struct StellarPortfolioView: View {
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    LiteLegacyScreens.activity(session: session, chrome: chrome)
                } else {
                    ProgressView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
