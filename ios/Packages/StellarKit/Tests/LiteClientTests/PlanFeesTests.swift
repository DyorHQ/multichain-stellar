import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// A plan's fees as the phone works them out (DESIGN-stellar-parity §4.3, §4.4): built steps from their own transaction,
/// unbuilt ones from their ceiling, nothing the verifier's fee caps refuse, and "Paid by DyorHQ" only where the phone can
/// check it.
final class PlanFeesTests: XCTestCase {
    private let user = try! StellarSigner(seed: [UInt8](repeating: 7, count: 32)).address
    private let friend = try! StellarSigner(seed: [UInt8](repeating: 8, count: 32)).address
    private let sponsor = try! StellarSigner(seed: [UInt8](repeating: 9, count: 32)).address
    private var pinned: PinnedContracts { PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: "", roles: [:]) }
    private var xlm: String { AssetContract.id(.native, network: .testnet) }

    private func payment(fee: UInt32, payments: Int = 1, source: String? = nil) -> String {
        TestTransaction.envelope(source: source ?? user, fee: fee, ops: Array(repeating: .payment(to: friend, stroops: 1), count: payments))
    }

    private var paymentIntent: Intent { Intent(kind: "payment", summary: "", spend: [xlm: "6"], ops: ["payment"], to: friend) }

    func testTheServersPlanFixtureAddsUpAsItsOwnFigures() throws {
        // A built trust step (its transaction declares 0.001 XLM) and a swap the server prices at its 0.05 XLM ceiling.
        let plan = try ApiFixtures.decode("plan", as: PlanView.self)
        let fees = try PlanFees(plan: plan, pinned: .testnet)
        XCTAssertEqual(fees.step("s1"), PlanFees.Step(id: "s1", stepKind: "trust", maxFee: 10_000, built: true, payer: .user, reserveDelta: 1))
        XCTAssertEqual(fees.step("s2"), PlanFees.Step(id: "s2", stepKind: "swap_soroswap", maxFee: 500_000, built: false, payer: .user, reserveDelta: 0))
        XCTAssertEqual(String(fees.userMax), plan.fees?.userMax)
        XCTAssertEqual(fees.newReserves, plan.fees?.newReserves)
        XCTAssertEqual(fees.unbuiltUserSteps, 1)
        XCTAssertFalse(fees.sponsorVerified)
    }

    func testABuiltStepCountsItsOwnFeeNotTheServersFigure() throws {
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: payment(fee: 300), intent: paymentIntent, maxFee: "1", feePayer: "user")])
        XCTAssertEqual(try PlanFees(plan: plan, pinned: pinned).maxFee("s1"), 300)
    }

    func testAnUnbuiltStepIsPricedAtItsCeilingThenTheEstimateThenTheCap() throws {
        let estimates = try ApiFixtures.decode("fees", as: StellarFees.self)
        let plan = TestPlan.view([
            TestPlan.step("s1", "Swap", stepKind: "swap_soroswap", maxFee: "700000"),
            TestPlan.step("s2", "Swap", stepKind: "swap_soroswap"),
            TestPlan.step("s3", "Something new", stepKind: "unheard_of"),
            TestPlan.step("s4", "Swap", stepKind: "swap_soroswap", maxFee: "-5"),
        ])
        let fees = try PlanFees(plan: plan, pinned: pinned, estimates: estimates)
        XCTAssertEqual(fees.maxFee("s1"), 700_000)
        XCTAssertEqual(fees.maxFee("s2"), 500_000)
        XCTAssertEqual(fees.maxFee("s3"), 30_000_000)
        XCTAssertEqual(fees.maxFee("s4"), 500_000, "a ceiling that isn't a whole number of stroops is ignored")
        XCTAssertEqual(fees.userMax, 700_000 + 500_000 + 30_000_000 + 500_000)
        XCTAssertEqual(try PlanFees(plan: plan, pinned: pinned).maxFee("s2"), 30_000_000)
    }

    func testAnythingAboveThePinnedCapThrows() {
        let ceiling = TestPlan.view([TestPlan.step("s1", "Launch", stepKind: "launch_create", maxFee: "30000001")])
        XCTAssertThrowsError(try PlanFees(plan: ceiling, pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: "Launch", reason: "The network fee is above the limit."))
        }
        let built = TestPlan.view([TestPlan.step("s1", "Send", xdr: payment(fee: 30_000_001, payments: 8), intent: paymentIntent)])
        XCTAssertThrowsError(try PlanFees(plan: built, pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: "Send", reason: "The network fee is above the limit."))
        }
        let tight = PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: "", roles: [:],
                                    feePolicy: FeePolicy(maxFee: 299, maxInclusionFeePerOp: 200_000, starterInnerFeeMax: 100))
        XCTAssertThrowsError(try PlanFees(plan: TestPlan.view([TestPlan.step("s1", "Send", xdr: payment(fee: 300), intent: paymentIntent)]), pinned: tight))
        XCTAssertNoThrow(try PlanFees(plan: TestPlan.view([TestPlan.step("s1", "Send", xdr: payment(fee: 299), intent: paymentIntent)]), pinned: tight))
    }

    func testABuiltStepIsPricedOnlyWithinTheVerifiersFeeCaps() throws {
        // One payment declaring 0.03 XLM: under the 3 XLM cap, but over the 0.02 XLM one operation may bid. The review
        // can't show a fee the runner would refuse.
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: payment(fee: 300_000), intent: paymentIntent)])
        XCTAssertThrowsError(try PlanFees(plan: plan, pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: "Send", reason: "The inclusion fee is above the limit."))
        }
        // Each shared vector the verifiers refuse for its fee (the cap, the resource fee's range, the inclusion bid),
        // PlanFees refuses for the same reason.
        let feeReasons: Set = ["the network fee is above the limit", "the resource fee is out of range", "the inclusion fee is above the limit"]
        let refused = try SharedVectors.all().filter { $0.expect.reason.map(feeReasons.contains) ?? false }
        XCTAssertGreaterThanOrEqual(refused.count, 4)
        for v in refused {
            let step = TestPlan.view([TestPlan.step("s1", v.name, xdr: v.envelope, intent: v.intent)])
            XCTAssertThrowsError(try PlanFees(plan: step, pinned: v.pinned), v.name) { error in
                XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: v.name, reason: SharedVectors.swiftReason(v.expect.reason ?? "")), v.name)
            }
        }
    }

    func testDyorHQPaysOnlyWhereThePhoneCanCheckIt() throws {
        // (a) An activation whose source is the pinned sponsor.
        let activation = TestTransaction.envelope(source: sponsor, fee: 400, ops: [
            .createAccount(to: user, stroops: 0),
            .beginSponsoring(sponsored: user, source: sponsor),
            .endSponsoring(source: user),
        ])
        let activate = Intent(kind: "activate", summary: "", spend: [:], ops: ["createAccount", "beginSponsoringFutureReserves", "endSponsoringFutureReserves"])
        // (b) A starter swap within the starter cap.
        let starter = payment(fee: 1_000_000, payments: 6)
        let plan = TestPlan.view([
            TestPlan.step("s1", "Set up", xdr: activation, intent: activate, feePayer: "sponsor", sponsorReason: "setup"),
            TestPlan.step("s2", "Swap", xdr: starter, intent: paymentIntent, feePayer: "sponsor", sponsorReason: "starter_swap", reserveDelta: 0),
            TestPlan.step("s3", "Enable EURC", xdr: payment(fee: 100), intent: paymentIntent, feePayer: "user", reserveDelta: 1),
        ])
        let fees = try PlanFees(plan: plan, pinned: pinned)
        XCTAssertEqual(fees.step("s1")?.payer, .dyorHQ(.setup))
        XCTAssertEqual(fees.step("s2")?.payer, .dyorHQ(.starterSwap))
        XCTAssertEqual(fees.step("s3")?.payer, .user)
        XCTAssertTrue(fees.sponsorVerified)
        XCTAssertEqual(fees.userMax, 100)
        XCTAssertEqual(fees.newReserves, 1)

        // The server's word alone pays nothing: "setup" on the user's own transaction, an activation intent from the
        // user, "sponsor" on an unbuilt step.
        let claims = TestPlan.view([
            TestPlan.step("s1", "Send", xdr: payment(fee: 100), intent: paymentIntent, feePayer: "sponsor", sponsorReason: "setup"),
            TestPlan.step("s2", "Set up", xdr: payment(fee: 100), intent: activate, feePayer: "sponsor", sponsorReason: "setup"),
            TestPlan.step("s3", "Swap", stepKind: "swap_soroswap", maxFee: "500000", feePayer: "sponsor", sponsorReason: "starter_swap"),
        ])
        let unverified = try PlanFees(plan: claims, pinned: pinned)
        XCTAssertFalse(unverified.sponsorVerified)
        XCTAssertEqual(unverified.userMax, 100 + 100 + 500_000)
    }

    func testAStarterStepAboveTheStarterCapIsRefused() {
        let plan = TestPlan.view([TestPlan.step("s1", "Swap", xdr: payment(fee: 1_000_001, payments: 6), intent: paymentIntent, feePayer: "sponsor", sponsorReason: "starter_swap")])
        XCTAssertThrowsError(try PlanFees(plan: plan, pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: "Swap", reason: "The sponsored step's network fee is above the limit."))
        }
    }
}
