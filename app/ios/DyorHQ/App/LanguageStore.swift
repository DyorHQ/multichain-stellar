import DyorKit
import Foundation
import Observation

/// The app's language, wired to iOS's own per-app language (`LanguageResolution` decides; this reads and saves). Made
/// once by `AppEnvironment`, before any screen: the first launch of an install saves English (owner decision 16).
///
/// A choice applies at once: `locale` is the SwiftUI environment's locale (`RootView`) and `L10n.locale`, so `Text` and
/// `tr()` redraw in the new language and every screen keeps its place. What iOS draws itself (Face ID, permission
/// prompts, the Apple button) follows from the next launch, when iOS reads the saved language.
@Observable
@MainActor
final class LanguageStore {
    /// What the Language screen checks: System, or one language.
    private(set) var choice: LanguageChoice
    /// The language the app's text is in.
    private(set) var resolved: AppLanguage
    /// `resolved` with the device's region and format settings.
    private(set) var locale: Locale
    /// The languages this build ships, in picker order: English, then each language whose translation is in the bundle.
    let available: [AppLanguage]
    /// Told the language in use after a choice or a reset changes it.
    @ObservationIgnored var onChange: ((AppLanguage) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let domain: String
    @ObservationIgnored private let shipped: [String]

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        domain = bundle.bundleIdentifier ?? "fun.dyorhq.app"
        shipped = bundle.localizations
        available = AppLanguage.shipped(in: shipped)
        let stored = LanguageResolution.stored(in: defaults, domain: domain)
        let launch = LanguageResolution.launch(stored: stored.appleLanguages, initialized: stored.initialized,
                                               device: Self.deviceLanguages(defaults), shipped: shipped)
        if let write = launch.write { LanguageResolution.save(write, to: defaults) }
        choice = launch.choice
        resolved = launch.resolved
        locale = L10n.locale(for: launch.resolved, device: .current)
        L10n.locale = locale
    }

    /// The device's language in its own name, shipped or not: the System row's subtitle.
    var deviceLanguageName: String {
        LanguageResolution.deviceLanguageName(device: Self.deviceLanguages(defaults))
    }

    /// Applies and saves a choice from the Language screen or the onboarding menu.
    func select(_ choice: LanguageChoice) {
        apply(LanguageResolution.select(choice, device: Self.deviceLanguages(defaults), shipped: shipped))
    }

    /// After this device's data was erased (`Session.eraseLocalData`): English again, saved with the marker, as on a new
    /// install.
    func reset() {
        apply(LanguageResolution.erased(device: Self.deviceLanguages(defaults), shipped: shipped))
    }

    private func apply(_ resolution: LanguageResolution) {
        if let write = resolution.write { LanguageResolution.save(write, to: defaults) }
        let changed = resolution.resolved != resolved
        choice = resolution.choice
        resolved = resolution.resolved
        locale = L10n.locale(for: resolution.resolved, device: .current)
        L10n.locale = locale
        if changed { onChange?(resolved) }
    }

    /// The device's ordered language list (Settings › General › Language & Region). The app's own `AppleLanguages`
    /// shadows it in the standard search, and in `Locale.preferredLanguages`, so it is read from the global domain
    /// itself. In an iOS app, `persistentDomain(forName: UserDefaults.globalDomain)` comes back without it, which named
    /// the app's language as the device's and made System keep it. iOS's list is the fallback, as at a launch with no
    /// language saved, when nothing shadows it.
    private static func deviceLanguages(_ defaults: UserDefaults) -> [String] {
        if let device = CFPreferencesCopyAppValue(LanguageResolution.appleLanguagesKey as CFString, kCFPreferencesAnyApplication) as? [String],
           !device.isEmpty {
            return device
        }
        if let device = defaults.persistentDomain(forName: UserDefaults.globalDomain)?[LanguageResolution.appleLanguagesKey] as? [String],
           !device.isEmpty {
            return device
        }
        return Locale.preferredLanguages
    }
}

/// The app's text for a place that takes a `String` (a model's label, an alert built in code), in the language in use.
/// A SwiftUI `Text("…")` needs nothing: it follows the environment's locale. Never `String(localized:locale:)`, whose
/// locale only formats the arguments.
func tr(_ resource: LocalizedStringResource) -> String {
    L10n.string(resource)
}
