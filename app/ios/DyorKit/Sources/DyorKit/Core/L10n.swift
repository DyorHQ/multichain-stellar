import Foundation
import Observation
import os

/// The language the app's text is in right now, and DyorKit's own text in it.
///
/// `locale` is the chosen language with the device's region and format settings (`locale(for:device:)`). The app sets
/// it at launch and on every choice (`LanguageStore`), and gives the same locale to SwiftUI's environment, so `Text`
/// switches at once. Text built as a `String` (a model's label, an error) goes through `tr` here or the app's `tr()`,
/// which set the resource's locale before resolving it: that selects the translation, plurals included, without a
/// relaunch. `String(localized:bundle:locale:)` is never used for this: its locale only formats the arguments, it does
/// not select the language.
///
/// `locale` is safe to read from any thread (a lock guards it) and observable: a view whose body read it through `tr`
/// redraws when it changes, so a screen keeps its navigation and still shows the new language.
public enum L10n {
    /// The current locale. English with the device's region until the app sets it.
    public static var locale: Locale {
        get { current.locale }
        set { current.locale = newValue }
    }

    /// DyorKit's text for `value` in the current language, from DyorKit's own catalog. The build copies `value` into the
    /// catalog as a key. Text that needs a note for its translator is written as a resource instead,
    /// `string(LocalizedStringResource("Long", bundle: kit, comment: "…"))`: the build copies a resource's comment.
    public static func tr(_ value: String.LocalizationValue) -> String {
        string(LocalizedStringResource(value, bundle: kit))
    }

    /// `tr(value)`: the build copies `value` into the catalog but never a comment passed through a function of ours, so
    /// the translator would never see it.
    @available(*, deprecated, message: "the build never copies this comment into the catalog: write string(LocalizedStringResource(value, bundle: kit, comment: …))")
    public static func tr(_ value: String.LocalizationValue, comment: StaticString?) -> String { tr(value) }

    /// DyorKit's resource bundle, which holds its catalog: `Bundle.module`, the package's own resource bundle, both inside
    /// the app and under `swift test`.
    static var bundle: Bundle { .module }

    /// DyorKit's catalog as a resource's bundle. Every `LocalizedStringResource` DyorKit writes names it: one without it
    /// would be looked up in the app's catalog, which never holds DyorKit's text, and always show its English.
    static var kit: LocalizedStringResource.BundleDescription { .atURL(bundle.bundleURL) }

    /// `resource` resolved in the current language (the app's `tr()` passes its own, from the main bundle).
    public static func string(_ resource: LocalizedStringResource) -> String {
        var resource = resource
        resource.locale = locale
        return String(localized: resource)
    }

    /// The locale for `language` on a device whose locale is `device`: the device's own when it is already in that
    /// language, so nothing about dates or numbers moves; otherwise the language with the device's region and its
    /// calendar, numbering and hour-cycle settings kept. Prices never depend on it (`PriceFormat`); dates and words
    /// follow the language.
    public static func locale(for language: AppLanguage, device: Locale) -> Locale {
        let chosen = Locale.Language(identifier: language.code)
        if device.language.languageCode == chosen.languageCode, device.language.script == chosen.script { return device }
        var components = Locale.Components(locale: device)
        var languageComponents = Locale.Language.Components(identifier: language.code)
        languageComponents.region = device.region
        components.languageComponents = languageComponents
        return Locale(components: components)
    }

    private static let current = Current(locale(for: .en, device: .current))

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
