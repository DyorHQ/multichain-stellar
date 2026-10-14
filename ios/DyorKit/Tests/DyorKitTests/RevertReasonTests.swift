import XCTest
@testable import DyorKit

/// The named custom errors of the DyorHQ contracts (v1 and v2): every selector pinned against `cast sig "<Name>()"`,
/// shared selectors included, and each decoded to its sentence the way `TransactionSender.prepare` sees a revert.
final class RevertReasonTests: XCTestCase {
    /// (error, `cast sig`) — the whole table, so adding or dropping a name is a reviewed change.
    static let pinned: [(String, String)] = [
        // Shared by several contracts.
        ("ModulesNotSet", "0x68cfa8e4"), ("ZeroAddress", "0xd92e233d"), ("NothingToClaim", "0x969bf728"),
        ("InsufficientGasForGraduation", "0x9a697b0d"), ("PriceOutOfRange", "0x37c8a83c"), ("NotGraduated", "0xd66173a5"),
        // Moments factory.
        ("TermsChanged", "0x4ec0a691"), ("Paused", "0x9e87fac8"), ("PriceTooHigh", "0x24fe1192"), ("PriceTooLow", "0xdbbbe822"),
        ("AllocTooHigh", "0xc163c07e"), ("BadWindow", "0x5419376a"), ("UnknownMoment", "0xdfcaf295"), ("PolicyLapsed", "0x5597e308"),
        ("NotGuardian", "0xef6d0f02"), ("NotGovernanceOrGuardian", "0xe88f4125"), ("UnpauseFirst", "0xe81d869d"), ("BaseURITooLong", "0x0bcf5189"),
        // Moments collect, graduation and vesting.
        ("NotCollecting", "0x7a984223"), ("CollectWindowClosed", "0xa818d914"), ("BadQuantity", "0x888e58a8"), ("NotExpirable", "0x41919ed3"),
        ("WrongState", "0xde4168ba"), ("NotBeneficiary", "0x644d871f"), ("NothingToWithdraw", "0xd0d04f60"), ("NotPending", "0x7dc6505a"),
        ("AlreadyGraduated", "0xe6a0d45f"),
        // Moments buyback.
        ("TooSoon", "0x6fed7d85"), ("BelowMinimum", "0x860b82a9"), ("Slippage", "0x7dd37f70"), ("PriceMoved", "0x38aa5c15"),
        // Launchpad factory.
        ("NotWhitelisted", "0x584a7938"), ("LaunchConfigDisabled", "0xa8b63076"), ("PairTokenNotApproved", "0x49285dfb"),
        ("PairRequiresMonday", "0x7b5da591"), ("GraduationVenueUnavailable", "0x0e19b99a"), ("LaunchFeeNotPaid", "0x7e6d78a5"),
        ("CreatorTaxTooHigh", "0x9ad465dc"), ("ExemptionListTooLong", "0x021c0d43"), ("LaunchEconomicsMismatch", "0x3cba147e"),
        ("UnknownLaunch", "0xf6806bf8"), ("WrongGraduationPhase", "0x9465dbd4"), ("FallbackNotAvailable", "0xc31e9f61"),
        ("Create2Mismatch", "0xcea6dd60"), ("InvalidTickSpacing", "0x270815a0"),
        // Bonding curve.
        ("CurveNotTrading", "0x8b84e37b"), ("CurveIsCompleted", "0x35a46eea"), ("SlippageExceeded", "0x8199f5f3"),
        ("NativeValueMismatch", "0xda52ba9e"), ("UnexpectedNativeValue", "0xe0aeda7d"), ("ZeroAmount", "0x1f2a2005"),
        ("InsufficientRealReserve", "0x3d5b7999"), ("UnsupportedQuoteToken", "0x658d8331"),
    ]

    func testEverySelectorIsPinnedAndNamed() {
        XCTAssertEqual(RevertReason.knownErrors.count, Self.pinned.count, "the table and the pins list the same errors")
        XCTAssertEqual(Set(Self.pinned.map(\.1)).count, Self.pinned.count, "no two errors share a selector")
        for (name, selector) in Self.pinned {
            XCTAssertEqual(ABI.selector("\(name)()").hexString, selector, name)
            let sentence = RevertReason.knownErrors[selector]
            XCTAssertNotNil(sentence, name)
            XCTAssertFalse(sentence?.isEmpty ?? true, name)
            XCTAssertFalse(sentence?.contains("0x") ?? true, "\(name): a sentence, not a selector")
        }
    }

    private func describe(_ selector: String) -> String {
        RevertReason.describe(RPCError(code: 3, message: "execution reverted: custom error \(selector)", data: selector))
    }

    /// A revert the node reports as the bare selector decodes to its sentence, as `TransactionSender.prepare` does it.
    func testRevertsDecodeToTheirSentences() {
        XCTAssertEqual(describe("0x4ec0a691"), "The Moments terms changed after you reviewed them, so nothing was published. Review them again.")
        XCTAssertTrue(describe("0x9e87fac8").contains("paused"))
        XCTAssertTrue(describe("0x24fe1192").contains("Lower it"))
        XCTAssertEqual(describe("0x3cba147e"), LaunchpadError.termsChanged.errorDescription, "the same sentence as the launch screen's own check")
        XCTAssertTrue(describe("0x584a7938").contains("approved wallets"))
        XCTAssertTrue(describe("0x6fed7d85").contains("less than an hour ago"))
        XCTAssertTrue(describe("0x38aa5c15").contains("more than 2%"))
        XCTAssertTrue(describe("0x9a697b0d").contains("needs more gas to graduate"))
        // An unnamed custom error still reads as one, with its selector.
        XCTAssertEqual(describe("0xdeadbeef"), "The contract rejected the transaction (custom error 0xdeadbeef).")
        // A collect keeps its own collect-specific wording.
        let closed = RPCError(code: 3, message: "execution reverted", data: "0xa818d914")
        XCTAssertEqual(MomentsService.collectReason(closed), "The collect window has closed.")
        XCTAssertEqual(MomentsService.collectReason(RPCError(code: 3, message: "execution reverted", data: "0x888e58a8")), "Choose between 1 and \(MomentsConstants.maxBatch) editions.")
    }
}
