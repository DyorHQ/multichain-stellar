// Withdraw on Stellar (docs/DESIGN-stellar-parity.md §8.8.2, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-32): today's send sheet hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Withdraw, as a sheet with its Close: a send of `asset` (XLM when nil) to another Stellar address. Until the port lands,
/// today's send sheet.
struct StellarSendSheet: View {
    let asset: String?
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(asset: String? = nil) {
        self.asset = asset
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.send(session: session, asset: asset, chrome: chrome)
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
