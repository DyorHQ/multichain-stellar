import XCTest
@testable import DyorKit

/// Tokens stored by builds that didn't mark discovered tokens are marked Unverified once, on upgrade (security audit
/// 2026-09-26, IOST-12).
final class UnverifiedTokensTests: XCTestCase {
    func testEveryStoredTokenButNativeAndCuratedIsMarkedOnUpgrade() {
        let fakeUSDC = Token(address: Address(literal: "0x1111111111111111111111111111111111111111"), symbol: "USDC", name: "USD Coin", decimals: 6)
        let bought = Token(address: Address(literal: "0x2222222222222222222222222222222222222222"), symbol: "ABC", name: "Abc", decimals: 18)
        let curated = Token.usdc
        let native = Token.mon
        let marked = Address(literal: "0x3333333333333333333333333333333333333333")
        let result = WalletTokenDiscovery.unverifiedAfterUpgrade(stored: [fakeUSDC, bought, curated, native], alreadyUnverified: [marked])
        XCTAssertEqual(result, [fakeUSDC.address, bought.address, marked], "a fake USDC is marked; the curated USDC and MON never are")
        XCTAssertTrue(WalletTokenDiscovery.unverifiedAfterUpgrade(stored: [], alreadyUnverified: []).isEmpty)
    }
}
