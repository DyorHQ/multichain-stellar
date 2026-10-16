import Foundation
@testable import LiteClient
import StellarCore
import XCTest

/// The plan runner against a fake API (DESIGN-stellar-parity §4.3, §4.4, §5.2): a step the user reviewed goes out as
/// reviewed, a step built after the review never goes out above the fee the user confirmed, a step marked as sponsored
/// never declares more than the pinned starter cap, the sponsor never signs outside an activation, and the limits still
/// hold. Nothing refused is ever signed.
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

    /// What the user typed for `send`: the friend's address, no memo.
    private var toFriend: PlanBindings { PlanBindings(destination: .confirmed(to: friend, memo: nil)) }

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
        let results = try await runner(backend).run(plan, limits: [xlm: 30_000_000], bindings: toFriend, fees: fees, signer: signer(signed))
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
            try await runner(backend).run(plan, limits: [xlm: 30_000_000], bindings: toFriend, fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(signed))
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

    func testSignsAStepTheUserReviewedAsReviewedWhateverTheServerAnswersLater() async throws {
        // The review showed s2 built: 5 XLM to the friend. Asked to build s1, the server answers with s2 rewritten to
        // pay another account, its intent rewritten to match. s2 still goes out exactly as reviewed (§5.2).
        let other = try StellarSigner(seed: [UInt8](repeating: 4, count: 32)).address
        let first = send(10_000_000, fee: 100)
        let reviewed = send(50_000_000, fee: 100)
        let rewritten = TestPlan.step(
            "s2", "Send to a friend",
            xdr: TestTransaction.envelope(source: user.address, fee: 100, ops: [.payment(to: other, stroops: 50_000_000)]),
            intent: Intent(kind: "payment", summary: "", spend: [xlm: "50000000"], ops: ["payment"], to: other)
        )
        let plan = TestPlan.view([
            TestPlan.step("s1", "Send", maxFee: "100"),
            TestPlan.step("s2", "Send to a friend", xdr: reviewed.xdr, intent: reviewed.intent),
        ])
        let backend = FakePlanBackend(plan: plan, builds: ["s1": TestPlan.step("s1", "Send", xdr: first.xdr, intent: first.intent)], rewrites: ["s1": [rewritten]])
        try await runner(backend).run(plan, limits: [xlm: 60_000_000], bindings: toFriend, fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(SignCount()))
        let builds = await backend.builds
        XCTAssertEqual(builds, ["s1"])
        let signed = await backend.signed
        let sent = try TransactionEnvelope(base64: XCTUnwrap(signed["s2"])).transaction
        XCTAssertEqual(sent.operations.map(\.body), [.payment(destination: friend, asset: .native, amount: 50_000_000)])
    }

    func testLooksUpTheFootprintsContractsOnlyForARestore() async throws {
        // A swap whose footprint names a pair nobody pins goes out with the RPC down: only a restore's footprint plays a
        // part in the checks (§4.9), so no other step's footprint costs an RPC lookup.
        let swap = try SharedVectors.named("soroban swap with a footprint ok")
        let down = FakeInspector(down: true)
        try await run(swap, inspector: down)
        let swapLookups = await down.lookedUp
        XCTAssertEqual(swapLookups, [])
        // A restore's footprint is looked up, and the launch token whose data it brings back is recognised.
        let restore = try SharedVectors.named("restore ok")
        let rpc = FakeInspector(launchTokens: Set(restore.launchTokens))
        try await run(restore, inspector: rpc)
        let restoreLookups = await rpc.lookedUp
        XCTAssertEqual(restoreLookups, Set(restore.launchTokens))
    }

    /// Runs a shared vector as a one-step plan, built for the review, on the vector's clock and pins.
    @discardableResult
    private func run(_ vector: SharedVectors.Vector, inspector: any LaunchTokenInspecting, intent: Intent? = nil,
                     bindings: PlanBindings? = nil, signed: SignCount = SignCount()) async throws -> [TxStatus] {
        let intent = intent ?? vector.intent
        let plan = TestPlan.view([TestPlan.step("s1", vector.name, xdr: vector.envelope, intent: intent)])
        var runner = PlanRunner(api: FakePlanBackend(plan: plan), user: vector.user, pinned: vector.pinned, inspector: inspector)
        let now = vector.now
        runner.now = { Date(timeIntervalSince1970: now) }
        let key = try SharedVectors.user()
        let limits = intent.spend.compactMapValues(TxVerifier.units)
        return try await runner.run(plan, limits: limits, bindings: bindings ?? PlanBindings.typed(intent, user: vector.user),
                                    fees: try PlanFees(plan: plan, pinned: vector.pinned), signer: {
                                        signed.add()
                                        return key
                                    })
    }

    // MARK: - What the user confirmed besides the spends (PlanBindings)

    /// "path payment ok" with its minimum (9 USDC, in its intent's receive) set to `receive`, or as it is.
    private func pathPayment(receive: String?) throws -> (SharedVectors.Vector, Intent) {
        let v = try SharedVectors.named("path payment ok")
        let i = v.intent
        return (v, Intent(kind: i.kind, summary: i.summary, spend: i.spend, receive: receive.map { r in i.receive!.mapValues { _ in r } } ?? i.receive, calls: i.calls,
                          ops: i.ops, trust: i.trust, display: i.display, to: i.to, memo: i.memo))
    }

    func testATradeGoesOutWhenItsMinimumIsTheOneTheUserConfirmed() async throws {
        let (v, intent) = try pathPayment(receive: nil)
        let usdc = try XCTUnwrap(intent.receive?.keys.first)
        let results = try await run(v, inspector: NoLaunchTokens(), bindings: PlanBindings(minimums: [usdc: 9_000_000]))
        XCTAssertEqual(results.count, 1)
    }

    func testATradeWhoseMinimumIsBelowTheConfirmedOneIsNeverSigned() async throws {
        let (v, intent) = try pathPayment(receive: nil)
        let usdc = try XCTUnwrap(intent.receive?.keys.first)
        let signed = SignCount()
        do {
            try await run(v, inspector: NoLaunchTokens(), bindings: PlanBindings(minimums: [usdc: 9_000_001]), signed: signed)
            XCTFail("a lower minimum was signed")
        } catch let f as PlanRunner.Failure {
            XCTAssertEqual(f, .minimumNotConfirmed(step: "path payment ok"))
        }
        XCTAssertEqual(signed.value, 0)
    }

    func testAZeroOrMissingMinimumIsNeverSigned() async throws {
        // The server zeroes the minimum: refused whatever the user confirmed, even with no minimum given.
        let (v, zero) = try pathPayment(receive: "0")
        let usdc = try XCTUnwrap(zero.receive?.keys.first)
        for bindings in [PlanBindings(minimums: [usdc: 9_000_000]), PlanBindings.none] {
            let signed = SignCount()
            do {
                try await run(v, inspector: NoLaunchTokens(), intent: zero, bindings: bindings, signed: signed)
                XCTFail("a zero minimum was signed")
            } catch let f as PlanRunner.Failure {
                XCTAssertEqual(f, .minimumNotConfirmed(step: "path payment ok"))
            }
            XCTAssertEqual(signed.value, 0)
        }
        // The server drops the minimum from the intent: never signed (the verifier may refuse it first, as one that needs
        // the intent's minimum does; the run refuses it in any case).
        let (_, missing) = try pathPayment(receive: nil)
        let dropped = Intent(kind: missing.kind, summary: missing.summary, spend: missing.spend, calls: missing.calls, ops: missing.ops, to: missing.to)
        let signed = SignCount()
        do {
            try await run(v, inspector: NoLaunchTokens(), intent: dropped, bindings: PlanBindings(minimums: [usdc: 9_000_000]), signed: signed)
            XCTFail("a step without its minimum was signed")
        } catch let f as PlanRunner.Failure {
            switch f {
            case .minimumNotConfirmed, .refused: break
            default: XCTFail("\(f)")
            }
        }
        XCTAssertEqual(signed.value, 0)
        // Without the verifier's rule, the run's own check: a spending step that names no minimum.
        var check = PlanBindings.Check(PlanBindings(minimums: [usdc: 9_000_000]), user: v.user)
        XCTAssertThrowsError(try check.step(dropped, spends: true, last: true)) {
            XCTAssertEqual($0 as? PlanBindings.Refusal, .minimum(reason: "the transaction names no minimum"))
        }
    }

    func testASendToAnotherAddressThanTheTypedOneIsNeverSigned() async throws {
        let other = try StellarSigner(seed: [UInt8](repeating: 4, count: 32)).address
        let five = send(50_000_000, fee: 100)
        let plan = TestPlan.view([TestPlan.step("s1", "Send", xdr: five.xdr, intent: five.intent)])
        let cases: [PlanBindings] = [
            .none, // nothing typed: only the user's own account
            PlanBindings(destination: .confirmed(to: other, memo: nil)), // typed another address
            PlanBindings(destination: .confirmed(to: friend, memo: .init(type: "text", value: "123"))), // a memo the step doesn't carry
        ]
        for bindings in cases {
            let backend = FakePlanBackend(plan: plan)
            let signed = SignCount()
            do {
                try await runner(backend).run(plan, limits: [xlm: 50_000_000], bindings: bindings, fees: try PlanFees(plan: plan, pinned: pinned), signer: signer(signed))
                XCTFail("a send the user didn't confirm was signed")
            } catch let f as PlanRunner.Failure {
                XCTAssertEqual(f, .destinationNotConfirmed(step: "Send"))
            }
            XCTAssertEqual(signed.value, 0)
            let submitted = await backend.submitted
            XCTAssertEqual(submitted, [])
        }
    }

    func testTheBindingsChecksStepByStep() throws {
        let me = user.address
        let token = "CARCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEIRCEVQO"
        func intent(receive: [String: String]? = nil, to: String? = nil, memo: Intent.Memo? = nil) -> Intent {
            Intent(kind: "k", summary: "", spend: [:], receive: receive, to: to, memo: memo)
        }
        // A trust step before the trade spends nothing and names nothing: it passes; the trade must name the minimum.
        var check = PlanBindings.Check(PlanBindings(minimums: [token: 100]), user: me)
        XCTAssertNoThrow(try check.step(intent(), spends: false, last: false))
        XCTAssertThrowsError(try check.step(intent(), spends: true, last: true)) { XCTAssertEqual($0 as? PlanBindings.Refusal, .minimum(reason: "the transaction names no minimum")) }
        check = PlanBindings.Check(PlanBindings(minimums: [token: 100]), user: me)
        XCTAssertNoThrow(try check.step(intent(receive: [token: "100"]), spends: true, last: true))
        XCTAssertTrue(check.outstanding.isEmpty)
        // A swap that receives another asset than the one the user chose, whatever its amount: refused.
        let usdc = "CBIELTK6YBZJU5UP2WWQEUCYKLPU6AUNZ2BQ4WWFEIE3USCIHMXQDAMA"
        check = PlanBindings.Check(PlanBindings(minimums: [token: 100]), user: me)
        XCTAssertThrowsError(try check.step(intent(receive: [usdc: "1000"]), spends: true, last: true)) {
            XCTAssertEqual($0 as? PlanBindings.Refusal, .minimum(reason: "the transaction receives another asset than the one you chose"))
        }
        check = PlanBindings.Check(PlanBindings(minimums: [token: 100]), user: me)
        XCTAssertThrowsError(try check.step(intent(receive: [token: "100", usdc: "1"]), spends: true, last: true))
        // A last step that spends nothing (an Earn withdrawal) must still name it.
        check = PlanBindings.Check(PlanBindings(minimums: [token: 100]), user: me)
        XCTAssertThrowsError(try check.step(intent(), spends: false, last: true))
        // A new coin's first buy: any asset, at the minimum.
        check = PlanBindings.Check(PlanBindings(minimums: [PlanBindings.anyAsset: 4000]), user: me)
        XCTAssertThrowsError(try check.step(intent(receive: [token: "3999"]), spends: true, last: true))
        check = PlanBindings.Check(PlanBindings(minimums: [PlanBindings.anyAsset: 4000]), user: me)
        XCTAssertNoThrow(try check.step(intent(receive: [token: "4000"]), spends: true, last: true))
        // Destinations: the user's own by default; the typed one exactly; a bridge's 0x address in either case.
        var own = PlanBindings.Check(.none, user: me)
        XCTAssertNoThrow(try own.step(intent(to: me), spends: true, last: true))
        XCTAssertThrowsError(try own.step(intent(to: friend), spends: true, last: true))
        XCTAssertThrowsError(try own.step(intent(memo: .init(type: "id", value: "1")), spends: true, last: true))
        let typed = PlanBindings(destination: .confirmed(to: friend, memo: .init(type: "id", value: "42")))
        var send = PlanBindings.Check(typed, user: me)
        XCTAssertNoThrow(try send.step(intent(), spends: false, last: false), "a trust step before the send")
        XCTAssertNoThrow(try send.step(intent(to: friend, memo: .init(type: "id", value: "42")), spends: true, last: true))
        send = PlanBindings.Check(typed, user: me)
        XCTAssertThrowsError(try send.step(intent(to: friend, memo: .init(type: "text", value: "42")), spends: true, last: true), "memo type included")
        send = PlanBindings.Check(typed, user: me)
        XCTAssertThrowsError(try send.step(intent(), spends: true, last: true), "the last step names no destination")
        var bridge = PlanBindings.Check(PlanBindings(destination: .confirmed(to: "0xAbCd000000000000000000000000000000001234", memo: nil)), user: me)
        XCTAssertNoThrow(try bridge.step(intent(to: "0xabcd000000000000000000000000000000001234"), spends: true, last: true))
        var unchecked = PlanBindings.Check(PlanBindings(destination: .unchecked), user: me)
        XCTAssertNoThrow(try unchecked.step(intent(to: friend), spends: false, last: true))
        // Settings: by kind or by the function called; a field written as a number or as its digits; missing = refused.
        let shown: [String: StellarJSON] = ["price": .string("10000000"), "windowSecs": .number(86400)]
        let settings = PlanBindings(shown: ["moment_publish": shown, "publish": shown])
        func step(kind: String, fn: String? = nil, display: [String: StellarJSON]) -> Intent {
            Intent(kind: kind, summary: "", spend: [:], calls: fn.map { [Intent.Call(contract: token, fn: $0)] }, display: display)
        }
        var held = PlanBindings.Check(settings, user: me)
        XCTAssertNoThrow(try held.step(step(kind: "trust", display: [:]), spends: false, last: false), "a step before it")
        XCTAssertNoThrow(try held.step(step(kind: "moment_publish", fn: "publish", display: ["price": .number(10_000_000), "windowSecs": .string("86400")]),
                                       spends: false, last: true))
        for display: [String: StellarJSON] in [["price": .string("1"), "windowSecs": .number(86400)], ["windowSecs": .number(86400)]] {
            XCTAssertThrowsError(try held.step(step(kind: "moment_publish", display: display), spends: false, last: true)) {
                XCTAssertEqual($0 as? PlanBindings.Refusal, .settings(reason: "the settings are not the ones you chose"))
            }
            XCTAssertThrowsError(try held.step(step(kind: "anything", fn: "publish", display: display), spends: false, last: true), "by its function")
        }
        XCTAssertThrowsError(try held.step(step(kind: "trust", display: [:]), spends: false, last: true)) {
            XCTAssertEqual($0 as? PlanBindings.Refusal, .settings(reason: "the transaction isn't the action you reviewed"))
        }
    }

    func testTheCompatibilityRunPricesUnbuiltStepsAtTheirCeiling() async throws {
        // No server ceiling: the pinned cap is the ceiling, and a step built within it goes out.
        let built = send(10_000_000, fee: 30_000)
        let plan = TestPlan.view([TestPlan.step("s1", "Send")])
        let backend = FakePlanBackend(plan: plan, builds: ["s1": TestPlan.step("s1", "Send", xdr: built.xdr, intent: built.intent)])
        let results = try await runner(backend).run(plan, limits: [xlm: 10_000_000], bindings: toFriend, signer: signer(SignCount()))
        XCTAssertEqual(results.count, 1)
        let builds = await backend.builds
        XCTAssertEqual(builds, ["s1"])
    }
}

// ------------------------------------------------------------------------------------------------------ fakes

extension PlanBindings {
    /// What a user who typed a shared vector's destination confirmed: its `to` and memo when it pays someone else.
    static func typed(_ intent: Intent, user: String) -> PlanBindings {
        guard let to = intent.to, to != user else { return .none }
        return PlanBindings(destination: .confirmed(to: to, memo: intent.memo))
    }
}

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

/// Launch tokens as a fake RPC knows them. Each contract outside the pins it's asked about is one RPC lookup, kept in
/// `lookedUp`; with the RPC down, any lookup fails.
actor FakeInspector: LaunchTokenInspecting {
    private let tokens: Set<String>
    private let down: Bool
    private(set) var lookedUp: Set<String> = []

    init(launchTokens: Set<String> = [], down: Bool = false) {
        tokens = launchTokens
        self.down = down
    }

    func launchTokens(among contracts: [String], pinned: PinnedContracts) async throws -> Set<String> {
        let lookups = Set(contracts).subtracting(pinned.allContracts)
        lookedUp.formUnion(lookups)
        if down, !lookups.isEmpty { throw URLError(.notConnectedToInternet) }
        return lookups.intersection(tokens)
    }
}

/// The Lite API's plan routes: builds a step by swapping in the step given for it (and any other steps `rewrites` gives
/// for that build, as a server that changes what the user reviewed would), and settles every submission.
actor FakePlanBackend: PlanBackend {
    private var plan: PlanView
    private let replacements: [String: PlanStep]
    private let rewrites: [String: [PlanStep]]
    private(set) var builds: [String] = []
    private(set) var submitted: [String] = []
    /// The signed envelope submitted for each step.
    private(set) var signed: [String: String] = [:]

    init(plan: PlanView, builds: [String: PlanStep] = [:], rewrites: [String: [PlanStep]] = [:]) {
        self.plan = plan
        replacements = builds
        self.rewrites = rewrites
    }

    func buildStep(planId: String, stepId: String) async throws -> PlanView {
        builds.append(stepId)
        let swapped = (replacements[stepId].map { [$0] } ?? []) + (rewrites[stepId] ?? [])
        let steps = plan.steps.map { step in swapped.first { $0.id == step.id } ?? step }
        plan = PlanView(planId: plan.planId, kind: plan.kind, expiresAt: plan.expiresAt, steps: steps, fees: plan.fees)
        return plan
    }

    func submit(planId: String, stepId: String, signedXdr: String) async throws -> TxStatus {
        submitted.append(stepId)
        signed[stepId] = signedXdr
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

/// The shared verifier vectors (Tests/StellarCoreTests/Vectors, from backend/tests/vectors/gen-vectors.ts), read from the
/// source tree like the API fixtures: transactions stellar-sdk built, to run and price as plan steps.
enum SharedVectors {
    struct Vector: Decodable {
        struct Expect: Decodable { let ok: Bool; let reason: String? }
        struct Fees: Decodable { let maxFee: String; let maxInclusionPerOp: String; let starterInnerFeeMax: String }
        let name: String
        let envelope: String
        let intent: Intent
        let user: String
        let sponsor: String
        let allowed: [String]
        let launchTokens: [String]
        let launchTokenWasmHash: String
        let monadDomain: UInt32
        let feePolicy: Fees
        let now: Double
        let expect: Expect

        var pinned: PinnedContracts {
            let fees = FeePolicy(maxFee: Int64(feePolicy.maxFee)!, maxInclusionFeePerOp: Int64(feePolicy.maxInclusionPerOp)!, starterInnerFeeMax: Int64(feePolicy.starterInnerFeeMax)!)
            return PinnedContracts(network: .testnet, sponsor: sponsor, launchTokenWasmHash: launchTokenWasmHash, roles: ["all": allowed], feePolicy: fees, monadDomain: monadDomain)
        }
    }

    private struct Keys: Decodable {
        struct Sep5: Decodable { let secret: String }
        let sep5: [Sep5]
    }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("StellarCoreTests/Vectors")

    static func all() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: directory.appendingPathComponent("verifier.json")))
    }

    static func named(_ name: String) throws -> Vector {
        try XCTUnwrap(all().first(where: { $0.name == name }), name)
    }

    /// The key of the vectors' user: SEP-5's published test account (keys.json).
    static func user() throws -> StellarSigner {
        let keys = try JSONDecoder().decode(Keys.self, from: Data(contentsOf: directory.appendingPathComponent("keys.json")))
        return try StellarSigner(secret: try XCTUnwrap(keys.sep5.first).secret)
    }

    /// The TS verifier's reason as the Swift verifier words it: a capital letter and a full stop.
    static func swiftReason(_ reason: String) -> String {
        reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }
}
