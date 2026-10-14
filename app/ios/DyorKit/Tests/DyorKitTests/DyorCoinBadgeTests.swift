import XCTest
@testable import DyorKit

/// What a DyorHQ coin shows, by the one look-alike and display rule (`LookAlikeRuleTests`): an imitation warns and
/// shows letters, a coin whose own symbol or name doesn't show as itself or is longer than the forms allow warns, a
/// warning never shows the creator's picture, the text kept is the chain's (cut to a size), and every check reads that
/// text, never the text a screen shows.
final class DyorCoinBadgeTests: XCTestCase {
    private let address = Address(literal: "0x00000000000000000000000000000000000c0ffe")

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
    }

    private func token(_ symbol: String, _ name: String = "Some Coin") -> Token {
        Token(address: address, symbol: symbol, name: name, decimals: 18)
    }

    private func coin(_ symbol: String, _ name: String = "Some Coin", moment: Bool = false, logo: String = "") -> DyorCoin {
        DyorCoin(address: address, origin: moment ? .moment(factory: MomentsAddresses.monadMainnet.factory, id: 1, retired: false)
                     : .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false),
                 symbol: symbol, name: name, creator: DyorCoinChain.creator, logo: logo, pair: .zero)
    }

    private func label(_ text: String) -> String { text.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " ") }

    // MARK: The same rule as the wallet and the forms (F4)

    /// A DyorHQ coin carrying a look-alike symbol or name gets the imitation warning, received or chosen, and shows its
    /// letters; one reading as a major token DyorHQ doesn't list says so.
    func testLookAlikesWarnEverywhere() {
        let art = DyorCoinChain.media(DyorCoinChain.creator, "usdc.png")
        func check(_ token: Token, _ coin: DyorCoin, _ expect: Token, _ text: String) {
            XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: true), .imitates(expect), text)
            XCTAssertEqual(TokenBadge.of(token, coin: coin, receivedUnasked: false), .imitates(expect), text)
            XCTAssertEqual(CoinIcon.resolve(token, coin: coin, policy: .dyorhq), .letters, text)
        }
        for (symbol, expect) in LookAlikeRuleTests.imitatingSymbols { check(token(symbol), coin(symbol, logo: art), expect, label(symbol)) }
        for (name, expect) in LookAlikeRuleTests.imitatingNames { check(token("SAFE", name), coin("SAFE", name, logo: art), expect, label(name)) }
        for symbol in LookAlikeRuleTests.majorSymbols {
            let major = WalletHoldings.majorTokens.first { $0.symbol == symbol }!
            check(token(symbol), coin(symbol, logo: art), major, symbol)
            XCTAssertEqual(TokenBadge.imitates(major).title, "Not the real \(symbol)")
        }
        XCTAssertEqual(TokenBadge.imitates(.usdc).title, "Not the USDC DyorHQ lists")
    }

    /// The words that aren't imitations keep their DyorHQ label; the curated tokens have none.
    func testOtherWordsKeepTheirLabel() {
        for symbol in LookAlikeRuleTests.ownSymbols {
            XCTAssertEqual(TokenBadge.of(token(symbol), coin: coin(symbol), receivedUnasked: true), .dyorLaunch, symbol)
        }
        for name in LookAlikeRuleTests.ownNames {
            XCTAssertEqual(TokenBadge.of(token("SAFE", name), coin: coin("SAFE", name), receivedUnasked: true), .dyorLaunch, name)
        }
        for curated in Token.core { XCTAssertEqual(TokenBadge.of(curated, coin: nil, receivedUnasked: true), .none, curated.symbol) }
    }

    /// Every DyorHQ coin on chain today (`DyorCoinChain.mainnet`: QT, JUST, BB, BP, GMGM, BPP, LP, NAT, 0N1, RWA, SPT,
    /// BTCD — "Bitcoin Diva" — and 0N1F) keeps its DyorHQ label under the stricter look-alike rules, and none is refused
    /// by the create forms.
    func testEveryDyorHQCoinOnChainKeepsItsLabel() async {
        DyorCoinChain.mainnet.install()
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        await registry.refresh()
        let coins = await registry.all
        XCTAssertEqual(coins.count, 13)
        for coin in coins.values {
            XCTAssertEqual(TokenBadge.of(coin.token, coin: coin, receivedUnasked: true), coin.isMoment ? .dyorMoment : .dyorLaunch, "\(coin.symbol) / \(coin.name)")
            XCTAssertNil(SymbolSafety.createRefusal(name: coin.name, symbol: coin.symbol,
                                                    maxName: coin.isMoment ? SymbolSafety.maxMomentNameLength : SymbolSafety.maxLaunchNameLength), coin.symbol)
        }
    }

    // MARK: The badge reads the name (F7)

    /// A DyorHQ coin whose name has a direction override — "USDC COIN" drawn from "NIOC CDSU" — a hidden character, a
    /// word mixing look-alike alphabets, or text that couldn't be read is Unverified, never "DyorHQ Launch"; so is one
    /// whose symbol couldn't be read. The create forms refuse each of those names.
    func testTheBadgeChecksTheCoinsName() {
        for name in ["\u{202E}NIOC CDSU", "P\u{0430}ypal", "Doge\u{200B}", "\u{FFFD}", "Coin\u{2800}"] + LookAlikeRuleTests.hiddenNames {
            let entry = coin("SAFE", name)
            XCTAssertTrue(TokenBadge.of(entry.token, coin: entry, receivedUnasked: false).isWarning, label(name))
            XCTAssertNotNil(SymbolSafety.createRefusal(name: name, symbol: "SAFE"), label(name))
        }
        XCTAssertEqual(TokenBadge.of(coin("SAFE", "\u{202E}NIOC CDSU").token, coin: coin("SAFE", "\u{202E}NIOC CDSU"), receivedUnasked: false), .unverified)
        let unreadable = coin(ChainText.unreadable, "Fine")
        XCTAssertEqual(TokenBadge.of(unreadable.token, coin: unreadable, receivedUnasked: false), .unverified)
    }

    // MARK: Lengths (F6)

    /// A DyorHQ coin whose symbol is longer than the forms allow is not display-safe, but a long name is no warning: the
    /// launch form of build 16 and before set no name limit and the Moment form no byte limit, so coins made in the app
    /// carry names such as "Monad Community Appreciation Token" (34 characters) or "USA" and 25 flags (204 bytes), and
    /// keep their DyorHQ label. The create guard still refuses them for new coins. What is kept of the text is cut (a
    /// symbol 32 characters, a name 64, within 128 and 256 bytes; a link over 2,048 bytes dropped), and a cut symbol
    /// still reads as too long. A name is cut between characters, so one ending in emoji ("Family" and ten families of
    /// four, 257 bytes; "Count" and forty "1️⃣" keycaps, 286) keeps whole emoji, none cut into a joiner or a variation
    /// selector that would read as hidden.
    func testLengthsTheFormsAllow() {
        XCTAssertEqual(TokenBadge.of(coin("ABCDEFGHIJ").token, coin: coin("ABCDEFGHIJ"), receivedUnasked: false), .dyorLaunch)
        let longSymbol = coin(String(repeating: "A", count: 11))
        XCTAssertEqual(TokenBadge.of(longSymbol.token, coin: longSymbol, receivedUnasked: false), .unverified)
        let flags = "USA " + String(repeating: "\u{1F1FA}\u{1F1F8}", count: 25)
        XCTAssertGreaterThan(flags.utf8.count, 4 * SymbolSafety.maxMomentNameLength, "over what the guard's byte count allows")
        let families = "Family " + String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", count: 10)
        let keycaps = "Count " + String(repeating: "1\u{FE0F}\u{20E3}", count: 40)
        for name in [families, keycaps] {
            XCTAssertGreaterThan(name.utf8.count, DyorCoin.maxStoredName.bytes, "cut when kept")
            XCTAssertLessThanOrEqual(name.count, DyorCoin.maxStoredName.characters, "by its bytes, not its characters")
            XCTAssertFalse(SymbolSafety.hasHiddenCharacters(name), "the whole name hides nothing")
            let kept = coin("SAFE", name, moment: true).name
            XCTAssertLessThanOrEqual(kept.utf8.count, DyorCoin.maxStoredName.bytes)
            XCTAssertTrue(name.hasPrefix(kept), "whole emoji kept, \(kept.utf8.count) bytes")
            XCTAssertGreaterThan(kept.utf8.count + (name.dropFirst(kept.count).first?.utf8.count ?? 0), DyorCoin.maxStoredName.bytes, "as many as fit")
            XCTAssertFalse(SymbolSafety.hasHiddenCharacters(kept), "what is kept hides nothing either")
        }
        for (name, moment) in [(String(repeating: "n", count: 33), false), ("Monad Community Appreciation Token", false), ("Department of Government Efficiency", false),
                               (String(repeating: "n", count: 64), false), (String(repeating: "n", count: 48), true), (flags, true), (families, true), (keycaps, true)] {
            let entry = coin("SAFE", name, moment: moment)
            XCTAssertEqual(TokenBadge.of(entry.token, coin: entry, receivedUnasked: true), moment ? .dyorMoment : .dyorLaunch, label(name))
            XCTAssertTrue(SymbolSafety.isDisplaySafe(entry), label(name))
        }
        XCTAssertEqual(SymbolSafety.createRefusal(name: "Monad Community Appreciation Token", symbol: "MCAT"), .nameTooLong(32), "a new launch is still held to 32")
        XCTAssertEqual(SymbolSafety.createRefusal(name: flags, symbol: "USA", maxName: SymbolSafety.maxMomentNameLength), .nameTooLongToStore,
                       "29 characters, but 204 bytes")
        let huge = coin(String(repeating: "A", count: 12_000), String(repeating: "B", count: 12_000), logo: "https://x.example/" + String(repeating: "a", count: 3_000))
        XCTAssertEqual(huge.symbol.count, DyorCoin.maxStoredSymbol.characters, "kept cut")
        XCTAssertEqual(huge.name.count, DyorCoin.maxStoredName.characters)
        XCTAssertEqual(huge.logo, "", "a link over 2,048 bytes is dropped")
        XCTAssertEqual(TokenBadge.of(huge.token, coin: huge, receivedUnasked: false), .unverified, "its symbol still too long once cut")
        let longName = coin("SAFE", String(repeating: "B", count: 12_000))
        XCTAssertEqual(longName.name.count, DyorCoin.maxStoredName.characters)
        XCTAssertEqual(TokenBadge.of(longName.token, coin: longName, receivedUnasked: false), .dyorLaunch, "a long name alone is no warning")
        let zalgo = coin("SAFE", String(repeating: "Z" + String(repeating: "\u{0301}", count: 100), count: 5))
        XCTAssertLessThanOrEqual(zalgo.name.utf8.count, DyorCoin.maxStoredName.bytes)
        let piledName = coin("SAFE", "A" + String(repeating: "\u{0301}", count: 300))
        XCTAssertEqual(piledName.name.utf8.count, DyorCoin.maxStoredName.bytes - 1, "one character longer than the cap is cut inside it")
        let piledSymbol = coin("A" + String(repeating: "\u{0301}", count: 200))
        XCTAssertEqual(TokenBadge.of(piledSymbol.token, coin: piledSymbol, receivedUnasked: false), .unverified, "one character piled with marks is not a short symbol")
        let decoded = try? JSONDecoder().decode(DyorCoin.self, from: JSONEncoder().encode(DyorCoin(address: address,
            origin: .launch(factory: LaunchpadAddresses.monadMainnet.factory, generation: .v2, retired: false), symbol: "S", name: "N", creator: .zero, logo: "", pair: .zero)))
        XCTAssertEqual(decoded?.symbol, "S", "an entry round-trips through the file's form")
    }

    // MARK: The icon follows the badge (F8)

    /// A coin whose badge is a warning shows its letters, never its creator's picture: a symbol drawn like "USDC" in
    /// another script, a symbol with a hidden character, a name with a direction override.
    func testAWarningShowsLettersNeverTheCreatorsPicture() {
        let art = DyorCoinChain.media(DyorCoinChain.creator, "usdc.png")
        for (symbol, name) in [("USD\u{03F9}", "USD Coin"), ("USD\u{13DF}", "USD Coin"), ("PEPE\u{200B}", "Pepe"), ("SAFE", "\u{202E}NIOC CDSU")] {
            let entry = coin(symbol, name, logo: art)
            XCTAssertTrue(TokenBadge.of(entry.token, coin: entry, receivedUnasked: false).isWarning, label(symbol))
            XCTAssertEqual(CoinIcon.resolve(entry.token, coin: entry, policy: .dyorhq), .letters, label(symbol))
        }
        let fine = coin("SAFE", "Safe Coin", logo: art)
        XCTAssertEqual(CoinIcon.resolve(fine.token, coin: fine, policy: .dyorhq), .remote([RemoteImageSource(url: URL(string: art)!)], fill: true))
    }

    // MARK: Chain text, not shown text (F13)

    /// A coin keeps its text as the chain has it, and every check reads that, whichever token a screen passes: its
    /// `DyorCoin.token`, a `MomentInfo.coinToken` or a token built from a `Launch`, each carrying the text as it shows
    /// (`ChainText.shown`: a right-to-left name inside an isolate). So a Hebrew name gets its DyorHQ label and picture
    /// every way, a shown "NOM ١" is no "١MON", a Hebrew symbol gets the same verdict raw as shown, and direction
    /// characters the chain holds are caught though `shown` removes them.
    func testChecksReadTheChainsTextNeverTheShownText() async throws {
        var chain = DyorCoinChain()
        func launch(_ n: Int, _ symbol: String, _ name: String) -> DyorCoinChain.LaunchCoin {
            let token = Address(literal: String(format: "0x0000000000000000000000000000000000%06x", 0xc0d000 + n))
            return DyorCoinChain.LaunchCoin(token: token, name: name, symbol: symbol, logo: DyorCoinChain.media(DyorCoinChain.creator, "\(n).jpg"), deployer: DyorCoinChain.creator,
                                            curve: Address(data: Data(token.data.reversed()))!)
        }
        let shalom = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"
        let hebrewSymbol = launch(1, "\u{05D0}\u{05D1}\u{05D2}", "Aleph")
        let hebrewName = launch(2, "SHLM", shalom)
        let isolated = launch(3, "\u{2066}QT\u{2069}", "Quiet")
        let arabicDigit = launch(4, "NOMI", "NOM \u{0661}")
        chain.launches[LaunchpadAddresses.monadMainnet.factory] = [hebrewSymbol, hebrewName, isolated, arabicDigit]
        let moment = DyorCoinChain.MomentCoin(coin: Address(literal: "0x0000000000000000000000000000000000c0d101"), nft: Address(literal: "0x0000000000000000000000000000000000c0d102"),
                                              creator: DyorCoinChain.creator, name: shalom, symbol: "SHLM", mediaURI: DyorCoinChain.media(DyorCoinChain.creator, "moment.jpg"),
                                              mediaHash: Data(count: 32))
        chain.moments[MomentsAddresses.monadMainnet.factory] = [moment]
        chain.install()
        let registry = DyorCoinRegistry(rpc: MomentsChainStub.rpc())
        await registry.refresh()
        let coins = await registry.all

        let nameCoin = try XCTUnwrap(coins[hebrewName.token])
        XCTAssertEqual(nameCoin.name, shalom, "kept as the chain has it")
        XCTAssertNil(SymbolSafety.createRefusal(name: shalom, symbol: "SHLM"), "the create forms allow it")
        // As `LaunchpadService` reads a launch (`ChainText.shown`) and Home, the Portfolio and the board make a token of it.
        let launchToken = Token(address: hebrewName.token, symbol: ChainText.shown("SHLM"), name: ChainText.shown(shalom), decimals: 18, isLaunchpad: true)
        for token in [nameCoin.token, launchToken] {
            XCTAssertEqual(TokenBadge.of(token, coin: nameCoin, receivedUnasked: true), .dyorLaunch)
            XCTAssertNotEqual(CoinIcon.resolve(token, coin: nameCoin, policy: .dyorhq), .letters, "its own picture")
        }

        let momentCoin = try XCTUnwrap(coins[moment.coin])
        let info = MomentInfo(moment: Moment(id: 1, creator: moment.creator, platform: .zero, treasury: .zero, coin: moment.coin, nft: moment.nft, price: 1, threshold: 1, rateNum: 1,
                                             rateDen: 1, creatorBps: 0, platformBps: 0, reserveBps: 0, creatorAllocBps: 0, expiryCreatorBps: 0, royaltyBps: 0, publishedAt: 0,
                                             deadline: 0, factory: MomentsAddresses.monadMainnet.factory),
                              name: ChainText.shown(shalom), symbol: ChainText.shown("SHLM"),
                              provenance: MomentProvenance(mediaURI: moment.mediaURI, mediaHash: moment.mediaHash, place: "", date: 0, animationURI: ""),
                              ledger: MomentLedger(state: .collecting, completedAt: 0, stuckSince: 0, endedAt: 0, reserve: 0, creatorClaimable: 0, platformClaimable: 0,
                                                   treasuryClaimable: 0, totalGross: 0, collects: 0),
                              editions: 0, closed: false, entitlements: 0, graduated: false, progressBps: 0, pool: nil)
        for token in [momentCoin.token, info.coinToken] {
            XCTAssertEqual(TokenBadge.of(token, coin: momentCoin, receivedUnasked: true), .dyorMoment)
            XCTAssertNotEqual(CoinIcon.resolve(token, coin: momentCoin, policy: .dyorhq), .letters)
        }

        let digitCoin = try XCTUnwrap(coins[arabicDigit.token])
        XCTAssertNil(WalletHoldings.imitated(by: digitCoin.token), "an isolate around all of it reverses nothing")
        XCTAssertEqual(TokenBadge.of(digitCoin.token, coin: digitCoin, receivedUnasked: true), .dyorLaunch)
        XCTAssertNil(WalletHoldings.imitated(by: Token(address: digitCoin.address, symbol: "SAFE", name: "\u{2068}NOM .\u{2069}", decimals: 18)))
        XCTAssertEqual(WalletHoldings.imitated(by: Token(address: digitCoin.address, symbol: "SAFE", name: "\u{202E}NOM .", decimals: 18)), .mon,
                       "an override does reverse it: \". MON\"")

        let symbolCoin = try XCTUnwrap(coins[hebrewSymbol.token])
        XCTAssertEqual(symbolCoin.symbol, "\u{05D0}\u{05D1}\u{05D2}", "kept as read")
        XCTAssertEqual(symbolCoin.displaySymbol, "\u{2068}\u{05D0}\u{05D1}\u{05D2}\u{2069}", "isolated for showing")
        XCTAssertEqual(SymbolSafety.isDisplaySafe(symbolCoin.symbol), SymbolSafety.isDisplaySafe(symbolCoin.displaySymbol), "the same verdict raw as shown")
        XCTAssertEqual(TokenBadge.of(symbolCoin.token, coin: symbolCoin, receivedUnasked: false), .unverified)

        let isolatedCoin = try XCTUnwrap(coins[isolated.token])
        XCTAssertEqual(isolatedCoin.symbol, "\u{2066}QT\u{2069}")
        XCTAssertEqual(isolatedCoin.token.symbol, "QT", "shown without its isolates")
        XCTAssertEqual(TokenBadge.of(isolatedCoin.token, coin: isolatedCoin, receivedUnasked: false), .unverified, "the isolates the chain holds are caught")

        // Last: a failure message holding the isolates can keep XCTest from reporting the ones after it.
        XCTAssertEqual(nameCoin.token.name, "\u{2068}\(shalom)\u{2069}", "a screen gets it as it shows")
        XCTAssertEqual(digitCoin.token.name, "\u{2068}NOM \u{0661}\u{2069}")
    }
}
