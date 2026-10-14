import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// The plan runner against a fake API (DESIGN-stellar-parity §4.3, §4.4): a step built after the review never goes out
/// above the fee the user confirmed, a step marked as sponsored never declares more than the pinned starter cap, the
/// sponsor never signs outside an activation, and the limits still hold. Nothing refused is ever signed.
final class PlanRunnerTests: XCTestCase {
    private let user = try! StellarSigner(seed: [UInt8](repeating: 7, count: 32))
    private let friend = try! StellarSigner(seed: [UInt8](repeating: 8, count: 32)).address
    private let sponsor = try! StellarSigner(seed: [UInt8](repeating: 9, count: 32)).address
    private var pinned: PinnedContracts { PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: "", roles: [:]) }
    private var xlm: String { AssetContract.id(.native, network: .testnet) }

    private func send(_ stroops: Int64, fee: UInt32, payments: Int = 1) -> (xdr: String, intent: Intent) {
        let xdr = TestTransaction.envelope(source: user.address, fee: fee, ops: Array(repeating: .payment(to: friend, stroops: stroops), count: payments))
        let intent = Intent(kind: "payment", summary: "", spend: [xlm: String(stroops * Int64(payments))], ops: ["payment"], to: friend)
        return (xdr, intent)
    }

    private func runner(_ backend: FakePlanBackend) -> PlanRunner {
        PlanRunner(api: backend, user: user.address, pinned: pinned, inspector: NoLaunchTokens())
    }

    private func signer(_ count: SignCount) -> @Sendable () async throws -> StellarSigner {
        let key = user
        return {
            count.add()
            return key
        }
    }

    func testSubmitsEveryStepWithinTheFeesTheUserConfirmed() async throws {
        let first = send(10_000_000, fee: 100)
        let second = send(20_000_000, fee: 1_000)
        let plan = TestPlan.view([
            TestPlan.step("s1", "Send", xdr: first.xdr, intent: first.intent),
            TestPlan.step("s2", "Send again", maxFee: "1000"),
        ])
        let backend = FakePlanBackend(plan: plan, builds: ["s2": TestPlan.step("s2", "Send again", xdr: second.xdr, intent: second.intent)])
        let fees = try PlanFees(plan: plan, pinned: pinned)
        XCTAssertEqual(fees.userMax, 1_100)
        let signed = SignCount()
        let results = try await runner(backend).run(plan, limits: [xlm: 30_000_000], fees: fees, signer: signer(signed))
        XCTAssertEqual(results.map(\.status), ["success", "success"])
        let submitted = await backend.submitted
        XCTAssertEqual(submitted, ["s1", "s2"])
        XCTAssertEqual(signed.value, 2)
    }

    func testNeverSubmitsARebuiltStepWhoseFeeRoseAboveTheConfirmedFee() async throws {
        let first = send(10_000_000, fee: 100)
        let pricier = send(20_000_000, fee: 1_001)
        let plan = TestPlan.view([
            TestPlan.step("s1", "Send", xdr: first.xdr, intent: first.intent),
            TestPlan.step("s2", "Send again", maxFee: "1000"),
        ])
        let backend = FakePlanBackend(plan: plan, builds: ["s2": TestPlan.step("s2", "Send again", xdr: pricier.xdr, intent: pricier.intent)])
        let signed = SignCount()
        do {
            try await runner(backend).run(plan, limits: [xlm: 30_000_000], fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(signed))
            XCTFail("a step above its confirmed fee was sent")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .feeAboveConfirmed(step: "Send again"))
            XCTAssertEqual(f.errorDescription, "Not signed: the network fee for Send again went up since you confirmed. Nothing was sent.")
        }
        let submitted = await backend.submitted
        XCTAssertEqual(submitted, ["s1"])
        XCTAssertEqual(signed.value, 1, "the pricier step was never signed")
    }

    func testRefusesAStepTheseFeesDontCover() async throws {
        let first = send(10_000_000, fee: 100)
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: first.xdr, intent: first.intent)])
        let other = TestPlan.view([TestPlan.step("s9", "Other", xdr: first.xdr, intent: first.intent)])
        let backend = FakePlanBackend(plan: plan)
        do {
            try await runner(backend).run(plan, limits: [xlm: 10_000_000], fees: try PlanFees(plan: other, pinned: pinned), signer: signer(SignCount()))
            XCTFail("signed with another plan's fees")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .feeAboveConfirmed(step: "Send"))
        }
        let submitted = await backend.submitted
        XCTAssertEqual(submitted, [])
    }

    func testRefusesASponsoredStepWhoseInnerFeeIsAboveTheStarterCap() async throws {
        // Six payments, so the transaction passes the inclusion cap (6 × 0.02 XLM) and only the starter cap can catch it.
        let starter = send(1_000_000, fee: 1_000_001, payments: 6)
        let plan = TestPlan.view([TestPlan.step("s1", "Swap", maxFee: "2000000")])
        let rebuilt = TestPlan.step("s1", "Swap", xdr: starter.xdr, intent: starter.intent, feePayer: "sponsor", sponsorReason: "starter_swap")
        let backend = FakePlanBackend(plan: plan, builds: ["s1": rebuilt])
        let signed = SignCount()
        do {
            try await runner(backend).run(plan, limits: [xlm: 6_000_000], fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(signed))
            XCTFail("a sponsored step above the starter cap was sent")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .refused(step: "Swap", reason: "The sponsored step's network fee is above the limit."))
        }
        XCTAssertEqual(signed.value, 0)
        let submitted = await backend.submitted
        XCTAssertEqual(submitted, [])

        // Built from the start, the same step can't even be priced for the review.
        XCTAssertThrowsError(try PlanFees(plan: TestPlan.view([rebuilt]), pinned: pinned)) { error in
            XCTAssertEqual(error as? PlanRunner.Failure, .refused(step: "Swap", reason: "The sponsored step's network fee is above the limit."))
        }
    }

    func testRefusesTheSponsorOutsideAnActivation() async throws {
        let usdcIssuer = try StellarSigner(seed: [UInt8](repeating: 3, count: 32)).address
        let sandwich = TestTransaction.envelope(source: user.address, fee: 300, ops: [
            .beginSponsoring(sponsored: user.address, source: sponsor),
            .changeTrust(code: "USDC", issuer: usdcIssuer),
            .endSponsoring(source: user.address),
        ])
        let intent = Intent(kind: "trust", summary: "", spend: [:], ops: ["beginSponsoringFutureReserves", "changeTrust", "endSponsoringFutureReserves"], trust: ["USDC:\(usdcIssuer)"])
        let plan = TestPlan.view([TestPlan.step("s1", "Enable USDC", xdr: sandwich, intent: intent, feePayer: "sponsor", sponsorReason: "setup")])
        let backend = FakePlanBackend(plan: plan)
        let signed = SignCount()
        do {
            try await runner(backend).run(plan, limits: [:], signer: signer(signed))
            XCTFail("the sponsor signed outside an activation")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .refused(step: "Enable USDC", reason: "The sponsor appears outside account activation."))
        }
        XCTAssertEqual(signed.value, 0)
    }

    func testRefusesAStepConfirmedAsPaidByDyorHQThatNoLongerIs() async throws {
        let starter = send(1_000_000, fee: 1_000_000, payments: 6)
        let sponsored = TestPlan.view([TestPlan.step("s1", "Swap", xdr: starter.xdr, intent: starter.intent, feePayer: "sponsor", sponsorReason: "starter_swap")])
        let fees = try PlanFees(plan: sponsored, pinned: pinned)
        XCTAssertEqual(fees.step("s1")?.payer, .dyorHQ(.starterSwap))
        XCTAssertEqual(fees.userMax, 0)
        let userPaid = TestPlan.view([TestPlan.step("s1", "Swap", xdr: starter.xdr, intent: starter.intent)])
        let backend = FakePlanBackend(plan: userPaid)
        do {
            try await runner(backend).run(userPaid, limits: [xlm: 6_000_000], fees: fees, signer: signer(SignCount()))
            XCTFail("a step the user confirmed as sponsored went out as theirs")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .feeAboveConfirmed(step: "Swap"))
        }
    }

    func testRefusesToSpendMoreThanTheUserConfirmed() async throws {
        let five = send(50_000_000, fee: 100)
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: five.xdr, intent: five.intent)])
        let backend = FakePlanBackend(plan: plan)
        let signed = SignCount()
        do {
            try await runner(backend).run(plan, limits: [xlm: 40_000_000], fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(signed))
            XCTFail("an over-limit plan was signed")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .overLimit(asset: xlm))
        }
        XCTAssertEqual(signed.value, 0)
    }

    func testTheCompatibilityRunPricesUnbuiltStepsAtTheirCeiling() async throws {
        // No server ceiling: the pinned cap is the ceiling, and a step built within it goes out.
        let built = send(10_000_000, fee: 30_000)
        let plan = TestPlan.view([TestPlan.step("s1", "Send")])
        let backend = FakePlanBackend(plan: plan, builds: ["s1": TestPlan.step("s1", "Send", xdr: built.xdr, intent: built.intent)])
        let results = try await runner(backend).run(plan, limits: [xlm: 10_000_000], signer: signer(SignCount()))
        XCTAssertEqual(results.count, 1)
        let builds = await backend.builds
        XCTAssertEqual(builds, ["s1"])
    }
}

// ------------------------------------------------------------------------------------------------------ fakes

/// Counts the signer's calls (a signature is one call).
final class SignCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func add() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// No contract is a launch token.
struct NoLaunchTokens: LaunchTokenInspecting {
    func launchTokens(among contracts: [String], pinned: PinnedContracts) async throws -> Set<String> { [] }
}

/// The Lite API's plan routes: builds a step by swapping in the step given for it, and settles every submission.
actor FakePlanBackend: PlanBackend {
    private var plan: PlanView
    private let replacements: [String: PlanStep]
    private(set) var builds: [String] = []
    private(set) var submitted: [String] = []

    init(plan: PlanView, builds: [String: PlanStep] = [:]) {
        self.plan = plan
        replacements = builds
    }

    func buildStep(planId: String, stepId: String) async throws -> PlanView {
        builds.append(stepId)
        let steps = plan.steps.map { $0.id == stepId ? replacements[stepId] ?? $0 : $0 }
        plan = PlanView(planId: plan.planId, kind: plan.kind, expiresAt: plan.expiresAt, steps: steps, fees: plan.fees)
        return plan
    }

    func submit(planId: String, stepId: String, signedXdr: String) async throws -> TxStatus {
        submitted.append(stepId)
        return TestPlan.status("hash-\(stepId)", "pending")
    }

    func txStatus(_ hash: String) async throws -> TxStatus { TestPlan.status(hash, "success") }
}

enum TestPlan {
    static func step(
        _ id: String,
        _ label: String,
        xdr: String? = nil,
        intent: Intent? = nil,
        stepKind: String? = nil,
        maxFee: String? = nil,
        feePayer: String? = nil,
        sponsorReason: String? = nil,
        reserveDelta: Int? = nil
    ) -> PlanStep {
        PlanStep(id: id, label: label, status: xdr == nil ? "pending" : "built", intent: intent, xdr: xdr, hash: nil, txHash: nil, error: nil,
                 stepKind: stepKind, maxFee: maxFee, feePayer: feePayer, sponsorReason: sponsorReason, reserveDelta: reserveDelta)
    }

    static func view(_ steps: [PlanStep]) -> PlanView {
        PlanView(planId: "plan-1", kind: "test", expiresAt: "2026-10-14T10:00:00.000Z", steps: steps, fees: nil)
    }

    static func status(_ hash: String, _ status: String) -> TxStatus {
        TxStatus(hash: hash, status: status, ledger: nil, error: nil, returnValue: nil, feeCharged: nil, feePayer: nil, result: nil)
    }
}

/// Classic transactions written as XDR in the tests, with whatever fee a fake server wants to hand the runner.
enum TestTransaction {
    enum Op {
        case payment(to: String, stroops: Int64)
        case createAccount(to: String, stroops: Int64, source: String? = nil)
        case beginSponsoring(sponsored: String, source: String)
        case changeTrust(code: String, issuer: String)
        case endSponsoring(source: String)
    }

    /// A v1 envelope from `source`, sequence 41, expiring `expiresIn` seconds from now, without signatures.
    static func envelope(source: String, fee: UInt32, ops: [Op], expiresIn: TimeInterval = 300) -> String {
        var w = XDRWriter()
        w.uint32(2) // ENVELOPE_TYPE_TX
        account(&w, source)
        w.uint32(fee)
        w.int64(41)
        w.uint32(1) // PRECOND_TIME
        w.uint64(0)
        w.uint64(UInt64(Date().timeIntervalSince1970 + expiresIn))
        w.uint32(0) // MEMO_NONE
        w.uint32(UInt32(ops.count))
        for op in ops {
            switch op {
            case let .payment(to, stroops):
                w.uint32(0)
                w.uint32(1) // PAYMENT
                account(&w, to)
                w.uint32(0) // native
                w.int64(stroops)
            case let .createAccount(to, stroops, source):
                opSource(&w, source)
                w.uint32(0) // CREATE_ACCOUNT
                account(&w, to)
                w.int64(stroops)
            case let .beginSponsoring(sponsored, source):
                opSource(&w, source)
                w.uint32(16) // BEGIN_SPONSORING_FUTURE_RESERVES
                account(&w, sponsored)
            case let .changeTrust(code, issuer):
                w.uint32(0)
                w.uint32(6) // CHANGE_TRUST
                w.uint32(1) // ASSET_TYPE_CREDIT_ALPHANUM4
                w.raw(Array(code.utf8) + [UInt8](repeating: 0, count: 4 - code.utf8.count))
                account(&w, issuer)
                w.int64(.max)
            case let .endSponsoring(source):
                opSource(&w, source)
                w.uint32(17) // END_SPONSORING_FUTURE_RESERVES
            }
        }
        w.uint32(0) // ext
        w.uint32(0) // signatures
        return Data(w.bytes).base64EncodedString()
    }

    private static func account(_ w: inout XDRWriter, _ address: String) {
        w.uint32(0) // KEY_TYPE_ED25519 (a MuxedAccount's and a PublicKey's first arm alike)
        w.raw(try! StrKey.decode(.accountID, address))
    }

    private static func opSource(_ w: inout XDRWriter, _ source: String?) {
        guard let source else { return w.uint32(0) }
        w.uint32(1)
        account(&w, source)
    }
}
