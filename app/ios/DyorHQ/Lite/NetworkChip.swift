// The network switch's shared pieces (docs/DESIGN-network-switch.md §3.1). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import DyorKit
import SwiftUI

/// A network's mark: its bundled image in the look of every logo's disc. Monad's is `logo-MON`, a purple disc; Stellar's is
/// `logo-XLM`, its official white mark on a black disc, which only the internal app ships (Internal/Resources, ruling 3)
/// and which the ring edges in dark mode. Drawn from the network itself, never looked up by a symbol: a coin's logo is
/// decided by its address (`TokenLogo`), and a symbol-keyed one is Perps' and Bridge's alone (`MarketLogo`). Decorative:
/// the network's name is always beside it, or in the label of what holds it.
struct NetworkMark: View {
    let network: AppNetwork
    /// 18 in the chip, 36 in the sheet's rows, 40 in the route.
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = UIImage(named: network.markImage) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                // Not bundled: the network's initial, as a coin with no logo shows letters.
                Text(verbatim: String(network.name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        // `LogoDisc`'s look (Components.swift): a neutral plate, clipped round, under the faint ring that suits the
        // appearance; Smart Invert leaves the mark as it is.
        .frame(width: size, height: size)
        .background(Color(.tertiarySystemFill))
        .clipShape(Circle())
        .accessibilityIgnoresInvertColors()
        .overlay(Circle().strokeBorder(Color.logoRing, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// "Testnet", after Stellar's name wherever the network is named: the chip, the sheet's row, Profile's Network row. The
/// look of `UnverifiedBadge`: the attention colour on a 14% capsule of it.
struct TestnetBadge: View {
    var body: some View {
        Text("Testnet", tableName: "Lite", comment: "[tight] A badge after the name Stellar: Stellar's test network, where balances have no value. One short word if possible")
            .font(.caption2.weight(.semibold))
            // One line at its own width, never wrapped or hyphenated ("Test-/net"): where it doesn't fit, the chip moves
            // it below the name instead.
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.attention)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.attention.opacity(0.14), in: Capsule())
            .accessibilityLabel(Text(verbatim: Self.spoken))
    }

    /// What VoiceOver says for the badge, and after a test network's name wherever the badge follows it.
    static var spoken: String {
        liteTr(LocalizedStringResource("Test network", table: "Lite", comment: "VoiceOver: the spoken form of the Testnet badge after the name Stellar"))
    }
}

/// The network control, "◉ Monad ⌄": the first row of Home's balance card on both networks' Homes, and inside Profile's
/// Network row. A filled capsule, so it reads as a control, matching the Total Volume period chip beside it. A tap opens
/// the network sheet from Home (`Router.networkSheet`); `interactive: false` draws the same look without a button, for the
/// Profile row, which is the button there.
struct NetworkChip: View {
    let network: AppNetwork
    let interactive: Bool
    @Environment(Router.self) private var router
    /// The mark grows with the name's text.
    @ScaledMetric(relativeTo: .subheadline) private var markSize: CGFloat = 18
    @AccessibilityFocusState private var focused: Bool

    init(network: AppNetwork, interactive: Bool = true) {
        self.network = network
        self.interactive = interactive
    }

    var body: some View {
        if interactive {
            Button {
                Haptics.tap()
                router.networkSheet = NetworkSheetRequest(origin: .home)
            } label: {
                chip
                    // A 44 pt target around the 32 pt capsule: the row holding it is 44 pt tall (`NetworkChipRow`).
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NetworkChipPressStyle())
            .networkControlAccessibility(network)
            .accessibilityFocused($focused)
            // Right after a swap, VoiceOver starts on the new Home's chip (§6): this chip appears with the request set.
            .task(id: router.focusesNetworkChip) {
                guard router.focusesNetworkChip else { return }
                router.focusesNetworkChip = false
                try? await Task.sleep(for: .milliseconds(350)) // the push settles
                guard !Task.isCancelled else { return }
                AccessibilityNotification.ScreenChanged().post()
                focused = true
            }
        } else {
            chip
        }
    }

    /// The capsule, with Stellar's Testnet badge inside it; at the accessibility sizes, where that doesn't fit, the badge
    /// goes on its own line just below.
    private var chip: some View {
        ViewThatFits(in: .horizontal) {
            capsule(badge: true)
            VStack(alignment: .leading, spacing: 4) {
                capsule(badge: false)
                if network.isTestnet { TestnetBadge() }
            }
        }
    }

    private func capsule(badge: Bool) -> some View {
        HStack(spacing: 6) {
            NetworkMark(network: network, size: markSize)
            Text(verbatim: network.name).font(.subheadline.weight(.medium))
            if badge, network.isTestnet { TestnetBadge() }
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.primary)
        // The disc sits optically inside the capsule: 6 before it, 10 after the chevron, 6 above and below (32 pt tall).
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

extension View {
    /// What VoiceOver says for the network control, the chip on Home and Profile's Network row alike: "Network: Stellar",
    /// "Test network" after it on a test network, a button that changes the network.
    func networkControlAccessibility(_ network: AppNetwork) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Network: \(network.name)", tableName: "Lite", comment: "VoiceOver: the network control on Home and in Profile. %@ is a network's name (Monad, Stellar), not translated"))
            .accessibilityValue(Text(verbatim: network.isTestnet ? TestnetBadge.spoken : ""))
            .accessibilityHint(Text("Changes the network.", tableName: "Lite", comment: "VoiceOver hint: what the network control on Home and in Profile does"))
            .accessibilityAddTraits(.isButton)
    }
}

/// The chip pressed: a little smaller and lighter (140 ms); lighter only with Reduce Motion.
private struct NetworkChipPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// The chip as the first row of a Home's balance card (§3.2): a 44 pt row that gives back 6 pt below it, so the capsule
/// sits 16 pt from the card's top edge (with the card's top padding of 10) and 14 pt above the balance.
struct NetworkChipRow: View {
    let network: AppNetwork

    var body: some View {
        // The whole row is the chip's to fit in, not the half an HStack beside a Spacer offers it, which wrapped
        // Stellar's badge.
        NetworkChip(network: network)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.bottom, -6)
    }
}

/// From one network to the other, "◉ → ✦", at the top of the sheet's Confirm and Setup steps. `done` puts a check on the
/// destination once the switch is ready.
struct NetworkRoute: View {
    let from: AppNetwork
    let to: AppNetwork
    let done: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(from: AppNetwork, to: AppNetwork, done: Bool = false) {
        self.from = from
        self.to = to
        self.done = done
    }

    var body: some View {
        HStack(spacing: 16) {
            NetworkMark(network: from, size: 40)
            Image(systemName: "arrow.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            NetworkMark(network: to, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.positive)
                            // A 2 pt ring of the sheet's ground, so the check reads on any mark.
                            .background(Circle().fill(Color(.systemBackground)).padding(-2))
                            .offset(x: 4, y: 4)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeOut(duration: 0.22) : .spring(duration: 0.22), value: done)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("From \(from.name) to \(to.name)", tableName: "Lite", comment: "VoiceOver: the two network marks at the top of the network sheet. Two network names (Monad, Stellar), not translated"))
        .accessibilityAddTraits(.isImage)
    }
}

/// The header of a picker-style sheet: a bold title on the left, an optional back button before it, and a round close
/// button on the right, each a 32 pt circle in a 44 pt target. The metrics of Perps' `sheetHeader` (PerpTradeView.swift),
/// which stays as it is: this is the network sheet's own copy, so the App Store build is untouched (ruling 1).
struct SheetHeader: View {
    private let title: Text?
    private let onBack: (() -> Void)?
    private let onClose: (() -> Void)?

    /// `title` nil: no title (Confirm and Setup). `onBack` nil: no back button. `onClose` nil: no close button.
    init(title: Text? = nil, onBack: (() -> Void)? = nil, onClose: (() -> Void)?) {
        self.title = title
        self.onBack = onBack
        self.onClose = onClose
    }

    var body: some View {
        HStack {
            if let onBack {
                circleButton("chevron.left", label: Text("Back"), action: onBack)
            }
            if let title {
                title.font(.title2.weight(.bold))
            }
            Spacer()
            if let onClose {
                circleButton("xmark", label: Text("Close", comment: "Closes this screen or sheet (a verb)"), action: onClose)
            }
        }
        .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 8)
    }

    private func circleButton(_ symbol: String, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 32, height: 32).background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
#endif
