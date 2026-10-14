import BigInt
import XCTest
@testable import DyorKit

/// The badge a token shows: DyorHQ's own coins say where they were made — "DyorHQ Launch" or "DyorHQ Moment", a Chinese,
/// Japanese or Korean symbol included — instead of "Unverified", while a look-alike keeps its warning whatever made it,
/// and what counts as received (a send's default, Top Tokens, the picker) is unchanged (IOST-12).
final class TokenBadgeTests: XCTestCase {
    private let creator = Address(literal: "0x90f3e7c3B4E32494b06814Fd2F4556671F5F4C47")

    private func launchCoin(_ address: Address, symbol: String, name: String = "Coin") -> DyorCoin {
        DyorCoin(address: address, origin: .launch(factory: DyorCoinChain.legacy, generation: .legacy, retired: true), symbol: symbol, name: name, creator: creator,
                 logo: "", pair: .zero)
    }

    private func token(_ address: String, _ symbol: String, name: String = "Coin") -> Token {
        Token(address: Address(literal: address), symbol: symbol, name: name, decimals: 18)
    }

    func testTheRuleInOrder() {
        let qt = token("0x73F942e084Ab047a94e4E3B5D6ae571e23A51856", "QT", name: "Quet")
        let qtCoin = launchCoin(qt.address, symbol: "QT", name: "Quet")
        // 1. MON and the curated tokens: nothing, whatever else is said of them.
        XCTAssertEqual(TokenBadge.of(.mon, coin: nil, receivedUnasked: true), .none)
        XCTAssertEqual(TokenBadge.of(.usdc, coin: nil, receivedUnasked: true), .none)
        // 2. A DyorHQ launch called "USDC" warns, as any look-alike does.
        let usdcLaunch = token("0x0000000000000000000000000000000000000c01", "USDC")
        XCTAssertEqual(TokenBadge.of(usdcLaunch, coin: launchCoin(usdcLaunch.address, symbol: "USDC"), receivedUnasked: false), .imitates(.usdc))
        let monadName = token("0x0000000000000000000000000000000000000c02", "MND", name: "Monad")
        XCTAssertEqual(TokenBadge.of(monadName, coin: launchCoin(monadName.address, symbol: "MND", name: "Monad"), receivedUnasked: true), .imitates(.mon))
        // 3. A DyorHQ coin whose symbol isn't display-safe is Unverified.
        let cyrillic = token("0x0000000000000000000000000000000000000c03", "Q\u{0422}")
        XCTAssertEqual(TokenBadge.of(cyrillic, coin: launchCoin(cyrillic.address, symbol: "Q\u{0422}"), receivedUnasked: false), .unverified)
        // 4. A DyorHQ coin, received or chosen, a CJK symbol included.
        XCTAssertEqual(TokenBadge.of(qt, coin: qtCoin, receivedUnasked: true), .dyorLaunch)
        XCTAssertEqual(TokenBadge.of(qt, coin: qtCoin, receivedUnasked: false), .dyorLaunch)
        let doge = token("0x0000000000000000000000000000000000000c04", "狗狗")
        XCTAssertEqual(TokenBadge.of(doge, coin: launchCoin(doge.address, symbol: "狗狗"), receivedUnasked: true), .dyorLaunch)
        let nat = token("0x43682FA268A98a87C946d0b933203a8834b391BF", "NAT", name: "Nature")
        let natCoin = DyorCoin(address: nat.address, origin: .moment(factory: DyorCoinChain.c3, id: 1, retired: true), symbol: "NAT", name: "Nature", creator: creator,
                               logo: "ipfs://x", mediaHash: Data(count: 32), mediaIsVideo: true, pair: Monad.usdc)
        XCTAssertEqual(TokenBadge.of(nat, coin: natCoin, receivedUnasked: true), .dyorMoment)
        // 5. Received unasked, not DyorHQ's (JAMES, from another launchpad): Unverified.
        let james = token(DyorCoinChain.james.hex, "JAMES")
        XCTAssertEqual(TokenBadge.of(james, coin: nil, receivedUnasked: true), .unverified)
        // 6. Chosen, not DyorHQ's: nothing.
        XCTAssertEqual(TokenBadge.of(james, coin: nil, receivedUnasked: false), .none)
        // A chosen token with a symbol that isn't display-safe still warns.
        XCTAssertEqual(TokenBadge.of(token("0x0000000000000000000000000000000000000c05", "PEPE\u{200B}"), coin: nil, receivedUnasked: false), .unverified)
    }

    /// The token's own name is read, and so is what its contract says: a stored snapshot that says "QT" doesn't hide a
    /// coin whose contract calls itself "USDC". An entry for another address counts for nothing.
    func testTheCoinsOwnSymbolIsReadToo() {
        let snapshot = token("0x0000000000000000000000000000000000000c06", "QT")
        XCTAssertEqual(TokenBadge.of(snapshot, coin: launchCoin(snapshot.address, symbol: "USDC"), receivedUnasked: true), .imitates(.usdc))
        XCTAssertEqual(TokenBadge.of(snapshot, coin: launchCoin(snapshot.address, symbol: "Q\u{0422}"), receivedUnasked: true), .unverified)
        let elsewhere = launchCoin(Address(literal: "0x0000000000000000000000000000000000000c07"), symbol: "QT")
        XCTAssertEqual(TokenBadge.of(snapshot, coin: elsewhere, receivedUnasked: true), .unverified, "another coin's entry proves nothing")
        XCTAssertEqual(TokenBadge.of(snapshot, coin: elsewhere, receivedUnasked: false), .none)
    }

    func testTitles() {
        XCTAssertNil(TokenBadge.none.title)
        XCTAssertEqual(TokenBadge.dyorLaunch.title, "DyorHQ Launch")
        XCTAssertEqual(TokenBadge.dyorMoment.title, "DyorHQ Moment")
        XCTAssertEqual(TokenBadge.unverified.title, "Unverified")
        XCTAssertEqual(TokenBadge.imitates(.usdc).title, "Not the USDC DyorHQ lists")
        XCTAssertFalse(TokenBadge.dyorLaunch.isWarning || TokenBadge.dyorMoment.isWarning || TokenBadge.none.isWarning)
        XCTAssertTrue(TokenBadge.unverified.isWarning && TokenBadge.imitates(.mon).isWarning)
        for title in [TokenBadge.none, .dyorLaunch, .dyorMoment, .unverified, .imitates(.usdc)].compactMap(\.title) {
            XCTAssertFalse(title.replacingOccurrences(of: "Unverified", with: "").contains("Verified"), "never \"Verified\": anyone can launch for 5 MON")
        }
    }

    /// A DyorHQ coin sent to the wallet shows its DyorHQ label, and is still what IOST-12 protects against: never where a
    /// send starts, ranked with the tokens the user chose.
    func testAReceivedDyorHQCoinIsLabelledButStaysReceived() {
        let qt = token("0x73F942e084Ab047a94e4E3B5D6ae571e23A51856", "QT", name: "Quet")
        let held = HeldToken(token: qt, balance: BigUInt(10).power(24), usd: 1_000, unverified: true)
        let usdc = HeldToken(token: .usdc, balance: 1_000_000, usd: 1)
        XCTAssertEqual(held.badge(launchCoin(qt.address, symbol: "QT", name: "Quet")), .dyorLaunch)
        XCTAssertTrue(held.unverified, "the label changes nothing about what was received")
        XCTAssertNil(WalletHoldings.defaultChoice([held]), "a received DyorHQ coin is never preselected to send")
        XCTAssertEqual(WalletHoldings.defaultChoice([held, usdc])?.token, .usdc)
        let chosen = HeldToken(token: token("0x0000000000000000000000000000000000000c08", "MEME"), balance: BigUInt(10).power(24), usd: 1_000)
        XCTAssertTrue(WalletHoldings.precedes(chosen, held), "chosen before received, at the same value")
    }
}
