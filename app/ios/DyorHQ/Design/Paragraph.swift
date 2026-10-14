import DyorKit
import SwiftUI

/// Text that, in Korean, moves to the next line only between words.
///
/// Korean is written with spaces between words and breaks a line only there, but SwiftUI's `Text` on iOS breaks Hangul
/// between any two syllables ("도착 / 하지"), and no joiner, paragraph style or typesetting language stops it
/// (`WordWrap`). In Korean a paragraph is therefore laid out word by word (`WordFlow`): each word a `Text` of its own on
/// one line, a word that doesn't fit moving to the next line whole. In every other language, and wherever a line limit
/// or a minimum scale applies, it is the `Text` it always was.
///
/// It reads the environment as `Text` does: font, weight, color, alignment and line spacing set around it apply to
/// every word. Markdown in a catalog key is drawn as `Text` draws it, bold or linked words included.
struct Paragraph: View {
    private enum Content {
        case localized(LocalizedStringResource)
        case verbatim(String)
    }

    private let content: Content
    @Environment(\.locale) private var locale
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.minimumScaleFactor) private var minimumScaleFactor
    @Environment(\.multilineTextAlignment) private var alignment
    @Environment(\.lineSpacing) private var lineSpacing

    /// A catalog key, as `Text("…")` takes one, in the app's language (`tr()`).
    init(_ resource: LocalizedStringResource) { content = .localized(resource) }

    /// Text shown as it is, as `Text(verbatim:)`.
    init(verbatim text: String) { content = .verbatim(text) }

    /// Text shown as it is, as `Text(someString)`.
    @_disfavoredOverload
    init<S: StringProtocol>(_ text: S) { content = .verbatim(String(text)) }

    /// The text, its markdown drawn as `Text` draws a key's.
    private var text: AttributedString {
        switch content {
        case .localized(let resource):
            let string = tr(resource)
            return (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
        case .verbatim(let string):
            return AttributedString(string)
        }
    }

    /// The most characters laid out word by word: a creator's text can run to tens of thousands, which as one view per
    /// word would be thousands of views. Longer text is the `Text` it always was.
    static let wordByWordLimit = 2_000

    var body: some View {
        let text = self.text
        if WordWrap.keepsWordsWhole(locale.language), lineLimit == nil, minimumScaleFactor >= 1,
           text.characters.count <= Self.wordByWordLimit {
            WordFlow(alignment: alignment, lineSpacing: lineSpacing) {
                // Two probes, never seen: their difference in width is one space in this font.
                Text(verbatim: "가 가").hidden()
                Text(verbatim: "가가").hidden()
                ForEach(Array(WordWrap.lines(of: text).enumerated()), id: \.offset) { _, words in
                    // An empty line (between two paragraphs) keeps its height.
                    let line = words.isEmpty ? [AttributedString(" ")] : words
                    ForEach(Array(line.enumerated()), id: \.offset) { index, word in
                        Text(word).layoutValue(key: StartsLine.self, value: index == 0)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(text))
            .accessibilityAddTraits(.isStaticText)
        } else {
            Text(text)
        }
    }
}

/// For a label whose title is a `Paragraph`. A label puts its icon on a `Text` title's first line, but centers it on any
/// other view, such as a Korean `Paragraph`'s lines: in Korean the icon sits on the first line's baseline instead, where
/// a label puts it beside a `Text`. Every other language keeps the label's own style.
struct ParagraphLabel: ViewModifier {
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        if WordWrap.keepsWordsWhole(locale.language) {
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

/// Whether a word starts a line of its own: the first word after a newline.
private struct StartsLine: LayoutValueKey {
    static let defaultValue = false
}

/// Lays out words as `Text` lays out a paragraph, breaking only between words: each word on one line, a word that
/// doesn't fit the width moving to the next line whole (one wider than a whole line gets the line to itself and wraps
/// inside), the words of a line sitting on one baseline, and the lines aligned and spaced as `Text`'s. The first two
/// subviews are the probes `Paragraph` measures a space with.
private struct WordFlow: Layout {
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
            let startsLine = subview[StartsLine.self] && index > 2
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

    /// The first and last lines' baselines, as `Text` gives them: a label's icon, or a row aligned on text baselines,
    /// lines up with the paragraph's first (or last) line.
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
