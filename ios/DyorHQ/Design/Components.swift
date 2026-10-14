import BigInt
import DyorKit
import SwiftUI

// Small, reusable pieces that keep every screen on the same system: SF Symbols, text styles, semantic colors.

/// A token's logo, decided by its address (`CoinIcon`, through `DyorCoinsModel`, so a row draws again when its coin
/// becomes known): a curated token's bundled logo, never another token's however it is named; a DyorHQ launch's or
/// Moment's own art, filled; a list logo, fitted whole; and letters for everything else — a look-alike or a token with
/// a warning among them — or while nothing can be loaded. Always circular, on the plate and with the faint ring that
/// suits the appearance (`LogoDisc`), whatever the picture: a list logo drawn on a white square shows as one inside the
/// ring, as a bundled logo would (no third-party art is changed beyond fitting and clipping it).
struct TokenLogo: View {
    let token: Token
    var size: CGFloat = 36
    @Environment(AppEnvironment.self) private var env: AppEnvironment?

    var body: some View {
        LogoDisc(size: size) {
            switch env?.dyorCoins.icon(token) ?? CoinIcon.resolve(token, coin: nil, policy: .app) {
            case .bundled(let symbol):
                // Curated tokens ship a rasterized logo (the token list only publishes SVGs, which the app cannot draw): a
                // transparent disc that fills the square (TokenLogoAssetTests). Found by the curated entry's symbol, which
                // only a curated address resolves to.
                if let shipped = UIImage(named: "logo-\(symbol)") { Image(uiImage: shipped).resizable().scaledToFit() } else { monogram }
            case .remote(let sources, let fill):
                // Capped and downsampled (RemoteImage): a neutral disc for a moment while it loads, then the monogram until
                // it comes; the monogram at once when it failed lately (RemoteImageWait).
                RemoteImage(sources: sources, pointSize: size, contentMode: fill ? .fill : .fit, grace: RemoteImageWait.grace) { loading in
                    if loading { Color.clear } else { monogram }
                }
            case .letters:
                monogram
            }
        }
    }

    private var monogram: some View { LogoMonogram(symbol: token.symbol, size: size) }
}

/// A market's or a bridge asset's logo, by its symbol: the bundled logo of that name (BTC, ETH, SOL on Perps; a bridge
/// asset on another chain), else the remote `url` fitted, else letters. Perps and Bridge only: a Monad token's logo is
/// `TokenLogo`'s, by address, so a token that merely carries a curated symbol never wears its logo.
struct MarketLogo: View {
    let symbol: String
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        LogoDisc(size: size) {
            if let shipped = UIImage(named: "logo-\(symbol)") {
                Image(uiImage: shipped).resizable().scaledToFit()
            } else {
                RemoteImage(url: url, pointSize: size, contentMode: .fit, grace: RemoteImageWait.grace) { loading in
                    if loading { Color.clear } else { LogoMonogram(symbol: symbol, size: size) }
                }
            }
        }
    }
}

/// The circle every logo sits in: a neutral plate under the picture, clipped round, with a faint ring that suits the
/// appearance (`Color.logoRing`). Smart Invert leaves the logo as it is but inverts the ring with the card, so the ring
/// still edges the logo on the inverted card.
private struct LogoDisc<Content: View>: View {
    let size: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color(.tertiarySystemFill))
            .clipShape(Circle())
            .accessibilityIgnoresInvertColors()
            .overlay(Circle().strokeBorder(Color.logoRing, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A token with no image gets a filled monogram in a colour derived from its symbol, so it reads as a real avatar (and
/// each token keeps a consistent, distinct colour across launches) rather than a grey placeholder.
private struct LogoMonogram: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        let seed = symbol.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        let hue = Double(seed % 360) / 360
        let tint = Color(hue: hue, saturation: 0.5, brightness: 0.62)
        let letters = ChainText.leading(symbol, 2)
        ZStack {
            LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // One line, shrunk rather than wrapped: two emoji at 0.4 of the disc would otherwise break onto two lines.
            // Inset from the sides so wide letters (two emoji, a ZWJ family, ﷽) fit the circle, not the square. The
            // letters skip the isolate around right-to-left text (`ChainText.leading`); "?" for a token with no symbol
            // that draws, as the launch views show.
            Text(letters.isEmpty ? "?" : letters.uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, size * 0.12)
                .foregroundStyle(.white)
        }
    }
}

/// What a token's row says about where it came from (`TokenBadge`): "DyorHQ Launch" or "DyorHQ Moment" in the brand
/// colour, or a warning in the attention colour — "Unverified", or a look-alike's "Not the real ETH" — and nothing for
/// MON, the curated tokens and a token the user chose. It replaces `UnverifiedBadge` for tokens: a DyorHQ coin sent to the
/// wallet shows its DyorHQ label, never "Unverified", unless its own name or symbol makes it a warning. Decided from the
/// token's address and what the registry knows of it (`DyorCoinsModel.badge`), or given as it was when a list was read.
struct TokenBadgeView: View {
    private let token: Token?
    private let receivedUnasked: Bool
    private let fixed: TokenBadge?
    @Environment(AppEnvironment.self) private var env: AppEnvironment?

    /// `token`'s badge, `receivedUnasked` being whether it reached the wallet without being chosen in the app.
    init(token: Token, receivedUnasked: Bool) {
        self.token = token
        self.receivedUnasked = receivedUnasked
        fixed = nil
    }

    /// A badge already decided.
    init(_ badge: TokenBadge) {
        token = nil
        receivedUnasked = false
        fixed = badge
    }

    private var badge: TokenBadge {
        if let fixed { return fixed }
        guard let token else { return .none }
        return env?.dyorCoins.badge(token, receivedUnasked: receivedUnasked) ?? TokenBadge.of(token, coin: nil, receivedUnasked: receivedUnasked)
    }

    var body: some View {
        let badge = self.badge
        if let title = badge.title {
            let tint = badge.isWarning ? Color.attention : Color.brand
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8) // shrinks a little before it truncates: the label's point is its whole name
                .foregroundStyle(tint)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule())
                .layoutPriority(-1)
        }
    }
}

/// Marks an NFT that reached the wallet without the user choosing it in DyorHQ: anyone can send any NFT to any wallet,
/// so its name and art prove nothing (security audit 2026-09-26, IOST-12). A token shows `TokenBadgeView`.
struct UnverifiedBadge: View {
    var body: some View {
        Text("Unverified")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.attention)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.attention.opacity(0.14), in: Capsule())
    }
}

/// A circular profile avatar: the uploaded image when there is one, otherwise the wallet's initials on a neutral
/// fill. Used in the Profile header and the DyorHQ Social screens.
struct Avatar: View {
    let url: URL?
    var initials: String = ""
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url {
                RemoteImage(url: url, pointSize: size) { loading in
                    if loading { ZStack { Color(.tertiarySystemFill); ImageLoadingSpinner() } } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityIgnoresInvertColors() // the photo; its ring inverts with the card, like TokenLogo's
        .overlay(Circle().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.46)).foregroundStyle(.secondary)
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
    }
}

extension UIImage {
    /// Downscales to fit `maxDimension` and returns JPEG bytes — a small, square-ish avatar rather than a
    /// multi-megabyte camera image.
    func avatarJPEG(maxDimension: CGFloat = 512, quality: CGFloat = 0.85) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    /// A launch's picture as the create form uploads it (`LaunchImage`): the largest centred square, drawn
    /// `LaunchImage.side` pixels a side, as JPEG bytes. Nil for an image with no size.
    func launchJPEG(quality: CGFloat = 0.85) -> Data? {
        let crop = LaunchImage.centreSquare(size)
        guard crop.width > 0 else { return nil }
        let side = CGFloat(LaunchImage.side)
        let scale = side / crop.width
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale, width: size.width * scale, height: size.height * scale))
        }
        return square.jpegData(compressionQuality: quality)
    }
}

/// Signed percentage in the semantic color, with a text sign so color is never the only cue.
struct ChangeText: View {
    let value: Double?
    var style: Font = .subheadline

    var body: some View {
        if let raw = value {
            let value = abs(raw) < 0.005 ? 0 : raw
            Text(NumberStyle.percent(value))
                .font(style.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary)
        } else {
            Text(verbatim: "—").font(style).foregroundStyle(.tertiary)
        }
    }
}

/// A capsule with the change, for rows that show a price and its movement side by side.
struct ChangeBadge: View {
    let value: Double?

    var body: some View {
        if let raw = value {
            let value = abs(raw) < 0.005 ? 0 : raw
            Text(NumberStyle.percent(value))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary).opacity(0.14), in: Capsule())
                .foregroundStyle(value < 0 ? Color.negative : value > 0 ? Color.positive : Color.secondary)
        }
    }
}

/// Dollars in the app's one style (`PriceFormat`), "—" when there are none. `USDText(price:)` is a unit price (4
/// significant digits under $1, the zeros of a dust price counted in subscript, read out in full by VoiceOver);
/// `USDText(value:)` is an amount of money (2 decimals, "<$0.01" for dust).
struct USDText: View {
    private let dollars: Double?
    private let isPrice: Bool
    private let font: Font

    init(price: Double?, font: Font = .body) { dollars = price; isPrice = true; self.font = font }
    init(value: Double?, font: Font = .body) { dollars = value; isPrice = false; self.font = font }

    var body: some View {
        if let dollars, dollars.isFinite {
            // One line, shrunk a little rather than wrapped: "$83,952.46" beside a change badge broke onto two lines.
            Text(isPrice ? PriceFormat.usdPrice(dollars) : PriceFormat.usdValue(dollars))
                .font(font)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(isPrice ? PriceFormat.spoken(dollars) : PriceFormat.usdValue(dollars))
        } else {
            Text(verbatim: "—").font(font).foregroundStyle(.tertiary)
        }
    }
}

/// Token amount with its symbol, e.g. "12.5 MON".
struct AmountText: View {
    let amount: BigUInt
    let token: Token
    var compact = false
    var font: Font = .body

    var body: some View {
        // An amount with its symbol, nothing to translate: shown as it is, never the key "%@ %@".
        Text(verbatim: "\(NumberStyle.units(amount, decimals: token.decimals, compact: compact)) \(token.symbol)")
            .font(font)
            .monospacedDigit()
    }
}

/// Decimal entry for token amounts. Keeps the raw string so typing feels native; the parsed value is derived.
///
/// The placeholder is localized when it is written in the code (a catalog key) and shown as it is when it is a `String`
/// built at run time, as `Text` does: the generic `String` initializer is disfavored, so a literal always picks the key.
struct AmountField: View {
    private let title: Placeholder
    @Binding var text: String
    let token: Token?
    var onMax: (() -> Void)?

    private enum Placeholder {
        case localized(LocalizedStringKey)
        case verbatim(String)
    }

    init(title: LocalizedStringKey, text: Binding<String>, token: Token?, onMax: (() -> Void)? = nil) {
        self.init(.localized(title), text: text, token: token, onMax: onMax)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, text: Binding<String>, token: Token?, onMax: (() -> Void)? = nil) {
        self.init(.verbatim(String(title)), text: text, token: token, onMax: onMax)
    }

    private init(_ title: Placeholder, text: Binding<String>, token: Token?, onMax: (() -> Void)?) {
        self.title = title
        _text = text
        self.token = token
        self.onMax = onMax
    }

    @ViewBuilder private var field: some View {
        switch title {
        case .localized(let titleKey): TextField(titleKey, text: $text)
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
            if let token {
                Text(token.symbol)
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

/// Copyable address row. Its title is a catalog key when written in the code, or a `String` shown as it is.
struct AddressRow: View {
    private let title: Text
    let address: Address

    init(title: LocalizedStringKey, address: Address) {
        self.title = Text(title)
        self.address = address
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, address: Address) {
        self.title = Text(verbatim: String(title))
        self.address = address
    }

    var body: some View {
        LabeledContent {
            Text(address.short)
                .speechSpellsOutCharacters()
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        } label: {
            title
        }
        .contextMenu {
            Button("Copy Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = address.checksummed }
            Link(destination: Monad.explorerAddress(address)) { Label("View on Monadscan", systemImage: "safari") }
        }
    }
}

/// Said over figures a screen saved when they were last read for the wallet (`SavedScreens`), while it shows them and
/// reads them again: when they were read ("Updated 3 min ago"), with a spinner while the read runs (`reading`). A saved
/// figure is never taken for a fresh one; once every figure shown was read again, the screen drops the line.
struct SavedLine: View {
    let date: Date
    let reading: Bool

    var body: some View {
        HStack(spacing: 6) {
            if reading { ProgressView().controlSize(.mini) }
            Text("Updated \(date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Inline error under a form, in sentence case with a symbol. A message written in the code is a catalog key; most come
/// at run time (a thrown error's description, a server's message, a model's text) and are shown as they are. It wraps
/// between words in Korean (`Paragraph`).
struct InlineError: View {
    private enum Message {
        case localized(LocalizedStringResource)
        case verbatim(String)
    }

    private let message: Message

    init(message: LocalizedStringResource) {
        self.message = .localized(message)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(message: S) {
        self.message = .verbatim(String(message))
    }

    /// The message in the app's language, for VoiceOver.
    private var spoken: String {
        switch message {
        case .localized(let resource): return tr(resource)
        case .verbatim(let text): return text
        }
    }

    var body: some View {
        Label {
            switch message {
            case .localized(let resource): Paragraph(resource)
            case .verbatim(let text): Paragraph(verbatim: text)
            }
        } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .modifier(ParagraphLabel())
            .font(.footnote)
            .foregroundStyle(Color.attention)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(Text("Error: \(spoken)"))
    }
}

/// "Learn more": one page of the DyorHQ docs (`DocsLinks`), opened in Safari like the Terms and Privacy links. It goes
/// only under an explanation the screen already gives (a section footer or a line of help text), once per explanation,
/// in the surrounding text style.
struct LearnMoreLink: View {
    let page: DocsLinks

    init(_ page: DocsLinks) { self.page = page }

    var body: some View {
        Link("Learn more", destination: page.url)
            .foregroundStyle(.tint)
            .accessibilityLabel("Learn more about \(page.topic)")
            .accessibilityHint("Opens the DyorHQ docs in Safari.")
    }
}

/// Full-width primary action at the bottom of a screen. Its title is a catalog key when written in the code, a `String`
/// built at run time shown as it is, or a `Text` the caller already made.
struct PrimaryButton: View {
    private let title: Text
    var systemImage: String?
    /// A custom symbol from the asset catalog, used when no `systemImage` fits (e.g. the balance scale).
    var image: String?
    var isBusy = false
    var isDisabled = false
    /// Label/spinner color on the prominent fill. Defaults to white, which reads on the brand purple in both themes.
    /// When the caller tints the button with a status color (`.positive`/`.negative`), pass `.onStatus` instead — the
    /// dark-mode status hues are light mint/rose where white fails WCAG contrast.
    var foreground: Color = .white
    let action: () -> Void

    init(title: LocalizedStringKey, systemImage: String? = nil, image: String? = nil, isBusy: Bool = false, isDisabled: Bool = false,
         foreground: Color = .white, action: @escaping () -> Void) {
        self.init(title: Text(title), systemImage: systemImage, image: image, isBusy: isBusy, isDisabled: isDisabled, foreground: foreground, action: action)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(title: S, systemImage: String? = nil, image: String? = nil, isBusy: Bool = false, isDisabled: Bool = false,
                            foreground: Color = .white, action: @escaping () -> Void) {
        self.init(title: Text(verbatim: String(title)), systemImage: systemImage, image: image, isBusy: isBusy, isDisabled: isDisabled,
                  foreground: foreground, action: action)
    }

    init(title: Text, systemImage: String? = nil, image: String? = nil, isBusy: Bool = false, isDisabled: Bool = false,
         foreground: Color = .white, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.image = image
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.foreground = foreground
        self.action = action
    }

    var body: some View {
        let unavailable = isDisabled && !isBusy
        let button = Button {
            Haptics.commit()
            action()
        } label: {
            HStack(spacing: 8) {
                if isBusy { ProgressView().controlSize(.small).tint(foreground) }
                else if let systemImage { Image(systemName: systemImage) }
                else if let image { Image(image) }
                title.fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(unavailable ? Color(.secondaryLabel) : foreground)
        }
        if unavailable {
            // iOS draws a disabled prominent button as a near-clear fill with faded text, which all but vanishes on a
            // light background. This keeps the button's size and shape with a solid neutral fill and readable text,
            // and it stays disabled for touch and VoiceOver.
            button.buttonStyle(UnavailablePrimaryButtonStyle()).disabled(true)
        } else {
            button
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy)
        }
    }
}

/// `PrimaryButton` while it can't be used: the height and shape of a `.large` `.borderedProminent` button (a capsule
/// from iOS 26, a rounded rectangle before), on a solid gray that reads in light and dark.
private struct UnavailablePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 15) // measured against the enabled button: both 62 pt at the default text size
            .background(Color(.systemGray5), in: shape)
    }

    private var shape: AnyShape {
        if #available(iOS 26, *) { AnyShape(Capsule()) } else { AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) }
    }
}

/// A block of label/value pairs, like a receipt.
struct DetailRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 10) { content }
            .font(.subheadline)
    }
}

/// One label/value line of `DetailRows`. The label is a catalog key. The value is a key when it is words written in the
/// code ("Locked forever", "Market · \(slippage) slippage"); a `String` built at run time (an amount, a symbol, an
/// address) is shown as it is, and so is an interpolated literal passed as `verbatim:` (an amount with its symbol, which
/// has nothing to translate). A literal always picks the key: the `String` initializer is disfavored, as `Text`'s is.
struct DetailRow: View {
    private let label: Text
    private let value: Text
    var tint: Color = .primary
    /// VoiceOver reads the value character by character: an address, a hash (AI-13).
    var spellsOut = false

    init(_ label: LocalizedStringKey, _ value: LocalizedStringKey, tint: Color = .primary, spellsOut: Bool = false) {
        self.init(Text(label), Text(value), tint: tint, spellsOut: spellsOut)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ label: LocalizedStringKey, _ value: S, tint: Color = .primary, spellsOut: Bool = false) {
        self.init(Text(label), Text(verbatim: String(value)), tint: tint, spellsOut: spellsOut)
    }

    init(_ label: LocalizedStringKey, verbatim value: String, tint: Color = .primary, spellsOut: Bool = false) {
        self.init(Text(label), Text(verbatim: value), tint: tint, spellsOut: spellsOut)
    }

    /// Either side already made: a label built at run time is `Text(verbatim:)`.
    init(_ label: Text, _ value: Text, tint: Color = .primary, spellsOut: Bool = false) {
        self.label = label
        self.value = value
        self.tint = tint
        self.spellsOut = spellsOut
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            label.foregroundStyle(.secondary)
            Spacer(minLength: 16)
            value.speechSpellsOutCharacters(spellsOut).monospacedDigit().foregroundStyle(tint).multilineTextAlignment(.trailing)
        }
    }
}

/// Progress of a transaction plan, shown in confirmation sheets.
struct TransactionProgress: View {
    let events: [TransactionEvent]
    /// When set, the confirmed row's "View" opens this callback with the tx hash instead of the block explorer.
    var onView: ((Data) -> Void)? = nil
    /// The sheet reads what the transaction did and says it with its own tone (a Perpl order's fill or "not filled"): the
    /// confirmed row then only says the transaction confirmed on Monad, in the neutral colour — never a green "Long
    /// BTC-PERP confirmed" over an order that filled nothing.
    var neutralConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                switch event {
                case .preparing(let label):
                    Label(label, systemImage: "circle.dotted").foregroundStyle(.secondary)
                case .sent(let label, let hash):
                    HStack {
                        Label("\(label) sent", systemImage: "paperplane").foregroundStyle(.secondary)
                        Spacer()
                        // Until it confirms, the explorer is the only way to see whether a sent step landed — which the
                        // user must check before trying again after an error.
                        if !events.contains(.confirmed(label, hash)) {
                            Link("View", destination: Monad.explorerTransaction(hash)).font(.footnote)
                        }
                    }
                case .confirmed(let label, let hash):
                    HStack {
                        if neutralConfirmation {
                            Label {
                                Text("Transaction confirmed on Monad", comment: "A Perps sheet's progress row: the transaction confirmed on the Monad network. What it did (filled, not filled) is said under it, so this says only that it ran.")
                            } icon: {
                                Image(systemName: "checkmark.circle")
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Label("\(label) confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(Color.positive)
                        }
                        Spacer()
                        if let onView {
                            Button("View") { onView(hash) }.font(.footnote)
                        } else {
                            Link("View", destination: Monad.explorerTransaction(hash)).font(.footnote)
                        }
                    }
                }
            }
        }
        .font(.subheadline)
        .symbolRenderingMode(.hierarchical)
    }
}

extension View {
    /// Standard treatment for a screen that is still loading its first data.
    @ViewBuilder
    func loadingOverlay(_ isLoading: Bool) -> some View {
        overlay {
            if isLoading {
                ProgressView().controlSize(.large)
            }
        }
    }
}

/// Resigns the first responder, dismissing the keyboard. The decimal pad has no return key, so screens that use it
/// pair this with a "Done" key-accessory button and interactive scroll-to-dismiss — otherwise the keyboard hides
/// the tab bar with no way back.
@MainActor func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    /// A "Done" button above the keyboard that dismisses it — the standard escape hatch for decimal-pad fields.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { Haptics.selection(); dismissKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

/// Text that reads a raw error the way a person would. An error with a description of its own says it (the app's and
/// DyorKit's errors write theirs in the app's language). Without one, a cancelled request and a lost connection are told
/// by the error's type and code (`FailureKind`), never by its text, which iOS writes in the device's language, and are
/// named in the app's language; any other error says what iOS says.
func describe(_ error: Error) -> String {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
    switch FailureKind.of(error) {
    case .cancelled:
        return tr(LocalizedStringResource("Cancelled.", comment: "An error message: what was under way was cancelled, by the person or by iOS (a request, a Face ID, passcode or passkey prompt). Not an order's status"))
    case .offline:
        return tr(LocalizedStringResource("No connection. Check your network and try again.", comment: "An error message: the device is offline, or its connection dropped during the request"))
    case .other: return error.localizedDescription
    }
}
