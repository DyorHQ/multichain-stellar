import BigInt
import XCTest
@testable import DyorKit

/// The graduation FDV the app shows must be the pool's actual opening valuation: threshold · (1 + 1/reserveFrac) /
/// (1 − creatorAlloc), the same identity `MomentsFactory.bundleRate` encodes (price continuity).
final class MomentsEconomicsTests: XCTestCase {
    func testGraduationFDVMatchesTheSpecAtTheValidationThreshold() {
        // Spec "Initial launch": a $10 reserve at 75% / 10% allocation opens at ≈ $26 FDV.
        XCTAssertEqual(MomentsMath.graduationFDV(threshold: 10_000_000, reserveBps: 7_500, creatorAllocBps: 1_000), 25.925926, accuracy: 1e-5)
    }

    func testCohortTwoThresholdOpensAtTwoThousandDollars() {
        // 771.428571 USDC reserve → $2,000.00 at the default 10% allocation; $1,800 when the creator takes none.
        XCTAssertEqual(MomentsMath.graduationFDV(threshold: 771_428_571, reserveBps: 7_500, creatorAllocBps: 1_000), 2_000, accuracy: 0.001)
        XCTAssertEqual(MomentsMath.graduationFDV(threshold: 771_428_571, reserveBps: 7_500, creatorAllocBps: 0), 1_800, accuracy: 0.001)
    }

    /// The collect price is capped at the gross that completes the reserve: the live cohort 3 policy ($771.428571 at
    /// 75%) charges at most $1,028.571428 however high the listed price, so the create screen refuses anything above it.
    func testMaxCollectPriceIsTheCompletionGrossRoundedUp() {
        XCTAssertEqual(MomentsMath.maxCollectPrice(threshold: 771_428_571, reserveBps: 7_500), 1_028_571_428)
        XCTAssertEqual(MomentsMath.maxCollectPrice(threshold: 10_000_000, reserveBps: 7_500), 13_333_334, "rounds up, as Math.ceilDiv")
        XCTAssertEqual(MomentsMath.maxCollectPrice(threshold: 10_000_000, reserveBps: 10_000), 10_000_000)
        XCTAssertNil(MomentsMath.maxCollectPrice(threshold: 10_000_000, reserveBps: 0))
    }

    func testDegenerateInputsAreZeroNotACrash() {
        XCTAssertEqual(MomentsMath.graduationFDV(threshold: 771_428_571, reserveBps: 0, creatorAllocBps: 1_000), 0)
        XCTAssertEqual(MomentsMath.graduationFDV(threshold: 771_428_571, reserveBps: 7_500, creatorAllocBps: 10_000), 0)
    }
}
