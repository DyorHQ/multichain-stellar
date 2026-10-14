// The app's full-screen covers, hoisted out of MainTabView (docs/DESIGN-network-switch.md §8.1). Internal builds only.
#if STELLAR_LITE
import SwiftUI

/// What opens over the app as a full-screen cover: the side menu, and Portfolio, News, Get Help, Profile and the
/// notification center, as build 23's `MainTabView` presents them. Out of it, so the root can present them above the swap
/// between the networks' trees: a switch made from Profile happens under Profile, which then closes onto the new Home
/// (§2.5). `MainTabView(hostsCovers: false)` leaves them to the root; `isHosting` false applies nothing.
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
                    case .portfolio: PortfolioView()
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
