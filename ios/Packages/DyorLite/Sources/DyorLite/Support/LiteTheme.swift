import StellarKit
import SwiftUI
#if canImport(UIKit)
import AudioToolbox
import UIKit
#endif

// The Stellar screens in DyorHQ's own system (design spec §7): monochrome grouped surfaces, the host's brand tint for
// selection and primary actions, status hues (from `LiteStyle`) only beside a word or a sign, the serif hero figure.

extension Color {
    /// The screen's ground (`systemGroupedBackground`).
    static var liteCanvas: Color { system("systemGroupedBackground") }
    /// A card's surface (`secondarySystemGroupedBackground`).
    static var liteCard: Color { system("secondarySystemGroupedBackground") }
    /// A control's fill: chips, option rows, fields, logo plates (`tertiarySystemFill`).
    static var liteControl: Color { system("tertiarySystemFill") }
    /// An unavailable primary button's fill (`systemGray5`).
    static var liteUnavailable: Color { system("systemGray5") }

    /// The hairline around every coin disc: it edges a white logo on a light card and a near-black one on a dark card,
    /// and is stronger under Increase Contrast (DyorHQ `Color.logoRing`).
    static var liteLogoRing: Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let strong = traits.accessibilityContrast == .high
            return traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: strong ? 0.28 : 0.12) : UIColor(white: 0, alpha: strong ? 0.22 : 0.08)
        })
        #else
        Color.primary.opacity(0.1)
        #endif
    }

    /// System colors by name, so the same file compiles where UIKit isn't there (the package also builds for macOS).
    private static func system(_ name: String) -> Color {
        #if canImport(UIKit)
        switch name {
        case "systemGroupedBackground": return Color(UIColor.systemGroupedBackground)
        case "secondarySystemGroupedBackground": return Color(UIColor.secondarySystemGroupedBackground)
        case "tertiarySystemFill": return Color(UIColor.tertiarySystemFill)
        case "systemGray5": return Color(UIColor.systemGray5)
        default: return .primary
        }
        #else
        switch name {
        case "systemGroupedBackground": return Color.gray.opacity(0.08)
        case "secondarySystemGroupedBackground": return Color.gray.opacity(0.16)
        default: return Color.gray.opacity(0.2)
        }
        #endif
    }
}

extension View {
    /// DyorHQ's grouped card: the card surface with continuous 18 pt corners (`cardBackground()`).
    func liteCardBackground() -> some View {
        background(Color.liteCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// A figure not read yet: the placeholder shape of one, said by VoiceOver to be loading, never "$0.00".
    @ViewBuilder func unreadFigure(_ unread: Bool) -> some View {
        if unread {
            redacted(reason: .placeholder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("Loading…"))
        } else {
            self
        }
    }

    /// A form sheet's ground: opaque grouped, as DyorHQ's form sheets (iOS 26 sheets are otherwise translucent).
    func liteFormSheet() -> some View {
        presentationBackground(Color.liteCanvas)
    }
}

struct LiteCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liteCardBackground()
    }
}

/// Full-width primary action, with DyorHQ `PrimaryButton`'s metrics: a large `.borderedProminent` button in the inherited
/// tint (a capsule on iOS 26), a semibold label, a spinner while busy, and a solid neutral fill while unavailable.
struct LitePrimaryButton: View {
    let title: String
    var systemImage: String?
    var busy = false
    var enabled = true
    /// The label's colour on the prominent fill: white, which reads on the brand purple in both appearances.
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        let unavailable = !enabled && !busy
        let button = Button {
            LiteHaptics.commit()
            action()
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small).tint(foreground) } else if let systemImage { Image(systemName: systemImage) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(unavailable ? Color.secondary : foreground)
        }
        if unavailable {
            button.buttonStyle(LiteUnavailableButtonStyle()).disabled(true)
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
        }
    }
}

/// `LitePrimaryButton` while it can't be used: the height and shape of a `.large` `.borderedProminent` button on a solid
/// gray that reads in light and dark (a disabled prominent button all but vanishes on a light ground).
private struct LiteUnavailableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 15)
            .background(Color.liteUnavailable, in: shape)
    }

    private var shape: AnyShape {
        if #available(iOS 26, macOS 26, *) { AnyShape(Capsule()) } else { AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
    }
}

/// A coin's disc in DyorHQ's logo look: a neutral plate, clipped round, with the faint ring (`LogoDisc`). The host app's
/// bundled logo of that symbol (`logo-XLM`, `logo-USDC`) when it has one, letters on a colour of their own otherwise.
struct AssetBadge: View {
    let code: String
    var size: CGFloat = 36

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color.liteControl)
            .clipShape(Circle())
            .accessibilityIgnoresInvertColors()
            .overlay(Circle().strokeBorder(Color.liteLogoRing, lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        #if canImport(UIKit)
        if let shipped = UIImage(named: "logo-\(code)") {
            Image(uiImage: shipped).resizable().scaledToFit()
        } else {
            monogram
        }
        #else
        monogram
        #endif
    }

    /// Letters on a colour derived from the symbol, the same on every launch (DyorHQ `LogoMonogram`).
    private var monogram: some View {
        let seed = code.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let tint = Color(hue: Double(seed % 360) / 360, saturation: 0.5, brightness: 0.62)
        let letters = String(code.prefix(2)).uppercased()
        return ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(verbatim: letters.isEmpty ? "?" : letters)
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.12)
                .foregroundStyle(.white)
        }
    }
}

/// "Testnet", after the name "Stellar" wherever the network is named: DyorHQ `UnverifiedBadge`'s metrics in the
/// attention colour.
struct TestnetBadge: View {
    @Environment(\.liteStyle) private var style

    var body: some View {
        Text(tr("Testnet"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(style.attention)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(style.attention.opacity(0.14), in: Capsule())
            .accessibilityLabel(tr("Test network"))
    }
}

/// An error under a form or in a card: footnote, attention colour, a triangle, wrapping between words in Korean
/// (DyorHQ `InlineError`). The message is already in the current language, or a server's own words.
struct LiteInlineError: View {
    let message: String
    @Environment(\.liteStyle) private var style

    var body: some View {
        Label {
            LiteParagraph(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .modifier(LiteParagraphLabel())
        .font(.footnote)
        .foregroundStyle(style.attention)
        .symbolRenderingMode(.hierarchical)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("Error: \(message)"))
    }
}

/// Decimal amount entry bound to base units, in DyorHQ `AmountField`'s type, with a capsule Max button.
struct AmountInput: View {
    let label: String
    @Binding var text: String
    let code: String
    var maxUnits: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                TextField(String("0"), text: $text)
                    .font(.title2.weight(.medium))
                    .monospacedDigit()
                    .textFieldStyle(.plain)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(verbatim: code).font(.headline).foregroundStyle(.secondary)
                if let maxUnits {
                    Button(tr("Max")) { text = Amount.format(maxUnits, maxFraction: 7).replacingOccurrences(of: ",", with: "") }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
        }
    }

    var units: Int64? { Amount.parse(text) }
}

/// A sheet's header where the sheet has no navigation bar (DyorHQ `SheetHeader`): a bold title on the left and a round
/// close button in a 44 pt target. Opaque, so content scrolling under it stays legible.
struct LiteSheetHeader: View {
    let title: String
    let onClose: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.title2.weight(.bold))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).background(Color.liteControl, in: Circle())
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Close"))
        }
        .padding(.top, 20).padding(.horizontal, 20).padding(.bottom, 8)
        .background(Color.liteCanvas)
    }
}

/// When a sheet sized to its content stops being: past 85% of the screen it opens `.large` and its content scrolls
/// (as the app's network sheet does).
@MainActor
enum LiteSheetHeight {
    static func fits(_ height: CGFloat) -> Bool { height <= screenHeight * 0.85 }

    private static var screenHeight: CGFloat {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.height ?? 800
        #else
        800
        #endif
    }
}

/// Tactile feedback, as DyorHQ's `Haptics` gives it.
enum LiteHaptics {
    /// A consequential action: a firmer knock and the system's subtle tick.
    static func commit() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        AudioServicesPlaySystemSound(1104)
        #endif
    }

    static func selection() {
        #if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }
}

/// Puts `text` on the pasteboard.
func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

func shortAddress(_ a: String) -> String { a.count > 12 ? "\(a.prefix(4))…\(a.suffix(4))" : a }

/// Dollars in DyorHQ's one style, the same in every language and region (`PriceFormat.usdValue`): "$" in front, "."
/// as the decimal point, "," between thousands, 2 decimals, "<$0.01" for dust, "−" for a negative.
func usd(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    let magnitude = abs(value)
    if magnitude == 0 { return "$0.00" }
    let sign = value < 0 ? "−" : ""
    if magnitude < 0.005 { return sign + "<$0.01" }
    let parts = String(format: "%.2f", magnitude).split(separator: ".")
    var whole = String(parts[0])
    var grouped = ""
    while whole.count > 3 {
        grouped = "," + whole.suffix(3) + grouped
        whole = String(whole.dropLast(3))
    }
    return sign + "$" + whole + grouped + "." + parts[1]
}

/// A rate as a percentage, in the current language's digits ("500%", "4.25%").
func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(fraction >= 10 ? 0 : 2)).locale(LiteL10n.locale))
}
