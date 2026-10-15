// The Earn side of Stellar's Earn tab (docs/DESIGN-stellar-parity.md §8.6.3, §13.3). Internal builds only
// (STELLAR_LITE).
// SEAM(WP-35): today's Earn hosts it until its port lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Earn, under the Earn tab's Swap | Earn switch: Blend's markets. A market a notification names opens over it. Until
/// the port lands, today's Earn.
struct StellarEarnView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    /// The market a Stellar destination asked for, open over the list.
    @State private var market: String?

    var body: some View {
        Group {
            if let session {
                LiteLegacyScreens.earn(session: session, chrome: chrome)
            } else {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { StellarTradeModeSwitcher() }
        .sheet(isPresented: Binding(get: { market != nil }, set: { if !$0 { market = nil } })) {
            if let session { LiteLegacyScreens.earnMarket(session: session, market: market, chrome: chrome) }
        }
        .onChange(of: router.pendingStellar, initial: true) { _, pending in
            guard case .earn(let id?) = pending else { return }
            router.pendingStellar = nil
            market = id
        }
    }

    /// The paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
