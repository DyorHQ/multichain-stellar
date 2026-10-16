// Stellar copy of ios/DyorHQ/Design/Components.swift AmountField (42cd8c7 sha256:21de7422956c)
// Amount entry on the Stellar tickets (docs/DESIGN-stellar-parity.md §3.5, §4.5). Internal builds only (STELLAR_LITE).
#if STELLAR_LITE
import SwiftUI

/// Decimal entry for a Stellar amount, with its asset's code and Max. Keeps the raw string so typing feels native; the
/// parsed value is derived. Max and the percent buttons write the field with `StellarFormat.plain(units:)`.
///
/// The placeholder is localized when it is written in the code (a catalog key, or a resource that names its Stellar
/// table) and shown as it is when it is a `String` built at run time, as `Text` does: the generic `String` initializer is
/// disfavored, so a literal always picks the key.
struct StellarAmountField: View {
    private let placeholder: Placeholder
    @Binding var text: String
    /// The asset's code ("XLM", "USDC", a coin's symbol): never translated.
    let code: String?
    var onMax: (() -> Void)?

    private enum Placeholder {
        case localized(LocalizedStringKey)
        case resource(LocalizedStringResource)
        case verbatim(String)
    }

    init(title: LocalizedStringKey, text: Binding<String>, code: String?, onMax: (() -> Void)? = nil) {
        self.init(.localized(title), text: text, code: code, onMax: onMax)
    }

    /// A placeholder that names its Stellar table: `LocalizedStringResource("…", table: "Stellar…", comment: "…")`.
    init(placeholder: LocalizedStringResource, text: Binding<String>, code: String?, onMax: (() -> Void)? = nil) {
        self.init(.resource(placeholder), text: text, code: code, onMax: onMax)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, text: Binding<String>, code: String?, onMax: (() -> Void)? = nil) {
        self.init(.verbatim(String(title)), text: text, code: code, onMax: onMax)
    }

    private init(_ placeholder: Placeholder, text: Binding<String>, code: String?, onMax: (() -> Void)?) {
        self.placeholder = placeholder
        _text = text
        self.code = code
        self.onMax = onMax
    }

    @ViewBuilder private var field: some View {
        switch placeholder {
        case .localized(let titleKey): TextField(titleKey, text: $text)
        case .resource(let resource): TextField(text: $text, prompt: Text(resource)) { Text(resource) }
        case .verbatim(let string): TextField(string, text: $text)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            field
                .keyboardType(.decimalPad)
                .font(.title2.weight(.medium))
                .monospacedDigit()
                .textFieldStyle(.plain)
            if let code {
                Text(verbatim: code)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if let onMax {
                Button("Max", action: onMax)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
    }
}
#endif
