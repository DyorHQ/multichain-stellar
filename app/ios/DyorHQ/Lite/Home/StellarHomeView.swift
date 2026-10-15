// Stellar Home (docs/DESIGN-stellar-parity.md §8.2, §13.3). Internal builds only (STELLAR_LITE).
// SEAM(WP-31): today's Home hosts the tab until the port of Monad Home lands.
#if STELLAR_LITE
import DyorKit
import DyorLite
import SwiftUI

/// Stellar's Home tab: DyorLite's Home, under Monad Home's header and with the network chip in its balance card, until
/// the port lands. A Stellar destination for Home's tab (a bridge's notification) opens over it.
struct StellarHomeView: View {
    @Environment(\.stellarSession) private var session
    @Environment(Router.self) private var router
    @Environment(\.stellarActions) private var actions
    @State private var bridging = false

    var body: some View {
        Group {
            if let session {
                LiteLegacyScreens.home(session: session, chrome: chrome)
            } else {
                ProgressView()
            }
        }
        .sheet(isPresented: $bridging) { StellarBridgeView() }
        .onChange(of: router.pendingStellar, initial: true) { _, pending in
            guard case .bridge = pending else { return }
            router.pendingStellar = nil
            bridging = true
        }
    }

    /// Monad Home's header (its search opens Stellar's), the network chip, and the paused card's Switch to Monad.
    private var chrome: LiteChrome {
        LiteChrome(header: { context in
                       AnyView(HomeHeader(showSearch: Binding(get: { false }, set: { if $0 { context.openSearch() } }),
                                          error: context.error, updatedAt: context.updatedAt))
                   },
                   networkChip: { AnyView(NetworkChip(network: .stellar)) },
                   switchToMonad: { actions.switchToMonad() })
    }
}
#endif
