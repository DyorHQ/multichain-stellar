import Foundation

/// The font of the "Continue with Google" label. Google's branding asks for Google Sans, and the app bundles a subset of
/// it (`Resources/Fonts/GoogleSans-Medium.ttf`, SIL Open Font License 1.1, no reserved font name) that holds only the
/// English label's letters: no accents, no other words, no other scripts. A missing glyph would draw as a box, so a label
/// the subset can't draw (Spanish and French, with their own words and accents) is drawn in the system font, and Chinese
/// and Korean always are. Rebuilding the subset with the Latin accents needs Google Sans's full font, which is not in the
/// repository.
public enum GoogleButtonFont {
    /// The characters the bundled subset can draw: the label's letters, the space and the no-break space
    /// (`GoogleButtonFontTests` reads them from the font file).
    public static let subsetCharacters: Set<Character> = Set(" CGeghilnotuw\u{00A0}")

    /// Whether `label`, the label in `language`, is drawn in Google Sans: only when every character of it is in the
    /// subset, and never in Chinese or Korean.
    public static func usesGoogleSans(_ label: String, language: AppLanguage) -> Bool {
        switch language {
        case .zhHans, .ko: return false
        case .en, .es, .fr: return !label.isEmpty && label.allSatisfy(subsetCharacters.contains)
        }
    }
}
