import BigInt
import Foundation
import XCTest
@testable import DyorKit

/// A policy proposed but not applied yet is read and compared with the live one, so the app can warn that a publish
/// may land under it (security audit 2026-09-26, MO-4).
final class MomentsPendingPolicyTests: XCTestCase {
    private let platform = Address(literal: "0x00000000000000000000000000000000000000a1")
    private let treasury = Address(literal: "0x00000000000000000000000000000000000000b2")

    func testSelectorsMatchFoundry() {
        // cast sig "pendingPolicy()" / "pendingPolicyAt()"
        XCTAssertEqual(ABI.selector(MomentsABI.Factory.pendingPolicy).hexString, "0xe6c5cf40")
        XCTAssertEqual(ABI.selector(MomentsABI.Factory.pendingPolicyAt).hexString, "0x15603e91")
    }

    private func current() -> MomentPolicy {
        MomentPolicy(threshold: 10_000_000, minPrice: 1_000_000, creatorBps: 2000, platformBps: 500, reserveBps: 7500, maxCreatorAllocBps: 1000,
                     expiryCreatorBps: 6000, royaltyBps: 500, platform: platform, treasury: treasury, momentCount: 3, publishingPaused: false, externalBaseURI: "")
    }

    private func pending(threshold: BigUInt = 10_000_000, creatorBps: Int = 2000, platformBps: Int = 500, royaltyBps: Int = 500,
                         treasury: Address? = nil, at: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> PendingMomentPolicy {
        PendingMomentPolicy(threshold: threshold, minPrice: 1_000_000, creatorBps: creatorBps, platformBps: platformBps, reserveBps: 7500, maxCreatorAllocBps: 1000,
                            expiryCreatorBps: 6000, royaltyBps: royaltyBps, platform: platform, treasury: treasury ?? self.treasury, applicableAt: at)
    }

    func testAProposalThatRepeatsThePolicyChangesNothing() {
        XCTAssertEqual(pending().changes(from: current()), [])
    }

    func testChangedTermsAreListedInOrder() {
        let other = Address(literal: "0x00000000000000000000000000000000000000c3")
        let proposal = pending(threshold: 50_000_000, creatorBps: 1500, platformBps: 1000, royaltyBps: 750, treasury: other)
        XCTAssertEqual(proposal.changes(from: current()), [.threshold, .split, .royalty, .treasury])
    }

    func testApplicableFromItsTime() {
        let proposal = pending(at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(proposal.isApplicable(at: Date(timeIntervalSince1970: 1_799_999_999)))
        XCTAssertTrue(proposal.isApplicable(at: Date(timeIntervalSince1970: 1_800_000_000)))
        // A v1 proposal has no lapse: it stays applicable until applied or cancelled.
        XCTAssertNil(proposal.lapsesAt)
        XCTAssertTrue(proposal.isApplicable(at: Date(timeIntervalSince1970: 1_900_000_000)))
        XCTAssertFalse(proposal.hasLapsed(at: Date(timeIntervalSince1970: 1_900_000_000)))
    }

    /// v2: `applyPolicy` works from `pendingPolicyAt` through `pendingPolicyAt + POLICY_APPLY_WINDOW` (7 days) and reverts
    /// `PolicyLapsed` once the time is past it (`block.timestamp > pendingPolicyAt + window`). A lapsed proposal is no
    /// longer a threat to a publish.
    func testAV2ProposalLapsesSevenDaysAfterItBecomesApplicable() {
        XCTAssertEqual(ABI.selector(MomentsABI.Factory.policyApplyWindow).hexString, "0xbfd9aa02")
        XCTAssertEqual(MomentsConstants.policyApplyWindowSeconds, 604_800)
        let at = 1_800_000_000
        let proposal = PendingMomentPolicy(threshold: 50_000_000, minPrice: 1_000_000, creatorBps: 2000, platformBps: 500, reserveBps: 7500, maxCreatorAllocBps: 1000,
                                           expiryCreatorBps: 6000, royaltyBps: 500, platform: platform, treasury: treasury,
                                           applicableAt: Date(timeIntervalSince1970: TimeInterval(at)),
                                           lapsesAt: Date(timeIntervalSince1970: TimeInterval(at + MomentsConstants.policyApplyWindowSeconds)))
        func time(_ t: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(t)) }
        let edges: [(Int, applicable: Bool, lapsed: Bool)] = [
            (at - 1, false, false), // before it can be applied
            (at, true, false), // from its time
            (at + 7 * 86_400, true, false), // the last second of the window
            (at + 7 * 86_400 + 1, false, true), // one second after: lapsed
        ]
        for (t, applicable, lapsed) in edges {
            XCTAssertEqual(proposal.isApplicable(at: time(t)), applicable, "t = at + \(t - at)")
            XCTAssertEqual(proposal.hasLapsed(at: time(t)), lapsed, "t = at + \(t - at)")
        }
    }
}
