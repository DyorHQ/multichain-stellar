// Profile's Stellar account page (docs/DESIGN-stellar-parity.md §8.12.2, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-41): today's account page hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// The Stellar account page, pushed in Profile: the address, Secured by, the secret key, Sign out of Stellar. Until the
/// port lands, today's account page.
struct StellarAccountView: View {
    @Environment(\.stellarSession) private var session

    var body: some View {
        if let session {
            LiteLegacyScreens.account(session: session, style: .dyorHQ)
        } else {
            ProgressView()
        }
    }
}

extension LiteStyle {
    /// DyorHQ's own colours for today's Stellar screens that Profile shows (`StellarProfile`'s rows and sheets, and this
    /// page): Brand, the status colours and the label on them. They go with the port of these Profile pieces.
    static let dyorHQ = LiteStyle(accent: .brand, positive: .positive, negative: .negative, attention: .attention, onStatus: .onStatus)
}
#endif
