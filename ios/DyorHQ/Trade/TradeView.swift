import DyorKit
import SwiftUI

/// The Trade tab: one destination for spot swaps and perps, switched by a top toggle — modeled on the pro-trading
/// apps where Spot/Perps share a screen. Each mode keeps its own navigation stack and view model; switching modes
/// shows the other one fresh (a mode switch resets any half-entered order, like flipping Spot/Perps elsewhere).
/// `router.tradeMode` drives it, so cross-tab jumps (Buy a token, open a market) land on the right mode.
struct TradeView: View {
    @Environment(Router.self) private var router

    var body: some View {
        switch router.tradeMode {
        case .swap: SwapView()
        case .perps: PerpsView()
        }
    }
}

/// The full-width underline switch between Swap and Perps, pinned above the trading UI. The active mode is bold
/// with a brand-colored underline; inactive modes are secondary. Placed as a top safe-area inset inside each mode's
/// own navigation stack so it stays put while the list scrolls under it.
struct TradeModeSwitcher: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        HStack(spacing: 0) {
            ForEach(TradeMode.allCases) { mode in
                let isActive = router.tradeMode == mode
                Button {
                    guard router.tradeMode != mode else { return }
                    Haptics.selection()
                    router.tradeMode = mode
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
