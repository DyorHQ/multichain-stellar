// The Swap side of Stellar's Earn tab (docs/DESIGN-stellar-parity.md §8.6.1, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-34): today's swap sheet hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Swap, under the Earn tab's Swap | Earn switch. It opens the pair a Swap entry asked for (`Router.openStellarSwap`).
/// Until the port lands, today's swap sheet.
struct StellarSwapView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    @State private var request = StellarSwapRequest()

    var body: some View {
        Group {
            if let session {
                // A new request starts the swap afresh on its pair.
                LiteLegacyScreens.swap(session: session, sell: request.sell, buy: request.buy, chrome: chrome)
                    .id(request)
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { StellarTradeModeSwitcher() }
        .onChange(of: router.pendingStellar, initial: true) { _, pending in
            guard case .swap(let next) = pending else { return }
            router.pendingStellar = nil
            request = next
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
