import XCTest
@testable import DyorKit

/// Which coin symbols show as what they are, and what the create forms refuse: Latin, Chinese, Japanese and Korean
/// symbols stay open to creators; look-alike alphabets, hidden characters and curated tokens' names don't.
final class SymbolSafetyTests: XCTestCase {
    func testLatinAndEastAsianSymbolsAreDisplaySafe() {
        for symbol in ["QT", "PEPE2", "0N1F", "狗狗", "강아지", "ドージ", "ひまわり", "狗2", "ㄱㄴ", "々木"] {
            XCTAssertTrue(SymbolSafety.isDisplaySafe(symbol), symbol)
        }
    }

    func testLookAlikesAndHiddenCharactersAreNot() {
        let unsafe = [
            "Q\u{0422}", // Cyrillic Т
            "Q\u{200B}T", // zero-width space
            "\u{202E}TQ", // right-to-left override
            "Q\u{2066}T\u{2069}", // isolates
            "\u{FF31}\u{FF34}", // full-width ＱＴ
            "\u{0391}\u{0392}", // Greek ΑΒ
            "QT\u{0301}", // a combining accent
            "\u{3164}", // the Hangul filler, a letter nobody sees
            "\u{1100}\u{1161}", // conjoining jamo, the same syllable drawn another way
            "\u{FF76}", // half-width katakana
            "\u{2F00}", // a Kangxi radical, drawn like 一
            "PEPE狗", // Latin and Han letters mixed
            "狗\u{FF12}", // a full-width digit
            "QT\u{0007}", // a control character
            "😀",
            "",
            "   ",
        ]
        for symbol in unsafe {
            XCTAssertFalse(SymbolSafety.isDisplaySafe(symbol), symbol.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }

    /// The create forms refuse a symbol or name that reads as a curated token's — "USDC", "Monad", "WM0N", "USDС" with a
    /// Cyrillic С — and a symbol that isn't display-safe; "QT" and "狗狗" go through.
    func testTheCreateGuard() {
        XCTAssertEqual(SymbolSafety.createRefusal(name: "My Coin", symbol: "USDC"), .symbolImitates(.usdc))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Monad", symbol: "MOND"), .nameImitates(.mon))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Coin", symbol: "Monad"), .symbolImitates(.mon))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Wrapped", symbol: "WM0N"), .symbolImitates(.wmon))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Dollar", symbol: "USD\u{0421}"), .symbolImitates(.usdc), "a Cyrillic С reads as USDC")
        XCTAssertEqual(SymbolSafety.createRefusal(name: "USDC", symbol: "DOLLAR"), .nameImitates(.usdc))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Quiet", symbol: "Q\u{0422}"), .symbolNotDisplaySafe)
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Quiet", symbol: "Q\u{200B}X"), .symbolNotDisplaySafe)
        XCTAssertNil(SymbolSafety.createRefusal(name: "Quet", symbol: "QT"))
        XCTAssertNil(SymbolSafety.createRefusal(name: "狗狗币", symbol: "狗狗"))
        XCTAssertNil(SymbolSafety.createRefusal(name: "강아지 코인", symbol: "강아지"))
        XCTAssertNil(SymbolSafety.createRefusal(name: "", symbol: ""), "an empty field is the form's own check")
        XCTAssertTrue(SymbolSafety.CreateRefusal.symbolNotDisplaySafe.isAboutSymbol)
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameImitates(.mon).isAboutSymbol)
        XCTAssertEqual(SymbolSafety.CreateRefusal.symbolImitates(.usdc).message, "This symbol looks like USDC, a token DyorHQ already lists. Choose another symbol.")
        // A name with hidden characters, or Latin letters mixed with Cyrillic or Greek look-alikes.
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Do\u{200B}ge", symbol: "DOGE"), .nameHasHiddenCharacters)
        XCTAssertEqual(SymbolSafety.createRefusal(name: "D\u{043E}ge", symbol: "DOGE"), .nameMixesAlphabets, "a Cyrillic о")
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Quiet", symbol: "Q\u{0422}"), .symbolNotDisplaySafe, "the symbol is said first")
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameHasHiddenCharacters.isAboutSymbol)
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameMixesAlphabets.isAboutSymbol)
        XCTAssertNil(SymbolSafety.createRefusal(name: "ドージコイン", symbol: "ドージ"))
        XCTAssertNil(SymbolSafety.createRefusal(name: "Café Niño 🐶", symbol: "CAFE"))
    }

    /// Names may be written in any language, with accents and emoji; what doesn't show as itself is refused.
    func testNamesWithHiddenCharacters() {
        let fine = ["Quet", "狗狗币", "강아지 코인", "ドージコイン", "Café Crème", "Niño", "Доге", "Αθηνά", "Doge 🐶", "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} Family",
                    "\u{2764}\u{FE0F} Love", "1\u{FE0F}\u{20E3} One", "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} Lions", "Cafe\u{0301}", "Dog\u{00A0}Coin", ""]
        for name in fine { XCTAssertFalse(SymbolSafety.hasHiddenCharacters(name), name) }
        let hidden = [
            "Do\u{200B}ge", // zero-width space
            "\u{202E}egoD", // right-to-left override
            "Do\u{2066}ge\u{2069}", // an isolate
            "Doge\u{0007}", // a control character
            "Doge\u{2028}Coin", // a line separator
            "Do\u{2060}ge", // word joiner
            "Doge\u{E000}", // private use
            "A\u{200D}B", // a joiner between letters
            "Do\u{00AD}ge", // soft hyphen
            "\u{3164}", // the Hangul filler
            "Doge\u{FE0F}", // a variation selector on a letter
        ]
        for name in hidden {
            XCTAssertTrue(SymbolSafety.hasHiddenCharacters(name), name.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }

    /// Latin letters mixed with Cyrillic or Greek ones are refused in a name; one alphabet alone, or any other mix, is not.
    func testNamesMixingLookAlikeAlphabets() {
        for name in ["D\u{043E}ge", "P\u{0430}yday", "\u{0391}lpha", "Mo\u{03BD}e", "\u{FF24}\u{043E}ge"] {
            XCTAssertTrue(SymbolSafety.mixesLookAlikeAlphabets(name), name)
        }
        for name in ["Doge", "Доге", "Αθηνά", "狗狗 Doge", "강아지 Coin", "Café", "Doge 2", "μ", ""] {
            XCTAssertFalse(SymbolSafety.mixesLookAlikeAlphabets(name), name)
        }
    }
}
