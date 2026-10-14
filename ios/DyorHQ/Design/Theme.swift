import DyorKit
import LocalAuthentication
import SwiftUI
import UIKit

/// User-controlled appearance and trading preferences. Persisted to `UserDefaults` so a choice survives launches,
/// and observed so the whole app restyles the moment it changes (the Appearance sheet, notifications, defaults).
@Observable
@MainActor
final class AppSettings {
    var appearance: AppearanceMode { didSet { store(appearance.rawValue, "settings.appearance"); appearance.apply() } }
    var notificationsEnabled: Bool { didSet { store(notificationsEnabled, "settings.notifications") } }
    /// Notify on completed swaps and on order fills the app sees while it runs (a preference; delivery needs the system
    /// permission).
    var notifyFills: Bool { didSet { store(notifyFills, "settings.notifyFills") } }
    var notifyPriceAlerts: Bool { didSet { store(notifyPriceAlerts, "settings.notifyPrice") } }
    /// Notify when an open Perps position's margin usage reaches 80% or 90%, or its mark comes within 10% of the
    /// liquidation price (`PerpRiskLevel`), on any screen while the app is open. On by default. Like every switch here it
    /// is saved only when changed (`didSet`), never by `init`, so it can't make a new install look like an earlier one
    /// before App Lock's default is decided (rule R4).
    var notifyMargin: Bool { didSet { store(notifyMargin, "settings.notifyMargin") } }
    /// Require Face ID / Touch ID before signing a transaction — a device-side second factor for a self-custodial
    /// wallet, enforced in the confirmation sheet. On by default for a new install (`appLockDefault`), and after this
    /// device's data is erased (`Session.eraseLocalData`). This device's own: it isn't mirrored to the backend (not in
    /// `snapshot`), so a change isn't reported (`onChange`), which would mark the settings changed and keep a restore out.
    var requireBiometrics: Bool { didSet { defaults.set(requireBiometrics, forKey: "settings.biometrics") } }
    /// Default leverage the perps ticket opens on.
    var defaultLeverage: Double { didSet { store(defaultLeverage, "settings.leverage") } }
    /// Max slippage for market orders and swaps, in basis points.
    var slippageBps: Int { didSet { store(slippageBps, "settings.slippageBps") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "settings.appearance") ?? "") ?? .system
        notificationsEnabled = defaults.object(forKey: "settings.notifications") as? Bool ?? true
        notifyFills = defaults.object(forKey: "settings.notifyFills") as? Bool ?? true
        notifyPriceAlerts = defaults.object(forKey: "settings.notifyPrice") as? Bool ?? false
        notifyMargin = defaults.object(forKey: "settings.notifyMargin") as? Bool ?? true
        requireBiometrics = defaults.object(forKey: "settings.biometrics") as? Bool ?? Self.appLockDefault(defaults)
        defaultLeverage = defaults.object(forKey: "settings.leverage") as? Double ?? TradingDefaults.leverage
        slippageBps = defaults.object(forKey: "settings.slippageBps") as? Int ?? TradingDefaults.slippageBps
    }

    /// Whether App Lock asks for Face ID before `account` signs. Never for a passkey (Mera) account: its passkey is the
    /// lock, and a locked session already asks for it where the signature is needed, so App Lock never stacks a second
    /// Face ID on top of a passkey prompt.
    func appLockApplies(to account: Session.Account?) -> Bool {
        requireBiometrics && account?.method != .meraPasskey
    }

    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key); AppSettings.onChange?() }

    /// App Lock where no choice was ever saved (security audit 2026-09-26, IOSK-4), decided once and saved so it never
    /// flips later: ON for a new install on a device that can verify its owner, so a phone picked up unlocked can't sign
    /// without Face ID or the passcode. An install from before this default — told apart by what earlier runs left in
    /// UserDefaults — keeps the OFF it has always had. A device with no passcode starts OFF too: App Lock fails closed
    /// there, and it would block every signature until one is set.
    private static func appLockDefault(_ defaults: UserDefaults) -> Bool {
        let earlierRun = ["settings.", "session.", "mera.", "localWallet.", "venueTokens.", "activityLog.", "notifications.",
                          "knownTokens.", "priceAlerts.", "bridge.", "perp."]
        let isEarlierInstall = defaults.dictionaryRepresentation().keys.contains { key in earlierRun.contains { key.hasPrefix($0) } }
        let on = !isEarlierInstall && BiometricGate.canAuthenticateOwner
        defaults.set(on, forKey: "settings.biometrics")
        return on
    }

    /// Mirrors settings to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (() -> Void)?

    /// The settings as a JSON object, for the backend copy (no keys, no addresses).
    var snapshot: [String: Any] {
        ["appearance": appearance.rawValue, "notificationsEnabled": notificationsEnabled, "notifyFills": notifyFills,
         "notifyPriceAlerts": notifyPriceAlerts, "notifyMargin": notifyMargin, "defaultLeverage": defaultLeverage, "slippageBps": slippageBps]
    }

    /// Applies a backend copy of the settings (a fresh device after sign-in). The copy is checked first
    /// (`BackendRestore.settings`): unknown or mistyped keys are ignored, and a slippage or leverage the Trading
    /// Preferences screen couldn't have set restores as the default, so a tampered row can't loosen a ticket.
    func apply(snapshot: [String: Any]) {
        let restored = BackendRestore.settings(from: snapshot, appearances: Set(AppearanceMode.allCases.map(\.rawValue)))
        if let raw = restored.appearance, let mode = AppearanceMode(rawValue: raw) { appearance = mode }
        if let v = restored.notificationsEnabled { notificationsEnabled = v }
        if let v = restored.notifyFills { notifyFills = v }
        if let v = restored.notifyPriceAlerts { notifyPriceAlerts = v }
        if let v = restored.notifyMargin { notifyMargin = v }
        if let v = restored.defaultLeverage { defaultLeverage = v }
        if let v = restored.slippageBps { slippageBps = v }
    }
}

/// Face ID / Touch ID gate used before signing when the user turns on the app lock.
enum BiometricGate {
    /// What the device's owner check asks for (`BiometricPromptKind`): the prompt's name and its icon both come from it,
    /// so the icon never depends on translated text.
    typealias PromptKind = BiometricPromptKind

    /// Whether the device can do biometric auth at all (so we don't offer a toggle that can never work).
    static var isAvailable: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }

    /// "Face ID", "Touch ID", or a generic name for the copy in Security, in the app's language.
    static var typeName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        let kind = PromptKind(biometricsAvailable: true, biometry: context.biometryType)
        return kind == .passcode ? tr("Biometrics") : kind.name
    }

    /// What this device's passkey prompt asks for: Face ID, Touch ID or Optic ID, and the passcode when no biometrics
    /// are enrolled (a passkey then takes the device passcode). Read once per launch.
    static let promptKind: PromptKind = {
        let context = LAContext()
        let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return PromptKind(biometricsAvailable: available, biometry: context.biometryType)
    }()

    /// The prompt's name in copy like "Confirm with Face ID" and "Face ID required: …": Apple's names as they are, and
    /// "Passcode" in the app's language.
    static var promptName: String { promptKind.name }

    /// The SF Symbol for the prompt, from its kind: never from its name, which is translated.
    static var promptSymbol: String { promptKind.symbol }

    /// Whether the device can verify its owner at all — biometrics or the device passcode.
    static var canAuthenticateOwner: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    /// Verifies the device owner before a sensitive action: Face ID / Touch ID, falling back to the device passcode
    /// (after a biometric lockout, or when no biometrics are enrolled). FAILS CLOSED — if the owner can't be verified
    /// at all (no passcode set) or verification fails, it returns false and the action must not proceed. `reason` is
    /// written in the code ("Confirm order"), and iOS shows it in the prompt in the app's language.
    @MainActor
    static func authenticate(reason: LocalizedStringResource) async -> Bool {
        await authenticate(reason: tr(reason))
    }

    /// The same check for a reason that is already in the app's language (a `tr("…")`), shown as it is. It is generic
    /// and disfavoured, so a reason written as a literal still takes the one above and is looked up as a key: a plain
    /// `String` overload, even disfavoured, would take every literal and show it untranslated.
    @MainActor
    @_disfavoredOverload
    static func authenticate<S: StringProtocol>(reason verbatim: S) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        let reason = String(verbatim)
        BiometricPrompt.shared.showing += 1
        defer { BiometricPrompt.shared.showing -= 1 }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Whether an `authenticate` prompt is on screen: its system UI makes the scene `.inactive`, and the privacy cover
    /// stays off behind it (RootView), as it does behind a passkey prompt. Observable.
    @MainActor
    static var isPrompting: Bool { BiometricPrompt.shared.showing > 0 }
}

/// The `BiometricGate` prompts on screen, observed through `BiometricGate.isPrompting`.
@Observable
@MainActor
final class BiometricPrompt {
    static let shared = BiometricPrompt()
    fileprivate(set) var showing = 0
}

/// Light / Dark / System, the same three choices Apple's own apps offer.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// The scheme this mode actually renders as right now: the choice itself, or what the system is currently set to.
    /// A sheet keeps the scheme it was presented with, so the Appearance sheet styles itself from this.
    @MainActor
    var resolved: ColorScheme {
        if let colorScheme { return colorScheme }
        // The scene's own traits, not a window's: a window carries the override we just set, and its trait collection
        // only catches up on the next layout pass, so reading it here would hand back the scheme we are leaving.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Restyles every window right now. `preferredColorScheme` on the root view only reaches the window itself, so a
    /// sheet or full-screen cover that is already on screen — Profile, and the Appearance sheet above it — keeps the
    /// old scheme until it is dismissed. Setting the window's own style restyles the presented hierarchy with it, so
    /// the switch is visible the instant it is tapped.
    @MainActor
    func apply() {
        let style = interfaceStyle
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.overrideUserInterfaceStyle = style
                // A presented sheet or full-screen cover carries its own override once SwiftUI has set one, which
                // would shadow the window; clear it down the chain so the whole stack follows.
                var presented = window.rootViewController
                while let controller = presented {
                    controller.overrideUserInterfaceStyle = style
                    presented = controller.presentedViewController
                }
            }
        }
    }

    /// The mode's name on the Appearance sheet and in Profile, in the app's language.
    var label: String {
        switch self {
        case .system: tr(LocalizedStringResource("System", comment: "Follows the device's own setting: on Appearance its light or dark look, on the Language screen and menu its language [tight]"))
        case .light: tr(LocalizedStringResource("Light", comment: "Appearance: the light look [tight]"))
        case .dark: tr(LocalizedStringResource("Dark", comment: "Appearance: the dark look [tight]"))
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

extension Color {
    /// A dynamic color that resolves per the active interface style, so a hue can be tuned separately for
    /// light and dark without an asset-catalog entry.
    init(light: Color, dark: Color) {
        self = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
    }

    /// The hairline around every coin logo: it edges a white logo (WBTC, cbBTC, WETH) on a light card and a near-black
    /// one (HYPE, USDe, LBTC) on a dark card, and is stronger under Increase Contrast. It resolves through the traits,
    /// so it follows the in-app appearance too.
    static let logoRing = Color(uiColor: UIColor { traits in
        let strong = traits.accessibilityContrast == .high
        return traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: strong ? 0.28 : 0.12)
                                                  : UIColor(white: 0, alpha: strong ? 0.22 : 0.08)
    })

    // Allocation ring hues — three restrained, distinguishable tones that hold up on paper and ink grounds.
    // They are identity, not status: never reused for up/down, which stay Positive/Negative.
    static let allocationSpot = Color(light: Color(red: 0.12, green: 0.51, blue: 0.60), dark: Color(red: 0.42, green: 0.79, blue: 0.86))
    static let allocationPerps = Color(light: Color(red: 0.36, green: 0.33, blue: 0.66), dark: Color(red: 0.62, green: 0.58, blue: 0.95))
    static let allocationLaunchpad = Color(light: Color(red: 0.72, green: 0.48, blue: 0.14), dark: Color(red: 0.93, green: 0.71, blue: 0.36))
    static let allocationMoments = Color(light: Color(red: 0.70, green: 0.30, blue: 0.42), dark: Color(red: 0.94, green: 0.56, blue: 0.68))
}
