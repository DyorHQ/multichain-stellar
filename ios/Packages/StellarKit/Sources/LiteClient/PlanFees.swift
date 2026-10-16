import Foundation
import StellarCore

/// A plan's network fees as the phone works them out (docs/DESIGN-stellar-parity.md §4.4): from each built step's own
/// transaction, and for a step the server hasn't built yet, from its ceiling. This is what the review shows and what the
/// user confirms: `PlanRunner` refuses any step whose fee comes out above its figure here. The server's `maxFee`,
/// `feePayer` and plan `fees` are display hints for the steps it hasn't built; a built step's decoded transaction is
/// the one that counts.
public struct PlanFees: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let id: String
        /// What the step does, as fees are estimated ("swap_soroswap", "trust", …); nil from older servers.
        public let stepKind: String?
        /// The most the step may charge, in stroops: a built step's `tx.fee`, an unbuilt step's ceiling.
        public let maxFee: Int64
        /// Whether `maxFee` is the transaction's own fee (else the server's ceiling, or the pinned cap without one).
        public let built: Bool
        /// Who pays, as far as the phone could check it: an unbuilt step is the user's until its transaction shows
        /// otherwise.
        public let payer: StellarFeePayer
        /// New base reserves the step holds back (a trustline is 1): the server's figure.
        public let reserveDelta: Int
    }

    public let steps: [Step]

    /// The most the user's own steps may charge together, in stroops.
    public var userMax: Int64 {
        steps.filter { $0.payer == .user }.reduce(0) { $0 + $1.maxFee }
    }

    /// The base reserves the plan adds.
    public var newReserves: Int {
        steps.reduce(0) { $0 + $1.reserveDelta }
    }

    /// Whether DyorHQ pays a step, checked on the phone (§4.3): the review says "Paid by DyorHQ" only then.
    public var sponsorVerified: Bool {
        steps.contains { $0.payer != .user }
    }

    /// The user's steps the server hasn't built yet: the review says "+ n more steps" for them.
    public var unbuiltUserSteps: Int {
        steps.filter { !$0.built && $0.payer == .user }.count
    }

    public func step(_ id: String) -> Step? { steps.first { $0.id == id } }

    /// The fee the user confirmed for a step, in stroops.
    public func maxFee(_ stepId: String) -> Int64? { step(stepId)?.maxFee }

    public init(steps: [Step]) {
        self.steps = steps
    }

    /// Works out every step of `plan`. Throws `PlanRunner.Failure.refused` for a step the runner would refuse anyway:
    /// a built step outside the verifier's fee caps (the whole fee, the resource fee's range, the inclusion bid), an
    /// unbuilt step's ceiling above the pinned cap, or a step marked as sponsored that declares more than
    /// `starterInnerFeeMax`. `estimates` prices an unbuilt step the server sent no ceiling for; without either, its
    /// ceiling is the pinned cap.
    public init(plan: PlanView, pinned: PinnedContracts, estimates: StellarFees? = nil) throws {
        steps = try plan.steps.map { step in
            if step.xdr != nil { return try Self.step(step, pinned: pinned) }
            let ceiling: Int64 = step.maxFee.flatMap(TxVerifier.units)
                ?? step.stepKind.flatMap { estimates?.estimate($0) }.flatMap { $0 >= 0 ? $0 : nil }
                ?? pinned.feePolicy.maxFee
            guard ceiling <= pinned.feePolicy.maxFee else {
                throw PlanRunner.Failure.refused(step: step.label, reason: Self.aboveCap)
            }
            return Step(id: step.id, stepKind: step.stepKind, maxFee: ceiling, built: false, payer: .user, reserveDelta: max(0, step.reserveDelta ?? 0))
        }
    }

    /// A built step, from its own transaction: its declared fee, and who pays it.
    public static func step(_ step: PlanStep, pinned: PinnedContracts) throws -> Step {
        guard let xdr = step.xdr else { throw PlanRunner.Failure.refused(step: step.label, reason: "missing transaction") }
        let envelope: TransactionEnvelope
        do {
            envelope = try TransactionEnvelope(base64: xdr)
        } catch {
            throw PlanRunner.Failure.refused(step: step.label, reason: "\(error)")
        }
        return try Self.step(step, envelope: envelope, pinned: pinned)
    }

    static func step(_ step: PlanStep, envelope: TransactionEnvelope, pinned: PinnedContracts) throws -> Step {
        let verifier = TxVerifier(user: "", pinned: pinned)
        let payer: StellarFeePayer
        do {
            // The verifier's own fee caps (the whole fee, the resource fee's range, the inclusion bid), then who pays.
            try verifier.checkFees(envelope.transaction)
            payer = try verifier.feePayer(envelope, intent: step.intent, flaggedPayer: step.feePayer, sponsorReason: step.sponsorReason)
        } catch let f as VerificationFailure {
            throw PlanRunner.Failure.refused(step: step.label, reason: f.reason)
        }
        return Step(id: step.id, stepKind: step.stepKind, maxFee: Int64(envelope.transaction.fee), built: true, payer: payer, reserveDelta: max(0, step.reserveDelta ?? 0))
    }

    /// The verifier's reason for a fee above the cap, so an unbuilt step's ceiling reads the same.
    static let aboveCap = "The network fee is above the limit."
}

public extension XLMReserve {
    /// The account's XLM position as the API sends it (`AccountView.xlm`), recomputed from its parts; nil when a part
    /// isn't a whole number of stroops.
    init?(_ position: StellarXLMPosition) {
        guard let balance = TxVerifier.units(position.balance),
              let baseReserve = TxVerifier.units(position.baseReserve),
              let liabilities = TxVerifier.units(position.sellingLiabilities) else { return nil }
        self.init(
            balance: balance,
            baseReserve: baseReserve,
            subentries: position.reserves.subentries,
            sponsoring: position.reserves.sponsoring,
            sponsored: position.reserves.sponsored,
            sellingLiabilities: liabilities
        )
    }
}
