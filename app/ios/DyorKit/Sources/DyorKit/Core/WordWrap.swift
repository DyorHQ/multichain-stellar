import Foundation

/// How a paragraph is cut into the words a Korean line moves between.
///
/// Korean is written with spaces between words and a line breaks only there. SwiftUI's `Text` on iOS breaks Hangul
/// between any two syllables instead ("도착 / 하지"), whatever the typesetting language or the device's, and no joiner
/// or paragraph style stops it (UIKit's labels keep Korean words whole with `NSLineBreakStrategy.hangulWordPriority`;
/// SwiftUI's text has no such setting). The app's `Paragraph` therefore lays a Korean paragraph out word by word, from
/// the words this finds.
public enum WordWrap {
    /// The languages whose paragraphs are laid out word by word: Korean.
    public static func keepsWordsWhole(_ language: Locale.Language) -> Bool {
        language.languageCode == .korean
    }

    /// Names that stay on one line: Apple's, never split ("Face / ID").
    static let unbroken = ["Face ID", "Touch ID", "Optic ID"]

    /// Two translated sentences as one paragraph: a space between them, as most languages write it, but none after a
    /// full-width stop ("。", "？"), where Chinese puts none; with one, a line can start with the stop. Either one empty
    /// leaves the other as it is.
    public static func sentences(_ first: String, _ second: String) -> String {
        guard let last = first.last, !second.isEmpty else { return first + second }
        return first + (fullWidthStops.contains(last) ? "" : " ") + second
    }

    /// Any number of translated sentences as one paragraph, in order, each joined to the text before it as
    /// `sentences(_:_:)` joins two.
    public static func sentences(_ parts: [String]) -> String {
        parts.reduce("") { sentences($0, $1) }
    }

    /// The full-width punctuation a Chinese sentence or clause ends with.
    static let fullWidthStops: Set<Character> = ["。", "！", "？", "；", "：", "）", "」", "』", "】"]

    /// `text` as lines, cut at its newlines, of words, cut at its spaces (U+0020). A word keeps its attributes (a bold
    /// or linked word stays so) and anything else that isn't a space or a newline: a no-break space joins two words
    /// into one, as it does in `Text`, and so does the space in a name that stays whole (`unbroken`). Spaces in a row,
    /// or at the start or end of a line, cut once and leave nothing behind. A line with no word, such as the empty line
    /// between two paragraphs, is an empty array.
    public static func lines(of text: AttributedString) -> [[AttributedString]] {
        let characters = Array(text.characters)
        var indices: [AttributedString.Index] = []
        indices.reserveCapacity(characters.count + 1)
        var index = text.startIndex
        while index < text.endIndex {
            indices.append(index)
            index = text.characters.index(after: index)
        }
        indices.append(text.endIndex)

        // The spaces inside a name that stays whole.
        var kept = Set<Int>()
        for name in unbroken {
            let pattern = Array(name)
            guard pattern.count <= characters.count else { continue }
            for start in 0...(characters.count - pattern.count) where Array(characters[start..<start + pattern.count]) == pattern {
                for (offset, character) in pattern.enumerated() where character == " " { kept.insert(start + offset) }
            }
        }

        var lines: [[AttributedString]] = [[]]
        var start: Int? = nil
        func close(at end: Int) {
            if let begin = start, begin < end { lines[lines.count - 1].append(AttributedString(text[indices[begin]..<indices[end]])) }
            start = nil
        }
        for (offset, character) in characters.enumerated() {
            if character == " ", !kept.contains(offset) {
                close(at: offset)
            } else if character.isNewline {
                close(at: offset)
                lines.append([])
            } else if start == nil {
                start = offset
            }
        }
        close(at: characters.count)
        return lines
    }

    /// `lines(of:)` for plain text.
    public static func lines(of text: String) -> [[String]] {
        lines(of: AttributedString(text)).map { $0.map { String($0.characters) } }
    }
}
