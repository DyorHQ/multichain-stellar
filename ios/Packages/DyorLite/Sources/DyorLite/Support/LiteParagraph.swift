import SwiftUI

/// Text that, in Korean, moves to the next line only between words: the package's copy of the app's `Paragraph`
/// (DyorHQ `Design/Paragraph.swift`, DyorKit `WordWrap`), which the package can't import.
///
/// SwiftUI's `Text` on iOS breaks Hangul between any two syllables, so in Korean a paragraph is laid out word by word
/// (`LiteWordFlow`): each word a `Text` of its own, a word that doesn't fit moving to the next line whole. In every other
/// language, and wherever a line limit or a minimum scale applies, it is plain `Text`. It reads the environment as
/// `Text` does: font, weight, color, alignment and line spacing set around it apply to every word. The text is already
/// in the current language (`tr`), or a server's or user's own words, shown as they are.
struct LiteParagraph: View {
    private let text: String
    @Environment(\.locale) private var locale
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.minimumScaleFactor) private var minimumScaleFactor
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.lineSpacing) private var lineSpacing

    init(_ text: String) { self.text = text }

    /// The most characters laid out word by word; longer text is plain `Text`.
    static let wordByWordLimit = 2_000

    var body: some View {
        if LiteWordWrap.keepsWordsWhole(locale.language), lineLimit == nil, minimumScaleFactor >= 1,
           text.count <= Self.wordByWordLimit {
            LiteWordFlow(alignment: alignment, lineSpacing: lineSpacing) {
                // Two probes, never seen: their difference in width is one space in this font.
                Text(verbatim: "가 가").hidden()
                Text(verbatim: "가가").hidden()
                ForEach(Array(LiteWordWrap.lines(of: text).enumerated()), id: \.offset) { _, words in
                    // An empty line (between two paragraphs) keeps its height.
                    let line = words.isEmpty ? [" "] : words
                    ForEach(Array(line.enumerated()), id: \.offset) { index, word in
                        Text(verbatim: word).layoutValue(key: LiteStartsLine.self, value: index == 0)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: text))
            .accessibilityAddTraits(.isStaticText)
        } else {
            Text(verbatim: text)
        }
    }
}

/// For a label whose title is a `LiteParagraph`: in Korean the icon sits on the first line's baseline, where a label
/// puts it beside a `Text`. Every other language keeps the label's own style.
struct LiteParagraphLabel: ViewModifier {
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        if LiteWordWrap.keepsWordsWhole(locale.language) {
            content.labelStyle(FirstLineLabelStyle())
        } else {
            content
        }
    }

    private struct FirstLineLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// How a paragraph is cut into the words a Korean line moves between (DyorKit `WordWrap`).
enum LiteWordWrap {
    /// The languages whose paragraphs are laid out word by word: Korean.
    static func keepsWordsWhole(_ language: Locale.Language) -> Bool {
        language.languageCode == .korean
    }

    /// Names that stay on one line: Apple's, never split ("Face / ID").
    static let unbroken = ["Face ID", "Touch ID", "Optic ID"]

    /// `text` as lines, cut at its newlines, of words, cut at its spaces (U+0020). A no-break space joins two words into
    /// one, and so does the space in a name that stays whole. Spaces in a row, or at the start or end of a line, cut once
    /// and leave nothing behind. A line with no word is an empty array.
    static func lines(of text: String) -> [[String]] {
        let characters = Array(text)
        var kept = Set<Int>()
        for name in unbroken {
            let pattern = Array(name)
            guard pattern.count <= characters.count else { continue }
            for start in 0...(characters.count - pattern.count) where Array(characters[start..<start + pattern.count]) == pattern {
                for (offset, character) in pattern.enumerated() where character == " " { kept.insert(start + offset) }
            }
        }
        var lines: [[String]] = [[]]
        var word = ""
        func close() {
            if !word.isEmpty { lines[lines.count - 1].append(word) }
            word = ""
        }
        for (offset, character) in characters.enumerated() {
            if character == " ", !kept.contains(offset) {
                close()
            } else if character.isNewline {
                close()
                lines.append([])
            } else {
                word.append(character)
            }
        }
        close()
        return lines
    }
}

/// Whether a word starts a line of its own: the first word after a newline.
private struct LiteStartsLine: LayoutValueKey {
    static let defaultValue = false
}

/// Lays out words as `Text` lays out a paragraph, breaking only between words. The first two subviews are the probes
/// `LiteParagraph` measures a space with.
private struct LiteWordFlow: Layout {
    let alignment: TextAlignment
    let lineSpacing: CGFloat

    struct Placed {
        let index: Int
        let size: CGSize
        let baseline: CGFloat
        var x: CGFloat = 0
    }

    struct Line {
        var words: [Placed] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }

    private func lines(_ subviews: Subviews, width: CGFloat?) -> [Line] {
        guard subviews.count > 2 else { return [] }
        let space = max(0, subviews[0].sizeThatFits(.unspecified).width - subviews[1].sizeThatFits(.unspecified).width)
        let limit = width ?? .infinity
        var lines: [Line] = []
        var line = Line()
        for index in 2..<subviews.count {
            let subview = subviews[index]
            var proposal = ProposedViewSize.unspecified
            var size = subview.sizeThatFits(proposal)
            if size.width > limit {
                proposal = ProposedViewSize(width: limit, height: nil)
                size = subview.sizeThatFits(proposal)
            }
            let baseline = subview.dimensions(in: proposal)[VerticalAlignment.firstTextBaseline]
            let startsLine = subview[LiteStartsLine.self] && index > 2
            if !line.words.isEmpty, startsLine || line.width + space + size.width > limit {
                lines.append(line)
                line = Line()
            }
            var placed = Placed(index: index, size: size, baseline: baseline)
            placed.x = line.words.isEmpty ? 0 : line.width + space
            line.width = placed.x + size.width
            line.ascent = max(line.ascent, baseline)
            line.descent = max(line.descent, size.height - baseline)
            line.words.append(placed)
        }
        if !line.words.isEmpty { lines.append(line) }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                           cache: inout ()) -> CGFloat? {
        let lines = lines(subviews, width: bounds.width)
        guard let first = lines.first, let last = lines.last else { return nil }
        if guide == .firstTextBaseline { return bounds.minY + first.ascent }
        if guide == .lastTextBaseline {
            let above = lines.dropLast().map(\.height).reduce(0, +) + lineSpacing * CGFloat(lines.count - 1)
            return bounds.minY + above + last.ascent
        }
        return nil
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for probe in subviews.prefix(2) { probe.place(at: bounds.origin, proposal: .unspecified) }
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let spare = bounds.width - line.width
            let offset: CGFloat = switch alignment {
            case .leading: 0
            case .center: spare / 2
            case .trailing: spare
            }
            for word in line.words {
                let proposal = word.size.width > bounds.width ? ProposedViewSize(width: bounds.width, height: nil) : .unspecified
                subviews[word.index].place(at: CGPoint(x: bounds.minX + offset + word.x, y: y + line.ascent - word.baseline),
                                           proposal: proposal)
            }
            y += line.height + lineSpacing
        }
    }
}
