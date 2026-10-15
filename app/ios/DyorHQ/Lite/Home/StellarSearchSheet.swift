// The Stellar search (docs/DESIGN-stellar-parity.md §8.4, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-30): today's search hosts the sheet until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// What a search is for: browsing from Home's header, or picking the asset to pay with or to receive in Swap.
enum StellarSearchPurpose {
    case browse, pay, receive
}

/// The search over Stellar's assets and launches, as a sheet with its Cancel; `onPick` gets the asset id or the coin's
/// contract. Until the port lands, today's search, for every purpose.
struct StellarSearchSheet: View {
    let purpose: StellarSearchPurpose
    let onPick: (String) -> Void
    @Environment(\.stellarSession) private var session

    init(purpose: StellarSearchPurpose, onPick: @escaping (String) -> Void) {
        self.purpose = purpose
        self.onPick = onPick
    }

    var body: some View {
        if let session {
            LiteLegacyScreens.search(session: session, onPick: onPick)
        } else {
            ProgressView()
        }
    }
}
#endif
