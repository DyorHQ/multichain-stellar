// Deposit on Stellar (docs/DESIGN-stellar-parity.md §8.8.1, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-32): today's deposit sheet hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Deposit, as a sheet with its Close: the account's Stellar address and its QR code. Until the port lands, today's
/// deposit sheet.
struct StellarReceiveSheet: View {
    @Environment(\.stellarSession) private var session

    var body: some View {
        if let session {
            LiteLegacyScreens.receive(session: session)
        } else {
            ProgressView()
        }
    }
}
#endif
