// Stellar copy of ios/DyorHQ/Trade/TradeView.swift TradeView (42cd8c7 sha256:e6df1ff7ca0b)
// Stellar copy of ios/DyorHQ/Trade/TradeView.swift TradeModeSwitcher (42cd8c7 sha256:fd7e1d7ecceb)
// Stellar's Earn tab, in Monad's Trade slot (docs/DESIGN-stellar-parity.md §8.5). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import SwiftUI

/// The Earn tab: swaps and Blend lending on one tab, switched by a top toggle, as Monad's Trade tab has Swap and Perps.
/// Each side keeps its own navigation stack and model. `router.stellarTradeMode` drives it, so the side menu's Spot and
/// every Swap entry land on Swap, and its Earn row on Earn; it opens on Earn, and the side stays through tab switches.
struct StellarTradeView: View {
    @Environment(Router.self) private var router

    var body: some View {
        switch router.stellarTradeMode {
        case .swap: StellarSwapView()
        case .earn: StellarEarnView()
        }
    }
}

/// The full-width underline switch between Swap and Earn, pinned above each side as Monad's `TradeModeSwitcher` is: the
/// active side bold with a brand underline, the other secondary. Each side places it as a top safe-area inset inside its
/// own navigation stack, so it stays put while the list scrolls under it.
struct StellarTradeModeSwitcher: View {
    @Environment(Router.self) private var router

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StellarTradeMode.allCases) { mode in
                let isActive = router.stellarTradeMode == mode
                Button {
                    guard router.stellarTradeMode != mode else { return }
                    Haptics.selection()
                    router.stellarTradeMode = mode
                } label: {
                    Text(mode.label)
                        .font(.subheadline.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(isActive ? Color.brand : .clear)
                                .frame(height: 2.5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
#endif
