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

/// Who pays a step's network fee, as far as the phone can check it (docs/DESIGN-stellar-parity.md §4.3).
public enum StellarFeePayer: Equatable, Sendable {
    case user
    /// DyorHQ, and the phone checked it: an activation the sponsor is the source of, or a starter swap whose own fee is
    /// within the pinned `starterInnerFeeMax`.
    case dyorHQ(StellarSponsorReason)
}

public enum StellarSponsorReason: String, Equatable, Sendable {
    /// The account's setup (`activate`).
    case setup
    /// Mainnet's one swap into XLM for an account that holds none.
    case starterSwap = "starter_swap"
}

/// Checks a transaction before the user's key signs it. Same rules as backend/.../verify.ts, with the same reasons
/// (capitalised here, with a full stop); both are tested against the same vectors (Tests/StellarCoreTests/Vectors).
///
/// The rules (docs/DESIGN-stellar-parity.md §4.4, §4.9, §5.2): the user's own source; a short expiry; the pinned fee
/// caps; the memo the user confirmed; only the operation types the intent names; the sponsor only in an account's
/// activation; payments and new accounts only to the address the user confirmed; contract calls only to pinned
/// contracts (and verified launch tokens), only the functions the intent names, each bound by its call rule; Soroban
/// auth only through the source account; restores only as their own intent, of the app's own data; and the user's
/// total outflow per asset never above what the intent declares.
public struct TxVerifier {
    public let user: String
    public let pinned: PinnedContracts
    /// Launch tokens the app has confirmed were deployed from the pinned launch-token WASM (checked on-chain by
    /// LiteClient before it asks for a signature).
    public var verifiedLaunchTokens: Set<String>
    public var now: () -> Date

    static let tokenSpendFunctions: Set<String> = ["transfer", "transfer_from", "burn", "burn_from", "approve"]
    static let maxValidity: TimeInterval = 30 * 60

    static let destination = "The destination is not the one you confirmed."
    static let forAnother = "The call acts for another account."
    static let arguments = "The call's arguments are not as expected."
    static let belowMinimum = "The minimum received is lower than quoted."
    static let outOfRange = "Amount out of range."

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
        try checkFees(tx)
        guard Self.memo(tx.memo, matches: intent.memo) else { throw fail("The memo is not the one you confirmed.") }

        var outflow = Outflow()
        let allowedOps = Set(intent.ops ?? [])
        let allowedCalls = intent.calls ?? []
        let allowedContracts = pinned.allContracts.union(verifiedLaunchTokens)

        for op in tx.operations {
            let opSource = op.source ?? tx.source
            guard opSource == user || opSource == sponsor else { throw fail("An operation runs from a third account.") }
            if opSource == sponsor {
                // DyorHQ pays only an account's setup (§4.3): anywhere else, the sponsor in a transaction is refused.
                guard intent.kind == "activate" else { throw fail("The sponsor appears outside account activation.") }
                switch op.body {
                case .beginSponsoringFutureReserves, .createAccount: break
                default: throw fail("The sponsor account runs an unexpected operation.")
                }
            }
            if case .invokeHostFunction = op.body {} else if !allowedOps.contains(op.body.typeName) {
                throw fail("Operation \(op.body.typeName) is not part of this action.")
            }
            switch op.body {
            case let .payment(destination, asset, amount):
                guard destination == intent.to else { throw fail(Self.destination) }
                try outflow.add(sac(asset), amount)
            case let .pathPaymentStrictSend(sendAsset, sendAmount, destination, destAsset, destMin, _):
                guard destination == user else { throw fail("Swap output goes to another account.") }
                try outflow.add(sac(sendAsset), sendAmount)
                if intent.receive != nil {
                    guard let want = Self.minimum(intent, for: sac(destAsset)), destMin >= want else { throw fail(Self.belowMinimum) }
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
                    // Sponsored activation: only the user's own account, with 0 XLM.
                    guard destination == user, startingBalance == 0 else { throw fail("Unexpected account creation.") }
                } else {
                    // The user funds a new account (a send of XLM to an address that doesn't exist yet).
                    guard destination == intent.to else { throw fail(Self.destination) }
                    try outflow.add(sac(.native), startingBalance)
                }
            case let .invokeHostFunction(fn, auth):
                guard case let .invokeContract(call) = fn, case let .contract(contract) = call.contract else {
                    throw fail("Only contract calls are allowed.")
                }
                guard allowedContracts.contains(contract) else { throw fail("Contract \(contract) is not on the allowlist.") }
                guard allowedCalls.contains(where: { $0.contract == contract && $0.fn == call.function }) else {
                    throw fail("Call \(call.function) is not part of this action.")
                }
                try checkCall(call, intent: intent, allowed: allowedContracts)
                for entry in auth {
                    guard entry.credentials == .sourceAccount else { throw fail("The transaction needs a signature from another address.") }
                    // The authorization of the call itself is bound by the call's rule; any other root is bound here.
                    let covered = entry.rootInvocation.function == .contractFn(call)
                    try walk(entry.rootInvocation, intent: intent, covered: covered, outflow: &outflow)
                }
            case .restoreFootprint:
                // Archived entries come back only as their own step, and only the app's own data (§4.9).
                guard intent.kind == "restore" else { throw fail("Restoring archived data is only allowed as its own action.") }
                let keys = (tx.footprint?.readOnly ?? []) + (tx.footprint?.readWrite ?? [])
                for key in keys where !restorable(key, allowed: allowedContracts) {
                    throw fail("The restore touches data outside the allowlist.")
                }
            case .manageData, .extendFootprintTTL:
                throw fail("Operation \(op.body.typeName) is not allowed.")
            }
        }

        for (asset, amount) in outflow.entries {
            guard let capText = intent.spend[asset] else { throw fail("The transaction spends an asset this action doesn't declare (\(asset)).") }
            guard let cap = Self.units(capText), amount <= cap else { throw fail("The transaction spends more than this action declares (\(asset)).") }
        }
        return outflow.byAsset
    }

    /// Who pays the step's fee, as the phone can check it (§4.3): DyorHQ for an activation whose source is the sponsor,
    /// or for a step the server marks as the starter swap whose own fee is within `starterInnerFeeMax`; the user
    /// otherwise. A step the server marks as sponsored is refused above `starterInnerFeeMax`, so a server that claims to
    /// pay and doesn't can charge the user at most that.
    public func feePayer(_ envelope: TransactionEnvelope, intent: Intent?, flaggedPayer: String?, sponsorReason: String?) throws -> StellarFeePayer {
        let tx = envelope.transaction
        if tx.source == pinned.sponsor, intent?.kind == "activate" { return .dyorHQ(.setup) }
        guard flaggedPayer == "sponsor" else { return .user }
        guard Int64(tx.fee) <= pinned.feePolicy.starterInnerFeeMax else { throw fail("The sponsored step's network fee is above the limit.") }
        return sponsorReason == StellarSponsorReason.starterSwap.rawValue ? .dyorHQ(.starterSwap) : .user
    }

    /// The fee caps (§4.4): the whole fee, then the resource fee's range and the inclusion bid per operation.
    private func checkFees(_ tx: Transaction) throws {
        let policy = pinned.feePolicy
        let fee = Int64(tx.fee)
        let ops = Int64(tx.operations.count)
        guard fee <= policy.maxFee else { throw fail("The network fee is above the limit.") }
        if let resourceFee = tx.resourceFee {
            guard resourceFee >= 0, resourceFee <= fee else { throw fail("The resource fee is out of range.") }
            guard fee - resourceFee <= policy.maxInclusionFeePerOp * ops else { throw fail("The inclusion fee is above the limit.") }
        } else {
            guard fee <= policy.maxInclusionFeePerOp * ops else { throw fail("The inclusion fee is above the limit.") }
        }
    }

    /// The transaction's memo is the intent's, compared as bytes (text), as a decimal (id) or as hex (hash); a
    /// transaction without a memo matches an intent without one.
    static func memo(_ memo: StellarMemo, matches want: Intent.Memo?) -> Bool {
        guard let want else { return memo == .none }
        switch memo {
        case .none, .returnHash: return false
        case let .text(bytes): return want.type == "text" && Array(want.value.utf8) == bytes
        case let .id(id): return want.type == "id" && want.value == String(id)
        case let .hash(bytes): return want.type == "hash" && want.value.lowercased() == hex(bytes)
        }
    }

    /// A footprint entry a restore may bring back: an allowlisted contract's or a verified launch token's data, or the
    /// pinned launch-token WASM.
    private func restorable(_ key: StellarLedgerKey, allowed: Set<String>) -> Bool {
        switch key {
        case let .contractData(.contract(contract), _, _): return allowed.contains(contract)
        case let .contractCode(hash): return !pinned.launchTokenWasmHash.isEmpty && hex(hash) == pinned.launchTokenWasmHash
        default: return false
        }
    }

    /// Adds every token outflow the user authorizes (transfer/burn/approve/transfer_from/burn_from from the user). A
    /// transfer outside a call that has its own rule (`covered`) must go to the address the user confirmed.
    private func walk(_ inv: AuthorizedInvocation, intent: Intent, covered: Bool, outflow: inout Outflow) throws {
        guard case let .contractFn(c) = inv.function, let contract = c.contract.string else {
            throw fail("The transaction asks to authorize contract creation.")
        }
        if Self.tokenSpendFunctions.contains(c.function) {
            // An approval counts in full: the spender may take it later.
            let layout: [String: (from: Int, amount: Int)] = [
                "transfer": (0, 2), "burn": (0, 1), "approve": (0, 2), "transfer_from": (1, 3), "burn_from": (1, 2),
            ]
            if let l = layout[c.function], c.args.count > l.amount, c.args[l.from].addressString == user {
                guard let n = c.args[l.amount].amount else { throw fail(Self.outOfRange) }
                try outflow.add(contract, n)
            }
        }
        if !covered, c.function == "transfer" || c.function == "transfer_from" {
            let (from, to) = c.function == "transfer" ? (0, 1) : (1, 2)
            if c.args.count > to, c.args[from].addressString == user, !Self.isConfirmed(c.args[to], intent) {
                throw fail(Self.destination)
            }
        }
        for sub in inv.subInvocations { try walk(sub, intent: intent, covered: covered, outflow: &outflow) }
    }

    /// The Stellar Asset Contract id of a classic asset on this network.
    public func sac(_ asset: Asset) -> String {
        AssetContract.id(asset, network: pinned.network)
    }

    /// Base units written as a decimal string: digits only, within Int64. Anything else is nil.
    public static func units(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(text)
    }

    /// Whether `value` is the G… or C… address the user confirmed.
    static func isConfirmed(_ value: SCVal, _ intent: Intent) -> Bool {
        guard let address = value.addressString else { return false }
        return address == intent.to
    }

    /// The minimum the intent quotes for `asset`, or nil when it quotes none.
    static func minimum(_ intent: Intent, for asset: String) -> Int64? {
        guard let text = intent.receive?[asset] else { return nil }
        return units(text)
    }

    /// The user's outflow per asset, in the order the assets first appear (the first one over its cap is the one named).
    struct Outflow {
        private(set) var byAsset: [String: Int64] = [:]
        private var order: [String] = []

        var entries: [(String, Int64)] { order.map { ($0, byAsset[$0]!) } }

        mutating func add(_ asset: String, _ amount: Int64) throws {
            let (sum, overflow) = (byAsset[asset] ?? 0).addingReportingOverflow(amount)
            guard !overflow, amount >= 0 else { throw VerificationFailure(reason: TxVerifier.outOfRange) }
            if byAsset[asset] == nil { order.append(asset) }
            byAsset[asset] = sum
        }
    }
}

// ------------------------------------------------------------------------------------------------------ call rules

extension TxVerifier {
    /// The call rule of each function the app signs (§5.2): what the call's arguments must say for this action. Each was
    /// written from the contract's own signature: contracts/launchpad and contracts/moments (the deployed v1 WASMs), the
    /// Soroswap and Aquarius routers' published ABIs, Blend's pool, Circle's TokenMessengerMinter and SEP-41. A function
    /// without a rule is not signed. Same order of checks as verify.ts's CALL_RULES.
    func checkCall(_ call: InvokeContractArgs, intent: Intent, allowed: Set<String>) throws {
        let args = call.args
        func arity(_ n: Int) throws { guard args.count == n else { throw fail(Self.arguments) } }
        func actsForUser(_ indices: Int...) throws {
            for i in indices where args[i].addressString != user { throw fail(Self.forAnother) }
        }
        func atLeast(_ min: Int64?, _ quoted: Int64?) throws {
            guard let min else { throw fail(Self.arguments) }
            guard let quoted, min >= quoted else { throw fail(Self.belowMinimum) }
        }
        switch call.function {
        case "transfer":
            // SEP-41 / SAC transfer(from, to, amount): a send, to the address the user confirmed.
            try arity(3)
            try actsForUser(0)
            guard Self.isConfirmed(args[1], intent) else { throw fail(Self.destination) }
        case "approve":
            // approve(from, spender, amount, live_until_ledger): an allowance for a pinned contract (the CCTP messenger).
            try arity(4)
            try actsForUser(0)
            guard let spender = args[1].addressString, allowed.contains(spender) else {
                throw fail("The allowance is for a contract outside the allowlist.")
            }
        case "swap_exact_tokens_for_tokens":
            // Soroswap router swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline).
            try arity(5)
            guard args[3].addressString == user else { throw fail("Swap output goes to another account.") }
            guard case let .vec(path?) = args[2], let last = path.last, let out = last.addressString else { throw fail(Self.arguments) }
            try atLeast(args[1].amount, Self.minimum(intent, for: out))
        case "swap_chained":
            // Aquarius router swap_chained(user, swaps_chain, token_in, in_amount, out_min); each hop is
            // (tokens, pool_index, token_out), so the last hop's token_out is what the user receives.
            try arity(5)
            try actsForUser(0)
            guard case let .vec(chain?) = args[1], case let .vec(hop?)? = chain.last, hop.count == 3, let out = hop[2].addressString else {
                throw fail(Self.arguments)
            }
            try atLeast(args[4].amount, Self.minimum(intent, for: out))
        case "launch":
            // Launchpad launch(creator, quote, name, symbol, uri, creator_fee_bps, initial_buy, min_tokens_out).
            try arity(8)
            try actsForUser(0)
        case "buy":
            // Launchpad buy(buyer, token, quote_in, min_tokens_out).
            try arity(4)
            try actsForUser(0)
            guard let token = args[1].addressString else { throw fail(Self.arguments) }
            try atLeast(args[3].amount, Self.minimum(intent, for: token))
        case "sell":
            // Launchpad sell(seller, token, tokens_in, min_quote_out): the quote asset isn't an argument, so the intent
            // quotes exactly one minimum.
            try arity(4)
            try actsForUser(0)
            guard args[1].addressString != nil else { throw fail(Self.arguments) }
            let quoted = intent.receive.flatMap { $0.count == 1 ? $0.values.first.flatMap(Self.units) : nil }
            try atLeast(args[3].amount, quoted)
        case "graduate", "claim_creator_fees":
            // Launchpad graduate(token) and claim_creator_fees(token): anyone may call them, and they pay only the
            // launch's own creator, pair and treasury, never from the caller.
            try arity(1)
            guard args[0].addressString != nil else { throw fail(Self.arguments) }
        case "publish":
            // Moments publish(creator, uri, price, quote, max_editions, window_secs).
            try arity(6)
            try actsForUser(0)
        case "collect":
            // Moments collect(collector, moment_id, quantity, max_total).
            try arity(4)
            try actsForUser(0)
        case "submit":
            // Blend pool submit(from, spender, to, requests).
            try arity(4)
            try actsForUser(0, 1, 2)
        case "deposit_for_burn":
            // CCTP TokenMessengerMinter deposit_for_burn(from, amount, destination_domain, mint_recipient, burn_token,
            // destination_caller, max_fee, min_finality_threshold).
            try arity(8)
            try actsForUser(0)
            guard case let .u32(domain) = args[2] else { throw fail(Self.arguments) }
            guard domain == pinned.monadDomain else { throw fail("The bridge sends to another network.") }
            guard case let .bytes(recipient) = args[3], recipient.count == 32 else { throw fail(Self.arguments) }
            guard let want = Self.evmBytes32(intent.to), want == recipient else { throw fail(Self.destination) }
        default:
            throw fail("Function \(call.function) is not on the allowlist.")
        }
    }

    /// A Monad address (0x + 40 hex) as the 32 bytes CCTP mints to; nil for anything else.
    static func evmBytes32(_ address: String?) -> [UInt8]? {
        guard let address, address.utf8.count == 42, address.hasPrefix("0x") else { return nil }
        var bytes = [UInt8](repeating: 0, count: 12)
        var digits = Array(address.utf8.dropFirst(2)).makeIterator()
        while let hi = digits.next(), let lo = digits.next() {
            guard let h = hexValue(hi), let l = hexValue(lo) else { return nil }
            bytes.append(h << 4 | l)
        }
        return bytes
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}

/// Lowercase hex.
func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
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
