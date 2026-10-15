// The app's full-screen covers, hoisted out of MainTabView (docs/DESIGN-network-switch.md §8.1). Internal builds only.
#if STELLAR_LITE
import SwiftUI

/// What opens over the app as a full-screen cover: the side menu, and Portfolio (Stellar's while Stellar is on screen),
/// News, Get Help, Profile and the notification center, as build 23's `MainTabView` presents them. Out of it, so the
/// root can present them above the swap between the networks' trees: a switch made from Profile happens under Profile,
/// which then closes onto the new Home (§2.5). `MainTabView(hostsCovers: false)` leaves them to the root; `isHosting`
/// false applies nothing.
struct AppCovers: ViewModifier {
    let isHosting: Bool
    @Environment(Router.self) private var router

    init(isHosting: Bool = true) {
        self.isHosting = isHosting
    }

    func body(content: Content) -> some View {
        @Bindable var router = router
        if isHosting {
            content
                .fullScreenCover(isPresented: $router.menuOpen) { SideMenuView() }
                .fullScreenCover(item: $router.presented) { screen in
                    switch screen {
                    // Stellar's own on Stellar (§8.12.1): Monad's lists Monad's wallet.
                    case .portfolio: if router.network == .stellar { StellarPortfolioView() } else { PortfolioView() }
                    case .news: NewsView()
                    case .help: GetHelpView()
                    case .profile: ProfileView(presented: true)
                    case .notifications: NotificationCenterView()
                    }
                }
        } else {
            content
        }
    }
}
#endif
