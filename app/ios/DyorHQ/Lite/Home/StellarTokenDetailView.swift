// A Stellar token's page (docs/DESIGN-stellar-parity.md §8.3, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-30): today's closest screens host the page until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import StellarKit
import SwiftUI

/// The page of `asset` (a registry id, or a coin's contract), pushed. Until the port lands: a coin's launch page, or
/// Swap buying the asset, the closest of today's screens.
struct StellarTokenDetailView: View {
    let asset: String
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(asset: String) {
        self.asset = asset
    }

    var body: some View {
        if let session {
            if StrKey.isValid(.contract, asset) {
                LiteLegacyScreens.launch(token: asset, session: session, chrome: chrome)
            } else {
                LiteLegacyScreens.swap(session: session, buy: asset, chrome: chrome)
            }
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
