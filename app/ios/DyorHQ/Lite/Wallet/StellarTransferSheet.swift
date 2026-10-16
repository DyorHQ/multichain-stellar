// Transfer between Spot and Earn on Stellar (docs/DESIGN-stellar-parity.md §8.8.4, §13.3). Internal builds only
// (STELLAR_LITE).
// SEAM(WP-32): today's Earn market sheet hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Which way a transfer goes: from Spot into Earn, or back.
enum StellarTransferDirection {
    case toEarn, toSpot
}

/// A transfer between Spot and Earn, as a sheet with its Close, for `market` (an Earn market's id or asset; Blend's first
/// when nil). Until the port lands, today's Earn market sheet, the closest, with its deposit and withdraw.
struct StellarTransferSheet: View {
    let direction: StellarTransferDirection
    let market: String?
    @Environment(\.stellarSession) private var session
    @Environment(\.stellarActions) private var actions

    init(direction: StellarTransferDirection, market: String?) {
        self.direction = direction
        self.market = market
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.earnMarket(session: session, market: market, chrome: chrome)
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
