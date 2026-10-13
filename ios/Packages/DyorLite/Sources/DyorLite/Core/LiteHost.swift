import Foundation
import StellarKit
import SwiftUI

/// How the host app lends the Stellar screens the account's Stellar key. The key is derived from the account's existing
/// secret (docs/ARCHITECTURE.md §3.2) and handed over only for the duration of one signature, or of one setup run
/// (`LiteSession`).
public protocol LiteKeyProvider: Sendable {
    /// The account's Stellar address (G…), known without unlocking anything.
    var address: String { get }
    /// False for watch-only accounts.
    var canSign: Bool { get }
    /// "Passkey", "Email", "Recovery phrase", … for the Stellar account screen, in the app's language.
    var methodLabel: String { get }
    /// Email & imported-key accounts can export their Stellar secret (S…); phrase accounts restore from the phrase.
    var canExportSecret: Bool { get }
    /// Unlocks and returns the signer (Face ID, passkey, or App Lock). `reason` is shown in the system prompt.
    func signer(reason: String) async throws -> StellarSigner
}

/// Optional: the account's Monad wallet, for the bridge. The host signs and sends EVM steps and returns the last hash.
public protocol LiteMonadBridge: Sendable {
    var monadAddress: String { get }
    func send(_ steps: [EvmStep]) async throws -> String
}

public struct LiteEnvironment: Sendable {
    public let apiURL: URL
    public let pinned: PinnedContracts
    public let buildNumber: Int

    public init(apiURL: URL, pinned: PinnedContracts = .testnet, buildNumber: Int) {
        self.apiURL = apiURL
        self.pinned = pinned
        self.buildNumber = buildNumber
    }
}

/// The Stellar tab bar's tabs, in order. The host keeps the selection (the side menu routes to it).
public enum LiteTab: String, CaseIterable, Hashable, Sendable {
    case home, earn, launch, moments
}

/// DyorHQ's tokens, set by the host so the Stellar screens draw in the app's own colours (design spec §7). The default
/// mirrors DyorHQ's colour sets, for LiteHarness. The interactive tint is never set here: it is inherited from the app.
public struct LiteStyle: Sendable {
    /// Brand purple: selection, charts and curve progress. Prominent buttons take the inherited tint.
    public var accent: Color
    public var positive: Color
    public var negative: Color
    public var attention: Color
    /// Text and symbols on a filled status colour.
    public var onStatus: Color

    public init(accent: Color, positive: Color, negative: Color, attention: Color, onStatus: Color) {
        self.accent = accent
        self.positive = positive
        self.negative = negative
        self.attention = attention
        self.onStatus = onStatus
    }

    /// DyorHQ's Brand, Positive, Negative and Attention colour sets (light / dark), and `Color.onStatus`.
    public static let `default` = LiteStyle(
        accent: Color(lightHex: 0x836EF9, darkHex: 0x8B78FA),
        positive: Color(lightHex: 0x126A4B, darkHex: 0x77D8AC),
        negative: Color(lightHex: 0xAD3047, darkHex: 0xF496AA),
        attention: Color(lightHex: 0x775812, darkHex: 0xE4C67D),
        onStatus: Color(lightHex: 0xFFFFFF, darkHex: 0x0D0D12)
    )
}

/// What Stellar Home hands the host's header (the same `HomeHeader` as Monad Home): what its search opens, and what
/// the capsule's trailing status shows — the last read's error, else when the figures were last read.
public struct LiteHeaderContext {
    /// Opens the Stellar search (`LiteSearchSheet`) over Stellar Home.
    public let openSearch: () -> Void
    /// The last read's failure, in the current language; nil when the last read worked.
    public let error: String?
    /// When the balances were last read; nil before the first read.
    public let updatedAt: Date?
}

/// The pieces the host draws inside the Stellar screens: the header and the network chip (the same ones as on Monad
/// Home), and what the locked and paused cards' buttons do.
public struct LiteChrome {
    let header: (LiteHeaderContext) -> AnyView
    let networkChip: () -> AnyView
    let unlock: () -> Void
    let switchToMonad: () -> Void

    /// - Parameters:
    ///   - header: Stellar Home's header, drawn as `.safeAreaInset(edge: .top)`; called on every redraw of Home.
    ///   - networkChip: the chip in the first row of the balance card (and of the locked and paused cards).
    ///   - unlock: the locked card's "Unlock with Face ID": the host runs Setup inline (`LiteSession.run()`) and opens
    ///     the network sheet at Setup if it pauses or fails. The button shows busy while the session runs.
    ///   - switchToMonad: the paused / update-needed card's "Switch to Monad": the host swaps to Monad at once.
    public init(header: @escaping (LiteHeaderContext) -> AnyView,
                networkChip: @escaping () -> AnyView,
                unlock: @escaping () -> Void,
                switchToMonad: @escaping () -> Void) {
        self.header = header
        self.networkChip = networkChip
        self.unlock = unlock
        self.switchToMonad = switchToMonad
    }

    /// Nothing drawn, nothing done: for a Stellar screen shown outside `LiteRootView`.
    static let none = LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) }, unlock: {}, switchToMonad: {})
}

private struct LiteStyleKey: EnvironmentKey {
    static let defaultValue = LiteStyle.default
}

private struct LiteChromeKey: EnvironmentKey {
    static let defaultValue = LiteChrome.none
}

public extension EnvironmentValues {
    /// The tokens the Stellar screens draw with. `LiteRootView` sets the style it is given; a host that presents
    /// `LiteAccountView`, `LiteDepositSheet` or `LiteWithdrawSheet` on its own sets it here (`.environment(\.liteStyle, …)`).
    var liteStyle: LiteStyle {
        get { self[LiteStyleKey.self] }
        set { self[LiteStyleKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var liteChrome: LiteChrome {
        get { self[LiteChromeKey.self] }
        set { self[LiteChromeKey.self] = newValue }
    }
}

extension Color {
    /// A colour that follows the appearance: `lightHex` in light mode, `darkHex` in dark (0xRRGGBB).
    init(lightHex: UInt32, darkHex: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? darkHex : lightHex)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(rgb: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkHex : lightHex)
        })
        #else
        self.init(rgb: lightHex)
        #endif
    }

    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#elseif canImport(AppKit)
private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif
