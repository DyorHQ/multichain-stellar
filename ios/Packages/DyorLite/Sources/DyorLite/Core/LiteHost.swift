import Foundation
import StellarKit
import SwiftUI

/// How the host app lends the Stellar screens the account's Stellar key (docs/DESIGN-stellar-parity.md §7.2, decision
/// 6). The key is derived from the account's existing secret (docs/ARCHITECTURE.md §3.2). Nothing here hands out a
/// signer outside a signing run: the provider signs the sign-in challenge itself, and a transaction's signer comes from
/// the run of the one action the user confirmed, for one signature.
public protocol LiteKeyProvider: Sendable {
    /// The account's Stellar address (G…), known without unlocking anything.
    var address: String { get }
    /// Whether the key can sign on this iPhone: false for watch-only accounts and a key that isn't here, never because
    /// of a session.
    var canSign: Bool { get }
    /// "Passkey", "Email", "Recovery phrase", … for the Stellar account screen, in the app's language.
    var methodLabel: String { get }
    /// Email & imported-key accounts can export their Stellar secret (S…); phrase accounts restore from the phrase.
    var canExportSecret: Bool { get }
    /// True when the account's Stellar seed is in this iPhone's Keychain (an imported phrase or key, email & password):
    /// it signs the sign-in challenge without a prompt. False for passkey and watch-only accounts.
    var signsInSilently: Bool { get }
    /// The SEP-53 signature, in base64, of the sign-in challenge `message` (`StellarSigner.signMessage`). Never prompts:
    /// the seed is read for this one signature and dropped. `LiteAPI.signIn` asks only for the exact challenge and checks
    /// the signature before it is sent (§5.8). Throws `LiteSession.Failure.needsPasskey` when `signsInSilently` is false.
    func signInSignature(for message: String) async throws -> String
    /// Starts the signing of one confirmed action. A seed account asks for Face ID or the passcode here, once, and only
    /// when the app's App Lock setting applies (read now, as Monad's Confirm reads it); with App Lock on and no device
    /// passcode it throws. A passkey account asks nothing here: its run asks for the passkey once per signature. A
    /// cancelled prompt throws, and nothing is signed.
    func beginSigning(reason: String) async throws -> LiteSigningRun
    /// The account's Stellar secret (S…), for "Show Stellar secret key": always the device owner's check (Face ID or the
    /// passcode), whatever App Lock says, as Monad's key export asks. Only where `canExportSecret`.
    func revealSecret(reason: String) async throws -> String
}

/// One confirmed action's signing (`LiteKeyProvider.beginSigning`). It holds no secret: each signer it gives is made for
/// one signature, and its caller drops it.
public protocol LiteSigningRun: Sendable {
    /// A signer for one step. A seed account reads the Keychain, with no prompt; a passkey account asks for the passkey
    /// once per call (`reason` names the step); a Privy account's asks Privy, through the user's own Privy key, for each
    /// signature. Throws after `end()`.
    func signer(reason: String) async throws -> any StellarHashSigner
    /// The action settled, failed or was cancelled: no signer after this.
    func end()
}

/// Transitional, until the host's providers have signing runs of their own (WP-20): a provider written before them has
/// none of these, and the session signs through the host's setup ceremony for it, one per signature, as before.
public extension LiteKeyProvider {
    var signsInSilently: Bool { false }

    func signInSignature(for message: String) async throws -> String { throw LiteSession.Failure.needsPasskey }

    func beginSigning(reason: String) async throws -> LiteSigningRun { throw LiteKeyProviderDefault.noSigningRun }

    func revealSecret(reason: String) async throws -> String { throw LiteKeyProviderDefault.noSigningRun }
}

/// What the defaults above throw: the provider has no signing run of its own (`LiteSession` then uses the host's setup
/// ceremony).
enum LiteKeyProviderDefault: Error, Equatable {
    case noSigningRun
}

/// Optional: the account's Monad wallet, for the bridge. The host signs and sends EVM steps and returns the last hash.
public protocol LiteMonadBridge: Sendable {
    var monadAddress: String { get }
    func send(_ steps: [EvmStep]) async throws -> String
    /// What the steps may cost on Monad, for the bridge review's "Up to … MON"; nil when the host can't price them, and
    /// the review then shows no Monad fee.
    func preview(_ steps: [EvmStep]) async throws -> LiteMonadFeePreview?
}

public extension LiteMonadBridge {
    func preview(_ steps: [EvmStep]) async throws -> LiteMonadFeePreview? { nil }
}

/// The Monad network fee of the bridge's Monad steps, as the host's sender prices them (DyorKit's `FeePreview`).
public struct LiteMonadFeePreview: Equatable, Sendable {
    /// The most the steps it could price may cost together, in wei (MON has 18 decimals), as a decimal string.
    public let maxFeeWei: String
    /// Steps it can price only once an earlier one lands (a burn after its approval).
    public let unestimated: Int

    public init(maxFeeWei: String, unestimated: Int) {
        self.maxFeeWei = maxFeeWei
        self.unestimated = unestimated
    }
}

public struct LiteEnvironment: Sendable {
    public let apiURL: URL
    public let pinned: PinnedContracts
    public let buildNumber: Int
    /// Where DyorHQ's Stellar media lives (`LITE_MEDIA_BASE`, pinned per build configuration): the only origin
    /// `LiteMediaPolicy` lets an image or a video come from. Never taken from the server.
    public let mediaBase: URL
    /// The storage's image renderer for that bucket (Release), or nil to load the originals only (Debug's stand-in).
    public let renderBase: URL?

    /// `mediaBase` defaults to the Release bucket and `renderBase` to none, until the host pins both per configuration.
    public init(apiURL: URL, pinned: PinnedContracts = .testnet, buildNumber: Int, mediaBase: URL = LiteEnvironment.releaseMediaBase,
                renderBase: URL? = nil) {
        self.apiURL = apiURL
        self.pinned = pinned
        self.buildNumber = buildNumber
        self.mediaBase = mediaBase
        self.renderBase = renderBase
    }

    /// The `lite-media` bucket of the DyorHQ project, where Release reads Stellar media (§3.8).
    public static let releaseMediaBase = URL(string: "https://fmnjqrguvopusfufmirs.supabase.co/storage/v1/object/public/lite-media/")!
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
/// Home), and what the paused card's button does.
public struct LiteChrome {
    let header: (LiteHeaderContext) -> AnyView
    let networkChip: () -> AnyView
    let switchToMonad: () -> Void

    /// - Parameters:
    ///   - header: Stellar Home's header, drawn as `.safeAreaInset(edge: .top)`; called on every redraw of Home.
    ///   - networkChip: the chip in the first row of the balance card (and of the paused card).
    ///   - switchToMonad: the paused / update-needed card's "Switch to Monad": the host swaps to Monad at once.
    public init(header: @escaping (LiteHeaderContext) -> AnyView,
                networkChip: @escaping () -> AnyView,
                switchToMonad: @escaping () -> Void) {
        self.header = header
        self.networkChip = networkChip
        self.switchToMonad = switchToMonad
    }

    /// The chrome as hosts passed it before decision 6: `unlock` is never called, since nothing on Stellar locks.
    @available(*, deprecated, message: "Nothing on Stellar locks any more (decision 6): drop unlock.")
    public init(header: @escaping (LiteHeaderContext) -> AnyView,
                networkChip: @escaping () -> AnyView,
                unlock: @escaping () -> Void,
                switchToMonad: @escaping () -> Void) {
        self.init(header: header, networkChip: networkChip, switchToMonad: switchToMonad)
    }

    /// Nothing drawn, nothing done: for a Stellar screen shown outside `LiteRootView`.
    public static let none = LiteChrome(header: { _ in AnyView(EmptyView()) }, networkChip: { AnyView(EmptyView()) }, switchToMonad: {})
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
