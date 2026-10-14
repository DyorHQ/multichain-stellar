import BigInt
import Foundation

/// A transaction the app wants to send, before nonce, gas and fees are filled in.
public struct TransactionRequest: Sendable, Equatable {
    public var to: Address
    public var data: Data
    public var value: BigUInt

    public init(to: Address, data: Data = Data(), value: BigUInt = 0) {
        self.to = to
        self.data = data
        self.value = value
    }
}

/// Everything a signer needs for an EIP-1559 transaction on Monad.
public struct PreparedTransaction: Sendable, Equatable {
    public let from: Address
    public let to: Address
    public let data: Data
    public let value: BigUInt
    public let nonce: UInt64
    public let gasLimit: BigUInt
    public let maxFeePerGas: BigUInt
    public let maxPriorityFeePerGas: BigUInt
    public let chainId: Int
}

/// The app's one signing abstraction. Privy's embedded wallet and any future passkey wallet both fit behind it,
/// so screens never know which is in use.
public protocol Wallet: Sendable {
    var address: Address { get }
    /// Signs and returns the raw RLP-encoded transaction (`0x02…`), ready for `eth_sendRawTransaction`.
    func sign(_ transaction: PreparedTransaction) async throws -> Data
    /// EIP-191 personal message signature.
    func signMessage(_ message: Data) async throws -> Data
}

public struct TransactionStep: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case approve(token: Address, spender: Address, amount: BigUInt)
        /// A Permit2 allowance of `amount` for `spender` that expires `lifetime` seconds after the step is sent. The
        /// expiration is set when the step runs, not when the plan is built, so a sheet left open never sends one that
        /// is already stale; skipped when the existing allowance covers `amount` for at least another minute.
        case permit2Approve(token: Address, spender: Address, amount: BigUInt, lifetime: Int)
        case call
    }
    public let kind: Kind
    public let request: TransactionRequest?
    public let label: String

    public static func approve(token: Address, spender: Address, amount: BigUInt, label: String) -> TransactionStep {
        TransactionStep(kind: .approve(token: token, spender: spender, amount: amount), request: nil, label: label)
    }

    public static func permit2Approve(token: Address, spender: Address, amount: BigUInt, lifetime: Int, label: String) -> TransactionStep {
        TransactionStep(kind: .permit2Approve(token: token, spender: spender, amount: amount, lifetime: lifetime), request: nil, label: label)
    }

    /// The transaction this step sends when it runs at `now` (an approval becomes its `approve` call). Nil for a call
    /// step without a request. For previews: at run time an approval the allowance already covers is skipped.
    public func request(at now: Date = Date()) throws -> TransactionRequest? {
        switch kind {
        case .approve(let token, let spender, let amount):
            return TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: spender, amount: amount))
        case .permit2Approve(let token, let spender, let amount, let lifetime):
            let expiration = BigUInt(Int(now.timeIntervalSince1970) + lifetime)
            return TransactionRequest(to: Uniswap.permit2, data: try SwapCalldata.permit2Approve(token: token, spender: spender, amount: amount, expiration: expiration))
        case .call:
            return request
        }
    }

    public static func call(_ request: TransactionRequest, label: String) -> TransactionStep {
        TransactionStep(kind: .call, request: request, label: label)
    }
}

public enum TransactionEvent: Sendable, Equatable {
    case preparing(String)
    case sent(String, Data)
    case confirmed(String, Data)
}

/// Prepares, simulates, signs, broadcasts and confirms transactions. Monad charges for the gas *limit*, so the
/// limit is the estimate plus a small margin rather than a generous round number.
public struct TransactionSender: Sendable {
    public let rpc: RPCClient
    public let multicall: Multicall
    /// The EVM chain this sender signs for. Defaults to Monad so every existing caller is unchanged; the Bridge
    /// builds a sender per source chain (Ethereum, Base, …) with that chain's id and RPC so the same wallet key
    /// signs a valid transaction there.
    public let chainId: Int
    /// How long the Monad reserve-balance waits poll and give up (MERA-PLAN §5). Tests shorten them.
    var timing = Timing()

    struct Timing: Sendable {
        /// Between `eth_blockNumber` reads while a MON-sending step waits out the 3-block spacing (blocks are ~0.4 s).
        var blockPoll: Duration = .milliseconds(150)
        /// The spacing wait gives up and sends anyway after this: a node whose head stalls (or a local fork that only
        /// mines on demand) must never hang a plan.
        var spacingTimeout: Duration = .seconds(5)
        /// Before resending a transaction Monad refused because the account's funding is still settling.
        var fundingRetry: Duration = .seconds(1)
        /// A broadcast that got no answer is resent (the same bytes) and looked up by hash this many times, waiting
        /// `resendBackoff`, then twice that, and so on, before it is reported as possibly sent.
        var resendAttempts = 3
        var resendBackoff: Duration = .seconds(1)
        /// The receipt wait for each sent step (`RPCClient.waitForReceipt`): a number of polls, not a deadline.
        var receiptPolls = 180
        var receiptInterval: Duration = .milliseconds(500)
        /// On Monad only, the receipt wait first reads this many times `receiptFastInterval` apart (about 3 s at ~7
        /// reads a second, under the public endpoint's limit): a confirmed step shows within a few hundred milliseconds.
        var receiptFastPolls = 20
        var receiptFastInterval: Duration = .milliseconds(150)
    }

    /// The receipt wait's fast first reads for this sender's chain: Monad's only (the Bridge's other chains keep 500 ms).
    var receiptFastPollCount: Int { chainId == Monad.chainId ? timing.receiptFastPolls : 0 }

    public init(rpc: RPCClient, chainId: Int = Monad.chainId) {
        self.rpc = rpc
        multicall = Multicall(rpc: rpc)
        self.chainId = chainId
    }

    public func prepare(_ request: TransactionRequest, from wallet: Wallet) async throws -> PreparedTransaction {
        let call = CallRequest(from: wallet.address, to: request.to, data: request.data, value: request.value)
        // Simulate first so a revert surfaces as a readable error before the wallet is asked to sign.
        do {
            _ = try await rpc.ethCall(call)
        } catch let error as RPCError {
            throw TransactionError.rejected(RevertReason.describe(error))
        }
        async let nonce = rpc.transactionCount(of: wallet.address)
        async let estimate = rpc.estimateGas(call)
        async let fees = feeQuote()
        let gasLimit = Self.gasLimit(estimate: try await estimate)
        let (maxFee, tip, baseFee) = try await fees
        // The RPC set every one of these: refuse, never clamp, a fee outside the chain's bounds (IOST-1).
        if let violation = NetworkFeeLimits.violation(gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, baseFee: baseFee, chainId: chainId) {
            throw TransactionError.rejected(NetworkFeeLimits.refusal(violation, gasLimit: gasLimit, maxFeePerGas: maxFee, chainId: chainId))
        }
        return PreparedTransaction(from: wallet.address, to: request.to, data: request.data, value: request.value, nonce: try await nonce, gasLimit: gasLimit, maxFeePerGas: maxFee, maxPriorityFeePerGas: tip, chainId: chainId)
    }

    /// The node's estimate plus 20%: the limit every prepared transaction carries.
    static func gasLimit(estimate: BigUInt) -> BigUInt { estimate * 120 / 100 }

    /// The gas limit `prepare` would set for `request` sent from `from`, or nil when the node can't estimate it (a
    /// revert, an unreachable RPC). For sizing a "Max" before the transaction exists.
    public func gasLimit(for request: TransactionRequest, from: Address) async -> BigUInt? {
        guard let estimate = try? await rpc.estimateGas(CallRequest(from: from, to: request.to, data: request.data, value: request.value)) else { return nil }
        return Self.gasLimit(estimate: estimate)
    }

    /// What a transaction of `gasLimit` may be charged up front on this chain today: `gasLimit × (2 × base + tip)`,
    /// the max fee `prepare` sets, with `NetworkFeeReserve`'s headroom. The chain's fallback when the RPC can't answer.
    public func feeReserve(gasLimit: BigUInt) async -> BigUInt {
        guard let fees = try? await feeParameters() else { return NetworkFeeReserve.fallback(chainId: chainId) }
        return NetworkFeeReserve.amount(gasLimit: gasLimit, maxFeePerGas: fees.maxFee, chainId: chainId)
    }

    /// The most of a native `balance` a "Max" can send and still pay the network fee (MERA-PLAN §5). The gas limit is
    /// estimated from `request` when there is one to estimate (a route on screen, a transfer to a known address), and
    /// is `budget` otherwise. Zero when the fee takes the whole balance.
    public func maxValue(balance: BigUInt, like request: TransactionRequest?, from: Address?, budget: BigUInt) async -> BigUInt {
        var limit = budget
        if let request, let from, let estimate = await gasLimit(for: request, from: from) { limit = estimate }
        return NetworkFeeReserve.spendable(balance: balance, reserve: await feeReserve(gasLimit: limit))
    }

    /// EIP-1559 fees: the node's suggested tip, with a max fee of twice the base fee plus that tip so the transaction
    /// still lands if the base fee doubles. Monad charges gas limit × min(maxFee, base + tip); tipping the whole gas
    /// price (the old rule) roughly doubled every fee there. Falls back to the gas price when a node can't answer.
    func feeParameters() async throws -> (maxFee: BigUInt, tip: BigUInt) {
        let quote = try await feeQuote()
        return (quote.maxFee, quote.tip)
    }

    /// `feeParameters` with the base fee they were derived from — nil on the gas-price fallback, whose fee doesn't come
    /// from it — for `NetworkFeeLimits`' checks against the base fee.
    func feeQuote() async throws -> (maxFee: BigUInt, tip: BigUInt, baseFee: BigUInt?) {
        async let baseFee = rpc.latestBaseFee()
        async let suggestedTip = rpc.maxPriorityFeePerGas()
        let base = (try? await baseFee) ?? nil
        let tip = try? await suggestedTip
        if let base, let tip { return (base * 2 + tip, tip, base) }
        let price = try await rpc.gasPrice()
        return (price * 2, price, nil)
    }

    /// The most a plan's network fees can come to at today's fees, for the confirmation sheet: each step the node can
    /// estimate now, at the gas limit and max fee `prepare` would set. A step that depends on an earlier one (a swap
    /// after its approval) can't be estimated until that one lands, so it is counted in `unestimated` instead; every
    /// step is still checked against `NetworkFeeLimits` when it is prepared. Approvals the allowance already covers
    /// are left out, as `run` skips them. Nil when the fees can't be read.
    public func feePreview(_ steps: [TransactionStep], from: Address) async -> FeePreview? {
        guard let fees = try? await feeQuote() else { return nil }
        var total: BigUInt = 0
        var unestimated = 0
        for step in steps {
            let request: TransactionRequest?
            do { request = try await self.request(for: step, owner: from) } catch { unestimated += 1; continue }
            guard let request else { continue }
            if let limit = await gasLimit(for: request, from: from) { total += limit * fees.maxFee } else { unestimated += 1 }
        }
        return FeePreview(maxFee: total, unestimated: unestimated, chainId: chainId)
    }

    public struct FeePreview: Sendable, Equatable {
        /// The most the estimated steps can be charged, in the chain's native coin (wei).
        public let maxFee: BigUInt
        /// Steps that can't be estimated before an earlier one lands.
        public let unestimated: Int
        public let chainId: Int
    }

    /// The transaction `step` sends from `owner` now, or nil when it has nothing to send: an approval the allowance
    /// already covers (a Permit2 one for at least another minute), or a call step without a request. An exact approval
    /// is sent even when a standing, effectively unlimited allowance covers it — one an earlier build or another app
    /// left — so that allowance is replaced by the exact amount instead of staying unseen (IOST-14).
    func request(for step: TransactionStep, owner: Address) async throws -> TransactionRequest? {
        switch step.kind {
        case .approve(let token, let spender, let amount):
            let allowance = try await multicall.readAll([try ERC20.allowance(token, owner: owner, spender: spender)])[0][0].uint
            if allowance >= amount, allowance < Self.unlimitedAllowance || amount >= Self.unlimitedAllowance { return nil }
            return TransactionRequest(to: token, data: try ERC20.approveCalldata(spender: spender, amount: amount))
        case .permit2Approve(let token, let spender, let amount, _):
            let allowance = try await multicall.readAll([try SwapCalldata.permit2Allowance(owner: owner, token: token, spender: spender)])[0]
            if allowance[0].uint >= amount, allowance[1].uint > BigUInt(Int(Date().timeIntervalSince1970) + 60) { return nil }
            return try step.request(at: Date())
        case .call:
            return step.request
        }
    }

    /// An allowance this large is effectively unlimited: what the confirmation sheet flags, and what an exact approval
    /// step replaces (`request(for:)`).
    public static let unlimitedAllowance = BigUInt(1) << 128

    /// The spenders whose standing, effectively unlimited allowance `steps` replace with an exact one (`request(for:)`),
    /// for the confirmation sheet to name. A read that fails names nothing.
    public func unlimitedAllowancesReplaced(by steps: [TransactionStep], owner: Address) async -> [Address] {
        var spenders: [Address] = []
        for step in steps {
            guard case .approve(let token, let spender, let amount) = step.kind, amount < Self.unlimitedAllowance,
                  let read = try? await multicall.readAll([try ERC20.allowance(token, owner: owner, spender: spender)]),
                  let allowance = read.first?.first?.uint, allowance >= Self.unlimitedAllowance else { continue }
            spenders.append(spender)
        }
        return spenders
    }

    public func send(_ request: TransactionRequest, from wallet: Wallet) async throws -> Data {
        let prepared = try await prepare(request, from: wallet)
        let signed = try await wallet.sign(prepared)
        return try await broadcast(signed, prepared)
    }

    /// Hands the signed bytes to the network and returns their hash: keccak-256 of those bytes, known before anything is
    /// sent. A node's refusal of this very transaction (`isRefusal`) settles it, after a look-up by hash in case an
    /// endpoint before a failover took it. Anything else — no answer at all (the connection dropped with the phone
    /// locked, every endpoint failed), a reply the client couldn't match, a gateway's "internal error" or "upstream
    /// timeout", throttling that outlasted the retries — leaves the transaction possibly live, so `confirmUnanswered`
    /// follows it by hash and never reports it as not sent.
    ///
    /// Monad's consensus checks a sender's balance as of a few blocks back, so a transaction from an account funded
    /// less than 3 blocks ago is refused with "Signer had insufficient balance" although the funds are visible. The
    /// same signed bytes are sent once more after ~1 s (no second signature, so no second Face ID). If the node still
    /// refuses, the message says what is true: the funds are still settling, or the balance doesn't cover the value
    /// plus the fee.
    func broadcast(_ signed: Data, _ transaction: PreparedTransaction) async throws -> Data {
        let hash = Keccak.hash256(signed)
        do {
            do {
                return try await rpc.sendRawTransaction(signed)
            } catch let error as RPCError where chainId == Monad.chainId && Self.isFundingInFlight(error) {
                try await Task.sleep(for: timing.fundingRetry)
                do {
                    return try await rpc.sendRawTransaction(signed)
                } catch let error as RPCError where Self.isFundingInFlight(error) {
                    throw TransactionError.rejected(await fundingRefusal(transaction))
                }
            }
        } catch let error as RPCError {
            if await rpc.knowsTransaction(hash) == true { return hash }
            guard Self.isRefusal(error) else { return try await confirmUnanswered(signed, hash: hash) }
            // "Nonce too low": a node behind the one that mined this transaction answers it too, so it is looked up a
            // few more times before another transaction is taken to have used the nonce.
            if Self.isNonceUsed(error), await becomesKnown(hash) { return hash }
            throw error
        } catch let error as TransactionError {
            throw error
        } catch {
            return try await confirmUnanswered(signed, hash: hash)
        }
    }

    /// A broadcast with no answer (PR-4). The same bytes go out again — the same transaction, never a replacement, so
    /// it can only land once — and the hash is looked up between tries. Anything short of the network taking it or
    /// having it is `possiblySent`: the caller follows the hash and never signs this step again, since a new signature
    /// would carry the next nonce and could land the step twice.
    private func confirmUnanswered(_ signed: Data, hash: Data) async throws -> Data {
        for attempt in 1...max(1, timing.resendAttempts) {
            try? await Task.sleep(for: timing.resendBackoff * attempt)
            if await rpc.knowsTransaction(hash) == true { return hash }
            if let taken = try? await rpc.sendRawTransaction(signed) { return taken }
        }
        if await rpc.knowsTransaction(hash) == true { return hash }
        throw TransactionError.possiblySent(hash)
    }

    /// Whether the network turns out to know `hash`, looked up with the same growing waits as `confirmUnanswered`.
    private func becomesKnown(_ hash: Data) async -> Bool {
        for attempt in 1...max(1, timing.resendAttempts) {
            try? await Task.sleep(for: timing.resendBackoff * attempt)
            if await rpc.knowsTransaction(hash) == true { return true }
        }
        return false
    }

    /// A node's answer that this very transaction is invalid — so no node holds it, and it can't land as signed (PR-4):
    /// the balance can't pay for it, its gas or fee fields are out of bounds, its nonce is used, it is signed for another
    /// chain. Deliberately narrow: an error that isn't about the transaction (a gateway's "internal error" or "upstream
    /// request timeout", the client's own "Missing response", throttling) may come from a path where a node took it.
    static func isRefusal(_ error: RPCError) -> Bool {
        let message = error.message.lowercased()
        return refusals.contains { message.contains($0) }
    }

    // not localized: the nodes' own English, matched as they send it
    static func isNonceUsed(_ error: RPCError) -> Bool { error.message.lowercased().contains("nonce too low") }

    // not localized: the nodes' own English, matched as they send it
    private static let refusals = [
        "insufficient funds", "insufficient balance", "intrinsic gas too low", "exceeds block gas limit", "underpriced",
        "less than block base fee", "tip higher than fee cap", "max priority fee per gas higher than max fee per gas",
        "nonce too low", "invalid sender", "invalid chain id", "transaction type not supported", "oversized data",
    ]

    /// Monad's refusal for a balance its consensus can't see yet. Other chains say "insufficient funds", which is a
    /// real shortfall and stays one.
    static func isFundingInFlight(_ error: RPCError) -> Bool {
        // not localized: Monad's own English, matched as it sends it
        error.message.localizedCaseInsensitiveContains("insufficient balance")
    }

    static var fundsArriving: String { L10n.tr("Your funds are still arriving. Try again in a moment.") }

    /// "Still arriving" when the latest balance covers the value and the most the fee can be; otherwise the account is
    /// really short, and saying the funds are on their way would be false.
    private func fundingRefusal(_ transaction: PreparedTransaction) async -> String {
        guard let balance = try? await rpc.balance(of: transaction.from) else { return Self.fundsArriving }
        let cost = transaction.value + transaction.gasLimit * transaction.maxFeePerGas
        return balance >= cost ? Self.fundsArriving : L10n.tr("Not enough MON to pay for gas.")
    }

    /// Monad's reserve balance: while an account holds under 10 MON plus what a transaction sends, that transaction
    /// reverts unless it is the sender's first in 3 blocks.
    public static let monadReserveBalance = BigUInt(10).power(19)
    static let reserveSpacingBlocks: UInt64 = 3

    /// Before a step that sends MON on Monad, when the account is under the reserve (10 MON + the value): waits until
    /// the head is 3 blocks past the block that confirmed this run's previous step (MERA-PLAN §5). The at-risk plan is
    /// an ERC-20-pair launch with a creator buy (approve, then `launchAndBuy` with its 5 MON fee). A first step, a step
    /// without value, a well-funded account and every other chain go straight on. A balance that can't be read counts
    /// as under the reserve; a head that doesn't move gives up after `timing.spacingTimeout` and sends anyway.
    func waitForReserveSpacing(value: BigUInt, after previousBlock: UInt64?, from address: Address) async throws {
        guard chainId == Monad.chainId, value > 0, let previousBlock else { return }
        if let balance = try? await rpc.balance(of: address), balance >= Self.monadReserveBalance + value { return }
        let target = previousBlock + Self.reserveSpacingBlocks
        let deadline = ContinuousClock.now + timing.spacingTimeout
        while ContinuousClock.now < deadline {
            if let head = try? await rpc.blockNumber(), head >= target { return }
            try await Task.sleep(for: timing.blockPoll)
        }
    }

    /// Runs a plan step by step. Approvals are skipped when the allowance already covers the amount.
    public func run(_ steps: [TransactionStep], from wallet: Wallet, onEvent: @Sendable @escaping (TransactionEvent) -> Void) async throws -> Data {
        var last: Data?
        // The block that confirmed this run's previous step, for Monad's reserve spacing.
        var previousBlock: UInt64?
        for step in steps {
            onEvent(.preparing(step.label))
            guard let request = try await self.request(for: step, owner: wallet.address) else { continue }
            try await waitForReserveSpacing(value: request.value, after: previousBlock, from: wallet.address)
            let hash: Data
            do {
                hash = try await send(request, from: wallet)
            } catch TransactionError.possiblySent(let possible) {
                // No endpoint said it took the broadcast, but it may be live: follow it like any sent step.
                hash = possible
            }
            onEvent(.sent(step.label, hash))
            let receipt = try await rpc.waitForReceipt(hash, polls: timing.receiptPolls, interval: timing.receiptInterval,
                                                       fastPolls: receiptFastPollCount, fastInterval: timing.receiptFastInterval)
            guard receipt.success else { throw TransactionError.reverted(hash) }
            onEvent(.confirmed(step.label, hash))
            last = hash
            previousBlock = receipt.blockNumber
        }
        guard let hash = last else { throw TransactionError.rejected(L10n.tr("Nothing to send.")) }
        return hash
    }
}

/// Turns node revert payloads into sentences people can act on.
public enum RevertReason {
    public static func describe(_ error: RPCError) -> String {
        if let data = error.data, let bytes = Data(hex: data), bytes.count >= 4 {
            let selector = bytes.prefix(4).hexString
            // not localized: a contract's own revert string, shown as it wrote it
            if selector == "0x08c379a0", let message = try? ABI.decode(bytes.dropFirst(4), "string")[0].string { // Error(string)
                return message
            }
            if let named = knownErrorSentences[selector] { return named() }
        }
        let message = error.message
        // not localized: the nodes' own English, matched as they send it ("insufficient funds", "custom error 0x…")
        if message.localizedCaseInsensitiveContains("insufficient funds") { return L10n.tr("Not enough MON to pay for gas.") }
        // "execution reverted: custom error 0xabcdef12: 0000…" — keep the selector and the payload's words as
        // numbers (usually amounts or limits), drop the wall of hex.
        if let range = message.range(of: #"custom error (0x[0-9a-fA-F]{8})"#, options: .regularExpression) {
            let selector = String(message[range]).replacingOccurrences(of: "custom error ", with: "")
            var args = ""
            let payload = error.data.flatMap { Data(hex: $0) }?.dropFirst(4) ?? Data()
            if !payload.isEmpty, payload.count % 32 == 0, payload.count <= 32 * 6 {
                let words = stride(from: payload.startIndex, to: payload.endIndex, by: 32).map { BigUInt(payload[$0..<$0 + 32]) }
                args = words.map { $0.bitWidth > 128 ? "0x" + String($0, radix: 16).prefix(10) + "…" : String($0) }.joined(separator: ", ")
            }
            // not localized: the selector and its arguments, hex and digits
            return args.isEmpty ? L10n.tr("The contract rejected the transaction (custom error \(selector)).")
                : L10n.tr("The contract rejected the transaction (custom error \(selector) with \(args)).")
        }
        return message.isEmpty ? L10n.tr("The transaction would fail.") : message
    }

    /// Custom error selectors worth naming: the DyorHQ launchpad and Moments contracts' errors (v1 and v2), keyed by
    /// selector. A selector is only the error's name and arguments, so several contracts can raise the same one
    /// (`ModulesNotSet`, `NothingToClaim`, `InsufficientGasForGraduation`, `ZeroAddress`, `PriceOutOfRange`…): every
    /// sentence reads right whichever contract raised it. `RevertReasonTests` pins each selector against `cast sig`.
    /// A flow with better context names its own (`MomentsService.collectReason`). Extend as contracts are added. Each
    /// sentence is written when it is shown, so it is in the app's language at that moment.
    static var knownErrors: [String: String] { knownErrorSentences.mapValues { $0() } }

    /// `knownErrors`, each sentence as the function that writes it: the selectors are hashed once.
    private static let knownErrorSentences: [String: @Sendable () -> String] = {
        let table: [(String, @Sendable () -> String)] = [
            // Shared by several contracts.
            ("ModulesNotSet", { L10n.tr("The contracts aren't fully set up yet, so nothing was sent.") }),
            ("ZeroAddress", { L10n.tr("The transaction names the zero address, so the contract refused it.") }),
            ("NothingToClaim", { L10n.tr("There is nothing to claim yet.") }),
            ("InsufficientGasForGraduation", { L10n.tr("This transaction would graduate the coin and needs more gas to graduate. Try again.") }),
            ("PriceOutOfRange", { L10n.tr("The pool price is out of the range graduation accepts right now. Try again later.") }),
            ("NotGraduated", { L10n.tr("This hasn't graduated yet.") }),
            // Moments factory.
            ("TermsChanged", { L10n.tr("The Moments terms changed after you reviewed them, so nothing was published. Review them again.") }),
            ("Paused", { L10n.tr("Publishing is paused right now, so nothing was published.") }),
            ("PriceTooHigh", { L10n.tr("That price is above the most a collect can be charged (the gross that completes the reserve). Lower it.") }),
            ("PriceTooLow", { L10n.tr("That price is below the minimum collect price.") }),
            ("AllocTooHigh", { L10n.tr("That allocation is above the most a creator can keep.") }),
            ("BadWindow", { L10n.tr("The collect window must be between 1 hour and 30 days.") }),
            ("UnknownMoment", { L10n.tr("That Moment does not exist.") }),
            ("PolicyLapsed", { L10n.tr("That proposed policy lapsed: nobody applied it within 7 days of it becoming applicable.") }),
            ("NotGuardian", { L10n.tr("Only the Moments guardian can do that.") }),
            ("NotGovernanceOrGuardian", { L10n.tr("Only governance or the Moments guardian can do that.") }),
            ("UnpauseFirst", { L10n.tr("The guardian's pause must be lifted first.") }),
            ("BaseURITooLong", { L10n.tr("That link base is too long.") }),
            // Moments collect, graduation and vesting.
            ("NotCollecting", { L10n.tr("This Moment is no longer collecting.") }),
            ("CollectWindowClosed", { L10n.tr("The collect window has closed.") }),
            ("BadQuantity", { L10n.tr("Choose between 1 and \(MomentsConstants.maxBatch) editions.") }),
            ("NotExpirable", { L10n.tr("This Moment can't be expired yet.") }),
            ("WrongState", { L10n.tr("This Moment isn't in a state that allows this.") }),
            ("NotBeneficiary", { L10n.tr("Only the wallet this is owed to can withdraw it.") }),
            ("NothingToWithdraw", { L10n.tr("There is nothing to withdraw.") }),
            ("NotPending", { L10n.tr("This Moment isn't waiting to graduate.") }),
            ("AlreadyGraduated", { L10n.tr("This Moment has already graduated.") }),
            // Moments buyback.
            ("TooSoon", { L10n.tr("A buyback for this Moment ran less than an hour ago. Try again later.") }),
            ("BelowMinimum", { L10n.tr("The buyback budget is below the 1 USDC minimum a round needs.") }),
            ("Slippage", { L10n.tr("The pool price moved past the buyback's slippage limit. Try again.") }),
            ("PriceMoved", { L10n.tr("The pool price moved more than 2% within this block, so the buyback was refused. Try again in a later block.") }),
            // Launchpad factory.
            ("NotWhitelisted", { L10n.tr("Launching is limited to approved wallets right now.") }),
            ("LaunchConfigDisabled", { L10n.tr("This launch template is turned off, so nothing was launched.") }),
            ("PairTokenNotApproved", { L10n.tr("That pair asset isn't approved for launches.") }),
            ("PairRequiresMonday", { L10n.tr("That pair asset can only graduate on Monday Trade.") }),
            ("GraduationVenueUnavailable", { L10n.tr("That graduation venue isn't available.") }),
            ("LaunchFeeNotPaid", { L10n.tr("The launch fee wasn't paid in full.") }),
            ("CreatorTaxTooHigh", { L10n.tr("That creator tax is above the maximum.") }),
            ("ExemptionListTooLong", { L10n.tr("Too many snipe-tax exemptions: at most \(String(LaunchpadService.maxExemptions)).") }),
            ("LaunchEconomicsMismatch", { LaunchpadError.termsChanged.errorDescription ?? "" }),
            ("UnknownLaunch", { L10n.tr("That coin wasn't launched on this launchpad.") }),
            ("WrongGraduationPhase", { L10n.tr("This coin isn't in the phase that allows this.") }),
            ("FallbackNotAvailable", { L10n.tr("The Uniswap v4 fallback isn't available for this coin yet.") }),
            ("Create2Mismatch", { L10n.tr("The coin couldn't be created at its expected address. Try again.") }),
            ("InvalidTickSpacing", { L10n.tr("That tick spacing isn't valid.") }),
            // Bonding curve.
            ("CurveNotTrading", { L10n.tr("This coin's bonding curve isn't trading.") }),
            ("CurveIsCompleted", { L10n.tr("This coin's bonding curve is complete; it trades in its pool now.") }),
            ("SlippageExceeded", { L10n.tr("The price moved past your slippage limit. Try again.") }),
            ("NativeValueMismatch", { L10n.tr("The MON sent doesn't match the amount.") }),
            ("UnexpectedNativeValue", { L10n.tr("MON was sent with a trade that takes none.") }),
            ("ZeroAmount", { L10n.tr("Enter an amount above zero.") }),
            ("InsufficientRealReserve", { L10n.tr("The curve doesn't hold enough to pay that out. Try a smaller amount.") }),
            ("UnsupportedQuoteToken", { L10n.tr("This pair asset can't trade on the curve.") }),
        ]
        return Dictionary(table.map { (ABI.selector("\($0.0)()").hexString, $0.1) }, uniquingKeysWith: { first, _ in first })
    }()
}

/// EIP-1559 transaction encoding (type 2) for wallets that sign a hash rather than a JSON request.
public enum RLP {
    public static func encode(_ item: RLPItem) -> Data {
        switch item {
        case .bytes(let data):
            if data.count == 1, data[data.startIndex] < 0x80 { return data }
            return length(data.count, offset: 0x80) + data
        case .list(let items):
            let body = items.map(encode).reduce(Data(), +)
            return length(body.count, offset: 0xC0) + body
        }
    }

    private static func length(_ n: Int, offset: UInt8) -> Data {
        if n < 56 { return Data([offset + UInt8(n)]) }
        let bytes = BigUInt(n).serialize()
        return Data([offset + 55 + UInt8(bytes.count)]) + bytes
    }

    public static func quantity(_ value: BigUInt) -> RLPItem { .bytes(value == 0 ? Data() : value.serialize()) }

    /// The bytes to sign for an EIP-1559 transaction: `0x02 || rlp([chainId, nonce, priority, maxFee, gas, to, value, data, accessList])`.
    public static func unsignedPayload(_ tx: PreparedTransaction) -> Data {
        Data([0x02]) + encode(.list([
            quantity(BigUInt(tx.chainId)), quantity(BigUInt(tx.nonce)), quantity(tx.maxPriorityFeePerGas), quantity(tx.maxFeePerGas),
            quantity(tx.gasLimit), .bytes(tx.to.data), quantity(tx.value), .bytes(tx.data), .list([]),
        ]))
    }

    /// The raw transaction once `v` (0/1), `r` and `s` are known.
    public static func signedTransaction(_ tx: PreparedTransaction, v: UInt8, r: BigUInt, s: BigUInt) -> Data {
        Data([0x02]) + encode(.list([
            quantity(BigUInt(tx.chainId)), quantity(BigUInt(tx.nonce)), quantity(tx.maxPriorityFeePerGas), quantity(tx.maxFeePerGas),
            quantity(tx.gasLimit), .bytes(tx.to.data), quantity(tx.value), .bytes(tx.data), .list([]),
            quantity(BigUInt(v)), quantity(r), quantity(s),
        ]))
    }
}

public indirect enum RLPItem: Sendable, Equatable {
    case bytes(Data)
    case list([RLPItem])
}
