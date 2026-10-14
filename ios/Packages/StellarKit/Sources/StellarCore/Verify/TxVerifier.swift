import Foundation

/// What the user confirmed, as the API describes it. The phone checks the transaction against these fields; the
/// summary text is never trusted on its own (the confirmation sheet builds its own words from `display`).
public struct Intent: Codable, Equatable, Sendable {
    public struct Call: Codable, Equatable, Sendable {
        public let contract: String
        public let fn: String
        public init(contract: String, fn: String) {
            self.contract = contract
            self.fn = fn
        }
    }

    public let kind: String
    public let summary: String
    /// Max outflow per asset contract id, base units as decimal strings.
    public let spend: [String: String]
    public let receive: [String: String]?
    public let calls: [Call]?
    public let ops: [String]?
    public let trust: [String]?
    public let display: [String: StellarJSON]?
    /// The destination the user typed or confirmed: a G… or C… address, or for `bridge_out` the Monad address as 0x-hex.
    /// Absent from older servers' intents.
    public let to: String?
    /// The memo the user typed or confirmed. Absent when the transaction carries none, and from older servers' intents.
    public let memo: Memo?

    /// A transaction memo as the user confirmed it.
    public struct Memo: Codable, Equatable, Sendable {
        /// "text", "id" or "hash".
        public let type: String
        public let value: String
        public init(type: String, value: String) {
            self.type = type
            self.value = value
        }
    }

    public init(kind: String, summary: String, spend: [String: String], receive: [String: String]? = nil, calls: [Call]? = nil, ops: [String]? = nil, trust: [String]? = nil, display: [String: StellarJSON]? = nil, to: String? = nil, memo: Memo? = nil) {
        self.kind = kind
        self.summary = summary
        self.spend = spend
        self.receive = receive
        self.calls = calls
        self.ops = ops
        self.trust = trust
        self.display = display
        self.to = to
        self.memo = memo
    }
}

/// A JSON scalar (display fields).
public enum StellarJSON: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    public var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "yes" : "no"
        case .null: return ""
        }
    }
}

public struct VerificationFailure: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// Checks a transaction before the user's key signs it. Same rules as backend/.../verify.ts; both are tested against
/// the same vectors (Tests/StellarCoreTests/Vectors).
public struct TxVerifier {
    public let user: String
    public let pinned: PinnedContracts
    /// Launch tokens the app has confirmed were deployed from the pinned launch-token WASM (checked on-chain by
    /// LiteClient before it asks for a signature).
    public var verifiedLaunchTokens: Set<String>
    public var now: () -> Date

    static let tokenSpendFunctions: Set<String> = ["transfer", "transfer_from", "burn", "burn_from", "approve"]
    static let maxValidity: TimeInterval = 30 * 60

    public init(user: String, pinned: PinnedContracts, verifiedLaunchTokens: Set<String> = [], now: @escaping () -> Date = Date.init) {
        self.user = user
        self.pinned = pinned
        self.verifiedLaunchTokens = verifiedLaunchTokens
        self.now = now
    }

    private func fail(_ reason: String) -> VerificationFailure { VerificationFailure(reason: reason) }

    /// Returns the outflow per asset contract id when the transaction is acceptable; throws the reason otherwise.
    @discardableResult
    public func verify(_ envelope: TransactionEnvelope, intent: Intent) throws -> [String: Int64] {
        let tx = envelope.transaction
        let sponsor = pinned.sponsor
        let sourceOK = tx.source == user || (intent.kind == "activate" && tx.source == sponsor)
        guard sourceOK else { throw fail("The transaction is not from your account.") }
        guard let tb = tx.timeBounds, tb.maxTime != 0, Double(tb.maxTime) <= now().timeIntervalSince1970 + Self.maxValidity else {
            throw fail("The transaction has no short expiry.")
        }
        guard (1...8).contains(tx.operations.count) else { throw fail("Unexpected number of operations.") }

        var outflow: [String: Int64] = [:]
        func add(_ asset: String, _ amount: Int64) throws {
            let (sum, overflow) = (outflow[asset] ?? 0).addingReportingOverflow(amount)
            guard !overflow, amount >= 0 else { throw fail("Amount out of range.") }
            outflow[asset] = sum
        }
        let allowedOps = Set(intent.ops ?? [])
        let allowedCalls = intent.calls ?? []
        let allowedContracts = pinned.allContracts.union(verifiedLaunchTokens)

        for op in tx.operations {
            let opSource = op.source ?? tx.source
            guard opSource == user || opSource == sponsor else { throw fail("An operation runs from a third account.") }
            if opSource == sponsor {
                switch op.body {
                case .beginSponsoringFutureReserves, .createAccount: break
                default: throw fail("The sponsor account runs an unexpected operation.")
                }
            }
            if case .invokeHostFunction = op.body {} else if !allowedOps.contains(op.body.typeName) {
                throw fail("Operation \(op.body.typeName) is not part of this action.")
            }
            switch op.body {
            case let .payment(_, asset, amount):
                if opSource == user { try add(sac(asset), amount) }
            case let .pathPaymentStrictSend(sendAsset, sendAmount, destination, destAsset, destMin, _):
                guard destination == user else { throw fail("Swap output goes to another account.") }
                try add(sac(sendAsset), sendAmount)
                if let receive = intent.receive {
                    guard let want = receive[sac(destAsset)].flatMap(Int64.init), destMin >= want else {
                        throw fail("The minimum received is lower than quoted.")
                    }
                }
            case let .changeTrust(asset, limit):
                guard (intent.trust ?? []).contains(asset.spec) else { throw fail("Unexpected trustline \(asset.spec).") }
                guard limit > 0 else { throw fail("The transaction removes a trustline.") }
            case let .beginSponsoringFutureReserves(sponsored):
                guard sponsored == user, opSource == sponsor else { throw fail("Unexpected sponsorship.") }
            case .endSponsoringFutureReserves:
                guard opSource == user else { throw fail("Unexpected sponsorship end.") }
            case let .createAccount(destination, startingBalance):
                if opSource == sponsor {
                    guard destination == user, startingBalance == 0 else { throw fail("Unexpected account creation.") }
                } else {
                    try add(sac(.native), startingBalance)
                }
            case let .invokeHostFunction(fn, auth):
                guard case let .invokeContract(call) = fn, let contract = call.contract.string, case .contract = call.contract else {
                    throw fail("Only contract calls are allowed.")
                }
                guard allowedContracts.contains(contract) else { throw fail("Contract \(contract) is not on the allowlist.") }
                guard allowedCalls.contains(where: { $0.contract == contract && $0.fn == call.function }) else {
                    throw fail("Call \(call.function) is not part of this action.")
                }
                for entry in auth {
                    guard entry.credentials == .sourceAccount else { throw fail("The transaction needs a signature from another address.") }
                    try walk(entry.rootInvocation, add: add)
                }
            case .manageData, .extendFootprintTTL, .restoreFootprint:
                throw fail("Operation \(op.body.typeName) is not allowed.")
            }
        }

        for (asset, amount) in outflow {
            guard let capText = intent.spend[asset] else { throw fail("The transaction spends an asset this action doesn't declare (\(asset)).") }
            guard let cap = Int64(capText), amount <= cap else { throw fail("The transaction spends more than this action declares (\(asset)).") }
        }
        return outflow
    }

    /// Adds every token outflow the user authorizes (transfer/burn/approve/transfer_from/burn_from from the user).
    private func walk(_ inv: AuthorizedInvocation, add: (String, Int64) throws -> Void) throws {
        guard case let .contractFn(c) = inv.function, let contract = c.contract.string else {
            throw fail("The transaction asks to authorize contract creation.")
        }
        if Self.tokenSpendFunctions.contains(c.function) {
            let layout: [String: (from: Int, amount: Int)] = [
                "transfer": (0, 2), "burn": (0, 1), "approve": (0, 2), "transfer_from": (1, 3), "burn_from": (1, 2),
            ]
            if let l = layout[c.function], c.args.count > l.amount, c.args[l.from].addressString == user {
                guard let n = c.args[l.amount].amount else { throw fail("Amount out of range.") }
                try add(contract, n)
            }
        }
        for sub in inv.subInvocations { try walk(sub, add: add) }
    }

    /// The Stellar Asset Contract id of a classic asset on this network.
    public func sac(_ asset: Asset) -> String {
        AssetContract.id(asset, network: pinned.network)
    }
}

/// Deterministic Stellar Asset Contract ids: sha256(HashIDPreimage{ENVELOPE_TYPE_CONTRACT_ID, networkID, fromAsset}).
public enum AssetContract {
    public static func id(_ asset: Asset, network: StellarNetwork) -> String {
        var w = XDRWriter()
        w.uint32(8) // HashIDPreimage: ENVELOPE_TYPE_CONTRACT_ID
        w.raw(network.networkID)
        w.uint32(1) // CONTRACT_ID_PREIMAGE_FROM_ASSET
        switch asset {
        case .native: w.uint32(0)
        case let .credit(code, issuer):
            let bytes = Array(code.utf8)
            let width = bytes.count <= 4 ? 4 : 12
            w.uint32(bytes.count <= 4 ? 1 : 2)
            w.raw(bytes + [UInt8](repeating: 0, count: width - bytes.count))
            w.uint32(0)
            w.raw((try? StrKey.decode(.accountID, issuer)) ?? [])
        }
        return StrKey.contractID(Array(SHA256Bridge.hash(w.bytes)))
    }
}
