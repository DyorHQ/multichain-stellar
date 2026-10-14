import XCTest
@testable import DyorKit

/// U+FFFD — what bytes that aren't text read as — shows as a mark, not a letter, so it can't keep a token from being
/// seen as imitating a curated one: "USDC" and one invalid byte reads "USDC�", and is flagged like any other "USDC".
/// Uses `WalletHoldings.imitated(by:)` only, so the same file shows what earlier builds answered.
final class LookAlikeReplacementTests: XCTestCase {
    private func token(_ symbol: String, name: String = "Some Token") -> Token {
        Token(address: Address(literal: "0x000000000000000000000000000000000000f00d"), symbol: symbol, name: name, decimals: 6)
    }

    func testAReplacementCharacterDoesntHideAnImitation() {
        XCTAssertEqual(WalletHoldings.imitated(by: token("USDC\u{FFFD}"))?.symbol, "USDC")
        XCTAssertEqual(WalletHoldings.imitated(by: token("US\u{FFFD}DC"))?.symbol, "USDC")
        XCTAssertEqual(WalletHoldings.imitated(by: token("\u{FFFD}\u{FFFD}MON"))?.symbol, "MON")
        XCTAssertEqual(WalletHoldings.imitated(by: token("X", name: "Monad\u{FFFD}"))?.symbol, "MON")
    }

    func testReplacementCharactersAloneImitateNothing() {
        XCTAssertNil(WalletHoldings.imitated(by: token("\u{FFFD}", name: "\u{FFFD}\u{FFFD}")))
        XCTAssertNil(WalletHoldings.imitated(by: token("PEPE\u{FFFD}", name: "Pepe")))
    }
}
