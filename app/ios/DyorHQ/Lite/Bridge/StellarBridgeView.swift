// The bridge between Monad and Stellar (docs/DESIGN-stellar-parity.md §8.9, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-33): today's bridge sheet hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Which way the bridge moves USDC.
enum StellarBridgeDirection {
    case toStellar, toMonad
}

/// The bridge, starting `direction`, as a sheet with its Close. Until the port lands, today's bridge sheet.
struct StellarBridgeView: View {
    let direction: StellarBridgeDirection
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(direction: StellarBridgeDirection = .toStellar) {
        self.direction = direction
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.bridge(session: session, toStellar: direction == .toStellar, chrome: chrome)
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
