import Foundation

public extension ChainText {
    /// Creator text as the app shows it (a launch's name, symbol and description, a Moment's name, symbol and place),
    /// with the characters that change direction or hide removed: the direction embeddings, overrides and isolates and
    /// the direction marks (U+061C, U+200E, U+200F, U+202A–U+202E, U+2066–U+2069), the byte-order mark, the zero-width
    /// space, the word joiner and invisible operators (U+2060–U+2064), the Hangul fillers and the Mongolian vowel
    /// separator, every other format character (general category Cf) and default-ignorable code point, and control
    /// characters. A creator's symbol can then never reverse or hide the app's text around it: "PEPE" and U+202E before
    /// "· 10.5 MON" showed "NOM 5.01 ·". A line break (CR LF as one) is a space, or stays a line break in `multiline`
    /// text (a description); a tab is a space.
    ///
    /// Kept wherever they are (`joins`), since none of them changes direction and scripts and emoji need them: the
    /// zero-width non-joiner and joiner (Persian "می‌خواهم", Indic conjuncts, emoji sequences such as a family), the
    /// variation selectors (a red heart, CJK ideographic variants), the Mongolian free variation selectors, the combining
    /// grapheme joiner and the soft hyphen. A tag character (U+E0020–U+E007F) is kept only in an emoji tag sequence, which
    /// draws a subdivision flag (England's): right after U+1F3F4 WAVING BLACK FLAG, or after a tag kept in that sequence,
    /// until U+E007F CANCEL TAG ends it; at most `maxTags` of them, so nobody can pad text with thousands of invisible
    /// tags. Anywhere else a tag is removed. Text made only of these kept characters is empty: it would draw nothing.
    ///
    /// Single-line text (a name, a symbol, a place) with a right-to-left letter in it (`isRightToLeft`) comes back inside
    /// U+2068 FIRST STRONG ISOLATE … U+2069 POP DIRECTIONAL ISOLATE: its own letters still read right to left, and the
    /// numbers and words the app puts around it keep their order. Without the isolate, the symbol "אבג" drew the ticket's
    /// "Balance: 1.2K אבג · 10.5 MON" as "Balance: 1.2K 10.5 · גבא MON". A description (`multiline`) is never wrapped: it
    /// is shown on its own, as a paragraph that takes its direction from its first letter, which an isolate would hide.
    /// Nor is text with no right-to-left letter, so every ASCII name and symbol comes back exactly as cleaned, character
    /// for character: comparisons with curated symbols ("USDC"), `WalletHoldings.isPlain` and look-ups by symbol are
    /// unaffected. A letter disc takes its letters with `leading`, which skips the isolate.
    ///
    /// For showing only: a Moment's link slug, and anything hashed or compared, reads the chain's text as it is.
    static func shown(_ text: String, multiline: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        var previous: UInt32 = 0
        // The tags kept so far in the emoji tag sequence being read; nil outside one.
        var tags: Int?
        for scalar in text.unicodeScalars {
            let value = scalar.value
            defer { previous = value }
            if (0xE0020...0xE007F).contains(value) {
                if let kept = tags, kept < maxTags {
                    out.append(scalar)
                    tags = value == 0xE007F ? nil : kept + 1
                } else {
                    tags = nil
                }
                continue
            }
            tags = value == 0x1F3F4 ? 0 : nil
            if lineBreaks.contains(value) {
                if value == 0x0A, previous == 0x0D { continue }
                out.append(multiline ? "\n" : " ")
                continue
            }
            if value == 0x09 {
                out.append(" ")
                continue
            }
            if joins(value) {
                out.append(scalar)
                continue
            }
            let properties = scalar.properties
            switch properties.generalCategory {
            case .format, .control: continue
            default: break
            }
            if properties.isDefaultIgnorableCodePoint || Address.isInvisible(scalar) { continue }
            out.append(scalar)
        }
        // Text made only of the invisible characters kept above draws nothing: it is empty, as it was before they were
        // kept, so no name, symbol or place shows as a blank label.
        if out.allSatisfy({ joins($0.value) }) { return "" }
        guard !multiline, out.contains(where: isRightToLeft) else { return String(out) }
        return "\u{2068}" + String(out) + "\u{2069}"
    }

    /// The first `count` characters of `text` that draw, for a letter disc (a coin with no logo): a character made only of
    /// format characters (general category Cf), such as the isolate `shown` puts around right-to-left text, is skipped,
    /// so the symbol "אבג" shows "אב", not one letter. Text without such characters gives exactly `text.prefix(count)`.
    static func leading(_ text: String, _ count: Int) -> String {
        String(text.lazy.filter { !$0.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format } }.prefix(max(0, count)))
    }

    /// Whether `scalar` lies where Unicode's code points default to a strong right-to-left direction (bidi class R or AL
    /// in DerivedBidiClass, assigned or not): Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and their
    /// extensions (U+0590–U+08FF), the Hebrew and Arabic presentation forms (U+FB1D–U+FDFF, U+FE70–U+FEFE; U+FEFF, the
    /// byte-order mark, is removed anyway), and the right-to-left scripts of the supplementary planes (U+10800–U+10FFF,
    /// U+1E800–U+1EFFF). Swift exposes no bidi class, so these ranges stand in for it. The few code points in them that
    /// aren't letters (Arabic digits, marks) only mean that text with them is isolated too, which changes nothing.
    private static func isRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFE, 0x10800...0x10FFF, 0x1E800...0x1EFFF: return true
        default: return false
        }
    }

    /// The invisible characters `shown` keeps wherever they are: U+00AD soft hyphen, U+034F combining grapheme joiner,
    /// U+180B–U+180D and U+180F Mongolian free variation selectors, U+200C zero-width non-joiner, U+200D zero-width
    /// joiner, U+FE00–U+FE0F and U+E0100–U+E01EF variation selectors. None of them changes the order text shows in.
    private static func joins(_ value: UInt32) -> Bool {
        switch value {
        case 0x00AD, 0x034F, 0x180B...0x180D, 0x180F, 0x200C, 0x200D, 0xFE00...0xFE0F, 0xE0100...0xE01EF: return true
        default: return false
        }
    }

    /// The most tag characters `shown` keeps in one emoji tag sequence. A subdivision flag needs at most eight: a code of
    /// up to seven letters and digits (a region and a subdivision), then CANCEL TAG; England's takes six.
    internal static let maxTags = 16

    /// LF, VT, FF, CR, NEL, and the line and paragraph separators.
    private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
}
