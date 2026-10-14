import Foundation

/// A language the app can be shown in. A language is offered only once the build ships its translation
/// (`shipped(in:)`): the picker lists the cases whose localization is in the app bundle, so a language that is not
/// complete is simply not there. English is the development language and is always there.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case en
    case es
    case fr
    case zhHans = "zh-Hans"
    case ko

    public var id: String { rawValue }

    /// The localization code: the app's `<code>.lproj` and the value saved in `AppleLanguages`.
    public var code: String { rawValue }

    /// The language's name in itself, as the picker shows it. Never translated.
    public var endonym: String {
        switch self {
        case .en: return "English" // not localized: each language's own name
        case .es: return "Español"
        case .fr: return "Français"
        case .zhHans: return "简体中文"
        case .ko: return "한국어"
        }
    }

    /// The languages a bundle with these localizations ships, in picker order. English always.
    public static func shipped(in localizations: [String]) -> [AppLanguage] {
        allCases.filter { $0 == .en || localizations.contains($0.code) }
    }
}

/// What the user chose on the Language screen: the device's language, or one language.
public enum LanguageChoice: Hashable, Sendable {
    case system
    case language(AppLanguage)
}

/// The app's language, decided from what iOS keeps for it. The one stored truth is iOS's own per-app language: the
/// `AppleLanguages` array in the app's own defaults domain, which Settings › Apps › DyorHQ › Language also shows and
/// edits, so the app and iOS Settings never disagree. A one-time marker, `language.initialized`, tells an install that
/// never chose apart from one that chose System.
///
/// English is the default (owner decision 16). A launch with no marker — a new install, the first launch after the
/// update, or the first after Delete Account erased the app's defaults — saves English and the marker. With the marker,
/// no `AppleLanguages` means System, whether chosen in the app or as "Default" in iOS Settings, and a value means that
/// language. Choosing System removes the key and keeps the marker; choosing a language saves it alone.
///
/// System follows the device's ordered language list among the languages this build ships, as iOS itself matches it,
/// with English last: Spanish for es-419, French for fr-CA, Simplified Chinese for zh-CN, and English for a device in
/// German, Portuguese or Traditional Chinese. While only English ships, everything resolves to English.
public struct LanguageResolution: Equatable, Sendable {
    /// iOS's per-app language list, read from and written to the app's own domain only.
    public static let appleLanguagesKey = "AppleLanguages"
    /// Set once the language was decided for this install. Neither key starts with a prefix that marks an install as
    /// one from before App Lock's default (`AppSettings.appLockDefault`, R4).
    public static let initializedKey = "language.initialized"

    /// What to save in the app's domain.
    public struct Write: Equatable, Sendable {
        /// The `AppleLanguages` to save; nil removes the key, which is System.
        public var appleLanguages: [String]?
        /// Saves the marker. Every write saves it: once decided, an install never goes back to "never chosen".
        public var markInitialized: Bool
    }

    /// The choice the Language screen checks.
    public let choice: LanguageChoice
    /// The language the app's text is in.
    public let resolved: AppLanguage
    /// What to save in the app's domain for this choice; nil when what is saved already says it.
    public let write: Write?

    /// The language at launch, from the app domain's `AppleLanguages` (`stored`) and the marker. `device` is the
    /// device's ordered language list, `shipped` the bundle's localizations.
    public static func launch(stored: [String]?, initialized: Bool, device: [String], shipped: [String]) -> LanguageResolution {
        guard initialized else { return select(.language(.en), device: device, shipped: shipped) }
        guard let stored, !stored.isEmpty else {
            return LanguageResolution(choice: .system, resolved: systemLanguage(device: device, shipped: shipped), write: nil)
        }
        // iOS shows the bundle in the best match of the saved list alone (the device's list is not consulted), and in
        // English when nothing matches: the screen checks the language the app is actually in.
        let resolved = match(stored, shipped: shipped)
        return LanguageResolution(choice: .language(resolved), resolved: resolved, write: nil)
    }

    /// The user's choice, and what to save for it.
    public static func select(_ choice: LanguageChoice, device: [String], shipped: [String]) -> LanguageResolution {
        switch choice {
        case .system:
            return LanguageResolution(choice: .system, resolved: systemLanguage(device: device, shipped: shipped),
                                      write: Write(appleLanguages: nil, markInitialized: true))
        case .language(let language):
            let resolved = match([language.code], shipped: shipped)
            return LanguageResolution(choice: .language(resolved), resolved: resolved,
                                      write: Write(appleLanguages: [language.code], markInitialized: true))
        }
    }

    /// After this device's data was erased (Delete Account, Forget This Device): the app's defaults are gone, marker
    /// included, so the language is English again, as on a new install.
    public static func erased(device: [String], shipped: [String]) -> LanguageResolution {
        launch(stored: nil, initialized: false, device: device, shipped: shipped)
    }

    /// The language System gives on a device with this ordered language list.
    public static func systemLanguage(device: [String], shipped: [String]) -> AppLanguage {
        match(device, shipped: shipped)
    }

    /// The device's language in its own name, for the System row: the first of the device's ordered list, whether or
    /// not this build ships it. One of the app's languages is named as the picker names it ("Français" for fr-CA,
    /// "简体中文" for zh-CN); any other as iOS names it in itself, capitalized ("Deutsch", "Português", "繁體中文"),
    /// with its script only when it is not the language's usual one. A code iOS has no name for is shown as it is.
    public static func deviceLanguageName(device: [String]) -> String {
        guard let first = device.first, !first.isEmpty else { return AppLanguage.en.endonym }
        let language = Locale.Language(identifier: first)
        let app = match([first], shipped: AppLanguage.allCases.map(\.code))
        if app != .en || language.languageCode == .english { return app.endonym }
        guard let code = language.languageCode?.identifier else { return first }
        let usualScript = Locale.Language(identifier: code).script
        let identifier = language.script.map { $0 == usualScript ? code : "\(code)-\($0.identifier)" } ?? code
        let locale = Locale(identifier: identifier)
        guard let name = locale.localizedString(forIdentifier: identifier), !name.isEmpty else { return first }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// iOS's own match of a preference list against the shipped languages (`Bundle.preferredLocalizations`), English
    /// last so a list with no match falls back to it.
    private static func match(_ preferences: [String], shipped: [String]) -> AppLanguage {
        let offered = AppLanguage.shipped(in: shipped).map(\.code)
        let best = Bundle.preferredLocalizations(from: offered, forPreferences: preferences + [AppLanguage.en.code]).first
        return best.flatMap(AppLanguage.init(rawValue:)) ?? .en
    }

    // MARK: - The app's defaults

    /// What is saved in `defaults`' app domain (`domain`, the bundle identifier): its own `AppleLanguages` — never the
    /// device's list, which the standard search falls back to — and the marker.
    public static func stored(in defaults: some LanguageDefaults, domain: String) -> (appleLanguages: [String]?, initialized: Bool) {
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        return (saved[appleLanguagesKey] as? [String], saved[initializedKey] as? Bool ?? false)
    }

    /// Saves `write` in `defaults`' app domain. Nothing else is touched.
    public static func save(_ write: Write, to defaults: some LanguageDefaults) {
        if let languages = write.appleLanguages {
            defaults.set(languages, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
        if write.markInitialized { defaults.set(true, forKey: initializedKey) }
    }
}

/// What `LanguageResolution` needs of the store: `UserDefaults`, or a test's in memory.
public protocol LanguageDefaults {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: LanguageDefaults {}
