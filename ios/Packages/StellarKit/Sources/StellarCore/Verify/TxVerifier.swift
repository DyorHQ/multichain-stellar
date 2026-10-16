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
/// auth only through the source account, of the call itself only, with nothing beneath it but spends of the user's own
/// tokens; a positive minimum wherever a trade encodes one; restores only as their own intent, of the app's own data;
/// and the user's total outflow per asset never above what the intent declares.
///
/// Contracts v2 (docs/DESIGN-stellar-contracts-v2.md §20.4): the live generation's contracts are pinned by role, and
/// the ones it creates at runtime (launch tokens, Moment NFTs and coins) are allowed only by their pinned WASM hash. A
/// call to launchpad-v2, moments-v2 or the lp-locker is judged by that contract's own rules, since v1's launchpad and
/// Moments use some of the same function names with other arguments: a launch binds its terms to the pins (the
/// executors, the locker, the token's WASM and the durations) and pays exactly its terms' fee, at most the pinned
/// bound, to the launchpad, and the creator-fee recipient, exemptions, creator fee and sharing are the ones the intent
/// shows (a Moment's price, allocation and window likewise); refunds, collects and claims act for the user; a call
/// anyone may make carries none of the user's authorization.
public struct TxVerifier {
    public let user: String
    public let pinned: PinnedContracts
    /// Launch tokens the app has confirmed were deployed from the pinned launch-token WASM (checked on-chain by
    /// LiteClient before it asks for a signature).
    public var verifiedLaunchTokens: Set<String>
    /// Contracts v2 created at runtime, each with the WASM hash (hex) the chain says it runs, as LiteClient read them.
    /// One counts as pinned only when that hash is one of `pinned.runtimeWasmHashes`.
    public var runtimeContracts: [String: String]
    public var now: () -> Date

    /// The token-spend functions (SEP-41 and the SAC), with the position of the account the tokens leave, of the
    /// amount, and their arity: transfer(from, to, amount) · burn(from, amount) · approve(from, spender, amount,
    /// live_until) · transfer_from(spender, from, to, amount) · burn_from(spender, from, amount).
    static let tokenSpends: [String: (from: Int, amount: Int, arity: Int)] = [
        "transfer": (0, 2, 3), "burn": (0, 1, 2), "approve": (0, 2, 4), "transfer_from": (1, 3, 4), "burn_from": (1, 2, 3),
    ]
    static let maxValidity: TimeInterval = 30 * 60

    static let destination = "The destination is not the one you confirmed."
    static let forAnother = "The call acts for another account."
    static let arguments = "The call's arguments are not as expected."
    static let belowMinimum = "The minimum received is lower than quoted."
    static let outOfRange = "Amount out of range."
    static let anyone = "A call anyone may make carries your authorization."
    static let claimSpends = "A claim must not spend anything."
    static let ticker = "The ticker is not 2 to 10 letters or digits."
    static let launchVenue = "The launch terms name a venue this app doesn't pin."
    static let launchTerms = "The launch terms are not the ones this app pins."
    static let launchFeeLimit = "The launch fee is above the limit."
    static let launchFeeTo = "The launch fee goes to another address than the launchpad."
    static let launchFeeAmount = "The launch fee is not the one in the terms."
    static let momentTerms = "The Moment's terms are not the ones this app pins."
    static let creation = "The transaction asks to authorize contract creation."
    /// An authorization entry whose root is not the call being judged (a second call the user would authorize).
    static let extraAuth = "The transaction asks you to authorize a call other than this one."
    /// A node beneath the call's own authorization that is not a spend of the user's own tokens.
    static let otherAuth = "The transaction asks you to authorize a call that is not a spend of your tokens."
    static let noMinimum = "The transaction sets no minimum received."
    static let route = "The swap route goes through a token this app doesn't list."
    static let launchRecipient = "The creator fees go to another address than the one you confirmed."
    static let launchSettings = "The launch settings are not the ones shown."
    static let momentSettings = "The Moment's price, allocation or window is not the one shown."

    public init(
        user: String,
        pinned: PinnedContracts,
        verifiedLaunchTokens: Set<String> = [],
        runtimeContracts: [String: String] = [:],
        now: @escaping () -> Date = Date.init
    ) {
        self.user = user
        self.pinned = pinned
        self.verifiedLaunchTokens = verifiedLaunchTokens
        self.runtimeContracts = runtimeContracts
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
        let v2 = V2Pins(pinned)
        // A contract v2 created at runtime counts only when the WASM it runs is one of the pinned runtime hashes.
        let runtimeHashes = v2?.runtimeHashes ?? []
        let provenRuntime = runtimeContracts.filter { runtimeHashes.contains($0.value) }.keys
        let pinnedOrVerified = pinned.allContracts.union(verifiedLaunchTokens)
        let allowedContracts = pinnedOrVerified.union(provenRuntime)

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
                // The intent must quote the minimum: a path payment without one is refused, not let through.
                guard destMin > 0 else { throw fail(Self.noMinimum) }
                guard let want = Self.minimum(intent, for: sac(destAsset)), destMin >= want else { throw fail(Self.belowMinimum) }
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
                try checkCall(call, intent: intent, allowed: pinnedOrVerified, listed: allowedContracts, auth: auth, v2: v2)
                for entry in auth {
                    guard entry.credentials == .sourceAccount else { throw fail("The transaction needs a signature from another address.") }
                    // Only the call itself, bound by its rule, with the user's own token spends beneath it.
                    try walk(entry, call: call, outflow: &outflow)
                }
            case .restoreFootprint:
                // Archived entries come back only as their own step, and only the app's own data (§4.9).
                guard intent.kind == "restore" else { throw fail("Restoring archived data is only allowed as its own action.") }
                let keys = (tx.footprint?.readOnly ?? []) + (tx.footprint?.readWrite ?? [])
                for key in keys where !restorable(key, allowed: allowedContracts, runtimeHashes: runtimeHashes) {
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

    /// The fee caps (§4.4): the whole fee, then the resource fee's range and the inclusion bid per operation. `verify`
    /// runs them, and PlanFees prices a built step with them, so the review never shows a fee the runner would refuse.
    public func checkFees(_ tx: Transaction) throws {
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

    /// A footprint entry a restore may bring back: the data of an allowlisted contract (a verified launch token or a v2
    /// runtime contract included), or a pinned WASM (the launch token's, or one v2 creates contracts from).
    private func restorable(_ key: StellarLedgerKey, allowed: Set<String>, runtimeHashes: Set<String>) -> Bool {
        switch key {
        case let .contractData(.contract(contract), _, _): return allowed.contains(contract)
        case let .contractCode(hash):
            let code = hex(hash)
            return (!pinned.launchTokenWasmHash.isEmpty && code == pinned.launchTokenWasmHash) || runtimeHashes.contains(code)
        default: return false
        }
    }

    /// Adds every token outflow the user authorizes in one authorization entry, and refuses anything else in it. The
    /// user's authorization moves their tokens, but it also lets a contract act for them in any other way (a Blend
    /// withdrawal to a third party, a creator-fee recipient change), which no outflow shows. So the entry's root must be
    /// the call being judged, byte for byte (InvokeContractArgs ==, as verify.ts compares them), which its own rule
    /// binds, and every node beneath it, at any depth, a spend of the user's own tokens (transfer, burn, approve,
    /// transfer_from or burn_from from the user), counted toward the outflow the intent declares. An approval counts in
    /// full: the spender may take it later.
    private func walk(_ entry: AuthorizationEntry, call: InvokeContractArgs, outflow: inout Outflow) throws {
        guard case let .contractFn(c) = entry.rootInvocation.function else { throw fail(Self.creation) }
        guard c == call else { throw fail(Self.extraAuth) }
        // The call itself may be a spend (a send, an approval); its rule has checked its arguments.
        if let l = Self.tokenSpends[c.function], c.args.count > l.amount, c.args[l.from].addressString == user, let contract = c.contract.string {
            guard let n = c.args[l.amount].amount else { throw fail(Self.outOfRange) }
            try outflow.add(contract, n)
        }
        for sub in entry.rootInvocation.subInvocations { try walkSpends(sub, outflow: &outflow) }
    }

    private func walkSpends(_ inv: AuthorizedInvocation, outflow: inout Outflow) throws {
        guard case let .contractFn(c) = inv.function, let contract = c.contract.string else { throw fail(Self.creation) }
        guard let l = Self.tokenSpends[c.function], c.args.count == l.arity, c.args[l.from].addressString == user else {
            throw fail(Self.otherAuth)
        }
        guard let n = c.args[l.amount].amount else { throw fail(Self.outOfRange) }
        try outflow.add(contract, n)
        for sub in inv.subInvocations { try walkSpends(sub, outflow: &outflow) }
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
    /// written from the contract's own signature: contracts/launchpad and contracts/moments (the deployed v1 WASMs),
    /// contracts/launchpad-v2, contracts/launch-token-v2, contracts/moments-v2 and contracts/lp-locker (v2), the
    /// Soroswap and Aquarius routers' published ABIs, Blend's pool, Circle's TokenMessengerMinter and SEP-41. A function
    /// without a rule is not signed. v2's singletons have their own rules, every other contract v1's. Same order of
    /// checks as verify.ts's rule tables.
    func checkCall(_ call: InvokeContractArgs, intent: Intent, allowed: Set<String>, listed: Set<String>, auth: [AuthorizationEntry], v2: V2Pins?) throws {
        let rules = CallRules(verifier: self, call: call, intent: intent, auth: auth, listed: listed)
        if let v2, let contract = call.contract.string {
            if contract == v2.launchpad { return try rules.launchpadV2(v2) }
            if contract == v2.moments { return try rules.momentsV2(v2) }
            if contract == v2.locker { return try rules.locker() }
        }
        try rules.v1(allowed: allowed)
    }

    /// v2's pins (DESIGN-stellar-contracts-v2 §20.1), as PinnedContracts holds them: nil until the deployment's v2 is
    /// pinned, and then every call is judged by v1's rules.
    struct V2Pins {
        let launchpad: String
        let moments: String
        let locker: String
        let graduator: String
        /// exec-soroswap: every Moment's venue.
        let soroswapExecutor: String
        /// The executors a launch's terms may name: the pinned ones (never testnet-qa's qa-exec-fail, finding F4).
        let executors: Set<String>
        let launchTokenWasm: String
        let nftWasm: String
        let coinWasm: String
        let durations: PinnedDurations
        let maxLaunchFeeStroops: Int64

        /// The pinned runtime WASM hashes: a contract running one of them counts as pinned.
        var runtimeHashes: Set<String> { [launchTokenWasm, nftWasm, coinWasm] }

        init?(_ pinned: PinnedContracts) {
            guard let launchpad = pinned.contracts("launchpadV2").first,
                  let moments = pinned.contracts("momentsV2").first,
                  let locker = pinned.contracts("lpLocker").first,
                  let graduator = pinned.contracts("momentsGraduator").first,
                  let soroswap = pinned.contracts("execSoroswap").first,
                  let launchToken = pinned.runtimeWasmHashes["launchTokenV2"], !launchToken.isEmpty,
                  let nft = pinned.runtimeWasmHashes["momentNft"], !nft.isEmpty,
                  let coin = pinned.runtimeWasmHashes["momentCoin"], !coin.isEmpty,
                  let durations = pinned.durations else { return nil }
            self.launchpad = launchpad
            self.moments = moments
            self.locker = locker
            self.graduator = graduator
            soroswapExecutor = soroswap
            executors = Set(pinned.contracts("execSoroswap") + pinned.contracts("execAquarius"))
            launchTokenWasm = launchToken
            nftWasm = nft
            coinWasm = coin
            self.durations = durations
            maxLaunchFeeStroops = pinned.maxLaunchFeeStroops
        }
    }

    /// Contract structs as their ScVal maps name their fields (contracts/launchpad-v2/src/storage.rs,
    /// contracts/moments-v2, contracts/common/src/types.rs). A struct is read only when it has exactly these fields.
    static let launchParams = [
        "quote", "name", "symbol", "uri", "creator_fee_bps", "venue", "holder_sharing", "creator_fee_recipient", "snipe_exempt",
        "initial_buy", "min_tokens_out", "nonce",
    ]
    static let launchTermsFields = [
        "supply", "fee_bps", "protocol_share_bps", "max_creator_fee_bps", "snipe_schedule", "snipe_step_secs", "launch_fee",
        "fee_asset", "quote", "phantom", "threshold", "venue", "fallback", "venue_locked", "locker", "token_wasm_hash", "durations",
    ]
    static let venueInfo = ["id", "kind", "executor", "params", "enabled"]
    static let publishParams = ["name", "symbol", "metadata_uri", "media_hash", "place", "date", "price", "creator_alloc_bps", "window_secs", "nonce"]
    static let momentsTermsFields = [
        "policy", "external_base", "nft_wasm_hash", "coin_wasm_hash", "graduator", "executor", "locker", "durations", "harvest_bps",
        "harvest_creator_bps",
    ]

    /// A contract struct's fields by name, compared as bytes (Swift's `==` on text would also match another Unicode
    /// normalization of a name).
    struct Fields {
        let byName: [[UInt8]: SCVal]
        subscript(_ name: String) -> SCVal? { byName[Array(name.utf8)] }

        /// A struct (a map with symbol keys) that has exactly the fields `names`; nil for anything else.
        init?(_ value: SCVal?, _ names: [String]) {
            guard let value, case let .map(entries?) = value else { return nil }
            var byName: [[UInt8]: SCVal] = [:]
            for (key, field) in entries {
                guard case let .symbol(name) = key, byName[Array(name.utf8)] == nil else { return nil }
                byName[Array(name.utf8)] = field
            }
            guard byName.count == names.count, names.allSatisfy({ byName[Array($0.utf8)] != nil }) else { return nil }
            self.byName = byName
        }
    }

    /// The rules of one call, with what they read: the call, the intent and the operation's authorizations.
    struct CallRules {
        let verifier: TxVerifier
        let call: InvokeContractArgs
        let intent: Intent
        let auth: [AuthorizationEntry]
        /// The allowlist: pinned contracts, verified launch tokens and v2 runtime contracts with a pinned WASM.
        let listed: Set<String>

        var args: [SCVal] { call.args }
        var user: String { verifier.user }
        private func fail(_ reason: String) -> VerificationFailure { VerificationFailure(reason: reason) }

        func arity(_ n: Int) throws { guard args.count == n else { throw fail(TxVerifier.arguments) } }
        func actsForUser(_ indices: Int...) throws {
            for i in indices where args[i].addressString != user { throw fail(TxVerifier.forAnother) }
        }
        @discardableResult
        func address(_ i: Int) throws -> String {
            guard let a = args[i].addressString else { throw fail(TxVerifier.arguments) }
            return a
        }
        /// The call's minimum is positive and at least the intent's quote: a minimum of 0 protects nothing, whatever
        /// the intent says.
        func atLeast(_ min: Int64?, _ quoted: Int64?) throws {
            guard let min else { throw fail(TxVerifier.arguments) }
            guard min > 0 else { throw fail(TxVerifier.noMinimum) }
            guard let quoted, min >= quoted else { throw fail(TxVerifier.belowMinimum) }
        }
        /// A swap's tokens (a Soroswap path, an Aquarius chain's hops) run their code inside the user's swap, so each
        /// must be on the allowlist; only the token sold, when the intent spends it, and the token bought, when the
        /// intent quotes its minimum, may be outside it (the user's own choice, which the phone binds to its form).
        func routeListed(_ tokens: [String], sold: String, bought: String) throws {
            var ends: Set<String> = []
            if intent.spend[sold] != nil { ends.insert(sold) }
            if intent.receive?[bought] != nil { ends.insert(bought) }
            for t in tokens where !listed.contains(t) && !ends.contains(t) { throw fail(TxVerifier.route) }
        }
        /// A display field of the intent, when it has it.
        func shown(_ key: String) -> StellarJSON? { intent.display?[key] }
        /// A displayed whole number equal to the call's `n`.
        func sameNumber(_ value: StellarJSON?, _ n: Int64?) -> Bool {
            guard case let .number(d)? = value, let n, d.rounded() == d, abs(d) <= 9_007_199_254_740_991 else { return false }
            return Int64(d) == n
        }
        /// A displayed amount (base units as a decimal string) equal to the call's `n`.
        func sameUnits(_ value: StellarJSON?, _ n: Int64?) -> Bool {
            guard case let .string(text)? = value, let u = TxVerifier.units(text), let n else { return false }
            return u == n
        }
        /// The intent's one quoted minimum, for a call whose output asset isn't among its arguments.
        var soleMinimum: Int64? { intent.receive.flatMap { $0.count == 1 ? $0.values.first.flatMap(TxVerifier.units) : nil } }
        /// A call anyone may make needs nobody's authorization: it must carry none of the user's (§20.4).
        func anyone() throws { guard auth.isEmpty else { throw fail(TxVerifier.anyone) } }
        /// A claim pays the user and takes nothing: its intent declares no spend (§20.4).
        func spendsNothing() throws { guard intent.spend.isEmpty else { throw fail(TxVerifier.claimSpends) } }
        /// The intent declares at least `amount` of `asset`, with the reasons the outflow check gives.
        func declares(_ asset: String, _ amount: Int64) throws {
            guard let capText = intent.spend[asset] else { throw fail("The transaction spends an asset this action doesn't declare (\(asset)).") }
            guard let cap = TxVerifier.units(capText), amount <= cap else { throw fail("The transaction spends more than this action declares (\(asset)).") }
        }
        /// A call anyone may make, of one address: a launch token, a Moment NFT or a pool.
        func byAnyone() throws {
            try arity(1)
            try address(0)
            try anyone()
        }

        /// The token transfers from the user inside the authorization of the call itself, in the order the call makes
        /// them.
        func ownTransfers() -> [(token: String?, to: String?, amount: Int64?)] {
            var out: [(token: String?, to: String?, amount: Int64?)] = []
            func walk(_ inv: AuthorizedInvocation) {
                if case let .contractFn(c) = inv.function, c.function == "transfer", c.args.count == 3, c.args[0].addressString == user {
                    out.append((c.contract.string, c.args[1].addressString, c.args[2].amount))
                }
                inv.subInvocations.forEach(walk)
            }
            for entry in auth where entry.rootInvocation.function == .contractFn(call) { walk(entry.rootInvocation) }
            return out
        }

        // ------------------------------------------------------------------------------------------ v1 and the rest

        func v1(allowed: Set<String>) throws {
            switch call.function {
            case "transfer":
                // SEP-41 / SAC transfer(from, to, amount): a send, to the address the user confirmed.
                try arity(3)
                try actsForUser(0)
                guard TxVerifier.isConfirmed(args[1], intent) else { throw fail(TxVerifier.destination) }
            case "approve":
                // approve(from, spender, amount, live_until_ledger): an allowance for a pinned contract (the CCTP
                // messenger).
                try arity(4)
                try actsForUser(0)
                guard let spender = args[1].addressString, allowed.contains(spender) else {
                    throw fail("The allowance is for a contract outside the allowlist.")
                }
            case "swap_exact_tokens_for_tokens":
                // Soroswap router swap_exact_tokens_for_tokens(amount_in, amount_out_min, path, to, deadline).
                try arity(5)
                guard args[3].addressString == user else { throw fail("Swap output goes to another account.") }
                guard case let .vec(path?) = args[2], !path.isEmpty else { throw fail(TxVerifier.arguments) }
                let tokens = path.compactMap(\.addressString)
                guard tokens.count == path.count, let out = tokens.last else { throw fail(TxVerifier.arguments) }
                try routeListed(tokens, sold: tokens[0], bought: out)
                try atLeast(args[1].amount, TxVerifier.minimum(intent, for: out))
            case "swap_chained":
                // Aquarius router swap_chained(user, swaps_chain, token_in, in_amount, out_min); each hop is
                // (tokens, pool_index, token_out), so the last hop's token_out is what the user receives.
                try arity(5)
                try actsForUser(0)
                guard case let .vec(chain?) = args[1], !chain.isEmpty, let tokenIn = args[2].addressString else { throw fail(TxVerifier.arguments) }
                var tokens = [tokenIn]
                var bought: String?
                for h in chain {
                    guard case let .vec(hop?) = h, hop.count == 3, case let .vec(pair?) = hop[0], let out = hop[2].addressString else {
                        throw fail(TxVerifier.arguments)
                    }
                    let pairTokens = pair.compactMap(\.addressString)
                    guard pairTokens.count == pair.count else { throw fail(TxVerifier.arguments) }
                    tokens += pairTokens + [out]
                    bought = out
                }
                guard let out = bought else { throw fail(TxVerifier.arguments) }
                try routeListed(tokens, sold: tokenIn, bought: out)
                try atLeast(args[4].amount, TxVerifier.minimum(intent, for: out))
            case "launch":
                // Launchpad launch(creator, quote, name, symbol, uri, creator_fee_bps, initial_buy, min_tokens_out).
                try arity(8)
                try actsForUser(0)
            case "buy":
                try buy()
            case "sell":
                try sell()
            case "graduate", "claim_creator_fees":
                // Launchpad graduate(token) and claim_creator_fees(token): anyone may call them, and they pay only the
                // launch's own creator, pair and treasury, never from the caller.
                try arity(1)
                try address(0)
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
                guard case let .u32(domain) = args[2] else { throw fail(TxVerifier.arguments) }
                guard domain == verifier.pinned.monadDomain else { throw fail("The bridge sends to another network.") }
                guard case let .bytes(recipient) = args[3], recipient.count == 32 else { throw fail(TxVerifier.arguments) }
                guard let want = TxVerifier.evmBytes32(intent.to), want == recipient else { throw fail(TxVerifier.destination) }
            case "claim":
                // Launch token v2 claim(holder): the holder's rewards in the quote and the token, paid to the holder.
                try arity(1)
                try actsForUser(0)
                try spendsNothing()
            default:
                throw fail("Function \(call.function) is not on the allowlist.")
            }
        }

        /// Launchpad buy(buyer, token, quote_in, min_tokens_out), v1 and v2.
        func buy() throws {
            try arity(4)
            try actsForUser(0)
            let token = try address(1)
            try atLeast(args[3].amount, TxVerifier.minimum(intent, for: token))
        }

        /// Launchpad sell(seller, token, tokens_in, min_quote_out), v1 and v2: the quote asset isn't an argument, so the
        /// intent quotes exactly one minimum.
        func sell() throws {
            try arity(4)
            try actsForUser(0)
            try address(1)
            try atLeast(args[3].amount, soleMinimum)
        }

        // ------------------------------------------------------------------------------------------ launchpad-v2

        /// launchpad-v2's functions (contracts/launchpad-v2/src/lib.rs). buy and sell keep v1's arguments and rules.
        func launchpadV2(_ v2: V2Pins) throws {
            switch call.function {
            case "launch": try launchV2(v2)
            case "buy": try buy()
            case "sell": try sell()
            case "refund":
                // refund(holder, token, tokens_in): the holder's own tokens are burned, and the intent declares the burn.
                try arity(3)
                try actsForUser(0)
                let token = try address(1)
                guard let tokens = args[2].amount, tokens > 0 else { throw fail(TxVerifier.arguments) }
                try declares(token, tokens)
            case "graduate", "graduate_fallback", "mark_stuck", "rescue", "claim_creator_fees", "execute_recipient_change":
                try byAnyone()
            case "claim_owed":
                // claim_owed(account, asset): anyone may pay an account what recipient changes left it; the app asks for
                // the user's.
                try arity(2)
                try actsForUser(0)
                try address(1)
                try spendsNothing()
                try anyone()
            case "transfer_creator_fee_recipient":
                // transfer_creator_fee_recipient(token, new): the current recipient hands the fees to the address the
                // user confirmed.
                try arity(2)
                try address(0)
                guard TxVerifier.isConfirmed(args[1], intent) else { throw fail(TxVerifier.destination) }
            case "cancel_recipient_change":
                // cancel_recipient_change(token, caller): the current recipient's veto, as the user.
                try arity(2)
                try actsForUser(1)
                try address(0)
            default:
                throw fail("Function \(call.function) is not on the allowlist.")
            }
        }

        /// launch(creator, p: LaunchParams, expected: LaunchTerms): the terms are this app's pins, and the creator pays
        /// exactly their fee, at most the pinned bound, to the launchpad (§20.4, decision O6, finding F18).
        func launchV2(_ v2: V2Pins) throws {
            try arity(3)
            try actsForUser(0)
            let p = Fields(args[1], TxVerifier.launchParams)
            let t = Fields(args[2], TxVerifier.launchTermsFields)
            let venue = Fields(t?["venue"], TxVerifier.venueInfo)
            let fallback = Fields(t?["fallback"], TxVerifier.venueInfo)
            guard let p, let t, let venue, let fallback, let fee = t["launch_fee"]?.amount, fee >= 0,
                  let initialBuy = p["initial_buy"]?.amount, let minOut = p["min_tokens_out"]?.amount else {
                throw fail(TxVerifier.arguments)
            }
            guard TxVerifier.isTicker(p["symbol"]) else { throw fail(TxVerifier.ticker) }
            for v in [venue, fallback] {
                guard let executor = v["executor"]?.addressString, v2.executors.contains(executor) else { throw fail(TxVerifier.launchVenue) }
            }
            let xlm = verifier.sac(.native)
            let pinnedTerms = t["locker"]?.addressString == v2.locker
                && TxVerifier.hash32(t["token_wasm_hash"]) == v2.launchTokenWasm
                && TxVerifier.sameDurations(t["durations"], v2.durations.launch.fields)
                && t["fee_asset"]?.addressString == xlm
            guard pinnedTerms else { throw fail(TxVerifier.launchTerms) }
            guard fee <= v2.maxLaunchFeeStroops else { throw fail(TxVerifier.launchFeeLimit) }
            // The fee is the first XLM the launch takes; anything else it takes (the initial buy) goes to the launchpad
            // too.
            let launchpad = call.contract.string
            let transfers = ownTransfers()
            let feeAt = fee > 0 ? transfers.firstIndex(where: { $0.token == xlm }) : nil
            if fee > 0 {
                guard let feeAt else { throw fail(TxVerifier.launchFeeAmount) }
                guard transfers[feeAt].to == launchpad else { throw fail(TxVerifier.launchFeeTo) }
                guard transfers[feeAt].amount == fee else { throw fail(TxVerifier.launchFeeAmount) }
            }
            for (i, x) in transfers.enumerated() where i != feeAt && x.to != launchpad { throw fail(TxVerifier.destination) }
            if initialBuy > 0 { try atLeast(minOut, soleMinimum) }
            // What the user chose: the creator fees go to the address they confirmed (intent.to), or to themselves when
            // it is absent, for the launch's whole life; the displayed exemptions, creator fee and sharing are the
            // call's.
            let recipient = p["creator_fee_recipient"]
            let isVoid = recipient == .void
            let recipientOK: Bool
            if let to = intent.to {
                recipientOK = !isVoid && recipient?.addressString == to
            } else {
                recipientOK = isVoid || recipient?.addressString == user
            }
            guard recipientOK, case let .string(shownRecipient)? = shown("recipient"),
                  shownRecipient.utf8.elementsEqual((intent.to ?? user).utf8) else { throw fail(TxVerifier.launchRecipient) }
            var exemptShown: [String]?
            if case let .string(list)? = shown("snipeExempt") {
                exemptShown = list.isEmpty ? [] : list.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
            var settingsOK = false
            if case let .vec(exempt?)? = p["snipe_exempt"], let exemptShown, exempt.count == exemptShown.count,
               zip(exempt, exemptShown).allSatisfy({ value, address in value.addressString?.utf8.elementsEqual(address.utf8) ?? false }),
               sameNumber(shown("creatorFeeBps"), p["creator_fee_bps"]?.amount),
               case let .bool(sharing)? = p["holder_sharing"], case let .bool(sharingShown)? = shown("holderSharing"), sharing == sharingShown {
                settingsOK = true
            }
            guard settingsOK else { throw fail(TxVerifier.launchSettings) }
        }

        // ------------------------------------------------------------------------------------------ moments-v2

        /// moments-v2's functions (contracts/moments-v2/src).
        func momentsV2(_ v2: V2Pins) throws {
            switch call.function {
            case "publish":
                // publish(creator, p: PublishParams, expected: MomentsTerms): the graduator, its executor, the locker,
                // the NFT and coin WASM hashes and the durations are this app's pins.
                try arity(3)
                try actsForUser(0)
                guard let p = Fields(args[1], TxVerifier.publishParams), let t = Fields(args[2], TxVerifier.momentsTermsFields) else {
                    throw fail(TxVerifier.arguments)
                }
                guard TxVerifier.isTicker(p["symbol"]) else { throw fail(TxVerifier.ticker) }
                let pinnedTerms = t["graduator"]?.addressString == v2.graduator
                    && t["executor"]?.addressString == v2.soroswapExecutor
                    && t["locker"]?.addressString == v2.locker
                    && TxVerifier.hash32(t["nft_wasm_hash"]) == v2.nftWasm
                    && TxVerifier.hash32(t["coin_wasm_hash"]) == v2.coinWasm
                    && TxVerifier.sameDurations(t["durations"], v2.durations.moments.fields)
                guard pinnedTerms else { throw fail(TxVerifier.momentTerms) }
                // What the user chose: the displayed price, creator allocation and collect window are the call's.
                let chosen = sameUnits(shown("price"), p["price"]?.amount)
                    && sameNumber(shown("allocationBps"), p["creator_alloc_bps"]?.amount)
                    && sameNumber(shown("windowSecs"), p["window_secs"]?.amount)
                guard chosen else { throw fail(TxVerifier.momentSettings) }
            case "collect":
                // collect(collector, nft, qty, max_total): the collector pays at most max_total, in the one asset the
                // intent spends.
                try arity(4)
                try actsForUser(0)
                try address(1)
                guard args[2].amount != nil, let max = args[3].amount, intent.spend.count == 1, let asset = intent.spend.keys.first else {
                    throw fail(TxVerifier.arguments)
                }
                try declares(asset, max)
            case "claim":
                // claim(account, nft): the account's vested coins, minted to it.
                try arity(2)
                try actsForUser(0)
                try address(1)
                try spendsNothing()
            case "claim_all":
                // claim_all(account, nfts).
                try arity(2)
                try actsForUser(0)
                guard case let .vec(nfts?) = args[1], !nfts.isEmpty, nfts.allSatisfy({ $0.addressString != nil }) else {
                    throw fail(TxVerifier.arguments)
                }
                try spendsNothing()
            case "withdraw_creator", "graduate", "expire":
                // Anyone may call them; they pay only the Moment's beneficiaries.
                try byAnyone()
            default:
                throw fail("Function \(call.function) is not on the allowlist.")
            }
        }

        // ------------------------------------------------------------------------------------------ lp-locker

        /// lp-locker's functions (contracts/lp-locker/src/lib.rs): harvest(pool), once per interval, by anyone.
        func locker() throws {
            switch call.function {
            case "harvest": try byAnyone()
            default: throw fail("Function \(call.function) is not on the allowlist.")
            }
        }
    }

    /// A durations struct (u64 seconds, these fields) equal, field by field, to the pinned values.
    static func sameDurations(_ value: SCVal?, _ pinned: [(String, UInt64)]) -> Bool {
        guard let got = Fields(value, pinned.map(\.0)) else { return false }
        return pinned.allSatisfy { name, secs in
            if case let .u64(v)? = got[name] { return v == secs }
            return false
        }
    }

    /// 32 bytes as lowercase hex (a WASM hash); nil for any other value.
    static func hash32(_ value: SCVal?) -> String? {
        guard case let .bytes(b)? = value, b.count == 32 else { return nil }
        return hex(b)
    }

    /// A launch or Moment ticker: 2 to 10 ASCII letters or digits, as the contracts take it (Soroswap reads a pair's
    /// symbols as UTF-8).
    static func isTicker(_ value: SCVal?) -> Bool {
        guard case let .string(text)? = value else { return false }
        let bytes = Array(text.utf8)
        return (2...10).contains(bytes.count) && bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
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

private extension PinnedDurations.Launch {
    /// The fields as dyor_common::LaunchDurations names them, in its order.
    var fields: [(String, UInt64)] {
        [
            ("grace", grace), ("fallback_delay", fallbackDelay), ("rescue_admin", rescueAdmin), ("rescue_public", rescuePublic),
            ("locked_fallback", lockedFallback), ("takeover_delay", takeoverDelay), ("takeover_window", takeoverWindow),
            ("timelock", timelock), ("timelock_window", timelockWindow), ("harvest_interval", harvestInterval),
        ]
    }
}

private extension PinnedDurations.Moments {
    /// The fields as dyor_common::MomentsDurations names them, in its order.
    var fields: [(String, UInt64)] {
        [
            ("vest_period", vestPeriod), ("stuck_expiry", stuckExpiry), ("pending_backstop", pendingBackstop), ("timelock", timelock),
            ("timelock_window", timelockWindow), ("min_window", minWindow), ("max_window", maxWindow), ("harvest_interval", harvestInterval),
        ]
    }
}
