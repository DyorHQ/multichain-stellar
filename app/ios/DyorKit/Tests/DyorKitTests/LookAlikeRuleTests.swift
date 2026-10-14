import XCTest
@testable import DyorKit

/// The look-alike rule (`WalletHoldings.imitated(by:)`), display safety and the create guard (`SymbolSafety`): what reads
/// as a curated or widely traded token, what shows as itself, and what the create forms refuse. The badge and the icon
/// go by the same rule (`DyorCoinBadgeTests`).
final class LookAlikeRuleTests: XCTestCase {
    private let address = Address(literal: "0x00000000000000000000000000000000000c0ffe")

    private func token(_ symbol: String, _ name: String = "Some Coin") -> Token {
        Token(address: address, symbol: symbol, name: name, decimals: 18)
    }

    private func label(_ text: String) -> String { text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ") }

    /// Symbols and names that are imitations, with what they imitate (shared with `DyorCoinBadgeTests`).
    static let imitatingSymbols: [(String, Token)] = [
        ("M0n", .mon), ("m0n", .mon), ("wm0n", .wmon), ("Wm0N", .wmon), ("M0NAD", .mon), ("usdto", Token.core.first { $0.symbol == "USDT0" }!),
        ("USDC.e", .usdc), ("USDC'", .usdc), ("USDC`", .usdc), ("$MON", .mon), ("MON2", .mon), ("USDC" + String(repeating: " ", count: 40) + ".", .usdc),
        ("USDC e", .usdc), ("USDC E", .usdc), ("USDC  e", .usdc), ("x MON", .mon),
        ("\u{A4F4}\u{A4E2}\u{A4D3}\u{A4DA}", .usdc), ("\u{A4DF}\u{A4F3}\u{A4E0}", .mon), ("USD\u{0106}", .usdc), ("USD\u{03F9}", .usdc), ("USD\u{13DF}", .usdc),
        // A stroke, bar or hook on a Latin letter (a letter of its own, which accent folding leaves alone).
        ("M\u{00D8}N", .mon), ("WM\u{00D8}N", .wmon), ("US\u{0110}C", .usdc), ("\u{0244}SDC", .usdc), ("M\u{019F}N", .mon), ("USD\u{0166}0", curated("USDT0")),
        ("USD\u{023B}", .usdc), ("USD\u{0187}", .usdc), ("\u{0141}BTC", curated("LBTC")), ("\u{0110}AI", major("DAI")), ("\u{00D0}AI", major("DAI")), ("\u{018A}AI", major("DAI")),
        ("ET\u{0126}", major("ETH")), ("\u{0246}TH", major("ETH")), ("\u{0243}TC", major("BTC")), ("\u{0181}TC", major("BTC")),
        // What ASCII writes in a letter's place.
        ("U$DC", .usdc), ("U$DT0", curated("USDT0")), ("rnUSD", curated("mUSD")), ("WrnON", .wmon), ("VVMON", .wmon),
    ]
    static func curated(_ symbol: String) -> Token { Token.core.first { $0.symbol == symbol }! }
    static func major(_ symbol: String) -> Token { WalletHoldings.majorTokens.first { $0.symbol == symbol }! }
    static let majorSymbols = ["USDT", "ETH", "BTC", "SOL", "DAI", "BNB"]
    static let imitatingNames: [(String, Token)] = [
        ("M0nad", .mon), ("\u{13B7}\u{13BE}NAD", .mon), ("M\u{0585}nad", .mon), ("M\u{1D0F}nad", .mon), ("\u{A4DF}\u{A4F3}\u{A4E0}", .mon),
        ("\u{A4F4}\u{A4E2}\u{A4D3}\u{A4DA}", .usdc), ("$MON", .mon), ("USDC 2", .usdc),
        ("M\u{00F8}nad", .mon), ("Bitc\u{00F8}in", major("BTC")), ("M\u{019F}NAD", .mon), ("Wrapped M\u{00D8}N", .wmon), ("\u{0246}thereum", major("ETH")),
        ("USD\u{0166}0", curated("USDT0")), ("\u{1D0D}\u{1D0F}\u{0274}\u{1D00}\u{1D05}", .mon), ("\u{0299}\u{026A}\u{1D1B}\u{1D04}\u{1D0F}\u{026A}\u{0274}", major("BTC")),
        // Letters of scripts beyond the six first covered: Myanmar ဝ, Hebrew ס, Tifinagh ⵔ, Canadian syllabics ᑌ.
        ("M\u{101D}nad", .mon), ("M\u{05E1}nad", .mon), ("S\u{2D54}lana", major("SOL")), ("Tether \u{144C}SD", major("USDT")), ("B1tcoin", major("BTC")),
    ]
    static let ownSymbols = ["USDL", "PEPE", "MONKE", "DOGE", "CAFÉ", "xMON", "BTCD", "0N1", "0N1F", "GMGM", "ETHX", "SOLAR", "DAISY", "\u{00D0}OGE", "\u{00D8}RE", "CORN", "BURN", "VVIP"]
    static let ownNames = ["Pepe Coin", "\u{03A9}mega", "\u{03BC}Swap", "\u{03C0}DAO", "Russian \u{0420}\u{0443}\u{0431}\u{043B}\u{044C}", "Monad Frogs", "Pepe on MON",
                           "Bitcoin Diva", "Good Morning", "\u{0394}Neutral", "Lambda \u{03BB}", "Pepe \u{041F}\u{0435}\u{043F}\u{0435}"]

    // MARK: Look-alikes (F4)

    /// Each of these is an imitation, as a symbol or a name: the wallet marks it, and the create forms refuse it.
    func testLookAlikesAreImitations() {
        for (symbol, expect) in Self.imitatingSymbols {
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), expect, "\(symbol) \(label(symbol))")
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), .symbolImitates(expect), symbol)
        }
        for symbol in Self.majorSymbols {
            let major = WalletHoldings.majorTokens.first { $0.symbol == symbol }!
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), major, symbol)
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Coin", symbol: symbol), .symbolImitates(major), symbol)
            XCTAssertTrue(SymbolSafety.CreateRefusal.symbolImitates(major).message.contains("widely traded"), symbol)
            XCTAssertNil(Token.core(major.address), "a placeholder address, never a curated one")
        }
        for (name, expect) in Self.imitatingNames {
            XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", name)), expect, "\(name) \(label(name))")
            XCTAssertEqual(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), .nameImitates(expect), name)
        }
        for name in ["Bitcoin", "Ethereum", "Solana", "Tether", "Tether USD", "Dai"] {
            XCTAssertNotNil(WalletHoldings.imitated(by: token("SAFE", name)), name)
        }
    }

    /// And these are not: other words that hold a ticker among letters, names in other alphabets, accents. The curated
    /// tokens themselves are never flagged.
    func testOtherWordsAreNotImitations() {
        for symbol in Self.ownSymbols {
            XCTAssertNil(WalletHoldings.imitated(by: token(symbol)), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), symbol)
        }
        for name in Self.ownNames {
            XCTAssertNil(WalletHoldings.imitated(by: token("SAFE", name)), name)
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), name)
        }
        for curated in Token.core {
            XCTAssertNil(WalletHoldings.imitated(by: curated), "\(curated.symbol) itself is never flagged")
        }
    }

    /// The look-alike letters come from Unicode's confusables: Armenian, Cherokee, Lisu, Coptic and the Latin small
    /// capitals and IPA letters read as the Latin letters they are drawn like; accented Latin letters are not in the
    /// table (their accents are folded where a reading needs it, and a stroke, bar or hook is read through
    /// `LookAlikeLetters.marked`).
    func testTheLookAlikeTableCoversTheScriptsDrawnLikeLatin() {
        let expected: [(UInt32, Unicode.Scalar)] = [(0x0585, "o"), (0x13B7, "M"), (0x13BE, "O"), (0xA4DF, "M"), (0xA4F3, "O"), (0x2C9F, "o"), (0x1D0F, "o"), (0x0261, "g"),
                                                    (0x0421, "C"), (0x0406, "I"), (0x03F9, "C")]
        for (code, latin) in expected {
            XCTAssertEqual(WalletHoldings.lookAlikeLetters[Unicode.Scalar(code)!], latin, String(format: "%04X", code))
        }
        for accented in ["É", "Ñ", "Ç", "Ð", "Ć", "ø", "ß"] {
            XCTAssertNil(WalletHoldings.lookAlikeLetters[accented.unicodeScalars.first!], accented)
        }
        for own in ["\u{03BC}", "\u{03C0}", "\u{03A9}", "\u{0394}", "\u{03BB}"] {
            XCTAssertNil(WalletHoldings.lookAlikeLetters[own.unicodeScalars.first!], "\(own) is drawn like no Latin letter")
        }
    }

    /// A space parts words as any character that isn't a letter does: "USDC e" is the bridged-USDC look "USDC.e" is, and
    /// "ETH x" holds ETH on its own; a symbol made on the contracts can have spaces the forms don't allow. Letters still
    /// make another word ("MONKE X", "xMON").
    func testASpacePartsAWord() {
        let eth = WalletHoldings.majorTokens.first { $0.symbol == "ETH" }!
        for (symbol, expect) in [("USDC e", Token.usdc), ("USDC E", .usdc), ("USDC\u{3000}e", .usdc), ("USDC\te", .usdc), ("ETH x", eth), ("x MON", .mon)] {
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), expect, label(symbol))
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), .symbolImitates(expect), label(symbol))
        }
        for symbol in ["MONKE X", "xMON y", "PE PE"] {
            XCTAssertNil(WalletHoldings.imitated(by: token(symbol)), symbol)
        }
    }

    /// A Latin letter with a stroke, bar or hook (Ø, Đ, Ł, Ħ, Ŧ, Ɵ, Ʉ, Ɇ, Ƀ) or a small capital is its own letter, so a
    /// symbol with one is display-safe (owner decision 5: ÐOGE and ØRE are fine), but it is drawn as the letter under the
    /// mark: "MØN", "USĐC" and "ᴍᴏɴᴀᴅ" read as MON, USDC and Monad, so the forms refuse them and a DyorHQ coin carrying
    /// one warns and shows its letters, never the creator's picture.
    func testMarkedLatinLettersReadAsTheLettersTheyAreDrawnFrom() {
        for (symbol, expect) in [("M\u{00D8}N", Token.mon), ("US\u{0110}C", .usdc), ("M\u{019F}N", .mon), ("\u{0141}BTC", Self.curated("LBTC"))] {
            XCTAssertTrue(SymbolSafety.isDisplaySafe(symbol), "\(symbol) is Latin")
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), .symbolImitates(expect), symbol)
        }
        for (symbol, name, expect) in [("US\u{0110}C", "US\u{0110} Coin", Token.usdc), ("\u{0244}SDC", "\u{0244}SD Coin", .usdc), ("M\u{019F}N", "M\u{019F}NAD", .mon),
                                       ("WM\u{00D8}N", "Wrapped M\u{00D8}N", .wmon), ("\u{0246}TH", "\u{0246}thereum", Self.major("ETH")), ("USD\u{0166}0", "USD\u{0166}0", Self.curated("USDT0"))] {
            XCTAssertEqual(SymbolSafety.createRefusal(name: name, symbol: symbol), .symbolImitates(expect), symbol)
            let coin = DyorCoin(address: address, origin: .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false), symbol: symbol, name: name,
                                creator: DyorCoinChain.creator, logo: DyorCoinChain.media(DyorCoinChain.creator, "usdc.png"), pair: .zero)
            XCTAssertEqual(TokenBadge.of(coin.token, coin: coin, receivedUnasked: true), .imitates(expect), symbol)
            XCTAssertEqual(CoinIcon.resolve(coin.token, coin: coin, policy: .dyorhq), .letters, symbol)
        }
        XCTAssertEqual(WalletHoldings.visible("M\u{00D8}N"), "MON")
        XCTAssertEqual(WalletHoldings.visible("\u{1D0D}\u{1D0F}\u{0274}\u{1D00}\u{1D05}").lowercased(), "monad")
        for symbol in ["\u{00D0}OGE", "\u{00D8}RE", "\u{0141}\u{00D3}D\u{0179}"] {
            XCTAssertTrue(SymbolSafety.isDisplaySafe(symbol), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), symbol)
        }
    }

    /// Unicode's confusables are read for every script, not six: a Myanmar ဝ, a Hebrew ס, a Tifinagh ⵔ, an Ethiopic ዐ, a
    /// Georgian ჿ and Canadian syllabics ᑌ, ᗪ and ᗷ are drawn as Latin letters. A word mixing one with Latin letters is
    /// refused even when the name reads as nothing curated ("USD Cဝin"), and a DyorHQ coin named so warns. A name in one
    /// of those scripts alone is fine.
    func testEveryScriptsLookAlikes() {
        let expected: [(UInt32, Unicode.Scalar)] = [(0x101D, "o"), (0x05E1, "o"), (0x0647, "o"), (0x2D54, "O"), (0x12D0, "O"), (0x10FF, "o"), (0x144C, "U"), (0x15EA, "D"), (0x15F7, "B")]
        for (code, latin) in expected {
            XCTAssertEqual(WalletHoldings.lookAlikeLetters[Unicode.Scalar(code)!], latin, String(format: "%04X", code))
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "USD C\u{101D}in", symbol: "USDCE"), .nameMixesAlphabets)
        let coin = DyorCoin(address: address, origin: .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false), symbol: "USDCE",
                            name: "USD C\u{101D}in", creator: DyorCoinChain.creator, logo: DyorCoinChain.media(DyorCoinChain.creator, "usdc.png"), pair: .zero)
        XCTAssertTrue(TokenBadge.of(coin.token, coin: coin, receivedUnasked: true).isWarning)
        XCTAssertEqual(CoinIcon.resolve(coin.token, coin: coin, policy: .dyorhq), .letters)
        for name in ["\u{05E9}\u{05DC}\u{05D5}\u{05DD}", "\u{0645}\u{0648}\u{0646}\u{0627}\u{062F}", "\u{1019}\u{102D}\u{102F}\u{1038}", "\u{1403}\u{14C4}\u{1483}"] {
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), label(name))
        }
    }

    /// A digit of any script and a sign are no letters: one right beside "MON" or "USDC" leaves it an imitation, as a
    /// 0 or a dot does ("MON०" with a Devanagari zero, "USDC©", "MON₹", "USDC®"). A digit drawn like a letter is still
    /// read as that letter where a whole symbol or name is compared ("M०N" is MON), and a sign is never spelled with
    /// letters ("©" is no "(C)", "₹" no "INR").
    func testADigitOrASignBesideASymbolIsNoLetter() {
        for (text, expect) in [("MON\u{0966}", Token.mon), ("USDC\u{00A9}", .usdc), ("MON\u{20B9}", .mon), ("USDC\u{00AE}", .usdc), ("M\u{0966}N", .mon),
                               ("\u{0966}MON", .mon), ("MON\u{0665}", .mon), ("USDC\u{0E50}", .usdc), ("MON\u{20BA}", .mon), ("USDC\u{2117}", .usdc)] {
            XCTAssertEqual(WalletHoldings.imitated(by: token(text)), expect, "symbol \(label(text))")
            XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", text)), expect, "name \(label(text))")
            XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: text), .symbolImitates(expect), label(text))
        }
        XCTAssertEqual(WalletHoldings.visible("M\u{0966}N"), "MoN", "a Devanagari zero drawn like o, where whole names are compared")
        XCTAssertEqual(WalletHoldings.visible("MON\u{0966}", digits: .value), "MON0", "and a digit where one is found inside another")
        XCTAssertEqual(WalletHoldings.visible("USDC\u{00A9}\u{20B9}\u{00C6}\u{1D0D}"), "USDC\u{00A9}\u{20B9}AEM", "signs stay signs; Latin letters are spelled in ASCII")
    }

    /// Nothing that made a symbol or name an imitation before every script's look-alike digits and ICU's Latin-ASCII
    /// were read (commit da90e7a) is lost: each character of the Basic Multilingual Plane that, right after or right
    /// before MON or USDC in a symbol or a name, made it MON's or USDC's look-alike then still does
    /// (`Fixtures/lookalike-affixes.json`, worked out by running `imitated(by:)` at that commit on every such text).
    func testEveryCharacterBesideMONOrUSDCThatMadeAnImitationStillDoes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "lookalike-affixes", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var cases: [(placement: String, scalars: [Unicode.Scalar])] = []
        for placement in ["symbolAfter", "symbolBefore", "nameAfter", "nameBefore"] {
            let ranges = try XCTUnwrap(fixture[placement] as? [String], placement)
            let scalars = ranges.flatMap { range -> [Unicode.Scalar] in
                let ends = range.split(separator: "-").compactMap { UInt32($0, radix: 16) }
                return (ends[0] ... ends[ends.count - 1]).compactMap(Unicode.Scalar.init)
            }
            XCTAssertGreaterThan(scalars.count, 13_000, placement)
            cases.append((placement, scalars))
        }
        let jobs = cases.flatMap { item in [Token.mon, Token.usdc].map { (item.placement, item.scalars, $0) } }
        var lost = [[String]](repeating: [], count: jobs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (placement, scalars, ticker) = jobs[index]
            var found: [String] = []
            for scalar in scalars {
                let text = placement.hasSuffix("After") ? ticker.symbol + String(scalar) : String(scalar) + ticker.symbol
                let probe = placement.hasPrefix("symbol") ? token(text) : token("SAFE", text)
                if WalletHoldings.imitated(by: probe) != ticker { found.append(String(format: "%04X", scalar.value)) }
            }
            lock.lock()
            lost[index] = found
            lock.unlock()
        }
        for (index, job) in jobs.enumerated() {
            XCTAssertEqual(lost[index], [], "\(job.0), \(job.2.symbol): no longer an imitation")
        }
    }

    // MARK: Cost

    /// An airdropped token's `name()` can compute 40 KB of text for a few thousand gas, and the Send list judges each
    /// row's token several times a draw: a crafted name or symbol costs what a short one does, on its own and through
    /// the badge. The cost is this thread's CPU time, which a busy machine doesn't inflate (the rule as it was took
    /// seconds of it for 10,000 characters). Only what shows is judged, so padding a look-alike with invisible
    /// characters, or putting it last behind an override that shows it first, hides nothing.
    func testALongCraftedNameCostsWhatAShortOneDoes() {
        continueAfterFailure = false
        let spam = Address(literal: "0x00000000000000000000000000000000000bad01")
        for size in [10_000, 40_000] {
            let crafted: [(String, Token)] = [
                ("dots then mon", Token(address: spam, symbol: "SPAM", name: String(repeating: ".", count: size / 2) + String(repeating: "mon", count: size / 6), decimals: 18)),
                ("dollars then usdc", Token(address: spam, symbol: "SPAM", name: String(repeating: "$", count: size / 2) + String(repeating: "usdc", count: size / 8), decimals: 18)),
                ("xmonx symbol", Token(address: spam, symbol: String(repeating: "xmonx", count: size / 5), name: "Spam", decimals: 18)),
                ("accents then Cyrillic", Token(address: spam, symbol: "SPAM", name: String(repeating: "é", count: size / 2) + String(repeating: "мон", count: size / 6), decimals: 18)),
                ("override", Token(address: spam, symbol: "SPAM", name: "\u{202E}" + String(repeating: "\u{200B}.", count: size / 2) + "CDSU", decimals: 18)),
            ]
            for (label, token) in crafted {
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                _ = WalletHoldings.imitated(by: token)
                _ = TokenBadge.of(token, coin: nil, receivedUnasked: true)
                let seconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
                XCTAssertLessThan(seconds, 0.25, "\(label), \(size) characters: \(seconds) s of CPU")
            }
        }
        let padded = token("SAFE", String(repeating: "\u{200B}", count: 40_000) + "USDC")
        XCTAssertEqual(WalletHoldings.imitated(by: padded), .usdc, "invisible padding hides nothing")
        let overridden = token("SAFE", "\u{202E}" + String(repeating: ".", count: 40_000) + "CDSU")
        XCTAssertEqual(WalletHoldings.imitated(by: overridden), .usdc, "an override shows the end first: \"USDC....\"")
    }

    /// The Send list and every badge judge each row's token on every draw, so judging one is cheap: plain ASCII is
    /// read as it is written, never run through ICU's Latin-ASCII transform or the look-alike tables (`visible` costs
    /// less than half of one run of that transform over the same text; it ran it each time, six times a token), and a
    /// token judged again is answered from the answers kept (`imitated(by:)`), so reading a held token's `imitates` and
    /// `looksAlike` again costs next to nothing (it judged the token each time: about 0.3 ms each). The costs are this
    /// thread's CPU time, the best of a few rounds, each compared with what the same thread does in the same round.
    func testJudgingATokenIsCheapAndJudgingItAgainCheaper() {
        func cpu(_ work: () -> Void) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            work()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        }
        let names = (0 ..< 1_000).map { "Pepe Coin \($0)" }
        _ = WalletHoldings.imitated(by: token("WARM", "Warm Up")) // the tables are built once, on first use
        var visible = Double.infinity
        var transform = Double.infinity
        for _ in 0 ..< 5 {
            visible = min(visible, cpu { for name in names { _ = WalletHoldings.visible(name) } })
            transform = min(transform, cpu { for name in names { _ = name.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) } })
        }
        XCTAssertLessThan(visible, transform / 2, "plain ASCII as it shows: \(visible) s of CPU, against \(transform) s for one Latin-ASCII run each")
        XCTAssertEqual(WalletHoldings.visible("Pepe  Coin 7", keepingSpaces: true), "Pepe Coin 7")

        let held = HeldToken(token: Token(address: address, symbol: "USDC.e", name: "USD Coin", decimals: 6), balance: 1, usd: 1)
        var again = Double.infinity
        for _ in 0 ..< 3 { again = min(again, cpu { for _ in 0 ..< 2_000 { _ = (held.imitates, held.looksAlike) } }) }
        XCTAssertLessThan(again, 0.1, "\(again) s of CPU for 2,000 reads of both")
        XCTAssertEqual(held.imitates, .usdc)
        XCTAssertTrue(held.looksAlike)
    }

    // MARK: Display safety and the create guard (F5, F6)

    /// Accented Latin letters are Latin letters: display-safe and allowed ("USDĆ" still reads as USDC).
    func testAccentedLatinSymbolsAreAllowed() {
        for symbol in ["CAFÉ", "PIÑA", "ÇA", "NIÑO", "ÐOGE", "CAFE\u{0301}", "ȘTEFAN", "ÆON"] {
            XCTAssertTrue(SymbolSafety.isDisplaySafe(symbol), symbol)
            XCTAssertNil(SymbolSafety.createRefusal(name: "Some Coin", symbol: symbol), symbol)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: "USDĆ"), .symbolImitates(.usdc))
        for symbol in ["\u{0131}QT", "Q\u{1D1B}", "\u{01C0}QT", "\u{017F}QT", "PEPE\u{72D7}", "\u{72D7} \u{72D7}", "\u{72D7}\u{FF12}"] {
            XCTAssertFalse(SymbolSafety.isDisplaySafe(symbol), label(symbol))
        }
    }

    /// The symbol refusal says what is allowed, in plain words.
    func testTheSymbolRefusalSaysWhatIsAllowed() {
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Some Coin", symbol: "PEPE\u{72D7}"), .symbolNotDisplaySafe)
        XCTAssertEqual(SymbolSafety.CreateRefusal.symbolNotDisplaySafe.message,
                       "A symbol can use A–Z, 0–9 and accented Latin letters, or Chinese, Japanese or Korean characters with 0–9, not mixed.")
    }

    /// A name mixing alphabets is judged word by word, counting only letters drawn like Latin ones.
    func testTheMixedAlphabetRuleIsPerWordAndOnlyForLookAlikes() {
        for name in ["\u{03A9}mega", "\u{03C0}DAO", "\u{03BC}Swap", "\u{0394}Neutral", "Lambda \u{03BB}", "Pepe \u{041F}\u{0435}\u{043F}\u{0435}",
                     "Russian \u{0420}\u{0443}\u{0431}\u{043B}\u{044C}", "K\u{0131}rm\u{0131}z\u{0131}", "Αθηνά"] {
            XCTAssertFalse(SymbolSafety.mixesLookAlikeAlphabets(name), name)
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), name)
        }
        for name in ["P\u{0430}ypal", "M\u{0585}nad", "Coin P\u{0430}y", "Gr\u{1D0F}ve"] {
            XCTAssertTrue(SymbolSafety.mixesLookAlikeAlphabets(name), name)
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "P\u{0430}ypal", symbol: "PAY"), .nameMixesAlphabets)
        XCTAssertEqual(SymbolSafety.createRefusal(name: "M\u{0585}nad", symbol: "SAFE"), .nameImitates(.mon), "reads as Monad first")
    }

    /// A joiner, a variation selector, a keycap mark or tags only where an emoji uses them; the blank Braille pattern and
    /// the Hangul fillers are hidden.
    static let hiddenNames = ["USD1\u{200D}", "Coin1" + englandTags, "Doge\u{1F436}\u{E0068}", "Doge \u{1F436}\u{200D}", "USDC\u{2800}", "A\u{20E3}", "\u{1F3F4}\u{E007F}",
                              "Coin #\u{FE0F}\u{200D}", "\u{1F436}\u{200D}A", "Q\u{115F}", "Q\u{1160}", "Q\u{3164}", "Q\u{FFA0}",
                              "\u{1F3F4}" + String(repeating: "\u{E0061}", count: 20) + "\u{E007F}"]
    static let englandTags = "\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"

    func testHiddenCharactersOutsideEmoji() {
        for name in Self.hiddenNames {
            XCTAssertTrue(SymbolSafety.hasHiddenCharacters(name), label(name))
            XCTAssertNotNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), label(name))
        }
        for name in ["\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{2764}\u{FE0F}", "1\u{FE0F}\u{20E3}", "#\u{20E3}", "\u{1F3F4}" + Self.englandTags,
                     "\u{1F468}\u{1F3FD}\u{200D}\u{1F4BB}", "\u{2764}\u{FE0F}\u{200D}\u{1F525}", "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "Family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
                     "Skin \u{1F44D}\u{1F3FD}", "Flag \u{1F1EC}\u{1F1ED}", "Café Crème"] {
            XCTAssertFalse(SymbolSafety.hasHiddenCharacters(name), label(name))
        }
        XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", "USDC\u{2800}")), .usdc, "the blank Braille pattern reads as nothing")
    }

    /// Persian spells with the zero-width non-joiner and Indic conjuncts with the joiner after a virama: between two
    /// letters of such a script they are part of the name, not hidden, so the forms allow the name and a DyorHQ coin
    /// named so keeps its label. Anywhere else — around Latin letters, doubled, at an end, between two scripts — they are
    /// still hidden.
    func testTheJoinersPersianAndIndicScriptsSpellWithAreNotHidden() {
        let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
        let conjunct = "\u{0915}\u{094D}\u{200D}\u{0937}"
        let bengali = "\u{0995}\u{09CD}\u{200C}\u{09B7}"
        for name in [persian, conjunct, bengali, "\u{0646}\u{0627}\u{0645}\u{0647}\u{200C}\u{0627}\u{06CC} \u{0645}\u{0646}"] {
            XCTAssertFalse(SymbolSafety.hasHiddenCharacters(name), label(name))
            XCTAssertNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength), label(name))
            let coin = DyorCoin(address: address, origin: .moment(factory: MomentsAddresses.monadMainnet.factory, id: 1, retired: false), symbol: "SAFE", name: name,
                                creator: DyorCoinChain.creator, logo: "", pair: Monad.usdc)
            XCTAssertEqual(TokenBadge.of(coin.token, coin: coin, receivedUnasked: true), .dyorMoment, label(name))
        }
        for name in ["Pay\u{200C}pal", "USD1\u{200D}", "\u{0645}\u{06CC}\u{200C}\u{200C}\u{062E}", "\u{0645}\u{06CC}\u{200C}", "\u{200C}\u{0645}\u{06CC}",
                     "\u{0645}\u{200C}\u{0915}", "\u{0915}\u{094D}\u{200D}A", "\u{0645} \u{200C}\u{062E}"] {
            XCTAssertTrue(SymbolSafety.hasHiddenCharacters(name), label(name))
        }
        XCTAssertEqual(WalletHoldings.imitated(by: token("SAFE", "M\u{200C}ON")), .mon, "a joiner still hides nothing")
    }

    /// The create forms refuse a symbol or name longer than they allow: a symbol 10 characters, a launch's name 32 (its
    /// form sets none), a Moment's 48.
    func testTheCreateGuardRefusesWhatTheFormsDont() {
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Coin", symbol: "ABCDEFGHIJK"), .symbolTooLong)
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 32), symbol: "ABCDEFGHIJ"))
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 33), symbol: "SAFE"), .nameTooLong(32))
        XCTAssertNil(SymbolSafety.createRefusal(name: String(repeating: "n", count: 48), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength))
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "n", count: 49), symbol: "SAFE", maxName: SymbolSafety.maxMomentNameLength), .nameTooLong(48))
        XCTAssertEqual(SymbolSafety.createRefusal(name: "A" + String(repeating: "\u{0301}", count: 200), symbol: "SAFE"), .nameTooLongToStore,
                       "one character piled with marks is not short")
        XCTAssertEqual(SymbolSafety.CreateRefusal.nameTooLong(32).message, "A name can be at most 32 characters.")
        // Characters that fit but bytes that don't are said plainly, never as "at most 32 characters" to a name of 10.
        XCTAssertEqual(SymbolSafety.createRefusal(name: String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 10), symbol: "FAM"),
                       .nameTooLongToStore)
        XCTAssertEqual(SymbolSafety.CreateRefusal.nameTooLongToStore.message, "This name is too long to store: use fewer emoji or symbols.")
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameTooLongToStore.isAboutSymbol)
        XCTAssertTrue(SymbolSafety.CreateRefusal.symbolTooLong.isAboutSymbol)
        XCTAssertFalse(SymbolSafety.CreateRefusal.nameTooLong(32).isAboutSymbol)
    }
}
