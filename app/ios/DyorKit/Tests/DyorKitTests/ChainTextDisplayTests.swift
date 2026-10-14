import BigInt
import XCTest
@testable import DyorKit

/// Creator text as the app shows it (`ChainText.shown`): no character that changes direction or hides can reach the
/// screen, emoji and every script still draw, and nothing that is hashed, compared or made into a Moment's link slug
/// changes (`ChainTextBidiTests` lays the result out with CoreText).
final class ChainTextDisplayTests: XCTestCase {
    /// The 13 coins DyorHQ lists on mainnet today (read 2026-09-30): the six named Moments of cohorts 1–3 (cohort 4 has
    /// none yet) and the seven launches of the retired launchpads (the v2 launchpad has none yet).
    static let liveMomentNames = ["Spectacular", "Bitcoin Diva", "0N1 Force NFT", "0N1 Force", "RWA", "Nature"]
    static let liveLaunchNames = ["Laptop", "Good Morning", "Pons", "Quet", "Justice", "Binance Boy", "Baby Pons"]

    func testDirectionAndInvisibleCharactersAreRemoved() {
        let removed: [UInt32] = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C, // direction
                                 0x200B, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x206A, 0x206F, 0xFEFF, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x180E, // invisible
                                 0xE0001, 0xE0020, 0xE0067, 0xE007F, // tags outside an emoji tag sequence
                                 0x00, 0x07, 0x1B, 0x7F, 0x9B] // control
        for value in removed {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(ChainText.shown("PE\(Character(scalar))PE"), "PEPE", String(format: "U+%04X", value))
        }
        XCTAssertEqual(ChainText.shown("PEPE\u{202E} · 10.5 MON"), "PEPE · 10.5 MON")
        XCTAssertEqual(ChainText.shown("\u{2067}\u{202B}Pepe\u{202C}\u{2069}"), "Pepe")
    }

    func testLineBreaksAreSpacesExceptInADescription() {
        XCTAssertEqual(ChainText.shown("Pepe\nCoin"), "Pepe Coin")
        XCTAssertEqual(ChainText.shown("Pepe\r\nCoin\tX"), "Pepe Coin X")
        XCTAssertEqual(ChainText.shown("Pepe\u{2029}Coin"), "Pepe Coin")
        XCTAssertEqual(ChainText.shown("First line\r\nSecond\u{2028}Third\n\nFourth", multiline: true), "First line\nSecond\nThird\n\nFourth")
    }

    func testEmojiAccentsAndEveryScriptStillShow() {
        for text in ["👨‍👩‍👧 Family", "❤️ Love", "❤️‍🔥", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "1️⃣", "👍🏽", "Café", "Cafe\u{0301}", "日本語", "Ελληνικά", "Кириллица", "\u{FFFD}", "A\u{FFFD}Z", "$PEPE · 1.5%"] {
            XCTAssertEqual(ChainText.shown(text), text, text)
        }
        // Right-to-left text keeps every letter, inside an isolate (`testRightToLeftTextIsIsolatedOnceAndOnlyOnOneLine`).
        for text in ["שלום", "مرحبا"] {
            XCTAssertEqual(ChainText.shown(text), "\u{2068}\(text)\u{2069}", text)
        }
    }

    /// The joiners and selectors scripts and emoji need stay wherever they are, since none changes direction: Persian's
    /// zero-width non-joiner, an Indic conjunct's joiner, a CJK ideographic variation selector, emoji sequences, the
    /// Mongolian free variation selectors, the grapheme joiner and the soft hyphen. They used to be removed anywhere but
    /// right after an emoji, which broke "می‌خواهم", "क्‍ष" and "葛󠄀".
    func testJoinersAndSelectorsStayWhereverTheyAre() {
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}" // می‌خواهم
        XCTAssertEqual(ChainText.shown(persian, multiline: true), persian)
        XCTAssertEqual(ChainText.shown(persian), "\u{2068}\(persian)\u{2069}", "kept, inside the isolate of right-to-left text")
        for text in ["\u{0915}\u{094D}\u{200D}\u{0937}", "\u{845B}\u{E0100}", "👨‍👩‍👧", "❤️", "❤️‍🔥", "🏴󠁧󠁢󠁥󠁮󠁧󠁿", "🏴󠁧󠁢󠁥󠁮󠁧󠁿🏴󠁧󠁢󠁳󠁣󠁴󠁿",
                     "\u{1820}\u{180B}", "\u{1820}\u{180F}", "A\u{034F}B", "Co\u{00AD}in", "A\u{200D}B\u{FE0F}C", "#\u{200D}", "1\u{FE0F}\u{20E3}"] {
            XCTAssertEqual(ChainText.shown(text), text, text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
        }
    }

    /// Text made only of the invisible characters `shown` keeps draws nothing, so it is empty, as it was before they were
    /// kept: a place of one zero-width joiner hides its pin label rather than showing it blank.
    func testTextOfOnlyKeptInvisiblesIsEmpty() {
        for text in ["\u{200D}", "\u{200C}\u{200D}", "\u{FE0F}", "\u{00AD}\u{034F}", "\u{180B}", "\u{E0100}", "\u{202E}\u{200D}", "\u{E0061}\u{200D}"] {
            XCTAssertEqual(ChainText.shown(text), "", text.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
            XCTAssertEqual(ChainText.shown(text, multiline: true), "")
        }
        XCTAssertEqual(ChainText.shown("A\u{200D}"), "A\u{200D}", "kept beside anything that draws")
        XCTAssertEqual(ChainText.shown(" "), " ", "a space is as it was")
    }

    /// Tag characters stay only in an emoji tag sequence (a subdivision flag: U+1F3F4, the tags, CANCEL TAG), and at most
    /// `ChainText.maxTags` of them; after anything else, however many, they are removed, so none can pad a name.
    func testTagsStayOnlyInAFlagAndOnlyAFew() {
        let tags = String(repeating: "\u{E0061}", count: 1000)
        XCTAssertEqual(ChainText.shown("1" + tags), "1")
        XCTAssertEqual(ChainText.shown("#" + tags), "#")
        XCTAssertEqual(ChainText.shown("1\u{FE0F}" + tags), "1\u{FE0F}")
        XCTAssertEqual(ChainText.shown("😀" + tags + "X"), "😀X")
        XCTAssertEqual(ChainText.shown("PE" + tags + "PE"), "PEPE")
        let flag = "🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
        XCTAssertEqual(ChainText.shown(flag + "\u{E0061}X"), flag + "X", "CANCEL TAG ends the sequence")
        XCTAssertEqual(ChainText.shown("🏴\u{200B}\u{E0067}\u{E0062}"), "🏴", "only right after the flag")
        XCTAssertEqual(ChainText.shown("🏴" + tags), "🏴" + String(repeating: "\u{E0061}", count: ChainText.maxTags))
        XCTAssertEqual(ChainText.maxTags, 16)
    }

    /// Single-line text with a right-to-left letter comes back inside one isolate (U+2068 … U+2069), however often it is
    /// shown; a description never, and text with no right-to-left letter never: every ASCII name and symbol, and every
    /// name DyorHQ lists today, stays exactly as it is.
    func testRightToLeftTextIsIsolatedOnceAndOnlyOnOneLine() {
        for text in ["PEPE", "USDC", "Pepe Coin", "$PEPE · 1.5%", "0N1 Force NFT", "日本語", "Ελληνικά", "Café", "\u{FFFD}", ""] + Self.liveMomentNames + Self.liveLaunchNames {
            XCTAssertEqual(ChainText.shown(text), text, text)
            XCTAssertEqual(ChainText.shown(text, multiline: true), text, text)
        }
        // Hebrew, Arabic, an Arabic letter before a digit, mixed with Latin, Phoenician and Adlam (supplementary planes).
        for text in ["אבג", "مرحبا", "ب1", "Pepe שלום", "שלום עולם", "\u{10900}\u{10901}", "\u{1E900}", "\u{FB1D}", "\u{FEFC}"] {
            let shown = ChainText.shown(text)
            XCTAssertEqual(shown, "\u{2068}\(text)\u{2069}", text)
            XCTAssertEqual(ChainText.shown(shown), shown, "shown again, still one isolate: \(text)")
        }
        XCTAssertEqual(ChainText.shown("\u{202E}אבג\u{2069}\u{2069}"), "\u{2068}אבג\u{2069}", "the creator's own direction characters are removed first")
        XCTAssertEqual(ChainText.shown("שלום\u{2029}עולם", multiline: true), "שלום\nעולם", "a description is never isolated")
        XCTAssertEqual(ChainText.shown("Hello\nשלום", multiline: true), "Hello\nשלום")
    }

    /// A letter disc's letters (`ChainText.leading`): the isolate around right-to-left text is skipped, and any other
    /// symbol gives exactly the letters `prefix` gave.
    func testLeadingSkipsTheIsolate() {
        for symbol in ["PEPE", "P", "", "USDC", "$PEPE", "1️⃣A", "👨‍👩‍👧X", "日本語", "Café"] + Self.liveMomentNames + Self.liveLaunchNames {
            XCTAssertEqual(ChainText.leading(symbol, 2), String(symbol.prefix(2)), symbol)
            XCTAssertEqual(ChainText.leading(ChainText.shown(symbol), 2), String(symbol.prefix(2)), symbol)
        }
        XCTAssertEqual(ChainText.leading(ChainText.shown("אבג"), 2), "אב")
        XCTAssertEqual(ChainText.leading(ChainText.shown("ب1"), 2), "ب1")
        XCTAssertEqual(ChainText.leading(ChainText.shown("א"), 2), "א")
        XCTAssertEqual(ChainText.leading("PEPE", 0), "")
        XCTAssertEqual(ChainText.leading("PEPE", -1), "")
    }

    /// No name DyorHQ lists today changes as it shows, so no screen and no link slug changes with this: the six named
    /// Moments keep the slugs their links have always had.
    func testNoLiveCoinChangesAndNoSlugMoves() {
        for name in Self.liveMomentNames + Self.liveLaunchNames {
            XCTAssertEqual(ChainText.shown(name), name)
            XCTAssertEqual(MomentSlug.base(ChainText.shown(name)), MomentSlug.base(name))
        }
        let cohorts: [MomentLink.Cohort] = [.c1, .c1, .c1, .c2, .c2, .c3]
        let ids = [1, 2, 3, 1, 2, 1]
        let keys = zip(cohorts, ids).map { MomentKey(factory: $0.factory, id: BigUInt($1)) }
        let slugs = MomentSlug.assign(zip(keys, Self.liveMomentNames).map { (key: $0, name: $1) })
        XCTAssertEqual(keys.map { slugs[$0] }, ["spectacular", "bitcoin-diva", "0n1-force-nft", "0n1-force", "rwa", "nature"])
    }

    /// A Moment's name shows without its direction characters, while its link slug is still made from the name as the
    /// chain has it: "Bit" U+202E "coin" keeps `bit-coin`, and a later plain "Bitcoin" keeps `bitcoin`.
    func testNamesShowCleanedButSlugsReadTheChainsText() async throws {
        let stack = FakeMomentsStack(addresses: .monadMainnet, policy: V2Fixture.policy(), factoryBase: MomentsAddresses.expectedExternalBaseURI,
                                     nftBase: MomentsAddresses.expectedExternalBaseURI, names: ["Bit\u{202E}coin", "Bitcoin"])
        MomentsChainStub.install { to, data in
            if to == stack.nft(1), data.prefix(4) == ABI.selector(MomentsABI.NFT.provenance) {
                return try! ABI.encode([.tuple([.string("ipfs://x\u{202E}"), .bytes(Data(count: 32)), .string("Accra\u{202E}\n"), .uint(0), .string("")])], MomentsABI.provenanceTuple)
            }
            return stack.answer(to, data)
        }
        let service = MomentsService(rpc: MomentsChainStub.rpc(), addresses: stack.addresses)
        let listed = try await service.moments()
        XCTAssertEqual(listed.map(\.name), ["Bitcoin", "Bitcoin"])
        XCTAssertEqual(listed.last?.provenance.place, "Accra ")
        XCTAssertEqual(listed.last?.provenance.mediaURI, "ipfs://x\u{202E}", "a link is kept as read: it is only opened")
        let directory = MomentDirectory(rpc: MomentsChainStub.rpc(), cohorts: [.c4])
        let first = try await directory.link(for: MomentKey(factory: stack.addresses.factory, id: 1))
        let second = try await directory.link(for: MomentKey(factory: stack.addresses.factory, id: 2))
        XCTAssertEqual(first, MomentLink(name: "bit-coin"))
        XCTAssertEqual(second, MomentLink(name: "bitcoin"))
    }
}
