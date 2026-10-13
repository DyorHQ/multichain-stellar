import Foundation
import Observation
import os
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The language the Stellar screens' text is in right now, from the package's own catalog
/// (`Resources/Localizable.xcstrings`). It mirrors DyorKit's `L10n`: the host sets `locale` with the app's own
/// (`LiteL10n.locale = L10n.locale`) at launch and on every language choice, so an in-app language change reaches the
/// Stellar screens at once, without a relaunch.
///
/// Every word the package shows goes through `tr`, which resolves its key in this package's bundle with the resource's
/// locale set: that selects the translation (plurals included). A literal handed straight to SwiftUI would be looked up
/// in the host app's catalog, which never holds the package's text, so the package hands SwiftUI the resolved `String`.
/// Network and product names ("Monad", "Stellar", "DyorHQ", "Blend") are never translated.
///
/// `locale` is safe to read from any thread (a lock guards it) and observable: a view whose body read it through `tr`
/// redraws when it changes.
public enum LiteL10n {
    /// The current locale. The device's until the host sets it.
    public static var locale: Locale {
        get { current.locale }
        set { current.locale = newValue }
    }

    /// The text for `value` in the current language. The build copies `value` into the catalog as a key; its note for
    /// translators lives in the catalog.
    static func tr(_ value: String.LocalizationValue) -> String {
        string(LocalizedStringResource(value, bundle: lite))
    }

    /// `resource` resolved in the current language.
    static func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// The package's resource bundle, which holds its catalog.
    static var bundle: Bundle { .module }

    /// The package's catalog as a resource's bundle: a resource without it would be looked up in the app's catalog.
    static var lite: LocalizedStringResource.BundleDescription { .atURL(bundle.bundleURL) }

    private static let current = Current(.current)

    /// The locale behind a lock, with an observation registrar so SwiftUI tracks a read of it.
    private final class Current: Observable, @unchecked Sendable {
        private let registrar = ObservationRegistrar()
        private let lock: OSAllocatedUnfairLock<Locale>

        init(_ locale: Locale) { lock = OSAllocatedUnfairLock(initialState: locale) }

        var locale: Locale {
            get {
                registrar.access(self, keyPath: \.locale)
                return lock.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.locale) { lock.withLock { $0 = newValue } }
            }
        }
    }
}

/// The package's text for `value`, in the current language (`LiteL10n.tr`).
func tr(_ value: String.LocalizationValue) -> String { LiteL10n.tr(value) }

/// What this device's owner check asks for, for copy like "Unlock with Face ID": Apple's names as they are, and
/// "Passcode" in the current language when no biometrics are enrolled (a passkey then takes the device passcode too).
enum LiteBiometrics {
    static var promptName: String {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch context.biometryType {
            case .faceID: return "Face ID"
            case .touchID: return "Touch ID"
            case .opticID: return "Optic ID"
            default: break
            }
        }
        #endif
        return tr("Passcode")
    }
}
