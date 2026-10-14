import BigInt
import XCTest
@testable import DyorKit

/// The held-token list the Portfolio's Assets and the Send sheet share: what is in it, its order, where a send starts,
/// search, and which tokens count as dollars.
final class WalletHoldingsTests: XCTestCase {
    private let meme = Token(address: Address(literal: "0x1111111111111111111111111111111111111111"), symbol: "MEME", name: "Meme Coin", decimals: 18)
    private let fakeUSDC = Token(address: Address(literal: "0x2222222222222222222222222222222222222222"), symbol: "USDC", name: "USD Coin", decimals: 6)
    private let launch = Token(address: Address(literal: "0x3333333333333333333333333333333333333333"), symbol: "LAUNCH", name: "Launch Coin", decimals: 18, isLaunchpad: true)
    private let spam = Token(address: Address(literal: "0x4444444444444444444444444444444444444444"), symbol: "VISIT", name: "Claim at visit.example", decimals: 18)

    private func units(_ whole: Double, _ token: Token) -> BigUInt { Amount.raw(whole, decimals: token.decimals) }

    func testZeroBalancesAndUnreadBalancesAreLeftOut() {
        let universe = [Token.mon, Token.wmon, Token.usdc, meme, launch]
        let balances: [Address: BigUInt] = [Monad.native: 0, Monad.wmon: units(2, .wmon), Monad.usdc: 0, meme.address: units(5, meme)]
        let held = WalletHoldings.held(universe, balances: balances)
        XCTAssertEqual(held.map(\.symbol), ["WMON", "MEME"], "zero balances and a balance that couldn't be read are not held")
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertFalse(ranked.contains { $0.balance == 0 })
        XCTAssertEqual(Set(ranked.map(\.id)), [Monad.wmon, meme.address])
    }

    func testDuplicateTokensAreListedOnce() {
        let held = WalletHoldings.held([Token.usdc, meme, Token.usdc], balances: [Monad.usdc: 1, meme.address: 1])
        XCTAssertEqual(held.map(\.address), [Monad.usdc, meme.address])
    }

    func testPricedTokensAreOrderedByDollarValueHighestFirst() {
        let universe = [Token.mon, Token.usdc, Token.wmon, meme]
        let balances: [Address: BigUInt] = [Monad.native: units(100, .mon), Monad.usdc: units(40, .usdc), Monad.wmon: units(1_000, .wmon), meme.address: units(40, meme)]
        let prices: [Address: Double] = [Monad.native: 0.5, Monad.usdc: 1, Monad.wmon: 0.5, meme.address: 0.25]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [])
        // WMON $500, MON $50, USDC $40, MEME $10.
        XCTAssertEqual(ranked.map(\.token.symbol), ["WMON", "MON", "USDC", "MEME"])
        XCTAssertEqual(ranked.compactMap(\.value), [500, 50, 40, 10])
    }

    func testUnpricedTokensComeAfterEveryPricedOneChosenBeforeUnverifiedThenByAmount() {
        let universe = [spam, launch, meme, Token.usdc, Token.mon]
        let balances: [Address: BigUInt] = [spam.address: units(9_000_000, spam), launch.address: units(10, launch), meme.address: units(500, meme),
                                            Monad.usdc: units(0.01, .usdc), Monad.native: units(1, .mon)]
        // Only USDC ($0.01) and MON ($0.02) have prices; an infinite price is no price at all.
        let prices: [Address: Double] = [Monad.usdc: 1, Monad.native: 0.02, launch.address: .infinity]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [spam.address])
        XCTAssertEqual(ranked.map(\.token.symbol), ["MON", "USDC", "MEME", "LAUNCH", "VISIT"],
                       "priced first, however small; then chosen tokens by amount; the Unverified spam last despite its huge amount")
        XCTAssertNil(ranked.first { $0.token == launch }?.value, "an unusable price reads as unknown, never as a value")
        XCTAssertEqual(ranked.filter { $0.value == nil }.count, 3)
    }

    /// The Portfolio keeps the order it has always used, (value or $0, amount) highest first, on the same tokens the Send
    /// list ranks its own way.
    func testThePortfolioKeepsItsOrder() {
        let chosen = Token(address: Address(literal: "0x5555555555555555555555555555555555555555"), symbol: "A", name: "Chosen", decimals: 18)
        let universe = [Token.mon, Token.usdc, chosen, spam, meme]
        let balances: [Address: BigUInt] = [Monad.native: units(100, .mon), Monad.usdc: units(0.01, .usdc), chosen.address: units(10, chosen),
                                            spam.address: units(9_000_000, spam), meme.address: units(40, meme)]
        let prices: [Address: Double] = [Monad.native: 0.03, Monad.usdc: 1, meme.address: 0]
        let portfolio = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [spam.address], by: WalletHoldings.portfolioPrecedes)
        // The rule the Portfolio sorted by before the Send list shared its read, applied to the same tokens.
        let before = WalletHoldings.held(universe, balances: balances)
            .map { HeldToken(token: $0, balance: balances[$0.address]!, usd: prices[$0.address], unverified: $0 == spam) }
            .sorted { ($0.value ?? 0, Amount.units($0.balance, decimals: $0.token.decimals)) > ($1.value ?? 0, Amount.units($1.balance, decimals: $1.token.decimals)) }
        XCTAssertEqual(portfolio, before)
        XCTAssertEqual(portfolio.map(\.token.symbol), ["MON", "USDC", "VISIT", "MEME", "A"], "unpriced and $0 tokens by amount, as always")
        let send = WalletHoldings.ranked(universe, balances: balances, prices: prices, unverified: [spam.address])
        XCTAssertEqual(send.map(\.token.symbol), ["MON", "USDC", "MEME", "A", "VISIT"], "the Send list: priced first ($0 included), then chosen before Unverified")
        XCTAssertEqual(Set(send), Set(portfolio), "the same tokens, values and marks")
    }

    func testTiesAreBrokenTheSameWayWhateverTheReadOrder() {
        let twin = Token(address: Address(literal: "0x0000000000000000000000000000000000000abc"), symbol: "meme", name: "Twin", decimals: 18)
        let other = Token(address: Address(literal: "0x5555555555555555555555555555555555555555"), symbol: "ALPHA", name: "Alpha", decimals: 18)
        let tokens = [meme, twin, other, launch]
        // Same value for all four; LAUNCH holds more; MEME and "meme" tie on value and amount, so the address decides.
        let balances: [Address: BigUInt] = [meme.address: units(10, meme), twin.address: units(10, twin), other.address: units(10, other), launch.address: units(20, launch)]
        let prices: [Address: Double] = [meme.address: 1, twin.address: 1, other.address: 1, launch.address: 0.5]
        let expected = ["LAUNCH", "ALPHA", "meme", "MEME"]
        for order in permutations(tokens) {
            XCTAssertEqual(WalletHoldings.ranked(order, balances: balances, prices: prices, unverified: []).map(\.token.symbol), expected)
        }
        // An exact tie on value between a chosen and an Unverified token: the chosen one first.
        let tied = WalletHoldings.ranked([fakeUSDC, Token.usdc], balances: [fakeUSDC.address: 5_000_000, Monad.usdc: 5_000_000],
                                         prices: [fakeUSDC.address: 1, Monad.usdc: 1], unverified: [fakeUSDC.address])
        XCTAssertEqual(tied.map(\.id), [Monad.usdc, fakeUSDC.address])
    }

    func testNativeMonIsListedAndIsTheDefaultOnlyWhenItIsTheTopAsset() {
        let universe = [Token.mon, Token.usdc]
        let monTop = WalletHoldings.ranked(universe, balances: [Monad.native: units(1_000, .mon), Monad.usdc: units(5, .usdc)], prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertEqual(monTop.first?.token, .mon)
        XCTAssertEqual(WalletHoldings.defaultChoice(monTop)?.token, .mon)
        let usdcTop = WalletHoldings.ranked(universe, balances: [Monad.native: units(10, .mon), Monad.usdc: units(5, .usdc)], prices: [Monad.native: 0.03, Monad.usdc: 1], unverified: [])
        XCTAssertEqual(usdcTop.map(\.token.symbol), ["USDC", "MON"], "MON is listed, below the higher-value USDC")
        XCTAssertEqual(WalletHoldings.defaultChoice(usdcTop)?.token, .usdc)
    }

    func testSpoofedUSDCIsMarkedNeverTheDefaultAndNeverDollars() {
        let universe = [Token.mon, Token.usdc, fakeUSDC]
        // The fake "USDC" has a seeded pool pricing it far above everything real.
        let balances: [Address: BigUInt] = [Monad.native: units(10, .mon), Monad.usdc: units(20, .usdc), fakeUSDC.address: units(1_000_000, fakeUSDC)]
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: [Monad.native: 0.03, Monad.usdc: 1, fakeUSDC.address: 1], unverified: [fakeUSDC.address])
        XCTAssertEqual(ranked.first?.id, fakeUSDC.address, "listed by its (claimed) value…")
        XCTAssertTrue(ranked.first?.unverified == true, "…and marked")
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.id, Monad.usdc, "a send starts on the real USDC, never the look-alike")

        XCTAssertNil(WalletHoldings.stableUSD(fakeUSDC, amount: 1_500_000), "a token named USDC is not dollars")
        XCTAssertEqual(WalletHoldings.stableUSD(.usdc, amount: 1_500_000), 1.5)
        XCTAssertNil(WalletHoldings.stableUSD(.mon, amount: units(3, .mon)))
        XCTAssertEqual(WalletHoldings.dollarStables, Set(["USDC", "USDT0", "AUSD", "USDe", "USD1", "mUSD"].map { symbol in Token.core.first { $0.symbol == symbol }!.address }))
        XCTAssertFalse(WalletHoldings.dollarStables.contains(fakeUSDC.address))
    }

    /// A token the user chose (tapped in Swap, or swapped into) that carries a curated token's symbol or name is marked and
    /// never the default, even when it is worth the most: a second "USDC" can be a look-alike.
    func testALookAlikeOfACuratedTokenIsMarkedAndNeverTheDefault() {
        XCTAssertEqual(WalletHoldings.imitated(by: fakeUSDC), .usdc)
        XCTAssertEqual(WalletHoldings.imitated(by: Token(address: spam.address, symbol: " usdc ", name: "Something", decimals: 6)), .usdc, "case and spaces")
        XCTAssertEqual(WalletHoldings.imitated(by: Token(address: spam.address, symbol: "ＵＳＤＣ", name: "Wide", decimals: 6)), .usdc, "full-width letters")
        XCTAssertEqual(WalletHoldings.imitated(by: Token(address: spam.address, symbol: "MONAD", name: "Monad", decimals: 18)), .mon, "MON's name")
        XCTAssertEqual(WalletHoldings.imitated(by: Token(address: spam.address, symbol: "USDC.e", name: "USD Coin", decimals: 6)), .usdc,
                       "\"USDC\" with only non-letters after it (build 17: a bridged-looking USDC is marked too)")
        XCTAssertNil(WalletHoldings.imitated(by: Token(address: spam.address, symbol: "USDCX", name: "USD Coin", decimals: 6)), "a letter after it makes another word")
        XCTAssertNil(WalletHoldings.imitated(by: .usdc))
        XCTAssertNil(WalletHoldings.imitated(by: .mon))
        XCTAssertNil(WalletHoldings.imitated(by: meme))

        // Both "USDC"s chosen; the look-alike's seeded pool makes it worth the most.
        let ranked = WalletHoldings.ranked([Token.mon, Token.usdc, fakeUSDC], balances: [Monad.native: units(10, .mon), Monad.usdc: units(20, .usdc), fakeUSDC.address: units(1_000_000, fakeUSDC)],
                                           prices: [Monad.native: 0.03, Monad.usdc: 1, fakeUSDC.address: 1], unverified: [])
        XCTAssertEqual(ranked.first?.id, fakeUSDC.address, "listed by its value…")
        XCTAssertEqual(ranked.first?.imitates, .usdc, "…and marked")
        XCTAssertNil(ranked.first { $0.id == Monad.usdc }?.imitates)
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.id, Monad.usdc, "a send starts on the curated USDC")
        let onlyLookAlike = WalletHoldings.ranked([fakeUSDC], balances: [fakeUSDC.address: 1], prices: [:], unverified: [])
        XCTAssertNil(WalletHoldings.defaultChoice(onlyLookAlike), "the user picks it themselves")
        XCTAssertEqual(WalletHoldings.selection(keeping: fakeUSDC.address, in: onlyLookAlike)?.id, fakeUSDC.address, "and keeps their pick")
    }

    /// The Send sheet says "Not the BTC DyorHQ lists" for any token `imitates` names, so it names curated tokens only: a
    /// held look-alike of BTC, ETH or USDT (which DyorHQ doesn't list) isn't called one of DyorHQ's, but is still never
    /// where a send starts. Its badge names it (`TokenBadge`: "Not the real BTC").
    func testALookAlikeOfAWidelyTradedTokenIsNeverTheDefaultNorCalledOneDyorHQLists() {
        let fakes = [Token(address: spam.address, symbol: "BTC", name: "BITCOIN", decimals: 8), Token(address: meme.address, symbol: "USDT", name: "Tether USD", decimals: 6),
                     Token(address: launch.address, symbol: "ETH", name: "Ether", decimals: 18)]
        let ranked = WalletHoldings.ranked(fakes + [Token.mon], balances: Dictionary(uniqueKeysWithValues: (fakes + [Token.mon]).map { ($0.address, BigUInt(10).power(20)) }),
                                           prices: Dictionary(uniqueKeysWithValues: fakes.map { ($0.address, 1_000.0) } + [(Monad.native, 0.03)]), unverified: [])
        for held in ranked where !held.token.isNative {
            XCTAssertNil(held.imitates, "\(held.token.symbol) is no token DyorHQ lists")
            XCTAssertTrue(held.looksAlike, held.token.symbol)
            XCTAssertEqual(WalletHoldings.imitated(by: held.token)?.symbol, held.token.symbol)
            XCTAssertEqual(TokenBadge.of(held.token, coin: nil, receivedUnasked: false).title, "Not the real \(held.token.symbol)")
        }
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.id, Monad.native, "a send starts on MON, below three look-alikes worth more")
        let usdc = HeldToken(token: fakeUSDC, balance: 1, usd: 1)
        XCTAssertEqual(usdc.imitates, .usdc, "a curated token's look-alike is still named")
        XCTAssertTrue(usdc.looksAlike)
    }

    /// A name that only reads as a curated one is marked as well: invisible characters (zero-width space and joiner, soft
    /// hyphen, byte-order mark), letters from another script drawn like Latin ones (Cyrillic "С", Greek "Ο"), mathematical
    /// letters, digits drawn like letters ("M0N", "USDl" for USD1) and text a direction override turns around. A name that
    /// merely differs ("USDL") is its own; "USDC.e" reads as USDC with non-letters after it (build 17). Whatever its name,
    /// a token whose symbol isn't plain ASCII is never preselected: it can read as a symbol it isn't.
    func testANameThatOnlyReadsAsACuratedOneIsMarkedAndNeverTheDefault() {
        func token(_ symbol: String, _ name: String = "Something") -> Token { Token(address: spam.address, symbol: symbol, name: name, decimals: 6) }
        let usdcLike = ["US\u{200B}DC", "U\u{00AD}SDC", "\u{FEFF}USDC", "USDC\u{200D}", "USD\u{0421}", "usd\u{0441}", "\u{202E}CDSU", "U\u{2060}S\u{2063}DC",
                        "USDC\u{FE0F}", "\u{1D414}\u{1D412}\u{1D403}\u{1D402}", "U S\u{00A0}D C"]
        for symbol in usdcLike {
            XCTAssertEqual(WalletHoldings.imitated(by: token(symbol)), .usdc, symbol.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))
        }
        XCTAssertEqual(WalletHoldings.imitated(by: token("M0N")), .mon, "zero for O")
        XCTAssertEqual(WalletHoldings.imitated(by: token("USDl")), Token.core.first { $0.symbol == "USD1" }, "l for 1")
        XCTAssertEqual(WalletHoldings.imitated(by: token("X", "\u{039C}\u{03BF}nad")), .mon, "a Greek name drawn as \"Monad\"")
        XCTAssertNil(WalletHoldings.imitated(by: token("USDL")), "L is not 1")
        XCTAssertEqual(WalletHoldings.imitated(by: token("USDC.e", "USD Coin")), .usdc)
        XCTAssertNil(WalletHoldings.imitated(by: token("\u{0414}\u{041E}\u{0413}")), "Cyrillic that reads as no curated name")
        XCTAssertNil(WalletHoldings.imitated(by: token("", "")))

        XCTAssertTrue(WalletHoldings.isPlain("USDC.e"))
        XCTAssertTrue(WalletHoldings.isPlain("MEME COIN"))
        XCTAssertFalse(WalletHoldings.isPlain(""))
        XCTAssertFalse(WalletHoldings.isPlain("MEME\u{200B}"))
        XCTAssertFalse(WalletHoldings.isPlain("\u{041C}EME"))
        // The user's own pick, worth the most, named in Cyrillic: listed first, never preselected; the next plain one is.
        let cyrillic = Token(address: spam.address, symbol: "\u{041C}\u{0415}\u{041C}\u{0415}", name: "Meme", decimals: 18)
        let ranked = WalletHoldings.ranked([Token.mon, cyrillic, meme], balances: [Monad.native: units(10, .mon), cyrillic.address: units(1_000, cyrillic), meme.address: units(1, meme)],
                                           prices: [Monad.native: 0.03, cyrillic.address: 1, meme.address: 1], unverified: [])
        XCTAssertEqual(ranked.map(\.id), [cyrillic.address, meme.address, Monad.native])
        XCTAssertFalse(ranked[0].plainSymbol)
        XCTAssertTrue(ranked.first { $0.token == .mon }?.plainSymbol == true)
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.id, meme.address)
        // A look-alike the user chose, worth the most, with a zero-width space: marked and never the default.
        let hidden = Token(address: fakeUSDC.address, symbol: "US\u{200B}DC", name: "USD Coin", decimals: 6)
        let withHidden = WalletHoldings.ranked([Token.usdc, hidden], balances: [Monad.usdc: 1_000_000, hidden.address: 1_000_000_000_000], prices: [Monad.usdc: 1, hidden.address: 1], unverified: [])
        XCTAssertEqual(withHidden.first?.imitates, .usdc)
        XCTAssertEqual(WalletHoldings.defaultChoice(withHidden)?.id, Monad.usdc)
    }

    /// Held tokens no pool prices (aprMON, cbBTC) are ranked by amount below the priced ones: a send never starts on one,
    /// since the most units is not the most value. With a priced token held, that one is the default.
    func testDefaultChoiceIsNeverAnUnpricedToken() {
        let aprMON = Token(address: spam.address, symbol: "aprMON", name: "aPriori Monad LST", decimals: 18)
        let unpricedOnly = WalletHoldings.ranked([aprMON, meme], balances: [aprMON.address: units(10, aprMON), meme.address: units(1, meme)], prices: [:], unverified: [])
        XCTAssertEqual(unpricedOnly.count, 2, "both listed")
        XCTAssertNil(WalletHoldings.defaultChoice(unpricedOnly), "no price, no preselection: the user picks")
        let withMON = WalletHoldings.ranked([aprMON, Token.mon], balances: [aprMON.address: units(10, aprMON), Monad.native: units(1, .mon)], prices: [Monad.native: 0.03], unverified: [])
        XCTAssertEqual(WalletHoldings.defaultChoice(withMON)?.token, .mon, "the priced token, though it holds fewer units")
        let zeroPriced = WalletHoldings.ranked([meme], balances: [meme.address: units(5, meme)], prices: [meme.address: 0], unverified: [])
        XCTAssertNil(WalletHoldings.defaultChoice(zeroPriced), "a zero price is no price")
    }

    func testDefaultChoiceSkipsUnverifiedAndIsNoneWhenNothingIsChosen() {
        let onlySent = WalletHoldings.ranked([spam, fakeUSDC], balances: [spam.address: 1, fakeUSDC.address: 1], prices: [:], unverified: [spam.address, fakeUSDC.address])
        XCTAssertEqual(onlySent.count, 2, "still listed")
        XCTAssertNil(WalletHoldings.defaultChoice(onlySent), "but the user picks one")
    }

    /// A price read that fails leaves only the prices known by definition (USDC and AUSD at $1): the list is then ranked
    /// by amount, so a send preselects nothing rather than the token with the most units.
    func testAFailedPriceReadPreselectsNothing() {
        let universe = [Token.mon, Token.usdc, meme]
        let balances: [Address: BigUInt] = [Monad.native: units(20, .mon), Monad.usdc: units(500, .usdc), meme.address: units(1_000_000, meme)]
        let defined = PriceService.definedPrices(for: universe).mapValues(\.usd)
        XCTAssertEqual(defined, [Monad.usdc: 1], "USDC at $1 without a read; MON and MEME need one")
        XCTAssertEqual(PriceService.definedPrices(for: [Token.ausd, fakeUSDC]).mapValues(\.usd), [Monad.ausd: 1], "a token named USDC is not priced by definition")
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: defined, unverified: [])
        XCTAssertEqual(ranked.map(\.token.symbol), ["USDC", "MEME", "MON"], "USDC valued; the rest unpriced, by amount")
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.token.symbol, "USDC", "(with prices read, the top chosen token)")
        XCTAssertNil(WalletHoldings.defaultChoice(ranked, pricesRead: false))
        XCTAssertNil(WalletHoldings.selection(keeping: nil, in: ranked, pricesRead: false), "nothing picked for the user")
        XCTAssertEqual(WalletHoldings.selection(keeping: meme.address, in: ranked, pricesRead: false)?.id, meme.address, "the user's own pick stays")
    }

    /// Curated tokens no pool the price finder looks for prices (read on mainnet 2026-09-29: USDe, USD1, mUSD, cbBTC, LBTC,
    /// ezETH, rETH and aprMON have no Uniswap v3, Monday Trade or Nad.fun pool with liquidity against USDC, AUSD or WMON).
    /// The stables among them are dollars, so 500 mUSD leads 10 MON; the others are named, never ranked as worthless in
    /// silence. Having no price is no failure: a send still starts on the top priced token. Only a curated token whose
    /// price read failed stops that.
    func testCuratedTokensWithNoPoolAreDollarsOrNamed() throws {
        func core(_ symbol: String) throws -> Token { try XCTUnwrap(Token.core.first { $0.symbol == symbol }) }
        let musd = try core("mUSD"), usde = try core("USDe"), usd1 = try core("USD1"), usdt0 = try core("USDT0"), cbbtc = try core("cbBTC")
        XCTAssertEqual(WalletHoldings.dollarStables, Set([Monad.usdc, Monad.ausd, usdt0.address, usde.address, usd1.address, musd.address]))

        // The finding's wallet: 500 mUSD and 10 MON, and the price finder has no price for mUSD.
        let pools: [Address: Double] = [Monad.native: 0.027]
        let wallet = [Token.mon, musd]
        let balances: [Address: BigUInt] = [Monad.native: units(10, .mon), musd.address: units(500, musd)]
        let before = WalletHoldings.ranked(wallet, balances: balances, prices: pools, unverified: [])
        XCTAssertEqual(before.map(\.token.symbol), ["MON", "mUSD"], "without it: mUSD last, as No price")
        let atPar = WalletHoldings.stablesAtPar(pools, tokens: wallet)
        let ranked = WalletHoldings.ranked(wallet, balances: balances, prices: atPar, unverified: [])
        XCTAssertEqual(ranked.map(\.token.symbol), ["mUSD", "MON"])
        XCTAssertEqual(ranked.compactMap(\.value).reduce(0, +), 500.27, accuracy: 1e-9, "the whole wallet in the total")
        XCTAssertTrue(WalletHoldings.unpricedCurated(wallet, prices: atPar).isEmpty)
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.token, musd)

        XCTAssertEqual(WalletHoldings.stablesAtPar([usdt0.address: 0.999], tokens: [usdt0])[usdt0.address], 0.999, "a pool's price stands")
        XCTAssertEqual(WalletHoldings.stablesAtPar([:], tokens: [usde, usd1]), [usde.address: 1, usd1.address: 1])
        XCTAssertTrue(WalletHoldings.stablesAtPar([:], tokens: [fakeUSDC, meme, cbbtc]).isEmpty, "only the stables' own contracts are dollars")

        // cbBTC has no pool: it is named, ranked after every priced token, and mUSD, the top priced one, is preselected.
        let withBTC = wallet + [cbbtc, meme]
        let heldBTC = balances.merging([cbbtc.address: units(0.01, cbbtc), meme.address: units(1_000, meme)]) { a, _ in a }
        let valued = WalletHoldings.stablesAtPar(pools.merging([meme.address: 0.001]) { a, _ in a }, tokens: withBTC)
        let list = WalletHoldings.ranked(withBTC, balances: heldBTC, prices: valued, unverified: [])
        XCTAssertEqual(list.map(\.token.symbol), ["mUSD", "MEME", "MON", "cbBTC"])
        XCTAssertEqual(WalletHoldings.unpricedCurated(list.map(\.token), prices: valued), [cbbtc], "a curated token with no price is named; a token of anyone's with none is not")
        let noPool = WalletHoldings.unpricedCurated(list.map(\.token), prices: valued, noPool: [cbbtc.address])
        XCTAssertEqual(noPool.noPool, [cbbtc])
        XCTAssertTrue(noPool.unread.isEmpty, "no pool is no failure")
        XCTAssertEqual(WalletHoldings.selection(keeping: nil, in: list, pricesRead: noPool.unread.isEmpty)?.token, musd)
        XCTAssertEqual(list.compactMap(\.value).reduce(0, +), 501.27, accuracy: 1e-9, "the total is of the priced assets")
        // Its price read failed instead (no lookup found it missing): unknown, not absent, and nothing is preselected.
        let unread = WalletHoldings.unpricedCurated(list.map(\.token), prices: valued, noPool: [])
        XCTAssertEqual(unread.unread, [cbbtc])
        XCTAssertTrue(unread.noPool.isEmpty)
        XCTAssertNil(WalletHoldings.selection(keeping: nil, in: list, pricesRead: unread.unread.isEmpty))
        XCTAssertEqual(WalletHoldings.unpricedCurated([Token.mon, meme], prices: [:]), [Token.mon], "MON's own price read can fail too")
        XCTAssertEqual(WalletHoldings.unpricedCurated([Token.mon, meme], prices: [:], noPool: []).unread, [Token.mon])
        XCTAssertEqual(WalletHoldings.unpricedCurated([Token.mon], prices: [Monad.native: 0]), [Token.mon], "a zero price is no price")
        XCTAssertTrue(WalletHoldings.unpricedCurated([meme], prices: [:], noPool: [meme.address]).noPool.isEmpty, "only curated tokens are named")

        XCTAssertEqual(WalletHoldings.symbolList([cbbtc]), "cbBTC")
        XCTAssertEqual(WalletHoldings.symbolList([cbbtc, try core("LBTC")]), "cbBTC and LBTC")
        XCTAssertEqual(WalletHoldings.symbolList([cbbtc, try core("LBTC"), try core("rETH")]), "cbBTC, LBTC and rETH")
    }

    /// The list of symbols follows the app's language as a whole, its commas included: English as it has always read,
    /// with no comma before "and" whatever the device's region, and every other language its own way of listing.
    func testASymbolListFollowsTheAppsLanguage() throws {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        let tokens = try ["cbBTC", "LBTC", "rETH"].map { symbol in try XCTUnwrap(Token.core.first { $0.symbol == symbol }) }
        let languages: [(AppLanguage, String, three: String, two: String)] = [
            (.en, "en_US", "cbBTC, LBTC and rETH", "cbBTC and LBTC"),
            (.en, "en_GB", "cbBTC, LBTC and rETH", "cbBTC and LBTC"),
            (.en, "fr_FR", "cbBTC, LBTC and rETH", "cbBTC and LBTC"),
            (.fr, "en_US", "cbBTC, LBTC et rETH", "cbBTC et LBTC"),
            (.es, "en_US", "cbBTC, LBTC y rETH", "cbBTC y LBTC"),
            (.zhHans, "en_US", "cbBTC、LBTC和rETH", "cbBTC和LBTC"),
            (.ko, "en_US", "cbBTC, LBTC 및 rETH", "cbBTC 및 LBTC"),
        ]
        for (language, device, three, two) in languages {
            L10n.locale = L10n.locale(for: language, device: Locale(identifier: device))
            let label = "\(language.code) on a \(device) device"
            XCTAssertEqual(WalletHoldings.symbolList(tokens), three, label)
            XCTAssertEqual(WalletHoldings.symbolList(Array(tokens.prefix(2))), two, label)
            XCTAssertEqual(WalletHoldings.symbolList(Array(tokens.prefix(1))), "cbBTC", label)
            XCTAssertEqual(WalletHoldings.symbolList([]), "", label)
        }
    }

    /// Dust never switches behaviour: a speck (1 wei) of a curated token no pool prices, which anyone can send to any
    /// wallet, leaves the order, the token a send starts on and the total as they were. It is only named.
    func testASpeckOfATokenWithNoPriceChangesNothing() throws {
        let aprmon = try XCTUnwrap(Token.core.first { $0.symbol == "aprMON" })
        let prices: [Address: Double] = [Monad.native: 0.03, Monad.usdc: 1]
        let balances: [Address: BigUInt] = [Monad.native: units(1_000, .mon), Monad.usdc: units(5, .usdc)]
        let clean = WalletHoldings.ranked([Token.mon, Token.usdc], balances: balances, prices: prices, unverified: [])
        let dusted = WalletHoldings.ranked([Token.mon, Token.usdc, aprmon], balances: balances.merging([aprmon.address: 1]) { a, _ in a }, prices: prices, unverified: [])
        let split = WalletHoldings.unpricedCurated(dusted.map(\.token), prices: prices, noPool: [aprmon.address])
        XCTAssertEqual(split.noPool, [aprmon], "named")
        XCTAssertTrue(split.unread.isEmpty, "no failure")
        XCTAssertEqual(dusted.map(\.token.symbol), ["MON", "USDC", "aprMON"], "after every priced token")
        XCTAssertEqual(WalletHoldings.selection(keeping: nil, in: dusted, pricesRead: split.unread.isEmpty)?.token, .mon)
        XCTAssertEqual(WalletHoldings.selection(keeping: nil, in: clean)?.token, .mon)
        XCTAssertEqual(dusted.compactMap(\.value).reduce(0, +), clean.compactMap(\.value).reduce(0, +), accuracy: 1e-9)
    }

    func testEmptyWallet() {
        let ranked = WalletHoldings.ranked([Token.mon, Token.usdc], balances: [Monad.native: 0, Monad.usdc: 0], prices: [Monad.native: 0.03], unverified: [])
        XCTAssertTrue(ranked.isEmpty)
        XCTAssertTrue(WalletHoldings.ranked([], balances: [:], prices: [:], unverified: []).isEmpty)
        XCTAssertNil(WalletHoldings.defaultChoice(ranked))
        XCTAssertNil(WalletHoldings.selection(keeping: Monad.usdc, in: ranked))
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "usdc").isEmpty)
    }

    func testSelectionKeepsTheCurrentTokenWhileItIsHeldAndNeverSwitchesToAnother() throws {
        let ranked = WalletHoldings.ranked([Token.mon, meme], balances: [Monad.native: units(100, .mon), meme.address: units(1, meme)], prices: [Monad.native: 0.03], unverified: [])
        XCTAssertEqual(WalletHoldings.selection(keeping: meme.address, in: ranked)?.id, meme.address)
        XCTAssertNil(WalletHoldings.selection(keeping: Monad.usdc, in: ranked), "no longer held: cleared, never swapped for the default under a typed amount")
        XCTAssertEqual(WalletHoldings.selection(keeping: nil, in: ranked)?.id, Monad.native, "nothing chosen yet: the default")
        // A re-read carries the kept token's fresh balance and marks.
        let reread = WalletHoldings.ranked([Token.mon, meme], balances: [Monad.native: units(100, .mon), meme.address: units(3, meme)], prices: [Monad.native: 0.03], unverified: [meme.address])
        let kept = try XCTUnwrap(WalletHoldings.selection(keeping: meme.address, in: reread))
        XCTAssertEqual(kept.balance, units(3, meme))
        XCTAssertTrue(kept.unverified)
    }

    func testSearchMatchesSymbolNameOrAddress() {
        let ranked = WalletHoldings.ranked([Token.mon, Token.usdc, fakeUSDC, meme], balances: [Monad.native: 1, Monad.usdc: 1, fakeUSDC.address: 1, meme.address: 1],
                                           prices: [:], unverified: [fakeUSDC.address])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "").count, 4)
        XCTAssertEqual(Set(WalletHoldings.matching(ranked, query: "usdc").map(\.id)), [Monad.usdc, fakeUSDC.address], "both, the look-alike marked")
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "meme coin").map(\.id), [meme.address], "by name")
        // A pasted address, with the spaces and invisible characters a copy can carry, matches that contract only.
        XCTAssertEqual(WalletHoldings.matching(ranked, query: " \u{200B}\(Monad.usdc.checksummed)\n").map(\.id), [Monad.usdc])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: fakeUSDC.address.hex.uppercased().replacingOccurrences(of: "0X", with: "0x")).map(\.id), [fakeUSDC.address])
        XCTAssertEqual(WalletHoldings.matching(ranked, query: "0x2222").map(\.id), [fakeUSDC.address], "the start of an address")
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "0x9999999999999999999999999999999999999999").isEmpty)
        XCTAssertTrue(WalletHoldings.matching(ranked, query: "nothing like it").isEmpty)
    }

    /// The sources wire it in: the Portfolio's Assets and the Send sheet read the wallet the same way (`WalletTokens`),
    /// the Send sheet starts on `selection`/`defaultChoice`, and a send's dollars come from the stables' addresses.
    func testThePortfolioAndTheSendSheetShareOneList() throws {
        var app = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { app.deleteLastPathComponent() } // DyorKitTests → Tests → DyorKit → ios
        app.appendPathComponent("DyorHQ")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("ios/DyorHQ is not in this checkout") }
        let assets = try String(contentsOf: app.appendingPathComponent("Portfolio/AssetsModel.swift"), encoding: .utf8)
        let profile = try String(contentsOf: app.appendingPathComponent("Profile/ProfileView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(profile.range(of: "struct SendSheet: View {"))
        let end = try XCTUnwrap(profile.range(of: "enum QRCode", range: start.upperBound..<profile.endIndex))
        let send = String(profile[start.upperBound..<end.lowerBound])
        for source in [assets, send] {
            XCTAssertTrue(source.contains("WalletTokens.read(env: env, address: address"))
            XCTAssertTrue(source.contains("WalletTokens.ranked(read, env: env"))
            XCTAssertFalse(source.contains("heldTokens("), "no screen reads the wallet's tokens its own way")
        }
        // Send lists MON, the curated tokens and the stored ones at once, with nothing preselected, and adds the tokens
        // the wallet's history shows when it is read: it never waits on the history to offer MON.
        XCTAssertTrue(send.contains("async let history = WalletTokens.history(env: env, address: address)"))
        XCTAssertTrue(send.contains("first = try await WalletTokens.read(env: env, address: address, history: nil)"))
        XCTAssertTrue(send.contains("show(firstRanked, complete: first.complete, readingHistory: true)"))
        XCTAssertTrue(send.contains("let scan = await history"))
        XCTAssertTrue(send.contains("let read = try? await WalletTokens.read(env: env, address: address, history: scan)"))
        let show = try XCTUnwrap(send.range(of: "private func show("))
        let shown = String(send[show.upperBound...].prefix(1_500))
        let partial = try XCTUnwrap(shown.range(of: "if readingHistory {"))
        let selection = try XCTUnwrap(shown.range(of: "WalletHoldings.selection("))
        XCTAssertLessThan(shown.distance(from: shown.startIndex, to: partial.lowerBound), shown.distance(from: shown.startIndex, to: selection.lowerBound),
                          "nothing is preselected while the history is read")
        XCTAssertTrue(shown[partial.upperBound..<selection.lowerBound].contains("return"))
        XCTAssertTrue(send.contains("let kept = WalletHoldings.selection(keeping: choice?.id, in: ranked.tokens, pricesRead: !ranked.pricesFailed)"))
        XCTAssertTrue(send.contains("usd: WalletHoldings.stableUSD(review.token, amount: review.amount)"))
        // Coming back from the token list restarts the form's tasks: the list is read once per wallet and attempt, a
        // finished recipient check stands, and Review takes only a pick from the list as read, with its Unverified mark.
        XCTAssertTrue(send.contains("if assetsKey == key { return }"))
        XCTAssertTrue(send.contains("if let running = assetsRead, running.id == key, !running.task.isCancelled { return }"))
        XCTAssertTrue(send.contains(".onDisappear { assetsRead?.task.cancel() }"))
        XCTAssertTrue(send.contains("if let to, to == checkedRecipient { return }"))
        XCTAssertTrue(send.contains("guard case .loaded = assets, choice != nil else { return false }"))
        XCTAssertTrue(send.contains("review = SendReview(asset: choice,"))
        XCTAssertTrue(send.contains("unverified = asset.unverified"))
        // A look-alike shows its contract and its label in the list (`TokenBadge.title`: "Not the real ETH", "Not the USDC
        // DyorHQ lists"), frozen with the pick for the review, which spells out every token contract.
        XCTAssertTrue(send.contains("badge: env.dyorCoins.badge(choice.token, receivedUnasked: choice.unverified))"))
        XCTAssertTrue(send.contains("private var badge: TokenBadge { env.dyorCoins.badge(asset.token, receivedUnasked: asset.unverified) }"))
        XCTAssertTrue(send.contains("TokenBadgeView(badge)"))
        XCTAssertFalse(send.contains("DyorHQ lists\""), "the label's own words, never \"Not the ETH DyorHQ lists\" for a token DyorHQ doesn't list")
        XCTAssertTrue(send.contains("DetailRow(\"Token contract\", review.token.address.checksummed, spellsOut: true)"))
        XCTAssertTrue(send.contains("if review.badge.isImitation, let title = review.badge.title { DetailRow(\"Token\", title, tint: .attention) }"))
        XCTAssertTrue(assets.contains("WalletTokens.ranked(read, env: env, by: WalletHoldings.portfolioPrecedes)"), "the Portfolio keeps its order")
        // Both lists value DyorHQ's own coins the app's way (`AppCoinValueTests`).
        let tokens = try String(contentsOf: app.appendingPathComponent("Wallet/WalletTokens.swift"), encoding: .utf8)
        XCTAssertTrue(tokens.contains("prices: valued, unverified:"))
        // The wallet's own launches and Moments aren't Unverified, in both lists; a curve buy records its coin as chosen.
        XCTAssertTrue(tokens.contains("let unverified = WalletHoldings.unverified(read.unverified, owner: read.owner, launches: own.launches, staked: own.staked)"))
        XCTAssertTrue(tokens.contains("rows.filter { $0.isCreator || $0.entitlement > 0 }"))
        XCTAssertTrue(assets.contains("Set(ranked.filter(\\.unverified).map(\\.id))"))
        let launchpad = try String(contentsOf: app.appendingPathComponent("Launchpad/LaunchpadView.swift"), encoding: .utf8)
        let buy = try XCTUnwrap(launchpad.range(of: "ConfirmationSheet(title: \"Buy \\(launch.symbol)\""))
        let bought = try XCTUnwrap(launchpad.range(of: "Activity.record(ActivityRecord(kind: .buy", range: buy.upperBound..<launchpad.endIndex))
        let settled = String(launchpad[buy.upperBound..<bought.lowerBound])
        XCTAssertTrue(settled.contains("KnownTokenStore.add(token, owner: session.address)"))
        XCTAssertTrue(settled.contains("KnownTokenStore.markChosen(launch.token, owner: session.address)"))
        // A failed price read — the whole of it, a curated token's own, or a DyorHQ coin's value — hides the Portfolio's
        // total and says so, and a send preselects nothing. A curated token no pool prices is no failure: the Portfolio totals
        // the priced assets and names what it leaves out, and a send starts on the top priced token, whatever amount of it
        // is held.
        XCTAssertTrue(assets.contains("failed = result.pricesFailed"))
        XCTAssertTrue(assets.contains("unpricedHeld = result.unpriced"))
        XCTAssertTrue(assets.contains("var showsTotal: Bool { !pricesFailed && totalValue > 0 }"))
        XCTAssertTrue(assets.contains("else if kind == .assets, model.showsTotal {"))
        XCTAssertTrue(assets.contains("case (true, true): return tokens.isEmpty ? nil : tr(\"Some prices couldn't be read, so values are missing and no total is shown.\")"))
        XCTAssertTrue(assets.contains("if kind == .assets, model.showsTotal, !model.unpriced.isEmpty, !model.loading {"))
        XCTAssertTrue(assets.contains("Paragraph(\"Doesn't include \\(WalletHoldings.symbolList(model.unpriced)): no price found.\")"))
        XCTAssertFalse(assets.contains("valuesMissing"))
        XCTAssertTrue(tokens.contains("let pooled = WalletHoldings.stablesAtPar(prices.mapValues(\\.usd), tokens: read.tokens)"))
        XCTAssertTrue(tokens.contains("noPool = await env.prices.withoutPool(read.tokens)"))
        XCTAssertTrue(tokens.contains("let unpriced = WalletHoldings.unpricedCurated(read.tokens, prices: valued, noPool: noPool)"))
        XCTAssertTrue(tokens.contains("pricesFailed: failed || !own.complete || !unpriced.unread.isEmpty, unpriced: unpriced.noPool,"))
        XCTAssertFalse(tokens.contains("valuesMissing"))
        XCTAssertFalse(send.contains("No price was found"), "no pool is no gap in the Send list: the row reads No price")
        XCTAssertTrue(send.contains("guard let value = asset.value else { return tr(\"No price\") }"), "in the app's language")
        // A token whose symbol isn't plain shows its contract in the list.
        XCTAssertTrue(send.contains("return asset.unverified || !asset.plainSymbol || badge.isWarning ?"))
        // After a new read of the list (Retry), Available and Max are the kept pick's balance from that read, then read again.
        XCTAssertTrue(send.contains(".task(id: balanceReadKey)"))
        XCTAssertTrue(send.contains("private var balanceReadKey: String { \"\\(token?.address.hex ?? \"\")#\\(assetsKey ?? \"\")\" }"))
        XCTAssertTrue(send.contains("balance = kept?.balance"))
        // The wallet's own coins are recorded as chosen, so Home marks them as the lists do; a launch records its coin.
        XCTAssertTrue(tokens.contains("let ownCoins = WalletHoldings.ownCoins(owner: read.owner, launches: own.launches, staked: own.staked)"))
        XCTAssertTrue(tokens.contains("markOwnCoins(ownCoins, among: read.tokens, owner: read.owner)"))
        XCTAssertTrue(tokens.contains("KnownTokenStore.markChosen(token.address, owner: owner)"), "the shared helper (`WalletTokens.markOwnCoins`)")
        let create = try XCTUnwrap(launchpad.range(of: "title: \"Launch \\(symbol)\", confirmTitle: \"Launch \\(symbol)\""))
        let launched = String(launchpad[create.upperBound...].prefix(2_500))
        XCTAssertTrue(launched.contains("result.deployer == owner"))
        XCTAssertTrue(launched.contains("KnownTokenStore.markChosen(result.token, owner: owner)"))
        XCTAssertFalse(send.contains("portfolioPrecedes"), "the Send list ranks by value, unpriced last")
        XCTAssertFalse(send.contains("Token.core.filter"), "no fixed short list")
        XCTAssertFalse(send.contains("\"USDC\", \"USDT0\""), "dollars are never decided by symbol")
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        return items.indices.flatMap { i -> [[T]] in
            var rest = items
            let head = rest.remove(at: i)
            return permutations(rest).map { [head] + $0 }
        }
    }
}

/// Whether a send would go through, asked of the chain before the review offers Send.
final class TokenTransferTests: XCTestCase {
    private let token = Token(address: Address(literal: "0x6666666666666666666666666666666666666666"), symbol: "ABC", name: "Abc", decimals: 18)
    private let owner = Address(literal: "0x7777777777777777777777777777777777777777")
    private let recipient = Address(literal: "0x8888888888888888888888888888888888888888")

    func testRequestIsTheValueForMonAndTransferForAToken() throws {
        let mon = try TokenTransfer.request(.mon, to: recipient, amount: 5)
        XCTAssertEqual(mon, TransactionRequest(to: recipient, value: 5))
        let erc20 = try TokenTransfer.request(token, to: recipient, amount: 5)
        XCTAssertEqual(erc20, TransactionRequest(to: token.address, data: try ERC20.transferCalldata(to: recipient, amount: 5)))
    }

    func testATransferThatGoesThroughIsNotRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? try! ABI.encode([.bool(true)], "bool") : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal)
        XCTAssertEqual(MomentsChainStub.calls().map(\.selector), [ABI.selector("transfer(address,uint256)").hexString])
    }

    func testATokenThatReturnsNothingIsNotRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? Data() : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal, "a token that returns no bool (USDT-style) still moved the funds")
    }

    func testARevertIsRefused() async {
        MomentsChainStub.install { _, _ in nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertEqual(refusal, "This send would fail: execution reverted.")
    }

    /// A reason that already ends a sentence keeps its own mark, in any script: a reason in Chinese ends with "。", which a
    /// check for "." alone followed with a second full stop. One that doesn't end a sentence gets the full stop.
    func testAReasonEndsItsSentenceOnce() {
        let saved = L10n.locale
        defer { L10n.locale = saved }
        L10n.locale = Locale(identifier: "en_US")
        XCTAssertEqual(TokenTransfer.wouldFail("Not enough MON to pay for gas."), "This send would fail: Not enough MON to pay for gas.")
        XCTAssertEqual(TokenTransfer.wouldFail("execution reverted"), "This send would fail: execution reverted.")
        XCTAssertEqual(TokenTransfer.wouldFail("余额不足。"), "This send would fail: 余额不足。")
        for reason in ["Paused.", "Trading isn't open yet!", "Is trading open?", "余额不足。", "交易已暂停！", "交易开放了吗？"] {
            XCTAssertTrue(TokenTransfer.endsASentence(reason), reason)
            XCTAssertEqual(TokenTransfer.wouldFail(reason), L10n.tr("This send would fail: \(reason)"), reason)
        }
        for reason in ["execution reverted", "Pausable: paused", "The contract rejected the transaction (custom error 0xdeadbeef)"] {
            XCTAssertFalse(TokenTransfer.endsASentence(reason), reason)
            XCTAssertEqual(TokenTransfer.wouldFail(reason), L10n.tr("This send would fail: \(reason)."), reason)
        }
    }

    func testATokenThatReturnsFalseIsRefused() async {
        let contract = token.address
        MomentsChainStub.install { to, _ in to == contract ? try! ABI.encode([.bool(false)], "bool") : nil }
        let refusal = await TokenTransfer.refusal(token, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertEqual(refusal, "The ABC contract refused this transfer, so nothing would be sent.")
    }

    func testMonToAWalletIsNotRefused() async {
        let payee = recipient
        MomentsChainStub.install { to, data in to == payee && data.isEmpty ? Data() : nil }
        let refusal = await TokenTransfer.refusal(.mon, to: recipient, amount: 5, from: owner, rpc: MomentsChainStub.rpc())
        XCTAssertNil(refusal)
    }

    func testOnlyARevertCountsAsARefusal() {
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: 3, message: "execution reverted", data: "0x08c379a0")))
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: -32000, message: "execution reverted")))
        XCTAssertTrue(TokenTransfer.isRevert(RPCError(code: -32000, message: "insufficient funds for transfer")))
        XCTAssertFalse(TokenTransfer.isRevert(RPCError(code: 429, message: "Too many requests")))
        XCTAssertFalse(TokenTransfer.isRevert(RPCError(code: -1, message: "Missing response")))
    }
}

/// DyorHQ's own coins are valued as the app values them, not left unpriced below priced dust: a launch coin at its live
/// price in its pair asset, a Moment coin at its pool's price (`WalletHoldings.pricing`), from the launch each held
/// coin's factory recorded (`LaunchpadService.heldLaunches`).
final class AppCoinValuationTests: XCTestCase {
    private let launchCoin = Token(address: Address(literal: "0x00000000000000000000000000000000000c1001"), symbol: "GRAD", name: "Graduated", decimals: 18, isLaunchpad: true)
    private let monCoin = Token(address: Address(literal: "0x00000000000000000000000000000000000c1002"), symbol: "CURVE", name: "On a curve", decimals: 18, isLaunchpad: true)
    private let momentCoin = Token(address: Address(literal: "0x00000000000000000000000000000000000c1003"), symbol: "NATURE", name: "Nature", decimals: 18)
    private let unreadMoment = Token(address: Address(literal: "0x00000000000000000000000000000000000c1004"), symbol: "UNREAD", name: "Unread", decimals: 18)
    private let usdcPair = PairInfo(address: Monad.usdc, symbol: "USDC", decimals: 6, isNative: false)

    override func tearDown() {
        MomentsChainStub.install { _, _ in nil }
        super.tearDown()
    }

    private func units(_ whole: Double, _ token: Token) -> BigUInt { Amount.raw(whole, decimals: token.decimals) }

    private func launch(_ token: Token, pair: PairInfo, price: BigUInt, phase: LaunchPhase = .graduated) -> Launch {
        Launch(token: token.address, curve: Address(literal: "0x00000000000000000000000000000000000c02c0"), deployer: .zero, creatorFeeRecipient: .zero,
               pairToken: pair.address, graduationThreshold: 0, creatorTaxBps: 0, poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false,
               graduationVenue: .uniswapV4, phase: phase, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, poolId: Data(count: 32), name: token.name,
               symbol: token.symbol, logo: "", description: "", socials: .none, pair: pair, price: price, realQuoteReserve: 0, completed: phase == .graduated,
               rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0)
    }

    /// The finding's wallet: 2,000,000 of a graduated launch coin (about $400 on Home), 1,500 of a Moment coin ($30) and
    /// 0.5 MON ($0.015). Without the app's valuations the coins read "No price" and MON leads; with them, value leads.
    func testLaunchAndMomentCoinsAreValuedTheAppsWay() {
        let universe = [Token.mon, launchCoin, momentCoin]
        let balances: [Address: BigUInt] = [Monad.native: units(0.5, .mon), launchCoin.address: units(2_000_000, launchCoin), momentCoin.address: units(1_500, momentCoin)]
        let pools: [Address: Double] = [Monad.native: 0.03]
        let unvalued = WalletHoldings.ranked(universe, balances: balances, prices: pools, unverified: [])
        XCTAssertEqual(unvalued.map(\.token.symbol), ["MON", "GRAD", "NATURE"], "the pool finder alone: both coins unpriced, below MON")

        // 0.0002 USDC per coin, live; the Moment's pool at $0.02.
        let launches = held([launchCoin.address: launch(launchCoin, pair: usdcPair, price: 200)], prices: [launchCoin.address: 0.0002])
        let priced = WalletHoldings.pricing(pools.merging([Monad.usdc: 1]) { a, _ in a }, launches: launches, moments: [momentCoin.address: 0.02])
        let ranked = WalletHoldings.ranked(universe, balances: balances, prices: priced, unverified: [])
        XCTAssertEqual(ranked.map(\.token.symbol), ["GRAD", "NATURE", "MON"])
        XCTAssertEqual(ranked[0].value ?? 0, 400, accuracy: 1e-6)
        XCTAssertEqual(ranked[1].value ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(WalletHoldings.defaultChoice(ranked)?.token, launchCoin, "the highest-value asset is the default")
        XCTAssertEqual(try XCTUnwrap(priced[launchCoin.address]), 0.0002, accuracy: 1e-15, "the live price in the pair, times the pair's dollar price")
    }

    /// `launches` as `heldLaunches` reads them: each recorded by the live factory, with its record's deployer and pair, and
    /// `prices` as the live prices read.
    private func held(_ launches: [Address: Launch], prices: [Address: Double]) -> HeldLaunches {
        HeldLaunches(factories: launches.mapValues { _ in V2Fixture.launchpad.factory }, phases: launches.mapValues(\.phase), deployers: launches.mapValues(\.deployer),
                     pairAssets: launches.mapValues(\.pairToken), launches: launches, pairPerCoin: prices)
    }

    func testAnAppCoinIsNeverValuedAtAnotherPoolsPrice() {
        // A MON-paired launch coin: valued through MON's price, never at the price some other pool quotes for it.
        let curve = launch(monCoin, pair: .mon, price: BigUInt(2) * BigUInt(10).power(14), phase: .bonding)
        let launches = held([monCoin.address: curve], prices: [monCoin.address: 0.0002])
        let priced = WalletHoldings.pricing([Monad.native: 0.03, monCoin.address: 99, momentCoin.address: 99, unreadMoment.address: 99, Monad.usdc: 1],
                                            launches: launches, moments: [momentCoin.address: 0.02, unreadMoment.address: nil])
        XCTAssertEqual(priced[monCoin.address] ?? 0, 0.0002 * 0.03, accuracy: 1e-15)
        XCTAssertEqual(priced[momentCoin.address], 0.02)
        XCTAssertNil(priced[unreadMoment.address], "a Moment whose pool wasn't read is unpriced, not the other pool's 99")
        XCTAssertEqual(priced[Monad.usdc], 1, "every other token keeps its price")
        let noMON = WalletHoldings.pricing([monCoin.address: 99], launches: launches, moments: [:])
        XCTAssertNil(noMON[monCoin.address], "no price for the pair asset: unpriced")
        // Recorded, but its launch or live price couldn't be read: unpriced, never the other pool's 99 nor $0.
        let unread = HeldLaunches(factories: [monCoin.address: V2Fixture.launchpad.factory], phases: [monCoin.address: .bonding], deployers: [monCoin.address: .zero],
                                  pairAssets: [monCoin.address: .zero], launches: [:], pairPerCoin: [:])
        XCTAssertFalse(unread.complete)
        XCTAssertNil(WalletHoldings.pricing([Monad.native: 0.03, monCoin.address: 99], launches: unread, moments: [:])[monCoin.address])
        let zero = held([monCoin.address: curve], prices: [monCoin.address: 0])
        XCTAssertNil(WalletHoldings.pricing([Monad.native: 0.03], launches: zero, moments: [:])[monCoin.address], "a zero price is no price")
    }

    /// A DyorHQ coin the wallet launched, or whose Moment it collected or created, is its own and not Unverified; the same
    /// kinds of coin merely sent to it stay Unverified.
    func testTheWalletsOwnCoinsAreNotUnverified() {
        let owner = Address(literal: "0x7777777777777777777777777777777777777777")
        let stranger = Address(literal: "0x8888888888888888888888888888888888888888")
        let airdropped = Token(address: Address(literal: "0x00000000000000000000000000000000000c1005"), symbol: "GIFT", name: "Gift", decimals: 18, isLaunchpad: true)
        let spam = Address(literal: "0x00000000000000000000000000000000000c1006")
        func launched(_ token: Token, by deployer: Address) -> Launch {
            let l = launch(token, pair: .mon, price: 1)
            return Launch(token: l.token, curve: l.curve, deployer: deployer, creatorFeeRecipient: deployer, pairToken: l.pairToken, graduationThreshold: 0, creatorTaxBps: 0,
                          poolFeeBps: 100, tickSpacing: 60, holderFeeSharing: false, graduationVenue: .uniswapV4, phase: .bonding, sweptQuote: 0, sweptTokens: 0, sweptAt: 0,
                          poolId: Data(count: 32), name: token.name, symbol: token.symbol, logo: "", description: "", socials: .none, pair: .mon, price: 1, realQuoteReserve: 0,
                          completed: false, rescued: false, launchedAt: 0, supply: 0, marketCap: 0, progressBps: 0)
        }
        let marked: Set<Address> = [monCoin.address, airdropped.address, momentCoin.address, unreadMoment.address, spam]
        let launches = held([monCoin.address: launched(monCoin, by: owner), airdropped.address: launched(airdropped, by: stranger)], prices: [:])
        let result = WalletHoldings.unverified(marked, owner: owner, launches: launches, staked: [momentCoin.address])
        XCTAssertEqual(result, [airdropped.address, unreadMoment.address, spam],
                       "its own launch and its collected Moment are its own; another's launch, a Moment it has no stake in and anything else stay marked")
        XCTAssertTrue(WalletHoldings.unverified([], owner: owner, launches: launches, staked: [momentCoin.address]).isEmpty)
        XCTAssertEqual(WalletHoldings.ownCoins(owner: owner, launches: launches, staked: [momentCoin.address]), [monCoin.address, momentCoin.address])
        // The deployer comes from the factory's record: a launch whose launch read failed is still the wallet's own.
        let recordOnly = HeldLaunches(factories: [monCoin.address: V2Fixture.launchpad.factory], phases: [monCoin.address: .bonding], deployers: [monCoin.address: owner],
                                      pairAssets: [monCoin.address: .zero], launches: [:], pairPerCoin: [:])
        XCTAssertEqual(WalletHoldings.unverified(marked, owner: owner, launches: recordOnly, staked: []), marked.subtracting([monCoin.address]))
    }

    /// A held coin's launch, found in any phase from its factory's record, on the live launchpad or a retired one; MON,
    /// the curated tokens and coins no factory recorded are left out, and a read that fails throws. A coin on its curve
    /// is priced from the reserves read with its launch (`Launch.pairPrice`); this fixture answers no pool price, so a
    /// graduated one is recorded and read, and unpriced.
    func testHeldLaunchesFindHeldCoinsInAnyPhase() async throws {
        let service = LaunchpadService(rpc: MomentsChainStub.rpc(), addresses: V2Fixture.launchpad, logsRPC: MomentsChainStub.rpc())
        let stranger = Token(address: Address(literal: "0x00000000000000000000000000000000000c0300"), symbol: "NEW", name: "New coin", decimals: 18)
        for stack in [V2Fixture.launchpad] + LaunchpadAddresses.retiredStacks {
            for phase in [LaunchPhase.bonding, .graduated, .refund] {
                let chain = CurveCoinChain(stack: stack, phase: phase, rescued: phase == .refund)
                let coin = Token(address: chain.coin, symbol: "OLD", name: "Old coin", decimals: 18, isLaunchpad: true)
                let label = "\(stack.factory.short) \(phase)"
                MomentsChainStub.install(chain.answer)
                let found = try await service.heldLaunches([.mon, .usdc, coin, stranger, coin])
                XCTAssertEqual(Array(found.factories.keys), [chain.coin], label)
                XCTAssertEqual(found.factories[chain.coin], stack.factory, label)
                XCTAssertEqual(found.phases[chain.coin], phase, label)
                let launch = try XCTUnwrap(found.launches[chain.coin], label)
                XCTAssertEqual(launch.phase, phase, label)
                XCTAssertEqual(launch.factory, stack.factory, label)
                if phase == .graduated {
                    XCTAssertNil(found.pairPerCoin[chain.coin], "\(label): no pool price answered")
                    XCTAssertFalse(found.complete, label)
                } else {
                    XCTAssertEqual(try XCTUnwrap(found.pairPerCoin[chain.coin], label), 1e-24, accuracy: 1e-36, "\(label): 1,000 wei per 1e9 coins, read with its launch")
                    XCTAssertEqual(found.pairPerCoin[chain.coin], launch.pairPrice, label)
                    XCTAssertTrue(found.complete, label)
                }
                XCTAssertEqual(found.curve.coins, phase == .graduated ? [] : [chain.coin], label)
                let asked = Set(MomentsChainStub.batches().first?.map(\.to) ?? [])
                XCTAssertEqual(asked, Set(CurveCoinChain.factories.map(\.factory)), "\(label): the coin and the stranger, asked of every factory; MON and USDC never")
            }
        }
    }
}
