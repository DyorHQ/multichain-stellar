import Foundation
import XCTest
@testable import DyorKit

/// The words a Korean paragraph moves to the next line between (`WordWrap`), and when a paragraph is laid out by them.
final class WordWrapTests: XCTestCase {
    func testOnlyKoreanIsLaidOutWordByWord() {
        XCTAssertTrue(WordWrap.keepsWordsWhole(Locale.Language(identifier: "ko")))
        XCTAssertTrue(WordWrap.keepsWordsWhole(Locale.Language(identifier: "ko-KR")))
        for other in ["en", "es", "fr", "zh-Hans", "ja"] {
            XCTAssertFalse(WordWrap.keepsWordsWhole(Locale.Language(identifier: other)), other)
        }
    }

    func testWordsAreCutAtSpacesAndLinesAtNewlines() {
        XCTAssertEqual(WordWrap.lines(of: "알림은 DyorHQ가 열려 있을 때 도착해요."), [["알림은", "DyorHQ가", "열려", "있을", "때", "도착해요."]])
        XCTAssertEqual(WordWrap.lines(of: "첫 줄\n둘째 줄"), [["첫", "줄"], ["둘째", "줄"]])
        XCTAssertEqual(WordWrap.lines(of: "문단 하나\n\n문단 둘"), [["문단", "하나"], [], ["문단", "둘"]], "the empty line between paragraphs stays")
        XCTAssertEqual(WordWrap.lines(of: "  앞뒤   공백  "), [["앞뒤", "공백"]], "spaces in a row cut once")
        XCTAssertEqual(WordWrap.lines(of: "80%\u{00A0}이상"), [["80%\u{00A0}이상"]], "a no-break space joins")
        XCTAssertEqual(WordWrap.lines(of: ""), [[]])
        XCTAssertEqual(WordWrap.lines(of: "끝\n"), [["끝"], []])
    }

    /// Apple's names stay on one line: the space in "Face ID" never cuts.
    func testApplesNamesStayWhole() {
        XCTAssertEqual(WordWrap.lines(of: "앱 잠금을 끄기 전에 Face ID(또는 기기 암호)를 요구합니다."),
                       [["앱", "잠금을", "끄기", "전에", "Face ID(또는", "기기", "암호)를", "요구합니다."]])
        XCTAssertEqual(WordWrap.lines(of: "Face ID 또는 Touch ID로 로그인해요."), [["Face ID", "또는", "Touch ID로", "로그인해요."]])
        XCTAssertEqual(WordWrap.lines(of: "Optic ID"), [["Optic ID"]])
        XCTAssertEqual(WordWrap.lines(of: "Face IDs"), [["Face IDs"]], "the name's space, wherever it stands")
        XCTAssertEqual(WordWrap.lines(of: "Face  ID"), [["Face", "ID"]], "two spaces are not the name")
    }

    /// Two sentences join with a space, but none after a Chinese full stop: "。 " let a line start with "。".
    func testSentencesJoinAsTheLanguageWritesThem() {
        XCTAssertEqual(WordWrap.sentences("Fees are paid.", "These come from curve trades only."), "Fees are paid. These come from curve trades only.")
        XCTAssertEqual(WordWrap.sentences("이 수수료는 지급돼요.", "커브 거래에서만 발생해요."), "이 수수료는 지급돼요. 커브 거래에서만 발생해요.")
        XCTAssertEqual(WordWrap.sentences("Frais versés\u{202F};", "il suffit"), "Frais versés\u{202F}; il suffit", "a French semicolon keeps its space")
        XCTAssertEqual(WordWrap.sentences("这些款项。", "这些仅来自曲线交易。"), "这些款项。这些仅来自曲线交易。")
        XCTAssertEqual(WordWrap.sentences("等待领取；", "一次领取"), "等待领取；一次领取")
        XCTAssertEqual(WordWrap.sentences("Paid straight.", ""), "Paid straight.", "nothing to add, no space")
        XCTAssertEqual(WordWrap.sentences("", "Only this."), "Only this.")
        // Any number of them, in order: the Perps order sheet's warnings.
        XCTAssertEqual(WordWrap.sentences(["Position opened.", "Order status unknown.", "Check Open Orders."]),
                       "Position opened. Order status unknown. Check Open Orders.")
        XCTAssertEqual(WordWrap.sentences(["已开仓。", "订单状态未知。"]), "已开仓。订单状态未知。")
        XCTAssertEqual(WordWrap.sentences(["Sent.", "", "Check."]), "Sent. Check.", "an empty one adds nothing")
        XCTAssertEqual(WordWrap.sentences(["Only this."]), "Only this.")
        XCTAssertEqual(WordWrap.sentences([]), "")
    }

    /// The app joins two translated sentences with `WordWrap.sentences`, never with a plain space: `" " + tr(…)` puts a
    /// space after a Chinese "。", and a line can then start with "。".
    func testTheAppNeverJoinsTranslatedSentencesWithAPlainSpace() throws {
        var found: [String] = []
        for (path, text) in try FormattedTextIsolationTests.appSources() {
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains("\" \" + tr(") {
                found.append("\(path):\(index + 1)")
            }
        }
        XCTAssertEqual(found, [], "join translated sentences with WordWrap.sentences")
    }

    /// A word keeps its attributes: a bold or linked word stays so, and the words read back as the text.
    func testWordsKeepTheirAttributes() throws {
        let text = try AttributedString(markdown: "**중요:** [자세히 보기](https://dyorhq.fun) 확인", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let lines = WordWrap.lines(of: text)
        XCTAssertEqual(lines.count, 1)
        let words = lines[0]
        XCTAssertEqual(words.map { String($0.characters) }, ["중요:", "자세히", "보기", "확인"])
        XCTAssertEqual(words[0].runs.first?.inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertEqual(words[1].runs.first?.link, URL(string: "https://dyorhq.fun"))
        XCTAssertEqual(words[2].runs.first?.link, URL(string: "https://dyorhq.fun"))
        XCTAssertNil(words[3].runs.first?.link)
    }
}
