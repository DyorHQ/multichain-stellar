import Foundation

/* A Mera signing session: the Swift equivalent of Mera's `createSecp256k1SigningSession` and
   `createEd25519SigningSession` (MERA-PLAN §3). One passkey ceremony opens it with the PRF outputs it returned, and it
   holds the only copies of what they derive, in memory, for a time fixed when it opens:

     account   the secp256k1 wallet key (Mera's account namespace)
     utility   DyorHQ's utility PRF output, from which an enrolment's Perpl Ed25519 trading secret is derived on use

   Key bytes never leave it: callers get signatures, the public address, and the Perpl API key the trading socket
   signs with. `end()` zeroes the mutable copies (best effort, as Mera says: copies the runtime or a library made are
   out of reach) and is permanent, like expiry — every later call throws `sessionEnded`. Opening another session takes
   another ceremony; that policy (when to prompt, step-ups) lives in the app's MeraSession. */
extension Mera {
    public enum SessionError: Error, LocalizedError, Equatable {
        /// The session was ended (Lock, background, sign-out) or expired. A new one takes a new ceremony.
        case sessionEnded
        /// The provider evaluated one PRF salt only and the utility output hasn't been fetched yet.
        case noUtilityOutput
        /// A PRF output that isn't 32 bytes.
        case malformedOutput

        public var errorDescription: String? {
            switch self {
            case .sessionEnded: return L10n.tr("Your passkey session ended before this finished. Nothing was signed; try again.")
            case .noUtilityOutput: return L10n.tr("This passkey hasn’t unlocked DyorHQ’s trading key yet. Try again to confirm with your passkey.")
            case .malformedOutput: return L10n.tr("The passkey returned an output DyorHQ can’t use.")
            }
        }
    }

    // MARK: Length

    /// How long a session stays open (Settings): 5, 15 or 60 minutes, 15 by default. The length is read when a session
    /// opens and fixes its `expiresAt`; changing it never touches a live session.
    public enum SessionLength {
        public static let choices: [TimeInterval] = [5 * 60, 15 * 60, 60 * 60]
        public static let standard: TimeInterval = 15 * 60

        /// A stored or requested length, as one of the choices. Anything else (unset, zero, a tampered default) is the
        /// standard length, never a longer one.
        public static func sanitized(_ length: TimeInterval) -> TimeInterval {
            choices.contains(length) ? length : standard
        }

        /// Whether moving from `current` to `requested` needs the owner (a forced pinned ceremony): lengthening does,
        /// shortening or keeping the length is free.
        public static func needsStepUp(from current: TimeInterval, to requested: TimeInterval) -> Bool {
            sanitized(requested) > sanitized(current)
        }
    }

    // MARK: Caps

    /// The dollar caps on what a live session does without a prompt (MERA-PLAN §3 "Scope", check 3): at most $100 per
    /// action and $250 over the whole session. An action above either, or one the app can't price, asks for a step-up.
    public struct SpendingCaps: Equatable, Sendable {
        public static let perActionUSD: Double = 100
        public static let perSessionUSD: Double = 250

        public enum Verdict: Equatable, Sendable {
            case allowed
            /// No usable dollar value (missing, negative, not finite): Face ID.
            case unpriced
            case overActionCap
            case overSessionCap
        }

        /// What this session's prompt-free actions have spent so far.
        public private(set) var spentUSD: Double = 0

        public init() {}

        public var remainingUSD: Double { max(0, Self.perSessionUSD - spentUSD) }

        /// Whether `usd` fits, without recording it. A cent of float noise never tips an exact fit over.
        public func verdict(for usd: Double?) -> Verdict {
            guard let usd, usd.isFinite, usd >= 0 else { return .unpriced }
            if usd > Self.perActionUSD + 1e-9 { return .overActionCap }
            if spentUSD + usd > Self.perSessionUSD + 1e-9 { return .overSessionCap }
            return .allowed
        }

        /// Records `usd` when it fits; anything else is left for a step-up and records nothing.
        @discardableResult
        public mutating func charge(_ usd: Double?) -> Verdict {
            let verdict = verdict(for: usd)
            if verdict == .allowed, let usd { spentUSD += usd }
            return verdict
        }

        /// Gives back a charge whose action provably didn't happen (refused before sending, or rejected).
        public mutating func refund(_ usd: Double) {
            guard usd.isFinite, usd > 0 else { return }
            spentUSD = max(0, spentUSD - usd)
        }

        /// A perp order's worst-case notional in USD (AUSD): its size at the highest price it may fill at — for a market
        /// order the mark moved by the whole slippage allowance, for a limit order the higher of its limit and the mark.
        /// A limit on the far side of the mark crosses the book and fills near the mark, so a short limited far below it
        /// (which the limit alone would value at a fraction of its size) is valued at the mark. Nil when it can't be priced.
        public static func notionalUSD(of order: OrderInput) -> Double? {
            let price = order.kind == .market
                ? order.market.mark * (1 + Double(max(order.slippageBps, 0)) / 10_000)
                : max(order.price ?? order.market.mark, order.market.mark)
            let notional = order.size * price
            guard order.size > 0, price > 0, notional.isFinite else { return nil }
            return notional
        }
    }

    // MARK: Session

    @MainActor
    public final class SigningSession {
        public let address: Address
        /// The passkey that opened it (public; deletion reports it, step-ups pin to it).
        public let credentialID: Data
        /// The passkey's WebAuthn user handle, when the ceremony returned it. Memory only.
        public let userID: Data?
        public let openedAt: Date
        /// Fixed when the session opens. Nothing extends it.
        public let expiresAt: Date
        public private(set) var isEnded = false
        /// What this session's prompt-free actions have spent against its caps.
        public private(set) var caps = SpendingCaps()

        /// The wallet key: the session's one mutable copy, zeroed by `end()`. A `Secp256k1Account` is built from it for
        /// each signature and dropped with it, so no second long-lived copy exists.
        private var privateKey: Data
        /// DyorHQ's utility PRF output, nil until available (see `attachUtility`). The Perpl trading secret of an
        /// enrolment is derived from it when asked (`Purpose.perplTrading(nonce:)`) and never stored.
        private var utility: Data?

        /// Opens a session from a ceremony's PRF outputs. Nil when the account output derives no account (it isn't 32
        /// bytes). A malformed utility output counts as missing.
        public init?(account output: Data, utility: Data?, credentialID: Data, userID: Data? = nil, length: TimeInterval, openedAt: Date = Date()) {
            guard let account = Mera.evmAccount(prf: output) else { return nil }
            address = account.address
            privateKey = account.privateKey
            self.credentialID = credentialID
            self.userID = userID
            self.openedAt = openedAt
            expiresAt = openedAt.addingTimeInterval(max(0, length))
            self.utility = Ceremony.usable(utility)
        }

        public func isLive(at date: Date = Date()) -> Bool { !isEnded && date < expiresAt }

        /// Whether the utility output (and so the Perpl trading secret) is available.
        public var hasUtility: Bool { utility != nil }

        /// Adds the utility output a later pinned assertion fetched, when the opening ceremony evaluated one salt only.
        /// Throws `sessionEnded` when the session ended while that prompt was open: nothing is attached to it then.
        public func attachUtility(_ output: Data, now: Date = Date()) throws {
            try requireLive(now)
            guard let output = Ceremony.usable(output) else { throw SessionError.malformedOutput }
            utility = output
        }

        // MARK: Signing (secp256k1)

        /// The raw signed EIP-1559 transaction.
        public func sign(_ transaction: PreparedTransaction, now: Date = Date()) throws -> Data {
            try account(now).sign(transaction)
        }

        /// An EIP-191 personal-message signature.
        public func signMessage(_ message: Data, now: Date = Date()) throws -> Data {
            try account(now).signMessage(message)
        }

        // MARK: Caps

        /// Charges a prompt-free action's dollar value against this session's caps; records it only when it fits.
        public func charge(usd: Double?, now: Date = Date()) throws -> SpendingCaps.Verdict {
            try requireLive(now)
            return caps.charge(usd)
        }

        public func refund(usd: Double) {
            guard !isEnded else { return }
            caps.refund(usd)
        }

        // MARK: Perpl (Ed25519)

        /// The Perpl API key the trading socket signs with: the stored `token` with the trading secret of the enrolment
        /// that issued it (`keyNonce`, stored with the token; nil for a pre-nonce enrolment). Nil until the utility
        /// output is available. It lives as long as the caller keeps it; the app drops it on `end()`.
        public func perplApiKey(token: String, scopeMask: Int, keyNonce: Data?, now: Date = Date()) throws -> PerplApiKey? {
            try requireLive(now)
            guard let secret = perplSecret(keyNonce) else { return nil }
            return PerplApiKey(token: token, secret: secret, address: address.checksummed, scopeMask: scopeMask)
        }

        /// Enrols a Perpl trading key for this account, entirely inside the session: the key is the passkey-derived
        /// secret for `keyNonce` (a fresh `Purpose.newPerplNonce()`, which the caller stores with the token), the
        /// server's typed data is validated for exactly this wallet and key (`PerplAuthClient.requestPayload`), and the
        /// digest signed is the one recomputed from it on device — no caller ever hands this session a digest. A session
        /// that ends during the round trip signs nothing. `now` is the clock (tests pin it to the payload's time).
        public func enrollPerpl(auth: PerplAuthClient, label: String, keyNonce: Data, now: () -> Date = { Date() }) async throws -> PerplApiKey {
            try requireLive(now())
            guard let secret = perplSecret(keyNonce) else { throw SessionError.noUtilityOutput }
            let payload = try await auth.requestPayload(address: address.checksummed, publicKeyHex: try PerplAuth.publicKeyHex(secret: secret),
                                                        scopeMask: PerplScope.trade, label: label, now: now())
            let signature = try account(now()).sign(hash32: payload.digest)
            return try await auth.enroll(address: address.checksummed, secret: secret, payload: payload, walletSignature: signature.hexString, scopeMask: PerplScope.trade)
        }

        // MARK: End

        /// Ends the session for good: the key copies are zeroed and dropped, and every later call throws `sessionEnded`.
        public func end() {
            guard !isEnded else { return }
            isEnded = true
            Self.wipe(&privateKey)
            Self.wipe(&utility)
        }

        /// Whether any key material is still held (false once ended). For tests; returns no bytes.
        var holdsKeyMaterial: Bool { privateKey.contains { $0 != 0 } || utility != nil }

        // MARK: Private

        /// The Perpl trading secret of the enrolment `nonce` names, from the utility output. Nil without it.
        private func perplSecret(_ nonce: Data?) -> Data? {
            utility.map { Mera.derivedKey(prf: $0, purpose: Purpose.perplTrading(nonce: nonce)) }
        }

        /// Throws `sessionEnded` unless the session is live. An expired session is ended on the spot, so expiry is as
        /// final as `end()`.
        private func requireLive(_ now: Date) throws {
            guard isLive(at: now) else {
                end()
                throw SessionError.sessionEnded
            }
        }

        /// The wallet key for one signature, built from the session's copy.
        private func account(_ now: Date) throws -> Secp256k1Account {
            try requireLive(now)
            guard let account = Secp256k1Account(privateKey: privateKey) else { throw SessionError.sessionEnded }
            return account
        }

        /// Zeroes the bytes in place with `memset_s`, which the optimizer may not drop as a dead store.
        private static func wipe(_ data: inout Data) {
            data.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress, buffer.count > 0 else { return }
                _ = memset_s(base, buffer.count, 0, buffer.count)
            }
        }

        private static func wipe(_ data: inout Data?) {
            guard var bytes = data else { return }
            data = nil // `bytes` now holds the only reference, so the wipe happens in place rather than on a copy
            wipe(&bytes)
        }
    }
}
