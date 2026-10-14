import CryptoKit
import DyorKit
import Foundation
import Observation
import Security

/// The only things the app remembers about a passkey account, both public: which credential backs it (so a
/// sign-in can be pinned to it) and the address it derives to (so the app can show the account while locked — the
/// address Receive shows). Neither is a secret, but both must be what this app wrote after a passkey ceremony derived
/// the address: they live in this device's Keychain (not synced, not in backups made on another device), where another
/// app or an edited backup can't swap in someone else's address (security audit 2026-09-26, IOSK-12). Builds before
/// that kept them in UserDefaults, which a restored or edited backup can plant, so that copy is never trusted: it is
/// deleted, and the account comes back with "I already have a passkey", which derives the address from the passkey. A
/// fresh device reconstructs everything from the passkey alone.
@MainActor
enum MeraCredentialStore {
    private static let service = "fun.dyorhq.mera"
    private static let account = "account.v1"
    /// Where builds before the Keychain move kept the pair (UserDefaults): deleted, never read.
    private static let legacyCredentialKey = "mera.credential.v1"
    private static let legacyAddressKey = "mera.address.v1"

    private struct Record: Codable, Equatable {
        let credential: String // base64url
        let address: String    // checksummed
    }

    /// Read once per launch, then kept in step with every save and clear.
    private static var cached: Record??

    static var credentialID: Data? { record.flatMap { Mera.Base64URL.decode($0.credential) } }
    static var address: Address? { record.flatMap { Address($0.address) } }

    static func save(credentialID: Data, address: Address) {
        let record = Record(credential: Mera.Base64URL.encode(credentialID), address: address.checksummed)
        guard record != cached ?? nil else { return }
        write(record)
        cached = .some(record)
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyCredentialKey)
        UserDefaults.standard.removeObject(forKey: legacyAddressKey)
        cached = .some(nil)
    }

    private static var record: Record? {
        if let cached { return cached }
        switch load() {
        case .found(let stored):
            cached = .some(stored)
            return stored
        case .missing:
            UserDefaults.standard.removeObject(forKey: legacyCredentialKey)
            UserDefaults.standard.removeObject(forKey: legacyAddressKey)
            cached = .some(nil)
            return nil
        case .unreadable:
            return nil // the Keychain is locked (before the first unlock): not remembered, so the next read tries again
        }
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private enum Lookup { case found(Record?), missing, unreadable }

    private static func load() -> Lookup {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        switch SecItemCopyMatching(lookup as CFDictionary, &item) {
        case errSecSuccess: return .found((item as? Data).flatMap { try? JSONDecoder().decode(Record.self, from: $0) })
        case errSecItemNotFound: return .missing
        default: return .unreadable
        }
    }

    @discardableResult
    private static func write(_ record: Record) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Readable after the first unlock, so a relaunch in the background still knows the account; never synced.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// What lives and dies with a passkey session besides the keys themselves: Perpl trading's in-memory key and socket.
@MainActor
protocol MeraSessionLifecycle: AnyObject {
    /// A session opened (or replaced the live one), or the live one gained its utility output.
    func meraSessionDidOpen(_ session: MeraSession)
    /// The live session ended: by expiry, Lock, the app leaving the foreground, or sign-out.
    func meraSessionDidEnd(_ session: MeraSession)
}

/// A Mera passkey account and its signing session (MERA-PLAN §3). One passkey ceremony (Face ID) opens a session
/// (`Mera.SigningSession`) that holds the wallet key and DyorHQ's utility namespace in memory until it ends — at the
/// `expiresAt` fixed when it opened, when the app leaves the foreground, on Lock, or on sign-out. Anything that signs
/// while it is live is prompt-free; anything after it re-runs the ceremony, pinned to the same credential and checked
/// to derive the same address. Only one ceremony runs at a time (`PasskeyCeremony.exclusive`): a concurrent request
/// fails with `Mera.Ceremony.Busy`.
///
/// Key material never leaves the session types: callers get signatures (`signTransaction`, `signMessage`), Perpl
/// enrolment done inside the session, the Perpl API key the trading socket needs while the session is live, and
/// step-up approvals — never key bytes. The one deliberate exception is export (`revealPhrase`): the recovery phrase,
/// behind a ceremony of its own every time, for the screen that shows it and nothing else.
///
/// Scope (MERA-PLAN §3): a live session signs an action without a prompt only when the sheet declared a session-OK
/// intent (`Action`), the wallet's own check of every transaction passes (`Mera.SigningPolicy`) and the caps hold.
/// Anything else — or anything at all while locked — runs one forced pinned ceremony that approves that action and
/// opens a new session (`approve`).
@Observable
@MainActor
final class MeraSession {
    enum Failure: LocalizedError {
        case differentPasskey(expected: Address, got: Address), noUtilityNamespace, noAccount
        /// Work nobody tapped for (`signMessageWithoutPrompt`) found no live session, or a message the session doesn't
        /// sign on its own: it would take a passkey prompt, so it is skipped instead.
        case promptNeeded
        /// The passkey's output gave no phrase that restores this account, so none is shown (`revealPhrase`).
        case phraseUnavailable
        /// A transaction no approval makes acceptable (`Mera.SigningPolicy.refusal`): refused before any prompt.
        case refused(Mera.SigningPolicy.Reason)
        /// The failure in the app's language (the policy's reason comes from DyorKit, in it too).
        var errorDescription: String? {
            switch self {
            case .differentPasskey(let expected, let got): return tr("That passkey belongs to \(got.short), not to this account (\(expected.short)). Sign out to switch accounts.")
            case .noUtilityNamespace: return tr("This passkey provider evaluates one PRF salt only; capability keys are unavailable.")
            case .noAccount: return tr("No passkey account is signed in on this device.")
            case .promptNeeded: return tr("Confirm with your passkey to continue.")
            case .phraseUnavailable: return tr("Couldn’t make a recovery phrase that restores this wallet, so none is shown. Try again.")
            case .refused(let reason): return tr("Blocked for your safety: \(reason.summary). This transaction wasn’t signed.")
            }
        }
    }

    /// An action the live session can't do without the owner: it's locked, over a cap, unpriced, or an action that
    /// always asks. The UI answers it with `stepUp()` and retries with the approval.
    struct StepUpRequired: LocalizedError, Equatable {
        enum Reason: Equatable {
            case locked, unpriced, overActionCap, overSessionCap, cancelOrder, reduceOnlyClose
            /// An action outside the session's scope that always asks (`Mera.AlwaysAsk.unlisted`): adding margin over the
            /// trading connection, as the wallet transaction asks for it.
            case unlisted
        }
        let reason: Reason

        /// The "<reason>" in "Face ID required: <reason>".
        var summary: String {
            switch reason {
            case .locked: return Mera.SigningPolicy.Reason.locked.summary
            case .unpriced: return Mera.SigningPolicy.Reason.unpriced.summary
            case .overActionCap: return Mera.SigningPolicy.Reason.overActionCap.summary
            case .overSessionCap: return Mera.SigningPolicy.Reason.overSessionCap.summary
            case .cancelOrder: return Mera.AlwaysAsk.cancelOrder.summary
            case .reduceOnlyClose: return Mera.AlwaysAsk.closePosition.summary
            case .unlisted: return Mera.AlwaysAsk.unlisted.summary
            }
        }
        var errorDescription: String? {
            tr(LocalizedStringResource("\(BiometricGate.promptName) required: \(summary).", comment: "“Face ID required: <why>.” The first value is Face ID, Touch ID, Optic ID or Passcode."))
        }
    }

    /// Proof that the owner just passed a forced pinned ceremony, for the one action that asked for it. Only `stepUp`
    /// makes one; it is spent by that action, and it is void once the session it opened ends.
    struct StepUp {
        /// The passkey the ceremony ran with (account deletion reports it to the provider).
        let credentialID: Data
        let address: Address
        fileprivate let id: UUID
    }

    /// A prompt-free action's charge against the session it ran in, refundable if the action provably didn't happen.
    struct Charge {
        fileprivate weak var session: Mera.SigningSession?
        let usd: Double
    }

    /// One action a sheet asks the session to sign — a whole plan (approve, then swap) — with the intent the sheet
    /// declared. Its dollar value is charged once, and a step-up approves everything it signs in the session that
    /// step-up opened, so one action never asks twice.
    @MainActor
    final class Action {
        let intent: Mera.Intent
        /// The session a step-up for this action opened.
        fileprivate weak var approvedIn: Mera.SigningSession?
        /// The session this action's dollar value was charged to.
        fileprivate weak var chargedIn: Mera.SigningSession?

        init(_ intent: Mera.Intent = .ask) { self.intent = intent }
    }

    /// What a sheet shows before its confirm button: "No Face ID needed", "Face ID required: <reason>", or — for a plan
    /// the wallet would refuse whatever the approval (`Mera.SigningPolicy.refusal`) — "Blocked for your safety: <reason>".
    /// "Face ID" is this device's own prompt (`BiometricGate.promptName`).
    enum Assessment: Equatable {
        case promptFree
        case faceID(String)
        case refused(String)

        var needsFaceID: Bool { if case .faceID = self { return true } else { return false } }
        var isRefused: Bool { if case .refused = self { return true } else { return false } }
        /// The badge in the app's language.
        var badge: String {
            switch self {
            case .promptFree: return tr("No \(BiometricGate.promptName) needed")
            case .faceID(let reason):
                return tr(LocalizedStringResource("\(BiometricGate.promptName) required: \(reason)", comment: "“Face ID required: <why>” on a confirmation sheet. The first value is Face ID, Touch ID, Optic ID or Passcode."))
            case .refused(let reason): return tr("Blocked for your safety: \(reason)")
            }
        }
    }

    /// The one rpId every Mera account is bound to — a constant, never a build setting.
    let rpId = Mera.relyingParty
    /// How long a new session stays open. Changing it never touches a live session (`setSessionLength`).
    private(set) var sessionLength: TimeInterval
    /// Perpl trading, which keeps its key and socket only while a session is live.
    @ObservationIgnored weak var lifecycle: (any MeraSessionLifecycle)?
    /// The contracts the scope check trusts (the app's configured Moments cohorts), set once by AppEnvironment.
    @ObservationIgnored var contracts: Mera.SigningPolicy.Contracts = .monadMainnet
    /// Reads, on-chain, the curve a known launchpad factory recorded for a launch token (`LaunchpadService.knownCurve`).
    /// Without it no launchpad trade is prompt-free.
    @ObservationIgnored var curveVerifier: (@Sendable (Address) async -> Address?)?
    /// Reads, on-chain, which of a plan's curves a retired launchpad recorded (`LaunchpadService.retiredCurves`), so a buy
    /// on one is refused (`Mera.SigningPolicy.refusal`). Without it every curve buy is refused as unverified.
    @ObservationIgnored var retiredCurveLookup: (@Sendable (Set<Address>) async -> Mera.SigningPolicy.RetiredCurves)?

    /// The open session. Private: its keys never leave these types.
    private var live: Mera.SigningSession?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// The step-up approval waiting to be spent, and the session its ceremony opened.
    @ObservationIgnored private var pendingStepUp: (id: UUID, session: Mera.SigningSession)?
    /// Approved actions still signing or sending (`beginAction`): a plan's later steps, a Perpl bracket's frames — for
    /// every account type, not only passkeys. Observable, so a Moment link waits until none is running (RootView).
    private(set) var runningActions = 0
    /// The app is in the background (`endWhenIdle` until `enteredForeground`).
    @ObservationIgnored private var inBackground = false
    /// The app left the foreground while an action ran: the session ends when the last one finishes (GL-1).
    @ObservationIgnored private var endsWhenIdle = false
    /// The background time iOS grants for those actions to finish; when it runs out the session ends regardless.
    @ObservationIgnored private var backgroundTime: BackgroundTime?
    /// And a deadline of its own, whatever iOS grants (GL-7): checked on every use of the session, and a timer ends it.
    @ObservationIgnored private var idleDeadline: Date?
    @ObservationIgnored private var idleDeadlineTimer: Task<Void, Never>?
    /// How long a session may outlive the app leaving the foreground for an approved action to finish: about the
    /// background time iOS grants.
    private static let backgroundGrace: TimeInterval = 30
    private let ceremony: PasskeyCeremony
    /// Where this build reports a passkey as unknown: orphan cleanup here, and account deletion (`AccountDeletion`,
    /// through `Mera.AccountDeletion.run`, which alone decides when it is sent).
    let signal: any PasskeySignaling
    #if DEBUG && targetEnvironment(simulator)
    /// Simulator test mode (`PasskeyBackend.isStub`): the stub's key sits in plain UserDefaults, and its RPC check runs
    /// only at ceremony time, so this session enforces the rest where it signs (`Mera.Stub.permits`) — transactions for
    /// Monad's chain id only (the local fork's), no message and so no production wallet-auth, no Perpl enrolment. The
    /// app's backend sign-in skips it quietly (`SocialSession.startSignIn`), and the Bridge screen is closed to it.
    let isStub: Bool
    #endif
    private var salts: (Data, Data) { (Mera.accountSalt, Mera.utilitySalt) }
    private static let lengthKey = "mera.sessionLength"

    init(backend: PasskeyBackend) {
        ceremony = PasskeyCeremony(authenticator: backend.authenticator)
        signal = backend.signal
        #if DEBUG && targetEnvironment(simulator)
        isStub = backend.isStub
        #endif
        sessionLength = Mera.SessionLength.sanitized(UserDefaults.standard.double(forKey: Self.lengthKey))
    }

    var address: Address? { live?.address ?? MeraCredentialStore.address }
    /// Whether a passkey ceremony is open: its system sheet makes the scene `.inactive`, and the privacy cover stays
    /// off for it (RootView). Observable.
    var isPrompting: Bool { ceremony.isBusy }
    /// When the live session ends; nil while locked. Fixed when the session opened.
    var expiresAt: Date? { live.flatMap { $0.isEnded ? nil : $0.expiresAt } }
    var isUnlocked: Bool { live?.isLive() ?? false }
    /// What the live session's prompt-free actions have spent, and what is left of its cap; nil while locked.
    var spentUSD: Double? { live.flatMap { $0.isLive() ? $0.caps.spentUSD : nil } }
    var remainingUSD: Double? { live.flatMap { $0.isLive() ? $0.caps.remainingUSD : nil } }

    // MARK: Ceremonies

    /// New account: one passkey ceremony over both salts, address on screen before the sheet closes. The passkey is
    /// named "DyorHQ · <date>". Nothing is stored but the credential id and the address.
    ///
    /// Orphan cleanup: when the new passkey yields no usable account output — the provider can't evaluate PRF, or the
    /// fallback assertion failed or was cancelled — no address was ever derived from it, so it is reported to the
    /// provider as unknown rather than left behind as a dead "DyorHQ" entry. Never once `open` has succeeded: from
    /// then on the passkey is the account.
    func create() async throws -> Address {
        try await ceremony.exclusive {
            let registration = try await ceremony.register(rpId: rpId, name: Mera.Ceremony.passkeyName(createdAt: Date()), salts: salts)
            do {
                return try open(try await ceremony.complete(registration, rpId: rpId, salts: salts), expecting: nil).address
            } catch {
                await signal.reportUnknown(relyingParty: rpId, credentialID: registration.credentialID)
                throw error
            }
        }
    }

    /// "I already have a passkey": a discoverable assertion with no allowCredentials, so any DyorHQ passkey on this
    /// phone, in iCloud Keychain or on another phone (QR in the system sheet) reconstructs its account.
    func signIn() async throws -> Address {
        try await ceremony.exclusive {
            try open(try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: nil), expecting: nil).address
        }
    }

    /// Opens a session when none is live (a ceremony pinned to the stored credential that must derive the stored
    /// address); does nothing while one is. For a tap that needs the session, e.g. reconnecting Perpl trading.
    func unlock() async throws {
        _ = try await current()
    }

    /// A fresh pinned ceremony even while a session is live, for an action outside the session's scope and deletion
    /// (export runs its own, `revealPhrase`): it must derive `expected` (the account on screen; the stored one when
    /// nil), then opens a new session and returns the approval for that one action. A failure leaves the current
    /// session as it was. Deletion spends no approval: it keeps the approval's credential ID for the signal, and the
    /// session the ceremony opened signs the backend sign-in.
    func stepUp(expecting expected: Address? = nil) async throws -> StepUp {
        guard let credentialID = MeraCredentialStore.credentialID, let account = expected ?? MeraCredentialStore.address else { throw Failure.noAccount }
        return try await ceremony.exclusive {
            let session = try open(try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: credentialID), expecting: account)
            let approval = StepUp(credentialID: session.credentialID, address: session.address, id: UUID())
            pendingStepUp = (approval.id, session)
            return approval
        }
    }

    /// Sets the length of sessions opened from now on. Shorter (or the same) is free. Longer needs the owner — a
    /// forced pinned ceremony, even while a session is live — and never extends that live session: it keeps the
    /// `expiresAt` it opened with. When none is live, the ceremony opens one with the new length.
    func setSessionLength(_ requested: TimeInterval) async throws {
        let length = Mera.SessionLength.sanitized(requested)
        guard Mera.SessionLength.needsStepUp(from: sessionLength, to: length) else { storeLength(length); return }
        guard let credentialID = MeraCredentialStore.credentialID, let account = MeraCredentialStore.address else { throw Failure.noAccount }
        try await ceremony.exclusive {
            let result = try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: credentialID)
            if liveSession() != nil {
                // Proof of the owner only: the ceremony's keys are derived to check the address, then dropped.
                guard let check = Mera.SigningSession(account: result.account, utility: nil, credentialID: result.credentialID, length: 0) else { throw PasskeyCeremony.Failure.prfUnavailable }
                check.end()
                if check.address != account { throw Failure.differentPasskey(expected: account, got: check.address) }
            } else {
                _ = try open(result, expecting: account, length: length)
            }
        }
        storeLength(length)
    }

    // MARK: Export

    /// The account's recovery phrase (MERA-PLAN §7): the 24 BIP-39 words of the passkey's account output, which
    /// restore this wallet in any BIP-39 wallet without the passkey. A fresh ceremony pinned to the stored credential
    /// every time — a live session never stands in for it — that must derive `expected` (the account on screen; the
    /// stored one when nil), and the words must derive it too. Like any step-up, the ceremony then opens a new session.
    /// The words are returned, never stored: the caller keeps them only while they are on screen.
    func revealPhrase(expecting expected: Address? = nil) async throws -> [String] {
        guard let credentialID = MeraCredentialStore.credentialID, let account = expected ?? MeraCredentialStore.address else { throw Failure.noAccount }
        return try await ceremony.exclusive {
            let result = try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: credentialID)
            _ = try open(result, expecting: account)
            guard let words = Mera.RecoveryPhrase.words(prf: result.account, account: account) else { throw Failure.phraseUnavailable }
            return words
        }
    }

    // MARK: Signing

    /// Signs one transaction of `action` (a lone transaction with no declared intent when nil, which always asks).
    /// First, whatever the session, what no approval makes acceptable is refused before any prompt
    /// (`Mera.SigningPolicy.refusal`: an out-of-bounds network fee, an output paid to someone else, another token,
    /// `graduateFallback`, a buy on a retired launchpad — its curves looked up on-chain first, `retiredCurves(for:)`).
    /// Then prompt-free only while a session is live and either a step-up already approved this action in it, or the
    /// wallet's own check passes and the action's dollar value fits the caps (charged once per action). Otherwise one
    /// forced pinned ceremony approves the action and opens a new session, and the transaction is signed there.
    func signTransaction(_ transaction: PreparedTransaction, for action: Action? = nil) async throws -> Data {
        #if DEBUG && targetEnvironment(simulator)
        if isStub { try Mera.Stub.require(.transaction(chainId: transaction.chainId)) } // before any prompt
        #endif
        let action = action ?? Action()
        if let account = address {
            let call = Mera.SigningPolicy.Call(transaction)
            let retired = await retiredCurves(for: [call])
            if let reason = Mera.SigningPolicy.refusal(call, intent: action.intent, account: account, retiredCurves: retired) { throw Failure.refused(reason) }
        }
        if let session = liveSession() {
            if action.approvedIn === session { return try session.sign(transaction) }
            if await admits([Mera.SigningPolicy.Call(transaction)], action: action, in: session, charge: true) == .allowed, session === liveSession() {
                return try session.sign(transaction)
            }
        }
        return try await approvedSession(for: action).sign(transaction)
    }

    /// Signs a personal message. DyorHQ's wallet-auth sign-in for this account is the only message a session signs on
    /// its own (opening one with a pinned ceremony when locked); any other message asks, like a transaction outside the
    /// scope — unless a step-up already approved `action` in the live session.
    func signMessage(_ message: Data, for action: Action? = nil) async throws -> Data {
        #if DEBUG && targetEnvironment(simulator)
        if isStub { try Mera.Stub.require(.message) }
        #endif
        if let session = liveSession(), let action, action.approvedIn === session { return try session.signMessage(message) }
        if let account = address, Mera.SigningPolicy.check(message: message, account: account) == .allowed {
            return try await current().signMessage(message)
        }
        return try await approvedSession(for: action ?? Action(.alwaysAsks(.message))).signMessage(message)
    }

    /// `signMessage` for work nobody tapped for (the backend sign-in `signInWithMera` runs after the account is on
    /// screen, and RootView's): signs only in the live session, and only a message the session signs on its own (the
    /// wallet-auth template). Never a prompt: with no live session — the app left the foreground meanwhile — it throws
    /// `promptNeeded`, and the caller skips.
    func signMessageWithoutPrompt(_ message: Data) throws -> Data {
        #if DEBUG && targetEnvironment(simulator)
        if isStub { try Mera.Stub.require(.message) }
        #endif
        guard let session = liveSession(), Mera.SigningPolicy.check(message: message, account: session.address) == .allowed else {
            throw Failure.promptNeeded
        }
        return try session.signMessage(message)
    }

    /// Face ID for one action outside the live session's scope, or any action while locked: a forced pinned ceremony
    /// that must derive this account, opens a new session, and approves everything `action` signs in it. A sheet calls
    /// it when its badge already says Face ID, so the prompt comes straight from the tap; signing does it otherwise.
    func approve(_ action: Action) async throws {
        _ = try await approvedSession(for: action)
    }

    /// The badge for a plan before it is signed: refused, locked or not, when a step is one no approval makes
    /// acceptable; else Face ID while locked; otherwise the wallet's check of every step against the declared intent,
    /// then the caps (previewed, not charged). An approval step the allowance already covers is skipped when the plan
    /// runs, so this is at least as strict as signing in every check but the network fee, which isn't known until a step
    /// is prepared: one out of bounds is refused when it is signed. Side-effect free, like every query a view makes: an
    /// expired session reads as locked here but is ended by its timer or the next signature.
    func assess(_ steps: [TransactionStep], intent: Mera.Intent, chainId: Int = Monad.chainId) async -> Assessment {
        if let account = address {
            let calls = steps.compactMap { Mera.SigningPolicy.Call(step: $0, from: account, chainId: chainId) }
            let retired = await retiredCurves(for: calls)
            for call in calls {
                if let reason = Mera.SigningPolicy.refusal(call, intent: intent, account: account, retiredCurves: retired) { return .refused(reason.summary) }
            }
        }
        guard let session = openSession else { return .faceID(Mera.SigningPolicy.Reason.locked.summary) }
        let calls = steps.compactMap { Mera.SigningPolicy.Call(step: $0, from: session.address, chainId: chainId) }
        guard calls.count == steps.count else { return .faceID(Mera.SigningPolicy.Reason.notAllowlisted.summary) }
        let context = await context(for: intent, session: session)
        switch Mera.SigningPolicy.review(calls, intent: intent, context: context, caps: session.caps) {
        case .allowed: return .promptFree
        case .ask(let reason): return .faceID(reason.summary)
        }
    }

    /// The badge for a Perpl order sent over the trading socket (`authorize`): its worst-case notional against the caps.
    /// Side-effect free: a view body reads it.
    func assessOrder(usd: Double?) -> Assessment {
        guard let session = openSession else { return .faceID(Mera.SigningPolicy.Reason.locked.summary) }
        switch Mera.SigningPolicy.verdict(session.caps.verdict(for: usd)) {
        case .allowed: return .promptFree
        case .ask(let reason): return .faceID(reason.summary)
        }
    }

    // MARK: Scope and caps

    /// Admits one prompt-free action worth `usd` (MERA-PLAN §3, check 3): a step-up `approval` covers exactly the
    /// action that asked for it, outside the caps; otherwise the session must be live and the action within $100 and
    /// within what is left of the session's $250. Anything else throws `StepUpRequired`. Returns the charge, to refund
    /// when the action provably didn't happen.
    func authorize(usd: Double?, approval: StepUp?) throws -> Charge? {
        if let approval, redeem(approval) { return nil }
        guard let session = liveSession() else { throw StepUpRequired(reason: .locked) }
        switch try session.charge(usd: usd) {
        case .allowed: return usd.map { Charge(session: session, usd: $0) }
        case .unpriced: throw StepUpRequired(reason: .unpriced)
        case .overActionCap: throw StepUpRequired(reason: .overActionCap)
        case .overSessionCap: throw StepUpRequired(reason: .overSessionCap)
        }
    }

    /// For an action that always asks (a cancel, a reduce-only close): only a step-up approval admits it.
    func requireStepUp(_ approval: StepUp?, for reason: StepUpRequired.Reason) throws {
        guard let approval, redeem(approval) else { throw StepUpRequired(reason: reason) }
    }

    /// Gives a charge back to the session it was made in (no-op once that session has ended).
    func refund(_ charge: Charge?) {
        guard let charge, let session = charge.session, session === live else { return }
        session.refund(usd: charge.usd)
    }

    // MARK: Perpl

    /// The Perpl API key for a passkey account's stored `token` and the nonce of the enrolment that issued it: the
    /// trading secret is derived from the session's utility output and exists only in memory. Nil while locked, or
    /// before the utility output is fetched. Never persisted: the caller drops it when the session ends
    /// (`MeraSessionLifecycle`).
    func perplKey(token: String, scopeMask: Int, keyNonce: Data?) -> PerplApiKey? {
        #if DEBUG && targetEnvironment(simulator)
        if isStub { return nil } // never enrolled (`enrollPerpl`), so no Perpl socket either
        #endif
        guard let session = openSession else { return nil }
        return try? session.perplApiKey(token: token, scopeMask: scopeMask, keyNonce: keyNonce)
    }

    /// Enrols a Perpl trading key for the account inside the session (opening one when locked): the passkey-derived
    /// key for a fresh nonce, the server's typed data validated for exactly this wallet and key, and its digest
    /// recomputed and signed there. A new nonce every time, so this works on any device, and again after a device lost
    /// its token (`Mera.Purpose.perplTrading(nonce:)`); the caller stores the nonce with the token.
    func enrollPerpl(label: String) async throws -> (key: PerplApiKey, keyNonce: Data) {
        #if DEBUG && targetEnvironment(simulator)
        if isStub { try Mera.Stub.require(.perplEnrolment) } // before any prompt or request to Perpl
        #endif
        let session = try await current()
        if !session.hasUtility { try await fetchUtility(for: session) }
        let nonce = Mera.Purpose.newPerplNonce()
        return (try await session.enrollPerpl(auth: PerplAuthClient(chainId: Monad.chainId), label: label, keyNonce: nonce), nonce)
    }

    /// Makes the live session's utility output available when the unlocking ceremony evaluated one salt only: one
    /// pinned assertion. For a tap (reconnecting Perpl trading); does nothing when it is already there.
    func loadUtility() async throws {
        let session = try await current()
        if !session.hasUtility { try await fetchUtility(for: session) }
    }

    /// The utility output the unlocking ceremony didn't return: one pinned assertion (see `PasskeyCeremony.utility`).
    /// When the provider also returns the account output, it must still derive this account. Attached to the session
    /// it was fetched for, which throws `sessionEnded` if that session ended while the prompt was open.
    private func fetchUtility(for session: Mera.SigningSession) async throws {
        let fetched = try await ceremony.exclusive {
            try await ceremony.utility(rpId: rpId, salts: (Mera.accountSalt, Mera.utilitySalt), pinnedTo: session.credentialID)
        }
        if let output = fetched.account, let derived = Mera.evmAccount(prf: output)?.address, derived != session.address {
            throw Failure.differentPasskey(expected: session.address, got: derived)
        }
        try session.attachUtility(fetched.utility)
        if live === session { lifecycle?.meraSessionDidOpen(self) }
    }

    // MARK: Leaving the app (security audit 2026-09-26, GL-1 and GL-7)

    /// An action the owner already approved starts signing or sending — a plan (`TransactionRun`), a Perpl bracket
    /// (`PerpTradeView`). While one runs, leaving the app doesn't end the session under it. Pair with `endAction`.
    func beginAction() {
        runningActions += 1
    }

    /// An approved action finished. If the app left the foreground meanwhile, the last one to finish ends the session.
    func endAction() {
        runningActions = max(0, runningActions - 1)
        guard runningActions == 0, endsWhenIdle else { return }
        end()
    }

    /// The app left the foreground (RootView). The session ends now, or — while an approved action is still running — the
    /// moment the last one finishes, within `backgroundGrace` (about the background time iOS grants); when that runs out
    /// it ends regardless. It still ends even if the app comes back first, and nothing new can start from the background,
    /// so whoever picks the phone up next has to present the passkey again.
    func endWhenIdle() {
        inBackground = true
        guard runningActions > 0, live != nil else { end(); return }
        endWithLastAction()
    }

    /// The live session ends when the last running action does, and no later than `backgroundGrace` from now (GL-7):
    /// the background time iOS grants ends it when it runs out, and so does a deadline of its own, which holds when iOS
    /// grants none or suspends the app before either fires — `liveSession` checks it on every use.
    private func endWithLastAction() {
        endsWhenIdle = true
        guard idleDeadline == nil else { return }
        idleDeadline = Date().addingTimeInterval(Self.backgroundGrace)
        backgroundTime = BackgroundTime("Passkey session") { [weak self] in self?.end() } // not localized: the task's name, never shown
        idleDeadlineTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.backgroundGrace))
            guard !Task.isCancelled, let self, self.endsWhenIdle else { return }
            self.end()
        }
    }

    /// Nothing ends the session with its running actions any more: it ended, or a ceremony in the foreground replaced it.
    private func cancelEndWithLastAction() {
        endsWhenIdle = false
        idleDeadline = nil
        idleDeadlineTimer?.cancel()
        idleDeadlineTimer = nil
        backgroundTime?.end()
        backgroundTime = nil
    }

    /// Whether a session waiting on its running actions has passed its deadline (`endWithLastAction`).
    private var pastIdleDeadline: Bool { idleDeadline.map { Date() >= $0 } ?? false }

    /// The app is active again. A session waiting on a running action still ends with it (`endWhenIdle`).
    func enteredForeground() {
        inBackground = false
    }

    // MARK: Ending

    /// Ends the live session (expiry, Lock, the app leaving the foreground, sign-out): Perpl trading drops its key and
    /// socket, then the session zeroes its key copies. Permanent: the ended session throws `sessionEnded` from then on,
    /// and the next signature runs a new ceremony.
    func end() {
        expiry?.cancel()
        expiry = nil
        pendingStepUp = nil
        cancelEndWithLastAction() // whatever ended it, nothing waits on its running actions any more
        guard let session = live else { return }
        live = nil
        // Perpl first, so its references to the trading secret are gone before the session wipes its copy.
        lifecycle?.meraSessionDidEnd(self)
        session.end()
    }

    /// Signs out: ends the session and forgets which passkey backs the account. The passkey itself stays in the user's
    /// iCloud Keychain.
    func forget() {
        end()
        MeraCredentialStore.clear()
    }

    // MARK: Private

    /// `approve`: the session the forced pinned ceremony opened, now bound to `action`.
    private func approvedSession(for action: Action) async throws -> Mera.SigningSession {
        guard let credentialID = MeraCredentialStore.credentialID, let account = MeraCredentialStore.address else { throw Failure.noAccount }
        let session = try await ceremony.exclusive {
            try open(try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: credentialID), expecting: account)
        }
        action.approvedIn = session
        return session
    }

    /// Checks 2 and 3 for `calls` of `action` in `session`: every call against the declared intent (verifying a
    /// launchpad curve on-chain first), then the caps — charged once per action and session when `charge` is set.
    private func admits(_ calls: [Mera.SigningPolicy.Call], action: Action, in session: Mera.SigningSession, charge: Bool) async -> Mera.SigningPolicy.Verdict {
        let context = await context(for: action.intent, session: session)
        for call in calls {
            if case .ask(let reason) = Mera.SigningPolicy.check(call, intent: action.intent, context: context) { return .ask(reason) }
        }
        guard charge else { return .allowed }
        if action.chargedIn === session { return .allowed }
        guard let verdict = try? session.charge(usd: action.intent.usd) else { return .ask(.locked) }
        if verdict == .allowed { action.chargedIn = session }
        return Mera.SigningPolicy.verdict(verdict)
    }

    /// What `Mera.SigningPolicy.refusal` needs to refuse a buy on a retired launchpad: which of `calls`' curves a retired
    /// factory recorded, read on-chain. Nothing is read for calls that pay into no curve; with no lookup wired, or a read
    /// that fails, no curve can be ruled out (`.unknown`), so a curve buy is refused.
    private func retiredCurves(for calls: [Mera.SigningPolicy.Call]) async -> Mera.SigningPolicy.RetiredCurves {
        let candidates = Mera.SigningPolicy.curveCandidates(calls)
        guard !candidates.isEmpty else { return .none }
        guard let lookup = retiredCurveLookup else { return .unknown }
        return await lookup(candidates)
    }

    /// What the scope check needs from outside the calldata: this session's account and end, the configured contracts,
    /// and — for a launchpad trade — the curve a known factory recorded for the launch, read on-chain.
    private func context(for intent: Mera.Intent, session: Mera.SigningSession) async -> Mera.SigningPolicy.Context {
        var curves: [Address: Address] = [:]
        if let verify = curveVerifier {
            for token in Set(intent.parts.compactMap(\.launchToken)) {
                if let curve = await verify(token) { curves[token] = curve }
            }
        }
        return Mera.SigningPolicy.Context(account: session.address, expiresAt: session.expiresAt, contracts: contracts, verifiedCurves: curves)
    }

    /// The live session, or a new one from a ceremony pinned to the stored credential that must derive the stored
    /// address.
    private func current() async throws -> Mera.SigningSession {
        if let session = liveSession() { return session }
        guard let credentialID = MeraCredentialStore.credentialID else { throw Failure.noAccount }
        return try await ceremony.exclusive {
            try open(try await ceremony.assert(rpId: rpId, salts: salts, pinnedTo: credentialID), expecting: MeraCredentialStore.address)
        }
    }

    /// The live session; one that has expired (its timer can lag, e.g. across a suspension) is ended here. For the
    /// signing and authorize paths only.
    private func liveSession() -> Mera.SigningSession? {
        guard let live else { return nil }
        if live.isLive(), !pastIdleDeadline { return live }
        end()
        return nil
    }

    /// The live session for a query (a badge, the Perpl key): nil once expired or past its deadline in the background,
    /// without ending it, so reading it never changes observed state — a view body may read it. The timers, or the next
    /// signature, end the session.
    private var openSession: Mera.SigningSession? {
        guard let live, live.isLive(), !pastIdleDeadline else { return nil }
        return live
    }

    /// Opens a session from a ceremony's outputs once the account checks out against `expecting`, then records the
    /// public hints. Throws before changing anything, so a failure leaves no address derived and adopted. A session
    /// that was live is replaced (and zeroed); its step-up approval, if any, is void.
    private func open(_ result: PasskeyCeremony.Result, expecting: Address?, length: TimeInterval? = nil) throws -> Mera.SigningSession {
        guard let session = Mera.SigningSession(account: result.account, utility: result.utility, credentialID: result.credentialID,
                                                userID: result.userID, length: length ?? sessionLength) else { throw PasskeyCeremony.Failure.prfUnavailable }
        if let expecting, expecting != session.address {
            session.end()
            throw Failure.differentPasskey(expected: expecting, got: session.address)
        }
        let previous = live
        live = session
        pendingStepUp = nil
        previous?.end()
        scheduleExpiry(of: session)
        MeraCredentialStore.save(credentialID: result.credentialID, address: session.address)
        lifecycle?.meraSessionDidOpen(self)
        // A ceremony that finished after the app left the foreground (GL-7): the session serves the call that asked for
        // it, then ends — with the last running action, within the same deadline as `endWhenIdle`, or, when none runs, as
        // soon as that call has it.
        if inBackground {
            if runningActions > 0 {
                endWithLastAction()
            } else {
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.live === session, self.inBackground, self.runningActions == 0 else { return }
                    self.end()
                }
            }
        } else {
            // The owner presented the passkey with the app in front: this session doesn't end with actions an earlier
            // one left running in the background.
            cancelEndWithLastAction()
        }
        return session
    }

    /// Ends `session` at its `expiresAt`, unless it was ended or replaced before then.
    private func scheduleExpiry(of session: Mera.SigningSession) {
        expiry?.cancel()
        let expiresAt = session.expiresAt
        expiry = Task { @MainActor [weak self, weak session] in
            let delay = expiresAt.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, let session, self.live === session else { return }
            self.end()
        }
    }

    /// Spends a step-up approval: valid once, and only while the session its ceremony opened is still the live one.
    private func redeem(_ approval: StepUp) -> Bool {
        guard let pending = pendingStepUp, pending.id == approval.id, let session = liveSession(), session === pending.session else { return false }
        pendingStepUp = nil
        return true
    }

    private func storeLength(_ length: TimeInterval) {
        sessionLength = length
        UserDefaults.standard.set(length, forKey: Self.lengthKey)
    }
}

/// A passkey account's signer for work nobody tapped for (`Session.backgroundWallet`): it signs the wallet-auth message
/// inside the live session and nothing else, and never shows a prompt — without a live session it throws
/// `MeraSession.Failure.promptNeeded`.
struct MeraBackgroundSigner: Wallet {
    let address: Address
    let session: MeraSession

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        throw MeraSession.Failure.promptNeeded
    }

    func signMessage(_ message: Data) async throws -> Data {
        try await session.signMessageWithoutPrompt(message)
    }
}

/// The app's signer for a Mera account. Signing goes through the session and its scope check, so anything that isn't
/// prompt-free shows the passkey prompt right where the signature is needed, and no key is ever stored. `action` is
/// the sheet's declared intent (`Session.wallet(for:)`); without one every signature asks. It signs transactions and
/// messages only, never a raw digest: Perpl enrolment builds its digest inside the session, and Moments collect takes
/// the exact-approval path instead of a Permit2 signature.
struct MeraWallet: Wallet {
    let address: Address
    let session: MeraSession
    var action: MeraSession.Action? = nil

    func sign(_ transaction: PreparedTransaction) async throws -> Data {
        try await session.signTransaction(transaction, for: action)
    }

    func signMessage(_ message: Data) async throws -> Data {
        try await session.signMessage(message, for: action)
    }
}
