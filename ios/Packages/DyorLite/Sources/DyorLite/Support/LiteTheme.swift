import StellarKit
import SwiftUI

/// Lite's look: same DyorHQ type and wordmark, a calmer palette (teal for Stellar instead of Pro's purple), large
/// numbers, rounded cards. Status colors always come with a word or sign, never color alone.
public enum LiteTheme {
    public static let accent = Color(red: 0.05, green: 0.62, blue: 0.56)
    static let card = Color(uiColorName: "secondarySystemGroupedBackground")
    static let canvas = Color(uiColorName: "systemGroupedBackground")
    static let positive = Color.green
    static let negative = Color.red
    static let corner: CGFloat = 20
}

extension Color {
    /// System colors by name, so the same file compiles where UIKit isn't imported directly.
    init(uiColorName name: String) {
        #if canImport(UIKit)
        switch name {
        case "secondarySystemGroupedBackground": self = Color(UIColor.secondarySystemGroupedBackground)
        case "systemGroupedBackground": self = Color(UIColor.systemGroupedBackground)
        default: self = .primary
        }
        #else
        self = name == "systemGroupedBackground" ? Color.gray.opacity(0.08) : Color.gray.opacity(0.16)
        #endif
    }
}

struct LiteCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LiteTheme.card, in: RoundedRectangle(cornerRadius: LiteTheme.corner, style: .continuous))
    }
}

struct LitePrimaryButton: View {
    let title: String
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if busy { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .tint(LiteTheme.accent)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(busy || !enabled)
    }
}

/// Coin badge: first letters on a tinted circle (Lite has no token logo service on testnet).
struct AssetBadge: View {
    let code: String
    var size: CGFloat = 36

    var body: some View {
        Text(String(code.prefix(code == "USDC" ? 1 : 2)))
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch code {
        case "XLM": return .black
        case "USDC": return Color(red: 0.16, green: 0.46, blue: 0.85)
        default:
            let h = Double(abs(code.hashValue % 360)) / 360
            return Color(hue: h, saturation: 0.55, brightness: 0.75)
        }
    }
}

struct TestnetBadge: View {
    var body: some View {
        Text("TESTNET")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityLabel("Test network: balances have no value")
    }
}

/// The Pro ⇄ Lite switch. Shown only when the host says Lite is available for this account.
public struct ModePill: View {
    public let isLite: Bool
    public let action: () -> Void

    public init(isLite: Bool, action: @escaping () -> Void) {
        self.isLite = isLite
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                segment("Pro · Monad", active: !isLite, tint: Color(red: 0.51, green: 0.43, blue: 0.98))
                segment("Lite · Stellar", active: isLite, tint: LiteTheme.accent)
            }
            .padding(3)
            .background(.thinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLite ? "Lite mode on Stellar. Double-tap to switch to Pro on Monad." : "Pro mode on Monad. Double-tap to switch to Lite on Stellar.")
        .sensoryFeedback(.selection, trigger: isLite)
    }

    private func segment(_ title: String, active: Bool, tint: Color) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(active ? .white : .secondary)
            .background(active ? tint : .clear, in: Capsule())
    }
}

/// Decimal amount entry bound to base units.
struct AmountInput: View {
    let label: String
    @Binding var text: String
    let code: String
    var maxUnits: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                TextField("0", text: $text)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                Text(code).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            if let maxUnits {
                Button("Max \(Amount.format(maxUnits, maxFraction: 4))") { text = Amount.format(maxUnits, maxFraction: 7).replacingOccurrences(of: ",", with: "") }
                    .font(.footnote)
                    .tint(LiteTheme.accent)
            }
        }
    }

    var units: Int64? { Amount.parse(text) }
}

func shortAddress(_ a: String) -> String { a.count > 12 ? "\(a.prefix(4))…\(a.suffix(4))" : a }

func usd(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value < 1 && value > 0 ? 4 : 2)))
}

func percent(_ fraction: Double) -> String {
    (fraction).formatted(.percent.precision(.fractionLength(fraction >= 10 ? 0 : 2)))
}
