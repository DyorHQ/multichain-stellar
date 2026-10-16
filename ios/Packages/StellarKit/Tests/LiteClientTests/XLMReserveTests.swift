import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// The minimum balance, spendable XLM and Max (DESIGN-stellar-parity §4.5), checked against the design's worked
/// examples to the stroop, with a base reserve of 0.5 XLM.
final class XLMReserveTests: XCTestCase {
    private let halfXLM: Int64 = 5_000_000

    func testAFriendbotAccountWithUSDCEnabled() throws {
        // Balance 10,000, one subentry (the USDC trustline): 1.5 XLM kept, 9,998.5 spendable, and Max of an XLM → USDC
        // Soroswap swap whose fee is estimated at 0.05 XLM is 9,998.4375.
        let account = XLMReserve(balance: 100_000_000_000, baseReserve: halfXLM, subentries: 1)
        XCTAssertEqual(account.minBalance, 15_000_000)
        XCTAssertEqual(account.spendable, 99_985_000_000)
        XCTAssertEqual(account.maxSend(feeEstimate: 500_000), 99_984_375_000)
    }

    func testTheAccountFixtureRecomputesToItsOwnFigures() throws {
        let position = try XCTUnwrap(ApiFixtures.decode("account", as: AccountView.self).xlm)
        let account = try XCTUnwrap(XLMReserve(position))
        XCTAssertEqual(account, XLMReserve(balance: 100_000_000_000, baseReserve: halfXLM, subentries: 1))
        XCTAssertEqual(String(account.minBalance), position.minBalance)
        XCTAssertEqual(String(account.spendable), position.spendable)
    }

    func testAMainnetSponsoredAccount() {
        // Balance 0, one subentry, three reserves sponsored by DyorHQ: nothing kept and nothing to spend, so the starter
        // swap is eligible.
        let account = XLMReserve(balance: 0, baseReserve: halfXLM, subentries: 1, sponsored: 3)
        XCTAssertEqual(account.minBalance, 0)
        XCTAssertEqual(account.spendable, 0)
        XCTAssertEqual(account.maxSend(feeEstimate: 500_000), 0)
    }

    func testAfterAStarterSwapDeliveredTwoXLM() {
        let account = XLMReserve(balance: 20_000_000, baseReserve: halfXLM, subentries: 1, sponsored: 3)
        XCTAssertEqual(account.minBalance, 0)
        XCTAssertEqual(account.spendable, 20_000_000)
    }

    func testEnablingAnotherAssetHoldsHalfAnXLMOfTheUsersOwn() {
        // Enabling EURC later: the review's reserveDelta of 1 comes off Max, and once enabled the minimum is 2 XLM.
        let account = XLMReserve(balance: 100_000_000_000, baseReserve: halfXLM, subentries: 1)
        XCTAssertEqual(account.maxSend(feeEstimate: 500_000, newReserves: 1), 99_984_375_000 - 5_000_000)
        XCTAssertEqual(account.reserves(1), 5_000_000)
        XCTAssertEqual(XLMReserve(balance: 100_000_000_000, baseReserve: halfXLM, subentries: 2).minBalance, 20_000_000)
    }

    func testLiabilitiesSponsoringAndTheFloors() {
        let offers = XLMReserve(balance: 30_000_000, baseReserve: halfXLM, subentries: 1, sellingLiabilities: 10_000_000)
        XCTAssertEqual(offers.spendable, 5_000_000)
        let sponsoring = XLMReserve(balance: 30_000_000, baseReserve: halfXLM, sponsoring: 2)
        XCTAssertEqual(sponsoring.minBalance, 20_000_000)
        let short = XLMReserve(balance: 10_000_000, baseReserve: halfXLM, subentries: 1)
        XCTAssertEqual(short.spendable, 0, "never below zero")
        XCTAssertEqual(short.maxSend(feeEstimate: 100), 0)
        XCTAssertEqual(XLMReserve(balance: .max, baseReserve: .max, subentries: .max, sponsoring: .max).spendable, 0, "no overflow")
    }

    func testAPositionThatIsntWholeStroopsIsRefused() throws {
        let json = #"{"balance":"1.5","minBalance":"0","sellingLiabilities":"0","spendable":"0","baseReserve":"5000000","reserves":{"base":2,"subentries":0,"sponsoring":0,"sponsored":0}}"#
        let position = try JSONDecoder().decode(StellarXLMPosition.self, from: Data(json.utf8))
        XCTAssertNil(XLMReserve(position))
    }
}
