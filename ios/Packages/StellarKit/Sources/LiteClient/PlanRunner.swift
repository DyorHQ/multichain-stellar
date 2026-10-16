import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StellarCore

/// What the plan runner needs from the Lite API: build a step, submit it, follow it. `LiteAPI` is one; tests pass fakes.
public protocol PlanBackend: Sendable {
    func buildStep(planId: String, stepId: String) async throws -> PlanView
    func submit(planId: String, stepId: String, signedXdr: String) async throws -> TxStatus
    func txStatus(_ hash: String) async throws -> TxStatus
}

extension LiteAPI: PlanBackend {}

/// Recognises the contracts created at runtime on chain by the WASM they run: v1's launch tokens, and v2's launch
/// tokens, Moment NFTs and Moment coins (DESIGN-stellar-contracts-v2 §20.1). `ContractInspector` is one; tests pass
/// fakes.
public protocol LaunchTokenInspecting: Sendable {
    /// The contracts among `contracts` whose code is the pinned v1 launch-token WASM.
    func launchTokens(among contracts: [String], pinned: PinnedContracts) async throws -> Set<String>
    /// The WASM hash (hex) the chain says each contract among `contracts` outside the pins runs. A contract that runs
    /// none (a Stellar Asset Contract, a missing one) is left out.
    func wasmHashes(among contracts: [String], pinned: PinnedContracts) async throws -> [String: String]
}

extension LaunchTokenInspecting {
    /// An inspector that knows only v1's launch tokens answers each with the pinned launch-token hash.
    public func wasmHashes(among contracts: [String], pinned: PinnedContracts) async throws -> [String: String] {
        let tokens = try await launchTokens(among: contracts, pinned: pinned)
        return Dictionary(uniqueKeysWithValues: tokens.map { ($0, pinned.launchTokenWasmHash) })
    }
}

extension ContractInspector: LaunchTokenInspecting {}

/// Runs a plan the way the phone must: for each step, build it if the API hasn't yet, decode it, verify it against
/// its intent AND against the limits and fees the user confirmed on screen, sign it, submit it, wait for the ledger.
/// Mirrors the Pro app's TransactionRun contract: a failed step stops the plan, and what was sent is reported.
public struct PlanRunner: Sendable {
    public enum Event: Sendable, Equatable {
        case building(stepId: String, label: String)
        case signing(stepId: String, label: String)
        case submitted(stepId: String, hash: String)
        case confirmed(stepId: String, hash: String)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case refused(step: String, reason: String)
        case overLimit(asset: String)
        /// The step's fee came out above the one the user confirmed (a step built after the review, or rebuilt).
        case feeAboveConfirmed(step: String)
        case failedOnChain(step: String, hash: String, error: String?)
        case timedOut(step: String, hash: String)

        public var errorDescription: String? {
            switch self {
            case let .refused(step, reason): return "Not signed: \(step) didn't pass the checks (\(reason)). Nothing was sent."
            case .overLimit: return "Not signed: this would spend more than you confirmed. Nothing was sent."
            case let .feeAboveConfirmed(step): return "Not signed: the network fee for \(step) went up since you confirmed. Nothing was sent."
            case let .failedOnChain(step, _, error): return "\(step) failed on the network\(error.map { " (\($0))" } ?? "")."
            case let .timedOut(step, _): return "\(step) was sent; confirmation not seen yet."
            }
        }
    }

    public let api: any PlanBackend
    public let user: String
    public let pinned: PinnedContracts
    public let inspector: any LaunchTokenInspecting
    /// The clock the expiry check reads.
    public var now: @Sendable () -> Date = { Date() }

    public init(api: any PlanBackend, user: String, pinned: PinnedContracts, inspector: any LaunchTokenInspecting) {
        self.api = api
        self.user = user
        self.pinned = pinned
        self.inspector = inspector
    }

    /// A runner that reads launch tokens' code through the pinned RPC (§5.5).
    public init(api: any PlanBackend, user: String, pinned: PinnedContracts) {
        self.init(api: api, user: user, pinned: pinned, inspector: ContractInspector(pinned: pinned))
    }

    /// `plan` is the plan as the user reviewed it: a step it holds built is signed exactly as reviewed, whatever the
    /// server answers later, and only a step it holds unbuilt is taken from the server, once built. `limits`: the most
    /// the user confirmed spending across the whole plan, per asset contract id (base units). An asset not listed may
    /// not be spent at all. `fees`: the network fees the user confirmed, per step (`PlanFees(plan:pinned:)`, worked
    /// out when the review opened); a step whose fee comes out higher, or that the user confirmed as paid by DyorHQ
    /// and no longer is, is refused. `signer` is asked once per step (it may prompt Face ID or a passkey, or ask Privy).
    @discardableResult
    public func run(
        _ plan: PlanView,
        limits: [String: Int64],
        fees: PlanFees,
        signer: @Sendable () async throws -> any StellarHashSigner,
        onEvent: @Sendable (Event) -> Void = { _ in }
    ) async throws -> [TxStatus] {
        var spent: [String: Int64] = [:]
        var results: [TxStatus] = []
        for (index, reviewed) in plan.steps.enumerated() {
            var step = reviewed
            if step.xdr == nil {
                onEvent(.building(stepId: step.id, label: step.label))
                // Of the plan the server answers with, only this step: the others are the ones the user reviewed.
                let built = try await api.buildStep(planId: plan.planId, stepId: step.id)
                guard built.steps.indices.contains(index), built.steps[index].id == step.id else {
                    throw Failure.refused(step: step.label, reason: "the plan changed")
                }
                step = built.steps[index]
            }
            guard let xdr = step.xdr, let intent = step.intent else { throw Failure.refused(step: step.label, reason: "missing transaction") }

            var envelope: TransactionEnvelope
            do {
                envelope = try TransactionEnvelope(base64: xdr)
            } catch {
                throw Failure.refused(step: step.label, reason: "\(error)")
            }
            var verifier = TxVerifier(user: user, pinned: pinned, now: now)
            let candidates = Self.launchTokenCandidates(envelope.transaction, intent: intent)
            let runtime = Self.runtimeContracts(try await inspector.wasmHashes(among: candidates, pinned: pinned), pinned: pinned)
            verifier.verifiedLaunchTokens = runtime.launchTokens
            verifier.runtimeContracts = runtime.v2
            let outflow: [String: Int64]
            do {
                outflow = try verifier.verify(envelope, intent: intent)
            } catch let f as VerificationFailure {
                throw Failure.refused(step: step.label, reason: f.reason)
            }
            // The step's fee and payer, from its own transaction, against what the user confirmed.
            let checked = try PlanFees.step(step, envelope: envelope, pinned: pinned)
            guard let confirmed = fees.step(step.id), checked.maxFee <= confirmed.maxFee,
                  confirmed.payer == .user || checked.payer == confirmed.payer else {
                throw Failure.feeAboveConfirmed(step: step.label)
            }
            for (asset, amount) in outflow {
                spent[asset, default: 0] += amount
                guard let cap = limits[asset], spent[asset]! <= cap else { throw Failure.overLimit(asset: asset) }
            }

            onEvent(.signing(stepId: step.id, label: step.label))
            let key = try await signer()
            guard key.address == user else { throw Failure.refused(step: step.label, reason: "wrong signing key") }
            // A key held elsewhere (Privy) signs over the network: its signature is attached only once it verifies.
            try await envelope.sign(using: key, network: pinned.network)
            let sent = try await api.submit(planId: plan.planId, stepId: step.id, signedXdr: envelope.base64())
            onEvent(.submitted(stepId: step.id, hash: sent.hash))
            let settled = try await waitFor(sent.hash, step: step.label)
            onEvent(.confirmed(stepId: step.id, hash: sent.hash))
            results.append(settled)
        }
        return results
    }

    /// The same run, with the fees worked out from `plan` and the pins as it starts: an unbuilt step may then cost
    /// up to its ceiling (or the pinned cap). For callers that don't show the fees yet.
    @discardableResult
    public func run(
        _ plan: PlanView,
        limits: [String: Int64],
        signer: @Sendable () async throws -> any StellarHashSigner,
        onEvent: @Sendable (Event) -> Void = { _ in }
    ) async throws -> [TxStatus] {
        try await run(plan, limits: limits, fees: PlanFees(plan: plan, pinned: pinned), signer: signer, onEvent: onEvent)
    }

    /// The contracts the verifier may need to know as runtime contracts (launch tokens, Moment NFTs and coins): the
    /// calls the intent names, and for a restore the contracts whose data it brings back (§4.9). Any other step's
    /// footprint plays no part in the checks, so it costs no RPC lookup and an RPC that's down can't stop it.
    static func launchTokenCandidates(_ tx: Transaction, intent: Intent) -> [String] {
        let calls = (intent.calls ?? []).map(\.contract)
        guard intent.kind == "restore", tx.operations.contains(where: { $0.body == .restoreFootprint }) else { return calls }
        return calls + (tx.footprint?.contracts ?? [])
    }

    /// The runtime-contract check (DESIGN-stellar-contracts-v2 §20.1): of the contracts read on chain, v1's launch tokens
    /// are the ones that run the pinned launch-token WASM, and v2's runtime contracts the ones that run one of
    /// `pinned.runtimeWasmHashes` (launch-token-v2, moment-nft, moment-coin), each with its hash. A contract that runs
    /// any other WASM is neither, so the verifier refuses a call to it, or a restore of its data.
    static func runtimeContracts(_ hashes: [String: String], pinned: PinnedContracts) -> (launchTokens: Set<String>, v2: [String: String]) {
        let v1 = pinned.launchTokenWasmHash.lowercased()
        let v2 = Set(pinned.runtimeWasmHashes.values.map { $0.lowercased() }.filter { !$0.isEmpty })
        let read = hashes.mapValues { $0.lowercased() }
        return (Set(read.filter { !v1.isEmpty && $0.value == v1 }.keys), read.filter { v2.contains($0.value) })
    }

    private func waitFor(_ hash: String, step: String) async throws -> TxStatus {
        for _ in 0..<45 {
            let s = try await api.txStatus(hash)
            switch s.status {
            case "success": return s
            case "failed": throw Failure.failedOnChain(step: step, hash: hash, error: s.error)
            default: try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw Failure.timedOut(step: step, hash: hash)
    }
}

/// Reads contract instances straight from Stellar RPC (not through the Lite API) to recognise the contracts created at
/// runtime: a contract counts as a launch token, a Moment NFT or a Moment coin only if its WASM hash is the pinned one
/// (`PlanRunner.runtimeContracts`) and, for v2, the pinned singleton created it (`RuntimeProvenance`).
public struct ContractInspector: Sendable {
    public let rpcURL: URL
    private let session: URLSession

    public init(rpcURL: URL, session: URLSession = .shared) {
        self.rpcURL = rpcURL
        self.session = session
    }

    /// An inspector on the build's pinned RPC: what the phone uses, whatever RPC the server's config names (§5.5).
    public init(pinned: PinnedContracts, session: URLSession = .shared) {
        self.init(rpcURL: pinned.rpcURL, session: session)
    }

    public func launchTokens(among contracts: [String], pinned: PinnedContracts) async throws -> Set<String> {
        guard !pinned.launchTokenWasmHash.isEmpty else { return [] }
        return PlanRunner.runtimeContracts(try await wasmHashes(among: contracts, pinned: pinned), pinned: pinned).launchTokens
    }

    /// One RPC read per contract outside the pins; none at all while no runtime WASM is pinned, since nothing read
    /// could then count.
    public func wasmHashes(among contracts: [String], pinned: PinnedContracts) async throws -> [String: String] {
        let unknown = Set(contracts).subtracting(pinned.allContracts).sorted()
        let runtimePinned = !pinned.launchTokenWasmHash.isEmpty || pinned.runtimeWasmHashes.values.contains { !$0.isEmpty }
        guard !unknown.isEmpty, runtimePinned else { return [:] }
        var out: [String: String] = [:]
        for c in unknown {
            if let hash = try await wasmHash(of: c, pinned: pinned) { out[c] = hash }
        }
        return out
    }

    /// The hex WASM hash `contract` counts by, or nil for a Stellar Asset Contract, a missing contract, an entry of
    /// another contract, or an instance of a pinned v2 WASM that the pinned singleton didn't create (RuntimeProvenance).
    public func wasmHash(of contract: String, pinned: PinnedContracts) async throws -> String? {
        let key = try Self.instanceKey(contract)
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "getLedgerEntries", "params": ["keys": [key]]]
        var req = URLRequest(url: rpcURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data = try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: req) { d, _, e in
                if let e { cont.resume(throwing: e) } else { cont.resume(returning: d ?? Data()) }
            }.resume()
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let entries = result["entries"] as? [[String: Any]],
              let xdr = entries.first?["xdr"] as? String,
              let bytes = Data(base64Encoded: xdr) else { return nil }
        return try RuntimeProvenance.wasmHash(ofInstance: [UInt8](bytes), contract: contract, pinned: pinned)
    }

    /// LedgerKey::ContractData { contract, ScVal::LedgerKeyContractInstance, persistent }, base64.
    static func instanceKey(_ contract: String) throws -> String {
        var w = XDRWriter()
        w.uint32(6) // CONTRACT_DATA
        w.uint32(1) // SC_ADDRESS_TYPE_CONTRACT
        w.raw(try StrKey.decode(.contract, contract))
        w.uint32(20) // SCV_LEDGER_KEY_CONTRACT_INSTANCE
        w.uint32(1) // PERSISTENT
        return Data(w.bytes).base64EncodedString()
    }
}
