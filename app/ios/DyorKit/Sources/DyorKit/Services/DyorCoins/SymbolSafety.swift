import Foundation

/// Which coin symbols and names show as what they are, and which names and symbols a coin made in DyorHQ may not take.
///
/// A symbol is display-safe when nothing in it can make it read as another: Latin — printable ASCII (as MON's and every
/// curated token's is) and the accented letters of the Latin alphabets (CAFÉ, PIÑA, ÇA, ÐOGE; owner decision 5, "Latin
/// letters stay allowed") — or Chinese, Japanese or Korean letters with ASCII digits (pick 19), never the two mixed.
/// Everything else is not: control, format, direction-changing and zero-width characters, combining marks left over
/// once the text is composed, full-width Latin, the Latin letters drawn like others (dotless ı, small capitals, IPA),
/// and letters from any other script — Cyrillic, Greek, Armenian, Cherokee, Lisu, Myanmar, Hebrew and more hold letters
/// drawn exactly like Latin ones. Accents don't hide a look-alike: "USDĆ" and "MØN" read as USDC and MON
/// (`WalletHoldings.imitated(by:)` folds them).
///
/// A name is display-safe when it has no hidden or direction-changing character (`hasHiddenCharacters`) and no word
/// mixes Latin letters with letters of another script drawn like Latin ones (`mixesLookAlikeAlphabets`); any language
/// and emoji are fine, with the joiners Persian, Indic scripts and emoji spell with. A DyorHQ coin whose symbol or name
/// isn't display-safe, or whose symbol is longer than the create forms allow (`maxSymbolLength`), carries a warning,
/// never "DyorHQ Launch" (`TokenBadge`), and the create forms refuse all of it (`createRefusal`), so a coin made in the
/// app never carries a warning. A name's length is the forms' alone (`maxLaunchNameLength`, `maxMomentNameLength`): the
/// launch form of build 16 and before set none and the Moment form no byte limit, so a long name is no reason to warn,
/// and what the registry keeps of one is cut (`DyorCoin.maxStoredName`). One made directly on the contracts can still
/// carry a warning. Every check reads the chain's text as it is — never `ChainText.shown`, which removes the direction
/// characters these checks exist to catch.
public enum SymbolSafety {
    /// The longest symbol the create forms take, in characters (`LaunchpadView`, `CreateMomentView`).
    public static let maxSymbolLength = 10
    /// The longest name a new launch may have: the launch form sets none, so this is the create guard's. Coins launched
    /// before it with longer names keep their DyorHQ label (`isDisplaySafe(_:)` of a coin doesn't judge a name's length).
    public static let maxLaunchNameLength = 32
    /// The longest name a new Moment may have (`CreateMomentView`, which counts characters only; the guard also counts
    /// bytes, `fits`).
    public static let maxMomentNameLength = 48

    /// Whether `symbol` shows as what it is (see above). False for empty text or spaces alone.
    public static func isDisplaySafe(_ symbol: String) -> Bool {
        guard symbol.unicodeScalars.contains(where: { $0.value != 0x20 }) else { return false }
        // Latin, composed (NFC) so an accent typed as a combining mark joins its letter; one left over is not safe.
        if symbol.precomposedStringWithCanonicalMapping.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) || isAccentedLatinLetter($0) }) { return true }
        // Chinese, Japanese or Korean, as written: conjoining jamo are another way to draw a syllable, not one.
        var letters = 0
        for scalar in symbol.unicodeScalars {
            if ("0"..."9").contains(scalar) { continue }
            guard isEastAsianLetter(scalar) else { return false }
            letters += 1
        }
        return letters > 0
    }

    /// Whether `text` fits a form field of `limit` characters: at most that many, and at most four UTF-8 bytes each, so
    /// a few characters piled with marks don't pass as short.
    public static func fits(_ text: String, limit: Int) -> Bool {
        text.count <= limit && text.utf8.count <= 4 * limit
    }

    /// Whether `name` shows as what it is: nothing hidden or direction-changing in it, and no word mixing Latin letters
    /// with look-alikes from another script.
    public static func isNameDisplaySafe(_ name: String) -> Bool {
        !hasHiddenCharacters(name) && !mixesLookAlikeAlphabets(name)
    }

    /// Whether a DyorHQ coin's own symbol and name show as what they are, and its symbol fits the create forms
    /// (`maxSymbolLength`, which every form of every build has kept to). A name is judged by what it holds, not its
    /// length: earlier forms let a launch's name be any length and a Moment's any number of bytes. An unreadable symbol
    /// or name (`ChainText.unreadable`) is not display-safe.
    public static func isDisplaySafe(_ coin: DyorCoin) -> Bool {
        isDisplaySafe(coin.symbol) && fits(coin.symbol, limit: maxSymbolLength) && isNameDisplaySafe(coin.name)
    }

    /// A precomposed letter of the Latin alphabets beyond ASCII (Latin-1, Extended-A and -B, Extended Additional) that
    /// has case — É, Ñ, Ç, Ð, Ø, ß, Ș — and isn't drawn like another letter (`WalletHoldings.lookAlikeLetters`: dotless ı,
    /// long ſ, the click letters and IPA-like forms are left out).
    static func isAccentedLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xC0...0x24F, 0x1E00...0x1EFF: break
        default: return false
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter: return WalletHoldings.lookAlikeLetters[scalar] == nil
        default: return false
        }
    }

    /// A letter of the Han (Chinese), Hangul (Korean), Hiragana or Katakana (Japanese) scripts, precomposed: the blocks
    /// below, and only their letters (`Lo`, or `Lm` such as 々 and the long-vowel mark ー), never an invisible filler
    /// (U+3164 and its kin are letters by category). Radicals, compatibility ideographs, conjoining and half-width jamo,
    /// half-width kana and the combining sound marks are left out: none is needed to write a name, and each is another way
    /// to draw the same text.
    static func isEastAsianLetter(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard properties.generalCategory == .otherLetter || properties.generalCategory == .modifierLetter, !properties.isDefaultIgnorableCodePoint else { return false }
        return eastAsianLetters.contains { $0.contains(scalar.value) }
    }

    private static let eastAsianLetters: [ClosedRange<UInt32>] = [
        // Han: the iteration marks 々 and 〆, CJK Unified Ideographs and Extension A, then Extensions B–I.
        0x3005...0x3006, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF, 0x2A700...0x2EE5F, 0x30000...0x323AF,
        // Hangul syllables and compatibility jamo.
        0xAC00...0xD7A3, 0x3131...0x318E,
        // Hiragana, its iteration marks; Katakana, the long-vowel and iteration marks, the small phonetic extensions.
        0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF,
    ]

    // MARK: Create guard

    /// Why a create form refuses a coin's name or symbol.
    public enum CreateRefusal: Hashable, Sendable {
        /// The symbol reads as a curated or a major token's (`WalletHoldings.imitated(by:)`): "USDC", "USDС" with a
        /// Cyrillic С, "WM0N", "MON2", "ETH".
        case symbolImitates(Token)
        /// The name reads as a curated or a major token's name or symbol: "Monad", "Wrapped MON", "M0nad", "Bitcoin".
        case nameImitates(Token)
        /// The symbol isn't display-safe (`isDisplaySafe`).
        case symbolNotDisplaySafe
        /// The symbol is longer than `maxSymbolLength`.
        case symbolTooLong
        /// The name holds a character that doesn't show as itself (`hasHiddenCharacters`).
        case nameHasHiddenCharacters
        /// A word of the name mixes Latin letters with look-alikes from another script (`mixesLookAlikeAlphabets`).
        case nameMixesAlphabets
        /// The name is longer than the form allows: the limit, in characters.
        case nameTooLong(Int)
        /// The name has no more characters than the form allows, but more than four UTF-8 bytes each on average (`fits`):
        /// emoji and symbols stored as many bytes each, which a count of characters doesn't show.
        case nameTooLongToStore

        /// What the form says under the field, in the app's language.
        public var message: String {
            switch self {
            case .symbolImitates(let token) where Token.core(token.address) == nil:
                return L10n.tr("This symbol looks like \(token.symbol), a widely traded token this coin isn't. Choose another symbol.")
            case .symbolImitates(let token): return L10n.tr("This symbol looks like \(token.symbol), a token DyorHQ already lists. Choose another symbol.")
            case .nameImitates(let token) where Token.core(token.address) == nil:
                return L10n.tr("This name looks like \(token.symbol), a widely traded token this coin isn't. Choose another name.")
            case .nameImitates(let token): return L10n.tr("This name looks like \(token.symbol), a token DyorHQ already lists. Choose another name.")
            case .symbolNotDisplaySafe:
                return L10n.tr("A symbol can use A–Z, 0–9 and accented Latin letters, or Chinese, Japanese or Korean characters with 0–9, not mixed.")
            case .symbolTooLong: return L10n.tr("A symbol can be at most \(SymbolSafety.maxSymbolLength) characters.")
            case .nameHasHiddenCharacters: return L10n.tr("This name has hidden or direction-changing characters. Remove them.")
            case .nameMixesAlphabets: return L10n.tr("A word in this name mixes Latin letters with letters from another alphabet that look like them. Use one alphabet in each word.")
            case .nameTooLong(let limit): return L10n.tr("A name can be at most \(limit) characters.")
            case .nameTooLongToStore: return L10n.tr("This name is too long to store: use fewer emoji or symbols.")
            }
        }

        /// Whether it is about the symbol field (else the name field).
        public var isAboutSymbol: Bool {
            switch self {
            case .symbolImitates, .symbolNotDisplaySafe, .symbolTooLong: return true
            case .nameImitates, .nameHasHiddenCharacters, .nameMixesAlphabets, .nameTooLong, .nameTooLongToStore: return false
            }
        }
    }

    /// Why a new launch or Moment may not take `name` and `symbol`, or nil when it may: a symbol that reads as a curated
    /// or major token's, then a name that does, then a symbol that isn't display-safe or is too long, then a name with
    /// hidden characters, one mixing look-alike alphabets in a word, or one longer than `maxName` (a launch's
    /// `maxLaunchNameLength`, a Moment's `maxMomentNameLength`) in characters, or in bytes (`fits`: said as too long to
    /// store, since its characters fit). An empty field is the form's own check, not a refusal here. What it allows, the
    /// badge never warns about (`TokenBadge`).
    public static func createRefusal(name: String, symbol: String, maxName: Int = maxLaunchNameLength) -> CreateRefusal? {
        if let token = WalletHoldings.imitated(by: probe(symbol: symbol, name: "")) { return .symbolImitates(token) }
        if let token = WalletHoldings.imitated(by: probe(symbol: "", name: name)) { return .nameImitates(token) }
        if !symbol.isEmpty, !isDisplaySafe(symbol) { return .symbolNotDisplaySafe }
        if !fits(symbol, limit: maxSymbolLength) { return .symbolTooLong }
        if hasHiddenCharacters(name) { return .nameHasHiddenCharacters }
        if mixesLookAlikeAlphabets(name) { return .nameMixesAlphabets }
        if name.count > maxName { return .nameTooLong(maxName) }
        if !fits(name, limit: maxName) { return .nameTooLongToStore }
        return nil
    }

    // MARK: Names

    /// Whether `name` holds a character that doesn't show as itself: a control, format or direction-changing character,
    /// a zero-width or other invisible one (`Address.isInvisible`, default-ignorable code points, the blank Braille
    /// pattern U+2800 and the Hangul fillers), a line or paragraph separator, a private-use or unassigned code point, or
    /// U+FFFD, which stands for bytes that aren't text. What a script or an emoji writes with is not hidden, and only
    /// where it does:
    /// - the zero-width non-joiner and joiner (U+200C, U+200D) between two letters of a script that spells with them
    ///   (`joinerScripts`: Arabic-script, Syriac, Mongolian and the Indic scripts), the first perhaps ending in a mark
    ///   such as a virama: Persian "می‌خواهم", a Devanagari conjunct "क्‍ष". `ChainText.shown` keeps them for the same
    ///   reason, and `WalletHoldings.visible` reads past them, so they hide no look-alike;
    /// - the zero-width joiner between two emoji ("👨‍👩‍👧"), after any variation selector or skin tone on the first;
    /// - VS15 or VS16 (U+FE0E, U+FE0F) right after an emoji ("❤️") or a keycap's 0–9, # or * followed by U+20E3;
    /// - U+20E3 COMBINING ENCLOSING KEYCAP right after 0–9, # or *, or after one of those and VS16 ("1️⃣");
    /// - tag characters (U+E0020–U+E007F) right after 🏴, ending with U+E007F CANCEL TAG, at most `ChainText.maxTags` of
    ///   them (England's flag).
    /// Accents belong to their letters ("Café", "Niño"): not hidden.
    public static func hasHiddenCharacters(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            let value = scalar.value
            if value == 0x1F3F4, let end = tagSequenceEnd(scalars, after: i) {
                i = end + 1
                continue
            }
            switch value {
            case 0x200C:
                guard joinsLetters(scalars, at: i) else { return true }
            case 0x200D:
                if joinsLetters(scalars, at: i) { break }
                guard i + 1 < scalars.count, isPictograph(scalars[i + 1]), let base = emojiBase(scalars, before: i), isPictograph(scalars[base]) else { return true }
            case 0xFE0E, 0xFE0F:
                guard i > 0, isPictograph(scalars[i - 1]) || (isKeycapBase(scalars[i - 1]) && i + 1 < scalars.count && scalars[i + 1].value == 0x20E3) else { return true }
            case 0x20E3:
                guard i > 0, isKeycapBase(scalars[i - 1]) || (scalars[i - 1].value == 0xFE0F && i > 1 && isKeycapBase(scalars[i - 2])) else { return true }
            case 0x2800, 0x115F, 0x1160, 0x3164, 0xFFA0, 0xFFFD:
                return true
            case 0xE0000...0xE007F:
                return true
            default:
                let properties = scalar.properties
                switch properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
                default: break
                }
                if properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) { return true }
            }
            i += 1
        }
        return false
    }

    /// Whether the joiner or non-joiner at `at` stands between two letters of one script in `joinerScripts`: a letter of
    /// it, or one of its marks (a virama, a vowel sign, a harakat) ending one, right before; a letter of it right after.
    private static func joinsLetters(_ scalars: [Unicode.Scalar], at: Int) -> Bool {
        guard at > 0, at + 1 < scalars.count, let script = joinerScript(scalars[at - 1]), joinerScript(scalars[at + 1]) == script else { return false }
        switch scalars[at - 1].properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .nonspacingMark, .spacingMark: break
        default: return false
        }
        switch scalars[at + 1].properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }

    /// Which of `joinerScripts` `scalar` belongs to, by block; nil for any other script.
    private static func joinerScript(_ scalar: Unicode.Scalar) -> Int? {
        joinerScripts.firstIndex { blocks in blocks.contains { $0.contains(scalar.value) } }
    }

    /// The scripts whose spelling uses the zero-width non-joiner and joiner, each as its blocks: Arabic (with its
    /// supplement, extensions and presentation forms: Persian, Urdu, Pashto), Syriac, Mongolian, Devanagari, Bengali,
    /// Gurmukhi, Gujarati, Oriya, Tamil, Telugu, Kannada, Malayalam and Sinhala.
    private static let joinerScripts: [[ClosedRange<UInt32>]] = [
        [0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF],
        [0x0700...0x074F, 0x0860...0x086F], [0x1800...0x18AF], [0x0900...0x097F, 0xA8E0...0xA8FF], [0x0980...0x09FF], [0x0A00...0x0A7F],
        [0x0A80...0x0AFF], [0x0B00...0x0B7F], [0x0B80...0x0BFF], [0x0C00...0x0C7F], [0x0C80...0x0CFF], [0x0D00...0x0D7F], [0x0D80...0x0DFF],
    ]

    /// An emoji a joiner may join or a variation selector may follow: a pictographic emoji (`isEmoji`, beyond ASCII's
    /// digits, # and *), not a regional-indicator letter, a skin tone or a tag.
    private static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard properties.isEmoji, scalar.value > 0x7F, !properties.isEmojiModifier else { return false }
        switch scalar.value {
        case 0x1F1E6...0x1F1FF, 0xE0000...0xE007F, 0x20E3, 0xFE0E, 0xFE0F, 0x200D: return false
        default: return true
        }
    }

    private static func isKeycapBase(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || scalar == "#" || scalar == "*"
    }

    /// The emoji a joiner at `joiner` follows: the scalar before it, past one variation selector and one skin tone.
    private static func emojiBase(_ scalars: [Unicode.Scalar], before joiner: Int) -> Int? {
        var at = joiner - 1
        if at >= 0, scalars[at].properties.isEmojiModifier { at -= 1 }
        if at >= 0, scalars[at].value == 0xFE0F { at -= 1 }
        return at >= 0 ? at : nil
    }

    /// Where the tag sequence after the 🏴 at `flag` ends (its U+E007F): the tags there are letters and digits' tags
    /// (U+E0020–U+E007E), at most `ChainText.maxTags` with the cancel tag. Nil when what follows isn't such a sequence.
    private static func tagSequenceEnd(_ scalars: [Unicode.Scalar], after flag: Int) -> Int? {
        var at = flag + 1
        while at < scalars.count, at - flag <= ChainText.maxTags {
            switch scalars[at].value {
            case 0xE007F: return at > flag + 1 ? at : nil
            case 0xE0020...0xE007E: at += 1
            default: return nil
            }
        }
        return nil
    }

    /// Whether a word of `name` mixes Latin letters with letters of another script drawn like Latin ones ("Pаypal" with a
    /// Cyrillic а, "Mօnad" with an Armenian օ, "Cဝin" with a Myanmar ဝ, "Mᴏnad" with a small capital): only letters in
    /// `WalletHoldings.lookAlikeLetters` from outside the everyday Latin blocks count, word by word. So "Ωmega", "πDAO",
    /// "μSwap", "ΔNeutral", "Lambda λ", "Pepe Пепе" and "Russian Рубль" are fine, as is a name in one alphabet alone,
    /// and the Turkish "ı" is a Latin letter. Words are split at anything that isn't a letter.
    public static func mixesLookAlikeAlphabets(_ name: String) -> Bool {
        for word in name.split(whereSeparator: { !$0.isLetter }) {
            var latin = false
            var lookAlike = false
            for scalar in word.unicodeScalars where scalar.properties.isAlphabetic {
                if isEverydayLatin(scalar.value) {
                    latin = true
                } else if WalletHoldings.lookAlikeLetters[scalar] != nil {
                    lookAlike = true
                }
            }
            if latin && lookAlike { return true }
        }
        return false
    }

    /// Basic Latin letters, Latin-1, Extended-A and -B, Extended Additional and full-width Latin: the letters Latin
    /// alphabets are written with.
    private static func isEverydayLatin(_ value: UInt32) -> Bool {
        switch value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF, 0xFF21...0xFF3A, 0xFF41...0xFF5A: return true
        default: return false
        }
    }

    /// A token that is neither MON nor curated, carrying the text to check, for `WalletHoldings.imitated(by:)`.
    private static func probe(symbol: String, name: String) -> Token {
        Token(address: Address(literal: "0x000000000000000000000000000000000000dEaD"), symbol: symbol, name: name, decimals: 18)
    }
}
