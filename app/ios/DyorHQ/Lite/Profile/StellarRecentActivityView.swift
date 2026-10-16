// The account's Stellar activity in Profile (docs/DESIGN-stellar-parity.md §8.12.3, §13.3). Internal builds only
// (STELLAR_LITE).
// SEAM(WP-41): today's activity list hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Recent Activity on Stellar, pushed in Profile: the account's Stellar transactions, newest first. Until the port
/// lands, today's activity list.
struct StellarRecentActivityView: View {
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    var body: some View {
        if let session {
            LiteLegacyScreens.activity(session: session, chrome: chrome)
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
